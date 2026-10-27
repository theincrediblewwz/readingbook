import Foundation
import XCTest
@testable import ReadingCore
#if os(macOS)
import PDFKit
import CoreGraphics
import CoreText

final class PDFSourceRangeTests: XCTestCase {
    private func document(pages: [String]) throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 600, height: 320)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, 24, nil)
        ]
        for text in pages {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 32, y: 196)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    @MainActor private func nativeText(_ text: String, size: CGFloat = 24, kerning: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil),
            NSAttributedString.Key(kCTKernAttributeName as String): kerning
        ])
    }

    @MainActor private func multilineDocument(_ lines: [NSAttributedString], height: CGFloat = 480,
                                               spacing: CGFloat = 120) throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 600, height: height)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.textMatrix = .identity
        for (index, text) in lines.enumerated() {
            context.textPosition = CGPoint(x: 32, y: height - 80 - CGFloat(index) * spacing)
            CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
        }
        context.endPDFPage(); context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    @MainActor func testNativeLineProofCoversMultilineKerningAndLastSentence() async throws {
        let sentences = ["首行😀正文。", "第二行有字距。", "页末最后一句。"]
        let document = try multilineDocument([
            nativeText(sentences[0]), nativeText(sentences[1], kerning: 1.5), nativeText(""), nativeText(sentences[2])
        ])
        let page = try XCTUnwrap(document.page(at: 0)), text = try XCTUnwrap(page.string)
        XCTAssertTrue(text.contains("\n"), "The fixture must contain real PDF text-line boundaries, not a newline inside one CTLine.")
        for sentence in sentences {
            let range = NSRange(try XCTUnwrap(text.range(of: sentence, options: .literal)), in: text)
            for offset in [range.location, NSMaxRange(range) - 1] {
                let bounds = page.characterBounds(at: offset)
                XCTAssertFalse(bounds.isEmpty)
                let point = CGPoint(x: bounds.midX, y: bounds.midY)
                let line = try XCTUnwrap(NativePDFTextLine.at(point, on: page, pageText: text), "Line proof must include the first and last glyph on every actual line.")
                XCTAssertTrue(line.intersects(range))
                XCTAssertTrue(NativePDFTextLine.rectangles(for: range, on: page).contains { $0.contains(point) })
            }
        }
    }

    @MainActor func testColdGlyphGapUsesTheSamePhysicalSentenceAsPreparedGeometry() async throws {
        let textLine = NSMutableAttributedString(attributedString: nativeText("高", size: 64))
        textLine.append(nativeText("小字间距句。", size: 18, kerning: 8))
        let document = try multilineDocument([textLine], height: 240)
        let page = try XCTUnwrap(document.page(at: 0)), text = try XCTUnwrap(page.string)
        let full = NSRange(location: 0, length: (text as NSString).length)
        let prepared = try XCTUnwrap(NativePDFTextLine.rectangles(for: full, on: page).first)
        let small = NSRange(try XCTUnwrap(text.range(of: "小", options: .literal)), in: text)
        let smallBounds = page.characterBounds(at: small.location)
        var gap: CGPoint?
        // Look for a true glyph gap, without filtering on selectionForLine:
        // a nil line result here must fail instead of silently skipping it.
        for step in 1..<128 {
            let point = CGPoint(x: prepared.minX + prepared.width * CGFloat(step) / 128, y: smallBounds.midY)
            let index = page.characterIndex(at: point)
            if index < 0 || index == NSNotFound { gap = point; break }
        }
        if gap == nil, prepared.maxY > smallBounds.maxY + 1 {
            let point = CGPoint(x: smallBounds.midX, y: (smallBounds.maxY + prepared.maxY) / 2)
            let index = page.characterIndex(at: point)
            if index < 0 || index == NSNotFound { gap = point }
        }
        let point = try XCTUnwrap(gap, "The mixed-size, kerned line must exercise a point inside line geometry but outside every character hit.")
        XCTAssertTrue(prepared.contains(point))
        let line = try XCTUnwrap(NativePDFTextLine.at(point, on: page, pageText: text), "The cold line lookup must work at the actual native glyph gap.")
        XCTAssertTrue(line.intersects(full))
        let hit = NativePDFTextLine.firstHit(at: point, candidates: [.init(id: "sentence", range: full)]) {
            NativePDFTextLine.rectangles(for: $0.range, on: page)
        }
        XCTAssertEqual(hit?.id, "sentence", "No earlier hover or stored sentence geometry is needed.")
    }

    @MainActor func testClippedEmptyCandidateFallsBackToContainingSentenceAfterRotation() async throws {
        let document = try multilineDocument([nativeText("裁切前部仍有原文，后面的句子正常。")])
        let page = try XCTUnwrap(document.page(at: 0)), text = try XCTUnwrap(page.string)
        let hidden = NSRange(location: 0, length: 1)
        let visible = NSRange(try XCTUnwrap(text.range(of: "后", options: .literal)), in: text)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        page.setBounds(CGRect(x: 90, y: 370, width: 480, height: 90), for: .cropBox)
        page.rotation = 90
        let bounds = page.characterBounds(at: visible.location), point = CGPoint(x: bounds.midX, y: bounds.midY)
        XCTAssertTrue(page.bounds(for: .cropBox).contains(point))
        XCTAssertTrue(NativePDFTextLine.rectangles(for: hidden, on: page).isEmpty, "The shortest source range has no visible geometry after crop.")
        let line = try XCTUnwrap(NativePDFTextLine.at(point, on: page, pageText: text))
        XCTAssertTrue(line.intersects(whole))
        let hit = NativePDFTextLine.firstHit(at: point, candidates: [.init(id: "empty", range: hidden), .init(id: "sentence", range: whole)]) {
            NativePDFTextLine.rectangles(for: $0.range, on: page)
        }
        XCTAssertEqual(hit?.id, "sentence", "An empty shorter candidate cannot hide actual containing geometry.")
        let outside = CGPoint(x: point.x, y: page.bounds(for: .cropBox).minY - 10)
        XCTAssertNil(NativePDFTextLine.firstHit(at: outside, candidates: [.init(id: "sentence", range: whole)]) {
            NativePDFTextLine.rectangles(for: $0.range, on: page)
        }, "A nearby line does not authorize a point outside its physical bounds.")
    }

    func testNativeCharacterPointMatchesUTF16RangeAfterEmojiAndChinese() throws {
        let document = try document(pages: ["甲😀乙。丙中文。"])
        let page = try XCTUnwrap(document.page(at: 0))
        let text = try XCTUnwrap(page.string)
        XCTAssertTrue(text.contains("😀"), "The fixture must retain the supplementary-plane character in its PDF text layer.")
        let sentence = "丙中文。"
        let swiftRange = try XCTUnwrap(text.range(of: sentence, options: .literal))
        let range = NSRange(swiftRange, in: text)
        XCTAssertGreaterThan(range.location, text.distance(from: text.startIndex, to: swiftRange.lowerBound), "An emoji before the sentence distinguishes UTF16 offsets from Swift Character counts.")
        XCTAssertEqual(page.selection(for: range)?.string, sentence)
        let source = try PDFPageSourceText(page: 1, text: text)
        let proof = try XCTUnwrap(NativePageTextProof.prove(page: 1, nativeText: text, source: source))
        XCTAssertEqual(proof.range(of: sentence, location: range.location, length: range.length), range)

        let character = page.characterBounds(at: range.location)
        XCTAssertFalse(character.isEmpty)
        let offset = page.characterIndex(at: CGPoint(x: character.midX, y: character.midY))
        XCTAssertEqual(offset, range.location)
        let index = ReadingRangeIndex<String>([.init(id: "sentence", range: range)])
        XCTAssertEqual(index.ids(containing: offset), ["sentence"])
        XCTAssertTrue(index.ids(containing: NSMaxRange(range)).isEmpty)
    }

    func testNativeRangePointRemainsPageLocalAfterCropAndPageRotation() throws {
        let document = try document(pages: ["第一页😀甲。", "乙中文。末句。"])
        let first = try XCTUnwrap(document.page(at: 0))
        let second = try XCTUnwrap(document.page(at: 1))
        second.setBounds(CGRect(x: 20.25, y: 160.5, width: 500, height: 90), for: .cropBox)
        second.rotation = 90
        let firstText = try XCTUnwrap(first.string)
        let secondText = try XCTUnwrap(second.string)
        let firstRange = NSRange(try XCTUnwrap(firstText.range(of: "甲。", options: .literal)), in: firstText)
        let secondRange = NSRange(try XCTUnwrap(secondText.range(of: "乙中文。", options: .literal)), in: secondText)
        XCTAssertNotEqual(firstRange.location, secondRange.location)
        XCTAssertEqual(second.selection(for: secondRange)?.string, "乙中文。")

        let character = second.characterBounds(at: secondRange.location)
        XCTAssertFalse(character.intersection(second.bounds(for: .cropBox)).isEmpty)
        let offset = second.characterIndex(at: CGPoint(x: character.midX, y: character.midY))
        XCTAssertEqual(offset, secondRange.location)
        let secondPageIndex = ReadingRangeIndex<String>([.init(id: "second-page", range: secondRange)])
        XCTAssertEqual(secondPageIndex.ids(containing: offset), ["second-page"])
    }

    func testNativeAnnotationHitTestingPreservesLinksHighlightsRegionsAndMutation() throws {
        let document = try document(pages: ["原生批注命中检查。"])
        let page = try XCTUnwrap(document.page(at: 0))
        let link = PDFAnnotation(bounds: CGRect(x: 20, y: 40, width: 80, height: 30), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com/reading-test")
        let highlight = PDFAnnotation(bounds: CGRect(x: 70, y: 45, width: 70, height: 20), forType: .highlight, withProperties: nil)
        let region = PDFAnnotation(bounds: CGRect(x: 150, y: 100, width: 80, height: 60), forType: .square, withProperties: nil)
        for annotation in [link, highlight, region] { page.addAnnotation(annotation) }
        let points = [CGPoint(x: 22, y: 42), CGPoint(x: 80, y: 50), CGPoint(x: 130, y: 55),
                      CGPoint(x: 180, y: 120), CGPoint(x: 5, y: 5), CGPoint(x: 250, y: 180)]
        for point in points {
            XCTAssertEqual(page.annotation(at: point) != nil, page.annotations.contains { $0.bounds.contains(point) }, "原生注释继续优先于原文卡片：\(point)")
        }
        let overlap = CGPoint(x: 80, y: 50)
        XCTAssertTrue(page.annotation(at: overlap) === page.annotations.last(where: { $0.bounds.contains(overlap) }))
        page.removeAnnotation(highlight)
        XCTAssertTrue(page.annotation(at: overlap) === link)
        page.removeAnnotation(link)
        XCTAssertNil(page.annotation(at: overlap), "不能保留已删除注释的命中缓存。")
        page.rotation = 90
        page.setBounds(CGRect(x: 10, y: 20, width: 400, height: 240), for: .cropBox)
        XCTAssertTrue(page.annotation(at: CGPoint(x: 180, y: 120)) === region, "旋转、裁切后仍使用page space。")
    }
}
#endif
