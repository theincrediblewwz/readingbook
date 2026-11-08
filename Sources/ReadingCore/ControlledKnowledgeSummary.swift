import Foundation

/// Show changed knowledge fields, not pages of escaped provenance JSON.
enum ControlledKnowledgeSummary {
    private static func name(_ id: String, in project: BookProject) -> String {
        project.entities.first { $0.id == id }?.name ?? project.events.first { $0.id == id }?.name ?? "相关对象"
    }
    private static func sources(_ evidence: [Evidence], in project: BookProject) -> String {
        let units = Dictionary(project.units.map { ($0.id, $0.locator) }, uniquingKeysWith: { first, _ in first })
        let locations = Set(evidence.compactMap { units[$0.unitID] }).sorted()
        return "原文依据：\(evidence.count)处" + (locations.isEmpty ? "" : "（" + locations.joined(separator: "、") + "）")
    }
    static func relation(_ patch: ControlledRecordPatch, from before: BookProject, to after: BookProject) throws -> String {
        let decoder = JSONDecoder(), old = try patch.before.map { try decoder.decode(KnowledgeRelation.self, from: $0) }, new = try patch.after.map { try decoder.decode(KnowledgeRelation.self, from: $0) }
        func detail(_ relation: KnowledgeRelation, in project: BookProject) -> String {
            name(relation.fromID, in: project) + " —" + relation.label + "→ " + name(relation.toID, in: project)
        }
        guard let value = new ?? old else { throw ReadingError.invalid("关系审阅缺少内容。") }
        var lines = [(new == nil ? "移除关系：" : "关系：") + detail(value, in: new == nil ? before : after)]
        if let old, let new, old.fromID != new.fromID || old.toID != new.toID || old.label != new.label { lines.append("原关系：" + detail(old, in: before)) }
        if let new { lines.append(sources(new.evidence, in: after)) }
        return lines.joined(separator: "\n")
    }
    static func anchor(_ patch: ControlledRecordPatch, from before: BookProject, to after: BookProject) throws -> String {
        guard let data = patch.after ?? patch.before else { throw ReadingError.invalid("原文依据审阅缺少内容。") }
        let value = try JSONDecoder().decode(SourceAnchor.self, from: data), project = patch.after == nil ? before : after
        let location = project.units.first { $0.id == value.unitID }?.locator ?? "原文位置"
        let preview = value.quote.replacingOccurrences(of: "\n", with: " ")
        return (patch.after == nil ? "移除原文依据：" : "原文依据：") + location + "\n" + String(preview.prefix(180)) + (preview.count > 180 ? "…（全文保留在原书中）" : "")
    }
    static func event(_ patch: ControlledRecordPatch, from before: BookProject, to after: BookProject) throws -> String {
        let decoder = JSONDecoder(), old = try patch.before.map { try decoder.decode(KnowledgeEvent.self, from: $0) }, new = try patch.after.map { try decoder.decode(KnowledgeEvent.self, from: $0) }
        var lines = ["事件：" + (new?.name ?? old?.name ?? "事件")]
        if let change = textChange("名称", before: old?.name, after: new?.name) { lines.append(change) }
        if let change = textChange("内容", before: old?.summary, after: new?.summary) { lines.append(change) }
        if let change = textChange("时间说明", before: old?.dateText, after: new?.dateText) { lines.append(change) }
        if old?.startYear != new?.startYear || old?.endYear != new?.endYear {
            lines.append("年份：\(old?.startYear.map(String.init) ?? "未记录")—\(old?.endYear.map(String.init) ?? "未记录") → \(new?.startYear.map(String.init) ?? "未记录")—\(new?.endYear.map(String.init) ?? "未记录")")
        }
        if old?.placeIDs != new?.placeIDs, let new { lines.append("地点：" + new.placeIDs.map { name($0, in: after) }.joined(separator: "、")) }
        if old?.participantIDs != new?.participantIDs, let new { lines.append("参与者：" + new.participantIDs.map { name($0, in: after) }.joined(separator: "、")) }
        if let new { lines.append(sources(new.evidence, in: after)) }
        return lines.joined(separator: "\n\n")
    }
    static func entity(_ patch: ControlledRecordPatch, from before: BookProject, to after: BookProject) throws -> String {
        let decoder = JSONDecoder(), old = try patch.before.map { try decoder.decode(KnowledgeEntity.self, from: $0) }, new = try patch.after.map { try decoder.decode(KnowledgeEntity.self, from: $0) }
        var lines = ["资料：" + (new?.name ?? old?.name ?? "实体")]
        if old?.name != new?.name { lines.append("名称：\(old?.name ?? "无") → \(new?.name ?? "移除")") }
        if let change = textChange("简介", before: old?.summary, after: new?.summary) { lines.append(change) }
        if old?.aliases != new?.aliases {
            let previous = (old?.aliases ?? []).joined(separator: "、"), next = (new?.aliases ?? []).joined(separator: "、")
            lines.append("其他称呼：\(previous.isEmpty ? "无" : previous) → \(next.isEmpty ? "无" : next)")
        }
        let keys = Set((old?.properties ?? [:]).keys).union((new?.properties ?? [:]).keys).sorted()
        let typeID = new?.typeID ?? old?.typeID
        let fields = after.types.first { $0.id == typeID }?.fields ?? before.types.first { $0.id == typeID }?.fields ?? []
        for key in keys where old?.properties[key] != new?.properties[key] {
            lines.append("\(fields.first { $0.key == key }?.label ?? key)：\(old?.properties[key] ?? "未记录") → \(new?.properties[key] ?? "移除")")
        }
        func position(_ value: KnowledgeEntity?) -> String {
            guard let lat = value?.latitude, let lon = value?.longitude else { return "未记录" }
            return String(format: "%.5f, %.5f", lat, lon)
        }
        if old?.latitude != new?.latitude || old?.longitude != new?.longitude { lines.append("参考坐标（纬度、经度）：" + position(old) + " → " + position(new)) }
        if let change = textChange("位置说明", before: old?.locationNote, after: new?.locationNote) { lines.append(change) }
        if old?.evidence != new?.evidence {
            let units = Dictionary(after.units.map { ($0.id, $0.locator) }, uniquingKeysWith: { first, _ in first })
            let locations = Set((new?.evidence ?? []).compactMap { units[$0.unitID] }).sorted()
            lines.append("原文依据：\(old?.evidence.count ?? 0)处 → \(new?.evidence.count ?? 0)处" + (locations.isEmpty ? "" : "（" + locations.joined(separator: "、") + "）"))
        }
        return lines.joined(separator: "\n\n")
    }
    /// Existing descriptions are retained by additive writes; show only the added text once.
    private static func textChange(_ label: String, before: String?, after: String?) -> String? {
        guard before != after else { return nil }
        if let before, !before.isEmpty, let after, after.hasPrefix(before) {
            var addition = String(after.dropFirst(before.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            while addition == before || addition.hasPrefix(before + "\n") {
                addition = String(addition.dropFirst(before.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return addition.isEmpty ? nil : label + "补充：" + addition
        }
        guard let after, !after.isEmpty else { return label + "：移除已有内容" }
        guard let before, !before.isEmpty else { return label + "：" + after }
        return label + "：" + before + "\n→ " + after
    }
    static func spatial(_ patch: ControlledRecordPatch, from before: BookProject, to after: BookProject) throws -> String? {
        let decoder = JSONDecoder(), old = try patch.before.map { try decoder.decode(RelationTemporalMetadata.self, from: $0) }, new = try patch.after.map { try decoder.decode(RelationTemporalMetadata.self, from: $0) }
        guard let value = new ?? old, let spatial = value.spatial else { return nil }
        let project = new == nil ? before : after
        guard let relation = project.relations.first(where: { $0.id == value.relationID }) else { return nil }
        func name(_ id: String) -> String { project.entities.first { $0.id == id }?.name ?? project.events.first { $0.id == id }?.name ?? "相关对象" }
        var lines = ["地图行动：" + relation.label, "方向：" + ([relation.fromID] + spatial.viaPlaceIDs + [relation.toID]).map(name).joined(separator: " → ")]
        if !spatial.actorIDs.isEmpty { lines.append("参与者：" + spatial.actorIDs.map(name).joined(separator: "、")) }
        if let eventID = spatial.eventID { lines.append("对应事件：" + name(eventID)) }
        lines.append("时间：" + ControlledEventMetadataSummary.time(value.validity))
        lines.append(value.assertion == .explicit ? "行动依据：原文明说；连线是方向示意。" : "行动依据：推断或待核对；以虚线显示。")
        if value.validity.assertion == .inferred { lines.append("时间为推算：" + (value.validity.explanation ?? "待核对")) }
        if !value.explanation.isEmpty { lines.append("说明：" + value.explanation) }
        lines.append("原文依据：\(value.sourceAnchorIDs.count)处")
        return lines.joined(separator: "\n")
    }
}
