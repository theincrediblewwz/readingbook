import Foundation

extension ReadingQuerySession {
    /// Small, read-only declarations already held by the host. This is built
    /// only for an explicitly authorized organizing question. It does not read
    /// private documents, grant citations, create objects or mark pages read.
    func organizationStartingPoint(maximumBytes: Int) throws -> String? {
        guard let project, proposalAccess != nil, maximumBytes >= 1200 else { return nil }
        var value: [String: Any] = ["scope": snapshot.displayTitle, "sourceUnitCount": snapshot.sources.count,
            "bodyProvided": false, "indexIsNotEvidence": true,
            "firstLocator": snapshot.sources.first?.locator ?? "", "lastLocator": snapshot.sources.last?.locator ?? "",
            "types": project.types.prefix(24).map { ["id": $0.id, "name": String($0.name.prefix(100))] },
            "typesPartial": project.types.count > 24,
            "writes": "host_controlled_proposals", "referenceGuide": ReadingProposalSchemas.referenceGuide(in: project)]
        var status: [String: Int] = [:]
        for id in snapshot.unitIDs { try Task.checkCancellation(); status[project.coverage[id]?.status.rawValue ?? "pending", default: 0] += 1 }
        value["coverageCounts"] = status
        // Existence here is only scoped identity, never an unread description
        // or permission to overwrite an old user correction.
        let local = project.entities.isEmpty && project.events.isEmpty ? nil : scopedKnowledgeProject()
        let objectCount = (local?.entities.count ?? 0) + (local?.events.count ?? 0)
        let entities = Array((local?.entities ?? []).prefix(12))
        let objects = entities.map { ["id": $0.id, "name": String($0.name.prefix(100)), "kind": "entity"] }
            + (local?.events ?? []).prefix(12 - entities.count).map { ["id": $0.id, "name": String($0.name.prefix(100)), "kind": "event"] }
        value["savedObjects"] = objects; value["savedObjectsPartial"] = objectCount > objects.count
        value["otherSavedObjectsMayBeReusable"] = project.entities.count + project.events.count > objectCount
        if let index = try? BookChapterRuntime.index(in: project) {
            let ranges = Dictionary(snapshot.sources.compactMap { source in source.sourceRange.map { (source.unitID, $0) } }, uniquingKeysWith: { first, _ in first })
            let allowed = Set(snapshot.unitIDs)
            let chapters = index.chapters.filter { chapter in
                guard let start = chapter.ranges.first, allowed.contains(start.unitID) else { return false }
                return ranges[start.unitID].map { $0.startUTF16 <= start.startUTF16 && start.startUTF16 < $0.endUTF16 } ?? true
            }
            value["chapters"] = chapters.prefix(12).compactMap { chapter -> [String: String]? in
                guard let first = chapter.ranges.first else { return nil }
                return ["title": String(chapter.title.prefix(160)), "firstUnitID": first.unitID]
            }
            value["chaptersPartial"] = chapters.count > 12
        }
        var rows = snapshot.sources.prefix(20).map { ["id": $0.unitID, "locator": String($0.locator.prefix(100))] }
        while true {
            value["sourceIndex"] = rows
            value["nextIndexOffset"] = rows.count < snapshot.sources.count ? rows.count as Any : NSNull()
            let encoded = try json(value)
            if encoded.utf8.count <= maximumBytes { return encoded }
            if !rows.isEmpty { rows.removeLast() }
            else { return nil }
        }
    }
}
