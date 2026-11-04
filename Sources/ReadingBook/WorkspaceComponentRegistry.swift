import SwiftUI
import ReadingCore

struct WorkspaceComponentDescriptor: Identifiable {
    var id: String { rendererID ?? kind.rawValue }
    var kind: ComponentKind
    var title: String
    var icon: String
    var aliases: Set<ComponentKind>
    var permanent = false
    var rendererID: String?
    var requiresDefinition = false
    var purpose: String {
        switch id {
        case "reading.layers": return "对照原文、译文与解释"
        case "reading.atlas": return "查看本书内容与阅读进展概览"
        case "reading.composition": return "将人物列表、关系图谱、时间轴、地图和原文等现有元件组合成联动视图"
        default:
            switch kind {
            case .cards: return "人物、地点、概念与事件卡片"
            case .map, .timeline: return "按时间和地点梳理书中线索"
            case .mindmap: return "梳理已有文档的分支结构与联系"
            case .relations: return "梳理人物、事件和概念之间有原文依据的关系"
            case .knowledge: return "集中查看本书已保存的资料"
            case .editor: return "查看与编辑读者笔记"
            case .query: return "围绕原文继续对话"
            case .workflow: return "选择原文范围并继续智能阅读"
            }
        }
    }
    init(kind: ComponentKind, title: String, icon: String, aliases: Set<ComponentKind> = [], permanent: Bool = false, rendererID: String? = nil) {
        self.kind = kind; self.title = title; self.icon = icon; self.aliases = aliases
        self.permanent = permanent; self.rendererID = rendererID
    }
}

/// Rendering, discovery and navigation consume the same registrations.
/// A compiled extension contributes a renderer through this interface; the shell
/// never selects a concrete component in a central switch.
@MainActor protocol WorkspaceComponentPlugin {
    var id: String { get }
    func register(in registry: inout WorkspaceComponentRegistry) throws
}

@MainActor struct WorkspaceComponentRegistry {
    private struct Entry {
        var descriptor: WorkspaceComponentDescriptor
        var render: (ViewDefinition?) -> AnyView
    }
    private var entries: [String: Entry] = [:]
    private var aliases: [ComponentKind: String] = [:]
    private var order: [String] = []
    static let shared: WorkspaceComponentRegistry = {
        var registry = WorkspaceComponentRegistry()
        do {
            try registry.install(BuiltInWorkspacePlugin())
            try registry.install(ReadingExperienceWorkspacePlugin())
            try registry.install(BookToolsWorkspacePlugin())
        }
        catch { preconditionFailure("内置组件注册失败：\(error)") }
        return registry
    }()
    var components: [WorkspaceComponentDescriptor] { order.compactMap { entries[$0]?.descriptor } }
    mutating func install(_ plugin: any WorkspaceComponentPlugin) throws {
        var staged = self; try plugin.register(in: &staged); self = staged
    }
    mutating func register(_ descriptor: WorkspaceComponentDescriptor, render: @escaping (ViewDefinition?) -> AnyView) throws {
        // Namespaced renderers can share a legacy fallback kind without claiming its navigation aliases.
        let keys: Set<ComponentKind> = descriptor.rendererID == nil ? descriptor.aliases.union([descriptor.kind]) : []
        guard !descriptor.id.isEmpty, entries[descriptor.id] == nil, keys.allSatisfy({ aliases[$0] == nil }) else { throw ReadingError.invalid("组件或别名已注册：\(descriptor.id)") }
        entries[descriptor.id] = Entry(descriptor: descriptor, render: render); order.append(descriptor.id)
        for kind in keys { aliases[kind] = descriptor.id }
    }
    func component(for kind: ComponentKind) -> WorkspaceComponentDescriptor? { aliases[kind].flatMap { entries[$0]?.descriptor } }
    func component(id: String) -> WorkspaceComponentDescriptor? { entries[id]?.descriptor }
    func render(id: String) -> AnyView? {
        guard !PluginEngine.isRetiredRenderer(id) else { return nil }
        return entries[id]?.render(nil)
    }
    func component(for view: ViewDefinition) -> WorkspaceComponentDescriptor? {
        guard !PluginEngine.isRetiredRenderer(view.rendererID ?? view.id) else { return nil }
        if let id = view.rendererID {
            return entries[id]?.descriptor ?? WorkspaceComponentDescriptor(kind: view.kind, title: view.title, icon: "puzzlepiece.extension", rendererID: id)
        }
        return component(for: view.kind)
    }
    func render(_ definition: ViewDefinition?, kind: ComponentKind) -> AnyView? {
        if let definition, PluginEngine.isRetiredRenderer(definition.rendererID ?? definition.id) { return nil }
        if let definition, let id = definition.rendererID {
            if let entry = entries[id] { return entry.render(definition) }
            return AnyView(ContentUnavailableView(definition.title, systemImage: "puzzlepiece.extension", description: Text("组件 \(id) 尚未安装。内容与配置已保留，安装对应插件后可继续查看。")))
        }
        return aliases[kind].flatMap { entries[$0]?.render(definition) }
    }
    func equivalent(_ lhs: ComponentKind, _ rhs: ComponentKind) -> Bool {
        guard let componentID = aliases[lhs] else { return false }
        return componentID == aliases[rhs]
    }
    func equivalent(_ lhs: ViewDefinition, _ rhs: ViewDefinition) -> Bool { rendererIdentity(lhs) == rendererIdentity(rhs) }
    func equivalent(_ view: ViewDefinition, _ descriptor: WorkspaceComponentDescriptor) -> Bool { rendererIdentity(view) == descriptor.id }
    private func rendererIdentity(_ view: ViewDefinition) -> String {
        // Each AI-composed page has its own layout and data bindings. It is not
        // an alias for every other page handled by the composition renderer.
        if view.rendererID == "reading.composition" { return "reading.composition:" + view.id }
        return view.rendererID ?? aliases[view.kind] ?? view.kind.rawValue
    }
    func removalIDs(for view: ViewDefinition, in views: [ViewDefinition]) -> Set<String> {
        // Navigation coalesces book-wide renderers. Remove the same group so an
        // old hidden alias cannot reappear immediately after removing its entry.
        // Filtered card collections remain independent entries.
        guard rendererIdentity(view) != aliases[.cards] else { return [view.id] }
        return Set(views.filter { $0.id == view.id || equivalent($0, view) }.map(\.id))
    }
    func navigationViews(_ views: [ViewDefinition]) -> [ViewDefinition] {
        var seen = Set<String>()
        return views.filter { view in
            guard view.configuration?["presentation"] != "inline" else { return false }
            guard let descriptor = component(for: view), !descriptor.permanent else { return false }
            // Card collections may intentionally filter different types. Other
            // current renderers share book-wide state and need one navigation entry.
            if rendererIdentity(view) == aliases[.cards] { return true }
            return seen.insert(rendererIdentity(view)).inserted
        }
    }
}

@MainActor private struct BookToolsWorkspacePlugin: WorkspaceComponentPlugin {
    let id = "builtin.book-tools"
    func register(in registry: inout WorkspaceComponentRegistry) throws {
        try registry.register(WorkspaceComponentDescriptor(kind: .workflow, title: "书本方案", icon: "slider.horizontal.3", permanent: true, rendererID: "book.scheme")) { AnyView(BookSchemeWorkspaceView(definition: $0)) }
    }
}

@MainActor private struct ReadingExperienceWorkspacePlugin: WorkspaceComponentPlugin {
    let id = "builtin.reading-experience"
    func register(in registry: inout WorkspaceComponentRegistry) throws {
        try registry.register(WorkspaceComponentDescriptor(kind: .knowledge, title: "多层伴读", icon: "text.book.closed", rendererID: "reading.layers")) { AnyView(ReadingExperienceWorkspaceView(section: "layers", definition: $0)) }
        try registry.register(WorkspaceComponentDescriptor(kind: .knowledge, title: "全书总览", icon: "chart.bar.xaxis", rendererID: "reading.atlas")) { AnyView(ReadingAtlasView(definition: $0)) }
        var composed = WorkspaceComponentDescriptor(kind: .knowledge, title: "本书专属组件", icon: "square.grid.2x2", rendererID: "reading.composition")
        composed.requiresDefinition = true
        try registry.register(composed) { AnyView(CompositionWorkspaceView(definition: $0)) }
    }
}

@MainActor private struct BuiltInWorkspacePlugin: WorkspaceComponentPlugin {
    let id = "builtin.workspace"
    func register(in registry: inout WorkspaceComponentRegistry) throws {
        try registry.register(WorkspaceComponentDescriptor(kind: .cards, title: "要素卡片", icon: ComponentKind.cards.icon, aliases: [])) { AnyView(EntityCardsView(typeIDs: $0?.typeIDs ?? [])) }
        try registry.register(WorkspaceComponentDescriptor(kind: .map, title: "时间与地图", icon: ComponentKind.map.icon, aliases: [.timeline])) { _ in AnyView(SpatialTimelineView()) }
        try registry.register(WorkspaceComponentDescriptor(kind: .mindmap, title: "思维导图", icon: ComponentKind.mindmap.icon, aliases: [])) { _ in AnyView(DocumentGraphView()) }
        try registry.register(WorkspaceComponentDescriptor(kind: .relations, title: "关系图谱", icon: ComponentKind.relations.icon, aliases: [])) { _ in AnyView(RelationGraphView()) }
        try registry.register(WorkspaceComponentDescriptor(kind: .knowledge, title: "知识库", icon: ComponentKind.knowledge.icon, aliases: [])) { _ in AnyView(KnowledgeLibraryView()) }
        try registry.register(WorkspaceComponentDescriptor(kind: .editor, title: "我的笔记", icon: ComponentKind.editor.icon, aliases: [], permanent: true)) { _ in AnyView(DocumentEditorView()) }
        try registry.register(WorkspaceComponentDescriptor(kind: .query, title: "与书对话", icon: ComponentKind.query.icon, aliases: [], permanent: true)) { _ in AnyView(EnhancedBookChatView()) }
        try registry.register(WorkspaceComponentDescriptor(kind: .workflow, title: "智能阅读", icon: ComponentKind.workflow.icon, aliases: [], permanent: true)) { _ in AnyView(ReaderMethodView()) }
    }
}
