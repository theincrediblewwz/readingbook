import Foundation
import XCTest
@testable import ReadingCore

final class AnalysisContextTests: XCTestCase {
    private func project() throws -> BookProject {
        let units = [SourceUnit(id: "u1", order: 0, chapter: "一", page: 1, text: "神秘人路过，青衣客停下。"),
            SourceUnit(id: "u2", order: 1, chapter: "二", page: 2, text: "神秘人原来是曹操；青衣客原来是许褚。此处揭晓结局。")]
        var book = BookProject(title: "范围", originalName: "scope.txt", sourceHash: try BookImporter.sha256(Data(units.map(\.text).joined().utf8)), units: units)
        PluginEngine.seed(&book)
        let local = Evidence(unitID: "u1", quote: units[0].text), future = Evidence(unitID: "u2", quote: units[1].text)
        book.entities = [KnowledgeEntity(id: "person1", typeID: "person", name: "曹操", summary: "后文结局", properties: ["身份": "隐藏身份"], aliases: ["神秘人"], evidence: [local, future]),
            KnowledgeEntity(id: "person2", typeID: "person", name: "许褚", summary: "未来分析", aliases: ["青衣客"], evidence: [future])]
        book.documents = [DocumentRecord(id: "secret-note", title: "秘密笔记", evidence: [future])]
        book.coverage["u1"]?.status = .completed; book.coverage["u2"]?.status = .completed
        return book
    }

    func testAnalysisSearchKeepsStableIdentityWithoutFutureFactsOrNotes() throws {
        var book = try project()
        func search(_ query: String, allowed: Set<String>) throws -> String {
            try PluginEngine.apply(name: "knowledge_search", arguments: JSONSerialization.data(withJSONObject: ["query": query]), to: &book, allowedUnitIDs: allowed, phase: .reading)
        }
        let local = try search("神秘人", allowed: ["u1"])
        XCTAssertTrue(local.contains("person1")); XCTAssertFalse(local.contains("曹操")); XCTAssertFalse(local.contains("后文结局")); XCTAssertFalse(local.contains("隐藏身份"))
        let candidate = try search("青衣客", allowed: ["u1"])
        XCTAssertTrue(candidate.contains("person2")); XCTAssertTrue(candidate.contains("identityOnly"))
        XCTAssertFalse(candidate.contains("许褚")); XCTAssertFalse(candidate.contains("未来分析"))
        XCTAssertFalse(try search("曹操", allowed: ["u1"]).contains("person1"))
        XCTAssertFalse(try search("秘密笔记", allowed: ["u1"]).contains("secret-note"))
        XCTAssertFalse(try search("神秘人", allowed: []).contains("person1"), "Old completed coverage is not a read grant.")
        XCTAssertThrowsError(try search("神秘人", allowed: ["missing"]))
    }

    func testAnalysisIndexRejectsCrossBoundaryLayersAndAllForeignAnchors() throws {
        var book = try project()
        let anchors = try book.units.map { try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: $0.id, quote: $0.text, in: book) }
        book.readingExperience = ReadingExperienceState(anchors: anchors,
            layers: [ReadingLayer(id: "local", kind: "commentary", title: "本地", markdown: "本地解释", sourceAnchorIDs: [anchors[0].id]),
                ReadingLayer(id: "mixed", kind: "commentary", title: "跨页结局", markdown: "范围外完整结局", sourceAnchorIDs: anchors.map(\.id)),
                ReadingLayer(id: "future", kind: "commentary", title: "后页", markdown: "后页分析", sourceAnchorIDs: [anchors[1].id])],
            alignments: [ReferenceAlignment(id: "mixed-alignment", sourceAnchorIDs: anchors.map(\.id), title: "后页资料标题", markdown: "后页资料正文")])
        let scoped = try PluginEngine.analysisContextProject(book, allowedUnitIDs: ["u1"])
        XCTAssertEqual(scoped.units.map(\.id), ["u1"])
        XCTAssertEqual(scoped.entities.first?.name, "神秘人"); XCTAssertEqual(scoped.entities.first?.summary, ""); XCTAssertTrue(scoped.entities.first!.properties.isEmpty)
        XCTAssertTrue(scoped.documents.isEmpty)
        XCTAssertEqual(scoped.readingExperience?.anchors.map(\.unitID), ["u1"])
        XCTAssertEqual(scoped.readingExperience?.layers.map(\.id), ["local"])
        XCTAssertTrue(scoped.readingExperience!.alignments.isEmpty)
    }
}
