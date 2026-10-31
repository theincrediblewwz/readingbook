import SwiftUI
import ReadingCore

/// Attachments are an explicit capability choice, independent of the page
/// range. Selecting layout never shares a node's mounted document body.
struct QueryAttachmentsControl: View {
    @EnvironmentObject private var store: AppStore
    @State private var presented = false
    @State private var search = ""
    @State private var noteFolderID: String?
    @State private var historyFolderID: String?
    @State private var owner: WorkspacePickerOwner?
    @StateObject private var browser = ReaderRecordBrowserState()
    private var count: Int { (store.queryScope == .notes ? 0 : store.queryAttachedDocuments.count) + store.queryReferencedAnswerIDs.count + (store.queryInteractionMode == .functional ? store.queryAuthorizedNodes.count : 0) }
    var body: some View {
        Button { owner = WorkspacePickerOwner(store: store); presented.toggle() } label: {
            Label(count == 0 ? "附加内容" : "附加 \(count) 项", systemImage: "paperclip")
                .font(.system(size: 13)).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(ReadingQuietButtonStyle()).fixedSize().disabled(store.isQueryBusy)
            .popover(isPresented: $presented) { attachmentPicker.frame(width: 430, height: 560) }
            .help("附加本次可读取的笔记、历史回答与可整理的节点")
    }
    private var attachmentPicker: some View {
        let notes = documents, answers = references
        let noteByID = Dictionary(notes.map { ("note:" + $0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let answerByID = Dictionary(answers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.queryInteractionMode == .reading ? "这次一起读" : "这次一起读与整理").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { presented = false } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).accessibilityLabel("关闭附加内容")
            }.padding(.horizontal, 16)
            TextField("搜索笔记、历史回答或节点", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12)
            ReaderRecordGroupingBar(state: browser).padding(.horizontal, 16).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if store.queryScope != .notes {
                        HStack { Text("笔记正文").font(.subheadline.weight(.semibold)); Spacer(); ReaderFolderControl(kind: .notes, selection: $noteFolderID) }
                        if let current = store.selectedDocumentID, store.book?.activeDocuments.contains(where: { $0.id == current }) == true {
                            Button("附加正在编辑的笔记") { if owner?.matches(store) == true { store.setQueryAttachedDocument(current, included: true) } }.buttonStyle(ReadingQuietButtonStyle())
                        }
                        ReaderRecordSections(state: browser, ids: notes.map { "note:" + $0.id }, searching: !search.isEmpty) { record, expanded in
                            if let document = noteByID[record.id] {
                                ReaderRecordFoldCard(record: record, expanded: expanded,
                                    selection: Binding(get: { store.queryAttachedDocumentIDs.contains(document.id) }, set: { included in
                                        guard owner?.matches(store) == true else { return }; store.setQueryAttachedDocument(document.id, included: included)
                                    })) {
                                    ReaderNoteRecordPreview(documentID: document.id)
                                    Button("打开完整笔记") {
                                        guard owner?.matches(store) == true else { return }; presented = false
                                        Task { await store.openDocument(document) }
                                    }.buttonStyle(ReadingToolbarButtonStyle())
                                }
                            }
                        }
                        if documents.isEmpty { Text("没有匹配的已保存笔记").font(.caption).foregroundStyle(.secondary) }
                        Divider().padding(.vertical, 8)
                    }
                    HStack { Text("历史回答").font(.subheadline.weight(.semibold)); Spacer(); ReaderFolderControl(kind: .history, selection: $historyFolderID) }
                    ReaderRecordSections(state: browser, ids: answers.map(\.id), searching: !search.isEmpty) { record, expanded in
                        if let reference = answerByID[record.id] {
                            ReaderRecordFoldCard(record: record, expanded: expanded,
                                selection: Binding(get: { store.queryReferencedAnswerIDs.contains(reference.id) }, set: { included in
                                    guard owner?.matches(store) == true else { return }; store.setReferencedAnswer(reference.id, included: included)
                                })) {
                                ChatMarkdownBody(markdown: MarkdownReferenceLinks.render(reference.content, bookID: store.bookID ?? "", project: store.book), presentationActiveOverride: true)
                            }
                        }
                    }
                    if references.isEmpty { Text("没有匹配的历史回答").font(.caption).foregroundStyle(.secondary) }
                    Divider().padding(.vertical, 8)
                    if store.queryInteractionMode == .functional {
                        Text("画布节点").font(.subheadline.weight(.semibold))
                        Button("附加画布中已选节点") { if owner?.matches(store) == true { store.addSelectedQueryNodes() } }.buttonStyle(ReadingQuietButtonStyle())
                        ForEach(nodes) { node in
                            Toggle(store.queryNodeTitle(node), isOn: Binding(get: { store.queryAuthorizedNodeIDs.contains(node.id) },
                                    set: { if owner?.matches(store) == true { store.setQueryAuthorizedNode(node.id, included: $0) } }))
                                .toggleStyle(.checkbox).frame(minHeight: 36, alignment: .leading)
                        }
                        if nodes.isEmpty { Text("没有匹配的节点").font(.caption).foregroundStyle(.secondary) }
                        Text("挂载文档需单独勾选；修改已有内容仍先审阅差异。")
                            .font(.caption).foregroundStyle(.secondary).lineSpacing(4).padding(.top, 10)
                    }
                }.padding(18)
            }
            Divider()
            HStack {
                Button("清空附加") { if owner?.matches(store) == true { store.clearQueryTaskAttachments() } }.buttonStyle(ReadingQuietButtonStyle())
                Spacer()
                Button("完成") { presented = false }.buttonStyle(.borderedProminent).controlSize(.large)
            }.padding(14)
        }.onExitCommand { presented = false }
            .onChange(of: store.collectionOwnerKey) { _, _ in presented = false; owner = nil; search = ""; noteFolderID = nil; historyFolderID = nil }
    }
    private var documents: [DocumentRecord] {
        (store.book?.activeDocuments ?? []).filter { document in
            let folder = store.readerCollections.assignments["note:" + document.id]
            let matches = noteFolderID.map { $0 == "@unfiled" ? folder == nil : folder == $0 } ?? true
            return matches && (search.isEmpty || document.title.localizedCaseInsensitiveContains(search))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private var references: [ReadingAnswerReference] {
        guard let book = store.book else { return [] }
        return ReaderCollectionRuntime.references(in: book).reversed().filter { reference in
            let folder = store.readerCollections.assignments[reference.id]
            let matches = historyFolderID.map { $0 == "@unfiled" ? folder == nil : folder == $0 } ?? true
            return matches && (search.isEmpty || reference.title.localizedCaseInsensitiveContains(search) || reference.content.localizedCaseInsensitiveContains(search))
        }
    }
    private var nodes: [CanvasNode] {
        Array(store.querySelectableNodes.filter { search.isEmpty || store.queryNodeTitle($0).localizedCaseInsensitiveContains(search) }.prefix(80))
    }
}

struct QueryMemoryInspector: View {
    @EnvironmentObject private var store: AppStore
    var onClose: () -> Void
    var onSource: (String) -> Void
    @State private var prepared = QueryMemoryDisplay()
    @State private var preparedKey: QueryMemoryPreparationKey?
    @State private var catalog: [ConversationMemory] = []
    @State private var selectedID: String?
    @State private var folderID: String?
    @State private var clearing = false
    @State private var clearOwner: WorkspacePickerOwner?
    private var current: QueryMemoryDisplay { preparedKey == store.queryMemoryPreparationKey ? prepared : .init() }
    private var records: [ConversationMemory] {
        var values = catalog
        if let memory = current.memory, !values.contains(where: { $0.id == memory.id }) { values.insert(memory, at: 0) }
        return values.filter { memory in
            guard let folderID else { return true }
            let folder = store.readerCollections.assignments["memory:" + memory.id]
            return folderID == "@unfiled" ? folder == nil : folder == folderID
        }
    }
    private var selected: ConversationMemory? { records.first { $0.id == selectedID } ?? records.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("对话摘要", systemImage: "brain.head.profile").font(.system(size: 18, weight: .semibold))
                Text("\(records.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                ReaderFolderControl(kind: .summaries, selection: $folderID).frame(maxWidth: 170)
                Spacer(minLength: 4)
                if store.isManagingQueryMemory {
                    ProgressView().controlSize(.small)
                    Button("停止") { store.queryMemoryTask?.cancel() }.buttonStyle(ReadingToolbarButtonStyle()).help("停止本次整理；已有摘要、完整问答和笔记保留。")
                } else {
                    Button(current.memory == nil ? "立即整理" : summaryComplete ? "已整理" : "继续整理") { store.summarizeCurrentConversation() }
                        .buttonStyle(ReadingToolbarButtonStyle(selected: true)).disabled(summaryComplete || store.storageState.working || current.historyCount == 0)
                        .help("用当前模型整理本范围的已有问答，会消耗一次模型请求。长对话分批处理，不删除原消息。")
                }
                ReaderInformationButton(title: "摘要状态与使用说明", text: statusText + "\n\n历史保存完整问答；摘要只提炼要点，帮助AI接着聊。自动整理在后续提问且对话较长、预算足够时进行。手动整理也可处理短对话。清除摘要不删除问答或笔记；旧范围的摘要可查阅和分类，只有当前范围与原消息核对通过的摘要才会自动使用。")
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).keyboardShortcut(.cancelAction).help("关闭对话摘要")
            }.padding(.horizontal, 18).frame(height: 58)
            if store.isManagingQueryMemory || statusText.hasPrefix("整理未完成") || statusText.hasPrefix("已停止") {
                Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 20).padding(.bottom, 8)
            }
            Divider().opacity(0.4)
            if records.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "text.badge.star").font(.system(size: 30)).foregroundStyle(Palette.accent)
                    Text("还没有对话摘要").font(.system(size: 19, weight: .semibold))
                    Text("点上方“立即整理”，就能在这里看到要点和来源。\n自动整理只在后续提问且对话较长、预算足够时进行。")
                        .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(records) { memory in
                                Button { selectedID = memory.id } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(memory.unresolved.first?.text ?? memory.requirements.first?.text ?? memory.conclusions.first?.text ?? "对话摘要").font(.system(size: 14, weight: .medium)).lineLimit(2)
                                        Text(memory.scopeTitle ?? "较早的对话摘要").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                        Text(memory.updatedAt, format: .dateTime.month().day().hour().minute()).font(.system(size: 12)).foregroundStyle(.secondary)
                                    }.padding(12).frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
                                        .background(selected?.id == memory.id ? Palette.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(ReadingQuietButtonStyle()).help("查看这份摘要及其原始问答来源。")
                            }
                        }.padding(12)
                    }.frame(width: 210)
                    Divider().opacity(0.4)
                    ScrollView {
                        if let memory = selected {
                            VStack(alignment: .leading, spacing: 18) {
                                HStack {
                                    Text(memory.scopeTitle ?? (current.memory?.id == memory.id ? "当前范围的摘要" : "已保存的摘要")).font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    ReaderMoveToFolderButton(kind: .summaries, recordIDs: ["memory:" + memory.id])
                                }
                                Text("已整理前\(memory.cursor.index)条消息" + (memory.cursor.offset > 0 ? "和下一条的部分内容" : "") + " · " + memory.updatedAt.formatted(.dateTime.month().day().hour().minute()))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                memoryGroup("你的想法与要求", items: memory.requirements)
                                memoryGroup("讨论过的结论", items: memory.conclusions)
                                memoryGroup("还想继续聊", items: memory.unresolved)
                            }.padding(20)
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
            Divider().opacity(0.4)
            HStack {
                Toggle("自动整理长对话", isOn: $store.queryMemoryEnabled).toggleStyle(.switch)
                    .help("对话较长时，在同一请求预算内提炼要点供后续问题使用；关闭后仍保留原始问答与已有摘要。")
                Spacer()
                Button("清除当前摘要…") { clearOwner = WorkspacePickerOwner(store: store); clearing = true }
                    .buttonStyle(ReadingToolbarButtonStyle()).disabled(current.memory == nil || store.isQueryBusy || store.isManagingQueryMemory || store.storageState.working)
                    .help(current.memory == nil ? "当前阅读范围还没有摘要可清除；其他范围的摘要不受影响。" : "只清除当前阅读范围的摘要，原问答、历史文件夹和笔记保留。")
            }.padding(18)
        }.frame(width: 780, height: 600).background(Palette.canvas).onExitCommand(perform: onClose)
            .confirmationDialog("清除当前范围的对话摘要？", isPresented: $clearing, titleVisibility: .visible) {
                Button("清除摘要", role: .destructive) {
                    guard clearOwner?.matches(store) == true else { return }; store.clearCurrentQueryMemory()
                }
                Button("保留", role: .cancel) { }
            } message: { Text("原始问答和笔记都保留。开启自动整理后，聊得长时可重新生成。") }
            .task(id: store.queryMemoryPreparationKey) {
                let key = store.queryMemoryPreparationKey, book = store.book
                preparedKey = nil
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                async let saved = QueryMemoryFiles.shared.catalog(bookID: book?.id ?? "", messages: book?.chats ?? [], root: key.root)
                let result = await store.prepareQueryMemoryDisplay(), values = await saved
                guard !Task.isCancelled, store.queryMemoryPreparationKey == key else { return }
                prepared = result; catalog = values; preparedKey = key
            }
            .onChange(of: store.collectionOwnerKey) { _, _ in onClose() }
    }
    private var statusText: String {
        if store.isSummaryRequestRunning, let key = store.queryMemoryStatusKey, !key.hasSameScope(as: store.queryMemoryPreparationKey) {
            return store.summaryProgressState.value.title + "，完成后保存在原来的范围。"
        }
        if store.queryMemoryStatusKey == store.queryMemoryPreparationKey, !store.queryMemoryStatus.isEmpty { return store.queryMemoryStatus }
        guard preparedKey != nil else { return "正在核对当前阅读范围…" }
        if current.historyCount == 0 { return "当前范围没有可整理的问答；可切回对应的范围和讲解方式查看。" }
        if let memory = current.memory { return "当前范围有\(current.historyCount)条消息，已整理\(memory.cursor.index)条。摘要是要点，完整回答在历史对话中。" }
        return "当前范围有\(current.historyCount)条消息，尚未整理；可立即整理，不必等到长对话自动触发。"
    }
    private var summaryComplete: Bool { current.memory.map { $0.cursor.index >= current.historyCount && $0.cursor.offset == 0 } ?? false }
    private func memoryGroup(_ title: String, items: [ConversationMemoryItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "folder").foregroundStyle(Palette.accent); Text(title).font(.system(size: 15, weight: .semibold)); Spacer(); Text("\(items.count)").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.text).font(.system(size: 16, design: .serif)).lineSpacing(5).textSelection(.enabled)
                    ForEach(item.sources, id: \.self) { id in
                        if let message = store.book?.chats.first(where: { $0.id == id }) {
                            Button { onSource(id) } label: {
                                Label((message.role == "user" ? "你：" : "AI：") + sourcePreview(message.content), systemImage: "arrow.uturn.backward")
                                    .font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            }.buttonStyle(ReadingQuietButtonStyle()).foregroundStyle(Palette.accent).help("打开产生这条摘要的完整原始问答。")
                        }
                    }
                }.padding(14).background(Palette.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            }
            if items.isEmpty { Text("暂无").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func sourcePreview(_ markdown: String) -> String {
        let line = markdown.split(whereSeparator: \.isNewline).first.map(String.init) ?? markdown
        return String(line.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression).prefix(80))
    }

}
