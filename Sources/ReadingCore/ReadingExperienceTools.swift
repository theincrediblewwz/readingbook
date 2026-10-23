import Foundation

/// The reading layer is a real native tool plugin. Declaration packs and AI
/// methods discover it through the same registry as cards, maps and timelines.
struct ReadingExperienceToolPlugin: ReadingToolPlugin {
    let info = ReadingPluginInfo(id: "builtin.reading-experience", name: "多层伴读")
    func register(in registry: inout PluginToolRegistry) throws {
        try registry.register(RegisteredReadingTool(pluginID: info.id, schema: ReadingExperienceTools.schema,
                                                   phases: [.reading, .workflow], requiresReceipts: true) { data, project, allowed in
            try ReadingExperienceTools.apply(arguments: data, to: &project, allowedUnitIDs: allowed)
        })
    }
}

public enum ReadingExperienceTools {
    public static var schema: [String: Any] {
        let id: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 128, "pattern": "^[A-Za-z0-9_.-]+$"]
        let short: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 400]
        let markdown: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 16000]
        let anchorIDs = list(id, minimum: 1, maximum: 32)
        let anchor = object(["id": id, "unitID": id, "quote": ["type": "string", "minLength": 1, "maxLength": 32768],
                             "prefix": ["type": "string", "maxLength": 400], "suffix": ["type": "string", "maxLength": 400]], required: ["id", "unitID", "quote"])
        let provenance = object(["label": short, "url": ["type": "string", "maxLength": 2000], "workTitle": short, "locator": short], required: ["label"])
        let layer = object(["id": id, "kind": ["type": "string", "minLength": 1, "maxLength": 80, "description": "适用类型如translation/explanation/glossary/commentary/reference；可声明自定义类型。"],
                            "title": short, "markdown": markdown, "sourceAnchorIDs": anchorIDs, "sourceLabel": short,
                            "parallelGroupID": id, "provenance": provenance], required: ["id", "kind", "title", "markdown", "sourceAnchorIDs", "sourceLabel"])
        let alignment = object(["id": id, "sourceAnchorIDs": anchorIDs, "title": short, "markdown": markdown, "provenance": provenance,
                                "status": ["type": "string", "enum": ["needs-review"], "description": "AI资料对齐保留待核对，不能假称外部来源已联网验证。"]],
                               required: ["id", "sourceAnchorIDs", "title", "markdown", "provenance", "status"])
        return ["type": "function", "function": ["name": "reading_enrich", "description": "依据当前已通过全部逐段回执的原文，原子保存稳定原文锚点、词语提及、译文/释义/评注与真实资料对齐。先创建实体，再以mentions关联。anchor.id仅为请求内别名，宿主生成真实稳定ID；引用可用该别名或已保存hostID。重复词句必须prefix/suffix精确消歧。不同内容不能覆盖已有ID，不能删改旧层或用户Markdown。AI产物标注待核对；资料对齐至少引用两个不同原文单元的真实锚点。没有新增适用内容时单独提供noChangesReason。",
            "parameters": object(["anchors": list(anchor, maximum: 64), "mentions": list(object(["targetID": id, "anchorID": id], required: ["targetID", "anchorID"]), maximum: 128),
                                   "layers": list(layer, maximum: 32), "alignments": list(alignment, maximum: 16),
                                   "noChangesReason": ["type": "string", "minLength": 1, "maxLength": 400]], required: [])]]
    }

    private struct AnchorRequest: Decodable {
        var id: String; var unitID: String; var quote: String; var prefix: String?; var suffix: String?
    }
    private struct Submission: Decodable {
        var anchors: [AnchorRequest]?; var mentions: [SourceMention]?; var layers: [ReadingLayer]?
        var alignments: [ReferenceAlignment]?; var noChangesReason: String?
    }

    public static func apply(arguments: Data, to project: inout BookProject, allowedUnitIDs: Set<String>) throws -> String {
        guard arguments.count <= 262_144, let object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              Set(object.keys).isSubset(of: ["anchors", "mentions", "layers", "alignments", "noChangesReason"]) else {
            throw ReadingError.invalid("阅读增强参数必须是小于256 KiB的合法JSON对象，不能包含未知字段。")
        }
        try ReadingLedger.requireComplete(unitIDs: allowedUnitIDs, in: project)
        let value = try JSONDecoder().decode(Submission.self, from: arguments)
        let requests = value.anchors ?? [], mentions = value.mentions ?? [], layers = value.layers ?? []
        let alignments = value.alignments ?? []
        guard requests.count <= 64, mentions.count <= 128, layers.count <= 32, alignments.count <= 16,
              Set(requests.map(\.id)).count == requests.count else { throw ReadingError.invalid("阅读增强条目过多或请求内锚点别名重复。") }
        if let reason = value.noChangesReason {
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.count <= 400,
                  requests.isEmpty, mentions.isEmpty, layers.isEmpty, alignments.isEmpty else {
                throw ReadingError.invalid("无新增内容说明只能单独提交，且不能超过400字。")
            }
            return "无新增阅读层：\(reason)；既有产物、原文及阅读覆盖保留。"
        }
        guard !mentions.isEmpty || !layers.isEmpty || !alignments.isEmpty else {
            throw ReadingError.invalid("阅读增强须包含可展示的提及、阅读层或资料对齐，或明确说明无新增内容。")
        }
        var candidate = project
        var state = project.readingExperience ?? ReadingExperienceState()
        var aliases: [String: String] = [:]
        for request in requests {
            try identifier(request.id)
            guard allowedUnitIDs.contains(request.unitID) else { throw ReadingError.invalid("新锚点超出本次获准原文单元。") }
            let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: request.unitID, quote: request.quote,
                                                                   prefix: request.prefix ?? "", suffix: request.suffix ?? "", in: project)
            aliases[request.id] = anchor.id
            // Adjacent context may differ between calls while the host identity
            // still resolves to exactly the same source position. Retain the
            // first validated record instead of treating this as an overwrite.
            if !state.anchors.contains(where: { $0.id == anchor.id }) { state.anchors.append(anchor) }
        }
        func remapped(_ ids: [String]) -> [String] { ids.map { aliases[$0] ?? $0 } }
        for mention in mentions {
            let mapped = SourceMention(targetID: mention.targetID, anchorID: aliases[mention.anchorID] ?? mention.anchorID)
            try append(mapped, to: &state.mentions, validateID: false, id: { $0.id })
        }
        for var layer in layers {
            layer.sourceAnchorIDs = remapped(layer.sourceAnchorIDs)
            layer.sourceLabel = "AI 生成 · 待核对"
            try append(layer, to: &state.layers, id: { $0.id })
        }
        for var alignment in alignments {
            alignment.sourceAnchorIDs = remapped(alignment.sourceAnchorIDs)
            let units = Set(alignment.sourceAnchorIDs.compactMap { id in state.anchors.first { $0.id == id }?.unitID })
            guard units.count >= 2 else { throw ReadingError.invalid("资料对齐须有至少两个不同原文单元的真实锚点；仅有链接或作品名不是来源证据。") }
            alignment.status = "needs-review"
            try append(alignment, to: &state.alignments, id: { $0.id })
        }
        candidate.readingExperience = state
        try validateTransition(from: project.readingExperience, to: state, allowedUnitIDs: allowedUnitIDs, in: candidate)
        project = candidate
        let anchorMap = aliases.keys.sorted().map { "\($0)=\(aliases[$0] ?? "")" }.joined(separator: "；")
        return "阅读增强批次已校验保存（已有相同条目保留）：\(requests.count)处锚点请求、\(mentions.count)条提及、\(layers.count)层释义/译文、\(alignments.count)组资料对齐；宿主原文锚点已核验，AI内容仍待核对。锚点别名对应：\(anchorMap)"
    }

    /// All native plugins obey the same write boundary, including future ones.
    /// AI appends immutable records; explicit user editing/deletion is a separate host action.
    public static func validateTransition(from old: ReadingExperienceState?, to new: ReadingExperienceState?, allowedUnitIDs: Set<String>, in project: BookProject) throws {
        guard let new else { throw ReadingError.invalid("AI插件不能删除整套阅读增强记录。") }
        let old = old ?? ReadingExperienceState()
        guard old.trash == new.trash else { throw ReadingError.invalid("AI 插件不能更改用户的伴读回收站。") }
        guard old.decisions == new.decisions else { throw ReadingError.invalid("思考卡能力已停用，插件不能追加或改写历史思考卡。") }
        try retained(old.anchors, in: new.anchors, id: { $0.id })
        try retained(old.mentions, in: new.mentions, id: { $0.id })
        try retained(old.layers, in: new.layers, id: { $0.id })
        try retained(old.alignments, in: new.alignments, id: { $0.id })
        try retained(old.decisions, in: new.decisions, id: { $0.id })
        try ReadingLedger.requireComplete(unitIDs: allowedUnitIDs, in: project)
        let oldAnchorIDs = Set(old.anchors.map(\.id))
        for anchor in new.anchors where !oldAnchorIDs.contains(anchor.id) {
            guard allowedUnitIDs.contains(anchor.unitID) else { throw ReadingError.invalid("插件新增锚点不属于本次已获准原文。") }
        }
        let current = Set(new.anchors.filter { allowedUnitIDs.contains($0.unitID) }.map(\.id))
        let oldMentions = Set(old.mentions.map(\.id))
        guard new.mentions.filter({ !oldMentions.contains($0.id) }).allSatisfy({ current.contains($0.anchorID) }) else {
            throw ReadingError.invalid("新增词语提及必须锚定当前获准原文。")
        }
        try checkCurrent(new.layers, old: old.layers, ids: { $0.sourceAnchorIDs }, id: { $0.id }, current: current)
        try checkCurrent(new.alignments, old: old.alignments, ids: { $0.sourceAnchorIDs }, id: { $0.id }, current: current)
        try checkCurrent(new.decisions, old: old.decisions, ids: { $0.sourceAnchorIDs }, id: { $0.id }, current: current)
        try ReadingExperienceRuntime.validate(new, in: project)
    }

    private static func checkCurrent<T>(_ values: [T], old: [T], ids: (T) -> [String], id: (T) -> String, current: Set<String>) throws {
        let oldIDs = Set(old.map(id))
        guard values.filter({ !oldIDs.contains(id($0)) }).allSatisfy({ !current.isDisjoint(with: ids($0)) }) else {
            throw ReadingError.invalid("新增阅读内容至少须引用当前获准原文中的一处锚点。")
        }
    }
    private static func append<T: Equatable>(_ value: T, to values: inout [T], validateID: Bool = true, id: (T) -> String) throws {
        if validateID { try identifier(id(value)) }
        if let old = values.first(where: { id($0) == id(value) }) {
            guard old == value else { throw ReadingError.invalid("阅读内容ID已有不同记录；不会静默覆盖：\(id(value))") }
        } else { values.append(value) }
    }
    private static func retained<T: Equatable>(_ old: [T], in new: [T], id: (T) -> String) throws {
        let next = Dictionary(new.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        guard old.allSatisfy({ next[id($0)] == $0 }) else { throw ReadingError.invalid("AI插件不能删除或覆盖已保存的阅读内容。") }
    }
    private static func identifier(_ value: String) throws {
        guard value != ".", value != "..", value.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil else {
            throw ReadingError.invalid("阅读内容ID须为1–128位ASCII字母数字._-。")
        }
    }
    private static func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "additionalProperties": false, "properties": properties, "required": required]
    }
    private static func list(_ item: [String: Any], minimum: Int = 0, maximum: Int) -> [String: Any] {
        ["type": "array", "items": item, "minItems": minimum, "maxItems": maximum]
    }
}
