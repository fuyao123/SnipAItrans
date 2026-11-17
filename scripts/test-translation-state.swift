import Foundation

// swiftc -swift-version 6 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
//   Sources/GPTTranslator/{Provider,TranslationService,TranslationViewModel,AppleTranslationService,OllamaService,APIModelCatalog,AppUpdateService,AppIdentity,KeychainStore}.swift \
//   scripts/test-translation-state.swift -o /tmp/snipaitrans-state-check && /tmp/snipaitrans-state-check
// Run as a standalone executable so defaults are isolated; requests are mocked.
@main
struct TranslationStateChecks {
    @MainActor
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    @MainActor
    static func waitUntil(_ condition: () -> Bool, _ message: String) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        fatalError(message)
    }

    @MainActor
    static func main() async throws {
        guard Bundle.main.bundleIdentifier == nil else {
            fatalError("Run this test as an unbundled executable to isolate defaults")
        }
        let source = CustomAPISource(
            displayName: "Mock",
            endpoint: "https://translation-test.invalid/v1/chat/completions",
            model: "mock-model"
        )
        let initialDefaults: [String: Any] = [
            "provider": ModelProvider.customAPI.rawValue,
            "customAPISources": try JSONEncoder().encode([source]),
            "selectedCustomAPIID": source.id.uuidString,
            "floatingSourceIDs": ["custom.\(source.id.uuidString)"]
        ]
        for (key, value) in initialDefaults { UserDefaults.standard.set(value, forKey: key) }
        UserDefaults.standard.removeObject(forKey: "selectedAPIModelSourceID")
        UserDefaults.standard.removeObject(forKey: "apiModelSources")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = TranslationViewModel(
            directService: DirectProviderService(session: session),
            apiModelCatalog: APIModelCatalog(session: session)
        )
        model.apiKey = "mock-key"
        require(model.provider == .customAPI, "Test provider was not isolated")
        require(model.enabledFloatingSources.map(\.id) == ["custom.\(source.id.uuidString)"], "Test source was not isolated")

        model.sourceText = "main original"
        model.translatedText = "main translation"
        model.errorMessage = "main error"
        model.translateForFloatingWindow("first selection")
        require(model.sourceText == "main original", "Selection replaced main source")
        require(model.translatedText == "main translation", "Selection cleared main result")
        require(model.errorMessage == "main error", "Selection cleared main error")
        try await waitUntil({ model.comparisonResults.first?.translatedText == "translated:first selection" }, "Floating result missing")
        require(model.floatingSourceText == "first selection", "Floating source missing")
        require(model.translatedText == "main translation", "Floating result replaced main result")

        model.translateForFloatingWindow("slow canceled selection")
        model.showFloatingError("selection error")
        require(model.floatingErrorMessage == "selection error", "Floating error missing")
        require(model.floatingSourceText.isEmpty && model.comparisonResults.isEmpty, "Stale floating content after error")
        require(model.sourceText == "main original" && model.errorMessage == "main error", "Floating error changed main state")
        try await Task.sleep(nanoseconds: 600_000_000)
        require(model.comparisonResults.isEmpty && model.floatingErrorMessage == "selection error", "Canceled result replaced floating error")

        model.translateForFloatingWindow("first selection")
        require(model.comparisonResults.first?.translatedText == "translated:first selection", "Cached floating result missing")
        require(model.floatingErrorMessage == nil && model.translatedText == "main translation", "Cached result changed main state")

        model.sourceText = "main scheduled"
        model.scheduleAutomaticTranslation(delayNanoseconds: 120_000_000)
        model.translateForFloatingWindow("simultaneous selection")
        try await waitUntil({ model.translatedText == "translated:main scheduled" }, "Selection cancelled main scheduled translation")
        try await waitUntil({ model.comparisonResults.first?.translatedText == "translated:simultaneous selection" }, "Concurrent floating translation missing")
        require(model.floatingErrorMessage == nil, "Floating error did not clear on next translation")
        require(model.sourceText == "main scheduled", "Concurrent selection changed main source")

        model.translateForFloatingWindow("slow selection")
        model.sourceText = "main edited during selection"
        try await waitUntil({ model.comparisonResults.first?.translatedText == "translated:slow selection" }, "Editing main source cancelled floating result")

        model.sourceText = "slow main"
        model.translate()
        model.translateForFloatingWindow("selection during main")
        try await waitUntil({ model.comparisonResults.first?.translatedText == "translated:selection during main" }, "Floating translation failed while main request was running")
        try await waitUntil({ model.translatedText == "translated:slow main" }, "Floating translation interfered with main request")

        model.translateForFloatingWindow("slow old selection")
        try await Task.sleep(nanoseconds: 30_000_000)
        model.translateForFloatingWindow("new selection")
        try await waitUntil({ model.comparisonResults.first?.translatedText == "translated:new selection" }, "Latest selection missing")
        try await Task.sleep(nanoseconds: 700_000_000)
        require(model.floatingSourceText == "new selection", "Stale request changed floating source")
        require(model.comparisonResults.first?.translatedText == "translated:new selection", "Stale result replaced latest selection")
        require(model.sourceText == "slow main" && model.translatedText == "translated:slow main", "Rapid selections changed main state")

        let localConfiguration = URLSessionConfiguration.ephemeral
        localConfiguration.protocolClasses = [LocalCompletionMockURLProtocol.self]
        let localSession = URLSession(configuration: localConfiguration)
        let localService = OllamaService(session: localSession, managedRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let localModel = TranslationViewModel(ollamaService: localService)
        localModel.provider = .ollama
        localModel.modelName = "qwen2.5:7b"
        localModel.floatingSourceIDs = [ModelProvider.ollama.rawValue]
        localModel.translateForFloatingWindow("local complete result")
        try await Task.sleep(nanoseconds: 200_000_000)
        require(localModel.comparisonResults.first?.isLoading == true && localModel.comparisonResults.first?.translatedText == nil,
                "Ollama selection must not show partial output while the response is in progress")
        try await waitUntil({ localModel.comparisonResults.first?.translatedText == "完整译文" }, "Complete Ollama selection result missing")
        require(localModel.comparisonResults.first?.isLoading == false, "Ollama selection must finish loading")
        require(LocalCompletionMockURLProtocol.usedNonStreamingRequest(), "Ollama selection must request a complete response")

        // Upgrade from a removed Google Web provider without hiding remaining sources.
        UserDefaults.standard.set("googleWeb", forKey: "provider")
        UserDefaults.standard.set(["googleWeb", "ollama"], forKey: "floatingSourceIDs")
        UserDefaults.standard.set(["googleWeb", "ollama"], forKey: "floatingSourceOrder")
        let migrated = TranslationViewModel(ollamaService: localService)
        require(migrated.provider == .ollama, "Removed default should migrate to an enabled source")
        require(migrated.enabledFloatingSources.map(\.id) == ["ollama"], "Removed source must disappear without affecting Ollama")
        require(UserDefaults.standard.string(forKey: "provider") == "ollama", "Migrated default must persist")
        require(!(UserDefaults.standard.stringArray(forKey: "floatingSourceIDs") ?? []).contains("googleWeb"), "Removed source must be removed from saved settings")
        require(!(UserDefaults.standard.stringArray(forKey: "floatingSourceOrder") ?? []).contains("googleWeb"), "Removed source must be removed from saved order")
        require(migrated.allTranslationSources.contains(where: { $0.provider == .antigravityOAuth }), "Gemini OAuth must remain available")

        UserDefaults.standard.set("googleWeb", forKey: "provider")
        UserDefaults.standard.set(["googleWeb"], forKey: "floatingSourceIDs")
        UserDefaults.standard.set(["googleWeb"], forKey: "floatingSourceOrder")
        let onlyRemoved = TranslationViewModel(ollamaService: localService)
        if #available(macOS 15.0, *) {
            require(onlyRemoved.provider == .appleTranslation, "Only removed source must fall back to Apple translation on supported macOS")
        } else {
            require(onlyRemoved.provider == .openAIChatGPT, "Only removed source must have a supported fallback")
        }
        require(onlyRemoved.enabledFloatingSources.count == 1, "Removing the last source must retain one fallback")

        UserDefaults.standard.set("googleWeb", forKey: "provider")
        UserDefaults.standard.set(["obsolete-source"], forKey: "floatingSourceIDs")
        let invalidFallback = TranslationViewModel(ollamaService: localService)
        require(invalidFallback.enabledFloatingSources.count == 1, "Removed provider with stale IDs must retain one fallback")

        UserDefaults.standard.set("googleWeb", forKey: "provider")
        UserDefaults.standard.set(["googleWeb", "custom.\(source.id.uuidString)"], forKey: "floatingSourceIDs")
        UserDefaults.standard.set(["custom.\(source.id.uuidString)", "googleWeb"], forKey: "floatingSourceOrder")
        let customFallback = TranslationViewModel(ollamaService: localService)
        require(customFallback.provider == .customAPI && customFallback.selectedCustomAPIID == source.id,
                "Removed default must preserve the enabled custom API source")
        require(customFallback.enabledFloatingSources.map(\.id) == ["custom.\(source.id.uuidString)"], "Custom API source must stay enabled")

        UserDefaults.standard.set("antigravityOAuth", forKey: "provider")
        UserDefaults.standard.set(["googleWeb", "antigravityOAuth"], forKey: "floatingSourceIDs")
        UserDefaults.standard.set(["antigravityOAuth", "googleWeb"], forKey: "floatingSourceOrder")
        let geminiPreserved = TranslationViewModel(ollamaService: localService)
        require(geminiPreserved.provider == .antigravityOAuth && geminiPreserved.enabledFloatingSources.map(\.id) == ["antigravityOAuth"],
                "Existing Gemini OAuth selection must remain unchanged")
        print("Translation state checks passed")
    }
}

private final class LocalCompletionMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var nonStreaming = false
    private let lock = NSLock()
    private var stopped = false

    static func usedNonStreamingRequest() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return nonStreaming
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        if url.path == "/api/tags" {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"models\":[{\"name\":\"qwen2.5:7b\"}]}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body: Data
        if let data = request.httpBody {
            body = data
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            var data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(bytes, count: count)
            }
            body = data
        } else {
            body = Data()
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        Self.stateLock.lock(); Self.nonStreaming = json?["stream"] as? Bool == false; Self.stateLock.unlock()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"message\":{\"content\":\"".utf8))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { [self] in
            lock.lock(); let shouldRespond = !stopped; lock.unlock()
            guard shouldRespond else { return }
            client?.urlProtocol(self, didLoad: Data("完整译文\"},\"done\":true}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

private final class TranslationMockURLProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body: Data
        let delay: Double
        if request.httpMethod == "GET" {
            body = Data("{\"data\":[{\"id\":\"mock-model\"}]}".utf8)
            delay = 0.01
        } else {
            let json = (try? JSONSerialization.jsonObject(with: requestBody())) as? [String: Any]
            let messages = json?["messages"] as? [[String: String]]
            let text = messages?.last?["content"] ?? ""
            let response: [String: Any] = ["choices": [["message": ["content": "translated:\(text)"]]]]
            body = try! JSONSerialization.data(withJSONObject: response)
            delay = text.hasPrefix("slow") ? 0.5 : 0.03
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            lock.lock()
            let shouldRespond = !stopped
            lock.unlock()
            guard shouldRespond else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }

    override func stopLoading() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
