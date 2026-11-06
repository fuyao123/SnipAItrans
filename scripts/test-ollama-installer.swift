import Foundation

// Exercises a fresh installation with the previously verified official ZIP.
// The server/model API is mocked; no existing Ollama data is modified.
@main
struct OllamaInstallerChecks {
    @MainActor static func main() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/snipaitrans-ollama-verified.zip") else {
            print("Skipped: verified official archive not present"); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snipai-install-test-\(UUID().uuidString)")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InstallerMockProtocol.self]
        let service = OllamaService(
            session: URLSession(configuration: config), managedRoot: root,
            runtimeDownloadURL: URL(string: "https://ollama-installer-test.invalid/archive.zip")!
        )
        var ready = false
        service.setup(model: "qwen2.5:7b") { ready = true }
        for _ in 0..<1500 {
            if !service.isBusy { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard ready && service.isManagedInstalled && service.models.contains("qwen2.5:7b") else {
            fatalError("One-click installation failed: \(service.errorMessage ?? service.status)")
        }
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: root, create: true)
        service.uninstall()
        guard !FileManager.default.fileExists(atPath: root.path) else { fatalError("Uninstall failed") }
        // This is a test-only archive, retained in /tmp for normal OS cleanup.
        let trashed = trash.appendingPathComponent(root.lastPathComponent)
        if FileManager.default.fileExists(atPath: trashed.path) {
            try FileManager.default.moveItem(at: trashed, to: root)
        }
        print("Fresh Ollama installation and uninstall checks passed")
    }
}

private final class InstallerMockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var modelReady = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.host == "ollama-installer-test.invalid" {
            let file = URL(fileURLWithPath: "/tmp/snipaitrans-ollama-verified.zip")
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "\(size)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let handle = try? FileHandle(forReadingFrom: file) {
                defer { try? handle.close() }
                while let data = try? handle.read(upToCount: 262_144), !data.isEmpty {
                    client?.urlProtocol(self, didLoad: data)
                }
            }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if url.port == 11434 {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        let body: String
        if url.path == "/api/pull" {
            Self.lock.lock(); Self.modelReady = true; Self.lock.unlock()
            body = "{\"status\":\"success\"}\n"
        } else {
            Self.lock.lock(); let ready = Self.modelReady; Self.lock.unlock()
            body = ready ? "{\"models\":[{\"name\":\"qwen2.5:7b\"}]}" : "{\"models\":[]}"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
