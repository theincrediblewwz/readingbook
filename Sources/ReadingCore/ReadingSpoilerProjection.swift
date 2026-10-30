import Foundation

/// A disposable reading view. Never save these redacted values over the user's
/// canonical objects; stable IDs remain available for navigation and editing.
public enum ReadingSpoilerProjection {
    public struct Context: Sendable {
        fileprivate let units: [String: SourceUnit]
        fileprivate let entities: [String: KnowledgeEntity]
        fileprivate let allowed: Set<String>?
        fileprivate let versions: ReadingKnowledgeRuntime.VersionContext
        public init(project: BookProject, allowedUnitIDs: Set<String>?) {
            units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            entities = Dictionary(project.entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            allowed = allowedUnitIDs
            versions = ReadingKnowledgeRuntime.VersionContext(project: project, allowed: allowedUnitIDs)
        }
        public func entity(_ value: KnowledgeEntity) -> KnowledgeEntity? { ReadingSpoilerProjection.entity(value, context: self) }
        public func event(_ value: KnowledgeEvent) -> KnowledgeEvent? { ReadingSpoilerProjection.event(value, context: self) }
        public func entitySnapshot(_ value: KnowledgeEntity) -> KnowledgeEntity? { ReadingSpoilerProjection.entity(value, context: self, usesSavedVersions: false) }
        public func eventSnapshot(_ value: KnowledgeEvent) -> KnowledgeEvent? { ReadingSpoilerProjection.event(value, context: self, usesSavedVersions: false) }
    }
    public static func entity(_ original: KnowledgeEntity, in project: BookProject, allowedUnitIDs: Set<String>?) -> KnowledgeEntity? {
        entity(original, context: Context(project: project, allowedUnitIDs: allowedUnitIDs))
    }
    private static func entity(_ canonical: KnowledgeEntity, context: Context, usesSavedVersions: Bool = true) -> KnowledgeEntity? {
        guard context.allowed != nil else { return canonical }
        let canonicalEvidence = evidence(canonical.evidence, context: context)
        guard !canonicalEvidence.isEmpty else { return nil }
        let completeCanonical = canonicalEvidence.count == canonical.evidence.count
        let original: KnowledgeEntity
        let local: [Evidence]
        if usesSavedVersions && !completeCanonical, let saved = context.versions.entity(canonical.id) {
            original = saved
            local = evidence(saved.evidence, context: context)
        } else {
            original = canonical
            local = canonicalEvidence
        }
        guard !local.isEmpty else { return nil }
        let names = ([original.name] + original.aliases).filter { name in
            !name.isEmpty && local.contains { exact(name, in: $0.quote) }
        }
        var result = original
        result.name = names.first ?? "本段关联对象"
        result.aliases = original.aliases.filter { names.contains($0) }
        result.evidence = local
        if local.count != original.evidence.count || !names.contains(original.name) {
            result.summary = ""; result.properties = [:]
            result.latitude = nil; result.longitude = nil; result.locationNote = nil
        }
        return result
    }

    public static func event(_ original: KnowledgeEvent, in project: BookProject, allowedUnitIDs: Set<String>?) -> KnowledgeEvent? {
        event(original, context: Context(project: project, allowedUnitIDs: allowedUnitIDs))
    }
    private static func event(_ canonical: KnowledgeEvent, context: Context, usesSavedVersions: Bool = true) -> KnowledgeEvent? {
        guard context.allowed != nil else { return canonical }
        let canonicalEvidence = evidence(canonical.evidence, context: context)
        guard !canonicalEvidence.isEmpty else { return nil }
        let completeCanonical = canonicalEvidence.count == canonical.evidence.count
        let original: KnowledgeEvent
        let local: [Evidence]
        if usesSavedVersions && !completeCanonical, let saved = context.versions.event(canonical.id) {
            original = saved
            local = evidence(saved.evidence, context: context)
        } else {
            original = canonical
            local = canonicalEvidence
        }
        guard !local.isEmpty else { return nil }
        var result = original
        let nameVisible = local.contains(where: { exact(original.name, in: $0.quote) })
        if !nameVisible { result.name = "本段关联事件" }
        result.evidence = local
        let complete = local.count == original.evidence.count
        if !complete || !nameVisible { result.summary = "" }
        let dateVisible = !original.dateText.isEmpty && local.contains { exact(original.dateText, in: $0.quote) }
        if !dateVisible { result.dateText = "时间待考" }
        if !complete || !dateVisible || original.startYear.map({ !exact(String($0), in: original.dateText) }) == true { result.startYear = nil }
        if !complete || !dateVisible || original.endYear.map({ !exact(String($0), in: original.dateText) }) == true { result.endYear = nil }
        func visibleIdentity(_ id: String) -> Bool {
            guard complete, let value = context.entities[id],
                  let projected = entity(value, context: context) else { return false }
            return projected.evidence.contains { source in ([value.name] + value.aliases).contains { exact($0, in: source.quote) } }
        }
        result.placeIDs = original.placeIDs.filter(visibleIdentity)
        result.participantIDs = original.participantIDs.filter(visibleIdentity)
        return result
    }

    private static func evidence(_ values: [Evidence], context: Context) -> [Evidence] {
        values.filter { item in
            context.allowed?.contains(item.unitID) == true && context.units[item.unitID].map { exact(item.quote, in: $0.text) } == true
        }
    }
    private static func exact(_ quote: String, in text: String) -> Bool {
        guard !quote.isEmpty, let range = text.range(of: quote, options: .literal) else { return false }
        return text[range].utf8.elementsEqual(quote.utf8)
    }
}
