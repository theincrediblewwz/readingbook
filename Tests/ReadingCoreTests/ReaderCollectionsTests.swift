import Foundation
import XCTest
@testable import ReadingCore

private actor CollectionTransportLog {
    var requests: [ProviderClient.Prepared] = []
    func append(_ value: ProviderClient.Prepared) { requests.append(value) }
}

final class ReaderCollectionsTests: XCTestCase {
    private func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    private func book() throws -> BookProject {
        let text = "王允问计，吕布为何迟疑？ e\u{301} 👩🏽‍💻。"
        var project = BookProject(id: "00000000-0000-4000-8000-000000000031", title: "收纳测试", originalName: "book.txt",
            sourceHash: try BookImporter.sha256(Data(text.utf8)), units: [
                SourceUnit(id: "u1", order: 0, chapter: "一", page: 1, text: text),
                SourceUnit(id: "u2", order: 1, chapter: "二", page: 2, text: "未分享的第二页 PRIVATE_PAGE。")])
        PluginEngine.seed(&project)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: ReadingContext(unitID: "u1", page: 1))
        let context = try ReadingChatContext(snapshot: snapshot, avoidsSpoilers: true)
        for index in 0..<3 {
            for role in ["user", "assistant"] {
                var message = ChatMessage(id: "\(index)-\(role)", role: role, content: "\(index) \(role) e\u{301} 👩🏽‍💻 FULL_BODY")
                message.readingContext = context; message.conversationMode = .reading; message.answerStyle = .mentor
                project.chats.append(message)
            }
        }
        project.documents = [DocumentRecord(id: "n1", title: "旧笔记"), DocumentRecord(id: "n2", title: "另一篇笔记")]
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: "u1", quote: text, in: project)
        project.readingExperience = ReadingExperienceState(anchors: [anchor], layers: [
            ReadingLayer(id: "l1", kind: "explanation", title: "解释", markdown: "已有解释 $x^2$ e\u{301}", sourceAnchorIDs: [anchor.id])])
        return project
    }
    private func apply(_ command: ReaderCollectionCommand, to project: inout BookProject) throws {
        project.readerCollections = try ReaderCollectionRuntime.apply(command, in: project)
    }
    func testLegacyBooksDecodeWithoutCollectionsAndKeepEverySourceField() throws {
        let project = try book(), before = try data(project)
        let decoded = try JSONDecoder().decode(BookProject.self, from: before)
        XCTAssertNil(decoded.readerCollections); XCTAssertEqual(try data(decoded), before)
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("readerCollections"))
    }
    func testCollapseKeepsAutomaticContextArchiveRemovesWholeTurnAndRestoreReturnsIt() throws {
        var project = try book(); let originalChats = try data(project.chats), originalUnits = try data(project.units)
        let before = try ReadingPreparedAnswer.freeze(project: project, scope: .page, context: ReadingContext(unitID: "u1", page: 1))
        try apply(.collapse(["chat:0-assistant"], true), to: &project)
        let folded = try ReadingPreparedAnswer.freeze(project: project, scope: .page, context: ReadingContext(unitID: "u1", page: 1))
        XCTAssertEqual(try data(folded.history), try data(before.history))
        try apply(.archive(["chat:0-assistant"], "第一轮"), to: &project)
        XCTAssertEqual(Set(project.readerCollections?.archivedChatIDs ?? []), ["0-user", "0-assistant"])
        let archived = try ReadingPreparedAnswer.freeze(project: project, scope: .page, context: ReadingContext(unitID: "u1", page: 1))
        XCTAssertEqual(archived.history.map(\.id), ["1-user", "1-assistant", "2-user", "2-assistant"])
        XCTAssertEqual(try data(project.chats), originalChats); XCTAssertEqual(try data(project.units), originalUnits)
        try apply(.restore(["chat:0-assistant"]), to: &project)
        XCTAssertEqual(try data(ReadingPreparedAnswer.freeze(project: project, scope: .page, context: ReadingContext(unitID: "u1", page: 1)).history), try data(before.history))
    }
    func testArchiveSharedQuestionIncludesAllItsAnswersWithoutReorderingOtherTurns() throws {
        var project = try book()
        var extra = project.chats[1]; extra.id = "same-turn-extra"; project.chats.insert(extra, at: 2)
        let before = try data(project.chats)
        try apply(.archive(["chat:same-turn-extra"], "一组"), to: &project)
        XCTAssertEqual(Set(project.readerCollections?.archivedChatIDs ?? []), ["0-user", "0-assistant", "same-turn-extra"])
        XCTAssertEqual(try data(project.chats), before)
    }
    func testNestedFolderMoveRenameAndRemovalRetainNotesAndPromoteChildren() throws {
        var project = try book(); let before = try data(project.documents)
        let parent = ReaderCollectionFolder(id: "parent", kind: .notes, title: "人物")
        try apply(.createFolder(parent), to: &project)
        try apply(.createFolder(.init(id: "child", kind: .notes, title: "待整理", parentID: parent.id)), to: &project)
        try apply(.move(.notes, ["note:n1"], parent.id), to: &project)
        try apply(.renameFolder("child", "细读"), to: &project)
        try apply(.removeFolder(parent.id), to: &project)
        XCTAssertNil(project.readerCollections?.assignments["note:n1"])
        XCTAssertNil(project.readerCollections?.folders.first?.parentID)
        XCTAssertEqual(project.readerCollections?.folders.first?.title, "细读")
        XCTAssertEqual(try data(project.documents), before)
    }
    func testFolderCyclesWrongKindsUnknownReferencesAndOversizeNamesAreRejected() throws {
        var project = try book()
        try apply(.createFolder(.init(id: "notes", kind: .notes, title: "笔记")), to: &project)
        let before = try data(project)
        for command in [ReaderCollectionCommand.createFolder(.init(id: "bad", kind: .history, title: "错层", parentID: "notes")),
                        .createFolder(.init(id: "long", kind: .notes, title: String(repeating: "长", count: 81))),
                        .move(.history, ["chat:0-assistant"], "notes"), .archive(["chat:missing"], "错回答")] {
            XCTAssertThrowsError(try ReaderCollectionRuntime.apply(command, in: project))
            XCTAssertEqual(try data(project), before)
        }
        var invalid = ReaderCollectionState()
        invalid.folders = [.init(id: "a", kind: .notes, title: "A", parentID: "b"), .init(id: "b", kind: .notes, title: "B", parentID: "a")]
        XCTAssertThrowsError(try ReaderCollectionRuntime.validate(invalid))
    }
    func testOneClickNoteGroupingOnlyTouchesUnfiledMetadata() throws {
        var project = try book(); project.documents[0].updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try apply(.createFolder(.init(id: "custom", kind: .notes, title: "自己的分类")), to: &project)
        try apply(.move(.notes, ["note:n2"], "custom"), to: &project)
        let notes = try data(project.documents), chats = try data(project.chats)
        try apply(.organizeNotesByMonth, to: &project)
        XCTAssertNotNil(project.readerCollections?.assignments["note:n1"])
        XCTAssertEqual(project.readerCollections?.assignments["note:n2"], "custom")
        let once = try data(project.readerCollections)
        try apply(.organizeNotesByMonth, to: &project)
        XCTAssertEqual(try data(project.readerCollections), once)
        XCTAssertEqual(try data(project.documents), notes); XCTAssertEqual(try data(project.chats), chats)
    }
    func testExplicitArchivedReferencesKeepExactBytesAndDoNotGrantOtherSourcePages() throws {
        var project = try book()
        try apply(.archive(["chat:0-assistant", "chat:1-assistant"], "旧讨论"), to: &project)
        let prepared = try ReadingPreparedAnswer.freeze(project: project, scope: .page, context: ReadingContext(unitID: "u1", page: 1), referencedAnswerIDs: ["chat:0-assistant"])
        XCTAssertEqual(prepared.referencedAnswers.map(\.id), ["chat:0-assistant"])
        XCTAssertTrue(prepared.referencedAnswers[0].content.utf8.elementsEqual(project.chats[1].content.utf8))
        XCTAssertEqual(prepared.snapshot.unitIDs, ["u1"]); XCTAssertEqual(prepared.snapshot.documentIDs, [])
        XCTAssertEqual(prepared.history.map(\.id), ["2-user", "2-assistant"])
        let ordinary = try ReadingPreparedAnswer.freeze(project: project, scope: .page, context: ReadingContext(unitID: "u1", page: 1))
        XCTAssertNotEqual(prepared.snapshot.scopeFingerprint, ordinary.snapshot.scopeFingerprint)
        var changed = project; changed.chats[1].content += " changed"
        let replacement = try ReadingPreparedAnswer.freeze(project: changed, scope: .page, context: ReadingContext(unitID: "u1", page: 1), referencedAnswerIDs: ["chat:0-assistant"])
        XCTAssertNotEqual(prepared.snapshot.scopeFingerprint, replacement.snapshot.scopeFingerprint)
        XCTAssertThrowsError(try ReaderCollectionRuntime.explicitReferences(["chat:0-assistant", "chat:0-assistant"], in: project))
        XCTAssertThrowsError(try ReaderCollectionRuntime.explicitReferences(["chat:other-book-answer"], in: project))
        changed.chats[1].content = String(repeating: "字", count: 30_000)
        XCTAssertThrowsError(try ReaderCollectionRuntime.explicitReferences(["chat:0-assistant"], in: changed))
    }
    func testArchivedCompanionIsWithheldFromAutomaticKnowledgeButExplicitlyReferenceable() throws {
        var project = try book(); let records = try data(project.readingExperience)
        try apply(.archive(["layer:l1"], "伴读历史"), to: &project)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: ReadingContext(unitID: "u1", page: 1))
        let session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: project)
        XCTAssertTrue(session.scopedKnowledgeProject()?.readingExperience?.layers.isEmpty == true)
        XCTAssertEqual(try ReaderCollectionRuntime.explicitReferences(["layer:l1"], in: project).first?.content, project.readingExperience?.layers.first?.markdown)
        XCTAssertEqual(try data(project.readingExperience), records)
        try apply(.restore(["layer:l1"]), to: &project)
        let restored = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: project)
        XCTAssertEqual(restored.scopedKnowledgeProject()?.readingExperience?.layers.map(\.id), ["l1"])
    }
    func testArchivedMessagesInvalidateOldAutomaticSummaryWithoutDeletingIt() throws {
        var project = try book()
        let prepared = try ReadingPreparedAnswer.freeze(project: project, scope: .page, context: ReadingContext(unitID: "u1", page: 1))
        let cursor = ConversationMemoryCursor(index: 2)
        let memory = ConversationMemory(id: project.id + ":" + prepared.snapshot.scopeFingerprint, bookID: project.id,
            scopeFingerprint: prepared.snapshot.scopeFingerprint, fingerprint: try ConversationMemoryRuntime.prefixFingerprint(prepared.history, cursor: cursor), cursor: cursor,
            requirements: [.init(text: "原来想讨论的问题", sources: ["0-user"])], conclusions: [.init(text: "旧回答的建议", sources: ["0-assistant"])], unresolved: [], updatedAt: Date(), model: "offline")
        XCTAssertTrue(ConversationMemoryRuntime.isValid(memory, snapshot: prepared.snapshot, history: prepared.history))
        let bytes = try data(memory)
        try apply(.archive(["chat:0-assistant"], "旧讨论"), to: &project)
        let next = try ReadingPreparedAnswer.freeze(project: project, scope: .page, context: ReadingContext(unitID: "u1", page: 1))
        XCTAssertFalse(ConversationMemoryRuntime.isValid(memory, snapshot: next.snapshot, history: next.history))
        XCTAssertEqual(try data(memory), bytes)
    }
    func testPluginAndAIResultsCannotChangeManualFoldersOrArchive() throws {
        let project = try book()
        for readOnly in [false, true] {
            var registry = PluginToolRegistry()
            try registry.register(RegisteredReadingTool(pluginID: "fixture", schema: ["type": "function", "function": ["name": "tamper", "parameters": ["type": "object", "properties": [:]]]], phases: [.reading], readOnly: readOnly, execute: { _, value, _ in
                value.readerCollections = ReaderCollectionState(); return "not admitted"
            }))
            var candidate = project; let before = try data(candidate)
            XCTAssertThrowsError(try registry.apply(name: "tamper", arguments: Data("{}".utf8), to: &candidate, allowedUnitIDs: ["u1"], phase: .reading))
            XCTAssertEqual(try data(candidate), before)
        }
        var changed = project; changed.readerCollections = .init()
        XCTAssertThrowsError(try AIProjectMerge.merge(base: project, result: changed, latest: project))
        var latest = project; try apply(.archive(["chat:0-assistant"], "保留"), to: &latest)
        var answer = project; answer.chats.append(ChatMessage(id: "new", role: "assistant", content: "新回答"))
        let merged = try AIProjectMerge.merge(base: project, result: answer, latest: latest)
        XCTAssertEqual(merged.readerCollections, latest.readerCollections); XCTAssertEqual(merged.chats.last?.id, "new")
    }
    func testRepositoryRestartStaleEditorAndConcurrentAIKeepFolderAndAllOriginalFiles() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/reader-collection-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.txt"), text = "王允问计，吕布为何迟疑？ e\u{301} 👩🏽‍💻。"
        try Data(text.utf8).write(to: source)
        let repository = LibraryRepository(rootURL: root.appendingPathComponent("library"))
        var project = try book(); project.units.removeLast(); project.documents = []
        project.coverage = project.coverage.filter { $0.key == "u1" }
        project = try await repository.create(project, sourceURL: source)
        let note = DocumentRecord(id: "note", title: "已有笔记"), markdown = "# 原笔记\n\n$x^2$ e\u{301}\n"
        project = try await repository.saveDocument(project: project, document: note, markdown: markdown)
        let before = project
        _ = try await repository.organizeReaderCollections(bookID: project.id, sourceHash: project.sourceHash, command: .archive(["chat:0-assistant"], "保留旧讨论"))
        let saved = try await repository.saveDocument(project: before, document: before.documents[0], markdown: markdown,
            expectedContentHash: BookImporter.sha256(Data(markdown.utf8)))
        XCTAssertTrue(saved.readerCollections?.archivedChatIDs.contains("0-assistant") == true)
        var result = before; result.chats.append(ChatMessage(id: "parallel", role: "assistant", content: "并行生成的回答"))
        let committed = try await repository.commitAIResult(base: before, result: result, operationID: "parallel-save")
        XCTAssertTrue(committed.readerCollections?.archivedChatIDs.contains("0-assistant") == true)
        XCTAssertEqual(committed.chats.last?.id, "parallel")
        let reopened = LibraryRepository(rootURL: root.appendingPathComponent("library")), books = try await reopened.loadAll()
        let final = try XCTUnwrap(books.first)
        XCTAssertEqual(final.readerCollections, committed.readerCollections)
        let body = try await reopened.readDocument(bookID: final.id, document: final.documents[0])
        XCTAssertEqual(Data(body.utf8), Data(markdown.utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data(text.utf8))
        do { _ = try await reopened.organizeReaderCollections(bookID: final.id, sourceHash: "other-source", command: .collapse(["chat:0-assistant"], true)); XCTFail("旧原书身份必须拒绝") } catch { }
    }
    func testActualModelReferenceRequestContainsOnlyChosenAnswerAndNoExtraSourceGrant() async throws {
        var project = try book(); try apply(.archive(["chat:0-assistant", "chat:1-assistant"], "旧讨论"), to: &project)
        let prepared = try ReadingPreparedAnswer.freeze(project: project, scope: .page, context: ReadingContext(unitID: "u1", page: 1), referencedAnswerIDs: ["chat:0-assistant"])
        let log = CollectionTransportLog()
        let response = ProviderClient.Result(message: .init(role: "assistant", content: "可以继续比较这个想法。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 10)
        let reader = AIReader(transport: { request in await log.append(request); return response })
        _ = try await reader.answerDetailed(question: "比较这段旧回答", prepared: prepared,
            settings: ProviderSettings(baseURL: "https://offline.invalid", model: "offline", maxRequestsPerRun: 4, maxOutputTokens: 1000, contextWindowTokens: 32768), apiKey: "", memoryEnabled: false)
        let requests = await log.requests
        XCTAssertFalse(requests.isEmpty)
        let body = try XCTUnwrap(requests.first?.request.httpBody), request = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(request.contains("0 assistant")); XCTAssertFalse(request.contains("1 assistant")); XCTAssertFalse(request.contains("PRIVATE_PAGE"))
        XCTAssertEqual(prepared.snapshot.unitIDs, ["u1"])
    }
    func testSuggestionsUseRealProviderResultAndOnlyBoundedCurrentSource() async throws {
        var project = try book(); project.units[0].text = String(repeating: "原文 e\u{301} 👩🏽‍💻。", count: 3000)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: ReadingContext(unitID: "u1", page: 1))
        let log = CollectionTransportLog()
        let response = ProviderClient.Result(message: .init(role: "assistant", content: "{\"questions\":[\"吕布为什么会犹豫？\",\"王允的话有什么暗示？\"]}", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
        let reader = AIReader(transport: { request in await log.append(request); return response })
        let result = try await reader.suggestReadingQuestions(snapshot: snapshot, title: project.title,
            settings: ProviderSettings(baseURL: "https://offline.invalid", model: "offline", maxRequestsPerRun: 3, maxOutputTokens: 1000, contextWindowTokens: 32768), apiKey: "")
        XCTAssertEqual(result.questions, ["吕布为什么会犹豫？", "王允的话有什么暗示？"])
        let requests = await log.requests; XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests.first?.request.httpBody), object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(object["tools"]); XCTAssertNil(object["tool_choice"])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]]), text = try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertFalse(text.contains("PRIVATE_PAGE")); XCTAssertFalse(text.contains("FULL_BODY")); XCTAssertLessThan(body.count, 20_000)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]), excerpts = try XCTUnwrap(payload["excerpts"] as? [[String: Any]])
        XCTAssertEqual(excerpts.first?["partial"] as? Bool, true)
        XCTAssertLessThanOrEqual(excerpts.reduce(0) { $0 + (($1["text"] as? String)?.utf8.count ?? 0) }, 12_000)
    }
    func testMalformedTruncatedOrRefusedSuggestionsHaveNoFixedFallback() async throws {
        for raw in ["{\"questions\":[]}", "{\"questions\":[\"一句\"]}", "{\"questions\":[\"这是同一问题？\",\"这是同一问题？\"]}", "{\"questions\":[\"有效的问题？\"],\"answer\":\"fake\"}", "```json\n{\"questions\":[\"有效的问题？\"]}\n```"] {
            XCTAssertThrowsError(try ReadingQuestionSuggestions.parse(raw))
        }
        let project = try book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: ReadingContext(unitID: "u1", page: 1))
        for finish in ["length", "tool_calls"] {
            let response = ProviderClient.Result(message: .init(role: "assistant", content: "{\"questions\":[\"有效的问题？\"]}", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: finish, tokenCost: 10)
            let reader = AIReader(transport: { _ in response })
            do { _ = try await reader.suggestReadingQuestions(snapshot: snapshot, title: project.title, settings: ProviderSettings(baseURL: "https://offline.invalid", model: "offline"), apiKey: ""); XCTFail("不完整响应必须隐藏") } catch { }
        }
    }

    func testBackgroundSuggestionsDoNotBlockAnotherForegroundAIRequestAndCancelCleanly() async throws {
        let project = try book(), before = try data(project), log = CollectionTransportLog()
        let response = ProviderClient.Result(message: .init(role: "assistant", content: "{\"keywords\":[\"吕布\"]}", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 12)
        let coordinator = AIRequestCoordinator(transport: { request in
            await log.append(request)
            let body = try JSONSerialization.jsonObject(with: request.request.httpBody!) as! [String: Any]
            let messages = body["messages"] as? [[String: Any]] ?? []
            if (messages.first?["content"] as? String)?.contains("想出1至3个") == true {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            return response
        })
        let settings = ProviderSettings(baseURL: "https://offline.invalid", model: "offline", maxRequestsPerRun: 8, maxOutputTokens: 1000, contextWindowTokens: 32768)
        let run = try await coordinator.beginManagedRun(settings: settings, maximumConcurrency: 2)
        defer { run.finish() }
        let background = AIReader(coordinator: coordinator, lane: .background), foreground = AIReader(coordinator: coordinator, lane: .foreground)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: ReadingContext(unitID: "u1", page: 1))
        let pending = Task { try await background.suggestReadingQuestions(snapshot: snapshot, title: project.title, settings: settings, apiKey: "") }
        defer { pending.cancel() }
        for _ in 0..<2000 {
            if await log.requests.count == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let started = await log.requests.count
        XCTAssertEqual(started, 1)
        let result = try await foreground.expandLibrarySearch(query: "吕布", languageProfile: .init(languageCodes: ["zh"], sampledCharacterCount: 0), settings: settings, apiKey: "")
        XCTAssertEqual(result.keywords, ["吕布"])
        pending.cancel()
        do { _ = try await pending.value; XCTFail("已取消的推荐不能继续返回问题") } catch { XCTAssertTrue(error is CancellationError) }
        let count = await log.requests.count
        XCTAssertEqual(count, 2); XCTAssertEqual(try data(project), before)
        await coordinator.endRun(run)
    }
}
