import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFReaderView: View {
    @StateObject private var session: PDFTranslationSession
    @StateObject private var controls = PDFReaderControls()
    @ObservedObject private var viewModel: TranslationViewModel
    @ObservedObject private var ollama: OllamaService
    @State private var pageText = "1"
    @State private var displayOriginalLayout = true
    @State private var splitFraction: CGFloat = 0.5
    @State private var splitDragStart: CGFloat?
    @State private var fontScale: CGFloat = 1.35
    @State private var fontUpdateTask: Task<Void, Never>?
    @State private var isPDFDropTargeted = false
    @State private var pdfDropError: String?
    @FocusState private var searchHasFocus: Bool

    init(session: PDFTranslationSession, viewModel: TranslationViewModel) {
        _session = StateObject(wrappedValue: session)
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _ollama = ObservedObject(wrappedValue: viewModel.ollamaService)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: openPDF) { Label("打开 PDF", systemImage: "folder") }
                    .disabled(session.isExporting)
                Divider().frame(height: 20)
                Button { session.goToPage(session.pageIndex - 1) } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(session.pageIndex == 0 || session.isExporting)
                .help("上一页")
                TextField("页码", text: $pageText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                    .multilineTextAlignment(.center)
                    .disabled(session.pageCount == 0 || session.isExporting)
                    .help("输入页码后按回车跳转")
                    .onSubmit(jumpToTypedPage)
                Text("/ \(session.pageCount)")
                    .monospacedDigit()
                Button { session.goToPage(session.pageIndex + 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(session.pageIndex + 1 >= session.pageCount || session.isExporting)
                .help("下一页")
                Spacer(minLength: 8)
                if session.document != nil {
                    Button("重新翻译") { session.translateCurrentPage(force: true) }
                        .disabled(session.isExporting)
                    Button(action: exportPDF) { Label("导出对照 PDF", systemImage: "square.and.arrow.down") }
                        .disabled(session.isExporting)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if session.document != nil {
                HStack(spacing: 10) {
                    Button { controls.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("缩小 PDF")
                    Text("\(controls.zoomPercent)%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 42)
                    Button { controls.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("放大 PDF")
                    Button("适合宽度") { controls.fitWidth() }
                    Divider().frame(height: 18)
                    Button {
                        searchHasFocus = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    .help("搜索 PDF 文字（⌘F）")
                    TextField("搜索 PDF 文字", text: $controls.searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchHasFocus)
                        .frame(minWidth: 120, idealWidth: 200, maxWidth: 260)
                        .onSubmit { controls.nextMatch() }
                        .help("搜索 PDF 自带的文字层；扫描图片需先识别文字")
                    Button { controls.previousMatch() } label: { Image(systemName: "chevron.up") }
                        .disabled(controls.matchCount == 0)
                        .help("上一处")
                    Button { controls.nextMatch() } label: { Image(systemName: "chevron.down") }
                        .disabled(controls.matchCount == 0)
                        .help("下一处")
                    if controls.matchCount > 0 {
                        Text("\(controls.currentMatch)/\(controls.matchCount)")
                            .font(.caption.monospacedDigit())
                    }
                    if !controls.searchStatus.isEmpty {
                        Text(controls.searchStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()

                HStack(spacing: 10) {
                    Text("翻译源").font(.caption)
                    Menu {
                        ForEach(session.sourceOptions) { option in
                            Button {
                                session.selectSource(option.id)
                            } label: {
                                if option.id == (session.selectedSourceID ?? session.activeModel) {
                                    Label(option.title, systemImage: "checkmark")
                                } else {
                                    Text(option.title)
                                }
                            }
                        }
                    } label: {
                        Text(session.selectedSourceTitle).lineLimit(1)
                    }
                    .disabled(session.isExporting)
                    .help("选择云端源后，PDF 文字将发送到该服务进行翻译")
                    if let option = session.sourceOptions.first(where: { $0.id == (session.selectedSourceID ?? session.activeModel) }), !option.isLocal {
                        Text("全文文字会发送至云端").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("译文字号").font(.caption)
                    Slider(value: $fontScale, in: 0.8...1.8, step: 0.05)
                        .frame(width: 110)
                        .disabled(session.isExporting)
                        .help("调整中文译文字号，超出页面的文字可在文字模式中查看")
                    Text("\(Int(fontScale * 100))%")
                        .font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                Divider()
            }

            if session.document == nil {
                VStack(spacing: 14) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("PDF 全文翻译")
                        .font(.title2.weight(.semibold))
                    Text("将 PDF 文件拖到这里，或点击下方按钮打开。")
                        .foregroundStyle(.secondary)
                    Button("打开 PDF", action: openPDF)
                        .buttonStyle(.borderedProminent)
                    if let error = session.errorMessage {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let error = pdfDropError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .background(isPDFDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                .onDrop(of: [UTType.fileURL], isTargeted: $isPDFDropTargeted, perform: acceptPDFDrop)
            } else {
                GeometryReader { geometry in
                  let available = max(geometry.size.width - 14, 440)
                  let leftWidth = min(max(available * splitFraction, 220), available - 220)
                  HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        panelHeading("英文原文", detail: session.fileName)
                        PDFDocumentView(session: session, controls: controls)
                            .disabled(session.isExporting)
                    }
                    .frame(width: leftWidth).frame(maxHeight: .infinity)

                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.5))
                        .frame(width: 1)
                        .frame(width: 14)
                        .contentShape(Rectangle())
                        .overlay {
                            Capsule().fill(Color.secondary.opacity(0.65)).frame(width: 3, height: 36)
                        }
                        .help("左右拖动，调整原文和译文宽度")
                        .onHover { hovering in (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if splitDragStart == nil { splitDragStart = splitFraction }
                                let start = splitDragStart ?? splitFraction
                                splitFraction = min(max(start + value.translation.width / available, 220 / available), 1 - 220 / available)
                            }
                            .onEnded { _ in splitDragStart = nil })

                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("中文译文").fontWeight(.semibold)
                            Spacer()
                            Button(displayOriginalLayout ? "文字模式" : "原版式") {
                                displayOriginalLayout.toggle()
                            }
                            .buttonStyle(.borderless)
                            .help("切换原版式和可复制的完整文字")
                        }
                        .font(.caption)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(Color(nsColor: .controlBackgroundColor))
                        if displayOriginalLayout, let data = session.renderedPageData {
                            if session.layoutOverflowCount > 0 {
                                HStack {
                                    Text("部分译文超出原位置，完整内容可在文字模式查看。")
                                    Spacer()
                                    Button("查看完整译文") { displayOriginalLayout = false }
                                }
                                .font(.caption)
                                .padding(8)
                            }
                            PDFTranslatedPageView(data: data, controls: controls)
                        } else {
                          ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(session.translatedParts.enumerated()), id: \.offset) { _, part in
                                    Text(part)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if let error = session.errorMessage {
                                    Text(error)
                                        .foregroundStyle(.red)
                                        .textSelection(.enabled)
                                }
                                if let error = session.layoutError {
                                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                                }
                                if session.isWorking {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text(session.status).foregroundStyle(.secondary)
                                    }
                                } else if !session.status.isEmpty {
                                    Text(session.status)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.system(size: 15))
                            .lineSpacing(5)
                            .padding(20)
                          }
                          .id(session.pageIndex)
                        }
                    }
                    .frame(width: available - leftWidth).frame(maxHeight: .infinity)
                  }
                }
                Divider()
                HStack {
                    if let error = session.backgroundError {
                        Text(error)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .help(error)
                    } else if let message = session.exportMessage {
                        Text(message).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("全文翻译：\(session.completedPageCount)/\(session.pageCount) 页")
                            .foregroundStyle(.secondary)
                        Text("复杂排版和 OCR 结果请结合原文核对。")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if session.isExporting {
                        Button("取消导出") { session.cancelExport() }
                    } else if session.backgroundError != nil {
                        Button("重试") { session.retryBackgroundTranslation() }
                    } else if session.isPaused || session.completedPageCount < session.pageCount {
                        Button(session.isPaused ? "继续全文翻译" : "暂停全文翻译") {
                            session.toggleBackgroundTranslation()
                        }
                    }
                }
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 800, minHeight: 520)
        .onAppear {
            controls.setDocument(session.document)
            ollama.refresh()
            pageText = "\(session.pageIndex + 1)"
            session.resumeIfNeeded()
        }
        .onChange(of: session.document) { controls.setDocument($0) }
        .onChange(of: session.pageIndex) { pageText = "\($0 + 1)" }
        .onChange(of: controls.searchText) { _ in controls.scheduleSearch() }
        .onChange(of: fontScale) { value in
            fontUpdateTask?.cancel()
            fontUpdateTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                session.setTranslationFontScale(value)
            }
        }
        .onDisappear {
            fontUpdateTask?.cancel()
            controls.stop()
            session.cancel()
        }
    }

    private func jumpToTypedPage() {
        guard let page = Int(pageText), page >= 1, page <= session.pageCount else {
            pageText = "\(session.pageIndex + 1)"
            return
        }
        session.goToPage(page - 1)
    }

    private func panelHeading(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).fontWeight(.semibold)
            Spacer()
            Text(detail).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func openPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        present(panel) { session.open($0) }
    }

    private func acceptPDFDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let fileURL = item as? URL {
                url = fileURL
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = nil
            }
            Task { @MainActor in
                guard let url, url.isFileURL, url.pathExtension.lowercased() == "pdf" else {
                    pdfDropError = "请拖入一个 PDF 文件。"
                    return
                }
                pdfDropError = nil
                session.open(url)
            }
        }
        return true
    }

    private func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = (session.fileName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base)-中英对照.pdf"
        present(panel) { session.export(to: $0) }
    }

    private func present(_ panel: NSSavePanel, selection: @escaping (URL) -> Void) {
        let readerWindow = NSApp.keyWindow
        AppFilePanelActivity.begin()
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            AppFilePanelActivity.end()
            guard response == .OK, let url = panel.url else { return }
            selection(url)
            readerWindow?.makeKeyAndOrderFront(nil)
        }
        if let readerWindow {
            panel.beginSheetModal(for: readerWindow, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

@MainActor
final class PDFReaderWindowHost: NSObject, NSWindowDelegate {
    let window: NSWindow
    let session: PDFTranslationSession
    var onClose: (() -> Void)?

    init(session: PDFTranslationSession, viewModel: TranslationViewModel) {
        self.session = session
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "PDF 全文翻译"
        window.minSize = NSSize(width: 800, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(rootView: PDFReaderView(session: session, viewModel: viewModel))
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        session.cancel()
        onClose?()
    }
}

/// Suppress global selection observation while an AppKit file panel is active.
@MainActor
enum AppFilePanelActivity {
    private static var depth = 0
    static var isActive: Bool { depth > 0 }
    static func begin() { depth += 1 }
    static func end() { depth = max(0, depth - 1) }
}

private struct PDFDocumentView: NSViewRepresentable {
    @ObservedObject var session: PDFTranslationSession
    @ObservedObject var controls: PDFReaderControls

    func makeCoordinator() -> Coordinator { Coordinator(session: session, controls: controls) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 5
        view.autoScales = true
        controls.attach(view)
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged, object: view
        )
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.scaleChanged(_:)),
            name: .PDFViewScaleChanged, object: view
        )
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== session.document {
            view.document = session.document
            context.coordinator.handledJump = nil
        }
        if let jump = session.pageJump, context.coordinator.handledJump != jump.id,
           let target = session.document?.page(at: jump.pageIndex) {
            context.coordinator.handledJump = jump.id
            view.go(to: target)
        }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var session: PDFTranslationSession?
        private weak var controls: PDFReaderControls?
        var handledJump: UUID?
        init(session: PDFTranslationSession, controls: PDFReaderControls) {
            self.session = session
            self.controls = controls
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView,
                  let document = view.document, let page = view.currentPage else { return }
            let index = document.index(for: page)
            DispatchQueue.main.async { [weak self, weak view, weak document, weak page] in
                guard let session = self?.session, session.document === document,
                      view?.document === document, view?.currentPage === page, !session.isExporting else { return }
                session.viewerDidChangePage(index)
            }
        }

        @objc func scaleChanged(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in self?.controls?.updateScale() }
        }
    }
}

private struct PDFTranslatedPageView: NSViewRepresentable {
    let data: Data
    @ObservedObject var controls: PDFReaderControls

    final class Coordinator {
        var displayedData: Data?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.autoScales = false
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 5
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.displayedData != data {
            context.coordinator.displayedData = data
            view.document = PDFDocument(data: data)
        }
        controls.attachTranslation(view)
        DispatchQueue.main.async { [weak controls] in controls?.synchronizeTranslation() }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        // PDFReaderControls keeps only a weak reference to this view.
    }
}
