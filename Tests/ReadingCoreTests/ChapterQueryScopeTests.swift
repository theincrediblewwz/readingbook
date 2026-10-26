import Foundation
import XCTest
@testable import ReadingCore

final class ChapterQueryScopeTests: XCTestCase {
    private func book() throws -> BookProject {
        var book = BookProject(id: "chapter-query", title: "章界书", originalName: "book.pdf",
            sourceHash: try BookImporter.sha256(Data("chapter-source".utf8)), units: [
                SourceUnit(id: "shared", order: 0, chapter: "章界书", page: 1, text: "第一章\n甲章原文。\n第二章\n乙章原文。é"),
                SourceUnit(id: "blank", order: 1, chapter: "章界书", page: 2, text: "")])
        let entries = try ["第一章", "第二章"].map { title -> BookOutlineEntry in
            let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "shared", quote: title, in: book)
            return BookOutlineEntry(id: anchor.id, title: title, page: 1, anchor: anchor)
        }
        book.originalBookOutline = BookChapterOutline(sourceHash: book.sourceHash,
            sourceFingerprint: try BookOutlineRuntime.fingerprint(in: book), scannedUnitCount: 2, totalUnitCount: 2, entries: entries)
        return book
    }
    private func context(_ book: BookProject, title: String) throws -> ReadingContext {
        let anchor = try XCTUnwrap(book.originalBookOutline?.entries.first { $0.title == title }?.anchor)
        return ReadingContext(sourceHash: book.sourceHash, unitID: anchor.unitID, page: 1, selectedSourceAnchor: anchor)
    }

    func testChapterQueryAndSourceReadStopBeforeNextHeadingInSharedUnit() async throws {
        let book = try book(), context = try context(book, title: "第一章")
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .chapter, in: book, context: context)
        XCTAssertEqual(snapshot.sources.map(\.text), ["第一章\n甲章原文。\n"])
        XCTAssertEqual(snapshot.displayTitle, "当前章节 · 第一章")
        XCTAssertFalse(snapshot.admits(Evidence(unitID: "shared", quote: "乙章原文。")))
        var query = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let content = try await query.execute(name: "source_read", arguments: ["id": "shared"], maximumBytes: 8_000)
        XCTAssertTrue(content.contains("甲章原文")); XCTAssertFalse(content.contains("乙章原文"))
        XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .chapter, in: book, context: ReadingContext(unitID: "shared", page: 1)))
        let second = try ReadingQuerySnapshot.freeze(scope: .chapter, in: book, context: self.context(book, title: "第二章"))
        XCTAssertNotEqual(snapshot.scopeFingerprint, second.scopeFingerprint)
        XCTAssertEqual(try snapshot.scopedSourceUnits(in: book).map(\.text), snapshot.sources.map(\.text))
    }

    func testFrozenSliceRejectsUnicodeEquivalentSourceChangeAndBlankBookProjectionSurvives() throws {
        let book = try book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .chapter, in: book, context: context(book, title: "第一章"))
        var changed = book; changed.units[0].text = changed.units[0].text.replacingOccurrences(of: "é", with: "e\u{301}")
        XCTAssertEqual(book.units[0].text, changed.units[0].text)
        XCTAssertThrowsError(try snapshot.sourceRanges(in: changed), "原句未变也不能把旧范围认作当前字节版本")
        let whole = try ReadingQuerySnapshot.freeze(scope: .book, in: book)
        XCTAssertEqual(try whole.sourceRanges(in: book).count, 1)
        XCTAssertEqual(try whole.scopedSourceUnits(in: book).map(\.text), book.units.map(\.text))
    }

    func testRepeatedSentenceHistoryUsesItsActualPositionAndChapterHistoryStaysInScope() throws {
        var book = try book()
        let first = try ReadingQuerySnapshot.freeze(scope: .chapter, in: book, context: context(book, title: "第一章"))
        let page = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: ReadingContext(unitID: "shared", page: 1))
        let preferences = ReadingAnswerPreferences(interaction: .functional, style: .research)
        var foreign = ChatMessage(role: "user", content: "整页里乙章的秘密")
        foreign.conversationMode = .functional; foreign.answerStyle = .research
        foreign.readingContext = try ReadingChatContext(snapshot: page, avoidsSpoilers: true)
        var local = ChatMessage(role: "user", content: "继续第一章")
        local.conversationMode = .functional; local.answerStyle = .research
        local.readingContext = try ReadingChatContext(snapshot: first, avoidsSpoilers: true)
        book.chats = [foreign, local]
        XCTAssertEqual(ReadingChatHistory.automaticHistory(in: book, preferences: preferences, snapshot: first).map(\.id), [local.id])
        book.units[0].text = "甲\n重复句。\n乙\n重复句。"
        func selected(_ prefix: String) throws -> ReadingQuerySnapshot {
            let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "shared", quote: "重复句。", prefix: prefix, in: book)
            return try ReadingQuerySnapshot.freeze(scope: .selection, in: book,
                context: ReadingContext(unitID: "shared", selectedText: anchor.quote, page: 1, selectedSourceAnchor: anchor))
        }
        let a = try selected("甲\n"), b = try selected("乙\n")
        XCTAssertNotEqual(a.scopeFingerprint, b.scopeFingerprint)
        XCTAssertNotEqual(try ReadingChatContext(snapshot: a, avoidsSpoilers: true).scopeFingerprint,
                          try ReadingChatContext(snapshot: b, avoidsSpoilers: true).scopeFingerprint)
    }

    func testScopedManualEnrichmentUsesOnlyExcerptAndDoesNotForgeReadingCoverage() async throws {
        var book = try book(); PluginEngine.seed(&book); book.plan = ReadingPlan(methodIDs: ["genre.history"])
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .chapter, in: book, context: context(book, title: "第一章"))
        let ranges = try snapshot.sourceRanges(in: book)
        let reader = AIReader(transport: { prepared in
            let data = try XCTUnwrap(prepared.request.httpBody)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
            let prompt = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
            XCTAssertTrue(prompt.contains("甲章原文")); XCTAssertFalse(prompt.contains("乙章原文"))
            XCTAssertFalse(prompt.contains("é"))
            let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["noChangesReason": "本章已有内容足够，无需补充。"]), as: UTF8.self)
            return ProviderClient.Result(message: .init(role: "assistant", content: nil, refusal: nil,
                tool_calls: [.init(id: "excerpt-call", type: "function", function: .init(name: "reading_enrich", arguments: arguments))], reasoning_content: nil),
                finishReason: "tool_calls", tokenCost: 10)
        })
        let saved = try await reader.enrichCurrent(project: book, unitID: "shared",
            settings: ProviderSettings(model: "offline-fixture", maxRequestsPerRun: 2, maxOutputTokens: 1_000), apiKey: "", sourceRanges: ranges)
        XCTAssertEqual(saved.units, book.units)
        XCTAssertEqual(saved.coverage, book.coverage)
        XCTAssertEqual(saved.paragraphReceipts, book.paragraphReceipts)
        XCTAssertNil(saved.smartReading)
        XCTAssertEqual(saved.audit.last?.name, "reading_enrich")
    }

    func testExcerptGrantRejectsOtherChapterFactsAndExistingAnchorReuse() throws {
        var book = try book(); PluginEngine.seed(&book)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .chapter, in: book, context: context(book, title: "第一章"))
        let ranges = try snapshot.sourceRanges(in: book)
        let outside = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "shared", quote: "乙章原文。", in: book)
        book.readingExperience = ReadingExperienceState(); book.readingExperience?.anchors = [outside]
        let grant = ReadingEnrichmentAuthority.Grant(bookID: book.id, sourceHash: book.sourceHash, unitID: "shared",
            unitHash: try BookImporter.sha256(Data(book.units[0].text.utf8)), ranges: ranges)
        try ReadingEnrichmentAuthority.$current.withValue(grant) {
            var candidate = book
            let fact: [String: Any] = ["entities": [["id": "foreign", "typeID": "person", "name": "乙章", "summary": "不得越章写入", "evidence": [["unitID": "shared", "quote": "乙章原文。"]]]]]
            XCTAssertThrowsError(try PluginEngine.apply(name: "cards_upsert", arguments: JSONSerialization.data(withJSONObject: fact), to: &candidate, allowedUnitIDs: ["shared"], phase: .reading))
            let layer: [String: Any] = ["layers": [["id": "foreign-layer", "kind": "explanation", "title": "越章", "markdown": "乙章资料", "sourceAnchorIDs": [outside.id], "sourceLabel": "AI"]]]
            XCTAssertThrowsError(try PluginEngine.apply(name: "reading_enrich", arguments: JSONSerialization.data(withJSONObject: layer), to: &candidate, allowedUnitIDs: ["shared"], phase: .reading))
            XCTAssertEqual(candidate.entities, book.entities)
            XCTAssertEqual(candidate.readingExperience, book.readingExperience)
        }
    }

    func testNativeOutlineCanonicalSavePreservesUserContentAndCannotBeForgedByAI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChapterStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("book.pdf"), bytes = Data("chapter-source".utf8)
        try bytes.write(to: source)
        var book = try book(); let outline = try XCTUnwrap(book.originalBookOutline); book.originalBookOutline = nil
        let repository = LibraryRepository(rootURL: directory.appendingPathComponent("library"))
        try await repository.create(book, sourceURL: source)
        let note = DocumentRecord(id: "own", title: "我的理解")
        let stale = try await repository.saveDocument(project: book, document: note, markdown: "保留我的原文笔记。")
        let saved = try await repository.saveOriginalBookOutline(bookID: book.id, outline: outline)
        XCTAssertEqual(saved.documents, stale.documents)
        let retained = try await repository.save(stale)
        XCTAssertEqual(retained.originalBookOutline, outline)
        var forged = book; forged.originalBookOutline = outline
        XCTAssertThrowsError(try AIProjectMerge.merge(base: book, result: forged, latest: saved))
        XCTAssertEqual(try AIProjectMerge.merge(base: book, result: book, latest: saved).originalBookOutline, outline)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let body = try await repository.readDocument(bookID: book.id, document: note)
        XCTAssertEqual(body, "保留我的原文笔记。")
        let exported = directory.appendingPathComponent("export.readingbook", isDirectory: true)
        try await repository.exportProject(retained, to: exported)
        let reload = try JSONDecoder().decode(BookProject.self, from: Data(contentsOf: exported.appendingPathComponent("project.json")))
        XCTAssertEqual(reload.originalBookOutline, outline)
    }
}
