import SwiftUI
import ReadingCore

/// The same real profile editor serves the floating workspace and macOS Settings.
struct ProviderSettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    var onClose: (() -> Void)? = nil
    @State private var deletingService = false
    @State private var showAdvanced = false
    @State private var showNotes = false
    @State private var showServices = true
    @State private var confirmingClose = false
    @State private var showingCatalog = false
    @State private var showingGuide = false
    @State private var presentationSize = CGSize(width: 960, height: 720)

    var body: some View {
        GeometryReader { geometry in
            // A system sheet already supplies its window surface. Fill it so
            // it does not surround another inset card with a second frame.
            let inset: CGFloat = embedded ? 40 : 0
            let cardWidth = min(860, max(1, geometry.size.width - inset))
            let cardHeight = min(680, max(1, geometry.size.height - inset))
            let wide = cardWidth >= 800
            VStack(spacing: 0) {
                SettingsManagementHeader(title: "模型设置", icon: "sparkles", dirty: store.serviceProfileDraft.isDirty(in: store), onClose: requestClose) {
                    if wide {
                        DockIconButton(title: showServices ? "收起我的服务" : "展开我的服务", icon: "sidebar.left", isSelected: showServices) { showServices.toggle() }
                    }
                }
                Divider().opacity(0.4)
                HStack(spacing: 0) {
                    if wide && showServices {
                        serviceList.frame(width: 240)
                        Divider().opacity(0.4)
                    }
                    modelConfiguration(wide: wide && showServices).frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(width: cardWidth, height: cardHeight)
                .font(.system(size: 15))
                .readingGlass(radius: 22, prominent: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { presentationSize = geometry.size }
                .onChange(of: geometry.size) { _, size in presentationSize = size }
        }
        .confirmationDialog("删除已保存的服务配置与其密钥？", isPresented: $deletingService) {
            Button("删除配置", role: .destructive) { if let id = store.selectedServiceID { store.removeService(id) } }
        } message: { Text("书籍、文档与已生成内容会保留。") }
        .serviceProfileChangeConfirmation(store: store, isSettingsContext: true)
        .interactiveDismissDisabled(store.serviceProfileDraft.isDirty(in: store))
        .onExitCommand { requestClose() }
        .confirmationDialog("保存模型配置后关闭？", isPresented: $confirmingClose, titleVisibility: .visible) {
            Button("保存并关闭") {
                store.saveServiceProfileForUI()
                if !store.serviceProfileDraft.isDirty(in: store) { close() }
            }.disabled(store.isBusy)
            Button("放弃更改并关闭", role: .destructive) {
                if store.discardServiceDraftForNavigation() { close() }
            }.disabled(store.isBusy)
            Button("继续编辑", role: .cancel) { }
        } message: { Text("本次修改尚未保存。保存失败时会留在这里，并保留输入。") }
        .onAppear { store.serviceProfileDraft.settingsPresentationCount += 1 }
        .onDisappear { store.serviceProfileDraft.settingsPresentationCount = max(0, store.serviceProfileDraft.settingsPresentationCount - 1) }
        .sheet(isPresented: $showingCatalog) { ModelCatalogManagerView(onClose: { showingCatalog = false }, availableSize: presentationSize).environmentObject(store) }
        .sheet(isPresented: $showingGuide) { ReadingGuideView(onClose: { showingGuide = false }) }
    }

    private var serviceList: some View {
        VStack(spacing: 0) {
            Text("我的服务").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 44)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(store.savedServices) { service in
                        Button { store.selectService(service.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "link").font(.system(size: 20)).foregroundStyle(Palette.accent).frame(width: 26)
                                VStack(alignment: .leading, spacing: 4) {
                                Text(service.name).font(.system(size: 15, weight: .medium)).lineLimit(2)
                                    Text(service.settings.model).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if service.id == store.selectedServiceID { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent) }
                            }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                                .background(Palette.accent.opacity(service.id == store.selectedServiceID ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(store.isBusy)
                    }
                    if store.savedServices.isEmpty { Text("还没有保存的服务").font(.subheadline).foregroundStyle(.secondary).padding(16) }
                }.padding(10)
            }
            Divider().opacity(0.5)
            newServiceMenu.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func modelConfiguration(wide: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 8) {
                        if wide {
                            Text(store.serviceName.isEmpty ? "选择或新建服务" : store.serviceName).font(.system(size: 15, weight: .medium)).lineLimit(1)
                        } else {
                            Picker("服务", selection: Binding(get: { store.selectedServiceID ?? "" }, set: { store.selectService($0) })) {
                                if store.selectedServiceID == nil { Text("新的未保存配置").tag("") }
                                ForEach(store.savedServices) { Text($0.name).tag($0.id) }
                            }.labelsHidden().accessibilityLabel("已保存的服务").frame(maxWidth: .infinity)
                            newServiceMenu
                        }
                        Spacer(minLength: 0)
                        DockIconButton(title: "使用指南", icon: "questionmark.circle", isSelected: false) { showingGuide = true }
                        DockIconButton(title: "删除当前服务配置及密钥", icon: "trash", isSelected: false) { deletingService = true }
                            .disabled(store.selectedServiceID == nil || store.isBusy)
                    }
                    ServiceProfileLocalError(draft: store.serviceProfileDraft)
                    connectionFields
                    Divider().opacity(0.5)
                    budgetFields
                    Divider().opacity(0.5)
                    ocrFields
                    if !store.connectionStatus.isEmpty {
                        Label(store.connectionStatus, systemImage: "info.circle").font(.system(size: 14)).foregroundStyle(.secondary)
                            .textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(16)
            }
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                Button { showingCatalog = true } label: { Label("模型目录", systemImage: "square.stack.3d.up") }.buttonStyle(ReadingToolbarButtonStyle())
                Button { store.testConnection() } label: { Label("测试连接", systemImage: "play") }
                    .buttonStyle(ReadingToolbarButtonStyle()).disabled(store.isBusy || store.settings.model.isEmpty)
                Spacer(minLength: 0)
                Button { store.saveServiceProfileForUI() } label: { Label("保存配置", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).controlSize(.large).frame(minHeight: ReadingLayout.controlHeight).disabled(store.isBusy)
            }.padding(16)
        }.controlSize(.large)
    }

    private func requestClose() {
        if store.serviceProfileDraft.isDirty(in: store) { confirmingClose = true }
        else { close() }
    }
    private func close() {
        if let onClose { onClose() }
        else if embedded { store.requestedWorkspaceRoute = store.book == nil ? "library" : "reader" }
        else { dismiss() }
    }

    private var newServiceMenu: some View {
        Menu {
            Button { store.newService() } label: { Label("自定义兼容服务", systemImage: "server.rack") }
            Divider()
            ForEach(store.providerCatalog.providers) { provider in Button { store.newService(provider) } label: { Label(provider.name, systemImage: "network") } }
        } label: { Label("新建服务", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize()
            .padding(.horizontal, 12).frame(minHeight: ReadingLayout.controlHeight).disabled(store.isBusy)
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsFormRow("服务名称") { TextField("例如：我的 DeepSeek", text: $store.serviceName).settingsTextField() }
            SettingsFormRow("接口地址") { TextField("完整 HTTPS 或本机服务 URL", text: $store.settings.baseURL).settingsTextField() }
            SettingsFormRow("API Key") { SecureField("API Key", text: $store.apiKey).settingsTextField() }
            SettingsFormRow("模型 ID") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("精确模型 API ID", text: $store.settings.model).settingsTextField()
                    if let preset = store.matchingPreset {
                        Menu { ForEach(preset.models) { model in Button { store.chooseModel(model) } label: { Label(model.name, systemImage: "cpu") } } } label: { Label("选择已核实预设", systemImage: "cpu") }
                            .menuStyle(.borderlessButton).font(.system(size: 13)).fixedSize()
                    }
                }
            }
            if let note = store.matchingPreset?.note, !note.isEmpty {
                DisclosureGroup("服务说明") { Text(note).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8) }
                    .font(.system(size: 14))
            }
        }.disabled(store.isBusy)
    }

    private var budgetFields: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("输出与能力").font(.system(size: 16, weight: .semibold))
            SettingsFormRow("最大输出 Token") {
                HStack(spacing: 10) {
                    TextField("输出上限", value: $store.settings.maxOutputTokens, format: .number).settingsTextField()
                    Button("Max") { store.useMaximumOutput() }.buttonStyle(ReadingToolbarButtonStyle())
                        .background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        .disabled(store.matchingModel?.maxOutputTokens == nil)
                        .help("使用此精确型号已核实的输出上限；未知型号不能自动猜测")
                }
            }
            if let model = store.matchingModel {
                HStack(spacing: 12) {
                    Label(model.vision ? "支持图像输入" : "文本模型", systemImage: model.vision ? "photo" : "text.alignleft")
                    Text(model.tools ? "支持工具" : "工具能力未确认").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let url = URL(string: model.documentationURL) { Link("官方规格", destination: url) }
                }.font(.system(size: 13))
                Text("上下文 \(model.contextTokens.map { String($0) } ?? "未确认") · 输出上限 \(model.maxOutputTokens.map { String($0) } ?? "未确认") Token")
                    .font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text("未匹配已核实型号，Max 暂不可用；可手动设置参数并核对服务文档。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let preset = store.matchingPreset, let url = URL(string: preset.documentationURL) { Link("服务文档", destination: url).font(.system(size: 13)) }
            }
            Text("Max 设置输出上限，不保证写满；实际请求仍受上下文余量和账户限制。")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("高级设置", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsFormRow("上下文 Token") {
                        TextField("未知可留空", text: Binding(get: { store.settings.contextWindowTokens.map { String($0) } ?? "" }, set: { store.settings.contextWindowTokens = Int($0.replacingOccurrences(of: ",", with: "")) })).settingsTextField()
                    }
                    SettingsFormRow("输出参数") {
                        Picker("输出参数", selection: Binding(get: { store.settings.tokenLimitParameter ?? "max_tokens" }, set: { store.settings.tokenLimitParameter = $0 })) {
                            Text("max_tokens").tag("max_tokens")
                            Text("max_completion_tokens").tag("max_completion_tokens")
                        }.labelsHidden()
                    }
                    Stepper("每轮最多 \(store.settings.maxRequestsPerRun) 次请求", value: $store.settings.maxRequestsPerRun, in: 1...2000)
                    Text("推理模型的输出额度可能包含推理 Token。未知型号不自动推测。模型目录核查于 \(store.providerCatalog.verifiedAt.isEmpty ? "未记录" : store.providerCatalog.verifiedAt)。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }.padding(.top, 16)
            }.font(.system(size: 16, weight: .medium))
        }.disabled(store.isBusy)
    }

    private var ocrFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PDF 视觉识别").font(.system(size: 16, weight: .semibold))
            SettingsFormRow("图像模型服务") {
                Picker("图像模型服务", selection: Binding(get: { store.ocrServiceID ?? "" }, set: { store.ocrServiceID = $0.isEmpty ? nil : $0; UserDefaults.standard.set(store.ocrServiceID, forKey: "ocr-service") })) {
                    Text("当前阅读服务").tag("")
                    ForEach(store.savedServices) { service in Text("\(service.name) · \(service.settings.model)").tag(service.id) }
                }.labelsHidden().lineLimit(1).frame(maxWidth: .infinity)
            }
            DisclosureGroup("发送范围与测试说明", isExpanded: $showNotes) {
                Text("文本分析发送所需原文，OCR 发送所选 PDF 页图。OCR 需支持图像输入，可与文本阅读使用不同服务；逐页请求与保存，可暂停续跑。测试连接会发送一条短文本请求。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.system(size: 14))
        }.disabled(store.isBusy)
    }
}

struct PluginLibraryView: View {
    @EnvironmentObject private var store: AppStore
    var embedded = false
    var onClose: (() -> Void)? = nil
    var draftStore: PluginDefinitionDraftStore? = nil
    @StateObject private var localDraftStore = PluginDefinitionDraftStore()
    var body: some View {
        PluginLibraryWorkspace(embedded: embedded, onClose: onClose,
                               definitionDraft: (draftStore ?? localDraftStore).draft(for: store))
    }
}

private struct PluginLibraryWorkspace: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    var onClose: (() -> Void)? = nil
    @State private var search = ""
    @State private var tab = "installed"
    @State private var showDetails = false
    @ObservedObject var definitionDraft: PluginDefinitionDraft
    @State private var importError = ""
    @State private var componentError = ""
    @State private var componentNotice = ""
    @State private var pendingAddition: String?

    private var available: [WorkspaceComponentDescriptor] {
        WorkspaceComponentRegistry.shared.components.filter { !$0.permanent && !$0.requiresDefinition && store.savedComponent(for: $0) == nil && matches($0.title) }
    }
    private func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }

    var body: some View {
        GeometryReader { geometry in
            let cardWidth = min(900, max(1, geometry.size.width - 40))
            let cardHeight = min(680, max(1, geometry.size.height - 40))
            VStack(spacing: 0) {
                SettingsManagementHeader(title: "插件与组件", icon: "puzzlepiece.extension", dirty: definitionDraft.isDirty, onClose: { requestDefinitionAction(.close) }) { EmptyView() }
                Divider().opacity(0.4)
                pluginList
            }.frame(width: cardWidth, height: cardHeight)
                .font(.system(size: 15))
                .readingGlass(radius: 22, prominent: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(PluginDefinitionConfirmation(draft: definitionDraft, store: store, active: !showDetails, perform: performDefinitionAction))
                .sheet(isPresented: Binding(get: { showDetails }, set: { if !$0 { requestDefinitionAction(.hide) } })) {
                    VStack(spacing: 0) {
                        SettingsManagementHeader(title: "类型与阅读方法", icon: "slider.horizontal.3", dirty: definitionDraft.isDirty, onClose: { requestDefinitionAction(.hide) }) { EmptyView() }
                        Divider().opacity(0.4)
                        definitionPanel
                    }.frame(width: min(540, max(1, geometry.size.width - 64)), height: min(620, max(1, geometry.size.height - 64)))
                        .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 22))
                        .interactiveDismissDisabled(definitionDraft.isDirty || definitionDraft.saving)
                        .onExitCommand { requestDefinitionAction(.hide) }
                        .modifier(PluginDefinitionConfirmation(draft: definitionDraft, store: store, active: true, perform: performDefinitionAction))
                }
        }
        .interactiveDismissDisabled(definitionDraft.isDirty || definitionDraft.saving)
        .onAppear { definitionDraft.reconcile(in: store.book) }
        .onChange(of: store.book?.types) { _, _ in definitionDraft.reconcile(in: store.book) }
        .onChange(of: store.book?.methods) { _, _ in definitionDraft.reconcile(in: store.book) }
        .onExitCommand { requestDefinitionAction(.close) }
        .onChange(of: store.isBusy) { _, busy in
            guard !busy, let componentID = pendingAddition else { return }
            if let component = WorkspaceComponentRegistry.shared.component(id: componentID), store.installedComponent(for: component) != nil {
                componentNotice = "已添加\(component.title)，可从侧栏打开。"
            }
            pendingAddition = nil
        }
    }
    private var pluginList: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { pluginSearch; pluginFilter.frame(width: 180) }
                VStack(spacing: 12) { pluginSearch; pluginFilter }
            }.padding(16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !importError.isEmpty { settingsError(importError) }
                    if !componentError.isEmpty { settingsError(componentError) }
                    if !componentNotice.isEmpty { Label(componentNotice, systemImage: "checkmark.circle").font(.system(size: 14)).foregroundStyle(Palette.accent).padding(.vertical, 12) }
                    if tab == "available" {
                        ForEach(available) { component in capabilityRow(component, addOnly: true) }
                        if available.isEmpty { ContentUnavailableView(search.isEmpty ? "本书组件已经齐全" : "没有匹配的组件", systemImage: "checkmark.circle", description: Text("已添加的组件不会重复出现在这里。")) }
                    } else {
                        ForEach(WorkspaceComponentRegistry.shared.components.filter { !$0.requiresDefinition && matches($0.title) }) { component in capabilityRow(component, addOnly: false) }
                        ForEach((store.book?.plugins ?? []).filter { matches($0.name + $0.description) }) { plugin in
                            CompactPluginRow(plugin: plugin)
                        }
                        DisclosureGroup("内置执行插件 · \(PluginEngine.registry.plugins.count)") {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(PluginEngine.registry.plugins, id: \.id) { plugin in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(plugin.name).font(.system(size: 15, weight: .medium))
                                        Text(PluginEngine.registry.schemas().compactMap { schema -> String? in
                                            guard let function = schema["function"] as? [String: Any], let name = function["name"] as? String, PluginEngine.registry.definition(named: name)?.pluginID == plugin.id else { return nil }; return name
                                        }.joined(separator: " · ")).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                            }.padding(.top, 12)
                        }.font(.system(size: 14)).padding(.vertical, 18)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
            Divider().opacity(0.5)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { definitionButtons; Spacer(minLength: 0); importButton }
                VStack(alignment: .leading, spacing: 8) { definitionButtons; importButton }
            }.padding(14)
        }
    }

    private var pluginSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索插件或组件…", text: $search).textFieldStyle(.plain).font(.system(size: 15))
            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("清空插件搜索") }
        }.padding(.leading, 14).padding(.trailing, search.isEmpty ? 14 : 0).frame(minWidth: 160, minHeight: 44)
            .background(Palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line, lineWidth: 0.7))
    }
    private var pluginFilter: some View {
        Picker("插件范围", selection: $tab) { Text("全部").tag("installed"); Text("可添加").tag("available") }.labelsHidden().pickerStyle(.segmented)
    }

    private func close() {
        if let onClose { onClose() }
        else if embedded { store.requestedWorkspaceRoute = store.book == nil ? "library" : "reader" }
        else { dismiss() }
    }
    private var definitionPanel: some View {
        PluginDefinitionPanel(draft: definitionDraft,
                              onTabChange: { requestDefinitionAction(.tab($0)) },
                              onSelectionChange: { requestDefinitionAction(.selection($0)) })
    }
    private func requestDefinitionAction(_ action: PluginDefinitionAction) {
        guard !definitionDraft.saving else { return }
        if definitionDraft.isDirty { definitionDraft.pending = action }
        else { performDefinitionAction(action) }
    }
    private func performDefinitionAction(_ action: PluginDefinitionAction) {
        switch action {
        case .tab(let tab): definitionDraft.selectFirst(in: store.book, tab: tab); showDetails = true
        case .selection(let id): definitionDraft.load(in: store.book, id: id, tab: definitionDraft.tab)
        case .hide: showDetails = false
        case .close: close()
        case .scheme: store.showingPlugins = false; store.openBookScheme(); if !embedded { dismiss() }
        case .openComponent(let id):
            guard let component = WorkspaceComponentRegistry.shared.component(id: id) else { return }
            store.activate(component, open: true, onError: { componentError = $0 }); if componentError.isEmpty { close() }
        case .importPlugin: importError = ""; store.importPlugin(onError: { importError = $0 })
        }
    }

    private var definitionButtons: some View {
        Menu {
            Button { requestDefinitionAction(.scheme) } label: { Label("书本方案", systemImage: "slider.horizontal.3") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.book == nil || store.isBusy)
            Button { if definitionDraft.tab == "types" { showDetails = true } else { requestDefinitionAction(.tab("types")) } } label: { Label("类型", systemImage: "square.stack") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.book == nil || definitionDraft.saving)
            Button { if definitionDraft.tab == "methods" { showDetails = true } else { requestDefinitionAction(.tab("methods")) } } label: { Label("读法", systemImage: "checklist") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.book == nil || definitionDraft.saving)
            Divider()
            Text("停用声明包会保留已有内容")
        } label: { Label("类型与阅读方法", systemImage: "slider.horizontal.3") }
            .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 10).frame(minHeight: 44)
    }
    private var importButton: some View {
        Button { requestDefinitionAction(.importPlugin) } label: { Label("导入 / 升级…", systemImage: "plus") }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(store.book == nil || store.isBusy)
    }
    private func capabilityRow(_ component: WorkspaceComponentDescriptor, addOnly: Bool) -> some View {
        let installed = store.installedComponent(for: component) != nil
        let retainedByDisabledPack = !installed && store.savedComponent(for: component) != nil
        return HStack(spacing: 12) {
            Image(systemName: component.icon).font(.system(size: 22, weight: .regular)).foregroundStyle(Palette.accent)
                .frame(width: 32, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(component.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                Text(retainedByDisabledPack ? "已保存，请启用所属声明包。" : capabilityDescription(component)).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if component.permanent { Text("常驻").font(.system(size: 13)).foregroundStyle(.secondary) }
            else {
                Button(installed ? "打开" : retainedByDisabledPack ? "已停用" : "添加") {
                    componentError = ""; componentNotice = ""
                    if installed { requestDefinitionAction(.openComponent(component.id)) }
                    else { pendingAddition = component.id; componentNotice = "正在添加\(component.title)…"; store.activate(component, open: false, onError: { componentError = $0; componentNotice = ""; pendingAddition = nil }) }
                }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.book == nil || store.isBusy || retainedByDisabledPack)
            }
        }.padding(.vertical, 12).frame(minHeight: 64).overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
    private func capabilityDescription(_ component: WorkspaceComponentDescriptor) -> String {
        switch component.rendererID ?? "" {
        case "book.scheme": return "预览与调整 AI 书本方案，保存模板，并安全撤销配置更新。"
        case "math.verify": return "对支持的有理数矩阵与方程逐步验算，保留原文依据和不适用说明。"
        case "reading.layers": return "译文、释义、评注和资料对齐，随原文按需展开。"
        case "reading.mentions": return "按原文词句追踪对象、别名与出现位置。"
        case "reading.decisions": return "带原文依据的问题、选项与分析路径。"
        case "reading.atlas": return "章节覆盖、内容类型、事件密度与原文共现。"
        default: break
        }
        switch component.kind {
        case .cards: return "由书决定类型，人物、定理、概念和战役都可使用。"
        case .timeline, .map: return "共享事件、时间窗、地点、参与者及原文依据。"
        case .mindmap: return "节点引用真实 Markdown，保留位置与连线。"
        case .relations: return "查看要素之间有原文依据的关系。"
        case .knowledge: return "查阅主动保存的文档与本书知识。"
        case .editor: return "编辑自己的 Markdown 理解与主动保存的回答。"
        case .query: return "引用本书材料提问，选段或合并保存回答。"
        case .workflow: return "按读书法执行，逐页逐段保存回执和检查点。"
        }
    }
}

private struct CompactPluginRow: View {
    @EnvironmentObject var store: AppStore
    let plugin: PluginManifest
    @State private var operationError = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox").font(.system(size: 22)).foregroundStyle(Palette.accent).frame(width: 32, height: 44)
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(plugin.description).font(.system(size: 14)).foregroundStyle(.secondary).textSelection(.enabled)
                        ForEach(plugin.types) { CompactTypeRow(type: $0) }
                        ForEach(plugin.methods.filter(PluginEngine.isActiveMethod)) { CompactMethodRow(method: $0) }
                        ForEach(plugin.views.filter { !PluginEngine.isRetiredRenderer($0.rendererID ?? $0.id) }) { Label("\($0.title) · \($0.kind.title)", systemImage: $0.kind.icon).font(.system(size: 13)).foregroundStyle(.secondary) }
                    }.padding(.top, 12)
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(plugin.name).font(.system(size: 15, weight: .medium)).lineLimit(2)
                        Text("声明包 · \(plugin.types.count) 类型 · \(plugin.methods.filter(PluginEngine.isActiveMethod).count) 方法 · \(plugin.views.filter { !PluginEngine.isRetiredRenderer($0.rendererID ?? $0.id) }.count) 视图").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                Toggle("启用", isOn: Binding(get: { store.book?.disabledPluginIDs.contains(plugin.id) != true }, set: { enabled in
                    operationError = ""; Task { _ = await store.setPluginEnabled(enabled, id: plugin.id, onError: { operationError = $0 }) }
                })).labelsHidden().accessibilityLabel("启用\(plugin.name)").toggleStyle(.switch).controlSize(.large).disabled(store.isBusy)
            }
            if !operationError.isEmpty { settingsError(operationError) }
        }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
}

@MainActor final class PluginDefinitionDraftStore: ObservableObject {
    private struct Key: Hashable { let owner: ObjectIdentifier; let bookID: String }
    private var values: [Key: PluginDefinitionDraft] = [:]
    fileprivate func draft(for store: AppStore) -> PluginDefinitionDraft {
        let key = Key(owner: ObjectIdentifier(store), bookID: store.bookID ?? "")
        if let value = values[key] { return value }
        let value = PluginDefinitionDraft(bookID: store.bookID)
        value.selectFirst(in: store.book, tab: "types"); values[key] = value; return value
    }
}

fileprivate enum PluginDefinitionAction { case tab(String), selection(String), hide, close, scheme, openComponent(String), importPlugin }

@MainActor fileprivate final class PluginDefinitionDraft: ObservableObject {
    let bookID: String?
    @Published var tab = "types"
    @Published var selectedID = ""
    @Published var name = ""
    @Published var detail = ""
    @Published var goal = ""
    @Published var actionID = "ai.analyze"
    @Published var error = ""
    @Published var notice = ""
    @Published var saving = false
    @Published var pending: PluginDefinitionAction?
    private struct Snapshot: Equatable { var tab, id, name, detail, goal, actionID: String }
    private var baseline: Snapshot?
    private var originalType: EntityType?
    private var originalMethod: ReadingMethod?
    init(bookID: String?) { self.bookID = bookID }
    private var snapshot: Snapshot { Snapshot(tab: tab, id: selectedID, name: name, detail: detail, goal: goal, actionID: actionID) }
    var isDirty: Bool { baseline.map { $0 != snapshot } ?? false }
    func selectFirst(in book: BookProject?, tab: String) {
        let id = tab == "types" ? book?.types.first?.id ?? "" : book.flatMap { PluginEngine.recommendedMethods(in: $0).first?.id } ?? ""
        load(in: book, id: id, tab: tab)
    }
    func load(in book: BookProject?, id: String, tab: String) {
        self.tab = tab; selectedID = id; error = ""; notice = ""; actionID = "ai.analyze"
        originalType = tab == "types" ? book?.types.first { $0.id == id } : nil
        originalMethod = tab == "methods" ? book.flatMap { PluginEngine.recommendedMethods(in: $0).first { $0.id == id } } : nil
        if let type = originalType { name = type.name; detail = type.fields.map(\.label).joined(separator: "\n"); goal = "" }
        else if let method = originalMethod { name = method.name; goal = method.goal; detail = method.steps.joined(separator: "\n") }
        else { name = ""; detail = ""; goal = "" }
        baseline = snapshot
    }
    func discard() {
        guard let baseline else { return }
        tab = baseline.tab; selectedID = baseline.id; name = baseline.name; detail = baseline.detail; goal = baseline.goal; actionID = baseline.actionID
        error = ""; notice = ""
    }
    func reconcile(in book: BookProject?) {
        guard !saving, !isDirty, book?.id == bookID, !selectedID.isEmpty else { return }
        let currentType = tab == "types" ? book?.types.first { $0.id == selectedID } : nil
        let currentMethod = tab == "methods" ? book.flatMap { PluginEngine.recommendedMethods(in: $0).first { $0.id == selectedID } } : nil
        guard currentType != originalType || currentMethod != originalMethod else { return }
        if currentType == nil && currentMethod == nil { selectFirst(in: book, tab: tab) }
        else { load(in: book, id: selectedID, tab: tab) }
    }
    func save(in store: AppStore, onSaved: (() -> Void)? = nil) {
        guard var project = store.book, project.id == bookID, !store.isBusy, !store.isSavingDocument, !saving else { return }
        if !selectedID.isEmpty {
            let currentType = tab == "types" ? project.types.first { $0.id == selectedID } : nil
            let currentMethod = tab == "methods" ? PluginEngine.recommendedMethods(in: project).first { $0.id == selectedID } : nil
            guard currentType == originalType, currentMethod == originalMethod else { error = "原定义已在其他操作中更新，输入已保留。请先核对，再放弃草稿并重新选择原定义。"; return }
        }
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = detail.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanedName.isEmpty, !lines.isEmpty else { error = "请填写名称，以及至少一个字段或步骤。"; return }
        let suffix = UUID().uuidString.lowercased()
        var manifest = PluginManifest(id: "user-definition-\(suffix)", name: cleanedName, description: "用户在本书保存的\(tab == "types" ? "卡片类型" : "阅读方法")。")
        if tab == "types" {
            var used = Set<String>()
            let fields = lines.enumerated().map { index, label -> TypeField in
                let existing = originalType?.fields.first { $0.label == label && !used.contains($0.key) }
                var key = existing?.key ?? "field_\(index + 1)"
                while used.contains(key) { key += "_new" }; used.insert(key)
                return TypeField(key: key, label: label, required: existing?.required ?? false)
            }
            manifest.types = [EntityType(id: "type-\(suffix)", name: cleanedName, icon: originalType?.icon ?? "square.stack", fields: fields)]
        } else {
            guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请填写读书目标。"; return }
            let executions = lines.enumerated().map { index, text -> ReadingStepExecution in
                if let oldIndex = originalMethod?.steps.firstIndex(of: text), var execution = originalMethod?.executions?.first(where: { $0.stepIndex == oldIndex }) { execution.stepIndex = index; return execution }
                return ReadingStepExecution(stepIndex: index, actionID: actionID)
            }
            manifest.methods = [ReadingMethod(id: "method-\(suffix)", name: cleanedName, goal: goal.trimmingCharacters(in: .whitespacesAndNewlines), steps: lines, executions: executions)]
        }
        do {
            try PluginEngine.install(manifest, into: &project)
            let savedID = manifest.types.first?.id ?? manifest.methods.first?.id ?? "", savedTab = tab
            saving = true; store.isBusy = true; store.isCommittingLocalWrite = true; error = ""; notice = ""
            Task { @MainActor in
                do {
                    try await store.repository.save(project); store.publish(project)
                    load(in: project, id: savedID, tab: savedTab); notice = "已保存新版本，原定义与既有内容保留。"
                    self.saving = false; store.isBusy = false; store.isCommittingLocalWrite = false
                    onSaved?()
                } catch {
                    self.saving = false; store.isBusy = false; store.isCommittingLocalWrite = false
                    self.error = error.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct PluginDefinitionConfirmation: ViewModifier {
    @ObservedObject var draft: PluginDefinitionDraft
    let store: AppStore
    var active: Bool
    var perform: (PluginDefinitionAction) -> Void
    func body(content: Content) -> some View {
        content.confirmationDialog("保存定义的修改？", isPresented: Binding(get: { active && draft.pending != nil }, set: { if !$0 && active { draft.pending = nil } }), titleVisibility: .visible) {
            Button("保存并继续") { let action = draft.pending; draft.pending = nil; draft.save(in: store) { if let action { perform(action) } } }.disabled(store.isBusy || draft.saving)
            Button("放弃修改并继续", role: .destructive) { let action = draft.pending; draft.pending = nil; draft.discard(); if let action { perform(action) } }.disabled(draft.saving)
            Button("继续编辑", role: .cancel) { draft.pending = nil }
        } message: { Text("尚未保存的名称、字段和步骤会保留。保存成功后才继续；已有定义与引用不会被覆盖。") }
    }
}

/// Definitions are immutable once referenced. Editing makes a new version through
/// the same declaration validator as imported packs, so old receipts stay valid.
private struct PluginDefinitionPanel: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var draft: PluginDefinitionDraft
    var onTabChange: (String) -> Void
    var onSelectionChange: (String) -> Void
    @State private var showExecutions = false
    private var selectedTab: String { draft.tab }
    private var selectedID: String { draft.selectedID }
    private var error: String { draft.error }
    private var notice: String { draft.notice }
    private var selectedType: EntityType? { store.book?.types.first { $0.id == selectedID } }
    private var methods: [ReadingMethod] { store.book.map { PluginEngine.recommendedMethods(in: $0) } ?? [] }
    private var selectedMethod: ReadingMethod? { methods.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("定义类型", selection: Binding(get: { draft.tab }, set: onTabChange)) { Text("卡片类型").tag("types"); Text("阅读方法").tag("methods") }.pickerStyle(.segmented).labelsHidden()
                    Picker(selectedTab == "types" ? "选择类型" : "选择方法", selection: Binding(get: { draft.selectedID }, set: onSelectionChange)) {
                        Label("新建定义", systemImage: "plus").tag("")
                        if selectedTab == "types" { ForEach(store.book?.types ?? []) { Label($0.name, systemImage: $0.icon).tag($0.id) } }
                        else { ForEach(methods) { Label($0.name, systemImage: "checklist").tag($0.id) } }
                    }.frame(minHeight: 44)
                    VStack(alignment: .leading, spacing: 8) { Text("名称").font(.system(size: 14)); TextField(selectedTab == "types" ? "例如：定理、战役" : "读书法名称", text: $draft.name).settingsTextField() }
                    if selectedTab == "methods" {
                        VStack(alignment: .leading, spacing: 8) { Text("目标").font(.system(size: 14)); TextField("阅读目标", text: $draft.goal, axis: .vertical).settingsTextField() }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedTab == "types" ? "字段 · 每行一项" : "步骤 · 每行一步").font(.system(size: 14))
                        TextEditor(text: $draft.detail).font(.system(size: 15)).scrollContentBackground(.hidden).padding(8).frame(minHeight: selectedTab == "types" ? 140 : 180)
                            .background(Palette.paper.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 0.6))
                    }
                    if selectedTab == "methods" {
                        Picker("新步骤执行动作", selection: $draft.actionID) { ForEach(PluginEngine.activeWorkflowActions, id: \.id) { Label($0.title, systemImage: "arrow.triangle.branch").tag($0.id) } }.frame(minHeight: 44)
                        if let method = selectedMethod {
                            DisclosureGroup("原方法执行绑定", isExpanded: $showExecutions) { CompactMethodRow(method: method) }.font(.system(size: 14))
                        }
                    }
                    DisclosureGroup("保存规则与兼容性") {
                        Text(selectedTab == "types" ? "按书定义，不限定为人物。每行一个字段，已有字段键会在另存时保留。" : "已有步骤保留各自动作；新增或改写步骤使用所选动作。宿主仍先核对逐段回执。")
                            .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 8)
                        Text("保存为本书声明包。已有类型、引用、阅读方案与回执保持原版本；新方法可在预读时由 AI 选择。")
                            .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                    }.font(.system(size: 14))
                    if !error.isEmpty { settingsError(error) }
                    if !notice.isEmpty { Label(notice, systemImage: "checkmark.circle").font(.system(size: 14)).foregroundStyle(Palette.accent) }
                }.padding(18).disabled(store.isBusy || draft.saving)
            }
            Divider().opacity(0.4)
            HStack {
                Text(store.book?.title ?? "先选择一本书").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button { draft.save(in: store) } label: { Label(draft.saving ? "保存中…" : selectedID.isEmpty ? "保存定义" : "保存为新版本", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).controlSize(.large).frame(minHeight: 44).disabled(store.book == nil || store.isBusy || draft.saving)
            }.padding(14)
        }
    }
}
private struct CompactTypeRow: View {
    let type: EntityType
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                Text("类型 ID：\(type.id)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(type.fields, id: \.key) { field in Text("\(field.label) · \(field.key)\(field.required ? " · 必填" : "")").font(.system(size: 13)).textSelection(.enabled) }
            }.padding(.top, 8)
        } label: { Label("\(type.name) · \(type.fields.count) 字段", systemImage: type.icon).font(.system(size: 14)).foregroundStyle(Palette.accent) }
    }
}

private struct CompactMethodRow: View {
    let method: ReadingMethod
    var isSelected = false
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text(method.goal).font(.system(size: 14)).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(Array(method.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 9) {
                        Text("\(index + 1).").foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(step).textSelection(.enabled)
                            let action = method.executions?.first { $0.stepIndex == index }?.actionID ?? "ai.analyze"
                            Text(ReadingWorkflowRuntime.actions.first { $0.id == action }?.title ?? action).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }.font(.system(size: 14))
                }
            }.padding(.top, 10)
        } label: { Text("\(method.name) · \(method.steps.count) 步\(isSelected ? " · 本次方案" : "")").font(.system(size: 14, weight: .medium)) }
    }
}

private struct SettingsFormRow<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text(title).font(.system(size: 15)).foregroundStyle(Palette.ink).frame(width: 114, alignment: .leading).padding(.top, 12).fixedSize(horizontal: false, vertical: true)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsTextField: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 15)).textFieldStyle(.plain).padding(.horizontal, 13).padding(.vertical, 12)
            .frame(minHeight: ReadingLayout.controlHeight).background(Palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.line, lineWidth: 0.8))
    }
}
private extension View { func settingsTextField() -> some View { modifier(SettingsTextField()) } }
private func settingsError(_ message: String) -> some View { Label(message, systemImage: "exclamationmark.circle").font(.system(size: 14)).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }

/// Management has one stationary title bar; its body and footer own their scrolling.
struct SettingsManagementHeader<Actions: View>: View {
    let title: String
    let icon: String
    var dirty = false
    var onClose: () -> Void
    let actions: Actions
    init(title: String, icon: String, dirty: Bool = false, onClose: @escaping () -> Void, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.icon = icon; self.dirty = dirty; self.onClose = onClose; self.actions = actions()
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Palette.accent)
            Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            if dirty { Circle().fill(Palette.accent).frame(width: 6, height: 6).accessibilityLabel("有未保存更改") }
            Spacer(minLength: 8)
            actions
            DockIconButton(title: "关闭\(title)", icon: "xmark", isSelected: false, action: onClose)
        }.padding(.leading, 18).padding(.trailing, 6).frame(height: 56)
    }
}
/// Shared by OCR sheets; footer actions remain outside scrolling content.
struct CompactSettingsSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 17, weight: .semibold))
            content
        }.frame(maxWidth: .infinity, alignment: .leading).padding(ReadingLayout.panelPadding)
            .background(Palette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line.opacity(0.75), lineWidth: 0.7))
    }
}
