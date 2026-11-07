import AppKit
import CoreText
import PDFKit

/// Writes a new document. Original pages are drawn as PDF vectors; each sheet
/// shows the source page on the left and one part of its translation on the right.
@MainActor
final class PDFBilingualWriter {
    private let context: CGContext
    private var finished = false

    init(url: URL) throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw PDFReaderError.message("无法创建对照 PDF。")
        }
        self.context = context
    }

    func append(page: PDFPage, pageNumber: Int, translatedPage: Data, overflow: [String]) throws {
        guard let translatedDocument = PDFDocument(data: translatedPage),
              let translated = translatedDocument.page(at: 0)?.pageRef else {
            throw PDFReaderError.message("无法读取译文页面。")
        }
        defer { withExtendedLifetime(translatedDocument) {} }
        let source = page.bounds(for: .cropBox)
        let sideways = page.rotation == 90 || page.rotation == 270
        let width = max(1, sideways ? source.height : source.width)
        let height = max(1, sideways ? source.width : source.height)
        let sheetHeight = min(max(height + 60, 600), 1200)
        let columnWidth = min(max((sheetHeight - 60) * width / height + 40, 350), 1000)
        var mediaBox = CGRect(x: 0, y: 0, width: columnWidth * 2, height: sheetHeight)
        let sourceRect = CGRect(x: 20, y: 20, width: columnWidth - 40, height: sheetHeight - 70)
        let translatedRect = CGRect(x: columnWidth + 20, y: 20, width: columnWidth - 40, height: sheetHeight - 70)
        let overflowText = overflow.joined(separator: "\n\n")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let text = NSAttributedString(string: overflowText, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        var offset = 0
        var sheet = 0
        repeat {
            let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            context.setStrokeColor(NSColor.lightGray.withAlphaComponent(0.6).cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: columnWidth, y: 18))
            context.addLine(to: CGPoint(x: columnWidth, y: sheetHeight - 18))
            context.strokePath()
            drawHeader("原文 · 第 \(pageNumber) 页", at: CGPoint(x: 20, y: sheetHeight - 30))
            let suffix = sheet == 0 ? "" : " · 续 \(sheet + 1)"
            drawHeader("中文译文 · 第 \(pageNumber) 页\(suffix)", at: CGPoint(x: columnWidth + 25, y: sheetHeight - 30))
            if let sourcePage = page.pageRef {
                context.saveGState()
                context.clip(to: sourceRect)
                context.concatenate(sourcePage.getDrawingTransform(.cropBox, rect: sourceRect, rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(sourcePage)
                if page.displaysAnnotations {
                    for annotation in page.annotations { annotation.draw(with: .cropBox, in: context) }
                }
                context.restoreGState()
            } else {
                context.saveGState()
                context.translateBy(x: sourceRect.minX, y: sourceRect.minY)
                context.scaleBy(x: sourceRect.width / width, y: sourceRect.height / height)
                page.draw(with: .cropBox, to: context)
                context.restoreGState()
            }
            if sheet == 0 {
                context.saveGState()
                context.clip(to: translatedRect)
                context.concatenate(translated.getDrawingTransform(.cropBox, rect: translatedRect, rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(translated)
                context.restoreGState()
            } else {
                let path = CGPath(rect: translatedRect.insetBy(dx: 5, dy: 5), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
                let visible = CTFrameGetVisibleStringRange(frame).length
                guard visible > 0 else {
                    context.endPDFPage()
                    throw PDFReaderError.message("译文排版失败。")
                }
                context.textMatrix = .identity
                CTFrameDraw(frame, context)
                offset += visible
            }
            context.endPDFPage()
            sheet += 1
        } while offset < text.length
    }

    func finish() {
        guard !finished else { return }
        context.closePDF()
        finished = true
    }

    private func drawHeader(_ string: String, at point: CGPoint) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.darkGray
        ]) as CFAttributedString)
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
