import Foundation
import XCTest
@testable import ReadingCore

private actor PreflightWriteHost {
    var received = [Data]()
    func submit(_ data: Data) -> Data {
        received.append(data)
        return Data(#"{"ok":true,"status":"success","applied":true}"#.utf8)
    }
}

private actor LaterValidationHost {
    var calls = 0
    func prepare(_ data: Data) throws -> Data {
        calls += 1
        if calls == 1 { throw ReadingError.invalid("时态知识：此路线还需要核对。") }
        return Data(#"{"ok":false,"status":"needs_confirmation","proposalID":"later-validation"}"#.utf8)
    }
}

final class ReadingProposalPreflightTests: XCTestCase {
    private func fixture() -> BookProject {
        var value = BookProject(title: "表单合成回归", originalName: "book.txt", sourceHash: "preflight", units: [
            .init(id: "u1", order: 611, chapter: "赤壁", page: 612, text: "黃蓋乘風縱火，曹操敗退。"),
            .init(id: "u2", order: 900, chapter: "未读", page: 901, text: "范围外的秘密正文。")])
        value.types = [.init(id: "person", name: "人物", icon: "person", fields: []),
                       .init(id: "place", name: "地点", icon: "map", fields: [])]
        return value
    }
    private func payload() -> [String: Any] {
        let evidence: [[String: Any]] = [["unitID": "u1", "quote": "黃蓋乘風縱火，曹操敗退。"]]
        return ["batch": ["knowledge": ["newEntityIDs": ["cao", "chibi"], "newEventIDs": ["fire"],
            "entities": [["id": "cao", "typeID": "person", "name": "曹操", "summary": "败退", "properties": [:], "aliases": [], "evidence": evidence],
                         ["id": "chibi", "typeID": "place", "name": "赤壁", "summary": "战场", "properties": [:], "aliases": [], "evidence": evidence, "latitude": 113.6, "longitude": 29.7]],
            "events": [["id": "fire", "name": "火攻", "summary": "乘风纵火", "dateText": "原文先后", "placeIDs": ["chibi"], "participantIDs": ["cao"], "evidence": evidence]],
            "anchors": [["clientID": "a", "unitID": "u1", "quote": "黃蓋乘風縱火，曹操敗退。"]],
            "eventMetadata": [["eventID": "fire", "kind": "火攻", "sourceAnchorIDs": ["a"], "assertion": "explicit", "explanation": "原文", "extent": [
                "sourceText": "", "precision": "narrative", "uncertainty": "unknown", "kind": "point", "assertion": "explicit", "explanation": "原文先后"]]]]]]
    }
    private func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func query(_ book: BookProject, access: ReadingProposalToolAccess? = nil) throws -> ReadingQuerySession {
        var result = ReadingQuerySession(snapshot: try .freeze(scope: .page, in: book, context: .init(unitID: "u1")), history: [], loader: nil,
            providedDocuments: [:], project: book, proposalAccess: access)
        result.sourceExcerpts = [("u1", book.units[0].text)]
        return result
    }
    func testOnePreflightReportsIndependentCoordinateAndTimeErrorsWithoutSaving() throws {
        let book = fixture(), q = try query(book), raw = try data(payload())
        do { _ = try q.preflightProposal(name: "knowledge_changes_propose", data: raw); XCTFail("Must reject") }
        catch let error as ReadingProposalPreflightError {
            let paths = error.issues.compactMap { $0["path"] as? String }
            XCTAssertTrue(paths.contains("$.batch.knowledge.entities[1].latitude"))
            XCTAssertTrue(paths.contains("$.batch.knowledge.eventMetadata[0].extent"))
            XCTAssertTrue(String(describing: error.issues).contains("-90"))
            XCTAssertFalse(String(describing: error.issues).contains("范围外的秘密正文"))
        }
        XCTAssertTrue(q.project!.entities.isEmpty); XCTAssertTrue(q.project!.events.isEmpty)
        XCTAssertEqual(try data(payload()), raw)
    }
    func testMalformedTimeRowDoesNotPreventOtherRowsOrCoordinatesBeingReported() throws {
        var raw = payload(), batch = raw["batch"] as! [String: Any], knowledge = batch["knowledge"] as! [String: Any]
        var rows = knowledge["eventMetadata"] as! [[String: Any]]
        var second = rows[0]; second["extent"] = ["precision": "not-a-precision"]
        rows.append(second); knowledge["eventMetadata"] = rows; batch["knowledge"] = knowledge; raw["batch"] = batch
        do { _ = try query(fixture()).preflightProposal(name: "knowledge_changes_propose", data: data(raw)); XCTFail("Must reject") }
        catch let error as ReadingProposalPreflightError {
            let paths = error.issues.compactMap { $0["path"] as? String }
            XCTAssertTrue(paths.contains("$.batch.knowledge.entities[1].latitude"))
            XCTAssertTrue(paths.contains("$.batch.knowledge.eventMetadata[0].extent"))
            XCTAssertTrue(paths.contains("$.batch.knowledge.eventMetadata[1].extent"))
        }
    }
    func testExplicitSplitKeepsCompleteHeldOriginalAndDoesNotInventCoordinates() throws {
        var raw = payload(); let before = try data(raw)
        raw["saveCoreOnly"] = true
        let result = try ReadingProposalPreparation.prepare(name: "knowledge_changes_propose", arguments: data(raw))
        let held = try XCTUnwrap(result.deferred)
        XCTAssertEqual(held.originalArguments, before)
        XCTAssertEqual(held.heldCounts, ["coordinates": 1, "eventMetadata": 1])
        let core = try XCTUnwrap(ReadingProposalTools.decode(name: "knowledge_changes_propose", arguments: result.arguments).knowledge)
        XCTAssertNil(core.entities?[1].latitude); XCTAssertNil(core.entities?[1].longitude)
        XCTAssertNil(core.eventMetadata); XCTAssertEqual(core.entities?.count, 2); XCTAssertEqual(core.events?.count, 1); XCTAssertEqual(core.anchors?.count, 1)
        XCTAssertNoThrow(try query(fixture()).preflightProposal(name: "knowledge_changes_propose", data: result.arguments))
    }
    func testSplitIsExplicitBooleanAndCannotStripCrossGroupDependenciesOrUnknownFields() throws {
        var raw = payload()
        XCTAssertNil(try ReadingProposalPreparation.prepare(name: "knowledge_changes_propose", arguments: data(raw)).deferred)
        for flag: Any in [1, "true", NSNull()] {
            raw["saveCoreOnly"] = flag
            XCTAssertThrowsError(try ReadingProposalPreparation.prepare(name: "knowledge_changes_propose", arguments: data(raw)))
        }
        raw["saveCoreOnly"] = false
        XCTAssertNil(try ReadingProposalPreparation.prepare(name: "knowledge_changes_propose", arguments: data(raw)).deferred)
        raw["saveCoreOnly"] = true
        var batch = raw["batch"] as! [String: Any]; batch["documents"] = ["create": []]; raw["batch"] = batch
        XCTAssertThrowsError(try ReadingProposalPreparation.prepare(name: "knowledge_changes_propose", arguments: data(raw)))
        XCTAssertThrowsError(try ReadingProposalPreparation.prepare(name: "graph_changes_propose", arguments: data(raw)))
        batch.removeValue(forKey: "documents"); var k = batch["knowledge"] as! [String: Any]; k["unrecognizedFacts"] = ["must not disappear"]
        batch["knowledge"] = k; raw["batch"] = batch
        XCTAssertThrowsError(try ReadingProposalPreparation.prepare(name: "knowledge_changes_propose", arguments: data(raw)))
    }
    func testDraftLocalSplitOnlyCallsWriteHostAfterCoreSourceAndRangeValidation() async throws {
        let host = PreflightWriteHost(), access = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { _, value in await host.submit(value) })
        var q = try query(fixture(), access: access)
        do { _ = try await q.execute(name: "knowledge_changes_propose", arguments: payload(), maximumBytes: 16000); XCTFail("Must reject") } catch { XCTAssertTrue(error is ReadingProposalPreflightError) }
        let before = await host.received.count; XCTAssertEqual(before, 0)
        let draft = try XCTUnwrap(q.rejectedToolDraft)
        let result = try await q.execute(name: "tool_draft_repair", arguments: ["draftID": draft.id, "edits": [["operation": "set", "path": "/saveCoreOnly", "value": true]]], maximumBytes: 16000)
        XCTAssertTrue(result.contains("repairedTool")); XCTAssertNil(q.rejectedToolDraft)
        let received = await host.received; XCTAssertEqual(received.count, 1)
        let submitted = try XCTUnwrap(JSONSerialization.jsonObject(with: received[0]) as? [String: Any])
        XCTAssertEqual(submitted["saveCoreOnly"] as? Bool, true)
        let submittedBatch = submitted["batch"] as? [String: Any]
        let submittedKnowledge = submittedBatch?["knowledge"] as? [String: Any]
        XCTAssertEqual((submittedKnowledge?["entities"] as? [[String: Any]])?[1]["latitude"] as? Double, 113.6)
        // Held original reaches the actual host; it must not be discarded by
        // the local preflight or confused with an already committed fact.
    }
    func testActualTransactionPersistsHeldDraftAcrossReloadAndUndoPreservesOriginalBook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var book = fixture(); book.units = [book.units[0]]; book.units[0].order = 0
        let source = root.appendingPathComponent("book.txt"); try Data(book.units[0].text.utf8).write(to: source)
        book.sourceHash = try BookImporter.sha256(Data(contentsOf: source))
        let library = root.appendingPathComponent("library"), repo = LibraryRepository(rootURL: library)
        _ = try await repo.create(book, sourceURL: source)
        let grant = try await repo.issueChangeGrant(bookID: book.id, permissions: [.knowledge], allowedUnitIDs: ["u1"], requiresReceipts: false, reason: "本次整理")
        var raw = payload(); raw["saveCoreOnly"] = true
        let prepared = try ReadingProposalPreparation.prepare(name: "knowledge_changes_propose", arguments: data(raw))
        var changes = try ReadingProposalTools.decode(name: "knowledge_changes_propose", arguments: prepared.arguments); changes.deferredKnowledge = prepared.deferred
        let proposal = try await repo.prepareChanges(changes, grant: grant)
        let before = try await repo.loadAll(); XCTAssertTrue(before[0].entities.isEmpty)
        XCTAssertTrue(proposal.summary.contains { $0.contains("待补") })
        let saved = try await repo.commitChanges(proposalID: proposal.id, grant: grant)
        XCTAssertEqual(saved.project.entities.count, 2); XCTAssertEqual(saved.project.events.count, 1)
        XCTAssertTrue(saved.project.entities.allSatisfy { $0.latitude == nil && $0.longitude == nil })
        XCTAssertTrue(saved.project.temporalKnowledge?.eventMetadata.isEmpty ?? true)
        XCTAssertEqual(saved.project.units, book.units)
        let reloaded = try await LibraryRepository(rootURL: library).loadAll()
        let held = try XCTUnwrap(reloaded[0].controlledChanges?.receipts.last?.deferredKnowledge)
        XCTAssertEqual(held.originalArguments, prepared.deferred?.originalArguments)
        XCTAssertEqual(held.heldCounts, ["coordinates": 1, "eventMetadata": 1])
        let undone = try await repo.undoChanges(bookID: book.id, operationID: proposal.operationID)
        XCTAssertTrue(undone.project.entities.isEmpty); XCTAssertTrue(undone.project.events.isEmpty)
        XCTAssertEqual(undone.project.units, book.units)
        XCTAssertNotNil(undone.project.controlledChanges?.receipts.last?.deferredKnowledge)
    }
    func testSplitDoesNotManufactureSourcesOrHostBookkeepingInModelPayload() throws {
        var raw = payload(); raw["saveCoreOnly"] = true
        var batch = raw["batch"] as! [String: Any], k = batch["knowledge"] as! [String: Any]
        var entities = k["entities"] as! [[String: Any]]
        entities[0]["evidence"] = [["unitID": "u2", "quote": "范围外的秘密正文。"]]
        k["entities"] = entities; batch["knowledge"] = k; raw["batch"] = batch
        let prepared = try ReadingProposalPreparation.prepare(name: "knowledge_changes_propose", arguments: data(raw))
        XCTAssertThrowsError(try query(fixture()).preflightProposal(name: "knowledge_changes_propose", data: prepared.arguments))
        batch["deferredKnowledge"] = ["approved": true]; raw["batch"] = batch
        XCTAssertThrowsError(try ReadingProposalPreparation.prepare(name: "knowledge_changes_propose", arguments: data(raw)))
    }

    func testMoreThanFourNonliteralQuotesAreReportedInOneFeedback() throws {
        var raw = payload(), batch = raw["batch"] as! [String: Any], k = batch["knowledge"] as! [String: Any]
        var entities = k["entities"] as! [[String: Any]]
        for index in entities.indices {
            entities[index].removeValue(forKey: "latitude"); entities[index].removeValue(forKey: "longitude")
            entities[index]["evidence"] = (0..<3).map { ["unitID": "u1", "quote": "手写的错误引文\(index)-\($0)"] }
        }
        k["entities"] = entities; k.removeValue(forKey: "eventMetadata"); batch["knowledge"] = k; raw["batch"] = batch
        do { _ = try query(fixture()).preflightProposal(name: "knowledge_changes_propose", data: data(raw)); XCTFail("Quotes must be literal") }
        catch let error as ReadingProposalEvidenceError {
            XCTAssertEqual(error.issues.count, 6)
            XCTAssertTrue(error.issues.contains { $0["path"] == "$.batch.knowledge.entities[1].evidence[2]" })
        }
    }

    func testMissingNarrativePositionUsesOneIssuePerRowSoLaterRowsAreNotHidden() throws {
        var raw = payload(), batch = raw["batch"] as! [String: Any], k = batch["knowledge"] as! [String: Any]
        let row = (k["eventMetadata"] as! [[String: Any]])[0]
        k["eventMetadata"] = Array(repeating: row, count: 12); batch["knowledge"] = k; raw["batch"] = batch
        let issues = try query(fixture()).temporalFormIssues(in: data(raw))
        XCTAssertEqual(issues.count, 12)
        XCTAssertTrue(issues.contains { $0["path"] as? String == "$.batch.knowledge.eventMetadata[11].extent" })
    }

    func testInvalidSourceReferenceDoesNotHideIndependentCoordinatesAndTime() throws {
        var raw = payload(), batch = raw["batch"] as! [String: Any], k = batch["knowledge"] as! [String: Any]
        var entities = k["entities"] as! [[String: Any]]
        entities[0]["evidence"] = [["sourceRef": "not-provided"]]
        k["entities"] = entities; batch["knowledge"] = k; raw["batch"] = batch
        do { _ = try query(fixture()).preflightSourceReferences(in: data(raw)); XCTFail("Reference is not granted") }
        catch let error as ReadingProposalPreflightError {
            let paths = error.issues.compactMap { $0["path"] as? String }
            XCTAssertTrue(paths.contains("$.batch.knowledge.entities[0].evidence[0]"))
            XCTAssertTrue(paths.contains("$.batch.knowledge.entities[1].latitude"))
            XCTAssertTrue(paths.contains("$.batch.knowledge.eventMetadata[0].extent"))
            XCTAssertFalse(String(describing: error.issues).contains("范围外的秘密正文"))
        }
    }

    func testUnresolvedTransportSpanDoesNotCreateFalseMissingManualPosition() throws {
        var raw = payload(), batch = raw["batch"] as! [String: Any], k = batch["knowledge"] as! [String: Any]
        var rows = k["eventMetadata"] as! [[String: Any]], time = rows[0]["extent"] as! [String: Any]
        time["sourceSpan"] = ["startAnchorID": "a"]; rows[0]["extent"] = time
        k["eventMetadata"] = rows; batch["knowledge"] = k; raw["batch"] = batch
        XCTAssertTrue(try query(fixture()).temporalFormIssues(in: data(raw)).isEmpty)
        let normalized = try query(fixture()).resolveTemporalSourceSpans(in: data(raw))
        let normalizedBatch = try ReadingProposalTools.decode(name: "knowledge_changes_propose", arguments: normalized)
        XCTAssertEqual(normalizedBatch.knowledge?.eventMetadata?[0].extent?.narrativeStart, 611)
    }

    func testRouteErrorsAreLocatedAlongsideTimeCoordinatesAndEvidence() throws {
        var raw = payload(), batch = raw["batch"] as! [String: Any], k = batch["knowledge"] as! [String: Any]
        let evidence: [[String: Any]] = [["unitID": "u1", "quote": "手写的错误引文"]]
        k["newRelationIDs"] = ["route"]
        k["relations"] = [["id": "route", "fromID": "cao", "toID": "chibi", "label": "火攻", "evidence": evidence]]
        k["relationMetadata"] = [["id": "route-metadata", "relationID": "route", "validity": ["precision": "unknown", "uncertainty": "unknown", "kind": "point", "sourceText": "", "assertion": "unknown"],
            "spatial": ["kind": "火攻", "viaPlaceIDs": ["chibi"], "actorIDs": [], "eventID": "fire"], "assertion": "explicit", "sourceAnchorIDs": ["a"], "explanation": "原文"]]
        k["presences"] = [["id": "bad-presence", "entityID": "chibi", "placeID": "cao", "extent": ["precision": "unknown", "uncertainty": "unknown", "kind": "point", "sourceText": "", "assertion": "unknown"],
            "action": "不得把人物写成地点", "sourceAnchorIDs": ["a"], "assertion": "explicit", "explanation": "合成错误"]]
        batch["knowledge"] = k; raw["batch"] = batch
        do { _ = try query(fixture()).preflightProposal(name: "knowledge_changes_propose", data: data(raw)); XCTFail("Invalid route") }
        catch let error as ReadingProposalPreflightError {
            let paths = error.issues.compactMap { $0["path"] as? String }
            XCTAssertTrue(paths.contains("$.batch.knowledge.entities[1].latitude"))
            XCTAssertTrue(paths.contains("$.batch.knowledge.eventMetadata[0].extent"))
            XCTAssertTrue(paths.contains("$.batch.knowledge.relations[0].evidence[0]"))
            XCTAssertTrue(paths.contains("$.batch.knowledge.presences[0].placeID"))
            XCTAssertTrue(error.issues.contains { $0["relationID"] as? String == "route" && $0["invalidPlaceIDs"] as? [String] == ["cao"] })
            XCTAssertTrue(error.issues.contains { $0["repeatedPlaceID"] as? String == "chibi" })
        }
    }

    func testRouteFeedbackDoesNotRevealEndpointsOutsideFrozenPage() throws {
        var value = fixture()
        value.entities = [.init(id: "secret", typeID: "place", name: "后文秘密城市", summary: "秘密", properties: [:], evidence: [.init(unitID: "u2", quote: value.units[1].text)])]
        value.relations = [.init(id: "future-route", fromID: "secret", toID: "secret", label: "秘密关系", evidence: [.init(unitID: "u2", quote: value.units[1].text)])]
        var raw = payload(), batch = raw["batch"] as! [String: Any], k = batch["knowledge"] as! [String: Any]
        k["relationMetadata"] = [["relationID": "future-route", "spatial": ["kind": "行军"]]]
        batch["knowledge"] = k; raw["batch"] = batch
        do { _ = try query(value).preflightProposal(name: "knowledge_changes_propose", data: data(raw)); XCTFail("Out of scope") }
        catch let error as ReadingProposalPreflightError {
            XCTAssertTrue(error.issues.contains { $0["path"] as? String == "$.batch.knowledge.relationMetadata[0].relationID" })
            XCTAssertFalse(String(describing: error.issues).contains("后文秘密城市"))
            XCTAssertFalse(String(describing: error.issues).contains("secret"))
        }
    }

    func testLaterHostValidationRetainsEarlierEvidenceRepairAndRechecksBeforeReview() async throws {
        let host = LaterValidationHost()
        let access = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { _, data in try await host.prepare(data) })
        var q = try query(fixture(), access: access)
        var raw = payload(), batch = raw["batch"] as! [String: Any], k = batch["knowledge"] as! [String: Any]
        var entities = k["entities"] as! [[String: Any]]
        entities[1].removeValue(forKey: "latitude"); entities[1].removeValue(forKey: "longitude")
        entities[0]["evidence"] = [["unitID": "u1", "quote": "错误引文"]]
        k["entities"] = entities; k.removeValue(forKey: "eventMetadata"); batch["knowledge"] = k; raw["batch"] = batch
        do { _ = try await q.execute(name: "knowledge_changes_propose", arguments: raw, maximumBytes: 16_000); XCTFail("Invalid quote") } catch { }
        let first = try XCTUnwrap(q.rejectedToolDraft)
        let patch: [String: Any] = ["draftID": first.id, "edits": [["operation": "set", "path": "/batch/knowledge/entities/0/evidence/0/quote", "value": fixture().units[0].text]]]
        do { _ = try await q.execute(name: "tool_draft_repair", arguments: patch, maximumBytes: 16_000); XCTFail("Later validation") } catch { XCTAssertTrue(error is ReadingError) }
        let second = try XCTUnwrap(q.rejectedToolDraft)
        XCTAssertNotEqual(first.id, second.id)
        let repaired = try XCTUnwrap(try JSONSerialization.jsonObject(with: second.arguments) as? [String: Any])
        let repairedEntities = ((repaired["batch"] as? [String: Any])?["knowledge"] as? [String: Any])?["entities"] as? [[String: Any]]
        XCTAssertEqual((repairedEntities?[0]["evidence"] as? [[String: Any]])?[0]["quote"] as? String, fixture().units[0].text)
        let result = try await q.execute(name: "tool_draft_repair", arguments: ["draftID": second.id, "edits": [["operation": "set", "path": "/batch/knowledge/entities/0/summary", "value": "已修正"]]], maximumBytes: 16_000)
        XCTAssertTrue(result.contains("needs_confirmation")); XCTAssertNil(q.rejectedToolDraft)
        let calls = await host.calls; XCTAssertEqual(calls, 2)
        XCTAssertTrue(q.project!.entities.isEmpty)
    }

    func testDeniedAndConflictingHostResultsDoNotBecomeEditableValidationDrafts() throws {
        let access = ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose"], prepare: { _, _ in Data() })
        var q = try query(fixture(), access: access)
        for error in [ControlledChangeError.denied("无权限"), .conflict("书库已改变"), .unsupported("不支持")] {
            q.retainRejectedDraft(name: "knowledge_changes_propose", arguments: payload(), error: error)
            XCTAssertNil(q.rejectedToolDraft); XCTAssertNil(q.lastRepairOffer)
        }
        q.retainRejectedDraft(name: "knowledge_changes_propose", arguments: payload(), error: ControlledChangeError.invalid("字段错误"))
        XCTAssertNotNil(q.rejectedToolDraft)
    }

    func testSharedEventLocationsRemainUsableWithGeneratedCustomTypeIDsWithoutTemplate() throws {
        var value = fixture()
        value.units[0].text = "曹操在港口一、港口二遭火攻。"
        value.types.append(.init(id: "w-custom-location", name: "地点", icon: "map", fields: []))
        let evidence = [Evidence(unitID: "u1", quote: value.units[0].text)]
        value.entities = [.init(id: "cao", typeID: "person", name: "曹操", evidence: evidence),
                          .init(id: "port1", typeID: "w-custom-location", name: "港口一", latitude: 30, longitude: 113, evidence: evidence),
                          .init(id: "port2", typeID: "w-custom-location", name: "港口二", latitude: 30.5, longitude: 113.5, evidence: evidence)]
        value.events = [.init(id: "fire", name: "火攻", placeIDs: ["port1", "port2"], participantIDs: ["cao"], evidence: evidence)]
        value.relations = [.init(id: "route", fromID: "port1", toID: "port2", label: "火攻", evidence: evidence)]
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: value.sourceHash, unitID: "u1", quote: value.units[0].text, in: value)
        let time = TemporalExtent(sourceText: "", precision: .unknown, uncertainty: .unknown, assertion: .unknown)
        value.temporalKnowledge = .init(anchors: [anchor], relationMetadata: [
            .init(id: "spatial", relationID: "route", validity: time, sourceAnchorIDs: [anchor.id], assertion: .explicit,
                spatial: .init(kind: "火攻", actorIDs: ["cao"], eventID: "fire"))])
        XCTAssertNil(value.temporalKnowledge?.profile)
        XCTAssertNoThrow(try TemporalKnowledgeRuntime.validateStoredState(in: value))
        XCTAssertEqual(try SpatialKnowledgeRuntime.routes(in: value).map(\.relationID), ["route"])
        let definition = CompositionDefinition(sources: [.init(id: "places", collection: .objects, scope: .book), .init(id: "actions", collection: .relations, scope: .book)],
            parts: [.init(id: "map", primitive: .map, sourceID: "places", routeSourceID: "actions")],
            layout: [.init(id: "root", kind: .part, partID: "map")], rootID: "root")
        let projection = try CompositionRuntime.project(definition, in: value)
        XCTAssertEqual(Set(projection["places"]?.mapPoints.filter { $0.kind == "entityLocation" }.map(\.targetID) ?? []), ["port1", "port2"])
        XCTAssertEqual(projection["actions"]?.mapRoutes.map(\.relationID), ["route"])
        value.relations[0].toID = "cao"
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateStoredState(in: value))
        value.relations[0].toID = "port2"
        value.temporalKnowledge!.relationMetadata[0].spatial!.viaPlaceIDs = ["port2"]
        XCTAssertThrowsError(try TemporalKnowledgeRuntime.validateStoredState(in: value))
    }

    func testFutureEventCannotAssignVisibleEntityAPlaceRoleAcrossBoundary() throws {
        var value = fixture()
        value.types.append(.init(id: "custom", name: "自定义", icon: "square", fields: []))
        value.entities = [.init(id: "visible", typeID: "custom", name: "已读对象", latitude: 30, longitude: 113, evidence: [.init(unitID: "u1", quote: value.units[0].text)])]
        value.events = [.init(id: "future", name: "未读地点角色", placeIDs: ["visible"], evidence: [.init(unitID: "u2", quote: value.units[1].text)])]
        XCTAssertTrue(TemporalKnowledgeRuntime.locationEntityIDs(in: value).contains("visible"))
        XCTAssertFalse(TemporalKnowledgeRuntime.locationEntityIDs(in: value, boundary: .init(allowedUnitIDs: ["u1"])).contains("visible"))
    }

    func testCitedSourceOrderEnrichmentRequiresReviewAndUndoRestoresOldPoint() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "曹操在甲地撤退。\n曹操到乙地遇伏击。"
        try Data(text.utf8).write(to: source)
        var book = BookProject(title: "原文范围补齐", originalName: "source.txt", sourceHash: try BookImporter.sha256(Data(text.utf8)), units: [
            .init(id: "early", order: 0, chapter: "一", page: 1, text: "曹操在甲地撤退。"),
            .init(id: "late", order: 1, chapter: "一", page: 2, text: "曹操到乙地遇伏击。")])
        let first = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "early", quote: book.units[0].text, in: book)
        let last = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "late", quote: book.units[1].text, in: book)
        book.events = [.init(id: "retreat", name: "撤退与伏击", evidence: [.init(unitID: "late", quote: book.units[1].text)])]
        let oldTime = TemporalExtent(precision: .narrative, uncertainty: .unknown, narrativeStart: 1, narrativeEnd: 1, assertion: .explicit, explanation: "先读到的原文位置", narrativeDomain: "source-order")
        book.temporalKnowledge = .init(anchors: [first, last], eventMetadata: [.init(eventID: "retreat", kind: "阶段", extent: oldTime, sourceAnchorIDs: [last.id], assertion: .explicit)])
        let repo = LibraryRepository(rootURL: folder.appendingPathComponent("library"))
        book = try await repo.create(book, sourceURL: source)
        let grant = try await repo.issueChangeGrant(bookID: book.id, permissions: [.knowledge], allowedUnitIDs: ["early", "late"], requiresReceipts: false, reason: "补齐有来源的叙事范围")
        let expanded = TemporalExtent(precision: .narrative, uncertainty: .unknown, kind: .interval, narrativeStart: 0, narrativeEnd: 1, assertion: .explicit, explanation: "补入先前的撤退段落", narrativeDomain: "source-order")
        let changes = ControlledChangeBatch(knowledge: .init(eventMetadata: [.init(eventID: "retreat", kind: "阶段", extent: expanded, sourceAnchorIDs: [first.id, last.id], assertion: .explicit)]))
        let proposal = try await repo.prepareChanges(changes, grant: grant)
        XCTAssertTrue(proposal.requiresConfirmation)
        let unchanged = try await repo.loadAll(); XCTAssertEqual(unchanged[0].temporalKnowledge?.eventMetadata[0].extent, oldTime)
        do { _ = try await repo.commitChanges(proposalID: proposal.id, grant: grant); XCTFail("Must review changed existing interval") }
        catch { XCTAssertTrue(error is ControlledChangeError) }
        let approval = try await repo.approveChanges(proposalID: proposal.id, digest: proposal.digest)
        let saved = try await repo.commitChanges(proposalID: proposal.id, grant: grant, approval: approval)
        XCTAssertEqual(saved.project.temporalKnowledge?.eventMetadata[0].extent?.narrativeStart, 0)
        XCTAssertEqual(saved.project.temporalKnowledge?.eventMetadata[0].extent?.narrativeEnd, 1)
        XCTAssertTrue(saved.project.temporalKnowledge!.eventMetadata[0].extent!.explanation!.contains("先读到的原文位置"))
        XCTAssertEqual(saved.project.units, book.units)
        let undone = try await repo.undoChanges(bookID: book.id, operationID: proposal.operationID)
        XCTAssertEqual(undone.project.temporalKnowledge?.eventMetadata[0].extent, oldTime)
        XCTAssertEqual(undone.project.units, book.units)
        for bad in [TemporalExtent(precision: .narrative, uncertainty: .unknown, narrativeStart: 0, narrativeEnd: 0, assertion: .explicit, narrativeDomain: "source-order"),
                    TemporalExtent(precision: .narrative, uncertainty: .unknown, narrativeStart: 0, narrativeEnd: 1, assertion: .explicit, narrativeDomain: "another-scale"),
                    TemporalExtent(sourceText: "208年", start: .init(year: 208), precision: .year, assertion: .explicit)] {
            let currentGrant = try await repo.issueChangeGrant(bookID: book.id, permissions: [.knowledge], allowedUnitIDs: ["early", "late"], requiresReceipts: false, reason: "拒绝矛盾范围")
            do { _ = try await repo.prepareChanges(.init(knowledge: .init(eventMetadata: [.init(eventID: "retreat", kind: "阶段", extent: bad, sourceAnchorIDs: [first.id, last.id], assertion: .explicit)])), grant: currentGrant); XCTFail("Conflicting range") }
            catch { XCTAssertTrue(error is ControlledChangeError) }
        }
    }
}
