import SwiftUI
import ReadingCore

/// One confirmation surface for AI planning, declaration upgrades and reusable templates.
struct BookSchemeWorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.bookSchemeDraftStore) private var sharedDrafts
    var definition: ViewDefinition?
    var onClose: (() -> Void)? = nil
    @StateObject private var localDrafts = BookSchemeViewDraftStore()
    var body: some View {
        BookSchemeWorkspaceContent(definition: definition, onClose: onClose, draft: (sharedDrafts ?? localDrafts).draft(for: store))
    }
}

@MainActor final class BookSchemeViewDraftStore: ObservableObject {
    private struct Key: Hashable { let owner: ObjectIdentifier; let bookID: String }
    private var values: [Key: BookSchemeViewDraft] = [:]
    fileprivate func draft(for store: AppStore) -> BookSchemeViewDraft {
        let key = Key(owner: ObjectIdentifier(store), bookID: store.bookID ?? "")
        if let value = values[key] { return value }
        let value = BookSchemeViewDraft(); value.reload(from: store.book); values[key] = value; return value
    }
}
private struct BookSchemeDraftStoreKey: EnvironmentKey { static let defaultValue: BookSchemeViewDraftStore? = nil }
extension EnvironmentValues {
    var bookSchemeDraftStore: BookSchemeViewDraftStore? {
        get { self[BookSchemeDraftStoreKey.self] }
        set { self[BookSchemeDraftStoreKey.self] = newValue }
    }
}

@MainActor fileprivate final class BookSchemeViewDraft: ObservableObject {
    @Published var tab = "scheme"
    @Published var selection: BookSchemeSelection?
    @Published var templateName = ""
    @Published var conflict = false
    private var signature = ""
    private var baseline: BookSchemeSelection?
    var isDirty: Bool {
        selection?.viewIDs != baseline?.viewIDs || selection?.typeIDs != baseline?.typeIDs || selection?.methodIDs != baseline?.methodIDs
    }
    static func signature(for book: BookProject?) -> String {
        guard let book else { return "" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let pending = book.bookSchemes?.pending, let data = try? encoder.encode(pending) { return data.base64EncodedString() }
        return (try? BookSchemeConfiguration(project: book).fingerprint()) ?? ""
    }
    func reconcile(with book: BookProject?) {
        guard signature != Self.signature(for: book) else { return }
        if isDirty && book?.bookSchemes?.pending != nil { conflict = true } else { reload(from: book) }
    }
    func reload(from book: BookProject?) {
        selection = book?.bookSchemes?.pending?.selection ?? book.map { BookSchemeSelection(configuration: BookSchemeConfiguration(project: $0)) }
        baseline = selection; signature = Self.signature(for: book); conflict = false
    }
}

private struct BookSchemeWorkspaceContent: View {
    @EnvironmentObject private var store: AppStore
    var definition: ViewDefinition?
    var onClose: (() -> Void)? = nil
    @ObservedObject var draft: BookSchemeViewDraft
    private var tab: String { get { draft.tab } nonmutating set { draft.tab = newValue } }
    private var selection: BookSchemeSelection? { get { draft.selection } nonmutating set { draft.selection = newValue } }
    private var templateName: String { get { draft.templateName } nonmutating set { draft.templateName = newValue } }
    @State private var confirmation = ""
    @State private var templateToDelete: String?
    private var state: BookSchemeState { store.book?.bookSchemes ?? BookSchemeState() }
    private var pending: BookSchemeProposal? { state.pending }
    private var active: BookSchemeConfiguration? { store.book.map(BookSchemeConfiguration.init(project:)) }
    private var configuration: BookSchemeConfiguration? { pending?.proposed ?? active }

    var body: some View {
        GeometryReader { geometry in
            let cardWidth = min(960, max(1, geometry.size.width - 40))
            let cardHeight = min(720, max(1, geometry.size.height - 40))
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.4)
                ManagementSegmentedControl(selection: $draft.tab, options: [
                    ManagementSegmentOption(id: "scheme", title: "方案预览", detail: "查看当前生效或待确认的书本方案。"),
                    ManagementSegmentOption(id: "templates", title: "模板 · \(state.templates.count)", detail: "保存、预览、导出或删除本书的方案模板。"),
                    ManagementSegmentOption(id: "history", title: "版本 · \(state.history.count)", detail: "查看已采纳的配置版本与可安全撤销的最近更新。")
                ]).frame(maxWidth: 450).padding(16).accessibilityIdentifier("book-scheme-tabs")
                if store.book == nil {
                    ContentUnavailableView("先选择一本书", systemImage: "book.closed", description: Text("书本方案按书保存，不改写用户知识和笔记。"))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if draft.conflict {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label("方案已在其他操作中更新，当前勾选已保留。重新载入后再调整和确认。", systemImage: "exclamationmark.circle")
                                        .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                                    Button("放弃当前勾选并重新载入") { draft.reload(from: store.book) }.buttonStyle(ReadingToolbarButtonStyle())
                                }.padding(16).background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                            }
                            if tab == "templates" { templates }
                            else if tab == "history" { history }
                            else if let configuration { scheme(configuration, wide: cardWidth >= 920) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 20)
                    }
                    if tab == "scheme", pending != nil { confirmationBar }
                    if tab == "templates" { templateEditor }
                }
            }.frame(width: cardWidth, height: cardHeight)
                .font(.system(size: 15))
                .readingGlass(radius: 22, prominent: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
            .onAppear { draft.reconcile(with: store.book) }
            .onChange(of: BookSchemeViewDraft.signature(for: store.book)) { _, _ in draft.reconcile(with: store.book) }
            .onChange(of: store.bookID) { _, _ in confirmation = ""; templateToDelete = nil }
            .onExitCommand(perform: close)
            .confirmationDialog(confirmation == "revert" ? "撤销最近一次配置更新？" : confirmation == "template" ? "删除这个方案模板？" : "放弃待确认方案？", isPresented: Binding(get: { !confirmation.isEmpty }, set: { if !$0 { confirmation = "" } }), titleVisibility: .visible) {
                if confirmation == "revert" { Button("撤销配置更新") { store.revertBookScheme() } }
                else if confirmation == "template" { Button("删除模板", role: .destructive) { if let id = templateToDelete { store.deleteBookSchemeTemplate(id) } } }
                else { Button("放弃方案", role: .destructive) { store.discardBookScheme() } }
                Button("取消", role: .cancel) {}
            } message: { Text("只处理方案配置。原书、Markdown、知识对象和阅读回执保持原样；撤销遇到后续配置编辑会停止。") }
    }

    private var header: some View {
        SettingsManagementHeader(title: "书本方案", icon: "slider.horizontal.3", dirty: draft.isDirty, onClose: close) {
            headerActions
        }
    }
    private var headerActions: some View {
        Menu {
            Button { store.importBookSchemeTemplate() } label: { Label("导入模板", systemImage: "square.and.arrow.down") }
            Button { store.makePlan() } label: { Label("AI 预读方案", systemImage: "sparkles") }
        } label: { ManagementMenuLabel(title: "更多", icon: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.visible).modifier(ManagementMenuSurface()).fixedSize()
            .help("导入方案模板，或用 AI 预读方案。待确认方案处理后可继续操作。")
            .accessibilityLabel("书本方案更多操作")
            .disabled(store.isBusy || pending != nil || store.book == nil)
    }
    private func close() {
        if let onClose { onClose() }
        else { store.requestedWorkspaceRoute = store.book == nil ? "library" : "reader" }
    }

    @ViewBuilder private func scheme(_ configuration: BookSchemeConfiguration, wide: Bool) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 20) {
                overview(configuration).frame(width: 320)
                definitions(configuration).frame(maxWidth: .infinity)
            }
        } else { overview(configuration); definitions(configuration) }
    }
    private func overview(_ configuration: BookSchemeConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(pending == nil ? "当前生效" : "待确认", systemImage: pending == nil ? "checkmark.seal" : "circle.dashed")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.accent)
            Text(pending?.title ?? "\(store.book?.title ?? "本书")的阅读配置").font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(configuration.plan?.rationale ?? "尚未选择读书法。可以生成 AI 预读方案，或导入适合的模板。")
                .font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let focus = configuration.plan?.focus, !focus.isEmpty {
                Divider()
                Text("本次关注").font(.system(size: 14, weight: .semibold))
                ForEach(Array(focus.enumerated()), id: \.offset) { item in
                    Label(item.element, systemImage: "smallcircle.filled.circle").font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let pending {
                DisclosureGroup("方案说明") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(pending.notes.enumerated()), id: \.offset) { item in Text(item.element).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        Text("逐段回执与已完成覆盖不会因方案切换而增加。")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 10)
                }.font(.system(size: 14))
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line.opacity(0.6), lineWidth: 0.6))
    }
    private func definitions(_ configuration: BookSchemeConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionTitle("组件", subtitle: "选择本书使用的工作区。已有知识继续保留。", count: configuration.views.filter { !PluginEngine.isRetiredRenderer($0.rendererID ?? $0.id) }.count)
            if configuration.views.allSatisfy({ PluginEngine.isRetiredRenderer($0.rendererID ?? $0.id) }) { Text("尚未配置额外组件。").foregroundStyle(.secondary) }
            ForEach(configuration.views.filter { !PluginEngine.isRetiredRenderer($0.rendererID ?? $0.id) }) { view in
                Toggle(isOn: option(view.id, keyPath: \.viewIDs)) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: view.kind.icon).foregroundStyle(Palette.accent).frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(view.title).font(.system(size: 16, weight: .medium)); changeTag(view, old: pending?.before.views) }
                            Text([view.kind.title, view.scope == "book" ? "全书" : "当前上下文"].joined(separator: " · "))
                                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if !view.typeIDs.isEmpty { Text("类型：" + view.typeIDs.compactMap { id in configuration.types.first { $0.id == id }?.name }.joined(separator: "、")).font(.system(size: 13)).foregroundStyle(.secondary) }
                        }
                    }.padding(.vertical, 4).frame(minHeight: 44)
                }.toggleStyle(.switch).disabled(pending == nil || store.isBusy || draft.conflict)
                if let renderer = view.rendererID {
                    DisclosureGroup("组件详情") { Text(renderer).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }.font(.system(size: 13))
                }
            }
            if let pending {
                ForEach(pending.before.views.filter { old in !configuration.views.contains { $0.id == old.id } }) { old in
                    Label("移除入口 · \(old.title)", systemImage: "minus.circle").foregroundStyle(.secondary).font(.system(size: 15))
                }
            }
            Divider()
            sectionTitle("读书法", subtitle: "可组合多种方法，按步骤分析并记录阅读进度。", count: configuration.methods.filter { PluginEngine.isActiveMethod($0) }.count)
            ForEach(configuration.methods.filter { PluginEngine.isActiveMethod($0) }) { method in methodRow(method, configuration: configuration) }
            Divider()
            sectionTitle("卡片类型", subtitle: "选择新增类型。已有内容继续使用原来的定义。", count: configuration.types.count)
            ForEach(configuration.types) { type in typeRow(type) }
            if !configuration.plugins.isEmpty {
                Divider()
                sectionTitle("声明包", subtitle: "版本与启用状态随方案保存。已有卡片继续引用其原来的类型。", count: configuration.plugins.count)
                ForEach(configuration.plugins) { plugin in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "shippingbox").foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(plugin.name) · v\(plugin.version)").font(.system(size: 15, weight: .medium))
                            if let old = pending?.before.plugins.first(where: { $0.id == plugin.id }), old.version != plugin.version {
                                Text("v\(old.version) → v\(plugin.version)").font(.system(size: 13)).foregroundStyle(Palette.accent)
                            }
                            Text(plugin.description).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(configuration.disabledPluginIDs.contains(plugin.id) ? "停用" : "启用").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line, lineWidth: 0.6))
    }
    private func methodRow(_ method: ReadingMethod, configuration: BookSchemeConfiguration) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(method.goal).font(.system(size: 15)).foregroundStyle(.secondary)
                ForEach(Array(method.steps.enumerated()), id: \.offset) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(step.offset + 1)").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.accent).frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.element).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
                            let actionID = method.executions?.first { $0.stepIndex == step.offset }?.actionID ?? "ai.analyze"
                            Text(ReadingWorkflowRuntime.actions.first { $0.id == actionID }?.title ?? "已注册的执行动作").font(.system(size: 13)).foregroundStyle(.secondary)
                                .help(actionID)
                        }
                    }
                }
            }.padding(.vertical, 12)
        } label: {
            Toggle(isOn: option(method.id, keyPath: \.methodIDs)) {
                HStack { Text(method.name).font(.system(size: 16, weight: .medium)); changeTag(method, old: pending?.before.methods) }
            }.toggleStyle(.checkbox).frame(minHeight: 44).disabled(pending == nil || store.isBusy || draft.conflict)
        }
    }
    private func typeRow(_ type: EntityType) -> some View {
        let existing = pending?.before.types.contains { $0.id == type.id } ?? true
        return DisclosureGroup {
            Text(type.fields.isEmpty ? "通用卡片，没有额外声明字段。" : type.fields.map { "\($0.label)\($0.required ? "（必填）" : "") · \($0.key)" }.joined(separator: "\n"))
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 10).textSelection(.enabled)
        } label: {
            Toggle(isOn: option(type.id, keyPath: \.typeIDs)) {
                HStack(spacing: 8) { Image(systemName: type.icon).foregroundStyle(Palette.accent); Text(type.name).font(.system(size: 15)); if existing { Text("已保存").font(.system(size: 13)).foregroundStyle(.secondary) } else { Text("新增").font(.system(size: 13)).foregroundStyle(Palette.accent) } }
            }.toggleStyle(.checkbox).frame(minHeight: 44).disabled(existing || pending == nil || store.isBusy || draft.conflict)
        }
    }
    private var confirmationBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            pendingActions.padding(14).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
    private var pendingActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { discardAction; saveAdjustmentsAction; acceptAction; if canConfirmAndStart { confirmAndStartAction } }
            VStack(spacing: 8) {
                HStack { discardAction; saveAdjustmentsAction; Spacer(minLength: 0) }
                HStack { Spacer(minLength: 0); acceptAction; if canConfirmAndStart { confirmAndStartAction } }
            }
        }.disabled(store.isBusy)
    }
    private var canConfirmAndStart: Bool { pending?.origin == "ai" && store.book?.smartReading != nil }
    private var discardAction: some View { Button("放弃") { confirmation = "discard" }.buttonStyle(ReadingToolbarButtonStyle()) }
    private var saveAdjustmentsAction: some View {
        Button("保存调整") { if let selection { store.saveBookSchemeSelection(selection, onSaved: { draft.reload(from: store.book) }) } }
            .buttonStyle(ReadingToolbarButtonStyle()).disabled(draft.conflict)
    }
    private var acceptAction: some View {
        Button { if let selection { store.applyBookScheme(selection) } } label: { Label("仅采纳方案", systemImage: "checkmark") }
            .buttonStyle(ReadingToolbarButtonStyle(selected: true)).disabled(draft.conflict)
    }
    private var confirmAndStartAction: some View {
        Button { if let selection { store.confirmSmartReading(selection) } } label: { Label("确认并开始分析", systemImage: "sparkles") }
            .buttonStyle(.borderedProminent).controlSize(.large).frame(minHeight: 44).disabled(draft.conflict)
    }
    private var templateEditor: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            HStack(spacing: 12) {
                TextField("为当前生效方案命名…", text: $draft.templateName).textFieldStyle(.plain).font(.system(size: 15))
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(Palette.paper.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 0.6))
                    .disabled(store.isBusy)
                Button { let submitted = templateName; store.saveBookSchemeTemplate(name: submitted, onSaved: { if templateName == submitted { templateName = "" } }) } label: { Label("保存模板", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent).controlSize(.large).frame(minHeight: 44)
                    .disabled(store.isBusy || templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(14)
        }
    }

    private var templates: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("模板只保存生效配置。待确认的调整请先采纳；导出后可在另一本书导入预览。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if state.templates.isEmpty { EmptyState(title: "还没有模板", detail: "保存合适的方案，下本书继续使用。", icon: "square.stack.3d.up").frame(maxWidth: .infinity, minHeight: 260) }
            ForEach(state.templates) { template in
                VStack(alignment: .leading, spacing: 14) {
                    Text(template.name).font(.system(size: 16, weight: .semibold))
                    Text("\(template.configuration.views.count) 个组件 · \(template.configuration.plan?.methodIDs.count ?? 0) 种执行方法 · \(template.configuration.types.count) 种类型").font(.system(size: 15)).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("预览使用") { store.stageBookSchemeTemplate(template); tab = "scheme" }.buttonStyle(ReadingToolbarButtonStyle(selected: true)).disabled(pending != nil)
                        Button("导出…") { store.exportBookSchemeTemplate(template) }.buttonStyle(ReadingToolbarButtonStyle())
                        Spacer()
                        Button { templateToDelete = template.id; confirmation = "template" } label: { Image(systemName: "trash") }.buttonStyle(ReadingToolbarButtonStyle()).help("删除模板")
                    }.disabled(store.isBusy)
                }.padding(16).background(Palette.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line.opacity(0.6), lineWidth: 0.6))
            }
        }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("最近 20 次采纳的配置版本；仅可安全撤销最近一次，后续编辑发生冲突时会停止。")
                .font(.system(size: 15)).foregroundStyle(.secondary)
            if state.history.isEmpty { EmptyState(title: "还没有采纳记录", detail: "采纳方案后，会在这里留下版本。", icon: "clock.arrow.circlepath").frame(maxWidth: .infinity, minHeight: 260) }
            ForEach(state.history.reversed()) { revision in
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text(revision.title).font(.system(size: 16, weight: .semibold)); Spacer(); Text(revision.revertedAt == nil ? "已采纳" : "已撤销").font(.system(size: 13)).foregroundStyle(.secondary) }
                    Text(revision.appliedAt, style: .date).font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("组件 \(revision.before.views.count) → \(revision.after.views.count) · 执行方法 \(revision.before.plan?.methodIDs.count ?? 0) → \(revision.after.plan?.methodIDs.count ?? 0)").font(.system(size: 15))
                    DisclosureGroup("查看前后配置") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("之前：" + revision.before.views.map(\.title).joined(separator: "、"))
                            Text("之后：" + revision.after.views.map(\.title).joined(separator: "、"))
                            Text("方法：" + readingMethodNames(revision.after))
                        }.font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 10)
                    }
                    if revision.id == state.history.last(where: { $0.revertedAt == nil })?.id {
                        Button { confirmation = "revert" } label: { Label("撤销这次配置更新", systemImage: "arrow.uturn.backward") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.isBusy || pending != nil)
                    }
                }.padding(16).background(Palette.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line.opacity(0.6), lineWidth: 0.6))
            }
        }
    }
    private func sectionTitle(_ title: String, subtitle: String, count: Int) -> some View {
        HStack { Text(title).font(.system(size: 16, weight: .semibold)); Text("\(count)").font(.system(size: 13)).foregroundStyle(.secondary) }
            .help(subtitle).accessibilityHint(subtitle)
    }
    private func readingMethodNames(_ configuration: BookSchemeConfiguration) -> String {
        let ids: [String] = configuration.plan?.methodIDs ?? []
        let names: [String] = ids.compactMap { id in configuration.methods.first(where: { $0.id == id })?.name }
        return names.joined(separator: "、")
    }
    private func changeTag<T: Identifiable & Equatable>(_ value: T, old: [T]?) -> some View where T.ID == String {
        let prior = old?.first { $0.id == value.id }
        let text = old == nil ? "" : prior == nil ? "新增" : prior == value ? "保留" : "调整"
        return Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(prior == value ? Color.secondary : Palette.accent)
    }
    private func option(_ id: String, keyPath: WritableKeyPath<BookSchemeSelection, Set<String>>) -> Binding<Bool> {
        Binding(get: { (selection ?? configuration.map(BookSchemeSelection.init(configuration:)))?[keyPath: keyPath].contains(id) ?? false }, set: { value in
            guard var current = selection ?? configuration.map(BookSchemeSelection.init(configuration:)) else { return }
            if value { current[keyPath: keyPath].insert(id) } else { current[keyPath: keyPath].remove(id) }; selection = current
        })
    }
}
