import SwiftUI
import ReadingCore

struct EntityCardsView: View {
    @EnvironmentObject var store: AppStore
    var typeIDs: [String]
    @State private var filter = ""
    @State private var query = ""
    @State private var inspectedEntity: KnowledgeEntity?
    private var entities: [KnowledgeEntity] {
        (store.book?.entities ?? []).filter { (typeIDs.isEmpty || typeIDs.contains($0.typeID)) && (filter.isEmpty || $0.typeID == filter) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompactWorkspaceHeader("卡片", subtitle: "\(entities.count) 张") {
                TextField("查找卡片", text: $query).textFieldStyle(.roundedBorder).frame(minWidth: 90, maxWidth: 200)
                Menu {
                    Picker("类型", selection: $filter) {
                        Text("全部类型").tag("")
                        ForEach((store.book?.types ?? []).filter { typeIDs.isEmpty || typeIDs.contains($0.id) }) { type in Text(type.name).tag(type.id) }
                    }
                } label: { Image(systemName: filter.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") }.help("筛选卡片类型")
            }
            if entities.isEmpty {
                if !query.isEmpty || !filter.isEmpty { EmptyState(title: "没有匹配的卡片", detail: "调整搜索词或类型筛选，已保存的卡片仍会保留。", icon: "magnifyingglass") }
                else { EmptyState(title: "卡片会随着阅读长出来", detail: "AI 会依据内容创建人物、概念、定理或自定义类型，并保留每张卡片的原文依据。", icon: "rectangle.stack") }
            }
            else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(entities) { entity in
                            Button { store.focus(entity.id); inspectedEntity = entity } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack { Image(systemName: store.book?.types.first { $0.id == entity.typeID }?.icon ?? "square.stack").font(.title3).foregroundStyle(Palette.accent); Spacer(); Text(store.book?.types.first { $0.id == entity.typeID }?.name ?? entity.typeID).font(.caption2).foregroundStyle(.secondary) }
                                    Text(entity.name).font(.system(size: 20, design: .serif))
                                    Text(entity.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                                    HStack { Text("\(entity.evidence.count) 处原文依据").font(.caption2).foregroundStyle(.tertiary); Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Palette.accent) }
                                }.softPanel().overlay(RoundedRectangle(cornerRadius: 14).stroke(store.selectedObjectID == entity.id ? Palette.accent.opacity(0.5) : .clear, lineWidth: 1)).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(16)
                }
            }
        }.popover(item: $inspectedEntity) { entity in
            ObjectInspector(id: entity.id, onClose: { inspectedEntity = nil }).environmentObject(store).frame(width: 330, height: 500)
        }.onChange(of: store.bookID) { _, _ in inspectedEntity = nil; query = ""; filter = "" }
            .onChange(of: typeIDs) { _, ids in if !ids.isEmpty && !ids.contains(filter) { filter = "" } }
    }
}

struct DocumentGraphView: View {
    @EnvironmentObject var store: AppStore
    @State private var inspectedID: String?
    @State private var operationError: String?
    @State private var physicalSelection: String?
    @State private var focusRequest: String?
    @State private var focusToken: UUID?
    @State private var showsNodes = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var browserNamespace
    private var nodes: [CanvasNode] {
        guard let book = store.book else { return [] }
        let hidden = Set(book.trashedDocuments.map(\.id))
        return book.nodes.filter { !hidden.contains($0.targetID) }
    }
    var body: some View {
        Group {
            if let book = store.book, !nodes.isEmpty {
                let sourceBookID = book.id
                let nodeIDs = Set(nodes.map(\.id))
                let graphItems = nodes.map { node in GraphItem(id: node.id, targetID: node.targetID, title: store.objectTitle(node.targetID), subtitle: book.activeDocuments.contains { $0.id == node.targetID } ? "Markdown" : "知识节点", x: node.x, y: node.y) }
                GeometryReader { geometry in
                let panelHeight = min(620, max(260, geometry.size.height - 96))
                GraphSurface(
                    items: graphItems,
                    lines: book.edges.filter { nodeIDs.contains($0.fromID) && nodeIDs.contains($0.toID) }.map { GraphLine(id: $0.id, from: $0.fromID, to: $0.toID, label: $0.label) },
                    selectedID: store.selectedObjectID, select: store.focus,
                    open: { id in
                        if book.activeDocuments.contains(where: { $0.id == id }) || book.units.contains(where: { $0.id == id }) { store.openObject(id) }
                        else { inspectedID = id }
                    },
                    move: { id, x, y in
                        guard store.bookID == sourceBookID else { return false }
                        return await store.moveNode(id: id, x: x, y: y, onError: { operationError = $0 })
                    },
                    remove: { id in Task { guard store.bookID == sourceBookID else { return }; await store.removeCanvasNode(id) } },
                    connect: { from, to in
                        guard store.bookID == sourceBookID else { return false }
                        return await store.connectNodes(from: from, to: to, label: "延伸", onError: { operationError = $0 })
                    },
                    renameLine: { id, label in
                        guard store.bookID == sourceBookID else { return false }
                        return await store.renameCanvasEdge(id: id, label: label, onError: { operationError = $0 })
                    },
                    removeLine: { id in
                        guard store.bookID == sourceBookID else { return false }
                        return await store.removeConnection(id, onError: { operationError = $0 })
                    },
                    deselect: { store.selectedObjectID = nil },
                    inspect: { id in inspectedID = id },
                    createDocument: { store.newDocument() },
                    title: "思维导图", isEnabled: !store.isBusy, errorText: { operationError },
                    focusNodeID: focusRequest, focusRequestToken: focusToken,
                    selectedNodeIDChanged: { physicalSelection = $0 },
                    interactionExclusion: showsNodes ? CGRect(x: max(0, geometry.size.width - ReadingLayout.nodeBrowserWidth - 12), y: 12, width: ReadingLayout.nodeBrowserWidth, height: panelHeight) : CGRect(x: max(0, geometry.size.width - 172), y: 12, width: 160, height: 56),
                    obscuredTrailingWidth: showsNodes ? ReadingLayout.nodeBrowserWidth + 24 : 0
                ).overlay(alignment: .topTrailing) {
                    if showsNodes {
                        GraphNodeBrowser(items: graphItems, selectedNodeID: physicalSelection ?? graphItems.first(where: { $0.targetID == store.selectedObjectID })?.id, height: panelHeight,
                                         select: { item in
                                             guard !store.isBusy else { return }; physicalSelection = item.id; store.focus(item.targetID); focusRequest = item.id; focusToken = UUID()
                                         }, open: { item in openNode(item.targetID) }, close: { withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { showsNodes = false } })
                            .contentShape(Rectangle()).readingGlassIdentity("document-nodes", in: browserNamespace).padding(12)
                            .transition(.opacity)
                    } else {
                        Button { withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { showsNodes = true } } label: { Label("节点 · \(graphItems.count)", systemImage: "sidebar.right") }
                            .buttonStyle(ReadingToolbarButtonStyle()).padding(5).readingGlass(interactive: true)
                            .readingGlassIdentity("document-nodes", in: browserNamespace).padding(12)
                    }
                }.readingGlassGroup()
                }.id(sourceBookID)
            } else {
                EmptyState(title: "从第一篇理解开始", detail: "在“我的理解”写一篇笔记，或主动保存 AI 回答。双击节点打开文档，从节点边缘的圆点拖出连线。", icon: "point.3.connected.trianglepath.dotted")
            }
        }.popover(isPresented: Binding(get: { inspectedID != nil }, set: { if !$0 { inspectedID = nil } })) {
            if let id = inspectedID { ObjectInspector(id: id, onClose: { inspectedID = nil }).environmentObject(store).frame(width: 330, height: 500) }
        }.onChange(of: store.bookID) { _, _ in inspectedID = nil; physicalSelection = nil; focusRequest = nil; focusToken = nil; showsNodes = true }
    }
    private func openNode(_ id: String) {
        guard let book = store.book else { return }
        if book.activeDocuments.contains(where: { $0.id == id }) || book.units.contains(where: { $0.id == id }) { store.openObject(id) }
        else { inspectedID = id }
    }
}

struct RelationGraphView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inspectedID: String?
    @State private var physicalSelection: String?
    @State private var focusRequest: String?
    @State private var focusToken: UUID?
    @State private var showsNodes = true
    @Namespace private var browserNamespace
    private var items: [GraphItem] {
        guard let book = store.book else { return [] }
        let entities = store.readingScopeCurrent ? store.readingContextItems.entities : book.entities
        let events = store.readingScopeCurrent ? store.readingContextItems.events : book.events
        let objects = entities.map { entity in (entity.id, entity.name, book.types.first(where: { $0.id == entity.typeID })?.name ?? "要素") } + events.map { ($0.id, $0.name, "事件") }
        return objects.enumerated().map { index, item in
            let angle = Double(index) * 2.399963229728653
            let radius = max(190, sqrt(Double(index + 1)) * 125)
            return GraphItem(id: item.0, targetID: item.0, title: item.1, subtitle: item.2, x: cos(angle) * radius, y: sin(angle) * radius)
        }
    }
    private var lines: [GraphLine] {
        guard let book = store.book else { return [] }
        var lines = book.relations.map { GraphLine(id: $0.id, from: $0.fromID, to: $0.toID, label: $0.label) }
        for event in book.events {
            lines += event.placeIDs.map { GraphLine(id: "event-place|\(event.id)|\($0)", from: event.id, to: $0, label: "发生于") }
            lines += event.participantIDs.map { GraphLine(id: "event-person|\(event.id)|\($0)", from: $0, to: event.id, label: "参与") }
        }
        let ids = Set(items.map(\.id))
        return lines.filter { ids.contains($0.from) && ids.contains($0.to) }
    }
    var body: some View {
        VStack(spacing: 0) {
            CompactWorkspaceHeader("关系图谱", subtitle: store.readingScopeCurrent ? "当前原文" : "全书") {
                Toggle("当前原文", isOn: $store.readingScopeCurrent).toggleStyle(.switch).controlSize(.small)
            }
        Group {
            if items.isEmpty { EmptyState(title: "关系来自阅读", detail: "AI 发现的依赖、参与、发生于等关系会在这里连接。双击节点查看卡片与原文。", icon: "point.3.filled.connected.trianglepath.dotted") }
            else { GeometryReader { geometry in
                let panelHeight = min(620, max(260, geometry.size.height - 96))
                GraphSurface(items: items, lines: lines, selectedID: store.selectedObjectID, select: store.focus,
                                open: { inspectedID = $0 }, deselect: { store.selectedObjectID = nil }, inspect: { inspectedID = $0 },
                                title: "关系图谱", isEnabled: !store.isBusy,
                                focusNodeID: focusRequest, focusRequestToken: focusToken, selectedNodeIDChanged: { physicalSelection = $0 },
                                interactionExclusion: showsNodes ? CGRect(x: max(0, geometry.size.width - ReadingLayout.nodeBrowserWidth - 12), y: 12, width: ReadingLayout.nodeBrowserWidth, height: panelHeight) : CGRect(x: max(0, geometry.size.width - 172), y: 12, width: 160, height: 56), obscuredTrailingWidth: showsNodes ? ReadingLayout.nodeBrowserWidth + 24 : 0)
                    .overlay(alignment: .topTrailing) {
                        if showsNodes {
                            GraphNodeBrowser(items: items, selectedNodeID: physicalSelection ?? store.selectedObjectID, height: panelHeight,
                                             select: { item in physicalSelection = item.id; store.focus(item.targetID); focusRequest = item.id; focusToken = UUID() },
                                             open: { inspectedID = $0.targetID }, close: { withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { showsNodes = false } })
                                .contentShape(Rectangle()).readingGlassIdentity("relation-nodes", in: browserNamespace).padding(12).transition(.opacity)
                        } else {
                            Button { withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { showsNodes = true } } label: { Label("节点 · \(items.count)", systemImage: "sidebar.right") }
                                .buttonStyle(ReadingToolbarButtonStyle()).padding(5).readingGlass(interactive: true)
                                .readingGlassIdentity("relation-nodes", in: browserNamespace).padding(12)
                        }
                    }.readingGlassGroup()
                }.id(store.bookID) }
        }.popover(isPresented: Binding(get: { inspectedID != nil }, set: { if !$0 { inspectedID = nil } })) {
            if let id = inspectedID { ObjectInspector(id: id, onClose: { inspectedID = nil }).environmentObject(store).frame(width: 330, height: 500) }
        }.onChange(of: store.bookID) { _, _ in inspectedID = nil; physicalSelection = nil; focusRequest = nil; focusToken = nil; showsNodes = true }
        }
    }
}

struct KnowledgeLibraryView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var section = "documents"
    @State private var documentTexts: [String: String] = [:]
    private var documents: [DocumentRecord] {
        (store.book?.activeDocuments ?? []).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || documentTexts[$0.id]?.localizedCaseInsensitiveContains(query) == true }
    }
    private var insights: [ReadingInsight] {
        (store.book?.insights ?? []).filter { query.isEmpty || $0.markdown.localizedCaseInsensitiveContains(query) }
    }
    private var entities: [KnowledgeEntity] {
        (store.book?.entities ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            CompactWorkspaceHeader("知识库") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: ReadingLayout.groupSpacing) { categoryPicker; librarySearch; newNoteButton }
                    VStack(alignment: .trailing, spacing: ReadingLayout.groupSpacing) {
                        categoryPicker
                        HStack(spacing: ReadingLayout.groupSpacing) { librarySearch; newNoteButton }
                    }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !query.isEmpty { Text("搜索全部笔记、阅读分析与要素").font(.caption).foregroundStyle(.secondary) }
                    if section == "documents" || !query.isEmpty {
                        if !query.isEmpty { sectionLabel("笔记", count: documents.count) }
                        ForEach(documents) { document in
                            Button { Task { await store.openDocument(document) } } label: {
                                HStack(spacing: 11) {
                                    BrandGlyph(name: "note").frame(width: 19, height: 19).foregroundStyle(Palette.accent)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(document.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                        Text(document.origin == "user" ? "我的理解" : "主动保存的摘记").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    Text(document.updatedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Palette.accent)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                            }.buttonStyle(.plain).contextMenu {
                                Button("加入导图") { Task { await store.addDocumentToGraph(document) } }.disabled(store.isBusy)
                                Button("移入回收站", role: .destructive) { store.requestDeletion(.document, id: document.id, title: document.title) }.disabled(store.isBusy)
                            }
                        }
                        if documents.isEmpty, query.isEmpty { Text("还没有保存笔记。可以主动保存 AI 回答，或写下自己的理解。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20) }
                    }
                    if section == "insights" || !query.isEmpty {
                        if !query.isEmpty { sectionLabel("阅读分析", count: insights.count) }
                        ForEach(insights) { insight in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 12) {
                                    MarkdownText(markdown: insight.markdown)
                                    ViewThatFits(in: .horizontal) {
                                        insightActions(insight)
                                        VStack(alignment: .leading, spacing: 8) { insightSources(insight); Button("保存为文档") { Task { await store.saveInsight(insight) } }.disabled(store.isBusy) }
                                    }.font(.caption)
                                }.padding(.top, 10)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(insight.unitIDs.first.flatMap { id in store.book?.units.first { $0.id == id }?.locator } ?? "阅读分析").font(.subheadline.weight(.medium))
                                    Text(excerpt(insight.markdown)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }.softPanel()
                        }
                        if insights.isEmpty, query.isEmpty { Text("精读保存的分析会出现在这里。展开条目查看全文与原文依据。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20) }
                    }
                    if section == "entities" || !query.isEmpty {
                        if !query.isEmpty { sectionLabel("要素", count: entities.count) }
                        ForEach(entities) { entity in
                            Button { store.focus(entity.id); inspectedID = entity.id } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: store.book?.types.first { $0.id == entity.typeID }?.icon ?? "square.stack").foregroundStyle(Palette.accent).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entity.name).font(.subheadline.weight(.medium))
                                        Text(entity.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if entities.isEmpty, query.isEmpty { Text("AI 创建的概念、人物或自定义要素会出现在这里。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20) }
                    }
                    if !query.isEmpty, documents.isEmpty, insights.isEmpty, entities.isEmpty { Text("没有找到匹配内容。").foregroundStyle(.secondary).padding(.vertical, 20) }
                }.padding(16).frame(maxWidth: 1000).frame(maxWidth: .infinity, alignment: .topLeading)
            }.background(Palette.canvas)
        }.popover(isPresented: Binding(get: { inspectedID != nil }, set: { if !$0 { inspectedID = nil } })) {
            if let id = inspectedID { ObjectInspector(id: id, onClose: { inspectedID = nil }).environmentObject(store).frame(width: 330, height: 500) }
        }.task(id: documentCacheKey) {
            documentTexts = [:]
            guard let book = store.book else { return }; var loaded: [String: String] = [:]
            do { for document in book.activeDocuments { try Task.checkCancellation(); loaded[document.id] = try await store.repository.readDocument(bookID: book.id, document: document) }; if !Task.isCancelled && store.book?.id == book.id { documentTexts = loaded } }
            catch is CancellationError { }
            catch { store.errorMessage = error.localizedDescription }
        }.onChange(of: store.bookID) { _, _ in inspectedID = nil; query = "" }
    }
    @State private var inspectedID: String?
    private var categoryPicker: some View {
        Picker("内容", selection: $section) {
            Text("笔记").tag("documents"); Text("分析").tag("insights"); Text("要素").tag("entities")
        }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
            .accessibilityLabel("知识库内容分类").disabled(!query.isEmpty)
    }
    private var librarySearch: some View {
        TextField("搜索全部内容", text: $query).textFieldStyle(.roundedBorder).frame(minWidth: 110, maxWidth: 210)
    }
    private var newNoteButton: some View {
        Button { store.newDocument() } label: { Image(systemName: "square.and.pencil") }
            .help("写下理解").accessibilityLabel("写下理解").disabled(store.isBusy)
    }
    private func sectionLabel(_ title: String, count: Int) -> some View {
        Text("\(title) · \(count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
    }
    private func excerpt(_ markdown: String) -> String {
        let compact = markdown.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let match = compact.range(of: query, options: .caseInsensitive) else { return String(compact.prefix(120)) }
        let start = compact.index(match.lowerBound, offsetBy: -30, limitedBy: compact.startIndex) ?? compact.startIndex
        return (start == compact.startIndex ? "" : "…") + String(compact[start...].prefix(120))
    }
    private func insightSources(_ insight: ReadingInsight) -> some View {
        Menu("回到原文") {
            ForEach(insight.unitIDs, id: \.self) { id in
                Button(store.book?.units.first { $0.id == id }?.locator ?? "原文") { store.navigateToUnit(id); store.route = "reader" }
            }
        }
    }
    private func insightActions(_ insight: ReadingInsight) -> some View {
        HStack { insightSources(insight); Spacer(); Button("保存为文档") { Task { await store.saveInsight(insight) } }.disabled(store.isBusy) }
    }
    private var documentCacheKey: String { (store.book?.id ?? "") + (store.book?.activeDocuments.map { $0.id + String($0.updatedAt.timeIntervalSince1970) }.joined(separator: "|") ?? "") }
}
