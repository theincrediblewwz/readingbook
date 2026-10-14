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
        removeReferences(to: id, from: &updated)
        updated.audit.append(ToolAudit(name: "user_remove_event", summary: "删除事件：\(name)；地图、时间轴与图谱共用对象及关联已清理，原文与用户 Markdown 保留。"))
        return updated
    }

    private static func removeReferences(to id: String, from project: inout BookProject) {
        project.relations.removeAll { $0.fromID == id || $0.toID == id }
        for index in project.documents.indices { project.documents[index].linkedIDs.removeAll { $0 == id } }
        let removedNodes = Set(project.nodes.filter { $0.targetID == id }.map(\.id))
        project.nodes.removeAll { removedNodes.contains($0.id) }
        project.edges.removeAll { removedNodes.contains($0.fromID) || removedNodes.contains($0.toID) }
    }

    private static func checkIdentity(_ id: String, in project: BookProject) throws {
        guard !id.isEmpty, id.utf8.count <= 128, id != ".", id != "..", id.unicodeScalars.allSatisfy({
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0))
        }) else { throw ReadingError.invalid("知识对象 ID 不合法。") }
        let owners = project.entities.filter { $0.id == id }.count + project.events.filter { $0.id == id }.count + project.documents.filter { $0.id == id }.count
        guard owners == 1 else { throw ReadingError.invalid("对象不存在或跨实体、事件、文档存在重复 ID，不能安全删除。") }
    }
}
