import SwiftUI
import AppKit
import CoreFoundation
import ReadingCore

struct WorkspaceAICommand: Equatable {
    let id = UUID()
    let name: String
    let arguments: Data
    var timeWindow: TemporalViewWindow? = nil
}

@MainActor extension AppStore {
    /// Visibility belongs to an exact library, publication, component scope and
    /// route. A late canvas task must not describe a previous book or range.
    var readingVisibilityContextID: String {
        [libraryRootURL.path, bookID ?? "", book?.sourceHash ?? "", String(currentBookRevision),
         componentDataScopeID?.uuidString ?? "", route].joined(separator: "\u{1f}")
    }
    func makeReadingWorkspaceSnapshot() -> ReadingWorkspaceSnapshot? {
        guard let book else { return nil }
        var visible = renderedWorkspaceVisibility.flatMap {
            $0.rendererID == route && $0.contextID == readingVisibilityContextID ? $0 : nil
        }
        let composition = route == "reading.composition" || book.views.first { $0.id == route }?.rendererID == "reading.composition"
        let rendered = composition ? renderedCompositionState.flatMap { $0.contextID == readingVisibilityContextID ? $0 : nil } : nil
        if let rendered, !rendered.maps.isEmpty {
            visible = ReadingVisibleObjectsSnapshot(rendererID: route, objectIDs: Array(Set(rendered.maps.flatMap(\.objectIDs))).sorted(), partial: true,
                description: "组合地图停稳后的可见标记，已扣除悬浮卡片；不代表工作台全部资料。", contextID: readingVisibilityContextID)
        }
        let clock = rendered?.clocks.count == 1 ? rendered?.clocks.first : nil
        var context = queryReadingContext
        if composition {
            // Composition clocks and selection live in their renderer. A
            // standalone view's old global clock is not their actual state.
            // Only the renderer-owned clock may replace it.
            context.timeFrom = clock?.from; context.timeTo = clock?.to; context.startYear = nil; context.endYear = nil
        }
        return ReadingWorkspaceSnapshot(bookID: book.id, sourceHash: book.sourceHash, rendererID: route,
            selectedObjectIDs: composition ? rendered?.selectedIDs ?? [] : selectedObjectID.map { [$0] } ?? [], context: context,
            visibleObjects: visible, selectedNodeIDs: visible == nil ? [] : renderedSelectedNodeIDs, timeAxis: composition ? clock?.axis : temporalAxis,
            timeFrom: composition ? clock?.from : timeFrom, timeTo: composition ? clock?.to : timeTo, currentTime: composition ? clock?.current : timeCursor,
            mapViewports: rendered?.maps, timeWindows: rendered?.clocks, sourceScopeTitle: composition ? componentSourceControlTitle : nil)
    }
    func readingViewToolAccess(bookID expectedBookID: String, sourceHash: String, runID: UUID? = nil,
                               grant: ControlledWriteGrant? = nil, snapshot: ReadingQuerySnapshot? = nil,
                               context: ReadingContext? = nil) -> ReadingHostToolAccess {
        let owner = ReadingQueryHostOwner(root: libraryRootURL, bookID: expectedBookID, sourceHash: sourceHash, runID: runID)
        let session = ReadingComponentToolSession(grant: grant, snapshot: snapshot, context: context)
        return ReadingHostToolAccess(viewActions: ["components_list", "component_show", "view_select", "view_focus", "view_set_time_window", "map_fit_objects", "graph_focus", "panel_present"], performViewAction: { [weak self] name, data in
            guard let self, await owner.matches(self) else { throw CancellationError() }
            if ["components_list", "component_show"].contains(name) {
                return try await self.performReadingComponentAction(name, data: data, owner: owner, session: session)
            }
            return try await self.performReadingViewAction(name, data: data, expectedBookID: expectedBookID, sourceHash: sourceHash, owner: owner, querySnapshot: snapshot)
        }, readWorkspace: { [weak self] in
            guard let self, await owner.matches(self) else { throw CancellationError() }
            return await self.makeReadingWorkspaceSnapshot()
        })
    }
    func viewToolResult(_ status: String, _ message: String, extra: [String: Any] = [:]) throws -> Data {
        var result = extra; result["status"] = status; result["message"] = message; result["ok"] = status == "success"
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }
    func acknowledgeViewCommand(_ command: WorkspaceAICommand, status: String = "success", message: String) {
        workspaceAIResponses[command.id] = try? viewToolResult(status, message)
    }
    func performReadingViewAction(_ name: String, data: Data, expectedBookID: String, sourceHash: String, owner: ReadingQueryHostOwner? = nil, querySnapshot: ReadingQuerySnapshot? = nil) async throws -> Data {
        guard owner?.matches(self) ?? !Task.isCancelled else { throw CancellationError() }
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
                guard owner?.matches(self) ?? true else { throw CancellationError() }
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
        var resolvedWindow: TemporalViewWindow?
        if name == "view_set_time_window" {
            let axes: [String]
            if let querySnapshot {
                let state = book.temporalKnowledge
                let anchors = Dictionary(((book.readingExperience?.anchors ?? []) + (state?.anchors ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                func admitted(_ ids: [String]) -> Bool {
                    !ids.isEmpty && ids.allSatisfy { id in anchors[id].map { querySnapshot.admits(Evidence(unitID: $0.unitID, quote: $0.quote)) } ?? false }
                }
                var extents: [TemporalExtent] = []
                for presence in state?.presences ?? [] where admitted(presence.sourceAnchorIDs) { extents.append(presence.extent) }
                for participation in state?.participations ?? [] where admitted(participation.sourceAnchorIDs) { if let extent = participation.extent { extents.append(extent) } }
                for event in state?.eventMetadata ?? [] where admitted(event.sourceAnchorIDs) { if let extent = event.extent { extents.append(extent) } }
                for relation in state?.relationMetadata ?? [] where admitted(relation.sourceAnchorIDs) { extents.append(relation.validity) }
                axes = TemporalAxis.available(extents)
            } else { axes = availableTemporalAxes }
            let window = try TemporalViewWindow(arguments: data, availableAxes: axes)
            if enabledViews.first(where: { $0.id == route })?.composition != nil {
                resolvedWindow = window
            } else {
                guard enabledViews.contains(where: { $0.id == route && ($0.kind == .map || $0.kind == .timeline) }), !hasWorkspaceAuxiliary else {
                    return try viewToolResult("unsupported", "请先打开地图、时间轴或组合工作台，再设置其时间范围。")
                }
                temporalAxis = window.axis; timeFrom = window.from; timeTo = window.to; timeCursor = window.cursor
                return try viewToolResult("success", "时间窗已同步。", extra: ["axis": window.axis, "from": window.from, "to": window.to, "current": window.cursor])
            }
        }

        let command = WorkspaceAICommand(name: name, arguments: data, timeWindow: resolvedWindow)
        workspaceAICommand = command
        defer { workspaceAIResponses[command.id] = nil; if workspaceAICommand?.id == command.id { workspaceAICommand = nil } }
        for _ in 0..<50 {
            try Task.checkCancellation()
            guard owner?.matches(self) ?? true else { throw CancellationError() }
            if let response = workspaceAIResponses[command.id] { return response }
            guard bookID == expectedBookID else { return try viewToolResult("conflict", "书籍已改变。") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try viewToolResult("unsupported", "当前界面未连接此操作；没有改变保存内容。")
    }
}
