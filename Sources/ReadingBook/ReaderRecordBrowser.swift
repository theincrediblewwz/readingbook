import SwiftUI
import ReadingCore

@MainActor final class ReaderRecordBrowserState: ObservableObject {
    @Published var grouping: ReadingRecordGrouping {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: "reader.recordGrouping.v1") }
    }
    @Published var defaultCollapsed: Bool {
        didSet { UserDefaults.standard.set(defaultCollapsed, forKey: "reader.recordsDefaultCollapsed.v1") }
    }
    @Published private(set) var foldRevision = 0
    private(set) var expandRequested = false
    init() {
        grouping = UserDefaults.standard.string(forKey: "reader.recordGrouping.v1").flatMap(ReadingRecordGrouping.init(rawValue:)) ?? .date
        defaultCollapsed = UserDefaults.standard.object(forKey: "reader.recordsDefaultCollapsed.v1") as? Bool ?? true
    }
    func setAll(expanded: Bool) { expandRequested = expanded; foldRevision += 1 }
}

struct ReaderRecordGroupingBar: View {
    @ObservedObject var state: ReaderRecordBrowserState
    @State private var options = false
    var body: some View {
        HStack(spacing: 6) {
            Button { options.toggle() } label: { Label(state.grouping.title, systemImage: state.grouping == .date ? "calendar" : state.grouping == .chapter ? "book.closed" : "list.bullet").font(.system(size: 12)).padding(.horizontal, 8).frame(minHeight: 36) }
                .buttonStyle(ReadingQuietButtonStyle()).help("按日期或章节收起查找；没有章节目录时按页码分组。")
                .popover(isPresented: $options) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("列表显示").font(.system(size: 16, weight: .semibold)).padding(.bottom, 4)
                        ForEach(ReadingRecordGrouping.allCases, id: \.self) { mode in
                            Button { state.grouping = mode; options = false } label: {
                                HStack { Text(mode.title); Spacer(); if mode == state.grouping { Image(systemName: "checkmark").foregroundStyle(Palette.accent) } }.frame(maxWidth: .infinity, minHeight: 40)
                            }.buttonStyle(ReadingQuietButtonStyle())
                        }
                        Divider().opacity(0.4)
                        Toggle("新打开时全部收起", isOn: $state.defaultCollapsed).toggleStyle(.switch).font(.system(size: 13))
                            .help("只改变列表显示，不改变历史归档、引用或AI上下文。")
                    }.padding(20).frame(width: 270)
                }
            Spacer(minLength: 2)
            Button { state.setAll(expanded: false) } label: { Image(systemName: "rectangle.compress.vertical").frame(width: 36, height: 36) }
                .buttonStyle(ReadingQuietButtonStyle()).help("全部收起；不改变归档或上下文").accessibilityLabel("收起列表全部记录")
            Button { state.setAll(expanded: true) } label: { Image(systemName: "rectangle.expand.vertical").frame(width: 36, height: 36) }
                .buttonStyle(ReadingQuietButtonStyle()).help("展开列表全部记录").accessibilityLabel("展开列表全部记录")
        }
    }
}

struct ReaderRecordSections<Content: View>: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var state: ReaderRecordBrowserState
    let ids: [String]
    var focusedID: String? = nil
    var onFocusReady: ((String) -> Void)? = nil
    var searching = false
    @ViewBuilder var row: (ReadingRecordDescriptor, Binding<Bool>) -> Content
    @State private var groups: [ReadingRecordGroup] = []
    @State private var expandedGroups: Set<String> = []
    @State private var expandedRows: Set<String> = []
    @State private var limits: [String: Int] = [:]
    @State private var ownerKey = ""
    @State private var appliedFoldRevision = 0
    @State private var appliedFocusKey = ""
    @State private var preparationError: String?
    private var preparationKey: String { store.collectionOwnerKey + "|" + String(store.projectRevision) + "|" + state.grouping.rawValue + "|" + ids.joined(separator: ",") + "|" + (focusedID ?? "") + "|" + String(searching) }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            if groups.isEmpty && !ids.isEmpty {
                Text(preparationError ?? "正在整理列表…").font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
            }
            ForEach(groups) { group in
                let expanded = expandedGroups.contains(group.id)
                Button { if expanded { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) } } label: {
                    HStack(spacing: 8) {
                        Text(group.title).font(.system(size: 13, weight: .medium)); Spacer(minLength: 4)
                        Text("\(group.records.count)").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3).background(Palette.line.opacity(0.3), in: Capsule())
                        Image(systemName: expanded ? "minus" : "plus").font(.system(size: 10, weight: .medium)).frame(width: 20)
                    }.padding(.horizontal, 9).frame(maxWidth: .infinity, minHeight: 38).contentShape(Rectangle())
                }.buttonStyle(ReadingQuietButtonStyle()).help((expanded ? "收起" : "展开") + "这组 \(group.records.count) 条记录；只改变显示。")
                    .accessibilityLabel(group.title + "，\(group.records.count)条，" + (expanded ? "已展开" : "已收起"))
                if expanded {
                    ForEach(Array(group.records.prefix(limits[group.id] ?? 60))) { record in
                        row(record, Binding(get: { expandedRows.contains(record.id) }, set: { value in if value { expandedRows.insert(record.id) } else { expandedRows.remove(record.id) } }))
                            .id(record.id)
                    }
                    if group.records.count > (limits[group.id] ?? 60) {
                        Button("继续显示这组记录（还剩 \(group.records.count - (limits[group.id] ?? 60)) 条）") { limits[group.id] = (limits[group.id] ?? 60) + 60 }
                            .buttonStyle(ReadingToolbarButtonStyle()).frame(minHeight: 40)
                    }
                }
            }
        }.task(id: preparationKey) {
            let key = preparationKey, owner = store.collectionOwnerKey, project = store.book, mode = state.grouping
            guard let project else { groups = []; return }
            preparationError = nil
            let offered = ids
            let worker = Task.detached(priority: .utility) { try ReadingRecordCatalog.prepare(in: project).groups(ids: offered, by: mode) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, key == preparationKey else { return }
                if ownerKey != owner { expandedGroups = []; expandedRows = []; limits = [:]; ownerKey = owner }
                groups = result
                if !state.defaultCollapsed || searching { expandedGroups.formUnion(result.map(\.id)) }
                if !state.defaultCollapsed { expandedRows.formUnion(result.flatMap(\.records).map(\.id)) }
                if state.foldRevision != appliedFoldRevision {
                    expandedGroups = state.expandRequested ? Set(result.map(\.id)) : []
                    expandedRows = state.expandRequested ? Set(result.flatMap(\.records).map(\.id)) : []
                    appliedFoldRevision = state.foldRevision
                }
                if let focusedID, appliedFocusKey != owner + "|" + focusedID, let group = result.first(where: { $0.records.contains { $0.id == focusedID } }) {
                    expandedGroups.insert(group.id); expandedRows.insert(focusedID)
                    if let index = group.records.firstIndex(where: { $0.id == focusedID }) { limits[group.id] = max(60, index + 1) }
                    // The reader that owns the enclosing ScrollView performs
                    // the one-time reveal. A reader nested in its content has
                    // no descendant scroll to control. Do not repeat a reveal
                    // after unrelated metadata/height updates.
                    try await Task.sleep(for: .milliseconds(25))
                    guard !Task.isCancelled, key == preparationKey else { return }
                    onFocusReady?(focusedID); appliedFocusKey = owner + "|" + focusedID
                }
            } catch { if !Task.isCancelled, key == preparationKey { groups = []; preparationError = "暂时无法整理列表：" + error.localizedDescription } }
        }.onChange(of: state.foldRevision) { _, _ in
            guard !groups.isEmpty || ids.isEmpty else { return }
            expandedGroups = state.expandRequested ? Set(groups.map(\.id)) : []
            expandedRows = state.expandRequested ? Set(groups.flatMap(\.records).map(\.id)) : []
            appliedFoldRevision = state.foldRevision
        }
    }
}

struct ReaderRecordFoldCard<Content: View>: View {
    let record: ReadingRecordDescriptor
    @Binding var expanded: Bool
    var selection: Binding<Bool>? = nil
    var open: (() -> Void)? = nil
    var openEnabled = true
    var status: String? = nil
    var actions: AnyView = AnyView(EmptyView())
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 3) {
                if let selection {
                    Button { selection.wrappedValue.toggle() } label: { Image(systemName: selection.wrappedValue ? "checkmark.circle.fill" : "circle").font(.system(size: 18)).frame(width: 40, height: 44) }
                        .buttonStyle(ReadingQuietButtonStyle()).foregroundStyle(selection.wrappedValue ? Palette.accent : .secondary)
                        .accessibilityLabel("引用：" + record.title).accessibilityValue(selection.wrappedValue ? "已引用" : "未引用")
                }
                Button { if let open { open() } else { expanded.toggle() } } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.title).font(.system(size: 14, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 7) {
                            if let date = record.date { Text(date, format: .dateTime.hour().minute()) }
                            Text(record.chapterTitle).lineLimit(1)
                            if let status { Text(status).fixedSize().help(status == "已归档" ? "不自动带入后续问题。" : "仍可参与当前范围的对话上下文。") }
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(ReadingQuietButtonStyle()).disabled(open != nil && !openEnabled).help(open == nil ? "展开或收起完整记录" : "在编辑器中打开这篇笔记")
                actions
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "minus" : "plus").font(.system(size: 12, weight: .medium)).frame(width: 36, height: 44) }
                    .buttonStyle(ReadingQuietButtonStyle()).help(expanded ? "收起这条记录" : "展开这条记录")
                    .accessibilityLabel((expanded ? "收起：" : "展开：") + record.title).accessibilityIdentifier("reader-record-toggle-" + record.id)
            }
            if expanded { content(); Button("收起这条记录") { expanded = false }.font(.system(size: 12)).buttonStyle(ReadingQuietButtonStyle()).frame(minHeight: 32) }
        }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.paper.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ReaderNoteRecordPreview: View {
    @EnvironmentObject private var store: AppStore
    let documentID: String
    @State private var text = ""
    var body: some View {
        Text(text).font(.system(size: 13, design: .serif)).foregroundStyle(.secondary).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .task(id: documentID + "|" + String(store.projectRevision)) {
                guard let book = store.book, let document = book.activeDocuments.first(where: { $0.id == documentID }) else { return }
                let owner = WorkspacePickerOwner(store: store)
                if let body = try? await store.repository.readDocument(bookID: book.id, document: document) {
                    let source = String(body.prefix(1800))
                    let preview = await Task.detached(priority: .utility) { PositionNotePreview.make(source, project: book) }.value
                    guard !Task.isCancelled, owner.matches(store) else { return }; text = preview + (body.count > 1800 ? "\n…（完整内容保留在笔记中）" : "")
                }
            }
    }
}
