import SwiftUI
import UniformTypeIdentifiers
import ReadingCore

struct WorkspaceView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 238, max: 290)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.45)
                if store.book != nil {
                    HSplitView {
                        content.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let id = store.selectedObjectID, store.book?.documents.contains(where: { $0.id == id }) != true {
                            ObjectInspector(id: id).frame(minWidth: 270, idealWidth: 310, maxWidth: 380)
                        }
                    }
                } else { WelcomeView() }
                footer
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(Palette.accent)
        .onOpenURL { url in Task { await store.openInternalURL(url) } }
        .sheet(isPresented: $store.showingSettings) { ProviderSettingsView().environmentObject(store).frame(width: 590, height: 540) }
        .sheet(isPresented: $store.showingPlugins) { PluginLibraryView().environmentObject(store).frame(width: 660, height: 580) }
        .alert("需要处理", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard !store.isBusy, let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                if let data = value as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { Task { @MainActor in store.importBook(url) } }
            }
            return true
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "book.closed.fill").font(.title2).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) { Text("ReadingBook").font(.headline); Text("让阅读长成理解").font(.caption2).foregroundStyle(.secondary) }
            }.padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    Text("书 库").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.bottom, 5)
                    ForEach(store.books) { book in
                        Button { Task { await store.selectBook(book.id); store.route = "reader" } } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 4).fill(Palette.accent.opacity(0.14)).frame(width: 28, height: 36).overlay(Image(systemName: "book.closed").font(.caption).foregroundStyle(Palette.accent))
                                VStack(alignment: .leading, spacing: 4) { Text(book.title).lineLimit(1).font(.subheadline.weight(.medium)); ProgressView(value: book.progress).tint(Palette.accent).frame(width: 95) }
                                Spacer(minLength: 0)
                            }.padding(9).background(store.bookID == book.id ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).disabled(store.isBusy)
                    }
                    Button { store.chooseBook() } label: { Label("导入一本书", systemImage: "plus").font(.subheadline).padding(10) }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(store.isBusy)
                    if let book = store.book {
                        Divider().padding(.vertical, 16)
                        Text("阅读工作台").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.horizontal, 12)
                        routeButton("原文阅读", icon: "book.pages", route: "reader")
                        routeButton("阅读流程", icon: ComponentKind.workflow.icon, route: "workflow")
                        routeButton("与书对话", icon: ComponentKind.query.icon, route: "query")
                        routeButton("我的理解", icon: "square.and.pencil", route: "editor")
                        if !store.enabledViews.isEmpty {
                            Text("AI 为这本书选择").font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.top, 17)
                            ForEach(store.enabledViews.filter { ![ComponentKind.workflow, .query, .editor].contains($0.kind) }) { view in
                                routeButton(view.title, icon: view.kind.icon, route: view.id)
                            }
                        }
                        Menu {
                            ForEach(ComponentKind.allCases, id: \.self) { kind in Button(kind.title) { store.activate(kind) } }
                        } label: { Label("添加组件", systemImage: "square.grid.2x2").font(.caption).padding(10) }.menuStyle(.borderlessButton).disabled(store.isBusy)
                    }
                }.padding(.horizontal, 12)
            }
            Divider().opacity(0.5)
            HStack {
                Button { store.showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }.help("自己的 AI")
                Button { store.showingPlugins = true } label: { Image(systemName: "puzzlepiece.extension") }.help("插件与读书法")
                Spacer()
                Menu { Button("导入书项目…") { store.importProject() }; Button("导出完整书项目…") { store.exportProject() } } label: { Image(systemName: "square.and.arrow.up") }.menuStyle(.borderlessButton).frame(width: 25)
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(20)
        }.background(.ultraThinMaterial)
    }
    private func routeButton(_ title: String, icon: String, route: String) -> some View {
        Button { store.route = route } label: {
            Label(title, systemImage: icon).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
                .background(store.route == route ? Palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).foregroundStyle(store.route == route ? Palette.accent : .primary)
    }
    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.book?.title ?? "你的下一次发现").font(.system(size: 18, weight: .semibold, design: .serif))
                Text(routeTitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let book = store.book {
                Text("\(book.completedCount) / \(book.units.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if store.isBusy { Button { store.pause() } label: { Label("暂停", systemImage: "pause.fill") } }
                else { Button { store.startReading() } label: { Label(book.completedCount > 0 ? "继续精读" : "开始精读", systemImage: "sparkles") }.buttonStyle(.borderedProminent) }
            }
        }.padding(.horizontal, 28).padding(.vertical, 18)
    }
    private var routeTitle: String { store.book?.views.first { $0.id == store.route }?.title ?? (store.route == "reader" ? "原文与证据" : ComponentKind(rawValue: store.route)?.title ?? "阅读工作台") }
    @ViewBuilder private var content: some View {
        if store.route == "reader" { ReaderWorkspaceView() }
        else {
            let kind = store.book?.views.first { $0.id == store.route }?.kind ?? ComponentKind(rawValue: store.route) ?? .workflow
            switch kind {
            case .cards: EntityCardsView(typeIDs: store.book?.views.first { $0.id == store.route }?.typeIDs ?? [])
            case .timeline, .map: SpatialTimelineView()
            case .mindmap: DocumentGraphView()
            case .relations: RelationGraphView()
            case .knowledge: KnowledgeLibraryView()
            case .editor: DocumentEditorView()
            case .query: BookChatView()
            case .workflow: ReadingWorkflowView()
            }
        }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            if store.isBusy { ProgressView().controlSize(.mini) } else { Circle().fill(Palette.accent.opacity(0.55)).frame(width: 5, height: 5) }
            Text(store.activity).lineLimit(1).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if store.requestsUsed > 0 { Text("本轮 \(store.requestsUsed) 次请求").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
            Text("本地书库").font(.caption2).foregroundStyle(.tertiary)
        }.padding(.horizontal, 22).padding(.vertical, 10).background(.bar)
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "book.pages.fill").font(.system(size: 62, weight: .ultraLight)).foregroundStyle(Palette.accent)
            VStack(spacing: 12) {
                Text("读一本书，\n留下一片自己的知识。").font(.system(size: 38, weight: .regular, design: .serif)).multilineTextAlignment(.center).lineSpacing(8)
                Text("原文、人物与概念、时间与空间，以及你写下的理解。\n让自己的 AI 把它们连接起来。").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(6)
            }
            Button { store.chooseBook() } label: { Label("导入一本书", systemImage: "plus").padding(.horizontal, 18).padding(.vertical, 5) }.buttonStyle(.borderedProminent).controlSize(.large)
            Text("PDF · EPUB · Markdown · TXT   /   也可以拖入窗口").font(.caption).foregroundStyle(.tertiary)
            HStack(spacing: 30) {
                feature("逐段阅读", "book", "看见进度与原文依据")
                feature("随书生长", "puzzlepiece.extension", "AI 选择组件和内容类型")
                feature("写下理解", "square.and.pencil", "Markdown 留在自己手中")
            }.padding(.top, 25)
            Spacer()
            Button("连接自己的 AI") { store.showingSettings = true }.buttonStyle(.plain).foregroundStyle(Palette.accent).padding(.bottom, 36)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
    private func feature(_ title: String, _ icon: String, _ detail: String) -> some View {
        VStack(spacing: 8) { Image(systemName: icon).foregroundStyle(Palette.accent); Text(title).font(.subheadline.weight(.medium)); Text(detail).font(.caption).foregroundStyle(.secondary) }
    }
}

struct EmptyState: View {
    var title: String
    var detail: String
    var icon: String = "sparkles"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 36, weight: .light)).foregroundStyle(Palette.accent.opacity(0.7))
            Text(title).font(.title3.weight(.medium)); Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440).lineSpacing(5)
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.borderedProminent).padding(.top, 8) }
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ObjectInspector: View {
    @EnvironmentObject var store: AppStore
    let id: String
    @State private var editingEntity: KnowledgeEntity?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("关联与依据").font(.caption).foregroundStyle(.secondary); Spacer(); Button { store.selectedObjectID = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                if let entity = store.book?.entities.first(where: { $0.id == id }) {
                    Text(store.book?.types.first { $0.id == entity.typeID }?.name ?? entity.typeID).font(.caption).foregroundStyle(Palette.copper)
                    Text(entity.name).font(.system(size: 26, design: .serif)); MarkdownText(markdown: entity.summary)
                    Button("编辑卡片") { editingEntity = entity }.font(.caption).disabled(store.isBusy)
                    ForEach(entity.properties.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 5) { Text(fieldLabel(key, type: entity.typeID)).font(.caption).foregroundStyle(.secondary); Text(entity.properties[key] ?? "").textSelection(.enabled) }
                    }
                    if let note = entity.locationNote { Label(note, systemImage: "location").font(.caption).foregroundStyle(.secondary) }
                    ForEach((store.book?.events ?? []).filter { $0.participantIDs.contains(id) || $0.placeIDs.contains(id) }) { event in Button(event.name) { store.focus(event.id) }.buttonStyle(.plain).foregroundStyle(Palette.accent) }
                    EvidenceList(evidence: entity.evidence)
                } else if let event = store.book?.events.first(where: { $0.id == id }) {
                    Text("事件").font(.caption).foregroundStyle(Palette.copper); Text(event.name).font(.system(size: 26, design: .serif))
                    Label(event.dateText, systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
                    MarkdownText(markdown: event.summary)
                    linkGroup("地点", ids: event.placeIDs); linkGroup("参与者", ids: event.participantIDs)
                    EvidenceList(evidence: event.evidence)
                } else if let unit = store.book?.units.first(where: { $0.id == id }) {
                    Text(unit.chapter).font(.title3); Text(unit.locator).font(.caption).foregroundStyle(.secondary)
                    Text(String(unit.text.prefix(500))).font(.caption).lineSpacing(5).textSelection(.enabled)
                }
                ForEach((store.book?.relations ?? []).filter { $0.fromID == id || $0.toID == id }) { relation in
                    Button { store.focus(relation.fromID == id ? relation.toID : relation.fromID) } label: {
                        Label("\(relation.label) · \(store.objectTitle(relation.fromID == id ? relation.toID : relation.fromID))", systemImage: "arrow.up.right").font(.caption)
                    }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                }
                ForEach((store.book?.documents ?? []).filter { $0.linkedIDs.contains(id) }) { document in
                    Button { Task { await store.openDocument(document) } } label: { Label(document.title, systemImage: "doc.text").font(.caption) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                }
            }.padding(22)
        }.background(.background).sheet(item: $editingEntity) { entity in EntityEditView(entity: entity).environmentObject(store) }
    }
    private func fieldLabel(_ key: String, type: String) -> String { store.book?.types.first { $0.id == type }?.fields.first { $0.key == key }?.label ?? key }
    private func linkGroup(_ title: String, ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption).foregroundStyle(.secondary); ForEach(ids, id: \.self) { target in Button(store.objectTitle(target)) { store.focus(target) }.buttonStyle(.plain).foregroundStyle(Palette.accent) } }
    }
}

struct EvidenceList: View {
    @EnvironmentObject var store: AppStore
    var evidence: [Evidence]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !evidence.isEmpty { Text("回到原文").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            ForEach(Array(evidence.enumerated()), id: \.offset) { _, reference in
                Button { store.follow(reference) } label: {
                    VStack(alignment: .leading, spacing: 5) { Text(store.book?.units.first { $0.id == reference.unitID }?.locator ?? reference.unitID).font(.caption2).foregroundStyle(Palette.accent); Text(reference.quote).font(.caption).foregroundStyle(.secondary).lineLimit(4) }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
            }
        }
    }
}
