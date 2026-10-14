import Foundation
import XCTest
@testable import ReadingCore

final class StorageTests: XCTestCase {
    private func fixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-StorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func sourceFixture(in directory: URL) async throws -> (BookProject, URL) {
        let source = directory.appendingPathComponent("原书.txt")
        try Data("第一行原书。\n第二行保留细节。\n".utf8).write(to: source, options: .atomic)
        return (try await BookImporter.importFile(at: source), source)
    }

    func testLongLinesAndBlankLinesReconstructWithoutOmission() throws {
        let source = "开始\r\n\r\n" + String(repeating: "数", count: 12_003) + "\r\n末页\n"
        let expected = source.replacingOccurrences(of: "\r\n", with: "\n")
        let units = try BookImporter.splitText(source, chapter: "测试")
        XCTAssertEqual(units.map(\.text).joined(), expected)
        XCTAssertTrue(units.allSatisfy { $0.text.count <= 5_000 })
        XCTAssertEqual(units.map(\.order), Array(0..<units.count))
        let coveredLines = units.reduce(into: Set<Int>()) { $0.formUnion($1.lineStart...$1.lineEnd) }
        XCTAssertEqual(coveredLines, Set(1...5))
        XCTAssertGreaterThanOrEqual(units.filter { $0.lineStart <= 3 && $0.lineEnd >= 3 }.count, 3)
        let blank = try BookImporter.splitText("\n\n", chapter: "空白")
        XCTAssertEqual(blank.map(\.text).joined(), "\n\n")
        XCTAssertEqual(blank.first?.lineStart, 1)
        XCTAssertEqual(blank.last?.lineEnd, 3)
        XCTAssertNotNil(blank.first?.warning)
    }

    func testDocumentBodyIsARealMarkdownFile() async throws {
        let fixture = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let (project, source) = try await sourceFixture(in: fixture)
        let root = fixture.appendingPathComponent("library", isDirectory: true)
        let repository = LibraryRepository(rootURL: root)
        try await repository.create(project, sourceURL: source)
        let document = DocumentRecord(title: "自己的理解", linkedIDs: [project.units[0].id])
        let markdown = "# 我的理解\n\n这是用户写下的正文，保留 $a^2+b^2=c^2$。\n"
        let saved = try await repository.saveDocument(project: project, document: document, markdown: markdown)
        let actual = try await repository.readDocument(bookID: saved.id, document: saved.documents[0])
        XCTAssertEqual(actual, markdown)
        let folder = root.appendingPathComponent("books/\(saved.id)")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(document.relativePath), encoding: .utf8), markdown)
        let metadata = try String(contentsOf: folder.appendingPathComponent("project.json"), encoding: .utf8)
        XCTAssertFalse(metadata.contains("这是用户写下的正文"), "project.json must not mirror Markdown bodies")
        let loaded = try await repository.loadAll()
        XCTAssertEqual(loaded.first?.documents.first?.id, document.id)
    }

    func testFolderPackageRoundTripUsesNewBookIdentityAndSameMarkdown() async throws {
        let fixture = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let (project, source) = try await sourceFixture(in: fixture)
        let repository = LibraryRepository(rootURL: fixture.appendingPathComponent("library"))
        try await repository.create(project, sourceURL: source)
        let document = DocumentRecord(title: "保存的回答", origin: "ai-saved")
        let markdown = "## 用户主动保存\n\n原回答内容。\n\n[原文](readingbook://book/\(project.id)/unit/\(project.units[0].id))\n"
        let saved = try await repository.saveDocument(project: project, document: document, markdown: markdown)
        let package = fixture.appendingPathComponent("备份.readingbook", isDirectory: true)
        try await repository.exportProject(saved, to: package)
        let imported = try await repository.importProject(from: package)
        XCTAssertNotEqual(imported.id, saved.id)
        XCTAssertEqual(imported.sourceHash, saved.sourceHash)
        XCTAssertEqual(imported.documents, saved.documents)
        let importedMarkdown = try await repository.readDocument(bookID: imported.id, document: imported.documents[0])
        XCTAssertEqual(importedMarkdown, markdown.replacingOccurrences(of: "readingbook://book/\(project.id)/", with: "readingbook://book/\(imported.id)/"))
        let books = try await repository.loadAll()
        XCTAssertEqual(books.count, 2, "Import must preserve the existing book")
        do {
            try await repository.exportProject(saved, to: package)
            XCTFail("Export must not replace an existing package")
        } catch { /* Expected: the first package remains untouched. */ }
    }

    func testTraversalAndDanglingReferencesAreRejected() async throws {
        let fixture = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let (project, source) = try await sourceFixture(in: fixture)
        let repository = LibraryRepository(rootURL: fixture.appendingPathComponent("library"))
        try await repository.create(project, sourceURL: source)
        let outside = fixture.appendingPathComponent("outside.md")
        try Data("existing user file".utf8).write(to: outside)
        let escaped = DocumentRecord(id: "note", title: "不合法", relativePath: "../../../outside.md")
        do {
            _ = try await repository.saveDocument(project: project, document: escaped, markdown: "overwrite")
            XCTFail("A document path must not escape docs/")
        } catch { }
        var escapedBook = project
        escapedBook.id = "../../outside"
        do {
            try await repository.save(escapedBook)
            XCTFail("A book ID must not be a path")
        } catch { }
        var dangling = project
        dangling.bookmarks = ["missing-unit"]
        do {
            try await repository.save(dangling)
            XCTFail("A bookmark must reference an existing source unit")
        } catch { }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "existing user file")
        let books = try await repository.loadAll()
        XCTAssertEqual(books.count, 1)
        XCTAssertTrue(books[0].documents.isEmpty)
    }

    func testLoadRecoversInterruptedMarkdownAndMetadataCommit() async throws {
        struct JournalFixture: Codable {
            var version = 1
            var bookID: String
            var documentID: String
            var markdownHash: String
            var project: BookProject
        }
        let fixture = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let (project, source) = try await sourceFixture(in: fixture)
        let root = fixture.appendingPathComponent("library")
        let repository = LibraryRepository(rootURL: root)
        try await repository.create(project, sourceURL: source)
        let document = DocumentRecord(title: "原标题")
        var saved = try await repository.saveDocument(project: project, document: document, markdown: "旧正文")
        saved.documents[0].title = "恢复后的标题"
        let body = Data("# 尚未提交完的真实 Markdown\n".utf8)
        let directory = root.appendingPathComponent("books/\(saved.id)")
        let journal = directory.appendingPathComponent(".journal", isDirectory: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        try body.write(to: journal.appendingPathComponent("document.md"), options: .atomic)
        let payload = JournalFixture(bookID: saved.id, documentID: document.id,
                                     markdownHash: try BookImporter.sha256(body), project: saved)
        try JSONEncoder().encode(payload).write(to: journal.appendingPathComponent("transaction.json"), options: .atomic)
        // Simulate a restart after the Markdown replacement but before project.json.
        try body.write(to: directory.appendingPathComponent(document.relativePath), options: .atomic)
        let restarted = LibraryRepository(rootURL: root)
        let recovered = try await restarted.loadAll()
        XCTAssertEqual(recovered[0].documents[0].title, "恢复后的标题")
        let markdown = try await restarted.readDocument(bookID: saved.id, document: recovered[0].documents[0])
        XCTAssertEqual(markdown, String(decoding: body, as: UTF8.self))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.appendingPathComponent("transaction.json").path))
    }
}
