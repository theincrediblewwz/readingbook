import Foundation
import XCTest
@testable import ReadingCore

final class NavigationOrbGeometryTests: XCTestCase {
    func testDockAndDragRemainVisibleAcrossWindowSizes() {
        for size in [CGSize(width: 800, height: 600), CGSize(width: 1440, height: 1024)] {
            for dock in [NavigationOrbDock.topLeading, .bottomLeading] {
                let center = NavigationOrbGeometry.center(in: size, dock: dock)
                XCTAssertGreaterThanOrEqual(center.x - 24, 0)
                XCTAssertLessThanOrEqual(center.y + 24, size.height)
                XCTAssertEqual(NavigationOrbGeometry.nearest(to: center, in: size), dock)
            }
            let clamped = NavigationOrbGeometry.clamped(CGPoint(x: -100, y: size.height + 900), in: size)
            XCTAssertEqual(clamped.x, 26)
            XCTAssertEqual(clamped.y, size.height - 26)
            XCTAssertEqual(NavigationOrbGeometry.nearest(to: clamped, in: size), .bottomLeading)
        }
    }
}
