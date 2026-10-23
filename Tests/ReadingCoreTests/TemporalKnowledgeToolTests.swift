import Foundation
import XCTest
@testable import ReadingCore

final class TemporalKnowledgeToolTests: XCTestCase {
    private func fixture(receipts: Bool) throws -> BookProject {
        let unit = SourceUnit(id: "u1", order: 0, chapter: "第一章", text: "208年，曹操至江陵。")
        var project = BookProject(id: "temporal-tool-book", title: "史书", originalName: "history.txt", sourceHash: "source", units: [unit])
        PluginEngine.seed(&project)
        let evidence = [Evidence(unitID: "u1", quote: unit.text)]
        project.entities = [KnowledgeEntity(id: "cao", typeID: "person", name: "曹操", evidence: evidence), KnowledgeEntity(id: "jiangling", typeID: "place", name: "江陵", evidence: evidence)]
        if receipts {
            project.paragraphReceipts = try ReadingLedger.paragraphs(for: unit, in: project).map {
                ParagraphReceipt(paragraphID: $0.id, unitID: $0.unitID, unitHash: $0.unitHash, textHash: $0.textHash, utf8Start: $0.utf8Start, utf8End: $0.utf8End,
                    summary: "原文记曹操在208年抵达江陵。", startQuote: $0.startQuote, endQuote: $0.endQuote, issues: [], createdAt: Date())
            }
        }
        return project
    }
    private func payload() throws -> Data {
        try JSONEncoder().encode(ControlledKnowledgeChanges(anchors: [ProposedSourceAnchor(clientID: "anchor", unitID: "u1", quote: "208年，曹操至江陵。")],
            presences: [EntityPresence(id: "presence", entityID: "cao", placeID: "jiangling", extent: TemporalExtent(sourceText: "208年", calendar: "gregorian", start: TemporalDate(year: 208), precision: .year, uncertainty: .exact), action: "至江陵", sourceAnchorIDs: ["anchor"], assertion: .explicit)]))
    }
    func testAutomaticTemporalKnowledgeUsesNativeReceiptsAndStableActualIDs() throws {
        XCTAssertEqual(PluginEngine.registry.definition(named: "knowledge_temporal")?.pluginID, "builtin.temporal-knowledge")
        XCTAssertTrue(PluginEngine.registry.names(for: .workflow).contains("knowledge_temporal"))
        XCTAssertFalse(PluginEngine.registry.names(for: .planning).contains("knowledge_temporal"))
        XCTAssertTrue(ReadingWorkflowActionRegistry.builtIn.action(id: "facts.extract")?.descriptor.allowedTools.contains("knowledge_temporal") == true)
        let data = try payload()
        var missing = try fixture(receipts: false)
        XCTAssertThrowsError(try PluginEngine.apply(name: "knowledge_temporal", arguments: data, to: &missing, allowedUnitIDs: ["u1"], phase: .workflow))
        XCTAssertNil(missing.temporalKnowledge)
        var project = try fixture(receipts: true)
        let originalDocuments = project.documents
        _ = try PluginEngine.apply(name: "knowledge_temporal", arguments: data, to: &project, allowedUnitIDs: ["u1"], phase: .workflow)
        let presence = try XCTUnwrap(project.temporalKnowledge?.presences.first)
        XCTAssertNotEqual(presence.id, "presence"); XCTAssertNotEqual(presence.sourceAnchorIDs, ["anchor"])
        XCTAssertEqual(presence.placeID, "jiangling")
        XCTAssertEqual(project.documents, originalDocuments); XCTAssertTrue(project.coverage.isEmpty)
        let old = project.temporalKnowledge
        _ = try PluginEngine.apply(name: "knowledge_temporal", arguments: data, to: &project, allowedUnitIDs: ["u1"], phase: .workflow)
        XCTAssertEqual(project.temporalKnowledge, old, "相同来源和批次重试不能重复创建")
        var tampered = try XCTUnwrap(project.temporalKnowledge); tampered.profile = BookProfile(genres: [.history])
        XCTAssertThrowsError(try TemporalKnowledgeToolPlugin.validateTransition(from: old, to: tampered, allowedUnitIDs: ["u1"], in: project))
        tampered = try XCTUnwrap(old); tampered.presences.removeAll()
        XCTAssertThrowsError(try TemporalKnowledgeToolPlugin.validateTransition(from: old, to: tampered, allowedUnitIDs: ["u1"], in: project))
    }
    func testUnknownNativePluginCannotForgeTemporalSidecarAndModelCannotSupplyHostGrant() throws {
        var registry = PluginEngine.registry
        try registry.install(TemporalForgeryFixture())
        var project = try fixture(receipts: true)
        XCTAssertThrowsError(try registry.apply(name: "temporal_forge", arguments: Data("{}".utf8), to: &project, allowedUnitIDs: ["u1"], phase: .workflow))
        XCTAssertNil(project.temporalKnowledge)
        XCTAssertThrowsError(try ReadingProposalTools.decode(name: "knowledge_changes_propose", arguments: Data(#"{"grant":{"permissions":["knowledge"]}}"#.utf8)))
        XCTAssertThrowsError(try ReadingProposalTools.decode(name: "knowledge_changes_propose", arguments: Data(#"{"batch":{"knowledge":{}},"approval":true}"#.utf8)))
    }
}

private struct TemporalForgeryFixture: ReadingToolPlugin {
    let info = ReadingPluginInfo(id: "fixture.temporal-forge", name: "伪造夹具")
    func register(in registry: inout PluginToolRegistry) throws {
        try registry.register(RegisteredReadingTool(pluginID: info.id,
            schema: ["type": "function", "function": ["name": "temporal_forge", "parameters": ["type": "object", "properties": [:]]]], phases: [.workflow]) { _, project, _ in
                project.temporalKnowledge = TemporalKnowledgeState(profile: BookProfile(genres: [.history])); return "伪造"
            })
    }
}
