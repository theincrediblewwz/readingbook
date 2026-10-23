import Foundation
import XCTest
@testable import ReadingCore

final class StorageAuditTests: XCTestCase {
    private func fixture() async throws -> (URL, URL, LibraryRepository, BookProject) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-StorageAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("book.txt")
        try Data("可核对的原书内容。\n".utf8).write(to: source, options: .atomic)
        let book = try await BookImporter.importFile(at: source)
        let root = directory.appendingPathComponent("library", isDirectory: true)
        let repository = LibraryRepository(rootURL: root)
        try await repository.create(book, sourceURL: source)
        return (directory, root, repository, book)
    }

    func testInterruptedImportsAndBrokenBookDoNotHideHealthyBookOrDeleteRecoveryData() async throws {
        let (directory, root, repository, book) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let books = root.appendingPathComponent("books")
        let staged = books.appendingPathComponent(".importing-\(UUID().uuidString)", isDirectory: true)
        let invalid = books.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
        let sentinel = staged.appendingPathComponent("recover-me.md"), badJSON = invalid.appendingPathComponent("project.json")
        try Data("保留恢复现场".utf8).write(to: sentinel)
        try Data("broken-json".utf8).write(to: badJSON)
        let report = try await repository.loadReport()
        XCTAssertEqual(report.projects.map(\.id), [book.id]); XCTAssertEqual(report.issues.count, 2)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "保留恢复现场")
        XCTAssertEqual(try String(contentsOf: badJSON, encoding: .utf8), "broken-json")
    }

    func testBrokenTrashEntryDoesNotPreventRestoringHealthyBook() async throws {
        let (directory, root, repository, book) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await repository.archiveBook(project: book)
        let broken = root.appendingPathComponent("trash/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        let report = try await repository.trashReport()
        XCTAssertEqual(report.projects.map(\.id), [book.id]); XCTAssertEqual(report.issues.count, 1)
        let restored = try await repository.restoreBook(id: book.id)
        XCTAssertEqual(restored.id, book.id); XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path))
    }

    func testExternalMarkdownEditRequiresExactBaselineAndPreservesBothVersionsOnConflict() async throws {
        let (directory, root, repository, book) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = DocumentRecord(id: "note", title: "理解")
        let saved = try await repository.saveDocument(project: book, document: document, markdown: "旧正文")
        let body = root.appendingPathComponent("books/\(book.id)/\(document.relativePath)")
        let withBOM = Data([0xef, 0xbb, 0xbf]) + Data("旧正文".utf8)
        try withBOM.write(to: body, options: .atomic)
        let snapshot = try await repository.readDocumentSnapshot(bookID: book.id, document: document)
        XCTAssertEqual(snapshot.contentHash, try BookImporter.sha256(withBOM), "版本来自原始字节，与String是否移除BOM无关。")
        let metadata = body.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("project.json")
        let originalMetadata = try Data(contentsOf: metadata)
        try Data("外部编辑器新正文".utf8).write(to: body, options: .atomic)
        do {
            _ = try await repository.saveDocument(project: saved, document: document, markdown: "App尚未合并的草稿", expectedContentHash: snapshot.contentHash)
            XCTFail("过期正文版本不能覆盖外部编辑。")
        } catch { }
        XCTAssertEqual(try String(contentsOf: body, encoding: .utf8), "外部编辑器新正文")
        XCTAssertEqual(try Data(contentsOf: metadata), originalMetadata)
        do {
            _ = try await repository.saveDocument(project: saved, document: document, markdown: "无版本强写")
            XCTFail("已有正文必须提供版本。")
        } catch { }
        let latest = try await repository.readDocumentSnapshot(bookID: book.id, document: document)
        _ = try await repository.saveDocument(project: saved, document: document, markdown: "用户已对照合并", expectedContentHash: latest.contentHash)
        XCTAssertEqual(try String(contentsOf: body, encoding: .utf8), "用户已对照合并")
    }

    func testRecoveryJournalDoesNotOverwriteAnExternalEditAfterInterruption() async throws {
        struct Journal: Codable {
            var version = 1; var bookID: String; var documentID: String
            var markdownHash: String; var previousMarkdownHash: String?; var project: BookProject
        }
        let (directory, root, repository, book) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = DocumentRecord(id: "note", title: "理解")
        let saved = try await repository.saveDocument(project: book, document: document, markdown: "旧正文")
        let folder = root.appendingPathComponent("books/\(book.id)")
        let journal = folder.appendingPathComponent(".journal", isDirectory: true)
        let pending = Data("App待恢复正文".utf8)
        try pending.write(to: journal.appendingPathComponent("document.md"), options: .atomic)
        let marker = Journal(bookID: book.id, documentID: document.id, markdownHash: try BookImporter.sha256(pending), previousMarkdownHash: try BookImporter.sha256(Data("旧正文".utf8)), project: saved)
        try JSONEncoder().encode(marker).write(to: journal.appendingPathComponent("transaction.json"), options: .atomic)
        let body = folder.appendingPathComponent(document.relativePath)
        try Data("退出后外部修改".utf8).write(to: body, options: .atomic)
        let report = try await repository.loadReport()
        XCTAssertTrue(report.projects.isEmpty); XCTAssertEqual(report.issues.count, 1)
        XCTAssertEqual(try String(contentsOf: body, encoding: .utf8), "退出后外部修改")
        XCTAssertEqual(try Data(contentsOf: journal.appendingPathComponent("document.md")), pending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.appendingPathComponent("transaction.json").path))
    }

    func testNewDocumentNeverOverwritesUnregisteredMarkdown() async throws {
        let (directory, root, repository, book) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = DocumentRecord(id: "orphan", title: "新笔记")
        let body = root.appendingPathComponent("books/\(book.id)/\(document.relativePath)")
        try Data("未登记的恢复资料".utf8).write(to: body, options: .atomic)
        do { _ = try await repository.saveDocument(project: book, document: document, markdown: "覆盖"); XCTFail("不能覆盖未登记正文。") } catch { }
        XCTAssertEqual(try String(contentsOf: body, encoding: .utf8), "未登记的恢复资料")
    }

    func testCachedDocumentValidationStillRejectsReplacementMissingFileAndSymlink() async throws {
        let (directory, root, repository, book) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = DocumentRecord(id: "note", title: "理解")
        let original = Data("正文".utf8)
        let saved = try await repository.saveDocument(project: book, document: document, markdown: "正文")
        try await repository.save(saved) // Admit the original identity to the metadata cache.
        let body = root.appendingPathComponent("books/\(book.id)/\(document.relativePath)")
        let modification = try FileManager.default.attributesOfItem(atPath: body.path)[.modificationDate]
        try Data(repeating: 0xff, count: original.count).write(to: body, options: .atomic)
        if let modification { try FileManager.default.setAttributes([.modificationDate: modification], ofItemAtPath: body.path) }
        do { try await repository.save(saved); XCTFail("相同大小和mtime的替换文件须按新identity重验UTF8。") } catch { }
        try original.write(to: body, options: .atomic); try await repository.save(saved)
        try FileManager.default.removeItem(at: body)
        do { try await repository.save(saved); XCTFail("缺失文件不能使用缓存放行。") } catch { }
        let outside = directory.appendingPathComponent("outside.md"); try original.write(to: outside)
        try FileManager.default.createSymbolicLink(at: body, withDestinationURL: outside)
        do { try await repository.save(saved); XCTFail("符号链接不能使用缓存放行。") } catch { }
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }
}
