import SwiftUI
import ReadingCore

struct ProviderSettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("连接自己的 AI").font(.system(size: 26, design: .serif)); Text("书籍与笔记留在本机；启动分析时会向这里的服务发送所需内容。").font(.caption).foregroundStyle(.secondary) }; Spacer() }
            Form {
                TextField("服务地址", text: $store.settings.baseURL).textFieldStyle(.roundedBorder)
                TextField("模型名称", text: $store.settings.model).textFieldStyle(.roundedBorder)
                SecureField("API Key", text: $store.apiKey).textFieldStyle(.roundedBorder)
                Text("兼容 Chat Completions 工具调用的模型。地址可为 /v1 或完整 /chat/completions；本机 Ollama 等服务可留空密钥。").font(.caption).foregroundStyle(.secondary)
                Stepper("每轮最多 \(store.settings.maxRequestsPerRun) 次请求", value: $store.settings.maxRequestsPerRun, in: 1...2000, step: 10)
                Stepper("单次输出最多 \(store.settings.maxOutputTokens) token", value: $store.settings.maxOutputTokens, in: 512...16000, step: 512)
            }.formStyle(.grouped).disabled(store.isBusy)
            Text("预读、每个内容单元与工具续轮都会消耗请求预算。达到上限后暂停，下次由你主动继续。首次运行先用短书或少量预算确认效果。").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            HStack { Button("关闭") { dismiss() }; Spacer(); Button("保存配置") { store.saveSettings(); if store.errorMessage == nil { dismiss() } }.buttonStyle(.borderedProminent).disabled(store.isBusy) }
        }.padding(28)
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
