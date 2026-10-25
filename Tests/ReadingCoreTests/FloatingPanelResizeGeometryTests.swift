import Foundation
import XCTest
@testable import ReadingCore

final class FloatingPanelResizeGeometryTests: XCTestCase {
    private let bounds = CGRect(x: 24, y: 88, width: 1152, height: 624)
    private let start = CGRect(x: 400, y: 200, width: 400, height: 360)

    func testEachEdgeMovesOnlyItsOwnAxisAndKeepsTheOppositeEdge() {
        let left = resize(.leading, CGSize(width: -100, height: 200))
        XCTAssertEqual(left, CGRect(x: 300, y: 200, width: 500, height: 360))
        let right = resize(.trailing, CGSize(width: 100, height: -200))
        XCTAssertEqual(right, CGRect(x: 400, y: 200, width: 500, height: 360))
        let top = resize(.top, CGSize(width: 200, height: -100))
        XCTAssertEqual(top, CGRect(x: 400, y: 100, width: 400, height: 460))
        let bottom = resize(.bottom, CGSize(width: -200, height: 100))
        XCTAssertEqual(bottom, CGRect(x: 400, y: 200, width: 400, height: 460))
    }

    func testEveryCornerPreservesItsOppositeCornerAndHonorsWindowBounds() {
        for direction in FloatingPanelResizeDirection.allCases {
            let grown = resize(direction, CGSize(width: direction.movesLeading ? -10_000 : 10_000,
                                                  height: direction.movesTop ? -10_000 : 10_000))
            XCTAssertTrue(bounds.contains(grown), "\(direction)")
            if direction.movesLeading { XCTAssertEqual(grown.maxX, start.maxX) }
            if direction.movesTrailing { XCTAssertEqual(grown.minX, start.minX) }
            if direction.movesTop { XCTAssertEqual(grown.maxY, start.maxY) }
            if direction.movesBottom { XCTAssertEqual(grown.minY, start.minY) }
            let shrunk = resize(direction, CGSize(width: direction.movesLeading ? 10_000 : -10_000,
                                                   height: direction.movesTop ? 10_000 : -10_000))
            if direction.movesLeading || direction.movesTrailing { XCTAssertEqual(shrunk.width, 320) }
            else { XCTAssertEqual(shrunk.width, start.width) }
            if direction.movesTop || direction.movesBottom { XCTAssertEqual(shrunk.height, 260) }
            else { XCTAssertEqual(shrunk.height, start.height) }
            XCTAssertTrue(bounds.contains(shrunk), "\(direction)")
        }
    }

    func testShortAvoidancePlacementKeepsHeightWhileResizingHorizontally() {
        let shortened = CGRect(x: 400, y: 200, width: 400, height: 140)
        let result = FloatingPanelResizeGeometry.resizedFrame(from: shortened, delta: CGSize(width: -40, height: 200), direction: .leading, in: bounds)
        XCTAssertEqual(result.height, shortened.height)
        XCTAssertEqual(result.minY, shortened.minY)
        XCTAssertEqual(result.maxX, shortened.maxX)
    }

    func testTinyBoundsAndInvalidInputCannotPushAHandleOutsideTheReadingArea() {
        let small = CGRect(x: 24, y: 88, width: 220, height: 100)
        for direction in FloatingPanelResizeDirection.allCases {
            let result = FloatingPanelResizeGeometry.resizedFrame(from: start, delta: CGSize(width: -1000, height: 1000), direction: direction, in: small)
            XCTAssertEqual(result, small)
            let unchanged = resize(direction, CGSize(width: CGFloat.nan, height: CGFloat.infinity))
            XCTAssertEqual(unchanged, start)
        }
        XCTAssertEqual(FloatingPanelResizeGeometry.resizedFrame(from: start, delta: .zero, direction: .top, in: .null), .zero)
        let invalid = CGRect(x: CGFloat.nan, y: CGFloat.infinity, width: CGFloat.nan, height: CGFloat.infinity)
        let recovered = FloatingPanelResizeGeometry.resizedFrame(from: invalid, delta: .zero, direction: .bottomTrailing, in: bounds)
        XCTAssertTrue(bounds.contains(recovered))
        XCTAssertEqual(recovered.size, CGSize(width: 320, height: 260))
    }

    private func resize(_ direction: FloatingPanelResizeDirection, _ delta: CGSize) -> CGRect {
        FloatingPanelResizeGeometry.resizedFrame(from: start, delta: delta, direction: direction, in: bounds)
    }
}
