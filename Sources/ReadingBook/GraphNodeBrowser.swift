import SwiftUI
import ReadingCore

/// Selection previews saved content here; only a double click opens the editor.
struct GraphNodeBrowser: View {
    @EnvironmentObject var store: AppStore
    var items: [GraphItem]
    var selectedNodeID: String?
    var height: CGFloat
    var select: (GraphItem) -> Void
    var open: (GraphItem) -> Void
    var close: () -> Void
    var collapsed = false
    var toggleCollapsed: (() -> Void)? = nil
    var width: CGFloat = ReadingLayout.nodeBrowserWidth
    var dragEpoch = 0
    var beginDrag: (() -> Void)? = nil
    var drag: ((CGSize, Bool) -> Void)? = nil
    var cancelDrag: (() -> Void)? = nil
    @State private var query = ""
    @State private var clickedInList: String?
    private var filtered: [GraphItem] { items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query) } }
    private var selected: GraphItem? { items.first { $0.id == selectedNodeID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                VStack(spacing: 0) {
                    searchField
                    nodeList
                    Divider().opacity(0.45)
                    preview
                }.transition(.opacity)
            }
        }.frame(width: width, height: collapsed ? 56 : height).contentShape(Rectangle()).onTapGesture { }.readingGlass(radius: 20)
    }
    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 18)).foregroundStyle(Palette.accent)
                Text("节点").font(.system(size: 16, weight: .semibold))
                Text("\(items.count)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                .overlay {
                    if let beginDrag, let drag, let cancelDrag {
                        FloatingPanelPointerInput(epoch: dragEpoch, begin: beginDrag, drag: drag, cancel: cancelDrag).accessibilityHidden(true)
                    }
                }.help("拖动标题移动节点面板").accessibilityHint("拖动标题可移动节点面板；右侧可收起或关闭")
            if let toggleCollapsed {
                Button(action: toggleCollapsed) { Image(systemName: collapsed ? "plus" : "minus") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help(collapsed ? "展开节点面板" : "收起节点面板内容")
                    .accessibilityLabel(collapsed ? "展开节点面板" : "收起节点面板内容")
            }
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("关闭节点面板，可从底部工具栏恢复").accessibilityLabel("关闭节点面板")
        }.padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6).frame(height: 56).layoutPriority(1)
    }
    private var searchField: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "magnifyingglass").readingSearchIcon()
            TextField("搜索节点…", text: $query).readingSearchInput()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }.buttonStyle(.plain).help("清除节点搜索").accessibilityLabel("清除节点搜索")
            }
        }.padding(.horizontal, 14).frame(height: 44).background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.line, lineWidth: 1)).padding(.horizontal, 16).padding(.bottom, 12)
    }
    private var nodeList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filtered) { item in
                        GraphNodeBrowserRow(item: item, selected: item.id == selectedNodeID) { twice in
                            clickedInList = item.id; select(item); if twice { open(item) }
                        }.id(item.id)
                    }
                    if filtered.isEmpty { Text("没有匹配的节点").font(.subheadline).foregroundStyle(.secondary).padding(18) }
                }.padding(.horizontal, 10).padding(.bottom, 10)
            }.frame(height: min(320, max(88, (height - 128) * 0.50)))
                .onChange(of: selectedNodeID) { _, id in
                    defer { clickedInList = nil }
                    if let id, clickedInList != id, filtered.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center) }
                }
        }
    }
    @ViewBuilder private var preview: some View {
        if let selected {
            GraphNodeDetails(item: selected).id(selected.id).frame(maxHeight: .infinity)
        } else {
            Text("单击节点在这里查看内容，双击打开对应文档。")
                .font(.system(size: 15)).foregroundStyle(.secondary).padding(16).frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct GraphNodeBrowserRow: View {
    let item: GraphItem
    let selected: Bool
    var activate: (Bool) -> Void
    @FocusState private var focused: Bool

    private var label: some View {
        HStack(spacing: 9) {
            Image(systemName: !item.documentIDs.isEmpty || item.subtitle == "Markdown" ? "doc.text" : "circle.hexagongrid")
                .font(.system(size: 23, weight: .regular)).foregroundStyle(Palette.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 15, weight: selected ? .semibold : .medium)).foregroundStyle(selected ? Palette.accent : Palette.ink).lineLimit(2)
                Text(item.subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Palette.accent.opacity(selected ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
    }
    var body: some View {
        label.overlay {
            GraphPointerBridge(enabled: true, movable: false,
                               click: { twice in focused = true; activate(twice) }, drag: { _, _ in }, cancel: {})
        }
        .focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(.space) { activate(false); return .handled }
        .onKeyPress(.return) { activate(true); return .handled }
        .contextMenu { Button("打开内容") { activate(true) } }
        .accessibilityElement(children: .combine).accessibilityLabel("\(item.title)，\(item.subtitle)")
        .accessibilityHint("单击预览详情，双击打开内容。")
        .accessibilityAction { activate(false) }
    }
}

/// One immutable view of a node and its related labels at the same read boundary.
/// The canonical graph objects and explicitly opened notes remain unchanged.
private struct GraphNodeDetailProjection: Sendable {
    enum Kind: Sendable { case entity, event, source, other }
    let request: String
    let kind: Kind
    let entity: KnowledgeEntity?
    let event: KnowledgeEvent?
    let unit: SourceUnit?
    let names: [String: String]

    static func build(request: String, targetID: String, book: BookProject, allowed: Set<String>?) -> Self? {
        guard !Task.isCancelled else { return nil }
        let context = ReadingSpoilerProjection.Context(project: book, allowedUnitIDs: allowed)
        guard !Task.isCancelled else { return nil }
        let originalEntity = book.entities.first { $0.id == targetID }
        let originalEvent = book.events.first { $0.id == targetID }
        let entity = originalEntity.flatMap { context.entity($0) }
        let event = originalEvent.flatMap { context.event($0) }
        let related = Set((event?.placeIDs ?? []) + (event?.participantIDs ?? []))
        var names: [String: String] = [:]
        for value in book.entities {
            guard !Task.isCancelled else { return nil }
            if related.contains(value.id), let visible = context.entity(value) { names[value.id] = visible.name }
        }
        let originalUnit = book.units.first { $0.id == targetID }
        let unit = originalEntity == nil && originalEvent == nil
            ? originalUnit.flatMap { allowed?.contains($0.id) != false ? $0 : nil } : nil
        guard !Task.isCancelled else { return nil }
        let kind: Kind = originalEntity != nil ? .entity : originalEvent != nil ? .event : originalUnit != nil ? .source : .other
        return Self(request: request, kind: kind, entity: entity, event: event, unit: unit, names: names)
    }
}

private struct GraphNodeDetails: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject private var typography: ReadingTypographySettings
    var item: GraphItem
    @State private var markdown: String?
    @State private var loadError: String?
    @State private var previewDocumentID: String?
    @State private var projection: GraphNodeDetailProjection?
    @State private var loadedDocumentRevision: String?
    private var documents: [DocumentRecord] {
        let ids = Set(item.documentIDs + [item.targetID])
        return store.book?.activeDocuments.filter { ids.contains($0.id) } ?? []
    }
    private var document: DocumentRecord? { documents.first { $0.id == previewDocumentID } ?? documents.first }
    private var revision: String {
        store.libraryRootURL.path + "|" + (store.bookID ?? "") + "|" + (store.book?.sourceHash ?? "") + "|" + item.targetID + "|" +
            (document?.id ?? "") + "|" + (document?.relativePath ?? "") + "|" + String(document?.updatedAt.timeIntervalSince1970 ?? 0)
    }
    private var projectionRequest: String {
        store.libraryRootURL.path + "|" + (store.bookID ?? "") + "|" + (store.book?.sourceHash ?? "") + "|" + item.targetID + "|" +
            (store.selectedUnitID ?? "") + "|" + (store.book?.temporalKnowledge?.profile?.avoidsSpoilers != false ? "safe" : "open") + "|" + String(store.projectRevision)
    }
    private var visibleProjection: GraphNodeDetailProjection? { projection?.request == projectionRequest ? projection : nil }
    private var title: String {
        if document != nil { return item.title }
        guard let value = visibleProjection else { return "正在读取内容" }
        switch value.kind {
        case .entity: return value.entity?.name ?? "本段尚无可显示的对象"
        case .event: return value.event?.name ?? "本段尚无可显示的事件"
        case .source: return value.unit == nil ? "尚未读到这里" : item.title
        case .other: return item.title
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 16, weight: .semibold)).textSelection(.enabled)
                if documents.count > 1 {
                    Menu {
                        ForEach(documents) { document in Button(document.title) { previewDocumentID = document.id } }
                    } label: { Label(document?.title ?? "挂载的笔记", systemImage: "doc.on.doc").frame(minHeight: 44) }
                        .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                }
                if let document {
                    Text(document.origin == "user" ? "我的笔记 · 已保存内容" : "主动保存的 AI 摘记").font(.caption).foregroundStyle(.secondary)
                    if loadedDocumentRevision == revision, let loadError { Text(loadError).font(.caption).foregroundStyle(.red) }
                    else if loadedDocumentRevision == revision, let markdown { MarkdownText(markdown: markdown).readingTextContext(.notes) }
                    else { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                    if !document.evidence.isEmpty { EvidenceDisclosure(evidence: document.evidence).id(document.id) }
                } else if let entity = visibleProjection?.entity {
                    Text(entity.summary).font(typography.font(for: .knowledge)).textSelection(.enabled)
                    ForEach(entity.properties.sorted(by: { $0.key < $1.key }), id: \.key) { field in
                        VStack(alignment: .leading, spacing: 3) { Text(field.key).font(.system(size: 13)).foregroundStyle(.secondary); Text(field.value).font(typography.font(for: .knowledge)).textSelection(.enabled) }
                    }
                    if !entity.evidence.isEmpty { EvidenceDisclosure(evidence: entity.evidence).id(entity.id) }
                } else if let event = visibleProjection?.event {
                    Text(event.dateText).font(.caption).foregroundStyle(Palette.accent)
                    Text(event.summary).font(typography.font(for: .knowledge)).textSelection(.enabled)
                    let places = event.placeIDs.compactMap { visibleProjection?.names[$0] }
                    let participants = event.participantIDs.compactMap { visibleProjection?.names[$0] }
                    if !places.isEmpty { Text("地点：" + places.joined(separator: "、")).font(typography.font(for: .knowledge)) }
                    if !participants.isEmpty { Text("参与者：" + participants.joined(separator: "、")).font(typography.font(for: .knowledge)) }
                    if !event.evidence.isEmpty { EvidenceDisclosure(evidence: event.evidence).id(event.id) }
                } else if let unit = visibleProjection?.unit {
                    Text(unit.locator).font(.caption).foregroundStyle(.secondary)
                    Text(unit.text).font(typography.font(for: .source)).textSelection(.enabled)
                } else if visibleProjection == nil, document == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else { Text("这个节点暂时没有可预览的内容。").font(.system(size: 15)).foregroundStyle(.secondary) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.task(id: projectionRequest) {
            guard document == nil, let book = store.book else { projection = nil; return }
            let request = projectionRequest, target = item.targetID, allowed = store.temporalBoundary.allowedUnitIDs
            let worker = Task.detached(priority: .userInitiated) { GraphNodeDetailProjection.build(request: request, targetID: target, book: book, allowed: allowed) }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, projectionRequest == request else { return }
            projection = result
        }.task(id: revision) {
            markdown = nil; loadError = nil
            guard let bookID = store.bookID, let document else { return }
            let request = revision, root = store.libraryRootURL, repository = store.repository
            do {
                let value = try await repository.readDocument(bookID: bookID, document: document)
                guard !Task.isCancelled, store.bookID == bookID, store.libraryRootURL == root, revision == request else { return }
                markdown = value; loadedDocumentRevision = request
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled, store.bookID == bookID, store.libraryRootURL == root, revision == request {
                    loadError = error.localizedDescription; loadedDocumentRevision = request
                }
            }
        }
    }
}
