import AppKit
import Foundation
import Darwin
@testable import ReadingBook
@testable import ReadingCore

/// Real Debug AppStore objects, no window or socket: production AIReaders use
/// one shared coordinator with a deterministic, independently gated transport.
private actor OfflineConcurrentTransport {
    private struct Waiter { let kind: String; let continuation: CheckedContinuation<Void, Error> }
    private var waiters: [UUID: Waiter] = [:]
    private var heldKinds: Set<String> = ["companion"]
    private(set) var companionStarts = 0
    private(set) var chatStarts = 0
    private(set) var planStarts = 0
    private(set) var connectionStarts = 0
    private var callNumber = 0
    func hold(_ kind: String) { heldKinds.insert(kind) }
    func release(_ kind: String) {
        heldKinds.remove(kind)
        for (id, waiter) in waiters.filter({ $0.value.kind == kind }) {
            waiters.removeValue(forKey: id); waiter.continuation.resume()
        }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
    private func wait(_ kind: String) async throws {
        guard heldKinds.contains(kind) else { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[id] = Waiter(kind: kind, continuation: continuation)
            }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    func probeConnection(_ settings: ProviderSettings, _ key: String) async throws -> String {
        guard URL(string: settings.baseURL)?.host == "127.0.0.1", key.isEmpty else {
            throw ReadingError.invalid("连接探针只能使用无密钥的本地fixture。")
        }
        connectionStarts += 1
        try await wait("connection"); try Task.checkCancellation()
        return "离线连接正常：" + settings.model
    }
    func perform(_ prepared: ProviderClient.Prepared) async throws -> ProviderClient.Result {
        guard prepared.request.url?.host == "127.0.0.1", let body = prepared.request.httpBody,
              let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ReadingError.invalid("离线探针收到非fixture请求。")
        }
        let tools = payload["tools"] as? [[String: Any]] ?? []
        let planning = tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "reading_plan" }
        let companion = tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "reading_enrich" }
        callNumber += 1
        let call = callNumber
        if planning {
            planStarts += 1
            try await wait("planning"); try Task.checkCancellation()
            throw ReadingError.invalid("离线fixture：模拟重新预读响应失败。")
        }
        if companion {
            companionStarts += 1
            let generation = companionStarts
            try await wait("companion"); try Task.checkCancellation()
            let arguments: [String: Any] = ["anchors": [["id": "focus", "unitID": "u1", "quote": "刘备在此。"]],
                "layers": [["id": "companion-layer-\(generation)", "kind": "explanation", "title": "离线伴读\(generation)",
                    "markdown": "本句说刘备在这里。", "sourceAnchorIDs": ["focus"], "sourceLabel": "AI"]]]
            return try toolResult("reading_enrich", arguments: arguments, id: "companion-\(call)")
        }
        chatStarts += 1
        let index = chatStarts
        try await wait("chat"); try Task.checkCancellation()
        if index.isMultiple(of: 2) {
            return ProviderClient.Result(message: .init(role: "assistant", content: "原文说“刘备在此”。[unit:u1]", refusal: nil,
                tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 10)
        }
        return try toolResult("source_read", arguments: ["id": "u1"], id: "chat-read-\(call)")
    }
    private func toolResult(_ name: String, arguments: [String: Any], id: String) throws -> ProviderClient.Result {
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        return ProviderClient.Result(message: .init(role: "assistant", content: nil, refusal: nil,
            tool_calls: [.init(id: id, type: "function", function: .init(name: name, arguments: encoded))], reasoning_content: nil),
            finishReason: "tool_calls", tokenCost: 10)
    }
}

@main struct AIConcurrencyProbe {
    @MainActor static func main() async {
        var result: [String: Any] = ["status": "failed", "realNetworkRequests": 0]
        var output: URL?
        do {
            guard CommandLine.arguments.count == 3 else { throw ReadingError.invalid("用法：ai-concurrency-probe WORKSPACE OUTPUT_DIRECTORY") }
            let workspace = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
            let destination = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Package.swift").path),
                  destination.pathComponents.starts(with: workspace.pathComponents), destination != workspace,
                  Bundle.main.bundleIdentifier != "org.readingbook.app" else { throw ReadingError.invalid("探针只允许工作目录内的独立输出路径。") }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            output = destination
            UserDefaults.standard.setVolatileDomain(["library.root.path.v1": destination.appendingPathComponent("library").path,
                "service-profiles": Data("[]".utf8), "query-memory-enabled": false, "reading.hoverTranslation": false], forName: UserDefaults.argumentDomain)
            defer {
                let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
                if domain != "org.readingbook.app" { UserDefaults.standard.removePersistentDomain(forName: domain) }
            }
            result.merge(try await run(in: destination)) { _, value in value }
            result["status"] = "passed"
        } catch { result["error"] = error.localizedDescription }
        if let output, let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: output.appendingPathComponent("result.json"), options: .atomic)
        }
        print(String(decoding: (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data(), as: UTF8.self))
        exit(result["status"] as? String == "passed" ? 0 : 1)
    }
    @MainActor private static func waitUntil(_ description: String, _ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ReadingError.invalid("离线并发探针超时：" + description)
    }
    private static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw ReadingError.invalid(message) }
    }
    @MainActor private static func run(in directory: URL) async throws -> [String: Any] {
        let source = directory.appendingPathComponent("fixture.txt"), sourceBytes = Data("刘备在此。".utf8)
        try sourceBytes.write(to: source)
        var project = BookProject(title: "离线并发书", originalName: "fixture.txt", sourceHash: try BookImporter.sha256(sourceBytes),
            units: [SourceUnit(id: "u1", order: 0, chapter: "第一章", page: 1, text: "刘备在此。")])
        PluginEngine.seed(&project); project.plan = ReadingPlan(methodIDs: ["genre.history"])
        project.plan?.recommendedParallelism = 1
        let paragraphs = try ReadingLedger.paragraphs(for: project.units[0], in: project)
        project.receiptBatch = try ReadingLedger.makeBatch(unit: project.units[0], paragraphs: paragraphs)
        let arguments: [String: Any] = ["batchID": project.receiptBatch!.id, "receipts": paragraphs.map { paragraph in
            ["paragraphID": paragraph.id, "textHash": paragraph.textHash, "summary": "刘备在这里。",
                "startQuote": paragraph.startQuote, "endQuote": paragraph.endQuote, "issues": []] as [String: Any]
        }]
        _ = try PluginEngine.apply(name: "read_receipt", arguments: JSONSerialization.data(withJSONObject: arguments), to: &project, allowedUnitIDs: ["u1"])
        project.receiptBatch = nil
        let owner = LibraryRepository(rootURL: directory.appendingPathComponent("library"))
        project = try await owner.create(project, sourceURL: source)
        let note = DocumentRecord(id: "my-note", title: "保留的用户笔记"), noteBody = "# 我的笔记\n\n保留 e\u{301}、🙂 和 $x^2$。\n"
        project = try await owner.saveDocument(project: project, document: note, markdown: noteBody)
        let transport = OfflineConcurrentTransport()
        let coordinator = AIRequestCoordinator(transport: { try await transport.perform($0) })
        let store = AppStore(sharedAIRequests: coordinator)
        store.repository = owner; store.libraryRootURL = directory.appendingPathComponent("library")
        store.books = [project]; store.bookID = project.id; store.selectedUnitID = "u1"
        store.settings = ProviderSettings(baseURL: "http://127.0.0.1:1/disabled", model: "offline-fixture", maxRequestsPerRun: 20,
            maxOutputTokens: 1_000, contextWindowTokens: 128_000)
        store.apiKey = ""; store.queryMemoryEnabled = false; store.queryScope = .page

        let selection = SmartReadingSelection(execution: .init())
        store.prepareSmartReading(selection)
        try require(store.pendingPlanRegeneration?.selection == selection && !store.isSmartReadingRunning && store.readingTask == nil,
            "已有阅读方案必须先确认，显示确认不能启动AI任务。")
        store.cancelPlanRegeneration()
        try require(store.pendingPlanRegeneration == nil && store.book?.plan?.focus == project.plan?.focus,
            "取消重新预读不能改动旧方案。")
        store.prepareSmartReading(selection)
        store.books[0].plan?.focus.append("确认期间另一条任务更新了方案")
        store.confirmPlanRegeneration()
        try require(store.pendingPlanRegeneration == nil && !store.isSmartReadingRunning && store.readingTask == nil,
            "确认期间方案变化时不能凭旧确认发起AI请求。")
        let reviewChatStarts = await transport.chatStarts, reviewCompanionStarts = await transport.companionStarts
        try require(reviewChatStarts == 0 && reviewCompanionStarts == 0, "确认/取消的空操作不能发送模型请求。")
        store.books = [project]; store.errorMessage = nil

        let first = Task { @MainActor in await store.enhanceSourceScope(scope: .page) }
        _ = await first.value
        try await waitUntil("首个伴读进入模拟传输") { await transport.companionStarts == 1 }
        try require(store.isCompanionGenerating && store.companionProgress.isRunning, "伴读应独立显示运行状态。")
        try require(store.canStartQuery && store.canStartReading && store.canEditAISettings && !store.canStartCompanion,
            "伴读运行时应允许对话、智能阅读和设置，仅阻止重复伴读。")
        try require(store.isBusy, "伴读期间的手动覆盖/删除/切库保护不能解除。")
        let companionID = store.companionProgress.runID
        store.ask("原文说谁在这里？")
        try await waitUntil("对话先完成、伴读仍被门控") { !store.isQueryBusy && store.book?.chats.filter { $0.role == "assistant" }.count == 1 }
        try require(store.isCompanionGenerating && store.companionProgress.isRunning && store.companionProgress.runID == companionID,
            "对话结束不能清理或覆盖伴读任务和进度。")
        try require(store.queryProgressState.value.status == .completed, "对话应有独立完成记录。")
        try require(store.queryProgressState.value.runID != companionID, "并发任务不能共享进度标识。")
        await transport.release("companion")
        try await waitUntil("首个伴读完成") { !store.isCompanionGenerating }

        await transport.hold("companion"); await transport.hold("chat")
        _ = await store.enhanceSourceScope(scope: .page)
        try await waitUntil("第二个伴读开始") { await transport.companionStarts == 2 }
        let cancelledRun = store.companionProgress.runID
        store.ask("再说一次原文。")
        try await waitUntil("第二条对话进入模拟传输") { await transport.chatStarts == 3 }
        store.cancelCompanion()
        try await waitUntil("只取消伴读") { !store.isCompanionGenerating }
        try require(store.isQueryBusy && store.queryProgressState.value.isRunning, "停止伴读不能取消正在等待的对话。")
        try require(store.companionProgress.status == .paused, "取消的伴读应显示已停止。")
        _ = await store.enhanceSourceScope(scope: .page)
        try await waitUntil("对话等待时第三次伴读可开始") { await transport.companionStarts == 3 }
        let replacementRun = store.companionProgress.runID
        if let cancelledRun { store.finishAIProgress(cancelledRun) }
        try require(replacementRun != cancelledRun && store.companionProgress.runID == replacementRun && store.companionProgress.isRunning,
            "旧任务迟到的清理不能停止新伴读。")
        await transport.release("chat")
        try await waitUntil("第二条对话完成") { !store.isQueryBusy }
        try require(store.isCompanionGenerating, "对话完成仍不能清理第三次伴读。")
        await transport.release("companion")
        try await waitUntil("第三次伴读完成和请求记录写入结束") { !store.isCompanionGenerating && store.pendingAIHistoryWrites == 0 }
        let saved = try await owner.loadReport().projects.first!
        try require(saved.chats.filter { $0.role == "assistant" }.count == 2 && saved.chats.filter { $0.role == "user" }.count == 2,
            "并发提交应保留两轮完整问答。")
        let layerIDs = Set(saved.readingExperience?.layers.map(\.id) ?? [])
        try require(layerIDs.contains("companion-layer-1") && layerIDs.contains("companion-layer-3") && !layerIDs.contains("companion-layer-2"),
            "成功伴读均须保存，取消的结果不能写入。")
        try require(try await owner.readDocument(bookID: saved.id, document: note) == noteBody, "并发AI不能改写用户Markdown。")
        try require(try Data(contentsOf: source) == sourceBytes, "并发AI不能修改原书。")
        try require(store.book?.chats.count == saved.chats.count && store.book?.readingExperience?.layers.count == saved.readingExperience?.layers.count,
            "UI发布顺序不能丢掉较新的并发保存。")

        // Same book/source identities in another library are a distinct owner.
        // Force that switch while the old transport is suspended.
        await transport.hold("companion")
        _ = await store.enhanceSourceScope(scope: .page)
        try await waitUntil("切库前的旧伴读开始") { await transport.companionStarts == 4 }
        let abandonedRun = store.companionProgress.runID
        let alternateRoot = directory.appendingPathComponent("alternate-library")
        let alternateOwner = LibraryRepository(rootURL: alternateRoot)
        var alternate = BookProject(id: saved.id, title: "同ID另一书库", originalName: "fixture.txt", sourceHash: saved.sourceHash, units: saved.units)
        PluginEngine.seed(&alternate)
        alternate = try await alternateOwner.create(alternate, sourceURL: source)
        store.libraryRootURL = alternateRoot; store.repository = alternateOwner; store.books = [alternate]
        try await waitUntil("切库取消旧伴读") { !store.isCompanionGenerating }
        if let abandonedRun { store.finishAIProgress(abandonedRun) }
        let alternateSaved = try await alternateOwner.loadReport().projects.first!
        try require(store.book?.title == alternate.title && store.book?.chats.isEmpty == true
            && (store.book?.readingExperience?.layers.isEmpty ?? true), "旧库回调不能污染同ID新库的UI。")
        try require(alternateSaved.chats.isEmpty && (alternateSaved.readingExperience?.layers.isEmpty ?? true),
            "旧伴读不能向同ID的新仓库写入结果。")
        let retryRoot = directory.appendingPathComponent("retry-library")
        var defaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults["library.root.path.v1"] = retryRoot.path
        UserDefaults.standard.setVolatileDomain(defaults, forName: UserDefaults.argumentDomain)
        let retryStore = AppStore(sharedAIRequests: coordinator)
        await retryStore.load()
        try require(retryStore.books.isEmpty && retryStore.errorMessage != nil, "缺失的书库路径应明确报错。")
        var retryProject = BookProject(title: "恢复书库", originalName: "fixture.txt", sourceHash: project.sourceHash, units: project.units)
        PluginEngine.seed(&retryProject)
        _ = try await retryStore.repository.create(retryProject, sourceURL: source)
        await retryStore.load()
        try require(retryStore.books.count == 1 && retryStore.bookID == retryProject.id && retryStore.errorMessage == nil,
            "同一AppStore应在目录恢复后重新load成功并清除旧加载错误。")
        try await checkFailedReplanning(in: directory, source: source, template: project)
        try await checkConnectionEditing(in: directory)
        try await checkMemoryPreparation(in: directory)
        return ["companionAndChatActuallyOverlapped": true, "chatCompletedBeforeHeldCompanion": true,
            "companionCancellationPreservedChat": true, "lateProgressCleanupPreservedReplacement": true,
            "independentProgressRunIDs": true, "manualWriteBarrierPreserved": true, "settingsAllowedDuringCompanion": true,
            "assistantAnswersSaved": 2, "companionLayersSaved": 2, "cancelledLayerSaved": false,
            "originalSourceBytesPreserved": true, "userMarkdownBytesPreserved": true, "failedLoadRetrySameInstance": true,
            "existingPlanCancelSentNoRequest": true, "stalePlanConfirmationSentNoRequest": true,
            "librarySwitchCancelledOldCompanionWithoutCrossPublication": true,
            "failedReplanPreservedConfirmedSessionPlanAndViews": true,
            "cancelledReplanPreservedConfirmedSessionPlanAndViews": true,
            "staleConnectionResultClearedOwnWaitingStatus": true,
            "staleConnectionResultPreservedNewerEditorStatus": true,
            "memoryPreparationScopeModeStyleCases": 12, "memoryPreparationPreservedCompleteMessages": true,
            "emptyForeignAndStaleMemoryRejected": true, "cancelledMemoryNotPublished": true]
    }

    /// Actual AppStore + file actor, no model calls. A missing source/history
    /// must never make an old sidecar visible under a new scope or mode.
    @MainActor private static func checkMemoryPreparation(in directory: URL) async throws {
        let root = directory.appendingPathComponent("memory-preparation-library")
        let coordinator = AIRequestCoordinator(transport: { _ in throw ReadingError.invalid("记忆窗口不能发送模型请求。") })
        let store = AppStore(sharedAIRequests: coordinator)
        store.repository = LibraryRepository(rootURL: root); store.libraryRootURL = root
        var project = BookProject(id: "memory-fixture", title: "记忆准备", originalName: "fixture.txt", sourceHash: "memory-source",
            units: [SourceUnit(id: "u1", order: 0, chapter: "一", page: 1, text: "刘备在此。e\u{301} 😀"),
                    SourceUnit(id: "u2", order: 1, chapter: "二", page: 2, text: "后页原文。")])
        project.documents = [DocumentRecord(id: "note", title: "授权笔记", evidence: [Evidence(unitID: "u1", quote: "刘备在此。")])]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        store.books = [project]; store.bookID = project.id; store.selectedUnitID = "u1"
        for scope in [ReadingQueryScope.book, .page, .notes] {
            for mode in [ReadingConversationMode.reading, .functional] {
                for style in [ReadingAnswerStyle.mentor, .research] {
                    store.queryScope = scope; store.queryInteractionMode = mode; store.queryAnswerStyle = style
                    store.queryDocumentIDs = scope == .notes ? ["note"] : nil
                    store.books = [project]
                    let preferences = store.currentQueryPreferences
                    let snapshot = try ReadingQuerySnapshot.freeze(scope: scope, in: project, context: store.queryReadingContext,
                        documentIDs: scope == .notes ? ["note"] : nil).withContextIdentity(preferences.contextIdentity)
                    let context = try ReadingChatContext(snapshot: snapshot, avoidsSpoilers: preferences.avoidsSpoilers)
                    var current = project
                    current.chats = ["user", "assistant"].map { role in
                        var message = ChatMessage(id: "memory-"+role, role: role, content: "完整记忆 e\u{301} 😀 "+role)
                        message.conversationMode = mode; message.answerStyle = style; message.readingContext = context
                        message.createdAt = Date(timeIntervalSince1970: 1_700_000_000); return message
                    }
                    let history = ReadingChatHistory.automaticHistory(in: current, preferences: preferences, snapshot: snapshot)
                    try require(history.count == 2, "记忆fixture必须真实获准两条完整历史。")
                    let cursor = ConversationMemoryCursor(index: 2)
                    let memory = ConversationMemory(id: snapshot.bookID+":"+snapshot.scopeFingerprint, bookID: snapshot.bookID,
                        scopeFingerprint: snapshot.scopeFingerprint, fingerprint: try ConversationMemoryRuntime.prefixFingerprint(history, cursor: cursor),
                        cursor: cursor, requirements: [.init(text: "保留用户要求", sources: ["memory-user"])],
                        conclusions: [.init(text: "保留原回答", sources: ["memory-assistant"])], unresolved: [],
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_001), model: "offline")
                    try require(ConversationMemoryRuntime.isValid(memory, snapshot: snapshot, history: history), "侧车必须先通过真实来源验证。")
                    try await QueryMemoryFiles.shared.write(memory, snapshot: snapshot, root: root)
                    store.books = [current]
                    let before = try encoder.encode(current), display = await store.prepareQueryMemoryDisplay()
                    try require(display.memory == memory && (try encoder.encode(display.messages)) == encoder.encode(Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })),
                        "记忆准备必须保留完整条目、来源消息和模式范围。")
                    try require(try encoder.encode(store.books[0]) == before, "准备记忆不能改写原书、分析或聊天。")
                    let cancelled = Task { @MainActor in
                        withUnsafeCurrentTask { $0?.cancel() }
                        return await store.prepareQueryMemoryDisplay()
                    }
                    let stopped = await cancelled.value
                    try require(stopped.memory == nil && stopped.messages.isEmpty, "有效侧车存在时，取消也不能发布记忆。")
                    store.books = [project]
                    let empty = await store.prepareQueryMemoryDisplay()
                    try require(empty.memory == nil && empty.messages.isEmpty, "空历史不能加载已存在的侧车。")
                    var other = current
                    for i in other.chats.indices { other.chats[i].conversationMode = mode == .reading ? .functional : .reading }
                    store.books = [other]
                    let mismatched = await store.prepareQueryMemoryDisplay()
                    try require(mismatched.memory == nil && mismatched.messages.isEmpty, "其他对话模式不能加载旧记忆。")
                    var changed = current
                    if scope == .notes { changed.documents[0].updatedAt = changed.documents[0].updatedAt.addingTimeInterval(1) }
                    else { changed.units[0].text += "原文更新" }
                    store.books = [changed]
                    let stale = await store.prepareQueryMemoryDisplay()
                    try require(stale.memory == nil && stale.messages.isEmpty, "原文字节更新不能沿用旧记忆。")
                    try await QueryMemoryFiles.shared.remove(snapshot: snapshot, root: root)
                }
            }
        }
    }

    @MainActor private static func checkFailedReplanning(in directory: URL, source: URL, template: BookProject) async throws {
        let root = directory.appendingPathComponent("replan-library"), owner = LibraryRepository(rootURL: directory.appendingPathComponent("replan-library"))
        var original = BookProject(title: "重新预读事务回归", originalName: "fixture.txt", sourceHash: template.sourceHash, units: template.units)
        PluginEngine.seed(&original); original.plan = template.plan
        original.views.removeAll { $0.kind == .map }
        original.smartReading = try SmartReadingRuntime.freeze(SmartReadingSelection(execution: .init()), in: original, currentUnitID: "u1")
        original.smartReading?.isPlanConfirmed = true; original.smartReading?.status = .ready
        original.smartReading?.lastMessage = "原先已确认的范围继续可用。"
        original = try await owner.create(original, sourceURL: source)
        let note = DocumentRecord(id: "replan-note", title: "重新预读也须保留笔记"), noteBody = "# 已有笔记\n\n刘备在此。\n"
        original = try await owner.saveDocument(project: original, document: note, markdown: noteBody)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let planData = try encoder.encode(original.plan), sessionData = try encoder.encode(original.smartReading), viewsData = try encoder.encode(original.views)
        func requirePreserved(_ current: BookProject) throws {
            try require(try encoder.encode(current.plan) == planData && encoder.encode(current.smartReading) == sessionData && encoder.encode(current.views) == viewsData,
                "重新预读失败/取消必须逐字段保留原方案、已确认阅读会话及视图。")
        }
        let transport = OfflineConcurrentTransport()
        await transport.hold("planning")
        let coordinator = AIRequestCoordinator(transport: { try await transport.perform($0) })
        let store = AppStore(sharedAIRequests: coordinator)
        store.libraryRootURL = root; store.repository = owner; store.books = [original]; store.bookID = original.id; store.selectedUnitID = "u1"
        store.settings = ProviderSettings(baseURL: "http://127.0.0.1:1/disabled", model: "offline-fixture", maxRequestsPerRun: 20,
            maxOutputTokens: 1_000, contextWindowTokens: 128_000)
        store.apiKey = ""
        let selection = SmartReadingSelection(scope: .currentPage, execution: .init(componentKinds: [.map]))
        store.prepareSmartReading(selection); store.confirmPlanRegeneration()
        try await waitUntil("重新预读进入延迟失败传输") { await transport.planStarts == 1 }
        try requirePreserved(store.book!)
        try requirePreserved(try await owner.loadReport().projects.first!)
        await transport.release("planning")
        try await waitUntil("重新预读失败已清理任务") { !store.isSmartReadingRunning }
        try require(store.errorMessage?.contains("模拟重新预读响应失败") == true, "失败fixture必须实际走过AI错误分支。")
        try requirePreserved(store.book!)
        try requirePreserved(try await owner.loadReport().projects.first!)
        try require(try await owner.readDocument(bookID: original.id, document: note) == noteBody, "失败重新预读不能改写已有笔记。")

        await transport.hold("planning")
        store.prepareSmartReading(selection); store.confirmPlanRegeneration()
        try await waitUntil("第二次重新预读进入延迟传输") { await transport.planStarts == 2 }
        store.pauseReading()
        try await waitUntil("取消重新预读已清理任务") { !store.isSmartReadingRunning }
        try requirePreserved(store.book!)
        try requirePreserved(try await owner.loadReport().projects.first!)
        try require(store.book?.smartReading?.isPlanConfirmed == true && store.book?.smartReading?.status == .ready,
            "取消重新预读后原确认方案必须仍能继续使用。")
    }

    @MainActor private static func checkConnectionEditing(in directory: URL) async throws {
        let transport = OfflineConcurrentTransport()
        let store = AppStore(connectionProbe: { try await transport.probeConnection($0, $1) })
        store.libraryRootURL = directory.appendingPathComponent("connection-library")
        store.settings = ProviderSettings(baseURL: "http://127.0.0.1:1/disabled", model: "fixture-A")
        store.apiKey = ""
        await transport.hold("connection")
        store.testConnection()
        try await waitUntil("连接A正在等待") { await transport.connectionStarts == 1 }
        store.settings.model = "fixture-B"
        await transport.release("connection")
        try await waitUntil("连接A旧结果退出") { !store.isTestingConnection }
        try require(store.connectionStatus == "配置已更改，请重新测试当前配置。", "修改连接后旧响应必须清理自己的等待状态，并提示重新测试。")
        await transport.hold("connection")
        store.testConnection()
        try await waitUntil("连接B正在等待") { await transport.connectionStarts == 2 }
        store.settings.model = "fixture-C"; store.connectionStatus = "配置已保存。"
        await transport.release("connection")
        try await waitUntil("连接B旧结果退出") { !store.isTestingConnection }
        try require(store.connectionStatus == "配置已保存。", "旧连接结果不能覆盖编辑器更新后的状态。")
        store.testConnection()
        try await waitUntil("连接C完成") { !store.isTestingConnection }
        try require(store.connectionStatus == "离线连接正常：fixture-C", "当前连接的正常测试结果仍应显示。")
    }
}
