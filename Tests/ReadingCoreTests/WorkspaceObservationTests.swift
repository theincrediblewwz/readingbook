import Foundation
import XCTest
@testable import ReadingCore

final class WorkspaceObservationTests: XCTestCase {
    private func book() -> BookProject {
        var b = BookProject(id: "observation", title: "画面状态", originalName: "book.txt", sourceHash: "source", units: [
            .init(id: "u1", order: 0, chapter: "已读", page: 1, text: "刘备在此。"),
            .init(id: "u2", order: 1, chapter: "未读", page: 2, text: "后文人物。")])
        PluginEngine.seed(&b)
        b.entities = [.init(id: "liu", typeID: "person", name: "刘备", evidence: [.init(unitID: "u1", quote: "刘备在此。")]),
            .init(id: "secret", typeID: "person", name: "后文人物", evidence: [.init(unitID: "u2", quote: "后文人物。")])]
        return b
    }
    private func workspace(_ book: BookProject, _ status: ReadingWorkspaceObservationStatus) -> ReadingWorkspaceSnapshot {
        .init(bookID: book.id, sourceHash: book.sourceHash, rendererID: "saved-map",
            visibleObjects: .init(rendererID: "saved-map", objectIDs: status == .empty ? [] : ["liu", "secret"]),
            mapViewports: status == .empty ? [] : [.init(partID: "map", latitude: 30, longitude: 110, latitudeDelta: 3, longitudeDelta: 3,
                objectIDs: ["liu", "secret"], visibleRouteIDs: [], projectedRouteIDs: [])], observationStatus: status)
    }
    private var receipt: Data { Data(#"{"ok":true,"status":"success","opened":true,"viewID":"saved-map","componentTitle":"地图","analysisCreated":false}"#.utf8) }
    private func json(_ text: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any] }
    func testOpeningUsesOneLocalSettlementCallbackInsteadOfAnExtraModelTurn() async throws {
        let b = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: b, context: .init(unitID: "u1", page: 1))
        let feed = ObservationFeed(workspace(b, .pending), workspace(b, .ready)), result = receipt
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in result },
            readWorkspace: { await feed.read() }, readWorkspaceAfterOpening: { route in await feed.settle(route) })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: b, hostTools: host)
        let text = try await session.execute(name: "component_show", arguments: ["viewID": "saved-map"], maximumBytes: 12000)
        let actual = try XCTUnwrap(try json(text)["actualView"] as? [String: Any])
        XCTAssertEqual(actual["status"] as? String, "success")
        XCTAssertTrue(text.contains("刘备")); XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("后文人物"))
        let counts = await feed.counts(); XCTAssertEqual(counts.reads, 0); XCTAssertEqual(counts.settles, 1); XCTAssertEqual(counts.route, "saved-map")
    }
    func testPendingFailedAndObscuredNeverExposeStaleVisibilityOrPretendEmpty() async throws {
        let b = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: b, context: .init(unitID: "u1", page: 1)), returned = receipt
        for state in [ReadingWorkspaceObservationStatus.pending, .failed, .obscured, .unsupported] {
            let value = workspace(b, state)
            let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in returned }, readWorkspace: { value }, readWorkspaceAfterOpening: { _ in value })
            var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: b, hostTools: host)
            let result = try json(try await session.execute(name: "component_show", arguments: ["viewID": "saved-map"], maximumBytes: 12000))
            let actual = try XCTUnwrap(result["actualView"] as? [String: Any])
            XCTAssertEqual(result["opened"] as? Bool, true)
            XCTAssertEqual(actual["status"] as? String, state.rawValue); XCTAssertNil(actual["items"])
            let visible = try json(try await session.execute(name: "visible_objects_list", arguments: [:], maximumBytes: 4000))
            XCTAssertEqual(visible["status"] as? String, state.rawValue); XCTAssertEqual(visible["ok"] as? Bool, false)
            let context = try json(try await session.execute(name: "workspace_context_get", arguments: [:], maximumBytes: 8000))
            XCTAssertEqual(context["observationStatus"] as? String, state.rawValue)
            XCTAssertEqual((context["mapViewports"] as? [[String: Any]])?.count, 0)
        }
    }
    func testExplicitEmptyIsDifferentFromUnavailableAndDoesNotClaimNoBookData() async throws {
        let b = book(), value = workspace(b, .empty), returned = receipt
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: b, context: .init(unitID: "u1", page: 1))
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in returned }, readWorkspaceAfterOpening: { _ in value })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: b, hostTools: host)
        let result = try json(try await session.execute(name: "component_show", arguments: ["viewID": "saved-map"], maximumBytes: 12000))
        let actual = try XCTUnwrap(result["actualView"] as? [String: Any]); XCTAssertEqual(actual["status"] as? String, "empty")
        XCTAssertEqual((actual["items"] as? [[String: Any]])?.count, 0)
        XCTAssertTrue((actual["note"] as? String)?.contains("不代表本书") == true)
    }
    func testSettlementCancellationPropagatesWithoutReopeningOrPersistingAnything() async throws {
        let b = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: b, context: .init(unitID: "u1", page: 1)), returned = receipt
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in returned }, readWorkspaceAfterOpening: { _ in throw CancellationError() })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: b, hostTools: host)
        do { _ = try await session.execute(name: "component_show", arguments: ["viewID": "saved-map"], maximumBytes: 12000); XCTFail("cancel") }
        catch is CancellationError {} catch { XCTFail("wrong cancellation") }
        XCTAssertTrue(b.documents.isEmpty); XCTAssertTrue(b.chats.isEmpty)
    }
    func testSettledSnapshotOfAnotherBookCannotEnterReceipt() async throws {
        let b = book(), snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: b, context: .init(unitID: "u1", page: 1)), returned = receipt
        var wrong = workspace(b, .ready); wrong.bookID = "other"; let value = wrong
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in returned }, readWorkspaceAfterOpening: { _ in value })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: b, hostTools: host)
        let text = try await session.execute(name: "component_show", arguments: ["viewID": "saved-map"], maximumBytes: 12000)
        let result = try json(text), actual = try XCTUnwrap(result["actualView"] as? [String: Any])
        XCTAssertEqual(result["opened"] as? Bool, true); XCTAssertEqual(actual["status"] as? String, "unsupported")
        XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("刘备"))
    }
    func testContradictoryEmptyObservationIsRejectedRatherThanInventingNoData() async throws {
        let b = book(), returned = receipt
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: b, context: .init(unitID: "u1", page: 1))
        var mixed = workspace(b, .ready); mixed.observationStatus = .empty; let value = mixed
        let host = ReadingHostToolAccess(viewActions: ["component_show"], performViewAction: { _, _ in returned }, readWorkspace: { value }, readWorkspaceAfterOpening: { _ in value })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: b, hostTools: host)
        let text = try await session.execute(name: "component_show", arguments: ["viewID": "saved-map"], maximumBytes: 12000)
        let actual = try XCTUnwrap(try json(text)["actualView"] as? [String: Any])
        XCTAssertEqual(actual["status"] as? String, "unsupported"); XCTAssertNil(actual["items"])
        do { _ = try await session.execute(name: "workspace_context_get", arguments: [:], maximumBytes: 8000); XCTFail("不能把非空投影说成空") } catch {}
    }
    func testLegacyWorkspaceStillDecodesWithoutObservationStatus() throws {
        let value = try JSONDecoder().decode(ReadingWorkspaceSnapshot.self, from: Data(#"{"bookID":"b","sourceHash":"s","selectedObjectIDs":[],"selectedNodeIDs":[]}"#.utf8))
        XCTAssertNil(value.observationStatus)
    }
    func testExplicitWorkspaceRefreshReplacesOpeningObservationInBudgetClosing() async throws {
        let b=book(),snapshot=try ReadingQuerySnapshot.freeze(scope:.page,in:b,context:.init(unitID:"u1",page:1)),returned=receipt
        let feed=ObservationFeed(workspace(b,.pending),workspace(b,.ready))
        let host=ReadingHostToolAccess(viewActions:["component_show"],performViewAction:{_,_ in returned},
            readWorkspace:{await feed.read()},readWorkspaceAfterOpening:{_ in await feed.settle("saved-map")})
        var session=ReadingQuerySession(snapshot:snapshot,history:[],loader:nil,providedDocuments:[:],project:b,hostTools:host)
        _ = try await session.execute(name:"component_show",arguments:["viewID":"saved-map"],maximumBytes:12000)
        _ = try await session.execute(name:"workspace_context_get",arguments:[:],maximumBytes:8000)
        let receipts=session.closingHostReceiptSummaries()
        XCTAssertEqual(receipts.count,2);XCTAssertNil(receipts.first?["actualView"])
        let actual=try XCTUnwrap(receipts.last?["actualView"] as? [String:Any])
        XCTAssertEqual(actual["observationStatus"] as? String,"pending")
        XCTAssertEqual((actual["mapViewports"] as? [[String:Any]])?.count,0)
    }
}
private actor ObservationFeed {
    let before: ReadingWorkspaceSnapshot
    let after: ReadingWorkspaceSnapshot
    var reads = 0, settles = 0
    var route = ""
    init(_ before: ReadingWorkspaceSnapshot, _ after: ReadingWorkspaceSnapshot) { self.before = before; self.after = after }
    func read() -> ReadingWorkspaceSnapshot { reads += 1; return before }
    func settle(_ target: String) -> ReadingWorkspaceSnapshot { settles += 1; route = target; return after }
    func counts() -> (reads: Int, settles: Int, route: String) { (reads, settles, route) }
}
