import Foundation

/// Shared by the plugin tool and the controlled book-scheme proposal. This is
/// deliberately a closed vocabulary, not a general purpose UI/program schema.
public enum CompositionSchema {
    public static var definition: [String: Any] {
        let id: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 128, "pattern": "^[A-Za-z0-9_.-]+$"]
        let text: [String: Any] = ["type": "string", "maxLength": 400]
        let filter = object(["field": ["type": "string", "maxLength": 140, "description": "name/summary/typeID/kind/origin/label，或properties.已声明字段key"],
            "operation": enumeration(["equals", "contains", "oneOf", "exists"]), "value": ["type": "string", "maxLength": 1000],
            "values": array(["type": "string", "maxLength": 1000], maximum: 16)], required: ["field", "operation"])
        let traversal = object(["labels": array(["type": "string", "minLength": 1, "maxLength": 400], maximum: 16),
            "direction": enumeration(CompositionTraversalDirection.allCases.map(\.rawValue)),
            "depth": ["type": "integer", "minimum": 1, "maximum": 4], "maxNodes": ["type": "integer", "minimum": 1, "maximum": 200],
            "maxEdges": ["type": "integer", "minimum": 1, "maximum": 800]], required: [])
        let column = object(["field": ["type": "string", "minLength": 1, "maxLength": 140,
            "description": "name/summary/kind/typeID/origin，或当前单一类型声明的properties.key；事件可读取properties.dateText/kind/phaseOrder。name覆盖固定对象列标题。"],
            "title": ["type": "string", "minLength": 1, "maxLength": 400]], required: ["field"])
        let source = object(["id": id, "collection": enumeration(CompositionCollection.allCases.map(\.rawValue)),
            "scope": enumeration(["current", "book"]), "typeIDs": array(id, maximum: 32), "selectionGroup": id, "timeGroup": id,
            "relation": enumeration(["none", "selected", "neighbors", "participants", "places", "events", "documents"]),
            "filters": array(filter, maximum: 8), "sort": enumeration(["name", "sourceOrder", "time"]),
            "limit": ["type": "integer", "minimum": 1, "maximum": 200],
            "traversal": traversal.merging(["description": "仅relation=neighbors可用。按已保存关系名称和方向展开，先遵守来源与时间范围；省略沿用旧一跳。类型和属性筛选只限制结果，隐藏中间对象不生成跨节点直连。"], uniquingKeysWith: { _, new in new })], required: ["id", "collection"])
        let part = object(["id": id, "primitive": enumeration(CompositionPrimitive.allCases.map(\.rawValue)), "sourceID": id,
            "title": text, "selectionGroup": id, "timeGroup": id,
            "columns": array(column, minimum: 1, maximum: 8)], required: ["id", "primitive", "sourceID"])
        let node = object(["id": id, "kind": enumeration(["row", "column", "tabs", "overlay", "part"]), "children": array(id, maximum: 8),
            "partID": id, "fraction": ["type": "number", "minimum": 0.1, "maximum": 0.9],
            "dock": enumeration(FloatingPanelDock.allCases.map(\.rawValue))], required: ["id", "kind"])
        return object(["version": ["type": "integer", "enum": [1]], "sources": array(source, minimum: 1, maximum: 12),
            "parts": array(part, minimum: 1, maximum: 24), "layout": array(node, minimum: 1, maximum: 48), "rootID": id],
            required: ["sources", "parts", "layout", "rootID"])
    }
    private static func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    private static func array(_ items: [String: Any], minimum: Int = 0, maximum: Int) -> [String: Any] {
        ["type": "array", "items": items, "minItems": minimum, "maxItems": maximum]
    }
    private static func enumeration(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
}
