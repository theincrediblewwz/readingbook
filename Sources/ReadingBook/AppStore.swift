import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Security
import ReadingCore

@MainActor final class AppStore: ObservableObject {
    @Published var books: [BookProject] = []
    @Published var bookID: String?
    @Published var route = "reader"
    @Published var selectedObjectID: String?
    @Published var selectedUnitID: String? {
        didSet { if let bookID, let selectedUnitID { UserDefaults.standard.set(selectedUnitID, forKey: "position-\(bookID)") } }
    }
    @Published var pdfNavigationToken = 0
    @Published var activeReadingUnitID: String?
    @Published var search = ""
    @Published var selectedDocumentID: String?
    @Published var editorTitle = "" { didSet { if editorDirty { persistDraft() } } }
    @Published var editorMarkdown = "" { didSet { if editorDirty { persistDraft() } } }
    @Published var editorDirty = false { didSet { if editorDirty { persistDraft() } } }
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
    @Published var deletionRequest: WorkspaceDeletion?
    @Published var settings = ProviderSettings()
    @Published var apiKey = ""
    @Published var requestsUsed = 0
    @Published var timeFrom = -5000.0
    @Published var timeTo = 3000.0
    @Published var showUndated = true
    let repository: LibraryRepository
    let reader = AIReader()
    let pdfOCRReader = PDFOCRReader()
    private var loaded = false
    private var navigationGeneration = 0
    private var documentGeneration = 0
    var task: Task<Void, Never>?
    var book: BookProject? { books.first { $0.id == bookID } }
    var selectedUnit: SourceUnit? { book?.units.first { $0.id == selectedUnitID } }
    var visibleEvents: [KnowledgeEvent] {
        (book?.events ?? []).filter {
            guard let year = $0.startYear else { return showUndated }
            return Double($0.endYear ?? year) >= timeFrom && Double(year) <= timeTo
        }.sorted { ($0.startYear ?? Int.max) < ($1.startYear ?? Int.max) }
    }
    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReadingBook", isDirectory: true)
        repository = LibraryRepository(rootURL: root)
        if let data = UserDefaults.standard.data(forKey: "provider"), let saved = try? JSONDecoder().decode(ProviderSettings.self, from: data) { settings = saved }
        loadServiceProfiles()
    }
    func load() async {
        guard !loaded else { return }; loaded = true
        do { books = try await repository.loadAll(); if let first = books.first { await selectBook(first.id) } }
        catch { errorMessage = "书库读取失败，原文件已保留：\(error.localizedDescription)" }
    }
    func selectBook(_ id: String) async {
        guard !isBusy else { return }
        guard !editorDirty else { errorMessage = "请先保存当前文档，再切换书籍。"; return }
        navigationGeneration += 1; documentGeneration += 1
        pdfNavigationToken += 1
        pdfPasswordRequest = nil
        let generation = navigationGeneration
        bookID = id; route = "reader"; sourceFileURL = nil; selectedObjectID = nil; selectedDocumentID = nil; activeReadingUnitID = nil; editorMarkdown = ""; editorTitle = ""; draftEvidence = []
        selectedUnitID = UserDefaults.standard.string(forKey: "position-\(id)") ?? book?.lastUnitID ?? book?.units.first?.id
        if book?.units.contains(where: { $0.id == selectedUnitID }) != true { selectedUnitID = book?.units.first?.id }
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
    }
    func publish(_ project: BookProject) {
        if let index = books.firstIndex(where: { $0.id == project.id }) { books[index] = project }
        else { books.insert(project, at: 0) }
    }
    func chooseBook() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.pdf, .plainText, .epub, UTType(filenameExtension: "md") ?? .text, UTType(filenameExtension: "markdown") ?? .text]
        if panel.runModal() == .OK, let url = panel.url { importBook(url) }
    }
    func importBook(_ url: URL) { startBookImport(url) }
    func makePlan() {
        guard let project = book, !isBusy, providerReady else { return }
        guard !requiresPDFRecognition else { showingOCR = true; activity = "请先识别扫描页，或在对照原页后确认空白内容。"; return }
        isBusy = true; activity = "AI 正在预读与选择方法、类型和组件…"
        task = Task {
            do {
                await reader.resetBudget()
                let result = try await reader.plan(project: project, settings: settings, apiKey: apiKey)
                try Task.checkCancellation(); try await repository.save(result); publish(result)
                requestsUsed = await reader.requestCount; route = "workflow"; activity = "预读计划已保存；全文覆盖尚未增加。"
            } catch { handle(error) }
            isBusy = false
        }
    }
    func startReading() {
        guard book != nil, !isBusy, providerReady else { return }
        guard !requiresPDFRecognition else { showingOCR = true; activity = "扫描页尚未识别；请先 OCR，避免把空提取结果当成已读。"; return }
        isBusy = true; activity = "准备顺序精读…"
        task = Task {
            await reader.resetBudget()
            do {
                if let current = book, current.plan == nil {
                    let planned = try await reader.plan(project: current, settings: settings, apiKey: apiKey)
                    try Task.checkCancellation(); try await repository.save(planned); publish(planned)
                }
                while let current = book {
                    try Task.checkCancellation()
                    let pending = current.units.first { unit in
                        let status = current.coverage[unit.id]?.status ?? .pending
                        return !ReadingLedger.isDeferred(unitID: unit.id, in: current) && status != .completed && !(status == .needsReview && ReadingLedger.hasReadingAnalysis(unitID: unit.id, in: current))
                    }
                    guard let unit = pending else { break }
                    activity = "正在精读：\(unit.locator)"
                    activeReadingUnitID = unit.id
                    let result = try await reader.readNext(project: current, settings: settings, apiKey: apiKey)
                    try Task.checkCancellation(); try await repository.save(result); publish(result)
                    requestsUsed = await reader.requestCount
                }
                while let current = book, !(await reader.synthesisComplete(project: current)) {
                    try Task.checkCancellation(); activity = "正在做章节复盘与全书综合…"
                    let result = try await reader.synthesizeNext(project: current, settings: settings, apiKey: apiKey)
                    try Task.checkCancellation(); try await repository.save(result); publish(result); requestsUsed = await reader.requestCount
                }
                if let current = book { activity = current.isFullyProcessed ? "全部登记单元已处理并通过核对。" : "本轮顺序处理结束，仍有 \(current.reviewCount) 个单元待核对。" }
            } catch { handle(error) }
            requestsUsed = await reader.requestCount; isBusy = false
        }
    }
    func pause() { guard !isSavingDocument, !isExportingProject, !isImportingBookCommit, !isCommittingLocalWrite else { return }; task?.cancel(); activity = "正在暂停，已保存结果可以继续阅读。" }
    private var requiresPDFRecognition: Bool {
        guard let book, book.originalName.lowercased().hasSuffix(".pdf") else { return false }
        return book.units.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (book.coverage[$0.id]?.status ?? .pending) == .pending }
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
        documentGeneration += 1
        selectedDocumentID = nil; editorTitle = "新的理解"; editorMarkdown = "# 新的理解\n\n"; draftEvidence = []; editorDirty = true; route = "editor"
    }
    func discardDraft() {
        guard !isSavingDocument, let bookID else { return }
        documentGeneration += 1
        let document = book?.activeDocuments.first { $0.id == selectedDocumentID }
        editorDirty = false
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
            let markdown = try await repository.readDocument(bookID: current.id, document: document)
            guard current.id == bookID, generation == documentGeneration, !editorDirty else { return }
            editorMarkdown = markdown
            editorTitle = document.title; selectedDocumentID = document.id; draftEvidence = document.evidence; editorDirty = false; route = "editor"
            selectedObjectID = document.id
        } catch { if current.id == bookID && generation == documentGeneration { errorMessage = error.localizedDescription } }
    }
    func saveCurrentDocument() async {
        guard var current = book, !isBusy, editorDirty else { return }
        let savingBookID = current.id, savingDocumentID = selectedDocumentID
        let savingTitle = editorTitle, savingMarkdown = editorMarkdown, savingEvidence = draftEvidence
        isBusy = true; isSavingDocument = true; activity = "正在保存 Markdown…"
        defer { isBusy = false; isSavingDocument = false }
        do {
            var document = current.documents.first { $0.id == savingDocumentID } ?? DocumentRecord(title: savingTitle, linkedIDs: selectedObjectID.map { [$0] } ?? [], evidence: savingEvidence)
            document.title = savingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名笔记" : savingTitle; document.updatedAt = Date()
            if !current.nodes.contains(where: { $0.targetID == document.id }) {
                let index = current.nodes.count; current.nodes.append(CanvasNode(targetID: document.id, x: Double(index % 3) * 270 + 60, y: Double(index / 3) * 150 + 60))
            }
            current = try await repository.saveDocument(project: current, document: document, markdown: savingMarkdown)
            publish(current)
            let unchanged = bookID == savingBookID && selectedDocumentID == savingDocumentID && editorTitle == savingTitle && editorMarkdown == savingMarkdown && draftEvidence == savingEvidence
            if bookID == savingBookID && selectedDocumentID == savingDocumentID { selectedDocumentID = document.id }
            if unchanged {
                editorDirty = false; UserDefaults.standard.removeObject(forKey: "draft-\(current.id)"); activity = "Markdown 文档已保存。"
            } else {
                editorDirty = true; persistDraft(); activity = "已保存上一版；保存期间的新编辑保留为待保存草稿。"
            }
        } catch { errorMessage = error.localizedDescription }
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
            if let parent = current.nodes.first(where: { $0.targetID == selectedDocumentID }) { current.edges.append(CanvasEdge(fromID: parent.id, toID: node.id, label: "追问")) }
            current.nodes.append(node)
            let citations = message.evidence.map { "- [\($0.unitID)](readingbook://book/\(current.id)/unit/\($0.unitID))：\($0.quote)" }.joined(separator: "\n")
            let markdown = "# \(title)\n\n## 提问\n\n\(question)\n\n## 回答\n\n\(message.content)\n\n## 原文依据\n\n\(citations)\n\n<!-- conversation-message: \(message.id) -->\n"
            current = try await repository.saveDocument(project: current, document: document, markdown: markdown)
            publish(current); activity = "回答已保存为 Markdown 与导图节点。"
        } catch { errorMessage = error.localizedDescription }
    }
    func ask(_ question: String) {
        guard let current = book, !isBusy, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, providerReady else { return }
        isBusy = true; activity = "正在从原文检索依据并回答…"
        task = Task {
            do {
                await reader.resetBudget()
                var documents: [String: String] = [:]
                var remaining = 200_000
                for document in current.activeDocuments {
                    let content = try await repository.readDocument(bookID: current.id, document: document)
                    let bounded = String(content.prefix(max(0, remaining)))
                    documents[document.id] = bounded; remaining -= bounded.count
                    if remaining <= 0 { break }
                }
                let reply = try await reader.answer(question: question, project: current, settings: settings, apiKey: apiKey, documents: documents)
                try Task.checkCancellation()
                var result = current; result.chats.append(ChatMessage(role: "user", content: question)); result.chats.append(reply)
                try await repository.save(result); publish(result); requestsUsed = await reader.requestCount
                activity = "回答已生成；你可以选择保存为 Markdown。"
            } catch { handle(error) }
            isBusy = false
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
        selectedUnitID = id
    }
    func follow(_ evidence: Evidence) { navigateToUnit(evidence.unitID); route = "reader" }
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
        if kind == "unit", book?.units.contains(where: { $0.id == id }) == true { navigateToUnit(id); route = "reader" }
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
    func activate(_ kind: ComponentKind) {
        guard var current = book, !isBusy else { return }
        let id = "manual-\(kind.rawValue)"
        isBusy = true
        if !current.views.contains(where: { $0.id == id || $0.kind == kind }) { current.views.append(ViewDefinition(id: id, title: kind.title, kind: kind)) }
        publish(current); route = current.views.first { $0.kind == kind }?.id ?? kind.rawValue
        Task { defer { isBusy = false }; do { try await repository.save(current) } catch { errorMessage = error.localizedDescription } }
    }
    func importPlugin() {
        guard var current = book, !isBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.message = "选择声明式插件 manifest.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url); guard data.count <= 1_000_000 else { throw ReadingError.invalid("插件包超过 1 MB。") }
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data); try PluginEngine.install(manifest, into: &current)
            isBusy = true; publish(current); Task { defer { isBusy = false }; do { try await repository.save(current) } catch { errorMessage = error.localizedDescription } }
        } catch { errorMessage = error.localizedDescription }
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
            Task { do { let current = try await repository.importProject(from: url); publish(current); await selectBook(current.id) } catch { errorMessage = error.localizedDescription } }
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
        editorMarkdown = "# \(editorTitle)\n\n> \(quote.replacingOccurrences(of: "\n", with: "\n> "))\n\n[回到原文](readingbook://book/\(bookID ?? "")/unit/\(unit.id))\n\n## 我的理解\n\n"
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
    func moveNode(id: String, x: Double, y: Double) async -> Bool {
        guard var current = book else { errorMessage = "请先打开书籍，再移动画布节点。"; return false }
        guard !isBusy else { errorMessage = "当前任务尚未结束，请稍后移动节点。"; return false }
        guard let index = current.nodes.firstIndex(where: { $0.id == id }) else { errorMessage = "画布节点已移除或不存在，请重新选择节点。"; return false }
        isBusy = true; defer { isBusy = false }
        current.nodes[index].x = x; current.nodes[index].y = y
        do { try await repository.save(current); publish(current); return true } catch { errorMessage = error.localizedDescription; return false }
    }
    @discardableResult
    func connectNodes(from: String, to: String, label: String) async -> Bool {
        guard let current = book else { errorMessage = "请先打开书籍，再连接画布节点。"; return false }
        guard !isBusy else { errorMessage = "当前任务尚未结束，请稍后连接节点。"; return false }
        isBusy = true; defer { isBusy = false }
        do {
            let connected = try GraphConnections.connecting(from: from, to: to, label: label, in: current)
            guard connected.edges.count != current.edges.count else { activity = "这两个画布节点之间已有同名关系。"; return true }
            try await repository.save(connected)
            publish(connected)
            activity = "画布节点已连接。"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    @discardableResult
    func renameCanvasEdge(id: String, label: String) async -> Bool {
        guard let current = book else { errorMessage = "请先打开书籍，再修改连线关系。"; return false }
        guard !isBusy else { errorMessage = "当前任务尚未结束，请稍后修改连线。"; return false }
        isBusy = true; defer { isBusy = false }
        do {
            let renamed = try GraphConnections.renaming(edgeID: id, label: label, in: current)
            guard renamed.edges != current.edges else { return true }
            try await repository.save(renamed)
            publish(renamed)
            activity = "连线关系已改名。"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func setPluginEnabled(_ enabled: Bool, id: String) async {
        guard var current = book, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do { try PluginEngine.setEnabled(enabled, pluginID: id, in: &current); try await repository.save(current); publish(current) } catch { errorMessage = error.localizedDescription }
    }
    func saveEntity(_ entity: KnowledgeEntity) async {
        guard var current = book, !isBusy, let index = current.entities.firstIndex(where: { $0.id == entity.id }) else { return }
        guard !entity.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "名称不能为空。"; return }
        guard (entity.latitude == nil) == (entity.longitude == nil) else { errorMessage = "经度和纬度需要同时填写，或同时留空。"; return }
        if let latitude = entity.latitude, !latitude.isFinite || !(-90...90).contains(latitude) { errorMessage = "纬度应在 -90 到 90 之间。"; return }
        if let longitude = entity.longitude, !longitude.isFinite || !(-180...180).contains(longitude) { errorMessage = "经度应在 -180 到 180 之间。"; return }
        isBusy = true; defer { isBusy = false }
        var edited = entity
        if edited.latitude != nil, (edited.latitude != current.entities[index].latitude || edited.longitude != current.entities[index].longitude), edited.locationNote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { edited.locationNote = "用户手动指定坐标；尚未作外部考证。" }
        current.entities[index] = edited; current.audit.append(ToolAudit(name: "user_edit", summary: "用户编辑卡片：\(entity.name)"))
        do { try await repository.save(current); publish(current) } catch { errorMessage = error.localizedDescription }
    }
    var enabledViews: [ViewDefinition] {
        guard let current = book else { return [] }
        let disabled = Set(current.plugins.filter { current.disabledPluginIDs.contains($0.id) }.flatMap { $0.views.map(\.id) })
        return current.views.filter { !disabled.contains($0.id) }
    }
    private struct DocumentDraft: Codable { var documentID: String?; var title: String; var markdown: String; var evidence: [Evidence] }
    private func persistDraft() {
        guard let bookID, editorDirty else { return }
        let draft = DocumentDraft(documentID: selectedDocumentID, title: editorTitle, markdown: editorMarkdown, evidence: draftEvidence)
        if let data = try? JSONEncoder().encode(draft) { UserDefaults.standard.set(data, forKey: "draft-\(bookID)") }
    }
    private func restoreDraft() {
        guard let bookID, let data = UserDefaults.standard.data(forKey: "draft-\(bookID)"), let draft = try? JSONDecoder().decode(DocumentDraft.self, from: data) else { return }
        selectedDocumentID = book?.activeDocuments.contains(where: { $0.id == draft.documentID }) == true ? draft.documentID : nil
        editorTitle = draft.title; editorMarkdown = draft.markdown; draftEvidence = draft.evidence; editorDirty = true; route = "editor"; activity = "已恢复上次尚未保存的文档草稿。"
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
