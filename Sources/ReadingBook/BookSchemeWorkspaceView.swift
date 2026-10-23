import SwiftUI
import ReadingCore

/// One confirmation surface for AI planning, declaration upgrades and reusable templates.
struct BookSchemeWorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    var definition: ViewDefinition?
    @State private var tab = "scheme"
    @State private var selection: BookSchemeSelection?
    @State private var templateName = ""
    @State private var confirmation = ""
    @State private var templateToDelete: String?
    private var state: BookSchemeState { store.book?.bookSchemes ?? BookSchemeState() }
    private var pending: BookSchemeProposal? { state.pending }
    private var active: BookSchemeConfiguration? { store.book.map(BookSchemeConfiguration.init(project:)) }
    private var configuration: BookSchemeConfiguration? { pending?.proposed ?? active }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 18) {
                header
                Picker("方案内容", selection: $tab) {
                    Text("方案预览").tag("scheme"); Text("模板 · \(state.templates.count)").tag("templates"); Text("版本 · \(state.history.count)").tag("history")
                }.pickerStyle(.segmented).frame(maxWidth: 450).labelsHidden()
                if store.book == nil {
                    ContentUnavailableView("先选择一本书", systemImage: "book.closed", description: Text("书本方案按书保存，不改写用户知识和笔记。"))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if tab == "templates" { templates }
                            else if tab == "history" { history }
                            else if let configuration { scheme(configuration, wide: geometry.size.width >= 1080) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24)
                    }
                    if tab == "scheme", pending != nil { confirmationBar }
                }
            }.padding(.horizontal, 24).padding(.top, 96).padding(.bottom, 20)
        }.background(Palette.canvas.opacity(0.2))
            .onAppear { resetSelection() }
            .onChange(of: pending?.id) { _, _ in resetSelection() }
            .onChange(of: store.bookID) { _, _ in resetSelection(); tab = "scheme"; confirmation = ""; templateToDelete = nil }
            .confirmationDialog(confirmation == "revert" ? "撤销最近一次配置更新？" : confirmation == "template" ? "删除这个方案模板？" : "放弃待确认方案？", isPresented: Binding(get: { !confirmation.isEmpty }, set: { if !$0 { confirmation = "" } }), titleVisibility: .visible) {
                if confirmation == "revert" { Button("撤销配置更新") { store.revertBookScheme() } }
                else if confirmation == "template" { Button("删除模板", role: .destructive) { if let id = templateToDelete { store.deleteBookSchemeTemplate(id) } } }
                else { Button("放弃方案", role: .destructive) { store.discardBookScheme() } }
                Button("取消", role: .cancel) {}
            } message: { Text("只处理方案配置。原书、Markdown、知识对象和阅读回执保持原样；撤销遇到后续配置编辑会停止。") }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { heading; Spacer(minLength: 12); headerActions }
            VStack(alignment: .leading, spacing: 12) { heading; headerActions }
        }
    }
    private var heading: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 25)).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("书本方案").font(.system(size: 27, weight: .semibold))
                Text(pending == nil ? "配置如何读、显示什么，保留每次改变。" : "先看变更，再决定是否用于这本书。")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
        }
    }
    private var headerActions: some View {
        HStack(spacing: 10) {
            Button { store.importBookSchemeTemplate() } label: { Label("导入模板", systemImage: "square.and.arrow.down") }
                .buttonStyle(ReadingToolbarButtonStyle()).disabled(store.isBusy || pending != nil || store.book == nil)
            Button { store.makePlan() } label: { Label("AI 预读方案", systemImage: "sparkles") }
                .buttonStyle(ReadingToolbarButtonStyle(selected: true)).disabled(store.isBusy || pending != nil || store.book == nil)
        }
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
            Text(pending?.title ?? "\(store.book?.title ?? "本书")的阅读配置").font(.system(size: 22, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(configuration.plan?.rationale ?? "尚未选择读书法。可以生成 AI 预读方案，或导入适合的模板。")
                .font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let focus = configuration.plan?.focus, !focus.isEmpty {
                Divider()
                Text("本次关注").font(.system(size: 14, weight: .semibold))
                ForEach(Array(focus.enumerated()), id: \.offset) { item in
                    Label(item.element, systemImage: "smallcircle.filled.circle").font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let pending {
                Divider()
                ForEach(Array(pending.notes.enumerated()), id: \.offset) { item in Text(item.element).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text("逐段回执与已完成覆盖不会因方案切换而增加。")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).readingGlass(radius: 22)
    }
    private func definitions(_ configuration: BookSchemeConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionTitle("组件", subtitle: "决定本书工作区中有哪些界面；关闭入口不会删除其中的知识。", count: configuration.views.filter { !PluginEngine.isRetiredRenderer($0.rendererID ?? $0.id) }.count)
            if configuration.views.allSatisfy({ PluginEngine.isRetiredRenderer($0.rendererID ?? $0.id) }) { Text("尚未配置额外组件。").foregroundStyle(.secondary) }
            ForEach(configuration.views.filter { !PluginEngine.isRetiredRenderer($0.rendererID ?? $0.id) }) { view in
                Toggle(isOn: option(view.id, keyPath: \.viewIDs)) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: view.kind.icon).foregroundStyle(Palette.accent).frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(view.title).font(.system(size: 16, weight: .medium)); changeTag(view, old: pending?.before.views) }
                            Text(([view.kind.title, view.scope == "book" ? "全书" : "当前上下文"] + (view.rendererID.map { [$0] } ?? [])).joined(separator: " · "))
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if !view.typeIDs.isEmpty { Text("类型：" + view.typeIDs.compactMap { id in configuration.types.first { $0.id == id }?.name }.joined(separator: "、")).font(.system(size: 12)).foregroundStyle(.secondary) }
                        }
                    }.padding(.vertical, 4)
                }.toggleStyle(.switch).disabled(pending == nil || store.isBusy)
            }
            if let pending {
                ForEach(pending.before.views.filter { old in !configuration.views.contains { $0.id == old.id } }) { old in
                    Label("移除入口 · \(old.title)", systemImage: "minus.circle").foregroundStyle(.secondary).font(.system(size: 14))
                }
            }
            Divider()
            sectionTitle("实际执行的读书法", subtitle: "可组合多种方法；步骤使用已注册动作执行，逐段回执始终先行。", count: configuration.methods.filter { PluginEngine.isActiveMethod($0) }.count)
            ForEach(configuration.methods.filter { PluginEngine.isActiveMethod($0) }) { method in methodRow(method, configuration: configuration) }
            Divider()
            sectionTitle("卡片类型", subtitle: "已有类型保留原 ID；新增类型可选择，依赖它的组件须一并保持有效。", count: configuration.types.count)
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
                                Text("v\(old.version) → v\(plugin.version)").font(.system(size: 12)).foregroundStyle(Palette.accent)
                            }
                            Text(plugin.description).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(configuration.disabledPluginIDs.contains(plugin.id) ? "停用" : "启用").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Palette.line, lineWidth: 0.6))
    }
    private func methodRow(_ method: ReadingMethod, configuration: BookSchemeConfiguration) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(method.goal).font(.system(size: 14)).foregroundStyle(.secondary)
                ForEach(Array(method.steps.enumerated()), id: \.offset) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(step.offset + 1)").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.accent).frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.element).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                            Text(method.executions?.first { $0.stepIndex == step.offset }?.actionID ?? "ai.analyze").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(.vertical, 12)
        } label: {
            Toggle(isOn: option(method.id, keyPath: \.methodIDs)) {
                HStack { Text(method.name).font(.system(size: 16, weight: .medium)); changeTag(method, old: pending?.before.methods) }
            }.toggleStyle(.checkbox).disabled(pending == nil || store.isBusy)
        }
    }
    private func typeRow(_ type: EntityType) -> some View {
        let existing = pending?.before.types.contains { $0.id == type.id } ?? true
        return DisclosureGroup {
            Text(type.fields.isEmpty ? "通用卡片，没有额外声明字段。" : type.fields.map { "\($0.label)\($0.required ? "（必填）" : "") · \($0.key)" }.joined(separator: "\n"))
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 10).textSelection(.enabled)
        } label: {
            Toggle(isOn: option(type.id, keyPath: \.typeIDs)) {
                HStack(spacing: 8) { Image(systemName: type.icon).foregroundStyle(Palette.accent); Text(type.name).font(.system(size: 15)); if existing { Text("已保存").font(.system(size: 11)).foregroundStyle(.secondary) } else { Text("新增").font(.system(size: 11)).foregroundStyle(Palette.accent) } }
            }.toggleStyle(.checkbox).disabled(existing || pending == nil || store.isBusy)
        }
    }
    private var confirmationBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { Text("确认后启用这些配置").font(.system(size: 14)).foregroundStyle(.secondary); Spacer(); pendingActions }
            VStack(alignment: .leading, spacing: 12) { Text("确认后启用这些配置").font(.system(size: 14)).foregroundStyle(.secondary); pendingActions }
        }.padding(16).readingGlass(radius: 20)
    }
    private var pendingActions: some View {
        HStack(spacing: 10) {
            Button("放弃") { confirmation = "discard" }.buttonStyle(ReadingToolbarButtonStyle())
            Button("保存调整") { if let selection { store.saveBookSchemeSelection(selection) } }.buttonStyle(ReadingToolbarButtonStyle())
            Button { if let selection { store.applyBookScheme(selection) } } label: { Label("采纳方案", systemImage: "checkmark") }.buttonStyle(ReadingToolbarButtonStyle(selected: true))
        }.disabled(store.isBusy)
    }
    private var templates: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                TextField("为当前生效方案命名…", text: $templateName).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                Button { store.saveBookSchemeTemplate(name: templateName); templateName = "" } label: { Label("保存为模板", systemImage: "square.and.arrow.up") }
                    .buttonStyle(ReadingToolbarButtonStyle(selected: true)).disabled(store.isBusy || templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("模板只保存生效配置。待确认的调整请先采纳；导出后可在另一本书导入预览。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            if state.templates.isEmpty { ContentUnavailableView("还没有模板", systemImage: "square.stack.3d.up", description: Text("把适合历史、教材或研究资料的方案保存下来，下一本书可以继续调整。")) }
            ForEach(state.templates) { template in
                VStack(alignment: .leading, spacing: 14) {
                    Text(template.name).font(.system(size: 20, weight: .semibold))
                    Text("\(template.configuration.views.count) 个组件 · \(template.configuration.plan?.methodIDs.count ?? 0) 种执行方法 · \(template.configuration.types.count) 种类型").font(.system(size: 14)).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("预览使用") { store.stageBookSchemeTemplate(template); tab = "scheme" }.buttonStyle(ReadingToolbarButtonStyle(selected: true)).disabled(pending != nil)
                        Button("导出…") { store.exportBookSchemeTemplate(template) }.buttonStyle(ReadingToolbarButtonStyle())
                        Spacer()
                        Button { templateToDelete = template.id; confirmation = "template" } label: { Image(systemName: "trash") }.buttonStyle(ReadingToolbarButtonStyle()).help("删除模板")
                    }.disabled(store.isBusy)
                }.padding(22).readingGlass(radius: 22)
            }
        }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("最近 20 次采纳的配置版本；仅可安全撤销最近一次，后续编辑发生冲突时会停止。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            if state.history.isEmpty { ContentUnavailableView("还没有采纳记录", systemImage: "clock.arrow.circlepath", description: Text("原有配置继续有效，下一次采纳方案时会保存前后版本。")) }
            ForEach(state.history.reversed()) { revision in
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text(revision.title).font(.system(size: 20, weight: .semibold)); Spacer(); Text(revision.revertedAt == nil ? "已采纳" : "已撤销").font(.system(size: 13)).foregroundStyle(.secondary) }
                    Text(revision.appliedAt, style: .date).font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("组件 \(revision.before.views.count) → \(revision.after.views.count) · 执行方法 \(revision.before.plan?.methodIDs.count ?? 0) → \(revision.after.plan?.methodIDs.count ?? 0)").font(.system(size: 14))
                    DisclosureGroup("查看前后配置") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("之前：" + revision.before.views.map(\.title).joined(separator: "、"))
                            Text("之后：" + revision.after.views.map(\.title).joined(separator: "、"))
                            Text("方法：" + (revision.after.plan?.methodIDs ?? []).compactMap { id in revision.after.methods.first { $0.id == id }?.name }.joined(separator: "、"))
                        }.font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 10)
                    }
                    if revision.id == state.history.last(where: { $0.revertedAt == nil })?.id {
                        Button { confirmation = "revert" } label: { Label("撤销这次配置更新", systemImage: "arrow.uturn.backward") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.isBusy || pending != nil)
                    }
                }.padding(22).readingGlass(radius: 22)
            }
        }
    }
    private func sectionTitle(_ title: String, subtitle: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(.system(size: 20, weight: .semibold)); Text("\(count)").font(.system(size: 13)).foregroundStyle(.secondary) }
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func changeTag<T: Identifiable & Equatable>(_ value: T, old: [T]?) -> some View where T.ID == String {
        let prior = old?.first { $0.id == value.id }
        let text = old == nil ? "" : prior == nil ? "新增" : prior == value ? "保留" : "调整"
        return Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(prior == value ? Color.secondary : Palette.accent)
    }
    private func option(_ id: String, keyPath: WritableKeyPath<BookSchemeSelection, Set<String>>) -> Binding<Bool> {
        Binding(get: { (selection ?? configuration.map(BookSchemeSelection.init(configuration:)))?[keyPath: keyPath].contains(id) ?? false }, set: { value in
            guard var current = selection ?? configuration.map(BookSchemeSelection.init(configuration:)) else { return }
            if value { current[keyPath: keyPath].insert(id) } else { current[keyPath: keyPath].remove(id) }; selection = current
        })
    }
    private func resetSelection() { selection = pending?.selection ?? active.map(BookSchemeSelection.init(configuration:)) }
}
