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
    private var count: Int { (store.queryScope == .notes ? 0 : store.queryAttachedDocuments.count) + store.queryReferencedAnswerIDs.count + (store.queryInteractionMode == .functional ? store.queryAuthorizedNodes.count : 0) }
    var body: some View {
        Button { presented.toggle() } label: {
            Label(count == 0 ? "附加内容" : "附加 \(count) 项", systemImage: "paperclip")
                .font(.system(size: 13)).frame(minHeight: 44)
        }.buttonStyle(ReadingQuietButtonStyle()).fixedSize().disabled(store.isQueryBusy)
            .popover(isPresented: $presented) { attachmentPicker.frame(width: 430, height: 560) }
            .help("附加本次可读取的笔记、历史回答与可整理的节点")
    }
    private var attachmentPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.queryInteractionMode == .reading ? "这次一起读" : "这次一起读与整理").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { presented = false } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).accessibilityLabel("关闭附加内容")
            }.padding(.horizontal, 16)
            TextField("搜索笔记、历史回答或节点", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if store.queryScope != .notes {
                        HStack { Text("笔记正文").font(.subheadline.weight(.semibold)); Spacer(); ReaderFolderControl(kind: .notes, selection: $noteFolderID) }
                        if let current = store.selectedDocumentID, store.book?.activeDocuments.contains(where: { $0.id == current }) == true {
                            Button("附加正在编辑的笔记") { store.setQueryAttachedDocument(current, included: true) }.buttonStyle(.borderless)
                        }
                        ForEach(documents) { document in
                            Toggle(document.title, isOn: Binding(get: { store.queryAttachedDocumentIDs.contains(document.id) },
                                set: { store.setQueryAttachedDocument(document.id, included: $0) }))
                                .toggleStyle(.checkbox).frame(minHeight: 36, alignment: .leading)
                        }
                        if documents.isEmpty { Text("没有匹配的已保存笔记").font(.caption).foregroundStyle(.secondary) }
                        Divider().padding(.vertical, 8)
                    }
                    HStack { Text("历史回答").font(.subheadline.weight(.semibold)); Spacer(); ReaderFolderControl(kind: .history, selection: $historyFolderID) }
                    ForEach(references) { reference in
                        Toggle(reference.title, isOn: Binding(get: { store.queryReferencedAnswerIDs.contains(reference.id) },
                            set: { store.setReferencedAnswer(reference.id, included: $0) }))
                            .toggleStyle(.checkbox).font(.system(size: 14)).frame(minHeight: 44, alignment: .leading)
                            .help("只引用这条完整回答供本次提问使用；不恢复整份历史，也不扩大原文阅读范围。")
                    }
                    if references.isEmpty { Text("没有匹配的历史回答").font(.caption).foregroundStyle(.secondary) }
                    Divider().padding(.vertical, 8)
                    if store.queryInteractionMode == .functional {
                        Text("画布节点").font(.subheadline.weight(.semibold))
                        Button("附加画布中已选节点") { store.addSelectedQueryNodes() }.buttonStyle(.borderless)
                        ForEach(nodes) { node in
                            Toggle(store.queryNodeTitle(node), isOn: Binding(get: { store.queryAuthorizedNodeIDs.contains(node.id) },
                                set: { store.setQueryAuthorizedNode(node.id, included: $0) }))
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
                Button("清空附加") { store.clearQueryTaskAttachments() }.buttonStyle(.borderless)
                Spacer()
                Button("完成") { presented = false }.buttonStyle(.borderedProminent).controlSize(.large)
            }.padding(14)
        }.onExitCommand { presented = false }
    }
    private var documents: [DocumentRecord] {
        Array((store.book?.activeDocuments ?? []).filter { document in
            let folder = store.readerCollections.assignments["note:" + document.id]
            let matches = noteFolderID.map { $0 == "@unfiled" ? folder == nil : folder == $0 } ?? true
            return matches && (search.isEmpty || document.title.localizedCaseInsensitiveContains(search))
        }.prefix(80))
    }
    private var references: [ReadingAnswerReference] {
        guard let book = store.book else { return [] }
        return Array(ReaderCollectionRuntime.references(in: book).reversed().filter { reference in
            let folder = store.readerCollections.assignments[reference.id]
            let matches = historyFolderID.map { $0 == "@unfiled" ? folder == nil : folder == $0 } ?? true
            return matches && (search.isEmpty || reference.title.localizedCaseInsensitiveContains(search) || reference.content.localizedCaseInsensitiveContains(search))
        }.prefix(80))
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
            HStack {
                Label("对话摘要", systemImage: "brain.head.profile").font(.system(size: 20, weight: .semibold))
                Spacer()
                ReaderInformationButton(title: "摘要与历史有什么不同？", text: "历史保存完整问答；摘要只提炼长对话中的要求、结论和待讨论问题，帮助AI接着聊。清除摘要不会删除任何原始问答或笔记。旧范围的摘要可以查阅和分类，只有经过当前范围与原消息核对的摘要才会自动使用。")
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).keyboardShortcut(.cancelAction).help("关闭对话摘要")
            }.padding(.horizontal, 20).padding(.vertical, 12)
            HStack {
                ReaderFolderControl(kind: .summaries, selection: $folderID)
                Spacer()
                Text("\(records.count) 份摘要").font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.bottom, 8)
            Divider().opacity(0.4)
            if records.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "text.badge.star").font(.system(size: 30)).foregroundStyle(Palette.accent)
                    Text("还没有对话摘要").font(.system(size: 19, weight: .semibold))
                    Text("聊得长时，会自动归纳要点，方便接着讨论。\n完整问答始终保留在历史对话中。")
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
                                    Text(current.memory?.id == memory.id ? "当前范围的摘要" : "已保存的摘要").font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    ReaderMoveToFolderButton(kind: .summaries, recordIDs: ["memory:" + memory.id])
                                }
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
                if current.memory != nil {
                    Button("清除当前摘要…") { clearOwner = WorkspacePickerOwner(store: store); clearing = true }
                        .buttonStyle(ReadingToolbarButtonStyle()).disabled(store.isQueryBusy || store.isManagingQueryMemory || store.storageState.working)
                        .help("只清除当前阅读范围的自动摘要，原问答、历史文件夹和笔记保留。")
                }
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
