import Foundation

/// Show changed knowledge fields, not pages of escaped provenance JSON.
enum ControlledKnowledgeSummary {
    static func entity(_ patch: ControlledRecordPatch, from before: BookProject, to after: BookProject) throws -> String {
        let decoder = JSONDecoder(), old = try patch.before.map { try decoder.decode(KnowledgeEntity.self, from: $0) }, new = try patch.after.map { try decoder.decode(KnowledgeEntity.self, from: $0) }
        var lines = ["资料：" + (new?.name ?? old?.name ?? "实体")]
        if old?.name != new?.name { lines.append("名称：\(old?.name ?? "无") → \(new?.name ?? "移除")") }
        if old?.summary != new?.summary { lines.append("简介：\(old?.summary ?? "未记录")\n→ \(new?.summary ?? "移除")") }
        if old?.aliases != new?.aliases { lines.append("其他称呼：\((old?.aliases ?? []).joined(separator: "、")) → \((new?.aliases ?? []).joined(separator: "、"))") }
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
        if old?.locationNote != new?.locationNote { lines.append("位置说明：\(old?.locationNote ?? "未记录")\n→ \(new?.locationNote ?? "移除")") }
        if old?.evidence != new?.evidence {
            let units = Dictionary(after.units.map { ($0.id, $0.locator) }, uniquingKeysWith: { first, _ in first })
            let locations = Set((new?.evidence ?? []).compactMap { units[$0.unitID] }).sorted()
            lines.append("原文依据：\(old?.evidence.count ?? 0)处 → \(new?.evidence.count ?? 0)处" + (locations.isEmpty ? "" : "（" + locations.joined(separator: "、") + "）"))
        }
        return lines.joined(separator: "\n")
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
