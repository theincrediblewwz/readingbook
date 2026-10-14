import SwiftUI
import ReadingCore

struct WorkspaceComponentDescriptor: Identifiable {
    var id: String { kind.rawValue }
    var kind: ComponentKind
    var title: String
    var icon: String
    var aliases: Set<ComponentKind>
    var permanent = false
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
        do { try registry.install(BuiltInWorkspacePlugin()) }
        catch { preconditionFailure("内置组件注册失败：\(error)") }
        return registry
    }()
    var components: [WorkspaceComponentDescriptor] { order.compactMap { entries[$0]?.descriptor } }
    mutating func install(_ plugin: any WorkspaceComponentPlugin) throws {
        var staged = self; try plugin.register(in: &staged); self = staged
    }
    mutating func register(_ descriptor: WorkspaceComponentDescriptor, render: @escaping (ViewDefinition?) -> AnyView) throws {
        let keys = descriptor.aliases.union([descriptor.kind])
        guard entries[descriptor.id] == nil, keys.allSatisfy({ aliases[$0] == nil }) else { throw ReadingError.invalid("组件或别名已注册：\(descriptor.id)") }
        entries[descriptor.id] = Entry(descriptor: descriptor, render: render); order.append(descriptor.id)
        for kind in keys { aliases[kind] = descriptor.id }
    }
    func component(for kind: ComponentKind) -> WorkspaceComponentDescriptor? { aliases[kind].flatMap { entries[$0]?.descriptor } }
    func render(_ definition: ViewDefinition?, kind: ComponentKind) -> AnyView? { aliases[kind].flatMap { entries[$0]?.render(definition) } }
    func equivalent(_ lhs: ComponentKind, _ rhs: ComponentKind) -> Bool {
        guard let componentID = aliases[lhs] else { return false }
        return componentID == aliases[rhs]
    }
    func removalIDs(for view: ViewDefinition, in views: [ViewDefinition]) -> Set<String> {
        // Navigation coalesces book-wide renderers. Remove the same group so an
        // old hidden alias cannot reappear immediately after removing its entry.
        // Filtered card collections remain independent entries.
        guard view.kind != .cards else { return [view.id] }
        return Set(views.filter { $0.id == view.id || equivalent($0.kind, view.kind) }.map(\.id))
    }
    func navigationViews(_ views: [ViewDefinition]) -> [ViewDefinition] {
        var seen = Set<String>()
        return views.filter { view in
            guard let descriptor = component(for: view.kind), !descriptor.permanent else { return false }
            // Card collections may intentionally filter different types. Other
            // current renderers share book-wide state and need one navigation entry.
            if view.kind == .cards { return true }
            return seen.insert(descriptor.id).inserted
        }
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
        try registry.register(WorkspaceComponentDescriptor(kind: .editor, title: "我的理解", icon: ComponentKind.editor.icon, aliases: [], permanent: true)) { _ in AnyView(DocumentEditorView()) }
        try registry.register(WorkspaceComponentDescriptor(kind: .query, title: "与书对话", icon: ComponentKind.query.icon, aliases: [], permanent: true)) { _ in AnyView(EnhancedBookChatView()) }
        try registry.register(WorkspaceComponentDescriptor(kind: .workflow, title: "阅读流程", icon: ComponentKind.workflow.icon, aliases: [], permanent: true)) { _ in AnyView(ReadingWorkflowView()) }
    }
}
