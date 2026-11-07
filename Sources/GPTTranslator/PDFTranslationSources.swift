import Foundation

/// PDF windows keep their own source selection; changing it never changes the
/// source used by the main window or by floating translations.
@MainActor
final class PDFTranslationSources {
    private let viewModel: TranslationViewModel
    private let separator = "::pdf-model::"

    init(viewModel: TranslationViewModel) { self.viewModel = viewModel }

    private func savedModel(for provider: ModelProvider) -> String {
        if viewModel.provider == provider { return viewModel.modelName }
        return UserDefaults.standard.string(forKey: "modelName.\(provider.rawValue)") ?? provider.defaultModel
    }

    private func id(source: TranslationSource, model: String) -> String {
        source.id + separator + model
    }

    var defaultID: String {
        let source = TranslationSource(id: ModelProvider.ollama.rawValue, provider: .ollama, customAPIID: nil, displayName: "Ollama 本地")
        return id(source: source, model: savedModel(for: .ollama))
    }

    func options() -> [PDFTranslationSession.SourceOption] {
        let local = TranslationSource(id: ModelProvider.ollama.rawValue, provider: .ollama, customAPIID: nil, displayName: "Ollama 本地")
        let current = viewModel.allTranslationSources.first { $0.id == viewModel.activeSourceID }
        var sources = [local] + viewModel.enabledFloatingSources + viewModel.configuredPDFSources
        if let current { sources.append(current) }
        var seenSources = Set<String>()
        sources = sources.filter { seenSources.insert($0.id).inserted }
        var result: [PDFTranslationSession.SourceOption] = []
        for source in sources {
            let provider = source.provider
            let models: [String]
            if provider == .ollama {
                models = [savedModel(for: provider)] + viewModel.ollamaService.models
            } else if let override = source.modelOverride {
                models = [override]
            } else if provider == .openAIChatGPT {
                models = [savedModel(for: provider)] + viewModel.openAIModels
            } else if provider == .antigravityOAuth {
                models = [savedModel(for: provider)] + viewModel.antigravityModels
            } else if provider.supportsModelSelection {
                let customModel = source.customAPIID.flatMap { id in viewModel.customAPISources.first { $0.id == id }?.model }
                models = [customModel ?? savedModel(for: provider)]
            } else {
                models = [""]
            }
            var seenModels = Set<String>()
            for model in models where seenModels.insert(model).inserted {
                guard !provider.supportsModelSelection || !model.isEmpty else { continue }
                let localSource = provider == .ollama || provider == .appleTranslation
                let sourceName = source.apiModelID == nil ? source.displayName : source.displayName.components(separatedBy: " · ").first ?? source.displayName
                let title = sourceName + (model.isEmpty ? "" : " · \(model)") + (localSource ? "" : "（云端）")
                result.append(.init(id: id(source: source, model: model), title: title, isLocal: localSource))
            }
        }
        return result
    }

    private func resolve(_ id: String) throws -> (TranslationSource, String) {
        let parts = id.components(separatedBy: separator)
        guard parts.count == 2,
              var source = viewModel.allTranslationSources.first(where: { $0.id == parts[0] }) else {
            throw PDFReaderError.message("翻译源已移除，请重新选择。")
        }
        let model = parts[1]
        source.modelOverride = model.isEmpty ? nil : model
        return (source, model)
    }

    func translate(_ text: String, sourceID: String) async throws -> String {
        let (source, _) = try resolve(sourceID)
        return try await viewModel.translatePDFText(text, with: source)
    }

    func translateBatch(_ texts: [String], sourceID: String) async throws -> [String] {
        let (source, model) = try resolve(sourceID)
        if source.provider == .ollama {
            return try await viewModel.ollamaService.translatePDFBlocks(texts, model: model)
        }
        var translations: [String] = []
        for text in texts {
            try Task.checkCancellation()
            translations.append(try await viewModel.translatePDFText(text, with: source))
        }
        return translations
    }
}
