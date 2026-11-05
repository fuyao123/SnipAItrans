import Foundation

// Run with: swiftc Sources/GPTTranslator/APIModelCatalog.swift scripts/test-model-catalog.swift -o /tmp/gpt-model-check && /tmp/gpt-model-check
@main
struct APIModelCatalogChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func main() async throws {
        let deepSeek = try APIModelCatalog.modelsURL(for: "https://api.deepseek.com/chat/completions")
        let glm = try APIModelCatalog.modelsURL(for: "https://open.bigmodel.cn/api/paas/v4/chat/completions")
        let custom = try APIModelCatalog.modelsURL(for: "https://example.com/v1/chat/completions/?api-version=1")
        require(deepSeek.absoluteString == "https://api.deepseek.com/models", "DeepSeek endpoint")
        require(glm.absoluteString == "https://open.bigmodel.cn/api/paas/v4/models", "GLM endpoint")
        require(custom.absoluteString == "https://example.com/v1/models?api-version=1", "Custom endpoint")
        for endpoint in ["https://example.com/v1/other", "https://user:secret@example.com/v1/chat/completions", "file:///tmp/chat/completions"] {
            do {
                _ = try APIModelCatalog.modelsURL(for: endpoint)
                fatalError("Accepted an unsupported endpoint")
            } catch { }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelMockURLProtocol.self]
        let catalog = APIModelCatalog(session: URLSession(configuration: configuration))
        let endpoint = "https://api.deepseek.com/chat/completions"
        ModelMockURLProtocol.handler = { request in
            require(request.url?.absoluteString == "https://api.deepseek.com/models", "Models URL")
            require(request.httpMethod == "GET", "Models method")
            require(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "Bearer authentication")
            return (200, Data("""
              {"data":[{"id":"deepseek-flash","input_modalities":["text"],"output_modalities":["text"]},
                       {"id":"deepseek-v4-pro"},{"id":"deepseek-flash"},
                       {"id":"image-only","input_modalities":["image"]}]}
              """.utf8))
        }
        let models = try await catalog.availableModels(endpoint: endpoint, apiKey: " test-key ")
        require(models == ["deepseek-flash", "deepseek-v4-pro"], "Unique text model filtering")
        for (status, expected) in [(401, "API Key 无效"), (404, "未提供模型列表"), (429, "过于频繁")] {
            ModelMockURLProtocol.handler = { _ in (status, Data("secret-server-detail".utf8)) }
            do {
                _ = try await catalog.availableModels(endpoint: endpoint, apiKey: "test-key")
                fatalError("Expected HTTP \(status) to fail")
            } catch {
                require(error.localizedDescription.contains(expected), "Incorrect HTTP error")
                require(!error.localizedDescription.contains("secret-server-detail"), "Server detail leaked")
            }
        }
        for body in ["{\"data\":[]}", "not-json"] {
            ModelMockURLProtocol.handler = { _ in (200, Data(body.utf8)) }
            do {
                _ = try await catalog.availableModels(endpoint: endpoint, apiKey: "test-key")
                fatalError("Empty or malformed model list was accepted")
            } catch { }
        }
        ModelMockURLProtocol.handler = nil
        print("Model catalog checks passed")
    }
}

private final class ModelMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
