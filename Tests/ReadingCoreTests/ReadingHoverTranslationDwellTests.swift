import XCTest
@testable import ReadingCore

final class ReadingHoverTranslationDwellTests: XCTestCase {
    func testLeavingAndReturningRequiresANewFullDwell() throws {
        var intent = ReadingHoverTranslationDwell()
        let first = try XCTUnwrap(intent.update(key: "book/sentence", enabled: true, active: true))
        XCTAssertEqual(intent.update(key: "book/sentence", enabled: true, active: true), first)
        XCTAssertNil(intent.update(key: "book/sentence", enabled: true, active: false))
        let second = try XCTUnwrap(intent.update(key: "book/sentence", enabled: true, active: true))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(intent.consume(first), "取消的计时不能在重新悬停后发请求。")
        XCTAssertTrue(intent.consume(second))
        XCTAssertFalse(intent.consume(second))
        XCTAssertNil(intent.update(key: "book/sentence", enabled: true, active: true))
    }
    func testChangingBookSentenceOrPreferenceInvalidatesPendingRequest() throws {
        var intent = ReadingHoverTranslationDwell()
        let old = try XCTUnwrap(intent.update(key: "libraryA/book/sentence", enabled: true, active: true))
        let next = try XCTUnwrap(intent.update(key: "libraryB/book/sentence", enabled: true, active: true))
        XCTAssertFalse(intent.consume(old))
        XCTAssertNil(intent.update(key: next.key, enabled: false, active: true))
        XCTAssertFalse(intent.consume(next))
        let current = try XCTUnwrap(intent.update(key: "libraryB/book/other", enabled: true, active: true))
        XCTAssertTrue(intent.consume(current))
    }
    func testManualTranslateOrStopCannotBeRestartedByTheOldTimer() throws {
        var intent = ReadingHoverTranslationDwell()
        let ticket = try XCTUnwrap(intent.update(key: "sentence", enabled: true, active: true))
        intent.suppress(key: "sentence")
        XCTAssertFalse(intent.consume(ticket))
        XCTAssertNil(intent.update(key: "sentence", enabled: true, active: true))
        intent.update(key: "sentence", enabled: true, active: false)
        XCTAssertNil(intent.update(key: "sentence", enabled: true, active: true))
        XCTAssertNotNil(intent.update(key: "other-sentence", enabled: true, active: true))
    }
    func testManualActionBeforeTheFirstTimerTaskStillSuppressesThatSentence() {
        var intent = ReadingHoverTranslationDwell()
        intent.suppress(key: "sentence")
        XCTAssertNil(intent.update(key: "sentence", enabled: true, active: true))
        XCTAssertNotNil(intent.update(key: "next-sentence", enabled: true, active: true))
    }
}
