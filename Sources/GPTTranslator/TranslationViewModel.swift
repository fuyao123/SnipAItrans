import AppKit
import Combine
import Foundation
import NaturalLanguage
import SwiftUI

enum LanguageOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case chineseSimplified
    case english
    case japanese
    case korean
    case spanish
    case french
    case german

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自动识别"
        case .chineseSimplified: return "中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        }
    }

    var promptName: String {
        switch self {
        case .auto: return "the detected source language"
        case .chineseSimplified: return "Simplified Chinese"
        case .english: return "English"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        }
    }

    var googleCode: String {
        switch self {
        case .auto: return "auto"
        case .chineseSimplified: return "zh-CN"
        case .english: return "en"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .spanish: return "es"
        case .french: return "fr"
        case .german: return "de"
        }
    }

    var localeLanguage: Locale.Language? {
        guard self != .auto else { return nil }
        return Locale.Language(identifier: googleCode)
    }
}

struct CustomAPISource: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var endpoint: String
    var model: String

    init(id: UUID = UUID(), displayName: String = "自定义 API", endpoint: String = "", model: String = "") {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.model = model
    }

    var keychainAccount: String { "customAPI.\(id.uuidString)" }
}

struct TranslationSource: Identifiable, Hashable, Sendable {
    let id: String
    let provider: ModelProvider
    let customAPIID: UUID?
    let displayName: String
    var modelOverride: String? = nil
    var apiModelID: UUID? = nil

    var shortName: String { displayName }
}

struct APIModelSource: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let provider: ModelProvider
    let customAPIID: UUID?
    let model: String

    init(id: UUID = UUID(), provider: ModelProvider, customAPIID: UUID?, model: String) {
        self.id = id
        self.provider = provider
        self.customAPIID = customAPIID
        self.model = model
    }

    var sourceID: String { "api-model.\(id.uuidString)" }
    var baseSourceID: String {
        customAPIID.map { "custom.\($0.uuidString)" } ?? provider.rawValue
    }
}

struct ComparisonTranslationResult: Identifiable, Sendable {
    let source: TranslationSource
    var translatedText: String?
    var errorMessage: String?
    var isLoading: Bool

    var id: String { source.id }
}

struct DefaultFallbackTranslationResult {
    let text: String
    let sourceName: String
}

enum ProviderConnectionState: Equatable, Sendable {
    case checking
    case connected
    case disconnected(String)
}

@MainActor
final class TranslationViewModel: ObservableObject {
    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var sourceLanguage: LanguageOption = .auto
    @Published var targetLanguage: LanguageOption = .english
    @Published var isTranslating = false
    @Published var errorMessage: String?
    @Published var isLoggedIn = false
    @Published var isLoggingIn = false
    @Published var provider: ModelProvider
    @Published var modelName: String
    @Published var reasoningEffort: ReasoningEffort
    @Published var apiKey: String
    @Published var customAPIEndpoint: String
    @Published var customAPIDisplayName: String
    @Published private(set) var customAPISources: [CustomAPISource]
    @Published var selectedCustomAPIID: UUID?
    @Published private(set) var apiModelSources: [APIModelSource]
    @Published private(set) var selectedAPIModelSourceID: UUID?
    @Published var translateChineseContent: Bool
    @Published var translateEnglishSelectionToChinese: Bool
    @Published var resultFontSize: CGFloat
    @Published var floatingSourceIDs: Set<String>
    @Published private(set) var floatingSourceOrder: [String]
    @Published private(set) var floatingSourceText = ""
    @Published private(set) var floatingErrorMessage: String?
    @Published private(set) var comparisonResults: [ComparisonTranslationResult] = []
    @Published private(set) var providerConnectionStates: [String: ProviderConnectionState] = [:]
    @Published private(set) var isTestingConnections = false
    @Published private(set) var updateState: AppUpdateState = .idle
    @Published private(set) var antigravityModels: [String] = []
    @Published private(set) var isLoadingAntigravityModels = false
    @Published private(set) var antigravityModelListError: String?
    @Published private(set) var openAIModels: [String] = []
    @Published private(set) var openAIModelDetails: [CodexModelOption] = []
    @Published private(set) var isLoadingOpenAIModels = false
    @Published private(set) var openAIModelListError: String?
    @Published private(set) var apiModelsBySource: [String: [String]] = [:]
    @Published private(set) var apiModelErrorsBySource: [String: String] = [:]
    @Published private(set) var loadingAPIModelSources: Set<String> = []

    private let codexService: CodexCLIService
    private let antigravityService: AntigravityCLIService
    private let directService: DirectProviderService
    private let apiModelCatalog: APIModelCatalog
    let appleService: AppleTranslationService
    let ollamaService: OllamaService
    private var ollamaObservation: AnyCancellable?
    private let keychain: KeychainStore
    private var automaticTranslationTask: Task<Void, Never>?
    private var pendingAutomaticTranslation = false
    private var lastSubmittedText = ""
    private var translationCache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private var comparisonTasks: [Task<Void, Never>] = []
    private var connectionMonitorTask: Task<Void, Never>?
    private var hasStartedAntigravityWarmUp = false
    private var hasStartedCodexWarmUp = false
    private var hasRequestedOpenAIModels = false
    private struct APIModelRequest: Equatable {
        let sourceID: String
        let endpoint: String
        let apiKey: String
    }
    private var apiModelRequests: [String: APIModelRequest] = [:]
    private var apiModelTasks: [String: Task<Void, Never>] = [:]
    private var apiModelDebounceTask: Task<Void, Never>?
    private var apiKeyWasEdited = false
    private let updateService = AppUpdateService()
    private var hasCheckedForUpdates = false

    init(
        codexService: CodexCLIService = CodexCLIService(),
        antigravityService: AntigravityCLIService = AntigravityCLIService(),
        directService: DirectProviderService = DirectProviderService(),
        apiModelCatalog: APIModelCatalog = APIModelCatalog(),
        appleService: AppleTranslationService = AppleTranslationService(),
        ollamaService: OllamaService = OllamaService(),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.codexService = codexService
        self.antigravityService = antigravityService
        self.directService = directService
        self.apiModelCatalog = apiModelCatalog
        self.appleService = appleService
        self.ollamaService = ollamaService
        self.keychain = keychain

        let storedProvider = UserDefaults.standard.string(forKey: "provider")
            .flatMap(ModelProvider.init(rawValue:)) ?? .openAIChatGPT
        self.provider = storedProvider
        let decodedCustomSources = UserDefaults.standard.data(forKey: "customAPISources")
            .flatMap { try? JSONDecoder().decode([CustomAPISource].self, from: $0) } ?? []
        let legacyEndpoint = UserDefaults.standard.string(forKey: "customAPIEndpoint") ?? ""
        let legacyModel = UserDefaults.standard.string(forKey: Self.modelKey(for: .customAPI)) ?? ""
        let initialCustomSources = decodedCustomSources.isEmpty
            ? [CustomAPISource(displayName: "Gemini", endpoint: legacyEndpoint, model: legacyModel)]
            : decodedCustomSources
        self.customAPISources = initialCustomSources
        let savedCustomID = UserDefaults.standard.string(forKey: "selectedCustomAPIID").flatMap(UUID.init(uuidString:))
        let initialCustom = initialCustomSources.first(where: { $0.id == savedCustomID }) ?? initialCustomSources[0]
        self.selectedCustomAPIID = initialCustom.id
        self.customAPIDisplayName = initialCustom.displayName
        self.customAPIEndpoint = initialCustom.endpoint
        let savedAPIModels = UserDefaults.standard.data(forKey: "apiModelSources")
            .flatMap { try? JSONDecoder().decode([APIModelSource].self, from: $0) } ?? []
        let initialAPIModels = savedAPIModels.filter { source in
            source.provider.needsAPIKey && !source.model.isEmpty &&
                (source.provider != .customAPI || initialCustomSources.contains { $0.id == source.customAPIID })
        }
        self.apiModelSources = initialAPIModels
        let savedAPIModelID = UserDefaults.standard.string(forKey: "selectedAPIModelSourceID").flatMap(UUID.init(uuidString:))
        let initialAPIModel = initialAPIModels.first {
            $0.id == savedAPIModelID && $0.provider == storedProvider &&
                ($0.provider != .customAPI || $0.customAPIID == initialCustom.id)
        }
        self.selectedAPIModelSourceID = initialAPIModel?.id
        let storedModel = Self.savedModel(for: storedProvider)
        let obsoleteModels = ["gpt-4.1-mini", "deepseek-chat", "deepseek-reasoner"]
        self.modelName = initialAPIModel?.model ?? (storedProvider == .customAPI
            ? initialCustom.model
            : (obsoleteModels.contains(storedModel) ? storedProvider.defaultModel : storedModel))
        self.reasoningEffort = UserDefaults.standard.string(forKey: "reasoningEffort")
            .flatMap(ReasoningEffort.init(rawValue:)) ?? .medium
        if storedProvider == .customAPI {
            self.apiKey = keychain.readAPIKey(account: initialCustom.keychainAccount)
                ?? keychain.readAPIKey(for: .customAPI)
                ?? ""
        } else {
            self.apiKey = storedProvider.needsAPIKey ? (keychain.readAPIKey(for: storedProvider) ?? "") : ""
        }
        self.translateChineseContent = UserDefaults.standard.object(forKey: "translateChineseContent") as? Bool ?? true
        self.translateEnglishSelectionToChinese = UserDefaults.standard.object(forKey: "translateEnglishSelectionToChinese") as? Bool ?? true
        self.resultFontSize = CGFloat(UserDefaults.standard.object(forKey: "resultFontSize") as? Double ?? 14)
        let customID = Self.customSourceID(initialCustom.id)
        let savedIDs = UserDefaults.standard.stringArray(forKey: "floatingSourceIDs")
            ?? (UserDefaults.standard.stringArray(forKey: "floatingProviders") ?? []).map { $0 == ModelProvider.customAPI.rawValue ? customID : $0 }
        self.floatingSourceIDs = savedIDs.isEmpty ? [ModelProvider.openAIChatGPT.rawValue, customID] : Set(savedIDs)
        let savedOrder = UserDefaults.standard.stringArray(forKey: "floatingSourceOrder")
            ?? (UserDefaults.standard.stringArray(forKey: "floatingProviderOrder") ?? []).map { $0 == ModelProvider.customAPI.rawValue ? customID : $0 }
        let allIDs = ModelProvider.allCases.filter { $0 != .customAPI }.map(\.rawValue)
            + initialCustomSources.map { Self.customSourceID($0.id) }
            + initialAPIModels.map(\.sourceID)
        self.floatingSourceOrder = Self.normalizedSourceOrder(savedOrder, allIDs: allIDs)
        // Migrate the OpenAI model even when another provider is currently selected,
        // so switching to OpenAI later uses the new default immediately.
        _ = Self.savedModel(for: .openAIChatGPT)
        if decodedCustomSources.isEmpty, let legacyKey = keychain.readAPIKey(for: .customAPI), !legacyKey.isEmpty {
            _ = keychain.saveAPIKey(legacyKey, account: initialCustom.keychainAccount)
        }
        ollamaObservation = ollamaService.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
        refreshLoginStatus()
    }

    var canTranslate: Bool {
        !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isTranslating
    }

    var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4.0"
    }

    func checkForUpdates(force: Bool = false) async {
        if case .checking = updateState { return }
        guard force || !hasCheckedForUpdates else { return }

        hasCheckedForUpdates = true
        updateState = .checking
        do {
            let release = try await updateService.latestRelease()
            updateState = updateService.isNewer(release.version, than: currentAppVersion)
                ? .available(release)
                : .upToDate
        } catch {
            hasCheckedForUpdates = false
            updateState = .failed(error.localizedDescription)
        }
    }

    var modelLabel: String {
        modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "默认模型" : modelName
    }

    var availableModelOptions: [String] {
        switch provider {
        case .openAIChatGPT where !openAIModels.isEmpty: return openAIModels
        case .antigravityOAuth where !antigravityModels.isEmpty: return antigravityModels
        case .ollama: return ollamaService.modelChoices
        case _ where provider.needsAPIKey:
            return apiModelSources.filter { $0.baseSourceID == activeBaseSourceID }.map(\.model)
        default: return provider.modelOptions
        }
    }

    var availableReasoningEfforts: [ReasoningEffort] {
        if provider == .ollama { return [] }
        if provider == .openAIChatGPT {
            if let model = openAIModelDetails.first(where: { $0.name == modelName }), !model.supportedEfforts.isEmpty {
                return model.supportedEfforts
            }
            return [.none, .low, .medium, .high, .xhigh]
        }
        if provider == .antigravityOAuth {
            let suffixes: [(String, ReasoningEffort)] = [("low", .low), ("medium", .medium), ("high", .high)]
            guard let suffix = suffixes.first(where: { modelName.hasSuffix("-" + $0.0) })?.0 else { return [] }
            let base = String(modelName.dropLast(suffix.count + 1))
            return suffixes.compactMap { availableModelOptions.contains(base + "-" + $0.0) ? $0.1 : nil }
        }
        if provider.isMachineTranslation { return [] }
        return [.none, .low, .medium, .high, .xhigh]
    }

    var displayedReasoningEffort: ReasoningEffort {
        if provider == .antigravityOAuth {
            return [.low, .medium, .high].first(where: { modelName.hasSuffix("-" + $0.rawValue) }) ?? .none
        }
        return reasoningEffort
    }

    func selectReasoningEffort(_ effort: ReasoningEffort, retranslate: Bool = true) {
        guard availableReasoningEfforts.contains(effort) else { return }
        if provider == .antigravityOAuth {
            guard let lastDash = modelName.lastIndex(of: "-") else { return }
            selectModel(String(modelName[..<lastDash]) + "-" + effort.rawValue)
            return
        }
        guard reasoningEffort != effort else { return }
        reasoningEffort = effort
        UserDefaults.standard.set(effort.rawValue, forKey: "reasoningEffort")
        if retranslate { refreshAfterReasoningChange() }
    }

    func refreshAfterReasoningChange() {
        lastSubmittedText = ""
        translatedText = ""
        errorMessage = nil
        scheduleAutomaticTranslation(delayNanoseconds: 100_000_000)
    }

    private func reconcileOpenAIReasoning() {
        guard provider == .openAIChatGPT,
              let model = openAIModelDetails.first(where: { $0.name == modelName }),
              !model.supportedEfforts.isEmpty, !model.supportedEfforts.contains(reasoningEffort) else { return }
        reasoningEffort = model.defaultEffort.flatMap { model.supportedEfforts.contains($0) ? $0 : nil } ?? model.supportedEfforts[0]
        UserDefaults.standard.set(reasoningEffort.rawValue, forKey: "reasoningEffort")
    }

    var modelListError: String? {
        switch provider {
        case .openAIChatGPT: return openAIModelListError
        case .antigravityOAuth: return antigravityModelListError
        case .ollama: return ollamaService.errorMessage
        default: return apiModelErrorsBySource[activeBaseSourceID]
        }
    }

    var isLoadingModelList: Bool {
        switch provider {
        case .openAIChatGPT: return isLoadingOpenAIModels
        case .antigravityOAuth: return isLoadingAntigravityModels
        case .ollama: return ollamaService.isBusy
        default: return loadingAPIModelSources.contains(activeBaseSourceID)
        }
    }

    func refreshCurrentModelList() {
        switch provider {
        case .openAIChatGPT: refreshOpenAIModels()
        case .antigravityOAuth: refreshAntigravityModels()
        case .ollama: ollamaService.refresh()
        case _ where provider.needsAPIKey: refreshCurrentAPIModels(force: true)
        default: break
        }
    }

    /// Debounce pasted or edited credentials and discard any response for older credentials.
    func scheduleAPIModelRefresh() {
        apiModelDebounceTask?.cancel()
        guard provider.needsAPIKey else { return }
        let request = currentAPIModelRequest()
        invalidateAPIModelListIfChanged(request)
        guard !request.apiKey.isEmpty, !request.endpoint.isEmpty else { return }
        apiModelDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, let self, self.currentAPIModelRequest() == request else { return }
            self.refreshCurrentAPIModels(force: false)
        }
    }

    func setAPIKeyFromUser(_ value: String) {
        apiKeyWasEdited = true
        apiKey = value
    }

    private func currentAPIModelRequest() -> APIModelRequest {
        let endpoint = provider == .customAPI ? customAPIEndpoint : (provider.endpoint?.absoluteString ?? "")
        return APIModelRequest(
            sourceID: activeBaseSourceID,
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func invalidateAPIModelListIfChanged(_ request: APIModelRequest) {
        guard apiModelRequests[request.sourceID] != request else { return }
        apiModelTasks[request.sourceID]?.cancel()
        apiModelTasks[request.sourceID] = nil
        apiModelsBySource[request.sourceID] = nil
        apiModelErrorsBySource[request.sourceID] = nil
        loadingAPIModelSources.remove(request.sourceID)
        apiModelRequests[request.sourceID] = request
    }

    private func refreshCurrentAPIModels(force: Bool) {
        guard provider.needsAPIKey else { return }
        let request = currentAPIModelRequest()
        invalidateAPIModelListIfChanged(request)
        if !force, loadingAPIModelSources.contains(request.sourceID) || apiModelsBySource[request.sourceID] != nil {
            return
        }
        apiModelTasks[request.sourceID]?.cancel()
        apiModelErrorsBySource[request.sourceID] = nil
        loadingAPIModelSources.insert(request.sourceID)
        apiModelTasks[request.sourceID] = Task { [weak self, apiModelCatalog] in
            do {
                let models = try await apiModelCatalog.availableModels(endpoint: request.endpoint, apiKey: request.apiKey)
                guard !Task.isCancelled, let self, self.apiModelRequests[request.sourceID] == request else { return }
                self.apiModelsBySource[request.sourceID] = models
                self.apiModelErrorsBySource[request.sourceID] = nil
                self.loadingAPIModelSources.remove(request.sourceID)
                self.apiModelTasks[request.sourceID] = nil
            } catch {
                guard !Task.isCancelled, let self, self.apiModelRequests[request.sourceID] == request else { return }
                self.apiModelErrorsBySource[request.sourceID] = error.localizedDescription
                self.loadingAPIModelSources.remove(request.sourceID)
                self.apiModelTasks[request.sourceID] = nil
            }
        }
    }

    func refreshOpenAIModels() {
        guard !isLoadingOpenAIModels else { return }
        hasRequestedOpenAIModels = true
        isLoadingOpenAIModels = true
        openAIModelListError = nil
        Task {
            do {
                let models = try await codexService.availableModels()
                openAIModelDetails = models
                openAIModels = models.map(\.name)
                reconcileOpenAIReasoning()
            } catch {
                openAIModelListError = error.localizedDescription
            }
            isLoadingOpenAIModels = false
        }
    }

    func selectModel(_ model: String) {
        let selected = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return }
        if provider.needsAPIKey,
           let matching = apiModelSources.first(where: { $0.baseSourceID == activeBaseSourceID && $0.model == selected }),
           matching.id != selectedAPIModelSourceID,
           let source = allTranslationSources.first(where: { $0.apiModelID == matching.id }) {
            selectTranslationSource(source)
            persistSettings()
            return
        }
        if provider.needsAPIKey, selectedAPIModelSourceID != nil,
           !apiModelSources.contains(where: { $0.id == selectedAPIModelSourceID && $0.model == selected }) {
            selectedAPIModelSourceID = nil
        }
        guard selected != modelName else { return }
        modelName = selected
        reconcileOpenAIReasoning()
        persistSettings()
        translatedText = ""
        errorMessage = nil
        lastSubmittedText = ""
        scheduleAutomaticTranslation(delayNanoseconds: 100_000_000)
    }

    func refreshAntigravityModels() {
        guard !isLoadingAntigravityModels else { return }
        isLoadingAntigravityModels = true
        antigravityModelListError = nil
        Task {
            do {
                antigravityModels = try await antigravityService.availableModels()
            } catch {
                antigravityModelListError = error.localizedDescription
            }
            isLoadingAntigravityModels = false
        }
    }

    var providerReady: Bool {
        isProviderReady(provider)
    }

    var selectedCustomAPI: CustomAPISource? {
        customAPISources.first { $0.id == selectedCustomAPIID }
    }

    var activeProviderDisplayName: String {
        if let id = selectedAPIModelSourceID,
           let source = allTranslationSources.first(where: { $0.apiModelID == id }) {
            return source.displayName
        }
        return provider == .customAPI ? (selectedCustomAPI?.displayName ?? "自定义 API") : provider.shortName
    }

    var activeBaseSourceID: String {
        provider == .customAPI ? selectedCustomAPIID.map(Self.customSourceID) ?? provider.rawValue : provider.rawValue
    }

    var activeSourceID: String {
        selectedAPIModelSourceID.map { "api-model.\($0.uuidString)" } ?? activeBaseSourceID
    }

    var allTranslationSources: [TranslationSource] {
        let builtIns = ModelProvider.allCases.filter { $0 != .customAPI }.map {
            TranslationSource(id: $0.rawValue, provider: $0, customAPIID: nil, displayName: $0.shortName)
        }
        let custom = customAPISources.map {
            TranslationSource(id: Self.customSourceID($0.id), provider: .customAPI, customAPIID: $0.id, displayName: $0.displayName)
        }
        let baseSources = builtIns + custom
        let models = apiModelSources.compactMap { model -> TranslationSource? in
            guard let base = baseSources.first(where: { $0.id == model.baseSourceID }) else { return nil }
            return TranslationSource(
                id: model.sourceID, provider: model.provider, customAPIID: model.customAPIID,
                displayName: "\(base.displayName) · \(model.model)", modelOverride: model.model, apiModelID: model.id
            )
        }
        return baseSources + models
    }

    var apiModelChoices: [String] {
        let fetched = apiModelsBySource[activeBaseSourceID] ?? []
        let saved = apiModelSources.filter { $0.baseSourceID == activeBaseSourceID }.map(\.model)
        var seen = Set<String>()
        return (fetched + saved).filter { seen.insert($0).inserted }
    }

    func isAPIModelAdded(_ model: String) -> Bool {
        apiModelSources.contains { $0.baseSourceID == activeBaseSourceID && $0.model == model }
    }

    func setAPIModelAdded(_ rawModel: String, enabled: Bool) {
        guard provider.needsAPIKey else { return }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        let baseID = activeBaseSourceID
        let existing = apiModelSources.first { $0.baseSourceID == baseID && $0.model == model }
        if enabled, existing == nil {
            let added = APIModelSource(provider: provider, customAPIID: provider == .customAPI ? selectedCustomAPIID : nil, model: model)
            apiModelSources.append(added)
            floatingSourceOrder.append(added.sourceID)
        } else if !enabled, let existing {
            if selectedAPIModelSourceID == existing.id,
               let base = allTranslationSources.first(where: { $0.id == baseID }) {
                selectTranslationSource(base)
                guard selectedAPIModelSourceID != existing.id else { return }
            }
            apiModelSources.removeAll { $0.id == existing.id }
            floatingSourceIDs.remove(existing.sourceID)
            floatingSourceOrder.removeAll { $0 == existing.sourceID }
            if floatingSourceIDs.isEmpty { floatingSourceIDs.insert(baseID) }
        }
        persistAPIModelSources()
    }

    var enabledFloatingSources: [TranslationSource] {
        let byID = Dictionary(uniqueKeysWithValues: allTranslationSources.map { ($0.id, $0) })
        return floatingSourceOrder.compactMap { floatingSourceIDs.contains($0) ? byID[$0] : nil }
    }

    func isProviderReady(_ provider: ModelProvider) -> Bool {
        switch provider {
        case .openAIChatGPT:
            return isLoggedIn
        case .antigravityOAuth:
            return antigravityService.isInstalled()
        case .appleTranslation:
            if #available(macOS 15.0, *) { return true }
            return false
        case .googleWeb:
            return true
        case .ollama:
            return ollamaService.models.contains(modelName)
        case .customAPI:
            guard let config = selectedCustomAPI else { return false }
            return !(keychain.readAPIKey(account: config.keychainAccount) ?? apiKey)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            if provider == self.provider {
                return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return !(keychain.readAPIKey(for: provider) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func connectionState(for source: TranslationSource) -> ProviderConnectionState {
        providerConnectionStates[source.id] ?? .checking
    }

    func startConnectionMonitoring() {
        guard connectionMonitorTask == nil else { return }
        connectionMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.testEnabledProviderConnections()
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        }
    }

    func testEnabledProviderConnections() async {
        guard !isTestingConnections else { return }
        isTestingConnections = true
        defer { isTestingConnections = false }
        let sources = enabledFloatingSources
        for source in sources {
            providerConnectionStates[source.id] = .checking
        }

        await withTaskGroup(of: (String, ProviderConnectionState).self) { group in
            for source in sources {
                group.addTask { [weak self] in
                    guard let self else { return (source.id, .disconnected("应用已停止")) }
                    do {
                        try await self.performConnectionTest(for: source)
                        return (source.id, .connected)
                    } catch {
                        return (source.id, .disconnected(error.localizedDescription))
                    }
                }
            }
            for await (sourceID, state) in group {
                providerConnectionStates[sourceID] = state
            }
        }
    }

    func selectProvider(_ newProvider: ModelProvider) {
        guard newProvider != provider else { return }
        guard persistCurrentProviderSettings() else { return }
        selectedAPIModelSourceID = nil
        provider = newProvider
        if newProvider == .customAPI, let config = selectedCustomAPI {
            customAPIDisplayName = config.displayName
            customAPIEndpoint = config.endpoint
            modelName = config.model
            apiKey = keychain.readAPIKey(account: config.keychainAccount) ?? ""
        } else {
            modelName = Self.savedModel(for: newProvider)
            apiKey = newProvider.needsAPIKey
                ? (keychain.readAPIKey(for: newProvider) ?? "")
                : ""
        }
        reconcileOpenAIReasoning()
        errorMessage = nil
        refreshLoginStatus()
        translatedText = ""
        lastSubmittedText = ""
        if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleAutomaticTranslation(delayNanoseconds: 100_000_000)
        }
    }

    func selectTranslationSource(_ source: TranslationSource) {
        guard source.id != activeSourceID else { return }
        let previousBaseID = activeBaseSourceID
        let previousAPIKey = apiKey
        guard persistCurrentProviderSettings() else { return }

        if source.provider == .customAPI,
           let id = source.customAPIID,
           let config = customAPISources.first(where: { $0.id == id }) {
            provider = .customAPI
            selectedCustomAPIID = id
            customAPIDisplayName = config.displayName
            customAPIEndpoint = config.endpoint
            modelName = source.modelOverride ?? config.model
            apiKey = previousBaseID == Self.customSourceID(id)
                ? previousAPIKey : (keychain.readAPIKey(account: config.keychainAccount) ?? "")
            UserDefaults.standard.set(id.uuidString, forKey: "selectedCustomAPIID")
        } else {
            provider = source.provider
            modelName = source.modelOverride ?? Self.savedModel(for: source.provider)
            apiKey = source.provider.needsAPIKey
                ? (previousBaseID == source.provider.rawValue ? previousAPIKey : (keychain.readAPIKey(for: source.provider) ?? ""))
                : ""
        }
        selectedAPIModelSourceID = source.apiModelID
        UserDefaults.standard.set(source.apiModelID?.uuidString, forKey: "selectedAPIModelSourceID")

        reconcileOpenAIReasoning()
        errorMessage = nil
        translatedText = ""
        lastSubmittedText = ""
        refreshLoginStatus()
        if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleAutomaticTranslation(delayNanoseconds: 100_000_000)
        }
    }

    func selectCustomAPI(_ id: UUID) {
        guard persistCurrentProviderSettings() else { return }
        guard let config = customAPISources.first(where: { $0.id == id }) else { return }
        selectedAPIModelSourceID = nil
        selectedCustomAPIID = id
        customAPIDisplayName = config.displayName
        customAPIEndpoint = config.endpoint
        modelName = config.model
        apiKey = keychain.readAPIKey(account: config.keychainAccount) ?? ""
        UserDefaults.standard.set(id.uuidString, forKey: "selectedCustomAPIID")
        scheduleAPIModelRefresh()
    }

    func authorizeSelectedAPIKeyFromKeychain() {
        if provider == .customAPI, let config = selectedCustomAPI {
            apiKey = keychain.readAPIKey(account: config.keychainAccount, allowInteraction: true) ?? ""
        } else if provider.needsAPIKey {
            apiKey = keychain.readAPIKey(for: provider, allowInteraction: true) ?? ""
        }
    }

    func addCustomAPI() {
        guard persistCurrentProviderSettings() else { return }
        selectedAPIModelSourceID = nil
        let config = CustomAPISource(displayName: "新自定义 API")
        customAPISources.append(config)
        floatingSourceOrder.append(Self.customSourceID(config.id))
        selectedCustomAPIID = config.id
        customAPIDisplayName = config.displayName
        customAPIEndpoint = ""
        modelName = ""
        apiKey = ""
        persistCustomSources()
    }

    func deleteSelectedCustomAPI() {
        guard customAPISources.count > 1, let id = selectedCustomAPIID else { return }
        let sourceID = Self.customSourceID(id)
        let removedModelSourceIDs = apiModelSources.filter { $0.customAPIID == id }.map(\.sourceID)
        if apiModelSources.contains(where: { $0.id == selectedAPIModelSourceID && $0.customAPIID == id }) {
            selectedAPIModelSourceID = nil
        }
        apiModelSources.removeAll { $0.customAPIID == id }
        for modelID in removedModelSourceIDs {
            floatingSourceIDs.remove(modelID)
            floatingSourceOrder.removeAll { $0 == modelID }
        }
        apiModelTasks[sourceID]?.cancel()
        apiModelTasks[sourceID] = nil
        apiModelRequests[sourceID] = nil
        apiModelsBySource[sourceID] = nil
        apiModelErrorsBySource[sourceID] = nil
        loadingAPIModelSources.remove(sourceID)
        _ = keychain.deleteAPIKey(account: "customAPI.\(id.uuidString)")
        customAPISources.removeAll { $0.id == id }
        floatingSourceIDs.remove(sourceID)
        floatingSourceOrder.removeAll { $0 == sourceID }
        if floatingSourceIDs.isEmpty { floatingSourceIDs.insert(Self.customSourceID(customAPISources[0].id)) }
        selectCustomAPI(customAPISources[0].id)
        persistCustomSources()
        persistAPIModelSources()
    }

    func refreshLoginStatus() {
        if provider.needsAPIKey { scheduleAPIModelRefresh() }
        if provider == .ollama || floatingSourceIDs.contains(ModelProvider.ollama.rawValue) { ollamaService.refresh() }
        if !hasRequestedOpenAIModels { refreshOpenAIModels() }
        let shouldWarmAntigravity = provider == .antigravityOAuth
            || floatingSourceIDs.contains(ModelProvider.antigravityOAuth.rawValue)
        let startAntigravityWarmUp = shouldWarmAntigravity && !hasStartedAntigravityWarmUp
        if startAntigravityWarmUp {
            hasStartedAntigravityWarmUp = true
        }
        if provider == .antigravityOAuth, antigravityModels.isEmpty, antigravityModelListError == nil {
            refreshAntigravityModels()
        }
        let antigravityModel = provider == .antigravityOAuth ? modelName : Self.savedModel(for: .antigravityOAuth)
        let shouldWarmCodex = provider == .openAIChatGPT || floatingSourceIDs.contains(ModelProvider.openAIChatGPT.rawValue)
        let codexModel = provider == .openAIChatGPT ? modelName : Self.savedModel(for: .openAIChatGPT)
        let codexReasoning = reasoningEffort

        Task {
            isLoggedIn = await codexService.loginStatus()
            if isLoggedIn, shouldWarmCodex, !hasStartedCodexWarmUp {
                hasStartedCodexWarmUp = true
                await codexService.warmUp(model: codexModel, reasoning: codexReasoning)
            }
            if startAntigravityWarmUp {
                await antigravityService.warmUp(model: antigravityModel)
            }
        }
    }

    func loginWithChatGPT() {
        guard provider == .openAIChatGPT, !isLoggingIn else { return }
        isLoggingIn = true
        errorMessage = nil
        Task {
            do {
                try await codexService.login()
                isLoggedIn = await codexService.loginStatus()
                if isLoggedIn { refreshOpenAIModels() }
                if !isLoggedIn { errorMessage = "登录流程未完成，请重试。" }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoggingIn = false
        }
    }

    func translate() {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请输入需要翻译的内容。"
            return
        }
        guard !isTranslating else {
            pendingAutomaticTranslation = true
            return
        }
        errorMessage = nil
        isTranslating = true
        let text = sourceText
        lastSubmittedText = text
        pendingAutomaticTranslation = false
        let source = sourceLanguage
        let target = targetLanguage
        let selectedProvider = provider
        let selectedSourceID = activeSourceID
        let model = modelName
        let reasoning = reasoningEffort
        let key = apiKey
        let cacheKey = makeCacheKey(text: text, source: source, target: target, provider: selectedProvider, model: model, reasoning: reasoning, sourceID: selectedSourceID)

        if let cached = translationCache[cacheKey] {
            translatedText = cached
            isTranslating = false
            return
        }

        Task {
            do {
                let result: String
                if selectedProvider == .openAIChatGPT {
                    result = try await codexService.translate(
                        text: text,
                        source: source,
                        target: target,
                        model: model,
                        reasoning: reasoning
                    )
                } else if selectedProvider == .antigravityOAuth {
                    result = try await antigravityService.translate(text: text, source: source, target: target, model: model)
                } else if selectedProvider == .appleTranslation {
                    result = try await appleService.translate(
                        text: text,
                        source: source,
                        target: target
                    )
                    providerConnectionStates[ModelProvider.appleTranslation.rawValue] = .connected
                } else if selectedProvider == .ollama {
                    result = try await ollamaService.translate(text: text, source: source, target: target, model: model)
                } else {
                    result = try await directService.translate(
                        text: text,
                        source: source,
                        target: target,
                        provider: selectedProvider,
                        model: model,
                        reasoning: reasoning,
                        apiKey: key,
                        customEndpoint: customAPIEndpoint
                    )
                }
                if sourceText == text, activeSourceID == selectedSourceID, modelName == model, reasoningEffort == reasoning,
                   sourceLanguage == source, targetLanguage == target {
                    translatedText = result
                    storeInCache(result, for: cacheKey)
                }
            } catch {
                if sourceText == text, activeSourceID == selectedSourceID, modelName == model, reasoningEffort == reasoning,
                   sourceLanguage == source, targetLanguage == target {
                    errorMessage = error.localizedDescription
                }
                if case CodexCLIService.ServiceError.notLoggedIn = error {
                    isLoggedIn = false
                }
            }
            isTranslating = false
            if pendingAutomaticTranslation || sourceText != text || activeSourceID != selectedSourceID || modelName != model || reasoningEffort != reasoning {
                pendingAutomaticTranslation = false
                scheduleAutomaticTranslation(delayNanoseconds: 150_000_000)
            }
        }
    }

    func scheduleAutomaticTranslation(delayNanoseconds: UInt64? = nil) {
        automaticTranslationTask?.cancel()
        let text = sourceText
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            translatedText = ""
            errorMessage = nil
            lastSubmittedText = ""
            return
        }
        guard text != lastSubmittedText else { return }

        let cacheKey = makeCacheKey(
            text: text,
            source: sourceLanguage,
            target: targetLanguage,
            provider: provider,
            model: modelName,
            reasoning: reasoningEffort,
            sourceID: activeSourceID
        )
        if let cached = translationCache[cacheKey] {
            translatedText = cached
            errorMessage = nil
            lastSubmittedText = text
            return
        }

        translatedText = ""
        errorMessage = nil
        automaticTranslationTask = Task { [weak self] in
            let delay = delayNanoseconds ?? (self?.provider.isMachineTranslation == true ? 280_000_000 : 480_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled,
                  let self,
                  self.sourceText == text else { return }
            self.translate()
        }
    }

    func setTextAndTranslate(_ text: String) {
        automaticTranslationTask?.cancel()
        sourceText = text
        translatedText = ""
        lastSubmittedText = ""
        translate()
    }

    func translateForFloatingWindow(_ text: String) {
        comparisonTasks.forEach { $0.cancel() }
        comparisonTasks.removeAll()

        floatingSourceText = text
        floatingErrorMessage = nil

        let selected = enabledFloatingSources
        comparisonResults = selected.map {
            ComparisonTranslationResult(source: $0, translatedText: nil, errorMessage: nil, isLoading: true)
        }
        let source = sourceLanguage
        let target = floatingTargetLanguage(for: text)

        for translationSource in selected {
            let selectedProvider = translationSource.provider
            let customConfig = translationSource.customAPIID.flatMap { id in customAPISources.first { $0.id == id } }
            let model = translationSource.modelOverride ?? customConfig?.model ?? (selectedProvider == provider
                ? modelName
                : (UserDefaults.standard.string(forKey: Self.modelKey(for: selectedProvider)) ?? selectedProvider.defaultModel))
            let reasoning = reasoningEffort
            let key = apiKey(for: translationSource)
            let cacheKey = makeCacheKey(
                text: text,
                source: source,
                target: target,
                provider: selectedProvider,
                model: model,
                reasoning: reasoning,
                sourceID: translationSource.id
            )

            if let cached = translationCache[cacheKey] {
                updateComparisonResult(for: translationSource.id, translatedText: cached, errorMessage: nil)
                continue
            }

            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let result: String
                    if selectedProvider == .openAIChatGPT {
                        result = try await codexService.translate(
                            text: text,
                            source: source,
                            target: target,
                            model: model,
                            reasoning: reasoning
                        )
                    } else if selectedProvider == .antigravityOAuth {
                        result = try await antigravityService.translate(text: text, source: source, target: target, model: model)
                    } else if selectedProvider == .appleTranslation {
                        result = try await appleService.translate(
                            text: text,
                            source: source,
                            target: target
                        )
                        self.providerConnectionStates[ModelProvider.appleTranslation.rawValue] = .connected
                    } else if selectedProvider == .ollama {
                        result = try await ollamaService.translate(text: text, source: source, target: target, model: model)
                    } else {
                        result = try await directService.translate(
                            text: text,
                            source: source,
                            target: target,
                            provider: selectedProvider,
                            model: model,
                            reasoning: reasoning,
                            apiKey: key,
                            customEndpoint: customConfig?.endpoint ?? self.customAPIEndpoint
                        )
                    }
                    guard !Task.isCancelled, self.floatingSourceText == text else { return }
                    self.storeInCache(result, for: cacheKey)
                    self.updateComparisonResult(for: translationSource.id, translatedText: result, errorMessage: nil)
                } catch {
                    guard !Task.isCancelled, self.floatingSourceText == text else { return }
                    self.updateComparisonResult(for: translationSource.id, translatedText: nil, errorMessage: error.localizedDescription)
                }
            }
            comparisonTasks.append(task)
        }
    }

    func showFloatingError(_ message: String) {
        comparisonTasks.forEach { $0.cancel() }
        comparisonTasks.removeAll()
        floatingSourceText = ""
        floatingErrorMessage = message
        comparisonResults = []
    }

    func translateQuickInput(_ text: String) async throws -> String {
        let defaultSource = allTranslationSources.first(where: { $0.id == activeSourceID }) ?? TranslationSource(
            id: activeSourceID,
            provider: provider,
            customAPIID: provider == .customAPI ? selectedCustomAPIID : nil,
            displayName: activeProviderDisplayName
        )
        return try await translateQuickInput(text, with: defaultSource)
    }

    func translateWithDefaultFallback(_ text: String) async throws -> DefaultFallbackTranslationResult {
        let defaultSource = allTranslationSources.first(where: { $0.id == activeSourceID }) ?? TranslationSource(
            id: activeSourceID,
            provider: provider,
            customAPIID: provider == .customAPI ? selectedCustomAPIID : nil,
            displayName: activeProviderDisplayName
        )
        let candidates = [defaultSource] + enabledFloatingSources.filter { $0.id != defaultSource.id }
        var failures: [String] = []
        for source in candidates {
            do {
                let translated = try await translateQuickInput(text, with: source)
                return DefaultFallbackTranslationResult(text: translated, sourceName: source.displayName)
            } catch {
                failures.append("\(source.displayName)：\(error.localizedDescription)")
            }
        }
        throw NSError(
            domain: "GPTTranslator.ScreenshotTranslation",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "；")]
        )
    }

    private func translateQuickInput(_ text: String, with sourceConfig: TranslationSource) async throws -> String {
        let selectedProvider = sourceConfig.provider
        let customConfig = sourceConfig.customAPIID.flatMap { id in customAPISources.first { $0.id == id } }
        let selectedModel = sourceConfig.modelOverride ?? customConfig?.model ?? (selectedProvider == provider
            ? modelName
            : (UserDefaults.standard.string(forKey: Self.modelKey(for: selectedProvider)) ?? selectedProvider.defaultModel))
        let target = floatingTargetLanguage(for: text)
        let source: LanguageOption = target == .english ? .chineseSimplified : .english
        if selectedProvider == .openAIChatGPT {
            return try await codexService.translate(
                text: text,
                source: source,
                target: target,
                model: selectedModel,
                reasoning: .none
            )
        }

        if selectedProvider == .antigravityOAuth {
            return try await antigravityService.translate(text: text, source: source, target: target, model: selectedModel)
        }

        if selectedProvider == .appleTranslation {
            let result = try await appleService.translate(
                text: text,
                source: source,
                target: target
            )
            providerConnectionStates[ModelProvider.appleTranslation.rawValue] = .connected
            return result
        }

        if selectedProvider == .ollama {
            return try await ollamaService.translate(text: text, source: source, target: target, model: selectedModel)
        }

        let endpoint: String
        if selectedProvider == .customAPI, let config = customConfig {
            endpoint = config.endpoint
        } else {
            endpoint = ""
        }
        return try await directService.translate(
            text: text,
            source: source,
            target: target,
            provider: selectedProvider,
            model: selectedModel,
            reasoning: .none,
            apiKey: apiKey(for: sourceConfig),
            customEndpoint: endpoint
        )
    }

    func shouldTranslateFloatingText(_ text: String) -> Bool {
        translateChineseContent || !isPredominantlyChinese(text)
    }

    func setTranslateChineseContent(_ enabled: Bool) {
        translateChineseContent = enabled
        UserDefaults.standard.set(enabled, forKey: "translateChineseContent")
    }

    func isFloatingSourceEnabled(_ source: TranslationSource) -> Bool {
        floatingSourceIDs.contains(source.id)
    }

    func setFloatingSource(_ source: TranslationSource, enabled: Bool) {
        if enabled {
            floatingSourceIDs.insert(source.id)
        } else if floatingSourceIDs.count > 1 {
            floatingSourceIDs.remove(source.id)
        }
        Task { await testEnabledProviderConnections() }
    }

    func enableOllamaAfterSetup() {
        floatingSourceIDs.insert(ModelProvider.ollama.rawValue)
        persistSettings()
        Task { await testEnabledProviderConnections() }
    }

    func moveComparisonProvider(_ sourceID: String, before destinationID: String) {
        guard sourceID != destinationID,
              let sourceIndex = comparisonResults.firstIndex(where: { $0.source.id == sourceID }),
              let destinationIndex = comparisonResults.firstIndex(where: { $0.source.id == destinationID }) else { return }

        let result = comparisonResults.remove(at: sourceIndex)
        let insertionIndex = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        comparisonResults.insert(result, at: insertionIndex)
        persistFloatingSourceOrder(comparisonResults.map(\.source.id))
    }

    func moveComparisonProviderToEnd(_ sourceID: String) {
        guard let sourceIndex = comparisonResults.firstIndex(where: { $0.source.id == sourceID }),
              sourceIndex != comparisonResults.index(before: comparisonResults.endIndex) else { return }
        let result = comparisonResults.remove(at: sourceIndex)
        comparisonResults.append(result)
        persistFloatingSourceOrder(comparisonResults.map(\.source.id))
    }

    func swapLanguages() {
        guard sourceLanguage != .auto else { return }
        let oldSource = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = oldSource
        if !translatedText.isEmpty {
            sourceText = translatedText
            translatedText = ""
        }
    }

    func clear() {
        automaticTranslationTask?.cancel()
        sourceText = ""
        translatedText = ""
        errorMessage = nil
        lastSubmittedText = ""
    }

    func copyTranslation() {
        guard !translatedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText, forType: .string)
    }

    func increaseFontSize() {
        setFontSize(resultFontSize + 1)
    }

    func decreaseFontSize() {
        setFontSize(resultFontSize - 1)
    }

    func resetFontSize() {
        setFontSize(14)
    }

    private func setFontSize(_ size: CGFloat) {
        resultFontSize = min(max(size, 11), 24)
        UserDefaults.standard.set(Double(resultFontSize), forKey: "resultFontSize")
    }

    func saveSettings() {
        persistSettings()
        Task { await testEnabledProviderConnections() }
    }

    func persistSettings() {
        guard persistCurrentProviderSettings() else { return }
        UserDefaults.standard.set(provider.rawValue, forKey: "provider")
        UserDefaults.standard.set(selectedAPIModelSourceID?.uuidString, forKey: "selectedAPIModelSourceID")
        UserDefaults.standard.set(reasoningEffort.rawValue, forKey: "reasoningEffort")
        UserDefaults.standard.set(Array(floatingSourceIDs).sorted(), forKey: "floatingSourceIDs")
        UserDefaults.standard.set(floatingSourceOrder, forKey: "floatingSourceOrder")
        UserDefaults.standard.set(translateChineseContent, forKey: "translateChineseContent")
        UserDefaults.standard.set(translateEnglishSelectionToChinese, forKey: "translateEnglishSelectionToChinese")
        UserDefaults.standard.set(Double(resultFontSize), forKey: "resultFontSize")
    }

    @discardableResult
    private func persistCurrentProviderSettings() -> Bool {
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        modelName = trimmedModel
        var apiKeySaved = true
        if provider == .customAPI, let id = selectedCustomAPIID,
           let index = customAPISources.firstIndex(where: { $0.id == id }) {
            let trimmedName = customAPIDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            customAPIDisplayName = trimmedName.isEmpty ? "自定义 API" : trimmedName
            customAPIEndpoint = customAPIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            customAPISources[index].displayName = customAPIDisplayName
            customAPISources[index].endpoint = customAPIEndpoint
            if selectedAPIModelSourceID == nil { customAPISources[index].model = trimmedModel }
            apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !apiKey.isEmpty || apiKeyWasEdited {
                apiKeySaved = keychain.saveAPIKey(apiKey, account: customAPISources[index].keychainAccount)
            }
            persistCustomSources()
        } else if selectedAPIModelSourceID == nil {
            UserDefaults.standard.set(trimmedModel, forKey: modelKey(for: provider))
        }
        if provider.needsAPIKey, provider != .customAPI {
            apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !apiKey.isEmpty || apiKeyWasEdited {
                apiKeySaved = keychain.saveAPIKey(apiKey, for: provider)
            }
        }
        if apiKeySaved {
            apiKeyWasEdited = false
            return true
        }
        errorMessage = "无法保存 API Key，请检查钥匙串权限。"
        return false
    }

    private func floatingTargetLanguage(for text: String) -> LanguageOption {
        guard translateEnglishSelectionToChinese else { return targetLanguage }
        if isPredominantlyChinese(text) {
            return .english
        }
        if looksLikeLatinText(text) {
            return .chineseSimplified
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        if (hypotheses[.english] ?? 0) >= 0.5 { return .chineseSimplified }
        if (hypotheses[.simplifiedChinese] ?? 0) >= 0.5 || (hypotheses[.traditionalChinese] ?? 0) >= 0.5 {
            return .english
        }
        return targetLanguage
    }

    private func looksLikeLatinText(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy { scalar in
            switch scalar.value {
            case 0x0041...0x024F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF:
                return true
            default:
                return false
            }
        }
    }

    private func isPredominantlyChinese(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !scalars.isEmpty else { return false }
        let hanCount = scalars.reduce(into: 0) { count, scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                count += 1
            default:
                break
            }
        }
        return hanCount > 0 && hanCount * 2 >= scalars.count
    }

    private func performConnectionTest(for translationSource: TranslationSource) async throws {
        let testText = "connection test"
        let sourceLanguage: LanguageOption = .english
        let target: LanguageOption = .chineseSimplified

        let provider = translationSource.provider
        let customConfig = translationSource.customAPIID.flatMap { id in customAPISources.first { $0.id == id } }

        let model = translationSource.modelOverride ?? customConfig?.model ?? (provider == self.provider
            ? modelName
            : (UserDefaults.standard.string(forKey: Self.modelKey(for: provider)) ?? provider.defaultModel))
        let key = apiKey(for: translationSource)

        if provider == .openAIChatGPT {
            guard await codexService.loginStatus() else { throw CodexCLIService.ServiceError.notLoggedIn }
            _ = try await codexService.translate(
                text: testText,
                source: sourceLanguage,
                target: target,
                model: model,
                reasoning: reasoningEffort
            )
            isLoggedIn = true
        } else if provider == .antigravityOAuth {
            _ = try await antigravityService.translate(
                text: testText,
                source: sourceLanguage,
                target: target,
                model: model
            )
        } else if provider == .appleTranslation {
            try await appleService.testInstalledPair(
                source: sourceLanguage,
                target: target,
                sampleText: testText
            )
        } else if provider == .ollama {
            try await ollamaService.testConnection(model: model)
        } else {
            _ = try await directService.translate(
                text: testText,
                source: sourceLanguage,
                target: target,
                provider: provider,
                model: model,
                reasoning: reasoningEffort,
                apiKey: key,
                customEndpoint: customConfig?.endpoint ?? customAPIEndpoint
            )
        }
    }

    private static func modelKey(for provider: ModelProvider) -> String {
        "modelName.\(provider.rawValue)"
    }

    private func apiKey(for source: TranslationSource) -> String {
        if source.provider == .customAPI {
            guard let id = source.customAPIID, let config = customAPISources.first(where: { $0.id == id }) else { return "" }
            if provider == .customAPI, selectedCustomAPIID == id { return apiKey }
            return keychain.readAPIKey(account: config.keychainAccount) ?? ""
        }
        return source.provider == provider ? apiKey : (keychain.readAPIKey(for: source.provider) ?? "")
    }

    private static func savedModel(for provider: ModelProvider) -> String {
        let stored = UserDefaults.standard.string(forKey: modelKey(for: provider))
            ?? (provider == .openAIChatGPT ? UserDefaults.standard.string(forKey: "modelName") : nil)
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Migrate the previous OpenAI translation default to the current fast model.
        // An empty value means “use the default model” in the settings UI.
        if provider == .openAIChatGPT,
           !UserDefaults.standard.bool(forKey: "openAIModelDefaultMigrationCompleted") {
            UserDefaults.standard.set(true, forKey: "openAIModelDefaultMigrationCompleted")
            if trimmed.isEmpty || trimmed == "gpt-5.6-luna" {
                let model = provider.defaultModel
                UserDefaults.standard.set(model, forKey: modelKey(for: provider))
                return model
            }
        }
        return trimmed.isEmpty ? provider.defaultModel : trimmed
    }

    private static func customSourceID(_ id: UUID) -> String { "custom.\(id.uuidString)" }

    private static func normalizedSourceOrder(_ savedOrder: [String], allIDs: [String]) -> [String] {
        var seen = Set<String>()
        let validSavedOrder = savedOrder.filter { allIDs.contains($0) && seen.insert($0).inserted }
        return validSavedOrder + allIDs.filter { !seen.contains($0) }
    }

    private func persistFloatingSourceOrder(_ visibleOrder: [String]) {
        let visible = Set(visibleOrder)
        floatingSourceOrder = visibleOrder + floatingSourceOrder.filter { !visible.contains($0) }
        UserDefaults.standard.set(floatingSourceOrder, forKey: "floatingSourceOrder")
    }

    private func persistCustomSources() {
        if let data = try? JSONEncoder().encode(customAPISources) {
            UserDefaults.standard.set(data, forKey: "customAPISources")
        }
        UserDefaults.standard.set(selectedCustomAPIID?.uuidString, forKey: "selectedCustomAPIID")
        UserDefaults.standard.set(Array(floatingSourceIDs).sorted(), forKey: "floatingSourceIDs")
        UserDefaults.standard.set(floatingSourceOrder, forKey: "floatingSourceOrder")
    }

    private func persistAPIModelSources() {
        if let data = try? JSONEncoder().encode(apiModelSources) {
            UserDefaults.standard.set(data, forKey: "apiModelSources")
        }
        UserDefaults.standard.set(selectedAPIModelSourceID?.uuidString, forKey: "selectedAPIModelSourceID")
        UserDefaults.standard.set(Array(floatingSourceIDs).sorted(), forKey: "floatingSourceIDs")
        UserDefaults.standard.set(floatingSourceOrder, forKey: "floatingSourceOrder")
    }

    private func modelKey(for provider: ModelProvider) -> String {
        Self.modelKey(for: provider)
    }

    private func makeCacheKey(text: String, source: LanguageOption, target: LanguageOption, provider: ModelProvider, model: String, reasoning: ReasoningEffort, sourceID: String? = nil) -> String {
        [sourceID ?? provider.rawValue, model, reasoning.rawValue, source.rawValue, target.rawValue, text].joined(separator: "\u{1F}")
    }

    private func storeInCache(_ result: String, for key: String) {
        if translationCache[key] == nil {
            cacheOrder.append(key)
        }
        translationCache[key] = result
        while cacheOrder.count > 100 {
            let oldest = cacheOrder.removeFirst()
            translationCache.removeValue(forKey: oldest)
        }
    }

    private func updateComparisonResult(for sourceID: String, translatedText: String?, errorMessage: String?) {
        guard let index = comparisonResults.firstIndex(where: { $0.source.id == sourceID }) else { return }
        comparisonResults[index].translatedText = translatedText
        comparisonResults[index].errorMessage = errorMessage
        comparisonResults[index].isLoading = false
    }
}
