import Foundation
import CryptoKit
import XCTest
@testable import ReadingCore

final class LibraryDocumentSearchTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let repository: LibraryRepository
        let project: BookProject
        let texts: [String: String]
        var package: URL { directory.appendingPathComponent("library/books/" + project.id) }
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-document-search-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.txt"), bytes = Data("原书 e\u{301} 😀。".utf8)
        try bytes.write(to: source)
        let repository = LibraryRepository(rootURL: directory.appendingPathComponent("library"))
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var project = try await repository.create(BookProject(title: "笔记检索", originalName: "source.txt", sourceHash: hash,
            units: [SourceUnit(id: "unit", order: 0, chapter: "一", text: "原书 e\u{301} 😀。")]), sourceURL: source)
        var texts: [String: String] = [:]
        for index in 0..<4 {
            let document = DocumentRecord(id: "note-\(index)", title: "笔记\(index)")
            let markdown = "# 笔记\(index)\n\n完整原文 e\u{301} 😀，以及 [来源](readingbook://book/\(project.id)/unit/unit)。\n"
            project = try await repository.saveDocument(project: project, document: document, markdown: markdown)
            texts[document.id] = markdown
        }
        return Fixture(directory: directory, repository: repository, project: project, texts: texts)
    }
    private func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func metadata(_ fixture: Fixture) throws -> Data { try Data(contentsOf: fixture.package.appendingPathComponent("project.json")) }

    func testBatchSearchReturnsCompleteUnicodeAndOnlyRequestedActiveDocumentsWithoutWrites() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let current = try await f.repository.setDocumentTrashed(project: f.project, documentID: "note-3", trashed: true)
        let source = await f.repository.sourceURL(for: current)
        let before = try metadata(f), original = try Data(contentsOf: source)
        let documents = Array(current.activeDocuments.reversed())
        var expected: [String: String] = [:]
        for document in documents { expected[document.id] = try await f.repository.readDocument(bookID: current.id, document: document) }
        let actual = try await f.repository.readDocumentsForSearch(bookID: current.id, sourceHash: current.sourceHash, documents: documents)
        XCTAssertEqual(try bytes(actual), try bytes(expected))
        XCTAssertEqual(Set(actual.keys), Set(documents.map(\.id)))
        XCTAssertEqual(Data(actual["note-0"]!.utf8), Data(f.texts["note-0"]!.utf8))
        XCTAssertEqual(try metadata(f), before)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testBatchSearchRejectsWrongSourceMissingDuplicateAndChangedDocumentReferences() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let documents = f.project.activeDocuments, before = try metadata(f)
        var path = documents[0]; path.relativePath = "../outside.md"
        var version = documents[0]; version.updatedAt = version.updatedAt.addingTimeInterval(-1)
        let missing = DocumentRecord(id: "not-in-this-book", title: "未授权")
        let cases: [(String, String, [DocumentRecord])] = [
            (f.project.id, String(repeating: "b", count: 64), documents),
            (UUID().uuidString, f.project.sourceHash, documents),
            (f.project.id, f.project.sourceHash, [documents[0], documents[0]]),
            (f.project.id, f.project.sourceHash, [documents[1], missing]),
            (f.project.id, f.project.sourceHash, [path]),
            (f.project.id, f.project.sourceHash, [version])]
        for (id, hash, selected) in cases {
            do { _ = try await f.repository.readDocumentsForSearch(bookID: id, sourceHash: hash, documents: selected); XCTFail("其他来源、版本或文档不能进入检索缓存。") }
            catch { XCTAssertFalse(error is CancellationError, "非取消的无效引用必须被拒绝。") }
            XCTAssertEqual(try metadata(f), before)
        }
    }

    func testBatchSearchRejectsNewlyTrashedAndRevisedDocuments() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let old = f.project.activeDocuments
        let current = try await f.repository.setDocumentTrashed(project: f.project, documentID: old[0].id, trashed: true)
        do { _ = try await f.repository.readDocumentsForSearch(bookID: current.id, sourceHash: current.sourceHash, documents: old); XCTFail("已移入回收站的笔记不能沿用旧列表。") }
        catch { XCTAssertTrue(error is ReadingError) }
        let opened = try await f.repository.readDocumentSnapshot(bookID: current.id, document: old[1])
        _ = try await f.repository.saveDocument(project: current, document: old[1], markdown: "新版本 e\u{301} 😀", expectedContentHash: opened.contentHash)
        do { _ = try await f.repository.readDocumentsForSearch(bookID: current.id, sourceHash: current.sourceHash, documents: [old[1]]); XCTFail("新正文不能被标记成旧版本。") }
        catch { XCTAssertTrue(error is ReadingError) }
    }

    func testBatchSearchReadsCurrentBytesAndRejectsSymlinksInvalidUTF8AndOversizeFiles() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let documents = f.project.activeDocuments, file = f.package.appendingPathComponent(documents[0].relativePath), before = try metadata(f)
        let changed = "外部更新的原始 e\u{301} 😀 字节\n"
        try Data(changed.utf8).write(to: file)
        let fresh = try await f.repository.readDocumentsForSearch(bookID: f.project.id, sourceHash: f.project.sourceHash, documents: documents)
        XCTAssertEqual(Data(fresh[documents[0].id]!.utf8), Data(changed.utf8), "不能用跨调用正文缓存替代本次读取。")
        let outside = f.directory.appendingPathComponent("outside.md"); try Data("不应读取".utf8).write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        do { _ = try await f.repository.readDocumentsForSearch(bookID: f.project.id, sourceHash: f.project.sourceHash, documents: documents); XCTFail("不能沿符号链接离开书籍文档目录。") }
        catch { XCTAssertTrue(error is ReadingError) }
        try FileManager.default.removeItem(at: file)
        for bad in [Data([0xF0, 0x28, 0x8C, 0x28]), Data(repeating: 65, count: 16 * 1024 * 1024 + 1)] {
            try bad.write(to: file)
            do { _ = try await f.repository.readDocumentsForSearch(bookID: f.project.id, sourceHash: f.project.sourceHash, documents: documents); XCTFail("非法UTF-8或超限正文不能返回部分检索缓存。") }
            catch { XCTAssertTrue(error is ReadingError) }
        }
        XCTAssertEqual(try metadata(f), before)
    }

    func testCancelledBatchLeavesRepositoryAvailableAndDoesNotWriteMetadata() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let before = try metadata(f), project = f.project, owner = f.repository
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await owner.readDocumentsForSearch(bookID: project.id, sourceHash: project.sourceHash, documents: project.activeDocuments)
        }
        do { _ = try await cancelled.value; XCTFail("取消必须在准备正文前传播。") }
        catch { XCTAssertTrue(error is CancellationError) }
        let following = try await owner.readDocumentsForSearch(bookID: project.id, sourceHash: project.sourceHash, documents: project.activeDocuments)
        XCTAssertEqual(try bytes(following), try bytes(f.texts))
        XCTAssertEqual(try metadata(f), before)
    }

    func testEmptyBatchDoesNotCreateMissingLibraryOrBook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-empty-search-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = LibraryRepository(rootURL: root)
        let actual = try await owner.readDocumentsForSearch(bookID: UUID().uuidString, sourceHash: String(repeating: "a", count: 64), documents: [])
        XCTAssertTrue(actual.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
