import Foundation
import XCTest
@testable import ReadingCore

final class ReadingHoverRefreshTests: XCTestCase {
    func testFinalRapidPointerUpdateRetainsOneScheduledTail() throws {
        var refresh = ReadingHoverRefresh()
        let first = try XCTUnwrap(refresh.request(at: 1))
        XCTAssertEqual(refresh.request(at: 1.001), first, "Input arriving before the first queued callback cannot starve it.")
        XCTAssertTrue(refresh.consume(first, at: 1.001))
        let tail = try XCTUnwrap(refresh.request(at: 1.005))
        for now in [1.010, 1.015, 1.025, 1.030] {
            XCTAssertEqual(refresh.request(at: now), tail)
        }
        XCTAssertFalse(refresh.consume(tail, at: 1.030))
        XCTAssertTrue(refresh.consume(tail, at: 1.036), "The final parked pointer must still receive a hit-test without another mouse event.")
        XCTAssertNil(refresh.pending)
    }

    func testQuietWindowExtensionPostponesRatherThanLosesHover() throws {
        var refresh = ReadingHoverRefresh()
        let initial = try XCTUnwrap(refresh.request(at: 1, quietUntil: 1.15))
        XCTAssertFalse(refresh.consume(initial, at: 1.10, quietUntil: 1.15))
        let extended = try XCTUnwrap(refresh.request(at: 1.10, quietUntil: 1.25))
        XCTAssertNotEqual(initial, extended)
        XCTAssertFalse(refresh.consume(initial, at: 1.30, quietUntil: 1.25))
        XCTAssertTrue(refresh.consume(extended, at: 1.25, quietUntil: 1.25))
    }

    func testProgressivePageReadyCanRequestAnotherHitTestWithoutPointerInput() throws {
        var refresh = ReadingHoverRefresh()
        let beforePageReady = try XCTUnwrap(refresh.request(at: 4))
        XCTAssertTrue(refresh.consume(beforePageReady, at: 4))
        let pageReady = try XCTUnwrap(refresh.request(at: 4.01))
        XCTAssertGreaterThan(pageReady.deadline, 4.01)
        XCTAssertTrue(refresh.consume(pageReady, at: 4.04))
        XCTAssertFalse(refresh.consume(pageReady, at: 4.05), "A completed page publication schedules one retry, never an unbounded polling loop.")
    }

    func testCancellationRevokesOldTailAcrossPointerOrDocumentChanges() throws {
        var refresh = ReadingHoverRefresh()
        XCTAssertEqual(ReadingSentenceAnchors.pageWindow(current: 2, visible: [2], available: [1, 2, 3]),
                       ReadingSentenceAnchors.pageWindow(current: 2, visible: [1, 2], available: [1, 2, 3]),
                       "A visible-page change can invalidate interaction while retaining the same prepared window; it still needs a fresh tail.")
        let old = try XCTUnwrap(refresh.request(at: 2, quietUntil: 2.15))
        refresh.cancel()
        let current = try XCTUnwrap(refresh.request(at: 2, quietUntil: 2.15))
        XCTAssertNotEqual(old, current)
        XCTAssertFalse(refresh.consume(old, at: 3))
        XCTAssertTrue(refresh.consume(current, at: 3))
        XCTAssertNil(refresh.request(at: .nan))
        XCTAssertNil(refresh.pending)
    }
}
