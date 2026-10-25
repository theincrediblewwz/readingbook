import Foundation
import XCTest
@testable import ReadingCore

final class ReadingGeometryBandsTests: XCTestCase {
    func testPointerQueryDoesNotVisitTheWholePageAndKeepsBoundaryLines() {
        var index = ReadingGeometryBands<Int>()
        for value in 0..<2000 { index.insert(value, rectangle: CGRect(x: 30, y: Double(value * 80), width: 200, height: 20)) }
        XCTAssertEqual(index.candidates(atY: 80 * 1000 + 10), [1000])
        XCTAssertLessThan(index.candidates(intersecting: CGRect(x: 0, y: 79_990, width: 800, height: 140)).count, 5)
        index.insert(3000, rectangle: CGRect(x: 0, y: 63, width: 200, height: 3))
        XCTAssertTrue(index.candidates(atY: 63).contains(3000))
        XCTAssertTrue(index.candidates(atY: 65).contains(3000))
    }
    func testRotatedLongLinesUseBoundedOverflowWithoutLosingCandidates() {
        var index = ReadingGeometryBands<String>(maximumBands: 2, maximumOverflow: 2)
        index.insert("rotated", rectangle: CGRect(x: 5, y: 0, width: 20, height: 400))
        XCTAssertTrue(index.candidates(atY: 380).contains("rotated"))
        index.insert("second", rectangle: CGRect(x: 5, y: 0, width: 20, height: 500))
        index.insert("third", rectangle: CGRect(x: 5, y: 0, width: 20, height: 600))
        XCTAssertTrue(index.requiresFallback, "饱和时宿主退回有界原始集合，不能静默漏掉命中。")
        XCTAssertEqual(index.candidates(atY: 200).count, 2, "overflow 本身仍有内存上限。")
    }
    func testInvalidGeometryIsIgnoredAndDuplicateRegistrationIsStable() {
        var index = ReadingGeometryBands<String>()
        index.insert("name", rectangle: CGRect(x: 0, y: -20, width: 60, height: 30))
        index.insert("name", rectangle: CGRect(x: 0, y: -20, width: 60, height: 30))
        index.insert("invalid", rectangle: CGRect(x: 0, y: .infinity, width: 10, height: 10))
        XCTAssertEqual(index.candidates(atY: -1), ["name"])
        XCTAssertEqual(index.candidates(atY: .nan), [])
        XCTAssertEqual(index.candidates(intersecting: CGRect(x: 0, y: -40, width: 100, height: 100)), ["name"])
    }
}
