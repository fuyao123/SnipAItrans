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
        UserDefaults.standard.register(defaults: [
            "provider": ModelProvider.customAPI.rawValue,
            "customAPISources": try JSONEncoder().encode([source]),
            "selectedCustomAPIID": source.id.uuidString,
            "floatingSourceIDs": ["custom.\(source.id.uuidString)"]
        ])
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
        print("Translation state checks passed")
    }
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
