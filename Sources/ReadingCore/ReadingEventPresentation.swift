import Foundation

/// A disposable goal resolved from shared, admitted facts. No calendar dates,
/// source permissions or persisted knowledge are created by presenting an event.
public struct ReadingEventPresentationPlan: Sendable, Equatable {
    public let eventID: String
    public let version: String
    public let sourceUnitIDs: [String]
    public let knownRouteIDs: [String]
    public let knownPlaceIDs: [String]
    public let window: TemporalViewWindow

    public static func resolve(eventID: String, in project: BookProject, snapshot: ReadingQuerySnapshot, preferredAxis: String? = nil,
                               allowsFullIdentity: Bool = false) throws -> Self {
        guard project.id == snapshot.bookID, project.sourceHash == snapshot.sourceHash else { throw ReadingError.invalid("书籍或原文版本已改变，未展示事件。") }
        // Match ReadingAnswerEngine's explicit whole-book identity policy.
        // Scoped excerpts still redact aggregates and keep exact admission.
        let session = ReadingQuerySession(snapshot: snapshot, history: [], loader: nil, providedDocuments: [:], project: project,
            allowsFullIdentity: allowsFullIdentity)
        guard !session.isIdentityStub(eventID), let scoped = session.scopedKnowledgeProject() else { throw ReadingError.invalid("当前范围不足以展示完整事件；请明确选择其完整原文范围。") }
        let boundary = KnowledgeReadBoundary(allowedUnitIDs: Set(snapshot.unitIDs))
        guard let event = try TemporalKnowledgeRuntime.events(in: scoped, boundary: boundary).first(where: { $0.object.id == eventID }),
              let source = sourceWindow(event.sourceExtent) else { throw ReadingError.invalid("事件在本范围没有完整、可定位的出处；未猜测时间或扩大范围。") }
        let allowed = Set(snapshot.unitIDs)
        let orders = Set(project.units.filter { allowed.contains($0.id) }.map { Double($0.order) })
        guard orders.contains(source.from), orders.contains(source.to) else { throw ReadingError.invalid("事件出处端点未落在本轮可用原文，未猜测范围。") }
        guard project.units.filter({ Double($0.order) >= source.from && Double($0.order) <= source.to }).allSatisfy({ allowed.contains($0.id) }) else {
            throw ReadingError.invalid("完整事件区间超过本次已分享原文，未扩大范围。")
        }
        let window = presentationWindow(recorded: event.extent, source: event.sourceExtent, preferredAxis: preferredAxis) ?? source
        guard let time = TemporalAxis(window.axis).window(from: window.from, to: window.to) else { throw ReadingError.invalid("事件时间体系无效，未定位。") }
        let routes = try TemporalKnowledgeRuntime.relations(in: scoped, within: time, boundary: boundary)
            .filter { $0.metadata?.spatial?.eventID == eventID }.map { $0.relation.id }
        return Self(eventID: eventID, version: event.object.version, sourceUnitIDs: Array(Set(event.object.evidence.map(\.unitID))).sorted(),
                    knownRouteIDs: Array(Set(routes)).sorted(), knownPlaceIDs: Array(Set(event.object.references["places"] ?? [])).sorted(), window: window)
    }

    /// Shared with the production timeline button, so model actions do not
    /// implement a second interpretation of the same saved source interval.
    public static func sourceWindow(_ extent: TemporalExtent?) -> TemporalViewWindow? {
        guard let extent, extent.narrativeDomain == "source-order", let lower = extent.narrativeStart else { return nil }
        let upper = extent.narrativeEnd ?? lower
        guard let data = try? JSONSerialization.data(withJSONObject: ["at": ["narrativeOrder": lower, "narrativeDomain": "source-order"], "from": lower, "to": upper]) else { return nil }
        return try? TemporalViewWindow(arguments: data, availableAxes: ["narrative-domain:source-order"])
    }

    /// Source admission always uses the complete source interval above. A
    /// reliable recorded date controls presentation only; it grants no text.
    /// Named calendars remain independent, with no inferred conversion or
    /// fabricated first/last day for an uncertain or month-only date.
    public static func presentationWindow(recorded: TemporalExtent?, source: TemporalExtent?, preferredAxis: String? = nil) -> TemporalViewWindow? {
        let source = sourceWindow(source)
        if let preferredAxis, preferredAxis == source?.axis { return source }
        guard let recorded, recorded.assertion == .explicit, recorded.uncertainty == .exact,
              recorded.kind != .uncertainRange, let calendar = recorded.calendar, !calendar.isEmpty,
              let first = recorded.start, recorded.kind == .point || recorded.end != nil,
              (try? TemporalKnowledgeRuntime.validateExtent(recorded)) != nil else { return source }
        let last = recorded.end ?? first
        var at: [String: Any] = ["calendar": calendar, "year": first.year]
        var args: [String: Any]
        let axis: String
        if recorded.precision == .day, let month = first.month, let day = first.day, let endMonth = last.month, let endDay = last.day {
            at["month"] = month; at["day"] = day; axis = "calendar-day:" + calendar
            args = ["at": at, "fromDate": ["year": first.year, "month": month, "day": day],
                    "toDate": ["year": last.year, "month": endMonth, "day": endDay]]
        } else if recorded.precision == .year, first.month == nil, first.day == nil, last.month == nil, last.day == nil {
            axis = "calendar:" + calendar; args = ["at": at, "from": first.year, "to": last.year]
        } else { return source }
        guard let data = try? JSONSerialization.data(withJSONObject: args) else { return source }
        return (try? TemporalViewWindow(arguments: data, availableAxes: [axis])) ?? source
    }

    func goal() -> [String: Any] {
        ["eventID": eventID, "coverage": "complete_saved_sources", "axis": window.axis, "from": window.from, "to": window.to,
         "knownActionCount": knownRouteIDs.count, "sourceUnitIDs": Array(sourceUnitIDs.prefix(8)), "sourceListPartial": sourceUnitIDs.count > 8,
         "note": TemporalAxis(window.axis).isNarrative ? "原文出处区间，不是历史日期；只改变呈现，不产生新事实或引用权限。" : "按已保存的明确时间展示，不换算历法；原文权限仍只来自本轮完整出处，不产生新事实。"]
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
            // Stationary events can be represented by an explicitly saved
            // place. This never substitutes places for missing action routes.
            let eventPlace = knownRouteIDs.isEmpty && !Set(knownPlaceIDs).isDisjoint(with: maps.flatMap(\.objectIDs))
            if !eventMarker && !eventAction && !eventPlace { missing.append("event_visible") }
            if !Set(knownRouteIDs).isSubset(of: projected) { missing.append("known_actions_projected") }
            if !Set(knownRouteIDs).isSubset(of: visible) { missing.append("known_actions_visible") }
        }
        return missing
    }
}

extension ReadingQuerySession {
    mutating func presentEvent(_ arguments: [String: Any], host: ReadingHostToolAccess, maximumBytes: Int) async throws -> String {
        guard Set(arguments.keys).isSubset(of: ["eventID", "viewID"]), let id = arguments["eventID"] as? String, !id.isEmpty, id.count <= 400,
              let project else { throw invalid("view_show_event接收eventID及可选的已有viewID；软件从已有出处计算完整范围，不接收猜测的时间坐标或新建布局。") }
        let viewID = arguments["viewID"] as? String
        if arguments["viewID"] != nil {
            guard let viewID, !viewID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, viewID.utf8.count <= 128,
                  host.viewActions.contains("component_show") else {
                throw invalid("请使用本轮已授权打开的已有视图ID；此动作不创建组件或增加权限。")
            }
        }
        guard maximumBytes >= 6_000 else { return try json(["ok": false, "budgetLimited": true, "message": "展示目标和实际回执所需预算不足，未操作。"] ) }
        if viewID == nil, let refresh = host.readWorkspace {
            // A user or an earlier time-window action may have changed the
            // clock since the last model receipt. Read the actual preference
            // locally rather than applying a cached axis to another action.
            workspace = nil
            do {
                if let fresh = try await refresh() { try validateWorkspace(fresh); workspace = fresh }
                try Task.checkCancellation()
            } catch { try QueryBudget.propagateControl(error) }
        }
        var plan = try ReadingEventPresentationPlan.resolve(eventID: id, in: project, snapshot: snapshot, preferredAxis: workspace?.timeAxis,
            allowsFullIdentity: allowsFullIdentity)
        let attempts = eventPresentationFailures[id, default: 0]
        guard attempts < 3 else {
            let result = try json(["ok": false, "status": "retry_limit", "message": "同一事件初次展示和两次修正仍未完成，已停止重复操作；已有成果保留。", "goal": plan.goal()])
            try recordHostReceipt(result, tool: "view_show_event")
            return result
        }
        if let viewID {
            // Reuse exactly the existing open capability, then the existing
            // event capability. The model need not spend a round trip merely
            // relaying success from one deterministic host action to another.
            let opened = try await executeExtended(name: "component_show", arguments: ["viewID": viewID], maximumBytes: min(16_000, maximumBytes))
            lastComponentReceipt = nil
            try Task.checkCancellation()
            let receipt = try JSONSerialization.jsonObject(with: Data(opened.utf8)) as! [String: Any]
            guard receipt["ok"] as? Bool == true, receipt["opened"] as? Bool == true,
                  receipt["viewID"] as? String == viewID, workspace?.rendererID == viewID else {
                pendingEventPresentation = plan; eventPresentationFailures[id] = attempts + 1
                let output = try json(["ok": false, "status": receipt["status"] as? String == "needs_confirmation" ? "needs_confirmation" : "partial", "applied": false, "complete": false,
                    "requestedViewID": viewID, "openingStatus": receipt["status"] ?? "unavailable", "missing": ["component_opened"], "goal": plan.goal(),
                    "openingMessage": String((receipt["message"] as? String ?? "").prefix(1000)),
                    "message": "目标组件尚未确认打开，没有在其他窗口执行事件定位；已有资料保留。"])
                try recordHostReceipt(output, tool: "view_show_event")
                return output
            }
            // The host owns the current view registry, including a view just
            // created in this question. The frozen knowledge project need not
            // contain that new display declaration to authorize an open.
            plan = try ReadingEventPresentationPlan.resolve(eventID: id, in: project, snapshot: snapshot, preferredAxis: workspace?.timeAxis,
                allowsFullIdentity: allowsFullIdentity)
        }
        workspace = nil
        let data = try JSONSerialization.data(withJSONObject: ["eventID": id, "expectedVersion": plan.version], options: [.sortedKeys])
        let raw = try hostResult(await host.performViewAction("view_show_event", data))
        var result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
        if let viewID { result["openedViewID"] = viewID }
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
