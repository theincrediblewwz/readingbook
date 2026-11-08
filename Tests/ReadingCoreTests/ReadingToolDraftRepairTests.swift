import Foundation
import XCTest
@testable import ReadingCore

private actor DraftRepairHost {
    var calls: [(String, Data)] = []
    var reviews = 0
    func show(_ name: String, _ data: Data) -> Data {
        calls.append((name, data))
        return Data(#"{"ok":true,"status":"success","opened":true,"analysisCreated":false,"rendererID":"reading.composition","viewID":"map"}"#.utf8)
    }
    func prepare(_ name: String, _ data: Data) -> Data {
        calls.append((name, data))
        return Data(#"{"ok":false,"status":"needs_confirmation","applied":false,"proposalID":"review-repaired"}"#.utf8)
    }
    func review(_ id: String) -> Data {
        reviews += 1
        return Data(#"{"ok":true,"status":"success","applied":true,"proposalID":"review-repaired"}"#.utf8)
    }
}

final class ReadingToolDraftRepairTests: XCTestCase {
    private func book() -> BookProject {
        var value = BookProject(title: "草案修正合成回归", originalName: "book.txt", sourceHash: "draft-repair", units: [
            .init(id: "u1", order: 0, chapter: "第一回", page: 1, text: "黄盖乘风火攻。"),
            .init(id: "u2", order: 1, chapter: "后文", page: 2, text: "未分享的后文，不可带入。")])
        PluginEngine.seed(&value); return value
    }
    private func object(_ value: Any) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value)) as? [String: Any])
    }
    private func patch(_ id: String, _ path: String, _ value: Any) -> [String: Any] {
        ["draftID": id, "edits": [["operation": "set", "path": path, "value": value]]]
    }
    private func query(_ value: BookProject, host: ReadingHostToolAccess? = nil, proposals: ReadingProposalToolAccess? = nil) throws -> ReadingQuerySession {
        var q = ReadingQuerySession(snapshot: try ReadingQuerySnapshot.freeze(scope: .page, in: value, context: .init(unitID: "u1")), history: [], loader: nil,
            providedDocuments: [:], project: value, hostTools: host, proposalAccess: proposals)
        _ = try q.initialSource(maximumBytes: 16_000); return q
    }
    private func invalidComposition() throws -> [String: Any] {
        var value = try XCTUnwrap(ReadingWorkbench.definition(for: ReadingWorkbench.timeMapTemplateID))
        value.parts[2].timeGroup = "wrong"; value.layout[0].children[0] = "map"
        return try object(JSONSerialization.jsonObject(with: JSONEncoder().encode(ReadingComponentRequest(componentID: "reading.composition", composition: value))))
    }
    private func invalidKnowledge() -> [String: Any] {
        ["batch": ["knowledge": ["newEntityIDs": ["new"], "entities": [["id": "new", "typeID": "person", "name": "黄盖", "summary": "乘风火攻", "properties": [:], "aliases": [], "evidence": [["sourceRef": "missing"]]]]]]]
    }
    func testPointerEditsPreserveUntouchedFieldsAndEscapedPropertyNames() throws {
        let original: [String: Any] = ["a/b": ["~key": ["old", "kept"]], "dot.key": "original", "other": ["keep": true]]
        let draft = ReadingToolDraft(tool: "knowledge_changes_propose", arguments: try JSONSerialization.data(withJSONObject: original))
        let repaired = try draft.applying(["draftID": draft.id, "edits": [["operation": "set", "path": "/a~1b/~0key/0", "value": "new"], ["operation": "set", "path": "/dot.key", "value": NSNull()], ["operation": "set", "path": "/added", "value": ["valid": 1]]]])
        XCTAssertEqual((repaired["a/b"] as? [String: [String]])?["~key"], ["new", "kept"])
        XCTAssertTrue(repaired["dot.key"] is NSNull); XCTAssertEqual((repaired["other"] as? [String: Bool])?["keep"], true)
        XCTAssertEqual((repaired["added"] as? [String: Int])?["valid"], 1)
        XCTAssertEqual(try draft.applying(patch(draft.id, "/dot.key", "again"))["dot.key"] as? String, "again")
        XCTAssertTrue(String(decoding: draft.arguments, as: UTF8.self).contains("original"))
    }
    func testMalformedAndOversizedPatchesAreAtomicAndDoNotReplaceTheRoot() throws {
        let draft = ReadingToolDraft(tool: "component_show", arguments: Data(#"{"array":[1,2],"keep":"yes"}"#.utf8))
        for path in ["", "$", "array/0", "/array/-", "/array/-1", "/array/00", "/array/2", "/array/+0", "/array/999999999999999999999", "/keep/child", "/bad~2", "/absent/child", "/" + Array(repeating: "a", count: 17).joined(separator: "/")] {
            XCTAssertThrowsError(try draft.applying(patch(draft.id, path, "bad")), path)
        }
        XCTAssertThrowsError(try draft.applying(patch("stale", "/keep", "no")))
        XCTAssertThrowsError(try draft.applying(patch(draft.id, "/keep", String(repeating: "x", count: 17_000))))
        XCTAssertThrowsError(try draft.applying(["draftID": draft.id, "edits": Array(repeating: ["operation": "set", "path": "/keep", "value": "x"], count: 33)]))
        XCTAssertThrowsError(try draft.applying(["draftID": draft.id, "edits": [["operation": "set", "path": "/keep", "value": "no"], ["operation": "remove", "path": "/absent"]]]))
        XCTAssertEqual(try draft.applying(patch(draft.id, "/keep", "yes"))["keep"] as? String, "yes")
    }
    func testArrayRemovalIsExplicitAndUnknownOperationsCannotExecute() throws {
        let draft = ReadingToolDraft(tool: "knowledge_changes_propose", arguments: Data(#"{"rows":["a","b","c"],"field":true}"#.utf8))
        let result = try draft.applying(["draftID": draft.id, "edits": [["operation": "remove", "path": "/rows/2"], ["operation": "remove", "path": "/field"]]])
        XCTAssertEqual(result["rows"] as? [String], ["a", "b"]); XCTAssertNil(result["field"])
        for edit: [String: Any] in [["operation": "move", "path": "/rows/0"], ["operation": "remove", "path": "/field", "value": false], ["operation": "set", "path": "/field"], ["operation": "set", "path": "/field", "value": false, "approved": true]] {
            XCTAssertThrowsError(try draft.applying(["draftID": draft.id, "edits": [edit]]))
        }
    }
    func testSessionKeepsLocalFixesButRejectsStaleDraftAndOnlyCallsHostAfterFullValidation() async throws {
        let value = book(), host = DraftRepairHost()
        let access = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { await host.show($0, $1) })
        var q = try query(value, host: access)
        do { _ = try await q.execute(name: "component_show", arguments: invalidComposition(), maximumBytes: 16_000); XCTFail("invalid layout") } catch { XCTAssertTrue(error is ReadingCompositionError) }
        let first = try XCTUnwrap(q.rejectedToolDraft)
        do { _ = try await q.execute(name: "tool_draft_repair", arguments: patch(first.id, "/composition/parts/2/timeGroup", "main"), maximumBytes: 16_000); XCTFail("other layout error remains") } catch { XCTAssertTrue(error is ReadingCompositionError) }
        let second = try XCTUnwrap(q.rejectedToolDraft); XCTAssertNotEqual(second.id, first.id)
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: second.arguments) as? [String: Any])
        let composition = raw["composition"] as? [String: Any]; XCTAssertEqual((composition?["parts"] as? [[String: Any]])?[2]["timeGroup"] as? String, "main")
        do { _ = try await q.execute(name: "tool_draft_repair", arguments: patch(first.id, "/composition/layout/0/children/0", "map-frame"), maximumBytes: 16_000); XCTFail("stale draft") } catch { }
        let before = await host.calls.count; XCTAssertEqual(before, 0)
        let result = try await q.execute(name: "tool_draft_repair", arguments: patch(second.id, "/composition/layout/0/children/0", "map-frame"), maximumBytes: 16_000)
        XCTAssertTrue(result.contains("repairedTool")); XCTAssertEqual(q.lastEffectiveTool, "component_show"); XCTAssertNil(q.rejectedToolDraft)
        let calls = await host.calls; XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls.first?.0, "component_show")
        XCTAssertEqual(q.project?.entities.count, 0); XCTAssertTrue(q.project?.views.isEmpty == true)
        do { _ = try await q.execute(name: "tool_draft_repair", arguments: patch(second.id, "/title", "again"), maximumBytes: 16_000); XCTFail("consumed") } catch { }
        let after = await host.calls.count; XCTAssertEqual(after, 1)
    }
    func testPatchCannotTurnUnsharedSourceIntoEvidenceOrAddHostApproval() async throws {
        let value = book(), host = DraftRepairHost()
        let access = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { await host.prepare($0, $1) })
        var q = try query(value, proposals: access)
        do { _ = try await q.execute(name: "knowledge_changes_propose", arguments: invalidKnowledge(), maximumBytes: 16_000); XCTFail("missing source") } catch { XCTAssertTrue(error is ReadingSourceReferenceError) }
        let draft = try XCTUnwrap(q.rejectedToolDraft)
        do { _ = try await q.execute(name: "tool_draft_repair", arguments: patch(draft.id, "/batch/knowledge/entities/0/evidence/0/sourceRef", "u2"), maximumBytes: 16_000); XCTFail("unshared") } catch { XCTAssertTrue(error is ReadingSourceReferenceError) }
        let current = try XCTUnwrap(q.rejectedToolDraft)
        let count = await host.calls.count; XCTAssertEqual(count, 0)
        do { _ = try await q.execute(name: "tool_draft_repair", arguments: ["draftID": current.id, "tool": "book_scheme_propose", "edits": []], maximumBytes: 16_000); XCTFail("tool override") } catch { }
        let stillCurrent = try XCTUnwrap(q.rejectedToolDraft); XCTAssertEqual(stillCurrent.id, current.id)
        let result = try await q.execute(name: "tool_draft_repair", arguments: patch(current.id, "/batch/knowledge/entities/0/evidence/0/sourceRef", "u1"), maximumBytes: 16_000)
        XCTAssertTrue(result.contains("needs_confirmation")); XCTAssertNil(q.rejectedToolDraft)
        let calls = await host.calls; XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(String(decoding: calls[0].1, as: UTF8.self).contains("黄盖乘风火攻。"))
        XCTAssertFalse(String(decoding: calls[0].1, as: UTF8.self).contains("未分享的后文"))
    }
    func testRepairToolCatalogAndDraftDoNotAddWritePermissions() throws {
        let value = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: value, context: .init(unitID: "u1"))
        let names: ([[String: Any]]) -> [String] = { $0.compactMap { ($0["function"] as? [String: Any])?["name"] as? String } }
        XCTAssertFalse(names(ReadingQueryToolCatalog.schemas(snapshot: snapshot, host: nil, proposals: nil)).contains("tool_draft_repair"))
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in Data() })
        XCTAssertTrue(names(ReadingQueryToolCatalog.schemas(snapshot: snapshot, host: host, proposals: nil)).contains("tool_draft_repair"))
        var q = try query(value, host: host)
        q.rejectedToolDraft = ReadingToolDraft(tool: "knowledge_changes_propose", arguments: Data(#"{"batch":{"knowledge":{}}}"#.utf8))
        XCTAssertFalse(q.repairableToolNames.contains("knowledge_changes_propose"))
        XCTAssertThrowsError(try q.resolveToolDraft(name: "tool_draft_repair", arguments: patch(q.rejectedToolDraft!.id, "/batch/knowledge/newEntityIDs", [])))
    }
    func testEngineRepairStillWaitsForOriginalProposalReview() async throws {
        let value = book(), host = DraftRepairHost()
        let access = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { await host.prepare($0, $1) }, currentProject: { value }, awaitReview: { await host.review($0) })
        var requests = 0
        let result = try await ReadingAnswerEngine.run(question: "按本页原文整理黄盖", project: value, settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1"), scope: .page, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 4, proposalAccess: access, preferences: .init(interaction: .functional)) { messages, tools, _, _ in
            requests += 1
            if requests <= 2 {
                var name = "knowledge_changes_propose", arguments = self.invalidKnowledge()
                if requests == 2 {
                    let text = try XCTUnwrap(messages.last?["content"] as? String)
                    let receipt = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                    let offer = try XCTUnwrap(receipt["repair"] as? [String: Any]); let id = try XCTUnwrap(offer["draftID"] as? String)
                    arguments = self.patch(id, "/batch/knowledge/entities/0/evidence/0/sourceRef", "u1"); name = "tool_draft_repair"
                    XCTAssertTrue(tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == name })
                    let count = await host.calls.count; XCTAssertEqual(count, 0)
                }
                let text = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
                return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [.init(id: "call-\(requests)", type: "function", function: .init(name: name, arguments: text))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20)
            }
            let text = messages.last?["content"] as? String ?? ""
            XCTAssertTrue(text.contains("review-repaired")); XCTAssertTrue(text.contains("success")); XCTAssertFalse(text.contains("needs_confirmation"))
            return .init(message: .init(role: "assistant", content: "已整理。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
        }
        let reviews = await host.reviews, count = await host.calls.count
        XCTAssertEqual(reviews, 1); XCTAssertEqual(count, 1); XCTAssertEqual(requests, 3)
        XCTAssertFalse(result.diagnostics.awaitingReview); XCTAssertEqual(result.diagnostics.toolCalls, 2)
    }
}
