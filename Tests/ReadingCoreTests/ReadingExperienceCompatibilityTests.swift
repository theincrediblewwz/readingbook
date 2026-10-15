import Foundation
import XCTest
@testable import ReadingCore

final class ReadingExperienceCompatibilityTests: XCTestCase {
    func testFutureRendererSurvivesStorageAndInvalidMetadataCannotReplaceIt() async throws {
        let raw = #"{"id":"future-view","title":"未来组件","kind":"vendor.future.canvas","typeIDs":[],"scope":"book","configuration":{"layout":"dense"}}"#
        let future = try JSONDecoder().decode(ViewDefinition.self, from: Data(raw.utf8))
        XCTAssertEqual(future.kind, .knowledge, "未知组件保留可阅读的回退类型。")
        XCTAssertEqual(future.rendererID, "vendor.future.canvas")
        XCTAssertEqual(try JSONDecoder().decode(ViewDefinition.self, from: JSONEncoder().encode(future)), future)
        let explicitRaw = #"{"id":"explicit-future","title":"另一个组件","kind":"knowledge","rendererID":"vendor.reader.v3"}"#
        let explicit = try JSONDecoder().decode(ViewDefinition.self, from: Data(explicitRaw.utf8))
        XCTAssertEqual(explicit.rendererID, "vendor.reader.v3")

        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Compatibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("原书.txt")
        try Data("原文保留，允许将来安装新的组件。".utf8).write(to: source)
        var project = try await BookImporter.importFile(at: source)
        project.views = [future, explicit]
        let repository = LibraryRepository(rootURL: fixture.appendingPathComponent("library", isDirectory: true))
        try await repository.create(project, sourceURL: source)
        let loaded = try await repository.loadAll()
        XCTAssertEqual(loaded.first?.views, [future, explicit], "未安装渲染器不能让整本书无法恢复。")

        var invalidExperience = project
        invalidExperience.readingExperience = ReadingExperienceState(mentions: [SourceMention(targetID: "missing", anchorID: "missing-anchor")])
        do { try await repository.save(invalidExperience); XCTFail("保存必须校验增强阅读的悬空引用。") } catch { }
        var invalidViews: [ViewDefinition] = []
        var invalid = future; invalid.rendererID = "../outside"; invalidViews.append(invalid)
        invalid = future; invalid.scope = "arbitrary"; invalidViews.append(invalid)
        invalid = future; invalid.configuration = ["layout": String(repeating: "a", count: 4_001)]; invalidViews.append(invalid)
        for view in invalidViews {
            var candidate = project; candidate.views = [view]
            do { try await repository.save(candidate); XCTFail("无效的声明元数据不能覆盖已保存组件。") } catch { }
        }
        let preserved = try await repository.loadAll()
        XCTAssertEqual(preserved.first?.views, [future, explicit])
        XCTAssertNil(preserved.first?.readingExperience)
    }

    func testEntityDeletionCleansMentionsAndOrphansButPreservesIndependentReadingLayer() throws {
        var project = BookProject(title: "删除关联", originalName: "source.txt", sourceHash: "fixture-v1", units: [SourceUnit(id: "u1", order: 0, chapter: "原文", text: "刘备入城。曹操离开。")])
        project.types = [EntityType(id: "person", name: "人物")]
        project.entities = [KnowledgeEntity(id: "liu", typeID: "person", name: "刘备"), KnowledgeEntity(id: "cao", typeID: "person", name: "曹操")]
        project.events = [KnowledgeEvent(id: "arrival", name: "入城", participantIDs: ["liu", "cao"])]
        project.documents = [DocumentRecord(id: "note", title: "用户理解", linkedIDs: ["liu", "cao"])]
        project.nodes = [CanvasNode(id: "liu-node", targetID: "liu"), CanvasNode(id: "cao-node", targetID: "cao")]
        project.edges = [CanvasEdge(id: "edge", fromID: "liu-node", toID: "cao-node", label: "联系")]
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: "u1", quote: "刘备", in: project)
        let other = try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: "u1", quote: "曹操", in: project)
        let orphan = try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: "u1", quote: "入城", in: project)
        let layer = ReadingLayer(id: "keep-layer", kind: "commentary", title: "独立评注", markdown: "用户仍可理解这句原文。", sourceAnchorIDs: [anchor.id])
        project.readingExperience = ReadingExperienceState(anchors: [anchor, other, orphan], mentions: [SourceMention(targetID: "liu", anchorID: anchor.id), SourceMention(targetID: "cao", anchorID: other.id), SourceMention(targetID: "liu", anchorID: orphan.id)], layers: [layer])
        let updated = try KnowledgeDeletion.removingEntity(id: "liu", from: project)
        let state = try XCTUnwrap(updated.readingExperience)
        XCTAssertEqual(state.mentions, [SourceMention(targetID: "cao", anchorID: other.id)])
        XCTAssertEqual(state.anchors, [anchor, other], "只清理已失去所有引用的锚点。")
        XCTAssertEqual(state.layers, [layer], "删除卡片不能级联删除独立评注。")
        XCTAssertEqual(updated.documents.first?.linkedIDs, ["cao"])
        XCTAssertEqual(updated.documents.first?.title, "用户理解")
        XCTAssertEqual(updated.events.first?.participantIDs, ["cao"])
        XCTAssertEqual(updated.nodes.map(\.id), ["cao-node"]); XCTAssertTrue(updated.edges.isEmpty)
        XCTAssertEqual(updated.units, project.units); XCTAssertEqual(project.readingExperience?.mentions.count, 3)
        XCTAssertNoThrow(try ReadingExperienceRuntime.validateStoredState(state, in: updated))
    }
}
