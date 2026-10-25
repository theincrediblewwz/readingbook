import Foundation
import XCTest
@testable import ReadingCore

final class ReadingKnowledgeTests: XCTestCase {
    private func book() throws -> BookProject {
        let first = "贾诩善于谋划。", later = "贾诩后来在军中献策。"
        var book = BookProject(title: "陪读测试", originalName: "book.txt", sourceHash: try BookImporter.sha256(Data((first + "\n" + later).utf8)),
            units: [SourceUnit(id: "u1", order: 0, chapter: "一", text: first), SourceUnit(id: "u2", order: 1, chapter: "二", text: later)])
        PluginEngine.seed(&book)
        book.entities = [KnowledgeEntity(id: "jia", typeID: "person", name: "贾诩", summary: "善于谋划。",
            evidence: [Evidence(unitID: "u1", quote: first)])]
        return book
    }
    private func record(_ request: TeacherBackgroundRequest, markdown: String = "贾诩是汉末的一位谋士。这里先记住他善于观察局势，就容易理解这段话。") -> TeacherBackgroundRecord {
        TeacherBackgroundRecord(id: "teacher-fixture", objectID: request.objectID, sourceHash: request.sourceHash,
            contextFingerprint: request.contextFingerprint, unitHashes: request.unitHashes, evidence: request.evidence,
            avoidsSpoilers: request.avoidsSpoilers, cursorOrder: request.cursorOrder, title: request.title, markdown: markdown, model: "fixture")
    }

    func testOptionalKnowledgeDoesNotRewriteLegacyObjectsAndLaterEvidenceKeepsEarlierVersion() throws {
        let original = try book()
        let bytes = try JSONEncoder().encode(original)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("readingKnowledge"))
        let legacy = try JSONDecoder().decode(BookProject.self, from: bytes)
        XCTAssertNil(legacy.readingKnowledge); XCTAssertEqual(legacy.entities, original.entities)
        var next = original
        next.entities[0].summary += "后来在军中献策。"
        next.entities[0].evidence.append(Evidence(unitID: "u2", quote: next.units[1].text))
        try ReadingKnowledgeRuntime.captureVersions(before: original, in: &next)
        XCTAssertEqual(next.readingKnowledge?.versions.count, 2)
        let early = try XCTUnwrap(ReadingSpoilerProjection.entity(next.entities[0], in: next, allowedUnitIDs: ["u1"]))
        XCTAssertEqual(early.summary, original.entities[0].summary)
        XCTAssertEqual(early.evidence.map(\.unitID), ["u1"])
        XCTAssertEqual(next.entities[0].summary, "善于谋划。后来在军中献策。", "只读投影不能覆盖完整对象。")
        let reused = try XCTUnwrap(SavedKnowledgeReuse(project: next, currentUnitIDs: ["u1"])?.record(id: "jia"))
        XCTAssertEqual(reused["summary"] as? String, original.entities[0].summary)
        try ReadingKnowledgeRuntime.validateStoredState(in: next)
    }

    func testEvidenceOnlyUpdatesDoNotDuplicateSummaryAndStaleWindowsRetainNewCache() throws {
        let original = try book()
        var next = original
        next.entities[0].evidence.append(Evidence(unitID: "u2", quote: next.units[1].text))
        try ReadingKnowledgeRuntime.captureVersions(before: original, in: &next)
        XCTAssertEqual(next.readingKnowledge?.versions.count, 1)
        let request = try TeacherBackgroundRequest.freeze(objectID: "jia", in: next, currentUnitID: "u1", avoidsSpoilers: true)
        next.readingKnowledge?.backgrounds = [record(request)]
        var stale = original
        stale.chats.append(ChatMessage(id: "question", role: "user", content: "这是谁？"))
        try ReadingKnowledgeRuntime.captureVersions(before: next, in: &stale)
        XCTAssertEqual(stale.readingKnowledge?.versions, next.readingKnowledge?.versions)
        XCTAssertEqual(stale.readingKnowledge?.backgrounds, next.readingKnowledge?.backgrounds)
        var conflicting = stale
        conflicting.readingKnowledge?.backgrounds[0].markdown = "旧窗口不能覆盖新介绍。"
        XCTAssertThrowsError(try ReadingKnowledgeRuntime.captureVersions(before: next, in: &conflicting))
    }

    func testCacheReusesUnchangedKnowledgeAcrossPagesButNeverAcrossSpoilerModesOrOCR() throws {
        var book = try book()
        let request = try TeacherBackgroundRequest.freeze(objectID: "jia", in: book, currentUnitID: "u1", avoidsSpoilers: true)
        book.readingKnowledge = ReadingKnowledgeState()
        book.readingKnowledge?.backgrounds = [record(request)]
        let later = try TeacherBackgroundRequest.freeze(objectID: "jia", in: book, currentUnitID: "u2", avoidsSpoilers: true)
        XCTAssertEqual(request.contextFingerprint, later.contextFingerprint)
        XCTAssertNotNil(ReadingKnowledgeRuntime.background(for: later, in: book), "相同介绍到后页应直接复用，不重新请求。")
        let open = try TeacherBackgroundRequest.freeze(objectID: "jia", in: book, currentUnitID: "u2", avoidsSpoilers: false)
        XCTAssertNil(ReadingKnowledgeRuntime.background(for: open, in: book))
        var changed = book; changed.units[0].text += "修订识别。"
        try ReadingKnowledgeRuntime.validateStoredState(in: changed)
        XCTAssertNil(ReadingKnowledgeRuntime.background(for: request, in: changed), "原文哈希改变，即便旧引文仍存在，也不能复用。")
        changed.entities = []
        try ReadingKnowledgeRuntime.validateStoredState(in: changed)
        XCTAssertEqual(changed.readingKnowledge?.backgrounds.count, 1, "回收或OCR不能删除缓存，恢复现场保留。")
        XCTAssertTrue(ReadingKnowledgeRuntime.readableBackgrounds(in: changed).isEmpty)
    }

    func testFutureCacheCannotLeakBackAndSourceSlicesAreRespected() throws {
        var book = try book(), later = try book()
        later.entities[0].summary = "后来献策。"; later.entities[0].evidence = [Evidence(unitID: "u2", quote: later.units[1].text)]
        let future = try TeacherBackgroundRequest.freeze(objectID: "jia", in: later, currentUnitID: "u2", avoidsSpoilers: true)
        book.readingKnowledge = ReadingKnowledgeState(); book.readingKnowledge?.backgrounds = [record(future)]
        let early = try TeacherBackgroundRequest.freeze(objectID: "jia", in: book, currentUnitID: "u1", avoidsSpoilers: true)
        XCTAssertNil(ReadingKnowledgeRuntime.background(for: early, in: book))
        var changed = book; changed.entities[0].summary += "另一条解释。"
        try ReadingKnowledgeRuntime.captureVersions(before: book, in: &changed)
        let selected = SavedKnowledgeReuse(project: changed, currentUnitIDs: ["u1"], currentSlices: ["u1": "善于谋划"])
        XCTAssertNil(selected?.record(id: "jia"), "同unit的选段不能借版本缓存扩大来源。")
    }

    func testIdentitySuggestionsNormalizeTraditionalNamesButNeverMergeOrRevealFutureNames() throws {
        var book = try book()
        book.units[0].text = "賈詡善於謀劃。"
        book.entities[0].name = "賈詡"; book.entities[0].evidence = [Evidence(unitID: "u1", quote: book.units[0].text)]
        book.entities.append(KnowledgeEntity(id: "future", typeID: "person", name: "曹操", evidence: [Evidence(unitID: "u2", quote: "贾诩")]))
        let original = book.entities
        let result = KnowledgeIdentitySuggestions.find("贾诩", in: book, allowedUnitIDs: ["u1"])
        XCTAssertEqual(result.first?.id, "jia"); XCTAssertEqual(result.first?.match, "normalized_name")
        XCTAssertTrue(result.allSatisfy(\.requiresConfirmation)); XCTAssertFalse(result.contains { $0.id == "future" })
        XCTAssertEqual(book.entities, original, "候选提示不能自动合并或改写名字。")
    }

    func testIdentitySuggestionsAreActuallyReturnedByBothReadToolsWithoutCitationGrants() async throws {
        var book = try book()
        book.units[0].text = "賈詡善於謀劃。"
        book.entities[0].name = "賈詡"; book.entities[0].evidence = [Evidence(unitID: "u1", quote: book.units[0].text)]
        let original = book.entities
        let reply = try PluginEngine.apply(name: "knowledge_search", arguments: Data(#"{"query":"贾诩"}"#.utf8),
            to: &book, allowedUnitIDs: ["u1"], phase: .reading)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let suggestions = try XCTUnwrap(parsed["identitySuggestions"] as? [[String: Any]])
        XCTAssertEqual(suggestions.first?["id"] as? String, "jia")
        XCTAssertEqual(suggestions.first?["requiresConfirmation"] as? Bool, true)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .selection, in: book,
            context: ReadingContext(unitID: "u1", selectedText: book.units[0].text))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let read = try await session.execute(name: "objects_search", arguments: ["query": "贾诩"], maximumBytes: 8000)
        let output = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(read.utf8)) as? [String: Any])
        XCTAssertEqual((output["identitySuggestions"] as? [[String: Any]])?.first?["id"] as? String, "jia")
        XCTAssertTrue(session.sourceExcerpts.isEmpty, "身份候选不能伪造已读取原文的引用权限。")
        XCTAssertEqual(book.entities, original)
    }

    func testTeacherPromptIsBoundedToolFreeAndBackgroundIsSeparateFromSourceFacts() async throws {
        let book = try book()
        let request = try TeacherBackgroundRequest.freeze(objectID: "jia", in: book, currentUnitID: "u1", avoidsSpoilers: true)
        let response = try await TeacherBackgroundEngine.generate(request: request,
            settings: ProviderSettings(model: "test", maxOutputTokens: 12_000)) { messages, settings, limit in
            XCTAssertEqual(settings.maxOutputTokens, 1600); XCTAssertLessThanOrEqual(limit, 32_000)
            let prompt = messages.compactMap { $0["content"] as? String }.joined()
            XCTAssertTrue(prompt.contains("不要流程")); XCTAssertTrue(prompt.contains("不说他后来做了什么"))
            XCTAssertFalse(prompt.contains("cards_upsert")); XCTAssertFalse(prompt.contains("reading_analysis"))
            return ProviderClient.Result(message: ProviderClient.Message(role: "assistant", content: "贾诩是汉末的一位谋士。读到这里，可以先留意他怎样观察局势。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 300)
        }
        XCTAssertEqual(response.objectID, "jia"); XCTAssertTrue(response.avoidsSpoilers)
        XCTAssertEqual(book.entities[0].summary, "善于谋划。", "背景从来不回写有原文证据的摘要。")
        var stored = book; stored.readingKnowledge = ReadingKnowledgeState(); stored.readingKnowledge?.backgrounds = [response]
        try ReadingKnowledgeRuntime.validateStoredState(in: stored)
        XCTAssertEqual(ReadingKnowledgeRuntime.readableBackgrounds(in: stored).first?.markdown, response.markdown)
    }

    func testBackgroundCanonicalSavePreservesMarkdownAndStaleWindowCannotEraseIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Teacher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var book = try book()
        let source = root.appendingPathComponent("book.txt")
        let original = Data(book.units.map(\.text).joined(separator: "\n").utf8); try original.write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library", isDirectory: true))
        try await repository.create(book, sourceURL: source)
        let document = DocumentRecord(id: "note", title: "我的笔记")
        let body = "# 我的理解\n\n正文与 $x^2$ 不变。"
        book = try await repository.saveDocument(project: book, document: document, markdown: body)
        let request = try TeacherBackgroundRequest.freeze(objectID: "jia", in: book, currentUnitID: "u1", avoidsSpoilers: true)
        let saved = try await repository.saveTeacherBackground(bookID: book.id, record: record(request))
        XCTAssertEqual(saved.entities, book.entities)
        var stale = book; stale.bookmarks = ["u1"]
        try await repository.save(stale)
        let currentDocument = try await repository.readDocumentSnapshot(bookID: book.id, document: document)
        _ = try await repository.saveDocument(project: book, document: document, markdown: body + "\n读者又写一句。", expectedContentHash: currentDocument.contentHash)
        let all = try await repository.loadAll(), canonical = try XCTUnwrap(all.first)
        XCTAssertEqual(canonical.readingKnowledge?.backgrounds.count, 1)
        XCTAssertEqual(canonical.entities, book.entities)
        let markdown = try await repository.readDocument(bookID: book.id, document: document)
        XCTAssertEqual(markdown, body + "\n读者又写一句。")
        XCTAssertEqual(try Data(contentsOf: source), original)
        var invalid = record(request); invalid.unitHashes["u1"] = String(repeating: "0", count: 64)
        do { _ = try await repository.saveTeacherBackground(bookID: book.id, record: invalid); XCTFail("不能保存失效来源的背景。") } catch {}
    }
}
