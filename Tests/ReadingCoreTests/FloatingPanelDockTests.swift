import Foundation
import XCTest
@testable import ReadingCore

final class FloatingPanelDockTests: XCTestCase {
    func testFiveTargetsSnapAndUpperRightReservesMapControls() {
        let viewport = CGSize(width: 1200, height: 800), panel = CGSize(width: 560, height: 200)
        for dock in FloatingPanelDock.allCases {
            let frame = FloatingPanelGeometry.frame(at: dock, viewport: viewport, panel: panel)
            XCTAssertEqual(FloatingPanelGeometry.nearest(to: CGPoint(x: frame.midX + 3, y: frame.midY - 2), viewport: viewport, panel: panel), dock)
            XCTAssertTrue(CGRect(origin: .zero, size: viewport).contains(frame))
        }
        let topRight = FloatingPanelGeometry.frame(at: .topTrailing, viewport: viewport, panel: panel)
        XCTAssertEqual(topRight.maxX, viewport.width - 16 - 56)
    }

    func testResizeAndDetailsKeepChosenEdgeAndStayVisible() {
        for viewport in [CGSize(width: 560, height: 500), CGSize(width: 900, height: 650)] {
            for dock in FloatingPanelDock.allCases {
                let collapsed = FloatingPanelGeometry.frame(at: dock, viewport: viewport, panel: CGSize(width: 560, height: 200))
                let expanded = FloatingPanelGeometry.frame(at: dock, viewport: viewport, panel: CGSize(width: 560, height: 410))
                XCTAssertTrue(CGRect(origin: .zero, size: viewport).contains(expanded))
                if dock == .topLeading || dock == .topTrailing { XCTAssertEqual(collapsed.minY, expanded.minY) }
                else { XCTAssertEqual(collapsed.maxY, expanded.maxY) }
            }
            let extreme = FloatingPanelGeometry.clampedCenter(CGPoint(x: -1000, y: 2000), viewport: viewport, panel: CGSize(width: 560, height: 410))
            XCTAssertGreaterThanOrEqual(extreme.x, 16)
            XCTAssertLessThanOrEqual(extreme.y, viewport.height - 16)
        }
        let tiny = FloatingPanelGeometry.frame(at: .bottomCenter, viewport: CGSize(width: 250, height: 220), panel: CGSize(width: 560, height: 410))
        XCTAssertEqual(tiny, CGRect(x: 16, y: 16, width: 218, height: 188))
        // The native panel leaves room for distinct corners plus MapKit controls.
        let narrowViewport = CGSize(width: 496, height: 500)
        let narrowPanel = CGSize(width: min(560, narrowViewport.width - 144), height: 214)
        let left = FloatingPanelGeometry.frame(at: .topLeading, viewport: narrowViewport, panel: narrowPanel)
        let right = FloatingPanelGeometry.frame(at: .topTrailing, viewport: narrowViewport, panel: narrowPanel)
        XCTAssertGreaterThanOrEqual(right.minX - left.minX, 56)
        XCTAssertEqual(FloatingPanelGeometry.nearest(to: CGPoint(x: right.midX, y: right.midY), viewport: narrowViewport, panel: narrowPanel), .topTrailing)
    }

    func testMapFocusUsesSpaceOppositeTheActualPanel() {
        let viewport = CGSize(width: 1000, height: 700), panel = CGSize(width: 560, height: 300)
        for dock in FloatingPanelDock.allCases {
            let frame = FloatingPanelGeometry.frame(at: dock, viewport: viewport, panel: panel)
            let free = FloatingPanelGeometry.unobscuredMapRect(viewport: viewport, panel: frame)
            XCTAssertGreaterThan(free.width * free.height, 0)
            XCTAssertFalse(frame.contains(CGPoint(x: free.midX, y: free.midY)))
        }
        let bottom = FloatingPanelGeometry.frame(at: .bottomCenter, viewport: viewport, panel: panel)
        let topFree = FloatingPanelGeometry.unobscuredMapRect(viewport: viewport, panel: bottom)
        XCTAssertLessThan(topFree.midY, bottom.minY)
    }
}
