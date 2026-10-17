import XCTest
@testable import ReadingCore

final class CanvasGestureRoutingTests: XCTestCase {
    func testPanelScrollAndInertiaNeverBecomeCanvasPan() {
        var ownership = CanvasGestureOwnership()
        XCTAssertFalse(ownership.accepts(phase: .began, isEligible: false))
        XCTAssertFalse(ownership.accepts(phase: .changed, isEligible: true))
        XCTAssertFalse(ownership.accepts(phase: .ended, isEligible: true))
        XCTAssertFalse(ownership.accepts(phase: .none, momentum: .began, isEligible: true))
        XCTAssertFalse(ownership.accepts(phase: .none, momentum: .changed, isEligible: true))
        XCTAssertFalse(ownership.accepts(phase: .none, momentum: .ended, isEligible: true))
        // A fresh, deliberate canvas gesture retains normal pan/zoom behavior.
        XCTAssertTrue(ownership.accepts(phase: .began, isEligible: true))
        XCTAssertTrue(ownership.accepts(phase: .changed, isEligible: true))
    }

    func testNewOverlayRevokesActiveGestureUntilNextBeginning() {
        var ownership = CanvasGestureOwnership()
        XCTAssertFalse(ownership.accepts(phase: .none, momentum: .began, isEligible: true))
        XCTAssertTrue(ownership.accepts(phase: .began, isEligible: true))
        XCTAssertFalse(ownership.accepts(phase: .changed, isEligible: false))
        XCTAssertFalse(ownership.accepts(phase: .changed, isEligible: true))
        XCTAssertFalse(ownership.accepts(phase: .none, momentum: .changed, isEligible: true))
        XCTAssertFalse(ownership.accepts(phase: .cancelled, isEligible: true))
        XCTAssertTrue(ownership.accepts(phase: .began, isEligible: true))
        XCTAssertTrue(ownership.accepts(phase: .none, isEligible: true))
        XCTAssertFalse(ownership.accepts(phase: .none, isEligible: false))
    }
}
