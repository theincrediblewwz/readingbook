import Foundation

public struct CompositionRepairIssue: Codable, Sendable {
    public var path: String
    public var reason: String
}

/// A failed declaration remains a declaration: no layout is silently guessed,
/// no shared facts are changed, and independent errors can be fixed together.
public struct ReadingCompositionError: Error, LocalizedError, Sendable {
    public var issues: [CompositionRepairIssue]
    public var errorDescription: String? { "组合布局有字段需要修正；没有新建、覆盖或打开这个组件。" }
}

extension CompositionRuntime {
    static func repairIssues(_ value: CompositionDefinition) -> [CompositionRepairIssue] {
        var result: [CompositionRepairIssue] = []
        func issue(_ path: String, _ reason: String) {
            if result.count < 32 { result.append(.init(path: path, reason: reason)) }
        }
        let sources = Dictionary(uniqueKeysWithValues: value.sources.map { ($0.id, $0) })
        let layouts = Dictionary(uniqueKeysWithValues: value.layout.map { ($0.id, $0) })
        let partIDs = Set(value.parts.map(\.id))
        var visiblePartIDs = Set<String>(), visited = Set<String>()
        func visible(_ id: String) {
            guard visited.insert(id).inserted, let node = layouts[id], node.presentation != .contextual else { return }
            if node.kind == .part { if let id = node.partID { visiblePartIDs.insert(id) } }
            else { node.children.forEach(visible) }
        }
        visible(value.rootID)
        let selectors: Set<CompositionPrimitive> = [.map, .timeline, .objectList, .table, .relations, .documentGraph]
        let selectableGroups = Set(value.parts.filter { visiblePartIDs.contains($0.id) && selectors.contains($0.primitive) }.map(\.selectionGroup))
        for (index, part) in value.parts.enumerated() {
            guard let source = sources[part.sourceID] else { issue("parts[\(index)].sourceID", "必须引用sources中的id：\(part.sourceID)不存在。"); continue }
            if part.selectionGroup != source.selectionGroup { issue("parts[\(index)].selectionGroup", "必须与数据源\(source.id)相同：\(source.selectionGroup)。省略时默认main。"); }
            if part.timeGroup != source.timeGroup { issue("parts[\(index)].timeGroup", "必须与数据源\(source.id)相同：\(source.timeGroup)。省略时默认main。"); }
            if let id = part.routeSourceID {
                if part.primitive != .map { issue("parts[\(index)].routeSourceID", "只有geo.map可另选行动关系数据源。"); }
                else if let routes = sources[id], routes.collection == .relations {
                    if routes.selectionGroup != part.selectionGroup { issue("parts[\(index)].routeSourceID", "行动数据源\(id)须与地图共用selectionGroup：\(part.selectionGroup)。"); }
                    if routes.timeGroup != part.timeGroup { issue("parts[\(index)].routeSourceID", "行动数据源\(id)须与地图共用timeGroup：\(part.timeGroup)，才能同步筛选。"); }
                } else { issue("parts[\(index)].routeSourceID", "须引用sources中collection=relations的数据源；它只投影已有行动，不创建事件归属。"); }
            }
            if part.columns != nil && part.primitive != .table { issue("parts[\(index)].columns", "columns仅适用于object.table；其他元件请移除此字段。"); }
            if !value.layout.contains(where: { $0.kind == .part && $0.partID == part.id }) { issue("parts[\(index)].id", "元件\(part.id)缺少布局位置。请添加kind=part、partID=\(part.id)的layout节点，并在父容器children引用该节点id。"); }
        }
        for (index, source) in value.sources.enumerated() where !value.parts.contains(where: { $0.sourceID == source.id || $0.routeSourceID == source.id }) {
            issue("sources[\(index)]", "数据源\(source.id)没有元件使用；移除此数据源或为它添加元件。");
        }
        if layouts[value.rootID] == nil { issue("rootID", "必须指向layout中的节点id：\(value.rootID)不存在。"); }
        for (index, node) in value.layout.enumerated() {
            if node.presentation == .contextual {
                let groups = Set(value.parts(inLayout: node.id).map(\.selectionGroup))
                for group in groups.sorted() where !selectableGroups.contains(group) {
                    issue("layout[\(index)].presentation", "情境卡片依赖选择组\(group)，但没有常驻的地图、时间轴、列表或图表能向该组发送选择。请与要联动的元件共用selectionGroup（现有选择组：\(selectableGroups.sorted().joined(separator: "、"))），或改为docked常驻。")
                }
            }
            if node.kind == .part {
                if node.partID.map({ !partIDs.contains($0) }) ?? true { issue("layout[\(index)].partID", "kind=part必须用partID引用parts.id。"); }
            } else {
                for (offset, child) in node.children.enumerated() where layouts[child] == nil {
                    issue("layout[\(index)].children[\(offset)]", "children引用layout.id，不是parts.id。\(child)没有对应布局节点；请引用或创建包含partID的布局节点。");
                }
            }
        }
        return result
    }
}
