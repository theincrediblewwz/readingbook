import Foundation
import XCTest
import PDFKit
@testable import ReadingCore

final class ReaderUnderlineStyleTests: XCTestCase {
    private func record() -> ReaderAnnotation {
        .init(sourceHash: "source", page: 1, text: "Keep the original text", rangeLocation: 12, rangeLength: 22,
              quads: [.init(x: 30, y: 60, width: 180, height: 16)], color: .blue, lineStyle: .wavy)
    }
    private var project: BookProject { .init(title: "Original", originalName: "book.pdf", sourceHash: "source", units: [.init(id: "p1", order: 0, chapter: "PDF", page: 1, text: "Keep the original text")]) }
    private let crop = CGRect(x: 0, y: 0, width: 300, height: 200)
    func testLegacyAndStyledAnnotationsRoundTrip() throws {
        var value = record()
        let old = try JSONEncoder().encode(value)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("lineAppearance"))
        XCTAssertNil(try JSONDecoder().decode(ReaderAnnotation.self, from: old).lineAppearance)
        value.lineAppearance = .init(red: 0.3, green: 0.7, blue: 0.1, opacity: 0.5, thickness: 2.2, waveLength: 13, highlighter: true, glow: true)
        XCTAssertEqual(try JSONDecoder().decode(ReaderAnnotation.self, from: JSONEncoder().encode(value)), value)
        try ReaderAnnotationValidator.validate(value, in: project)
    }
    func testInvalidAppearanceCannotEnterProject() throws {
        var value = record()
        let invalid: [ReaderUnderlineAppearance] = [.init(red: -.infinity), .init(red: 1.1), .init(green: -0.1), .init(blue: .nan), .init(opacity: 0), .init(opacity: 1.01), .init(thickness: 0), .init(thickness: 4.01), .init(waveLength: 1.9), .init(waveLength: 18.1)]
        for appearance in invalid {
            value.lineAppearance = appearance
            XCTAssertFalse(appearance.isValid)
            XCTAssertThrowsError(try ReaderAnnotationValidator.validate(value, in: project))
            XCTAssertNil(ReaderAnnotationAppearance.make(value, quad: value.quads[0], crop: crop))
        }
    }
    func testAppearanceRequiresAnActualTextUnderline() throws {
        var value = record(); value.lineAppearance = .init(); value.lineStyle = nil
        XCTAssertThrowsError(try ReaderAnnotationValidator.validate(value, in: project))
        value.kind = .region; value.text = ""; value.rangeLength = 0; value.rangeLocation = 0
        XCTAssertThrowsError(try ReaderAnnotationValidator.validate(value, in: project))
    }
    func testEveryStrokeCrestStaysBelowGlyphs() throws {
        for thickness in [0.35, 0.8, 4.0] { for waveLength in [2.0, 6.0, 18.0] { for style in ReaderAnnotationLineStyle.allCases {
            var value = record(); value.lineStyle = style; value.lineAppearance = .init(thickness: thickness, waveLength: waveLength, glow: true)
            let original = value.quads
            let ink = try XCTUnwrap(ReaderAnnotationAppearance.make(value, quad: value.quads[0], crop: crop))
            let path = try XCTUnwrap(ink.paths?.first)
            XCTAssertEqual(ink.type, "Ink")
            XCTAssertLessThanOrEqual(ink.bounds.minY + path.bounds.maxY + thickness / 2, value.quads[0].y - 1.499)
            XCTAssertLessThanOrEqual(path.elementCount, 4097)
            XCTAssertEqual(value.quads, original)
        } } }
    }
    func testBottomCropNeverPushesAnUnderlineIntoText() throws {
        var value = record(); value.quads = [.init(x: 30, y: 0, width: 180, height: 16)]
        XCTAssertNil(ReaderAnnotationAppearance.make(value, quad: value.quads[0], crop: crop))
    }
    func testWaveSpacingAndThicknessChangeNativePaths() throws {
        var value = record(); value.lineAppearance = .init(thickness: 0.4, waveLength: 2)
        let dense = try XCTUnwrap(ReaderAnnotationAppearance.make(value, quad: value.quads[0], crop: crop))
        value.lineAppearance = .init(thickness: 3, waveLength: 18)
        let loose = try XCTUnwrap(ReaderAnnotationAppearance.make(value, quad: value.quads[0], crop: crop))
        XCTAssertNotEqual(dense.paths?.first?.cgPath, loose.paths?.first?.cgPath)
        XCTAssertEqual(dense.border?.lineWidth, 0.4); XCTAssertEqual(loose.border?.lineWidth, 3)
    }
    private func raster(_ appearance: ReaderUnderlineAppearance) throws -> Data {
        var value = record(); value.lineAppearance = appearance
        let ink = try XCTUnwrap(ReaderAnnotationAppearance.make(value, quad: value.quads[0], crop: crop))
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 1200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(crop); ink.draw(with: .cropBox, in: context)
        return Data(bytes: try XCTUnwrap(context.data), count: 240000)
    }
    func testHighlighterGlowAndPaletteActuallyChangePixels() throws {
        let plain = try raster(.init())
        XCTAssertNotEqual(plain, try raster(.init(highlighter: true)))
        XCTAssertNotEqual(plain, try raster(.init(glow: true)))
        XCTAssertNotEqual(plain, try raster(.init(red: 0.8, green: 0.1, blue: 0.2)))
        XCTAssertNotEqual(plain, try raster(.init(opacity: 0.3)))
        XCTAssertNotEqual(plain, try raster(.init(waveLength: 2)))
        XCTAssertNotEqual(plain, try raster(.init(thickness: 3)))
    }
    func testAppearanceChangesPreserveQuoteAndSourceGeometry() throws {
        var before = record(); before.comment = "User comment"; let source = before
        before.lineAppearance = .init(thickness: 2, highlighter: true)
        var book = project; book.readerAnnotations = [before]
        let reopened = try JSONDecoder().decode(BookProject.self, from: JSONEncoder().encode(book))
        let after = try XCTUnwrap(reopened.readerAnnotations?.first)
        XCTAssertEqual(after.text, source.text); XCTAssertEqual(after.rangeLocation, source.rangeLocation)
        XCTAssertEqual(after.rangeLength, source.rangeLength); XCTAssertEqual(after.quads, source.quads)
        XCTAssertEqual(after.id, source.id); XCTAssertEqual(after.sourceHash, source.sourceHash)
        XCTAssertEqual(after.comment, source.comment); XCTAssertEqual(after.lineAppearance, before.lineAppearance)
    }
}
