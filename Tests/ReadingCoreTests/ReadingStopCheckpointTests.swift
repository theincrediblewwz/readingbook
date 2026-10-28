import Foundation
import XCTest
@testable import ReadingCore

final class ReadingStopCheckpointTests: XCTestCase {
    private func fixture() async throws -> (URL, LibraryRepository, BookProject, DocumentRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source.txt"), text = "甲来到城中。"
        try Data(text.utf8).write(to: source)
        var book = BookProject(title: "暂停回归", originalName: "source.txt", sourceHash: try BookImporter.sha256(Data(text.utf8)),
            units: [SourceUnit(id: "u1", order: 0, chapter: "一", text: text)])
        PluginEngine.seed(&book)
        book.smartReading = try SmartReadingRuntime.freeze(SmartReadingSelection(execution: .init()), in: book, currentUnitID: "u1")
        book.smartReading?.status = .running
        book.insights = [ReadingInsight(id: "saved-analysis", unitIDs: ["u1"], markdown: "已保存的阅读所得。")]
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library", isDirectory: true))
        try await repository.create(book, sourceURL: source)
        let document = DocumentRecord(id: "note", title: "我的理解")
        book = try await repository.saveDocument(project: book, document: document, markdown: "# 我的理解\n\n不要改变用户正文。")
        return (root, repository, book, document)
    }

    func testCancelledCallerStillPersistsChinesePauseAndRetainsProducts() async throws {
        let (root, repository, book, document) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = try XCTUnwrap(book.smartReading?.id)
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertTrue(Task.isCancelled)
            return try await repository.checkpointReadingStop(bookID: book.id, sessionID: sessionID, failed: false, message: "已暂停，已保存的内容保留。")
        }
        let result = try await caller.value
        XCTAssertEqual(result?.smartReading?.status, .paused)
        let stored = try await repository.loadAll(), canonical = try XCTUnwrap(stored.first)
        XCTAssertEqual(canonical.smartReading?.status, .paused)
        XCTAssertEqual(canonical.smartReading?.lastMessage, "已暂停，已保存的内容保留。")
        XCTAssertEqual(canonical.insights.map(\.id), ["saved-analysis"])
        XCTAssertEqual(canonical.documents, book.documents)
        let markdown = try await repository.readDocument(bookID: book.id, document: document)
        XCTAssertEqual(markdown, "# 我的理解\n\n不要改变用户正文。")
    }

    func testOldSessionCannotPauseReplacementOrRegressCompletedState() async throws {
        let (root, repository, book, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldID = try XCTUnwrap(book.smartReading?.id)
        var replacement = book
        replacement.smartReading = try SmartReadingRuntime.freeze(SmartReadingSelection(execution: .init(granularity: .page)), in: replacement, currentUnitID: "u1")
        replacement.smartReading?.status = .running
        try await repository.save(replacement)
        let stale = try await repository.checkpointReadingStop(bookID: book.id, sessionID: oldID, failed: false, message: "旧任务迟到的暂停。")
        XCTAssertNil(stale)
        var stored = try await repository.loadAll(), canonical = try XCTUnwrap(stored.first)
        XCTAssertEqual(canonical.smartReading?.id, replacement.smartReading?.id)
        XCTAssertEqual(canonical.smartReading?.status, .running)
        XCTAssertEqual(canonical.insights.map(\.id), ["saved-analysis"])
        canonical.smartReading?.status = .completed
        try await repository.save(canonical)
        let completed = try await repository.checkpointReadingStop(bookID: book.id, sessionID: replacement.smartReading!.id, failed: false, message: "不能降级已完成任务。")
        XCTAssertNil(completed)
        stored = try await repository.loadAll()
        XCTAssertEqual(stored.first?.smartReading?.status, .completed)
    }
}
