import Foundation

public enum CompositionCollection: String, Codable, CaseIterable, Sendable { case objects, events, relations, documents, evidence }
public enum CompositionScope: String, Codable, Hashable, Sendable { case current, book }
/// Host query policy only. A word used to locate an inline card need not narrow
/// its automatic component to that word; explicit selection queries stay exact.
public enum CompositionCurrentScope: Equatable, Sendable { case automatic, page, selection }
public enum CompositionMapTimeMode: String, CaseIterable, Hashable, Sendable { case instant, windowFootprints }
public enum CompositionSelectionRelation: String, Codable, Sendable { case none, selected, neighbors, participants, places, events, documents }
public enum CompositionSort: String, Codable, Sendable { case name, sourceOrder, time }
public enum CompositionFilterOperation: String, Codable, Sendable { case equals, contains, oneOf, exists }
public enum CompositionPrimitive: String, Codable, CaseIterable, Sendable {
    case objectList = "object.list", objectDetail = "object.detail", sourceExcerpt = "source.excerpt", markdown = "document.markdown"
    case map = "geo.map", timeline = "time.axis", relations = "relation.graph", documentGraph = "document.graph"
}
public enum CompositionLayoutKind: String, Codable, Sendable { case row, column, tabs, overlay, part }

public struct CompositionFilter: Codable, Hashable, Sendable {
    public var field: String
    public var operation: CompositionFilterOperation
    public var value: String?
    public var values: [String]?
    public init(field: String, operation: CompositionFilterOperation, value: String? = nil, values: [String]? = nil) {
        self.field = field; self.operation = operation; self.value = value; self.values = values
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case field, operation, value, values }
    public init(from decoder: Decoder) throws {
        try compositionKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decode(String.self, forKey: .field); operation = try c.decode(CompositionFilterOperation.self, forKey: .operation)
        value = try c.decodeIfPresent(String.self, forKey: .value); values = try c.decodeIfPresent([String].self, forKey: .values)
    }
}

public struct CompositionDataSource: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var collection: CompositionCollection
    public var scope: CompositionScope
    public var typeIDs: [String]
    public var selectionGroup: String
    public var timeGroup: String
    public var relation: CompositionSelectionRelation
    public var filters: [CompositionFilter]
    public var sort: CompositionSort
    public var limit: Int
    public init(id: String, collection: CompositionCollection, scope: CompositionScope = .current, typeIDs: [String] = [], selectionGroup: String = "main", timeGroup: String = "main", relation: CompositionSelectionRelation = .none, filters: [CompositionFilter] = [], sort: CompositionSort = .sourceOrder, limit: Int = 100) {
        self.id = id; self.collection = collection; self.scope = scope; self.typeIDs = typeIDs; self.selectionGroup = selectionGroup; self.timeGroup = timeGroup
        self.relation = relation; self.filters = filters; self.sort = sort; self.limit = limit
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case id, collection, scope, typeIDs, selectionGroup, timeGroup, relation, filters, sort, limit }
    public init(from decoder: Decoder) throws {
        try compositionKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); collection = try c.decode(CompositionCollection.self, forKey: .collection)
        scope = try c.decodeIfPresent(CompositionScope.self, forKey: .scope) ?? .current; typeIDs = try c.decodeIfPresent([String].self, forKey: .typeIDs) ?? []
        selectionGroup = try c.decodeIfPresent(String.self, forKey: .selectionGroup) ?? "main"; timeGroup = try c.decodeIfPresent(String.self, forKey: .timeGroup) ?? "main"
        relation = try c.decodeIfPresent(CompositionSelectionRelation.self, forKey: .relation) ?? .none; filters = try c.decodeIfPresent([CompositionFilter].self, forKey: .filters) ?? []
        sort = try c.decodeIfPresent(CompositionSort.self, forKey: .sort) ?? .sourceOrder; limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 100
    }
}

public struct CompositionPart: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var primitive: CompositionPrimitive
    public var sourceID: String
    public var title: String
    public var selectionGroup: String
    public var timeGroup: String
    public init(id: String, primitive: CompositionPrimitive, sourceID: String, title: String = "", selectionGroup: String = "main", timeGroup: String = "main") {
        self.id = id; self.primitive = primitive; self.sourceID = sourceID; self.title = title; self.selectionGroup = selectionGroup; self.timeGroup = timeGroup
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case id, primitive, sourceID, title, selectionGroup, timeGroup }
    public init(from decoder: Decoder) throws {
        try compositionKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); primitive = try c.decode(CompositionPrimitive.self, forKey: .primitive); sourceID = try c.decode(String.self, forKey: .sourceID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""; selectionGroup = try c.decodeIfPresent(String.self, forKey: .selectionGroup) ?? "main"
        timeGroup = try c.decodeIfPresent(String.self, forKey: .timeGroup) ?? "main"
    }
}

public struct CompositionLayoutNode: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: CompositionLayoutKind
    public var children: [String]
    public var partID: String?
    public var fraction: Double?
    public var dock: FloatingPanelDock?
    public init(id: String, kind: CompositionLayoutKind, children: [String] = [], partID: String? = nil, fraction: Double? = nil, dock: FloatingPanelDock? = nil) {
        self.id = id; self.kind = kind; self.children = children; self.partID = partID; self.fraction = fraction; self.dock = dock
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case id, kind, children, partID, fraction, dock }
    public init(from decoder: Decoder) throws {
        try compositionKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); kind = try c.decode(CompositionLayoutKind.self, forKey: .kind); children = try c.decodeIfPresent([String].self, forKey: .children) ?? []
        partID = try c.decodeIfPresent(String.self, forKey: .partID); fraction = try c.decodeIfPresent(Double.self, forKey: .fraction)
        if let raw = try c.decodeIfPresent(String.self, forKey: .dock) {
            guard let value = FloatingPanelDock(rawValue: raw) else { throw ReadingError.invalid("未知组合面板停靠位置。") }; dock = value
        } else { dock = nil }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(children, forKey: .children)
        try c.encodeIfPresent(partID, forKey: .partID); try c.encodeIfPresent(fraction, forKey: .fraction); try c.encodeIfPresent(dock?.rawValue, forKey: .dock)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.children == rhs.children && lhs.partID == rhs.partID && lhs.fraction == rhs.fraction && lhs.dock?.rawValue == rhs.dock?.rawValue
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(kind); hasher.combine(children); hasher.combine(partID); hasher.combine(fraction); hasher.combine(dock?.rawValue)
    }
}

/// Only references and presentation rules; no book facts, Markdown bodies or code.
public struct CompositionDefinition: Codable, Hashable, Sendable {
    public var version: Int
    public var sources: [CompositionDataSource]
    public var parts: [CompositionPart]
    public var layout: [CompositionLayoutNode]
    public var rootID: String
    public init(version: Int = 1, sources: [CompositionDataSource], parts: [CompositionPart], layout: [CompositionLayoutNode], rootID: String) {
        self.version = version; self.sources = sources; self.parts = parts; self.layout = layout; self.rootID = rootID
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case version, sources, parts, layout, rootID }
    public init(from decoder: Decoder) throws {
        try compositionKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1; sources = try c.decode([CompositionDataSource].self, forKey: .sources)
        parts = try c.decode([CompositionPart].self, forKey: .parts); layout = try c.decode([CompositionLayoutNode].self, forKey: .layout); rootID = try c.decode(String.self, forKey: .rootID)
    }
}

public struct CompositionItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var objectID: String?
    public var documentID: String?
    public var unitID: String?
    public var anchorID: String?
    public var title: String
    public var summary: String
    public var kind: String
    public var typeID: String?
    public var fields: [String: String]
    public var evidence: [Evidence]
    public var references: [String: [String]]
    public var latitude: Double?
    public var longitude: Double?
    public var extent: TemporalExtent?
    public var sourceOrder: Int?
}
public struct CompositionEdge: Identifiable, Hashable, Sendable {
    public var id: String; public var fromID: String; public var toID: String; public var label: String; public var kind: String
    public var temporalMatch: TemporalMatch? = nil
}
public struct CompositionMapPoint: Identifiable, Hashable, Sendable {
    public var id: String; public var targetID: String; public var title: String; public var subtitle: String
    public var latitude: Double; public var longitude: Double; public var evidence: [Evidence]; public var kind: String
}
public struct CompositionProjection: Sendable {
    public var items: [CompositionItem]; public var edges: [CompositionEdge]; public var mapPoints: [CompositionMapPoint]
    public var total: Int; public var partial: Bool; public var diagnostics: [String]
}

private struct CompositionKey: CodingKey {
    let stringValue: String; var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil }
}
private func compositionKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let c = try decoder.container(keyedBy: CompositionKey.self)
    guard Set(c.allKeys.map(\.stringValue)).isSubset(of: allowed) else { throw ReadingError.invalid("组合组件包含未实现的字段；不执行代码、路径或任意请求。") }
}
