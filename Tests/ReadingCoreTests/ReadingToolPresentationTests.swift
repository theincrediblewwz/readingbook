import Foundation
import XCTest
@testable import ReadingCore

private actor ToolPresentationRequests {
    var values: [Data] = []
    func record(_ messages: [[String: Any]]) throws -> Int {
        values.append(try JSONSerialization.data(withJSONObject: messages)); return values.count
    }
}
private final class ToolPresentationProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AIProgressEvent] = []
    func record(_ value: AIProgressEvent) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func traces() -> [AIToolTrace] { lock.lock(); defer { lock.unlock() }; return values.compactMap(\.toolTrace) }
}

final class ReadingToolPresentationTests: XCTestCase {
    private func book() -> BookProject {
        let quote = String(repeating: "黃蓋火攻。\n曹操退軍。", count: 30)
        var book = BookProject(id: "wire-test", title: "合成阅读测试", originalName: "book.txt", sourceHash: "wire-source", units: [
            .init(id: "u1", order: 0, chapter: "一", page: 1, text: quote),
            .init(id: "u2", order: 1, chapter: "二", page: 2, text: "后文未提供。")])
        PluginEngine.seed(&book)
        book.entities = [.init(id: "gai", typeID: "person", name: "黃蓋", evidence: [.init(unitID: "u1", quote: quote)])]
        return book
    }
    private func session() throws -> ReadingQuerySession {
        let book = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u1", page: 1))
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
        _ = try session.initialSource(maximumBytes: 8000); return session
    }
    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    func testOnlyWholeAlreadySuppliedEvidenceCompactsAndRoundTripsLiterally() throws {
        let session = try session(), quote = book().units[0].text
        let raw = try session.json(["ok": true, "version": "unchanged-hash", "object": ["id": "gai", "summary": quote,
            "evidence": [["unitID": "u1", "quote": quote]]], "nextOffset": 20, "partial": true])
        let output = try session.modelReadToolResult(raw, tool: "object_get"), row = try object(output)
        let nested = try XCTUnwrap(row["object"] as? [String: Any]), evidence = try XCTUnwrap(nested["evidence"] as? [[String: Any]])
        XCTAssertEqual(evidence.count, 1); XCTAssertEqual(evidence.first?["sourceRef"] as? String, "u1")
        XCTAssertNil(evidence.first?["quote"]); XCTAssertEqual(nested["summary"] as? String, quote)
        XCTAssertEqual(row["version"] as? String, "unchanged-hash"); XCTAssertEqual(row["nextOffset"] as? Int, 20); XCTAssertEqual(row["partial"] as? Bool, true)
        XCTAssertLessThan(output.utf8.count, raw.utf8.count)
        let expanded = try session.resolveSourceReferences(in: JSONSerialization.data(withJSONObject: ["evidence": evidence]))
        let decoded = try object(String(decoding: expanded, as: UTF8.self))
        let restored = try XCTUnwrap((decoded["evidence"] as? [[String: String]])?.first)
        XCTAssertTrue(restored["quote"]?.utf8.elementsEqual(quote.utf8) == true); XCTAssertEqual(restored["unitID"], "u1")
        XCTAssertEqual(session.sourceExcerpts.count, 1); XCTAssertEqual(session.sourceReferences.count, 2)
    }
    func testUnsentPartialUnicodeEquivalentAndAdditionalEvidenceFieldsAreNotRewritten() throws {
        var session = try session()
        let quote = book().units[0].text
        let decomposed = "e\u{301}" + quote, composed = "é" + quote
        session.sourceReferences["unicode"] = .init(unitID: "u1", quote: decomposed)
        session.sourceExcerpts.append(("u1", decomposed))
        XCTAssertEqual(decomposed, composed, "Swift规范等价不等于引文逐字节相同")
        let rows: [[String: Any]] = [["unitID": "u1", "quote": String(quote.prefix(5))], ["unitID": "u2", "quote": "后文未提供。"],
            ["unitID": "u1", "quote": composed], ["unitID": "u1", "quote": quote, "custom": true]]
        let raw = try session.json(["evidence": rows, "quote": quote])
        XCTAssertEqual(try session.modelReadToolResult(raw, tool: "relations_list"), raw)
        XCTAssertEqual(try session.modelReadToolResult(raw, tool: "source_read"), raw)
        XCTAssertEqual(try session.modelReadToolResult("invalid", tool: "object_get"), "invalid")
        session.sourceExcerpts = []
        XCTAssertEqual(try session.modelReadToolResult(try session.json(["evidence": [["unitID": "u1", "quote": quote]]]), tool: "object_get"), try session.json(["evidence": [["unitID": "u1", "quote": quote]]]))
    }
    func testReceiptOriginsAndLatestDecisionsSurviveRepeatedDiscovery() throws {
        var session = try session()
        try session.recordHostReceipt(#"{"tool":"component_show","status":"needs_confirmation","proposalID":"p1","applied":false}"#, tool: "knowledge_changes_propose")
        try session.recordHostReceipt(#"{"status":"success","proposalID":"p1","applied":true,"operationID":"saved"}"#, tool: "knowledge_changes_propose")
        try session.recordHostReceipt(#"{"status":"needs_confirmation","proposalID":"p2","applied":false}"#, tool: "knowledge_changes_propose")
        try session.recordHostReceipt(#"{"status":"needs_confirmation","proposalID":"p3","applied":false}"#, tool: "knowledge_changes_propose")
        try session.recordHostReceipt(#"{"status":"discarded","proposalID":"p3","applied":false}"#, tool: "knowledge_changes_propose")
        try session.recordHostReceipt(#"{"status":"success","opened":true,"viewID":"map","actualView":{"status":"unsupported"}}"#, tool: "component_show")
        for _ in 0..<20 { try session.recordHostReceipt(#"{"status":"success","message":"目录返回"}"#, tool: "components_list") }
        let summaries = session.closingHostReceiptSummaries()
        XCTAssertEqual(summaries.count, 4)
        XCTAssertEqual(summaries.first?["applied"] as? Bool, true); XCTAssertEqual(summaries.first?["tool"] as? String, "knowledge_changes_propose")
        XCTAssertEqual(summaries[1]["status"] as? String, "needs_confirmation"); XCTAssertEqual(summaries[2]["status"] as? String, "discarded")
        XCTAssertEqual(summaries.last?["opened"] as? Bool, true)
        let final = try object(try XCTUnwrap(session.finalEvidence(maximumBytes: 7000)))
        XCTAssertEqual((final["hostToolReceipts"] as? [[String: Any]])?.count, 4)
        let small = try XCTUnwrap(session.finalEvidence(maximumBytes: 600)); XCTAssertLessThanOrEqual(small.utf8.count, 600)
    }
    func testActualWireMatchesProgressAndKeepsCanonicalKnowledgeUntouched() async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let book = book(), before = try encoder.encode(book), requests = ToolPresentationRequests(), progress = ToolPresentationProgress()
        let result = try await ReadingAnswerEngine.run(question: "黃蓋是谁？", project: book,
            settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1),
            scope: .page, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil,
            operationLimit: 512_000, remainingRequests: 4, progress: { progress.record($0) }) { messages, _, _, _ in
                let count = try await requests.record(messages)
                if count == 1 {
                    let call = ProviderClient.ToolCall(id: "read", type: "function", function: .init(name: "object_get", arguments: #"{"id":"gai"}"#))
                    return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [call], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 10)
                }
                return .init(message: .init(role: "assistant", content: "原文记载黃蓋火攻。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 10)
            }
        let sent = await requests.values
        let messages = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent.last)) as? [[String: Any]])
        let wire = try XCTUnwrap(messages.first { $0["tool_call_id"] as? String == "read" }?["content"] as? String)
        let row = try object(wire), nested = try XCTUnwrap(row["object"] as? [String: Any])
        let evidence = try XCTUnwrap((nested["evidence"] as? [[String: Any]])?.first)
        XCTAssertEqual(evidence["sourceRef"] as? String, "u1"); XCTAssertNil(evidence["quote"])
        XCTAssertNotNil(row["previouslySaved"], "派生旧简介保持独立，不把它的片段自动替换成新原文权限")
        XCTAssertEqual(progress.traces().last?.result.text, wire)
        XCTAssertEqual(result.diagnostics.sourceReadIDs, ["u1"]); XCTAssertEqual(try encoder.encode(book), before)
    }
    func testBudgetClosingGetsAppliedDecisionInsteadOfEarlierPendingReceipt() async throws {
        let book = book(), requests = ToolPresentationRequests()
        let proposals = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { _, _ in
            Data(#"{"status":"needs_confirmation","proposalID":"reviewed","applied":false}"#.utf8)
        }, currentProject: { book }, awaitReview: { _ in
            Data(#"{"status":"success","proposalID":"reviewed","applied":true,"message":"已实际保存"}"#.utf8)
        })
        _ = try await ReadingAnswerEngine.run(question: "整理已有资料", project: book,
            settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128_000), documents: [:],
            context: .init(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false,
            documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 2, proposalAccess: proposals,
            preferences: .init(interaction: .functional)) { messages, _, _, _ in
                let count = try await requests.record(messages)
                if count == 1 {
                    let call = ProviderClient.ToolCall(id: "proposal", type: "function", function: .init(name: "knowledge_changes_propose", arguments: #"{"batch":{"knowledge":{}}}"#))
                    return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [call], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 10)
                }
                return .init(message: .init(role: "assistant", content: "已实际保存。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 10)
            }
        let sent = await requests.values
        let messages = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent.last)) as? [[String: Any]])
        let receipt = try XCTUnwrap(messages.compactMap { $0["content"] as? String }.first { $0.contains("软件回执（非正文）") })
        XCTAssertTrue(receipt.contains("knowledge_changes_propose")); XCTAssertTrue(receipt.contains("\"applied\":true"))
        XCTAssertTrue(receipt.contains("\"status\":\"success\"")); XCTAssertFalse(receipt.contains("needs_confirmation"))
        XCTAssertEqual(sent.count, 2)
    }
    func testClosingKeepsBoundedActualMapCountsScopeAndTimeInsteadOfOnlyOpened() throws {
        var session = try session()
        let observation: [String: Any] = ["status":"success", "rendererID":"map", "sourceScope":"本次第43–50回", "partial":true,
            "items":Array(repeating:["name":String(repeating:"不应复制的大文本",count:1000)],count:100),
            "mapViewports":[["partID":"main","projectedRouteCount":9,"visibleRouteCount":8,"partial":false,
                             "visibleRouteIDs":Array(repeating:"不要保留的大数组",count:1000)]],
            "timeFilterApplied":true,"timeWindows":[["groupID":"main","axis":"narrative","from":1,"to":4,"current":3]]]
        try session.recordHostReceipt(try session.json(["status":"success","opened":true,"viewID":"map","actualView":observation]),tool:"component_show")
        let packed = try XCTUnwrap(session.finalEvidence(maximumBytes:2400)), final = try object(packed)
        let receipts = try XCTUnwrap(final["hostToolReceipts"] as? [[String:Any]])
        let actual = try XCTUnwrap(receipts.last?["actualView"] as? [String:Any])
        XCTAssertEqual(actual["status"] as? String,"success");XCTAssertEqual(actual["sourceScope"] as? String,"本次第43–50回")
        let map = try XCTUnwrap((actual["mapViewports"] as? [[String:Any]])?.first)
        XCTAssertEqual(map["projectedRouteCount"] as? Int,9);XCTAssertEqual(map["visibleRouteCount"] as? Int,8)
        XCTAssertEqual(actual["timeFilterApplied"] as? Bool,true)
        XCTAssertEqual((actual["timeWindows"] as? [[String:Any]])?.first?["current"] as? Int,3)
        XCTAssertNil(actual["items"]);XCTAssertNil(map["visibleRouteIDs"]);XCTAssertLessThanOrEqual(packed.utf8.count,2400)
    }
    func testClosingLatestPendingObservationSupersedesEarlierReadyMap() throws {
        var session = try session()
        try session.recordHostReceipt(#"{"status":"success","opened":true,"viewID":"map","actualView":{"status":"success","mapViewports":[{"projectedRouteCount":9,"visibleRouteCount":8}]}}"#,tool:"component_show")
        try session.recordHostReceipt(#"{"rendererID":"map","observationStatus":"pending","timeFilterApplied":false,"mapViewports":[],"timeWindows":[]}"#,tool:"workspace_context_get")
        let receipts = session.closingHostReceiptSummaries()
        XCTAssertEqual(receipts.count,2);XCTAssertNil(receipts.first?["actualView"])
        let actual = try XCTUnwrap(receipts.last?["actualView"] as? [String:Any])
        XCTAssertEqual(actual["observationStatus"] as? String,"pending")
        XCTAssertEqual(actual["timeFilterApplied"] as? Bool,false)
        XCTAssertEqual((actual["mapViewports"] as? [[String:Any]])?.count,0)
        XCTAssertFalse(try session.json(receipts).contains("visibleRouteCount"))
    }
    func testBudgetClosingModelActuallyReceivesOpenedCanvasReceipt() async throws {
        let book=book(),requests=ToolPresentationRequests()
        let workspace=ReadingWorkspaceSnapshot(bookID:book.id,sourceHash:book.sourceHash,rendererID:"map",
            visibleObjects:.init(rendererID:"map",objectIDs:["gai"]),mapViewports:[.init(partID:"main",latitude:30,longitude:110,
                latitudeDelta:2,longitudeDelta:3,objectIDs:["gai"],visibleRouteIDs:[],projectedRouteIDs:[])],observationStatus:.ready)
        let host=ReadingHostToolAccess(viewActions:["component_show"],performViewAction:{_,_ in
            Data(#"{"ok":true,"status":"success","opened":true,"viewID":"map"}"#.utf8)
        },readWorkspaceAfterOpening:{_ in workspace})
        _ = try await ReadingAnswerEngine.run(question:"打开已有地图并核对实际画面",project:book,
            settings:.init(model:"offline",maxOutputTokens:512,contextWindowTokens:128_000),documents:[:],context:.init(unitID:"u1",page:1),
            scope:.page,history:[],memory:nil,memoryEnabled:false,documentIDs:nil,loader:nil,operationLimit:128_000,remainingRequests:2,
            hostTools:host,preferences:.init(interaction:.functional)) { messages,_,_,_ in
                let count=try await requests.record(messages)
                if count==1 {
                    return .init(message:.init(role:"assistant",content:nil,refusal:nil,tool_calls:[.init(id:"show",type:"function",
                        function:.init(name:"component_show",arguments:#"{"viewID":"map","confirmationOnly":false}"#))],reasoning_content:nil),finishReason:"tool_calls",tokenCost:10)
                }
                return .init(message:.init(role:"assistant",content:"已打开，当前全时段，没有行动路线。",refusal:nil,tool_calls:nil,reasoning_content:nil),finishReason:"stop",tokenCost:10)
            }
        let sent=await requests.values
        let messages=try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(sent.last)) as? [[String:Any]])
        let summary=try XCTUnwrap(messages.compactMap{$0["content"] as? String}.first{$0.contains("软件回执（非正文）")})
        XCTAssertTrue(summary.contains("actualView"));XCTAssertTrue(summary.contains("projectedRouteCount"))
        XCTAssertTrue(summary.contains("visibleRouteCount"));XCTAssertTrue(summary.contains("timeFilterApplied"))
        XCTAssertTrue(summary.contains("\"status\":\"success\""));XCTAssertEqual(sent.count,2)
    }
    func testReadingModeDoesNotAcquireNewWorkspaceObservationCapability() async throws {
        let book=book(),requests=ToolPresentationRequests(),observations=ToolPresentationRequests()
        let value=ReadingWorkspaceSnapshot(bookID:book.id,sourceHash:book.sourceHash,rendererID:"map",
            visibleObjects:.init(rendererID:"map",objectIDs:["gai"]),observationStatus:.ready)
        let host=ReadingHostToolAccess(viewActions:["component_show"],performViewAction:{_,_ in
            Data(#"{"ok":true,"status":"success","opened":true,"viewID":"map"}"#.utf8)
        },readWorkspace:{_ = try await observations.record([["kind":"read"]]);return value},
          readWorkspaceAfterOpening:{_ in _ = try await observations.record([["kind":"settle"]]);return value})
        _ = try await ReadingAnswerEngine.run(question:"打开已有地图",project:book,
            settings:.init(model:"offline",maxOutputTokens:512,contextWindowTokens:128_000),documents:[:],context:.init(unitID:"u1",page:1),
            scope:.page,history:[],memory:nil,memoryEnabled:false,documentIDs:nil,loader:nil,operationLimit:128_000,remainingRequests:2,
            hostTools:host,preferences:.init(interaction:.reading)) { messages,_,_,_ in
                let count=try await requests.record(messages)
                if count==1 {
                    return .init(message:.init(role:"assistant",content:nil,refusal:nil,tool_calls:[.init(id:"show",type:"function",
                        function:.init(name:"component_show",arguments:#"{"viewID":"map","confirmationOnly":false}"#))],reasoning_content:nil),finishReason:"tool_calls",tokenCost:10)
                }
                return .init(message:.init(role:"assistant",content:"已打开地图。",refusal:nil,tool_calls:nil,reasoning_content:nil),finishReason:"stop",tokenCost:10)
            }
        let seen=await observations.values
        XCTAssertTrue(seen.isEmpty)
    }
}
