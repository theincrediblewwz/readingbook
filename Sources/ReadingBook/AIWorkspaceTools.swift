import SwiftUI
import AppKit
import CoreFoundation
import ReadingCore

struct WorkspaceAICommand: Equatable {
    let id = UUID()
    let name: String
    let arguments: Data
}

@MainActor extension AppStore {
    func makeReadingWorkspaceSnapshot() -> ReadingWorkspaceSnapshot? {
        guard let book else { return nil }
        let visible = renderedWorkspaceVisibility.flatMap { $0.rendererID == route ? $0 : nil }
        return ReadingWorkspaceSnapshot(bookID: book.id, sourceHash: book.sourceHash, rendererID: route,
            selectedObjectIDs: selectedObjectID.map { [$0] } ?? [], context: queryReadingContext,
            visibleObjects: visible, selectedNodeIDs: visible == nil ? [] : renderedSelectedNodeIDs, timeAxis: temporalAxis,
            timeFrom: timeFrom, timeTo: timeTo, currentTime: timeCursor)
    }
    func readingViewToolAccess(bookID expectedBookID: String, sourceHash: String) -> ReadingHostToolAccess {
        ReadingHostToolAccess(viewActions: ["view_select", "view_focus", "view_set_time_window", "map_fit_objects", "graph_focus", "panel_present"], performViewAction: { [weak self] name, data in
            guard let self else { throw CancellationError() }
            return try await self.performReadingViewAction(name, data: data, expectedBookID: expectedBookID, sourceHash: sourceHash)
        }, readWorkspace: { [weak self] in await self?.makeReadingWorkspaceSnapshot() })
    }
    func viewToolResult(_ status: String, _ message: String, extra: [String: Any] = [:]) throws -> Data {
        var result = extra; result["status"] = status; result["message"] = message; result["ok"] = status == "success"
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }
    func acknowledgeViewCommand(_ command: WorkspaceAICommand, status: String = "success", message: String) {
        workspaceAIResponses[command.id] = try? viewToolResult(status, message)
    }
    func performReadingViewAction(_ name: String, data: Data, expectedBookID: String, sourceHash: String) async throws -> Data {
        guard let book, book.id == expectedBookID, book.sourceHash == sourceHash else { return try viewToolResult("conflict", "当前书籍已改变。") }
        guard NSEvent.pressedMouseButtons == 0, !isSavingDocument, !isCommittingLocalWrite else { return try viewToolResult("busy", "读者正在操作，未抢占界面。") }
        guard let args = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReadingError.invalid("视图操作参数无效。") }
        if name == "view_select" {
            guard !editorDirty else { return try viewToolResult("needs_confirmation", "当前笔记有未保存修改，请读者先保存或放弃。") }
            guard let renderer = args["rendererID"] as? String else { throw ReadingError.invalid("缺少组件ID。") }
            let route: String?
            if ["reader", "query", "editor", "workflow", "library"].contains(renderer) { route = renderer }
            else { route = enabledViews.first { $0.id == renderer || $0.rendererID == renderer || $0.kind.rawValue == renderer }?.id }
            guard let route else { return try viewToolResult("unsupported", "该组件未安装或未启用；没有自动添加组件。") }
            requestedWorkspaceRoute = route
            for _ in 0..<50 {
                try Task.checkCancellation()
                let presented = route == "editor" ? isNotesForeground : (self.route == route && !hasWorkspaceAuxiliary)
                if presented && requestedWorkspaceRoute == nil { return try viewToolResult("success", "已打开组件。", extra: ["rendererID": route]) }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return try viewToolResult("busy", "导航尚未完成，未宣称打开成功。")
        }
        if name == "view_focus" {
            guard !editorDirty else { return try viewToolResult("needs_confirmation", "请先处理未保存笔记。") }
            if let id = args["documentID"] as? String, let document = book.activeDocuments.first(where: { $0.id == id }) {
                await openDocument(document); return try viewToolResult(selectedDocumentID == id && isNotesForeground ? "success" : "conflict", "文档聚焦结果。")
            }
            if let id = args["anchorID"] as? String {
                let anchors = (book.readingExperience?.anchors ?? []) + (book.temporalKnowledge?.anchors ?? [])
                guard let anchor = anchors.first(where: { $0.id == id }) else { return try viewToolResult("unsupported", "原文锚点不存在。") }
                follow(Evidence(unitID: anchor.unitID, quote: anchor.quote)); return try viewToolResult("success", "已回到原文出处。")
            }
            guard let id = args["objectID"] as? String, book.entities.contains(where: { $0.id == id }) || book.events.contains(where: { $0.id == id }) else { return try viewToolResult("unsupported", "对象不存在。") }
            focus(id); return try viewToolResult("success", "已选中共享对象。", extra: ["objectID": id])
        }
        if name == "view_set_time_window" {
            func number(_ value: Any?) -> Double? {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
                return number.doubleValue
            }
            guard let from = number(args["from"]), let to = number(args["to"]),
                  from.isFinite, to.isFinite, abs(from) <= 1e9, abs(to) <= 1e9, from <= to,
                  let at = args["at"] as? [String: Any] else { throw ReadingError.invalid("请提供完整时间窗和时间体系。") }
            let axis: String, cursor: Double
            if Set(at.keys) == ["narrativeOrder"], let order = number(at["narrativeOrder"]), order.rounded() == order, abs(order) <= 1e9, hasNarrativeTime { axis = "narrative"; cursor = order }
            else if Set(at.keys) == ["calendar", "year"], let calendar = at["calendar"] as? String, let year = number(at["year"]), year.rounded() == year, abs(year) <= 1e9, temporalCalendars.contains(calendar) { axis = "calendar:" + calendar; cursor = year }
            else { return try viewToolResult("unsupported", "该时间体系尚无可用数据。") }
            guard at["month"] == nil, at["day"] == nil else { return try viewToolResult("unsupported", "当前时间轴按年或叙事位置浏览，未把日精度降格冒充。") }
            guard cursor >= from, cursor <= to else { throw ReadingError.invalid("当前时间不在窗口内。") }
            temporalAxis = axis; timeFrom = from; timeTo = to; timeCursor = cursor
            return try viewToolResult("success", "时间窗已同步。", extra: ["axis": axis, "from": from, "to": to, "current": cursor])
        }
        let command = WorkspaceAICommand(name: name, arguments: data)
        workspaceAICommand = command
        defer { workspaceAIResponses[command.id] = nil; if workspaceAICommand?.id == command.id { workspaceAICommand = nil } }
        for _ in 0..<50 {
            try Task.checkCancellation()
            if let response = workspaceAIResponses[command.id] { return response }
            guard bookID == expectedBookID else { return try viewToolResult("conflict", "书籍已改变。") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try viewToolResult("unsupported", "当前界面未连接此操作；没有改变保存内容。")
    }
}
