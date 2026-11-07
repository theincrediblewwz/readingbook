import Foundation
import XCTest
@testable import ReadingCore

final class ReadingOrganizationTests: XCTestCase {
    private func book() -> BookProject {
        var book = BookProject(id: "organize", title: "原书", originalName: "book.pdf", sourceHash: "original", units: [
            .init(id: "one", order: 0, chapter: "原书", page: 1, text: "前章秘密。"),
            .init(id: "two", order: 1, chapter: "原书", page: 2, text: "周瑜與諸葛亮商議火攻。"),
            .init(id: "three", order: 2, chapter: "原书", page: 3, text: "黃蓋獻計。"),
            .init(id: "four", order: 3, chapter: "原书", page: 4, text: "后章秘密。")])
        PluginEngine.seed(&book)
        book.documents = [.init(id: "private", title: "私密笔记")]
        return book
    }
    private func context(_ range: ReadingQueryRange) -> ReadingContext {
        var context = ReadingContext(sourceHash: "original", unitID: "two", page: 2)
        context.queryRange = range; return context
    }
    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
    private func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    func testExplicitPagesAreActualReadAndComponentBoundaries() async throws {
        let book = book(), before = try bytes(book)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context(.init(pageStart: 2, pageEnd: 3)))
        XCTAssertEqual(snapshot.unitIDs, ["two", "three"]); XCTAssertTrue(snapshot.documentIDs.isEmpty)
        XCTAssertTrue(snapshot.displayTitle.contains("2–3"))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: ["private": "秘密"], project: book)
        do { _ = try await session.execute(name: "source_read", arguments: ["id": "one"], maximumBytes: 8000); XCTFail("不得读前章") } catch {}
        do { _ = try await session.execute(name: "source_read", arguments: ["id": "four"], maximumBytes: 8000); XCTFail("不得读后章") } catch {}
        do { _ = try await session.execute(name: "document_read", arguments: ["id": "private"], maximumBytes: 8000); XCTFail("不附带笔记") } catch {}
        XCTAssertEqual(try ReadingComponentProjection.project(snapshot, in: book).units.map(\.id), ["two", "three"])
        XCTAssertEqual(try bytes(book), before)
    }
    func testRangeChoiceCannotBeMissingReversedOrSmuggleOtherKind() throws {
        let book = book()
        XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .range, in: book))
        for (first, last) in [(0, 2), (3, 2), (2, 5)] {
            XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context(.init(pageStart: first, pageEnd: last))))
        }
        var mixed = ReadingQueryRange(pageStart: 2, pageEnd: 3); mixed.chapterStartID = "hidden"
        XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context(mixed)))
        XCTAssertEqual(try ReadingQuerySnapshot.freeze(scope: .book, in: book, context: context(.init(pageStart: 2, pageEnd: 3))).unitIDs.count, 4)
    }
    func testMultiChapterRangeUsesSamePageOffsetsAndRejectsStaleOutline() throws {
        var book = book(); book.units[1].text = "第一章\n甲章正文。第二章\n乙章正文。第三章\n后章秘密。"
        let entries = try ["第一章", "第二章", "第三章"].enumerated().map { index, title in
            BookOutlineEntry(id: "chapter-\(index)", title: title, page: 2,
                anchor: try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "two", quote: title, in: book))
        }
        book.originalBookOutline = BookChapterOutline(sourceHash: book.sourceHash, sourceFingerprint: try BookOutlineRuntime.fingerprint(in: book),
            scannedUnitCount: 4, totalUnitCount: 4, entries: entries)
        let choice = ReadingQueryRange(chapterStartID: entries[0].id, chapterEndID: entries[1].id)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context(choice))
        XCTAssertEqual(snapshot.unitIDs, ["two"])
        XCTAssertEqual(snapshot.sources.first?.text, "第一章\n甲章正文。第二章\n乙章正文。")
        XCTAssertFalse(snapshot.admits(.init(unitID: "two", quote: "后章秘密。")))
        XCTAssertEqual(try ReadingComponentProjection.project(snapshot, in: book).units.first?.text, snapshot.sources.first?.text)
        book.units[1].text += "修订"
        XCTAssertThrowsError(try snapshot.sourceRanges(in: book))
        XCTAssertThrowsError(try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context(choice)))
    }
    func testRangeHistoryRoundTripsWithoutMakingOldClientsReadUnknownEnum() throws {
        let book = book(), preferences = ReadingAnswerPreferences()
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context(.init(pageStart: 2, pageEnd: 3)))
        let saved = try ReadingChatContext(snapshot: snapshot, avoidsSpoilers: true), data = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(ReadingChatContext.self, from: data), saved)
        let wire = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(wire["scope"] as? String, "selection"); XCTAssertEqual(wire["rangePolicy"] as? String, "explicitSourceRange")
        var modified = book
        modified.chats = ["user", "assistant"].map { role in
            var message = ChatMessage(role: role, content: "范围内讨论"); message.readingContext = saved
            message.conversationMode = .reading; message.answerStyle = .mentor; return message
        }
        XCTAssertEqual(ReadingChatHistory.automaticHistory(in: modified, preferences: preferences, snapshot: snapshot).count, 2)
        let smaller = try ReadingQuerySnapshot.freeze(scope: .range, in: modified, context: context(.init(pageStart: 2, pageEnd: 2)))
        XCTAssertTrue(ReadingChatHistory.automaticHistory(in: modified, preferences: preferences, snapshot: smaller).isEmpty)
    }
    func testActualWireSizeReturnsWholeChinesePageWithinSameBudget() async throws {
        var book = book(); book.units[1].text = String(repeating: "請問將軍，為何在此長歎？", count: 100)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: context(.init(pageStart: 2, pageEnd: 2)))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let returned = try await session.execute(name: "source_read", arguments: ["id": "two"], maximumBytes: 8000), row = try object(returned)
        XCTAssertEqual(row["text"] as? String, book.units[1].text)
        XCTAssertTrue(row["nextOffset"] is NSNull); XCTAssertLessThanOrEqual(returned.utf8.count, 8000)
        XCTAssertEqual(session.sourceExcerpts.last?.1, book.units[1].text)
    }
    func testExplicitRangePreloadIsCompleteOrAbsentAndNeverMarksCoverage() throws {
        var book = book()
        let coverage = try bytes(book.coverage)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context(.init(pageStart: 2, pageEnd: 3)))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let body = try XCTUnwrap(session.initialSource(maximumBytes: 6000))
        XCTAssertTrue(body.contains("周瑜與諸葛亮")); XCTAssertTrue(body.contains("黃蓋獻計"))
        XCTAssertFalse(body.contains("前章秘密")); XCTAssertFalse(body.contains("后章秘密"))
        XCTAssertTrue(session.hasOnlyPreloadedSources); XCTAssertEqual(session.sourceExcerpts.count, 2)
        XCTAssertEqual(try bytes(book.coverage), coverage)
        book.units[1].text = String(repeating: "很长正文。", count: 1000)
        let large = try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context(.init(pageStart: 2, pageEnd: 3)))
        var bounded = ReadingQuerySession(snapshot: large, history: [], loader: nil, providedDocuments: [:], project: book)
        XCTAssertNil(try bounded.initialSource(maximumBytes: 700)); XCTAssertTrue(bounded.sourceExcerpts.isEmpty)
        XCTAssertFalse(bounded.hasOnlyPreloadedSources)
    }
    func testEscapedUnicodeContinuationHasNoGapsAndNeverExceedsWireBudget() async throws {
        var book = book(); book.units[1].text = String(repeating: "中\"\n\t\\/👨‍👩‍👧‍👦e\u{301}\u{0001}", count: 30)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: context(.init(pageStart: 2, pageEnd: 2)))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        var collected = "", offset = 0, requests = 0
        while true {
            let result = try await session.execute(name: "source_read", arguments: ["id": "two", "offset": offset], maximumBytes: 700), row = try object(result)
            XCTAssertLessThanOrEqual(result.utf8.count, 700)
            let text = try XCTUnwrap(row["text"] as? String); XCTAssertFalse(text.isEmpty)
            collected += text; requests += 1
            guard let next = row["nextOffset"] as? Int else { break }
            XCTAssertEqual(next, offset + text.count); XCTAssertGreaterThan(next, offset); offset = next
            XCTAssertLessThan(requests, 100)
        }
        XCTAssertEqual(Data(collected.utf8), Data(book.units[1].text.utf8))
    }
    func testOversizedMetadataDoesNotGrantUnreturnedSource() async throws {
        var book = book(); book.units[1].chapter = String(repeating: "极长定位", count: 1000)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: context(.init(pageStart: 2, pageEnd: 2)))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        // The actual source locator for PDFs is short. Notes have a caller-
        // supplied long title, which must be counted as part of the envelope.
        var notes = book; notes.documents[0].title = String(repeating: "极长标题", count: 1000)
        let noteScope = try ReadingQuerySnapshot.freeze(scope: .notes, in: notes)
        session = ReadingQuerySession(snapshot: noteScope, history: [], loader: nil, providedDocuments: ["private": "正文"], project: notes)
        do { _ = try await session.execute(name: "document_read", arguments: ["id": "private"], maximumBytes: 700); XCTFail("不能忽略元数据体积") } catch {}
        XCTAssertTrue(session.documentExcerpts.isEmpty)
    }
    func testModelSourceSearchUsesReaderScriptMatchingAndOriginalQuotesOnly() async throws {
        let book = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context(.init(pageStart: 2, pageEnd: 3)))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let result = try await session.execute(name: "source_search", arguments: ["keywords": ["周瑜", "诸葛亮"], "mode": "all"], maximumBytes: 8000)
        let hits = try XCTUnwrap(try object(result)["hits"] as? [[String: Any]])
        XCTAssertEqual(hits.count, 1); XCTAssertEqual(hits.first?["id"] as? String, "two")
        XCTAssertTrue((hits.first?["snippet"] as? String)?.contains("諸葛亮") == true)
        XCTAssertFalse(result.contains("前章秘密")); XCTAssertFalse(result.contains("后章秘密"))
        let absent = try await session.execute(name: "source_search", arguments: ["keywords": ["三国演义"]], maximumBytes: 8000)
        XCTAssertEqual(try object(absent)["totalMatches"] as? Int, 0, "不把相关词自动混入主搜索")
    }
    func testPreparationProvidesActualDeclarationsWithoutReadingNotesOrGrantingEvidence() throws {
        let book = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context(.init(pageStart: 2, pageEnd: 3)))
        let proposals = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { _, _ in Data() })
        let session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: ["private": "秘密正文"], project: book, proposalAccess: proposals)
        let json = try XCTUnwrap(session.organizationStartingPoint(maximumBytes: 6000)), value = try object(json)
        XCTAssertLessThanOrEqual(json.utf8.count, 6000); XCTAssertEqual(value["sourceUnitCount"] as? Int, 2)
        XCTAssertEqual(value["bodyProvided"] as? Bool, false)
        XCTAssertFalse(json.contains("秘密正文")); XCTAssertFalse(json.contains("后章秘密")); XCTAssertTrue(session.sourceExcerpts.isEmpty)
        XCTAssertEqual((value["types"] as? [[String: String]])?.map { $0["id"]! }, book.types.prefix(24).map(\.id))
        let readOnly = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        XCTAssertNil(try readOnly.organizationStartingPoint(maximumBytes: 6000))
    }
    func testHostSourceReferencesExpandExactTextAndKeepLiteralValidation() throws {
        let book = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context(.init(pageStart: 2, pageEnd: 3)))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        let supplied = try object(try XCTUnwrap(session.initialSource(maximumBytes: 6000)))
        let refs = try XCTUnwrap(supplied["actualReadFragments"] as? [[String: Any]])
        let ref = try XCTUnwrap(refs.first?["sourceRef"] as? String)
        let input: [String: Any] = ["batch": ["knowledge": ["entities": [["id": "zhou", "typeID": "person", "name": "周瑜", "summary": "", "properties": [:], "aliases": [], "evidence": [["sourceRef": ref]]]], "newEntityIDs": ["zhou"], "anchors": [["clientID": "a", "sourceRef": ref]]]]]
        let data = try session.resolveSourceReferences(in: JSONSerialization.data(withJSONObject: input))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sourceRef"))
        let decoded = try ReadingProposalTools.decode(name: "knowledge_changes_propose", arguments: data)
        XCTAssertEqual(decoded.knowledge?.entities?.first?.evidence.first?.quote, book.units[1].text)
        XCTAssertEqual(decoded.knowledge?.anchors?.first?.quote, book.units[1].text)
        try session.validateProposal(name: "knowledge_changes_propose", data: data)
        XCTAssertTrue(book.entities.isEmpty, "只有引用展开，不自行写入或提交")
    }
    func testSourceReferenceCannotBeForgedMixedOrUsedAfterTextWasDropped() throws {
        let book = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context(.init(pageStart: 2, pageEnd: 3)))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        _ = try session.initialSource(maximumBytes: 6000)
        let ref = try XCTUnwrap(session.sourceReferences.keys.first)
        for row in [["sourceRef": "forged"], ["sourceRef": ref, "quote": "更改后的话"]] {
            XCTAssertThrowsError(try session.resolveSourceReferences(in: JSONSerialization.data(withJSONObject: ["evidence": [row]])))
        }
        let normalProperty = try JSONSerialization.data(withJSONObject: ["properties": ["sourceRef": "用户自己定义的字段"]], options: [.sortedKeys])
        XCTAssertEqual(try session.resolveSourceReferences(in: normalProperty), normalProperty)
        session.sourceExcerpts = []
        XCTAssertThrowsError(try session.resolveSourceReferences(in: JSONSerialization.data(withJSONObject: ["evidence": [["sourceRef": ref]]])))
        XCTAssertThrowsError(try session.resolveSourceReferences(in: Data(repeating: 32, count: 262145)))
    }
    func testPreparationExplainsRealPropertyKeysInsteadOfChineseLabels() throws {
        let book = book(), guide = ReadingProposalSchemas.referenceGuide(in: book)
        let fields = try XCTUnwrap(guide["entityPropertyFields"] as? [[String: Any]])
        let person = try XCTUnwrap(fields.first { $0["typeID"] as? String == "person" })
        XCTAssertEqual(person["keys"] as? [String], ["role", "affiliation", "description"])
        XCTAssertFalse((person["keys"] as? [String] ?? []).contains("身份"))
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: guide).count, 4000)
    }
    func testLargePreloadedRangeDoesNotGetReservedAgainAsFinalEvidence() async throws {
        var project = book(); project.units[1].text = String(repeating: "原文句。", count: 10000)
        let settings = ProviderSettings(model: "offline", maxRequestsPerRun: 100, maxOutputTokens: 393216, contextWindowTokens: 1048576)
        var requests = 0
        _ = try await ReadingAnswerEngine.run(question: "先保存核心整理", project: project, settings: settings, documents: [:],
            context: context(.init(pageStart: 2, pageEnd: 3)), scope: .range, history: [], memory: nil, memoryEnabled: false,
            documentIDs: nil, loader: nil, operationLimit: 1048576, remainingRequests: 100, preferences: .init(interaction: .functional)) { _, _, limit, final in
                requests += 1; XCTAssertFalse(final)
                XCTAssertGreaterThanOrEqual(limit, 80000)
                if requests <= 8 {
                    return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [
                        .init(id: "read-\(requests)", type: "function", function: .init(name: "source_read", arguments: #"{"id":"three"}"#))
                    ], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 80000)
                }
                return .init(message: .init(role: "assistant", content: "黃蓋獻計。[unit:three]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
            }
        XCTAssertEqual(requests, 9)
    }
    func testScopedAnalysisPreservesDerivedLabelsAfterExactEvidenceAdmission() throws {
        var book = book(); book.units[1].text = "公瑾與孔明商議火攻。"
        let source = Evidence(unitID: "two", quote: book.units[1].text)
        book.entities = [.init(id: "zhou", typeID: "person", name: "周瑜", summary: "周瑜筹划火攻。", aliases: ["公瑾"], evidence: [source])]
        book.events = [.init(id: "fire", name: "赤壁火攻的准备", summary: "两位军师议定火攻。", dateText: "第四十四回", participantIDs: ["zhou", "not-in-range"], evidence: [source])]
        let before = try bytes(book)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context(.init(pageStart: 2, pageEnd: 3)))
        let projected = try ReadingComponentProjection.project(snapshot, in: book)
        XCTAssertEqual(projected.entities.first?.name, "周瑜")
        XCTAssertEqual(projected.entities.first?.summary, "周瑜筹划火攻。")
        XCTAssertEqual(projected.events.first?.name, "赤壁火攻的准备")
        XCTAssertEqual(projected.events.first?.summary, "两位军师议定火攻。")
        XCTAssertEqual(projected.events.first?.participantIDs, ["zhou"])
        XCTAssertEqual(projected.events.first?.dateText, "时间待考", "未核实的日期仍沿用原保护")
        XCTAssertEqual(try bytes(book), before)
        XCTAssertEqual(ReadingSpoilerProjection.entity(book.entities[0], in: book, allowedUnitIDs: ["two"])?.name, "公瑾", "普通跟读投影不改变")
    }
    func testScopedDerivedLabelsDoNotRestoreCrossRangeFacts() throws {
        var book = book(); book.units[1].text = "公瑾與孔明商議火攻。"
        let local = Evidence(unitID: "two", quote: book.units[1].text), future = Evidence(unitID: "four", quote: book.units[3].text)
        book.entities = [.init(id: "masked", typeID: "person", name: "后文身份", summary: "后章说明", aliases: ["公瑾"], evidence: [local, future]),
            .init(id: "future", typeID: "person", name: "后章秘密", evidence: [future])]
        book.events = [.init(id: "later", name: "后文结局", summary: "后章结果", participantIDs: ["masked", "future"], evidence: [local, future])]
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context(.init(pageStart: 2, pageEnd: 3)))
        let projected = try ReadingComponentProjection.project(snapshot, in: book)
        XCTAssertEqual(projected.entities.map(\.name), ["公瑾"])
        XCTAssertEqual(projected.entities.first?.summary, "")
        XCTAssertEqual(projected.events.first?.name, "本段关联事件")
        XCTAssertEqual(projected.events.first?.summary, "")
        XCTAssertTrue(projected.events.first?.participantIDs.isEmpty == true)
        XCTAssertEqual(book.events.first?.name, "后文结局")
    }
    func testTimeMapWorkbenchProjectsSharedEventsPlacesAndSelection() throws {
        var book = book(); let source = Evidence(unitID: "two", quote: book.units[1].text)
        book.entities = [.init(id: "place", typeID: "place", name: "火攻地点", latitude: 30, longitude: 114, evidence: [source])]
        book.events = [.init(id: "fire", name: "赤壁火攻准备", summary: "先商议火攻", placeIDs: ["place"], evidence: [source])]
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "two", quote: book.units[1].text, in: book)
        var temporal = TemporalKnowledgeState(); temporal.anchors = [anchor]
        temporal.eventMetadata = [.init(eventID: "fire", extent: .init(sourceText: "本段先后", precision: .narrative, uncertainty: .exact, narrativeStart: 2), sourceAnchorIDs: [anchor.id], assertion: .explicit)]
        book.temporalKnowledge = temporal
        let request = try ReadingComponentRequest.decode(Data(#"{"componentID":"reading.composition","templateID":"reading-time-map"}"#.utf8))
        let definition = try XCTUnwrap(request.resolvedComposition)
        try CompositionRuntime.validate(definition, in: book)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .range, in: book, context: context(.init(pageStart: 2, pageEnd: 3)))
        let prepared = try CompositionRuntime.prepare(definition, in: book, sourceSnapshot: snapshot)
        let result = try CompositionRuntime.project(prepared, selections: ["main": ["fire"]])
        XCTAssertEqual(result["details"]?.items.map(\.id), ["fire"])
        XCTAssertEqual(result["events"]?.items.first?.title, "赤壁火攻准备")
        XCTAssertEqual(result["events"]?.items.first?.extent?.narrativeStart, 2)
        XCTAssertTrue(result["objects"]?.mapPoints.contains { $0.id == "entity.place" && $0.targetID == "place" } == true)
        XCTAssertEqual(Set(definition.parts.map(\.primitive)), [.map, .timeline, .objectDetail, .objectList, .relations, .markdown])
        XCTAssertFalse(String(decoding: try bytes(definition), as: UTF8.self).contains("赤壁火攻准备"), "布局不另存知识正文")
        XCTAssertEqual(book.events.count, 1); XCTAssertEqual(book.entities.count, 1)
    }
    func testTimeMapTemplateKeepsClosedRequestAndExistingTemplate() throws {
        XCTAssertEqual(try ReadingComponentRequest.decode(Data(#"{"componentID":"reading.composition","templateID":"reading-workbench"}"#.utf8)).resolvedComposition, ReadingWorkbench.definition())
        for raw in [#"{"componentID":"relations","templateID":"reading-time-map"}"#, #"{"componentID":"reading.composition","templateID":"reading-time-map","viewID":"x"}"#, #"{"componentID":"reading.composition","templateID":"reading-time-map","displayPurpose":"x"}"#] {
            XCTAssertThrowsError(try ReadingComponentRequest.decode(Data(raw.utf8)))
        }
        let view = ViewDefinition(id: "time-map", title: ReadingWorkbench.timeMapTitle, kind: .knowledge, rendererID: "reading.composition", composition: ReadingWorkbench.definition(for: ReadingWorkbench.timeMapTemplateID))
        XCTAssertTrue(ReadingWorkbench.isWorkbench(view)); XCTAssertTrue(ReadingWorkbench.continuationQuestion(view: view).contains("事件先后和地点"))
    }
    func testLargeConfiguredOutputDoesNotReserveItsCeilingOnEveryToolTurn() async throws {
        let settings = ProviderSettings(model: "offline", maxRequestsPerRun: 100, maxOutputTokens: 393216, contextWindowTokens: 1048576)
        var requests = 0
        let result = try await ReadingAnswerEngine.run(question: "整理赤壁核心内容", project: book(), settings: settings, documents: [:],
            context: context(.init(pageStart: 2, pageEnd: 3)), scope: .range, history: [], memory: nil, memoryEnabled: false,
            documentIDs: nil, loader: nil, operationLimit: 1048576, remainingRequests: 100, preferences: .init(interaction: .functional)) { messages, tools, limit, final in
                requests += 1
                XCTAssertFalse(final, "剩余额度足够时不能因393216的输出上限提前禁用工具")
                let prepared = try ProviderClient.prepare(messages: messages, tools: tools, settings: settings, apiKey: "", remainingTokens: limit)
                if requests == 1 {
                    XCTAssertEqual(try self.object(String(decoding: prepared.request.httpBody!, as: UTF8.self))["max_tokens"] as? Int, settings.maxOutputTokens, "没有偷偷改小真实输出上限")
                }
                if requests <= 12 {
                    return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [
                        .init(id: "read-\(requests)", type: "function", function: .init(name: "source_read", arguments: #"{"id":"two"}"#))
                    ], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 60000)
                }
                return .init(message: .init(role: "assistant", content: "周瑜與諸葛亮商議火攻。[unit:two]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
            }
        XCTAssertEqual(requests, 13); XCTAssertEqual(result.message.evidence.first?.unitID, "two")
    }
}
