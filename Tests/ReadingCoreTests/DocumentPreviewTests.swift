import Foundation
import XCTest
@testable import ReadingCore

final class DocumentPreviewTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let repository: LibraryRepository
        var book: BookProject
        var body: URL { root.appendingPathComponent("library/books/" + book.id + "/docs/a.md") }
    }
    private func fixture() async throws -> Fixture {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".build/document-preview-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        try Data("王允问，吕布答。原书保留。".utf8).write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library"))
        var book = try await repository.create(BookImporter.importFile(at: source), sourceURL: source)
        book = try await repository.saveDocument(project: book, document: .init(id: "a", title: "原问题"), markdown: "# 原问题\n\n王允是在试探。 e\u{301} 👩🏽‍💻\n<!-- internal -->")
        book = try await repository.saveDocument(project: book, document: .init(id: "b", title: "空标题"), markdown: "后续独立内容。")
        return Fixture(root: root, repository: repository, book: book)
    }
    private func refuses(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected refusal", file: file, line: line) } catch { }
    }
    func testBatchMatchesSinglePreviewsDeduplicatesAndNeverChangesMarkdown() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try Data(contentsOf: f.body)
        let result = try await f.repository.readFoldedDocumentPreviews(bookID: f.book.id, sourceHash: f.book.sourceHash, documents: f.book.activeDocuments + f.book.activeDocuments)
        XCTAssertEqual(result.count, 2)
        for document in f.book.activeDocuments {
            let single = try await f.repository.readFoldedNotePreview(bookID: f.book.id, sourceHash: f.book.sourceHash, document: document)
            XCTAssertEqual(result[document.id], single)
        }
        XCTAssertEqual(result["a"], "王允是在试探。 e\u{301} 👩🏽‍💻")
        XCTAssertEqual(try Data(contentsOf: f.body), before)
    }
    func testCachedPreviewRejectsWrongSourceAndAnyStaleRecord() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.repository.readFoldedDocumentPreviews(bookID: f.book.id, sourceHash: f.book.sourceHash, documents: f.book.activeDocuments)
        await refuses { _ = try await f.repository.readFoldedDocumentPreviews(bookID: f.book.id, sourceHash: "wrong", documents: f.book.activeDocuments) }
        var changed = f.book.activeDocuments; changed[1].title = "伪造旧引用"
        await refuses { _ = try await f.repository.readFoldedDocumentPreviews(bookID: f.book.id, sourceHash: f.book.sourceHash, documents: changed) }
    }
    func testCachedPrefixRefreshesAfterExternalReplacementAndRejectsMissingFile() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.repository.readFoldedDocumentPreviews(bookID: f.book.id, sourceHash: f.book.sourceHash, documents: f.book.activeDocuments)
        try Data("外部编辑的新正文".utf8).write(to: f.body, options: .atomic)
        let updated = try await f.repository.readFoldedDocumentPreviews(bookID: f.book.id, sourceHash: f.book.sourceHash, documents: f.book.activeDocuments)
        XCTAssertEqual(updated["a"], "外部编辑的新正文")
        try FileManager.default.removeItem(at: f.body)
        await refuses { _ = try await f.repository.readFoldedDocumentPreviews(bookID: f.book.id, sourceHash: f.book.sourceHash, documents: f.book.activeDocuments) }
    }
    func testBatchPreviewsDoNotFollowSymlinksEvenAfterCacheWasWarm() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.repository.readFoldedDocumentPreviews(bookID: f.book.id, sourceHash: f.book.sourceHash, documents: f.book.activeDocuments)
        let outside = f.root.appendingPathComponent("private.txt")
        try Data("不能读取".utf8).write(to: outside)
        try FileManager.default.removeItem(at: f.body)
        try FileManager.default.createSymbolicLink(at: f.body, withDestinationURL: outside)
        await refuses { _ = try await f.repository.readFoldedDocumentPreviews(bookID: f.book.id, sourceHash: f.book.sourceHash, documents: f.book.activeDocuments) }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "不能读取")
    }
    func testBatchReadsBoundedUTF8PrefixAndDoesNotIncludeLongTail() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data(("中文起点 " + String(repeating: "中", count: 6000) + "不能出现在预览的末尾").utf8).write(to: f.body)
        let result = try await f.repository.readFoldedDocumentPreviews(bookID: f.book.id, sourceHash: f.book.sourceHash, documents: f.book.activeDocuments)
        XCTAssertTrue(result["a"]?.hasPrefix("中文起点") == true)
        XCTAssertLessThanOrEqual(result["a"]?.count ?? 999, 91)
        XCTAssertFalse(result["a"]?.contains("不能出现在预览的末尾") == true)
    }
    func testTrashingAndEditingCannotReuseCachedOldRecord() async throws {
        var f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old = f.book.activeDocuments[0]
        _ = try await f.repository.readFoldedNotePreview(bookID: f.book.id, sourceHash: f.book.sourceHash, document: old)
        f.book = try await f.repository.setDocumentTrashed(project: f.book, documentID: old.id, trashed: true)
        await refuses { _ = try await f.repository.readFoldedNotePreview(bookID: f.book.id, sourceHash: f.book.sourceHash, document: old) }
        f.book = try await f.repository.setDocumentTrashed(project: f.book, documentID: old.id, trashed: false)
        let restored = try XCTUnwrap(f.book.activeDocuments.first { $0.id == old.id })
        let snapshot = try await f.repository.readDocumentSnapshot(bookID: f.book.id, document: restored)
        f.book = try await f.repository.saveDocument(project: f.book, document: restored, markdown: "最新内容，不用旧摘要。", expectedContentHash: snapshot.contentHash)
        let latest = try XCTUnwrap(f.book.activeDocuments.first { $0.id == old.id })
        let text = try await f.repository.readFoldedNotePreview(bookID: f.book.id, sourceHash: f.book.sourceHash, document: latest)
        XCTAssertEqual(text, "最新内容，不用旧摘要。")
        await refuses { _ = try await f.repository.readFoldedNotePreview(bookID: f.book.id, sourceHash: f.book.sourceHash, document: old) }
    }
    func testEmptyAndOversizeBatchesAreBoundedWithoutCreatingLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("must-not-be-created-" + UUID().uuidString)
        let repository = LibraryRepository(rootURL: root)
        let result = try await repository.readFoldedDocumentPreviews(bookID: "missing", sourceHash: "missing", documents: [])
        XCTAssertTrue(result.isEmpty)
        await refuses { _ = try await repository.readFoldedDocumentPreviews(bookID: "missing", sourceHash: "missing", documents: Array(repeating: .init(id: "a", title: "a"), count: 257)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testCancelledBatchDoesNotReadOrChangeFilesAndRepositoryRemainsUsable() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try Data(contentsOf: f.body)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await f.repository.readFoldedDocumentPreviews(bookID: f.book.id, sourceHash: f.book.sourceHash, documents: f.book.activeDocuments)
        }
        task.cancel()
        await refuses { _ = try await task.value }
        XCTAssertEqual(try Data(contentsOf: f.body), before)
        let result = try await f.repository.readFoldedDocumentPreviews(bookID: f.book.id, sourceHash: f.book.sourceHash, documents: f.book.activeDocuments)
        XCTAssertEqual(result.count, 2)
    }
}
