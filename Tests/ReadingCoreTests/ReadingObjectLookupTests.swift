import Foundation
import XCTest
@testable import ReadingCore

final class ReadingObjectLookupTests: XCTestCase {
    private func fixture() throws -> BookProject {
        let units = [SourceUnit(id: "one", order: 1, chapter: "第一章", page: 1, text: "甲地起火，曹操退向乙地。"),
                     SourceUnit(id: "two", order: 2, chapter: "第二章", page: 2, text: "后文秘密城池与总战役。")]
        var book = BookProject(title: "对象目录", originalName: "fixture.txt", sourceHash: "object-catalog-source", units: units)
        PluginEngine.seed(&book)
        let local = Evidence(unitID: "one", quote: units[0].text), future = Evidence(unitID: "two", quote: units[1].text)
        book.entities = [.init(id: "place", typeID: "place", name: "甲地", summary: String(repeating: "地图已有记录。", count: 90), latitude: 30, longitude: 110, evidence: [local]),
                         .init(id: "person", typeID: "person", name: "曹操", summary: "本段人物", evidence: [local]),
                         .init(id: "hidden", typeID: "place", name: "秘密城池", latitude: 40, longitude: 120, evidence: [future])]
        book.events = [.init(id: "child", name: "甲地火攻", placeIDs: ["place"], participantIDs: ["person"], evidence: [local]),
                       .init(id: "parent", name: "后文总战役", evidence: [future])]
        let first = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "one", quote: units[0].text, in: book)
        book.temporalKnowledge = .init(anchors: [first], eventMetadata: [.init(eventID: "child", kind: "fire", parentEventID: "parent", phaseOrder: 1,
            sourceAnchorIDs: [first.id], assertion: .explicit)])
        return book
    }
    private func session(_ book: BookProject) throws -> ReadingQuerySession {
        ReadingQuerySession(snapshot: try .freeze(scope: .page, in: book, context: .init(unitID: "one", page: 1)),
            history: [], loader: nil, providedDocuments: [:], project: book)
    }
    private func object(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
    private func canonical(_ book: BookProject) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(book) }

    func testBatchRetainsCanonicalMetadataVersionsAndInputOrderWithoutLongEvidence() async throws {
        let book = try fixture(), before = try canonical(book)
        var query = try session(book)
        let batch = try object(await query.execute(name: "object_get", arguments: ["ids": ["child", "place", "person", "place"]], maximumBytes: 20000))
        let rows = try XCTUnwrap(batch["items"] as? [[String: Any]])
        let objects = try rows.map { try XCTUnwrap($0["object"] as? [String: Any]) }
        XCTAssertEqual(objects.compactMap { $0["id"] as? String }, ["child", "place", "person"])
        XCTAssertEqual(batch["total"] as? Int, 3); XCTAssertTrue(query.sourceExcerpts.isEmpty)
        for value in objects {
            let id = try XCTUnwrap(value["id"] as? String)
            let full = try object(await query.execute(name: "object_get", arguments: ["id": id], maximumBytes: 20000))
            let original = try XCTUnwrap(full["object"] as? [String: Any])
            for key in ["id", "name", "typeID", "version", "fields", "references", "latitude", "longitude", "temporalExtent", "sourceAnchorIDs"] {
                XCTAssertEqual(value[key] as? NSObject, original[key] as? NSObject)
            }
            XCTAssertNil(value["evidence"]); XCTAssertEqual(value["evidenceOmitted"] as? Bool, true)
            XCTAssertEqual(value["sourceUnitIDs"] as? [String], ["one"])
        }
        XCTAssertEqual(try canonical(book), before)
    }

    func testLightweightSingleIsExplicitAndFullReadStillGrantsOnlyReturnedLocalQuotes() async throws {
        let book = try fixture(); var query = try session(book)
        let light = try object(await query.execute(name: "object_get", arguments: ["id": "place", "includeEvidence": false], maximumBytes: 20000))
        let value = try XCTUnwrap(light["object"] as? [String: Any])
        XCTAssertEqual((value["summary"] as? String)?.count, 400); XCTAssertEqual(value["summaryTruncated"] as? Bool, true)
        XCTAssertNil((light["previouslySaved"] as? [String: Any])?["sources"])
        XCTAssertTrue(query.sourceExcerpts.isEmpty); XCTAssertTrue(query.sourceReferences.isEmpty)
        let full = try object(await query.execute(name: "object_get", arguments: ["id": "place", "expectedHash": value["version"]!], maximumBytes: 20000))
        let fullObject = try XCTUnwrap(full["object"] as? [String: Any])
        XCTAssertEqual(fullObject["summary"] as? String, book.entities[0].summary)
        XCTAssertEqual((fullObject["evidence"] as? [[String: Any]])?.first?["quote"] as? String, book.units[0].text)
        XCTAssertTrue(query.sourceExcerpts.allSatisfy { $0.0 == "one" && $0.1 == book.units[0].text })
        XCTAssertFalse(query.sourceExcerpts.isEmpty)
        do { _ = try await query.execute(name: "object_get", arguments: ["id": "place", "expectedHash": "stale"], maximumBytes: 20000); XCTFail("Stale object versions must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("hash")) }
    }

    func testUnavailableBatchRowsDoNotRevealExistenceOrHiddenParentAndExplicitEvidenceIsScoped() async throws {
        let book = try fixture(); var query = try session(book)
        let text = try await query.execute(name: "object_get", arguments: ["ids": ["hidden", "absent", "child"], "includeEvidence": true], maximumBytes: 20000)
        let rows = try XCTUnwrap(object(text)["items"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["status"] as? String, "unavailable"); XCTAssertEqual(rows[1]["status"] as? String, "unavailable")
        XCTAssertEqual(rows[0]["message"] as? String, rows[1]["message"] as? String)
        XCTAssertFalse(text.contains("秘密城池")); XCTAssertFalse(text.contains("后文总战役")); XCTAssertFalse(text.contains("parentEvent"))
        let child = try XCTUnwrap(rows[2]["object"] as? [String: Any]), fields = try XCTUnwrap(child["fields"] as? [String: String])
        XCTAssertEqual(fields["kind"], "fire"); XCTAssertNil(fields["phaseOrder"])
        XCTAssertEqual((child["evidence"] as? [[String: Any]])?.first?["unitID"] as? String, "one")
        XCTAssertFalse(query.sourceExcerpts.isEmpty); XCTAssertTrue(query.sourceExcerpts.allSatisfy { $0.0 == "one" })
    }

    func testMixedScopeIdentityDoesNotRegainAggregateFieldsOrCoordinatesInBatch() async throws {
        var book = try fixture()
        book.entities[1].evidence += [.init(unitID: "two", quote: book.units[1].text)]
        book.entities[1].summary = "聚合到未来的简介"; book.entities[1].properties = ["secret": "后章内容"]
        book.entities[1].latitude = 35; book.entities[1].longitude = 115
        var query = try session(book)
        let text = try await query.execute(name: "object_get", arguments: ["ids": ["person"]], maximumBytes: 12000)
        let row = try XCTUnwrap((object(text)["items"] as? [[String: Any]])?.first), value = try XCTUnwrap(row["object"] as? [String: Any])
        XCTAssertEqual(row["identityOnly"] as? Bool, true); XCTAssertEqual(value["summary"] as? String, "")
        XCTAssertNil(value["latitude"]); XCTAssertNil(value["longitude"])
        XCTAssertFalse(text.contains("后章内容")); XCTAssertFalse(text.contains("聚合到未来")); XCTAssertTrue(query.sourceExcerpts.isEmpty)
    }

    func testBatchPagingAndByteBudgetDoNotDiscardRequestedObjectsSilently() async throws {
        let book = try fixture(); var query = try session(book)
        let first = try object(await query.execute(name: "object_get", arguments: ["ids": ["place", "person", "child"], "limit": 1], maximumBytes: 20000))
        XCTAssertEqual((first["items"] as? [Any])?.count, 1); XCTAssertEqual(first["total"] as? Int, 3); XCTAssertEqual(first["nextOffset"] as? Int, 1)
        let last = try object(await query.execute(name: "object_get", arguments: ["ids": ["place", "person", "child"], "offset": 1], maximumBytes: 20000))
        XCTAssertEqual((last["items"] as? [Any])?.count, 2); XCTAssertNil(last["nextOffset"] as? Int)
        let capped = try await query.execute(name: "object_get", arguments: ["ids": ["place"]], maximumBytes: 800)
        XCTAssertLessThanOrEqual(capped.utf8.count, 800)
        let limited = try object(capped); XCTAssertEqual(limited["budgetLimited"] as? Bool, true); XCTAssertEqual((limited["items"] as? [Any])?.count, 0)
        XCTAssertTrue(query.sourceExcerpts.isEmpty)
    }

    func testInvalidBatchNeverBecomesAnUnfilteredOrFullRead() async throws {
        let book = try fixture(); var query = try session(book)
        let invalid: [[String: Any]] = [["ids": []], ["ids": [""]], ["ids": true], ["ids": [1]], ["ids": Array(repeating: "place", count: 21)],
            ["ids": ["place"], "id": "person"], ["ids": ["place"], "expectedHash": "hash"], ["ids": ["place"], "includeEvidence": 1],
            ["id": "place", "includeEvidence": "false"], ["id": "place", "offset": 0], [:]]
        for arguments in invalid {
            do { _ = try await query.execute(name: "object_get", arguments: arguments, maximumBytes: 20000); XCTFail("Invalid lookup must not default to all objects") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        XCTAssertTrue(query.sourceExcerpts.isEmpty); XCTAssertTrue(query.sourceReferences.isEmpty)
    }
}
