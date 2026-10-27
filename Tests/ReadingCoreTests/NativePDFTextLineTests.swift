import Foundation
import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import ReadingCore

final class NativePDFTextLineTests: XCTestCase {
    func testRawLineRangeMustReproduceItsUntrimmedNativeBytes() throws {
        let page = "前言\n😀甲\r\n乙  \n后文", lineText = "😀甲\r\n乙  "
        let native = page as NSString
        let range = native.range(of: lineText)
        let line = try XCTUnwrap(NativePDFTextLine.validate([range], lineText: lineText, pageText: page,
                                                          nativeCharacterCount: native.length))
        XCTAssertEqual(line.ranges, [range])
        XCTAssertEqual(line.enclosingRange, range)
        let fromNSString = try XCTUnwrap(NativePDFTextLine.validate([range], lineText: lineText, pageText: native,
                                                                  nativeCharacterCount: native.length))
        XCTAssertEqual(fromNSString.ranges, line.ranges)
        XCTAssertNil(NativePDFTextLine.validate([range], lineText: lineText.trimmingCharacters(in: .whitespacesAndNewlines),
                                               pageText: page, nativeCharacterCount: native.length))
        XCTAssertNil(NativePDFTextLine.validate([range], lineText: lineText.replacingOccurrences(of: "\r\n", with: "\n"),
                                               pageText: page, nativeCharacterCount: native.length))
        XCTAssertNil(NativePDFTextLine.validate([range], lineText: lineText, pageText: page,
                                               nativeCharacterCount: NSMaxRange(range) - 1))
    }

    func testDisjointRangesIntersectTheirTextButNeverTheEnclosingGaps() throws {
        let page = "甲xx乙yy丙"
        let ranges = [NSRange(location: 0, length: 1), NSRange(location: 3, length: 1), NSRange(location: 6, length: 1)]
        let line = try XCTUnwrap(NativePDFTextLine.validate(ranges, lineText: "甲乙丙", pageText: page,
                                                          nativeCharacterCount: (page as NSString).length))
        XCTAssertEqual(line.ranges, ranges)
        XCTAssertEqual(line.enclosingRange, NSRange(location: 0, length: 7))
        for range in ranges { XCTAssertTrue(line.intersects(range)) }
        XCTAssertFalse(line.intersects(NSRange(location: 1, length: 2)))
        XCTAssertFalse(line.intersects(NSRange(location: 4, length: 2)))
        XCTAssertFalse(line.intersects(NSRange(location: 7, length: 1)))
        XCTAssertTrue(line.intersects(NSRange(location: 2, length: 2)))
        XCTAssertTrue(line.intersects(NSRange(location: 5, length: 2)))
        for invalid in [NSRange(location: -1, length: 1), NSRange(location: 0, length: 0),
                        NSRange(location: 0, length: -1), NSRange(location: NSNotFound, length: 1),
                        NSRange(location: 0, length: NSNotFound), NSRange(location: Int.max - 1, length: 3)] {
            XCTAssertFalse(line.intersects(invalid))
        }
    }

    func testInvalidOverlappingUnorderedAndSurrogateRangesAreRejected() throws {
        let page = "甲乙😀丙", count = (page as NSString).length
        for range in [NSRange(location: -1, length: 1), NSRange(location: 0, length: -1),
                      NSRange(location: 0, length: 0), NSRange(location: NSNotFound, length: 1),
                      NSRange(location: 0, length: NSNotFound), NSRange(location: Int.max - 1, length: 3),
                      NSRange(location: count, length: 1), NSRange(location: 0, length: count + 1),
                      NSRange(location: 2, length: 1), NSRange(location: 3, length: 1)] {
            XCTAssertNil(NativePDFTextLine.validate([range], lineText: "�", pageText: page, nativeCharacterCount: count))
        }
        XCTAssertNil(NativePDFTextLine.validate([NSRange(location: 0, length: 2), NSRange(location: 1, length: 1)],
                                               lineText: "甲乙乙", pageText: page, nativeCharacterCount: count))
        XCTAssertNil(NativePDFTextLine.validate([NSRange(location: 1, length: 1), NSRange(location: 0, length: 1)],
                                               lineText: "乙甲", pageText: page, nativeCharacterCount: count))
        XCTAssertNotNil(NativePDFTextLine.validate([NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)],
                                                  lineText: "甲乙", pageText: page, nativeCharacterCount: count))
        let emoji = try XCTUnwrap(NativePDFTextLine.validate([NSRange(location: 2, length: 2)], lineText: "😀",
                                                           pageText: page, nativeCharacterCount: count))
        XCTAssertEqual(emoji.enclosingRange, NSRange(location: 2, length: 2))
        XCTAssertNil(NativePDFTextLine.validate([], lineText: "甲", pageText: page, nativeCharacterCount: count))
        XCTAssertNil(NativePDFTextLine.validate([NSRange(location: 0, length: 1)], lineText: "", pageText: page,
                                               nativeCharacterCount: count))
        XCTAssertNil(NativePDFTextLine.validate([NSRange(location: 0, length: 1)], lineText: "甲", pageText: page,
                                               nativeCharacterCount: -1))
    }

    func testEquivalentUnicodeAndTrimmedTextDoNotProveRawLineIdentity() throws {
        let page = " e\u{301}  ", native = page as NSString
        let full = NSRange(location: 0, length: native.length)
        XCTAssertNotNil(NativePDFTextLine.validate([full], lineText: page, pageText: native, nativeCharacterCount: native.length))
        let normalized = page.precomposedStringWithCanonicalMapping
        XCTAssertEqual(page, normalized, "String equality alone treats these different original bytes as equivalent.")
        XCTAssertNil(NativePDFTextLine.validate([full], lineText: normalized, pageText: native, nativeCharacterCount: native.length))
        XCTAssertNil(NativePDFTextLine.validate([full], lineText: page.trimmingCharacters(in: .whitespaces),
                                               pageText: native, nativeCharacterCount: native.length))
        XCTAssertNil(NativePDFTextLine.validate([full], lineText: " e\u{301} \t", pageText: native,
                                               nativeCharacterCount: native.length))
    }

    func testLineValidationKeepsExistingRangeAndTextSizeBounds() {
        let page = String(repeating: "甲", count: 65)
        let ranges = (0..<65).map { NSRange(location: $0, length: 1) }
        XCTAssertNil(NativePDFTextLine.validate(ranges, lineText: page, pageText: page, nativeCharacterCount: 65))
        let long = String(repeating: "甲", count: 32_769)
        XCTAssertNil(NativePDFTextLine.validate([NSRange(location: 0, length: 32_769)], lineText: long, pageText: long,
                                               nativeCharacterCount: 32_769))
    }

    func testFirstHitFallsBackWhenMoreSpecificGeometryIsEmptyOrMissesPoint() throws {
        let point = CGPoint(x: 20, y: 30), expected = CGRect(x: 10, y: 20, width: 30, height: 20)
        let candidates: [NativePDFTextLine.Candidate<String>] = [
            .init(id: "short", range: NSRange(location: 0, length: 1)),
            .init(id: "middle", range: NSRange(location: 0, length: 3)),
            .init(id: "long", range: NSRange(location: 0, length: 8))
        ]
        var visited: [String] = []
        let hit = try XCTUnwrap(NativePDFTextLine.firstHit(at: point, candidates: candidates) { candidate in
            visited.append(candidate.id)
            switch candidate.id {
            case "short": return []
            case "middle": return [CGRect(x: 100, y: 100, width: 20, height: 20)]
            default: return [expected]
            }
        })
        XCTAssertEqual(hit.id, "long")
        XCTAssertEqual(hit.rectangle, expected)
        XCTAssertEqual(visited, ["short", "middle", "long"])

        visited = []
        let specific = try XCTUnwrap(NativePDFTextLine.firstHit(at: point, candidates: candidates) { candidate in
            visited.append(candidate.id); return [expected]
        })
        XCTAssertEqual(specific.id, "short")
        XCTAssertEqual(visited, ["short"], "A valid most-specific hit must not prepare the remaining candidates.")
    }

    func testInvalidGeometryNeverHitsOrHidesALaterUsableRectangle() throws {
        let point = CGPoint(x: 20, y: 30)
        let candidate = NativePDFTextLine.Candidate(id: "sentence", range: NSRange(location: 0, length: 8))
        let invalid: [CGRect] = [.null, .infinite, .zero,
            CGRect(x: CGFloat.nan, y: 0, width: 30, height: 40),
            CGRect(x: 0, y: CGFloat.nan, width: 30, height: 40),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 40),
            CGRect(x: 0, y: 0, width: 30, height: CGFloat.infinity)]
        for rectangle in invalid {
            XCTAssertNil(NativePDFTextLine.firstHit(at: point, candidates: [candidate]) { _ in [rectangle] })
        }
        let valid = CGRect(x: 10, y: 20, width: 30, height: 20)
        let hit = try XCTUnwrap(NativePDFTextLine.firstHit(at: point, candidates: [candidate]) { _ in invalid + [valid] })
        XCTAssertEqual(hit.id, candidate.id)
        XCTAssertEqual(hit.rectangle, valid)
    }
}
