import Foundation

extension ReadingQuerySession {
    /// The global directory avoids querying every endpoint separately. Names
    /// come only from the already scoped project; excerpts stay opt-in.
    func relationDiscovery(_ value: TemporalRelationSnapshot, includeEvidence: Bool, names: [String: String]) throws -> [String: Any] {
        if includeEvidence { return try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:] }
        var compact = value
        let evidence = compact.relation.evidence
        compact.relation.evidence = []
        if var metadata = compact.metadata { metadata.explanation = ""; compact.metadata = metadata }
        var row = try JSONSerialization.jsonObject(with: JSONEncoder().encode(compact)) as? [String: Any] ?? [:]
        var relation = row["relation"] as? [String: Any] ?? [:]
        relation.removeValue(forKey: "evidence"); relation["evidenceOmitted"] = true
        relation["evidenceCount"] = evidence.count
        relation["sourceUnitIDs"] = Array(Set(evidence.map(\.unitID))).sorted()
        relation["fromName"] = names[value.relation.fromID]; relation["toName"] = names[value.relation.toID]
        row["relation"] = relation
        if value.metadata?.explanation.isEmpty == false { row["metadataExplanationOmitted"] = true }
        if let spatial = value.metadata?.spatial {
            row["actorNames"] = spatial.actorIDs.compactMap { names[$0] }
            row["eventName"] = spatial.eventID.flatMap { names[$0] }
        }
        return row
    }
    /// Discovery retains the canonical version, links and temporal semantics.
    /// Full evidence stays available explicitly; omitted text never grants a
    /// citation and is never removed from the shared project or its version.
    func eventDiscovery(_ value: TemporalEventSnapshot, includeEvidence: Bool) throws -> [String: Any] {
        if includeEvidence {
            var row = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]
            row["timeSummary"] = TemporalDatePresentation.summary(value.extent)
            return row
        }
        var compact = value
        let evidence = compact.object.evidence
        let fullSummary = compact.object.summary
        compact.object.evidence = []
        compact.object.summary = String(fullSummary.prefix(400))
        var row = try JSONSerialization.jsonObject(with: JSONEncoder().encode(compact)) as? [String: Any] ?? [:]
        var object = row["object"] as? [String: Any] ?? [:]
        object.removeValue(forKey: "evidence")
        object["evidenceOmitted"] = true
        object["evidenceCount"] = evidence.count
        object["sourceUnitIDs"] = Array(Set(evidence.map(\.unitID))).sorted()
        if compact.object.summary != fullSummary { object["summaryTruncated"] = true }
        // A stage used to repeat one identical extent four times. Keep one
        // complete value (including calendar/assertion/explanation) and name
        // the exact aliases; different factual/source extents stay separate.
        var sameAs = [String: String]()
        func identical(_ lhs: Any?, _ rhs: Any?) -> Bool {
            guard let lhs = lhs as? NSDictionary, let rhs = rhs as? NSDictionary else { return false }
            return lhs.isEqual(rhs)
        }
        if identical(object["temporalExtent"], row["extent"]) {
            object.removeValue(forKey: "temporalExtent"); sameAs["object.temporalExtent"] = "extent"
        }
        if identical(row["sourceExtent"], row["extent"]) {
            row.removeValue(forKey: "sourceExtent"); sameAs["sourceExtent"] = "extent"
        }
        if var metadata = row["metadata"] as? [String: Any] {
            if identical(metadata["extent"], row["extent"]) {
                metadata.removeValue(forKey: "extent"); sameAs["metadata.extent"] = "extent"
            }
            if let explanation = metadata["explanation"] as? String, !explanation.isEmpty {
                metadata.removeValue(forKey: "explanation"); row["metadataExplanationOmitted"] = true
            }
            row["metadata"] = metadata
        }
        if !sameAs.isEmpty { row["sameAs"] = sameAs }
        row["object"] = object
        row["timeSummary"] = TemporalDatePresentation.summary(value.extent)
        return row
    }
}
