import SwiftUI
import ReadingCore

struct ProviderSettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var deletingService = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自己的模型工作台").font(.system(size: 26, design: .serif))
            Text("保存多套服务，随时切换。文本分析发送所需原文，OCR 发送所选 PDF 页图。密钥只进本机 Keychain。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("已保存", selection: Binding(get: { store.selectedServiceID ?? "" }, set: { store.selectService($0) })) {
                    if store.selectedServiceID == nil { Text("新的未保存配置").tag("") }
                    ForEach(store.savedServices) { service in Text(service.name).tag(service.id) }
                }
                Menu("新建") {
                    Button("自定义兼容服务") { store.newService() }
                    Divider()
                    ForEach(ProviderCatalog.current.providers) { provider in Button(provider.name) { store.newService(provider) } }
                }
                Button(role: .destructive) { deletingService = true } label: { Image(systemName: "trash") }.disabled(store.selectedServiceID == nil)
            }.disabled(store.isBusy)
            Form {
                Section("连接") {
                    TextField("配置名称", text: $store.serviceName)
                    TextField("服务地址", text: $store.settings.baseURL)
                    HStack {
                        TextField("模型 API ID", text: $store.settings.model)
                        if let preset = store.matchingPreset {
                            Menu("模型预设") { ForEach(preset.models) { model in Button(model.name) { store.chooseModel(model) } } }
                        }
                    }
                    SecureField("API Key", text: $store.apiKey)
                }
                Section("能力与预算") {
                    if let model = store.matchingModel {
                        HStack { Label(model.vision ? "图像输入" : "文本模型", systemImage: model.vision ? "photo" : "text.alignleft"); Spacer(); Text(model.tools ? "支持工具调用" : "未确认工具调用").foregroundStyle(.secondary) }.font(.caption)
                        Text("上下文：\(model.contextTokens.map { String($0) } ?? "未确认") · 输出上限：\(model.maxOutputTokens.map { String($0) } ?? "未确认") token").font(.caption)
                        if let url = URL(string: model.documentationURL) { Link("官方规格 · 核查于 \(ProviderCatalog.current.verifiedAt)", destination: url).font(.caption) }
                    }
                    HStack {
                        TextField("单次最大输出 token", value: $store.settings.maxOutputTokens, format: .number)
                        Button("Max") { store.useMaximumOutput() }.disabled(store.matchingModel?.maxOutputTokens == nil)
                    }
                    TextField("上下文 token（未知可留空）", text: Binding(get: { store.settings.contextWindowTokens.map { String($0) } ?? "" }, set: { store.settings.contextWindowTokens = Int($0.replacingOccurrences(of: ",", with: "")) }))
                    Picker("输出参数", selection: Binding(get: { store.settings.tokenLimitParameter ?? "max_tokens" }, set: { store.settings.tokenLimitParameter = $0 })) {
                        Text("max_tokens").tag("max_tokens"); Text("max_completion_tokens").tag("max_completion_tokens")
                    }
                    Stepper("每轮最多 \(store.settings.maxRequestsPerRun) 次请求", value: $store.settings.maxRequestsPerRun, in: 1...2000)
                    Text("Max 取该模型已核实的输出上限；实际请求还受上下文余量和服务账户限制。推理模型的输出额度可能包含推理 token。未知型号可手动填写，不自动猜测。测试会发送一条短文本请求。").font(.caption).foregroundStyle(.secondary)
                }
                Section("PDF OCR 使用的配置") {
                    Picker("图像模型", selection: Binding(get: { store.ocrServiceID ?? "" }, set: { store.ocrServiceID = $0.isEmpty ? nil : $0; UserDefaults.standard.set(store.ocrServiceID, forKey: "ocr-service") })) {
                        Text("当前阅读服务").tag("")
                        ForEach(store.savedServices) { service in Text("\(service.name) · \(service.settings.model)").tag(service.id) }
                    }
                    Text("必须支持图像输入。文本模型与 OCR 可以选择不同的服务；逐页请求、逐页保存，可暂停续跑。").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).disabled(store.isBusy)
            if !store.connectionStatus.isEmpty { Text(store.connectionStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button("关闭") { dismiss() }; Spacer()
                Button("测试连接") { store.testConnection() }.disabled(store.isBusy || store.settings.model.isEmpty)
                Button("保存配置") { do { try store.persistServiceProfile(); store.connectionStatus = "配置已保存。" } catch { store.errorMessage = error.localizedDescription } }.buttonStyle(.borderedProminent).disabled(store.isBusy)
            }
        }.padding(28)
        .confirmationDialog("删除已保存的服务配置与其密钥？", isPresented: $deletingService) {
            Button("删除配置", role: .destructive) { if let id = store.selectedServiceID { store.removeService(id) } }
        } message: { Text("书籍、文档与已生成内容会保留。") }
    }
}

struct PluginLibraryView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading, spacing: 6) { Text("让组件随书生长").font(.system(size: 27, design: .serif)); Text("AI 调用插件能力，声明包提供类型、读书法与视图组合。").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("导入插件…") { store.importPlugin() }.disabled(store.book == nil || store.isBusy) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("内置能力").font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(ComponentKind.allCases, id: \.self) { kind in
                            Button { store.activate(kind); dismiss() } label: { VStack(spacing: 10) { Image(systemName: kind.icon).font(.title3).foregroundStyle(Palette.accent); Text(kind.title).font(.caption) }.frame(maxWidth: .infinity).padding(15).background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain).disabled(store.book == nil || store.isBusy)
                        }
                    }
                    Text("本书安装的声明包").font(.headline)
                    ForEach(store.book?.plugins ?? []) { plugin in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "puzzlepiece.extension").foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: 7) { Text(plugin.name).font(.subheadline.weight(.medium)); Text(plugin.description).font(.caption).foregroundStyle(.secondary); Text("\(plugin.types.count) 种类型 · \(plugin.methods.count) 套方法 · \(plugin.views.count) 个视图").font(.caption2).foregroundStyle(.tertiary) }
                            Spacer()
                            Toggle("启用", isOn: Binding(get: { store.book?.disabledPluginIDs.contains(plugin.id) != true }, set: { enabled in Task { await store.setPluginEnabled(enabled, id: plugin.id) } })).toggleStyle(.switch).controlSize(.small).disabled(store.isBusy)
                        }.softPanel()
                    }
                    if store.book?.plugins.isEmpty != false { Text("还没有安装声明包。仓库 Examples 中附有数学精读示例。").font(.caption).foregroundStyle(.secondary) }
                    if let book = store.book {
                        Text("可用读书法").font(.headline)
                        ForEach(book.methods) { method in VStack(alignment: .leading, spacing: 6) { Text(method.name).font(.subheadline.weight(.medium)); Text(method.goal).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4) }
                    }
                }.padding(.vertical, 5)
            }
            HStack { Text("停用声明包保留已有知识，不会删除用户文档。").font(.caption2).foregroundStyle(.secondary); Spacer(); Button("完成") { dismiss() } }
        }.padding(27)
    }
}
