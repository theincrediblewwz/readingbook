import AppKit
import Foundation
import ReadingCore

/// A mounted workspace reports its actual unobscured canvas. Route equality
/// alone cannot prove that a component is visible behind settings or a sheet.
struct ReadingComponentPresentation: Equatable {
    let mountID: UUID
    let root: URL
    let bookID: String?
    let sourceHash: String?
    let route: String
    let unobscured: Bool
    @MainActor func matches(_ store: AppStore, route expected: String) -> Bool {
        let foreground = expected == "editor" ? store.isNotesForeground : (store.route == expected && !store.hasWorkspaceAuxiliary)
        return unobscured && foreground && root == store.libraryRootURL && bookID == store.bookID && sourceHash == store.book?.sourceHash
            && route == expected
            && !store.showingSettings && !store.showingPlugins && !store.showingOCR
            && store.errorMessage == nil && store.deletionRequest == nil
            && NSApp?.modalWindow == nil && NSApp?.keyWindow?.attachedSheet == nil
    }
}

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
    let snapshot: ReadingQuerySnapshot?
    let context: ReadingContext?
    init(grant: ControlledWriteGrant? = nil, snapshot: ReadingQuerySnapshot? = nil, context: ReadingContext? = nil) {
        self.grant = grant; self.snapshot = snapshot; self.context = context
    }
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
                "templates": ReadingWorkbench.templateIDs.map { id in ["id": id, "componentID": "reading.composition", "title": ReadingWorkbench.title(for: id), "purpose": id == ReadingWorkbench.timeMapTemplateID ? "可选布局：地图、事件先后与人物详情联动，共用本书资料。" : "人物/关系/相关事件/读者笔记联动；选择一个人物时一起查看，已保存工作台复用。"] },
                "customComponents": "只能组合现有元件，不执行代码；打开的组件沿用这次提问的原文范围，正文读取仍限本次授权。"])
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
        let composition = request.resolvedComposition
        if let viewID = request.viewID {
            guard let view = enabledViews.first(where: { $0.id == viewID && $0.configuration?["presentation"] != "inline" }),
                  descriptor.requiresDefinition ? view.rendererID == descriptor.id : registry.equivalent(view, descriptor) else {
                return try viewToolResult("unsupported", "本书没有这个已启用的组件视图；没有改动配置。")
            }
            route = view.id
        } else if descriptor.permanent {
            guard composition == nil else { throw ReadingError.invalid("这个组件不接受组合定义。") }
            route = descriptor.rendererID ?? descriptor.kind.rawValue
        } else if let existing = enabledViews.first(where: { view in
            guard view.configuration?["presentation"] != "inline" else { return false }
            if descriptor.requiresDefinition {
                return view.rendererID == descriptor.id && composition != nil && view.composition == composition && (request.templateID != nil || view.title == (request.title ?? "本书专属视图"))
            }
            return composition == nil && registry.equivalent(view, descriptor)
        }) {
            // Navigation needs no canonical reload or publication. In
            // particular, repeated AI presentation must not invalidate graph
            // and composition preparations for unchanged book content.
            route = existing.id
        } else {
            guard descriptor.requiresDefinition == (composition != nil) else {
                return try viewToolResult("unsupported", "请提供组合定义，或选择已经保存的视图。")
            }
            if let definition = composition {
                try CompositionRuntime.validate(definition, in: book)
            }
            // Repeated tool calls reuse the same declaration; a single turn may
            // not fill the sidebar with unbounded generated pages.
            guard session.createdCount < 3 else { return try viewToolResult("busy", "这次已经加入三个组件，请先使用它们。") }
            let title = composition == nil ? descriptor.title : (request.title ?? request.templateID.map { ReadingWorkbench.title(for: $0) } ?? "本书专属视图")
            let definition = ViewDefinition(id: "chat-component-" + UUID().uuidString, title: title, kind: descriptor.kind,
                rendererID: descriptor.rendererID, scope: "current", composition: composition)
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
        guard requestedWorkspaceRoute == nil || requestedWorkspaceRoute == route else {
            return try viewToolResult("busy", "已有其他界面切换正在处理，未覆盖这次操作。",
                extra: ["viewID": route, "created": created, "opened": false, "analysisCreated": false])
        }
        if let snapshot = session.snapshot {
            let current = readingComponentView
            if current?.route != route || current?.snapshot?.scopeFingerprint != snapshot.scopeFingerprint {
                try installComponentView(route: route, snapshot: snapshot, context: session.context)
            }
        }
        func openedResult() throws -> Data {
            try viewToolResult("success", created ? "已加入并打开组件；显示已有资料，尚未新增分析。" : "已打开已有组件；没有重复创建。",
                extra: ["rendererID": descriptor.id, "componentTitle": self.book?.views.first(where: { $0.id == route })?.title ?? descriptor.title, "viewID": route, "created": created, "opened": true, "analysisCreated": false,
                    "confirmationOnly": request.confirmationOnly == true,
                    "sourceScope": session.snapshot?.displayTitle ?? "跟随阅读位置",
                    "displayPurpose": descriptor.purpose])
        }
        if renderedComponentPresentation?.matches(self, route: route) == true {
            // Repeated same-route intentions can be coalesced by onChange.
            // A genuine presentation needs neither a new navigation nor another
            // whole-workspace update; clear only an identical redundant intent.
            if requestedWorkspaceRoute == route { requestedWorkspaceRoute = nil }
            return try openedResult()
        }
        requestedWorkspaceRoute = route
        for _ in 0..<75 {
            guard owner.matches(self) else { throw CancellationError() }
            if renderedComponentPresentation?.matches(self, route: route) == true && requestedWorkspaceRoute == nil {
                return try openedResult()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try viewToolResult("busy", created ? "组件配置已加入，但界面尚未完成打开。" : "界面尚未完成打开。",
            extra: ["viewID": route, "created": created, "opened": false, "analysisCreated": false])
    }
}
