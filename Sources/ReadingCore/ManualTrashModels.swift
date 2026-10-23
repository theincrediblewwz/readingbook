import Foundation

public enum ManualTrashKind: String, Codable, CaseIterable, Sendable {
    case entity, event, relation, node, edge, view
}
public struct ManualTrashState: Codable, Sendable {
    public var version: Int = 1
    /// Kept after the last restore so a stale window cannot pass an ABA check.
    public var revision: Int = 0
    public var items: [ManualTrashItem] = []
    public init() {}
}
public struct ManualTrashItem: Codable, Identifiable, Sendable {
    public var id: String
    public var kind: ManualTrashKind
    public var rootID: String
    public var title: String
    public var deletedAt: Date
    public var sourceHash: String
    public var unitHashes: [String: String]
    public var patches: [ManualTrashPatch]
    public var dependencies: [ManualTrashReference]
    public var supportingTypes: [EntityType]
}
public enum ManualTrashCollection: String, Codable, CaseIterable, Sendable {
    case entities, events, relations, nodes, edges, views, documents, graphGroups
    case temporalAnchors, presences, participations, eventMetadata, relationMetadata, experienceAnchors, mentions
}
public struct ManualTrashPatch: Codable, Sendable {
    public var collection: ManualTrashCollection
    public var id: String
    public var before: Data
    /// nil means the record was removed; otherwise only changed fields are reversed.
    public var after: Data?
}
public struct ManualTrashReference: Codable, Hashable, Sendable {
    public var collection: ManualTrashCollection
    public var id: String
}
public struct ManualTrashRestorePlan: Sendable {
    public var itemIDs: [String]
    public var items: [ManualTrashItem]
    public var titles: [String] { items.map(\.title) }
    public var conflicts: [String]
}
