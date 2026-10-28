import Foundation
import XCTest
@testable import ReadingCore

final class ReadingControlRowsGeometryTests: XCTestCase {
    private let sizes = [CGSize(width: 100, height: 40), CGSize(width: 160, height: 44), CGSize(width: 44, height: 32)]

    func testWideRowsPreserveOrderAndPutSpareSpaceAfterFirstGroup() {
        let plan = ReadingControlRowsGeometry.plan(idealSizes: sizes, proposedWidth: 400,
            narrowRows: [[0, 2], [1]])
        XCTAssertEqual(plan.rows, [[0, 1, 2]])
        XCTAssertEqual(plan.size, CGSize(width: 400, height: 44))
        XCTAssertEqual(plan.frames[0], CGRect(x: 0, y: 2, width: 100, height: 40))
        XCTAssertEqual(plan.frames[1], CGRect(x: 188, y: 0, width: 160, height: 44))
        XCTAssertEqual(plan.frames[2], CGRect(x: 356, y: 6, width: 44, height: 32))
    }

    func testNarrowRowsKeepSendButtonBesideScopeAndFullWidthSecondGroup() {
        let plan = ReadingControlRowsGeometry.plan(idealSizes: sizes, proposedWidth: 240,
            fittedHeights: [40, 92, 32], narrowRows: [[0, 2], [1]])
        XCTAssertEqual(plan.rows, [[0, 2], [1]])
        XCTAssertEqual(plan.size, CGSize(width: 240, height: 136))
        XCTAssertEqual(plan.frames[2], CGRect(x: 196, y: 4, width: 44, height: 32))
        XCTAssertEqual(plan.frames[1], CGRect(x: 0, y: 44, width: 240, height: 92))
    }

    func testExactFitAndUnspecifiedProposalUseOneRow() {
        for width: CGFloat? in [320, nil, .infinity, .nan] {
            let plan = ReadingControlRowsGeometry.plan(idealSizes: sizes, proposedWidth: width)
            XCTAssertEqual(plan.rows, [[0, 1, 2]])
            XCTAssertEqual(plan.size.width, 320)
        }
    }

    func testInvalidNarrowRowsCannotDropOrDuplicateControls() {
        let plan = ReadingControlRowsGeometry.plan(idealSizes: sizes, proposedWidth: 120,
            narrowRows: [[0, 0, -1], [], [8, 2]])
        XCTAssertEqual(plan.rows, [[0], [2], [1]])
        XCTAssertEqual(plan.rows.flatMap { $0 }.sorted(), [0, 1, 2])
        XCTAssertTrue(plan.frames.allSatisfy { $0.width == 120 })
    }

    func testEmptyAndNonFiniteInputsRemainFiniteAndKeepEveryChild() {
        XCTAssertEqual(ReadingControlRowsGeometry.plan(idealSizes: [], proposedWidth: 400).size, .zero)
        let plan = ReadingControlRowsGeometry.plan(idealSizes: [CGSize(width: CGFloat.infinity, height: CGFloat.nan), CGSize(width: -40, height: 12)],
            proposedWidth: -10, horizontalSpacing: .nan, rowSpacing: .infinity)
        XCTAssertEqual(plan.size, CGSize(width: 0, height: 16))
        XCTAssertEqual(plan.rows, [[0], [1]])
        XCTAssertTrue(plan.frames.allSatisfy { [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) })
    }
}
