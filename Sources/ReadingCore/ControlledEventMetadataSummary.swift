import Foundation

enum ControlledEventMetadataSummary {
    static func describe(_ patch: ControlledRecordPatch, from before: BookProject, to after: BookProject) throws -> String {
        let decoder = JSONDecoder()
        let old = try patch.before.map { try decoder.decode(EventTemporalMetadata.self, from: $0) }
        let new = try patch.after.map { try decoder.decode(EventTemporalMetadata.self, from: $0) }
        func eventName(_ id: String?, in project: BookProject) -> String {
            guard let id else { return "无" }
            return project.events.first { $0.id == id }?.name ?? "原事件"
        }
        func typeName(_ id: String?, in project: BookProject) -> String {
            guard let id else { return "未指定" }
            return project.types.first { $0.id == id }?.name ?? "原类型"
        }
        func classification(_ value: String?) -> String { value == "event" ? "通用事件" : value ?? "未指定" }
        func assertion(_ value: KnowledgeAssertion?) -> String {
            switch value { case .explicit: return "原文明说"; case .inferred: return "推断"; case .unknown, nil: return "待核对" }
        }
        var lines = ["事件：" + eventName(patch.id, in: after.events.contains { $0.id == patch.id } ? after : before)]
        if old?.extent != new?.extent {
            lines.append("时间：\(time(old?.extent)) → \(time(new?.extent))")
            if let text = new?.extent?.sourceText, !text.isEmpty { lines.append("时间依据原句：" + text) }
        }
        if old?.typeID != new?.typeID { lines.append("类型：\(typeName(old?.typeID, in: before)) → \(typeName(new?.typeID, in: after))") }
        if old?.kind != new?.kind { lines.append("分类：\(classification(old?.kind)) → \(classification(new?.kind))") }
        if old?.parentEventID != new?.parentEventID { lines.append("所属事件：\(eventName(old?.parentEventID, in: before)) → \(eventName(new?.parentEventID, in: after))") }
        if old?.phaseOrder != new?.phaseOrder { lines.append("阶段顺序：\(old?.phaseOrder.map(String.init) ?? "未指定") → \(new?.phaseOrder.map(String.init) ?? "未指定")") }
        lines.append("提案依据标记：" + (old?.assertion == new?.assertion ? assertion(new?.assertion) : assertion(old?.assertion) + " → " + assertion(new?.assertion)))
        if old?.sourceAnchorIDs != new?.sourceAnchorIDs {
            let anchors = Dictionary(((after.readingExperience?.anchors ?? []) + (after.temporalKnowledge?.anchors ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let units = Dictionary(after.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let locations = Set((new?.sourceAnchorIDs ?? []).compactMap { anchors[$0] }.compactMap { units[$0.unitID] }.map { $0.page.map { "第\($0)页" } ?? $0.chapter }).sorted()
            lines.append("原文依据：\(old?.sourceAnchorIDs.count ?? 0)处 → \(new?.sourceAnchorIDs.count ?? 0)处" + (locations.isEmpty ? "" : "（" + locations.joined(separator: "、") + "）"))
        }
        if let text = new?.explanation, text != old?.explanation, !text.isEmpty {
            let prefix = (old?.explanation ?? "") + "\n\n"
            lines.append("补充说明：" + (!prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text))
        }
        return lines.joined(separator: "\n")
    }
    private static func time(_ value: TemporalExtent?) -> String {
        guard let value else { return "未记录" }
        let certainty: String
        switch value.uncertainty { case .exact: certainty = "明确"; case .approximate: certainty = "约"; case .disputed: certainty = "有争议"; case .unknown: certainty = "确定性未注明" }
        if value.precision == .narrative, let start = value.narrativeStart {
            return "原文顺序\(start)" + (value.narrativeEnd.flatMap { $0 != start ? "—\($0)" : nil } ?? "") + "（\(certainty)）"
        }
        func date(_ value: TemporalDate?) -> String? { value.map { "\($0.year)年" + ($0.month.map { "\($0)月" } ?? "") + ($0.day.map { "\($0)日" } ?? "") } }
        let calendar = value.calendar == "gregorian" ? "公历" : value.calendar ?? ""
        guard let start = date(value.start) else { return date(value.end).map { "截至\(calendar)\($0)（\(certainty)）" } ?? "时间待考" }
        return calendar + start + (date(value.end).flatMap { $0 != start ? "—" + $0 : nil } ?? "") + "（\(certainty)）"
    }
}
