import AppKit
import Foundation
import SystemConfiguration

/// Manages only the runtime and models downloaded by SnipAItrans. A running
/// system Ollama is also usable, but is never stopped or uninstalled here.
@MainActor
final class OllamaService: ObservableObject {
    static let recommendedModels = ["qwen2.5:7b", "qwen2.5:3b", "qwen2.5:1.5b"]
    private static let downloadURL = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!
    private static let externalURL = URL(string: "http://127.0.0.1:11434")!
    private static let managedURL = URL(string: "http://127.0.0.1:11553")!

    @Published private(set) var models: [String] = []
    @Published private(set) var status = "尚未配置 Ollama"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false
    @Published private(set) var progress: Double?
    @Published private(set) var usingExternalService = false

    private let session: URLSession
    private let root: URL
    private let runtimeDownloadURL: URL
    private var server: Process?
    private var baseURL: URL?
    private var operation: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var startupTask: Task<Void, Error>?
    private var terminationObserver: NSObjectProtocol?

    private var application: URL { root.appendingPathComponent("Ollama.app", isDirectory: true) }
    private var executable: URL { application.appendingPathComponent("Contents/Resources/ollama") }
    private var modelsDirectory: URL { root.appendingPathComponent("models", isDirectory: true) }
    var isManagedInstalled: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }
    var modelChoices: [String] {
        var seen = Set<String>()
        return (models + Self.recommendedModels).filter { seen.insert($0).inserted }
    }

    init(session: URLSession = .shared, managedRoot: URL? = nil, runtimeDownloadURL: URL? = nil) {
        self.session = session
        self.root = managedRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnipAItrans/Ollama", isDirectory: true)
        self.runtimeDownloadURL = runtimeDownloadURL ?? Self.downloadURL
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopOwnedServer() }
        }
    }

    func refresh() {
        guard !isBusy else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                let url = try await availableServer(startManaged: true)
                let available = try await listModels(at: url)
                guard !Task.isCancelled else { return }
                models = available
                errorMessage = nil
                status = models.isEmpty ? "Ollama 已连接，尚未安装模型" : "已发现 \(models.count) 个本地模型"
            } catch {
                guard !Task.isCancelled else { return }
                models = []
                errorMessage = nil
                status = isManagedInstalled ? "Ollama 未运行，请重试" : "选择模型后点击一键安装"
            }
        }
    }

    func setup(model rawModel: String, onReady: @escaping @MainActor () -> Void) {
        guard !isBusy else { return }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isLocalModelName(model) else {
            errorMessage = "请输入有效的本地 Ollama 模型名称，不能使用云端模型。"
            return
        }
        isBusy = true
        refreshTask?.cancel()
        errorMessage = nil
        progress = nil
        operation = Task {
            defer { isBusy = false; progress = nil; operation = nil }
            do {
                let url: URL
                if isManagedInstalled {
                    url = try await availableServer(startManaged: true)
                } else if (try? await listModels(at: Self.externalURL)) != nil {
                    baseURL = Self.externalURL
                    usingExternalService = true
                    url = Self.externalURL
                } else {
                    try await installRuntime()
                    url = try await availableServer(startManaged: true)
                }
                try Task.checkCancellation()
                models = try await listModels(at: url)
                if !models.contains(model) {
                    status = "正在下载 \(model)…"
                    try await pull(model: model, at: url)
                    models = try await listModels(at: url)
                    guard models.contains(model) else { throw Failure.message("模型下载完成，但 Ollama 未返回该模型。") }
                }
                status = "\(model) 已就绪"
                onReady()
            } catch is CancellationError {
                status = "已取消安装；可以稍后重试"
            } catch {
                errorMessage = error.localizedDescription
                status = "安装或配置未完成"
            }
        }
    }

    func cancelSetup() { operation?.cancel() }

    func uninstall() {
        guard !isBusy, isManagedInstalled else { return }
        stopOwnedServer()
        do {
            // Trash makes removal recoverable and never touches ~/.ollama or an
            // independently installed Ollama.app.
            try FileManager.default.trashItem(at: root, resultingItemURL: nil)
            baseURL = nil
            models = []
            usingExternalService = false
            errorMessage = nil
            status = "已移到废纸篓，清空废纸篓后可释放空间"
        } catch {
            errorMessage = "无法卸载本软件安装的 Ollama：\(error.localizedDescription)"
        }
    }

    func translate(text: String, source: LanguageOption, target: LanguageOption, model: String) async throws -> String {
        guard Self.isLocalModelName(model) else { throw Failure.message("请选择有效的本地模型。") }
        let url = try await availableServer(startManaged: true)
        guard try await listModels(at: url).contains(model) else {
            throw Failure.message("该本地模型尚未安装，请在设置中安装。")
        }
        let sourceName = source == .auto ? "the detected source language" : source.promptName
        let prompt = "Translate from \(sourceName) to \(target.promptName). Preserve meaning and formatting. Return only the translation.\n\n\(text)"
        var request = URLRequest(url: url.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false, "keep_alive": "5m",
            "messages": [["role": "user", "content": prompt]]
        ])
        let (data, response) = try await session.data(for: request)
        try check(response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let result = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else { throw Failure.message("本地模型没有返回翻译结果。") }
        return result
    }

    func testConnection(model: String) async throws {
        let url = try await availableServer(startManaged: true)
        let available = try await listModels(at: url)
        guard available.contains(model) else { throw Failure.message("请先安装所选本地模型。") }
    }

    private func availableServer(startManaged: Bool) async throws -> URL {
        if let baseURL, (try? await listModels(at: baseURL)) != nil { return baseURL }
        if isManagedInstalled, startManaged {
            if let startupTask {
                try await startupTask.value
            } else {
                let task = Task { try await startOwnedServer() }
                startupTask = task
                defer { startupTask = nil }
                try await task.value
            }
            baseURL = Self.managedURL
            usingExternalService = false
            return Self.managedURL
        }
        if (try? await listModels(at: Self.externalURL)) != nil {
            baseURL = Self.externalURL
            usingExternalService = true
            return Self.externalURL
        }
        throw Failure.message("请在设置中选择模型并点击“一键安装并启用”。")
    }

    private func startOwnedServer() async throws {
        if server?.isRunning == true, (try? await listModels(at: Self.managedURL)) != nil { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = "127.0.0.1:11553"
        environment["OLLAMA_MODELS"] = modelsDirectory.path
        environment["OLLAMA_NO_CLOUD"] = "1"
        environment["OLLAMA_KEEP_ALIVE"] = "5m"
        if environment["HTTPS_PROXY"] == nil, environment["https_proxy"] == nil,
           let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any],
           (proxies[kSCPropNetProxiesHTTPSEnable as String] as? NSNumber)?.boolValue == true,
           let host = proxies[kSCPropNetProxiesHTTPSProxy as String] as? String,
           let port = proxies[kSCPropNetProxiesHTTPSPort as String] as? Int {
            environment["HTTPS_PROXY"] = "http://\(host):\(port)"
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        server = process
        for _ in 0..<60 {
            try Task.checkCancellation()
            guard process.isRunning else { throw Failure.message("本地 Ollama 启动失败，端口 11553 可能已被占用。") }
            if (try? await listModels(at: Self.managedURL)) != nil { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        stopOwnedServer()
        throw Failure.message("本地 Ollama 启动超时，请重试。")
    }

    private func stopOwnedServer() {
        if let server, server.isRunning { server.terminate() }
        server = nil
        if baseURL == Self.managedURL { baseURL = nil }
    }

    private func listModels(at url: URL) async throws -> [String] {
        var request = URLRequest(url: url.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        let (data, response) = try await session.data(for: request)
        try check(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["models"] as? [[String: Any]] else { throw Failure.message("无法读取 Ollama 模型列表。") }
        return items.compactMap { item in
            if let remote = item["remote_model"] as? String, !remote.isEmpty { return nil }
            guard let name = item["name"] as? String, Self.isLocalModelName(name) else { return nil }
            return name
        }
    }

    private func pull(model: String, at url: URL) async throws {
        var request = URLRequest(url: url.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.message("模型下载请求失败，请检查网络后重试。")
        }
        var succeeded = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8),
                  let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = item["error"] as? String { throw Failure.message(error) }
            if let total = item["total"] as? Double, total > 0, let completed = item["completed"] as? Double {
                progress = min(max(completed / total, 0), 1)
            }
            if (item["status"] as? String) == "success" { succeeded = true }
        }
        guard succeeded else { throw Failure.message("模型下载未完成，请重试。") }
    }

    private func installRuntime() async throws {
        guard #available(macOS 14, *) else { throw Failure.message("Ollama 需要 macOS 14 或更新版本。") }
        status = "正在下载 Ollama（约 220 MB）…"
        var resumeData: Data?
        var result: (URL, URLResponse)?
        for attempt in 0..<4 {
            do {
                if let resumeData {
                    result = try await session.download(resumeFrom: resumeData)
                } else {
                    result = try await session.download(from: runtimeDownloadURL)
                }
                break
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard attempt < 3 else { throw error }
                resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                status = "下载中断，正在重试（\(attempt + 1)/3）…"
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }
        guard let (downloaded, response) = result else { throw Failure.message("Ollama 下载失败。") }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.message("Ollama 下载失败，请检查网络后重试。")
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("snipaitrans-ollama-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("Ollama.zip")
        try FileManager.default.moveItem(at: downloaded, to: archive)
        status = "正在安装并校验 Ollama…"
        try await Self.runTool("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
        let extracted = staging.appendingPathComponent("Ollama.app", isDirectory: true)
        let requirement = "anchor apple generic and identifier \"com.electron.ollama\" and certificate leaf[subject.OU] = \"3MU9H2V9Y9\""
        try await Self.runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", extracted.path])
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: extracted, to: application)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    private nonisolated static func runTool(_ executable: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.message("Ollama 安装包解压或签名校验失败。") }
        }.value
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.message("Ollama 返回无效响应。") }
        guard (200..<300).contains(http.statusCode) else {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure.message(error ?? "Ollama 请求失败（HTTP \(http.statusCode)）。")
        }
    }

    private static func isLocalModelName(_ name: String) -> Bool {
        !name.isEmpty && !name.lowercased().hasSuffix(":cloud") &&
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/-]*$", options: .regularExpression) != nil
    }

    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
    }
}
