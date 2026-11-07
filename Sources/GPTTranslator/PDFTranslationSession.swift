import AppKit
import Combine
import PDFKit
import Vision

/// Splits long pages without dropping text or splitting words when a nearby
/// whitespace boundary is available. A page is always translated in order.
enum PDFTranslationText {
    static func chunks(_ text: String, maximumLength: Int = 1_200) -> [String] {
        guard !text.isEmpty, maximumLength > 0 else { return [] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let limit = text.index(start, offsetBy: maximumLength, limitedBy: text.endIndex) ?? text.endIndex
            var end = limit
            if limit < text.endIndex {
                let minimum = text.index(start, offsetBy: maximumLength / 2, limitedBy: limit) ?? start
                if let boundary = text[minimum..<limit].lastIndex(where: { $0.isWhitespace }) {
                    end = text.index(after: boundary)
                }
            }
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }
}

enum PDFPageOCR {
    static func recognize(_ image: CGImage, pageSize: CGSize) throws -> [PDFLayoutLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesCPUOnly = true
        // Do not autocorrect unfamiliar drug and gene names into common words.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return PDFLayoutLine(text: text, bounds: CGRect(x: box.minX * pageSize.width, y: box.minY * pageSize.height,
                                                            width: box.width * pageSize.width, height: box.height * pageSize.height))
        }
    }
}

@MainActor
final class PDFTranslationSession: ObservableObject {
    typealias Translator = @MainActor (String, String) async throws -> String
    typealias BatchTranslator = @MainActor ([String], String) async throws -> [String]
    typealias ModelName = @MainActor () -> String

    struct SourceOption: Identifiable, Equatable {
        let id: String
        let title: String
        let isLocal: Bool
    }

    struct PageJump: Equatable {
        let id = UUID()
        let pageIndex: Int
    }

    @Published private(set) var document: PDFDocument?
    @Published private(set) var fileName = ""
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageJump: PageJump?
    @Published private(set) var translatedParts: [String] = []
    @Published private(set) var status = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isExporting = false
    @Published private(set) var usedOCR = false
    @Published private(set) var activeModel = ""
    @Published private(set) var completedPageCount = 0
    @Published private(set) var isBackgroundRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var backgroundError: String?
    @Published private(set) var exportMessage: String?
    @Published private(set) var renderedPageData: Data?
    @Published private(set) var layoutOverflowCount = 0
    @Published private(set) var layoutError: String?
    @Published private(set) var selectedSourceID: String?
    @Published private(set) var translationFontScale: CGFloat = 1.35

    private struct CacheKey: Hashable {
        let page: Int
        let model: String
    }
    private struct CachedPage {
        let parts: [String]
        let usedOCR: Bool
        let isEmpty: Bool
        let layout: PDFLayoutPage
    }
    private struct PartialPage {
        let layout: PDFLayoutPage
        var parts: [String]
    }
    private var cache: [CacheKey: CachedPage] = [:]
    private var partialPages: [CacheKey: PartialPage] = [:]
    private var translationTask: Task<Void, Never>?
    private var generation = UUID()
    private var workerPage: Int?
    private var workerActivity = ""
    private var failedPage: Int?
    private var renderedKey: CacheKey?
    private var scopedURL: URL?
    private var documentURL: URL?
    private let modelName: ModelName
    private let translate: Translator
    private let translateBatch: BatchTranslator?
    private let availableSources: @MainActor () -> [SourceOption]
    private let prefetchAllPages: Bool

    init(modelName: @escaping ModelName, translate: @escaping Translator, translateBatch: BatchTranslator? = nil, prefetchAllPages: Bool = true, availableSources: @escaping @MainActor () -> [SourceOption] = { [] }) {
        self.modelName = modelName
        self.translate = translate
        self.translateBatch = translateBatch
        self.availableSources = availableSources
        self.prefetchAllPages = prefetchAllPages
    }

    deinit {
        translationTask?.cancel()
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    var pageCount: Int { document?.pageCount ?? 0 }
    var sourceOptions: [SourceOption] { availableSources() }
    var selectedSourceTitle: String { sourceOptions.first(where: { $0.id == (selectedSourceID ?? modelName()) })?.title ?? activeModel }
    private func requestedModel() -> String { (selectedSourceID ?? modelName()).trimmingCharacters(in: .whitespacesAndNewlines) }

    func selectSource(_ id: String) {
        guard !isExporting, sourceOptions.contains(where: { $0.id == id }), id != requestedModel() else { return }
        selectedSourceID = id
        isPaused = false
        synchronizeModel()
        refreshVisiblePage()
        startBackgroundIfNeeded()
    }

    func setTranslationFontScale(_ scale: CGFloat) {
        guard !isExporting else { return }
        let value = min(max(scale, 0.8), 1.8)
        guard abs(value - translationFontScale) > 0.01 else { return }
        translationFontScale = value
        renderedKey = nil
        refreshVisiblePage()
    }

    /// An invalid or locked file never replaces the document already open.
    func open(_ url: URL) {
        let accessGranted = url.startAccessingSecurityScopedResource()
        guard let newDocument = PDFDocument(url: url), !newDocument.isLocked, newDocument.pageCount > 0 else {
            if accessGranted { url.stopAccessingSecurityScopedResource() }
            errorMessage = "无法打开此 PDF。请检查文件是否损坏或需要密码。"
            return
        }
        guard newDocument.allowsCopying else {
            if accessGranted { url.stopAccessingSecurityScopedResource() }
            errorMessage = "此 PDF 限制提取文字，请先使用有权处理的文件。"
            return
        }
        cancel()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = accessGranted ? url : nil
        documentURL = url
        pageJump = nil
        document = newDocument
        fileName = url.lastPathComponent
        pageIndex = 0
        cache.removeAll()
        partialPages.removeAll()
        completedPageCount = 0
        isPaused = false
        backgroundError = nil
        failedPage = nil
        exportMessage = nil
        renderedPageData = nil
        renderedKey = nil
        layoutOverflowCount = 0
        layoutError = nil
        translatedParts = []
        errorMessage = nil
        translateCurrentPage()
    }

    func goToPage(_ index: Int) {
        guard index >= 0, index < pageCount, !isExporting else { return }
        pageJump = PageJump(pageIndex: index)
        guard index != pageIndex else { return }
        showPage(index)
    }

    /// Scrolling never cancels an in-flight chunk. At the next chunk boundary,
    /// the worker prioritizes the page being read and its next two pages.
    func viewerDidChangePage(_ index: Int) {
        guard index >= 0, index < pageCount, index != pageIndex, !isExporting else { return }
        showPage(index)
    }

    private func showPage(_ index: Int) {
        pageIndex = index
        exportMessage = nil
        synchronizeModel()
        refreshVisiblePage()
        startBackgroundIfNeeded()
    }

    func resumeIfNeeded() {
        guard document != nil, !isExporting else { return }
        synchronizeModel()
        startBackgroundIfNeeded()
    }

    func cancel() {
        generation = UUID()
        translationTask?.cancel()
        translationTask = nil
        isWorking = false
        isExporting = false
        isBackgroundRunning = false
        workerPage = nil
    }

    func cancelExport() {
        guard isExporting else { return }
        cancel()
        exportMessage = "已取消导出，未生成对照文件。"
        refreshVisiblePage()
        startBackgroundIfNeeded()
    }

    /// Translate each page in order, reuse completed page translations, and only
    /// replace the destination once the complete output was written successfully.
    func export(to destination: URL) {
        guard let document, let documentURL else { return }
        guard destination.standardizedFileURL.resolvingSymlinksInPath() !=
                documentURL.standardizedFileURL.resolvingSymlinksInPath() else {
            errorMessage = "请选择新的文件名，不能覆盖原始 PDF。"
            return
        }
        cancel()
        let currentGeneration = generation
        let model = requestedModel()
        let fontScale = translationFontScale
        guard !model.isEmpty else {
            errorMessage = "请先选择可用的翻译源。"
            return
        }
        activeModel = model
        errorMessage = nil
        exportMessage = nil
        updateCompletedPageCount()
        isWorking = true
        isExporting = true
        status = "正在准备导出…"
        translationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let accessGranted = destination.startAccessingSecurityScopedResource()
            defer { if accessGranted { destination.stopAccessingSecurityScopedResource() } }
            let temporaryURL = destination.deletingLastPathComponent()
                .appendingPathComponent(".snipaitrans-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            do {
                let writer = try PDFBilingualWriter(url: temporaryURL)
                defer { writer.finish() }
                for index in 0..<document.pageCount {
                    try Task.checkCancellation()
                    guard self.generation == currentGeneration, let page = document.page(at: index) else { return }
                    let key = CacheKey(page: index, model: model)
                    while self.cache[key] == nil {
                        self.status = "正在翻译第 \(index + 1)/\(document.pageCount) 页…"
                        try await self.processPageStep(key, generation: currentGeneration)
                    }
                    guard let translated = self.cache[key] else { throw CancellationError() }
                    self.status = "正在排版第 \(index + 1)/\(document.pageCount) 页…"
                    let rendered = try PDFLayoutRenderer.render(page: page, layout: translated.layout, translations: translated.parts, fontScale: fontScale)
                    try writer.append(page: page, pageNumber: index + 1, translatedPage: rendered.data, overflow: rendered.overflow)
                    await Task.yield()
                }
                try Task.checkCancellation()
                guard self.generation == currentGeneration else { return }
                writer.finish()
                let files = FileManager.default
                if files.fileExists(atPath: destination.path) {
                    _ = try files.replaceItemAt(destination, withItemAt: temporaryURL)
                } else {
                    try files.moveItem(at: temporaryURL, to: destination)
                }
                self.isExporting = false
                self.translationTask = nil
                self.exportMessage = "已导出：\(destination.lastPathComponent)"
                self.refreshVisiblePage()
                self.startBackgroundIfNeeded()
            } catch {
                guard self.generation == currentGeneration else { return }
                self.isExporting = false
                self.translationTask = nil
                if error is CancellationError { return }
                self.exportMessage = "导出失败：\(error.localizedDescription)"
                self.errorMessage = self.exportMessage
                self.refreshVisiblePage()
                self.startBackgroundIfNeeded()
            }
        }
    }

    private func pageLayout(_ page: PDFPage) async throws -> PDFLayoutPage {
        let embeddedText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let size = PDFLayoutExtractor.displaySize(for: page)
        let letterCount = embeddedText.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        if letterCount >= 3 {
            let lines = PDFLayoutExtractor.textLines(for: page)
            guard !lines.isEmpty else { throw PDFReaderError.message("无法定位页面文字，请尝试其他 PDF 文件。") }
            return PDFLayoutPage(size: size, blocks: PDFLayoutExtractor.blocks(from: lines, pageWidth: size.width), usedOCR: false)
        }
        // Scans may have only an embedded page number. OCR also supplies
        // bounding boxes so recognized words retain their approximate position.
        let longest = max(size.width, size.height, 1)
        let scale = min(2.0, 3000.0 / longest)
        let image = page.thumbnail(of: NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale)), for: .cropBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PDFReaderError.message("无法读取扫描页面。")
        }
        let lines = try await Task.detached(priority: .userInitiated) {
            try PDFPageOCR.recognize(cgImage, pageSize: size)
        }.value
        return PDFLayoutPage(size: size, blocks: PDFLayoutExtractor.blocks(from: lines, pageWidth: size.width), usedOCR: !lines.isEmpty)
    }

    func translateCurrentPage(force: Bool = false) {
        guard document != nil, !isExporting else { return }
        synchronizeModel()
        if force {
            // Invalidate the in-flight result before clearing the current page.
            cancel()
            let key = CacheKey(page: pageIndex, model: activeModel)
            cache.removeValue(forKey: key)
            partialPages.removeValue(forKey: key)
            updateCompletedPageCount()
        }
        isPaused = false
        failedPage = nil
        backgroundError = nil
        exportMessage = nil
        refreshVisiblePage()
        startBackgroundIfNeeded()
    }

    func toggleBackgroundTranslation() {
        guard document != nil, !isExporting else { return }
        if isPaused {
            isPaused = false
            backgroundError = nil
            failedPage = nil
            synchronizeModel()
            startBackgroundIfNeeded()
        } else {
            isPaused = true
            cancel()
            refreshVisiblePage()
        }
    }

    func retryBackgroundTranslation() {
        guard document != nil, !isExporting else { return }
        backgroundError = nil
        failedPage = nil
        isPaused = false
        synchronizeModel()
        startBackgroundIfNeeded()
    }

    private func synchronizeModel() {
        let requested = requestedModel()
        guard requested != activeModel else { return }
        cancel()
        activeModel = requested
        backgroundError = nil
        failedPage = nil
        updateCompletedPageCount()
    }

    private func updateCompletedPageCount() {
        completedPageCount = (0..<pageCount).reduce(0) { count, index in
            count + (cache[CacheKey(page: index, model: activeModel)] == nil ? 0 : 1)
        }
    }

    private func nextUnfinishedPage() -> Int? {
        guard pageCount > 0 else { return nil }
        let priority = [pageIndex, pageIndex + 1, pageIndex + 2]
        let candidates = prefetchAllPages ? priority + Array(0..<pageCount) : [pageIndex]
        return candidates.first { index in
            index >= 0 && index < pageCount && cache[CacheKey(page: index, model: activeModel)] == nil
        }
    }

    private func startBackgroundIfNeeded() {
        guard document != nil, !isExporting, !isPaused, !isBackgroundRunning, backgroundError == nil else {
            refreshVisiblePage()
            return
        }
        guard !activeModel.isEmpty else {
            backgroundError = "请先选择可用的翻译源。"
            refreshVisiblePage()
            return
        }
        guard nextUnfinishedPage() != nil else {
            refreshVisiblePage()
            return
        }
        let currentGeneration = generation
        isBackgroundRunning = true
        refreshVisiblePage()
        translationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                while let index = self.nextUnfinishedPage() {
                    try Task.checkCancellation()
                    guard self.generation == currentGeneration else { throw CancellationError() }
                    self.workerPage = index
                    try await self.processPageStep(CacheKey(page: index, model: self.activeModel), generation: currentGeneration)
                    await Task.yield()
                }
                guard self.generation == currentGeneration else { return }
                self.isBackgroundRunning = false
                self.workerPage = nil
                self.translationTask = nil
                self.refreshVisiblePage()
            } catch {
                guard self.generation == currentGeneration else { return }
                self.isBackgroundRunning = false
                self.translationTask = nil
                if !(error is CancellationError) {
                    self.failedPage = self.workerPage
                    let prefix = self.workerPage.map { "第 \($0 + 1) 页翻译失败" } ?? "全文翻译失败"
                    self.backgroundError = "\(prefix)：\(error.localizedDescription)"
                }
                self.workerPage = nil
                self.refreshVisiblePage()
            }
        }
    }

    /// One extraction or model call at a time. Partial results survive page
    /// switches, export, and pauses; only successful complete pages count.
    private func processPageStep(_ key: CacheKey, generation expected: UUID) async throws {
        try Task.checkCancellation()
        guard generation == expected, let page = document?.page(at: key.page) else { throw CancellationError() }
        if partialPages[key] == nil {
            workerActivity = (page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
                ? "正在本机识别扫描页面…" : "正在读取页面…"
            refreshVisiblePage()
            let layout = try await pageLayout(page)
            try Task.checkCancellation()
            guard generation == expected else { throw CancellationError() }
            if layout.blocks.isEmpty {
                cache[key] = CachedPage(parts: ["（本页未识别到可翻译的文字）"], usedOCR: layout.usedOCR, isEmpty: true, layout: layout)
                updateCompletedPageCount()
            } else {
                partialPages[key] = PartialPage(layout: layout, parts: [])
            }
            refreshVisiblePage()
            return
        }
        guard var partial = partialPages[key], partial.parts.count < partial.layout.blocks.count else { return }
        let index = partial.parts.count
        var end = index + 1
        var total = partial.layout.blocks[index].text.count
        // Short table cells and captions are particularly prone to being
        // reassigned by a small local model. Translate those independently.
        if translateBatch != nil, total >= 120 {
            while end < partial.layout.blocks.count, end - index < 6,
                  partial.layout.blocks[end].text.count >= 120,
                  total + partial.layout.blocks[end].text.count <= 1_050 {
                total += partial.layout.blocks[end].text.count
                end += 1
            }
        }
        workerActivity = "正在翻译本页 \(index + 1)/\(partial.layout.blocks.count)…"
        refreshVisiblePage()
        let source = partial.layout.blocks[index..<end].map(\.text)
        let result: [String]
        if let translateBatch, source.count > 1 {
            result = try await translateBatch(source, key.model)
        } else {
            result = [try await translate(source[0], key.model)]
        }
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
        guard result.count == source.count, result.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw PDFReaderError.message("本地模型未返回完整的分段译文，请重试。")
        }
        partial.parts.append(contentsOf: result)
        if partial.parts.count == partial.layout.blocks.count {
            cache[key] = CachedPage(parts: partial.parts, usedOCR: partial.layout.usedOCR, isEmpty: false, layout: partial.layout)
            partialPages.removeValue(forKey: key)
            updateCompletedPageCount()
        } else {
            partialPages[key] = partial
        }
        refreshVisiblePage()
    }

    private func refreshVisiblePage() {
        guard !isExporting else { return }
        let key = CacheKey(page: pageIndex, model: activeModel)
        if let saved = cache[key] {
            translatedParts = saved.parts
            usedOCR = saved.usedOCR
            status = saved.isEmpty ? "本页无可识别文字" : (saved.usedOCR ? "本页已翻译 · OCR 识别" : "本页已翻译")
            isWorking = false
            if renderedKey != key, let page = document?.page(at: pageIndex) {
                do {
                    let rendered = try PDFLayoutRenderer.render(page: page, layout: saved.layout, translations: saved.parts, fontScale: translationFontScale)
                    renderedPageData = rendered.data
                    layoutOverflowCount = rendered.overflow.count
                    layoutError = nil
                    renderedKey = key
                } catch {
                    renderedPageData = nil
                    layoutError = "原版式排版失败，可切换文字模式查看完整译文：\(error.localizedDescription)"
                }
            }
        } else {
            let partial = partialPages[key]
            translatedParts = partial?.parts ?? []
            usedOCR = partial?.layout.usedOCR ?? false
            renderedKey = nil
            renderedPageData = nil
            layoutOverflowCount = 0
            layoutError = nil
            isWorking = isBackgroundRunning && !isPaused && backgroundError == nil
            if isPaused {
                status = "全文翻译已暂停"
            } else if backgroundError != nil {
                status = "全文翻译已停止，请重试"
            } else if isBackgroundRunning {
                status = workerPage == pageIndex ? workerActivity : "等待当前任务完成，随后翻译本页…"
            } else {
                status = "准备翻译本页…"
            }
        }
        errorMessage = (failedPage == pageIndex || (failedPage == nil && backgroundError != nil)) ? backgroundError : nil
    }
}

enum PDFReaderError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
