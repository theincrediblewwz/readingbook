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
    @State private var query = ""
    @State private var clickedInList: String?
    @FocusState private var focusedNodeID: String?
    private var filtered: [GraphItem] { items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query) } }
    private var selected: GraphItem? { items.first { $0.id == selectedNodeID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("节点", systemImage: "list.bullet.rectangle").font(.system(size: 14, weight: .semibold))
                Text("\(items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "sidebar.left") }.buttonStyle(ReadingToolbarButtonStyle()).help("收起节点列表").accessibilityLabel("收起节点列表")
            }.padding(.leading, 14).padding(.trailing, 6).padding(.top, 6)
            TextField("查找节点", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.vertical, 7)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filtered) { item in
                            HStack(spacing: 9) {
                                Image(systemName: item.subtitle == "Markdown" ? "doc.text" : "circle.hexagongrid").foregroundStyle(Palette.accent).frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.system(size: 13, weight: item.id == selectedNodeID ? .semibold : .regular)).lineLimit(2)
                                    Text(item.subtitle).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .background(item.id == selectedNodeID ? Palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                                .overlay { GraphPointerBridge(enabled: true, movable: false, click: { twice in clickedInList = item.id; focusedNodeID = item.id; select(item); if twice { open(item) } }, drag: { _, _ in }, cancel: {}) }
                                .focusable().focusEffectDisabled().focused($focusedNodeID, equals: item.id)
                                .onKeyPress(.space) { select(item); return .handled }
                                .onKeyPress(.return) { select(item); open(item); return .handled }
                                .contextMenu { Button("打开内容") { open(item) } }
                                .accessibilityElement(children: .combine).accessibilityLabel("\(item.title)，\(item.subtitle)")
                                .accessibilityHint("单击预览详情，双击打开内容。")
                                .accessibilityAction { select(item) }
                                .id(item.id)
                        }
                        if filtered.isEmpty { Text("没有匹配的节点").font(.subheadline).foregroundStyle(.secondary).padding(18) }
                    }.padding(.horizontal, 7).padding(.bottom, 7)
                }.frame(height: min(210, height * 0.38))
                    .onChange(of: selectedNodeID) { _, id in
                        defer { clickedInList = nil }
                        if let id, clickedInList != id, filtered.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center) }
                    }
            }
            Divider().opacity(0.45)
            if let selected {
                GraphNodeDetails(item: selected).id(selected.id).frame(maxHeight: .infinity)
            } else {
                Text("单击节点在这里查看内容，双击打开对应文档。")
                    .font(.caption).foregroundStyle(.secondary).padding(14).frame(maxHeight: .infinity, alignment: .topLeading)
            }
        }.frame(width: 288, height: height).contentShape(Rectangle()).onTapGesture { }.readingGlass(radius: 20)
    }
}

private struct GraphNodeDetails: View {
    @EnvironmentObject var store: AppStore
    var item: GraphItem
    @State private var markdown: String?
    @State private var loadError: String?
    private var document: DocumentRecord? { store.book?.activeDocuments.first { $0.id == item.targetID } }
    private var revision: String { "\(store.bookID ?? "")|\(item.targetID)|\(document?.updatedAt.timeIntervalSince1970 ?? 0)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title).font(.system(size: 17, weight: .semibold, design: .serif)).textSelection(.enabled)
                if let document {
                    Text(document.origin == "user" ? "我的理解 · 已保存内容" : "主动保存的 AI 摘记").font(.caption).foregroundStyle(.secondary)
                    if let loadError { Text(loadError).font(.caption).foregroundStyle(.red) }
                    else if let markdown { MarkdownText(markdown: markdown) }
                    else { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                    if !document.evidence.isEmpty { DisclosureGroup("原文依据 · \(document.evidence.count)") { EvidenceList(evidence: document.evidence) }.font(.caption) }
                } else if let entity = store.book?.entities.first(where: { $0.id == item.targetID }) {
                    Text(entity.summary).font(.subheadline).textSelection(.enabled)
                    ForEach(entity.properties.sorted(by: { $0.key < $1.key }), id: \.key) { field in
                        VStack(alignment: .leading, spacing: 3) { Text(field.key).font(.caption).foregroundStyle(.secondary); Text(field.value).font(.subheadline).textSelection(.enabled) }
                    }
                    EvidenceList(evidence: entity.evidence)
                } else if let event = store.book?.events.first(where: { $0.id == item.targetID }) {
                    Text(event.dateText).font(.caption).foregroundStyle(Palette.accent)
                    Text(event.summary).font(.subheadline).textSelection(.enabled)
                    if !event.placeIDs.isEmpty { Text("地点：" + event.placeIDs.map(store.objectTitle).joined(separator: "、")).font(.subheadline) }
                    if !event.participantIDs.isEmpty { Text("参与者：" + event.participantIDs.map(store.objectTitle).joined(separator: "、")).font(.subheadline) }
                    EvidenceList(evidence: event.evidence)
                } else if let unit = store.book?.units.first(where: { $0.id == item.targetID }) {
                    Text(unit.locator).font(.caption).foregroundStyle(.secondary)
                    Text(unit.text).font(.system(size: 15)).textSelection(.enabled)
                } else { Text("这个节点暂时没有可预览的内容。").font(.subheadline).foregroundStyle(.secondary) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
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
