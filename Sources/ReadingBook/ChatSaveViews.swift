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
    @State private var selectionMode = false
    @State private var selectedAnswers = Set<String>()
    @State private var renderedSelections: [String: RenderedMarkdownSelection] = [:]
    @State private var saveRequest: AnswerSaveRequest?
    @State private var openTrashAfterSheet = false

    var body: some View {
        VStack(spacing: 0) {
            if selectionMode { selectionBar }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if store.book?.chats.isEmpty != false {
                            EmptyState(title: "顺着一个问题，读得更深", detail: "在回答的保存菜单中选片段或合并多条。公式可选择 Markdown 源文。", icon: "bubble.left.and.bubble.right").frame(minHeight: 200)
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
        .onChange(of: store.bookID) { _, _ in selectionMode = false; selectedAnswers.removeAll(); renderedSelections.removeAll(); saveRequest = nil }
        .sheet(item: $saveRequest, onDismiss: {
            if openTrashAfterSheet { openTrashAfterSheet = false; store.showingTrash = true }
        }) { request in
            AnswerSaveSheet(bookID: request.bookID, sourceAnswer: request.sourceAnswer, parts: request.parts,
                            showTrash: { openTrashAfterSheet = true; saveRequest = nil },
                            onSaved: { selectionMode = false; selectedAnswers.removeAll() })
                .environmentObject(store).frame(minWidth: 520, idealWidth: 680, minHeight: 440, idealHeight: 600)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Label("已选 \(selectedAnswers.count) 条", systemImage: "checkmark.circle.fill").font(.caption.weight(.medium))
            Spacer()
            Button("取消多选") { selectionMode = false; selectedAnswers.removeAll() }.buttonStyle(.borderless)
            Button("合并保存…") {
                guard let book = store.book else { return }
                let parts = book.chats.filter { $0.role == "assistant" && selectedAnswers.contains($0.id) }.map { SavedAnswerPart(answer: $0) }
                saveRequest = AnswerSaveRequest(bookID: book.id, sourceAnswer: nil, parts: parts)
            }.buttonStyle(.borderedProminent).disabled(store.isBusy || selectedAnswers.isEmpty)
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
                    if selectionMode {
                        Toggle("选择", isOn: Binding(get: { selectedAnswers.contains(message.id) }, set: { selected in
                            if selected { selectedAnswers.insert(message.id) } else { selectedAnswers.remove(message.id) }
                        })).toggleStyle(.checkbox).font(.caption).help("将这条回答加入合并选择").disabled(store.isBusy)
                    }
                    Menu("保存") {
                        answerActions(message, bookID: bookID, prepared: prepared)
                    }.font(.caption).menuStyle(.borderlessButton).fixedSize().disabled(store.isBusy)
                        .help("保存完整回答、精确 Markdown 片段，或进入多选合并；也可右键回答")
                        .accessibilityLabel("保存回答")
                }
            }.controlSize(.small)
            ChatMarkdownBody(markdown: prepared, onSelectionChange: assistant ? { selection in
                guard store.bookID == bookID,
                      store.book?.chats.first(where: { $0.id == message.id })?.content == message.content else { return }
                if let selection, selection.sourceMarkdown == prepared {
                    if renderedSelections[message.id] != selection || renderedSelections.count != 1 { renderedSelections = [message.id: selection] }
                } else if renderedSelections[message.id] != nil { renderedSelections.removeValue(forKey: message.id) }
            } : nil, onSelectionSave: assistant && !store.isBusy ? { selection in
                guard store.bookID == bookID, selection.sourceMarkdown == prepared,
                      store.book?.chats.first(where: { $0.id == message.id })?.content == message.content else { return }
                saveRenderedSelection(message, bookID: bookID, selection: selection)
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
            .contextMenu {
                if assistant { answerActions(message, bookID: bookID, prepared: prepared) }
            }
    }

    @ViewBuilder private func answerActions(_ message: ChatMessage, bookID: String, prepared: String) -> some View {
        if let selection = renderedSelections[message.id], selection.sourceMarkdown == prepared {
            Button("保存选区为语义摘记…") { saveRenderedSelection(message, bookID: bookID, selection: selection) }.disabled(store.isBusy)
            Divider()
        }
        Button("保存完整回答…") { request(parts: [SavedAnswerPart(answer: message)], bookID: bookID) }.disabled(store.isBusy)
        Button("选择 Markdown 片段…") { requestSource(message, bookID: bookID) }.disabled(store.isBusy)
        Divider()
        Button(selectionMode ? "加入合并选择" : "多选合并…") {
            guard store.bookID == bookID else { return }
            selectedAnswers.insert(message.id); selectionMode = true
        }.disabled(store.isBusy)
    }

    private func selectionSummary(_ selection: RenderedMarkdownSelection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("语义摘录 · \(selection.text.count) 字").font(.caption.weight(.medium))
            if selection.containsMath { Text("含公式，建议选源文").font(.caption).foregroundStyle(Palette.copper) }
        }.help("渲染区只保存语义文本，不包含精确 Markdown / TeX。需要保留公式时请选择源文片段。")
    }

    private func selectionActions(_ message: ChatMessage, bookID: String, selection: RenderedMarkdownSelection) -> some View {
        HStack(spacing: 10) {
            Button("选源文") { requestSource(message, bookID: bookID) }
                .buttonStyle(.borderless).help("从只读 Markdown 中选择连续原文，精确保留公式")
            Button("保存选段…") {
                saveRenderedSelection(message, bookID: bookID, selection: selection)
            }.keyboardShortcut("s", modifiers: [.command, .shift]).help("保存语义摘录 · ⌘⇧S；公式建议选择源文")
        }.font(.caption).controlSize(.small).fixedSize().disabled(store.isBusy)
    }

    private func request(parts: [SavedAnswerPart], bookID expectedBookID: String? = nil) {
        guard !store.isBusy, let bookID = store.bookID, expectedBookID == nil || expectedBookID == bookID else { return }
        saveRequest = AnswerSaveRequest(bookID: bookID, sourceAnswer: nil, parts: parts)
    }
    private func requestSource(_ message: ChatMessage, bookID: String) {
        guard !store.isBusy, store.bookID == bookID,
              store.book?.chats.first(where: { $0.id == message.id })?.content == message.content else { return }
        saveRequest = AnswerSaveRequest(bookID: bookID, sourceAnswer: message, parts: [])
    }
    private func saveRenderedSelection(_ message: ChatMessage, bookID: String, selection: RenderedMarkdownSelection) {
        guard !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selection.sourceMarkdown == ChatMarkdownBody.prepare(message.content, bookID: bookID),
              store.bookID == bookID, store.book?.chats.first(where: { $0.id == message.id })?.content == message.content else { return }
        request(parts: [SavedAnswerPart(messageID: message.id, sourceContent: message.content,
                                      text: selection.text, kind: .renderedText)], bookID: bookID)
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
    let onSaved: () -> Void
    @State private var selectedSource = ""
    @State private var preparedSource = ""
    @State private var composition: SavedAnswerComposition?
    @State private var title = ""
    @State private var localError: String?
    @State private var saving = false
    @State private var previewExpanded = true
    @State private var initialized = false

    private var readyComposition: SavedAnswerComposition? {
        guard sourceAnswer == nil || preparedSource == selectedSource else { return nil }
        return composition
    }
    private var isSemanticExcerpt: Bool { parts.contains { $0.kind == .renderedText } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("保存摘记").font(.headline)
                Spacer()
                Text(sourceAnswer != nil ? "Markdown 原文片段" : isSemanticExcerpt ? "渲染区语义摘录" : "\(parts.count) 条回答")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("标题").font(.subheadline).foregroundStyle(.secondary)
                    TextField("文档标题", text: $title).textFieldStyle(.roundedBorder).disabled(saving)
                }.controlSize(.small)
                sourceNotice
                if let answer = sourceAnswer {
                    GeometryReader { geometry in sourceWorkspace(answer, height: geometry.size.height) }
                } else if let composition = readyComposition {
                    documentPreview(composition)
                } else {
                    VStack { Spacer(); Text(localError == nil ? "正在准备预览…" : "请检查下方提示，尚未保存。").font(.callout).foregroundStyle(.secondary); Spacer() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let localError {
                    ScrollView {
                        Text(localError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: localError.count > 100 ? 64 : 34)
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider().opacity(0.5)
            saveBar
        }
        .task { initialize() }
        .task(id: selectedSource) {
            guard let answer = sourceAnswer else { return }
            let selection = selectedSource
            if selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                composition = nil; preparedSource = selection; return
            }
            // Coalesce drag-selection notifications without moving the native
            // source view or enabling save for an earlier selection.
            do { try await Task.sleep(nanoseconds: 75_000_000) } catch { return }
            guard !Task.isCancelled, selectedSource == selection else { return }
            prepare([SavedAnswerPart(messageID: answer.id, sourceContent: answer.content, text: selection, kind: .markdownExcerpt)], source: selection)
        }
        .onChange(of: store.bookID) { _, id in if id != bookID { localError = "书籍已切换，请关闭并重新选择。"; composition = nil } }
        .interactiveDismissDisabled(saving)
    }

    @ViewBuilder private var sourceNotice: some View {
        if sourceAnswer != nil {
            Text("选择只读源文中的连续片段；公式请选全分隔符。即时预览保留对应问题与原答引用。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if isSemanticExcerpt {
            Text("语义文本不还原公式、图片或 Markdown 排版；需要精确保留时，请使用 Markdown 源文片段。")
                .font(.caption).foregroundStyle(Palette.copper).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("按会话顺序保留问题、消息 ID 与原答引用；确认后保存为 Markdown 与导图节点。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sourceWorkspace(_ answer: ChatMessage, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("原回答 · 只读 Markdown").font(.caption.weight(.medium))
                Spacer(minLength: 0)
                Text(selectedSource.isEmpty ? "拖动选择" : "已选 \(selectedSource.count) 字").font(.caption).foregroundStyle(.secondary)
            }
            MarkdownSourceSelector(source: answer.content) { source, text in
                guard !saving else { return }
                selectedSource = source == answer.content ? text : ""
            }.frame(minHeight: 60, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line)).allowsHitTesting(!saving)
            DisclosureGroup(isExpanded: $previewExpanded) {
                Group {
                    if let composition { documentPreview(composition) }
                    else {
                        Text(selectedSource.isEmpty ? "选择后即时显示完整摘记，包含对应问题和原答的证据/文档引用。" : "正在核对连续原文与来源…")
                            .font(.caption).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }.frame(height: max(40, min(220, (height - 40) * 0.40))).padding(.top, 5)
            } label: {
                Text(readyComposition == nil && !selectedSource.isEmpty ? "正在更新选区预览…" : "即时预览 · 问题与来源").font(.caption.weight(.medium))
            }.tint(Palette.accent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func documentPreview(_ composition: SavedAnswerComposition) -> some View {
        ScrollView {
            ChatMarkdownBody(markdown: ChatMarkdownBody.prepare(previewMarkdown(composition), bookID: bookID))
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Palette.paper, in: RoundedRectangle(cornerRadius: 9))
    }

    private var saveBar: some View {
        HStack(spacing: 10) {
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
            Spacer(minLength: 0)
            if let composition = readyComposition,
               store.book?.documents.first(where: { $0.id == composition.documentID })?.trashedAt != nil {
                Button("回收站恢复") { showTrash() }.help("恢复已保存的原摘记，不另建副本").disabled(saving)
            }
            Button(saving ? "保存中…" : "保存摘记") { save() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(readyComposition == nil || saving || store.isBusy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.bookID != bookID)
        }.controlSize(.small).padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func initialize() {
        guard !initialized else { return }; initialized = true
        if let answer = sourceAnswer, let book = store.book, book.id == bookID {
            let question = book.chats.prefix(while: { $0.id != answer.id }).last(where: { $0.role == "user" })?.content ?? "回答摘记"
            title = String(question.replacingOccurrences(of: "\n", with: " ").prefix(70))
        } else { prepare(parts, seedTitle: true) }
    }

    private func prepare(_ parts: [SavedAnswerPart], source: String = "", seedTitle: Bool = false) {
        guard let book = store.book, book.id == bookID else { localError = "书籍已切换，请重新选择。"; return }
        do {
            let prepared = try SavedAnswerComposition.build(project: book, parts: parts)
            composition = prepared; preparedSource = source; localError = nil
            if seedTitle { title = prepared.suggestedTitle }
        } catch { composition = nil; preparedSource = source; localError = error.localizedDescription }
    }

    private func save() {
        guard let composition = readyComposition, !saving, !store.isBusy, store.bookID == bookID else { return }
        saving = true; localError = nil
        Task {
            let saved = await store.saveAnswerComposition(composition, title: title, onError: { localError = $0 })
            saving = false
            if saved { onSaved(); dismiss() } else if localError == nil { localError = "未能保存，标题与选区已保留，请重试。" }
        }
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
    var onSelectionSave: ((RenderedMarkdownSelection) -> Void)? = nil
    var body: some View {
        RichMarkdownView(markdown: markdown,
                         baseDirectory: store.sourceFileURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs", isDirectory: true),
                         onSelectionChange: onSelectionChange, onSelectionSave: onSelectionSave)
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
