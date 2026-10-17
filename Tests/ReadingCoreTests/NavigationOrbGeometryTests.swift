import Foundation
import XCTest
@testable import ReadingCore

final class NavigationOrbGeometryTests: XCTestCase {
    func testDockAndDragRemainVisibleAcrossWindowSizes() {
        for size in [CGSize(width: 800, height: 600), CGSize(width: 1440, height: 1024)] {
            for dock in [NavigationOrbDock.topLeading, .bottomLeading] {
                let center = NavigationOrbGeometry.center(in: size, dock: dock)
                XCTAssertGreaterThanOrEqual(center.x - 24, 0)
                XCTAssertLessThanOrEqual(center.x + 24, size.width)
                if dock == .topLeading { XCTAssertLessThanOrEqual(center.y + 24, 96) }
                XCTAssertLessThanOrEqual(center.y + 24, size.height)
                XCTAssertEqual(NavigationOrbGeometry.nearest(to: center, in: size), dock)
            }
            let clamped = NavigationOrbGeometry.clamped(CGPoint(x: -100, y: size.height + 900), in: size)
            XCTAssertEqual(clamped.x, NavigationOrbGeometry.horizontalMargin + 24)
            XCTAssertEqual(clamped.y, size.height - 26)
            XCTAssertEqual(NavigationOrbGeometry.nearest(to: clamped, in: size), .bottomLeading)
        }
    }

    func testDraggingChangesOnlyTheFloatingControlPosition() {
        let size = CGSize(width: 800, height: 600)
        for point in [CGPoint(x: -400, y: -300), CGPoint(x: 400, y: 250), CGPoint(x: 1800, y: 2000)] {
            let result = NavigationOrbGeometry.clamped(point, in: size)
            XCTAssertGreaterThanOrEqual(result.x - NavigationOrbGeometry.buttonDiameter / 2, 0)
            XCTAssertEqual(result.x, NavigationOrbGeometry.horizontalMargin + NavigationOrbGeometry.buttonDiameter / 2)
            XCTAssertGreaterThanOrEqual(result.y - NavigationOrbGeometry.buttonDiameter / 2, 0)
            XCTAssertLessThanOrEqual(result.y + NavigationOrbGeometry.buttonDiameter / 2, size.height)
        }
    }

    func testZeroViewportDoesNotInventOutOfBoundsCoordinates() {
        XCTAssertEqual(NavigationOrbGeometry.center(in: .zero, dock: .topLeading), .zero)
        XCTAssertEqual(NavigationOrbGeometry.clamped(CGPoint(x: 100, y: 200), in: .zero), .zero)
    }
}
