import Foundation

/// Sequential reading shares the typed transaction, with host receipt authority.
struct TemporalKnowledgeToolPlugin: ReadingToolPlugin {
    let info = ReadingPluginInfo(id: "builtin.temporal-knowledge", name: "有来源的时态知识")
    func register(in registry: inout PluginToolRegistry) throws {
        let schema: [String: Any] = ["type": "function", "function": ["name": "knowledge_temporal",
            "description": "在当前已完成逐段回执的原文内，原子补充实体/事件/关系及人物出现、个人参与、事件阶段、关系有效期。先复用既有hostID；新对象ID须列new*IDs，其他新记录ID与anchor.clientID是批次别名，宿主返回idMap。精确quote是唯一来源，不把参与事件推成位置，不把未知时间当成立。不能编辑用户文档/书型偏好，也不能选择宿主权限或operationID。",
            "parameters": ReadingProposalSchemas.knowledge]]
        try registry.register(RegisteredReadingTool(pluginID: info.id, schema: schema, phases: [.reading, .workflow], requiresReceipts: true) { data, project, allowed in
            let batch = try ReadingProposalTools.decode(name: "knowledge_changes_propose", arguments: data)
            guard let changes = batch.knowledge, batch.graph == nil, batch.documents == nil, batch.bookScheme == nil else { throw ReadingError.invalid("自动阅读知识工具只接受知识组；不能夹带文档、布局或书本方案。") }
            let payload = try ControlledChangeCoding.data(changes)
            let identity = try BookImporter.sha256(Data(project.sourceHash.utf8) + Data(allowed.sorted().joined(separator: "\n").utf8) + payload)
            let before = project
            let idMap = try ControlledKnowledgeRuntime.apply(changes, to: &project, allowedUnitIDs: allowed, operationID: "read-" + String(identity.prefix(48)))
            try PluginEngine.validateKnowledgeTypeTransition(from: before, to: project)
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "applied": true, "idMap": idMap,
                "note": "已由宿主通过当前逐段回执与真实引文校验；未改用户正文，不代表语义无遗漏。"], options: [.sortedKeys]), as: UTF8.self)
        })
    }

    static func validateTransition(from old: TemporalKnowledgeState?, to new: TemporalKnowledgeState?, allowedUnitIDs: Set<String>, in project: BookProject) throws {
        guard let new, new.schemaVersion == (old?.schemaVersion ?? 1), new.profile == old?.profile else { throw ReadingError.invalid("阅读工具不能删除时态知识、改版本或更改读者书型偏好。") }
        func appended<T: Hashable>(_ previous: [T], _ current: [T]) throws {
            guard Set(previous).isSubset(of: Set(current)) else { throw ReadingError.invalid("阅读时态工具只能追加有来源记录，不能改写或删除旧记录。") }
        }
        try appended(old?.anchors ?? [], new.anchors); try appended(old?.presences ?? [], new.presences)
        try appended(old?.participations ?? [], new.participations); try appended(old?.eventMetadata ?? [], new.eventMetadata)
        try appended(old?.relationMetadata ?? [], new.relationMetadata)
        let anchors = Dictionary(((project.readingExperience?.anchors ?? []) + new.anchors).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func admitted(_ ids: [String]) throws {
            guard !ids.isEmpty, ids.allSatisfy({ anchors[$0].map { allowedUnitIDs.contains($0.unitID) } ?? false }) else { throw ReadingError.invalid("新增时态记录必须全部引用本次获准原文。") }
        }
        let oldAnchors = Set(old?.anchors ?? []), oldPresences = Set(old?.presences ?? []), oldParticipations = Set(old?.participations ?? [])
        let oldEvents = Set(old?.eventMetadata ?? []), oldRelations = Set(old?.relationMetadata ?? [])
        for anchor in new.anchors where !oldAnchors.contains(anchor) {
            guard allowedUnitIDs.contains(anchor.unitID) else { throw ReadingError.invalid("新时态锚点超出本次原文。") }
        }
        for value in new.presences where !oldPresences.contains(value) { try admitted(value.sourceAnchorIDs) }
        for value in new.participations where !oldParticipations.contains(value) { try admitted(value.sourceAnchorIDs) }
        for value in new.eventMetadata where !oldEvents.contains(value) { try admitted(value.sourceAnchorIDs) }
        for value in new.relationMetadata where !oldRelations.contains(value) { try admitted(value.sourceAnchorIDs) }
        try TemporalKnowledgeRuntime.validateStoredState(in: project)
    }
}
