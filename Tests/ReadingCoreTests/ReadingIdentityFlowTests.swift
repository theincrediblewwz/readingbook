import Foundation
import XCTest
@testable import ReadingCore

final class ReadingIdentityFlowTests: XCTestCase {
    private func fixture() -> BookProject {
        let text = "周瑜、公瑾、周郎、小周瑜、张飞、曹操，在此议事。"
        var book = BookProject(id: "identity", title: "身份", originalName: "b.pdf", sourceHash: "source", units: [
            .init(id: "u1", order: 0, chapter: "一", page: 1, text: text),
            .init(id: "u2", order: 1, chapter: "二", page: 2, text: "未读秘密。")])
        PluginEngine.seed(&book)
        let e = [Evidence(unitID: "u1", quote: text)]
        book.entities = [
            .init(id: "aa-summary", typeID: "person", name: "曹操", summary: "曾与周瑜交战", evidence: e),
            .init(id: "bb-partial", typeID: "person", name: "小周瑜", evidence: e),
            .init(id: "cc-alias", typeID: "person", name: "周郎", aliases: ["周瑜"], evidence: e),
            .init(id: "zz-exact", typeID: "person", name: "周瑜", aliases: ["公瑾"], evidence: e),
            .init(id: "hidden", typeID: "person", name: "未读秘密", evidence: [.init(unitID: "u2", quote: "未读秘密。")])]
        return book
    }
    private func session(_ book: BookProject) throws -> ReadingQuerySession {
        var context = ReadingContext(unitID: "u1", page: 1); context.queryRange = .init(pageStart: 1, pageEnd: 1)
        return ReadingQuerySession(snapshot: try .freeze(scope: .range, in: book, context: context), history: [], loader: nil, providedDocuments: [:], project: book)
    }
    private func object(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
    private func rows(_ text: String) throws -> [[String: Any]] { try XCTUnwrap(object(text)["items"] as? [[String: Any]]) }
    private func canonical(_ book: BookProject) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(book) }
    private func receipt(_ book: BookProject, mapping: [String: String], undone: Bool = false, patches: [ControlledRecordPatch] = []) -> ControlledChangeReceipt {
        .init(operationID: "op", originBookID: book.id, digest: "digest", grantID: "grant", createdAt: Date(timeIntervalSince1970: 0),
            undoneAt: undone ? Date(timeIntervalSince1970: 1) : nil, idMap: mapping, groups: [.knowledge], patches: patches, documents: [])
    }
    func testWireMappingPrioritizesActualBusinessIDsEvenWhenClientNamesLookLikeAnchors() throws {
        let book = fixture(), mapping = ["aa-anchor": "anchor.source", "zz-person": "person", "ab-reused": "anchor.reused", "ac-odd-name": "anchor.person", "ba-experience": "point"]
        let patches: [ControlledRecordPatch] = [.init(collection: .entities, id: "person", after: Data()),
            .init(collection: .entities, id: "anchor.person", after: Data()), .init(collection: .experienceAnchors, id: "point", after: Data())]
        let value = receipt(book, mapping: mapping, patches: patches), before = try JSONEncoder().encode(value)
        XCTAssertEqual(value.inlineMappingKeys, ["ac-odd-name", "zz-person", "aa-anchor", "ab-reused", "ba-experience"])
        XCTAssertEqual(Set(value.inlineMappingKeys), Set(mapping.keys)); XCTAssertEqual(value.idMap, mapping)
        XCTAssertEqual(try JSONEncoder().encode(value).count, before.count)
    }
    func testExactNameThenAliasThenPartialAndDescriptionWithoutChangingIdentitiesOrVersions() async throws {
        let book = fixture(), before = try canonical(book); var query = try session(book)
        let value = try rows(await query.execute(name: "objects_search", arguments: ["query": "周瑜"], maximumBytes: 16000))
        XCTAssertEqual(value.compactMap { $0["id"] as? String }, ["zz-exact", "cc-alias", "bb-partial", "aa-summary"])
        for item in value {
            let full = try object(await query.execute(name: "object_get", arguments: ["id": item["id"]!, "includeEvidence": false], maximumBytes: 16000))
            XCTAssertEqual(item["version"] as? String, (full["object"] as? [String: Any])?["version"] as? String)
        }
        XCTAssertEqual(try canonical(query.project!), before); XCTAssertTrue(query.sourceReferences.isEmpty); XCTAssertTrue(query.sourceExcerpts.isEmpty)
    }
    func testBatchCoversAllSixteenNamesBeforeSharedDescriptionMatches() async throws {
        var book = fixture();let names = (0..<16).map { "人物\($0)" }, text = names.joined(separator: "，")
        book.units[0].text = text
        let evidence = [Evidence(unitID: "u1", quote: text)]
        book.entities = (0..<20).map { .init(id: "a-\($0)", typeID: "person", name: "相关\($0)", summary: text, evidence: evidence) }
            + names.enumerated().map { .init(id: "z-\($0.offset)", typeID: "person", name: $0.element, evidence: evidence) }
        var query = try session(book)
        let result = try object(await query.execute(name: "objects_search", arguments: ["queries": names, "limit": 20], maximumBytes: 16000))
        let items = try XCTUnwrap(result["items"] as? [[String: Any]])
        XCTAssertEqual(Array(items.prefix(16)).compactMap { $0["name"] as? String }, names)
        XCTAssertEqual(result["total"] as? Int, 36); XCTAssertEqual(result["nextOffset"] as? Int, 20)
        XCTAssertEqual(Set(items.compactMap { $0["id"] as? String }).count, 20); XCTAssertTrue(query.sourceExcerpts.isEmpty)
    }
    func testDuplicateNamesStayAmbiguousAndPagingKeepsEveryMatchExactlyOnce() async throws {
        var book = fixture();var other = book.entities[3];other.id = "zz-other";book.entities.append(other)
        var query = try session(book);var all = [String](), offset = 0
        repeat {
            let value = try object(await query.execute(name: "objects_search", arguments: ["query": "周瑜", "limit": 2, "offset": offset], maximumBytes: 16000))
            all += (value["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            guard let next = value["nextOffset"] as? Int else { break }; XCTAssertGreaterThan(next, offset); offset = next
        } while offset < 20
        XCTAssertEqual(Array(all.prefix(2)), ["zz-exact", "zz-other"])
        XCTAssertEqual(Set(all), ["zz-exact", "zz-other", "cc-alias", "bb-partial", "aa-summary"]); XCTAssertEqual(all.count, 5)
        XCTAssertFalse(all.contains("hidden")); XCTAssertTrue(query.sourceExcerpts.isEmpty)
    }
    func testNoTermKeepsDirectoryOrderAndScopedMatchingSet() async throws {
        let book = fixture();var query = try session(book)
        let expected = try TemporalKnowledgeRuntime.objects(in: query.scopedKnowledgeProject()!, boundary: .init(allowedUnitIDs: ["u1"])).map(\.id)
        let values = try rows(await query.execute(name: "objects_search", arguments: [:], maximumBytes: 16000))
        XCTAssertEqual(values.compactMap { $0["id"] as? String }, expected)
        XCTAssertFalse(String(describing: values).contains("未读秘密"))
        let alias = try rows(await query.execute(name: "objects_search", arguments: ["query": "公瑾", "typeIDs": ["person"], "limit": 1], maximumBytes: 16000))
        XCTAssertEqual(alias.first?["id"] as? String, "zz-exact")
    }
    func testCanonicalSavedIdentitySurvivesShortenedHistoryWithoutBodyOrScopeGrant() throws {
        var book = fixture(); book.controlledChanges = .init()
        let saved = receipt(book, mapping: ["new": "zz-exact", "future": "hidden"])
        book.controlledChanges?.receipts = [saved]
        let before = try canonical(book); var query = try session(book)
        let wire: [String: Any] = ["status": "success", "applied": true, "operationID": "op", "idMap": ["new": "zz-exact", "future": "hidden", "spoofed": "aa-summary"]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: wire), as: UTF8.self)
        try query.recordSavedIdentities(text)
        let directory = try query.returnedObjectDirectory.rows(maximumBytes: 16000)
        XCTAssertEqual(directory.values.compactMap { $0["id"] as? String }, ["zz-exact"])
        XCTAssertEqual(directory.values.first?["name"] as? String, "周瑜"); XCTAssertNotNil(directory.values.first?["version"])
        XCTAssertNil(directory.values.first?["evidence"]); XCTAssertNil(directory.values.first?["summary"])
        XCTAssertTrue(query.sourceReferences.isEmpty); XCTAssertTrue(query.sourceExcerpts.isEmpty); XCTAssertEqual(try canonical(query.project!), before)
        let closing = try XCTUnwrap(query.finalEvidence(maximumBytes: 16000))
        XCTAssertTrue(closing.contains("zz-exact")); XCTAssertFalse(closing.contains("未读秘密"))
    }
    func testUnappliedUncorroboratedOrUndoneReceiptCannotSeedIdentityDirectory() throws {
        for mode in ["pending", "unknown-operation", "undone", "wrong-origin"] {
            var book = fixture();book.controlledChanges = .init()
            var actual = receipt(book, mapping: ["new": "zz-exact"], undone: mode == "undone")
            if mode == "wrong-origin" {actual.originBookID = "another-book"}
            book.controlledChanges?.receipts = [actual]
            var query = try session(book)
            let wire: [String: Any] = ["status": mode == "pending" ? "needs_confirmation" : "success", "applied": mode != "pending",
                "operationID": mode == "unknown-operation" ? "other" : "op", "idMap": ["new": "zz-exact"]]
            try query.recordSavedIdentities(String(decoding: JSONSerialization.data(withJSONObject: wire), as: UTF8.self))
            XCTAssertTrue(query.returnedObjectDirectory.isEmpty); XCTAssertTrue(query.sourceReferences.isEmpty)
        }
    }
}
