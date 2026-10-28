import Foundation

/// Removes a derived object and its structured references while retaining original text and Markdown files.
public enum KnowledgeDeletion {
    public static func removingEntity(id: String, from project: BookProject) throws -> BookProject {
        try checkIdentity(id, in: project)
        guard project.entities.contains(where: { $0.id == id }) else { throw ReadingError.invalid("要删除的实体不存在。") }
        var updated = project
        let name = updated.entities.first(where: { $0.id == id })?.name ?? id
        updated.entities.removeAll { $0.id == id }
        for index in updated.events.indices {
            updated.events[index].placeIDs.removeAll { $0 == id }
            updated.events[index].participantIDs.removeAll { $0 == id }
        }
        if updated.temporalKnowledge != nil {
            updated.temporalKnowledge?.presences.removeAll { $0.entityID == id || $0.placeID == id }
            updated.temporalKnowledge?.participations.removeAll { $0.entityID == id }
        }
        removeReferences(to: id, from: &updated)
        updated.audit.append(ToolAudit(name: "user_remove_entity", summary: "删除实体：\(name)；清理结构化关联，原文与用户 Markdown 保留。"))
        return updated
    }

    public static func removingEvent(id: String, from project: BookProject) throws -> BookProject {
        try checkIdentity(id, in: project)
        guard project.events.contains(where: { $0.id == id }) else { throw ReadingError.invalid("要删除的事件不存在。") }
        var updated = project
        let name = updated.events.first(where: { $0.id == id })?.name ?? id
        updated.events.removeAll { $0.id == id }
        if var temporal = updated.temporalKnowledge {
            temporal.presences.removeAll { $0.eventID == id }
            temporal.participations.removeAll { $0.eventID == id }
            temporal.eventMetadata.removeAll { $0.eventID == id }
            // Deleting a campaign does not delete its independent phases.
            // Detach the parent and ordering without losing their own dates.
            for index in temporal.eventMetadata.indices where temporal.eventMetadata[index].parentEventID == id {
                temporal.eventMetadata[index].parentEventID = nil
                temporal.eventMetadata[index].phaseOrder = nil
            }
            updated.temporalKnowledge = temporal
        }
        removeReferences(to: id, from: &updated)
        updated.audit.append(ToolAudit(name: "user_remove_event", summary: "删除事件：\(name)；地图、时间轴与图谱共用对象及关联已清理，原文与用户 Markdown 保留。"))
        return updated
    }

    public static func removingRelation(id: String, from project: BookProject) throws -> BookProject {
        try checkFormat(id)
        guard project.relations.filter({ $0.id == id }).count == 1 else { throw ReadingError.invalid("要删除的知识关系不存在或标识重复。") }
        var updated = project
        updated.relations.removeAll { $0.id == id }
        updated.temporalKnowledge?.relationMetadata.removeAll { $0.relationID == id }
        updated.audit.append(ToolAudit(name: "user_remove_relation", summary: "删除知识关系及其有效期：\(id)；布局连线与 Markdown 保留。"))
        return updated
    }

    /// Physical canvas deletion never changes a same-ID knowledge relation.
    public static func removingCanvasNode(id: String, from project: BookProject) throws -> BookProject {
        try checkFormat(id)
        guard project.nodes.filter({ $0.id == id }).count == 1 else { throw ReadingError.invalid("要移除的画布节点不存在或标识重复。") }
        var updated = project
        removeCanvasNodes([id], from: &updated)
        return updated
    }
    public static func removingCanvasEdge(id: String, from project: BookProject) throws -> BookProject {
        try checkFormat(id)
        guard project.edges.filter({ $0.id == id }).count == 1 else { throw ReadingError.invalid("要移除的布局连线不存在或标识重复。") }
        var updated = project; updated.edges.removeAll { $0.id == id }; return updated
    }

    private static func removeReferences(to id: String, from project: inout BookProject) {
        let removedRelations = Set(project.relations.filter { $0.fromID == id || $0.toID == id }.map(\.id))
        project.relations.removeAll { removedRelations.contains($0.id) }
        project.temporalKnowledge?.relationMetadata.removeAll { removedRelations.contains($0.relationID) }
        for index in project.documents.indices { project.documents[index].linkedIDs.removeAll { $0 == id } }
        let documents = Dictionary(project.documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var removedNodes = Set<String>()
        for index in project.nodes.indices where project.nodes[index].targetID == id {
            let attachments = (project.nodes[index].documentIDs ?? []).filter { documents[$0] != nil }
            if let first = attachments.first(where: { documents[$0]?.trashedAt == nil }) ?? attachments.first {
                // A mixed node owns a physical layout and attached Markdown.
                // Retarget that same node rather than discarding either.
                project.nodes[index].targetID = first
                project.nodes[index].documentIDs = attachments
                project.nodes[index].isStandalone = false
            } else if project.nodes[index].documentIDs != nil,
                      project.nodes[index].title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                project.nodes[index].targetID = project.nodes[index].id
                project.nodes[index].documentIDs = []
                project.nodes[index].isStandalone = true
            } else { removedNodes.insert(project.nodes[index].id) }
        }
        removeCanvasNodes(removedNodes, from: &project)
        if let experience = project.readingExperience {
            var cleaned = ReadingExperienceRuntime.removeTarget(id, from: experience)
            let temporal = project.temporalKnowledge ?? TemporalKnowledgeState()
            let externalAnchorIDs = Set(temporal.presences.flatMap(\.sourceAnchorIDs) + temporal.participations.flatMap(\.sourceAnchorIDs)
                + temporal.eventMetadata.flatMap(\.sourceAnchorIDs) + temporal.relationMetadata.flatMap(\.sourceAnchorIDs))
            let kept = Set(cleaned.anchors.map(\.id)).union(externalAnchorIDs)
            cleaned.anchors = experience.anchors.filter { kept.contains($0.id) }
            project.readingExperience = cleaned
        }
    }

    private static func removeCanvasNodes(_ ids: Set<String>, from project: inout BookProject) {
        project.nodes.removeAll { ids.contains($0.id) }
        project.edges.removeAll { ids.contains($0.fromID) || ids.contains($0.toID) }
        if project.graphGroups != nil {
            for index in project.graphGroups!.indices { project.graphGroups![index].nodeIDs.removeAll { ids.contains($0) } }
        }
    }

    private static func checkIdentity(_ id: String, in project: BookProject) throws {
        try checkFormat(id)
        let owners = project.entities.filter { $0.id == id }.count + project.events.filter { $0.id == id }.count + project.documents.filter { $0.id == id }.count
        guard owners == 1 else { throw ReadingError.invalid("对象不存在或跨实体、事件、文档存在重复 ID，不能安全删除。") }
    }
    private static func checkFormat(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 128, id != ".", id != "..", id.unicodeScalars.allSatisfy({
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0))
        }) else { throw ReadingError.invalid("知识对象 ID 不合法。") }
    }
}
