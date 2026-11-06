import Foundation
import XCTest
@testable import ReadingCore

final class ComponentPresentationTruthTests: XCTestCase {
    private func book() -> BookProject {
        var value = BookProject(title: "真实视图", originalName: "book.txt", sourceHash: "fixture", units: [
            .init(id: "u1", order: 0, chapter: "已读", page: 1, text: "刘备与关羽同行。"),
            .init(id: "u2", order: 1, chapter: "未读", page: 2, text: "后文秘密人物。")])
        PluginEngine.seed(&value)
        value.entities = [.init(id: "liu", typeID: "person", name: "刘备", evidence: [.init(unitID: "u1", quote: "刘备与关羽同行。")]),
            .init(id: "future", typeID: "person", name: "后文秘密人物", evidence: [.init(unitID: "u2", quote: "后文秘密人物。")])]
        value.documents = [.init(id: "private", title: "未分享的秘密笔记")]
        value.nodes = [.init(id: "n-liu", targetID: "liu"), .init(id: "n-private", targetID: "private")]
        return value
    }
    private func receipt(_ status: String = "success", confirmation: Bool = true) -> Data {
        try! JSONSerialization.data(withJSONObject: ["ok": status == "success", "status": status, "opened": status == "success",
            "analysisCreated": false, "viewID": "relations", "rendererID": "builtin.relations", "componentTitle": "关系图谱", "confirmationOnly": confirmation])
    }
    private func json(_ text: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any] }
    private func call(_ name: String, _ args: String, id: String = "open") -> ProviderClient.Result {
        .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [.init(id: id, type: "function", function: .init(name: name, arguments: args))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20)
    }
    func testConfirmationFlagIsOptionalAndStrictBoolean() throws {
        XCTAssertNil(try ReadingComponentRequest.decode(Data(#"{"componentID":"relations"}"#.utf8)).confirmationOnly)
        XCTAssertEqual(try ReadingComponentRequest.decode(Data(#"{"componentID":"relations","confirmationOnly":true}"#.utf8)).confirmationOnly, true)
        for flag in ["1", "\"true\"", "{}"] { XCTAssertThrowsError(try ReadingComponentRequest.decode(Data("{\"componentID\":\"relations\",\"confirmationOnly\":\(flag)}".utf8))) }
    }
    func testFreshReceiptIncludesOnlyVisibleAuthorizedItemsAndNoHostPath() async throws {
        let book = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u1", page: 1))
        let fresh = ReadingWorkspaceSnapshot(bookID: book.id, sourceHash: book.sourceHash, rendererID: "relations",
            visibleObjects: .init(rendererID: "relations", objectIDs: ["liu", "future", "private"], nodeIDs: ["n-liu", "n-private"], contextID: "/private/host/path", connections: [
                .init(fromID: "liu", toID: "liu", label: "实际界面线"), .init(fromID: "liu", toID: "private", label: "不得发送的私有连线")]))
        let returned = receipt()
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in returned }, readWorkspace: { fresh })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book, hostTools: host)
        let result = try await session.execute(name: "component_show", arguments: ["componentID": "relations", "confirmationOnly": true], maximumBytes: 16_000)
        let actual = try XCTUnwrap(try json(result)["actualView"] as? [String: Any])
        XCTAssertEqual(actual["status"] as? String, "success"); XCTAssertEqual(actual["partial"] as? Bool, true)
        XCTAssertTrue(result.contains("刘备") && result.contains("n-liu"))
        XCTAssertTrue(result.contains("实际界面线")); XCTAssertFalse(result.contains("不得发送的私有连线"))
        XCTAssertFalse(result.contains("future") || result.contains("n-private") || result.contains("秘密") || result.contains("/private/host/path"))
        XCTAssertEqual(session.componentPresentationConfirmation(), "已打开“关系图谱”。原有资料保留，这次没有重新生成分析。")
    }
    func testUnavailableOrOtherRouteDoesNotClaimAnEmptyCanvas() async throws {
        let book = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u1", page: 1)), returned = receipt()
        for route in ["reader", "relations"] {
            let workspace = ReadingWorkspaceSnapshot(bookID: book.id, sourceHash: book.sourceHash, rendererID: route)
            let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in returned }, readWorkspace: { workspace })
            var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book, hostTools: host)
            let result = try await session.execute(name: "component_show", arguments: ["componentID": "relations"], maximumBytes: 16_000)
            let actual = try XCTUnwrap(try json(result)["actualView"] as? [String: Any])
            XCTAssertEqual(actual["status"] as? String, "unsupported"); XCTAssertNil(actual["items"])
            XCTAssertEqual(try json(result)["opened"] as? Bool, true)
        }
    }
    func testFailedOptionalSnapshotKeepsOpenedReceiptButCancellationPropagates() async throws {
        let book = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u1", page: 1)), returned = receipt()
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in returned }, readWorkspace: { throw ReadingError.invalid("unavailable") })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book, hostTools: host)
        let result = try await session.execute(name: "component_show", arguments: ["componentID": "relations"], maximumBytes: 16_000)
        XCTAssertEqual(try json(result)["opened"] as? Bool, true)
        let cancelledHost = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in returned }, readWorkspace: { throw CancellationError() })
        var cancelledSession = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book, hostTools: cancelledHost)
        do { _ = try await cancelledSession.execute(name: "component_show", arguments: ["componentID": "relations"], maximumBytes: 16_000); XCTFail("cancel") } catch is CancellationError {} catch { XCTFail("wrong error") }
    }
    func testBusyAndFailedReceiptsNeverGetSuccessConfirmation() async throws {
        let book = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u1", page: 1))
        for status in ["busy", "failed", "needs_confirmation", "unsupported"] {
            let returned = receipt(status)
            let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in returned })
            var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book, hostTools: host)
            _ = try await session.execute(name: "component_show", arguments: ["componentID": "relations"], maximumBytes: 16_000)
            XCTAssertNil(session.componentPresentationConfirmation())
        }
    }
    func testPureOpenCompletesWithoutAnotherModelRequest() async throws {
        let book = book(), returned = receipt()
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in returned })
        var calls = 0
        let result = try await ReadingAnswerEngine.run(question: "只打开已有关系图", project: book, settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 3, hostTools: host) { _, _, _, _ in
            calls += 1
            return self.call("component_show", #"{"componentID":"relations","confirmationOnly":true}"#)
        }
        XCTAssertEqual(calls, 1); XCTAssertEqual(result.message.content, "已打开“关系图谱”。原有资料保留，这次没有重新生成分析。")
    }
    func testContentQuestionStillReadsAndCitesSource() async throws {
        let book = book(), returned = receipt(confirmation: false)
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in returned })
        var calls = 0
        let result = try await ReadingAnswerEngine.run(question: "打开图并解释刘备和谁同行", project: book, settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 5, hostTools: host) { _, _, _, _ in
            calls += 1
            if calls == 1 { return self.call("component_show", #"{"componentID":"relations","confirmationOnly":false}"#) }
            if calls == 2 { return self.call("source_read", #"{"id":"u1"}"#, id: "read") }
            return .init(message: .init(role: "assistant", content: "刘备与关羽同行。[unit:u1]", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
        }
        XCTAssertEqual(calls, 3); XCTAssertTrue(result.message.content.contains("刘备与关羽同行")); XCTAssertFalse(result.message.content.contains("未引用"))
    }
    func testLegacyVisibleSnapshotDecodesWithoutOwnership() throws {
        let old = Data(#"{"rendererID":"map","objectIDs":[],"nodeIDs":[],"partial":true,"description":""}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ReadingVisibleObjectsSnapshot.self, from: old).contextID)
    }
    func testWritingTaskCannotBeShortCircuitedByPresentationFlag() async throws {
        let book = book(), returned = receipt()
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in returned })
        let proposals = ReadingProposalToolAccess(proposalTools: [], prepare: { _, _ in throw ReadingError.invalid("unused") })
        var calls = 0
        _ = try await ReadingAnswerEngine.run(question: "打开图后继续核查补充", project: book, settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 3, hostTools: host, proposalAccess: proposals, preferences: .init(interaction: .functional)) { _, _, _, _ in
            calls += 1
            if calls == 1 { return self.call("component_show", #"{"componentID":"relations","confirmationOnly":true}"#) }
            return .init(message: .init(role: "assistant", content: "已打开视图，尚未补充分析。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
        }
        XCTAssertEqual(calls, 2)
    }
    func testMixedToolBatchCannotBeShortCircuited() async throws {
        let book = book(), returned = receipt()
        let host = ReadingHostToolAccess(viewActions: ["component_show", "components_list"], performViewAction: { _, _ in returned })
        var calls = 0
        _ = try await ReadingAnswerEngine.run(question: "打开图并列出可用组件", project: book, settings: .init(model: "offline", maxOutputTokens: 512, contextWindowTokens: 128_000), documents: [:], context: .init(unitID: "u1", page: 1), scope: .page, history: [], memory: nil, memoryEnabled: false, documentIDs: nil, loader: nil, operationLimit: 128_000, remainingRequests: 3, hostTools: host) { _, _, _, _ in
            calls += 1
            if calls == 1 {
                return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [
                    .init(id: "list", type: "function", function: .init(name: "components_list", arguments: "{}")),
                    .init(id: "show", type: "function", function: .init(name: "component_show", arguments: #"{"componentID":"relations","confirmationOnly":true}"#))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 20)
            }
            return .init(message: .init(role: "assistant", content: "图谱已打开，可用组件以上述实际目录为准。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 20)
        }
        XCTAssertEqual(calls, 2)
    }
}
