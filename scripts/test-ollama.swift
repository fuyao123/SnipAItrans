import Foundation

// Uses an ephemeral mocked Ollama server. No model is downloaded or deleted.
@main
struct OllamaChecks {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    @MainActor static func waitUntil(_ condition: () -> Bool, _ message: String) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        fatalError(message)
    }

    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaMockProtocol.self]
        let externalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("snipai-external-test-\(UUID().uuidString)", isDirectory: true)
        let service = OllamaService(session: URLSession(configuration: config), managedRoot: externalRoot)
        service.refresh()
        try await waitUntil({ service.models.contains("qwen2.5:7b") }, "Existing model was not discovered")
        require(!service.models.contains("remote:latest"), "Cloud model appeared in local list")
        let result = try await service.translate(text: "good morning", source: .english, target: .chineseSimplified, model: "qwen2.5:7b")
        require(result == "早上好", "Local translation failed")
        OllamaMockProtocol.setStreaming(true)
        var partials: [String] = []
        let streamed = try await service.translateStreaming(text: "good morning", source: .english, target: .chineseSimplified, model: "qwen2.5:7b") { partials.append($0) }
        require(streamed == "早上好" && partials.first == "早上", "Streaming must show partial text and return the complete translation: \(streamed), partials=\(partials)")
        OllamaMockProtocol.setIncompleteStream(true)
        do {
            _ = try await service.translateStreaming(text: "good morning", source: .english, target: .chineseSimplified, model: "qwen2.5:7b") { _ in }
            fatalError("Incomplete streaming response was accepted as complete")
        } catch { }
        OllamaMockProtocol.setIncompleteStream(false)
        OllamaMockProtocol.setStreaming(false)
        do {
            _ = try await service.translate(text: "test", source: .english, target: .chineseSimplified, model: "remote:latest")
            fatalError("A remote model was accepted as local")
        } catch { }
        var ready = false
        service.setup(model: "qwen2.5:3b") { ready = true }
        try await waitUntil({ !service.isBusy }, "Model installation did not finish")
        require(ready && service.models.contains("qwen2.5:3b"), "Model pull or setup failed: \(service.errorMessage ?? "")")
        service.uninstall()
        require(service.models.contains("qwen2.5:7b"), "Uninstall touched an external Ollama")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snipai-owned-test-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("Ollama.app/Contents/Resources/ollama")
        let neighbor = FileManager.default.temporaryDirectory.appendingPathComponent("snipai-neighbor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data("keep".utf8).write(to: neighbor)
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: root, create: true)
        defer {
            try? FileManager.default.removeItem(at: neighbor)
            try? FileManager.default.removeItem(at: trash.appendingPathComponent(root.lastPathComponent))
            try? FileManager.default.removeItem(at: root)
        }
        let managed = OllamaService(session: URLSession(configuration: config), managedRoot: root)
        require(managed.isManagedInstalled, "Test runtime was not discovered")
        managed.uninstall()
        require(!FileManager.default.fileExists(atPath: root.path), "Managed runtime was not removed")
        require(FileManager.default.fileExists(atPath: neighbor.path), "Uninstall touched unrelated data")
        print("Ollama integration checks passed")
    }
}

private final class OllamaMockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pulled = false
    nonisolated(unsafe) private static var incompleteStream = false
    nonisolated(unsafe) private static var streaming = false
    static func setIncompleteStream(_ value: Bool) {
        lock.lock(); incompleteStream = value; lock.unlock()
    }
    static func setStreaming(_ value: Bool) {
        lock.lock(); streaming = value; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let body: String
        switch url.path {
        case "/api/tags":
            Self.lock.lock()
            let extra = Self.pulled ? ", {\"name\":\"qwen2.5:3b\"}" : ""
            Self.lock.unlock()
            body = "{\"models\":[{\"name\":\"qwen2.5:7b\"}, {\"name\":\"remote:latest\",\"remote_model\":\"remote\"}\(extra)]}"
        case "/api/chat":
            Self.lock.lock(); let isStreaming = Self.streaming; let incomplete = Self.incompleteStream; Self.lock.unlock()
            if isStreaming {
                body = "{\"message\":{\"content\":\"早上\"},\"done\":false}\n" +
                    "{\"message\":{\"content\":\"好\"},\"done\":\(incomplete ? "false" : "true")}\n"
            } else {
                body = "{\"message\":{\"content\":\"早上好\"},\"done\":true}"
            }
        case "/api/pull":
            Self.lock.lock(); Self.pulled = true; Self.lock.unlock()
            body = "{\"status\":\"downloading\",\"total\":100,\"completed\":50}\n{\"status\":\"success\"}\n"
        default:
            body = "{}"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
