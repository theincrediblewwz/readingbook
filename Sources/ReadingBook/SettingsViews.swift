import SwiftUI
import ReadingCore

/// The same real profile editor serves the floating workspace and macOS Settings.
struct ProviderSettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    @State private var deletingService = false
    @State private var showAdvanced = false
    @State private var showNotes = false
    @State private var showServices = true
    @State private var configuredWidth = false

    var body: some View {
        GeometryReader { geometry in
            let wide = embedded && geometry.size.width >= 1000
            let inset: CGFloat = embedded ? 22 : 12
            let topInset: CGFloat = embedded ? 96 : inset
            let canvas = CGSize(width: max(1, geometry.size.width - inset * 2), height: max(1, geometry.size.height - topInset - inset))
            let listWidth: CGFloat = 300
            let showList = wide && showServices
            ZStack(alignment: .topLeading) {
                if showList {
                    SettingsFloatingCard(title: "我的服务", subtitle: "本机保存 · 随时切换", icon: "link", viewport: canvas,
                                         width: listWidth, height: min(560, canvas.height), initial: .zero,
                                         onClose: { showServices = false }) {
                        serviceList
                    }
                }
                SettingsFloatingCard(title: store.serviceName.isEmpty ? "模型设置" : store.serviceName,
                                     subtitle: store.serviceProfileDraft.isDirty(in: store) ? "有未保存更改" : "密钥保存在本机钥匙串",
                                     icon: "sparkles", viewport: canvas,
                                     width: showList ? max(300, canvas.width - listWidth - 22) : canvas.width,
                                     height: canvas.height, initial: CGPoint(x: showList ? listWidth + 22 : 0, y: 0),
                                     movable: embedded, canClose: false) {
                    modelConfiguration(wide: wide)
                }
            }.frame(width: canvas.width, height: canvas.height, alignment: .topLeading).padding(.horizontal, inset).padding(.top, topInset).padding(.bottom, inset)
                .onAppear { if !configuredWidth { showServices = wide; configuredWidth = true } }
                .onChange(of: wide) { _, value in if !value { showServices = false } }
        }
        .background(Palette.canvas.opacity(0.3))
        .confirmationDialog("删除已保存的服务配置与其密钥？", isPresented: $deletingService) {
            Button("删除配置", role: .destructive) { if let id = store.selectedServiceID { store.removeService(id) } }
        } message: { Text("书籍、文档与已生成内容会保留。") }
        .serviceProfileChangeConfirmation(store: store, isSettingsContext: true)
        .onAppear { store.serviceProfileDraft.settingsPresentationCount += 1 }
        .onDisappear { store.serviceProfileDraft.settingsPresentationCount = max(0, store.serviceProfileDraft.settingsPresentationCount - 1) }
    }

    private var serviceList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(store.savedServices) { service in
                        Button { store.selectService(service.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "link").font(.system(size: 20)).foregroundStyle(Palette.accent).frame(width: 26)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(service.name).font(.system(size: 16, weight: .medium)).lineLimit(2)
                                    Text(service.settings.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if service.id == store.selectedServiceID { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent) }
                            }.padding(12).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
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
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 8) {
                        if wide {
                            if !showServices { Button { showServices = true } label: { Label("我的服务", systemImage: "sidebar.left") }.buttonStyle(ReadingToolbarButtonStyle()) }
                        } else {
                            Picker("服务", selection: Binding(get: { store.selectedServiceID ?? "" }, set: { store.selectService($0) })) {
                                if store.selectedServiceID == nil { Text("新的未保存配置").tag("") }
                                ForEach(store.savedServices) { Text($0.name).tag($0.id) }
                            }.labelsHidden().accessibilityLabel("已保存的服务").frame(maxWidth: .infinity)
                            newServiceMenu
                        }
                        Spacer(minLength: 0)
                        Button { deletingService = true } label: { Image(systemName: "trash") }
                            .buttonStyle(ReadingToolbarButtonStyle()).help("删除当前服务配置及密钥").disabled(store.selectedServiceID == nil || store.isBusy)
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
                }.padding(22)
            }
            Divider().opacity(0.5)
            HStack(spacing: 12) {
                if !embedded { Button("关闭") { dismiss() }.buttonStyle(ReadingToolbarButtonStyle()) }
                Button { store.testConnection() } label: { Label("测试连接", systemImage: "play") }
                    .buttonStyle(ReadingToolbarButtonStyle()).disabled(store.isBusy || store.settings.model.isEmpty)
                Spacer(minLength: 0)
                Button { store.saveServiceProfileForUI() } label: { Label("保存配置", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).controlSize(.large).frame(minHeight: ReadingLayout.controlHeight).disabled(store.isBusy)
            }.padding(14)
        }.controlSize(.large)
    }

    private var newServiceMenu: some View {
        Menu {
            Button("自定义兼容服务") { store.newService() }
            Divider()
            ForEach(ProviderCatalog.current.providers) { provider in Button(provider.name) { store.newService(provider) } }
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
                        Menu { ForEach(preset.models) { model in Button(model.name) { store.chooseModel(model) } } } label: { Label("选择已核实预设", systemImage: "chevron.down") }
                            .menuStyle(.borderlessButton).font(.system(size: 13)).fixedSize()
                    }
                }
            }
        }.disabled(store.isBusy)
    }

    private var budgetFields: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("输出与能力").font(.system(size: 18, weight: .semibold))
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
                    Text("推理模型的输出额度可能包含推理 Token。未知型号不自动推测。模型目录核查于 \(ProviderCatalog.current.verifiedAt.isEmpty ? "未记录" : ProviderCatalog.current.verifiedAt)。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }.padding(.top, 16)
            }.font(.system(size: 16, weight: .medium))
        }.disabled(store.isBusy)
    }

    private var ocrFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PDF 视觉识别").font(.system(size: 18, weight: .semibold))
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
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    @State private var search = ""
    @State private var tab = "installed"
    @State private var showDetails = true
    @State private var detailTab = "types"
    @State private var configuredWidth = false
    @State private var importError = ""
    @State private var componentError = ""
    @State private var componentNotice = ""
    @State private var pendingAddition: String?

    private var available: [WorkspaceComponentDescriptor] {
        WorkspaceComponentRegistry.shared.components.filter { !$0.permanent && store.savedComponent(for: $0) == nil && matches($0.title) }
    }
    private func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }

    var body: some View {
        GeometryReader { geometry in
            let wide = embedded && geometry.size.width >= 1100
            let inset: CGFloat = embedded ? 22 : 12
            let topInset: CGFloat = embedded ? 96 : inset
            let canvas = CGSize(width: max(1, geometry.size.width - inset * 2), height: max(1, geometry.size.height - topInset - inset))
            let asideWidth: CGFloat = 350
            let withAside = wide && showDetails
            ZStack(alignment: .topLeading) {
                SettingsFloatingCard(title: "插件与组件", subtitle: "按书组合类型、方法和视图", icon: "puzzlepiece.extension", viewport: canvas,
                                     width: withAside ? max(350, canvas.width - asideWidth - 22) : canvas.width,
                                     height: canvas.height, initial: .zero, movable: embedded, canClose: false) {
                    pluginList
                }
                if withAside {
                    SettingsFloatingCard(title: detailTab == "types" ? "本书卡片类型" : "可执行读书法", subtitle: "定义随书保存", icon: detailTab == "types" ? "square.stack" : "checklist", viewport: canvas,
                                         width: asideWidth, height: canvas.height, initial: CGPoint(x: canvas.width - asideWidth, y: 0), onClose: { showDetails = false }) {
                        PluginDefinitionPanel(selectedTab: $detailTab)
                    }
                }
            }.frame(width: canvas.width, height: canvas.height, alignment: .topLeading).padding(.horizontal, inset).padding(.top, topInset).padding(.bottom, inset)
                .onAppear { if !configuredWidth { showDetails = wide; configuredWidth = true } }
                .onChange(of: wide) { _, value in if !value { showDetails = false } }
                .sheet(isPresented: Binding(get: { configuredWidth && showDetails && !wide }, set: { if !$0 { showDetails = false } })) {
                    VStack(spacing: 0) {
                        HStack { Text("本书类型与读书法").font(.system(size: 20, weight: .semibold)); Spacer(); Button("完成") { showDetails = false }.buttonStyle(ReadingToolbarButtonStyle()) }.padding(18)
                        PluginDefinitionPanel(selectedTab: $detailTab)
                    }.frame(width: 540, height: 660)
                }
        }.background(Palette.canvas.opacity(0.3))
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
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索插件或组件…", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("清空插件搜索") }
                }.padding(12).background(Palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 0.7))
                Picker("插件范围", selection: $tab) { Text("插件").tag("installed"); Text("可添加").tag("available") }.labelsHidden().pickerStyle(.segmented).frame(width: 190)
            }.padding(18)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !importError.isEmpty { settingsError(importError) }
                    if !componentError.isEmpty { settingsError(componentError) }
                    if !componentNotice.isEmpty { Label(componentNotice, systemImage: "checkmark.circle").font(.system(size: 14)).foregroundStyle(Palette.accent).padding(.vertical, 12) }
                    if tab == "available" {
                        ForEach(available) { component in capabilityRow(component, addOnly: true) }
                        if available.isEmpty { ContentUnavailableView(search.isEmpty ? "本书组件已经齐全" : "没有匹配的组件", systemImage: "checkmark.circle", description: Text("已添加的组件不会重复出现在这里。")) }
                    } else {
                        ForEach(WorkspaceComponentRegistry.shared.components.filter { matches($0.title) }) { component in capabilityRow(component, addOnly: false) }
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
                }.padding(.horizontal, 24).padding(.bottom, 16)
            }
            Divider().opacity(0.5)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { footerExplanation; Spacer(minLength: 0); definitionButtons; importButton }
                VStack(alignment: .leading, spacing: 8) { footerExplanation; HStack { definitionButtons; Spacer(minLength: 0); importButton } }
            }.padding(14)
            if !embedded { HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(ReadingToolbarButtonStyle()) }.padding(.horizontal, 14).padding(.bottom, 8) }
        }
    }

    private var footerExplanation: some View { Label("停用保留已有内容", systemImage: "info.circle").font(.system(size: 13)).foregroundStyle(.secondary).fixedSize() }
    private var definitionButtons: some View {
        HStack(spacing: 4) {
            Button { store.showingPlugins = false; store.openBookScheme(); if !embedded { dismiss() } } label: { Label("书本方案", systemImage: "slider.horizontal.3") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.book == nil || store.isBusy)
            Button { detailTab = "types"; showDetails = true } label: { Label("类型", systemImage: "square.stack") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.book == nil)
            Button { detailTab = "methods"; showDetails = true } label: { Label("读书法", systemImage: "checklist") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.book == nil)
        }
    }
    private var importButton: some View {
        Button { importError = ""; store.importPlugin(onError: { importError = $0 }) } label: { Label("导入 / 升级…", systemImage: "plus") }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(store.book == nil || store.isBusy)
    }
    private func capabilityRow(_ component: WorkspaceComponentDescriptor, addOnly: Bool) -> some View {
        let installed = store.installedComponent(for: component) != nil
        let retainedByDisabledPack = !installed && store.savedComponent(for: component) != nil
        return HStack(spacing: 18) {
            Image(systemName: component.icon).font(.system(size: 28, weight: .regular)).foregroundStyle(Palette.accent)
                .frame(width: 58, height: 62).background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 7) {
                Text(component.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                Text(retainedByDisabledPack ? "已保存，请启用所属声明包。" : capabilityDescription(component)).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if component.permanent { Text("常驻").font(.system(size: 13)).foregroundStyle(.secondary) }
            else {
                Button(installed ? "打开" : retainedByDisabledPack ? "已停用" : "添加") {
                    componentError = ""; componentNotice = ""
                    if installed { store.activate(component, open: true, onError: { componentError = $0 }); if !embedded { dismiss() } }
                    else { pendingAddition = component.id; componentNotice = "正在添加\(component.title)…"; store.activate(component, open: false, onError: { componentError = $0; componentNotice = ""; pendingAddition = nil }) }
                }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.book == nil || store.isBusy || retainedByDisabledPack)
            }
        }.padding(.vertical, 20).overlay(alignment: .bottom) { Divider().opacity(0.45) }
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
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "shippingbox").font(.system(size: 28)).foregroundStyle(Palette.accent).frame(width: 58, height: 62).background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(plugin.description).font(.system(size: 14)).foregroundStyle(.secondary).textSelection(.enabled)
                        ForEach(plugin.types) { CompactTypeRow(type: $0) }
                        ForEach(plugin.methods) { CompactMethodRow(method: $0) }
                        ForEach(plugin.views) { Label("\($0.title) · \($0.kind.title)", systemImage: $0.kind.icon).font(.system(size: 13)).foregroundStyle(.secondary) }
                    }.padding(.top, 12)
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(plugin.name).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                        Text("声明包 · \(plugin.types.count) 类型 · \(plugin.methods.count) 方法 · \(plugin.views.count) 视图").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                Toggle("启用", isOn: Binding(get: { store.book?.disabledPluginIDs.contains(plugin.id) != true }, set: { enabled in
                    operationError = ""; Task { _ = await store.setPluginEnabled(enabled, id: plugin.id, onError: { operationError = $0 }) }
                })).labelsHidden().accessibilityLabel("启用\(plugin.name)").toggleStyle(.switch).controlSize(.large).disabled(store.isBusy)
            }
            if !operationError.isEmpty { settingsError(operationError) }
        }.padding(.vertical, 20).overlay(alignment: .bottom) { Divider().opacity(0.45) }
    }
}

/// Definitions are immutable once referenced. Editing makes a new version through
/// the same declaration validator as imported packs, so old receipts stay valid.
private struct PluginDefinitionPanel: View {
    @EnvironmentObject var store: AppStore
    @Binding var selectedTab: String
    @State private var selectedID = ""
    @State private var name = ""
    @State private var detail = ""
    @State private var goal = ""
    @State private var actionID = "ai.analyze"
    @State private var error = ""
    @State private var notice = ""
    @State private var showExecutions = false
    private var selectedType: EntityType? { store.book?.types.first { $0.id == selectedID } }
    private var selectedMethod: ReadingMethod? { store.book?.methods.first { $0.id == selectedID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("定义类型", selection: $selectedTab) { Text("卡片类型").tag("types"); Text("读书法").tag("methods") }.pickerStyle(.segmented).labelsHidden()
                Text(store.book?.title ?? "先选择一本书").font(.system(size: 15, weight: .medium)).lineLimit(2)
                Picker(selectedTab == "types" ? "选择类型" : "选择方法", selection: $selectedID) {
                    Text("＋ 新建定义").tag("")
                    if selectedTab == "types" { ForEach(store.book?.types ?? []) { Text($0.name).tag($0.id) } }
                    else { ForEach(store.book?.methods ?? []) { Text($0.name).tag($0.id) } }
                }.onChange(of: selectedID) { _, _ in loadSelection() }
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 8) { Text("名称").font(.system(size: 14)); TextField(selectedTab == "types" ? "例如：定理、战役" : "读书法名称", text: $name).settingsTextField() }
                if selectedTab == "types" {
                    Text("按书定义，不限定为人物。每行一个字段，已有字段键会在另存时保留。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) { Text("目标").font(.system(size: 14)); TextField("阅读目标", text: $goal, axis: .vertical).settingsTextField() }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectedTab == "types" ? "字段 · 每行一项" : "步骤 · 每行一步").font(.system(size: 14))
                    TextEditor(text: $detail).font(.system(size: 15)).scrollContentBackground(.hidden).padding(8).frame(minHeight: selectedTab == "types" ? 160 : 200)
                        .background(Palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, lineWidth: 0.7))
                }
                if selectedTab == "methods" {
                    Picker("新步骤执行动作", selection: $actionID) { ForEach(ReadingWorkflowRuntime.actions, id: \.id) { Text($0.title).tag($0.id) } }
                    Text("已有步骤保留各自动作；新增或改写步骤使用上面的动作。宿主仍先核对逐段回执。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    if let method = selectedMethod {
                        DisclosureGroup("原方法执行绑定", isExpanded: $showExecutions) { CompactMethodRow(method: method) }.font(.system(size: 13))
                    }
                }
                if !error.isEmpty { settingsError(error) }
                if !notice.isEmpty { Label(notice, systemImage: "checkmark.circle").font(.system(size: 14)).foregroundStyle(Palette.accent) }
                Button { saveDefinition() } label: { Label(selectedID.isEmpty ? "保存定义" : "保存为新版本", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(store.book == nil || store.isBusy)
                Text("保存为本书声明包。已有类型、引用、阅读方案与回执保持原版本；新方法可在预读时由 AI 选择。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20)
        }.onAppear { selectFirstDefinition() }
        .onChange(of: selectedTab) { _, _ in selectFirstDefinition() }
        .onChange(of: store.bookID) { _, _ in selectFirstDefinition() }
    }

    private func selectFirstDefinition() {
        selectedID = selectedTab == "types" ? store.book?.types.first?.id ?? "" : store.book?.methods.first?.id ?? ""
        loadSelection()
    }

    private func loadSelection() {
        error = ""; notice = ""
        if selectedTab == "types", let type = selectedType { name = type.name; detail = type.fields.map(\.label).joined(separator: "\n"); goal = "" }
        else if selectedTab == "methods", let method = selectedMethod { name = method.name; goal = method.goal; detail = method.steps.joined(separator: "\n") }
        else { name = ""; detail = ""; goal = "" }
    }

    private func saveDefinition() {
        guard var project = store.book, !store.isBusy else { return }
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = detail.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanedName.isEmpty, !lines.isEmpty else { error = "请填写名称，以及至少一个字段或步骤。"; return }
        let suffix = UUID().uuidString.lowercased()
        var manifest = PluginManifest(id: "user-definition-\(suffix)", name: cleanedName, description: "用户在本书保存的\(selectedTab == "types" ? "卡片类型" : "可执行读书法")。")
        if selectedTab == "types" {
            let original = selectedType
            var used = Set<String>()
            let fields = lines.enumerated().map { index, label -> TypeField in
                let existing = original?.fields.first { $0.label == label && !used.contains($0.key) }
                var key = existing?.key ?? "field_\(index + 1)"
                while used.contains(key) { key += "_new" }; used.insert(key)
                return TypeField(key: key, label: label, required: existing?.required ?? false)
            }
            manifest.types = [EntityType(id: "type-\(suffix)", name: cleanedName, icon: original?.icon ?? "square.stack", fields: fields)]
        } else {
            guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请填写读书目标。"; return }
            let original = selectedMethod
            let executions = lines.enumerated().map { index, text -> ReadingStepExecution in
                if let oldIndex = original?.steps.firstIndex(of: text), var execution = original?.executions?.first(where: { $0.stepIndex == oldIndex }) { execution.stepIndex = index; return execution }
                return ReadingStepExecution(stepIndex: index, actionID: actionID)
            }
            manifest.methods = [ReadingMethod(id: "method-\(suffix)", name: cleanedName, goal: goal.trimmingCharacters(in: .whitespacesAndNewlines), steps: lines, executions: executions)]
        }
        do {
            try PluginEngine.install(manifest, into: &project)
            let expectedBookID = project.id
            store.isBusy = true; error = ""; notice = ""
            Task { @MainActor in
                defer { store.isBusy = false }
                do {
                    try await store.repository.save(project)
                    store.publish(project)
                    if store.bookID == expectedBookID { notice = "已保存新定义，原版本与既有内容保留。"; selectedID = manifest.types.first?.id ?? manifest.methods.first?.id ?? "" }
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
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

/// Retained AppKit pointer coordinates keep floating forms steady while dragging.
private struct SettingsFloatingCard<Content: View>: View {
    let title: String
    var subtitle = ""
    var icon = "square.stack"
    let viewport: CGSize
    let width: CGFloat
    let height: CGFloat
    let initial: CGPoint
    var movable = true
    var canClose = true
    var onClose: () -> Void = {}
    let content: Content
    @State private var position: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var collapsed = false
    @State private var epoch = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(title: String, subtitle: String = "", icon: String = "square.stack", viewport: CGSize, width: CGFloat, height: CGFloat, initial: CGPoint, movable: Bool = true, canClose: Bool = true, onClose: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.icon = icon; self.viewport = viewport; self.width = width; self.height = height; self.initial = initial; self.movable = movable; self.canClose = canClose; self.onClose = onClose; self.content = content()
    }
    private var cardSize: CGSize { CGSize(width: min(width, viewport.width), height: collapsed ? 78 : min(height, viewport.height)) }
    private var origin: CGPoint { clamp(position ?? initial) }
    private func clamp(_ point: CGPoint) -> CGPoint { CGPoint(x: min(max(0, point.x), max(0, viewport.width - cardSize.width)), y: min(max(0, point.y), max(0, viewport.height - cardSize.height))) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.system(size: 21, weight: .semibold)).lineLimit(1)
                        if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    if movable { Image(systemName: "ellipsis").font(.system(size: 18, weight: .medium)).rotationEffect(.degrees(90)).foregroundStyle(.tertiary) }
                }.frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                    .overlay {
                        if movable {
                            FloatingPanelPointerInput(epoch: epoch, begin: { dragStart = origin }, drag: { translation, ended in
                                let start = dragStart ?? origin
                                var transaction = Transaction(); transaction.disablesAnimations = true
                                withTransaction(transaction) { position = clamp(CGPoint(x: start.x + translation.width, y: start.y + translation.height)) }
                                if ended { dragStart = nil }
                            }, cancel: { if let dragStart { position = clamp(dragStart) }; dragStart = nil })
                        }
                    }
                Button { withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { collapsed.toggle() } } label: { Image(systemName: collapsed ? "plus" : "minus") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help(collapsed ? "展开面板" : "收起面板").accessibilityLabel(collapsed ? "展开\(title)" : "收起\(title)")
                if canClose { Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("关闭面板").accessibilityLabel("关闭\(title)") }
            }.padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 10)
            if !collapsed { Divider().opacity(0.4); content.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.frame(width: cardSize.width, height: cardSize.height).readingGlass(radius: 22)
            .offset(x: origin.x, y: origin.y)
            .onChange(of: viewport) { _, _ in epoch += 1; dragStart = nil; if let position { self.position = clamp(position) } }
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
