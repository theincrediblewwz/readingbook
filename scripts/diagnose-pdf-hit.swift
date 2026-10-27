import Foundation
import PDFKit
import CoreGraphics
import CoreText

// Temporary SDK probe. All PDF data below is generated in memory; this script
// never opens a user book, library, configuration, or credential file.
@main
struct PDFHitProbe {
    struct FixtureFailure: Error { let message: String }

    @MainActor static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw FixtureFailure(message: message) }
        return value
    }

    @MainActor static func nativeText(_ text: String, size: CGFloat = 24, kerning: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil),
            NSAttributedString.Key(kCTKernAttributeName as String): kerning
        ])
    }

    @MainActor static func document(_ lines: [NSAttributedString], height: CGFloat = 480,
                                    spacing: CGFloat = 120) throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try require(CGDataConsumer(data: data as CFMutableData), "consumer")
        var media = CGRect(x: 0, y: 0, width: 600, height: height)
        let context = try require(CGContext(consumer: consumer, mediaBox: &media, nil), "context")
        context.beginPDFPage(nil)
        context.textMatrix = .identity
        for (index, text) in lines.enumerated() {
            context.textPosition = CGPoint(x: 32, y: height - 80 - CGFloat(index) * spacing)
            CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
        }
        context.endPDFPage()
        context.closePDF()
        return try require(PDFDocument(data: data as Data), "PDFDocument")
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    static func usable(_ rectangle: CGRect) -> Bool {
        !rectangle.isNull && !rectangle.isInfinite && !rectangle.isEmpty &&
        [rectangle.minX, rectangle.minY, rectangle.maxX, rectangle.maxY].allSatisfy(\.isFinite)
    }

    @MainActor static func rangeDump(_ selection: PDFSelection, page: PDFPage, source: NSString,
                                     label: String, point: CGPoint? = nil) {
        let string = selection.string
        let bounds = selection.bounds(for: page)
        let clipped = bounds.intersection(page.bounds(for: .cropBox))
        print("\(label): pages=\(selection.pages.count) samePage=\(selection.pages.first === page)")
        print("  string=\(String(reflecting: string)) utf8=\(hex((string ?? "").utf8))")
        print("  bounds=\(bounds) clipped=\(clipped) usable=\(usable(clipped)) contains=\(point.map { clipped.contains($0) } as Any)")
        let count = selection.numberOfTextRanges(on: page)
        print("  numberOfTextRanges=\(count)")
        var joined = Data(), previousEnd = 0, totalLength = 0
        var rangesValid = count > 0 && count <= 64
        for index in 0..<min(max(count, 0), 64) {
            let range = selection.range(at: index, on: page)
            let limit = min(source.length, page.numberOfCharacters)
            let valid = range.location >= 0 && range.location != NSNotFound && range.length > 0 &&
                range.length != NSNotFound && range.location <= limit && range.length <= limit - range.location
            let ordered = index == 0 || range.location >= previousEnd
            print("  range[\(index)]=\(range) valid=\(valid) ordered=\(ordered)")
            guard valid else { rangesValid = false; continue }
            let substring = source.substring(with: range)
            print("    raw=\(String(reflecting: substring)) utf8=\(hex(substring.utf8))")
            print("    originalSelectionString=\(String(reflecting: page.selection(for: range)?.string))")
            joined.append(contentsOf: substring.utf8)
            previousEnd = range.location + range.length
            totalLength += range.length
            rangesValid = rangesValid && ordered && totalLength <= 32_768
        }
        print("  joinedUTF8=\(hex(joined)) byteEqual=\(string.map { joined.elementsEqual($0.utf8) } as Any) rangesValid=\(rangesValid)")
    }

    @MainActor static func pageDump(_ page: PDFPage, text: String, label: String) {
        let source = text as NSString
        print("\n=== \(label) ===")
        print("page.string=\(String(reflecting: text)) utf8=\(hex(text.utf8))")
        print("nativeCharacterCount=\(page.numberOfCharacters) pageStringUTF16=\(source.length) rotation=\(page.rotation)")
        print("crop=\(page.bounds(for: .cropBox)) media=\(page.bounds(for: .mediaBox))")
        for offset in 0..<min(source.length, page.numberOfCharacters) {
            let bounds = page.characterBounds(at: offset)
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let scalar = String(format: "%04x", source.character(at: offset))
            print("  char[\(offset)] UTF16=\(scalar) bounds=\(bounds) centerIndex=\(page.characterIndex(at: center))")
        }
        let full = NSRange(location: 0, length: source.length)
        if full.length > 0, full.length <= page.numberOfCharacters, let selection = page.selection(for: full) {
            rangeDump(selection, page: page, source: source, label: "fullSelection")
            for (index, line) in selection.selectionsByLine().enumerated() {
                rangeDump(line, page: page, source: source, label: "fullSelection.line[\(index)]")
            }
        }
    }

    @MainActor static func pointDump(_ point: CGPoint, page: PDFPage, text: String, label: String) {
        print("\n--- \(label) point=\(point) nativeIndex=\(page.characterIndex(at: point)) cropContains=\(page.bounds(for: .cropBox).contains(point)) ---")
        if let line = page.selectionForLine(at: point) {
            rangeDump(line, page: page, source: text as NSString, label: "selectionForLine", point: point)
        } else {
            print("selectionForLine=nil")
        }
        if let word = page.selectionForWord(at: point) {
            rangeDump(word, page: page, source: text as NSString, label: "selectionForWord", point: point)
        } else {
            print("selectionForWord=nil")
        }
        let tiny = CGRect(x: point.x - 0.5, y: point.y - 0.5, width: 1, height: 1)
        if let selection = page.selection(for: tiny) {
            rangeDump(selection, page: page, source: text as NSString, label: "selectionForTinyRect", point: point)
        } else {
            print("selectionForTinyRect=nil")
        }
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        if full.length > 0, full.length <= page.numberOfCharacters, let selection = page.selection(for: full) {
            for (index, line) in selection.selectionsByLine().enumerated() {
                let bounds = line.bounds(for: page).intersection(page.bounds(for: .cropBox))
                print("fullSelection.line[\(index)].containsPoint=\(usable(bounds) && bounds.contains(point))")
            }
        }
    }

    @MainActor static func multiline() throws {
        let sentences = ["首行😀正文。", "第二行有字距。", "页末最后一句。"]
        let pdf = try document([nativeText(sentences[0]), nativeText(sentences[1], kerning: 1.5), nativeText(""), nativeText(sentences[2])])
        let page = try require(pdf.page(at: 0), "multiline page"), text = try require(page.string, "multiline text")
        pageDump(page, text: text, label: "multiline kerning and last sentence")
        for sentence in sentences {
            let swiftRange = try require(text.range(of: sentence, options: .literal), "sentence \(sentence)")
            let range = NSRange(swiftRange, in: text)
            print("expectedSentence=\(String(reflecting: sentence)) expectedUTF16Range=\(range)")
            for offset in [range.location, NSMaxRange(range) - 1] {
                let bounds = page.characterBounds(at: offset)
                pointDump(CGPoint(x: bounds.midX, y: bounds.midY), page: page, text: text,
                          label: "sentence \(sentence) offset \(offset) charBounds \(bounds)")
            }
        }
    }

    @MainActor static func gap() throws {
        let line = NSMutableAttributedString(attributedString: nativeText("高", size: 64))
        line.append(nativeText("小字间距句。", size: 18, kerning: 8))
        let pdf = try document([line], height: 240)
        let page = try require(pdf.page(at: 0), "gap page"), text = try require(page.string, "gap text")
        pageDump(page, text: text, label: "actual mixed-size glyph gap")
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard full.length > 0, full.length <= page.numberOfCharacters else { throw FixtureFailure(message: "gap full range invalid") }
        let selection = try require(page.selection(for: full), "gap full selection")
        let prepared = try require(selection.selectionsByLine().map { $0.bounds(for: page).intersection(page.bounds(for: .cropBox)) }.first(where: usable), "gap prepared rect")
        let small = NSRange(try require(text.range(of: "小", options: .literal), "small glyph"), in: text)
        let smallBounds = page.characterBounds(at: small.location)
        print("gap prepared=\(prepared) smallRange=\(small) smallBounds=\(smallBounds)")
        var gap: CGPoint?, method = "none"
        for step in 1..<128 {
            let point = CGPoint(x: prepared.minX + prepared.width * CGFloat(step) / 128, y: smallBounds.midY)
            let index = page.characterIndex(at: point)
            if index < 0 || index == NSNotFound { gap = point; method = "horizontal step \(step)"; break }
        }
        if gap == nil, prepared.maxY > smallBounds.maxY + 1 {
            let point = CGPoint(x: smallBounds.midX, y: (smallBounds.maxY + prepared.maxY) / 2)
            let index = page.characterIndex(at: point)
            if index < 0 || index == NSNotFound { gap = point; method = "vertical mixed-font gap" }
        }
        guard let gap else { throw FixtureFailure(message: "actual glyph gap not found") }
        print("gap selection method=\(method) preparedContains=\(prepared.contains(gap))")
        pointDump(gap, page: page, text: text, label: "actual no-character gap")
    }

    @MainActor static func cropControl() throws {
        let pdf = try document([nativeText("裁切前部仍有原文，后面的句子正常。")])
        let page = try require(pdf.page(at: 0), "crop page"), text = try require(page.string, "crop text")
        let visible = NSRange(try require(text.range(of: "后", options: .literal), "visible glyph"), in: text)
        page.setBounds(CGRect(x: 90, y: 370, width: 480, height: 90), for: .cropBox)
        page.rotation = 90
        pageDump(page, text: text, label: "successful crop and rotation control")
        let bounds = page.characterBounds(at: visible.location)
        pointDump(CGPoint(x: bounds.midX, y: bounds.midY), page: page, text: text, label: "crop visible glyph")
    }

    @MainActor static func main() throws {
        print("PDFKit native hit probe; all inputs are in-memory fixtures")
        try multiline()
        try gap()
        try cropControl()
    }
}
