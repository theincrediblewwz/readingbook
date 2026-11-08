import Foundation
import XCTest
@testable import ReadingCore

private actor TemporalFormSubmissions {
    var values: [Data] = []
    func submit(_ data: Data) -> Data { values.append(data); return Data(#"{"ok":true,"status":"success","applied":true}"#.utf8) }
}

final class ReadingTemporalFormTests: XCTestCase {
    private func session() throws -> ReadingQuerySession {
        var book = BookProject(title: "时间表单合成回归", originalName: "book.txt", sourceHash: "temporal-form", units: [
            .init(id: "unit-000001", order: 605, chapter: "第四十九回", page: 606, text: "將近三更時分，忽聽\n風聲響。"),
            .init(id: "unit-000002", order: 611, chapter: "第五十回", page: 612, text: "走至五更，回望火光漸遠。"),
            .init(id: "unit-000003", order: 900, chapter: "后文", page: 901, text: "秘密后文不能出现在修复提示中。")])
        PluginEngine.seed(&book)
        book.events = [.init(id: "wind", name: "起风", evidence: [.init(unitID: book.units[0].id, quote: book.units[0].text)]),
                       .init(id: "retreat", name: "撤退", evidence: [.init(unitID: book.units[1].id, quote: book.units[1].text)])]
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: book.units[0].id, quote: book.units[0].text, in: book)
        book.temporalKnowledge = .init(anchors: [anchor], eventMetadata: [.init(eventID: "wind", kind: "event", sourceAnchorIDs: [anchor.id], assertion: .explicit)])
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: book)
        var query = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        for unit in book.units.prefix(2) {
            query.sourceExcerpts.append((unit.id, unit.text))
            query.sourceReferences[unit.id] = .init(unitID: unit.id, quote: unit.text)
        }
        return query
    }
    private func extent(_ span: [String: Any] = ["startAnchorID": "a"]) -> [String: Any] {
        ["sourceText": "", "precision": "narrative", "uncertainty": "exact", "kind": "point", "assertion": "explicit", "explanation": "", "sourceSpan": span]
    }
    private func payload(_ time: [String: Any], second: [String: Any]? = nil, assertion: String = "explicit") throws -> Data {
        var rows: [[String: Any]] = [["eventID": "wind", "kind": "event", "extent": time, "sourceAnchorIDs": ["a", "b"], "assertion": assertion, "explanation": "原文记述"]]
        if let second { rows.append(["eventID": "retreat", "kind": "event", "extent": second, "sourceAnchorIDs": ["b"], "assertion": "explicit", "explanation": ""]) }
        return try JSONSerialization.data(withJSONObject: ["batch": ["knowledge": [
            "anchors": [["clientID": "a", "sourceRef": "unit-000001"], ["clientID": "b", "sourceRef": "unit-000002"]], "eventMetadata": rows]]])
    }
    private func resolved(_ time: [String: Any], query: ReadingQuerySession) throws -> Data {
        try query.resolveTemporalSourceSpans(in: query.resolveSourceReferences(in: payload(time)))
    }
    func testSourceSpanUsesActualOrderNotIDOrPageNumberAndIsNotStored() throws {
        let query = try session(), data = try resolved(extent(), query: query)
        try query.validateProposal(name: "knowledge_changes_propose", data: data)
        let value = try XCTUnwrap(ReadingProposalTools.decode(name: "knowledge_changes_propose", arguments: data).knowledge?.eventMetadata?.first?.extent)
        XCTAssertEqual(value.narrativeStart, 605); XCTAssertNil(value.narrativeEnd)
        XCTAssertEqual(value.narrativeDomain, "source-order"); XCTAssertEqual(value.sourceText, "")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sourceSpan"))
        XCTAssertNoThrow(try TemporalKnowledgeRuntime.validateExtent(value))
    }
    func testIntervalResolvesBothDeclaredAnchorsWithoutInventingCalendarDate() throws {
        let query = try session(); var time = extent(["startAnchorID": "a", "endAnchorID": "b"]); time["kind"] = "interval"
        let data = try resolved(time, query: query); try query.validateProposal(name: "knowledge_changes_propose", data: data)
        let value = try XCTUnwrap(ReadingProposalTools.decode(name: "knowledge_changes_propose", arguments: data).knowledge?.eventMetadata?.first?.extent)
        XCTAssertEqual(value.narrativeStart, 605); XCTAssertEqual(value.narrativeEnd, 611); XCTAssertNil(value.calendar); XCTAssertNil(value.start)
    }
    func testManualOrderDatesAndUnknownKeysCannotMixWithSourceSpan() throws {
        let query = try session()
        for extra: [String: Any] in [["narrativeStart": 1], ["narrativeEnd": 2], ["calendar": "建安"], ["start": ["year": 12]], ["precision": "day"], ["narrativeDomain": "chapters"]] {
            var time = extent(); time.merge(extra) { _, next in next }
            XCTAssertThrowsError(try resolved(time, query: query))
        }
        for span: [String: Any] in [["startAnchorID": true], ["startAnchorID": "a", "page": 606], ["endAnchorID": "b"], ["startAnchorID": "a", "endAnchorID": NSNull()]] {
            XCTAssertThrowsError(try resolved(extent(span), query: query))
        }
    }
    func testReversedUnknownAndUndeclaredEndpointsAreRejected() throws {
        let query = try session()
        for span in [["startAnchorID": "b", "endAnchorID": "a"], ["startAnchorID": "missing"], ["startAnchorID": "unit-000001"]] {
            XCTAssertThrowsError(try resolved(extent(span), query: query))
        }
        var raw = try JSONSerialization.jsonObject(with: query.resolveSourceReferences(in: payload(extent()))) as! [String: Any]
        var batch = raw["batch"] as! [String: Any], knowledge = batch["knowledge"] as! [String: Any]
        var rows = knowledge["eventMetadata"] as! [[String: Any]]; rows[0]["sourceAnchorIDs"] = ["b"]
        knowledge["eventMetadata"] = rows; batch["knowledge"] = knowledge; raw["batch"] = batch
        XCTAssertThrowsError(try query.resolveTemporalSourceSpans(in: JSONSerialization.data(withJSONObject: raw)))
    }
    func testUnreadAndCroppedTextCannotGrantSourceSpanOrLeakRepairHints() throws {
        var query = try session()
        var raw = try JSONSerialization.jsonObject(with: payload(extent())) as! [String: Any], batch = raw["batch"] as! [String: Any], knowledge = batch["knowledge"] as! [String: Any]
        knowledge["anchors"] = [["clientID": "a", "unitID": "unit-000003", "quote": "秘密后文不能出现在修复提示中。"]]
        batch["knowledge"] = knowledge; raw["batch"] = batch
        do { _ = try query.resolveTemporalSourceSpans(in: JSONSerialization.data(withJSONObject: raw)); XCTFail("Unread anchor") }
        catch let error as ReadingProposalTemporalError {
            XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: error.issues), as: UTF8.self).contains("秘密后文"))
        }
        query.sourceExcerpts = [("unit-000001", "風聲響。")]
        XCTAssertThrowsError(try query.resolveTemporalSourceSpans(in: query.resolveSourceReferences(in: payload(extent()))))
    }
    func testSeveralWrongTimeLabelsAndFactClassificationReturnTogether() throws {
        let query = try session(); var first = extent(), second = extent()
        first.removeValue(forKey: "sourceSpan"); second.removeValue(forKey: "sourceSpan")
        first.merge(["sourceText": "次日清晨，孫權升堂。", "narrativeDomain": "source-order", "narrativeStart": 49]) { _, next in next }
        second.merge(["sourceText": "天明以后抵达。", "narrativeDomain": "source-order", "narrativeStart": 611]) { _, next in next }
        let data = try query.resolveSourceReferences(in: payload(first, second: second, assertion: "inferred"))
        do { try query.validateProposal(name: "knowledge_changes_propose", data: data); XCTFail("Must not silently repair facts") }
        catch let error as ReadingProposalTemporalError {
            XCTAssertEqual(error.issues.compactMap { $0["path"] as? String }, ["$.batch.knowledge.eventMetadata[0].extent.sourceText", "$.batch.knowledge.eventMetadata[0].extent.narrativeStart", "$.batch.knowledge.eventMetadata[1].extent.sourceText"])
            XCTAssertEqual(error.metadataIssues.first?["currentValue"], "explicit")
            XCTAssertEqual(error.metadataIssues.first?["path"], "$.batch.knowledge.eventMetadata[0].assertion")
            XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: error.issues), as: UTF8.self).contains("秘密后文"))
        }
        XCTAssertNil(query.project?.temporalKnowledge?.eventMetadata.first?.extent)
        XCTAssertEqual(query.project?.temporalKnowledge?.eventMetadata.first?.assertion, .explicit)
    }
    func testNonliteralTimeWordsAreNotSilentlyErasedEvenWithSourceSpan() throws {
        let query = try session(); var time = extent(); time["sourceText"] = "已经天明"
        let data = try resolved(time, query: query)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("已经天明"))
        XCTAssertThrowsError(try query.validateProposal(name: "knowledge_changes_propose", data: data))
    }
    func testOnlyNewlineBreaksCanBeCanonicalizedInTimeQuote() throws {
        let query = try session(); var time = extent(); time["sourceText"] = "忽聽風聲響"
        let data = try resolved(time, query: query)
        XCTAssertNoThrow(try query.validateProposal(name: "knowledge_changes_propose", data: data))
        time["sourceText"] = "忽听风声响"; XCTAssertThrowsError(try query.validateProposal(name: "knowledge_changes_propose", data: resolved(time, query: query)))
    }
    func testEmptyPositionLabelCannotWeakenDateOrUnscopedNarrativeValidation() throws {
        let time = TemporalExtent(sourceText: "", precision: .narrative, uncertainty: .exact, narrativeStart: 605, assertion: .explicit, narrativeDomain: "source-order")
        XCTAssertNoThrow(try TemporalKnowledgeRuntime.validateExtent(time))
        var legacy = time; legacy.narrativeDomain = nil; XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateExtent(legacy))
        legacy.narrativeDomain = "chapters"; XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateExtent(legacy))
        let date = TemporalExtent(sourceText: "", calendar: "建安", start: .init(year: 12, month: 11, day: 20), precision: .day, uncertainty: .exact)
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateExtent(date))
    }
    func testStoredPositionStillRequiresItsOwnReferencedOriginalOrder() throws {
        let query = try session(); var book = query.project!
        let anchor = book.temporalKnowledge!.anchors[0]
        book.temporalKnowledge!.eventMetadata[0].extent = .init(sourceText: "", precision: .narrative, uncertainty: .exact, narrativeStart: 605, assertion: .explicit, narrativeDomain: "source-order")
        XCTAssertNoThrow(try TemporalKnowledgeRuntime.validateStoredState(in: book))
        book.temporalKnowledge!.eventMetadata[0].extent!.narrativeStart = 611
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateStoredState(in: book))
        XCTAssertEqual(book.temporalKnowledge!.eventMetadata[0].sourceAnchorIDs, [anchor.id])
    }
    func testEngineReturnsAllTimeFieldsThenSubmitsOnlyExplicitCorrectedSpan() async throws {
        let query = try session(), submissions = TemporalFormSubmissions(), book = query.project!
        let proposals = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { _, data in await submissions.submit(data) })
        let good = try payload(extent())
        var bad = extent(); bad.removeValue(forKey: "sourceSpan")
        bad.merge(["sourceText": "次日清晨，孫權升堂。", "narrativeDomain": "source-order", "narrativeStart": 49]) { _, next in next }
        let wrong = try payload(bad, assertion: "inferred")
        var context = ReadingContext(unitID: book.units[0].id, page: 606)
        context.queryRange = .init(pageStart: 606, pageEnd: 612)
        var requests = 0
        _ = try await ReadingAnswerEngine.run(question: "补充事件先后", project: book, settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128000), documents: [:],
            context: context, scope: .range, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil,
            operationLimit: 128000, remainingRequests: 5, proposalAccess: proposals, preferences: .init(interaction: .functional)) { messages, _, _, _ in
                requests += 1
                if requests == 2 {
                    let text = try XCTUnwrap(messages.last?["content"] as? String)
                    let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                    XCTAssertEqual((receipt["temporalIssues"] as? [[String: Any]])?.count, 2)
                    XCTAssertEqual((receipt["metadataIssues"] as? [[String: String]])?.count, 1)
                    XCTAssertNil(receipt["referenceGuide"])
                    let count = await submissions.values.count; XCTAssertEqual(count, 0)
                }
                if requests <= 2 { return .init(message: .init(role: "assistant", content: nil, refusal: nil,
                    tool_calls: [.init(id: "temporal-\(requests)", type: "function", function: .init(name: "knowledge_changes_propose", arguments: String(decoding: requests == 1 ? wrong : good, as: UTF8.self)))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20) }
                return .init(message: .init(role: "assistant", content: "已补充原文先后。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
            }
        let values = await submissions.values
        XCTAssertEqual(requests, 3); XCTAssertEqual(values.count, 1)
        let submitted = try XCTUnwrap(values.first)
        let extent = try XCTUnwrap(ReadingProposalTools.decode(name: "knowledge_changes_propose", arguments: submitted).knowledge?.eventMetadata?.first?.extent)
        XCTAssertEqual(extent.narrativeStart, 605); XCTAssertEqual(extent.sourceText, "")
        XCTAssertFalse(String(decoding: submitted, as: UTF8.self).contains("sourceSpan"))
    }
}
