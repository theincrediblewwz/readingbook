import Foundation

/// Unit IDs remain canonical. A worker authorized for half of a shared unit
/// must prove its new facts and exact anchors within that half before publish.
enum AnalysisSourceGuard {
    static var currentRanges: [ReadingSourceRange]? {
        ReadingAnalysisAuthority.current?.chunk.sourceRanges ?? ReadingEnrichmentAuthority.current?.ranges
    }
    static func validate(arguments: Data, before: BookProject, after: BookProject) throws {
        guard currentRanges != nil else { return }
        func require(_ condition: Bool) throws {
            guard condition else { throw ReadingError.invalid("新增内容超出本次章节片段；已有内容保留。") }
        }
        func inspect(_ value: Any, depth: Int) throws {
            try Task.checkCancellation()
            try require(depth <= 64)
            if let object = value as? [String: Any] {
                if let unitID = object["unitID"] as? String, let quote = object["quote"] as? String {
                    try require(SmartReadingRuntime.analysisEvidenceAdmitted(Evidence(unitID: unitID, quote: quote), in: before))
                }
                for child in object.values { try inspect(child, depth: depth + 1) }
            } else if let values = value as? [Any] {
                for child in values { try inspect(child, depth: depth + 1) }
            }
        }
        try inspect(JSONSerialization.jsonObject(with: arguments), depth: 0)
        func evidence(_ next: [Evidence], previous: [Evidence]) throws {
            try require(next.contains { SmartReadingRuntime.analysisEvidenceAdmitted($0, in: before) })
            for value in next where !previous.contains(value) {
                try require(SmartReadingRuntime.analysisEvidenceAdmitted(value, in: before))
            }
        }
        let entities = Dictionary(before.entities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for value in after.entities where entities[value.id] != value {
            try evidence(value.evidence, previous: entities[value.id]?.evidence ?? [])
        }
        let events = Dictionary(before.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for value in after.events where events[value.id] != value {
            try evidence(value.evidence, previous: events[value.id]?.evidence ?? [])
        }
        let relations = Dictionary(before.relations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for value in after.relations where relations[value.id] != value {
            try evidence(value.evidence, previous: relations[value.id]?.evidence ?? [])
        }
        let priorAnchors = Set((before.readingExperience?.anchors ?? []).map(\.id))
        for anchor in after.readingExperience?.anchors ?? [] where !priorAnchors.contains(anchor.id) {
            try require(SmartReadingRuntime.analysisAnchorAdmitted(anchor, in: after))
        }
        let allAnchors = Dictionary((after.readingExperience?.anchors ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func anchors(_ ids: [String]) throws {
            try require(!ids.isEmpty)
            for id in ids { try require(allAnchors[id].map { SmartReadingRuntime.analysisAnchorAdmitted($0, in: after) } ?? false) }
        }
        let oldLayers = Set((before.readingExperience?.layers ?? []).map(\.id))
        for layer in after.readingExperience?.layers ?? [] where !oldLayers.contains(layer.id) { try anchors(layer.sourceAnchorIDs) }
        let oldMentions = Set((before.readingExperience?.mentions ?? []).map(\.id))
        for mention in after.readingExperience?.mentions ?? [] where !oldMentions.contains(mention.id) { try anchors([mention.anchorID]) }
        let oldAlignments = Set((before.readingExperience?.alignments ?? []).map(\.id))
        for alignment in after.readingExperience?.alignments ?? [] where !oldAlignments.contains(alignment.id) { try anchors(alignment.sourceAnchorIDs) }
        let oldTemporalAnchors = Set((before.temporalKnowledge?.anchors ?? []).map(\.id))
        for anchor in after.temporalKnowledge?.anchors ?? [] where !oldTemporalAnchors.contains(anchor.id) {
            try require(SmartReadingRuntime.analysisAnchorAdmitted(anchor, in: after))
        }
        let temporalAnchors = Dictionary((after.temporalKnowledge?.anchors ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func temporal(_ ids: [String]) throws {
            try require(!ids.isEmpty)
            for id in ids { try require((temporalAnchors[id] ?? allAnchors[id]).map { SmartReadingRuntime.analysisAnchorAdmitted($0, in: after) } ?? false) }
        }
        for value in after.temporalKnowledge?.presences ?? [] where !(before.temporalKnowledge?.presences.contains(value) ?? false) { try temporal(value.sourceAnchorIDs) }
        for value in after.temporalKnowledge?.participations ?? [] where !(before.temporalKnowledge?.participations.contains(value) ?? false) { try temporal(value.sourceAnchorIDs) }
        for value in after.temporalKnowledge?.eventMetadata ?? [] where !(before.temporalKnowledge?.eventMetadata.contains(value) ?? false) { try temporal(value.sourceAnchorIDs) }
        for value in after.temporalKnowledge?.relationMetadata ?? [] where !(before.temporalKnowledge?.relationMetadata.contains(value) ?? false) { try temporal(value.sourceAnchorIDs) }
    }

    /// A saved summary learned later on the same physical unit must not leak
    /// through the historical-knowledge reuse path at a chapter boundary.
    static func permitsKnowledge(_ evidence: [Evidence], in project: BookProject) -> Bool {
        guard let ranges = currentRanges else { return true }
        let unitIDs = Set(ranges.map(\.unitID))
        return evidence.allSatisfy { !unitIDs.contains($0.unitID) || SmartReadingRuntime.analysisEvidenceAdmitted($0, in: project) }
    }
}
