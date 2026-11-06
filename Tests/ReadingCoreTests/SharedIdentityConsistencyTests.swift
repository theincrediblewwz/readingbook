import Foundation
import XCTest
@testable import ReadingCore

final class SharedIdentityConsistencyTests: XCTestCase {
    private func book() -> BookProject {
        var value = BookProject(title: "身份一致性", originalName: "book.txt", sourceHash: "fixture", units: [
            .init(id: "u1", order: 0, chapter: "开头", page: 1, text: "劉備又称玄德。关羽与刘备同行。")])
        PluginEngine.seed(&value)
        value.entities = [.init(id: "liu", typeID: "person", name: "劉備", aliases: ["玄德"],
            evidence: [.init(unitID: "u1", quote: value.units[0].text)])]
        return value
    }
    private func entity(_ name: String, id: String = "new", type: String = "person", aliases: [String] = []) -> KnowledgeEntity {
        .init(id: id, typeID: type, name: name, aliases: aliases,
              evidence: [.init(unitID: "u1", quote: "劉備又称玄德。")])
    }
    private func apply(_ entities: [KnowledgeEntity], newIDs: [String], to project: BookProject) throws -> BookProject {
        var candidate = project, map = ControlledIdentityMap(operationID: "identity-check", project: project)
        try ControlledKnowledgeRuntime.apply(.init(entities: entities, newEntityIDs: newIDs), to: &candidate,
            allowedUnitIDs: ["u1"], requiresReceipts: false, identity: &map)
        return candidate
    }
    func testControlledProposalCannotCreateAnotherIDForExistingNameOrAlias() throws {
        let original = book(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; let bytes = try encoder.encode(original)
        for name in ["劉備", "玄德"] {
            XCTAssertThrowsError(try apply([entity(name)], newIDs: ["new"], to: original))
        }
        XCTAssertEqual(try encoder.encode(original), bytes)
    }
    func testControlledProposalChecksNewObjectsWithinSameBatch() throws {
        var original = book(); original.entities = []
        XCTAssertThrowsError(try apply([entity("劉備", id: "a"), entity("刘备", id: "b")], newIDs: ["a", "b"], to: original))
        XCTAssertEqual(original.entities.count, 0)
    }
    func testControlledProposalAllowsExplicitlyDisambiguatedPeopleAndDifferentTypes() throws {
        let original = book()
        let result = try apply([entity("刘备（同名读者）"), entity("劉備", id: "place-liu", type: "place")], newIDs: ["new", "place-liu"], to: original)
        XCTAssertEqual(result.entities.count, 3)
        XCTAssertEqual(result.entities[0].id, "liu")
    }
    func testExistingIDStillAcceptsEvidenceAndPreservesReaderCorrection() throws {
        var original = book(), corrected = original.entities[0]; corrected.summary = "我的理解"
        original = try KnowledgeUserEditsRuntime.applying(expected: .entity(original.entities[0]), replacement: .entity(corrected), basis: .interpretation, to: original)
        var incoming = entity("刘备", id: "liu"); incoming.summary = "AI 不能覆盖我的理解"
        let result = try apply([incoming], newIDs: [], to: original)
        XCTAssertEqual(result.entities.count, 1); XCTAssertEqual(result.entities[0].summary, "我的理解")
        XCTAssertTrue(result.entities[0].evidence.contains(incoming.evidence[0]))
    }
    func testLegacyToolsRejectSimplifiedDuplicateAndStillAllowStableIDReuse() throws {
        var original = book()
        let unit = original.units[0], paragraphs = try ReadingLedger.paragraphs(for: original.units[0], in: original)
        original.receiptBatch = try ReadingLedger.makeBatch(unit: unit, paragraphs: paragraphs)
        let receipts: [[String: Any]] = paragraphs.map { ["paragraphID": $0.id, "textHash": $0.textHash, "summary": "核对人物称谓。", "startQuote": $0.startQuote, "endQuote": $0.endQuote, "issues": []] }
        _ = try PluginEngine.apply(name: "read_receipt", arguments: JSONSerialization.data(withJSONObject: ["batchID": original.receiptBatch!.id, "receipts": receipts]), to: &original, allowedUnitIDs: ["u1"])
        original.receiptBatch = nil
        let data = try JSONSerialization.data(withJSONObject: ["entities": [["id": "new", "typeID": "person", "name": "刘备", "evidence": [["unitID": "u1", "quote": "劉備又称玄德。"]]]]])
        XCTAssertThrowsError(try PluginEngine.apply(name: "cards_upsert", arguments: data, to: &original, allowedUnitIDs: ["u1"]))
        XCTAssertEqual(original.entities.map(\.id), ["liu"])
        let reused = try JSONSerialization.data(withJSONObject: ["entities": [["id": "liu", "typeID": "person", "name": "刘备", "evidence": [["unitID": "u1", "quote": "劉備又称玄德。"]]]]])
        XCTAssertNoThrow(try PluginEngine.apply(name: "cards_upsert", arguments: reused, to: &original, allowedUnitIDs: ["u1"]))
        XCTAssertEqual(original.entities.count, 1)
    }
    func testConcurrentMergeRejectsEquivalentNamesAndAliases() throws {
        let base = book()
        for name in ["刘备", " 玄德 "] {
            var proposed = base; proposed.entities.append(entity(name))
            XCTAssertThrowsError(try AIProjectMerge.merge(base: base, result: proposed, latest: base))
        }
        var empty = base; empty.entities = []
        var proposed = empty; proposed.entities = [entity("劉備", id: "a"), entity("刘备", id: "b")]
        XCTAssertThrowsError(try AIProjectMerge.merge(base: empty, result: proposed, latest: empty))
    }
    func testIdentityCheckDoesNotTruncateNamesOrStripMeaningfulPunctuation() throws {
        var original = book()
        let prefix = String(repeating: "甲", count: 170)
        original.entities = [entity(prefix + "乙", id: "long"), entity("A-B", id: "hyphen"), entity("José", id: "accent")]
        let result = try apply([entity(prefix + "丙"), entity("AB", id: "letters"), entity("Jose", id: "plain")], newIDs: ["new", "letters", "plain"], to: original)
        XCTAssertEqual(result.entities.count, 6)
    }
    func testWidthCaseAndCanonicalUnicodeAreCheckedWithoutChangingStoredNames() throws {
        var original = book(); original.entities = [entity("Alice", id: "alice"), entity("José", id: "jose")]
        for name in ["ＡＬＩＣＥ", "alice", "Jose\u{301}"] {
            XCTAssertThrowsError(try apply([entity(name)], newIDs: ["new"], to: original))
        }
        XCTAssertEqual(original.entities.map(\.name), ["Alice", "José"])
    }
    func testAliasAddedToExistingObjectInSameBatchCannotHideNewDuplicate() throws {
        let original = book()
        var update = original.entities[0]; update.aliases.append("玄德公")
        let duplicate = entity("玄德公")
        for values in [[update, duplicate], [duplicate, update]] {
            XCTAssertThrowsError(try apply(values, newIDs: ["new"], to: original))
            var proposed = original; proposed.entities = values
            XCTAssertThrowsError(try AIProjectMerge.merge(base: original, result: proposed, latest: original))
        }
    }
}
