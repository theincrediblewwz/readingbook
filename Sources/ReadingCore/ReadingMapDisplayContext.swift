import Foundation

/// A bounded directory over an already source-sliced project. No source text,
/// documents or coordinates are serialized, and no additional facts are read.
public struct ReadingMapKindCatalog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let kind: String
        public let eventCount: Int
        public let actionCount: Int
        public var count: Int { eventCount + actionCount }
    }
    public let entries: [Entry]
    public let totalKinds: Int
    public let totalRecords: Int
    public let omittedRecords: Int
    public var partial: Bool { entries.count != totalKinds || omittedRecords > 0 }
    private enum CodingKeys: String, CodingKey { case entries, totalKinds, totalRecords, omittedRecords, partial }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decode([Entry].self, forKey: .entries); totalKinds = try c.decode(Int.self, forKey: .totalKinds)
        totalRecords = try c.decode(Int.self, forKey: .totalRecords); omittedRecords = try c.decode(Int.self, forKey: .omittedRecords)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries, forKey: .entries); try c.encode(totalKinds, forKey: .totalKinds)
        try c.encode(totalRecords, forKey: .totalRecords); try c.encode(omittedRecords, forKey: .omittedRecords); try c.encode(partial, forKey: .partial)
    }
    private init(entries: [Entry], totalKinds: Int, totalRecords: Int, omittedRecords: Int) {
        self.entries = entries; self.totalKinds = totalKinds; self.totalRecords = totalRecords; self.omittedRecords = omittedRecords
    }
    public static func make(in scopedProject: BookProject, maximumKinds: Int = 32) throws -> Self {
        guard (1...32).contains(maximumKinds) else { throw ReadingError.invalid("地图类别目录每次提供1至32种。") }
        var eventKinds: [String: Int] = [:], actionKinds: [String: Int] = [:], totalRecords = 0, omitted = 0
        func admissible(_ kind: String) -> Bool {
            !kind.isEmpty && kind == kind.trimmingCharacters(in: .whitespacesAndNewlines) && kind.utf8.count <= 80
        }
        for row in try TemporalKnowledgeRuntime.events(in: scopedProject, boundary: .all) {
            try Task.checkCancellation(); totalRecords += 1
            let kind = row.metadata?.kind ?? "event"
            if admissible(kind) { eventKinds[kind, default: 0] += 1 } else { omitted += 1 }
        }
        for row in try TemporalKnowledgeRuntime.relations(in: scopedProject, boundary: .all) {
            try Task.checkCancellation()
            guard let spatial = row.metadata?.spatial else { continue }
            totalRecords += 1
            if admissible(spatial.kind) { actionKinds[spatial.kind, default: 0] += 1 } else { omitted += 1 }
        }
        // Asset choices are keyed by kind, not collection. Publish each key
        // once even when both events and actions use it.
        let sorted = Set(eventKinds.keys).union(actionKinds.keys).sorted().map {
            Entry(kind: $0, eventCount: eventKinds[$0, default: 0], actionCount: actionKinds[$0, default: 0])
        }
        return .init(entries: Array(sorted.prefix(maximumKinds)), totalKinds: sorted.count, totalRecords: totalRecords, omittedRecords: omitted)
    }
}

/// Route details reuse one configured contextual event card. Other groups,
/// docked panels and layouts without a suitable visible event card keep their
/// own behavior; the map can use its standalone fallback in those cases.
public enum CompositionRouteContext {
    public static func detailPartID(eventID: String?, mapPartID: String, definition: CompositionDefinition,
                                    projections: [String: CompositionProjection], selectedIDs: Set<String>,
                                    collapsed: Set<String> = []) -> String? {
        guard let eventID, selectedIDs.contains(eventID),
              let map = definition.parts.first(where: { $0.id == mapPartID && $0.primitive == .map }),
              definition.canvasMapPart?.id == mapPartID,
              let root = definition.layout.first(where: { $0.id == definition.rootID }) else { return nil }
        for id in root.children.dropFirst() {
            guard let node = definition.layout.first(where: { $0.id == id }), node.presentation == .contextual else { continue }
            for part in definition.parts(inLayout: id) where part.primitive == .objectDetail && part.selectionGroup == map.selectionGroup && !collapsed.contains(part.id) {
                if projections[part.sourceID]?.items.contains(where: { $0.kind == "event" && ($0.objectID ?? $0.id) == eventID }) == true { return part.id }
            }
        }
        return nil
    }
}
