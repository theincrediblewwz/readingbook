import Foundation
import XCTest
@testable import ReadingCore

final class ReadingProposalShapeTests: XCTestCase {
    private func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func failure(_ value: [String: Any], tool: String) throws -> ReadingProposalShapeError {
        do { _ = try ReadingProposalTools.decode(name: tool, arguments: data(value)); XCTFail("Unknown fields must not disappear") }
        catch let error as ReadingProposalShapeError { return error }
        throw ReadingError.invalid("Expected shape feedback")
    }
    func testMisgroupedFactsReturnExactPathsAndAnUnambiguousWholeGroupMove() throws {
        let payload: [String: Any] = ["batch": ["bookScheme": ["types": [], "newTypeIDs": ["person"],
            "entities": [], "newEntityIDs": [], "anchors": []]]]
        let error = try failure(payload, tool: "book_scheme_propose")
        XCTAssertEqual(error.issues.map { $0["path"]! }, ["/batch/bookScheme/anchors", "/batch/bookScheme/entities", "/batch/bookScheme/newEntityIDs", "/batch/bookScheme/newTypeIDs"])
        XCTAssertTrue(error.issues.allSatisfy { $0["belongsTo"]?.hasPrefix("/batch/knowledge/") == true })
        XCTAssertEqual(error.groupMoves, [["from": "/batch/bookScheme", "path": "/batch/knowledge", "targetTool": "knowledge_changes_propose"]])
        XCTAssertTrue(error.localizedDescription.contains("没有忽略"))
    }
    func testAllBusinessGroupsAndAtomicCompanionsRejectUnknownFields() throws {
        for (group, tool) in [("knowledge", "knowledge_changes_propose"), ("graph", "graph_changes_propose"),
                              ("documents", "document_changes_propose"), ("bookScheme", "book_scheme_propose")] {
            let direct = try failure(["unexpected": true], tool: tool)
            XCTAssertEqual(direct.issues.first?["path"], "/unexpected")
            let wrapped = try failure(["batch": [group: ["unexpected": true]]], tool: tool)
            XCTAssertEqual(wrapped.issues.first?["path"], "/batch/" + group + "/unexpected")
            var groups: [String: Any] = ["knowledge": [:]]
            groups[group] = ["unexpected": true]
            let companion = try failure(["batch": groups], tool: "knowledge_changes_propose")
            XCTAssertEqual(companion.issues.first?["path"], "/batch/" + group + "/unexpected")
        }
    }
    func testNestedUnknownFieldsDoNotDisappearButDeclaredFlexibleMapsRemainOpen() throws {
        let unknown = try failure(["batch": ["knowledge": ["eventMetadata": [["extent": ["dateGuess": "tomorrow"]]]]]], tool: "knowledge_changes_propose")
        XCTAssertEqual(unknown.issues.first?["path"], "/batch/knowledge/eventMetadata/0/extent/dateGuess")
        let evidence = try failure(["batch": ["documents": ["create": [["evidence": [["a/b~key": true]]]]]]], tool: "document_changes_propose")
        XCTAssertEqual(evidence.issues.first?["path"], "/batch/documents/create/0/evidence/0/a~1b~0key")
        let properties = ["future-field": "reader defined", "name/with~escape": "kept"]
        let raw: [String: Any] = ["batch": ["knowledge": ["newEntityIDs": ["new"], "entities": [["id": "new", "typeID": "person", "name": "name", "summary": "", "aliases": [], "properties": properties, "evidence": [["unitID": "u1", "quote": "text"]]]]],
            "bookScheme": ["views": [["id": "view", "title": "view", "kind": "map", "configuration": properties]]]]]
        let decoded = try ReadingProposalTools.decode(name: "knowledge_changes_propose", arguments: data(raw))
        XCTAssertEqual(decoded.knowledge?.entities?.first?.properties, properties)
        XCTAssertEqual(decoded.bookScheme?.views?.first?.configuration, properties)
    }
    func testFeedbackIsBoundedAndDoesNotRecommendOverwritingAnExistingGroup() throws {
        let raw: [String: Any] = ["batch": ["knowledge": [:], "bookScheme": ["entities": [], "newEntityIDs": []]]]
        let error = try failure(raw, tool: "book_scheme_propose")
        XCTAssertTrue(error.groupMoves.isEmpty)
        let many = Dictionary(uniqueKeysWithValues: (0..<100).map { ("unrecognized-\($0)", true) })
        let bounded = try failure(["batch": ["knowledge": many]], tool: "knowledge_changes_propose")
        XCTAssertEqual(bounded.issues.count, 24)
    }
}
