import SwiftUI
import ReadingCore

@MainActor extension AppStore {
    static let modelCatalogRepository = ModelCatalogRepository(rootURL:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReadingBook/ModelCatalog", isDirectory: true))
    func loadModelCatalog() async {
        do { providerCatalog = try await Self.modelCatalogRepository.load(baseline: .current).catalog }
        catch { connectionStatus = "自定义模型目录未能读取，已保留文件并使用内置目录：\(error.localizedDescription)" }
    }
}

/// Public catalog metadata has a separate lifecycle from saved connections,
/// credentials, books and conversation. The model can propose, never apply.
struct ModelCatalogManagerView: View {
    @EnvironmentObject private var store: AppStore
    var onClose: () -> Void
    @State private var snapshot: ModelCatalogSnapshot?
    @State private var review: ModelCatalogReview?
    @State private var evidence: [CatalogPublicEvidence] = []
    @State private var request = "核对当前公共模型目录的服务地址、可用 Chat 协议型号、上下文和输出上限；新增近期型号，附上实际读取的官方依据，不复制其他服务的限额。"
    @State private var officialURLs = ""
    @State private var status = ""
    @State private var running = false
    @State private var search = ""
    @State private var task: Task<Void, Never>?
    private var catalog: ProviderCatalog { snapshot?.catalog ?? store.providerCatalog }
    @State private var pane = "update"
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 18)).foregroundStyle(Palette.accent)
                Text("模型目录").font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 8)
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle())
                    .keyboardShortcut(.cancelAction).accessibilityLabel("关闭模型目录")
            }.padding(.horizontal, 16).frame(height: 56)
            Divider().opacity(0.4)
            GeometryReader { geometry in
                if geometry.size.width >= 880 {
                    HStack(spacing: 0) {
                        catalogList.frame(width: 280)
                        Divider().opacity(0.4)
                        updatePanel
                    }
                } else {
                    VStack(spacing: 0) {
                        Picker("目录页面", selection: $pane) {
                            Text("目录").tag("catalog"); Text(review == nil ? "更新目录" : "审阅提案").tag("update")
                        }.pickerStyle(.segmented).labelsHidden().padding(16)
                        if pane == "catalog" { catalogList } else { updatePanel }
                    }
                }
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 8) {
                Text("已保存的连接、模型选择和 Key 保持不变。").font(.system(size: 13)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    catalogActions
                }
            }.padding(16)
        }.frame(minWidth: 600, idealWidth: 980, minHeight: 440, idealHeight: 640)
            .font(.system(size: 15)).background(Palette.surface).task { await load() }.onDisappear { task?.cancel() }
            .onChange(of: review != nil) { _, available in if available { pane = "update" } }
            .onExitCommand(perform: onClose)
    }
    private var updatePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let review { proposalReview(review) } else { updateRequest }
                if !status.isEmpty {
                    Label(status, systemImage: running ? "sparkles" : "info.circle")
                        .font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    @ViewBuilder private var catalogActions: some View {
        if running {
            Button("停止核对") { task?.cancel() }.buttonStyle(ReadingToolbarButtonStyle())
        } else if review != nil {
            Button("放弃提案") { review = nil; evidence = []; status = "原目录保留。" }.buttonStyle(ReadingToolbarButtonStyle())
            Button("应用目录更新", action: applyReview).buttonStyle(.borderedProminent).controlSize(.large).frame(minHeight: 44)
        } else {
            Button("回退上次目录", action: rollback).buttonStyle(ReadingToolbarButtonStyle()).disabled(snapshot?.canRollback != true)
            Button(action: inspect) { Label("AI 检查官网", systemImage: "sparkles") }.buttonStyle(.borderedProminent).controlSize(.large).frame(minHeight: 44).disabled(snapshot == nil || store.isBusy)
        }
    }
    private var catalogList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索服务或型号", text: $search).textFieldStyle(.plain)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("清空型号搜索") }
            }.padding(.leading, 14).padding(.trailing, search.isEmpty ? 14 : 0).frame(height: 44)
                .background(Palette.paper.opacity(0.75), in: RoundedRectangle(cornerRadius: 16)).padding(16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(catalog.providers.filter { provider in search.isEmpty || provider.name.localizedCaseInsensitiveContains(search) || provider.models.contains(where: { $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }) }) { provider in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(provider.name).font(.system(size: 16, weight: .semibold))
                            ForEach(provider.models) { model in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.name).font(.system(size: 15, weight: .medium))
                                    Text("上下文 \(model.contextTokens.map(String.init) ?? "未确认") · 输出 \(model.maxOutputTokens.map(String.init) ?? "未确认")")
                                        .font(.system(size: 13)).foregroundStyle(.secondary)
                                }.padding(.vertical, 3)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(Palette.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
                    }
                }.padding(.horizontal, 14).padding(.bottom, 18)
            }
        }
    }
    private var updateRequest: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("让目录跟上新模型").font(.system(size: 18, weight: .semibold))
            Text("AI 查阅官网并生成提案。核对型号、上限与出处后，再由你保存。")
                .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4)
            TextEditor(text: $request).font(.system(size: 15)).scrollContentBackground(.hidden).padding(12)
                .frame(height: 130).background(Palette.paper, in: RoundedRectangle(cornerRadius: 14)).disabled(running)
            Text("补充官网链接 · 可选，每行一个 HTTPS 地址").font(.system(size: 13, weight: .medium))
            TextField("https://服务商官网/文档", text: $officialURLs, axis: .vertical).textFieldStyle(.plain).lineLimit(2...4)
                .padding(14).background(Palette.paper, in: RoundedRectangle(cornerRadius: 14)).disabled(running)
            Text("仅发送公开目录资料。点击检查将使用当前模型的请求额度；未核实的上限保持空缺。").font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
    private func proposalReview(_ value: ModelCatalogReview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("检查这次更新").font(.system(size: 18, weight: .semibold))
            Text(value.proposal.summary).font(.system(size: 15)).lineSpacing(4)
            ForEach(value.differences) { difference in
                VStack(alignment: .leading, spacing: 8) {
                    Text(difference.path).font(.subheadline.weight(.semibold)).textSelection(.enabled)
                    Text(difference.before.isEmpty ? "之前：未收录" : "之前：" + difference.before).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("更新：" + difference.after).font(.callout).textSelection(.enabled)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.paper.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
            }
            ForEach(value.proposal.providers) { provider in
                ForEach(Array((provider.sources ?? []).enumerated()), id: \.offset) { _, source in
                    DisclosureGroup("来源 · \(provider.name)") {
                        Text(source.quote).font(.callout).textSelection(.enabled).padding(.top, 8)
                        if let url = URL(string: source.url) { Link("打开原始资料", destination: url) }
                    }.font(.subheadline)
                }
            }
        }
    }
    private func load() async {
        do {
            let value = try await AppStore.modelCatalogRepository.load(baseline: .current)
            snapshot = value; store.providerCatalog = value.catalog
        } catch { status = error.localizedDescription }
    }
    private func inspect() {
        guard !running, let snapshot else { return }
        guard store.providerReady else { status = "请先配置可用的模型与 Key。"; return }
        let configuration = store.settings, key = store.apiKey, instruction = request
        let urls = officialURLs.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        running = true; status = "准备核对官网…"
        task = Task {
            defer { running = false }
            do {
                let reader = try ModelCatalogPublicReader(additionalOfficialURLs: urls)
                let assistant = ModelCatalogAssistant(reader: reader)
                let result = try await assistant.inspect(request: instruction, catalog: snapshot.catalog, settings: configuration, apiKey: key, progress: { message in await MainActor.run { status = message } })
                try Task.checkCancellation()
                review = try await AppStore.modelCatalogRepository.prepare(proposal: result.proposal, evidence: result.evidence, expectedRevision: snapshot.revision, baseline: .current)
                evidence = result.evidence; status = "尝试读取 \(result.readsUsed) 次，保留 \(result.evidence.count) 个资料片段；请检查差异后再应用。"
            } catch is CancellationError { status = "已停止，原目录保留。" }
            catch { status = error.localizedDescription }
        }
    }
    private func applyReview() {
        guard !running, let review else { return }
        running = true
        task = Task {
            defer { running = false }
            do {
                let value = try await AppStore.modelCatalogRepository.apply(review: review, baseline: .current)
                snapshot = value; store.providerCatalog = value.catalog; self.review = nil; evidence = []; status = "模型目录已更新。原有连接保持不变。"
            } catch { status = error.localizedDescription }
        }
    }
    private func rollback() {
        guard !running, let snapshot else { return }
        running = true
        task = Task {
            defer { running = false }
            do {
                let value = try await AppStore.modelCatalogRepository.rollback(expectedRevision: snapshot.revision, baseline: .current)
                self.snapshot = value; store.providerCatalog = value.catalog; status = "已回退上次公共目录，连接和 Key 保留。"
            } catch { status = error.localizedDescription }
        }
    }
}
