import Foundation
import XCTest
@testable import ReadingCore

final class ReadingUnderlineGeometryTests: XCTestCase {
    func testClearanceIsOutsideForBothViewOrientationsAndAllPageRotations() throws {
        for flipped in [false, true] {
            for turn in 0..<4 {
                func transform(_ p: CGPoint) -> CGPoint {
                    var p = p
                    for _ in 0..<turn { p = CGPoint(x: -p.y, y: p.x) }
                    if flipped { p.y = -p.y }
                    return p
                }
                let start = transform(CGPoint(x: 10, y: 20)), end = transform(CGPoint(x: 110, y: 20))
                let center = transform(CGPoint(x: 60, y: 30))
                let line = try XCTUnwrap(ReadingUnderlineGeometry.outside(edgeStart: start, edgeEnd: end, contentCenter: center))
                let ox = line.start.x - start.x, oy = line.start.y - start.y
                XCTAssertEqual(hypot(ox, oy), 2, accuracy: 0.0001)
                XCTAssertLessThan(ox * (center.x - start.x) + oy * (center.y - start.y), 0)
                XCTAssertEqual(hypot(line.end.x - line.start.x, line.end.y - line.start.y), 100, accuracy: 0.0001)
            }
        }
    }
    func testZoomChangesLengthButNotDisplayClearanceAndInvalidEdgesAreSkipped() throws {
        for scale in [0.25, 1.0, 3.12, 8.0] {
            let line = try XCTUnwrap(ReadingUnderlineGeometry.outside(edgeStart: .zero, edgeEnd: CGPoint(x: 100 * scale, y: 0), contentCenter: CGPoint(x: 50 * scale, y: 10 * scale), gap: 1.5, lineWidth: 1.6))
            XCTAssertEqual(line.start.y, -2.3, accuracy: 0.0001)
        }
        XCTAssertNil(ReadingUnderlineGeometry.outside(edgeStart: .zero, edgeEnd: .zero, contentCenter: CGPoint(x: 0, y: 10)))
        XCTAssertNil(ReadingUnderlineGeometry.outside(edgeStart: .zero, edgeEnd: CGPoint(x: 10, y: 0), contentCenter: .zero))
        XCTAssertNil(ReadingUnderlineGeometry.outside(edgeStart: .zero, edgeEnd: CGPoint(x: Double.nan, y: 0), contentCenter: .zero))
    }
}
