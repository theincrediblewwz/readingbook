import Foundation

/// Derived from the accepted host state transition, never the model's claim.
enum AIToolResultDetails {
    static func describe(before: BookProject, after: BookProject, name: String) -> [String] {
        func changed<T: Encodable>(_ old: [T], _ new: [T], id: (T) -> String, title: (T) -> String) -> [String] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let prior = Dictionary(uniqueKeysWithValues: old.map { (id($0), $0) })
            return Array(new.lazy.filter { item in
                guard let previous = prior[id(item)] else { return true }
                return (try? encoder.encode(previous)) != (try? encoder.encode(item))
            }.prefix(20).map { "\(prior[id($0)] == nil ? "新增" : "更新")：\(title($0))" })
        }
        switch name {
        case "views_configure": return changed(before.views, after.views, id: { $0.id }, title: { $0.title + "（" + $0.kind.title + "）" })
        case "cards_upsert": return changed(before.entities, after.entities, id: { $0.id }, title: { $0.name })
        case "events_upsert": return changed(before.events, after.events, id: { $0.id }, title: { $0.name })
        case "methods_define": return changed(before.methods, after.methods, id: { $0.id }, title: { $0.name })
        case "reading_plan": return ["阅读方法：" + (after.plan?.methodIDs.compactMap { id in after.methods.first { $0.id == id }?.name }.joined(separator: "、") ?? "")]
        case "reading_enrich":
            let old = Set(before.readingExperience?.layers.map(\.id) ?? [])
            return Array((after.readingExperience?.layers ?? []).filter { !old.contains($0.id) }.prefix(20).map { "新增伴读：" + $0.title })
        default: return []
        }
    }
}
