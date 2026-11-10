import Foundation

/// Shared by the plugin tool and the controlled book-scheme proposal. This is
/// deliberately a closed vocabulary, not a general purpose UI/program schema.
public enum CompositionSchema {
    public static var definition: [String: Any] {
        let id: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 128, "pattern": "^[A-Za-z0-9_.-]+$"]
        let text: [String: Any] = ["type": "string", "maxLength": 400]
        let filter = object(["field": ["type": "string", "maxLength": 140, "description": "name/summary/typeID/origin/label；kind仅entity/event/document/evidence；parentEventID筛父事件的阶段；properties.声明字段，events还可用properties.dateText/kind/phaseOrder。"],
            "operation": enumeration(["equals", "contains", "oneOf", "exists"]), "value": ["type": "string", "maxLength": 1000],
            "values": array(["type": "string", "maxLength": 1000], maximum: 16)], required: ["field", "operation"])
        let traversal = object(["labels": array(["type": "string", "minLength": 1, "maxLength": 400], maximum: 16),
            "direction": enumeration(CompositionTraversalDirection.allCases.map(\.rawValue)),
            "depth": ["type": "integer", "minimum": 1, "maximum": 4], "maxNodes": ["type": "integer", "minimum": 1, "maximum": 200],
            "maxEdges": ["type": "integer", "minimum": 1, "maximum": 800]], required: [])
        let column = object(["field": ["type": "string", "minLength": 1, "maxLength": 140,
            "description": "name/summary/kind/typeID/origin，或当前单一类型声明的properties.key；事件可读取properties.dateText/kind/phaseOrder，不必重复指定typeIDs。name覆盖固定对象列标题。"],
            "title": ["type": "string", "minLength": 1, "maxLength": 400]], required: ["field"])
        let source = object(["id": id, "collection": enumeration(CompositionCollection.allCases.map(\.rawValue)),
            "scope": enumeration(["current", "book"]), "typeIDs": array(id, maximum: 32), "selectionGroup": id, "timeGroup": id,
            "relation": enumeration(["none", "selected", "neighbors", "participants", "places", "events", "documents"]),
            "filters": array(filter, maximum: 8), "sort": enumeration(["name", "sourceOrder", "time"]),
            "limit": ["type": "integer", "minimum": 1, "maximum": 200],
            "traversal": traversal.merging(["description": "仅relation=neighbors可用。按已保存关系名称和方向展开，先遵守来源与时间范围；省略沿用旧一跳。类型和属性筛选只限制结果，隐藏中间对象不生成跨节点直连。"], uniquingKeysWith: { _, new in new })], required: ["id", "collection"])
        let part = object(["id": id, "primitive": enumeration(CompositionPrimitive.allCases.map(\.rawValue)).merging(["description": "object.detail含摘要、字段、原文依据及跳转；source.excerpt仅展示原文；选择联动的元件共用selectionGroup，时间筛选共用timeGroup。"], uniquingKeysWith: { _, new in new }), "sourceID": id,
            "title": text, "selectionGroup": id, "timeGroup": id,
            "columns": array(column, minimum: 1, maximum: 8),
            "routeSourceID": id.merging(["description": "geo.map可另绑定collection=relations的行动数据源，与地图共用selectionGroup/timeGroup；事件标记和行动路线独立取数，没有eventID的行动也可显示，不替它编造事件关联。省略只画主数据源相关路线。"], uniquingKeysWith: { _, next in next })], required: ["id", "primitive", "sourceID"])
        let node = object(["id": id, "kind": enumeration(["row", "column", "tabs", "overlay", "part"]).merging(["description": "overlay按children顺序叠放：首项为主画布，其后为浮动卡片；首项是geo.map时地图铺满可用空间。每个元件各有kind=part的布局节点，children引用layout.id，partID引用parts.id。"], uniquingKeysWith: { _, new in new }), "children": array(id, maximum: 8),
            "preferredHeight": ["type": "number", "minimum": 120, "maximum": 640, "description": "仅overlay浮卡的屏幕高度偏好；内容可滚动，省略按元件紧凑显示。"],
            "partID": id, "fraction": ["type": "number", "minimum": 0.1, "maximum": 0.9],
            "dock": enumeration(FloatingPanelDock.allCases.map(\.rawValue)),
            "presentation": enumeration(["docked", "contextual"]).merging(["description": "仅overlay浮层：docked常驻停靠，contextual在本层联动组选中对象时就近出现，点击画布空白收起；省略沿用常驻。fraction控制卡片宽度比例。"], uniquingKeysWith: { _, new in new })], required: ["id", "kind"])
        return object(["version": ["type": "integer", "enum": [1]], "sources": array(source, minimum: 1, maximum: 12),
            "parts": array(part, minimum: 1, maximum: 24), "layout": array(node, minimum: 1, maximum: 48), "rootID": id],
            required: ["sources", "parts", "layout", "rootID"])
            .merging(["description": "省略的selectionGroup/timeGroup沿用相连数据源与元件唯一明确的组；均未指定时用main，显式不同的组不会自动合并。"], uniquingKeysWith: { _, new in new })
    }
    private static func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    private static func array(_ items: [String: Any], minimum: Int = 0, maximum: Int) -> [String: Any] {
        ["type": "array", "items": items, "minItems": minimum, "maxItems": maximum]
    }
    private static func enumeration(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
}
