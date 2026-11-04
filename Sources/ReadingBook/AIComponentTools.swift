import AppKit
import Foundation
import ReadingCore

/// Navigation belongs to one request and one library, including when another
/// library happens to contain a book with identical IDs and source bytes.
struct ReadingQueryHostOwner {
    let root: URL
    let bookID: String
    let sourceHash: String
    let runID: UUID?
    @MainActor func matches(_ store: AppStore) -> Bool {
        !Task.isCancelled && store.libraryRootURL == root && store.bookID == bookID && store.book?.sourceHash == sourceHash &&
            (runID == nil || store.queryRunID == runID)
    }
}

@MainActor final class ReadingComponentToolSession {
    var createdCount = 0
    let grant: ControlledWriteGrant?
    init(grant: ControlledWriteGrant? = nil) { self.grant = grant }
}

@MainActor extension AppStore {
    func performReadingComponentAction(_ name: String, data: Data, owner: ReadingQueryHostOwner,
                                       session: ReadingComponentToolSession) async throws -> Data {
        guard owner.matches(self), let book else { throw CancellationError() }
        let registry = WorkspaceComponentRegistry.shared
        if name == "components_list" {
            let page = try ReadingComponentDirectoryRequest.decode(data)
            let components: [[String: Any]] = registry.components.filter { $0.id != "book.scheme" }.map { descriptor in
                let views = book.views.filter { view in
                    descriptor.requiresDefinition ? view.rendererID == descriptor.id : registry.equivalent(view, descriptor)
                }
                return ["id": descriptor.id, "title": descriptor.title, "purpose": descriptor.purpose,
                    "customDefinition": descriptor.requiresDefinition, "permanent": descriptor.permanent,
                    "viewCount": views.count]
            }
            let views: [[String: Any]] = book.views.dropFirst(page.offset).prefix(page.limit).map { view in
                ["id": view.id, "componentID": registry.component(for: view)?.id ?? (view.rendererID ?? view.kind.rawValue),
                 "title": String(view.title.prefix(40)), "enabled": enabledViews.contains { $0.id == view.id },
                 "inNavigation": view.configuration?["presentation"] != "inline"]
            }
            return try viewToolResult("success", "按当前需求选择组件；显示配置不代表已有分析。", extra: ["components": components,
                "views": views, "totalViews": book.views.count, "nextOffset": page.offset + views.count < book.views.count ? page.offset + views.count as Any : NSNull(),
                "customComponents": "只能组合现有元件，不执行代码；本书资料遵守阅读位置与防剧透设置，正文读取仍限本次授权。"])
        }
        let request = try ReadingComponentRequest.decode(data)
        guard name == "component_show", request.componentID != "book.scheme", let descriptor = registry.component(id: request.componentID) else {
            return try viewToolResult("unsupported", "这个组件没有安装，请从组件目录选择。")
        }
        guard !editorDirty, positionNoteRequest == nil, positionNoteBinding == nil else {
            return try viewToolResult("needs_confirmation", "请先保存或放弃正在编辑的笔记，或完成位置选择；没有切走。")
        }
        guard NSEvent.pressedMouseButtons == 0, canEditAISettings, !storageState.working, !isSavingDocument, !isCommittingLocalWrite else {
            return try viewToolResult("busy", "读者正在操作，稍后可再打开；没有抢占界面。")
        }
        let route: String
        var created = false
        if let viewID = request.viewID {
            guard let view = enabledViews.first(where: { $0.id == viewID && $0.configuration?["presentation"] != "inline" }),
                  descriptor.requiresDefinition ? view.rendererID == descriptor.id : registry.equivalent(view, descriptor) else {
                return try viewToolResult("unsupported", "本书没有这个已启用的组件视图；没有改动配置。")
            }
            route = view.id
        } else if descriptor.permanent {
            guard request.composition == nil else { throw ReadingError.invalid("这个组件不接受组合定义。") }
            route = descriptor.rendererID ?? descriptor.kind.rawValue
        } else if let existing = enabledViews.first(where: { view in
            guard view.configuration?["presentation"] != "inline" else { return false }
            if descriptor.requiresDefinition {
                return view.rendererID == descriptor.id && request.composition != nil && view.composition == request.composition && view.title == (request.title ?? "本书专属视图")
            }
            return request.composition == nil && registry.equivalent(view, descriptor)
        }) {
            // Navigation needs no canonical reload or publication. In
            // particular, repeated AI presentation must not invalidate graph
            // and composition preparations for unchanged book content.
            route = existing.id
        } else {
            guard descriptor.requiresDefinition == (request.composition != nil) else {
                return try viewToolResult("unsupported", "请提供组合定义，或选择已经保存的视图。")
            }
            if let definition = request.composition {
                try CompositionRuntime.validate(definition, in: book)
            }
            // Repeated tool calls reuse the same declaration; a single turn may
            // not fill the sidebar with unbounded generated pages.
            guard session.createdCount < 3 else { return try viewToolResult("busy", "这次已经加入三个组件，请先使用它们。") }
            let title = request.composition == nil ? descriptor.title : (request.title ?? "本书专属视图")
            let definition = ViewDefinition(id: "chat-component-" + UUID().uuidString, title: title, kind: descriptor.kind,
                rendererID: descriptor.rendererID, scope: "current", composition: request.composition)
            let saved = try await repository.ensureReadingComponent(bookID: book.id, sourceHash: book.sourceHash,
                view: definition, equivalentKinds: descriptor.aliases, grant: session.grant)
            // The atomic append may have completed before cancellation. Keep
            // it on disk, but never publish/navigate into a different owner.
            guard owner.matches(self) else { throw CancellationError() }
            publish(saved.project)
            route = saved.view.id; created = saved.created
            guard enabledViews.contains(where: { $0.id == route }) else {
                return try viewToolResult("conflict", "组件保存后界面已更新，请重新选择；没有打开旧视图。", extra: ["created": created, "opened": false])
            }
            if created { session.createdCount += 1 }
        }
        guard owner.matches(self) else { throw CancellationError() }
        // The repository append can suspend while the reader starts editing.
        // Keep any appended configuration, but never dismiss the new draft.
        guard !editorDirty, positionNoteRequest == nil, positionNoteBinding == nil else {
            return try viewToolResult("needs_confirmation", "组件配置已保留；请先完成笔记编辑或位置选择，未切换界面。",
                extra: ["viewID": route, "created": created, "opened": false, "analysisCreated": false])
        }
        requestedWorkspaceRoute = route
        for _ in 0..<75 {
            guard owner.matches(self) else { throw CancellationError() }
            let presented = route == "editor" ? isNotesForeground : (self.route == route && !hasWorkspaceAuxiliary)
            if presented && requestedWorkspaceRoute == nil {
                return try viewToolResult("success", created ? "已加入并打开组件；显示已有资料，尚未新增分析。" : "已打开已有组件；没有重复创建。",
                    extra: ["rendererID": descriptor.id, "componentTitle": descriptor.title, "viewID": route, "created": created, "opened": true, "analysisCreated": false])
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try viewToolResult("busy", created ? "组件配置已加入，但界面尚未完成打开。" : "界面尚未完成打开。",
            extra: ["viewID": route, "created": created, "opened": false, "analysisCreated": false])
    }
}
