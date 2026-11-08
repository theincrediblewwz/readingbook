import Foundation
import XCTest
@testable import ReadingCore

private actor QueryReviewGate {
    var waiting = false
    var continuation: CheckedContinuation<Data, Error>?
    var requests: [Data] = []
    var project: BookProject
    var noteBody = "审阅前的原笔记"
    init(_ project: BookProject) { self.project = project }
    func record(_ messages: [[String: Any]]) throws -> Int {
        requests.append(try JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys])); return requests.count
    }
    func suspend() async throws -> Data {
        waiting = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func decide(_ data: Data, changedSource: Bool = false) {
        if changedSource { project.units[0].text += "已更换原文" }
        let pending = continuation; continuation = nil; pending?.resume(returning: data)
    }
    func cancel() { let pending = continuation; continuation = nil; pending?.resume(throwing: CancellationError()) }
    func current() -> BookProject { project }
    func addEntity() { project.entities.append(KnowledgeEntity(id: "new-person", typeID: "person", name: "黄盖", evidence: [.init(unitID: "u1", quote: project.units[0].text)])) }
    func changeNote() { noteBody = "审阅期间改写的笔记" }
}

final class QueryReviewContinuationTests: XCTestCase {
    private func book() throws -> BookProject {
        let text = "十一月二十日，黄盖火攻。"; var value = BookProject(title: "审阅续接合成测试", originalName: "book.txt", sourceHash: try BookImporter.sha256(Data(text.utf8)), units: [.init(id: "u1", order: 0, chapter: "第一回", page: 1, text: text)])
        PluginEngine.seed(&value); return value
    }
    private func call(_ id: String, _ name: String, _ arguments: String) -> ProviderClient.ToolCall {
        .init(id: id, type: "function", function: .init(name: name, arguments: arguments))
    }
    private func decision(_ status: String = "success", id: String = "review-one") -> Data {
        Data("{\"ok\":\(status == "success"),\"status\":\"\(status)\",\"applied\":\(status == "success"),\"proposalID\":\"\(id)\",\"idMap\":{\"person\":\"new-person\"}}".utf8)
    }
    private func wait(_ gate: QueryReviewGate) async throws {
        for _ in 0..<200 { if await gate.waiting { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Engine did not reach actual review suspension")
    }
    private func run(_ book: BookProject, gate: QueryReviewGate, siblings: Bool = false, requests: Int = 8, readNew: Bool = false) async throws -> ReadingAnswerResult {
        let access = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { _, _ in
            Data(#"{"ok":false,"status":"needs_confirmation","applied":false,"proposalID":"review-one"}"#.utf8)
        }, currentProject: { await gate.current() }, awaitReview: { _ in try await gate.suspend() })
        return try await ReadingAnswerEngine.run(question: "请把火攻整理到地图", project: book,
            settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128_000), documents: [:],
            context: .init(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false,
            documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: requests,
            proposalAccess: access, preferences: .init(interaction: .functional)) { messages, _, _, _ in
                let count = try await gate.record(messages)
                if count == 1 {
                    var calls = [self.call("proposal", "knowledge_changes_propose", #"{"batch":{"knowledge":{}}}"#)]
                    if siblings { calls.append(self.call("not-run", "source_read", #"{"id":"u1"}"#)) }
                    return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: calls, reasoning_content: nil), finishReason: "tool_calls", tokenCost: 30)
                }
                if readNew && count == 2 {
                    return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [self.call("new-read", "object_get", #"{"id":"new-person"}"#)], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 30)
                }
                return .init(message: .init(role: "assistant", content: "继续完成原问题。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 30)
            }
    }
    func testWaitResumesSameTranscriptAndDoesNotSendWhileAwaitingHuman() async throws {
        let value = try book(), gate = QueryReviewGate(value)
        let task = Task { try await self.run(value, gate: gate) }; try await wait(gate)
        let before = await gate.requests.count; XCTAssertEqual(before, 1)
        await gate.decide(decision()); let result = try await task.value
        let sent = await gate.requests; XCTAssertEqual(sent.count, 2)
        let messages = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1]) as? [[String: Any]])
        XCTAssertEqual(messages.filter { $0["content"] as? String == "请把火攻整理到地图" }.count, 1)
        XCTAssertTrue(messages.contains { $0["role"] as? String == "assistant" && $0["tool_calls"] != nil })
        let actual = try XCTUnwrap(messages.first { $0["tool_call_id"] as? String == "proposal" }?["content"] as? String)
        XCTAssertTrue(actual.contains("new-person")); XCTAssertTrue(actual.contains("success")); XCTAssertFalse(actual.contains("needs_confirmation"))
        XCTAssertEqual(result.message.content, "继续完成原问题。[unit:u1]"); XCTAssertFalse(result.diagnostics.awaitingReview)
        XCTAssertEqual(result.diagnostics.toolCalls, 1); XCTAssertEqual(result.diagnostics.sourceReadIDs, ["u1"])
    }
    func testUnexecutedSiblingGetsProtocolReceiptWithoutRereadingSource() async throws {
        let value = try book(), gate = QueryReviewGate(value)
        let task = Task { try await self.run(value, gate: gate, siblings: true) }; try await wait(gate)
        await gate.decide(decision()); let result = try await task.value; let sent = await gate.requests
        let messages = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1]) as? [[String: Any]])
        XCTAssertEqual(messages.filter { $0["role"] as? String == "tool" }.count, 2)
        XCTAssertTrue((messages.first { $0["tool_call_id"] as? String == "not-run" }?["content"] as? String)?.contains("not_executed") == true)
        XCTAssertEqual(result.diagnostics.toolCalls, 1)
    }
    func testDiscardIsReportedAsDiscardAndStillKeepsOriginalTask() async throws {
        let value = try book(), gate = QueryReviewGate(value)
        let task = Task { try await self.run(value, gate: gate) }; try await wait(gate)
        await gate.decide(decision("discarded")); let result = try await task.value; let sent = await gate.requests
        XCTAssertTrue(String(decoding: sent[1], as: UTF8.self).contains("discarded")); XCTAssertEqual(result.message.evidence.first?.unitID, "u1")
    }
    func testWrongReviewIdentityStopsWithoutSendingAgain() async throws {
        let value = try book(), gate = QueryReviewGate(value)
        let task = Task { try await self.run(value, gate: gate) }; try await wait(gate)
        await gate.decide(decision(id: "other-proposal"))
        do { _ = try await task.value; XCTFail("Wrong decision resumed") } catch { XCTAssertTrue(error is ReadingWorkflowBudgetPause) }
        let sent = await gate.requests.count; XCTAssertEqual(sent, 1)
    }
    func testSourceChangedDuringReviewStopsBeforeNextRequest() async throws {
        let value = try book(), gate = QueryReviewGate(value)
        let task = Task { try await self.run(value, gate: gate) }; try await wait(gate)
        await gate.decide(decision(), changedSource: true)
        do { _ = try await task.value; XCTFail("Stale source resumed") } catch { XCTAssertTrue(error is ReadingWorkflowBudgetPause) }
        let sent = await gate.requests.count; XCTAssertEqual(sent, 1)
    }
    func testCancelDuringReviewDoesNotLeakAnotherRequest() async throws {
        let value = try book(), gate = QueryReviewGate(value)
        let task = Task { try await self.run(value, gate: gate) }; try await wait(gate); task.cancel(); await gate.cancel()
        do { _ = try await task.value; XCTFail("Cancelled task resumed") } catch { XCTAssertTrue(error is CancellationError) }
        let sent = await gate.requests.count; XCTAssertEqual(sent, 1)
    }
    func testReviewRefreshMakesCommittedObjectsReadableWithoutRestart() async throws {
        let value = try book(), gate = QueryReviewGate(value)
        let task = Task { try await self.run(value, gate: gate, readNew: true) }; try await wait(gate)
        await gate.addEntity(); await gate.decide(decision()); let result = try await task.value; let sent = await gate.requests
        XCTAssertEqual(sent.count, 3)
        XCTAssertTrue(String(decoding: sent[2], as: UTF8.self).contains("黄盖")); XCTAssertEqual(result.diagnostics.toolCalls, 2)
    }
    func testReviewDoesNotResetTheRequestLimit() async throws {
        let value = try book(), gate = QueryReviewGate(value)
        let task = Task { try await self.run(value, gate: gate, requests: 2) }; try await wait(gate)
        await gate.decide(decision()); _ = try await task.value
        let sent = await gate.requests.count; XCTAssertEqual(sent, 2)
    }
    func testReviewCannotReuseAStaleDocumentBodyFromBeforeThePause() async throws {
        var value = try book(); value.documents = [DocumentRecord(id: "note", title: "读者笔记")]
        let gate = QueryReviewGate(value), snapshot = try ReadingQuerySnapshot.freeze(scope: .notes, in: value, documentIDs: ["note"])
        let access = ReadingProposalToolAccess(proposalTools: [], prepare: { _, _ in Data() }, currentProject: { await gate.current() })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: { _ in await gate.noteBody }, providedDocuments: [:], project: value, proposalAccess: access)
        let original = try await session.execute(name: "document_read", arguments: ["id": "note"], maximumBytes: 4000)
        XCTAssertTrue(original.contains("审阅前的原笔记"))
        await gate.changeNote(); try await session.refreshReviewedProject()
        do {
            _ = try await session.execute(name: "document_read", arguments: ["id": "note"], maximumBytes: 4000)
            XCTFail("Changed note reused a stale cached body")
        } catch { XCTAssertTrue(error.localizedDescription.contains("笔记在本次问答中发生变化")) }
    }
}
