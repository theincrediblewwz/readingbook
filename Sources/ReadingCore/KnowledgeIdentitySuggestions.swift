import Foundation

/// Suggestions help the model look up a stable ID. Similar spelling is never
/// sufficient authority to merge people or to attach another person's facts.
public struct KnowledgeIdentitySuggestion: Codable, Hashable, Sendable {
    public var id: String
    public var typeID: String
    public var kind: String
    public var name: String
    public var match: String
    public var requiresConfirmation = true
}

public enum KnowledgeIdentitySuggestions {
    public static func find(_ query: String, in project: BookProject, allowedUnitIDs: Set<String>?,
                            typeIDs: Set<String> = [], limit: Int = 8) -> [KnowledgeIdentitySuggestion] {
        guard !query.isEmpty, query.utf8.count <= 1600 else { return [] }
        let wanted = normalized(query)
        guard !wanted.isEmpty else { return [] }
        let context = ReadingSpoilerProjection.Context(project: project, allowedUnitIDs: allowedUnitIDs)
        var matches: [(Int, KnowledgeIdentitySuggestion)] = []
        func rank(_ names: [String]) -> (Int, String)? {
            var best: (Int, String)?
            for name in names.prefix(65) {
                let candidate = normalized(name)
                let value: (Int, String)?
                if candidate == wanted { value = (0, "normalized_name") }
                else if min(candidate.count, wanted.count) >= 2 && (candidate.contains(wanted) || wanted.contains(candidate)) { value = (1, "partial_name") }
                else if min(candidate.count, wanted.count) >= 3, max(candidate.count, wanted.count) <= 24,
                        editDistance(candidate, wanted, maximum: 1) <= 1 { value = (2, "similar_name") }
                else { value = nil }
                if let value, best == nil || value.0 < best!.0 { best = value }
            }
            return best
        }
        for original in project.entities.prefix(20_000) where typeIDs.isEmpty || typeIDs.contains(original.typeID) {
            guard let entity = context.entity(original), let (score, match) = rank([entity.name] + entity.aliases),
                  entity.name != "本段关联对象" else { continue }
            matches.append((score, KnowledgeIdentitySuggestion(id: entity.id, typeID: entity.typeID, kind: "entity", name: entity.name, match: match)))
        }
        if typeIDs.isEmpty || typeIDs.contains("event") {
            for original in project.events.prefix(20_000) {
                guard let event = context.event(original), event.name != "本段关联事件", let (score, match) = rank([event.name]) else { continue }
                matches.append((score, KnowledgeIdentitySuggestion(id: event.id, typeID: "event", kind: "event", name: event.name, match: match)))
            }
        }
        return Array(matches.sorted { $0.0 == $1.0 ? $0.1.id < $1.1.id : $0.0 < $1.0 }.prefix(min(12, max(1, limit))).map(\.1))
    }

    private static func normalized(_ value: String) -> String {
        let folded = String(value.prefix(160)).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_Hans"))
        let simplified = folded.applyingTransform(StringTransform(rawValue: "Traditional-Simplified"), reverse: false) ?? folded
        return simplified.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) }
            .map(String.init).joined()
    }
    private static func editDistance(_ lhs: String, _ rhs: String, maximum: Int) -> Int {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= maximum else { return maximum + 1 }
        var previous = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var current = [i + 1]
            for (j, other) in b.enumerated() { current.append(min(min(current[j] + 1, previous[j + 1] + 1), previous[j] + (character == other ? 0 : 1))) }
            if (current.min() ?? maximum + 1) > maximum { return maximum + 1 }
            previous = current
        }
        return previous.last ?? maximum + 1
    }
}
