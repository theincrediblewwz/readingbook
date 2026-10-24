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
@MainActor final class QueryComposerDraft: ObservableObject {
    @Published var text = ""
}

struct EnhancedBookChatView: View {
    @EnvironmentObject var store: AppStore
    var embedded = false
    var body: some View { BookChatContent(composerDraft: store.queryComposerDraft, embedded: embedded) }
}

private struct BookChatContent: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.readingReduceMotion) private var reduceMotion
    @Environment(\.workspaceCanvasBlocked) private var workspaceBlocked
    @ObservedObject var composerDraft: QueryComposerDraft
    var embedded = false
    private var question: String {
        get { composerDraft.text }
        nonmutating set { composerDraft.text = newValue }
    }
    @State private var selectionMode = false
    @State private var selectedAnswers = Set<String>()
    @State private var renderedSelections: [String: RenderedMarkdownSelection] = [:]
    @State private var saveRequest: AnswerSaveRequest?
    @State private var openTrashAfterSheet = false
    @State private var reviewingChanges = false
    @State private var showingMemory = false
    @State private var showingComposerHelp = false
    @State private var memorySourceID: String?
    @FocusState private var composerFocused: Bool
    private var composerIsActive: Bool { !workspaceBlocked && (embedded ? store.readingCompanionVisible && store.readingCompanionTab == "chat" : store.route == "query") }

    var body: some View {
        VStack(spacing: 0) {
            if selectionMode { selectionBar }
            if store.aiProgress.hasActivity, store.aiProgress.bookID == store.bookID {
                AIProgressStatusView(state: store.aiProgressState, compact: true).padding(.horizontal, embedded ? 16 : 24).padding(.vertical, 10)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if store.book?.chats.isEmpty != false {
                            questionEmptyState
                        }
                        ForEach(store.book?.chats ?? []) { message in answerCard(message).id(message.id) }
                    }.padding(.horizontal, embedded ? 16 : 24).padding(.vertical, embedded ? 12 : 20).frame(maxWidth: 940).frame(maxWidth: .infinity)
                }.onChange(of: store.book?.chats.count) { _, _ in
                    if let last = store.book?.chats.last { withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: memorySourceID) { _, id in
                    guard let id else { return }; withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { proxy.scrollTo(id, anchor: .center) }; memorySourceID = nil
                }
            }
            composer
        }.padding(.top, embedded ? 0 : 76).background(embedded ? Color.clear : Palette.canvas)
        .onChange(of: store.bookID) { _, _ in selectionMode = false; selectedAnswers.removeAll(); renderedSelections.removeAll(); saveRequest = nil }
        .onChange(of: composerIsActive) { _, active in if !active { composerFocused = false } }
        .sheet(item: $saveRequest, onDismiss: {
            if openTrashAfterSheet { openTrashAfterSheet = false; store.showingTrash = true }
        }) { request in
            AnswerSaveSheet(bookID: request.bookID, sourceAnswer: request.sourceAnswer, parts: request.parts,
                            showTrash: { openTrashAfterSheet = true; saveRequest = nil },
                            onSaved: { selectionMode = false; selectedAnswers.removeAll() })
                .environmentObject(store).frame(minWidth: 520, idealWidth: 680, minHeight: 440, idealHeight: 600)
        }
        .sheet(isPresented: $reviewingChanges) { AIChangeReview(close: { reviewingChanges = false }).environmentObject(store) }
        .sheet(isPresented: $showingMemory) {
            QueryMemoryInspector(onClose: { showingMemory = false }, onSource: { id in showingMemory = false; memorySourceID = id }).environmentObject(store)
        }
    }

    private var questionEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 24, weight: .medium)).foregroundStyle(Palette.accent)
            Text("想从这本书里弄懂什么？").font(.system(size: 18, weight: .semibold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { suggestion("这一部分在讲什么？"); suggestion("有哪些重要概念？"); suggestion("这些线索如何联系？") }
                VStack(spacing: 8) { suggestion("这一部分在讲什么？"); suggestion("有哪些重要概念？"); suggestion("这些线索如何联系？") }
            }
        }.padding(.vertical, 32).frame(maxWidth: .infinity, minHeight: 180)
    }
    private func suggestion(_ text: String) -> some View {
        Button { question = text } label: { Text(text).font(.system(size: 13)).lineLimit(1).fixedSize().padding(.horizontal, 12).frame(minHeight: 44).contentShape(Capsule()) }
            .buttonStyle(.plain).background(Palette.accent.opacity(0.055), in: Capsule()).disabled(store.isBusy)
            .help("填入问题，确认后发送")
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("围绕所选内容，问一个问题…", text: Binding(get: { question }, set: { question = $0 }), axis: .vertical)
                .font(.system(size: 15)).lineLimit(1...5).textFieldStyle(.plain).focused($composerFocused).onSubmit { send() }
                .frame(minHeight: 44)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { scopeControls; Spacer(minLength: 4); questionOptions; sendButton }
                VStack(spacing: 4) {
                    HStack(spacing: 8) { scopeControls; Spacer(minLength: 0) }
                    HStack(spacing: 8) { questionOptions; Spacer(minLength: 0); sendButton }
                }
            }
            if store.isBusy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在阅读所选内容…").font(.system(size: 13)).foregroundStyle(.secondary) }
            } else if let previous = store.queryRetryQuestion {
                Button { question = previous; store.queryRetryQuestion = nil } label: { Label("继续上次问题", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless).font(.system(size: 13))
            }
            if !store.queryDisclosure.isEmpty && !store.isBusy {
                DisclosureGroup("这次查阅记录") {
                    Text(store.queryDisclosure).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                }.font(.system(size: 13)).padding(.top, 4)
            }
            if !store.pendingCurrentBookChanges.isEmpty {
                Button { reviewingChanges = true } label: {
                    Label("审阅 \(store.pendingCurrentBookChanges.count) 项待确认修改", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Palette.accent).disabled(store.isBusy)
            }
        }.padding(embedded ? 12 : 16).modifier(ChatComposerSurface(embedded: embedded)).frame(maxWidth: 900).padding(.horizontal, embedded ? 12 : 24).padding(.bottom, embedded ? 12 : 22)
            .popover(isPresented: $showingComposerHelp) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("范围、保存与公式").font(.system(size: 16, weight: .semibold))
                    Text("左下选择本次允许阅读的范围，附加内容会一同提供给 AI。")
                    Text("回答的保存菜单支持完整保存、选段和多条合并。保留公式与排版时，选择 Markdown 源文片段。")
                    Text("整理授权仅用于接下来这次发送。修改正文、移除内容或改变读法仍会先请你审阅。对话记忆计入模型预算，原消息保留。")
                }.font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4).padding(20).frame(width: 320)
            }
    }
    private var scopeControls: some View {
        HStack(spacing: 6) { QueryScopeControl(compact: embedded).help(store.isBusy ? store.lastQuestionContext : store.queryScopePreview); QueryAttachmentsControl() }
    }
    private var sendButton: some View {
        Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold)).frame(width: 28, height: 30) }
            .controlSize(.large).buttonStyle(.borderedProminent)
            .disabled(store.isBusy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canUseQueryScope(store.queryScope))
            .help("发送问题").accessibilityLabel("发送问题")
    }
    private var questionOptions: some View {
        Menu {
            Button { store.queryAllowsOrganizing = false } label: { Label("只读提问", systemImage: "lock") }
            Button { store.queryAllowsOrganizing = true } label: { Label("允许本次整理、增添与修改", systemImage: "square.stack.3d.up") }
            Divider()
            Toggle(isOn: $store.queryMemoryEnabled) { Label("整理长对话记忆", systemImage: "brain.head.profile") }
            Button { showingMemory = true } label: { Label("查看记忆与原消息", systemImage: "text.bubble") }
            Button { store.clearCurrentQueryMemory() } label: { Label("清除本范围的整理摘要", systemImage: "eraser") }
            if store.latestAIChange != nil {
                Divider()
                Button { Task { await store.undoLatestAIChange() } } label: { Label("撤销最近一次 AI 整理", systemImage: "arrow.uturn.backward") }
            }
            Divider()
            Button { store.requestedWorkspaceRoute = "reader" } label: { Label("回到原文", systemImage: "book.closed") }
            Button { showingComposerHelp = true } label: { Label("范围、保存与公式说明", systemImage: "info.circle") }
        } label: {
            Label(store.queryAllowsOrganizing ? "本次整理" : "只读", systemImage: store.queryAllowsOrganizing ? "square.stack.3d.up" : "lock")
                .font(.system(size: 13, weight: .medium)).frame(minHeight: 44)
        }.menuStyle(.borderlessButton).fixedSize().disabled(store.isBusy).help("本次权限、对话记忆与更多操作")
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Label("已选 \(selectedAnswers.count) 条", systemImage: "checkmark.circle.fill").font(.system(size: 14, weight: .medium))
            Spacer()
            Button { selectionMode = false; selectedAnswers.removeAll() } label: { Label("取消多选", systemImage: "xmark") }.buttonStyle(.borderless)
            Button {
                guard let book = store.book else { return }
                let parts = book.chats.filter { $0.role == "assistant" && selectedAnswers.contains($0.id) }.map { SavedAnswerPart(answer: $0) }
                saveRequest = AnswerSaveRequest(bookID: book.id, sourceAnswer: nil, parts: parts)
            } label: { Label("合并保存…", systemImage: "doc.on.doc") }.buttonStyle(.borderedProminent).disabled(store.isBusy || selectedAnswers.isEmpty)
        }.controlSize(.large).frame(minHeight: 44).padding(.horizontal, 16).padding(.vertical, 8)
            .background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 16)).frame(maxWidth: 900).padding(.horizontal, 24)
    }

    private func answerCard(_ message: ChatMessage) -> some View {
        let assistant = message.role == "assistant"
        let bookID = store.bookID ?? ""
        let prepared = ChatMarkdownBody.prepare(message.content, bookID: bookID)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label(assistant ? "一起理解" : "你的问题", systemImage: assistant ? "sparkles" : "person.crop.circle")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(assistant ? Palette.accent : .secondary)
                Spacer()
                if assistant {
                    if selectionMode {
                        Toggle("选择", isOn: Binding(get: { selectedAnswers.contains(message.id) }, set: { selected in
                            if selected { selectedAnswers.insert(message.id) } else { selectedAnswers.remove(message.id) }
                        })).toggleStyle(.checkbox).font(.system(size: 13)).help("将这条回答加入合并选择").disabled(store.isBusy)
                    }
                    Menu {
                        answerActions(message, bookID: bookID, prepared: prepared)
                    } label: { Label("保存", systemImage: "square.and.arrow.down").frame(minHeight: 44).contentShape(Rectangle()) }.font(.system(size: 14)).menuStyle(.borderlessButton).fixedSize().disabled(store.isBusy)
                        .help("保存完整回答、精确 Markdown 片段，或进入多选合并；也可右键回答")
                        .accessibilityLabel("保存回答")
                }
            }.controlSize(.regular)
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
                }.padding(12)
                    .background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            if assistant, !message.evidence.isEmpty {
                EvidenceDisclosure(evidence: message.evidence)
            }
        }.padding(24).background(assistant ? Palette.surface.opacity(0.94) : Palette.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line.opacity(0.65), lineWidth: 0.65))
            .padding(.leading, assistant ? 0 : 64)
            .contextMenu {
                if assistant { answerActions(message, bookID: bookID, prepared: prepared) }
            }
    }

    @ViewBuilder private func answerActions(_ message: ChatMessage, bookID: String, prepared: String) -> some View {
        if let selection = renderedSelections[message.id], selection.sourceMarkdown == prepared {
            Button { saveRenderedSelection(message, bookID: bookID, selection: selection) } label: { Label("保存选中文字…", systemImage: "text.badge.plus") }.disabled(store.isBusy)
            Divider()
        }
        Button { request(parts: [SavedAnswerPart(answer: message)], bookID: bookID) } label: { Label("保存完整回答…", systemImage: "square.and.arrow.down") }.disabled(store.isBusy)
        Button { requestSource(message, bookID: bookID) } label: { Label("选择 Markdown 片段…", systemImage: "text.cursor") }.disabled(store.isBusy)
        Divider()
        Button {
            guard store.bookID == bookID else { return }
            selectedAnswers.insert(message.id); selectionMode = true
        } label: { Label(selectionMode ? "加入合并选择" : "多选合并…", systemImage: "checklist") }.disabled(store.isBusy)
    }

    private func selectionSummary(_ selection: RenderedMarkdownSelection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("文字选区 · \(selection.text.count) 字").font(.system(size: 13, weight: .medium))
            if selection.containsMath { Text("含公式，建议选源文").font(.system(size: 13)).foregroundStyle(Palette.copper) }
        }.help("渲染区只保存语义文本，不包含精确 Markdown / TeX。需要保留公式时请选择源文片段。")
    }

    private func selectionActions(_ message: ChatMessage, bookID: String, selection: RenderedMarkdownSelection) -> some View {
        HStack(spacing: 12) {
            Button { requestSource(message, bookID: bookID) } label: { Label("选源文", systemImage: "text.cursor") }
                .buttonStyle(.borderless).help("从只读 Markdown 中选择连续原文，精确保留公式")
            Button {
                saveRenderedSelection(message, bookID: bookID, selection: selection)
            } label: { Label("保存选段…", systemImage: "square.and.arrow.down") }.keyboardShortcut("s", modifiers: [.command, .shift]).help("保存语义摘录 · ⌘⇧S；公式建议选择源文")
        }.font(.system(size: 14)).controlSize(.large).fixedSize().disabled(store.isBusy)
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
        guard composerIsActive else { return }
        guard !store.isBusy, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let input = question; store.ask(input, allowsOrganizing: store.queryAllowsOrganizing)
        if store.isBusy { question = "" }
    }
}

private struct ChatComposerSurface: ViewModifier {
    var embedded: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if embedded { content.background(Palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line.opacity(0.65), lineWidth: 0.7) } }
        else { content.readingGlass(radius: 24) }
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
            HStack(spacing: 12) {
                Text("保存摘记").font(.system(size: 18, weight: .semibold))
                Spacer()
                Text(sourceAnswer != nil ? "Markdown 片段" : isSemanticExcerpt ? "选中文字" : "\(parts.count) 条回答")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }.padding(.horizontal, ReadingLayout.panelPadding).padding(.vertical, 16)
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("标题").font(.system(size: 14)).foregroundStyle(.secondary).fixedSize()
                    TextField("文档标题", text: $title).font(.system(size: 16)).textFieldStyle(.roundedBorder).disabled(saving)
                }.controlSize(.large)
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
                        Text(localError).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: localError.count > 100 ? 64 : 34)
                }
            }.padding(.horizontal, ReadingLayout.panelPadding).padding(.vertical, 16)
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
            Text("选中连续的 Markdown 片段；公式请包含完整分隔符。下方可预览问题与出处。")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if isSemanticExcerpt {
            Text("这里只保存选中的文字。需要保留公式、图片和排版时，请选择 Markdown 源文片段。")
                .font(.system(size: 13)).foregroundStyle(Palette.copper).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("保留对应的问题与出处，保存到笔记并添加导图节点。")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sourceWorkspace(_ answer: ChatMessage, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("原回答 · Markdown 源文", systemImage: "doc.text").font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                Text(selectedSource.isEmpty ? "拖动选择" : "已选 \(selectedSource.count) 字").font(.system(size: 13)).foregroundStyle(.secondary)
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
                            .font(.system(size: 13)).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }.frame(height: max(40, min(220, (height - 40) * 0.40))).padding(.top, 5)
            } label: {
                Text(readyComposition == nil && !selectedSource.isEmpty ? "正在更新选区预览…" : "即时预览 · 问题与来源").font(.system(size: 13, weight: .medium))
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
        HStack(spacing: 12) {
            Button { dismiss() } label: { Label("取消", systemImage: "xmark") }.keyboardShortcut(.cancelAction).disabled(saving)
            Spacer(minLength: 0)
            if let composition = readyComposition,
               store.book?.documents.first(where: { $0.id == composition.documentID })?.trashedAt != nil {
                Button { showTrash() } label: { Label("回收站恢复", systemImage: "arrow.uturn.backward") }.help("恢复已保存的原摘记，不另建副本").disabled(saving)
            }
            Button { save() } label: { Label(saving ? "保存中…" : "保存摘记", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(readyComposition == nil || saving || store.isBusy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.bookID != bookID)
        }.controlSize(.large).frame(minHeight: ReadingLayout.controlHeight)
            .padding(.horizontal, ReadingLayout.panelPadding).padding(.vertical, 12)
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
        text.font = .monospacedSystemFont(ofSize: 15, weight: .regular); text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
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
