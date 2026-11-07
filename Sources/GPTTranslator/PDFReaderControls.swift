import AppKit
import Combine
import PDFKit

@MainActor
final class PDFReaderControls: ObservableObject {
    @Published var searchText = ""
    @Published private(set) var searchStatus = ""
    @Published private(set) var matchCount = 0
    @Published private(set) var currentMatch = 0
    @Published private(set) var isSearching = false
    @Published private(set) var zoomPercent = 100

    private weak var view: PDFView?
    private weak var translatedView: PDFView?
    private weak var sourceClipView: NSClipView?
    private var scrollObserver: NSObjectProtocol?
    private weak var document: PDFDocument?
    private var searchTask: Task<Void, Never>?
    private var matches: [PDFSelection] = []

    deinit { searchTask?.cancel() }

    func attach(_ view: PDFView) {
        self.view = view
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view else { return }
            self.observeScroll(in: view)
        }
    }

    func attachTranslation(_ view: PDFView) {
        translatedView = view
        synchronizeTranslation()
    }

    func detachTranslation(_ view: PDFView) {
        if translatedView === view { translatedView = nil }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func observeScroll(in view: PDFView) {
        guard let clip = scrollView(in: view)?.contentView, sourceClipView !== clip else { return }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        sourceClipView = clip
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronizeTranslation() }
        }
    }

    /// Follow the source page's visible position in page coordinates, so
    /// different page heights and continuous scrolling do not cause drift.
    func synchronizeTranslation() {
        guard let source = view, let target = translatedView,
              let sourcePage = source.currentPage, let targetPage = target.document?.page(at: 0),
              let sourceScroll = scrollView(in: source), let sourceDoc = sourceScroll.documentView,
              let targetScroll = scrollView(in: target), let targetDoc = targetScroll.documentView else { return }
        observeScroll(in: source)
        if abs(target.scaleFactor - source.scaleFactor) > 0.001 {
            target.autoScales = false
            target.scaleFactor = source.scaleFactor
            target.layoutSubtreeIfNeeded()
        }
        let sourcePoint = source.convert(sourceScroll.contentView.bounds.origin, from: sourceDoc)
        let pagePoint = source.convert(sourcePoint, to: sourcePage)
        let targetSize = targetPage.bounds(for: .cropBox).size
        let transform = sourcePage.pageRef?.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: targetSize), rotate: 0, preserveAspectRatio: true) ?? .identity
        let translatedPoint = pagePoint.applying(transform)
        let pointInTarget = target.convert(translatedPoint, from: targetPage)
        let desiredOrigin = target.convert(pointInTarget, to: targetDoc)
        let clip = targetScroll.contentView
        let proposed = clip.constrainBoundsRect(NSRect(origin: desiredOrigin, size: clip.bounds.size))
        if abs(clip.bounds.origin.x - proposed.origin.x) > 0.5 || abs(clip.bounds.origin.y - proposed.origin.y) > 0.5 {
            clip.scroll(to: proposed.origin)
            targetScroll.reflectScrolledClipView(clip)
        }
    }

    func setDocument(_ document: PDFDocument?) {
        guard self.document !== document else { return }
        searchTask?.cancel()
        self.document = document
        matches = []
        matchCount = 0
        currentMatch = 0
        searchStatus = ""
        isSearching = false
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleSearch()
        }
    }

    func updateScale() {
        guard let view else { return }
        zoomPercent = Int((view.scaleFactor * 100).rounded())
        synchronizeTranslation()
    }

    func zoomIn() {
        guard let view else { return }
        view.autoScales = false
        view.zoomIn(nil)
        updateScale()
    }

    func zoomOut() {
        guard let view else { return }
        view.autoScales = false
        view.zoomOut(nil)
        updateScale()
    }

    func fitWidth() {
        guard let view else { return }
        view.autoScales = true
        updateScale()
    }

    func scheduleSearch() {
        searchTask?.cancel()
        matches = []
        matchCount = 0
        currentMatch = 0
        view?.clearSelection()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document, !query.isEmpty else {
            isSearching = false
            searchStatus = ""
            return
        }
        isSearching = true
        searchStatus = "搜索中…"
        searchTask = Task { @MainActor [weak self, weak document] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, let document, !Task.isCancelled, self.document === document else { return }
            var found: [PDFSelection] = []
            var capped = false
            for index in 0..<document.pageCount {
                guard !Task.isCancelled, self.document === document else { return }
                if let page = document.page(at: index), let content = page.string as NSString? {
                    var location = 0
                    while location < content.length {
                        let remaining = NSRange(location: location, length: content.length - location)
                        let range = content.range(of: query, options: [.caseInsensitive], range: remaining)
                        guard range.location != NSNotFound, range.length > 0 else { break }
                        if let selection = page.selection(for: range) { found.append(selection) }
                        location = NSMaxRange(range)
                        if found.count >= 10_000 { capped = true; break }
                    }
                }
                if capped { break }
                if index.isMultiple(of: 10) { self.searchStatus = "搜索中 \(index + 1)/\(document.pageCount)…" }
                await Task.yield()
            }
            guard !Task.isCancelled, self.document === document else { return }
            self.matches = found
            self.matchCount = found.count
            self.isSearching = false
            if found.isEmpty {
                self.searchStatus = "无匹配文字"
            } else {
                self.currentMatch = 1
                self.searchStatus = capped ? "结果过多，仅显示前 10000 处" : ""
                self.showMatch(at: 0)
            }
            self.searchTask = nil
        }
    }

    func nextMatch() {
        guard !matches.isEmpty else { return }
        showMatch(at: currentMatch % matches.count)
    }

    func previousMatch() {
        guard !matches.isEmpty else { return }
        showMatch(at: (currentMatch - 2 + matches.count) % matches.count)
    }

    func stop() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        sourceClipView = nil
    }

    private func showMatch(at index: Int) {
        guard matches.indices.contains(index), let view else { return }
        currentMatch = index + 1
        let selection = matches[index]
        view.setCurrentSelection(selection, animate: true)
        view.go(to: selection)
    }
}
