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
    func testChapterTranslationDoesNotSendItsOpeningSentenceAndRejectsOldMixedAnchor() async throws {
        let title = "第三十八回\n定三分隆中决策\n战长江孙氏报仇", opening = "却说玄德三顾茅庐。"
        let text = title + "\n" + opening + "后文不应进入标题的翻译。"
        let project = BookProject(title: "三国", originalName: "book.pdf", sourceHash: try BookImporter.sha256(Data(text.utf8)),
            units: [SourceUnit(id: "u1", order: 0, chapter: "第三十八回", page: 1, text: text)])
        let mixed = try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: "u1", quote: title + "\n" + opening, in: project)
        XCTAssertThrowsError(try SentenceTranslationRequest.freeze(anchor: mixed, in: project))
        let titleAnchor = try XCTUnwrap(ReadingSentenceAnchors.anchors(in: project.units[0], project: project).first)
        let request = try SentenceTranslationRequest.freeze(anchor: titleAnchor, in: project), response = try result("隆中定下三分天下的计策，孙氏在长江一带报仇。")
        XCTAssertEqual(request.anchor.quote, title); XCTAssertTrue(request.precedingText.isEmpty)
        _ = try await SentenceTranslationEngine.generate(request: request, settings: .init()) { messages, _, _ in
            XCTAssertFalse(String(describing: messages).contains(opening))
            XCTAssertFalse(String(describing: messages).contains("后文不应"))
            return response
        }
    }
    func testOldMixedTranslationStaysOnDiskButCannotBeReusedForTheNewTitleOrFirstSentence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-OldTitle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let title = "第十九回 下邳城曹操鏖兵 白门楼吕布殒命", firstSentence = "却说曹操正在城下。"
        let text = title + "\n" + firstSentence
        var project = BookProject(title: "三国", originalName: "source.txt", sourceHash: try BookImporter.sha256(Data(text.utf8)),
            units: [SourceUnit(id: "u1", order: 0, chapter: "三国", text: text)])
        let oldAnchor = try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: "u1", quote: text, in: project)
        let oldIdentity = [project.id, project.sourceHash, oldAnchor.unitID, oldAnchor.unitTextHash, oldAnchor.id, "简体中文"].joined(separator: "|")
        let oldCacheID = "sentence-translation-" + (try BookImporter.sha256(Data(oldIdentity.utf8)))
        project.readingExperience = ReadingExperienceState(anchors: [oldAnchor], layers: [ReadingLayer(id: oldCacheID, kind: "translation", title: "旧句译",
            markdown: "旧译文混入了开篇正文。", sourceAnchorIDs: [oldAnchor.id], provenance: ReadingProvenance(label: "sentence-translation", workTitle: "简体中文"))])
        let source = directory.appendingPathComponent("source.txt"); try Data(text.utf8).write(to: source)
        let repository = LibraryRepository(rootURL: directory.appendingPathComponent("library"))
        try await repository.create(project, sourceURL: source)
        let anchors = ReadingSentenceAnchors.anchors(in: project.units[0], project: project)
        XCTAssertEqual(anchors.map(\.quote), [title, firstSentence])
        let titleRequest = try SentenceTranslationRequest.freeze(anchor: anchors[0], in: project)
        let bodyRequest = try SentenceTranslationRequest.freeze(anchor: anchors[1], in: project)
        XCTAssertNil(titleRequest.cachedLayer(in: project)); XCTAssertNil(bodyRequest.cachedLayer(in: project))
        XCTAssertNotEqual(titleRequest.cacheID, oldCacheID); XCTAssertNotEqual(bodyRequest.cacheID, oldCacheID)
        let oldRequest = SentenceTranslationRequest(bookID: project.id, anchor: oldAnchor, precedingText: "", targetLanguage: "简体中文", cacheID: oldCacheID)
        XCTAssertNil(oldRequest.cachedLayer(in: project), "旧请求实例也不能继续命中错误的混合译文。")
        do { _ = try await repository.saveSentenceTranslation(request: oldRequest, markdown: "仍然错误的范围", model: "offline"); XCTFail("旧跨标题请求不能重新保存或假装复用成功。") }
        catch { XCTAssertTrue(error.localizedDescription.contains("标题与正文")) }
        let saved = try await repository.saveSentenceTranslation(request: titleRequest, markdown: "本回的标题译文。", model: "offline")
        XCTAssertEqual(saved.readingExperience?.layers.count, 2)
        XCTAssertEqual(saved.readingExperience?.layers.first { $0.id == oldCacheID }?.markdown, "旧译文混入了开篇正文。")
        XCTAssertEqual(titleRequest.cachedLayer(in: saved)?.markdown, "本回的标题译文。")
        XCTAssertNil(bodyRequest.cachedLayer(in: saved))
        XCTAssertEqual(saved.units, project.units); XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), text)
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
    func testTranslationWithOneExactAndOneCrossHeadingAnchorIsNeverACacheHit() throws {
        let title = "第38回 定三分隆中决策", text = title + "\n却说玄德三顾茅庐。"
        var project = BookProject(title: "三国", originalName: "source.txt", sourceHash: try BookImporter.sha256(Data(text.utf8)),
            units: [SourceUnit(id: "u1", order: 0, chapter: "三国", text: text)])
        let titleAnchor = try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: "u1", quote: title, in: project)
        let mixed = try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: "u1", quote: text, in: project)
        let request = try SentenceTranslationRequest.freeze(anchor: titleAnchor, in: project)
        for ids in [[titleAnchor.id, mixed.id], [mixed.id, titleAnchor.id]] {
            project.readingExperience = ReadingExperienceState(anchors: [titleAnchor, mixed], layers: [ReadingLayer(id: "old-combined", kind: "translation", title: "旧译文",
                markdown: "旧内容含了第一句正文。", sourceAnchorIDs: ids)])
            XCTAssertNil(request.cachedLayer(in: project), "精确锚并不能替另一个越界锚洗白整个旧layer。")
        }
        project.readingExperience?.layers = [ReadingLayer(id: "exact-title", kind: "translation", title: "本回标题", markdown: "只解释标题。", sourceAnchorIDs: [titleAnchor.id])]
        XCTAssertEqual(request.cachedLayer(in: project)?.id, "exact-title", "合法的单锚旧译注仍可复用。")
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
        let now = Date(), history = AIRequestHistoryRecord(id: UUID().uuidString, title: "句旁翻译", number: 1,
            startedAt: now, finishedAt: now, status: "returned", reasoningCharacters: 2, answerCharacters: 18)
        let repeated = try await repository.saveSentenceTranslation(request: request, markdown: "不应覆盖旧译文", model: "offline", requestHistory: [history])
        XCTAssertEqual(repeated.readingExperience?.layers.count, 1)
        XCTAssertEqual(request.cachedLayer(in: repeated)?.markdown, "先顾好眼前的事情。")
        XCTAssertEqual(repeated.aiRequestHistory?.filter { $0.id == history.id }.count, 1, "并发命中已有译文仍须保存真实请求记录。")
        let third = try await repository.saveSentenceTranslation(request: request, markdown: "仍不覆盖", model: "offline", requestHistory: [history, history])
        XCTAssertEqual(third.aiRequestHistory?.filter { $0.id == history.id }.count, 1, "重复回执不重复记账。")
        let text = try await repository.readDocument(bookID: book.id, document: document)
        XCTAssertEqual(text, body); XCTAssertEqual(try Data(contentsOf: source), original)
        let backup = root.appendingPathComponent("copy.readingbookbackup")
        _ = try await repository.exportLibraryBackup(to: backup)
        let guide = backup.appendingPathComponent("library/books/\(book.id)/AI分析/句旁译注.md")
        XCTAssertTrue(try String(contentsOf: guide, encoding: .utf8).contains("先顾好眼前的事情。"), "立即备份也应刷新派生导览。")
    }
}
