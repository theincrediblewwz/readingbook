import Foundation

/// Sequential reading may organize already extracted objects. This is separate
/// from chat layout grants and cannot edit an existing reader-owned node.
struct ReadingGraphToolPlugin: ReadingToolPlugin {
    let info = ReadingPluginInfo(id: "builtin.reading-graph", name: "阅读导图")
    func register(in registry: inout PluginToolRegistry) throws {
        try registry.register(RegisteredReadingTool(pluginID: info.id, schema: ReadingGraphTools.schema,
            phases: [.reading, .workflow], requiresReceipts: true) { data, project, allowed in
                try ReadingGraphTools.apply(arguments: data, to: &project, allowedUnitIDs: allowed)
            })
    }
}

public enum ReadingGraphTools {
    public static var schema: [String: Any] {
        let id: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 128, "pattern": "^[A-Za-z0-9_.-]+$"]
        return ["type": "function", "function": ["name": "reading_graph",
            "description": "为当前已通过逐段回执、已有实际原文证据的重要实体或事件创建持久导图节点。传真实targetIDs；按targetID复用已有节点，不改用户标题、位置或文档挂载。可选relationIDs仅沿已有真实知识关系创建同两端、同标签连线，且两端均须在targetIDs。返回真实idMap和新增/复用清单；不创建书中事实、不读写Markdown。由你按书选择重点，不自动把所有对象塞进导图。",
            "parameters": ["type": "object", "additionalProperties": false,
                "properties": ["targetIDs": ["type": "array", "items": id, "minItems": 1, "maxItems": 80, "uniqueItems": true],
                    "relationIDs": ["type": "array", "items": id, "maxItems": 120, "uniqueItems": true]], "required": ["targetIDs"]]]]
    }

    /// Build on a local copy so validation or identity collisions never leave a
    /// half-created graph, even when this helper is used without the registry.
    public static func apply(arguments: Data, to project: inout BookProject, allowedUnitIDs: Set<String>) throws -> String {
        struct Request: Decodable { var targetIDs: [String]; var relationIDs: [String]? }
        guard arguments.count <= 65_536,
              let raw = try JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              Set(raw.keys).isSubset(of: ["targetIDs", "relationIDs"]), raw["targetIDs"] != nil else { throw invalid("阅读导图参数必须是小于64KB的targetIDs/relationIDs声明。") }
        let request = try JSONDecoder().decode(Request.self, from: arguments)
        let targets = request.targetIDs, relationIDs = request.relationIDs ?? []
        guard (1...80).contains(targets.count), relationIDs.count <= 120,
              Set(targets).count == targets.count, Set(relationIDs).count == relationIDs.count,
              !allowedUnitIDs.isEmpty, allowedUnitIDs.isSubset(of: Set(project.units.map(\.id))) else { throw invalid("阅读导图的对象、关系或当前原文范围无效或超过上限。") }
        for id in targets + relationIDs { try checkID(id) }
        try SmartReadingRuntime.requireAnalysisAuthority(unitIDs: allowedUnitIDs, in: project)
        let safe = try PluginEngine.analysisContextProject(project, allowedUnitIDs: allowedUnitIDs)
        let names = Dictionary((safe.entities.map { ($0.id, $0.name) } + safe.events.map { ($0.id, $0.name) }), uniquingKeysWith: { first, _ in first })
        guard Set(targets).isSubset(of: Set(names.keys)) else { throw invalid("导图只能选择在当前获准原文有真实证据的既有实体或事件；身份候选和外页对象不算当前事实。") }
        let relations = Dictionary(project.relations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visibleRelations = Set(safe.relations.map(\.id))
        let targetSet = Set(targets)
        // The safe query projection is strict about aggregated relation evidence.
        // A relationship may still be used when one independent exact current
        // quote supports that same already stored pair and label.
        let currentUnits = Dictionary(project.units.filter { allowedUnitIDs.contains($0.id) }.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        func localProof(_ evidence: [Evidence]) -> Bool {
            evidence.contains { proof in
                guard !proof.quote.isEmpty, let text = currentUnits[proof.unitID], let range = text.range(of: proof.quote, options: .literal) else { return false }
                return text[range].utf8.elementsEqual(proof.quote.utf8)
            }
        }
        for id in relationIDs {
            guard let relation = relations[id], targetSet.contains(relation.fromID), targetSet.contains(relation.toID),
                  visibleRelations.contains(id) || localProof(relation.evidence) else { throw invalid("导图连线必须引用当前原文有真实依据的现存关系，且两端显式包含在targetIDs。") }
        }
        guard Set(project.nodes.map(\.id)).count == project.nodes.count, Set(project.edges.map(\.id)).count == project.edges.count else { throw invalid("已有导图身份重复，请先修复原图；本次未写入。") }
        var candidate = project, idMap: [String: String] = [:], edgeMap: [String: String] = [:]
        var createdNodes: [String] = [], reusedNodes: [String] = [], createdEdges: [String] = [], reusedEdges: [String] = []
        let orderedNodes = project.nodes.sorted { $0.id < $1.id }
        let bottom = project.nodes.filter { $0.y.isFinite }.map(\.y).max() ?? -220
        let baseY = min(9_900_000, max(-9_900_000, bottom + 220))
        for target in targets.sorted() {
            if let node = orderedNodes.first(where: { $0.targetID == target }) {
                idMap[target] = node.id; reusedNodes.append(node.id); continue
            }
            let id = try stableID("reading.node", [project.id, target])
            guard !candidate.nodes.contains(where: { $0.id == id }) else { throw invalid("稳定导图节点ID已被其他节点占用；本次未写入。") }
            let index = createdNodes.count
            var node = CanvasNode(id: id, targetID: target, x: Double(index % 8) * 360, y: baseY + Double(index / 8) * 220)
            if let title = names[target] {
                try ControlledChangeCoding.text(title, maximum: 1600)
                node.title = title
            }
            candidate.nodes.append(node); idMap[target] = id; createdNodes.append(id)
        }
        for relationID in relationIDs.sorted() {
            guard let relation = relations[relationID], let from = idMap[relation.fromID], let to = idMap[relation.toID] else { throw invalid("导图关联对象缺失；本次未写入。") }
            if let edge = candidate.edges.first(where: { $0.fromID == from && $0.toID == to && $0.label == relation.label }) {
                reusedEdges.append(edge.id); edgeMap[relationID] = edge.id; continue
            }
            let id = try stableID("reading.edge", [project.id, relationID, from, to])
            guard !candidate.edges.contains(where: { $0.id == id }) else { throw invalid("稳定导图连线ID已被其他连线占用；本次未写入。") }
            candidate.edges.append(CanvasEdge(id: id, fromID: from, toID: to, label: relation.label)); createdEdges.append(id); edgeMap[relationID] = id
        }
        guard candidate.nodes.count <= 100_000, candidate.edges.count <= 200_000 else { throw invalid("导图已达到保存上限；本次未写入。") }
        let response: [String: Any] = ["ok": true, "idMap": idMap, "edgeMap": edgeMap, "edgeIDs": createdEdges + reusedEdges, "createdNodeIDs": createdNodes, "reusedNodeIDs": reusedNodes,
            "createdEdgeIDs": createdEdges, "reusedEdgeIDs": reusedEdges,
            "notice": "已保存真实导图节点和现存关系的布局连线；没有修改原书、Markdown、已有用户节点或阅读覆盖。"]
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else { throw invalid("无法编码导图实际结果。") }
        guard result.utf8.count <= 11_000 else { throw invalid("导图完整ID回执超过本轮工具窗口，请缩小targetIDs/relationIDs分批组织；本次未写入。") }
        project = candidate
        return result
    }
    private static func stableID(_ prefix: String, _ fields: [String]) throws -> String {
        prefix + "." + String((try BookImporter.sha256(JSONSerialization.data(withJSONObject: fields))).prefix(40))
    }
    private static func checkID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 128, id.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { throw invalid("导图对象ID格式无效。") }
    }
    private static func invalid(_ message: String) -> ReadingError { .invalid(message) }
}
