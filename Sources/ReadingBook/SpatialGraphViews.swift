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
            if entities.isEmpty {
                if !query.isEmpty || !filter.isEmpty { EmptyState(title: "没有匹配的卡片", detail: "调整搜索词或类型筛选，已保存的卡片仍会保留。", icon: "magnifyingglass") }
                else { EmptyState(title: "卡片会随着阅读长出来", detail: "AI 会依据内容创建人物、概念、定理或自定义类型，并保留每张卡片的原文依据。", icon: "rectangle.stack") }
            }
            else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18)], alignment: .leading, spacing: 18) {
                        ForEach(entities) { entity in
                            Button { store.focus(entity.id); inspectedEntity = entity } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack { Image(systemName: store.book?.types.first { $0.id == entity.typeID }?.icon ?? "square.stack").font(.system(size: 24)).foregroundStyle(Palette.accent); Spacer(); Text(store.book?.types.first { $0.id == entity.typeID }?.name ?? entity.typeID).font(.system(size: 13)).foregroundStyle(.secondary) }
                                    Text(entity.name).font(.system(size: 16, weight: .semibold))
                                    Text(entity.summary).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(4).frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
                                    HStack { Text("\(entity.evidence.count) 处原文依据").font(.system(size: 12)).foregroundStyle(.secondary); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 13)).foregroundStyle(Palette.accent) }
                                }.softPanel().overlay(RoundedRectangle(cornerRadius: 14).stroke(store.selectedObjectID == entity.id ? Palette.accent.opacity(0.5) : .clear, lineWidth: 1)).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }.padding(.top, 80).padding(.bottom, 92).background(Palette.canvas)
            .overlay(alignment: .bottom) { cardsDock.padding(.horizontal, 24).padding(.bottom, 18) }
            .popover(item: $inspectedEntity) { entity in
            ObjectInspector(id: entity.id, onClose: { inspectedEntity = nil }).environmentObject(store).frame(width: 330, height: 500)
        }.onChange(of: store.bookID) { _, _ in inspectedEntity = nil; query = ""; filter = "" }
            .onChange(of: typeIDs) { _, ids in if !ids.isEmpty && !ids.contains(filter) { filter = "" } }
    }
    private var cardsDock: some View {
        ReadingDockSurface {
                Text("\(entities.count) 张卡片").font(.system(size: 14)).foregroundStyle(.secondary).padding(.leading, 12)
                DockDivider()
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("查找卡片", text: $query).textFieldStyle(.plain).font(.system(size: 15))
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }.buttonStyle(.plain).help("清除卡片搜索").accessibilityLabel("清除卡片搜索") }
                }.padding(.horizontal, 14).frame(width: 260, height: 44)
                    .background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                Menu {
                    Picker("类型", selection: $filter) {
                        Text("全部类型").tag("")
                        ForEach((store.book?.types ?? []).filter { typeIDs.isEmpty || typeIDs.contains($0.id) }) { type in Text(type.name).tag(type.id) }
                    }
                } label: { Image(systemName: filter.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill").frame(width: 44, height: 44).contentShape(Rectangle()) }.menuStyle(.borderlessButton).fixedSize().help("筛选卡片类型")
        }
    }

}

struct DocumentGraphView: View {
    @EnvironmentObject var store: AppStore
    @State private var inspectedID: String?
    @State private var operationError: String?
    @State private var physicalSelection: String?
    @State private var focusRequest: String?
    @State private var focusToken: UUID?
    @State private var presentation = BookGraphPresentationCache()
    private var graphData: BookGraphSnapshot {
        guard let book = store.book else { return BookGraphSnapshot() }
        return presentation.documents(book: book, revision: store.projectRevision)
    }
    var body: some View {
        Group {
            if let book = store.book, !graphData.items.isEmpty {
                graphWorkspace(book).id(book.id)
            } else {
                EmptyState(title: "从第一篇笔记开始", detail: "在“我的笔记”写一篇笔记，或主动保存 AI 回答。双击节点打开文档，从节点边缘的圆点拖出连线。", icon: "point.3.connected.trianglepath.dotted")
            }
        }.popover(isPresented: Binding(get: { inspectedID != nil }, set: { if !$0 { inspectedID = nil } })) {
            if let id = inspectedID { ObjectInspector(id: id, onClose: { inspectedID = nil }).environmentObject(store).frame(width: 330, height: 500) }
        }.onChange(of: store.bookID) { _, _ in inspectedID = nil; physicalSelection = nil; focusRequest = nil; focusToken = nil }
    }

    private func graphWorkspace(_ book: BookProject) -> some View {
        let graphItems = graphData.items, graphLines = graphData.lines
        return FloatingGraphWorkspace<GraphSurface>(items: graphItems,
                                       memoryID: "mindmap.browser",
                                       selectedNodeID: physicalSelection ?? graphItems.first(where: { $0.targetID == store.selectedObjectID })?.id,
                                       select: { item in
                                           guard !store.isBusy else { return }
                                           physicalSelection = item.id; store.focus(item.targetID); focusRequest = item.id; focusToken = UUID()
                                       }, open: { item in openNode(item.targetID, nodeID: item.id) }) { exclusion, leading, trailing in
            graphSurface(book: book, items: graphItems, lines: graphLines, exclusion: exclusion, leading: leading, trailing: trailing)
        }
    }
    private func graphSurface(book: BookProject, items graphItems: [GraphItem], lines graphLines: [GraphLine], exclusion: CGRect, leading: CGFloat, trailing: CGFloat) -> GraphSurface {
        let sourceBookID = book.id
        return GraphSurface(
                    items: graphItems,
                    lines: graphLines,
                    selectedID: store.selectedObjectID, select: store.focus,
                    open: { id in
                        openNode(id)
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
                    interactionExclusion: exclusion, obscuredLeadingWidth: leading, obscuredTrailingWidth: trailing,
                    openPhysicalNode: { physical in
                        if let node = book.nodes.first(where: { $0.id == physical }) { openNode(node.targetID, nodeID: physical) }
                    }
                )
    }
    private func openNode(_ id: String, nodeID: String? = nil) {
        guard let book = store.book else { return }
        let chosen = nodeID.flatMap { physical in book.nodes.first { $0.id == physical } } ?? book.nodes.first { $0.targetID == id }
        if let documentID = chosen?.documentIDs?.first(where: { id in book.activeDocuments.contains { $0.id == id } }),
           let document = book.activeDocuments.first(where: { $0.id == documentID }) { Task { await store.openDocument(document) }; return }
        if book.activeDocuments.contains(where: { $0.id == id }) || book.units.contains(where: { $0.id == id }) { store.openObject(id) }
        else if chosen?.isStandalone != true { inspectedID = id }
    }
}

struct RelationGraphView: View {
    @EnvironmentObject var store: AppStore
    @State private var inspectedID: String?
    @State private var physicalSelection: String?
    @State private var focusRequest: String?
    @State private var focusToken: UUID?
    @State private var presentation = BookGraphPresentationCache()
    private var graphData: BookGraphSnapshot {
        guard let book = store.book else { return BookGraphSnapshot() }
        return presentation.relations(book: book, revision: store.projectRevision, context: store.readingScopeCurrent ? store.currentReadingContext : nil,
                                      point: store.temporalPoint, boundary: store.temporalBoundary,
                                      scopedItems: { store.readingContextItems })
    }
    private var items: [GraphItem] { graphData.items }
    private var lines: [GraphLine] { graphData.lines }
    var body: some View {
        Group {
            if items.isEmpty {
                EmptyState(title: "关系来自阅读", detail: "AI 发现的依赖、参与、发生于等关系会在这里连接。双击节点查看卡片与原文。", icon: "point.3.filled.connected.trianglepath.dotted")
                    .overlay(alignment: .bottom) {
                        ReadingDockSurface {
                            Button { store.readingScopeCurrent.toggle() } label: {
                                Label(store.readingScopeCurrent ? "当前原文 · 切换全书" : "全书关系 · 切换当前原文", systemImage: "line.3.horizontal.decrease").frame(minHeight: 44)
                            }.buttonStyle(ReadingToolbarButtonStyle())
                        }.padding(.bottom, 18)
                    }
            }
            else { FloatingGraphWorkspace(items: items, memoryID: "relations.browser", selectedNodeID: physicalSelection ?? store.selectedObjectID,
                                          select: { item in physicalSelection = item.id; store.focus(item.targetID); focusRequest = item.id; focusToken = UUID() },
                                          open: { inspectedID = $0.targetID }) { exclusion, leading, trailing in
                GraphSurface(items: items, lines: lines, selectedID: store.selectedObjectID, select: store.focus,
                                open: { inspectedID = $0 }, deselect: { store.selectedObjectID = nil }, inspect: { inspectedID = $0 },
                                title: "关系图谱", isEnabled: !store.isBusy,
                                focusNodeID: focusRequest, focusRequestToken: focusToken, selectedNodeIDChanged: { physicalSelection = $0 },
                                interactionExclusion: exclusion, obscuredLeadingWidth: leading, obscuredTrailingWidth: trailing,
                                scopeTitle: store.readingScopeCurrent ? "当前原文" : "全书关系", toggleScope: { store.readingScopeCurrent.toggle() }, ambientMotion: true)
                }.id(store.bookID) }
        }.popover(isPresented: Binding(get: { inspectedID != nil }, set: { if !$0 { inspectedID = nil } })) {
            if let id = inspectedID { ObjectInspector(id: id, onClose: { inspectedID = nil }).environmentObject(store).frame(width: 330, height: 500) }
        }.onChange(of: store.bookID) { _, _ in inspectedID = nil; physicalSelection = nil; focusRequest = nil; focusToken = nil }
    }
}

private struct BookGraphSnapshot { var items: [GraphItem] = []; var lines: [GraphLine] = [] }

/// Workspace camera/panel updates publish presentation state frequently. The
/// expensive book-to-graph projection only changes with book content or scope.
private final class BookGraphPresentationCache {
    private struct Key: Equatable {
        var bookID: String; var revision: Int; var kind: String; var context: ReadingContext?
        var point: TemporalQueryPoint? = nil; var boundary: KnowledgeReadBoundary = .all
    }
    private var key: Key?
    private var snapshot = BookGraphSnapshot()
    func documents(book: BookProject, revision: Int) -> BookGraphSnapshot {
        let next = Key(bookID: book.id, revision: revision, kind: "documents", context: nil)
        if key == next { return snapshot }
        let hidden = Set(book.trashedDocuments.map(\.id)), active = Set(book.activeDocuments.map(\.id))
        let nodes = book.nodes.filter { node in !hidden.contains(node.targetID) || (node.documentIDs ?? []).contains(where: active.contains) }, ids = Set(nodes.map(\.id))
        let titles = Dictionary((book.entities.map { ($0.id, $0.name) } + book.events.map { ($0.id, $0.name) } + book.documents.map { ($0.id, $0.title) }), uniquingKeysWith: { first, _ in first })
        let items = nodes.map { node in
            let mounts = (node.documentIDs ?? []).filter(active.contains)
            let documents = mounts.isEmpty && active.contains(node.targetID) ? [node.targetID] : mounts
            return GraphItem(id: node.id, targetID: node.targetID, title: node.title ?? titles[node.targetID] ?? documents.first.flatMap { titles[$0] } ?? "新节点",
                subtitle: documents.isEmpty ? "知识节点" : documents.count == 1 ? "Markdown" : "\(documents.count) 篇 Markdown", x: node.x, y: node.y, documentIDs: documents)
        }
        snapshot = BookGraphSnapshot(items: items, lines: book.edges.filter { ids.contains($0.fromID) && ids.contains($0.toID) }.map { GraphLine(id: $0.id, from: $0.fromID, to: $0.toID, label: $0.label) })
        key = next; return snapshot
    }
    func relations(book: BookProject, revision: Int, context: ReadingContext?, point: TemporalQueryPoint? = nil, boundary: KnowledgeReadBoundary = .all, scopedItems: () -> ReadingContextItems) -> BookGraphSnapshot {
        let next = Key(bookID: book.id, revision: revision, kind: "relations", context: context, point: point, boundary: boundary)
        if key == next { return snapshot }
        let scoped = context == nil ? nil : scopedItems()
        let scopedIDs = scoped.map { Set($0.entities.map(\.id) + $0.events.map(\.id)) }
        let canonical = ((try? TemporalKnowledgeRuntime.objects(in: book, boundary: boundary)) ?? []).filter { $0.kind != .document && (scopedIDs?.contains($0.id) ?? true) }
        let timedEvents = ((try? TemporalKnowledgeRuntime.events(in: book, at: point, boundary: boundary)) ?? []).filter { point == nil || $0.match != .outside }
        let timedIDs = Set(timedEvents.map(\.object.id))
        let types = Dictionary(book.types.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let objects = canonical.filter { $0.kind != .event || timedIDs.contains($0.id) }.map { ($0.id, $0.name, $0.kind == .event ? "事件" : (types[$0.typeID] ?? "要素")) }
        let items = objects.enumerated().map { index, item in
            let angle = Double(index) * 2.399963229728653, radius = max(190, sqrt(Double(index + 1)) * 125)
            return GraphItem(id: item.0, targetID: item.0, title: item.1, subtitle: item.2, x: cos(angle) * radius, y: sin(angle) * radius)
        }
        let ids = Set(items.map(\.id))
        let relations = (try? TemporalKnowledgeRuntime.relations(in: book, at: point, boundary: boundary)) ?? []
        var lines = relations.filter { $0.match != .outside }.map { item in
            GraphLine(id: item.relation.id + "|" + (item.metadata?.id ?? "legacy"), from: item.relation.fromID, to: item.relation.toID,
                      label: item.relation.label + (point != nil && item.match != .matches ? " · 时间待考" : ""))
        }
        for item in timedEvents {
            let event = item.object
            lines += (event.references["places"] ?? []).map { GraphLine(id: "event-place|\(event.id)|\($0)", from: event.id, to: $0, label: "发生于") }
            lines += (event.references["participants"] ?? []).map { GraphLine(id: "event-person|\(event.id)|\($0)", from: $0, to: event.id, label: "参与") }
        }
        snapshot = BookGraphSnapshot(items: items, lines: lines.filter { ids.contains($0.from) && ids.contains($0.to) })
        key = next; return snapshot
    }
}

struct KnowledgeLibraryView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var section = "documents"
    @State private var documentTexts: [String: String] = [:]
    @State private var loadedDocumentKey: DocumentSearchRequest?
    private struct DocumentSearchEntry: Hashable {
        let id: String
        let relativePath: String
        let updatedAt: Date
    }
    private struct DocumentSearchRequest: Hashable {
        let libraryRoot: URL
        let bookID: String
        let sourceHash: String
        let documents: [DocumentSearchEntry]
    }
    private var documents: [DocumentRecord] {
        let contentIsCurrent = loadedDocumentKey == documentSearchKey
        return (store.book?.activeDocuments ?? []).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || (contentIsCurrent && documentTexts[$0.id]?.localizedCaseInsensitiveContains(query) == true) }
    }
    private var insights: [ReadingInsight] {
        (store.book?.insights ?? []).filter { query.isEmpty || $0.markdown.localizedCaseInsensitiveContains(query) }
    }
    private var entities: [KnowledgeEntity] {
        (store.book?.entities ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !query.isEmpty { Text("搜索全部笔记、阅读分析与要素").font(.caption).foregroundStyle(.secondary) }
                    documentSection
                    insightSection
                    entitySection
                    if !query.isEmpty, documents.isEmpty, insights.isEmpty, entities.isEmpty { Text("没有找到匹配内容。").foregroundStyle(.secondary).padding(.vertical, 20) }
                }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: 1100).frame(maxWidth: .infinity, alignment: .topLeading)
            }.background(Palette.canvas)
        }.padding(.top, 80).padding(.bottom, 92).background(Palette.canvas)
            .overlay(alignment: .bottom) { libraryDock.padding(.horizontal, 24).padding(.bottom, 18) }
            .popover(isPresented: Binding(get: { inspectedID != nil }, set: { if !$0 { inspectedID = nil } })) {
            if let id = inspectedID { ObjectInspector(id: id, onClose: { inspectedID = nil }).environmentObject(store).frame(width: 330, height: 500) }
        }.task(id: documentSearchKey) {
            documentTexts = [:]; loadedDocumentKey = nil
            // Opening the library needs metadata only. Read Markdown bodies
            // once when a content search is active, not on every library visit.
            guard let request = documentSearchKey, let book = store.book else { return }
            let repository = store.repository
            var loaded: [String: String] = [:]
            do {
                for document in book.activeDocuments {
                    try Task.checkCancellation()
                    loaded[document.id] = try await repository.readDocument(bookID: book.id, document: document)
                }
                if !Task.isCancelled, documentSearchKey == request { documentTexts = loaded; loadedDocumentKey = request }
            }
            catch is CancellationError { }
            catch { if !Task.isCancelled, documentSearchKey == request { store.errorMessage = error.localizedDescription } }
        }.onChange(of: store.bookID) { _, _ in inspectedID = nil; query = "" }
    }
    @ViewBuilder private var documentSection: some View {
        if section == "documents" || !query.isEmpty {
            if !query.isEmpty { sectionLabel("笔记", count: documents.count) }
            ForEach(documents) { document in
                Button { Task { await store.openDocument(document) } } label: {
                    HStack(spacing: 11) {
                        BrandGlyph(name: "note").frame(width: 19, height: 19).foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(document.title).font(.system(size: 16, weight: .medium)).lineLimit(2)
                            Text(document.origin == "user" ? "我的笔记" : "主动保存的摘记").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(document.updatedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Palette.accent)
                    }.padding(20).frame(maxWidth: .infinity, minHeight: 88, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16)).contentShape(Rectangle())
                }.buttonStyle(.plain).contextMenu {
                    Button("加入导图") { Task { await store.addDocumentToGraph(document) } }.disabled(store.isBusy)
                    Button("移入回收站", role: .destructive) { store.requestDeletion(.document, id: document.id, title: document.title) }.disabled(store.isBusy)
                }
            }
            if documents.isEmpty, query.isEmpty { Text("还没有保存笔记。可以主动保存 AI 回答，或写下自己的理解。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20) }
        }
    }
    @ViewBuilder private var insightSection: some View {
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
    }
    @ViewBuilder private var entitySection: some View {
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
    }
    @State private var inspectedID: String?
    private var libraryDock: some View {
        ReadingDockSurface {
            categoryPicker
            DockDivider()
            librarySearch
            DockDivider()
            newNoteButton
        }
    }
    private var categoryPicker: some View {
        HStack(spacing: 2) {
            ForEach([("documents", "笔记"), ("insights", "分析"), ("entities", "要素")], id: \.0) { item in
                Button { section = item.0 } label: { Text(item.1).font(.system(size: 15)).frame(minWidth: 44, minHeight: 44) }
                    .buttonStyle(ReadingToolbarButtonStyle(selected: section == item.0)).accessibilityAddTraits(section == item.0 ? .isSelected : [])
            }
        }.accessibilityLabel("知识库内容分类").disabled(!query.isEmpty)
    }
    private var librarySearch: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索全部内容", text: $query).textFieldStyle(.plain).font(.system(size: 15))
            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }.buttonStyle(.plain).help("清除知识搜索").accessibilityLabel("清除知识搜索") }
        }.padding(.horizontal, 14).frame(width: 260, height: 44)
            .background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }
    private var newNoteButton: some View {
        DockIconButton(title: "新建笔记", icon: "square.and.pencil") { store.newDocument() }.disabled(store.isBusy)
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
    private var documentSearchKey: DocumentSearchRequest? {
        guard !query.isEmpty, let book = store.book else { return nil }
        return DocumentSearchRequest(libraryRoot: store.libraryRootURL, bookID: book.id, sourceHash: book.sourceHash,
            documents: book.activeDocuments.map { DocumentSearchEntry(id: $0.id, relativePath: $0.relativePath, updatedAt: $0.updatedAt) })
    }
}
