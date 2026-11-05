import Foundation

struct AppRelease: Equatable, Sendable {
    let version: String
    let pageURL: URL
}

enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(AppRelease)
    case failed(String)
}

struct AppUpdateService: Sendable {
    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
    }

    private enum UpdateError: LocalizedError {
        case httpStatus(Int)
        case invalidRelease
        case bothRequestsFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .httpStatus(403), .httpStatus(429):
                return "GitHub 请求受限，请稍后重试。"
            case .httpStatus(let status):
                return "GitHub 更新接口返回 HTTP \(status)。"
            case .invalidRelease:
                return "GitHub 未返回有效的正式版本信息。"
            case .bothRequestsFailed(let api, let webpage):
                return "无法获取 GitHub 更新信息。API：\(api)；网页：\(webpage)"
            }
        }
    }

    private let latestReleaseAPIURL = URL(
        string: "https://api.github.com/repos/fuyao123/SnipAItrans/releases/latest"
    )!
    private let latestReleaseURL = URL(
        string: "https://github.com/fuyao123/SnipAItrans/releases/latest"
    )!

    func latestRelease() async throws -> AppRelease {
        do {
            return try await releaseFromAPI()
        } catch {
            let apiError = error.localizedDescription
            try Task.checkCancellation()
            do {
                return try await releaseFromWebpage()
            } catch {
                try Task.checkCancellation()
                throw UpdateError.bothRequestsFailed(apiError, error.localizedDescription)
            }
        }
    }

    private func releaseFromAPI() async throws -> AppRelease {
        var request = updateRequest(url: latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else { throw UpdateError.invalidRelease }
        return try validatedRelease(tag: release.tag_name, pageURL: release.html_url)
    }

    private func releaseFromWebpage() async throws -> AppRelease {
        let (_, response) = try await URLSession.shared.data(for: updateRequest(url: latestReleaseURL))
        try validateResponse(response)
        guard let finalURL = response.url,
              finalURL.path.contains("/releases/tag/") else {
            throw UpdateError.invalidRelease
        }
        return try validatedRelease(tag: finalURL.lastPathComponent, pageURL: finalURL)
    }

    private func updateRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 15
        request.setValue(AppIdentity.name, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw UpdateError.invalidRelease }
        guard (200..<300).contains(response.statusCode) else {
            throw UpdateError.httpStatus(response.statusCode)
        }
    }

    private func validatedRelease(tag: String, pageURL: URL) throws -> AppRelease {
        let version = Self.normalizedVersion(tag)
        guard version.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil,
              pageURL.scheme == "https",
              pageURL.host == "github.com",
              ["/fuyao123/SnipAItrans/releases/tag/", "/fuyao123/GPT-Translator/releases/tag/"]
                .contains(where: { pageURL.path.hasPrefix($0) }) else {
            throw UpdateError.invalidRelease
        }
        return AppRelease(version: version, pageURL: pageURL)
    }

    func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = Self.versionParts(candidate)
        let currentParts = Self.versionParts(current)
        let count = max(candidateParts.count, currentParts.count)

        for index in 0..<count {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }

    private static func normalizedVersion(_ version: String) -> String {
        var result = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.lowercased().hasPrefix("v") {
            result.removeFirst()
        }
        return result
    }

    private static func versionParts(_ version: String) -> [Int] {
        let baseVersion = normalizedVersion(version).split(separator: "-", maxSplits: 1).first ?? ""
        return baseVersion.split(separator: ".").map { Int($0) ?? 0 }
    }
}
