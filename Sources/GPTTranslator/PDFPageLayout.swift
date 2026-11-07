import AppKit
import CoreText
import PDFKit

/// Geometry is stored in displayed-page coordinates, with the origin at the bottom left.
struct PDFLayoutLine: Sendable {
    let text: String
    let bounds: CGRect
}

struct PDFLayoutBlock {
    let text: String
    let lines: [PDFLayoutLine]
    var bounds: CGRect { lines.reduce(CGRect.null) { $0.union($1.bounds) } }
}

struct PDFLayoutPage {
    let size: CGSize
    let blocks: [PDFLayoutBlock]
    let usedOCR: Bool
}

@MainActor
enum PDFLayoutExtractor {
    static func displaySize(for page: PDFPage) -> CGSize {
        let source = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation) % 180 == 90
        return CGSize(width: max(1, rotated ? source.height : source.width),
                      height: max(1, rotated ? source.width : source.height))
    }

    static func textLines(for page: PDFPage) -> [PDFLayoutLine] {
        let source = page.bounds(for: .cropBox)
        let size = displaySize(for: page)
        let destination = CGRect(origin: .zero, size: size)
        guard let selection = page.selection(for: source) else { return [] }
        let transform = page.pageRef?.getDrawingTransform(.cropBox, rect: destination, rotate: 0, preserveAspectRatio: true) ?? .identity
        return selection.selectionsByLine().flatMap { line -> [PDFLayoutLine] in
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let bounds = line.bounds(for: page).applying(transform).intersection(destination)
            guard !text.isEmpty, !bounds.isNull, bounds.width > 1, bounds.height > 1 else { return [] }
            // PDFKit can merge separate table cells or page-header fragments
            // into one line. Split unusually sparse lines at their visual gaps,
            // so a mask cannot erase a border or move text to another cell.
            guard bounds.width / CGFloat(max(1, text.count)) > bounds.height * 0.65,
                  let pageText = page.string as NSString?,
                  let regex = try? NSRegularExpression(pattern: "\\S+") else {
                return [PDFLayoutLine(text: text, bounds: bounds)]
            }
            var words: [PDFLayoutLine] = []
            for rangeIndex in 0..<line.numberOfTextRanges(on: page) {
                let range = line.range(at: rangeIndex, on: page)
                guard range.location != NSNotFound, NSMaxRange(range) <= pageText.length else { continue }
                for match in regex.matches(in: pageText as String, range: range) {
                    guard let word = page.selection(for: match.range) else { continue }
                    let rect = word.bounds(for: page).applying(transform).intersection(destination)
                    guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
                    words.append(PDFLayoutLine(text: pageText.substring(with: match.range), bounds: rect))
                }
            }
            guard words.count > 1 else { return [PDFLayoutLine(text: text, bounds: bounds)] }
            var fragments: [[PDFLayoutLine]] = []
            for word in words {
                if let previous = fragments.last?.last,
                   word.bounds.minX - previous.bounds.maxX <= max(10, bounds.height * 1.25) {
                    fragments[fragments.count - 1].append(word)
                } else {
                    fragments.append([word])
                }
            }
            guard fragments.count > 1 else { return [PDFLayoutLine(text: text, bounds: bounds)] }
            return fragments.map { words in
                PDFLayoutLine(text: words.map(\.text).joined(separator: " "),
                              bounds: words.reduce(CGRect.null) { $0.union($1.bounds) })
            }
        }
    }

    static func blocks(from lines: [PDFLayoutLine], pageWidth: CGFloat) -> [PDFLayoutBlock] {
        let sorted = coalesceLineFragments(lines, pageWidth: pageWidth).sorted {
            let diff = $0.bounds.midY - $1.bounds.midY
            return abs(diff) > 2 ? diff > 0 : $0.bounds.minX < $1.bounds.minX
        }
        var groups: [[PDFLayoutLine]] = []
        for line in sorted {
            let letters = line.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            let isURL = line.text.contains("://") || line.text.lowercased().hasPrefix("doi:") || line.text.contains("@")
            let stretchedHeader = line.bounds.width > pageWidth * 0.75 && line.text.count < 25
            // Preserve formulas, numbers, URLs, and sparse headers verbatim.
            guard letters >= 3, !isURL, !stretchedHeader else { continue }
            var best: Int?
            var bestGap = CGFloat.greatestFiniteMagnitude
            for index in groups.indices {
                guard let previous = groups[index].last else { continue }
                let gap = previous.bounds.minY - line.bounds.maxY
                let maxHeight = max(previous.bounds.height, line.bounds.height)
                let overlap = min(previous.bounds.maxX, line.bounds.maxX) - max(previous.bounds.minX, line.bounds.minX)
                let minWidth = min(previous.bounds.width, line.bounds.width)
                let sameColumn = overlap > minWidth * 0.45 && abs(previous.bounds.minX - line.bounds.minX) < max(18, pageWidth * 0.04)
                let similarSize = maxHeight < min(previous.bounds.height, line.bounds.height) * 1.65
                let normalGap = gap >= -maxHeight * 0.35 && gap <= max(5, maxHeight * 1.3)
                let isParagraph = max(previous.bounds.width, line.bounds.width) > pageWidth * 0.16
                let currentLength = groups[index].reduce(0) { $0 + $1.text.count }
                // Structured abstracts frequently have no blank vertical gap:
                // "Methods:" and "Results:" begin immediately on the next
                // baseline. Treat their label as a paragraph boundary.
                let beginsLabel = startsParagraphLabel(line.text) && (endsSentence(previous.text) || startsStructuredAbstractLabel(line.text))
                let endsShortParagraph = previous.bounds.width < line.bounds.width * 0.78 &&
                    previous.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".")
                let standaloneHeading = previous.text.count < 24 && previous.bounds.width < line.bounds.width * 0.5
                let columnLeft = groups[index].map(\.bounds.minX).min() ?? previous.bounds.minX
                let indentedParagraph = startsIndentedParagraph(line, after: previous, columnLeft: columnLeft)
                if sameColumn && similarSize && normalGap && isParagraph && !beginsLabel && !endsShortParagraph && !standaloneHeading && !indentedParagraph && currentLength + line.text.count < 1_050 && gap < bestGap {
                    best = index
                    bestGap = gap
                }
            }
            if let best { groups[best].append(line) } else { groups.append([line]) }
        }
        return groups.map { lines in
            let text = lines.map(\.text).joined(separator: " ")
            return PDFLayoutBlock(text: text, lines: lines)
        }
    }

    /// PDFKit sometimes returns the words on one baseline as multiple
    /// selections (for example, a citation or quoted phrase). Reunite only
    /// nearby fragments; the wider gaps between columns and table cells remain.
    private static func coalesceLineFragments(_ lines: [PDFLayoutLine], pageWidth: CGFloat) -> [PDFLayoutLine] {
        let ordered = lines.sorted {
            if abs($0.bounds.midY - $1.bounds.midY) > 2 { return $0.bounds.midY > $1.bounds.midY }
            return $0.bounds.minX < $1.bounds.minX
        }
        var result: [PDFLayoutLine] = []
        for line in ordered {
            var match: Int?
            for index in result.indices.reversed() {
                let previous = result[index]
                let vertical = abs(previous.bounds.midY - line.bounds.midY)
                let gap = line.bounds.minX - previous.bounds.maxX
                let height = min(previous.bounds.height, line.bounds.height)
                let likelyColumns = previous.bounds.width > pageWidth * 0.2 && line.bounds.width > pageWidth * 0.2 &&
                    line.bounds.minX - previous.bounds.minX > pageWidth * 0.25
                guard vertical <= max(2, height * 0.4), gap >= -1,
                      gap <= min(12, max(5, height * 1.4)), !likelyColumns else { continue }
                match = index
                break
            }
            if let index = match {
                let previous = result[index]
                let punctuation = CharacterSet(charactersIn: ",.;:!?)]}，。；：！？）】」』")
                let tight = line.text.unicodeScalars.first.map { punctuation.contains($0) } ?? false
                let joined = previous.text + (tight ? "" : " ") + line.text
                result[index] = PDFLayoutLine(text: joined, bounds: previous.bounds.union(line.bounds))
            } else {
                result.append(line)
            }
        }
        return result
    }

    /// Recognize first-line indents only after the preceding sentence ended,
    /// rather than mistaking a column change or mid-sentence line for a break.
    fileprivate static func startsIndentedParagraph(_ line: PDFLayoutLine, after previous: PDFLayoutLine, columnLeft: CGFloat) -> Bool {
        let indent = line.bounds.minX - columnLeft
        let threshold = max(6, min(line.bounds.height, previous.bounds.height) * 0.8)
        guard indent >= threshold else { return false }
        return endsSentence(previous.text)
    }

    fileprivate static func endsSentence(_ text: String) -> Bool {
        let ending = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]}）】」』"))
        guard let last = ending.unicodeScalars.last else { return false }
        return CharacterSet(charactersIn: ".!?。！？").contains(last)
    }

    fileprivate static func startsParagraphLabel(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let label = text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 48, label.split(whereSeparator: \.isWhitespace).count <= 6 else { return false }
        return label.unicodeScalars.allSatisfy {
            CharacterSet.letters.union(.whitespaces).union(CharacterSet(charactersIn: "-/&()")).contains($0)
        }
    }

    fileprivate static func startsStructuredAbstractLabel(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let label = text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["background", "background and purpose", "background and objectives", "objective", "objectives", "purpose", "methods", "methodology", "materials and methods", "experimental approach", "results", "key results", "findings", "conclusion", "conclusions", "conclusion and implications", "conclusions and implications"].contains(label)
    }
}

struct PDFRenderedTranslation {
    let data: Data
    let overflow: [String]
}

private struct PDFRenderGroup {
    var blocks: [PDFLayoutBlock]
    var translations: [String]
    var bounds: CGRect { blocks.reduce(CGRect.null) { $0.union($1.bounds) } }
}

@MainActor
enum PDFLayoutRenderer {
    /// Lay out neighbouring text blocks together so a long paragraph split
    /// for model requests does not leave a blank gap after each translated part.
    private static func renderGroups(layout: PDFLayoutPage, translations: [String]) -> [PDFRenderGroup] {
        var groups: [PDFRenderGroup] = []
        for (index, block) in layout.blocks.enumerated() where index < translations.count {
            let text = translations[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let first = block.lines.first else { continue }
            var match: Int?
            var bestGap = CGFloat.greatestFiniteMagnitude
            for i in groups.indices {
                guard let previous = groups[i].blocks.last, let last = previous.lines.last else { continue }
                let gap = last.bounds.minY - first.bounds.maxY
                let h = max(last.bounds.height, first.bounds.height)
                let minWidth = min(previous.bounds.width, block.bounds.width)
                let maxWidth = max(previous.bounds.width, block.bounds.width)
                let overlap = min(previous.bounds.maxX, block.bounds.maxX) - max(previous.bounds.minX, block.bounds.minX)
                let aligned = abs(previous.bounds.minX - block.bounds.minX) < max(16, layout.size.width * 0.035)
                let sameColumn = aligned && overlap > minWidth * 0.7 && minWidth > maxWidth * 0.55
                let sameFont = h < min(last.bounds.height, first.bounds.height) * 1.4
                if sameColumn && sameFont && gap >= -h * 0.3 && gap <= max(7, h * 1.65) && gap < bestGap {
                    match = i
                    bestGap = gap
                }
            }
            if let match {
                groups[match].blocks.append(block)
                groups[match].translations.append(text)
            } else {
                groups.append(PDFRenderGroup(blocks: [block], translations: [text]))
            }
        }
        return groups
    }

    /// The original page is rasterized for the translated side so copied text
    /// contains only the visible translation, not hidden English underneath it.
    static func render(page: PDFPage, layout: PDFLayoutPage, translations: [String], fontScale: CGFloat = 1.35) throws -> PDFRenderedTranslation {
        let size = layout.size
        let pageRect = CGRect(origin: .zero, size: size)
        let image = page.thumbnail(of: NSSize(width: size.width * 2, height: size.height * 2), for: .cropBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PDFReaderError.message("无法绘制 PDF 页面。")
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw PDFReaderError.message("无法创建译文页面。") }
        var mediaBox = pageRect
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw PDFReaderError.message("无法创建译文页面。") }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(pageRect)
        context.interpolationQuality = .high
        context.draw(cgImage, in: pageRect)
        var overflow: [String] = []
        let groups = renderGroups(layout: layout, translations: translations)
        for group in groups {
            let lines = group.blocks.flatMap(\.lines)
            var text = ""
            var boldRanges: [NSRange] = []
            for (index, block) in group.blocks.enumerated() {
                let part = group.translations[index]
                if index > 0 {
                    let previous = group.blocks[index - 1].lines.last
                    let endedSentence = previous?.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".") == true
                    let shortLastLine = (previous?.bounds.width ?? 0) < block.bounds.width * 0.78
                    let indented = previous.map {
                        PDFLayoutExtractor.startsIndentedParagraph(block.lines[0], after: $0, columnLeft: min(group.blocks[index - 1].bounds.minX, block.bounds.minX))
                    } ?? false
                    if indented {
                        text += "\n\u{3000}\u{3000}"
                    } else if (PDFLayoutExtractor.startsParagraphLabel(block.text) && ((previous.map { PDFLayoutExtractor.endsSentence($0.text) } ?? false) || PDFLayoutExtractor.startsStructuredAbstractLabel(block.text))) || (endedSentence && shortLastLine) {
                        text += "\n"
                    } else if text.last?.isASCII == true && part.first?.isASCII == true {
                        text += " "
                    }
                }
                let offset = (text as NSString).length
                if PDFLayoutExtractor.startsStructuredAbstractLabel(block.text),
                   let colon = part.firstIndex(where: { $0 == ":" || $0 == "：" }) {
                    let heading = String(part[...colon])
                    if heading.count <= 30 { boldRanges.append(NSRange(location: offset, length: (heading as NSString).length)) }
                }
                text += part
            }
            var backgrounds: [NSColor] = []
            for line in lines {
                let color = backgroundColor(bitmap, at: line.bounds, pageSize: size)
                backgrounds.append(color)
                // Use the image's ICC profile for the sampled components.
                // Converting to device RGB made gray page backgrounds visibly
                // lighter than the adjacent original image, leaving stripes.
                if let space = cgImage.colorSpace, space.model == .rgb,
                   let fill = CGColor(colorSpace: space, components: [color.redComponent, color.greenComponent, color.blueComponent, 1]) {
                    context.setFillColor(fill)
                } else {
                    context.setFillColor(color.cgColor)
                }
                let mask = line.bounds.insetBy(dx: -0.9, dy: -0.8).intersection(pageRect)
                context.fill(mask)
            }
            let heights = lines.map(\.bounds.height).sorted()
            let sourceSize = min(max((heights[heights.count / 2]) * 1.08, 5), 28)
            let background = backgrounds.first ?? .white
            let brightness = background.redComponent * 0.299 + background.greenComponent * 0.587 + background.blueComponent * 0.114
            let foreground = brightness < 0.48 ? NSColor.white : NSColor.black
            var rect = group.bounds.insetBy(dx: -0.5, dy: -1).intersection(pageRect)
            // If source text is shorter than its translation, permit a modest
            // expansion into genuinely blank space below it. Do not cross
            // another text group or sample pixels that differ from the page's
            // background, which would cover a diagram or table border.
            let desiredExtra = min(sourceSize * max(0, fontScale - 1) * 1.5, 14)
            if desiredExtra > 0.5 {
                var floor = max(pageRect.minY, rect.minY - desiredExtra)
                for other in groups where other.bounds.maxY <= group.bounds.minY {
                    let overlap = min(group.bounds.maxX, other.bounds.maxX) - max(group.bounds.minX, other.bounds.minX)
                    if overlap > 0 { floor = max(floor, other.bounds.maxY + 1.5) }
                }
                let candidate = CGRect(x: rect.minX, y: floor, width: rect.width, height: max(0, rect.minY - floor))
                if candidate.height > 0.5 && isUniformBackground(bitmap, rect: candidate, pageSize: size, color: background) {
                    rect = CGRect(x: rect.minX, y: floor, width: rect.width, height: rect.maxY - floor)
                }
            }
            var chosenFrame: CTFrame?
            var visible = 0
            // Prefer a larger readable font; step down only as needed to keep
            // the translated text inside its original column or section.
            var fontSize = min(sourceSize * min(max(fontScale, 0.8), 1.8), 36)
            let length = (text as NSString).length
            while fontSize >= 3.5 {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                let attributed = NSMutableAttributedString(string: text, attributes: [
                    .font: NSFont(name: "PingFangSC-Regular", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: foreground,
                    .paragraphStyle: style
                ])
                // Retain the visual emphasis of structured abstract labels.
                let bold = NSFont(name: "PingFangSC-Semibold", size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)
                for range in boldRanges {
                    attributed.addAttribute(.font, value: bold, range: range)
                }
                let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
                let count = CTFrameGetVisibleStringRange(frame).length
                chosenFrame = frame
                visible = count
                if count >= length { break }
                fontSize -= 0.5
            }
            if let chosenFrame {
                context.saveGState()
                context.clip(to: rect)
                context.textMatrix = .identity
                CTFrameDraw(chosenFrame, context)
                context.restoreGState()
            }
            if visible < length {
                overflow.append((text as NSString).substring(from: max(0, visible)))
            }
        }
        context.endPDFPage()
        context.closePDF()
        return PDFRenderedTranslation(data: data as Data, overflow: overflow)
    }

    private static func backgroundColor(_ bitmap: NSBitmapImageRep, at bounds: CGRect, pageSize: CGSize) -> NSColor {
        let points = [
            CGPoint(x: bounds.minX - 2, y: bounds.midY), CGPoint(x: bounds.maxX + 2, y: bounds.midY),
            CGPoint(x: bounds.minX + 1, y: bounds.maxY + 2), CGPoint(x: bounds.maxX - 1, y: bounds.maxY + 2),
            CGPoint(x: bounds.minX + 1, y: bounds.minY - 2), CGPoint(x: bounds.maxX - 1, y: bounds.minY - 2)
        ]
        let colors: [NSColor] = points.compactMap { point in
            let x = min(max(Int(point.x / pageSize.width * CGFloat(bitmap.pixelsWide)), 0), bitmap.pixelsWide - 1)
            let y = min(max(Int((1 - point.y / pageSize.height) * CGFloat(bitmap.pixelsHigh)), 0), bitmap.pixelsHigh - 1)
            return bitmap.colorAt(x: x, y: y)
        }
        guard !colors.isEmpty else { return .white }
        func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
        return NSColor(deviceRed: median(colors.map(\.redComponent)), green: median(colors.map(\.greenComponent)), blue: median(colors.map(\.blueComponent)), alpha: 1)
    }

    private static func isUniformBackground(_ bitmap: NSBitmapImageRep, rect: CGRect, pageSize: CGSize, color: NSColor) -> Bool {
        let expected = [color.redComponent, color.greenComponent, color.blueComponent]
        for xf: CGFloat in [0.1, 0.3, 0.5, 0.7, 0.9] {
            for yf: CGFloat in [0.25, 0.5, 0.75] {
                let px = min(max(Int((rect.minX + rect.width * xf) / pageSize.width * CGFloat(bitmap.pixelsWide)), 0), bitmap.pixelsWide - 1)
                let py = min(max(Int((1 - (rect.minY + rect.height * yf) / pageSize.height) * CGFloat(bitmap.pixelsHigh)), 0), bitmap.pixelsHigh - 1)
                guard let sample = bitmap.colorAt(x: px, y: py),
                      zip([sample.redComponent, sample.greenComponent, sample.blueComponent], expected).allSatisfy({ abs($0.0 - $0.1) < 0.035 }) else { return false }
            }
        }
        return true
    }
}
