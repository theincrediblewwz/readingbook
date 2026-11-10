import Foundation

extension ReadingQuerySession {
    /// A small explanation of admitted saved facts next to the actual renderer
    /// receipt. It never reads source text, adds citation rights, or invents a
    /// second event/action store. Temporal variants keep their own record IDs.
    func eventReceiptContext(_ plan: ReadingEventPresentationPlan, maximumBytes: Int) throws -> [String: Any]? {
        guard let scoped = scopedKnowledgeProject() else { return nil }
        let boundary = KnowledgeReadBoundary(allowedUnitIDs: Set(snapshot.unitIDs))
        guard let event = try TemporalKnowledgeRuntime.events(in: scoped, boundary: boundary)
            .first(where: { $0.object.id == plan.eventID && $0.object.version == plan.version }) else { return nil }
        let window = TemporalQueryWindow.ordered(from: Int(plan.window.from), to: Int(plan.window.to), domain: "source-order")
        let included = Set(try TemporalKnowledgeRuntime.relations(in: scoped, within: window, boundary: boundary)
            .compactMap { $0.metadata?.id })
        let actions = try TemporalKnowledgeRuntime.relations(in: scoped, boundary: boundary)
            .filter { $0.metadata?.spatial?.eventID == plan.eventID }
        let names = Dictionary(scoped.entities.filter { !isIdentityStub($0.id) }.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let matchingGroups = Set((workspace?.timeWindows ?? []).filter {
            $0.axis == plan.window.axis && $0.from == plan.window.from && $0.to == plan.window.to
        }.map(\.groupID))
        let mapParts = workspace?.rendererID.flatMap { id in scoped.views.first(where: { $0.id == id })?.composition?.parts }
        let maps = (workspace?.mapViewports ?? []).filter { viewport in
            guard let mapParts else { return true }
            return mapParts.contains { $0.id == viewport.partID && matchingGroups.contains($0.timeGroup) }
        }
        let projected = Set(maps.flatMap(\.projectedRouteIDs)), visible = Set(maps.flatMap(\.visibleRouteIDs))
        let observed = workspace?.observationStatus?.permitsVisibility == true && !matchingGroups.isEmpty
        let locations = Dictionary(snapshot.sources.map { ($0.unitID, $0.locator) }, uniquingKeysWith: { first, _ in first })
        let pages = Dictionary(scoped.units.compactMap { unit in unit.page.map { (unit.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let sources: [[String: Any]] = plan.sourceUnitIDs.prefix(8).map { id in
            var row: [String: Any] = ["unitID": id, "locator": locations[id] ?? id]
            if let page = pages[id] { row["page"] = page }
            return row
        }
        var rows = [[String: Any]](), inWindow = 0, outside = 0, visibleRelations = Set<String>()
        for action in actions {
            try Task.checkCancellation()
            guard let metadata = action.metadata, let spatial = metadata.spatial else { continue }
            let matches = included.contains(metadata.id)
            let extent = action.sourceExtent ?? metadata.validity
            let excludedByTime = !matches && TemporalKnowledgeRuntime.match(extent, within: window) == .outside
            if matches { inWindow += 1 }
            if excludedByTime { outside += 1 }
            let lineVisible = matches && observed && projected.contains(action.relation.id) && visible.contains(action.relation.id)
            if lineVisible { visibleRelations.insert(action.relation.id) }
            var row: [String: Any] = ["relationID": action.relation.id, "recordID": metadata.id,
                "label": String(action.relation.label.prefix(160)), "kind": String(spatial.kind.prefix(80)),
                "from": ["id": action.relation.fromID, "name": String((names[action.relation.fromID] ?? "").prefix(100))],
                "to": ["id": action.relation.toID, "name": String((names[action.relation.toID] ?? "").prefix(100))],
                "actors": spatial.actorIDs.prefix(8).compactMap { id -> [String: String]? in
                    names[id].map { ["id": id, "name": String($0.prefix(100))] }
                },
                "windowMatch": matches ? "included" : excludedByTime ? "outside_window" : "not_admitted_in_window",
                "relationLineVisible": lineVisible, "timeSummary": TemporalDatePresentation.summary(extent),
                "assertion": metadata.assertion.rawValue]
            if action.relation.label.count > 160 { row["labelTruncated"] = true }
            if spatial.actorIDs.count > 8 { row["actorsPartial"] = true }
            rows.append(row)
        }
        rows.sort {
            let first = $0["relationLineVisible"] as? Bool == true ? 0 : $0["windowMatch"] as? String == "included" ? 1 : 2
            let second = $1["relationLineVisible"] as? Bool == true ? 0 : $1["windowMatch"] as? String == "included" ? 1 : 2
            return (first, $0["recordID"] as? String ?? "") < (second, $1["recordID"] as? String ?? "")
        }
        var kept = Array(rows.prefix(8))
        func envelope() -> [String: Any] {
            ["basis": "saved_analysis_and_actual_view", "bodyProvided": false,
             "event": ["id": plan.eventID, "name": String(event.object.name.prefix(200)),
                       "timeSummary": TemporalDatePresentation.summary(event.sourceExtent ?? event.extent)],
             "sourceLocations": sources, "sourceLocationsPartial": plan.sourceUnitIDs.count > sources.count,
             "actionRecordCount": rows.count, "recordsInWindow": inWindow, "recordsOutsideWindow": outside,
             "visibleRelationCount": visibleRelations.count, "actions": kept, "actionsPartial": kept.count < rows.count,
             "note": "已有分析概览，不是新读正文或精确历史地理。同一关系可有不同时间的行动记录；relationLineVisible只说明该关系的线有部分实际可见。范围外的关联行动不因本次展示自动调宽时间。"]
        }
        while !kept.isEmpty, try json(envelope()).utf8.count > maximumBytes { kept.removeLast() }
        let result = envelope()
        return try json(result).utf8.count <= maximumBytes ? result : nil
    }
}
