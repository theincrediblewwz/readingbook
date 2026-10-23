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
                searchField
                nodeList
                Divider().opacity(0.45)
                preview
            }
        }.frame(width: width, height: collapsed ? 60 : height).contentShape(Rectangle()).onTapGesture { }.readingGlass(radius: 24)
    }
    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "circle.grid.2x3.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text("节点").font(.system(size: 18, weight: .semibold))
                Text("\(items.count)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                .overlay {
                    if let beginDrag, let drag, let cancelDrag {
                        FloatingPanelPointerInput(epoch: dragEpoch, begin: beginDrag, drag: drag, cancel: cancelDrag).accessibilityHidden(true)
                    }
                }.help("拖动标题移动节点面板")
            if let toggleCollapsed {
                Button(action: toggleCollapsed) { Image(systemName: collapsed ? "plus" : "minus") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help(collapsed ? "展开节点面板" : "收起节点面板内容")
                    .accessibilityLabel(collapsed ? "展开节点面板" : "收起节点面板内容")
            }
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("关闭节点面板，可从右侧恢复").accessibilityLabel("关闭节点面板")
        }.padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
    }
    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索节点…", text: $query).textFieldStyle(.plain).font(.system(size: 15))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("清除节点搜索")
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
            }.frame(height: min(390, max(96, (height - 152) * 0.60)))
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
                .font(.caption).foregroundStyle(.secondary).padding(14).frame(maxHeight: .infinity, alignment: .topLeading)
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
                Text(item.title).font(.system(size: 16, weight: selected ? .semibold : .medium)).foregroundStyle(selected ? Palette.accent : Palette.ink).lineLimit(2)
                Text(item.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
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

private struct GraphNodeDetails: View {
    @EnvironmentObject var store: AppStore
    var item: GraphItem
    @State private var markdown: String?
    @State private var loadError: String?
    @State private var previewDocumentID: String?
    private var documents: [DocumentRecord] {
        let ids = Set(item.documentIDs + [item.targetID])
        return store.book?.activeDocuments.filter { ids.contains($0.id) } ?? []
    }
    private var document: DocumentRecord? { documents.first { $0.id == previewDocumentID } ?? documents.first }
    private var revision: String { "\(store.bookID ?? "")|\(item.targetID)|\(document?.id ?? "")|\(document?.updatedAt.timeIntervalSince1970 ?? 0)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title).font(.system(size: 20, weight: .semibold)).textSelection(.enabled)
                if documents.count > 1 {
                    Menu {
                        ForEach(documents) { document in Button(document.title) { previewDocumentID = document.id } }
                    } label: { Label(document?.title ?? "挂载的笔记", systemImage: "doc.on.doc").frame(minHeight: 44) }
                        .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                }
                if let document {
                    Text(document.origin == "user" ? "我的笔记 · 已保存内容" : "主动保存的 AI 摘记").font(.caption).foregroundStyle(.secondary)
                    if let loadError { Text(loadError).font(.caption).foregroundStyle(.red) }
                    else if let markdown { MarkdownText(markdown: markdown) }
                    else { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                    if !document.evidence.isEmpty { EvidenceDisclosure(evidence: document.evidence).id(document.id) }
                } else if let entity = store.book?.entities.first(where: { $0.id == item.targetID }) {
                    Text(entity.summary).font(.subheadline).textSelection(.enabled)
                    ForEach(entity.properties.sorted(by: { $0.key < $1.key }), id: \.key) { field in
                        VStack(alignment: .leading, spacing: 3) { Text(field.key).font(.caption).foregroundStyle(.secondary); Text(field.value).font(.subheadline).textSelection(.enabled) }
                    }
                    if !entity.evidence.isEmpty { EvidenceDisclosure(evidence: entity.evidence).id(entity.id) }
                } else if let event = store.book?.events.first(where: { $0.id == item.targetID }) {
                    Text(event.dateText).font(.caption).foregroundStyle(Palette.accent)
                    Text(event.summary).font(.subheadline).textSelection(.enabled)
                    if !event.placeIDs.isEmpty { Text("地点：" + event.placeIDs.map(store.objectTitle).joined(separator: "、")).font(.subheadline) }
                    if !event.participantIDs.isEmpty { Text("参与者：" + event.participantIDs.map(store.objectTitle).joined(separator: "、")).font(.subheadline) }
                    if !event.evidence.isEmpty { EvidenceDisclosure(evidence: event.evidence).id(event.id) }
                } else if let unit = store.book?.units.first(where: { $0.id == item.targetID }) {
                    Text(unit.locator).font(.caption).foregroundStyle(.secondary)
                    Text(unit.text).font(.system(size: 15)).textSelection(.enabled)
                } else { Text("这个节点暂时没有可预览的内容。").font(.subheadline).foregroundStyle(.secondary) }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.task(id: revision) {
            markdown = nil; loadError = nil
            guard let bookID = store.bookID, let document else { return }
            do {
                let value = try await store.repository.readDocument(bookID: bookID, document: document)
                guard !Task.isCancelled, store.bookID == bookID else { return }
                markdown = value
            } catch is CancellationError { }
            catch { if !Task.isCancelled { loadError = error.localizedDescription } }
        }
    }
}
