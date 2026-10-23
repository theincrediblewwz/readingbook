import Foundation

/// Canvas connections address canvas instances, never document/knowledge target IDs.
/// A document may appear in several independent nodes without their connections being folded together.
public enum GraphConnections {
    public static func connecting(from: String, to: String, label: String, in project: BookProject) throws -> BookProject {
        try validateEndpoints(from: from, to: to, in: project)
        let normalized = try normalizedLabel(label)
        // Direction is meaningful. A→B and B→A remain separate; whitespace from
        // older labels must not let a retry create another identical connection.
        if project.edges.contains(where: { $0.fromID == from && $0.toID == to && $0.label.trimmingCharacters(in: .whitespacesAndNewlines) == normalized }) { return project }
        var result = project
        result.edges.append(CanvasEdge(fromID: from, toID: to, label: normalized))
        return result
    }

    public static func renaming(edgeID: String, label: String, in project: BookProject) throws -> BookProject {
        let indices = project.edges.indices.filter { project.edges[$0].id == edgeID }
        guard indices.count == 1 else { throw ReadingError.invalid("连线已移除、标识重复或不存在，请重新选择连线。") }
        let index = indices[0], edge = project.edges[index]
        try validateEndpoints(from: edge.fromID, to: edge.toID, in: project)
        let normalized = try normalizedLabel(label)
        guard !project.edges.contains(where: { $0.id != edgeID && $0.fromID == edge.fromID && $0.toID == edge.toID && $0.label.trimmingCharacters(in: .whitespacesAndNewlines) == normalized }) else {
            throw ReadingError.invalid("这两个节点之间已有同方向的同名关系。请使用其他名称；原有两条连线均已保留。")
        }
        if edge.label.trimmingCharacters(in: .whitespacesAndNewlines) == normalized { return project }
        var result = project
        result.edges[index].label = normalized
        return result
    }

    private static func validateEndpoints(from: String, to: String, in project: BookProject) throws {
        guard from != to else { throw ReadingError.invalid("不能把画布节点连接到自己。") }
        let sources = project.nodes.filter { $0.id == from }, destinations = project.nodes.filter { $0.id == to }
        guard sources.count == 1, destinations.count == 1 else { throw ReadingError.invalid("连线端点已移除、标识重复或不存在，请重新选择节点。") }
        let hiddenDocuments = Set(project.trashedDocuments.map(\.id))
        let validTargets = Set(project.activeDocuments.map(\.id))
            .union(project.entities.map(\.id)).union(project.events.map(\.id))
            .union(project.units.map(\.id)).union(project.insights.map(\.id))
        let activeDocuments = Set(project.activeDocuments.map(\.id)), registeredTargets = validTargets.union(hiddenDocuments)
        guard [sources[0], destinations[0]].allSatisfy({ node in
            (node.isStandalone == true && node.targetID == node.id) ||
            (!hiddenDocuments.contains(node.targetID) && validTargets.contains(node.targetID)) ||
            (registeredTargets.contains(node.targetID) && !(Set(node.documentIDs ?? []).intersection(activeDocuments)).isEmpty)
        }) else {
            throw ReadingError.invalid("连线节点的文档已回收，或引用的内容已失效。请恢复文档或重新选择节点。")
        }
    }

    private static func normalizedLabel(_ label: String) throws -> String {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 400 else { throw ReadingError.invalid("关系名称不能为空，且最多400字。") }
        return normalized
    }
}
