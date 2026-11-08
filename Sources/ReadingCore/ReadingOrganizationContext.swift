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
            "writes": "host_controlled_proposals"]
        var status: [String: Int] = [:]
        for id in snapshot.unitIDs { try Task.checkCancellation(); status[project.coverage[id]?.status.rawValue ?? "pending", default: 0] += 1 }
        value["coverageCounts"] = status
        // Existence here is only scoped identity, never an unread description
        // or permission to overwrite an old user correction.
        let local = project.entities.isEmpty && project.events.isEmpty ? nil : scopedKnowledgeProject()
        let objectCount = (local?.entities.count ?? 0) + (local?.events.count ?? 0)
        let metadata = Dictionary((local?.temporalKnowledge?.eventMetadata ?? []).map { ($0.eventID, $0) }, uniquingKeysWith: { first, _ in first })
        let entities = (local?.entities ?? []).prefix(32).map { ["id": $0.id, "name": String($0.name.prefix(60)), "kind": "entity", "typeID": $0.typeID] }
        let events = (local?.events ?? []).prefix(32).map { ["id": $0.id, "name": String($0.name.prefix(60)), "kind": "event", "timeState": metadata[$0.id]?.extent?.precision.rawValue ?? "missing"] }
        // Alternate kinds before applying the byte limit, so a book with many
        // people cannot hide every event from the continuation's first turn.
        var objects: [[String: String]] = []
        for index in 0..<max(entities.count, events.count) {
            if index < entities.count { objects.append(entities[index]) }
            if index < events.count { objects.append(events[index]) }
        }
        objects = Array(objects.prefix(48))
        value["savedCounts"] = ["entities": local?.entities.count ?? 0, "events": local?.events.count ?? 0,
            "relations": local?.relations.count ?? 0, "eventsWithoutTime": (local?.events ?? []).filter { metadata[$0.id]?.extent == nil }.count]
        value["otherSavedObjectsMayBeReusable"] = project.entities.count + project.events.count > objectCount
        // These are layout declarations, not their unshared document bodies or
        // book facts. Listing actual reusable views avoids a discovery round;
        // it does not prescribe a template, enable a plugin or authorize data.
        let disabled = Set(project.plugins.filter { project.disabledPluginIDs.contains($0.id) }.flatMap { $0.views.map(\.id) })
        let views = hostTools?.viewActions.contains("component_show") == true ? project.views.filter { !disabled.contains($0.id) } : []
        var viewRows = views.prefix(12).map { ["id": $0.id, "title": String($0.title.prefix(60)), "kind": $0.kind.rawValue, "rendererID": $0.rendererID ?? $0.kind.rawValue] }
        var chapters: [[String: String]] = []
        var chapterCount = 0
        if let index = try? BookChapterRuntime.index(in: project) {
            let ranges = Dictionary(snapshot.sources.compactMap { source in source.sourceRange.map { (source.unitID, $0) } }, uniquingKeysWith: { first, _ in first })
            let allowed = Set(snapshot.unitIDs)
            let selected = index.chapters.filter { chapter in
                guard let start = chapter.ranges.first, allowed.contains(start.unitID) else { return false }
                return ranges[start.unitID].map { $0.startUTF16 <= start.startUTF16 && start.startUTF16 < $0.endUTF16 } ?? true
            }
            chapterCount = selected.count
            chapters = selected.prefix(12).compactMap { chapter -> [String: String]? in
                guard let first = chapter.ranges.first else { return nil }
                return ["title": String(chapter.title.prefix(80)), "firstUnitID": first.unitID]
            }
        }
        var types = Array(project.types.prefix(24))
        var rows = snapshot.sources.prefix(20).map { ["id": $0.unitID, "locator": String($0.locator.prefix(100))] }
        while true {
            value["types"] = types.map { ["id": $0.id, "name": String($0.name.prefix(60))] }
            value["typesPartial"] = types.count < project.types.count
            value["typeFields"] = types.map { ["typeID": $0.id, "keys": Array($0.fields.prefix(16).map(\.key)), "partial": $0.fields.count > 16] as [String: Any] }
            value["savedObjects"] = objects; value["savedObjectsPartial"] = objectCount > objects.count
            value["availableViews"] = viewRows; value["availableViewsPartial"] = views.count > viewRows.count
            value["chapters"] = chapters; value["chaptersPartial"] = chapters.count < chapterCount
            value["sourceIndex"] = rows
            value["nextIndexOffset"] = rows.count < snapshot.sources.count ? rows.count as Any : NSNull()
            let encoded = try json(value)
            if encoded.utf8.count <= maximumBytes { return encoded }
            if !rows.isEmpty { rows.removeLast() }
            else if !chapters.isEmpty { chapters.removeLast() }
            else if objects.count > 2 { objects.removeLast() }
            else if !viewRows.isEmpty { viewRows.removeLast() }
            else if !types.isEmpty { types.removeLast() }
            else if !objects.isEmpty { objects.removeLast() }
            else { return nil }
        }
    }
}
