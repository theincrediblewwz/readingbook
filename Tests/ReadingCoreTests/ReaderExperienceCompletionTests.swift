import Foundation
import XCTest
@testable import ReadingCore

final class ReaderExperienceCompletionTests: XCTestCase {
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    private func book() throws -> BookProject {
        let text = "王允为何反复佯惊？ e\u{301} 👩🏽‍💻。"
        var value = BookProject(id: "00000000-0000-4000-8000-000000000131", title: "体验回归", originalName: "book.txt",
            sourceHash: try BookImporter.sha256(Data(text.utf8)), units: [
                SourceUnit(id: "u1", order: 0, chapter: "一", page: 1, text: text),
                SourceUnit(id: "u2", order: 1, chapter: "二", page: 2, text: "未授权 PRIVATE_SECOND_PAGE")])
        PluginEngine.seed(&value)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: value, context: ReadingContext(unitID: "u1", page: 1))
        let context = try ReadingChatContext(snapshot: snapshot, avoidsSpoilers: true)
        for role in ["user", "assistant"] {
            var message = ChatMessage(id: role, role: role, content: role == "user" ? "王允在装糊涂吗？" : "佯惊是一种试探，仍须对照原文。")
            message.readingContext = context; message.conversationMode = .reading; message.answerStyle = .mentor
            value.chats.append(message)
        }
        value.documents = [DocumentRecord(id: "n1", title: "动机"), DocumentRecord(id: "n2", title: "用词")]
        return value
    }
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/experience-completion-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func placement(_ book: BookProject) -> ReadingNotePlacement {
        .init(sourceHash: book.sourceHash, unitID: "u1", page: 1, x: 0.7, y: 0.25)
    }
    func testLegacyCollectionMetadataStillDecodesWithoutPlacements() throws {
        let raw = Data(#"{"folders":[],"assignments":{},"archivedChatIDs":[],"archivedCompanionIDs":[],"collapsedReferenceIDs":[]}"#.utf8)
        let value = try JSONDecoder().decode(ReaderCollectionState.self, from: raw)
        XCTAssertNil(value.notePlacements); try ReaderCollectionRuntime.validate(value)
    }
    func testPlacingAndUnbindingOrdinaryNoteNeverChangesBodiesSourceOrOtherCollections() throws {
        var value = try book(); let notes = value.documents, units = value.units, chats = value.chats
        value.readerCollections = try ReaderCollectionRuntime.apply(.setNotePlacement("n1", placement(value)), in: value)
        XCTAssertEqual(value.readerCollections?.notePlacements?["n1"], placement(value))
        value.readerCollections = try ReaderCollectionRuntime.apply(.setNotePlacement("n1", nil), in: value)
        XCTAssertNil(value.readerCollections?.notePlacements?["n1"])
        XCTAssertEqual(value.documents, notes); XCTAssertEqual(value.units, units); XCTAssertEqual(try encoded(value.chats), try encoded(chats))
    }
    func testRejectsInvalidOrStalePositionsAndTrashedTargets() throws {
        let value = try book()
        for number in [Double.nan, .infinity, -0.01, 1.01] {
            var p = placement(value); p.x = number
            XCTAssertThrowsError(try ReaderCollectionRuntime.apply(.setNotePlacement("n1", p), in: value))
        }
        var wrong = placement(value); wrong.sourceHash = "another"
        XCTAssertThrowsError(try ReaderCollectionRuntime.apply(.setNotePlacement("n1", wrong), in: value))
        var trashed = value; trashed.documents[0].trashedAt = .now
        XCTAssertThrowsError(try ReaderCollectionRuntime.apply(.setNotePlacement("n1", placement(value)), in: trashed))
    }
    func testStacksRetainEveryIDAndStayInReservedMargin() {
        let points = [10.0, 12, 20, 400, 410, 790].enumerated().map { ReadingNoteScreenPosition(id: "\($0.offset)", y: $0.element) }
        let stacks = ReadingNoteLayout.stacks(points, height: 800)
        XCTAssertEqual(stacks.flatMap(\.ids), points.map(\.id)); XCTAssertEqual(stacks.first?.ids.count, 3)
        XCTAssertTrue(stacks.allSatisfy { $0.top >= 16 && $0.top + 170 <= 800 })
        XCTAssertTrue(ReadingNoteLayout.stacks(points, height: .nan).isEmpty)
    }
    func testTopicParserRejectsInventedDuplicateIDsAndUnexpectedFields() throws {
        for raw in [#"{"groups":[{"title":"人物","noteIDs":["missing"]}]}"#,
                    #"{"groups":[{"title":"人物","noteIDs":["n1","n1"]}]}"#,
                    #"{"groups":[{"title":"人物","noteIDs":["n1"],"command":"delete"}]}"#] {
            XCTAssertThrowsError(try ReadingNoteTopicRuntime.parse(raw, offeredIDs: ["n1"]))
        }
    }
    func testTopicApplicationOnlyGroupsOfferedUnchangedUnfiledNotes() throws {
        var value = try book(); let original = value
        let groups = [ReadingNoteTopicGroup(title: "人物动机", noteIDs: ["n1"])]
        value.readerCollections = try ReaderCollectionRuntime.apply(.organizeNotesByTopic(groups, expectedDocuments: value.documents), in: value)
        XCTAssertEqual(value.documents, original.documents); XCTAssertEqual(try encoded(value.chats), try encoded(original.chats))
        XCTAssertNotNil(value.readerCollections?.assignments["note:n1"]); XCTAssertNil(value.readerCollections?.assignments["note:n2"])
        XCTAssertThrowsError(try ReaderCollectionRuntime.apply(.organizeNotesByTopic(groups, expectedDocuments: original.documents), in: value))
        var edited = original; edited.documents[0].title = "用户改过"
        XCTAssertThrowsError(try ReaderCollectionRuntime.apply(.organizeNotesByTopic(groups, expectedDocuments: original.documents), in: edited))
    }
    func testManualShortSummaryUsesOnlyAdmittedMessagesAndDoesNotMutateOriginals() async throws {
        let value = try book(), prepared = try ReadingPreparedAnswer.freeze(project: value, scope: .page, context: ReadingContext(unitID: "u1", page: 1))
        XCTAssertEqual(prepared.history.count, 2)
        XCTAssertNil(try ConversationMemoryRuntime.batch(history: prepared.history, after: .init(), maximumBytes: 8000))
        let reader = AIReader(transport: { request in
            let body = String(decoding: request.request.httpBody!, as: UTF8.self)
            XCTAssertTrue(body.contains("王允在装糊涂吗")); XCTAssertFalse(body.contains("PRIVATE_SECOND_PAGE"))
            return .init(message: .init(role: "assistant", content: #"{"requirements":[{"text":"想弄懂王允的动机","sources":["user"]}],"conclusions":[{"text":"可能是在试探，仍须核对","sources":["assistant"]}],"unresolved":[]}"#, refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 30)
        })
        let memory = try await reader.summarizeConversation(prepared: prepared, previous: nil, settings: .init(model: "offline", maxRequestsPerRun: 3, maxOutputTokens: 1000), apiKey: "")
        XCTAssertTrue(ConversationMemoryRuntime.isValid(memory, snapshot: prepared.snapshot, history: prepared.history))
        XCTAssertEqual(memory.cursor.index, 2); XCTAssertEqual(value.chats.count, 2)
    }
    func testCatalogDoesNotLoseCurrentBookBehindMoreThan256OtherBooks() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try book(), prepared = try ReadingPreparedAnswer.freeze(project: value, scope: .page, context: ReadingContext(unitID: "u1", page: 1))
        let directory = root.appendingPathComponent("ConversationMemory"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var memory = ConversationMemory(id: value.id + ":" + prepared.snapshot.scopeFingerprint, bookID: value.id, scopeFingerprint: prepared.snapshot.scopeFingerprint,
            fingerprint: try ConversationMemoryRuntime.prefixFingerprint(prepared.history, cursor: .init(index: 2)), cursor: .init(index: 2), requirements: [],
            conclusions: [.init(text: "保留更早摘要", sources: ["assistant"])], unresolved: [], updatedAt: .distantPast, model: "offline")
        try JSONEncoder().encode(memory).write(to: directory.appendingPathComponent("old-current.json"))
        for index in 0..<300 { memory.bookID = "other-\(index)"; memory.id = memory.bookID + ":" + memory.scopeFingerprint; memory.updatedAt = .now
            try JSONEncoder().encode(memory).write(to: directory.appendingPathComponent("new-\(index).json")) }
        let found = ConversationMemoryCatalog.read(bookID: value.id, messages: value.chats, root: root)
        XCTAssertEqual(found.count, 1); XCTAssertEqual(found.first?.conclusions.first?.text, "保留更早摘要")
    }
    func testSuggestionCycleSurvivesRestartAndSeparatesBookScopeAndModel() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = ReadingSuggestionCache(), identity = "book|hash|page1|provider|model"
        try await first.write(.init(questions: ["王允为什么故作惊讶？"]), root: root, identity: identity)
        let reopened = ReadingSuggestionCache()
        let saved = await reopened.read(root: root, identity: identity), other = await reopened.read(root: root, identity: identity + "other")
        XCTAssertEqual(saved?.questions, ["王允为什么故作惊讶？"]); XCTAssertNil(other)
        try await reopened.write(.init(occupied: true), root: root, identity: identity)
        let cycle = await first.read(root: root, identity: identity)
        XCTAssertTrue(cycle?.occupied == true); XCTAssertEqual(cycle?.questions, [])
    }
    func testCompanionActuallyReceivesChosenHistoryWithoutWideningOriginalSource() async throws {
        var value = try book(); value.plan = ReadingPlan(methodIDs: ["genre.history"])
        let chosen = try ReaderCollectionRuntime.explicitReferences(["chat:assistant"], in: value)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: value, context: ReadingContext(unitID: "u1", page: 1))
        let ranges = try snapshot.sourceRanges(in: value)
        let reader = AIReader(transport: { prepared in
            let body = String(decoding: prepared.request.httpBody!, as: UTF8.self)
            XCTAssertTrue(body.contains("读者主动引用的旧回答")); XCTAssertTrue(body.contains("佯惊是一种试探"))
            XCTAssertFalse(body.contains("PRIVATE_SECOND_PAGE"))
            return .init(message: .init(role: "assistant", content: nil, refusal: nil,
                tool_calls: [.init(id: "complete", type: "function", function: .init(name: "reading_enrich", arguments: #"{"noChangesReason":"已核对本页与所选旧回答，没有需要补建的内容。"}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 30)
        })
        let result = try await reader.enrichCurrent(project: value, unitID: "u1", settings: .init(model: "offline", maxRequestsPerRun: 3, maxOutputTokens: 1000), apiKey: "", sourceRanges: ranges, referencedAnswers: chosen)
        XCTAssertEqual(result.units, value.units); XCTAssertEqual(try encoded(result.chats), try encoded(value.chats))
    }
    func testActiveSuggestionBatchesAreNotEvictedAfter256OtherPageVisits() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReadingSuggestionCache()
        for index in 0..<260 {
            try await cache.write(.init(questions: ["王允为什么第\(index)次故作惊讶？"]), root: root, identity: "page-\(index)")
        }
        let preserved = await cache.read(root: root, identity: "page-0")
        XCTAssertEqual(preserved?.questions, ["王允为什么第0次故作惊讶？"])
    }
    func testPositionSurvivesStaleDocumentSaveAndConcurrentAIThenRestart() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var value = try book(); value.documents = []; value.units.removeLast(); value.coverage = value.coverage.filter { $0.key == "u1" }
        let source = root.appendingPathComponent("book.txt"); try Data(value.units[0].text.utf8).write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library"))
        value = try await repository.create(value, sourceURL: source)
        let body = "用户原句 e\u{301} 👩🏽‍💻 $x^2$", document = DocumentRecord(id: "n1", title: "普通笔记")
        value = try await repository.saveDocument(project: value, document: document, markdown: body, notePlacement: placement(value))
        let stale = value
        var changedPlacement = placement(value); changedPlacement.fontSize = 19
        _ = try await repository.organizeReaderCollections(bookID: value.id, sourceHash: value.sourceHash, command: .setNotePlacement("n1", changedPlacement))
        let saved = try await repository.saveDocument(project: stale, document: stale.documents[0], markdown: body, expectedContentHash: BookImporter.sha256(Data(body.utf8)))
        XCTAssertEqual(saved.readerCollections?.notePlacements?["n1"]?.fontSize, 19)
        var result = stale; result.chats.append(ChatMessage(id: "late", role: "assistant", content: "迟到回答"))
        _ = try await repository.commitAIResult(base: stale, result: result, operationID: "late-note-test")
        let reopened = LibraryRepository(rootURL: root.appendingPathComponent("library")), loaded = try await reopened.loadAll()
        let final = try XCTUnwrap(loaded.first)
        XCTAssertEqual(final.readerCollections?.notePlacements?["n1"]?.fontSize, 19)
        let markdown = try await reopened.readDocument(bookID: final.id, document: final.documents[0])
        XCTAssertEqual(Data(markdown.utf8), Data(body.utf8))
    }
    func testLatestNoteSaveRetainsAnalysisAddedSinceTheEditorOpened() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var value = try book(); value.documents = []
        let source = root.appendingPathComponent("book.txt"); try Data(value.units[0].text.utf8).write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library"))
        value = try await repository.create(value, sourceURL: source)
        let original = value
        value.insights.append(.init(id: "parallel-analysis", unitIDs: ["u1"], markdown: "独立分析必须保留"))
        let analyzed = try await repository.commitAIResult(base: original, result: value, operationID: "new-analysis-before-note")
        let note = DocumentRecord(id: "late-note", title: "用户正文")
        let saved = try await repository.saveLatestNote(bookID: original.id, sourceHash: original.sourceHash, document: note,
            markdown: "新笔记", notePlacement: placement(original))
        XCTAssertEqual(try encoded(saved.insights), try encoded(analyzed.insights))
        XCTAssertEqual(saved.readerCollections?.notePlacements?[note.id], placement(original))
    }
    func testTopicRequestFitsSmallContextWithoutInventingOmittedNoteIDs() async throws {
        let notes = (0..<50).map { ReadingNoteTopicInput(id: "n\($0)", title: "人物与动机", excerpt: String(repeating: "王允为何反复佯惊？", count: 40)) }
        let reader = AIReader(transport: { prepared in
            let object = try JSONSerialization.jsonObject(with: prepared.request.httpBody!) as! [String: Any]
            let messages = object["messages"] as! [[String: Any]], raw = messages[1]["content"] as! String
            let offered = try JSONDecoder().decode([ReadingNoteTopicInput].self, from: Data(raw.utf8))
            XCTAssertTrue(offered.count < notes.count); XCTAssertFalse(offered.isEmpty)
            let result = ["groups":[["title":"人物动机","noteIDs":[offered[0].id]]]]
            return .init(message: .init(role: "assistant", content: String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self), refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 30)
        })
        let groups = try await reader.organizeNotesByTopic(notes: notes, settings: .init(model: "offline", maxRequestsPerRun: 2, maxOutputTokens: 1000, contextWindowTokens: 4096), apiKey: "")
        XCTAssertEqual(groups.first?.noteIDs, ["n0"])
    }
    func testLibraryBackupRestoresOrdinaryNoteBodyPositionAndAllAnalysis() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var value = try book(); value.documents = []
        let source = root.appendingPathComponent("book.txt"), bytes = Data(value.units[0].text.utf8)
        try bytes.write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library"))
        value = try await repository.create(value, sourceURL: source)
        let note = DocumentRecord(id: "n1", title: "普通笔记"), body = "只保存用户正文 e\u{301} 👩🏽‍💻 $x^2$\n"
        value = try await repository.saveDocument(project: value, document: note, markdown: body, notePlacement: placement(value))
        let backup = root.appendingPathComponent("saved.readingbookbackup"), restoredRoot = root.appendingPathComponent("restored")
        _ = try await repository.exportLibraryBackup(to: backup)
        _ = try await repository.restoreLibraryBackup(from: backup, to: restoredRoot)
        let restored = LibraryRepository(rootURL: restoredRoot), books = try await restored.loadAll()
        let reopened = try XCTUnwrap(books.first)
        XCTAssertEqual(try encoded(reopened), try encoded(value))
        let restoredBody = try await restored.readDocument(bookID: reopened.id, document: note)
        XCTAssertEqual(Data(restoredBody.utf8), Data(body.utf8))
        let restoredSource = await restored.sourceURL(for: reopened)
        XCTAssertEqual(try Data(contentsOf: restoredSource), bytes)
        XCTAssertEqual(reopened.readerCollections?.notePlacements?[note.id], placement(value))
    }
    func testAdjacentKnownCitationsRenderSeparatelyWithoutChangingRealMarkdownReferences() throws {
        let value = try book(), raw = "结论。[unit:u1][doc:n1]"
        let rendered = MarkdownReferenceLinks.render(raw, bookID: value.id, project: value)
        XCTAssertTrue(rendered.contains("[第 1 页](readingbook://")); XCTAssertTrue(rendered.contains("[动机](readingbook://"))
        XCTAssertFalse(rendered.contains("[unit:u1]")); XCTAssertFalse(rendered.contains("[doc:n1]"))
        let defined = "[unit:u1][doc:n1]\n\n[doc:n1]: https://example.test/real-reference"
        XCTAssertEqual(MarkdownReferenceLinks.render(defined, bookID: value.id, project: value), defined)
        XCTAssertEqual(MarkdownReferenceLinks.render(raw, bookID: value.id), raw)
        let code = "`[unit:u1][doc:n1]` and $[unit:u1][doc:n1]$"
        XCTAssertEqual(MarkdownReferenceLinks.render(code, bookID: value.id, project: value), code)
    }
}
