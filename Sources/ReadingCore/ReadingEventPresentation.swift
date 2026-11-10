import Foundation

/// A disposable goal resolved from shared, admitted facts. No calendar dates,
/// source permissions or persisted knowledge are created by presenting an event.
public struct ReadingEventPresentationPlan: Sendable, Equatable {
    public let eventID: String
    public let version: String
    public let sourceUnitIDs: [String]
    public let knownRouteIDs: [String]
    public let window: TemporalViewWindow

    public static func resolve(eventID: String, in project: BookProject, snapshot: ReadingQuerySnapshot) throws -> Self {
        guard project.id == snapshot.bookID, project.sourceHash == snapshot.sourceHash else { throw ReadingError.invalid("书籍或原文版本已改变，未展示事件。") }
        let session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: project)
        guard !session.isIdentityStub(eventID), let scoped = session.scopedKnowledgeProject() else { throw ReadingError.invalid("当前范围不足以展示完整事件；请明确选择其完整原文范围。") }
        let boundary = KnowledgeReadBoundary(allowedUnitIDs: Set(snapshot.unitIDs))
        guard let event = try TemporalKnowledgeRuntime.events(in: scoped, boundary: boundary).first(where: { $0.object.id == eventID }),
              let window = sourceWindow(event.sourceExtent) else { throw ReadingError.invalid("事件在本范围没有完整、可定位的出处；未猜测时间或扩大范围。") }
        let allowed = Set(snapshot.unitIDs)
        let orders = Set(project.units.filter { allowed.contains($0.id) }.map { Double($0.order) })
        guard orders.contains(window.from), orders.contains(window.to) else { throw ReadingError.invalid("事件出处端点未落在本轮可用原文，未猜测范围。") }
        guard project.units.filter({ Double($0.order) >= window.from && Double($0.order) <= window.to }).allSatisfy({ allowed.contains($0.id) }) else {
            throw ReadingError.invalid("完整事件区间超过本次已分享原文，未扩大范围。")
        }
        let routes = try TemporalKnowledgeRuntime.relations(in: scoped, within: .ordered(from: Int(window.from), to: Int(window.to), domain: "source-order"), boundary: boundary)
            .filter { $0.metadata?.spatial?.eventID == eventID }.map { $0.relation.id }
        return Self(eventID: eventID, version: event.object.version, sourceUnitIDs: Array(Set(event.object.evidence.map(\.unitID))).sorted(),
                    knownRouteIDs: Array(Set(routes)).sorted(), window: window)
    }

    /// Shared with the production timeline button, so model actions do not
    /// implement a second interpretation of the same saved source interval.
    public static func sourceWindow(_ extent: TemporalExtent?) -> TemporalViewWindow? {
        guard let extent, extent.narrativeDomain == "source-order", let lower = extent.narrativeStart else { return nil }
        let upper = extent.narrativeEnd ?? lower
        guard let data = try? JSONSerialization.data(withJSONObject: ["at": ["narrativeOrder": lower, "narrativeDomain": "source-order"], "from": lower, "to": upper]) else { return nil }
        return try? TemporalViewWindow(arguments: data, availableAxes: ["narrative-domain:source-order"])
    }

    func goal() -> [String: Any] {
        ["eventID": eventID, "coverage": "complete_saved_sources", "axis": window.axis, "from": window.from, "to": window.to,
         "knownActionCount": knownRouteIDs.count, "sourceUnitIDs": Array(sourceUnitIDs.prefix(8)), "sourceListPartial": sourceUnitIDs.count > 8,
         "note": "原文出处区间，不是历史日期；只改变呈现，不产生新事实或引用权限。"]
    }

    public func missing(in workspace: ReadingWorkspaceSnapshot?) -> [String] {
        guard let workspace else { return ["renderer_observation"] }
        var missing: [String] = []
        if workspace.observationStatus?.permitsVisibility != true { missing.append("renderer_observation") }
        if !(workspace.timeWindows ?? []).contains(where: { $0.axis == window.axis && $0.from == window.from && $0.to == window.to }) { missing.append("complete_source_window") }
        if !workspace.selectedObjectIDs.contains(eventID) { missing.append("event_selection") }
        let maps = workspace.mapViewports ?? []
        if maps.isEmpty { missing.append("map_observation") }
        else {
            let projected = Set(maps.flatMap(\.projectedRouteIDs)), visible = Set(maps.flatMap(\.visibleRouteIDs))
            // A place-based map can represent an event through its actually
            // drawn action instead of a second event marker. Selection or a
            // projected-but-occluded route alone is still insufficient.
            let eventMarker = maps.contains { $0.objectIDs.contains(eventID) }
            let eventAction = !Set(knownRouteIDs).intersection(projected).intersection(visible).isEmpty
            if !eventMarker && !eventAction { missing.append("event_visible") }
            if !Set(knownRouteIDs).isSubset(of: projected) { missing.append("known_actions_projected") }
            if !Set(knownRouteIDs).isSubset(of: visible) { missing.append("known_actions_visible") }
        }
        return missing
    }
}

extension ReadingQuerySession {
    mutating func presentEvent(_ arguments: [String: Any], host: ReadingHostToolAccess, maximumBytes: Int) async throws -> String {
        guard Set(arguments.keys) == ["eventID"], let id = arguments["eventID"] as? String, !id.isEmpty, id.count <= 400,
              let project else { throw invalid("view_show_event只接收eventID；软件从已有出处计算完整范围，不接收模型猜测的时间坐标。") }
        guard maximumBytes >= 6_000 else { return try json(["ok": false, "budgetLimited": true, "message": "展示目标和实际回执所需预算不足，未操作。"] ) }
        let plan = try ReadingEventPresentationPlan.resolve(eventID: id, in: project, snapshot: snapshot)
        let attempts = eventPresentationFailures[id, default: 0]
        guard attempts < 3 else {
            let result = try json(["ok": false, "status": "retry_limit", "message": "同一事件初次展示和两次修正仍未完成，已停止重复操作；已有成果保留。", "goal": plan.goal()])
            try recordHostReceipt(result, tool: "view_show_event")
            return result
        }
        workspace = nil
        let data = try JSONSerialization.data(withJSONObject: ["eventID": id, "expectedVersion": plan.version], options: [.sortedKeys])
        let raw = try hostResult(await host.performViewAction("view_show_event", data))
        var result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
        result["goal"] = plan.goal()
        let applied = result["ok"] as? Bool == true
        result["applied"] = applied
        var packed = try json(result)
        if applied, let route = result["rendererID"] as? String {
            packed = try await receiptWithActualView(packed, route: route, maximumBytes: maximumBytes)
            result = try JSONSerialization.jsonObject(with: Data(packed.utf8)) as! [String: Any]
        }
        let missing = applied ? plan.missing(in: workspace) : ["event_presentation_applied"]
        let complete = applied && missing.isEmpty
        result["complete"] = complete; result["observed"] = applied && workspace?.observationStatus?.permitsVisibility == true
        result["missing"] = missing
        if applied {
            if let context = try eventReceiptContext(plan, maximumBytes: min(4_000, maximumBytes / 2)) {
                result["eventContext"] = context
            } else { result["eventContextOmitted"] = true }
        }
        pendingEventPresentation = complete ? nil : plan
        if !complete {
            eventPresentationFailures[id] = attempts + 1
            result["applicationStatus"] = result["status"]
            result["ok"] = false
            if result["status"] as? String != "needs_confirmation" { result["status"] = "partial" }
            result["repair"] = ["kind": "presentation", "attemptsRemaining": 2 - attempts,
                "message": "已有应用结果保留；按missing与实际画面只修正缺口。未就绪可重试本动作；布局不支持时先打开合适的已有组合。没有有据地点或行动时说明缺少资料，不造路线。"]
        }
        var output = try json(result)
        if output.utf8.count > min(16_000, maximumBytes), result.removeValue(forKey: "eventContext") != nil {
            result["eventContextOmitted"] = true; output = try json(result)
        }
        if output.utf8.count > min(16_000, maximumBytes), let actual = result["actualView"] as? [String: Any] {
            result["actualView"] = closingWorkspaceObservation(actual); output = try json(result)
        }
        if output.utf8.count > min(16_000, maximumBytes) {
            result.removeValue(forKey: "actualView")
            result["observationDetailOmitted"] = true
            output = try json(result)
        }
        guard output.utf8.count <= min(16_000, maximumBytes) else { throw invalid("展示回执超过预算；不应重复创建资料。") }
        try recordHostReceipt(output, tool: "view_show_event")
        return output
    }
}

extension ReadingQuerySession {
    mutating func presentationRepairFeedback() throws -> String? {
        guard let plan = pendingEventPresentation else { return nil }
        let missing = plan.missing(in: workspace)
        if missing.isEmpty { pendingEventPresentation = nil; return nil }
        guard eventPresentationFailures[plan.eventID, default: 0] < 3 else { return nil }
        let goal = try json(["goal": plan.goal(), "missing": missing])
        return "宿主呈现核验：刚才的展示尚未完成。" + goal + "。请依据实际回执，只修正缺口或明确说明无法完成；保留已有结果，不重新分析或创建重复资料，不改变原问题和权限。可重试view_show_event，界面不支持时先选合适的已有组合；无需再读原文来猜坐标。"
    }
    mutating func presentationIncompleteNotice() -> String? {
        guard let plan = pendingEventPresentation else { return nil }
        if plan.missing(in: workspace).isEmpty { pendingEventPresentation = nil; return nil }
        return "显示核验尚未确认完整阶段和行动都已呈现；已有资料与已应用结果保留。"
    }
}
