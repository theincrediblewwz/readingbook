import SwiftUI
import AppKit
import ReadingCore

private struct AnswerSaveRequest: Identifiable {
    let id = UUID()
    let bookID: String
    let sourceAnswer: ChatMessage?
    let parts: [SavedAnswerPart]
}

/// Explicit collection only: rendering or selecting an answer never creates a document.
struct EnhancedBookChatView: View {
    @EnvironmentObject var store: AppStore
    @State private var question = ""
    @State private var selectedAnswers = Set<String>()
    @State private var renderedSelections: [String: RenderedMarkdownSelection] = [:]
    @State private var saveRequest: AnswerSaveRequest?
    @State private var openTrashAfterSheet = false

    var body: some View {
        VStack(spacing: 0) {
            if !selectedAnswers.isEmpty { selectionBar }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if store.book?.chats.isEmpty != false {
                            EmptyState(title: "顺着一个问题，读得更深", detail: "直接选择回答文字保存摘录，或勾选多条回答合成自己的文档。公式可从 Markdown 源文选择。", icon: "bubble.left.and.bubble.right").frame(minHeight: 260)
                        }
                        ForEach(store.book?.chats ?? []) { message in answerCard(message).id(message.id) }
                    }.padding(26).frame(maxWidth: 900).frame(maxWidth: .infinity)
                }.onChange(of: store.book?.chats.count) { _, _ in
                    if let last = store.book?.chats.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack(alignment: .bottom, spacing: 14) {
                TextField("从这本书出发，问一个问题…", text: $question, axis: .vertical)
                    .lineLimit(2...6).textFieldStyle(.plain).onSubmit { send() }
                Button { send() } label: { Image(systemName: "arrow.up").font(.headline).frame(width: 30, height: 30) }
                    .buttonStyle(.borderedProminent).disabled(store.isBusy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(18).readingGlass().padding(.horizontal, 26).padding(.bottom, 20)
        }
        .onChange(of: store.bookID) { _, _ in selectedAnswers.removeAll(); renderedSelections.removeAll(); saveRequest = nil }
        .sheet(item: $saveRequest, onDismiss: {
            if openTrashAfterSheet { openTrashAfterSheet = false; store.showingTrash = true }
        }) { request in
            AnswerSaveSheet(bookID: request.bookID, sourceAnswer: request.sourceAnswer, parts: request.parts,
                            showTrash: { openTrashAfterSheet = true; saveRequest = nil })
                .environmentObject(store).frame(minWidth: 620, idealWidth: 780, minHeight: 560, idealHeight: 720)
        }
    }

    private var selectionBar: some View {
        HStack {
            Label("已选 \(selectedAnswers.count) 条 AI 回答", systemImage: "checkmark.circle.fill").font(.subheadline)
            Spacer()
            Button("清空") { selectedAnswers.removeAll() }
            Button("合并预览…") {
                guard let book = store.book else { return }
                let parts = book.chats.filter { $0.role == "assistant" && selectedAnswers.contains($0.id) }.map { SavedAnswerPart(answer: $0) }
                saveRequest = AnswerSaveRequest(bookID: book.id, sourceAnswer: nil, parts: parts)
            }.buttonStyle(.borderedProminent).disabled(store.isBusy)
        }.padding(.horizontal, 26).padding(.vertical, 11).background(Palette.accent.opacity(0.07))
    }

    private func answerCard(_ message: ChatMessage) -> some View {
        let assistant = message.role == "assistant"
        let bookID = store.bookID ?? ""
        let prepared = ChatMarkdownBody.prepare(message.content, bookID: bookID)
        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label(assistant ? "一起理解" : "你的问题", systemImage: assistant ? "sparkles" : "person.crop.circle")
                    .font(.caption.weight(.semibold)).foregroundStyle(assistant ? Palette.accent : .secondary)
                Spacer()
                if assistant {
                    Toggle("合并", isOn: Binding(get: { selectedAnswers.contains(message.id) }, set: { selected in
                        if selected { selectedAnswers.insert(message.id) } else { selectedAnswers.remove(message.id) }
                    })).toggleStyle(.checkbox).font(.caption)
                    Menu("保存…") {
                        Button("保存完整回答…") { request(parts: [SavedAnswerPart(answer: message)]) }
                        Button("选择 Markdown 片段…") {
                            saveRequest = AnswerSaveRequest(bookID: bookID, sourceAnswer: message, parts: [])
                        }
                    }.font(.caption).disabled(store.isBusy)
                }
            }
            ChatMarkdownBody(markdown: prepared, onSelectionChange: assistant ? { selection in
                guard store.bookID == bookID,
                      store.book?.chats.first(where: { $0.id == message.id })?.content == message.content else { return }
                if let selection, selection.sourceMarkdown == prepared { renderedSelections[message.id] = selection }
                else { renderedSelections.removeValue(forKey: message.id) }
            } : nil)
            if assistant, let selection = renderedSelections[message.id], selection.sourceMarkdown == prepared {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已选 \(selection.text.count) 字 · 渲染区语义文本").font(.caption.weight(.medium))
                        Text(selection.containsMath ? "包含公式；需要精确保留 TeX 时请选择 Markdown 原文。" : "排版标记不在摘录中；需要源文时请选择 Markdown 片段。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("保存选段…") {
                        request(parts: [SavedAnswerPart(messageID: message.id, sourceContent: message.content,
                                                       text: selection.text, kind: .renderedText)])
                    }.font(.caption).disabled(store.isBusy)
                }.padding(12).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            }
            if assistant { EvidenceList(evidence: message.evidence) }
        }.padding(22).background(assistant ? Color(nsColor: .textBackgroundColor) : Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func request(parts: [SavedAnswerPart]) {
        guard let bookID = store.bookID else { return }
        saveRequest = AnswerSaveRequest(bookID: bookID, sourceAnswer: nil, parts: parts)
    }
    private func send() {
        guard !store.isBusy, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let input = question; store.ask(input)
        if store.isBusy { question = "" }
    }
}

private struct AnswerSaveSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let bookID: String
    let sourceAnswer: ChatMessage?
    let parts: [SavedAnswerPart]
    let showTrash: () -> Void
    @State private var selectedSource = ""
    @State private var composition: SavedAnswerComposition?
    @State private var title = ""
    @State private var localError: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(composition == nil && sourceAnswer != nil ? "选择 Markdown 原文片段" : "保存回答摘记").font(.title2.weight(.medium))
                    Text("由你确认后保存为真实 Markdown，并创建一个导图节点。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
            }.padding(22)
            Divider()
            if let composition { preview(composition) }
            else if let answer = sourceAnswer { sourceSelector(answer) }
            else { Spacer(); Text(localError ?? "正在准备预览…").foregroundStyle(.secondary).padding(24); Spacer() }
            if let localError { Text(localError).font(.caption).foregroundStyle(.red).padding(.horizontal, 22).padding(.vertical, 10) }
        }
        .task { if sourceAnswer == nil { prepare(parts) } }
        .onChange(of: store.bookID) { _, id in if id != bookID { localError = "书籍已切换，请关闭并重新选择。"; composition = nil } }
    }

    private func sourceSelector(_ answer: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在下面只读源文中拖动选择。片段逐字保留，不能在此编辑原答；公式请包含完整分隔符。").font(.callout).foregroundStyle(.secondary)
            MarkdownSourceSelector(source: answer.content) { source, text in
                selectedSource = source == answer.content ? text : ""
            }.frame(maxWidth: .infinity, maxHeight: .infinity).overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.10)))
            HStack {
                Text(selectedSource.isEmpty ? "尚未选择文字" : "已选 \(selectedSource.count) 字").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("预览所选片段") {
                    prepare([SavedAnswerPart(messageID: answer.id, sourceContent: answer.content, text: selectedSource, kind: .markdownExcerpt)])
                }.buttonStyle(.borderedProminent).disabled(selectedSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.bookID != bookID)
            }
        }.padding(22)
    }

    private func preview(_ composition: SavedAnswerComposition) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("标题").foregroundStyle(.secondary); TextField("文档标题", text: $title).textFieldStyle(.roundedBorder) }
            Text("\(composition.messageIDs.count) 条回答，按会话顺序排列；保留对应问题、消息 ID 与原答引用。正文在保存后可独立编辑。").font(.caption).foregroundStyle(.secondary)
            ScrollView { ChatMarkdownBody(markdown: previewMarkdown(composition)).padding(18).frame(maxWidth: .infinity, alignment: .leading) }
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 9))
            HStack {
                if sourceAnswer != nil { Button("重新选择片段") { self.composition = nil; selectedSource = ""; localError = nil } }
                Spacer()
                if store.book?.documents.first(where: { $0.id == composition.documentID })?.trashedAt != nil {
                    Button("前往回收站恢复") { showTrash() }
                }
                Button(saving ? "正在保存…" : "确认保存为文档节点") {
                    saving = true
                    Task {
                        let saved = await store.saveAnswerComposition(composition, title: title)
                        saving = false
                        if saved { dismiss() } else { localError = store.errorMessage ?? "未能保存，请重新检查选择。" }
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || store.isBusy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.bookID != bookID)
            }
        }.padding(22)
    }

    private func prepare(_ parts: [SavedAnswerPart]) {
        guard let book = store.book, book.id == bookID else { localError = "书籍已切换，请重新选择。"; return }
        do {
            let prepared = try SavedAnswerComposition.build(project: book, parts: parts)
            composition = prepared; title = prepared.suggestedTitle; localError = nil
        } catch { localError = error.localizedDescription }
    }

    private func previewMarkdown(_ composition: SavedAnswerComposition) -> String {
        let heading = title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "#", with: "\\#")
        guard let newline = composition.markdown.firstIndex(of: "\n") else { return composition.markdown }
        return "# \(heading)" + composition.markdown[newline...]
    }
}

private struct ChatMarkdownBody: View {
    @EnvironmentObject var store: AppStore
    var markdown: String
    var onSelectionChange: ((RenderedMarkdownSelection?) -> Void)? = nil
    var body: some View {
        RichMarkdownView(markdown: markdown,
                         baseDirectory: store.sourceFileURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs", isDirectory: true),
                         onSelectionChange: onSelectionChange)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "readingbook" { Task { await store.openInternalURL(url) }; return .handled }
                return ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
            })
    }
    static func prepare(_ markdown: String, bookID: String) -> String {
        var text = markdown
        for kind in ["unit", "doc"] {
            if let regex = try? NSRegularExpression(pattern: "\\[\(kind):([A-Za-z0-9._-]+)\\]") {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                    withTemplate: "[\(kind == "unit" ? "原文" : "文档") $1](readingbook://book/\(bookID)/\(kind == "unit" ? "unit" : "document")/$1)")
            }
        }
        return text
    }
}

/// Read-only AppKit selection preserves exact UTF-16 source ranges, including TeX.
private struct MarkdownSourceSelector: NSViewRepresentable {
    let source: String
    let onSelection: (String, String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(source: source, onSelection: onSelection) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)); text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular); text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 14, height: 14); text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.string = source; text.delegate = context.coordinator; scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.source = source; context.coordinator.onSelection = onSelection
        if let text = scroll.documentView as? NSTextView, text.string != source { text.string = source; text.setSelectedRange(NSRange(location: 0, length: 0)) }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var source: String
        var onSelection: (String, String) -> Void
        init(source: String, onSelection: @escaping (String, String) -> Void) { self.source = source; self.onSelection = onSelection }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let text = notification.object as? NSTextView, text.string == source else { return }
            let range = text.selectedRange(), value = source as NSString
            guard range.location != NSNotFound, range.location <= value.length, range.length <= value.length - range.location else { return }
            onSelection(source, range.length > 0 ? value.substring(with: range) : "")
        }
    }
}
