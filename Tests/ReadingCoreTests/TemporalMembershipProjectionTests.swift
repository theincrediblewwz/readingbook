import Foundation
import XCTest
@testable import ReadingCore

final class TemporalMembershipProjectionTests: XCTestCase {
    private func book() -> BookProject {
        var b = BookProject(id: "membership", title: "合成书", originalName: "source.txt", sourceHash: "source",
            units: [SourceUnit(id: "u1", order: 0, chapter: "一", page: 1, text: "刘备在此。甲地战役。"),
                    SourceUnit(id: "u2", order: 1, chapter: "二", page: 2, text: "后文人物抵达乙地。")])
        b.importedAt = Date(timeIntervalSince1970: 0)
        let early = [Evidence(unitID: "u1", quote: "刘备在此。")]
        let future = [Evidence(unitID: "u2", quote: "后文人物抵达乙地。")]
        b.entities = [KnowledgeEntity(id: "liu", typeID: "person", name: "刘备", aliases: ["玄德 e\u{301} 😀"], evidence: early),
                      KnowledgeEntity(id: "place", typeID: "place", name: "甲地", latitude: 30, longitude: 110,
                                      evidence: [Evidence(unitID: "u1", quote: "甲地战役。")]),
                      KnowledgeEntity(id: "future", typeID: "person", name: "后文人物", evidence: future)]
        b.events = [KnowledgeEvent(id: "early", name: "相遇", participantIDs: ["liu"], evidence: early),
                    KnowledgeEvent(id: "late", name: "后文事件", participantIDs: ["future"], evidence: future)]
        b.documents = [DocumentRecord(id: "note", title: "早期笔记", linkedIDs: ["future"], evidence: early),
                       DocumentRecord(id: "later-note", title: "后文笔记", evidence: future)]
        b.nodes = [CanvasNode(id: "n1", targetID: "liu"), CanvasNode(id: "n2", targetID: "place"), CanvasNode(id: "n3", targetID: "future")]
        return b
    }
    private func canonical(_ b: BookProject, _ boundary: KnowledgeReadBoundary, entities: Bool) throws -> Set<String> {
        Set(try TemporalKnowledgeRuntime.objects(in: b, boundary: boundary).filter { !entities || $0.kind == .entity }.map(\.id))
    }
    private func errorKey(_ action: () throws -> Set<String>) -> String? {
        do { _ = try action(); return nil }
        catch EncodingError.invalidValue(let value, let context) {
            return "\(value)|\(context.codingPath.map(\.stringValue))|\(context.debugDescription)"
        } catch { return String(reflecting: error) }
    }
    func testEntityMembershipMatchesCompleteAdapterAcrossBoundaries() throws {
        let b = book()
        for boundary in [KnowledgeReadBoundary.all, .init(allowedUnitIDs: ["u1"]), .init(allowedUnitIDs: ["u2"]), .init(allowedUnitIDs: [])] {
            XCTAssertEqual(try TemporalKnowledgeRuntime.entityIDs(in: b, boundary: boundary), try canonical(b, boundary, entities: true))
        }
    }
    func testObjectMembershipMatchesCompleteAdapterAcrossBoundaries() throws {
        let b = book()
        for boundary in [KnowledgeReadBoundary.all, .init(allowedUnitIDs: ["u1"]), .init(allowedUnitIDs: ["u2"]), .init(allowedUnitIDs: [])] {
            XCTAssertEqual(try TemporalKnowledgeRuntime.objectIDs(in: b, boundary: boundary), try canonical(b, boundary, entities: false))
        }
    }
    func testVisibleNonFiniteCoordinatesKeepOriginalErrorAndFirstFailure() {
        for value in [Double.nan, .infinity, -.infinity] {
            for latitude in [true, false] {
                var b = book()
                if latitude { b.entities[0].latitude = value } else { b.entities[0].longitude = value }
                b.entities[1].latitude = .infinity
                let expected = errorKey { try canonical(b, .all, entities: true) }
                XCTAssertNotNil(expected)
                XCTAssertEqual(errorKey { try TemporalKnowledgeRuntime.entityIDs(in: b, boundary: .all) }, expected)
                XCTAssertEqual(errorKey { try TemporalKnowledgeRuntime.objectIDs(in: b, boundary: .all) }, expected)
            }
        }
    }
    func testHiddenNonFiniteCoordinatesDoNotInvalidateVisibleMembers() throws {
        var b = book(); b.entities[2].latitude = .nan; b.entities[2].longitude = .infinity
        let boundary = KnowledgeReadBoundary(allowedUnitIDs: ["u1"])
        XCTAssertEqual(try TemporalKnowledgeRuntime.entityIDs(in: b, boundary: boundary), ["liu", "place"])
        XCTAssertEqual(try TemporalKnowledgeRuntime.objectIDs(in: b, boundary: boundary), try canonical(b, boundary, entities: false))
    }
    func testMissingAndMixedEvidenceKeepOriginalAdmission() throws {
        var b = book(); b.entities[0].evidence = []; b.entities[1].evidence.append(Evidence(unitID: "u2", quote: "后文"))
        b.events[0].evidence = []; b.documents[0].evidence.append(Evidence(unitID: "unknown", quote: "未知出处"))
        let boundary = KnowledgeReadBoundary(allowedUnitIDs: ["u1"])
        XCTAssertTrue(try TemporalKnowledgeRuntime.objectIDs(in: b, boundary: boundary).isEmpty)
        XCTAssertEqual(try TemporalKnowledgeRuntime.objectIDs(in: b, boundary: .all), try canonical(b, .all, entities: false))
    }
    func testSameIDEditsAndEvidenceChangesAreReadImmediately() throws {
        var b = book(); let boundary = KnowledgeReadBoundary(allowedUnitIDs: ["u1"])
        XCTAssertTrue(try TemporalKnowledgeRuntime.entityIDs(in: b, boundary: boundary).contains("liu"))
        b.entities[0].name = "已修改"; b.entities[0].summary = "新内容"; b.entities[0].evidence.append(Evidence(unitID: "u2", quote: "后文"))
        XCTAssertFalse(try TemporalKnowledgeRuntime.entityIDs(in: b, boundary: boundary).contains("liu"))
        b.entities.removeAll { $0.id == "place" }; b.events[0].evidence = [Evidence(unitID: "u2", quote: "后文")]
        XCTAssertEqual(try TemporalKnowledgeRuntime.objectIDs(in: b, boundary: boundary), try canonical(b, boundary, entities: false))
    }
    func testBookAndSourceSwitchNeverReusePreviousMembership() throws {
        let first = book(); var second = first; second.id = "other-book"; second.sourceHash = "other-source"
        second.entities = [KnowledgeEntity(id: "replacement", typeID: "person", name: "另一书的人物")]; second.events = []; second.documents = []
        XCTAssertTrue(try TemporalKnowledgeRuntime.entityIDs(in: first, boundary: .all).contains("liu"))
        XCTAssertEqual(try TemporalKnowledgeRuntime.objectIDs(in: second, boundary: .all), ["replacement"])
        XCTAssertEqual(try TemporalKnowledgeRuntime.objectIDs(in: first, boundary: .all), try canonical(first, .all, entities: false))
    }
    func testDocumentTrashAndRestoreKeepCatalogueMembership() throws {
        var b = book(); b.documents[0].trashedAt = Date(timeIntervalSince1970: 1)
        XCTAssertFalse(try TemporalKnowledgeRuntime.objectIDs(in: b, boundary: .all).contains("note"))
        XCTAssertEqual(try TemporalKnowledgeRuntime.objectIDs(in: b, boundary: .all), try canonical(b, .all, entities: false))
        b.documents[0].trashedAt = nil
        XCTAssertTrue(try TemporalKnowledgeRuntime.objectIDs(in: b, boundary: .all).contains("note"))
    }
    func testDuplicateAndCrossKindIDsKeepSetAndSourceOrder() throws {
        var b = book(); b.entities[2].id = "liu"; b.events[0].id = "liu"; b.documents[0].id = "liu"
        let boundary = KnowledgeReadBoundary(allowedUnitIDs: ["u1"])
        let old = try canonical(b, boundary, entities: true), new = try TemporalKnowledgeRuntime.entityIDs(in: b, boundary: boundary)
        XCTAssertEqual(new, old)
        XCTAssertEqual(b.entities.filter { new.contains($0.id) }.map(\.name), b.entities.filter { old.contains($0.id) }.map(\.name))
        XCTAssertEqual(try TemporalKnowledgeRuntime.objectIDs(in: b, boundary: boundary), try canonical(b, boundary, entities: false))
    }
    func testMembershipDoesNotChangeFullContentVersionsOrProjectBytes() throws {
        var b = book(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(b), objects = try TemporalKnowledgeRuntime.objects(in: b, boundary: .all)
        _ = try TemporalKnowledgeRuntime.entityIDs(in: b, boundary: .all); _ = try TemporalKnowledgeRuntime.objectIDs(in: b, boundary: .all)
        XCTAssertEqual(try encoder.encode(b), before)
        XCTAssertEqual(try encoder.encode(TemporalKnowledgeRuntime.objects(in: b, boundary: .all)), try encoder.encode(objects))
        XCTAssertTrue(objects.allSatisfy { !$0.version.isEmpty })
        b.entities[0].name = "新名字"
        XCTAssertNotEqual(try TemporalKnowledgeRuntime.object(id: "liu", in: b, boundary: .all)?.version, objects.first?.version)
    }
    func testUnencodedDocumentMetadataAndFiniteCoordinatesKeepOldBehavior() throws {
        var b = book(); b.documents[0].createdAt = Date(timeIntervalSince1970: .nan); b.documents[0].updatedAt = Date(timeIntervalSince1970: .infinity)
        b.entities[1].latitude = 999; b.entities[1].longitude = -999
        XCTAssertEqual(try TemporalKnowledgeRuntime.entityIDs(in: b, boundary: .all), try canonical(b, .all, entities: true))
        XCTAssertEqual(try TemporalKnowledgeRuntime.objectIDs(in: b, boundary: .all), try canonical(b, .all, entities: false))
    }
    func testExactSelectionKeepsWorkspaceAndProposalScope() async throws {
        let b = book(), context = ReadingContext(unitID: "u1", selectedText: "刘备在此。", page: 1)
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .selection, in: b, context: context)
        let workspace = ReadingWorkspaceSnapshot(bookID: b.id, sourceHash: b.sourceHash, rendererID: "map", selectedObjectIDs: ["liu", "place", "future"],
            visibleObjects: .init(rendererID: "map", objectIDs: ["liu", "place", "future"], nodeIDs: ["n1", "n2", "n3"]), selectedNodeIDs: ["n1", "n2", "n3"])
        let access = ReadingHostToolAccess(viewActions: ["view_focus"], performViewAction: { _, _ in Data(#"{"status":"success"}"#.utf8) }, readWorkspace: { workspace })
        var session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: b, hostTools: access)
        for name in ["workspace_context_get", "visible_objects_list"] {
            let response = try await session.execute(name: name, arguments: [:], maximumBytes: 4000)
            XCTAssertTrue(response.contains("liu")); XCTAssertFalse(response.contains("place")); XCTAssertFalse(response.contains("future")); XCTAssertFalse(response.contains("n2"))
        }
        XCTAssertThrowsError(try session.validateProposal(name: "graph_changes_propose", data: Data(#"{"batch":{"graph":{"moves":[{"nodeID":"n3","x":1,"y":2}]}}}"#.utf8)))
        var rejected = false
        do { _ = try await session.execute(name: "view_focus", arguments: ["nodeID": "n2"], maximumBytes: 4000) } catch { rejected = true }
        XCTAssertTrue(rejected)
    }
}
