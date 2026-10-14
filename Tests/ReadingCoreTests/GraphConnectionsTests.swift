import Foundation
import XCTest
@testable import ReadingCore

final class GraphConnectionsTests: XCTestCase {
    private func project() -> BookProject {
        var project = BookProject(title: "导图", originalName: "source.txt", sourceHash: "fixture", units: [SourceUnit(id: "source", order: 0, chapter: "原文", text: "原文保留。")])
        project.documents = [DocumentRecord(id: "doc-a", title: "理解A"), DocumentRecord(id: "doc-b", title: "理解B")]
        project.nodes = [CanvasNode(id: "a-first", targetID: "doc-a"), CanvasNode(id: "a-second", targetID: "doc-a"), CanvasNode(id: "b", targetID: "doc-b")]
        return project
    }

    func testCanvasInstanceIDsRemainDistinctAndRetryTrimsOnlyLabel() throws {
        let initial = project()
        let first = try GraphConnections.connecting(from: "a-first", to: "b", label: "  推导\n", in: initial)
        XCTAssertEqual(first.edges.first?.label, "推导")
        let retried = try GraphConnections.connecting(from: "a-first", to: "b", label: "\n推导 ", in: first)
        XCTAssertEqual(retried.edges, first.edges, "重复操作必须保留原连线ID。")
        let second = try GraphConnections.connecting(from: "a-second", to: "b", label: "推导", in: retried)
        XCTAssertEqual(second.edges.count, 2, "同一文档的不同画布实例不能按targetID合并端点。")
        XCTAssertEqual(Set(second.edges.map(\.fromID)), ["a-first", "a-second"])
        let reverse = try GraphConnections.connecting(from: "b", to: "a-first", label: "推导", in: second)
        XCTAssertEqual(reverse.edges.count, 3)
        let sameDocument = try GraphConnections.connecting(from: "a-first", to: "a-second", label: "另一种理解", in: reverse)
        XCTAssertEqual(sameDocument.edges.count, 4, "不同画布实例即使引用同一文档，也不是节点自连。")
        XCTAssertTrue(initial.edges.isEmpty, "纯函数不能提前修改调用方项目。")
    }

    func testInvalidSelectionAndHiddenOrDanglingContentNeverMutateProject() throws {
        var project = project()
        project.documents[1].trashedAt = Date()
        project.nodes.append(CanvasNode(id: "missing-target", targetID: "deleted-object"))
        let nodes = project.nodes
        for (from, to, label) in [("a-first", "a-first", "关联"), ("a-first", "missing-node", "关联"), ("a-first", "missing-target", "关联"), ("a-first", "b", "关联"), ("a-first", "a-second", " \n\t")] {
            XCTAssertThrowsError(try GraphConnections.connecting(from: from, to: to, label: label, in: project))
            XCTAssertTrue(project.edges.isEmpty)
            XCTAssertEqual(project.nodes, nodes)
        }
        project.nodes.append(CanvasNode(id: "a-first", targetID: "doc-a"))
        XCTAssertThrowsError(try GraphConnections.connecting(from: "a-first", to: "a-second", label: "关联", in: project))
        XCTAssertTrue(project.edges.isEmpty)
    }

    func testOldWhitespaceLabelIsIdempotentWithoutRewritingHistory() throws {
        var project = project()
        let existing = CanvasEdge(id: "legacy-link", fromID: "a-first", toID: "b", label: "  延伸  ")
        project.edges = [existing]
        let result = try GraphConnections.connecting(from: "a-first", to: "b", label: "延伸", in: project)
        XCTAssertEqual(result.edges, [existing])
    }

    func testRenameKeepsEdgeIdentityEndpointsAndSameNameIsUnchanged() throws {
        var initial = project()
        initial.edges = [CanvasEdge(id: "keep-this-id", fromID: "a-first", toID: "b", label: "延伸")]
        let renamed = try GraphConnections.renaming(edgeID: "keep-this-id", label: "\n  证明依据  ", in: initial)
        XCTAssertEqual(renamed.edges.count, 1)
        XCTAssertEqual(renamed.edges[0].id, "keep-this-id")
        XCTAssertEqual(renamed.edges[0].fromID, "a-first")
        XCTAssertEqual(renamed.edges[0].toID, "b")
        XCTAssertEqual(renamed.edges[0].label, "证明依据")
        XCTAssertEqual(initial.edges[0].label, "延伸")
        let repeated = try GraphConnections.renaming(edgeID: "keep-this-id", label: " 证明依据\n", in: renamed)
        XCTAssertEqual(repeated.edges, renamed.edges)
    }

    func testRenameConflictHiddenAndMissingEndpointsPreserveAllExistingEdges() throws {
        var initial = project()
        initial.edges = [CanvasEdge(id: "first", fromID: "a-first", toID: "b", label: "延伸"), CanvasEdge(id: "second", fromID: "a-first", toID: "b", label: "  推导  ")]
        let oldEdges = initial.edges
        for (id, label) in [("first", "推导"), ("missing", "新名称"), ("first", " \n\t"), ("first", String(repeating: "长", count: 401))] {
            XCTAssertThrowsError(try GraphConnections.renaming(edgeID: id, label: label, in: initial))
            XCTAssertEqual(initial.edges, oldEdges)
        }
        initial.documents[1].trashedAt = Date()
        XCTAssertThrowsError(try GraphConnections.renaming(edgeID: "first", label: "新名称", in: initial))
        XCTAssertEqual(initial.edges, oldEdges)
        initial.documents[1].trashedAt = nil
        initial.nodes.removeAll { $0.id == "b" }
        XCTAssertThrowsError(try GraphConnections.renaming(edgeID: "first", label: "新名称", in: initial))
        XCTAssertEqual(initial.edges, oldEdges)
    }
}
