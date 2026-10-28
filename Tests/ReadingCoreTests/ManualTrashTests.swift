import Foundation
import XCTest
@testable import ReadingCore

final class ManualTrashTests: XCTestCase {
    private func fixture() throws -> BookProject {
        let text = "甲与乙在城中参加战役，随后进入阶段。"
        var book = BookProject(title: "回收测试", originalName: "trash.txt", sourceHash: try BookImporter.sha256(Data(text.utf8)),
            units: [SourceUnit(id: "u1", order: 0, chapter: "原文", page: 1, text: text)])
        PluginEngine.seed(&book)
        let evidence = Evidence(unitID: "u1", quote: text)
        book.entities = [KnowledgeEntity(id: "a", typeID: "person", name: "甲", evidence: [evidence]),
            KnowledgeEntity(id: "b", typeID: "person", name: "乙", evidence: [evidence]), KnowledgeEntity(id: "city", typeID: "place", name: "城", evidence: [evidence])]
        book.events = [KnowledgeEvent(id: "battle", name: "战役", placeIDs: ["city"], participantIDs: ["a", "b"], evidence: [evidence]),
            KnowledgeEvent(id: "phase", name: "阶段", participantIDs: ["b"], evidence: [evidence])]
        book.relations = [KnowledgeRelation(id: "same", fromID: "a", toID: "b", label: "同伴", evidence: [evidence])]
        var trashed = DocumentRecord(id: "doc-trash", title: "回收笔记"); trashed.trashedAt = Date()
        book.documents = [DocumentRecord(id: "doc", title: "用户笔记", linkedIDs: ["a", "battle"]), trashed]
        var mixed = CanvasNode(id: "mixed", targetID: "a", x: 60, y: 120); mixed.title = "混合节点"; mixed.documentIDs = ["doc-trash", "doc"]
        var custom = CanvasNode(id: "custom", targetID: "a", x: 300, y: 120); custom.title = "保留主题"; custom.documentIDs = []
        book.nodes = [mixed, custom, CanvasNode(id: "plain", targetID: "a"), CanvasNode(id: "other", targetID: "b"), CanvasNode(id: "event", targetID: "battle")]
        book.edges = [CanvasEdge(id: "same", fromID: "mixed", toID: "other", label: "我的连线"), CanvasEdge(id: "plain-edge", fromID: "plain", toID: "other")]
        book.graphGroups = [CanvasGroup(id: "group", title: "原分组", nodeIDs: book.nodes.map(\.id))]
        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: text, in: book)
        let orphan = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: "u1", quote: "甲", in: book)
        book.readingExperience = ReadingExperienceState(anchors: [anchor, orphan], mentions: [SourceMention(targetID: "a", anchorID: anchor.id)])
        book.temporalKnowledge = TemporalKnowledgeState(
            presences: [EntityPresence(id: "presence", entityID: "a", placeID: "city", eventID: "battle", action: "在城中", sourceAnchorIDs: [anchor.id], assertion: .explicit)],
            participations: [Participation(id: "participation", entityID: "a", eventID: "battle", role: "参加", sourceAnchorIDs: [anchor.id], assertion: .explicit)],
            eventMetadata: [EventTemporalMetadata(eventID: "battle", sourceAnchorIDs: [anchor.id], assertion: .explicit),
                EventTemporalMetadata(eventID: "phase", parentEventID: "battle", phaseOrder: 0, sourceAnchorIDs: [anchor.id], assertion: .explicit)],
            relationMetadata: [RelationTemporalMetadata(id: "validity", relationID: "same", validity: TemporalExtent(), sourceAnchorIDs: [anchor.id], assertion: .explicit)])
        return book
    }
    private func restore(_ id: String, in book: BookProject) throws -> BookProject {
        let plan = try ManualTrashRuntime.restorePlan(in: book, itemID: id)
        XCTAssertTrue(plan.conflicts.isEmpty, plan.conflicts.joined(separator: "\n"))
        return try ManualTrashRuntime.restoring(itemID: id, expectedItemIDs: plan.itemIDs, in: book)
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }

    func testEntityRestoresAllAssociationsAndPreservesUnrelatedLaterEdits() throws {
        let original = try fixture()
        var deleted = try ManualTrashRuntime.trashing(kind: .entity, id: "a", in: original)
        let item = try XCTUnwrap(deleted.manualTrash?.items.last)
        XCTAssertFalse(deleted.entities.contains { $0.id == "a" }); XCTAssertEqual(deleted.nodes.first { $0.id == "mixed" }?.targetID, "doc")
        XCTAssertTrue(item.patches.contains { $0.collection == .mentions && $0.id.contains("::") })
        let index = try XCTUnwrap(deleted.nodes.firstIndex { $0.id == "mixed" })
        deleted.nodes[index].x = 999; deleted.nodes[index].title = "删除后自己的标题"
        deleted.nodes[index].documentIDs = ["doc", "doc-trash"]
        deleted.documents[0].title = "删除后修改笔记标题"; deleted.documents[0].updatedAt = Date()
        let restored = try restore(item.id, in: deleted)
        XCTAssertTrue(restored.entities.contains { $0.id == "a" }); XCTAssertEqual(restored.events, original.events)
        XCTAssertEqual(restored.relations, original.relations); XCTAssertEqual(restored.temporalKnowledge, original.temporalKnowledge)
        XCTAssertEqual(Set(restored.readingExperience!.anchors.map(\.id)), Set(original.readingExperience!.anchors.map(\.id)))
        XCTAssertEqual(restored.readingExperience?.mentions, original.readingExperience?.mentions)
        XCTAssertEqual(restored.graphGroups, original.graphGroups)
        let mixed = try XCTUnwrap(restored.nodes.first { $0.id == "mixed" })
        XCTAssertEqual(mixed.targetID, "a"); XCTAssertEqual(mixed.title, "删除后自己的标题"); XCTAssertEqual(mixed.x, 999)
        XCTAssertEqual(mixed.documentIDs, ["doc", "doc-trash"])
        XCTAssertEqual(restored.documents[0].title, "删除后修改笔记标题"); XCTAssertEqual(restored.documents[0].linkedIDs, original.documents[0].linkedIDs)
        XCTAssertEqual(restored.documents[1].trashedAt, original.documents[1].trashedAt)
        XCTAssertEqual(restored.units, original.units); XCTAssertEqual(restored.manualTrash?.items.count, 0)
        XCTAssertEqual(restored.manualTrash?.revision, 2)
    }

    func testRepeatedRelatedDeletionsRequireExplicitReverseOrderRestoreSet() throws {
        let original = try fixture()
        let first = try ManualTrashRuntime.trashing(kind: .entity, id: "a", in: original)
        let a = try XCTUnwrap(first.manualTrash?.items.last)
        let second = try ManualTrashRuntime.trashing(kind: .entity, id: "b", in: first)
        let b = try XCTUnwrap(second.manualTrash?.items.last)
        let plan = try ManualTrashRuntime.restorePlan(in: second, itemID: a.id)
        XCTAssertEqual(plan.itemIDs, [b.id, a.id]); XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertThrowsError(try ManualTrashRuntime.restoring(itemID: a.id, expectedItemIDs: [a.id], in: second))
        let restored = try ManualTrashRuntime.restoring(itemID: a.id, expectedItemIDs: plan.itemIDs, in: second)
        XCTAssertEqual(Set(restored.entities.map(\.id)), Set(original.entities.map(\.id)))
        XCTAssertEqual(restored.events, original.events); XCTAssertEqual(restored.relations, original.relations)
        XCTAssertEqual(Set(restored.nodes.map(\.id)), Set(original.nodes.map(\.id)))
        XCTAssertEqual(restored.graphGroups, original.graphGroups); XCTAssertEqual(restored.manualTrash?.revision, 3)
        let again = try ManualTrashRuntime.trashing(kind: .entity, id: "a", in: restored)
        XCTAssertEqual(again.manualTrash?.revision, 4); XCTAssertNotEqual(again.manualTrash?.items.last?.id, a.id)
    }

    func testPhysicalAndKnowledgeEdgesRemainSeparateAndNodeRestoresMounts() throws {
        let original = try fixture()
        let relation = try ManualTrashRuntime.trashing(kind: .relation, id: "same", in: original)
        XCTAssertEqual(relation.edges, original.edges)
        let restoredRelation = try restore(relation.manualTrash!.items[0].id, in: relation)
        XCTAssertEqual(restoredRelation.relations, original.relations); XCTAssertEqual(restoredRelation.temporalKnowledge, original.temporalKnowledge)
        let edge = try ManualTrashRuntime.trashing(kind: .edge, id: "same", in: original)
        XCTAssertEqual(edge.relations, original.relations)
        XCTAssertEqual(try restore(edge.manualTrash!.items[0].id, in: edge).edges.count, original.edges.count)
        let node = try ManualTrashRuntime.trashing(kind: .node, id: "mixed", in: original)
        XCTAssertEqual(node.documents, original.documents); XCTAssertEqual(node.entities, original.entities)
        let restored = try restore(node.manualTrash!.items[0].id, in: node)
        XCTAssertEqual(restored.nodes.first { $0.id == "mixed" }, original.nodes.first { $0.id == "mixed" })
        XCTAssertEqual(restored.graphGroups, original.graphGroups); XCTAssertEqual(restored.edges.count, original.edges.count)
    }

    func testParentEventRecoveryAndSameFieldConflictAreAtomic() throws {
        let original = try fixture()
        var deleted = try ManualTrashRuntime.trashing(kind: .event, id: "battle", in: original)
        let id = deleted.manualTrash!.items[0].id
        XCTAssertNil(deleted.temporalKnowledge?.eventMetadata.first { $0.eventID == "phase" }?.parentEventID)
        let phase = try XCTUnwrap(deleted.temporalKnowledge?.eventMetadata.firstIndex { $0.eventID == "phase" })
        deleted.temporalKnowledge?.eventMetadata[phase].explanation = "后续独立解释"
        let restored = try restore(id, in: deleted)
        XCTAssertEqual(restored.temporalKnowledge?.eventMetadata.first { $0.eventID == "phase" }?.parentEventID, "battle")
        XCTAssertEqual(restored.temporalKnowledge?.eventMetadata.first { $0.eventID == "phase" }?.explanation, "后续独立解释")
        var conflicting = try ManualTrashRuntime.trashing(kind: .entity, id: "a", in: original)
        let index = try XCTUnwrap(conflicting.nodes.firstIndex { $0.id == "mixed" }); conflicting.nodes[index].targetID = "b"
        let before = try encoded(conflicting), itemID = conflicting.manualTrash!.items[0].id
        let plan = try ManualTrashRuntime.restorePlan(in: conflicting, itemID: itemID)
        XCTAssertFalse(plan.conflicts.isEmpty)
        XCTAssertThrowsError(try ManualTrashRuntime.restoring(itemID: itemID, expectedItemIDs: plan.itemIDs, in: conflicting))
        XCTAssertEqual(try encoded(conflicting), before)
    }

    func testCompositionAndUnknownRendererSnapshotsKeepExactDefinitionsAndSchema() throws {
        var original = try fixture()
        original.types.append(EntityType(id: "custom-type", name: "自定义类型"))
        let composition = CompositionDefinition(sources: [CompositionDataSource(id: "objects", collection: .objects, typeIDs: ["custom-type"])],
            parts: [CompositionPart(id: "cards", primitive: .objectList, sourceID: "objects")], layout: [CompositionLayoutNode(id: "root", kind: .part, partID: "cards")], rootID: "root")
        original.views = [ViewDefinition(id: "custom-view", title: "自定义组合", kind: .knowledge, rendererID: "reading.composition", scope: "book", composition: composition),
            ViewDefinition(id: "future-view", title: "旧扩展", kind: .knowledge, rendererID: "unknown.renderer", configuration: ["label": "旧配置"])]
        var deleted = try ManualTrashRuntime.trashing(kind: .view, id: "custom-view", viewIDs: original.views.map(\.id), in: original)
        deleted.types.removeAll { $0.id == "custom-type" }
        deleted.views.append(ViewDefinition(id: "new-view", title: "后来组件", kind: .map))
        let restored = try restore(deleted.manualTrash!.items[0].id, in: deleted)
        XCTAssertEqual(restored.views.first { $0.id == "custom-view" }, original.views[0])
        XCTAssertEqual(restored.views.first { $0.id == "future-view" }, original.views[1])
        XCTAssertTrue(restored.views.contains { $0.id == "new-view" }); XCTAssertTrue(restored.types.contains { $0.id == "custom-type" })
    }

    func testReservedIdentitySourceProtectionAndSnapshotBounds() throws {
        let original = try fixture(), deleted = try ManualTrashRuntime.trashing(kind: .entity, id: "a", in: original)
        XCTAssertEqual(try ManualTrashRuntime.protectedUnitIDs(in: deleted), ["u1"])
        var reused = deleted; reused.events.append(KnowledgeEvent(id: "a", name: "另一个事件"))
        XCTAssertThrowsError(try ManualTrashRuntime.validateReservedRecords(in: reused))
        var changed = deleted; changed.units[0].text += "新的OCR"
        let id = changed.manualTrash!.items[0].id, plan = try ManualTrashRuntime.restorePlan(in: changed, itemID: id)
        XCTAssertFalse(plan.conflicts.isEmpty)
        XCTAssertThrowsError(try ManualTrashRuntime.restoring(itemID: id, expectedItemIDs: plan.itemIDs, in: changed))
        var full = deleted
        let item = full.manualTrash!.items[0]
        full.manualTrash!.items = (0..<200).map { _ in var copy = item; copy.id = UUID().uuidString; return copy }
        XCTAssertThrowsError(try ManualTrashRuntime.trashing(kind: .entity, id: "b", in: full))
        XCTAssertTrue(full.entities.contains { $0.id == "b" }); XCTAssertEqual(full.manualTrash?.items.count, 200)
        var invalid = deleted; invalid.manualTrash!.items[0].deletedAt = Date(timeIntervalSince1970: .infinity)
        XCTAssertThrowsError(try ManualTrashRuntime.validateStoredState(in: invalid))
        let legacy = try JSONDecoder().decode(BookProject.self, from: encoded(original))
        XCTAssertNil(legacy.manualTrash)
    }

    func testRecoveryDisplayTitlesDoNotRejectLegacyBlankOrLongOriginalContent() throws {
        var original = try fixture()
        original.events[0].name = "   "
        original.relations[0].label = ""
        original.edges[0].label = String(repeating: "👩🏽‍💻", count: 400)
        for (kind, id) in [(ManualTrashKind.event, "battle"), (.relation, "same"), (.edge, "same")] {
            let deleted = try ManualTrashRuntime.trashing(kind: kind, id: id, in: original)
            let item = try XCTUnwrap(deleted.manualTrash?.items.first)
            XCTAssertFalse(item.title.isEmpty); XCTAssertLessThanOrEqual(item.title.utf8.count, 1600)
            let restored = try restore(item.id, in: deleted)
            XCTAssertEqual(restored.events.first { $0.id == "battle" }?.name, "   ")
            XCTAssertEqual(restored.relations.first { $0.id == "same" }?.label, "")
            XCTAssertEqual(restored.edges.first { $0.id == "same" }?.label, original.edges[0].label)
        }
        for label in ["\0\t\n", "a" + String(repeating: "\u{301}", count: 1000)] {
            var legacy = try fixture(); legacy.edges[0].label = label
            let deleted = try ManualTrashRuntime.trashing(kind: .edge, id: "same", in: legacy)
            let item = try XCTUnwrap(deleted.manualTrash?.items.first)
            XCTAssertEqual(item.title, "导图连线 · same")
            XCTAssertEqual(try restore(item.id, in: deleted).edges.first { $0.id == "same" }?.label, label)
        }
    }
}
