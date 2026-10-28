import XCTest
@testable import ReadingCore

final class PDFPageTurnPolicyTests: XCTestCase {
    func testOneTurnPerTrackpadGestureIncludingMomentumTail() {
        var policy = PDFPageTurnPolicy()
        XCTAssertEqual(policy.action(delta: 10, precise: true, phase: .began, timestamp: 1, atStart: true, atEnd: true), .consume)
        XCTAssertEqual(policy.action(delta: 20, precise: true, phase: .changed, timestamp: 1.01, atStart: true, atEnd: true), .turn(1))
        XCTAssertEqual(policy.action(delta: 80, precise: true, phase: .changed, timestamp: 1.02, atStart: true, atEnd: true), .consume)
        XCTAssertEqual(policy.action(delta: 0, precise: true, phase: .ended, timestamp: 1.03, atStart: true, atEnd: true), .consume)
        XCTAssertEqual(policy.action(delta: 80, precise: true, phase: .none, momentum: .began, timestamp: 1.04, atStart: true, atEnd: true), .consume)
        XCTAssertEqual(policy.action(delta: 0, precise: true, phase: .none, momentum: .ended, timestamp: 1.2, atStart: true, atEnd: true), .consume)
        XCTAssertEqual(policy.action(delta: -30, precise: true, phase: .began, timestamp: 1.4, atStart: true, atEnd: true), .turn(-1))
    }

    func testMagnifiedPageRequiresFreshGestureAfterReachingBoundary() {
        var policy = PDFPageTurnPolicy()
        XCTAssertEqual(policy.action(delta: 30, precise: true, phase: .began, timestamp: 1, atStart: false, atEnd: false), .scroll)
        XCTAssertEqual(policy.action(delta: 60, precise: true, phase: .changed, timestamp: 1.1, atStart: false, atEnd: true), .consume)
        XCTAssertEqual(policy.action(delta: 50, precise: true, phase: .none, momentum: .began, timestamp: 1.2, atStart: false, atEnd: true), .consume)
        _ = policy.action(delta: 0, precise: true, phase: .none, momentum: .ended, timestamp: 1.3, atStart: false, atEnd: true)
        XCTAssertEqual(policy.action(delta: 30, precise: true, phase: .began, timestamp: 1.5, atStart: false, atEnd: true), .turn(1))
    }

    func testCrossAxisPanAndUnownedContinuationNeverArmPageTurn() {
        var policy = PDFPageTurnPolicy()
        XCTAssertEqual(policy.action(delta: 0, crossDelta: 40, precise: true, phase: .began, timestamp: 1, atStart: true, atEnd: true), .scroll)
        XCTAssertEqual(policy.action(delta: 40, precise: true, phase: .changed, timestamp: 1.1, atStart: true, atEnd: true), .consume)
        policy.reset()
        XCTAssertEqual(policy.action(delta: 100, precise: true, phase: .changed, timestamp: 2, atStart: true, atEnd: true), .scroll)
        XCTAssertEqual(policy.action(delta: 100, precise: true, phase: .none, momentum: .began, timestamp: 2.1, atStart: true, atEnd: true), .consume)
    }

    func testConventionalWheelBurstTurnsOnceAndRearmsAfterPause() {
        var policy = PDFPageTurnPolicy()
        XCTAssertEqual(policy.action(delta: 3, precise: false, phase: .none, timestamp: 1, atStart: true, atEnd: true), .turn(1))
        XCTAssertEqual(policy.action(delta: 3, precise: false, phase: .none, timestamp: 1.1, atStart: true, atEnd: true), .consume)
        XCTAssertEqual(policy.action(delta: 3, precise: false, phase: .none, timestamp: 1.2, atStart: true, atEnd: true), .consume)
        XCTAssertEqual(policy.action(delta: 3, precise: false, phase: .none, timestamp: 1.6, atStart: true, atEnd: true), .turn(1))
    }

    func testInvalidInputCannotPoisonFollowingGesture() {
        var policy = PDFPageTurnPolicy()
        XCTAssertEqual(policy.action(delta: .nan, precise: true, phase: .began, timestamp: 1, atStart: true, atEnd: true), .scroll)
        XCTAssertEqual(policy.action(delta: -30, precise: true, phase: .began, timestamp: 2, atStart: true, atEnd: true), .turn(-1))
        _ = policy.action(delta: 0, precise: true, phase: .cancelled, timestamp: 2.1, atStart: true, atEnd: true)
        XCTAssertEqual(policy.action(delta: 30, precise: true, phase: .changed, timestamp: 2.2, atStart: true, atEnd: true), .scroll)
    }
}
