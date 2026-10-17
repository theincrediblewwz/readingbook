import XCTest
@testable import ReadingCore

final class WorkspaceMemoryTests: XCTestCase {
    func testHiddenPDFCannotReplaceTextOrParallelReadingPosition() throws {
        var memory = BookWorkspaceMemory(bookID: "a", sourceHash: "s")
        memory.pdf = WorkspacePDFMemory(page: 8)
        XCTAssertEqual(memory.activePDFPage, 8)
        memory.readerShowsPDF = false
        XCTAssertNil(memory.activePDFPage)
        memory.readerShowsPDF = true; memory.readingSourceMode = "parallel"
        XCTAssertNil(memory.activePDFPage)
        let restored = try JSONDecoder().decode(BookWorkspaceMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(restored.readingSourceMode, "parallel"); XCTAssertNil(restored.activePDFPage)
    }
    func testSourceIdentityCannotRestoreAnotherBookOrReplacementSource() {
        var memory = BookWorkspaceMemory(bookID: "a", sourceHash: "first")
        memory.route = "editor"; memory.documentID = "note-a"
        memory.pdf = WorkspacePDFMemory(page: 30)
        XCTAssertEqual(memory.sanitized(bookID: "b", sourceHash: "first"), BookWorkspaceMemory(bookID: "b", sourceHash: "first"))
        XCTAssertEqual(memory.sanitized(bookID: "a", sourceHash: "replacement"), BookWorkspaceMemory(bookID: "a", sourceHash: "replacement"))
    }
    func testInvalidGeometryAndPDFSettingsFallBackWithoutLosingNavigation() {
        var memory = BookWorkspaceMemory(bookID: "a", sourceHash: "s")
        memory.route = "mindmap"; memory.documentID = "valid-note"
        memory.graphs["good"] = WorkspaceGraphCamera(center: WorkspacePoint(x: 100, y: 80), scale: 0.75)
        memory.graphs["bad"] = WorkspaceGraphCamera(center: WorkspacePoint(x: .nan, y: 80), scale: 0.75)
        memory.pdf = WorkspacePDFMemory(page: 0, scale: 100)
        memory.panels["bad"] = WorkspacePanelMemory(origin: WorkspacePoint(x: .infinity, y: 10))
        memory.timeFrom = 100; memory.timeTo = -100
        memory.map = WorkspaceMapMemory(latitude: 200, longitude: 0, latitudeDelta: 2, longitudeDelta: 2)
        let restored = memory.sanitized(bookID: "a", sourceHash: "s")
        XCTAssertEqual(restored.route, "mindmap"); XCTAssertEqual(restored.documentID, "valid-note")
        XCTAssertEqual(restored.graphs.count, 1); XCTAssertNotNil(restored.graphs["good"])
        XCTAssertNil(restored.pdf); XCTAssertNil(restored.map); XCTAssertNil(restored.timeFrom); XCTAssertNil(restored.timeTo)
        XCTAssertTrue(restored.panels.isEmpty)
    }
    func testLayoutResetRetainsReadingAndDocumentPosition() throws {
        var memory = BookWorkspaceMemory(bookID: "a", sourceHash: "s")
        memory.route = "editor"; memory.documentID = "note"
        memory.pdf = WorkspacePDFMemory(page: 8, location: WorkspacePoint(x: 0.2, y: 0.6), scale: 2.5, fitMode: "custom", continuous: false, thumbnails: true)
        memory.graphs["mindmap"] = WorkspaceGraphCamera(center: WorkspacePoint(x: 30, y: 20), scale: 2)
        memory.panels["reader.outline"] = WorkspacePanelMemory(isPresented: true, collapsed: true)
        memory.timeFrom = -10; memory.timeTo = 60
        memory.resetLayout()
        XCTAssertEqual(memory.documentID, "note"); XCTAssertEqual(memory.route, "editor")
        XCTAssertEqual(memory.pdf?.page, 8); XCTAssertEqual(memory.pdf?.location, WorkspacePoint(x: 0.2, y: 0.6))
        XCTAssertEqual(memory.pdf?.fitMode, "width"); XCTAssertTrue(memory.graphs.isEmpty); XCTAssertTrue(memory.panels.isEmpty)
        XCTAssertEqual(memory.timeFrom, -10); XCTAssertEqual(memory.timeTo, 60)
        XCTAssertEqual(try JSONDecoder().decode(BookWorkspaceMemory.self, from: JSONEncoder().encode(memory)), memory)
    }
}
