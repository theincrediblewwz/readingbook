import Foundation
import XCTest
@testable import ReadingCore

final class QuestionPanelGeometryTests: XCTestCase {
    func testFiveDocksClampToReaderSafeBoundsAndTinyWindowsKeepPreferredTie() {
        let bounds = QuestionPanelGeometry.availableBounds(CGRect(x: 20, y: 88, width: 1160, height: 616), viewport: CGSize(width: 1200, height: 800))
        let size = QuestionPanelGeometry.fittedSize(requested: QuestionPanelGeometry.defaultSize, in: bounds)
        for dock in FloatingPanelDock.allCases {
            let frame = QuestionPanelGeometry.frame(at: dock, in: bounds, panel: size)
            XCTAssertTrue(bounds.contains(frame))
            XCTAssertEqual(QuestionPanelGeometry.nearest(to: CGPoint(x: frame.midX, y: frame.midY), in: bounds, panel: size), dock)
        }
        let defaultFrame = QuestionPanelGeometry.frame(at: .bottomTrailing, in: bounds, panel: size)
        XCTAssertEqual(defaultFrame.maxX, 1180); XCTAssertEqual(defaultFrame.maxY, 704)
        let tiny = CGRect(x: 20, y: 88, width: 240, height: 26)
        let fitted = QuestionPanelGeometry.fittedSize(requested: size, in: tiny)
        XCTAssertEqual(fitted, tiny.size, "窄窗可低于推荐最小尺寸，不能越出真实空间。")
        XCTAssertEqual(QuestionPanelGeometry.nearest(to: CGPoint(x: tiny.midX, y: tiny.midY), in: tiny, panel: fitted, preferred: .bottomTrailing), .bottomTrailing)
        XCTAssertEqual(QuestionPanelGeometry.clampedFrame(CGRect(x: -1000, y: 9000, width: 440, height: 184), in: tiny), tiny)
        XCTAssertEqual(QuestionPanelGeometry.availableBounds(.null, viewport: .zero), .zero)
    }

    func testResizeKeepsOppositeCornerAndHonorsMinimumMaximumAndWindowEdges() {
        let bounds = CGRect(x: 20, y: 88, width: 1160, height: 616)
        let start = QuestionPanelGeometry.frame(at: .bottomTrailing, in: bounds, panel: QuestionPanelGeometry.defaultSize)
        let corner = QuestionPanelGeometry.resizeCorner(for: .bottomTrailing)
        let grown = QuestionPanelGeometry.resizedFrame(from: start, delta: CGSize(width: -200, height: -200), corner: corner, in: bounds)
        XCTAssertEqual(grown.size, CGSize(width: 640, height: 384))
        XCTAssertEqual(grown.maxX, start.maxX); XCTAssertEqual(grown.maxY, start.maxY)
        let maximum = QuestionPanelGeometry.resizedFrame(from: start, delta: CGSize(width: -10000, height: -10000), corner: corner, in: bounds)
        XCTAssertEqual(maximum.size, QuestionPanelGeometry.maximumSize); XCTAssertTrue(bounds.contains(maximum))
        let minimum = QuestionPanelGeometry.resizedFrame(from: start, delta: CGSize(width: 10000, height: 10000), corner: corner, in: bounds)
        XCTAssertEqual(minimum.size, QuestionPanelGeometry.minimumSize)
        let invalid = QuestionPanelGeometry.resizedFrame(from: start, delta: CGSize(width: .nan, height: .infinity), corner: corner, in: bounds)
        XCTAssertEqual(invalid, start)
        for dock in FloatingPanelDock.allCases {
            let origin = QuestionPanelGeometry.frame(at: dock, in: bounds, panel: QuestionPanelGeometry.defaultSize)
            let frame = QuestionPanelGeometry.resizedFrame(from: origin, delta: CGSize(width: 10000, height: -10000), corner: QuestionPanelGeometry.resizeCorner(for: dock), in: bounds)
            XCTAssertTrue(bounds.contains(frame))
        }
    }

    func testPanelSizeAndDockRemainOptionalAndResetOnlyDisposableLayout() throws {
        let legacy = try JSONDecoder().decode(WorkspacePanelMemory.self, from: Data(#"{"origin":{"x":5,"y":7},"isPresented":true,"collapsed":false}"#.utf8))
        XCTAssertNil(legacy.size); XCTAssertNil(legacy.dock)
        var memory = BookWorkspaceMemory(bookID: "book", sourceHash: "source")
        memory.route = "query"; memory.pdf = WorkspacePDFMemory(page: 8)
        memory.panels["reader.question"] = WorkspacePanelMemory(collapsed: true, size: WorkspaceSize(width: 620, height: 280), dock: FloatingPanelDock.bottomTrailing.rawValue)
        let restored = try JSONDecoder().decode(BookWorkspaceMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(restored.panels["reader.question"]?.size, WorkspaceSize(width: 620, height: 280))
        XCTAssertEqual(restored.panels["reader.question"]?.dock, FloatingPanelDock.bottomTrailing.rawValue)
        memory.panels["bad-size"] = WorkspacePanelMemory(size: WorkspaceSize(width: .nan, height: 10), dock: "unknown")
        let sanitized = memory.sanitized(bookID: "book", sourceHash: "source")
        XCTAssertNil(sanitized.panels["bad-size"]?.size); XCTAssertNil(sanitized.panels["bad-size"]?.dock)
        XCTAssertEqual(sanitized.route, "query"); XCTAssertEqual(sanitized.pdf?.page, 8)
        memory.resetLayout()
        XCTAssertTrue(memory.panels.isEmpty); XCTAssertEqual(memory.route, "query"); XCTAssertEqual(memory.pdf?.page, 8)
    }
}
