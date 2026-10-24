import Foundation
import XCTest
@testable import ReadingCore

final class FloatingChromeGeometryTests: XCTestCase {
    func testSmallMapProgressAvoidsTimelinePersonAndNavigationWithoutReservingColumns() throws {
        let bounds = CGRect(x: 20, y: 88, width: 760, height: 488)
        let timeline = CGRect(x: 80, y: 340, width: 656, height: 236)
        let person = CGRect(x: 436, y: 108, width: 340, height: 220)
        let navigation = CGRect(x: 8, y: 528, width: 48, height: 48)
        let preferred = CGPoint(x: 80, y: 444)
        let frame = try XCTUnwrap(FloatingChromeGeometry.place(size: CGSize(width: 260, height: 52), preferredOrigin: preferred,
            within: bounds, avoiding: [timeline, person, navigation]))
        XCTAssertTrue(bounds.contains(frame))
        for obstacle in [timeline, person, navigation] { XCTAssertFalse(frame.intersects(obstacle.insetBy(dx: -12, dy: -12))) }
        XCTAssertEqual(frame.minX, 80, "可用的左侧空间仍可显示内容，不推导成一整列禁区。")
        XCTAssertLessThan(frame.maxY, timeline.minY)
    }

    func testKeepsClearPreferenceAndReturnsNilInsteadOfOverlappingInCrowdedWindow() throws {
        let bounds = CGRect(x: 20, y: 88, width: 760, height: 488)
        let preferred = CGPoint(x: 220, y: 512)
        let size = CGSize(width: 360, height: 56)
        XCTAssertEqual(try XCTUnwrap(FloatingChromeGeometry.place(size: size, preferredOrigin: preferred, within: bounds, avoiding: [])), CGRect(origin: preferred, size: size))
        XCTAssertNil(FloatingChromeGeometry.place(size: size, preferredOrigin: preferred, within: bounds, avoiding: [bounds]))
        XCTAssertNil(FloatingChromeGeometry.place(size: CGSize(width: 900, height: 56), preferredOrigin: preferred, within: bounds, avoiding: []))
    }

    func testClampsRestoredOffscreenOriginAndRejectsInvalidGeometry() throws {
        let bounds = CGRect(x: 20, y: 88, width: 760, height: 488)
        let size = CGSize(width: 260, height: 52)
        let frame = try XCTUnwrap(FloatingChromeGeometry.place(size: size, preferredOrigin: CGPoint(x: -1000, y: 10000), within: bounds,
            avoiding: [.null, .zero, CGRect(x: 900, y: 100, width: 50, height: 50)]))
        XCTAssertEqual(frame, CGRect(x: 20, y: 524, width: 260, height: 52))
        XCTAssertNil(FloatingChromeGeometry.place(size: CGSize(width: CGFloat.nan, height: 52), preferredOrigin: .zero, within: bounds, avoiding: []))
        XCTAssertNil(FloatingChromeGeometry.place(size: size, preferredOrigin: .zero, within: .null, avoiding: []))
    }
}
