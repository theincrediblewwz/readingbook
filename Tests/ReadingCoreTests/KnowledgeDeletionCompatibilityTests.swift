import Foundation
import XCTest
@testable import ReadingCore

final class KnowledgeDeletionCompatibilityTests: XCTestCase {
    private let text = "甲至城，乙参与战役及阶段。"
    private func fixture(base: BookProject? = nil) throws -> BookProject {
        var book: BookProject
        if let base { book = base }
        else {
            book = BookProject(title: "删除兼容", originalName: "source.txt", sourceHash: try BookImporter.sha256(Data(text.utf8)),
                units: [SourceUnit(id: "u1", order: 0, chapter: "原文", text: text)])
        }
        PluginEngine.seed(&book)
        let unit = try XCTUnwrap(book.units.first), evidence = Evidence(unitID: unit.id, quote: unit.text)
        book.entities = [KnowledgeEntity(id: "person", typeID: "person", name: "甲", evidence: [evidence]),
                         KnowledgeEntity(id: "other", typeID: "person", name: "乙", evidence: [evidence]),
                         KnowledgeEntity(id: "city", typeID: "place", name: "城", evidence: [evidence])]
        book.events = [KnowledgeEvent(id: "campaign", name: "战役", participantIDs: ["person", "other"], evidence: [evidence]),
                       KnowledgeEvent(id: "phase", name: "阶段", participantIDs: ["other"], evidence: [evidence])]
        book.relations = [KnowledgeRelation(id: "r-person", fromID: "person", toID: "campaign", label: "参与", evidence: [evidence]),
                          KnowledgeRelation(id: "r-parent", fromID: "campaign", toID: "other", label: "关联", evidence: [evidence]),
                          KnowledgeRelation(id: "r-keep", fromID: "other", toID: "phase", label: "参与", evidence: [evidence])]
        if book.documents.isEmpty {
            var trash = DocumentRecord(id: "doc-trash", title: "回收中的笔记"); trash.trashedAt = Date()
            book.documents = [DocumentRecord(id: "doc-active", title: "用户 Markdown", linkedIDs: ["person", "campaign"]), trash]
        }
        var mixed = CanvasNode(id: "n-mixed", targetID: "person", x: 40, y: 80)
        mixed.title = "我的布局"; mixed.documentIDs = ["doc-trash", "doc-active"]
        var empty = CanvasNode(id: "n-custom", targetID: "person", x: 240, y: 80)
        empty.title = "独立主题"; empty.documentIDs = []
        var event = CanvasNode(id: "n-event", targetID: "campaign", x: 440, y: 80); event.documentIDs = ["doc-trash"]
        book.nodes = [mixed, CanvasNode(id: "n-old", targetID: "person"), empty, event, CanvasNode(id: "n-keep", targetID: "other")]
        book.edges = [CanvasEdge(id: "e-mixed", fromID: mixed.id, toID: "n-keep"), CanvasEdge(id: "e-old", fromID: "n-old", toID: "n-keep"),
                      CanvasEdge(id: "r-person", fromID: event.id, toID: "n-keep")]
        book.graphGroups = [CanvasGroup(id: "group", title: "整组", nodeIDs: book.nodes.map(\.id), childGroupIDs: ["nested"]),
                            CanvasGroup(id: "nested", title: "子组", nodeIDs: [mixed.id, "n-old"])]
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: unit.id, quote: unit.text, in: book)
        let orphan = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: unit.id, quote: "甲", in: book)
        // Temporal records deliberately share an anchor stored only by the
        // reading sidecar. Removing its last mention must not prune that source.
        book.readingExperience = ReadingExperienceState(anchors: [anchor, orphan], mentions: [SourceMention(targetID: "person", anchorID: anchor.id)])
        book.temporalKnowledge = TemporalKnowledgeState(
            presences: [EntityPresence(id: "presence-person", entityID: "person", placeID: "city", eventID: "campaign", action: "到城", sourceAnchorIDs: [anchor.id], assertion: .explicit),
                        EntityPresence(id: "presence-place", entityID: "other", placeID: "city", eventID: "phase", action: "参与阶段", sourceAnchorIDs: [anchor.id], assertion: .explicit),
                        EntityPresence(id: "presence-keep", entityID: "other", action: "独立出现", sourceAnchorIDs: [anchor.id], assertion: .explicit)],
            participations: [Participation(id: "part-person", entityID: "person", eventID: "campaign", role: "参与", sourceAnchorIDs: [anchor.id], assertion: .explicit),
                             Participation(id: "part-keep", entityID: "other", eventID: "phase", role: "参与", sourceAnchorIDs: [anchor.id], assertion: .explicit)],
            eventMetadata: [EventTemporalMetadata(eventID: "campaign", kind: "battle", sourceAnchorIDs: [anchor.id], assertion: .explicit),
                            EventTemporalMetadata(eventID: "phase", kind: "phase", parentEventID: "campaign", phaseOrder: 0, sourceAnchorIDs: [anchor.id], assertion: .explicit)],
            relationMetadata: [RelationTemporalMetadata(id: "time-person", relationID: "r-person", validity: TemporalExtent(), sourceAnchorIDs: [anchor.id], assertion: .explicit),
                               RelationTemporalMetadata(id: "time-parent", relationID: "r-parent", validity: TemporalExtent(), sourceAnchorIDs: [anchor.id], assertion: .explicit),
                               RelationTemporalMetadata(id: "time-keep", relationID: "r-keep", validity: TemporalExtent(), sourceAnchorIDs: [anchor.id], assertion: .explicit)])
        return book
    }
    private func validate(_ book: BookProject) throws {
        try TemporalKnowledgeRuntime.validateStoredState(in: book)
        try ControlledGraphRuntime.validate(in: book)
        if let state = book.readingExperience { try ReadingExperienceRuntime.validateStoredState(state, in: book) }
    }

    func testEntityAndPlaceDeletionClearTemporalReferencesAndKeepMixedDocumentNodes() throws {
        let original = try fixture()
        let updated = try KnowledgeDeletion.removingEntity(id: "person", from: original)
        let temporal = try XCTUnwrap(updated.temporalKnowledge)
        XCTAssertEqual(temporal.presences.map(\.id), ["presence-place", "presence-keep"])
        XCTAssertEqual(temporal.participations.map(\.id), ["part-keep"])
        XCTAssertEqual(temporal.relationMetadata.map(\.id), ["time-parent", "time-keep"])
        let mixed = try XCTUnwrap(updated.nodes.first { $0.id == "n-mixed" })
        XCTAssertEqual(mixed.targetID, "doc-active"); XCTAssertEqual(mixed.documentIDs, ["doc-trash", "doc-active"])
        XCTAssertEqual(mixed.title, "我的布局"); XCTAssertEqual(mixed.x, 40); XCTAssertEqual(mixed.y, 80)
        let custom = try XCTUnwrap(updated.nodes.first { $0.id == "n-custom" })
        XCTAssertEqual(custom.targetID, custom.id); XCTAssertEqual(custom.isStandalone, true)
        XCTAssertFalse(updated.nodes.contains { $0.id == "n-old" })
        XCTAssertEqual(updated.edges.map(\.id), ["e-mixed", "r-person"])
        XCTAssertTrue(updated.graphGroups!.allSatisfy { !$0.nodeIDs.contains("n-old") })
        XCTAssertEqual(updated.readingExperience?.anchors.count, 1, "Shared temporal source remains; unrelated orphan is still pruned.")
        XCTAssertEqual(updated.documents.map(\.relativePath), original.documents.map(\.relativePath))
        XCTAssertEqual(updated.documents.map(\.trashedAt), original.documents.map(\.trashedAt)); XCTAssertEqual(updated.units, original.units)
        try validate(updated)
        let withoutPlace = try KnowledgeDeletion.removingEntity(id: "city", from: original)
        XCTAssertEqual(withoutPlace.temporalKnowledge?.presences.map(\.id), ["presence-keep"])
        XCTAssertEqual(withoutPlace.temporalKnowledge?.participations, original.temporalKnowledge?.participations)
        try validate(withoutPlace)
    }
    func testDeletingParentEventDetachesPhaseAndRetainsItsOwnEvidence() throws {
        let original = try fixture(), updated = try KnowledgeDeletion.removingEvent(id: "campaign", from: original)
        let temporal = try XCTUnwrap(updated.temporalKnowledge), child = try XCTUnwrap(temporal.eventMetadata.first)
        XCTAssertEqual(child.eventID, "phase"); XCTAssertNil(child.parentEventID); XCTAssertNil(child.phaseOrder)
        XCTAssertEqual(child.sourceAnchorIDs, original.temporalKnowledge?.eventMetadata.last?.sourceAnchorIDs)
        XCTAssertEqual(temporal.presences.map(\.id), ["presence-place", "presence-keep"])
        XCTAssertEqual(temporal.participations.map(\.id), ["part-keep"])
        XCTAssertEqual(temporal.relationMetadata.map(\.id), ["time-keep"])
        XCTAssertEqual(updated.nodes.first { $0.id == "n-event" }?.targetID, "doc-trash", "A trashed attachment must remain restorable with its node.")
        XCTAssertEqual(updated.edges, original.edges); XCTAssertEqual(updated.documents.map(\.relativePath), original.documents.map(\.relativePath))
        try validate(updated)
    }
    func testKnowledgeRelationAndSameNamedLayoutEdgeDeleteIndependently() throws {
        let original = try fixture()
        let relation = try KnowledgeDeletion.removingRelation(id: "r-person", from: original)
        XCTAssertFalse(relation.relations.contains { $0.id == "r-person" })
        XCTAssertFalse(relation.temporalKnowledge!.relationMetadata.contains { $0.relationID == "r-person" })
        XCTAssertEqual(relation.edges, original.edges); XCTAssertEqual(relation.nodes, original.nodes)
        try validate(relation)
        let edge = try KnowledgeDeletion.removingCanvasEdge(id: "r-person", from: original)
        XCTAssertFalse(edge.edges.contains { $0.id == "r-person" })
        XCTAssertEqual(edge.relations, original.relations); XCTAssertEqual(edge.temporalKnowledge, original.temporalKnowledge)
        try validate(edge)
    }
    func testPhysicalNodeRemovalCleansEveryGroupWithoutDeletingMarkdownOrKnowledge() throws {
        let original = try fixture(), updated = try KnowledgeDeletion.removingCanvasNode(id: "n-mixed", from: original)
        XCTAssertFalse(updated.nodes.contains { $0.id == "n-mixed" })
        XCTAssertFalse(updated.edges.contains { $0.fromID == "n-mixed" || $0.toID == "n-mixed" })
        XCTAssertTrue(updated.graphGroups!.allSatisfy { !$0.nodeIDs.contains("n-mixed") })
        XCTAssertEqual(updated.documents, original.documents); XCTAssertEqual(updated.entities, original.entities)
        XCTAssertEqual(updated.relations, original.relations); XCTAssertEqual(updated.temporalKnowledge, original.temporalKnowledge)
        try validate(updated)
        XCTAssertThrowsError(try KnowledgeDeletion.removingCanvasNode(id: "missing", from: original))
    }
    func testDeletedKnowledgeKeepsRealMarkdownAndTrashedAttachmentRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-DeletionCompatibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        try Data(text.utf8).write(to: source, options: .atomic)
        var book = try await BookImporter.importFile(at: source)
        let repository = LibraryRepository(rootURL: directory.appendingPathComponent("library", isDirectory: true))
        try await repository.create(book, sourceURL: source)
        let active = DocumentRecord(id: "doc-active", title: "用户 Markdown"), trash = DocumentRecord(id: "doc-trash", title: "回收中的笔记")
        let activeBody = "# 用户 Markdown\n\n保留 $x^2$ 与自己的理解。", trashBody = "# 回收中的笔记\n\n仍能恢复。"
        book = try await repository.saveDocument(project: book, document: active, markdown: activeBody)
        book = try await repository.saveDocument(project: book, document: trash, markdown: trashBody)
        book = try await repository.setDocumentTrashed(project: book, documentID: trash.id, trashed: true)
        book = try fixture(base: book); try await repository.save(book)
        let updated = try KnowledgeDeletion.removingEvent(id: "campaign", from: KnowledgeDeletion.removingEntity(id: "person", from: book))
        try await repository.save(updated)
        let loaded = try await repository.loadAll()
        let saved = try XCTUnwrap(loaded.first)
        let actualActive = try await repository.readDocument(bookID: saved.id, document: active)
        let actualTrash = try await repository.readDocument(bookID: saved.id, document: trash)
        XCTAssertEqual(actualActive, activeBody); XCTAssertEqual(actualTrash, trashBody)
        let restored = try await repository.setDocumentTrashed(project: saved, documentID: trash.id, trashed: false)
        XCTAssertTrue(restored.activeDocuments.contains { $0.id == trash.id })
        XCTAssertEqual(restored.nodes, saved.nodes); XCTAssertEqual(restored.nodes.first { $0.id == "n-event" }?.targetID, trash.id)
    }
}
