import Foundation
import XCTest
@testable import ReadingCore

final class BattleStructureTests: XCTestCase {
    private func fixture() throws -> BookProject {
        let units = [SourceUnit(id: "u1", order: 1, chapter: "前文", page: 1, text: "208年，甲地火攻开始，曹操退向乙地。"),
                     SourceUnit(id: "u2", order: 2, chapter: "后文", page: 2, text: "后文总结全战役，丙地结局仍未读。")]
        var book = BookProject(title: "归属与范围", originalName: "fixture.txt", sourceHash: "structure-source", units: units)
        PluginEngine.seed(&book)
        let early = Evidence(unitID: "u1", quote: units[0].text), late = Evidence(unitID: "u2", quote: units[1].text)
        book.entities = [.init(id: "a", typeID: "place", name: "甲地", latitude: 30, longitude: 110, evidence: [early]),
                         .init(id: "b", typeID: "place", name: "乙地", latitude: 31, longitude: 111, evidence: [early]),
                         .init(id: "c", typeID: "person", name: "曹操", evidence: [early]),
                         .init(id: "hidden", typeID: "place", name: "丙地秘密", evidence: [late])]
        book.events = [.init(id: "child", name: "火攻", placeIDs: ["a"], participantIDs: ["c"], evidence: [early]),
                       .init(id: "parent", name: "后文全战役", evidence: [late])]
        book.relations = [.init(id: "route", fromID: "a", toID: "b", label: "撤退", evidence: [early]),
                          .init(id: "hidden-route", fromID: "b", toID: "hidden", label: "未读方向", evidence: [late])]
        let first = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: units[0].text, in: book)
        let second = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u2", quote: units[1].text, in: book)
        let extent = TemporalExtent(sourceText: "208年", calendar: "gregorian", start: .init(year: 208), precision: .year, uncertainty: .exact)
        book.temporalKnowledge = .init(anchors: [first, second], eventMetadata: [.init(eventID: "child", kind: "fire", parentEventID: "parent", phaseOrder: 1,
            extent: extent, sourceAnchorIDs: [first.id], assertion: .explicit)], relationMetadata: [.init(id: "route-time", relationID: "route", validity: extent,
            sourceAnchorIDs: [first.id], assertion: .explicit, explanation: "原文明说方向", spatial: .init(kind: "retreat", actorIDs: ["c"], eventID: "child"))])
        return book
    }
    private func session(_ book: BookProject) throws -> ReadingQuerySession {
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: book, context: .init(unitID: "u1", page: 1))
        return ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: book)
    }
    private func object(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
    private func canonical(_ book: BookProject) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(book) }

    func testHiddenParentDoesNotEraseIndependentlySourcedChildTimeOrKind() throws {
        let book = try fixture(), before = try canonical(book), boundary = KnowledgeReadBoundary(allowedUnitIDs: ["u1"])
        let child = try XCTUnwrap(TemporalKnowledgeRuntime.object(id: "child", in: book, boundary: boundary))
        XCTAssertEqual(child.fields["kind"], "fire"); XCTAssertEqual(child.temporalExtent?.start?.year, 208)
        XCTAssertNil(child.references["parentEvent"]); XCTAssertNil(child.fields["phaseOrder"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(child), as: UTF8.self).contains("后文全战役"))
        let events = try TemporalKnowledgeRuntime.events(in: book, at: .date(.init(year: 208), calendar: "gregorian"), boundary: boundary)
        XCTAssertEqual(events.map(\.object.id), ["child"]); XCTAssertEqual(events.first?.metadata?.kind, "fire")
        XCTAssertNil(events.first?.metadata?.parentEventID); XCTAssertEqual(events.first?.match, .matches)
        let all = try XCTUnwrap(TemporalKnowledgeRuntime.object(id: "child", in: book, boundary: .all))
        XCTAssertEqual(all.references["parentEvent"], ["parent"]); XCTAssertEqual(all.fields["phaseOrder"], "1")
        XCTAssertEqual(try canonical(book), before)
    }

    func testUnsharedChildMetadataStillHiddenAndScopedProjectionCannotLeakParentID() throws {
        var book = try fixture()
        let scoped = try XCTUnwrap(session(book).scopedKnowledgeProject())
        let metadata = try XCTUnwrap(scoped.temporalKnowledge?.eventMetadata.first)
        XCTAssertNil(metadata.parentEventID); XCTAssertNil(metadata.phaseOrder)
        XCTAssertEqual(metadata.kind, "fire"); XCTAssertEqual(metadata.extent?.start?.year, 208)
        let objects = try TemporalKnowledgeRuntime.objects(in: scoped, boundary: .all)
        XCTAssertFalse(objects.contains { $0.id == "parent" })
        XCTAssertTrue(objects.allSatisfy { !($0.references["parentEvent"] ?? []).contains("parent") })
        let unsharedAnchorID = book.temporalKnowledge!.anchors[1].id
        book.temporalKnowledge?.eventMetadata[0].sourceAnchorIDs = [unsharedAnchorID]
        let hidden = try XCTUnwrap(TemporalKnowledgeRuntime.object(id: "child", in: book, boundary: .init(allowedUnitIDs: ["u1"])))
        XCTAssertNil(hidden.fields["kind"]); XCTAssertEqual(hidden.temporalExtent?.precision, .unknown)
        XCTAssertNil(hidden.references["parentEvent"])
    }

    func testRelationDirectoryListsScopedActionsWithoutPerEndpointReadsOrLongQuotes() async throws {
        let book = try fixture(), before = try canonical(book)
        var value = try session(book)
        let text = try await value.execute(name: "relations_list", arguments: [:], maximumBytes: 12000), result = try object(text)
        let rows = try XCTUnwrap(result["items"] as? [[String: Any]])
        XCTAssertEqual(result["total"] as? Int, 1); XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first), relation = try XCTUnwrap(row["relation"] as? [String: Any])
        XCTAssertEqual(relation["id"] as? String, "route"); XCTAssertEqual(relation["fromName"] as? String, "甲地")
        XCTAssertEqual(relation["toName"] as? String, "乙地"); XCTAssertNil(relation["evidence"])
        XCTAssertEqual(relation["sourceUnitIDs"] as? [String], ["u1"])
        XCTAssertEqual(row["actorNames"] as? [String], ["曹操"]); XCTAssertEqual(row["eventName"] as? String, "火攻")
        XCTAssertFalse(text.contains("丙地秘密")); XCTAssertFalse(text.contains(book.units[0].text))
        XCTAssertEqual(try canonical(book), before)
        let full = try await value.execute(name: "relations_list", arguments: ["includeEvidence": true], maximumBytes: 12000)
        XCTAssertTrue(full.contains(book.units[0].text)); XCTAssertFalse(full.contains("丙地秘密"))
        let legacy = try await value.execute(name: "relations_list", arguments: ["objectID": "a"], maximumBytes: 12000)
        XCTAssertEqual(try object(full)["items"] as? NSArray, try object(legacy)["items"] as? NSArray)
    }

    func testRelationDirectoryPaginationAndInvalidFilterDoNotWidenScope() async throws {
        var book = try fixture()
        let evidence = book.relations[0].evidence
        book.relations += (0..<22).map { .init(id: "r\($0)", fromID: "a", toID: "b", label: "各自有据的关系\($0)", evidence: evidence) }
        var value = try session(book)
        let first = try object(await value.execute(name: "relations_list", arguments: ["limit": 20], maximumBytes: 32000))
        let rows = try XCTUnwrap(first["items"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 20); XCTAssertEqual(first["total"] as? Int, 23)
        let second = try object(await value.execute(name: "relations_list", arguments: ["offset": 20], maximumBytes: 32000))
        XCTAssertEqual((second["items"] as? [Any])?.count, 3); XCTAssertNil(second["nextOffset"] as? Int)
        for filter in [true, 1, NSNull(), ""] as [Any] {
            do { _ = try await value.execute(name: "relations_list", arguments: ["objectID": filter], maximumBytes: 32000); XCTFail("Invalid object filter must not turn into an all-relations read") }
            catch { XCTAssertTrue(error.localizedDescription.contains("objectID")) }
        }
    }

    func testBatchedObjectNamesReuseOneScopedReadWithoutSplittingRealNames() async throws {
        var book = try fixture()
        let englishQuote = "Jean de La Fontaine在甲地。"
        book.units[0].text += englishQuote
        book.entities.append(.init(id: "english", typeID: "person", name: "Jean de La Fontaine", evidence: [.init(unitID: "u1", quote: englishQuote)]))
        var value = try session(book)
        let batch = try object(await value.execute(name: "objects_search", arguments: ["queries": ["曹操", "Jean de La Fontaine", "曹操", "丙地秘密"]], maximumBytes: 12000))
        let rows = try XCTUnwrap(batch["items"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["id"] as? String }), ["c", "english"])
        let single = try object(await value.execute(name: "objects_search", arguments: ["query": "Jean de La Fontaine"], maximumBytes: 12000))
        XCTAssertEqual((single["items"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["english"])
        let missing = try object(await value.execute(name: "objects_search", arguments: ["queries": ["不在当前范围", "丙地秘密"]], maximumBytes: 12000))
        XCTAssertEqual(missing["total"] as? Int, 0)
        let invalid: [[String: Any]] = [["queries": []], ["queries": [""]], ["queries": true], ["queries": ["曹操"], "query": "甲地"], ["query": true]]
        for arguments in invalid {
            do { _ = try await value.execute(name: "objects_search", arguments: arguments, maximumBytes: 12000); XCTFail("Invalid batch must not fall back to the whole catalogue") }
            catch { XCTAssertTrue(error.localizedDescription.contains("quer")) }
        }
    }
}
