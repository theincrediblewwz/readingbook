import Foundation
import XCTest
@testable import ReadingCore

final class AIProjectMergeTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let source: URL
        let repository: LibraryRepository
        let book: BookProject
        let document: DocumentRecord
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-AIMerge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("book.txt"), text = "贾诩善于谋划。"
        try Data(text.utf8).write(to: source)
        var book = BookProject(title: "并行测试", originalName: "book.txt", sourceHash: try BookImporter.sha256(Data(text.utf8)), units: [SourceUnit(id: "u1", order: 0, chapter: "一", text: text)])
        PluginEngine.seed(&book)
        book.entities = [KnowledgeEntity(id: "jia", typeID: "person", name: "贾诩", evidence: [Evidence(unitID: "u1", quote: text)])]
        let repository = LibraryRepository(rootURL: directory.appendingPathComponent("library", isDirectory: true))
        try await repository.create(book, sourceURL: source)
        let document = DocumentRecord(id: "note", title: "用户的理解")
        book = try await repository.saveDocument(project: book, document: document, markdown: "# 我的笔记\n\n最初的理解。\n")
        return Fixture(directory: directory, source: source, repository: repository, book: book, document: document)
    }

    func testIndependentQuestionAndAnalysisMergeAndDuplicateOperationIsIdempotent() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        var reading = f.book, question = f.book
        reading.entities[0].summary = "善于谋划的人。"; reading.coverage["u1"]?.status = .completed
        question.chats.append(ChatMessage(id: "q", role: "user", content: "这个人是谁？"))
        let readingResult = reading, questionResult = question
        async let a = f.repository.commitAIResult(base: f.book, result: readingResult, operationID: "reading-a")
        async let b = f.repository.commitAIResult(base: f.book, result: questionResult, operationID: "question-b")
        _ = try await (a, b)
        let books = try await f.repository.loadAll(), latest = try XCTUnwrap(books.first)
        XCTAssertEqual(latest.chats.map(\.id), ["q"]); XCTAssertEqual(latest.entities[0].summary, "善于谋划的人。")
        XCTAssertEqual(latest.coverage["u1"]?.status, .completed)
        let replayed = try await f.repository.commitAIResult(base: f.book, result: question, operationID: "question-b")
        XCTAssertEqual(replayed.chats.count, 1); XCTAssertEqual(replayed.appliedOperationIDs.filter { $0 == "question-b" }.count, 1)
        XCTAssertEqual(replayed.entities[0].summary, latest.entities[0].summary)
    }

    func testConflictingSameFieldIsRejectedAndUserMarkdownBodyIsPreserved() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let original = try await f.repository.readDocumentSnapshot(bookID: f.book.id, document: f.document)
        let markdown = "# 用户亲自修改\n\n保留公式 $x^2$ 和新的理解。\n"
        _ = try await f.repository.saveDocument(project: f.book, document: f.document, markdown: markdown, expectedContentHash: original.contentHash)
        var first = f.book, second = f.book
        first.entities[0].summary = "第一条已保存结论。"; second.entities[0].summary = "另一条冲突结论。"
        _ = try await f.repository.commitAIResult(base: f.book, result: first, operationID: "first")
        do { _ = try await f.repository.commitAIResult(base: f.book, result: second, operationID: "second"); XCTFail("同字段冲突不能覆盖较新结果。") } catch {}
        let books = try await f.repository.loadAll(), latest = try XCTUnwrap(books.first)
        XCTAssertEqual(latest.entities[0].summary, "第一条已保存结论。")
        let body = try await f.repository.readDocument(bookID: f.book.id, document: f.document)
        XCTAssertEqual(body, markdown); XCTAssertEqual(try Data(contentsOf: f.source), Data("贾诩善于谋划。".utf8))
        var forbidden = f.book; forbidden.documents[0].title = "AI不该覆盖用户标题"
        XCTAssertThrowsError(try AIProjectMerge.merge(base: f.book, result: forbidden, latest: latest))
    }
}
