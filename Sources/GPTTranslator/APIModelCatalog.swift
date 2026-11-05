import Foundation

/// Reads model IDs from an OpenAI-compatible models endpoint without persisting credentials.
struct APIModelCatalog: Sendable {
    enum CatalogError: LocalizedError {
        case missingAPIKey
        case invalidEndpoint
        case unsupportedEndpoint
        case unauthorized
        case forbidden
        case rateLimited
        case http(Int)
        case invalidResponse
        case emptyList

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "请先填写 API Key。"
            case .invalidEndpoint: return "请填写有效的 API 接口地址。"
            case .unsupportedEndpoint: return "该接口未提供模型列表，请手动输入模型名称。"
            case .unauthorized: return "API Key 无效或已过期，请检查后重试。"
            case .forbidden: return "当前 API Key 无权读取模型列表。"
            case .rateLimited: return "获取模型过于频繁，请稍后重试。"
            case .http(let status): return "获取模型失败（HTTP \(status)）。"
            case .invalidResponse: return "模型列表响应格式无法识别，请手动输入模型名称。"
            case .emptyList: return "服务没有返回可用模型，请手动输入模型名称。"
            }
        }
    }

    private struct Response: Decodable {
        struct Model: Decodable {
            let id: String?
            let input_modalities: [String]?
            let output_modalities: [String]?
        }
        let data: [Model]
    }

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func modelsURL(for endpoint: String) throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw CatalogError.invalidEndpoint
        }
        let path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let suffix = "/chat/completions"
        guard path.hasSuffix(suffix) else { throw CatalogError.unsupportedEndpoint }
        components.path = String(path.dropLast(suffix.count)) + "/models"
        components.fragment = nil
        guard let url = components.url else { throw CatalogError.invalidEndpoint }
        return url
    }

    func availableModels(endpoint: String, apiKey: String) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CatalogError.missingAPIKey }
        var request = URLRequest(url: try Self.modelsURL(for: endpoint))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        // A configured gateway must not forward its API key to another origin.
        let (data, response) = try await session.data(for: request, delegate: SameOriginRedirectDelegate())
        guard let http = response as? HTTPURLResponse else { throw CatalogError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 401: throw CatalogError.unauthorized
        case 403: throw CatalogError.forbidden
        case 404, 405, 501: throw CatalogError.unsupportedEndpoint
        case 429: throw CatalogError.rateLimited
        default: throw CatalogError.http(http.statusCode)
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CatalogError.invalidResponse
        }
        var seen = Set<String>()
        let models = response.data.compactMap { model -> String? in
            if let input = model.input_modalities, !input.contains("text") { return nil }
            if let output = model.output_modalities, !output.contains("text") { return nil }
            guard let id = model.id?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
        guard !models.isEmpty else { throw CatalogError.emptyList }
        return models
    }
}

private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url, let redirected = request.url,
              original.scheme?.lowercased() == redirected.scheme?.lowercased(),
              original.host?.lowercased() == redirected.host?.lowercased(),
              Self.effectivePort(original) == Self.effectivePort(redirected) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}
