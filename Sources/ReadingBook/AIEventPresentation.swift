import Foundation
import ReadingCore

@MainActor extension AppStore {
    /// An event identity is the model's intent. Source span, linked clocks and
    /// camera work are deterministic host operations, using the saved facts.
    func presentReadingEvent(_ args: [String: Any], data: Data, book: BookProject,
                             owner: ReadingQueryHostOwner?, snapshot: ReadingQuerySnapshot?) async throws -> Data {
        guard Set(args.keys) == ["eventID", "expectedVersion"], let id = args["eventID"] as? String,
              let version = args["expectedVersion"] as? String, let snapshot else {
            return try viewToolResult("invalid_arguments", "缺少本轮事件身份或版本，未改变界面。")
        }
        guard !editorDirty else { return try viewToolResult("needs_confirmation", "请先处理未保存笔记。") }
        guard !hasWorkspaceAuxiliary, let view = enabledViews.first(where: { $0.id == route }), let composition = view.composition,
              composition.parts.contains(where: { $0.primitive == .map }), composition.parts.contains(where: { $0.primitive == .timeline }),
              let state = activeComponentView, state.issue == nil, state.snapshot?.scopeFingerprint == snapshot.scopeFingerprint else {
            return try viewToolResult("unsupported", "请先用component_show打开本轮范围内已有的地图与时间轴组合；未扩大范围或新建资料。")
        }
        let plan = try ReadingEventPresentationPlan.resolve(eventID: id, in: book, snapshot: snapshot)
        guard version == plan.version else { return try viewToolResult("conflict", "已有事件已被修改，请重新取得资料；未沿用旧版本。") }
        let contextID = readingVisibilityContextID, revision = currentBookRevision, renderer = route
        let command = WorkspaceAICommand(name: "view_show_event", arguments: data, timeWindow: plan.window, eventID: id)
        let response = try await sendWorkspaceCommand(command, expectedBookID: book.id, owner: owner)
        var receipt = try JSONSerialization.jsonObject(with: response) as! [String: Any]
        guard receipt["ok"] as? Bool == true else { return response }
        guard owner?.matches(self) ?? !Task.isCancelled, readingVisibilityContextID == contextID,
              currentBookRevision == revision else { throw CancellationError() }
        // Fitting reuses the production map operation, after its filtered data
        // projection has settled. It does not consume another model request.
        let fitArgs = try JSONSerialization.data(withJSONObject: ["objectIDs": [id]])
        let fitResponse = try await performReadingViewAction("map_fit_objects", data: fitArgs, expectedBookID: book.id,
                                                            sourceHash: book.sourceHash, owner: owner, querySnapshot: snapshot)
        guard owner?.matches(self) ?? !Task.isCancelled, readingVisibilityContextID == contextID,
              currentBookRevision == revision else { throw CancellationError() }
        let fit = try JSONSerialization.jsonObject(with: fitResponse) as! [String: Any]
        receipt["rendererID"] = renderer
        receipt["cameraStatus"] = fit["status"]
        receipt["message"] = "已按事件完整出处选择并筛选；地图和行动是否可见以随后实际画面回执为准。"
        return try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
    }
}
