import SwiftUI
import ReadingCore

/// Recovery actions keep the owning book and exact item IDs captured at preview
/// time. The repository rechecks the plan before committing any restoration.
@MainActor struct LibraryTrashView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var onClose: (() -> Void)? = nil
    @State private var query = ""
    @State private var filter: TrashFilter = .all
    @State private var restorePreview: ManualRestorePreview?
    @State private var localError: String?
    @State private var restoring = false
    @State private var checking = false

    private var removedRows: [BookProject] {
        guard filter == .all || filter == .books else { return [] }
        return store.removedBooks.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var archivedRows: [TrashDisplayItem] {
        store.archivedBooks.map { book in
            TrashDisplayItem(id: "book-" + book.id, title: book.title, category: .books,
                             detail: "整本书 · \(book.documents.count) 篇 Markdown", date: nil,
                             action: .book(book.id))
        }.filter { matches($0, bookTitle: $0.title) }
    }
    private var bookSections: [TrashBookSection] {
        store.books.compactMap { book in
            let documents = book.trashedDocuments.map { document in
                TrashDisplayItem(id: "document-" + document.id, title: document.title, category: .documents,
                                 detail: "正文与原来的导图节点保留", date: document.trashedAt,
                                 action: .document(book.id, document.id))
            }
            let manual = (book.manualTrash?.items ?? []).map { item in
                TrashDisplayItem(id: "manual-" + item.id, title: item.title, category: TrashFilter(item.kind),
                                 detail: item.kind == .view ? "原组件配置保留，书中知识仍在" : "恢复时会核对受影响的关联",
                                 date: item.deletedAt, action: .manual(book.id, item.id))
            }
            let rows = (documents + manual).filter { matches($0, bookTitle: book.title) }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return rows.isEmpty ? nil : TrashBookSection(id: book.id, title: book.title, rows: rows)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "trash").foregroundStyle(Palette.accent).font(.system(size: 22))
                Text("回收站").font(.system(size: 25, weight: .semibold))
                Spacer(minLength: 0)
                Button { close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(SettingsActionButtonStyle()).keyboardShortcut(.cancelAction).accessibilityLabel("关闭回收站").help("关闭回收站")
            }
            Text("按书保留回收内容及关联。恢复前会核对当前版本；另行回收的笔记需要单独恢复。")
                .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4)
            searchBar
            if let localError { errorBanner(localError) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !removedRows.isEmpty {
                        sectionHeading("已移出书库 · 文件保留", count: removedRows.count)
                        ForEach(removedRows) { book in
                            HStack(spacing: 12) {
                                Image(systemName: "books.vertical").foregroundStyle(Palette.accent)
                                Text(book.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                                Spacer(minLength: 8)
                                Button("重新加入") { Task { await store.restoreRemovedBook(book.id) } }.buttonStyle(SettingsActionButtonStyle()).disabled(store.isBusy || store.editorDirty)
                                    .help(store.editorDirty ? "请先保存正在编辑的 Markdown" : "将保留在本机的《\(book.title)》重新加入书库")
                            }.padding(14).readingGlass(radius: 16)
                        }
                    }
                    if !archivedRows.isEmpty {
                        sectionHeading("已回收的书籍", count: archivedRows.count)
                        ForEach(archivedRows) { item in trashRow(item) }
                    }
                    ForEach(bookSections) { section in
                        sectionHeading(section.title, count: section.rows.count).padding(.top, 10)
                        ForEach(section.rows) { item in trashRow(item) }
                    }
                    if archivedRows.isEmpty && bookSections.isEmpty && removedRows.isEmpty {
                        EmptyState(title: query.isEmpty && filter == .all ? "回收站是空的" : "没有匹配的内容",
                                   detail: query.isEmpty && filter == .all ? "回收的书籍、笔记、对象、连线和组件会保留在这里。" : "换一个标题、书名或类型试试。", icon: "trash")
                            .frame(minHeight: 190)
                    }
                }.padding(.bottom, 4)
            }
            HStack(spacing: 8) {
                if checking { ProgressView().controlSize(.small); Text("正在核对恢复关联…") }
                else { Label("保留恢复入口，不提供永久清空。", systemImage: "arrow.uturn.backward.circle") }
            }.font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(24).background(Palette.canvas).controlSize(.large)
        .task { await store.reloadTrash() }
        .sheet(item: $restorePreview) { preview in restorationSheet(preview) }
    }

    private var searchBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "magnifyingglass").readingSearchIcon()
            TextField("搜索标题、书名…", text: $query).readingSearchInput()
                .frame(minWidth: 60)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(SettingsActionButtonStyle()).accessibilityLabel("清空回收站搜索").help("清空回收站搜索")
            }
            Divider().frame(height: 20)
            Menu {
                Picker("类型", selection: $filter) {
                    ForEach(TrashFilter.allCases) { value in Label(value.title, systemImage: value.icon).tag(value) }
                }.pickerStyle(.inline).labelsHidden()
            } label: { ManagementMenuLabel(title: filter.title) }
                .menuStyle(.borderlessButton).menuIndicator(.visible).modifier(ManagementMenuSurface()).frame(width: 126)
                .accessibilityLabel("筛选回收内容类型").help("按书籍、笔记、对象、连线或组件筛选回收内容")
        }.padding(.leading, 14).padding(.trailing, 8).frame(minHeight: 48).readingGlass(radius: 14)
    }
    private func sectionHeading(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            Text("\(count)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(.horizontal, 4)
    }
    private func trashRow(_ item: TrashDisplayItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.category.icon).font(.system(size: 21)).foregroundStyle(Palette.accent)
                .frame(width: 42, height: 46).background(Palette.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                Text(item.category.title + " · " + item.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = item.date {
                    Text("回收于 " + date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { beginRestore(item.action) } label: { Label("恢复", systemImage: "arrow.uturn.backward") }
                .buttonStyle(SettingsActionButtonStyle()).disabled(store.isBusy || restoring || checking || store.editorDirty)
                .help(store.editorDirty ? "请先保存正在编辑的 Markdown" : "恢复\(item.title)")
        }.padding(14).frame(maxWidth: .infinity, minHeight: 88)
            .background(Palette.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line.opacity(0.75), lineWidth: 0.8))
    }
    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.copper)
            Text(text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { localError = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(SettingsActionButtonStyle()).accessibilityLabel("关闭恢复提示").help("收起这条恢复提示")
        }.padding(12).background(Palette.copper.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
    private func restorationSheet(_ preview: ManualRestorePreview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(preview.plan.conflicts.isEmpty ? "一起恢复关联内容" : "恢复需要先处理冲突")
                    .font(.system(size: 21, weight: .semibold))
                Spacer(minLength: 0)
                Button { restorePreview = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(SettingsActionButtonStyle()).keyboardShortcut(.cancelAction).disabled(restoring)
                    .accessibilityLabel("关闭恢复预览").help("关闭恢复预览，回收内容保留")
            }
            Text("以下项目属于必要的恢复关联。确认后一起恢复；另行回收的 Markdown 笔记不会自动恢复，需在回收站中单独恢复。")
                .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(preview.plan.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(item.title, systemImage: TrashFilter(item.kind).icon).font(.system(size: 15))
                            if item.patches.count > 1 {
                                Text("同时还原 \(item.patches.count - 1) 处关联")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(Array(preview.plan.conflicts.enumerated()), id: \.offset) { entry in
                        Label(entry.element, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13)).foregroundStyle(Palette.copper).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let localError { errorBanner(localError) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 12) {
                Button("取消") { restorePreview = nil }.buttonStyle(SettingsActionButtonStyle()).disabled(restoring).help("取消本次恢复，回收内容保留")
                Spacer(minLength: 0)
                Button(restoring ? "恢复中…" : "恢复这 \(preview.plan.itemIDs.count) 项") { restore(preview) }
                    .buttonStyle(SettingsActionButtonStyle(prominent: true)).disabled(restoring || store.isBusy || store.editorDirty || !preview.plan.conflicts.isEmpty)
                    .help("按预览恢复所列项目及必要关联；另行回收的笔记需要单独恢复")
            }
        }.padding(24).frame(width: 520, height: 440).background(Palette.canvas)
            .interactiveDismissDisabled(restoring)
    }
    private func matches(_ row: TrashDisplayItem, bookTitle: String) -> Bool {
        guard filter == .all || row.category == filter else { return false }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || (row.title + " " + bookTitle + " " + row.category.title).localizedCaseInsensitiveContains(trimmed)
    }
    private func beginRestore(_ action: TrashDisplayAction) {
        guard !store.isBusy, !restoring, !checking else { return }
        guard !store.editorDirty else { localError = "请先保存正在编辑的 Markdown，再恢复内容。"; return }
        localError = nil
        switch action {
        case .book(let id): Task { await store.restoreBook(id) }
        case .document(let bookID, let id): Task { await store.restoreDocument(bookID: bookID, documentID: id) }
        case .manual(let bookID, let id):
            guard let project = store.books.first(where: { $0.id == bookID }) else { localError = "原书已不在书库，请先恢复书籍。"; return }
            checking = true
            Task {
                defer { checking = false }
                do {
                    let corePlan = try await Task.detached(priority: .userInitiated) {
                        try ManualTrashRuntime.restorePlan(in: project, itemID: id)
                    }.value
                    guard !store.isBusy, !store.editorDirty else { localError = "当前有任务或未保存的笔记，请稍后重新核对恢复。"; return }
                    guard let current = store.books.first(where: { $0.id == bookID }),
                          current.manualTrash?.revision == project.manualTrash?.revision else {
                        localError = "回收内容已变化，请重新点击恢复以核对关联。"; return
                    }
                    let plan = try addingComponentConflicts(to: corePlan, in: current)
                    let preview = ManualRestorePreview(bookID: bookID, itemID: id, plan: plan)
                    if plan.itemIDs.count > 1 || plan.items.contains(where: { $0.patches.count > 1 }) || !plan.conflicts.isEmpty { restorePreview = preview }
                    else { restore(preview) }
                } catch { localError = error.localizedDescription }
            }
        }
    }
    private func addingComponentConflicts(to corePlan: ManualTrashRestorePlan, in project: BookProject) throws -> ManualTrashRestorePlan {
        var plan = corePlan
        let restoredViews = try plan.items.flatMap(\.patches).filter { $0.collection == .views }.map {
            try JSONDecoder().decode(ViewDefinition.self, from: $0.before)
        }
        let restoredIDs = Set(restoredViews.map(\.id))
        var reported = Set<String>()
        for restored in restoredViews {
            let equivalents = WorkspaceComponentRegistry.shared.removalIDs(for: restored, in: project.views + [restored])
                .subtracting(restoredIDs)
            let active = project.views.filter { equivalents.contains($0.id) }
            guard !active.isEmpty else { continue }
            let identity = active.map(\.id).sorted().joined(separator: ",")
            guard reported.insert(identity).inserted else { continue }
            let titles = active.prefix(3).map { "“\($0.title)”" }.joined(separator: "、")
            plan.conflicts.append("已有同类组件\(titles)。请先将当前入口移入回收站，再恢复原配置；两份配置均会保留。")
        }
        return plan
    }
    private func restore(_ preview: ManualRestorePreview) {
        guard !restoring, !store.isBusy, preview.plan.conflicts.isEmpty else { return }
        guard let current = store.books.first(where: { $0.id == preview.bookID }) else { localError = "原书已不在书库，请先恢复书籍。"; return }
        do {
            let checked = try addingComponentConflicts(to: preview.plan, in: current)
            guard checked.conflicts.isEmpty else {
                restorePreview = ManualRestorePreview(bookID: preview.bookID, itemID: preview.itemID, plan: checked)
                return
            }
        } catch { localError = error.localizedDescription; return }
        restoring = true; localError = nil
        Task {
            let saved = await store.restoreManualItems(bookID: preview.bookID, itemID: preview.itemID,
                                                       expectedItemIDs: preview.plan.itemIDs, onError: { localError = $0 })
            restoring = false
            if saved { restorePreview = nil }
        }
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }
}

private struct TrashBookSection: Identifiable { let id: String; let title: String; let rows: [TrashDisplayItem] }
private struct TrashDisplayItem: Identifiable {
    let id: String
    let title: String
    let category: TrashFilter
    let detail: String
    let date: Date?
    let action: TrashDisplayAction
}
private enum TrashDisplayAction { case book(String), document(String, String), manual(String, String) }
private struct ManualRestorePreview: Identifiable {
    let id = UUID()
    let bookID: String
    let itemID: String
    let plan: ManualTrashRestorePlan
}
private enum TrashFilter: String, CaseIterable, Identifiable {
    case all, books, documents, entity, event, relation, node, edge, view
    var id: String { rawValue }
    init(_ kind: ManualTrashKind) {
        switch kind {
        case .entity: self = .entity; case .event: self = .event; case .relation: self = .relation
        case .node: self = .node; case .edge: self = .edge; case .view: self = .view
        }
    }
    var title: String {
        switch self {
        case .all: return "全部类型"; case .books: return "书籍"; case .documents: return "Markdown"
        case .entity: return "卡片"; case .event: return "事件"; case .relation: return "知识关系"
        case .node: return "导图节点"; case .edge: return "导图连线"; case .view: return "组件"
        }
    }
    var icon: String {
        switch self {
        case .all: return "square.stack"; case .books: return "book.closed"; case .documents: return "doc.text"
        case .entity: return "rectangle.stack"; case .event: return "calendar"; case .relation: return "point.3.filled.connected.trianglepath.dotted"
        case .node: return "square.on.square"; case .edge: return "point.topleft.down.to.point.bottomright.curvepath"; case .view: return "puzzlepiece.extension"
        }
    }
}
