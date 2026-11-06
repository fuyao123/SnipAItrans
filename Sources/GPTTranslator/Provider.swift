import Foundation

enum ModelProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case openAIChatGPT
    case antigravityOAuth
    case appleTranslation
    case googleWeb
    case ollama
    case deepSeek
    case zhipu
    case customAPI

    // Selected from the models currently exposed by the local agy account.
    // Flash + low reasoning is the latency-first configuration for translation.
    static let antigravityFastModel = "gemini-3.8-flash-low"
    static let openAIDefaultModel = "gpt-6-luna"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAIChatGPT: return "OpenAI / ChatGPT OAuth"
        case .antigravityOAuth: return "Gemini / Google OAuth（Antigravity）"
        case .appleTranslation: return "Apple 离线翻译"
        case .googleWeb: return "Google 网页翻译（非官方）"
        case .ollama: return "Ollama 本地大模型"
        case .deepSeek: return "DeepSeek"
        case .zhipu: return "智谱 GLM"
        case .customAPI: return "自定义兼容 API"
        }
    }

    var shortName: String {
        switch self {
        case .openAIChatGPT: return "OpenAI"
        case .antigravityOAuth: return "Gemini OAuth"
        case .appleTranslation: return "Apple 离线"
        case .googleWeb: return "Google 网页"
        case .ollama: return "Ollama 本地"
        case .deepSeek: return "DeepSeek"
        case .zhipu: return "智谱"
        case .customAPI: return "自定义 API"
        }
    }

    var endpoint: URL? {
        switch self {
        case .openAIChatGPT, .antigravityOAuth, .appleTranslation, .googleWeb, .ollama, .customAPI: return nil
        case .deepSeek: return URL(string: "https://api.deepseek.com/chat/completions")
        case .zhipu: return URL(string: "https://open.bigmodel.cn/api/paas/v4/chat/completions")
        }
    }

    var needsAPIKey: Bool {
        switch self {
        case .openAIChatGPT, .antigravityOAuth, .appleTranslation, .googleWeb, .ollama: return false
        default: return true
        }
    }

    var isMachineTranslation: Bool {
        switch self {
        case .appleTranslation, .googleWeb: return true
        default: return false
        }
    }

    var supportsModelSelection: Bool { !isMachineTranslation }

    var modelOptions: [String] {
        switch self {
        case .openAIChatGPT:
            return ["gpt-6-luna", "gpt-6-sol", "gpt-6-astra", "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.5"]
        case .antigravityOAuth:
            return [Self.antigravityFastModel]
        case .appleTranslation:
            return []
        case .googleWeb:
            return []
        case .ollama:
            return ["qwen2.5:7b", "qwen2.5:3b", "qwen2.5:1.5b"]
        case .deepSeek:
            return ["deepseek-flash", "deepseek-v4-pro"]
        case .zhipu:
            return ["glm-5.3-flash", "glm-5-turbo", "glm-5.3", "glm-5.2", "glm-5.1", "glm-5", "glm-4.7", "glm-4.6", "glm-4.5-air", "glm-4.5"]
        case .customAPI:
            return []
        }
    }

    var defaultModel: String {
        switch self {
        case .openAIChatGPT: return Self.openAIDefaultModel
        case .antigravityOAuth: return Self.antigravityFastModel
        case .appleTranslation: return ""
        case .googleWeb: return ""
        case .ollama: return "qwen2.5:7b"
        case .deepSeek: return "deepseek-flash"
        case .zhipu: return "glm-5.3-flash"
        case .customAPI: return ""
        }
    }
}

enum ReasoningEffort: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "关闭"
        case .minimal: return "最低"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .xhigh: return "极高"
        case .max: return "最大"
        case .ultra: return "超高"
        }
    }

    var apiValue: String? { self == .none ? nil : rawValue }
}
