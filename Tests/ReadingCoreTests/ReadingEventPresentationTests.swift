import Foundation
import XCTest
@testable import ReadingCore

final class ReadingEventPresentationTests: XCTestCase {
    private func fixture() throws -> BookProject {
        let names = ["火攻", "登岸", "追击", "伏兵", "截击", "义释", "南郡", "结局"]
        let units = names.enumerated().map { SourceUnit(id: "u\($0.offset)", order: 50 + $0.offset, chapter: "战役", page: 51 + $0.offset,
            text: "战役\($0.element)，甲地乙地。") }
        var b = BookProject(title: "完整阶段", originalName: "fixture.txt", sourceHash: "saved-source", units: units)
        PluginEngine.seed(&b)
        let proofs = units.map { Evidence(unitID: $0.id, quote: $0.text) }
        b.entities = [.init(id: "a", typeID: "place", name: "甲地", latitude: 30, longitude: 110, evidence: [proofs[0]]),
                      .init(id: "b", typeID: "place", name: "乙地", latitude: 31, longitude: 111, evidence: [proofs[0]])]
        b.events = [.init(id: "parent", name: "战役", evidence: [proofs[7]])] + (1...7).map { phase -> KnowledgeEvent in
            .init(id: "phase\(phase)", name: names[phase-1], placeIDs: ["a"], evidence: phase == 1 ? Array(proofs.prefix(2)) : [proofs[phase-1]])
        }
        b.relations = [.init(id: "action", fromID: "a", toID: "b", label: "登岸", evidence: [proofs[1]])]
        let anchors = try units.map { try ReadingExperienceRuntime.createAnchor(sourceHash: b.sourceHash, unitID: $0.id, quote: $0.text, in: b) }
        let metadata = (1...7).map { (phase: Int) -> EventTemporalMetadata in
            .init(eventID: "phase\(phase)", kind: phase == 1 ? "fire" : "event", parentEventID: "parent", phaseOrder: phase,
                  sourceAnchorIDs: phase == 1 ? Array(anchors.prefix(2).map(\.id)) : [anchors[phase-1].id], assertion: .explicit)
        }
        b.temporalKnowledge = .init(anchors: anchors, eventMetadata: metadata, relationMetadata: [
            .init(id: "action-meta", relationID: "action", validity: .init(), sourceAnchorIDs: [anchors[1].id],
                  assertion: .explicit, spatial: .init(kind: "march", eventID: "phase1"))])
        return b
    }
    private func json(_ s: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any] }
    private func session(_ b: BookProject, host: ReadingHostToolAccess? = nil) throws -> ReadingQuerySession {
        .init(snapshot: try .freeze(scope: .book, in: b), history: [], loader: nil, providedDocuments: [:], project: b, hostTools: host)
    }
    private func workspace(_ b: BookProject, complete: Bool = true, state: ReadingWorkspaceObservationStatus = .ready) -> ReadingWorkspaceSnapshot {
        .init(bookID: b.id, sourceHash: b.sourceHash, rendererID: "saved-map", selectedObjectIDs: ["phase1"],
              visibleObjects: .init(rendererID: "saved-map", objectIDs: ["phase1"]),
              mapViewports: [.init(partID: "map", latitude: 30, longitude: 110, latitudeDelta: 3, longitudeDelta: 3,
                                   objectIDs: ["phase1"], visibleRouteIDs: complete ? ["action"] : [], projectedRouteIDs: complete ? ["action"] : [])],
              timeWindows: [.init(groupID: "story", axis: "narrative-domain:source-order", from: 50, to: complete ? 51 : 50, current: 50)], observationStatus: state)
    }
    private func host(_ feed: EventPresentationFeed) -> ReadingHostToolAccess {
        .init(viewActions: ["view_show_event"], performViewAction: { name, data in try await feed.apply(name, data) },
              readWorkspace: { await feed.read() }, readWorkspaceAfterOpening: { _ in await feed.read() })
    }
    func testParentLookupReturnsOnlyOrderedChildrenAndNoSourcePermissions() async throws {
        let b = try fixture(); var s = try session(b)
        let result = try json(try await s.execute(name: "events_query", arguments: ["parentEventID": "parent", "limit": 20], maximumBytes: 20_000))
        let rows = try XCTUnwrap(result["items"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { ($0["object"] as? [String: Any])?["id"] as? String }, (1...7).map { "phase\($0)" })
        XCTAssertEqual(rows.count, 7); XCTAssertFalse(result["nextOffset"] is Int)
        XCTAssertEqual(s.sourceReferences.count, 0); XCTAssertTrue(s.sourceExcerpts.isEmpty)
        let empty = try json(try await s.execute(name: "events_query", arguments: ["parentEventID": "absent"], maximumBytes: 8000))
        XCTAssertEqual((empty["items"] as? [[String: Any]])?.count, 0)
    }
    func testHiddenParentCannotBeRecoveredByChildQuery() async throws {
        let b = try fixture(), snap = try ReadingQuerySnapshot.freeze(scope: .page, in: b, context: .init(unitID: "u0", page: 51))
        var s = ReadingQuerySession(snapshot: snap, history: [], loader: nil, providedDocuments: [:], project: b)
        let result = try await s.execute(name: "events_query", arguments: ["parentEventID": "parent"], maximumBytes: 8000)
        XCTAssertEqual((try json(result)["items"] as? [[String: Any]])?.count, 0)
        XCTAssertFalse(result.contains("parent")); XCTAssertEqual(s.sourceReferences.count, 0)
        for bad: Any in [true, 1, " "] {
            do { _ = try await s.execute(name: "events_query", arguments: ["parentEventID": bad], maximumBytes: 8000); XCTFail("invalid parent") } catch {}
        }
    }
    func testPlanUsesCompleteOwnProofAndSharedActionWithoutChangingKnowledge() throws {
        let b = try fixture(), snap = try ReadingQuerySnapshot.freeze(scope: .book, in: b)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(b), plan = try ReadingEventPresentationPlan.resolve(eventID: "phase1", in: b, snapshot: snap)
        XCTAssertEqual(plan.window.from, 50); XCTAssertEqual(plan.window.to, 51); XCTAssertEqual(plan.window.cursor, 50)
        XCTAssertEqual(plan.knownRouteIDs, ["action"]); XCTAssertEqual(plan.sourceUnitIDs, ["u0", "u1"])
        XCTAssertEqual(try encoder.encode(b), before)
        XCTAssertEqual(ReadingEventPresentationPlan.sourceWindow(.init(narrativeStart: 50, narrativeEnd: 51, narrativeDomain: "source-order")), plan.window)
        XCTAssertNil(ReadingEventPresentationPlan.sourceWindow(.init(start: .init(year: 208))))
    }
    func testPlanCannotExpandScopeOrReuseChangedPublication() throws {
        let b = try fixture(), page = try ReadingQuerySnapshot.freeze(scope: .page, in: b, context: .init(unitID: "u0", page: 51))
        XCTAssertThrowsError(try ReadingEventPresentationPlan.resolve(eventID: "phase1", in: b, snapshot: page))
        let snap = try ReadingQuerySnapshot.freeze(scope: .book, in: b)
        var changed = b; changed.sourceHash = "new-source"
        XCTAssertThrowsError(try ReadingEventPresentationPlan.resolve(eventID: "phase1", in: changed, snapshot: snap))
        XCTAssertThrowsError(try ReadingEventPresentationPlan.resolve(eventID: "a", in: b, snapshot: snap))
        changed = b; changed.temporalKnowledge?.eventMetadata[0].extent = .init(precision: .narrative, narrativeStart: 50, narrativeEnd: 99, narrativeDomain: "source-order")
        XCTAssertThrowsError(try ReadingEventPresentationPlan.resolve(eventID: "phase1", in: changed, snapshot: snap))
    }
    func testSettledActualReceiptConfirmsAllGoalPartsWithoutAnotherRead() async throws {
        let b = try fixture(), feed = EventPresentationFeed(workspace(b)); var s = try session(b, host: host(feed))
        let result = try json(try await s.execute(name: "view_show_event", arguments: ["eventID": "phase1"], maximumBytes: 12_000))
        XCTAssertEqual(result["complete"] as? Bool, true); XCTAssertEqual(result["observed"] as? Bool, true)
        XCTAssertEqual((result["actualView"] as? [String: Any])?["status"] as? String, "success")
        XCTAssertEqual((result["missing"] as? [String])?.count, 0)
        XCTAssertEqual((result["goal"] as? [String: Any])?["to"] as? Int, 51)
        let calls = await feed.calls; XCTAssertEqual(calls.count, 1)
        let args = try JSONSerialization.jsonObject(with: calls[0]) as! [String: Any]
        XCTAssertEqual(Set(args.keys), ["eventID", "expectedVersion"])
        XCTAssertEqual(args["expectedVersion"] as? String, try ReadingEventPresentationPlan.resolve(eventID: "phase1", in: b, snapshot: s.snapshot).version)
        XCTAssertTrue(s.sourceExcerpts.isEmpty); XCTAssertTrue(s.sourceReferences.isEmpty)
        XCTAssertNil(try s.presentationRepairFeedback())
    }
    func testValidPointFilterIsPartialAndCarriesTargetedRepair() async throws {
        let b = try fixture(), feed = EventPresentationFeed(workspace(b, complete: false)); var s = try session(b, host: host(feed))
        let result = try json(try await s.execute(name: "view_show_event", arguments: ["eventID": "phase1"], maximumBytes: 12_000))
        XCTAssertEqual(result["ok"] as? Bool, false); XCTAssertEqual(result["applied"] as? Bool, true)
        XCTAssertEqual(result["complete"] as? Bool, false); XCTAssertEqual(result["status"] as? String, "partial")
        let missing = try XCTUnwrap(result["missing"] as? [String])
        XCTAssertTrue(missing.contains("complete_source_window")); XCTAssertTrue(missing.contains("known_actions_visible"))
        XCTAssertEqual((result["repair"] as? [String: Any])?["attemptsRemaining"] as? Int, 2)
        XCTAssertTrue(try s.presentationRepairFeedback()?.contains("只修正缺口") == true)
        let closing = s.closingHostReceiptSummaries()
        XCTAssertEqual(closing.last?["complete"] as? Bool, false); XCTAssertNotNil(closing.last?["goal"])
    }
    func testPendingObscuredAndWrongBookCannotClaimCompletion() async throws {
        let b = try fixture()
        for state in [ReadingWorkspaceObservationStatus.pending, .obscured, .failed, .unsupported] {
            let feed = EventPresentationFeed(workspace(b, state: state)); var s = try session(b, host: host(feed))
            let result = try json(try await s.execute(name: "view_show_event", arguments: ["eventID": "phase1"], maximumBytes: 12_000))
            XCTAssertEqual(result["complete"] as? Bool, false); XCTAssertEqual(result["observed"] as? Bool, false)
        }
        var wrong = workspace(b); wrong.bookID = "other-book"
        let feed = EventPresentationFeed(wrong); var s = try session(b, host: host(feed))
        let result = try json(try await s.execute(name: "view_show_event", arguments: ["eventID": "phase1"], maximumBytes: 12_000))
        XCTAssertEqual(result["complete"] as? Bool, false); XCTAssertNil(s.workspace)
    }
    func testRetryLimitBudgetAndArgumentValidationNeverCauseExtraHostActions() async throws {
        let b = try fixture(), feed = EventPresentationFeed(workspace(b, complete: false)); var s = try session(b, host: host(feed))
        let low = try json(try await s.execute(name: "view_show_event", arguments: ["eventID": "phase1"], maximumBytes: 4000))
        XCTAssertEqual(low["budgetLimited"] as? Bool, true)
        for args: [String: Any] in [["eventID": "phase1", "from": 50], ["eventID": "phase1", "expectedVersion": "model-value"], ["eventID": ""]] {
            do { _ = try await s.execute(name: "view_show_event", arguments: args, maximumBytes: 12_000); XCTFail("model cannot set host version/window") } catch {}
        }
        for _ in 0..<3 { _ = try await s.execute(name: "view_show_event", arguments: ["eventID": "phase1"], maximumBytes: 12_000) }
        let stopped = try json(try await s.execute(name: "view_show_event", arguments: ["eventID": "phase1"], maximumBytes: 12_000))
        XCTAssertEqual(stopped["status"] as? String, "retry_limit")
        let count = await feed.calls.count; XCTAssertEqual(count, 3); XCTAssertNil(try s.presentationRepairFeedback())
        XCTAssertNotNil(s.presentationIncompleteNotice()); XCTAssertEqual(s.hostReceipts.count, 4)
    }
    func testSelectionOrRouteVisibilityEachRemainSeparateRequirements() throws {
        let b = try fixture(), plan = try ReadingEventPresentationPlan.resolve(eventID: "phase1", in: b, snapshot: .freeze(scope: .book, in: b))
        var value = workspace(b); value.selectedObjectIDs = []
        XCTAssertEqual(plan.missing(in: value), ["event_selection"])
        value = workspace(b); value.mapViewports?[0].visibleRouteIDs = []
        XCTAssertEqual(plan.missing(in: value), ["known_actions_visible"])
        value = workspace(b); value.mapViewports?[0].objectIDs = []
        XCTAssertEqual(plan.missing(in: value), ["event_visible"])
    }
    func testReviewInvalidatesOldGoalRetryStateAndObservation() async throws {
        let b = try fixture(), snapshot = try ReadingQuerySnapshot.freeze(scope: .book, in: b)
        var fresh = b; fresh.events[1].summary = "读者修正的说明"
        let updated = fresh
        let access = ReadingProposalToolAccess(proposalTools: [], prepare: { _, _ in Data() }, currentProject: { updated })
        var s = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: b, proposalAccess: access)
        s.pendingEventPresentation = try ReadingEventPresentationPlan.resolve(eventID: "phase1", in: b, snapshot: snapshot)
        s.eventPresentationFailures["phase1"] = 2; s.workspace = workspace(b)
        try await s.refreshReviewedProject()
        XCTAssertNil(s.pendingEventPresentation); XCTAssertTrue(s.eventPresentationFailures.isEmpty); XCTAssertNil(s.workspace)
        XCTAssertEqual(s.project?.events[1].summary, "读者修正的说明")
        XCTAssertNil(try s.presentationRepairFeedback()); XCTAssertTrue(s.sourceReferences.isEmpty)
    }
    func testReadingOnlyProfileCannotInvokePresentationHost() async throws {
        let b = try fixture(), feed = EventPresentationFeed(workspace(b)); var requests = 0
        _ = try await ReadingAnswerEngine.run(question: "查看火攻", project: b,
            settings: .init(model: "offline", maxOutputTokens: 1024, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u0", page: 51), scope: .book,
            history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 4, hostTools: host(feed)) { _, _, _, _ in
                requests += 1
                if requests == 1 { return self.toolCall() }
                return .init(message: .init(role: "assistant", content: "当前没有界面操作权限。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 30)
            }
        let count = await feed.calls.count; XCTAssertEqual(count, 0); XCTAssertEqual(requests, 2)
    }
    func testEngineFeedsIncompleteGoalBackAndKeepsCorrectedAnswer() async throws {
        let b = try fixture(), feed = EventPresentationFeed(workspace(b, complete: false), corrected: workspace(b))
        var requests = 0, sawFeedback = false
        let result = try await ReadingAnswerEngine.run(question: "展示火攻并核实路线", project: b,
            settings: .init(model: "offline", maxOutputTokens: 1024, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u0", page: 51), scope: .book,
            history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 6, hostTools: host(feed), preferences: .init(interaction: .functional)) { messages, _, _, _ in
                requests += 1
                if requests == 3 { sawFeedback = messages.contains { ($0["content"] as? String)?.contains("宿主呈现核验") == true } }
                if requests == 1 || requests == 3 { return self.toolCall() }
                return .init(message: .init(role: "assistant", content: "火攻阶段展示结果以画面回执为准。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 30)
            }
        XCTAssertTrue(sawFeedback); XCTAssertEqual(requests, 4)
        XCTAssertFalse(result.message.content.contains("显示核验尚未确认"))
        let count = await feed.calls.count; XCTAssertEqual(count, 2)
    }
    func testEngineDoesNotLoopForeverWhenPresentationCannotFinish() async throws {
        let b = try fixture(), feed = EventPresentationFeed(workspace(b, complete: false)); var requests = 0
        let result = try await ReadingAnswerEngine.run(question: "展示火攻并核实路线", project: b,
            settings: .init(model: "offline", maxOutputTokens: 1024, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u0", page: 51), scope: .book,
            history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 8, hostTools: host(feed), preferences: .init(interaction: .functional)) { _, _, _, _ in
                requests += 1
                if requests == 1 { return self.toolCall() }
                return .init(message: .init(role: "assistant", content: "当前有未完成部分。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 30)
            }
        XCTAssertEqual(requests, 4); XCTAssertTrue(result.message.content.contains("显示核验尚未确认"))
        let count = await feed.calls.count; XCTAssertEqual(count, 1)
    }
    func testUnreadDirectoryCitationGetsOneChanceToReadWithinFrozenScope() async throws {
        let b = try fixture(), feed = EventPresentationFeed(workspace(b)); var requests = 0, sawFeedback = false
        let result = try await ReadingAnswerEngine.run(question: "展示火攻并引用原文", project: b,
            settings: .init(model: "offline", maxOutputTokens: 1024, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u0", page: 51), scope: .book,
            history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 6,
            hostTools: host(feed), preferences: .init(interaction: .functional)) { messages, _, _, _ in
                requests += 1
                if requests == 1 { return self.toolCall() }
                if requests == 3 {
                    sawFeedback = messages.contains { ($0["content"] as? String)?.contains("正文尚未实际读取") == true }
                    return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [
                        .init(id: "read", type: "function", function: .init(name: "source_read", arguments: #"{"id":"u0"}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 30)
                }
                return .init(message: .init(role: "assistant", content: "火攻在原文有记载。[unit:u0]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 30)
            }
        XCTAssertTrue(sawFeedback); XCTAssertEqual(requests, 4); XCTAssertTrue(result.message.content.contains("火攻在原文有记载"))
        let count = await feed.calls.count; XCTAssertEqual(count, 1)
    }
    func testUnreadCitationFeedbackIsBoundedAndDoesNotGrantAnySource() async throws {
        let b = try fixture(), feed = EventPresentationFeed(workspace(b)); var requests = 0
        do {
            _ = try await ReadingAnswerEngine.run(question: "展示火攻并引用原文", project: b,
                settings: .init(model: "offline", maxOutputTokens: 1024, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u0", page: 51), scope: .book,
                history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 6,
                hostTools: host(feed), preferences: .init(interaction: .functional)) { _, _, _, _ in
                    requests += 1
                    if requests == 1 { return self.toolCall() }
                    return .init(message: .init(role: "assistant", content: "未读取的原文。[unit:outside]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 30)
                }
            XCTFail("Unprovided source must still be rejected after one correction")
        } catch { XCTAssertTrue(error.localizedDescription.contains("引用")) }
        XCTAssertEqual(requests, 3)
        let count = await feed.calls.count; XCTAssertEqual(count, 1)
    }
    private func toolCall() -> ProviderClient.Result {
        .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [
            .init(id: UUID().uuidString, type: "function", function: .init(name: "view_show_event", arguments: #"{"eventID":"phase1"}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 30)
    }
}

private actor EventPresentationFeed {
    let initial: ReadingWorkspaceSnapshot
    let corrected: ReadingWorkspaceSnapshot?
    var calls: [Data] = []
    init(_ initial: ReadingWorkspaceSnapshot, corrected: ReadingWorkspaceSnapshot? = nil) { self.initial = initial; self.corrected = corrected }
    func apply(_ name: String, _ data: Data) throws -> Data {
        calls.append(data)
        return Data(#"{"ok":true,"status":"success","rendererID":"saved-map"}"#.utf8)
    }
    func read() -> ReadingWorkspaceSnapshot { calls.count > 1 ? corrected ?? initial : initial }
}
