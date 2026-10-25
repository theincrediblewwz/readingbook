import Foundation
import XCTest
@testable import ReadingCore

final class AIProjectMergeTests: XCTestCase {
    func testHostExplanationCacheAndTransportHistoryDoNotInvalidateReviewedAuthority() throws {
        let base = BookProject(title: "旧功能", originalName: "book.txt", sourceHash: String(repeating: "a", count: 64), units: [])
        var derived = base; derived.readingKnowledge = ReadingKnowledgeState()
        derived.aiRequestHistory = [AIRequestHistoryRecord(id: "request", title: "老师讲解", number: 1,
            startedAt: Date(), finishedAt: Date(), status: "returned", reasoningCharacters: 12, answerCharacters: 20)]
        XCTAssertEqual(try ControlledChangeRecords.revision(base), try ControlledChangeRecords.revision(derived))
        derived.entities.append(KnowledgeEntity(id: "new", typeID: "person", name: "真正的对象变化"))
        XCTAssertNotEqual(try ControlledChangeRecords.revision(base), try ControlledChangeRecords.revision(derived), "不能把真实知识变更也排除出审阅版本。")
    }
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

    func testCanonicalEquivalentSourceBytesInvalidateCachedManifestAndRejectStaleMerge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-SourceBytes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let decomposed = "Cafe\u{301} 的原文。", composed = "Caf\u{e9} 的原文。"
        XCTAssertEqual(decomposed, composed, "此回归必须覆盖Swift规范等价但原始字节不同的情况。")
        XCTAssertFalse(decomposed.utf8.elementsEqual(composed.utf8))
        let original = Data(decomposed.utf8), source = directory.appendingPathComponent("book.txt")
        try original.write(to: source)
        let library = directory.appendingPathComponent("library", isDirectory: true)
        let repository = LibraryRepository(rootURL: library)
        var book = BookProject(title: "原文字节", originalName: "book.txt", sourceHash: try BookImporter.sha256(original),
            units: [SourceUnit(id: "u1", order: 0, chapter: "一", text: decomposed)])
        PluginEngine.seed(&book)
        book.smartReading = try SmartReadingRuntime.freeze(SmartReadingSelection(execution: .init()), in: book, currentUnitID: "u1")
        try await repository.create(book, sourceURL: source)
        try await repository.save(book) // Warm the same repository actor's manifest cache.
        let managedSource = await repository.sourceURL(for: book)
        let metadataURL = library.appendingPathComponent("books/\(book.id)/project.json")
        let metadata = try Data(contentsOf: metadataURL)
        var changed = book; changed.units[0].text = composed
        XCTAssertEqual(book.units, changed.units, "Synthesized SourceUnit equality alone cannot protect a byte-derived hash.")
        do { try await repository.save(changed); XCTFail("不能把旧缓存哈希复用到字节已改变的规范等价原文。") } catch {}
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: managedSource), original)
        let books = try await repository.loadAll(), saved = try XCTUnwrap(books.first)
        XCTAssertTrue(saved.units[0].text.utf8.elementsEqual(decomposed.utf8))
        XCTAssertEqual(saved.smartReading?.unitHashes["u1"], try BookImporter.sha256(original))
        var result = book; result.chats.append(ChatMessage(id: "answer", role: "assistant", content: "旧原文上的回答"))
        XCTAssertThrowsError(try AIProjectMerge.merge(base: book, result: result, latest: changed), "原文UTF8已变化，旧分析不能跨版本合并。")
        result.units[0].text = composed
        XCTAssertThrowsError(try AIProjectMerge.merge(base: book, result: result, latest: book), "分析结果本身也不能偷偷更换为规范等价但字节不同的原文。")
    }
}
