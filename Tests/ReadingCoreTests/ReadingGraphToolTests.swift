import Foundation
import XCTest
@testable import ReadingCore

final class ReadingGraphToolTests: XCTestCase {
    private func fixture(receipted: Bool = true) throws -> BookProject {
        let units = [SourceUnit(id: "u1", order: 0, chapter: "一", page: 1, text: "神秘人与乙结盟。"),
            SourceUnit(id: "u2", order: 1, chapter: "二", page: 2, text: "神秘人原来叫后文姓名，远方人物也来了。")]
        var book = BookProject(title: "阅读导图", originalName: "graph.txt", sourceHash: try BookImporter.sha256(Data(units.map(\.text).joined().utf8)), units: units)
        PluginEngine.seed(&book)
        let local = Evidence(unitID: "u1", quote: units[0].text), future = Evidence(unitID: "u2", quote: units[1].text)
        book.entities = [KnowledgeEntity(id: "a", typeID: "person", name: "后文姓名", aliases: ["神秘人"], evidence: [local, future]),
            KnowledgeEntity(id: "b", typeID: "person", name: "乙", evidence: [local]),
            KnowledgeEntity(id: "outside", typeID: "person", name: "远方人物", evidence: [future])]
        book.relations = [KnowledgeRelation(id: "alliance", fromID: "a", toID: "b", label: "结盟", evidence: [local, future]),
            KnowledgeRelation(id: "later", fromID: "a", toID: "outside", label: "后来相识", evidence: [future])]
        book.documents = [DocumentRecord(id: "note", title: "用户笔记")]
        var node = CanvasNode(id: "user-node", targetID: "b", x: 123, y: -456)
        node.title = "用户自定标题"; node.documentIDs = ["note"]; book.nodes = [node]
        if receipted {
            let unit = units[0], paragraphs = try ReadingLedger.paragraphs(for: units[0], in: book)
            let batch = try ReadingLedger.makeBatch(unit: unit, paragraphs: paragraphs); book.receiptBatch = batch
            let payload: [String: Any] = ["batchID": batch.id, "receipts": paragraphs.map {
                ["paragraphID": $0.id, "textHash": $0.textHash, "summary": "本段明确记载两个人物结盟。", "startQuote": $0.startQuote, "endQuote": $0.endQuote, "issues": []] as [String: Any]
            }]
            _ = try PluginEngine.apply(name: "read_receipt", arguments: JSONSerialization.data(withJSONObject: payload), to: &book, allowedUnitIDs: [unit.id], phase: .receipt)
            book.receiptBatch = nil
        }
        return book
    }
    private func apply(_ payload: [String: Any], to book: inout BookProject, allowed: Set<String> = ["u1"], phase: PluginToolPhase = .reading) throws -> [String: Any] {
        let result = try PluginEngine.apply(name: "reading_graph", arguments: JSONSerialization.data(withJSONObject: payload), to: &book, allowedUnitIDs: allowed, phase: phase)
        let wrapper = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let summary = try XCTUnwrap(wrapper["summary"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(summary.utf8)) as? [String: Any])
    }
    private func encoded(_ book: BookProject) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(book) }

    func testReadingGraphCreatesRealStableNodesAndRelationsWithoutTouchingUserLayout() async throws {
        var book = try fixture()
        let userNode = book.nodes[0], documents = book.documents, evidence = book.entities[0].evidence
        let payload: [String: Any] = ["targetIDs": ["a", "b"], "relationIDs": ["alliance"]]
        let response = try apply(payload, to: &book)
        let mapping = try XCTUnwrap(response["idMap"] as? [String: String])
        XCTAssertEqual(mapping["b"], "user-node")
        let a = try XCTUnwrap(book.nodes.first { $0.targetID == "a" })
        XCTAssertEqual(mapping["a"], a.id); XCTAssertEqual(a.title, "神秘人")
        XCTAssertTrue(a.x.isFinite && a.y.isFinite); XCTAssertLessThan(abs(a.x), 10_000_000); XCTAssertLessThan(abs(a.y), 10_000_000)
        XCTAssertEqual(book.nodes.first { $0.id == userNode.id }, userNode)
        XCTAssertEqual(book.documents, documents); XCTAssertEqual(book.entities[0].evidence, evidence)
        XCTAssertEqual(book.edges.count, 1); XCTAssertEqual(book.edges[0].fromID, a.id)
        XCTAssertEqual(book.edges[0].toID, userNode.id); XCTAssertEqual(book.edges[0].label, "结盟")
        XCTAssertEqual((response["edgeMap"] as? [String: String])?["alliance"], book.edges[0].id)
        let nodes = book.nodes, edges = book.edges
        let again = try apply(payload, to: &book)
        XCTAssertEqual(book.nodes, nodes); XCTAssertEqual(book.edges, edges)
        XCTAssertEqual(again["idMap"] as? [String: String], mapping)
        XCTAssertEqual(again["createdNodeIDs"] as? [String], []); XCTAssertEqual(again["createdEdgeIDs"] as? [String], [])
        XCTAssertTrue(ReadingWorkflowRuntime.actions.first { $0.id == "facts.extract" }!.allowedTools.contains("reading_graph"))
        var workflowBook = try fixture()
        workflowBook.methods = [ReadingMethod(id: "graph-method", name: "对象组织", goal: "把已抽取对象组织成图", steps: ["组织重要对象"],
            executions: [ReadingStepExecution(stepIndex: 0, actionID: "facts.extract")])]
        workflowBook.plan = ReadingPlan(methodIDs: ["graph-method"])
        let task = try XCTUnwrap(ReadingWorkflowRuntime.nextTask(for: workflowBook.units[0], in: workflowBook))
        let services = ReadingWorkflowServices { task, original in
            var candidate = original
            _ = try PluginEngine.apply(name: "reading_graph", arguments: JSONSerialization.data(withJSONObject: ["targetIDs": ["a", "b"], "relationIDs": ["alliance"]]),
                to: &candidate, allowedUnitIDs: ["u1"], phase: .workflow)
            ReadingWorkflowRuntime.recordTool("reading_graph", in: &candidate, previous: original)
            try ReadingWorkflowRuntime.complete(stepID: task.requirement.stepID,
                output: ReadingWorkflowOutput(result: "已保存两个人物的导图节点及原文结盟关系连线。", paragraphIDs: task.input.paragraphIDs,
                    evidence: [Evidence(unitID: "u1", quote: "神秘人与乙结盟。")]), to: &candidate, allowedUnitIDs: ["u1"])
            return candidate
        }
        workflowBook = try await ReadingWorkflowRuntime.perform(task, in: workflowBook, services: services)
        XCTAssertEqual(workflowBook.workflowRuns?.first?.status, .completed)
        XCTAssertEqual(workflowBook.workflowRuns?.first?.knowledgeWriteTools, ["reading_graph"])
    }

    func testReadingGraphRequiresCurrentEvidenceReceiptsAndAtomicValidRelations() throws {
        var book = try fixture()
        let before = try encoded(book)
        let invalidPayloads: [[String: Any]] = [
            ["targetIDs": ["a", "outside"]],
            ["targetIDs": ["a", "b"], "relationIDs": ["later"]],
            ["targetIDs": ["a", "b"], "relationIDs": ["made-up-relation"]],
            ["targetIDs": ["a", "a"]],
            ["targetIDs": ["a"], "x": 1_000_000_000]
        ]
        for payload in invalidPayloads {
            XCTAssertThrowsError(try apply(payload, to: &book)); XCTAssertEqual(try encoded(book), before)
        }
        XCTAssertThrowsError(try apply(["targetIDs": ["a"]], to: &book, allowed: []))
        XCTAssertThrowsError(try apply(["targetIDs": ["a"]], to: &book, phase: .planning))
        var noReceipts = try fixture(receipted: false)
        XCTAssertThrowsError(try apply(["targetIDs": ["a"]], to: &noReceipts))
        XCTAssertEqual(noReceipts.nodes.count, 1); XCTAssertTrue(noReceipts.edges.isEmpty)
        XCTAssertEqual(try encoded(book), before)
        for title in ["标题\0含空字符", String(repeating: "👩🏽‍💻", count: 150)] {
            var invalid = try fixture()
            let local = invalid.entities[0].evidence[0]
            invalid.entities[0].name = title; invalid.entities[0].evidence = [local]
            invalid.entities.append(KnowledgeEntity(id: "0-valid", typeID: "person", name: "当前人物", evidence: [local]))
            let original = try encoded(invalid)
            XCTAssertThrowsError(try apply(["targetIDs": ["0-valid", "a"]], to: &invalid))
            XCTAssertEqual(try encoded(invalid), original, "A later invalid title cannot leave an earlier valid node half-written.")
        }
    }
}
