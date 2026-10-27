import Foundation
import XCTest
@testable import ReadingCore

final class ReadingPreparationProgressTests: XCTestCase {
    func testUnknownAndEmptyTotalsNeverManufacturePercentages() {
        XCTAssertNil(ReadingPreparationProgress(phase: .pageText).fraction)
        XCTAssertNil(ReadingPreparationProgress(phase: .nativeLines, completed: 8).fraction)
        XCTAssertNil(ReadingPreparationProgress(phase: .matching, total: 8).fraction)
        let empty = ReadingPreparationProgress(phase: .companion, completed: 0, total: 0)
        XCTAssertEqual(empty.completed, 0)
        XCTAssertEqual(empty.total, 0)
        XCTAssertNil(empty.fraction)
    }

    func testCountsAndPagesAreClampedWithoutOverflow() {
        let invalid = ReadingPreparationProgress(phase: .sourceIndex, page: -1, completed: -5, total: -2)
        XCTAssertNil(invalid.page)
        XCTAssertEqual(invalid.completed, 0)
        XCTAssertEqual(invalid.total, 0)
        XCTAssertNil(invalid.fraction)
        XCTAssertNil(ReadingPreparationProgress(phase: .pageText, page: 0).page)

        let bounded = ReadingPreparationProgress(phase: .geometry, page: 3, completed: Int.max, total: 4)
        XCTAssertEqual(bounded.page, 3)
        XCTAssertEqual(bounded.completed, 4)
        XCTAssertEqual(bounded.fraction, 1)
        let large = ReadingPreparationProgress(phase: .outline, completed: Int.max, total: Int.max)
        XCTAssertEqual(large.fraction, 1)
        XCTAssertEqual(ReadingPreparationProgress(phase: .matching, completed: 3, total: 8).fraction, 0.375)
        XCTAssertEqual(ReadingPreparationProgress(phase: .matching, completed: -1, total: 8).fraction, 0)
    }

    func testEventsPreserveRunIdentityAndExactPhaseValues() {
        let first = UUID(), second = UUID()
        let progress = ReadingPreparationProgress(phase: .matching, page: 2, completed: 3, total: 8)
        XCTAssertEqual(ReadingPreparationEvent.started(first, progress), .started(first, progress))
        XCTAssertNotEqual(ReadingPreparationEvent.started(first, progress), .advanced(first, progress))
        XCTAssertNotEqual(ReadingPreparationEvent.advanced(first, progress), .advanced(second, progress))
        XCTAssertNotEqual(ReadingPreparationEvent.advanced(first, progress),
                          .advanced(first, ReadingPreparationProgress(phase: .geometry, page: 2, completed: 3, total: 8)))
        XCTAssertEqual(ReadingPreparationEvent.finished(first), .finished(first))
        XCTAssertNotEqual(ReadingPreparationEvent.finished(first), .finished(second))
    }
}
