import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: TranslationViewModel
    @EnvironmentObject private var globalController: GlobalTranslationController
    @State private var automaticSaveTask: Task<Void, Never>?
    @State private var manualModelDraft = ""
    @State private var modelSearch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                settingsSection("翻译服务") {
                    Picker("服务", selection: Binding(
                        get: { viewModel.provider },
                        set: { viewModel.selectProvider($0) }
                    )) {
                        ForEach(ModelProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

                    if viewModel.provider == .openAIChatGPT {
                        HStack {
                            Label(
                                viewModel.isLoggedIn ? "已通过 ChatGPT OAuth 登录" : "尚未登录 ChatGPT",
                                systemImage: viewModel.isLoggedIn ? "checkmark.circle.fill" : "person.crop.circle"
                            )
                            .foregroundStyle(viewModel.isLoggedIn ? .green : .secondary)
                            Spacer()
                            Button(viewModel.isLoggingIn ? "登录中…" : "使用 ChatGPT 登录") {
                                viewModel.loginWithChatGPT()
                            }
                            .disabled(viewModel.isLoggingIn)
                            .buttonStyle(.borderedProminent)
                        }
                        Text("登录会打开浏览器完成 OAuth，并复用本机 Codex CLI 会话。应用不会要求或保存 OpenAI API Key。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if viewModel.provider == .antigravityOAuth {
                        Label(
                            viewModel.providerReady ? "已找到官方 Antigravity CLI" : "未找到 Antigravity CLI（agy）",
                            systemImage: viewModel.providerReady ? "checkmark.circle.fill" : "terminal"
                        )
                        .foregroundStyle(viewModel.providerReady ? .green : .secondary)
                        Text("使用 agy 自己管理的 Google OAuth 登录会话。应用不会读取、复制或打包 OAuth Token；默认使用 \(ModelProvider.antigravityFastModel)，也可选择账号支持的其他模型。首次使用请先在终端运行 agy 完成 Google 登录。连接测试会发出一次极短请求，并可能受 Google 地区与额度限制。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if viewModel.provider == .appleTranslation {
                        Label("无需账号或 API Key", systemImage: "apple.logo")
                            .foregroundStyle(.secondary)
                        Text("使用系统翻译语言包，本地处理且不消耗云端 token。缺少语言包时，请先在系统“翻译”App 或系统设置中下载；下载完成后即可离线使用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if viewModel.provider == .googleWeb {
                        Label("无需账号或 API Key", systemImage: "globe")
                            .foregroundStyle(.secondary)
                        Text("使用 Google 网页翻译的非官方公共接口，可能受网络环境或请求频率限制；HTTP 429 时请切换其他翻译源。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if viewModel.provider == .ollama {
                        OllamaSetupSection(service: viewModel.ollamaService, viewModel: viewModel)
                    } else {
                        if viewModel.provider == .customAPI {
                            HStack {
                                Picker("配置", selection: Binding(
                                    get: { viewModel.selectedCustomAPIID },
                                    set: { if let id = $0 { viewModel.selectCustomAPI(id) } }
                                )) {
                                    ForEach(viewModel.customAPISources) { source in
                                        Text(source.displayName).tag(Optional(source.id))
                                    }
                                }
                                Button("添加", systemImage: "plus") { viewModel.addCustomAPI() }
                                Button("删除", systemImage: "trash") { viewModel.deleteSelectedCustomAPI() }
                                    .disabled(viewModel.customAPISources.count <= 1)
                            }
                            TextField("显示名称，例如 Gemini", text: $viewModel.customAPIDisplayName)
                                .textFieldStyle(.roundedBorder)
                            TextField("接口地址，例如 https://example.com/v1/chat/completions", text: $viewModel.customAPIEndpoint)
                                .textFieldStyle(.roundedBorder)
                        }
                        SecureField("\(viewModel.provider.shortName) API Key", text: Binding(
                            get: { viewModel.apiKey },
                            set: { viewModel.setAPIKeyFromUser($0) }
                        ))
                            .textFieldStyle(.roundedBorder)
                        Button("重新授权钥匙串读取", systemImage: "key") {
                            viewModel.authorizeSelectedAPIKeyFromKeychain()
                        }
                        .help("仅在你主动点击时显示钥匙串授权；启动和后台检测不会弹窗")
                        Text(credentialHelp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if viewModel.provider.supportsModelSelection && viewModel.provider != .ollama {
                    settingsSection("模型与推理") {
                    HStack {
                    Picker("当前模型", selection: Binding(
                        get: { viewModel.modelName },
                        set: { if !$0.isEmpty { viewModel.selectModel($0) } }
                    )) {
                        if !viewModel.availableModelOptions.contains(viewModel.modelName) {
                            Text(viewModel.modelName.isEmpty ? "请选择模型" : viewModel.modelName).tag(viewModel.modelName)
                        }
                        ForEach(viewModel.availableModelOptions, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    Button(viewModel.isLoadingModelList ? "获取中…" : "刷新模型") {
                        viewModel.refreshCurrentModelList()
                    }
                    .disabled(viewModel.isLoadingModelList)
                    }
                    if let error = viewModel.modelListError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if viewModel.provider.needsAPIKey {
                        Text(viewModel.apiModelsBySource[viewModel.activeBaseSourceID].map { "已获取 \($0.count) 个模型。" }
                             ?? "填写 API Key 后自动获取模型。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if viewModel.provider.needsAPIKey {
                        if !viewModel.apiModelChoices.isEmpty {
                            Text("选择要加入翻译源的模型").font(.subheadline.weight(.medium))
                            if viewModel.apiModelChoices.count > 8 {
                                TextField("搜索模型", text: $modelSearch)
                                    .textFieldStyle(.roundedBorder)
                            }
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 7) {
                                    ForEach(viewModel.apiModelChoices.filter {
                                        modelSearch.isEmpty || $0.localizedCaseInsensitiveContains(modelSearch)
                                    }, id: \.self) { model in
                                        Toggle(isOn: Binding(
                                            get: { viewModel.isAPIModelAdded(model) },
                                            set: { viewModel.setAPIModelAdded(model, enabled: $0) }
                                        )) {
                                            HStack {
                                                Text(model)
                                                if let fetched = viewModel.apiModelsBySource[viewModel.activeBaseSourceID], !fetched.contains(model) {
                                                    Text("当前列表未返回")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                            }
                            .frame(maxHeight: 150)
                            Text("勾选后可在主窗口选择；如需划词时同时显示，请在下方“悬浮窗结果来源”中启用。多个模型会分别请求接口，可能产生额外费用。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if viewModel.modelListError != nil {
                            HStack {
                                TextField("无法获取列表时，手动输入模型名称", text: $manualModelDraft)
                                    .textFieldStyle(.roundedBorder)
                                Button("加入翻译源") {
                                    viewModel.setAPIModelAdded(manualModelDraft, enabled: true)
                                    manualModelDraft = ""
                                }
                                .disabled(manualModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    } else {
                        TextField("模型名称", text: $viewModel.modelName)
                            .textFieldStyle(.roundedBorder)
                    }
                    if viewModel.provider != .antigravityOAuth {
                        Picker("推理强度", selection: Binding(
                            get: { viewModel.displayedReasoningEffort },
                            set: { viewModel.selectReasoningEffort($0) }
                        )) {
                            ForEach(viewModel.availableReasoningEfforts) { effort in
                                Text(effort.displayName).tag(effort)
                            }
                        }
                    }
                    Text("Codex OAuth、DeepSeek、智谱和自定义兼容 API 会使用所选模型及推理强度；Antigravity OAuth 使用模型名称对应的推理配置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                settingsSection("系统权限") {
                    HStack {
                        Label(
                            globalController.accessibilityTrusted ? "辅助功能权限已允许" : "需要辅助功能权限",
                            systemImage: globalController.accessibilityTrusted ? "checkmark.shield.fill" : "lock.shield"
                        )
                        .foregroundStyle(globalController.accessibilityTrusted ? .green : .secondary)
                        Spacer()
                        Button("检查并打开设置") {
                            globalController.requestAccessibilityPermission()
                        }
                    }
                    Text("划词翻译需要辅助功能权限；截图翻译首次使用时，macOS 还会请求屏幕录制权限。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                settingsSection("应用显示") {
                    Toggle("在 Dock 中显示应用", isOn: $globalController.showInDock)
                    Toggle("登录时自动启动", isOn: $globalController.launchAtLogin)
                    Text("隐藏 Dock 图标后仍可通过菜单栏图标打开主窗口和设置；自动启动由 macOS 登录项管理。当前状态：\(globalController.launchAtLoginStatusDescription)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                settingsSection("划词翻译") {
                    Toggle("启用划词翻译", isOn: Binding(
                        get: { globalController.selectionEnabled },
                        set: { globalController.setSelectionTranslationEnabled($0) }
                    ))
                    Toggle("选中后显示翻译图标", isOn: Binding(
                        get: { globalController.selectionTriggerMode == .button },
                        set: { globalController.setShowSelectionTranslationButton($0) }
                    ))
                    Text("未勾选时，选中文字后直接翻译；勾选后先显示翻译图标，将鼠标移到图标上即可翻译。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("自动判断中英文翻译方向", isOn: $viewModel.translateEnglishSelectionToChinese)
                    Text("检测到英文时译成中文，检测到中文时译成英文。是否处理中文可在菜单栏中快速切换。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                settingsSection("快捷键") {
                    shortcutPicker(
                        title: "启用/关闭划词翻译",
                        modifiers: $globalController.translateShortcutModifiers,
                        key: $globalController.translateShortcutKey
                    )
                    shortcutPicker(
                        title: "截图翻译",
                        modifiers: $globalController.screenshotShortcutModifiers,
                        key: $globalController.screenshotShortcutKey
                    )
                    shortcutPicker(
                        title: "普通截图",
                        modifiers: $globalController.captureShortcutModifiers,
                        key: $globalController.captureShortcutKey
                    )
                    shortcutPicker(
                        title: "截图 OCR",
                        modifiers: $globalController.ocrShortcutModifiers,
                        key: $globalController.ocrShortcutKey
                    )
                    shortcutPicker(
                        title: "快捷翻译输入框",
                        modifiers: $globalController.quickInputShortcutModifiers,
                        key: $globalController.quickInputShortcutKey
                    )
                        Text("菜单栏会显示各功能的当前快捷键；“启用/关闭划词翻译”快捷键用于切换划词监听状态，截图 OCR 只识别并复制文字，不进行翻译。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if globalController.hasShortcutConflict {
                        Label("五个功能不能使用相同的快捷键。", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                settingsSection("悬浮窗结果来源") {
                    ForEach(viewModel.allTranslationSources) { source in
                        Toggle(source.displayName, isOn: Binding(
                            get: { viewModel.isFloatingSourceEnabled(source) },
                            set: { viewModel.setFloatingSource(source, enabled: $0) }
                        ))
                    }
                    Text("至少保留一个来源。划词和截图翻译会并行请求已勾选的来源；云服务需要先切换到对应服务并保存凭据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

        }
        .padding(24)
        .frame(width: 680, height: 560)
        .onAppear {
            viewModel.refreshLoginStatus()
            globalController.refreshAccessibilityStatus()
            globalController.refreshLaunchAtLoginStatus()
        }
        .onDisappear {
            automaticSaveTask?.cancel()
            saveImmediately()
        }
        .onChange(of: automaticSaveSnapshot) { _ in scheduleAutomaticSave() }
        .onChange(of: viewModel.apiKey) { _ in viewModel.scheduleAPIModelRefresh() }
        .onChange(of: viewModel.customAPIEndpoint) { _ in viewModel.scheduleAPIModelRefresh() }
        .onChange(of: viewModel.activeBaseSourceID) { _ in
            modelSearch = ""
            manualModelDraft = ""
        }
    }

    private var credentialHelp: String {
        viewModel.provider == .customAPI
            ? "支持 OpenAI Chat Completions 兼容接口；API Key 只保存在本机钥匙串中。"
            : "API Key 只保存在本机钥匙串中。"
    }

    private func scheduleAutomaticSave() {
        automaticSaveTask?.cancel()
        automaticSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            saveImmediately()
        }
    }

    private func saveImmediately() {
        guard !globalController.hasShortcutConflict else { return }
        viewModel.persistSettings()
        _ = globalController.saveSelectionPreferences()
    }

    private var automaticSaveSnapshot: AutomaticSaveSnapshot {
        AutomaticSaveSnapshot(
            provider: viewModel.provider,
            modelName: viewModel.modelName,
            reasoningEffort: viewModel.reasoningEffort,
            apiKey: viewModel.apiKey,
            customAPIEndpoint: viewModel.customAPIEndpoint,
            customAPIDisplayName: viewModel.customAPIDisplayName,
            selectedCustomAPIID: viewModel.selectedCustomAPIID,
            selectedAPIModelSourceID: viewModel.selectedAPIModelSourceID,
            translateEnglishSelectionToChinese: viewModel.translateEnglishSelectionToChinese,
            floatingSourceIDs: viewModel.floatingSourceIDs,
            selectionEnabled: globalController.selectionEnabled,
            autoTranslateSelection: globalController.autoTranslateSelection,
            showSelectionButton: globalController.showSelectionButton,
            translateShortcutModifiers: globalController.translateShortcutModifiers,
            translateShortcutKey: globalController.translateShortcutKey,
            screenshotShortcutModifiers: globalController.screenshotShortcutModifiers,
            screenshotShortcutKey: globalController.screenshotShortcutKey,
            captureShortcutModifiers: globalController.captureShortcutModifiers,
            captureShortcutKey: globalController.captureShortcutKey,
            ocrShortcutModifiers: globalController.ocrShortcutModifiers,
            ocrShortcutKey: globalController.ocrShortcutKey,
            quickInputShortcutModifiers: globalController.quickInputShortcutModifiers,
            quickInputShortcutKey: globalController.quickInputShortcutKey,
            showInDock: globalController.showInDock,
            launchAtLogin: globalController.launchAtLogin
        )
    }

    private func shortcutPicker(
        title: String,
        modifiers: Binding<ShortcutModifiers>,
        key: Binding<ShortcutKey>
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker("组合键", selection: modifiers) {
                ForEach(ShortcutModifiers.allCases) { option in
                    Text(option.symbols).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 90)
            Picker("按键", selection: key) {
                ForEach(ShortcutKey.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 70)
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

private struct OllamaSetupSection: View {
    @ObservedObject var service: OllamaService
    @ObservedObject var viewModel: TranslationViewModel
    @State private var customModel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("本地模型", selection: Binding(
                get: { viewModel.modelName },
                set: { viewModel.selectModel($0) }
            )) {
                if !service.modelChoices.contains(viewModel.modelName), !viewModel.modelName.isEmpty {
                    Text(viewModel.modelName).tag(viewModel.modelName)
                }
                ForEach(service.modelChoices, id: \.self) { model in
                    Text(service.models.contains(model) ? model : "\(model)（未下载）").tag(model)
                }
            }
            .disabled(service.isBusy)
            HStack {
                TextField("其他本地模型名称，例如 qwen3:8b", text: $customModel)
                    .textFieldStyle(.roundedBorder)
                Button("选择") {
                    viewModel.selectModel(customModel)
                    customModel = ""
                }
                .disabled(service.isBusy || customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Button(service.models.contains(viewModel.modelName) ? "启用此模型" : "一键安装并启用") {
                    service.setup(model: viewModel.modelName) { viewModel.enableOllamaAfterSetup() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.isBusy || viewModel.modelName.isEmpty)
                Button("刷新模型") { service.refresh() }
                    .disabled(service.isBusy)
                if service.isBusy {
                    Button("取消") { service.cancelSetup() }
                }
                if service.isManagedInstalled {
                    Button("卸载本地模型与组件") { service.uninstall() }
                        .disabled(service.isBusy)
                }
            }
            if service.isBusy {
                if let progress = service.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Text(service.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = service.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("自动安装官方 Ollama 并下载所选模型；Qwen2.5 7B 约 4.7 GB。模型在本机运行，空闲 5 分钟后释放内存。卸载只移除本软件安装的组件和模型，不影响已有的 Ollama。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AutomaticSaveSnapshot: Equatable {
    let provider: ModelProvider
    let modelName: String
    let reasoningEffort: ReasoningEffort
    let apiKey: String
    let customAPIEndpoint: String
    let customAPIDisplayName: String
    let selectedCustomAPIID: UUID?
    let selectedAPIModelSourceID: UUID?
    let translateEnglishSelectionToChinese: Bool
    let floatingSourceIDs: Set<String>
    let selectionEnabled: Bool
    let autoTranslateSelection: Bool
    let showSelectionButton: Bool
    let translateShortcutModifiers: ShortcutModifiers
    let translateShortcutKey: ShortcutKey
    let screenshotShortcutModifiers: ShortcutModifiers
    let screenshotShortcutKey: ShortcutKey
    let captureShortcutModifiers: ShortcutModifiers
    let captureShortcutKey: ShortcutKey
    let ocrShortcutModifiers: ShortcutModifiers
    let ocrShortcutKey: ShortcutKey
    let quickInputShortcutModifiers: ShortcutModifiers
    let quickInputShortcutKey: ShortcutKey
    let showInDock: Bool
    let launchAtLogin: Bool
}
