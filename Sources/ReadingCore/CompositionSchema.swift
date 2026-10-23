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
        let source = object(["id": id, "collection": enumeration(CompositionCollection.allCases.map(\.rawValue)),
            "scope": enumeration(["current", "book"]), "typeIDs": array(id, maximum: 32), "selectionGroup": id, "timeGroup": id,
            "relation": enumeration(["none", "selected", "neighbors", "participants", "places", "events", "documents"]),
            "filters": array(filter, maximum: 8), "sort": enumeration(["name", "sourceOrder", "time"]),
            "limit": ["type": "integer", "minimum": 1, "maximum": 200]], required: ["id", "collection"])
        let part = object(["id": id, "primitive": enumeration(CompositionPrimitive.allCases.map(\.rawValue)), "sourceID": id,
            "title": text, "selectionGroup": id, "timeGroup": id], required: ["id", "primitive", "sourceID"])
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
