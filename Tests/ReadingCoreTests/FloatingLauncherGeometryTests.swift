import Foundation
import XCTest
@testable import ReadingCore

final class FloatingLauncherGeometryTests: XCTestCase {
    private let circle = CGSize(width: 52, height: 52)

    func testFreeDragUsesBothAxesAndStaysInsideViewport() throws {
        let viewport = CGSize(width: 800, height: 600)
        XCTAssertEqual(FloatingLauncherGeometry.clampedCenter(CGPoint(x: 430, y: 280), viewport: viewport, control: circle), CGPoint(x: 430, y: 280))
        XCTAssertEqual(FloatingLauncherGeometry.clampedCenter(CGPoint(x: -100, y: 2000), viewport: viewport, control: circle), CGPoint(x: 34, y: 566))
        let stored = try XCTUnwrap(FloatingLauncherGeometry.normalizedPosition(CGPoint(x: 430, y: 280), viewport: viewport, control: circle))
        let restored = try XCTUnwrap(FloatingLauncherGeometry.restoredCenter(stored, viewport: viewport, control: circle))
        XCTAssertEqual(restored.x, 430, accuracy: 0.001); XCTAssertEqual(restored.y, 280, accuracy: 0.001)
    }

    func testShrinkAndExpansionKeepControlVisibleWithoutReplacingSavedPreference() throws {
        let stored = WorkspacePoint(x: 0.94, y: 0.9)
        for (viewport, control) in [(CGSize(width: 360, height: 260), circle), (CGSize(width: 700, height: 500), CGSize(width: 306, height: 330))] {
            let center = try XCTUnwrap(FloatingLauncherGeometry.restoredCenter(stored, viewport: viewport, control: control))
            XCTAssertGreaterThanOrEqual(center.x - control.width / 2, 8)
            XCTAssertGreaterThanOrEqual(center.y - control.height / 2, 8)
            XCTAssertLessThanOrEqual(center.x + control.width / 2, viewport.width - 8)
            XCTAssertLessThanOrEqual(center.y + control.height / 2, viewport.height - 8)
        }
        XCTAssertNil(FloatingLauncherGeometry.restoredCenter(WorkspacePoint(x: -1, y: 0.5), viewport: CGSize(width: 800, height: 600), control: circle))
        XCTAssertNil(FloatingLauncherGeometry.normalizedPosition(.zero, viewport: .zero, control: circle))
        XCTAssertEqual(FloatingLauncherGeometry.clampedCenter(CGPoint(x: CGFloat.nan, y: CGFloat.infinity), viewport: .zero, control: circle), .zero)
        XCTAssertEqual(FloatingLauncherGeometry.clampedCenter(CGPoint(x: 999, y: -999), viewport: CGSize(width: 30, height: 20), control: circle), CGPoint(x: 15, y: 10))
    }
}
