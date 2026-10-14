import SwiftUI
import ReadingCore

struct ProviderSettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var deletingService = false
    @State private var showAdvanced = false
    @State private var showNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("自己的模型工作台").font(.system(size: 18, weight: .semibold)).lineLimit(1)
                Text("多套服务随时切换 · 密钥保存在本机钥匙串").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            profilePicker
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    connectionFields
                    budgetFields
                    ocrFields
                    if !store.connectionStatus.isEmpty {
                        Text(store.connectionStatus).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.vertical, 2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button("关闭") { dismiss() }
                Spacer()
                Button("测试连接") { store.testConnection() }.disabled(store.isBusy || store.settings.model.isEmpty)
                Button("保存配置") {
                    do { try store.persistServiceProfile(); store.connectionStatus = "配置已保存。" }
                    catch { store.errorMessage = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(store.isBusy)
            }
        }.padding(18).controlSize(.small)
        .confirmationDialog("删除已保存的服务配置与其密钥？", isPresented: $deletingService) {
            Button("删除配置", role: .destructive) { if let id = store.selectedServiceID { store.removeService(id) } }
        } message: { Text("书籍、文档与已生成内容会保留。") }
    }

    private var profilePicker: some View {
        HStack(spacing: 8) {
            Picker("已保存", selection: Binding(get: { store.selectedServiceID ?? "" }, set: { store.selectService($0) })) {
                if store.selectedServiceID == nil { Text("新的未保存配置").tag("") }
                ForEach(store.savedServices) { service in Text(service.name).tag(service.id) }
            }
            Menu("新建") {
                Button("自定义兼容服务") { store.newService() }
                Divider()
                ForEach(ProviderCatalog.current.providers) { provider in Button(provider.name) { store.newService(provider) } }
            }.fixedSize()
            Button(role: .destructive) { deletingService = true } label: { Image(systemName: "trash") }
                .help("删除当前服务配置及密钥").disabled(store.selectedServiceID == nil)
        }.disabled(store.isBusy)
    }

    private var connectionFields: some View {
        CompactSettingsSection("连接") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("配置名称"); TextField("服务名称", text: $store.serviceName) }
                GridRow { Text("服务地址"); TextField("HTTPS 或本机服务 URL", text: $store.settings.baseURL) }
                GridRow {
                    Text("模型 API ID")
                    HStack(spacing: 8) {
                        TextField("精确模型 ID", text: $store.settings.model)
                        if let preset = store.matchingPreset {
                            Menu("模型预设") { ForEach(preset.models) { model in Button(model.name) { store.chooseModel(model) } } }.fixedSize()
                        }
                    }
                }
                GridRow { Text("API Key"); SecureField("API Key", text: $store.apiKey) }
            }.font(.system(size: 12)).textFieldStyle(.roundedBorder)
        }.disabled(store.isBusy)
    }

    private var budgetFields: some View {
        CompactSettingsSection("能力与预算") {
            if let model = store.matchingModel {
                HStack(spacing: 10) {
                    Label(model.vision ? "图像输入" : "文本模型", systemImage: model.vision ? "photo" : "text.alignleft")
                    Text(model.tools ? "支持工具调用" : "未确认工具调用").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let url = URL(string: model.documentationURL) { Link("官方规格", destination: url) }
                }.font(.caption)
                Text("上下文 \(model.contextTokens.map { String($0) } ?? "未确认") · 输出上限 \(model.maxOutputTokens.map { String($0) } ?? "未确认") token")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                HStack {
                    Text("未匹配已核实型号，规格请手动确认").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let preset = store.matchingPreset, let url = URL(string: preset.documentationURL) { Link("服务文档", destination: url) }
                }.font(.caption)
            }
            HStack(spacing: 10) {
                Text("最大输出 token").font(.system(size: 12))
                TextField("输出上限", value: $store.settings.maxOutputTokens, format: .number)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 140)
                Button("Max") { store.useMaximumOutput() }.disabled(store.matchingModel?.maxOutputTokens == nil)
                    .help("使用该模型已核实的输出上限；未知型号不自动推测")
                Spacer(minLength: 0)
            }
            Stepper("每轮最多 \(store.settings.maxRequestsPerRun) 次请求", value: $store.settings.maxRequestsPerRun, in: 1...2000)
                .font(.system(size: 12))
            Text("Max 设置上限，不保证写满；实际请求还受上下文余量和账户限制。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("高级参数与说明", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 9) {
                    LabeledContent("上下文 token") {
                        TextField("未知可留空", text: Binding(get: { store.settings.contextWindowTokens.map { String($0) } ?? "" }, set: { store.settings.contextWindowTokens = Int($0.replacingOccurrences(of: ",", with: "")) }))
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    }
                    Picker("输出参数", selection: Binding(get: { store.settings.tokenLimitParameter ?? "max_tokens" }, set: { store.settings.tokenLimitParameter = $0 })) {
                        Text("max_tokens").tag("max_tokens")
                        Text("max_completion_tokens").tag("max_completion_tokens")
                    }
                    Text("推理模型的输出额度可能包含推理 token。未知型号可手动填写，不自动猜测。")
                        .foregroundStyle(.secondary)
                    if !ProviderCatalog.current.verifiedAt.isEmpty {
                        Text("模型目录核查于 \(ProviderCatalog.current.verifiedAt)").foregroundStyle(.secondary)
                    }
                }.font(.caption).padding(.top, 7)
            }.font(.system(size: 12))
        }.disabled(store.isBusy)
    }

    private var ocrFields: some View {
        CompactSettingsSection("PDF OCR") {
            Picker("图像模型配置", selection: Binding(get: { store.ocrServiceID ?? "" }, set: { store.ocrServiceID = $0.isEmpty ? nil : $0; UserDefaults.standard.set(store.ocrServiceID, forKey: "ocr-service") })) {
                Text("当前阅读服务").tag("")
                ForEach(store.savedServices) { service in Text("\(service.name) · \(service.settings.model)").tag(service.id) }
            }.font(.system(size: 12))
            DisclosureGroup("发送范围与测试说明", isExpanded: $showNotes) {
                Text("文本分析发送所需原文，OCR 发送所选 PDF 页图。OCR 需支持图像输入，可与文本阅读使用不同服务；逐页请求与保存，可暂停续跑。测试连接会发送一条短文本请求。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }.font(.system(size: 12))
        }.disabled(store.isBusy)
    }
}

struct PluginLibraryView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var showCapabilities = false
    @State private var showTypes = false
    @State private var showMethods = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("插件与读书法").font(.system(size: 18, weight: .semibold)).lineLimit(1)
                    Text("按书组合类型、方法与视图").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("导入插件…") { store.importPlugin() }.disabled(store.book == nil || store.isBusy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CompactSettingsSection("本书安装的声明包") {
                        if store.book?.plugins.isEmpty != false {
                            Text("尚未安装。仓库 Examples 附有数学精读示例。").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(store.book?.plugins ?? []) { plugin in
                            CompactPluginRow(plugin: plugin).environmentObject(store)
                        }
                    }
                    CompactSettingsSection("组件能力") {
                        DisclosureGroup("内置组件 · \(ComponentKind.allCases.count)", isExpanded: $showCapabilities) {
                            VStack(spacing: 0) {
                                ForEach(ComponentKind.allCases, id: \.self) { kind in capabilityRow(kind) }
                            }.padding(.top, 5)
                        }.font(.system(size: 12))
                    }
                    if let book = store.book {
                        CompactSettingsSection("本书类型与方法") {
                            DisclosureGroup("卡片类型 · \(book.types.count)", isExpanded: $showTypes) {
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(book.types) { type in CompactTypeRow(type: type) }
                                }.padding(.top, 7)
                            }.font(.system(size: 12))
                            DisclosureGroup("读书法 · \(book.methods.count)", isExpanded: $showMethods) {
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(book.methods) { method in
                                        CompactMethodRow(method: method, isSelected: book.plan?.methodIDs.contains(method.id) == true)
                                    }
                                }.padding(.top, 7)
                            }.font(.system(size: 12))
                        }
                    }
                }.padding(.vertical, 2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                Text("停用保留已有知识与用户文档。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).controlSize(.small)
    }

    private func capabilityRow(_ kind: ComponentKind) -> some View {
        HStack(spacing: 10) {
            BrandGlyph(name: BrandNavigation.glyph(route: kind.rawValue)).frame(width: 17, height: 17).foregroundStyle(Palette.accent)
            Text(kind.title).font(.system(size: 12, weight: .medium)).frame(width: 82, alignment: .leading)
            Text(capabilityDescription(kind)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Button("添加") { store.activate(kind); dismiss() }.disabled(store.book == nil || store.isBusy)
        }.padding(.vertical, 6)
    }

    private func capabilityDescription(_ kind: ComponentKind) -> String {
        switch kind {
        case .cards: return "按书定义类型，查看带来源的要素"
        case .timeline: return "按事件时间筛选"
        case .map: return "地点与时间窗联动"
        case .mindmap: return "组织文档节点与连线"
        case .relations: return "查看要素之间的关系"
        case .knowledge: return "查阅已保存文档与知识"
        case .editor: return "编辑自己的 Markdown"
        case .query: return "引用本书材料提问"
        case .workflow: return "查看方案、处理记录与复核"
        }
    }
}

private struct CompactPluginRow: View {
    @EnvironmentObject var store: AppStore
    let plugin: PluginManifest

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text(plugin.description).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    ForEach(plugin.types) { type in CompactTypeRow(type: type) }
                    ForEach(plugin.methods) { method in CompactMethodRow(method: method) }
                    ForEach(plugin.views) { view in
                        Label("\(view.title) · \(view.kind.title)", systemImage: view.kind.icon).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 7)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(plugin.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("\(plugin.types.count) 类型 · \(plugin.methods.count) 方法 · \(plugin.views.count) 视图")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Toggle("启用", isOn: Binding(get: { store.book?.disabledPluginIDs.contains(plugin.id) != true }, set: { enabled in Task { await store.setPluginEnabled(enabled, id: plugin.id) } }))
                .toggleStyle(.switch).controlSize(.mini).fixedSize().disabled(store.isBusy)
        }.padding(.vertical, 4)
    }
}

private struct CompactTypeRow: View {
    let type: EntityType
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                Text("类型 ID：\(type.id)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                if type.fields.isEmpty { Text("未声明附加字段").font(.caption).foregroundStyle(.secondary) }
                ForEach(type.fields, id: \.key) { field in
                    Text("\(field.label) · \(field.key)\(field.required ? " · 必填" : "")").font(.caption).textSelection(.enabled)
                }
            }.padding(.top, 5)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: type.icon).frame(width: 16).foregroundStyle(Palette.accent)
                Text(type.name).lineLimit(1)
                Text("\(type.fields.count) 字段").font(.caption2).foregroundStyle(.secondary)
            }.font(.system(size: 12))
        }
    }
}

private struct CompactMethodRow: View {
    let method: ReadingMethod
    var isSelected = false
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(method.goal).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(Array(method.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(index + 1).").foregroundStyle(.secondary)
                        Text(step).textSelection(.enabled)
                    }.font(.caption)
                }
            }.padding(.top, 5)
        } label: {
            HStack(spacing: 7) {
                Text(method.name).lineLimit(1)
                Text("\(method.steps.count) 步").font(.caption2).foregroundStyle(.secondary)
                if isSelected { Text("本次方案").font(.caption2).foregroundStyle(Palette.accent) }
            }.font(.system(size: 12))
        }
    }
}

/// Shared by the compact model and OCR sheets; footer actions stay outside scrolling content.
struct CompactSettingsSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.accent.opacity(0.08), lineWidth: 1))
    }
}
