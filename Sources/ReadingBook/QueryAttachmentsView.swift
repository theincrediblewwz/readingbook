import SwiftUI
import ReadingCore

/// Attachments are an explicit capability choice, independent of the page
/// range. Selecting layout never shares a node's mounted document body.
struct QueryAttachmentsControl: View {
    @EnvironmentObject private var store: AppStore
    @State private var presented = false
    @State private var search = ""
    private var count: Int { (store.queryScope == .notes ? 0 : store.queryAttachedDocuments.count) + (store.queryInteractionMode == .functional ? store.queryAuthorizedNodes.count : 0) }
    var body: some View {
        Button { presented.toggle() } label: {
            Label(count == 0 ? "附加内容" : "附加 \(count) 项", systemImage: "paperclip")
                .font(.system(size: 13)).frame(minHeight: 44)
        }.buttonStyle(.plain).fixedSize().disabled(store.isQueryBusy)
            .popover(isPresented: $presented) { attachmentPicker.frame(width: 370, height: 470) }
            .help("附加本次可读取的笔记与可整理的节点")
    }
    private var attachmentPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.queryInteractionMode == .reading ? "这次一起读" : "这次一起读与整理").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { presented = false } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).accessibilityLabel("关闭附加内容")
            }.padding(.horizontal, 16)
            TextField("搜索笔记或节点", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if store.queryScope != .notes {
                        Text("笔记正文").font(.subheadline.weight(.semibold))
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
        Array((store.book?.activeDocuments ?? []).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }.prefix(80))
    }
    private var nodes: [CanvasNode] {
        Array(store.querySelectableNodes.filter { search.isEmpty || store.queryNodeTitle($0).localizedCaseInsensitiveContains(search) }.prefix(80))
    }
}

struct QueryMemoryInspector: View {
    @EnvironmentObject private var store: AppStore
    var onClose: () -> Void
    var onSource: (String) -> Void
    var body: some View {
        let memory = store.currentQueryMemory
        let sourceIDs = Set(((memory?.requirements ?? []) + (memory?.conclusions ?? []) + (memory?.unresolved ?? [])).flatMap(\.sources))
        let messages = Dictionary(store.currentQueryContextHistory.filter { sourceIDs.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("对话记忆", systemImage: "brain.head.profile").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).keyboardShortcut(.cancelAction)
            }.padding(18)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("摘要是可重建的阅读资料。原始问答保留，点出处回看原消息；摘要不会替代原文或变成新授权。")
                        .font(.callout).foregroundStyle(.secondary).lineSpacing(5)
                    if let memory {
                        memoryGroup("你的要求", items: memory.requirements, sources: messages)
                        memoryGroup("AI 的结论", items: memory.conclusions, sources: messages)
                        memoryGroup("待继续讨论", items: memory.unresolved, sources: messages)
                    } else {
                        Text("这个范围暂时没有有效摘要。长对话需要时才整理，不额外制造一份空记忆。")
                            .font(.system(size: 17, design: .serif)).foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                }.padding(22)
            }
            Divider()
            HStack {
                Toggle("使用长对话记忆", isOn: $store.queryMemoryEnabled).toggleStyle(.switch)
                Spacer()
                Button("清除派生摘要") { store.clearCurrentQueryMemory() }.disabled(store.isQueryBusy)
            }.padding(18)
        }.frame(width: 620, height: 560).onExitCommand(perform: onClose)
    }
    private func memoryGroup(_ title: String, items: [ConversationMemoryItem], sources: [String: ChatMessage]) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.system(size: 17, weight: .semibold))
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 9) {
                    Text(item.text).font(.system(size: 16, design: .serif)).lineSpacing(5).textSelection(.enabled)
                    ForEach(item.sources, id: \.self) { id in
                        if let message = sources[id] {
                            Button { onSource(id) } label: {
                                Label((message.role == "user" ? "你：" : "AI：") + String(message.content.prefix(80)), systemImage: "arrow.uturn.backward")
                                    .font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                        }
                    }
                }.padding(15).background(Palette.paper.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            }
            if items.isEmpty { Text("暂无").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
