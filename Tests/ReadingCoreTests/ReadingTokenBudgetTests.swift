import XCTest
@testable import ReadingCore

final class ReadingTokenBudgetTests: XCTestCase {
    func testUsageExactlyAtLimitAndOverflowCannotWrapIntoAcceptedBudget() throws {
        var consumed = 1
        XCTAssertThrowsError(try ReadingTokenBudget.charge(Int.max, to: &consumed, limit: 200_000)) { error in
            XCTAssertTrue(error is ReadingWorkflowBudgetPause)
        }
        XCTAssertEqual(consumed, 1, "Rejected usage must not wrap or corrupt the budget.")
        try ReadingTokenBudget.charge(9, to: &consumed, limit: 10)
        XCTAssertEqual(consumed, 10)
        XCTAssertThrowsError(try ReadingTokenBudget.charge(1, to: &consumed, limit: 10))
        XCTAssertEqual(consumed, 10)
        XCTAssertThrowsError(try ReadingTokenBudget.charge(-1, to: &consumed, limit: 10))
    }

    func testInvalidSettingsAreRejectedBeforeDerivedIntegerArithmetic() throws {
        XCTAssertThrowsError(try ReadingTokenBudget.operationLimit(for: ProviderSettings(maxOutputTokens: Int.max)))
        XCTAssertThrowsError(try ReadingTokenBudget.operationLimit(for: ProviderSettings(contextWindowTokens: Int.max)))
        XCTAssertEqual(try ReadingTokenBudget.operationLimit(for: ProviderSettings(maxOutputTokens: 1_048_576)), 1_112_576)
        XCTAssertEqual(try ReadingTokenBudget.operationLimit(for: ProviderSettings(contextWindowTokens: 128_000)), 128_000)
    }
}
