import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Security
import CryptoKit
import ReadingCore

@MainActor final class AppStore: ObservableObject {
    @Published var books: [BookProject] = []
    @Published var bookID: String? {
        didSet {
            if oldValue != bookID {
                queryDocumentIDs = nil; queryAttachedDocumentIDs = []; queryAuthorizedNodeIDs = []; queryComposerDraft.text = ""
                queryDisclosure = ""; lastQuestionContext = ""; queryRetryQuestion = nil
                queryAllowsOrganizing = false; renderedWorkspaceVisibility = nil; renderedSelectedNodeIDs = []
                smartReadingPlanReady = false
                if queryScope == .selection { queryScope = .page }
            }
        }
    }
    @Published var route = "reader" { didSet { if route != "query" { queryAllowsOrganizing = false }; rememberWorkspaceNavigation() } }
    @Published var requestedWorkspaceRoute: String?
    @Published var workspaceMemory = BookWorkspaceMemory()
    @Published var workspaceMemoryRevision = 0
    var restoringWorkspaceMemory = false
    var workspaceMemorySaveTask: Task<Void, Never>?
    @Published var selectedObjectID: String?
    @Published var selectedUnitID: String? {
        didSet {
            if let bookID, let selectedUnitID { UserDefaults.standard.set(selectedUnitID, forKey: "position-\(bookID)") }
            if oldValue != selectedUnitID { sourceReadingSelection = nil; focusedReadingAnchorID = nil; selectedObjectID = nil; readingContextDocumentID = nil; refreshReadingExperienceIndex() }
        }
    }
    @Published var sourceReadingSelection: SourceReadingSelection?
    @Published var focusedReadingAnchorID: String?
    let queryComposerDraft = QueryComposerDraft()
    @Published var readingCompanionTab = "companion"
    @Published var readingCompanionVisible = false
    @Published var readingCompanionSection = "context"
    @Published var readingSourceMode = "original" { didSet { updateWorkspaceMemory { $0.readingSourceMode = readingSourceMode } } }
    @Published var readingExperienceIndex = ReadingExperienceState()
    @Published var readingScopeCurrent = false
    @Published var lastQuestionContext = ""
    @Published var queryScope: ReadingQueryScope = .page
    /// nil means all active notes; an empty set is an explicit empty selection.
    @Published var queryDocumentIDs: Set<String>?
    /// Added only by the reader's explicit attachment controls; never inferred from visibility.
    @Published var queryAttachedDocumentIDs: Set<String> = []
    @Published var queryAuthorizedNodeIDs: Set<String> = []
    @Published var queryMemoryEnabled = UserDefaults.standard.object(forKey: "query-memory-enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(queryMemoryEnabled, forKey: "query-memory-enabled") }
    }
    @Published var queryDisclosure = ""
    @Published var queryRetryQuestion: String?
    @Published var queryAllowsOrganizing = false
    @Published var pendingAIChanges: [PendingAIChange] = []
    @Published var renderedWorkspaceVisibility: ReadingVisibleObjectsSnapshot?
    @Published var renderedSelectedNodeIDs: [String] = []
    @Published var workspaceAICommand: WorkspaceAICommand?
    var workspaceAIResponses: [UUID: Data] = [:]
    @Published var readingExperienceError: String?
    @Published var showingLibrarySearch = false
    @Published var readingContextDocumentID: String?
    var readingContextCacheKey: ReadingContext?
    var readingContextCache = ReadingContextItems()
    @Published var projectRevision = 0
    @Published var pdfNavigationToken = 0
    @Published var activeReadingUnitID: String?
    @Published var isSmartReadingRunning = false
    @Published var smartReadingPlanReady = false
    var smartReadingProgressCacheKey: String?
    var smartReadingProgressCache: SmartReadingProgress?
    var smartReadingUnitProgressCache = SmartReadingProgressCache()
    @Published var search = ""
    @Published var selectedDocumentID: String? { didSet { rememberWorkspaceNavigation() } }
    @Published var editorTitle = "" { didSet { if editorDirty { persistDraft() } } }
    @Published var editorMarkdown = "" { didSet { if editorDirty { persistDraft() } } }
    @Published var editorDirty = false { didSet { if editorDirty { persistDraft() } else { draftSaveTask?.cancel() } } }
    var documentBaseHash: String?
    private var draftSaveTask: Task<Void, Never>?
    @Published var libraryLoadIssues: [LibraryLoadIssue] = []
    @Published var documentError: String?
    @Published var draftEvidence: [Evidence] = []
    @Published var sourceFileURL: URL?
    @Published var pdfPasswordRequest: PDFPasswordRequest?
    @Published var pdfSessionPasswords: [String: String] = [:]
    @Published var pdfUnlockedBookIDs: Set<String> = []
    @Published var isBusy = false
    @Published var isSavingDocument = false
    @Published var isExportingProject = false
    @Published var isImportingBookCommit = false
    @Published var isCommittingLocalWrite = false
    @Published var activity = "把一本书带进来，让理解慢慢长出来。"
    @Published var errorMessage: String?
    @Published var showingSettings = false
    @Published var showingPlugins = false
    @Published var showingOCR = false
    @Published var showingTrash = false
    @Published var isRecognizingPDF = false
    @Published var savedServices: [SavedAIService] = []
    @Published var selectedServiceID: String?
    @Published var serviceName = "我的 AI"
    @Published var ocrServiceID: String?
    @Published var connectionStatus = ""
    @Published var archivedBooks: [BookProject] = []
    @Published var removedBooks: [BookProject] = []
    let aiProgressState = AIProgressObservableState()
    var aiProgress: AIProgressPresentationState {
        get { aiProgressState.value }
        set {
            let old = aiProgressState.value
            if old.runID != newValue.runID || old.bookID != newValue.bookID || old.status != newValue.status || old.phase != newValue.phase || old.toolName != newValue.toolName { objectWillChange.send() }
            aiProgressState.value = newValue
        }
    }
    @Published var catalogOperations = 0
    @Published var libraryRootURL: URL
    @Published var lastTrashedProjectURL: URL?
    let storageState = StorageSettingsState()
    @Published var deletionRequest: WorkspaceDeletion?
    @Published var settings = ProviderSettings()
    @Published var providerCatalog = ProviderCatalog.current
    @Published var apiKey = ""
    @Published var requestsUsed = 0
    @Published var timeFrom = -5000.0
    @Published var timeTo = 3000.0
    @Published var showUndated = true
    @Published var selectedTemporalEntityID: String?
    @Published var temporalAxis = "legacy"
    @Published var timeCursor = 0.0
    var repository: LibraryRepository
    var modelCatalogRepository: ModelCatalogRepository
    var readingIndexTask: Task<Void, Never>?
    var readingIndexGeneration = 0
    var readingIndexCache: [String: ReadingExperienceState] = [:]
    var readingIndexCacheOrder: [String] = []
    var readableRefreshTask: Task<Void, Never>?
    let serviceProfileDraft = ServiceProfileDraftState()
    let reader = AIReader()
    let pdfOCRReader = PDFOCRReader()
    private var loaded = false
    var navigationGeneration = 0
    private var documentGeneration = 0
    var task: Task<Void, Never>?
    var book: BookProject? { books.first { $0.id == bookID } }
    var selectedUnit: SourceUnit? { book?.units.first { $0.id == selectedUnitID } }
    var visibleEvents: [KnowledgeEvent] {
        let scoped = readingScopeCurrent ? readingContextItems.events : (book?.events ?? [])
        return scoped.filter {
            guard let year = $0.startYear else { return showUndated }
            return Double($0.endYear ?? year) >= timeFrom && Double(year) <= timeTo
        }.sorted { ($0.startYear ?? Int.max) < ($1.startYear ?? Int.max) }
    }
    init() {
        let root = AppDataLocations.rootURL
        libraryRootURL = root
        repository = LibraryRepository(rootURL: root)
        modelCatalogRepository = ModelCatalogRepository(rootURL: root.appendingPathComponent("ModelCatalog", isDirectory: true))
        if let data = UserDefaults.standard.data(forKey: "provider"), let saved = try? JSONDecoder().decode(ProviderSettings.self, from: data) { settings = saved }
        loadServiceProfiles()
    }
    func load() async {
        guard !loaded else { return }; loaded = true
        guard AppDataLocations.configuredRootAvailable else {
            errorMessage = "书库位置暂不可用。请连接原磁盘，或在设置中打开已有书库。"; route = "library"; return
        }
        await loadModelCatalog()
        do {
            let report = try await repository.loadReport()
            books = report.projects; libraryLoadIssues = report.issues
            removedBooks = try await repository.removedBooksReport().projects
            let lastID = UserDefaults.standard.string(forKey: "workspace-last-book-v1")
            if let first = books.first(where: { $0.id == lastID }) ?? books.first { await selectBook(first.id) }
            refreshMissingReadableFiles()
            if !report.issues.isEmpty { errorMessage = libraryLoadIssueSummary(report.issues) }
        }
        catch { errorMessage = "书库读取失败，原文件已保留：\(error.localizedDescription)" }
    }
    func selectBook(_ id: String, preferredRoute: String? = nil) async {
        guard !isBusy else { return }
        guard !editorDirty else { errorMessage = "请先保存当前文档，再切换书籍。"; return }
        guard books.contains(where: { $0.id == id }) else { errorMessage = "这本书当前不可用，请回到书库重新选择。"; return }
        isBusy = true
        defer { isBusy = false; restoringWorkspaceMemory = false }
        NotificationCenter.default.post(name: Notification.Name("ReadingBookCaptureWorkspaceMemory"), object: nil)
        flushWorkspaceMemory()
        restoringWorkspaceMemory = true
        navigationGeneration += 1; documentGeneration += 1
        pdfNavigationToken += 1
        pdfPasswordRequest = nil
        let generation = navigationGeneration
        bookID = id; route = "reader"; sourceFileURL = nil; selectedObjectID = nil; selectedDocumentID = nil; activeReadingUnitID = nil; editorMarkdown = ""; editorTitle = ""; draftEvidence = []; documentError = nil; documentBaseHash = nil
        loadWorkspaceMemory()
        sourceReadingSelection = nil; focusedReadingAnchorID = nil; readingCompanionVisible = false; readingCompanionSection = "context"; readingSourceMode = "original"; readingScopeCurrent = false; lastQuestionContext = ""; readingExperienceError = nil
        selectedUnitID = UserDefaults.standard.string(forKey: "position-\(id)") ?? book?.lastUnitID ?? book?.units.first?.id
        if book?.units.contains(where: { $0.id == selectedUnitID }) != true { selectedUnitID = book?.units.first?.id }
        if let page = workspaceMemory.activePDFPage, let unit = book?.units.first(where: { $0.page == page }) { selectedUnitID = unit.id }
        if let project = book {
            let url = await repository.sourceURL(for: project)
            guard bookID == id && generation == navigationGeneration else { return }
            sourceFileURL = url
            await preparePDFSession(bookID: id, sourceURL: url)
            guard bookID == id && generation == navigationGeneration else { return }
        }
        let years = book?.events.flatMap { [$0.startYear, $0.endYear].compactMap { $0 } } ?? []
        timeFrom = Double((years.min() ?? -5000) - 1); timeTo = Double((years.max() ?? 3000) + 1)
        restoreDraft()
        await restoreWorkspaceNavigation(expectedBookID: id, generation: generation)
        guard bookID == id && generation == navigationGeneration else { return }
        if let preferredRoute, !editorDirty { route = preferredRoute }
        restoringWorkspaceMemory = false
        workspaceMemoryRevision &+= 1
        rememberWorkspaceNavigation()
        refreshReadingExperienceIndex()
        let owner = repository
        Task { try? await owner.refreshReadableViews(id: id, archived: false) }
    }
    func publish(_ project: BookProject) {
        projectRevision += 1
        if let index = books.firstIndex(where: { $0.id == project.id }) { books[index] = project }
        else { books.insert(project, at: 0) }
        if project.id == bookID {
            let activeDocumentIDs = Set(project.activeDocuments.map(\.id))
            queryAttachedDocumentIDs.formIntersection(activeDocumentIDs)
            queryAuthorizedNodeIDs.formIntersection(Set(project.nodes.map(\.id)))
            if let selected = queryDocumentIDs { queryDocumentIDs = selected.intersection(activeDocumentIDs) }
            refreshReadingExperienceIndex()
        }
    }
    func chooseBook() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.pdf, .plainText, .epub, UTType(filenameExtension: "md") ?? .text, UTType(filenameExtension: "markdown") ?? .text]
        if panel.runModal() == .OK, let url = panel.url { importBook(url) }
    }
    func importBook(_ url: URL) { startBookImport(url) }
    func resetWorkflowRetry(_ stepID: String, inBook expectedBookID: String) async {
        guard var current = book, current.id == expectedBookID, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do { try ReadingWorkflowRuntime.resetRetry(stepID: stepID, in: &current); try await repository.save(current); publish(current); activity = "已重置此步骤的重试预算，点击继续分析可重试。" }
        catch { errorMessage = error.localizedDescription }
    }
    var providerReady: Bool {
        if settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errorMessage = "请先在模型设置中填写模型名称与服务地址。"; showingSettings = true; return false }
        return true
    }
    func handle(_ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { activity = "已暂停；从最后一次成功保存的位置继续。" }
        else { errorMessage = error.localizedDescription; activity = "任务暂停，已保存的阅读结果保留。" }
    }
    func saveSettings() {
        do {
            try persistServiceProfile()
            showingSettings = false; activity = "模型配置已保存，密钥保存在系统钥匙串。"
        } catch { errorMessage = error.localizedDescription }
    }
    func newDocument() {
        guard book != nil, !isRecognizingPDF else { return }
        guard !editorDirty else { errorMessage = "请先保存当前文档。"; return }
        documentGeneration += 1; documentError = nil; documentBaseHash = nil
        selectedDocumentID = nil; editorTitle = "新的理解"; editorMarkdown = "# 新的理解\n\n"; draftEvidence = []; editorDirty = true; route = "editor"
    }
    func discardDraftForWorkspaceNavigation() {
        guard !isSavingDocument, let bookID else { return }
        documentGeneration += 1
        editorDirty = false; documentError = nil; documentBaseHash = nil
        selectedDocumentID = nil; editorTitle = ""; editorMarkdown = ""; draftEvidence = []
        UserDefaults.standard.removeObject(forKey: "draft-\(bookID)")
        activity = "未保存修改已放弃；已保存的 Markdown 保留。"
    }
    func discardDraft() {
        guard !isSavingDocument, let bookID else { return }
        documentGeneration += 1; documentError = nil
        let document = book?.activeDocuments.first { $0.id == selectedDocumentID }
        editorDirty = false; documentBaseHash = nil
        UserDefaults.standard.removeObject(forKey: "draft-\(bookID)")
        selectedDocumentID = nil; editorTitle = ""; editorMarkdown = ""; draftEvidence = []
        if let document { Task { await openDocument(document) } }
        activity = "未保存修改已放弃；已保存的文档保留。"
    }
    func openDocument(_ document: DocumentRecord) async {
        guard let current = book else { return }
        guard document.trashedAt == nil else { errorMessage = "文档已在回收站，请先恢复。"; showingTrash = true; return }
        guard !editorDirty else {
            if selectedDocumentID == document.id { route = "editor"; return }
            errorMessage = "请先保存当前文档。"; return
        }
        documentGeneration += 1
        let generation = documentGeneration
        do {
            let snapshot = try await repository.readDocumentSnapshot(bookID: current.id, document: document)
            guard current.id == bookID, generation == documentGeneration, !editorDirty else { return }
            editorMarkdown = snapshot.markdown; documentBaseHash = snapshot.contentHash
            documentError = nil
            editorTitle = document.title; selectedDocumentID = document.id; draftEvidence = document.evidence; editorDirty = false; route = "editor"
            selectedObjectID = document.id; readingContextDocumentID = document.id
        } catch { if current.id == bookID && generation == documentGeneration { errorMessage = error.localizedDescription } }
    }
    func saveCurrentDocument(asNew: Bool = false) async {
        guard var current = book, !isBusy, editorDirty else { return }
        documentError = nil
        let savingBookID = current.id, savingDocumentID = selectedDocumentID
        let savingTitle = editorTitle, savingMarkdown = editorMarkdown, savingEvidence = draftEvidence
        let savingContentHash = SHA256.hash(data: Data(savingMarkdown.utf8)).map { String(format: "%02x", $0) }.joined()
        isBusy = true; isSavingDocument = true; activity = "正在保存 Markdown…"
        defer { isBusy = false; isSavingDocument = false }
        do {
            var document = (asNew ? nil : current.documents.first { $0.id == savingDocumentID }) ?? DocumentRecord(title: savingTitle, linkedIDs: selectedObjectID.map { [$0] } ?? [], evidence: savingEvidence)
            document.title = savingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名笔记" : savingTitle; document.updatedAt = Date()
            if !current.nodes.contains(where: { $0.targetID == document.id || ($0.documentIDs ?? []).contains(document.id) }) {
                let index = current.nodes.count; current.nodes.append(CanvasNode(targetID: document.id, x: Double(index % 3) * 270 + 60, y: Double(index / 3) * 150 + 60))
            }
            current = try await repository.saveDocument(project: current, document: document, markdown: savingMarkdown, expectedContentHash: asNew ? nil : documentBaseHash)
            publish(current)
            let unchanged = bookID == savingBookID && selectedDocumentID == savingDocumentID && editorTitle == savingTitle && editorMarkdown == savingMarkdown && draftEvidence == savingEvidence
            if bookID == savingBookID && selectedDocumentID == savingDocumentID { selectedDocumentID = document.id; documentBaseHash = savingContentHash }
            if unchanged {
                editorDirty = false; UserDefaults.standard.removeObject(forKey: "draft-\(current.id)"); activity = "Markdown 文档已保存。"
            } else {
                editorDirty = true; persistDraft(); activity = "已保存上一版；保存期间的新编辑保留为待保存草稿。"
            }
        } catch { documentError = error.localizedDescription }
    }
    func saveAnswer(_ message: ChatMessage) async {
        guard var current = book, !isBusy else { return }
        do {
            let stableID = "answer-\(message.id)"
            if let existing = current.documents.first(where: { $0.id == stableID }) { await openDocument(existing); return }
            isBusy = true; defer { isBusy = false }
            let question = current.chats.prefix(while: { $0.id != message.id }).last(where: { $0.role == "user" })?.content ?? "与书对话"
            let title = String(question.prefix(60))
            let document = DocumentRecord(id: stableID, title: title, origin: "saved-answer", linkedIDs: selectedObjectID.map { [$0] } ?? [], evidence: message.evidence)
            let index = current.nodes.count; let node = CanvasNode(targetID: document.id, x: Double(index % 3) * 270 + 60, y: Double(index / 3) * 150 + 60)
            let parents = current.nodes.filter { candidate in selectedDocumentID.map { candidate.targetID == $0 || (candidate.documentIDs ?? []).contains($0) } ?? false }
            if let parent = parents.first(where: { renderedSelectedNodeIDs.contains($0.id) }) ?? parents.first { current.edges.append(CanvasEdge(fromID: parent.id, toID: node.id, label: "追问")) }
            current.nodes.append(node)
            let citations = message.evidence.map { "- [\($0.unitID)](readingbook://book/\(current.id)/unit/\($0.unitID))：\($0.quote)" }.joined(separator: "\n")
            let markdown = "# \(title)\n\n## 提问\n\n\(question)\n\n## 回答\n\n\(message.content)\n\n## 原文依据\n\n\(citations)\n\n<!-- conversation-message: \(message.id) -->\n"
            current = try await repository.saveDocument(project: current, document: document, markdown: markdown)
            publish(current); activity = "回答已保存为 Markdown 与导图节点。"
        } catch { errorMessage = error.localizedDescription }
    }
    func ask(_ question: String, allowsOrganizing: Bool = false) {
        guard let current = book, !isBusy, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, providerReady else { return }
        guard question.count <= 4000 else { errorMessage = "问题最多 4000 字，请缩短后再发送；输入内容保留。"; return }
        let context = queryReadingContext
        let scope = queryScope
        let documentIDs = queryDocumentIDs.map { Array($0).sorted() }
        let attachedDocumentIDs = scope == .notes ? [] : queryAttachedDocumentIDs.sorted()
        let authorizedNodeIDs = queryAuthorizedNodeIDs.sorted()
        let snapshot: ReadingQuerySnapshot
        do { snapshot = try ReadingQuerySnapshot.freeze(scope: scope, in: current, context: context, documentIDs: documentIDs,
            appendedDocumentIDs: attachedDocumentIDs, authorizedNodeIDs: authorizedNodeIDs) }
        catch { errorMessage = error.localizedDescription; return }
        let memoryEnabled = queryMemoryEnabled
        let memory = memoryEnabled ? loadQueryMemory(for: snapshot) : nil
        let repository = repository
        var requestSettings = settings
        requestSettings.transportSessionID = "readingbook-" + current.id + "-chat"
        let requestKey = apiKey
        let workspaceSnapshot = makeReadingWorkspaceSnapshot()
        let hostOperationContext = queryHostOperationContext
        let viewTools = readingViewToolAccess(bookID: current.id, sourceHash: current.sourceHash)
        queryAllowsOrganizing = false // A grant belongs to this send, never the next question.
        isBusy = true; activity = "正在读取所选范围并回答…"
        lastQuestionContext = snapshot.displayTitle; queryDisclosure = ""; queryRetryQuestion = nil
        let userMessage = ChatMessage(role: "user", content: question)
        let previousChangeIDs = Set(current.controlledChanges?.receipts.map(\.operationID) ?? [])
        task = Task {
            let aiRunID = await beginAIProgress(title: "回答问题")
            var writeGrant: ControlledWriteGrant?
            defer { finishAIProgress(aiRunID); isBusy = false }
            defer {
                if let grant = writeGrant, !pendingAIChanges.contains(where: { $0.grant.id == grant.id }) {
                    Task { await repository.revokeChangeGrant(grant.id) }
                }
            }
            do {
                // Preserve the exact question before networking; a cancelled or
                // failed answer never discards the reader's input.
                var pending = current; pending.chats.append(userMessage)
                try await repository.save(pending); publish(pending)
                try Task.checkCancellation()
                if allowsOrganizing {
                    writeGrant = try await repository.issueChangeGrant(bookID: current.id, permissions: [.knowledge, .graph, .documents, .bookScheme],
                        allowedUnitIDs: Set(snapshot.unitIDs), editableDocumentIDs: Set(snapshot.documentIDs), requiresReceipts: false,
                        reason: "读者选择本次整理；原问题ID：\(userMessage.id)；摘要：" + String(question.prefix(500)))
                }
                let proposalTools = writeGrant.map { readingProposalAccess(grant: $0, snapshot: snapshot) }
                await reader.resetBudget()
                let answer = try await reader.answerDetailed(question: question, project: current, settings: requestSettings, apiKey: requestKey,
                    readingContext: context, queryScope: scope, history: current.chats, memory: memory, memoryEnabled: memoryEnabled,
                    documentIDs: documentIDs, documentLoader: { document in
                        try Task.checkCancellation()
                        return try await repository.readDocument(bookID: current.id, document: document)
                    }, appendedDocumentIDs: attachedDocumentIDs, authorizedNodeIDs: authorizedNodeIDs,
                    hostOperationContext: hostOperationContext, workspace: workspaceSnapshot, hostTools: viewTools, proposalAccess: proposalTools)
                try Task.checkCancellation()
                guard var result = book, result.id == current.id, result.sourceHash == current.sourceHash,
                      result.chats.map(\.id) == current.chats.map(\.id) + [userMessage.id] else { throw ReadingError.invalid("对话或原书已改变，本次回答未写入其他版本，请重试。") }
                result.chats.append(answer.message)
                markAIProgressSaving(aiRunID)
                try await repository.save(result); publish(result); requestsUsed = await reader.requestCount
                queryDisclosure = ([answer.diagnostics.disclosure] + answer.diagnostics.notices).joined(separator: "\n")
                if memoryEnabled { saveQueryMemory(answer.memory, for: snapshot) }
                activity = "回答已生成；你可以选择保存为 Markdown。"
            } catch {
                finishAIProgress(aiRunID, error: error)
                queryRetryQuestion = question; handle(error)
                let saved = book?.id == current.id ? (book?.controlledChanges?.receipts.filter { !previousChangeIDs.contains($0.operationID) && $0.undoneAt == nil }.count ?? 0) : 0
                if saved > 0 {
                    queryDisclosure = "本次回答尚未完成；已保存 \(saved) 次授权整理，可从权限菜单撤销。原问题与待审阅提案保留。"
                    activity = queryDisclosure
                }
                requestsUsed = await reader.requestCount
            }
        }
    }
    func focus(_ id: String) {
        selectedObjectID = id
        if let event = book?.events.first(where: { $0.id == id }), let year = event.startYear {
            if Double(year) < timeFrom || Double(year) > timeTo { timeFrom = Double(year - 2); timeTo = Double((event.endYear ?? year) + 2) }
        }
    }
    func openObject(_ id: String) {
        if let document = book?.activeDocuments.first(where: { $0.id == id }) { Task { await openDocument(document) } }
        else if let unit = book?.units.first(where: { $0.id == id }) { navigateToUnit(unit.id); route = "reader" }
        else { focus(id) }
    }
    func navigateToUnit(_ id: String) {
        guard book?.units.contains(where: { $0.id == id }) == true else { return }
        pdfNavigationToken += 1
        sourceReadingSelection = nil; focusedReadingAnchorID = nil
        readingContextDocumentID = nil
        selectedUnitID = id
    }
    func follow(_ evidence: Evidence) { followReadingEvidence(evidence) }
    func openInternalURL(_ url: URL) async {
        guard url.scheme == "readingbook" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        let kind: String, id: String
        if url.host == "book", parts.count == 3 {
            let targetBook = parts[0]
            guard books.contains(where: { $0.id == targetBook }) else { errorMessage = "此引用所属的书籍尚未导入当前书库。"; return }
            if bookID != targetBook { await selectBook(targetBook) }
            guard bookID == targetBook else { return }
            kind = parts[1]; id = parts[2]
        } else { kind = url.host ?? ""; id = parts.last ?? "" }
        if kind == "anchor" { focusReadingAnchor(id) }
        else if kind == "unit", let project = book, project.units.contains(where: { $0.id == id }) {
            navigateToUnit(id); route = "reader"
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let quote = query.first(where: { $0.name == "quote" })?.value,
               let anchor = try? ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: id, quote: quote,
                         prefix: query.first(where: { $0.name == "prefix" })?.value ?? "", suffix: query.first(where: { $0.name == "suffix" })?.value ?? "", in: project) {
                if !readingExperienceIndex.anchors.contains(where: { $0.id == anchor.id }) { readingExperienceIndex.anchors.append(anchor) }
                focusedReadingAnchorID = anchor.id
            }
        }
        else if kind == "document", let document = book?.documents.first(where: { $0.id == id }) { await openDocument(document) }
        else { errorMessage = "引用的原文或文档不存在于当前书籍。" }
    }
    func markReviewed(_ unitID: String) async {
        guard var current = book, !isBusy, let index = current.units.firstIndex(where: { $0.id == unitID }) else { return }
        isBusy = true; defer { isBusy = false }
        current.units[index].warning = nil
        if current.units[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var entry = current.coverage[unitID] ?? CoverageEntry(); entry.status = .completed; entry.message = "用户确认此单元为原书空白。"; entry.updatedAt = Date(); current.coverage[unitID] = entry
            let insightID = "blank-\(unitID)"
            current.insights.removeAll { $0.id == "deferred-\(unitID)" && $0.unitIDs == [unitID] }
            if !current.insights.contains(where: { $0.id == insightID }) { current.insights.append(ReadingInsight(id: insightID, unitIDs: [unitID], markdown: "用户对照原书确认此单元为空白，无需 AI 提取文字。")) }
        } else if current.coverage[unitID]?.status == .needsReview {
            let hasAnalysis = ReadingLedger.hasReadingAnalysis(unitID: unitID, in: current)
            current.coverage[unitID]?.status = hasAnalysis ? .completed : .pending
            current.coverage[unitID]?.message = hasAnalysis ? "用户已对照原文核对内容及回执问题。" : "用户已核对源内容，仍待 AI 读取。"
            current.coverage[unitID]?.updatedAt = Date()
            if !hasAnalysis { current.insights.removeAll { $0.id == "deferred-\(unitID)" && $0.unitIDs == [unitID] } }
        }
        current.audit.append(ToolAudit(name: "user_review", summary: "用户核对单元 \(unitID)"))
        do { try await repository.save(current); publish(current) } catch { errorMessage = error.localizedDescription }
    }
    func deferUnit(_ unitID: String) async {
        guard var current = book, !isBusy, let unit = current.units.first(where: { $0.id == unitID }) else { return }
        isBusy = true; defer { isBusy = false }
        var entry = current.coverage[unitID] ?? CoverageEntry(); entry.status = .needsReview; entry.message = "用户保留本单元为待识别，未读取其中内容。"; entry.updatedAt = Date(); current.coverage[unitID] = entry
        let insightID = "deferred-\(unitID)"
        if !current.insights.contains(where: { $0.id == insightID }) { current.insights.append(ReadingInsight(id: insightID, unitIDs: [unitID], markdown: "【未读取，待识别】\(unit.locator)。该单元尚无可靠文本，不得推断其中的事实。")) }
        do { try await repository.save(current); publish(current) } catch { errorMessage = error.localizedDescription }
    }
    func installedComponent(for kind: ComponentKind) -> ViewDefinition? {
        guard let component = WorkspaceComponentRegistry.shared.component(for: kind) else { return nil }
        return installedComponent(for: component)
    }
    func installedComponent(for component: WorkspaceComponentDescriptor) -> ViewDefinition? {
        if component.permanent { return ViewDefinition(id: component.id, title: component.title, kind: component.kind, rendererID: component.rendererID) }
        return enabledViews.first { (component.rendererID != nil || $0.rendererID == nil) && WorkspaceComponentRegistry.shared.equivalent($0, component) }
    }
    func savedComponent(for kind: ComponentKind) -> ViewDefinition? {
        guard let component = WorkspaceComponentRegistry.shared.component(for: kind) else { return nil }
        return savedComponent(for: component)
    }
    func savedComponent(for component: WorkspaceComponentDescriptor) -> ViewDefinition? {
        book?.views.first { (component.rendererID != nil || $0.rendererID == nil) && WorkspaceComponentRegistry.shared.equivalent($0, component) }
    }
    func activate(_ kind: ComponentKind, open: Bool = true, onError: ((String) -> Void)? = nil) {
        guard let component = WorkspaceComponentRegistry.shared.component(for: kind) else { return }
        activate(component, open: open, onError: onError)
    }
    func activate(_ descriptor: WorkspaceComponentDescriptor, open: Bool = true, onError: ((String) -> Void)? = nil) {
        guard var current = book, !isBusy, let component = WorkspaceComponentRegistry.shared.component(id: descriptor.id) else { return }
        if let existing = installedComponent(for: component) { if open { route = existing.id }; return }
        // Disabled packs retain their entries. Every entry point must refuse a
        // second equivalent view, even when the saved ID is not "manual-*".
        if savedComponent(for: component) != nil {
            let message = "此组件已由停用的声明包保存，请在插件页启用该包。"
            if let onError { onError(message) } else { errorMessage = message }; return
        }
        let view = ViewDefinition(id: "manual-\(component.id)", title: component.title, kind: component.kind, rendererID: component.rendererID, scope: "current")
        guard !current.views.contains(where: { $0.id == view.id }) else {
            let message = "同名组件入口由已停用声明包保留，请先启用该包。"
            if let onError { onError(message) } else { errorMessage = message }; return
        }
        current.views.append(view); isBusy = true
        Task {
            defer { isBusy = false }
            do { try await repository.save(current); publish(current); if open, bookID == current.id { route = view.id }; activity = "已添加\(component.title)。" }
            catch { if let onError { onError(error.localizedDescription) } else { errorMessage = error.localizedDescription } }
        }
    }
    func importPlugin(onError: ((String) -> Void)? = nil) {
        previewImportPlugin(onError: onError)
    }
    func exportProject() {
        guard let current = book, !isBusy else { return }
        guard !editorDirty else { errorMessage = "请先保存或放弃当前 Markdown 草稿，再导出完整书项目。"; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(current.title).readingbook"; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            isBusy = true; isExportingProject = true
            Task { defer { isBusy = false; isExportingProject = false }; do { try await repository.exportProject(current, to: url); activity = "书项目及 Markdown 已导出。" } catch { errorMessage = error.localizedDescription } }
        }
    }
    func importProject() {
        guard !isBusy else { return }
        guard !editorDirty else { errorMessage = "请先保存或放弃当前 Markdown 草稿，再导入书项目。"; return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            isBusy = true; isImportingBookCommit = true; activity = "正在验证并导入书项目…"
            task = Task {
                do {
                    let current = try await repository.importProject(from: url); publish(current)
                    isImportingBookCommit = false; isBusy = false
                    activity = "书项目已导入；原书与用户 Markdown 已保留。"
                    await selectBook(current.id, preferredRoute: "reader")
                } catch { isImportingBookCommit = false; isBusy = false; errorMessage = error.localizedDescription }
            }
        }
    }
    func exportMarkdown() {
        guard let current = book, let document = current.documents.first(where: { $0.id == selectedDocumentID }) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(document.title).md"
        if panel.runModal() == .OK, let url = panel.url {
            Task { do { let content = try await repository.readDocument(bookID: current.id, document: document); try content.write(to: url, atomically: true, encoding: .utf8) } catch { errorMessage = error.localizedDescription } }
        }
    }
    func newNote(for unit: SourceUnit) {
        guard !isRecognizingPDF else { return }
        guard !editorDirty else { errorMessage = "请先保存当前文档。"; return }
        selectedObjectID = unit.id; newDocument(); editorTitle = "关于\(unit.chapter)的理解"
        let quote = String(unit.text.prefix(240))
        draftEvidence = quote.isEmpty ? [] : [Evidence(unitID: unit.id, quote: quote)]
        // Source evidence remains attached and can be opened from the note header.
        // Start with a clean writing surface; never rewrite an existing note.
        editorMarkdown = "# \(editorTitle)\n\n"
    }
    func saveInsight(_ insight: ReadingInsight) async {
        guard var current = book, !isBusy else { return }
        let id = "insight-\(insight.id)"
        if let existing = current.documents.first(where: { $0.id == id }) { await openDocument(existing); return }
        isBusy = true; defer { isBusy = false }
        let title = "阅读笔记 · \(current.units.first { insight.unitIDs.contains($0.id) }?.chapter ?? current.title)"
        let evidence = insight.unitIDs.compactMap { id -> Evidence? in guard let unit = current.units.first(where: { $0.id == id }), !unit.text.isEmpty else { return nil }; return Evidence(unitID: id, quote: String(unit.text.prefix(180))) }
        let document = DocumentRecord(id: id, title: title, origin: "saved-analysis", linkedIDs: insight.unitIDs, evidence: evidence)
        let index = current.nodes.count; current.nodes.append(CanvasNode(targetID: id, x: Double(index % 3) * 270 + 60, y: Double(index / 3) * 150 + 60))
        do { current = try await repository.saveDocument(project: current, document: document, markdown: "# \(title)\n\n\(insight.markdown)\n"); publish(current); activity = "分析已由你保存为 Markdown 文档。" } catch { errorMessage = error.localizedDescription }
    }
    func toggleBookmark(_ unitID: String) async {
        guard var current = book, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        if current.bookmarks.contains(unitID) { current.bookmarks.removeAll { $0 == unitID } } else { current.bookmarks.append(unitID) }
        do { try await repository.save(current); publish(current) } catch { errorMessage = error.localizedDescription }
    }
    @discardableResult
    func moveNode(id: String, x: Double, y: Double, onError: ((String) -> Void)? = nil) async -> Bool {
        func fail(_ message: String) -> Bool { if let onError { onError(message) } else { errorMessage = message }; return false }
        guard var current = book else { return fail("请先打开书籍，再移动画布节点。") }
        guard !isBusy else { return fail("当前任务尚未结束，请稍后移动节点。") }
        guard x.isFinite, y.isFinite, let index = current.nodes.firstIndex(where: { $0.id == id }) else { return fail("画布节点已移除，或坐标无效，请重新选择节点。") }
        isBusy = true; defer { isBusy = false }
        current.nodes[index].x = x; current.nodes[index].y = y
        do { try await repository.save(current); publish(current); return true } catch { return fail(error.localizedDescription) }
    }
    @discardableResult
    func connectNodes(from: String, to: String, label: String, onError: ((String) -> Void)? = nil) async -> Bool {
        func fail(_ message: String) -> Bool { if let onError { onError(message) } else { errorMessage = message }; return false }
        guard let current = book else { return fail("请先打开书籍，再连接画布节点。") }
        guard !isBusy else { return fail("当前任务尚未结束，请稍后连接节点。") }
        isBusy = true; defer { isBusy = false }
        do {
            let connected = try GraphConnections.connecting(from: from, to: to, label: label, in: current)
            guard connected.edges.count != current.edges.count else { activity = "这两个画布节点之间已有同名关系。"; return true }
            try await repository.save(connected)
            publish(connected)
            activity = "画布节点已连接。"
            return true
        } catch { return fail(error.localizedDescription) }
    }
    @discardableResult
    func renameCanvasEdge(id: String, label: String, onError: ((String) -> Void)? = nil) async -> Bool {
        func fail(_ message: String) -> Bool { if let onError { onError(message) } else { errorMessage = message }; return false }
        guard let current = book else { return fail("请先打开书籍，再修改连线关系。") }
        guard !isBusy else { return fail("当前任务尚未结束，请稍后修改连线。") }
        isBusy = true; defer { isBusy = false }
        do {
            let renamed = try GraphConnections.renaming(edgeID: id, label: label, in: current)
            guard renamed.edges != current.edges else { return true }
            try await repository.save(renamed)
            publish(renamed)
            activity = "连线关系已改名。"
            return true
        } catch { return fail(error.localizedDescription) }
    }
    @discardableResult
    func setPluginEnabled(_ enabled: Bool, id: String, onError: ((String) -> Void)? = nil) async -> Bool {
        guard var current = book, !isBusy else { return false }
        isBusy = true; defer { isBusy = false }
        do { try PluginEngine.setEnabled(enabled, pluginID: id, in: &current); try await repository.save(current); publish(current); return true }
        catch { if let onError { onError(error.localizedDescription) } else { errorMessage = error.localizedDescription }; return false }
    }
    @discardableResult
    func saveEntity(_ entity: KnowledgeEntity, inBook expectedBookID: String? = nil, onError: ((String) -> Void)? = nil) async -> Bool {
        func fail(_ message: String) -> Bool { if let onError { onError(message) } else { errorMessage = message }; return false }
        guard var current = book, expectedBookID == nil || current.id == expectedBookID else { return fail("书籍已切换，编辑草稿保留，请回到原书保存。") }
        guard !isBusy, let index = current.entities.firstIndex(where: { $0.id == entity.id }) else { return fail("当前任务尚未完成，或卡片已被移除。") }
        guard !entity.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fail("名称不能为空。") }
        guard (entity.latitude == nil) == (entity.longitude == nil) else { return fail("经度和纬度需要同时填写，或同时留空。") }
        if let latitude = entity.latitude, !latitude.isFinite || !(-90...90).contains(latitude) { return fail("纬度应在 -90 到 90 之间。") }
        if let longitude = entity.longitude, !longitude.isFinite || !(-180...180).contains(longitude) { return fail("经度应在 -180 到 180 之间。") }
        guard let type = current.types.first(where: { $0.id == entity.typeID }), type.fields.filter(\.required).allSatisfy({ entity.properties[$0.key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else { return fail("请选择已有类型，并填写该类型的必填字段。") }
        isBusy = true; defer { isBusy = false }
        var edited = entity
        if edited.latitude != nil, (edited.latitude != current.entities[index].latitude || edited.longitude != current.entities[index].longitude), edited.locationNote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { edited.locationNote = "用户手动指定坐标；尚未作外部考证。" }
        current.entities[index] = edited; current.audit.append(ToolAudit(name: "user_edit", summary: "用户编辑卡片：\(entity.name)"))
        do { try await repository.save(current); publish(current); return true } catch { return fail(error.localizedDescription) }
    }
    var enabledViews: [ViewDefinition] {
        guard let current = book else { return [] }
        let disabled = Set(current.plugins.filter { current.disabledPluginIDs.contains($0.id) }.flatMap { $0.views.map(\.id) })
        return current.views.filter { !disabled.contains($0.id) }
    }
    private struct DocumentDraft: Codable { var documentID: String?; var title: String; var markdown: String; var evidence: [Evidence]; var baseHash: String? = nil }
    private func persistDraft() {
        guard let bookID, editorDirty else { return }
        draftSaveTask?.cancel()
        let generation = documentGeneration
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.bookID == bookID, self.documentGeneration == generation else { return }
            self.flushDocumentDraft()
        }
    }
    func flushDocumentDraft() {
        draftSaveTask?.cancel(); draftSaveTask = nil
        guard let bookID, editorDirty else { return }
        let draft = DocumentDraft(documentID: selectedDocumentID, title: editorTitle, markdown: editorMarkdown, evidence: draftEvidence, baseHash: documentBaseHash)
        if let data = try? JSONEncoder().encode(draft) { UserDefaults.standard.set(data, forKey: "draft-\(bookID)") }
    }
    private func restoreDraft() {
        guard let bookID, let data = UserDefaults.standard.data(forKey: "draft-\(bookID)"), let draft = try? JSONDecoder().decode(DocumentDraft.self, from: data) else { return }
        selectedDocumentID = book?.activeDocuments.contains(where: { $0.id == draft.documentID }) == true ? draft.documentID : nil
        documentBaseHash = selectedDocumentID == nil ? nil : draft.baseHash
        editorTitle = draft.title; editorMarkdown = draft.markdown; draftEvidence = draft.evidence; editorDirty = true; route = "editor"; activity = "已恢复上次尚未保存的文档草稿。"
    }
    func libraryLoadIssueSummary(_ issues: [LibraryLoadIssue]) -> String {
        "有 \(issues.count) 个目录未载入，其他书籍仍可使用；原文件保留。\n" + issues.prefix(8).map { "\($0.folder)：\($0.message)" }.joined(separator: "\n")
    }
    func objectTitle(_ id: String) -> String { book?.entities.first { $0.id == id }?.name ?? book?.events.first { $0.id == id }?.name ?? book?.documents.first { $0.id == id }?.title ?? id }
}

enum Keychain {
    static let service = "org.readingbook.provider"
    static func read(account: String = "api-key") throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8) else { throw ReadingError.invalid("钥匙串读取失败（\(status)）。") }; return text
    }
    static func write(_ value: String, account: String = "api-key") throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { var addition = query; addition[kSecValueData as String] = Data(value.utf8); status = SecItemAdd(addition as CFDictionary, nil) }
        guard status == errSecSuccess else { throw ReadingError.invalid("钥匙串保存失败（\(status)）。") }
    }
    static func remove(account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ReadingError.invalid("钥匙串删除失败（\(status)）。") }
    }
}
