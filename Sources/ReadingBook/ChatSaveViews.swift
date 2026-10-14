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
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if store.book?.chats.isEmpty != false {
                            EmptyState(title: "顺着一个问题，读得更深", detail: "选择文字保存摘录，或勾选多条回答合并。公式可选择 Markdown 源文。", icon: "bubble.left.and.bubble.right").frame(minHeight: 200)
                        }
                        ForEach(store.book?.chats ?? []) { message in answerCard(message).id(message.id) }
                    }.padding(.horizontal, 18).padding(.vertical, 16).frame(maxWidth: 900).frame(maxWidth: .infinity)
                }.onChange(of: store.book?.chats.count) { _, _ in
                    if let last = store.book?.chats.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("从这本书出发，问一个问题…", text: $question, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain).onSubmit { send() }
                Button { send() } label: { Image(systemName: "arrow.up").font(.headline).frame(width: 26, height: 26) }
                    .buttonStyle(.borderedProminent).disabled(store.isBusy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("发送问题").accessibilityLabel("发送问题")
            }.padding(12).readingGlass().padding(.horizontal, 18).padding(.bottom, 12)
        }
        .onChange(of: store.bookID) { _, _ in selectedAnswers.removeAll(); renderedSelections.removeAll(); saveRequest = nil }
        .sheet(item: $saveRequest, onDismiss: {
            if openTrashAfterSheet { openTrashAfterSheet = false; store.showingTrash = true }
        }) { request in
            AnswerSaveSheet(bookID: request.bookID, sourceAnswer: request.sourceAnswer, parts: request.parts,
                            showTrash: { openTrashAfterSheet = true; saveRequest = nil })
                .environmentObject(store).frame(minWidth: 520, idealWidth: 680, minHeight: 440, idealHeight: 600)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Label("已选 \(selectedAnswers.count) 条", systemImage: "checkmark.circle.fill").font(.caption.weight(.medium))
            Spacer()
            Button("清空") { selectedAnswers.removeAll() }.buttonStyle(.borderless)
            Button("合并预览…") {
                guard let book = store.book else { return }
                let parts = book.chats.filter { $0.role == "assistant" && selectedAnswers.contains($0.id) }.map { SavedAnswerPart(answer: $0) }
                saveRequest = AnswerSaveRequest(bookID: book.id, sourceAnswer: nil, parts: parts)
            }.buttonStyle(.borderedProminent).disabled(store.isBusy)
        }.controlSize(.small).padding(.horizontal, 18).padding(.vertical, 6)
            .background(Palette.paper).overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private func answerCard(_ message: ChatMessage) -> some View {
        let assistant = message.role == "assistant"
        let bookID = store.bookID ?? ""
        let prepared = ChatMarkdownBody.prepare(message.content, bookID: bookID)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(assistant ? "一起理解" : "你的问题", systemImage: assistant ? "sparkles" : "person.crop.circle")
                    .font(.caption.weight(.semibold)).foregroundStyle(assistant ? Palette.accent : .secondary)
                Spacer()
                if assistant {
                    Toggle("合并", isOn: Binding(get: { selectedAnswers.contains(message.id) }, set: { selected in
                        if selected { selectedAnswers.insert(message.id) } else { selectedAnswers.remove(message.id) }
                    })).toggleStyle(.checkbox).font(.caption).help("将这条回答加入合并选择")
                    Menu("保存") {
                        Button("保存完整回答…") { request(parts: [SavedAnswerPart(answer: message)]) }
                        Button("选择 Markdown 片段…") {
                            saveRequest = AnswerSaveRequest(bookID: bookID, sourceAnswer: message, parts: [])
                        }
                    }.font(.caption).menuStyle(.borderlessButton).fixedSize().disabled(store.isBusy)
                }
            }.controlSize(.small)
            ChatMarkdownBody(markdown: prepared, onSelectionChange: assistant ? { selection in
                guard store.bookID == bookID,
                      store.book?.chats.first(where: { $0.id == message.id })?.content == message.content else { return }
                if let selection, selection.sourceMarkdown == prepared { renderedSelections[message.id] = selection }
                else { renderedSelections.removeValue(forKey: message.id) }
            } : nil)
            if assistant, let selection = renderedSelections[message.id], selection.sourceMarkdown == prepared {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        selectionSummary(selection)
                        Spacer(minLength: 0)
                        selectionActions(message, bookID: bookID, selection: selection)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        selectionSummary(selection)
                        selectionActions(message, bookID: bookID, selection: selection)
                    }
                }.padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            if assistant, !message.evidence.isEmpty {
                DisclosureGroup {
                    EvidenceList(evidence: message.evidence).padding(.top, 5)
                } label: {
                    Text("原文依据 · \(message.evidence.count) 处").font(.caption).foregroundStyle(.secondary)
                }.tint(Palette.accent)
            }
        }.padding(16).background(assistant ? Palette.surface : Palette.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line.opacity(0.65), lineWidth: 0.65))
    }

    private func selectionSummary(_ selection: RenderedMarkdownSelection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("语义摘录 · \(selection.text.count) 字").font(.caption.weight(.medium))
            if selection.containsMath { Text("含公式，建议选源文").font(.caption).foregroundStyle(Palette.copper) }
        }.help("渲染区只保存语义文本，不包含精确 Markdown / TeX。需要保留公式时请选择源文片段。")
    }

    private func selectionActions(_ message: ChatMessage, bookID: String, selection: RenderedMarkdownSelection) -> some View {
        HStack(spacing: 10) {
            Button("选源文") { saveRequest = AnswerSaveRequest(bookID: bookID, sourceAnswer: message, parts: []) }
                .buttonStyle(.borderless).help("从只读 Markdown 中选择连续原文，精确保留公式")
            Button("保存选段…") {
                request(parts: [SavedAnswerPart(messageID: message.id, sourceContent: message.content,
                                               text: selection.text, kind: .renderedText)])
            }
        }.font(.caption).controlSize(.small).fixedSize().disabled(store.isBusy)
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
            HStack(spacing: 10) {
                Text(sheetTitle).font(.headline)
                Spacer()
                if sourceAnswer != nil, composition != nil {
                    Button("重选源文") { self.composition = nil; selectedSource = ""; localError = nil }
                        .help("返回只读 Markdown，重新选择连续片段").disabled(saving)
                }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
            }.controlSize(.small).padding(.horizontal, 16).padding(.vertical, 12)
            Divider().opacity(0.5)
            if let composition { preview(composition) }
            else if let answer = sourceAnswer { sourceSelector(answer) }
            else { Spacer(); if localError == nil { Text("正在准备预览…").foregroundStyle(.secondary).padding(16) }; Spacer() }
            if let localError { Text(localError).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 16).padding(.vertical, 8) }
        }
        .task { if sourceAnswer == nil { prepare(parts) } }
        .onChange(of: store.bookID) { _, id in if id != bookID { localError = "书籍已切换，请关闭并重新选择。"; composition = nil } }
    }

    private var sheetTitle: String {
        guard let composition else { return sourceAnswer != nil ? "1  选择 Markdown 源文" : "回答摘记预览" }
        if sourceAnswer != nil { return "2  预览并保存原文片段" }
        return composition.parts.contains(where: { $0.kind == .renderedText }) ? "语义摘录预览" : "回答摘记预览"
    }

    private func sourceSelector(_ answer: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("只读连续原文 · 公式请选全分隔符，不在此编辑原答。").font(.caption).foregroundStyle(.secondary)
            MarkdownSourceSelector(source: answer.content) { source, text in
                selectedSource = source == answer.content ? text : ""
            }.frame(maxWidth: .infinity, maxHeight: .infinity).overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.10)))
            HStack(spacing: 10) {
                Text(selectedSource.isEmpty ? "拖动选择需要保留的片段" : "已选 \(selectedSource.count) 字 · 精确保留源文").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("预览片段") {
                    prepare([SavedAnswerPart(messageID: answer.id, sourceContent: answer.content, text: selectedSource, kind: .markdownExcerpt)])
                }.buttonStyle(.borderedProminent).disabled(selectedSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.bookID != bookID)
            }.controlSize(.small)
        }.padding(16)
    }

    private func preview(_ composition: SavedAnswerComposition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) { Text("标题").font(.subheadline).foregroundStyle(.secondary); TextField("文档标题", text: $title).textFieldStyle(.roundedBorder) }.controlSize(.small)
            HStack(spacing: 6) {
                Text("\(composition.messageIDs.count) 条回答 · 会话顺序 · 问题与引用保留")
                if composition.parts.contains(where: { $0.kind == .renderedText }) { Text("· 公式以源文为准").foregroundStyle(Palette.copper) }
            }.font(.caption).foregroundStyle(.secondary)
            ScrollView { ChatMarkdownBody(markdown: previewMarkdown(composition)).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 9))
            HStack(spacing: 10) {
                Text("Markdown + 导图节点").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if store.book?.documents.first(where: { $0.id == composition.documentID })?.trashedAt != nil {
                    Button("回收站恢复") { showTrash() }.help("恢复已保存的原摘记，不另建副本")
                }
                Button(saving ? "保存中…" : "确认保存") {
                    saving = true
                    Task {
                        let saved = await store.saveAnswerComposition(composition, title: title)
                        saving = false
                        if saved { dismiss() } else { localError = store.errorMessage ?? "未能保存，请重新检查选择。" }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || store.isBusy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.bookID != bookID)
            }.controlSize(.small)
        }.padding(16)
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
        text.textContainerInset = NSSize(width: 10, height: 10); text.isVerticallyResizable = true; text.isHorizontallyResizable = false
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
