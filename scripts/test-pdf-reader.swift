import AppKit
import CoreText
import PDFKit

@MainActor
private final class FakeTranslator {
    var calls = 0
    var model = "qwen2.5:7b"
    var delay: UInt64 = 0
    var fails = false

    func run(_ text: String, _ model: String) async throws -> String {
        calls += 1
        // Deliberately ignore cancellation: stale results must still be rejected.
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if fails { throw PDFReaderError.message("模拟模型不可用") }
        if text.contains("FIRST") {
            return "第一页译文开始。" + String(repeating: "临床药物研究和病人安全。", count: 500) + "第一页译文结尾。"
        }
        if text.contains("SECOND") { return "第二页译文，验证页码。" }
        return "扫描页面译文。"
    }
}

@MainActor
private final class BackgroundTranslator {
    var calls: [String] = []
    var fails = false
    var delay: UInt64 = 100_000_000

    func run(_ text: String, _ model: String) async throws -> String {
        calls.append(text)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if fails { throw PDFReaderError.message("模拟模型不可用") }
        return "译文：\(text)"
    }
}

@main
struct PDFReaderChecks {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-reader-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let keepFixtures = ProcessInfo.processInfo.environment["SNIP_TEST_KEEP"] == "1"
        defer { if !keepFixtures { try? FileManager.default.removeItem(at: temp) } }
        let input = temp.appendingPathComponent("synthetic-input.pdf")
        try makeFixture(at: input)

        let long = String(repeating: "Bevacizumab 项目 😀 word.\n", count: 200)
        let chunks = PDFTranslationText.chunks(long, maximumLength: 80)
        try require(chunks.joined() == long && chunks.allSatisfy { $0.count <= 80 }, "chunk text lost or split incorrectly")
        try require(PDFTranslationText.chunks("").isEmpty, "empty text produced a chunk")

        var selectedCalls: [String] = []
        let sourceOptions: [PDFTranslationSession.SourceOption] = [
            .init(id: "local-same-model", title: "本地", isLocal: true),
            .init(id: "cloud-same-model", title: "云端", isLocal: false)
        ]
        let sourceSession = PDFTranslationSession(modelName: { "local-same-model" }, translate: { text, model in
            selectedCalls.append(model)
            return "\(model)：\(text)"
        }, prefetchAllPages: false, availableSources: { sourceOptions })
        sourceSession.open(temp.appendingPathComponent("fixture-text.pdf"))
        try await wait(sourceSession)
        try require(sourceSession.translatedParts.joined().contains("local-same-model"), "default source must be local")
        let localCalls = selectedCalls.count
        sourceSession.selectSource("cloud-same-model")
        try await wait(sourceSession)
        try require(sourceSession.translatedParts.joined().contains("cloud-same-model") && selectedCalls.count > localCalls, "switching source must translate with that source")
        let afterCloud = selectedCalls.count
        let sourceOutput = temp.appendingPathComponent("selected-source.pdf")
        sourceSession.export(to: sourceOutput)
        try await wait(sourceSession)
        try require(PDFDocument(url: sourceOutput) != nil && selectedCalls.count > afterCloud && selectedCalls.dropFirst(afterCloud).allSatisfy { $0 == "cloud-same-model" }, "export must use the selected source for all uncached pages")
        let afterCloudExport = selectedCalls.count
        sourceSession.selectSource("local-same-model")
        try require(!sourceSession.isWorking && sourceSession.translatedParts.joined().contains("local-same-model") && selectedCalls.count == afterCloudExport, "switching back must reuse only that source's cache")
        let beforeResize = sourceSession.renderedPageData
        sourceSession.setTranslationFontScale(1.7)
        try require(sourceSession.translationFontScale == 1.7 && sourceSession.renderedPageData != nil && sourceSession.renderedPageData != beforeResize && selectedCalls.count == afterCloudExport, "changing font size must re-render without re-translating")
        sourceSession.cancel()

        guard let fontDocument = PDFDocument(url: input), let fontPage = fontDocument.page(at: 0) else {
            throw PDFReaderError.message("font fixture missing")
        }
        let fontLine = PDFLayoutLine(text: "Reader text block", bounds: CGRect(x: 40, y: 600, width: 350, height: 12))
        let fontLayout = PDFLayoutPage(size: PDFLayoutExtractor.displaySize(for: fontPage), blocks: [PDFLayoutBlock(text: fontLine.text, lines: [fontLine])], usedOCR: false)
        let regular = try PDFLayoutRenderer.render(page: fontPage, layout: fontLayout, translations: ["学习翻译"], fontScale: 1.0)
        let enlarged = try PDFLayoutRenderer.render(page: fontPage, layout: fontLayout, translations: ["学习翻译"], fontScale: 1.5)
        guard let regularDocument = PDFDocument(data: regular.data), let enlargedDocument = PDFDocument(data: enlarged.data),
              let regularPage = regularDocument.page(at: 0), let enlargedPage = enlargedDocument.page(at: 0),
              let regularSelection = regularDocument.findString("学习翻译", withOptions: []).first,
              let enlargedSelection = enlargedDocument.findString("学习翻译", withOptions: []).first else {
            throw PDFReaderError.message("font size sample missing")
        }
        try require(enlargedSelection.bounds(for: enlargedPage).height > regularSelection.bounds(for: regularPage).height * 1.15 && enlarged.overflow.isEmpty, "font slider must visibly enlarge text when blank space is available")

        let abstractLines = [
            PDFLayoutLine(text: "Abstract", bounds: CGRect(x: 210, y: 532, width: 37, height: 9)),
            PDFLayoutLine(text: "Background and Purpose: This is the background", bounds: CGRect(x: 210, y: 517, width: 332, height: 9)),
            PDFLayoutLine(text: "for this clinical study.", bounds: CGRect(x: 210, y: 502, width: 170, height: 9)),
            PDFLayoutLine(text: "Experimental Approach: We performed an analysis", bounds: CGRect(x: 210, y: 487, width: 332, height: 9)),
            PDFLayoutLine(text: "with clinical observations.", bounds: CGRect(x: 210, y: 472, width: 190, height: 9)),
            PDFLayoutLine(text: "Key Results: The findings were significant", bounds: CGRect(x: 210, y: 457, width: 332, height: 9)),
            PDFLayoutLine(text: "Conclusion and Implications: These findings help.", bounds: CGRect(x: 210, y: 442, width: 332, height: 9))
        ]
        let abstractBlocks = PDFLayoutExtractor.blocks(from: abstractLines, pageWidth: 595)
        try require(abstractBlocks.count == 5 && abstractBlocks[1].text.hasPrefix("Background") && abstractBlocks[2].text.hasPrefix("Experimental") && abstractBlocks[3].text.hasPrefix("Key Results") && abstractBlocks[4].text.hasPrefix("Conclusion"), "structured abstract paragraphs must retain their boundaries")

        let indentedLines = [
            PDFLayoutLine(text: "The initial report included patients.", bounds: CGRect(x: 40, y: 650, width: 250, height: 9)),
            PDFLayoutLine(text: "This ensured unique case numbers.", bounds: CGRect(x: 40, y: 636, width: 225, height: 9)),
            PDFLayoutLine(text: "Standard controlled terminology was provided.", bounds: CGRect(x: 55, y: 622, width: 235, height: 9)),
            PDFLayoutLine(text: "including ‘social circumstances’", bounds: CGRect(x: 40, y: 608, width: 90, height: 9)),
            PDFLayoutLine(text: ",", bounds: CGRect(x: 130, y: 608, width: 2, height: 9)),
            PDFLayoutLine(text: "‘surgical and medical procedures’", bounds: CGRect(x: 136, y: 608, width: 124, height: 9)),
            PDFLayoutLine(text: "and products were excluded.", bounds: CGRect(x: 40, y: 594, width: 225, height: 9)),
            PDFLayoutLine(text: "The time-to-onset was recorded.", bounds: CGRect(x: 55, y: 580, width: 235, height: 9)),
            PDFLayoutLine(text: "Patients were placed into two primary", bounds: CGRect(x: 40, y: 566, width: 250, height: 9)),
            PDFLayoutLine(text: "groups: treatments were combined.", bounds: CGRect(x: 40, y: 552, width: 225, height: 9))
        ]
        let paragraphBlocks = PDFLayoutExtractor.blocks(from: indentedLines, pageWidth: 595)
        try require(paragraphBlocks.count == 3 && paragraphBlocks[1].text.hasPrefix("Standard controlled") && paragraphBlocks[2].text.hasPrefix("The time-to-onset"), "indented source paragraphs were merged")
        try require(paragraphBlocks[1].lines.count == 3 && paragraphBlocks[1].text.contains("circumstances’, ‘surgical"), "adjacent fragments on one source line were misplaced")
        try require(paragraphBlocks[2].text.contains("two primary groups:"), "a continuation line with a colon became a new paragraph")
        let separateColumns = PDFLayoutExtractor.blocks(from: [
            PDFLayoutLine(text: "Left column contains independent text.", bounds: CGRect(x: 40, y: 500, width: 245, height: 9)),
            PDFLayoutLine(text: "Right column contains different text.", bounds: CGRect(x: 295, y: 500, width: 245, height: 9))
        ], pageWidth: 595)
        try require(separateColumns.count == 2, "neighbouring columns must not be merged as fragments")

        let paragraphLayout = PDFLayoutPage(size: PDFLayoutExtractor.displaySize(for: fontPage), blocks: paragraphBlocks, usedOCR: false)
        let paragraphRender = try PDFLayoutRenderer.render(page: fontPage, layout: paragraphLayout, translations: ["第一段内容。", "第二段内容。", "第三段内容。"], fontScale: 1)
        guard let paragraphDocument = PDFDocument(data: paragraphRender.data), let paragraphPage = paragraphDocument.page(at: 0),
              let first = paragraphDocument.findString("第一段", withOptions: []).first,
              let second = paragraphDocument.findString("第二段", withOptions: []).first,
              let third = paragraphDocument.findString("第三段", withOptions: []).first else {
            throw PDFReaderError.message("paragraph translation sample missing")
        }
        let firstBox = first.bounds(for: paragraphPage), secondBox = second.bounds(for: paragraphPage), thirdBox = third.bounds(for: paragraphPage)
        try require(firstBox.minY > secondBox.minY && secondBox.minY > thirdBox.minY && secondBox.minX > firstBox.minX + 5 && thirdBox.minX > firstBox.minX + 5, "translated paragraphs must begin on separate indented lines")

        let fake = FakeTranslator()
        let session = PDFTranslationSession(modelName: { fake.model }, translate: fake.run, prefetchAllPages: false)
        session.open(input)
        try await wait(session)
        try require(session.pageCount == 3 && session.translatedParts.joined().contains("第一页译文结尾"), "first page translation")
        session.goToPage(1)
        try await wait(session)
        try require(session.translatedParts.joined().contains("第二页译文"), "second page translation")
        let callsAfterTwoPages = fake.calls
        session.goToPage(0)
        try require(!session.isWorking && fake.calls == callsAfterTwoPages, "returning to a page should reuse its cache")

        let rapidFake = FakeTranslator()
        let rapidSession = PDFTranslationSession(modelName: { rapidFake.model }, translate: rapidFake.run, prefetchAllPages: false)
        rapidSession.open(input)
        try await wait(rapidSession)
        rapidFake.delay = 150_000_000
        let beforeScrolling = rapidFake.calls
        rapidSession.viewerDidChangePage(1)
        try await Task.sleep(nanoseconds: 40_000_000)
        rapidSession.viewerDidChangePage(2)
        try await Task.sleep(nanoseconds: 40_000_000)
        rapidSession.viewerDidChangePage(1)
        try await wait(rapidSession)
        try require(rapidSession.pageIndex == 1 && rapidFake.calls == beforeScrolling + 1, "rapid scrolling restarted an in-flight page")
        try require(rapidSession.pageJump == nil, "scrolling must not request a programmatic jump")
        rapidSession.goToPage(0)
        let jumpID = rapidSession.pageJump?.id
        try require(rapidSession.pageJump?.pageIndex == 0, "page buttons must request a view jump")
        rapidSession.viewerDidChangePage(1)
        try require(rapidSession.pageJump?.id == jumpID, "viewer page changes must not request another jump")

        let searchDocument = PDFDocument(url: input)!
        let readerView = PDFView()
        readerView.document = searchDocument
        let controls = PDFReaderControls()
        controls.attach(readerView)
        controls.setDocument(searchDocument)
        controls.searchText = "original"
        controls.scheduleSearch()
        try await waitForSearch(controls)
        try require(controls.matchCount == 2 && controls.currentMatch == 1, "case-insensitive PDF search")
        controls.nextMatch()
        try require(controls.currentMatch == 2, "search next match")
        controls.previousMatch()
        try require(controls.currentMatch == 1, "search previous match")
        controls.searchText = "not in this document"
        controls.scheduleSearch()
        try await waitForSearch(controls)
        try require(controls.matchCount == 0 && controls.searchStatus == "无匹配文字", "search without results")

        fake.model = "other-local-model"
        session.translateCurrentPage()
        try await wait(session)
        try require(fake.calls == callsAfterTwoPages + 1, "cache must be scoped to the model")
        fake.model = "qwen2.5:7b"
        session.goToPage(2)
        try await wait(session, timeoutSeconds: 90)
        try require(session.usedOCR && !session.translatedParts.isEmpty, "scanned page OCR")

        let oldName = session.fileName
        session.open(temp.appendingPathComponent("missing.pdf"))
        try require(session.fileName == oldName && session.errorMessage != nil, "invalid PDF must preserve the open document")
        session.goToPage(0)
        let original = try Data(contentsOf: input)
        session.export(to: input)
        try require(session.errorMessage != nil && (try Data(contentsOf: input)) == original, "must never overwrite source")

        let output = temp.appendingPathComponent("bilingual.pdf")
        session.export(to: output)
        try await wait(session, timeoutSeconds: 90)
        try require(session.errorMessage == nil, "export failed: \(session.errorMessage ?? "unknown")")
        guard let exported = PDFDocument(url: output) else { throw PDFReaderError.message("export is not a PDF") }
        let exportedText = (0..<exported.pageCount).compactMap { exported.page(at: $0)?.string }.joined(separator: "\n")
            .precomposedStringWithCompatibilityMapping.replacingOccurrences(of: "⻚", with: "页")
            .filter { !$0.isWhitespace }
        try require(exported.pageCount > 3, "long translation should continue onto extra pages")
        try require(exportedText.contains("FIRSTORIGINAL") && exportedText.contains("SECONDORIGINAL"), "original pages missing")
        try require(exportedText.contains("第一页译文开始") && exportedText.contains("第一页译文结尾") && exportedText.contains("第二页译文"), "translation truncated")
        try require((try Data(contentsOf: input)) == original, "source PDF changed")
        // NSSavePanel has already confirmed overwriting an existing destination.
        try Data("previous-output".utf8).write(to: output)
        session.export(to: output)
        try await wait(session, timeoutSeconds: 90)
        try require(session.errorMessage == nil && PDFDocument(url: output) != nil, "confirmed destination replacement")

        let failed = FakeTranslator()
        failed.fails = true
        let failingSession = PDFTranslationSession(modelName: { failed.model }, translate: failed.run, prefetchAllPages: false)
        failingSession.open(input)
        try await wait(failingSession)
        let existing = temp.appendingPathComponent("existing.pdf")
        let sentinel = Data("unchanged-existing-file".utf8)
        try sentinel.write(to: existing)
        failingSession.export(to: existing)
        try await wait(failingSession)
        try require(failingSession.errorMessage != nil && (try Data(contentsOf: existing)) == sentinel, "failed export replaced existing file")

        let slow = FakeTranslator()
        let slowSession = PDFTranslationSession(modelName: { slow.model }, translate: slow.run, prefetchAllPages: false)
        slowSession.open(input)
        try await wait(slowSession)
        slow.delay = 350_000_000
        slowSession.goToPage(1)
        try await Task.sleep(nanoseconds: 30_000_000)
        slowSession.goToPage(0)
        try await Task.sleep(nanoseconds: 450_000_000)
        try require(slowSession.pageIndex == 0 && slowSession.translatedParts.joined().contains("第一页译文"), "late page response changed current page")
        let cancelledOutput = temp.appendingPathComponent("cancelled.pdf")
        slow.model = "export-cancel-model"
        slowSession.export(to: cancelledOutput)
        try await Task.sleep(nanoseconds: 80_000_000)
        slowSession.cancelExport()
        try await Task.sleep(nanoseconds: 500_000_000)
        try require(!FileManager.default.fileExists(atPath: cancelledOutput.path), "cancelled export created output")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix(".snipaitrans-") }
        try require(leftovers.isEmpty, "temporary export files remain")

        let backgroundInput = temp.appendingPathComponent("background-input.pdf")
        try makeBackgroundFixture(at: backgroundInput)
        let background = BackgroundTranslator()
        let automatic = PDFTranslationSession(modelName: { "test-model" }, translate: background.run)
        automatic.open(backgroundInput)
        try await waitForCalls(background, count: 1)
        automatic.goToPage(3)
        try await waitForCompletion(automatic, count: 5)
        try require(background.calls.count > 5, "long page must be translated in multiple chunks")
        try require(background.calls[0].contains("PAGE1") && background.calls[1].contains("PAGE4") && background.calls[2].contains("PAGE5"), "reading page and next page were not prioritized at chunk boundary")
        try require(Set(background.calls).count == background.calls.count, "a completed chunk was translated twice")
        let automaticCalls = background.calls.count
        automatic.goToPage(0)
        try require(!automatic.isWorking && automatic.translatedParts.joined().contains("PAGE1") && background.calls.count == automaticCalls, "revisited page did not use background cache")
        let backgroundOutput = temp.appendingPathComponent("background-export.pdf")
        automatic.export(to: backgroundOutput)
        try await wait(automatic)
        try require(PDFDocument(url: backgroundOutput) != nil && background.calls.count == automaticCalls, "export did not reuse completed background translations")

        let pausedFake = BackgroundTranslator()
        let paused = PDFTranslationSession(modelName: { "test-model" }, translate: pausedFake.run)
        paused.open(backgroundInput)
        try await waitForCalls(pausedFake, count: 1)
        paused.toggleBackgroundTranslation()
        try require(paused.isPaused && !paused.isBackgroundRunning, "pause did not stop background work")
        paused.toggleBackgroundTranslation()
        try await waitForCompletion(paused, count: 5)

        let retryFake = BackgroundTranslator()
        retryFake.fails = true
        let retry = PDFTranslationSession(modelName: { "test-model" }, translate: retryFake.run)
        retry.open(backgroundInput)
        try await wait(retry)
        try require(retry.backgroundError != nil && retry.completedPageCount == 0, "translation error was incorrectly counted as success")
        retryFake.fails = false
        retry.retryBackgroundTranslation()
        try await waitForCompletion(retry, count: 5)

        print("PASS: automatic whole-document translation, priority, partial and completed cache, pause/retry, navigation, PDF search, OCR, export and cancellation")
        if keepFixtures { print("Synthetic fixtures: \(temp.path)") }
    }

    @MainActor
    private static func wait(_ session: PDFTranslationSession, timeoutSeconds: Int = 10) async throws {
        for _ in 0..<(timeoutSeconds * 50) {
            if !session.isWorking { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw PDFReaderError.message("test timed out at page \(session.pageIndex + 1), status: \(session.status)")
    }

    @MainActor
    private static func waitForCalls(_ translator: BackgroundTranslator, count: Int) async throws {
        for _ in 0..<500 {
            if translator.calls.count >= count { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw PDFReaderError.message("background translator did not start")
    }

    @MainActor
    private static func waitForCompletion(_ session: PDFTranslationSession, count: Int) async throws {
        for _ in 0..<1_500 {
            if let error = session.backgroundError { throw PDFReaderError.message(error) }
            if session.completedPageCount == count { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw PDFReaderError.message("background translation timed out: \(session.completedPageCount)/\(count)")
    }

    @MainActor
    private static func waitForSearch(_ controls: PDFReaderControls) async throws {
        for _ in 0..<500 {
            if !controls.isSearching { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw PDFReaderError.message("PDF search timed out")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw PDFReaderError.message(message) }
    }

    @MainActor
    private static func makeFixture(at url: URL) throws {
        let textPDF = url.deletingLastPathComponent().appendingPathComponent("fixture-text.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(textPDF as CFURL, mediaBox: &box, nil) else { throw PDFReaderError.message("fixture context") }
        for label in ["FIRST ORIGINAL synthetic English text.", "SECOND ORIGINAL synthetic English text."] {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 22)]) as CFAttributedString)
            context.textPosition = CGPoint(x: 50, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(url: textPDF) else { throw PDFReaderError.message("fixture pdf") }
        document.page(at: 1)?.rotation = 90
        let image = NSImage(size: NSSize(width: 900, height: 500))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 500).fill()
        ("SCANNED ENGLISH TEXT" as NSString).draw(at: NSPoint(x: 60, y: 250), withAttributes: [.font: NSFont.systemFont(ofSize: 55), .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let imagePage = PDFPage(image: image) else { throw PDFReaderError.message("fixture image page") }
        document.insert(imagePage, at: 2)
        guard document.write(to: url) else { throw PDFReaderError.message("fixture write") }
    }

    @MainActor
    private static func makeBackgroundFixture(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw PDFReaderError.message("background fixture") }
        for page in 1...5 {
            context.beginPDFPage(nil)
            let lineCount = page == 1 ? 40 : 1
            for number in 0..<lineCount {
                let label = "PAGE\(page) LINE\(number) " + String(repeating: "medical translation example ", count: page == 1 ? 4 : 1)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 9)]) as CFAttributedString)
                context.textPosition = CGPoint(x: 40, y: 750 - number * 16)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }
}
