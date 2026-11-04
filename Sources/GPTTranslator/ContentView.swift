import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: TranslationViewModel
    @EnvironmentObject private var globalController: GlobalTranslationController
    @State private var isModelEditorPresented = false
    @State private var customModelDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            languageBar
            editorArea
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topLeading) {
            AppleTranslationBridgeHost(service: viewModel.appleService)
        }
        .onAppear { viewModel.refreshOpenAIModels() }
        .onChange(of: viewModel.sourceText) { _ in
            viewModel.scheduleAutomaticTranslation()
        }
        .onChange(of: viewModel.sourceLanguage) { _ in
            viewModel.scheduleAutomaticTranslation(delayNanoseconds: 100_000_000)
        }
        .onChange(of: viewModel.targetLanguage) { _ in
            viewModel.scheduleAutomaticTranslation(delayNanoseconds: 100_000_000)
        }
    }

    private var header: some View {
        HStack {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
            Text("GPT 翻译助手")
                .font(.title2.weight(.semibold))
            Spacer()
            Button {
                globalController.showSettingsWindow()
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var languageBar: some View {
        HStack(spacing: 12) {
            LanguagePicker(title: "原文", selection: $viewModel.sourceLanguage)
            Button(action: viewModel.swapLanguages) {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .help("交换语言")
            LanguagePicker(title: "译文", selection: $viewModel.targetLanguage, excludesAuto: true)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var editorArea: some View {
        HStack(spacing: 16) {
            EditorCard(
                title: "原文",
                text: $viewModel.sourceText,
                placeholder: "输入或粘贴要翻译的内容…",
                fontSize: viewModel.resultFontSize,
                footer: {
                    Button("清空", systemImage: "xmark.circle") { viewModel.clear() }
                        .buttonStyle(.borderless)
                        .disabled(viewModel.sourceText.isEmpty && viewModel.translatedText.isEmpty)
                }
            )
            EditorCard(
                title: "译文",
                text: .constant(viewModel.translatedText),
                placeholder: "翻译结果会显示在这里…",
                fontSize: viewModel.resultFontSize,
                footer: {
                    Button("复制", systemImage: "doc.on.doc") { viewModel.copyTranslation() }
                        .buttonStyle(.borderless)
                        .disabled(viewModel.translatedText.isEmpty)
                }
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Picker("默认翻译源", selection: Binding(
                    get: { viewModel.activeSourceID },
                    set: { selectedID in
                        if let source = viewModel.allTranslationSources.first(where: { $0.id == selectedID }) {
                            viewModel.selectTranslationSource(source)
                            viewModel.saveSettings()
                        }
                    }
                )) {
                    ForEach(viewModel.allTranslationSources) { source in
                        Text(source.displayName).tag(source.id)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("选择并保存主窗口的默认翻译源")

                Divider()
                    .frame(height: 18)

                if viewModel.provider.supportsModelSelection {
                    modelMenu
                } else {
                    Text("此翻译源无需选择模型")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 18)

                if !viewModel.availableReasoningEfforts.isEmpty {
                    reasoningSlider
                    Divider().frame(height: 18)
                }

                if viewModel.isTranslating {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在翻译…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var modelMenu: some View {
        HStack(spacing: 6) {
            Text("模型")
                .foregroundStyle(.secondary)
            Menu {
                if !viewModel.availableModelOptions.contains(viewModel.modelName), !viewModel.modelName.isEmpty {
                    Button(viewModel.modelName) { viewModel.selectModel(viewModel.modelName) }
                    Divider()
                }
                ForEach(viewModel.availableModelOptions, id: \.self) { model in
                    Button {
                        viewModel.selectModel(model)
                    } label: {
                        if model == viewModel.modelName {
                            Label(model, systemImage: "checkmark")
                        } else {
                            Text(model)
                        }
                    }
                }
                Divider()
                Button("输入模型名称…") {
                    customModelDraft = viewModel.modelName
                    isModelEditorPresented = true
                }
                if viewModel.provider == .openAIChatGPT || viewModel.provider == .antigravityOAuth {
                    Button(viewModel.isLoadingModelList ? "正在获取模型…" :
                           (viewModel.modelListError == nil ? "刷新可用模型" : "刷新失败，点击重试")) {
                        viewModel.refreshCurrentModelList()
                    }
                    .disabled(viewModel.isLoadingModelList)
                    .help(viewModel.modelListError ?? "重新获取当前账号可用的模型")
                }
            } label: {
                Text(viewModel.modelLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 210)
            .help(viewModel.modelListError ?? "选择当前翻译源使用的模型")
            .popover(isPresented: $isModelEditorPresented) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("模型名称").font(.headline)
                    TextField("输入模型名称", text: $customModelDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyCustomModel() }
                    HStack {
                        Spacer()
                        Button("取消") { isModelEditorPresented = false }
                        Button("确定") { applyCustomModel() }
                            .disabled(customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(16)
                .frame(width: 300)
            }
        }
    }

    private var reasoningSlider: some View {
        let options = viewModel.availableReasoningEfforts
        let selected = options.firstIndex(of: viewModel.displayedReasoningEffort) ?? 0
        return HStack(spacing: 5) {
            Text("推理").foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { Double(selected) },
                set: { value in
                    let index = min(max(Int(value.rounded()), 0), options.count - 1)
                    viewModel.selectReasoningEffort(options[index], retranslate: false)
                }
            ), in: 0...Double(max(options.count - 1, 1)), step: 1, onEditingChanged: { editing in
                if !editing, viewModel.provider != .antigravityOAuth { viewModel.refreshAfterReasoningChange() }
            })
            .frame(width: 100)
            .disabled(options.count < 2)
            .accessibilityLabel("推理强度")
            .accessibilityValue(viewModel.displayedReasoningEffort.displayName)
            Text(viewModel.displayedReasoningEffort.displayName)
                .font(.caption)
                .frame(minWidth: 28, alignment: .leading)
        }
        .help(viewModel.provider == .antigravityOAuth ? "切换同一模型可用的推理档位" : "调整当前模型的推理强度")
    }

    private func applyCustomModel() {
        viewModel.selectModel(customModelDraft)
        isModelEditorPresented = false
    }
}

private struct LanguagePicker: View {
    let title: String
    @Binding var selection: LanguageOption
    var excludesAuto = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Picker(title, selection: $selection) {
                ForEach(LanguageOption.allCases.filter { !excludesAuto || $0 != .auto }) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .labelsHidden()
            .frame(width: 150)
        }
    }
}

private struct EditorCard<Footer: View>: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let fontSize: CGFloat
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: fontSize))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: fontSize))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }

            Divider()
            HStack {
                footer
                Spacer()
                Text("\(text.count) 字")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }
}
