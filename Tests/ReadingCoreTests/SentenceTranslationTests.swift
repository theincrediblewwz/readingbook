import XCTest
@testable import ReadingCore

final class SentenceTranslationTests: XCTestCase {
    private func book() throws -> BookProject {
        let text = "前文只供理解。贾诩说：先看眼前的事。后文秘密不应该进入句译。"
        return BookProject(title: "句译", originalName: "book.txt", sourceHash: try BookImporter.sha256(Data(text.utf8)),
            units: [SourceUnit(id: "u1", order: 0, chapter: "一", text: text)])
    }
    private func request(_ book: BookProject) throws -> SentenceTranslationRequest {
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: "贾诩说：先看眼前的事。", in: book)
        return try SentenceTranslationRequest.freeze(anchor: anchor, in: book)
    }
    private func result(_ content: String, finish: String = "stop") throws -> ProviderClient.Result {
        let data = try JSONSerialization.data(withJSONObject: ["role": "assistant", "content": content])
        return ProviderClient.Result(message: try JSONDecoder().decode(ProviderClient.Message.self, from: data), finishReason: finish, tokenCost: 8)
    }
    func testExactRequestUsesStableIdentityAndNeverIncludesFollowingText() throws {
        let book = try book(), first = try request(book), second = try request(book)
        XCTAssertEqual(first.cacheID, second.cacheID)
        XCTAssertEqual(first.anchor.quote, "贾诩说：先看眼前的事。")
        XCTAssertFalse(first.precedingText.contains("后文秘密"))
        var changed = book; changed.units[0].text = "已改的原句。"
        XCTAssertThrowsError(try SentenceTranslationRequest.freeze(anchor: first.anchor, in: changed))
    }
    func testProviderGetsBoundedCleanTranslationContextAndAdequateInputBudget() async throws {
        let request = try request(book()), response = try result("贾诩说，先顾好眼前的事情。")
        let output = try await SentenceTranslationEngine.generate(request: request,
            settings: ProviderSettings(model: "offline", maxOutputTokens: 6_000)) { messages, settings, remaining in
            XCTAssertEqual(messages.count, 2); XCTAssertLessThanOrEqual(settings.maxOutputTokens, 1_600)
            XCTAssertGreaterThan(remaining, settings.maxOutputTokens)
            XCTAssertFalse(String(describing: messages).contains("后文秘密"))
            XCTAssertFalse(String(describing: messages).contains("reading_graph"))
            return response
        }
        XCTAssertEqual(output, "贾诩说，先顾好眼前的事情。")
    }
    func testTruncatedAndEmptyOutputAreNotAccepted() async throws {
        let request = try request(book()), truncated = try result("不完整", finish: "length"), empty = try result("  ")
        do { _ = try await SentenceTranslationEngine.generate(request: request, settings: .init()) { _, _, _ in truncated }; XCTFail("不能保存截断译文。") } catch {}
        do { _ = try await SentenceTranslationEngine.generate(request: request, settings: .init()) { _, _, _ in empty }; XCTFail("不能保存空译文。") } catch {}
    }
    func testCanonicalAppendReusesTranslationAndPreservesMarkdownAndConcurrentChat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Sentence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var book = try book(); let original = Data(book.units[0].text.utf8)
        let source = root.appendingPathComponent("book.txt"); try original.write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library", isDirectory: true))
        try await repository.create(book, sourceURL: source)
        let document = DocumentRecord(id: "my-note", title: "我的理解"), body = "# 我的笔记\n\n$x^2$ 和自己的文字。"
        book = try await repository.saveDocument(project: book, document: document, markdown: body)
        let request = try request(book)
        var question = book; question.chats.append(ChatMessage(id: "question", role: "user", content: "这个人物是谁？"))
        _ = try await repository.commitAIResult(base: book, result: question, operationID: "parallel-question")
        let saved = try await repository.saveSentenceTranslation(request: request, markdown: "先顾好眼前的事情。", model: "offline")
        XCTAssertEqual(saved.chats.map(\.id), ["question"])
        XCTAssertEqual(request.cachedLayer(in: saved)?.markdown, "先顾好眼前的事情。")
        let repeated = try await repository.saveSentenceTranslation(request: request, markdown: "不应覆盖旧译文", model: "offline")
        XCTAssertEqual(repeated.readingExperience?.layers.count, 1)
        XCTAssertEqual(request.cachedLayer(in: repeated)?.markdown, "先顾好眼前的事情。")
        let text = try await repository.readDocument(bookID: book.id, document: document)
        XCTAssertEqual(text, body); XCTAssertEqual(try Data(contentsOf: source), original)
        let backup = root.appendingPathComponent("copy.readingbookbackup")
        _ = try await repository.exportLibraryBackup(to: backup)
        let guide = backup.appendingPathComponent("library/books/\(book.id)/AI分析/句旁译注.md")
        XCTAssertTrue(try String(contentsOf: guide, encoding: .utf8).contains("先顾好眼前的事情。"), "立即备份也应刷新派生导览。")
    }
}
