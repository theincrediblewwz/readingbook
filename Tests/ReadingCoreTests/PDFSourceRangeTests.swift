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
}
#endif
