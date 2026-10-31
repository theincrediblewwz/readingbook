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
    @EnvironmentObject private var typography: ReadingTypographySettings
    @Environment(\.readingReduceMotion) private var reduceMotion
    @Environment(\.workspaceCanvasBlocked) private var workspaceBlocked
    @Environment(\.isReaderPanelActive) private var panelActive
    let composerDraft: QueryComposerDraft
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
    @State private var historyBook: BookProject?
    @State private var historyMessageID: String?
    @State private var memorySourceID: String?
    @State private var foldedExpanded = false
    @FocusState private var composerFocused: Bool
    private var composerIsActive: Bool { !workspaceBlocked && (embedded ? panelActive && store.readingCompanionVisible && store.readingCompanionTab == "chat" : store.route == "query") }

    var body: some View {
        VStack(spacing: 0) {
            if selectionMode { selectionBar }
            if !store.currentQueryHistory.isEmpty { conversationCollectionBar }
            if !embedded && store.isQueryBusy {
                queryStatus.padding(.horizontal, embedded ? 16 : 24).padding(.vertical, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if store.visibleQueryHistory.isEmpty {
                            questionEmptyState
                        }
                        if foldedExpanded { foldedAnswerRows }
                        ForEach(store.visibleQueryHistory) { message in answerCard(message).id(message.id) }
                    }.padding(.horizontal, embedded ? 16 : 24).padding(.vertical, embedded ? 12 : 20).frame(maxWidth: 940).frame(maxWidth: .infinity)
                }.onChange(of: store.currentQueryHistory.count) { _, _ in
                    if let last = store.currentQueryHistory.last { withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: memorySourceID) { _, id in
                    guard let id else { return }; withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { proxy.scrollTo(id, anchor: .center) }; memorySourceID = nil
                }
            }
            composer
        }.padding(.top, embedded ? 0 : 76).background(embedded ? Color.clear : Palette.canvas)
        .readingTextContext(.conversation)
        .onChange(of: store.bookID) { _, _ in selectionMode = false; selectedAnswers.removeAll(); renderedSelections.removeAll(); saveRequest = nil; historyBook = nil; historyMessageID = nil }
        .onAppear { revealRequestedHistory() }
        .onChange(of: store.queryHistoryMessageID) { _, _ in revealRequestedHistory() }
        .onChange(of: composerIsActive) { _, active in if !active { composerFocused = false } else { revealRequestedHistory() } }
        .onChange(of: store.queryInteractionMode) { _, _ in store.queryAllowsOrganizing = false; resetModePresentation() }
        .onChange(of: store.queryAnswerStyle) { _, _ in resetModePresentation() }
        .task(id: suggestionRefreshKey) {
            store.questionSuggestions.refresh(store: store, active: composerIsActive,
                eligible: !store.visibleQueryHistory.contains(where: { $0.role == "assistant" }))
        }
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
            QueryMemoryInspector(onClose: { showingMemory = false }, onSource: { id in
                let owner = WorkspacePickerOwner(store: store); showingMemory = false
                Task { @MainActor in
                    await Task.yield(); guard owner.matches(store) else { return }
                    historyMessageID = id; historyBook = store.book
                }
            }).environmentObject(store)
        }
        .sheet(item: $historyBook) { project in
            SavedConversationHistory(project: project, focusedMessageID: historyMessageID, onClose: { historyBook = nil }).environmentObject(store)
        }
    }

    private func revealRequestedHistory() {
        guard composerIsActive, let id = store.queryHistoryMessageID, let project = store.book,
              project.chats.contains(where: { $0.id == id }) else { return }
        historyMessageID = id; historyBook = project; store.queryHistoryMessageID = nil
    }

    private var questionEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 24, weight: .medium)).foregroundStyle(Palette.accent)
            Text("想从这本书里弄懂什么？").font(.system(size: 18, weight: .semibold))
            ModelQuestionSuggestions(state: store.questionSuggestions, draft: composerDraft) { question = $0 }
        }.padding(.vertical, 32).frame(maxWidth: .infinity, minHeight: 180)
    }
    private var suggestionRefreshKey: String {
        store.collectionOwnerKey + "|" + store.queryScope.rawValue + "|" + (store.selectedUnitID ?? "") + "|" + store.currentQueryPreferences.contextIdentity + "|" + store.settings.baseURL + "|" + store.settings.model + "|" + String(composerIsActive) + "|" + String(store.isQueryBusy) + "|" + String(store.visibleQueryHistory.contains { $0.role == "assistant" })
    }
    private var conversationCollectionBar: some View {
        HStack(spacing: 6) {
            if !store.foldedQueryAnswers.isEmpty {
                Button { foldedExpanded.toggle() } label: {
                    Label("已收起 \(store.foldedQueryAnswers.count)", systemImage: "tray.full").font(.system(size: 12, weight: .medium))
                }.buttonStyle(ReadingToolbarButtonStyle(selected: foldedExpanded)).help("收起的回答仍属于当前对话，后续问题仍可使用它们；点击展开列表。")
            } else { Text("当前对话").font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Button { Task { await store.collapseCurrentQueryAnswers() } } label: { Image(systemName: "rectangle.compress.vertical").frame(width: 32, height: 32) }
                .buttonStyle(ReadingQuietButtonStyle()).help("一键收起所有回答；仍保留在当前上下文中。").accessibilityLabel("收起全部回答")
                .disabled(store.isOrganizingCollections || !store.visibleQueryHistory.contains { $0.role == "assistant" })
            if !store.foldedQueryAnswers.isEmpty {
                Button { Task { await store.archiveFoldedQueryAnswers(); foldedExpanded = false } } label: { Label("移入历史", systemImage: "archivebox").font(.system(size: 12)).frame(minHeight: 32) }
                    .buttonStyle(ReadingQuietButtonStyle()).help("把已收起的完整问答收纳到一个历史文件夹；从下一次提问起不再自动带入上下文，仍可恢复或主动引用。")
                    .disabled(store.isOrganizingCollections)
            }
        }.padding(.horizontal, embedded ? 16 : 24).padding(.vertical, 4)
    }
    private var foldedAnswerRows: some View {
        ForEach(store.foldedQueryAnswers) { message in
            Button { Task { await store.organizeReaderCollections(.collapse(["chat:" + message.id], false)) } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "text.bubble").foregroundStyle(Palette.accent)
                    Text(String(message.content.prefix(100))).lineLimit(2).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                    Text("展开").font(.system(size: 12)).foregroundStyle(Palette.accent)
                }.padding(12).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            }.buttonStyle(ReadingQuietButtonStyle()).help("展开这条回答；不会重新生成。").disabled(store.isOrganizingCollections)
        }
    }
    private var composer: some View {
        BookChatComposer(composerDraft: composerDraft, embedded: embedded, composerFocus: $composerFocused,
            onSend: send, onReviewChanges: { reviewingChanges = true },
            onShowHistory: { historyMessageID = nil; historyBook = store.book }, onShowMemory: { showingMemory = true })
    }
    private var queryStatus: some View {
        QueryProgressButton(state: store.queryProgressState, onCancel: store.cancelQuery)
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
        let prepared = ChatMarkdownBody.prepare(message.content, bookID: bookID, project: store.book)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label(assistant ? "一起理解" : "你的问题", systemImage: assistant ? "sparkles" : "person.crop.circle")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(assistant ? Palette.accent : .secondary)
                Spacer()
                if assistant {
                    Button { Task { await store.organizeReaderCollections(.collapse(["chat:" + message.id], true)) } } label: { Image(systemName: "minus").frame(width: 30, height: 32) }
                        .buttonStyle(ReadingQuietButtonStyle()).help("收起这条回答，仍保留在当前对话上下文。").accessibilityLabel("收起回答").disabled(store.isOrganizingCollections)
                    if selectionMode {
                        Toggle("选择", isOn: Binding(get: { selectedAnswers.contains(message.id) }, set: { selected in
                            if selected { selectedAnswers.insert(message.id) } else { selectedAnswers.remove(message.id) }
                        })).toggleStyle(.checkbox).font(.system(size: 13)).help("将这条回答加入合并选择").disabled(store.isBusy)
                    }
                    Menu {
                        answerActions(message, bookID: bookID, prepared: prepared)
                    } label: { Label("保存", systemImage: "square.and.arrow.down").frame(minHeight: 44).contentShape(Rectangle()) }.font(.system(size: 14)).menuStyle(.borderlessButton).modifier(ReadingHoverSurface()).fixedSize().disabled(store.isBusy)
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
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
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
              selection.sourceMarkdown == ChatMarkdownBody.prepare(message.content, bookID: bookID, project: store.book),
              store.bookID == bookID, store.book?.chats.first(where: { $0.id == message.id })?.content == message.content else { return }
        request(parts: [SavedAnswerPart(messageID: message.id, sourceContent: message.content,
                                      text: selection.text, kind: .renderedText)], bookID: bookID)
    }
    private func send() {
        guard composerIsActive else { return }
        guard store.canStartQuery, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let input = question; store.ask(input, allowsOrganizing: store.queryInteractionMode == .functional && store.queryAllowsOrganizing)
        if store.isQueryBusy { question = "" }
    }
    private func resetModePresentation() {
        selectionMode = false; selectedAnswers = []; renderedSelections = [:]
        store.queryDisclosure = ""; store.queryRetryQuestion = nil
    }
}

private struct ModelQuestionSuggestions: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var state: ReadingQuestionSuggestionState
    @ObservedObject var draft: QueryComposerDraft
    let select: (String) -> Void
    var body: some View {
        if !state.questions.isEmpty && draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isQueryBusy {
            VStack(spacing: 8) {
                ForEach(state.questions, id: \.self) { question in
                    Button { select(question) } label: {
                        Text(question).font(.system(size: 14)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: 620, minHeight: 44, alignment: .leading)
                    }.buttonStyle(ReadingQuietButtonStyle(radius: 16)).background(Palette.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                        .disabled(store.isQueryBusy).help("模型结合当前原文想到的问题。点击填入，确认后发送。")
                }
            }
        }
    }
}

// Draft edits invalidate only this input surface; history owns no draft subscription.
private struct BookChatComposer: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject private var typography: ReadingTypographySettings
    @ObservedObject var composerDraft: QueryComposerDraft
    var embedded = false
    var composerFocus: FocusState<Bool>.Binding
    var onSend: () -> Void
    var onReviewChanges: () -> Void
    var onShowHistory: () -> Void
    var onShowMemory: () -> Void
    @State private var composerPopover: ComposerPopover?
    private enum ComposerPopover: String, Identifiable { case help, disclosure, actions, mode; var id: String { rawValue } }
    private var question: String {
        get { composerDraft.text }
        nonmutating set { composerDraft.text = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("围绕所选内容，问一个问题…", text: Binding(get: { question }, set: { question = $0 }), axis: .vertical)
                .font(typography.font(for: .conversation)).lineLimit(1...6).textFieldStyle(.plain).focused(composerFocus).onSubmit(onSend)
                .frame(minHeight: 48)
            // One stable native menu hierarchy. Do not create an alternative
            // composer containing the same menus during an adaptive size probe.
            HStack(spacing: 5) {
                scopeControls
                modeStyleControl
                Spacer(minLength: 0)
                QueryAttachmentsControl().labelStyle(.iconOnly).frame(width: 28)
                    .overlay(alignment: .topTrailing) {
                        if attachmentCount > 0 {
                            Text("\(attachmentCount)").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.accent)
                                .padding(.horizontal, 3).background(Palette.surface, in: Capsule()).offset(x: 4, y: 2).allowsHitTesting(false)
                        }
                    }.accessibilityLabel("附加内容").accessibilityValue("已附加 \(attachmentCount) 项")
                questionOptions
                sendButton
            }
            if !store.pendingCurrentBookChanges.isEmpty {
                Button(action: onReviewChanges) {
                    Label("审阅 \(store.pendingCurrentBookChanges.count) 项待确认修改", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(ReadingQuietButtonStyle()).foregroundStyle(Palette.accent).disabled(store.isBusy)
            }
        }.padding(embedded ? 10 : 16).modifier(ChatComposerSurface(embedded: embedded)).frame(maxWidth: 900).padding(.horizontal, embedded ? 12 : 24).padding(.bottom, embedded ? 10 : 22)
            .popover(item: $composerPopover) { page in
                if page == .actions {
                    optionsPanel
                } else if page == .mode {
                    modeStylePanel
                } else if page == .disclosure {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("这次查阅记录").font(.system(size: 16, weight: .semibold))
                        ScrollView { Text(store.queryDisclosure).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }.padding(20).frame(width: 340, height: 300)
                } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("范围、保存与公式").font(.system(size: 16, weight: .semibold))
                    Text("左下选择本次允许阅读的范围；旁边的模式按钮选择对话模式、讲解方式与本次权限，回形针可附加内容。更多菜单可查看记录、历史与记忆。")
                    Text("回答的保存菜单支持完整保存、选段和多条合并。保留公式与排版时，选择 Markdown 源文片段。")
                    Text("纯阅读只分享所选内容；功能协作可调用组件。老师伴读会分开说明背景，原文考据只谈已读出处。已有笔记的修改仍先供你审阅。")
                }.font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4).padding(20).frame(width: 320)
                }
            }
    }
    private var scopeControls: some View {
        QueryScopeControl(compact: embedded).help(store.isQueryBusy ? store.lastQuestionContext : store.queryScopePreview)
    }
    private var permissionSummary: String {
        store.queryInteractionMode.title + " · " + store.queryAnswerStyle.title +
            (store.queryInteractionMode == .functional ? (store.queryAllowsOrganizing ? " · 允许本次整理，修改仍需审阅" : " · 只读提问") : " · 仅阅读所选内容")
    }
    private var attachmentCount: Int {
        (store.queryScope == .notes ? 0 : store.queryAttachedDocuments.count) + store.queryReferencedAnswerIDs.count +
            (store.queryInteractionMode == .functional ? store.queryAuthorizedNodes.count : 0)
    }
    private var sendButton: some View {
        Button(action: onSend) { Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold)).frame(width: 28, height: 30) }
            .controlSize(.large).buttonStyle(.borderedProminent)
            .disabled(!store.canStartQuery || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canUseQueryScope(store.queryScope))
            .help("发送问题\n" + permissionSummary).accessibilityLabel("发送问题").accessibilityHint(permissionSummary)
    }
    private var compactModeStyleTitle: String {
        (store.queryInteractionMode == .reading ? "纯阅读" : "协作") + " · " +
            (store.queryAnswerStyle == .mentor ? "老师" : "考据")
    }
    private var modeStyleControl: some View {
        Button { composerPopover = .mode } label: {
            HStack(spacing: 4) {
                Text(compactModeStyleTitle).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
            }.padding(.horizontal, 6).frame(minWidth: 64, minHeight: 40)
        }.buttonStyle(ReadingQuietButtonStyle()).disabled(store.isQueryBusy)
            .help(permissionSummary + "\n选择对话模式、讲解方式和功能协作权限")
            .accessibilityLabel("对话模式与讲解方式").accessibilityValue(permissionSummary)
    }
    private var modeStylePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("对话方式").font(.system(size: 17, weight: .semibold)); Spacer(); ReaderInformationButton(title: "对话方式", text: permissionSummary) }
            Text("对话模式").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            ManagementSegmentedControl(selection: Binding(get: { store.queryInteractionMode.rawValue }, set: { if let mode = ReadingConversationMode(rawValue: $0) { store.queryInteractionMode = mode } }), options: [
                .init(id: "reading", title: "纯阅读", detail: "只阅读本次选择的原文和资料，不修改内容。"),
                .init(id: "functional", title: "功能协作", detail: "可以使用组件功能；改动已有内容仍先供你审阅。")
            ])
            Text("讲解方式").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            ManagementSegmentedControl(selection: Binding(get: { store.queryAnswerStyle.rawValue }, set: { if let style = ReadingAnswerStyle(rawValue: $0) { store.queryAnswerStyle = style } }), options: [
                .init(id: "mentor", title: "老师伴读", detail: "解释眼前内容，可以另外补充背景并明确区分。"),
                .init(id: "research", title: "原文考据", detail: "围绕本次读到的原文与出处讲解，区分明载、推断和未知。")
            ])
            if store.queryInteractionMode == .functional {
                Toggle("允许这次整理", isOn: $store.queryAllowsOrganizing).toggleStyle(.switch)
                    .help("只授权这一次提问；修改已有内容仍需审阅，切换回纯阅读会取消整理权限。")
            }
        }.padding(22).frame(width: 370)
    }
    private var questionOptions: some View {
        Button { composerPopover = .actions } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium)).frame(width: 30, height: 40)
        }.buttonStyle(ReadingQuietButtonStyle()).help("历史对话、自动摘要、查阅记录与字号")
            .accessibilityLabel("对话更多设置").accessibilityHint("查看历史对话、自动摘要、查阅记录与字号")
    }
    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("对话工具").font(.system(size: 17, weight: .semibold)); Spacer()
                Button { composerPopover = nil } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("关闭对话工具")
            }
            optionRow("历史对话", detail: "按文件夹查找、收纳和引用完整回答", icon: "archivebox") { composerPopover = nil; onShowHistory() }
            optionRow("对话摘要", detail: "查看长对话要点及其原始问答", icon: "brain.head.profile") { composerPopover = nil; onShowMemory() }
            HStack(spacing: 12) {
                Image(systemName: "text.badge.star").font(.system(size: 19)).foregroundStyle(Palette.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text("自动整理长对话").font(.system(size: 14, weight: .medium))
                    Text("聊得长时归纳要点，方便接着讨论").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("自动整理长对话", isOn: $store.queryMemoryEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }.padding(10).help("开启后，长对话可在请求预算内生成摘要。完整问答保留；关闭只影响后续提问。")
            Divider().opacity(0.4).padding(.vertical, 4)
            HStack(spacing: 4) {
                Text("文字大小").font(.system(size: 13)).foregroundStyle(.secondary); Spacer()
                readingSizeControls
            }.controlSize(.regular)
            if !store.queryDisclosure.isEmpty {
                optionRow("这次查阅记录", detail: "查看本次读取的范围与来源", icon: "list.bullet.rectangle") { composerPopover = .disclosure }
            }
            if let previous = store.queryRetryQuestion {
                optionRow("继续上次问题", detail: "把未完成的问题放回输入框", icon: "arrow.clockwise") { question = previous; store.queryRetryQuestion = nil; composerPopover = nil }
            }
            if store.latestAIChange != nil {
                optionRow("撤销最近一次AI整理", detail: "恢复该次整理前的内容", icon: "arrow.uturn.backward") { composerPopover = nil; Task { await store.undoLatestAIChange() } }
                    .disabled(store.isBusy)
            }
            Divider().opacity(0.4).padding(.vertical, 4)
            optionRow("回到原文", detail: "收起伴读与对话，回到原来的阅读位置", icon: "book.closed") { composerPopover = nil; store.returnToOriginalReading() }
            optionRow("使用说明", detail: "阅读范围、引用、保存与公式", icon: "info.circle") { composerPopover = .help }
        }.padding(18).frame(width: 390)
    }
    private func optionRow(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 19)).foregroundStyle(Palette.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(10).frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        }.buttonStyle(ReadingQuietButtonStyle()).help(title + "\n" + detail)
    }
    @ViewBuilder private var readingSizeControls: some View {
        Button { typography.setPointSize(typography.style(for: .conversation).pointSize + 1, for: .conversation) } label: { Image(systemName: "textformat.size.larger").frame(width: 36, height: 36) }.buttonStyle(ReadingQuietButtonStyle()).help("放大对话文字").accessibilityLabel("放大文字")
            .disabled(typography.style(for: .conversation).pointSize >= ReadingTextStyle.pointSizeRange.upperBound)
        Button { typography.setPointSize(typography.style(for: .conversation).pointSize - 1, for: .conversation) } label: { Image(systemName: "textformat.size.smaller").frame(width: 36, height: 36) }.buttonStyle(ReadingQuietButtonStyle()).help("缩小对话文字").accessibilityLabel("缩小文字")
            .disabled(typography.style(for: .conversation).pointSize <= ReadingTextStyle.pointSizeRange.lowerBound)
        Button("默认") { typography.reset(.conversation) }.buttonStyle(ReadingToolbarButtonStyle()).help("恢复默认对话字号")
    }
}

private struct QueryProgressButton: View {
    @ObservedObject var state: AIProgressObservableState
    var onCancel: () -> Void
    @Environment(\.readingReduceMotion) private var reduceMotion
    @State private var details = false
    var body: some View {
        HStack(spacing: 8) {
            Button { details = true } label: {
                HStack(spacing: 8) {
                    if reduceMotion { Image(systemName: "ellipsis.circle") } else { ProgressView().controlSize(.small) }
                    Text(state.value.phaseTitle).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "ellipsis").foregroundStyle(.secondary)
                }.frame(minHeight: 36).contentShape(Rectangle())
            }.buttonStyle(ReadingQuietButtonStyle()).help("查看本次问答详情")
                .popover(isPresented: $details) { AIProgressStatusView(state: state).padding(18).frame(width: 320) }
            Button(action: onCancel) { Image(systemName: "stop.fill") }
                .buttonStyle(ReadingToolbarButtonStyle()).help("停止这次对话")
        }
    }
}

struct SavedConversationHistory: View {
    @EnvironmentObject private var store: AppStore
    let project: BookProject
    var focusedMessageID: String?
    var onClose: () -> Void
    @State private var windowStart: Int
    @State private var windowEnd: Int
    @State private var folderID: String?
    @State private var kind = "chat"
    @State private var owner: WorkspacePickerOwner?
    private var current: BookProject { owner?.matches(store) == true && store.book?.id == project.id ? store.book! : project }
    private var messages: [ChatMessage] {
        let state = ReaderCollectionRuntime.state(in: current)
        return current.chats.filter { message in
            guard let folderID else { return true }
            let folder = state.assignments["chat:" + message.id]
            return folderID == "@unfiled" ? folder == nil : folder == folderID
        }
    }
    private var companion: [ReadingAnswerReference] {
        let state = ReaderCollectionRuntime.state(in: current)
        return state.archivedCompanionIDs.filter { id in
            guard let folderID else { return true }
            let folder = state.assignments[id]
            return folderID == "@unfiled" ? folder == nil : folder == folderID
        }.compactMap { ReaderCollectionRuntime.reference($0, in: current) }
    }
    init(project: BookProject, focusedMessageID: String?, initialKind: String = "chat", onClose: @escaping () -> Void) {
        self.project = project; self.focusedMessageID = focusedMessageID; self.onClose = onClose
        _kind = State(initialValue: initialKind)
        let start = focusedMessageID.flatMap { id in project.chats.firstIndex { $0.id == id } } ?? max(0, project.chats.count - 60)
        _windowStart = State(initialValue: start); _windowEnd = State(initialValue: min(project.chats.count, start + 60))
    }
    private var displayedRange: Range<Int> {
        let start = min(messages.count, max(0, windowStart))
        return start..<min(messages.count, max(start, windowEnd))
    }
    private func resetWindow(_ id: String?) {
        let start = id.flatMap { id in messages.firstIndex { $0.id == id } } ?? max(0, messages.count - 60)
        windowStart = start; windowEnd = min(messages.count, start + 60)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("历史对话", systemImage: "archivebox").font(.system(size: 18, weight: .semibold))
                    .accessibilityIdentifier("history.range")
                    .accessibilityValue(kind == "chat" ? "显示第 \(displayedRange.isEmpty ? 0 : displayedRange.lowerBound + 1)–\(displayedRange.upperBound) 条，共 \(messages.count) 条已保存的对话" : "共 \(companion.count) 条已归档伴读")
                Spacer()
                ReaderInformationButton(title: "历史与当前对话", text: "这里只收纳和查看完整记录。标有‘已归档’的问答不会自动带入后续问题；‘当前对话’仍可参与上下文。引用只分享本次选中的回答，不会恢复整份历史。")
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).keyboardShortcut(.cancelAction).help("关闭历史对话")
            }.padding(.horizontal, 18).padding(.top, 10)
            HStack {
                ReaderFolderControl(kind: .history, selection: $folderID)
                Spacer(minLength: 8)
                ManagementSegmentedControl(selection: $kind, options: [
                    .init(id: "chat", title: "问答", detail: "完整保存的问答，可按文件夹查阅。"),
                    .init(id: "companion", title: "伴读", detail: "已移入历史的解释、译文和资料对读。")
                ]).frame(maxWidth: 210)
            }.padding(.horizontal, 18).padding(.bottom, 8)
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if kind == "chat" {
                        if displayedRange.lowerBound > 0 {
                            Button("显示更早的对话") { windowStart = max(0, displayedRange.lowerBound - 60) }
                                .buttonStyle(ReadingToolbarButtonStyle()).accessibilityIdentifier("history.load-earlier")
                                .help("向前显示最多60条已保存对话，已显示的内容会保留。")
                        }
                        ForEach(Array(messages[displayedRange])) { message in historyMessage(message) }
                        if messages.isEmpty { emptyHistory }
                        if displayedRange.upperBound < messages.count {
                            Button("显示后续的对话") { windowEnd = min(messages.count, displayedRange.upperBound + 60) }
                                .buttonStyle(ReadingToolbarButtonStyle()).accessibilityIdentifier("history.load-later")
                                .help("继续显示最多60条后续对话，已显示的内容会保留。")
                        }
                    } else {
                        ForEach(companion) { reference in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { Text(reference.title).font(.headline); Spacer(); referenceActions(reference.id, archived: true) }
                                ChatMarkdownBody(markdown: MarkdownReferenceLinks.render(reference.content, bookID: current.id, project: current), presentationActiveOverride: true)
                            }.padding(16).background(Palette.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                        }
                        if companion.isEmpty { emptyHistory }
                    }
                }.padding(18)
            }.id(focusedMessageID)
                .onChange(of: focusedMessageID) { _, id in folderID = nil; kind = "chat"; resetWindow(id) }
                .onChange(of: folderID) { _, _ in resetWindow(nil) }
        }.frame(minWidth: 360, idealWidth: 740, maxWidth: 1000, minHeight: 320, idealHeight: 620, maxHeight: .infinity)
            .background(Palette.canvas).onExitCommand(perform: onClose)
            .onAppear { owner = WorkspacePickerOwner(store: store) }
            .onChange(of: store.collectionOwnerKey) { _, _ in onClose() }
    }
    private var emptyHistory: some View {
        VStack(spacing: 12) {
            Image(systemName: "archivebox").font(.system(size: 26)).foregroundStyle(Palette.accent)
            Text("这里还没有记录").font(.headline)
            Text("将收起的回答移入历史后，可在这里按文件夹查找。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, minHeight: 200)
    }
    private func historyMessage(_ message: ChatMessage) -> some View {
        let archived = current.readerCollections?.archivedChatIDs.contains(message.id) == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.role == "user" ? "你" : "伴读").font(.system(size: 13, weight: .semibold))
                Text(archived ? "已归档" : "当前对话").font(.system(size: 11)).foregroundStyle(.secondary)
                    .help(archived ? "不自动带入后续问题。" : "仍可参与当前范围的对话上下文。")
                Spacer()
                if message.role == "assistant" { referenceActions("chat:" + message.id, archived: archived) }
            }
            ChatMarkdownBody(markdown: MarkdownReferenceLinks.render(message.content, bookID: current.id, project: current), presentationActiveOverride: true)
        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            .background(message.id == focusedMessageID ? Palette.accent.opacity(0.055) : Color.clear).id(message.id)
    }
    private func referenceActions(_ id: String, archived: Bool) -> some View {
        HStack(spacing: 4) {
            ReaderMoveToFolderButton(kind: .history, recordIDs: [id])
            Button {
                guard owner?.matches(store) == true else { return }
                store.setReferencedAnswer(id, included: true); store.readingCompanionTab = "chat"; onClose()
            } label: { Label("引用", systemImage: "paperclip").font(.system(size: 12)).frame(minHeight: 36) }
                .buttonStyle(ReadingQuietButtonStyle()).help("仅把这条回答附加到下一次提问，不恢复其他历史。").disabled(store.isQueryBusy)
            if archived {
                Button { guard let owner else { return }; Task { await store.organizeReaderCollections(.restore([id]), owner: owner) } } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 32, height: 36)
                }.buttonStyle(ReadingQuietButtonStyle()).help("放回当前对话，后续提问可再次自动使用。").accessibilityLabel("放回当前对话").disabled(store.isOrganizingCollections)
            }
        }.disabled(owner?.matches(store) != true)
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
    @EnvironmentObject private var typography: ReadingTypographySettings
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
            MarkdownSourceSelector(source: answer.content, font: typography.nsFont(for: .notes)) { source, text in
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
            ChatMarkdownBody(markdown: ChatMarkdownBody.prepare(previewMarkdown(composition), bookID: bookID, project: store.book), context: .notes, presentationActiveOverride: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
    var context: ReadingTextContext = .conversation
    var onSelectionChange: ((RenderedMarkdownSelection?) -> Void)? = nil
    var onSelectionSave: ((RenderedMarkdownSelection) -> Void)? = nil
    var presentationActiveOverride: Bool? = nil
    var body: some View {
        RichMarkdownView(markdown: markdown,
                         baseDirectory: store.sourceFileURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs", isDirectory: true),
                         onSelectionChange: onSelectionChange, onSelectionSave: onSelectionSave,
                         presentationActiveOverride: presentationActiveOverride)
            .frame(maxWidth: .infinity, alignment: .leading)
            .readingTextContext(context)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "readingbook" { Task { await store.openInternalURL(url) }; return .handled }
                return ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
            })
    }
    static func prepare(_ markdown: String, bookID: String, project: BookProject? = nil) -> String {
        MarkdownReferenceLinks.render(markdown, bookID: bookID, project: project)
    }
}

/// Read-only AppKit selection preserves exact UTF-16 source ranges, including TeX.
private struct MarkdownSourceSelector: NSViewRepresentable {
    let source: String
    let font: NSFont
    let onSelection: (String, String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(source: source, onSelection: onSelection) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)); text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = font; text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 10, height: 10); text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.string = source; text.delegate = context.coordinator; scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.source = source; context.coordinator.onSelection = onSelection
        guard let text = scroll.documentView as? NSTextView else { return }
        if text.string != source { text.string = source; text.setSelectedRange(NSRange(location: 0, length: 0)) }
        if text.font != font {
            let selection = text.selectedRanges, origin = scroll.contentView.bounds.origin
            text.font = font
            if text.selectedRanges != selection { text.selectedRanges = selection }
            scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        }
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
