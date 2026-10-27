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

    func testDirectoryUsesPhysicalContainsAcrossBandEdgesAndColumns() throws {
        let left = try XCTUnwrap(NativePDFTextLine.validate([NSRange(location: 0, length: 2)], lineText: "甲乙",
                                                          pageText: "甲乙丙丁", nativeCharacterCount: 4))
        let right = try XCTUnwrap(NativePDFTextLine.validate([NSRange(location: 2, length: 2)], lineText: "丙丁",
                                                           pageText: "甲乙丙丁", nativeCharacterCount: 4))
        var directory = NativePDFTextLine.Directory()
        XCTAssertTrue(directory.lines(at: CGPoint(x: 20, y: 64)).isEmpty)
        directory.append(.init(text: left, rectangle: CGRect(x: 10, y: 63, width: 30, height: 4)))
        directory.append(.init(text: right, rectangle: CGRect(x: 100, y: 63, width: 30, height: 4)))
        let positions: [CGFloat] = [63.5, 64, 66.5]
        for y in positions {
            XCTAssertEqual(directory.lines(at: CGPoint(x: 20, y: y)).map(\.ranges), [left.ranges])
            XCTAssertEqual(directory.lines(at: CGPoint(x: 110, y: y)).map(\.ranges), [right.ranges])
            XCTAssertTrue(directory.lines(at: CGPoint(x: 70, y: y)).isEmpty, "One row's enclosing horizontal gap is not a physical line hit.")
        }
        XCTAssertTrue(directory.lines(at: CGPoint(x: 20, y: 62)).isEmpty)
        XCTAssertTrue(directory.lines(at: CGPoint(x: 20, y: 68)).isEmpty)
        XCTAssertGreaterThan(directory.byteCount, left.ranges.count * MemoryLayout<NSRange>.stride + right.ranges.count * MemoryLayout<NSRange>.stride)
    }

    func testDirectoryRejectsInvalidRectanglesAndNonfinitePointsWithoutRetainingThem() throws {
        let line = try XCTUnwrap(NativePDFTextLine.validate([NSRange(location: 0, length: 1)], lineText: "甲",
                                                          pageText: "甲", nativeCharacterCount: 1))
        var directory = NativePDFTextLine.Directory()
        for rectangle in [CGRect.null, .infinite, .zero,
                          CGRect(x: CGFloat.nan, y: 0, width: 40, height: 40),
                          CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 40)] {
            directory.append(.init(text: line, rectangle: rectangle))
        }
        XCTAssertEqual(directory.byteCount, 0)
        XCTAssertTrue(directory.lines(at: CGPoint(x: 20, y: 20)).isEmpty)
        let physical = NativePDFTextLine.PhysicalLine(text: line, rectangle: CGRect(x: 10, y: 10, width: 30, height: 30))
        directory.append(physical)
        XCTAssertGreaterThanOrEqual(directory.byteCount, physical.byteCount)
        XCTAssertEqual(directory.lines(at: CGPoint(x: 20, y: 20)).map(\.ranges), [line.ranges])
        XCTAssertTrue(directory.lines(at: CGPoint(x: CGFloat.nan, y: 20)).isEmpty)
        XCTAssertTrue(directory.lines(at: CGPoint(x: 20, y: CGFloat.infinity)).isEmpty)
    }

    func testDirectoryChargesActualEndpointBandsAtTheOverflowBoundary() throws {
        let line = try XCTUnwrap(NativePDFTextLine.validate([NSRange(location: 0, length: 1)], lineText: "甲",
                                                          pageText: "甲", nativeCharacterCount: 1))
        func directory(height: CGFloat) -> NativePDFTextLine.Directory {
            var value = NativePDFTextLine.Directory()
            value.append(.init(text: line, rectangle: CGRect(x: 10, y: 0, width: 30, height: height)))
            return value
        }
        let atLimit = directory(height: 4_096), aboveLimit = directory(height: 4_097)
        XCTAssertEqual(atLimit.byteCount, aboveLimit.byteCount,
                       "Both lines occupy endpoint bands 0 through 64; height alone cannot select the overflow charge.")
        let overflow = directory(height: 4_160), singleBand = directory(height: 1)
        XCTAssertEqual(overflow.byteCount, singleBand.byteCount, "A span of 65 really uses the single overflow entry.")
        XCTAssertGreaterThan(aboveLimit.byteCount, overflow.byteCount)
        XCTAssertEqual(aboveLimit.lines(at: CGPoint(x: 20, y: 4_096.5)).map(\.ranges), [line.ranges])
        XCTAssertEqual(overflow.lines(at: CGPoint(x: 20, y: 4_159)).map(\.ranges), [line.ranges])
    }

    func testDirectoryRetainsFiniteLinesOutsideAndAcrossTheBandCoordinateDomain() throws {
        let page = "甲乙丙"
        var directory = NativePDFTextLine.Directory()
        let rectangles = [CGRect(x: 10, y: 1_000_000_010, width: 30, height: 20),
                          CGRect(x: 100, y: -1_000_000_030, width: 30, height: 20),
                          CGRect(x: 200, y: 999_999_995, width: 30, height: 20)]
        for (index, rectangle) in rectangles.enumerated() {
            let range = NSRange(location: index, length: 1)
            let text = (page as NSString).substring(with: range)
            let line = try XCTUnwrap(NativePDFTextLine.validate([range], lineText: text, pageText: page, nativeCharacterCount: 3))
            directory.append(.init(text: line, rectangle: rectangle))
            XCTAssertEqual(directory.lines(at: CGPoint(x: rectangle.midX, y: rectangle.midY)).map(\.ranges), [[range]])
        }
        XCTAssertEqual(directory.lines(at: CGPoint(x: 210, y: 999_999_999)).map(\.ranges), [[NSRange(location: 2, length: 1)]],
                       "A line crossing the band limit also remains hittable on its in-domain side.")
        XCTAssertTrue(directory.lines(at: CGPoint(x: 170, y: 1_000_000_012)).isEmpty)
    }
}
