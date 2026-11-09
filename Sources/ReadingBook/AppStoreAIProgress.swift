import SwiftUI
import ReadingCore

/// The synchronous final drain prevents an already-received final counter from
/// being lost when the caller finishes before a queued MainActor UI update.
fileprivate final class AIProgressMailbox: Equatable, @unchecked Sendable {
    let finishAction: @Sendable () async -> Void
    let requestRun: AIRequestRun?
    private let lock = NSLock()
    private var events: [AIProgressEvent] = []
    private var scheduled = false
    private var closed = false
    init(requestRun: AIRequestRun?, finishAction: @escaping @Sendable () async -> Void) {
        self.requestRun = requestRun; self.finishAction = finishAction
    }
    static func == (lhs: AIProgressMailbox, rhs: AIProgressMailbox) -> Bool { lhs === rhs }
    func append(_ value: AIProgressEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        if let last = events.last, last.requestID == value.requestID,
           [AIProgressPhase.receiving, .reasoning, .answering, .receivingTools].contains(last.phase),
           [AIProgressPhase.receiving, .reasoning, .answering, .receivingTools].contains(value.phase) {
            events[events.count - 1] = value
        } else { events.append(value) }
        guard !scheduled else { return false }
        scheduled = true; return true
    }
    func take(close: Bool = false) -> [AIProgressEvent] {
        lock.lock(); defer { lock.unlock() }
        if close { closed = true }
        let value = events; events.removeAll(keepingCapacity: !close); scheduled = false
        return value
    }
}

struct AIProgressPresentationState: Equatable {
    enum Status: Equatable { case idle, running, completed, paused, failed }
    struct ToolStep: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var succeeded: Bool?
        var requiresReview = false
        var requestNumber = 0
        var requestID: UUID?
        var summary = ""
        var trace: AIToolTrace?
        var traceExpired = false
    }
    struct Request: Identifiable, Equatable {
        var id: UUID
        var number: Int
        var startedAt = Date()
        var finishedAt: Date?
        var reasoning = 0
        var output = 0
        var bytes = 0
        var trace: AIRequestTrace?
        var response: AIResponseTrace?
        var traceExpired = false
    }
    var requests: [Request] = []
    var runID: UUID?
    fileprivate var mailbox: AIProgressMailbox?
    var bookID: String?
    var libraryRoot: URL?
    var title = ""
    var detail = ""
    var startedAt: Date?
    var finishedAt: Date?
    var status: Status = .idle
    var phase: AIProgressPhase = .preparing
    var requestNumber = 0
    var toolName: String?
    var toolIndex: Int?
    var toolTotal: Int?
    var toolSteps: [ToolStep] = []
    var completedTools = 0
    var failedTools = 0
    var failureMessage = ""
    private var activeRequestID: UUID?
    private var priorReasoning = 0
    private var priorAnswer = 0
    private var priorBytes = 0
    private var requestReasoning = 0
    private var requestAnswer = 0
    private var requestBytes = 0
    var reasoningCharacters: Int { priorReasoning + requests.reduce(0) { $0 + $1.reasoning } }
    var answerCharacters: Int { priorAnswer + requests.reduce(0) { $0 + $1.output } }
    var receivedBytes: Int { priorBytes + requests.reduce(0) { $0 + $1.bytes } }
    var isRunning: Bool { status == .running }
    var hasActivity: Bool { startedAt != nil }
    var phaseTitle: String {
        switch status {
        case .idle: return "尚未开始"
        case .completed: return "本次任务已完成"
        case .paused: return "本次任务已停止，已保存结果保留"
        case .failed: return "本次任务未完成，已保存结果保留"
        case .running: break
        }
        switch phase {
        case .preparing: return "准备本次内容"
        case .waitingForResponse: return "等待模型响应"
        case .receiving: return "已连接，等待模型输出"
        case .reasoning: return "模型正在思考"
        case .answering: return "正在接收模型输出"
        case .receivingTools: return "接收组件操作"
        case .requestCompleted: return "校验模型结果"
        case .performingTool: return Self.toolTitle(toolName)
        case .toolCompleted:
            if toolSteps.last?.requiresReview == true { return "修改方案已准备，未自动应用" }
            return failedTools > 0 && toolSteps.last?.succeeded == false ? "操作未通过，等待修正" : "操作结果已返回"
        case .saving: return "保存已校验的结果"
        }
    }
    mutating func apply(_ event: AIProgressEvent) {
        guard isRunning else { return }
        if event.phase == .waitingForResponse, let id = event.requestID, !requests.contains(where: { $0.id == id }) {
            activeRequestID = id
            requests.append(Request(id: id, number: event.requestNumber ?? requests.count + 1, trace: event.requestTrace))
            if requests.count > 300 {
                let removed = requests.removeFirst(); priorReasoning += removed.reasoning; priorAnswer += removed.output; priorBytes += removed.bytes
            }
        }
        phase = event.phase
        let requestIndex = requests.firstIndex { $0.id == (event.requestID ?? activeRequestID) }
        let number = requestIndex.map { requests[$0].number } ?? requestNumber
        let requestID = requestIndex.map { requests[$0].id } ?? event.requestID ?? activeRequestID
        requestNumber = max(requestNumber, number)
        if let index = requestIndex {
            if let count = event.reasoningCharacters { requests[index].reasoning = max(requests[index].reasoning, count) }
            if let count = event.answerCharacters { requests[index].output = max(requests[index].output, count) }
            if let count = event.receivedBytes { requests[index].bytes = max(requests[index].bytes, count) }
            if event.phase == .requestCompleted { requests[index].finishedAt = Date() }
            if let response = event.responseTrace { requests[index].response = response }
        }
        if event.phase == .performingTool {
            toolName = event.toolName; toolIndex = event.toolIndex; toolTotal = event.toolTotal
            toolSteps.append(ToolStep(title: Self.toolTitle(event.toolName), succeeded: nil, requestNumber: number, requestID: requestID))
            if toolSteps.count > 300 { toolSteps.removeFirst(toolSteps.count - 300) }
        } else if event.phase == .toolCompleted {
            let requiresReview = event.toolStatus == "needs_confirmation"
            if let index = toolSteps.lastIndex(where: { ($0.requestID == requestID && $0.requestNumber == number) && $0.title == Self.toolTitle(event.toolName) && $0.succeeded == nil && (!$0.requiresReview || !requiresReview) }) {
                toolSteps[index].requiresReview = requiresReview; toolSteps[index].summary = event.toolSummary ?? ""
                toolSteps[index].trace = event.toolTrace
                if !requiresReview { toolSteps[index].succeeded = event.toolSucceeded == true }
            }
            if !requiresReview { if event.toolSucceeded == true { completedTools += 1 } else { failedTools += 1 } }
        }
        if event.requestTrace != nil || event.responseTrace != nil || event.toolTrace != nil { trimTraceText() }
    }
    /// Keep detail text separate from durable books and bounded to 2 MiB per
    /// lane. Eviction removes text, never the request counts or success status.
    private mutating func trimTraceText() {
        var bytes = requests.reduce(0) { $0 + ($1.trace?.retainedBytes ?? 0) + ($1.response?.retainedBytes ?? 0) }
            + toolSteps.reduce(0) { $0 + ($1.trace?.retainedBytes ?? 0) }
        for index in requests.indices where bytes > 2 * 1024 * 1024 {
            bytes -= (requests[index].trace?.retainedBytes ?? 0) + (requests[index].response?.retainedBytes ?? 0)
            requests[index].trace = nil; requests[index].response = nil; requests[index].traceExpired = true
        }
        for index in toolSteps.indices where bytes > 2 * 1024 * 1024 {
            guard let trace = toolSteps[index].trace else { continue }
            bytes -= trace.retainedBytes; toolSteps[index].trace = nil; toolSteps[index].traceExpired = true
        }
    }
    static func toolTitle(_ name: String?) -> String {
        switch name ?? "" {
        case "source_outline", "source_list": return "查看原文范围"
        case "source_search": return "查找相关原文"
        case "components_list": return "选择合适的展示方式"
        case "component_show": return "打开阅读组件"
        case "source_read": return "阅读原文片段"
        case "source_locate": return "查询原文位置"
        case "capabilities_list": return "查看可用功能与参数"
        case "book_schema_get": return "查看本书数据类型"
        case "objects_search", "object_get": return "查找已保存的要素"
        case "events_query": return "查看已保存事件"
        case "relations_list": return "核对已保存关系"
        case "entity_history_get": return "查看人物与事件经过"
        case "reading_coverage_get": return "检查已有阅读进度"
        case "analysis_outline": return "查看已有分析目录"
        case "analysis_read": return "阅读已有分析"
        case "documents_list", "documents_search", "document_read": return "查阅授权笔记"
        case "conversation_search", "conversation_read": return "重读本次对话记录"
        case "reading_receipts", "reading_receipt", "read_receipt": return "核对逐段阅读记录"
        case "types_define": return "定义本书要素类型"
        case "cards_upsert": return "整理实体卡片"
        case "events_upsert": return "整理事件"
        case "relations_link": return "连接原文关系"
        case "views_configure": return "组装本书组件"
        case "methods_define", "reading_plan": return "制定智能阅读方案"
        case "map_attach": return "连接地图事件"
        case "timeline_attach": return "连接时间轴事件"
        case "reading_graph", "graph_changes_propose": return "整理文档与导图"
        case "reading_enrich": return "生成伴读内容"
        case "reading_finish", "workflow_step_complete": return "核对阅读检查点"
        case "knowledge_changes_propose": return "整理实体、事件和关系"
        case "tool_draft_repair": return "修正整理草案"
        case "document_changes_propose": return "准备笔记修改方案"
        case "book_scheme_propose", "book_plan": return "准备本书阅读方案"
        case "view_select", "view_focus", "map_fit_objects", "graph_focus", "panel_present", "view_set_time_window": return "调整当前组件视图"
        default: return "处理组件操作"
        }
    }
}

/// Frequent transport counters redraw only their small progress surface, rather
/// than publishing the entire workspace's AppStore on every streaming update.
@MainActor final class AIProgressObservableState: ObservableObject {
    @Published var value = AIProgressPresentationState()
}

fileprivate final class AIWorkerProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UUID?
    func tag(_ event: AIProgressEvent) -> AIProgressEvent {
        lock.lock(); defer { lock.unlock() }
        var value = event
        if value.phase == .waitingForResponse { current = value.requestID }
        if value.requestID == nil { value.requestID = current }
        return value
    }
}

@MainActor extension AppStore {
    var aiConcurrencyLimit: Int {
        // A model's plan may recommend sequential book analysis; that is not
        // permission to serialize every independent reader interaction. Keep
        // the host/user's explicit global cap, including an intentional cap1.
        min(5, max(1, book?.smartReading?.selection.execution?.maximumConcurrentRequests ?? 2))
    }
    @discardableResult func beginAIProgress(title: String, ocr: Bool = false, backgroundReading: Bool = false, settings frozenSettings: ProviderSettings? = nil) async -> UUID {
        let sourceBookID = bookID, sourceRoot = libraryRootURL, owner = repository
        var run: AIRequestRun?
        if !ocr { run = try? await sharedAIRequests.beginManagedRun(settings: frozenSettings ?? settings, maximumConcurrency: aiConcurrencyLimit, independentBudget: true) }
        return await prepareProgress(title: title, destination: .general, ocr: ocr, worker: backgroundReading ? readingReader : reader, requestRun: run,
            sourceBookID: sourceBookID, sourceRoot: sourceRoot, owner: owner)
    }
    @discardableResult func beginQueryProgress(title: String, settings frozenSettings: ProviderSettings? = nil) async -> UUID {
        let sourceBookID = bookID, sourceRoot = libraryRootURL, owner = repository
        let run = try? await sharedAIRequests.beginManagedRun(settings: frozenSettings ?? settings, maximumConcurrency: aiConcurrencyLimit, independentBudget: true)
        return await prepareProgress(title: title, destination: .query, ocr: false, worker: queryReader, requestRun: run,
            sourceBookID: sourceBookID, sourceRoot: sourceRoot, owner: owner)
    }
    @discardableResult func beginCompanionProgress(title: String, settings frozenSettings: ProviderSettings? = nil) async -> UUID {
        let sourceBookID = bookID, sourceRoot = libraryRootURL, owner = repository
        let run = try? await sharedAIRequests.beginManagedRun(settings: frozenSettings ?? settings, maximumConcurrency: aiConcurrencyLimit, independentBudget: true)
        return await prepareProgress(title: title, destination: .companion, ocr: false, worker: companionReader, requestRun: run,
            sourceBookID: sourceBookID, sourceRoot: sourceRoot, owner: owner)
    }
    @discardableResult func beginSummaryProgress(title: String, worker: AIReader, settings: ProviderSettings) async -> UUID {
        let sourceBookID = bookID, sourceRoot = libraryRootURL, owner = repository
        let run = try? await sharedAIRequests.beginManagedRun(settings: settings, maximumConcurrency: aiConcurrencyLimit, independentBudget: true)
        return await prepareProgress(title: title, destination: .summary, ocr: false, worker: worker, requestRun: run,
            sourceBookID: sourceBookID, sourceRoot: sourceRoot, owner: owner)
    }
    private func progressValue(_ runID: UUID) -> AIProgressPresentationState? {
        if aiProgress.runID == runID { return aiProgress }
        if queryProgressState.value.runID == runID { return queryProgressState.value }
        if companionProgress.runID == runID { return companionProgress }
        if summaryProgressState.value.runID == runID { return summaryProgressState.value }
        return nil
    }
    private func setProgress(_ value: AIProgressPresentationState) {
        if value.runID == queryProgressState.value.runID { queryProgressState.value = value }
        else if value.runID == companionProgress.runID { companionProgress = value }
        else if value.runID == summaryProgressState.value.runID { summaryProgressState.value = value }
        else { aiProgress = value }
    }
    private enum ProgressDestination: Equatable { case general, query, companion, summary }
    private func prepareProgress(title: String, destination: ProgressDestination, ocr: Bool, worker: AIReader, requestRun: AIRequestRun?,
                                 sourceBookID: String?, sourceRoot: URL, owner: LibraryRepository) async -> UUID {
        let runID = UUID()
        let old = destination == .query ? queryProgressState.value : destination == .companion ? companionProgress : destination == .summary ? summaryProgressState.value : aiProgress
        _ = old.mailbox?.take(close: true)
        let mailbox = AIProgressMailbox(requestRun: requestRun) {
            if let sourceBookID { _ = try? await owner.refreshReadableViews(id: sourceBookID, archived: false) }
        }
        var value = AIProgressPresentationState()
        value.mailbox = mailbox; value.runID = runID; value.bookID = sourceBookID; value.libraryRoot = sourceRoot
        value.title = title; value.startedAt = Date(); value.status = .running
        switch destination {
        case .query: queryProgressState.value = value
        case .companion: companionProgress = value
        case .general: aiProgress = value
        case .summary: summaryProgressState.value = value
        }
        let handler = workerProgressHandler(runID)
        if ocr { await pdfOCRReader.setProgressHandler(handler) } else { await worker.setRequestRun(requestRun); await worker.setProgressHandler(handler) }
        return runID
    }
    func workerProgressHandler(_ runID: UUID) -> AIProgressHandler {
        let relay = AIWorkerProgressRelay()
        let value = progressValue(runID), mailbox = value?.mailbox, sourceBookID = value?.bookID, sourceRoot = value?.libraryRoot
        return { [weak self] event in
            guard let mailbox, mailbox.append(relay.tag(event)) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.bookID == sourceBookID, self.libraryRootURL == sourceRoot,
                      self.progressValue(runID)?.isRunning == true else { return }
                self.flushAIProgress(runID)
            }
        }
    }
    func markAIProgressSaving(_ runID: UUID) {
        flushAIProgress(runID)
        guard var value = progressValue(runID), value.isRunning else { return }
        value.phase = .saving; setProgress(value)
    }
    func updateAIProgressDetail(_ runID: UUID, detail: String) {
        guard var value = progressValue(runID), value.isRunning else { return }
        value.detail = String(detail.prefix(160)); setProgress(value)
    }
    func updateAIProgressTitle(_ runID: UUID, title: String) {
        guard var value = progressValue(runID), value.isRunning else { return }
        value.title = title; setProgress(value)
    }
    /// A progress surface cancels exactly the run it displays, never whichever
    /// other lane happens to be busy when the click reaches the main actor.
    func cancelAIActivity(_ runID: UUID?) {
        guard let runID, let value = progressValue(runID), value.isRunning,
              value.bookID == bookID, value.libraryRoot == libraryRootURL else { return }
        if companionProgress.runID == runID { cancelCompanion() }
        else if queryProgressState.value.runID == runID { cancelQuery() }
        else if summaryProgressState.value.runID == runID { queryMemoryTask?.cancel() }
        else if aiProgress.runID == runID {
            if isSmartReadingRunning { pauseReading() }
            else { task?.cancel(); activity = "正在停止本次任务，已保存内容保留。" }
        }
    }
    func finishAIProgress(_ runID: UUID, error: Error? = nil) {
        guard progressValue(runID)?.isRunning == true else { return }
        flushAIProgress(runID, close: true)
        guard var value = progressValue(runID) else { return }
        let finishAction = value.mailbox?.finishAction
        let requestRun = value.mailbox?.requestRun
        requestRun?.finish()
        Task {
            if let requestRun { await sharedAIRequests.endRun(requestRun) }
            await finishAction?()
        }
        value.finishedAt = Date()
        if let error {
            value.status = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled || error is ReadingWorkflowBudgetPause ? .paused : .failed
            value.failureMessage = String(error.localizedDescription.prefix(600))
        } else { value.status = .completed }
        setProgress(value)
        if let bookID = value.bookID, let sourceHash = book?.sourceHash, self.bookID == bookID, value.libraryRoot == libraryRootURL {
            let records = value.requests.map { request in
                AIRequestHistoryRecord(id: request.id.uuidString, title: value.title, number: request.number,
                    startedAt: request.startedAt, finishedAt: request.finishedAt ?? value.finishedAt ?? Date(),
                    status: request.finishedAt != nil ? "returned" : value.status == .paused ? "paused" : "failed",
                    reasoningCharacters: request.reasoning, answerCharacters: request.output)
            }
            let owner = repository
            if !records.isEmpty {
                pendingAIHistoryWrites += 1
                Task {
                    defer { pendingAIHistoryWrites -= 1 }
                    try? await owner.recordAIRequestHistory(bookID: bookID, sourceHash: sourceHash, records: records)
                }
            }
        }
    }
    private func flushAIProgress(_ runID: UUID, close: Bool = false) {
        guard var value = progressValue(runID) else { return }
        let events = value.mailbox?.take(close: close) ?? []
        guard !events.isEmpty else { return }
        for event in events { value.apply(event) }
        setProgress(value)
    }
}

struct AIProgressStatusView: View {
    @ObservedObject var state: AIProgressObservableState
    var compact = false
    var showsDetailsButton = true
    @Environment(\.readingReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: AppStore
    private var progress: AIProgressPresentationState { state.value }
    var body: some View {
        if let started = progress.startedAt {
            TimelineView(.animation(minimumInterval: 1, paused: !progress.isRunning)) { context in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        if progress.isRunning {
                            if reduceMotion { Image(systemName: "ellipsis.circle").foregroundStyle(Palette.accent) }
                            else { ProgressView().controlSize(.small) }
                        }
                        else { Image(systemName: progress.status == .completed ? "checkmark.circle" : "pause.circle").foregroundStyle(Palette.accent) }
                        Text(progress.phaseTitle).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        Spacer(minLength: 4)
                        Text("\(max(0, Int((progress.finishedAt ?? context.date).timeIntervalSince(started)))) 秒").monospacedDigit().foregroundStyle(.secondary)
                    }
                    if !progress.detail.isEmpty { Text(progress.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                    if progress.reasoningCharacters > 0 || progress.answerCharacters > 0 {
                        Text("已收到思考 \(progress.reasoningCharacters) · 输出 \(progress.answerCharacters) 字符")
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                            .help("仅统计服务实际返回的字符，不显示思考原文；字符数不是 Token，也不表示内容已经保存。")
                    } else if progress.receivedBytes > 0 {
                        Text("已接收 \(ByteCountFormatter.string(fromByteCount: Int64(progress.receivedBytes), countStyle: .file))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if !compact {
                        HStack {
                            Text(progress.requestNumber > 0 ? "第 \(progress.requestNumber) 次模型请求" : "尚未发送请求")
                            Spacer()
                            if [.performingTool, .toolCompleted].contains(progress.phase), let index = progress.toolIndex, let total = progress.toolTotal {
                                Text("本批操作 \(index)/\(total)")
                            } else if progress.completedTools > 0 { Text("\(progress.completedTools) 项操作通过") }
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                        LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(progress.toolSteps.reversed()) { step in
                            Button { store.showAIRequestHistory(state, focusing: step) } label: { HStack(spacing: 8) {
                                Image(systemName: step.requiresReview ? "clock" : step.succeeded == nil ? "circle.dotted" : step.succeeded == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                                    .foregroundStyle(step.succeeded == false ? Palette.copper : Palette.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(step.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    if step.requiresReview { Text("审阅后应用").font(.system(size: 11)).foregroundStyle(.secondary) }
                                    else if !step.summary.isEmpty { Text(step.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                                    else if let fragment = step.trace?.fragments.first { Text(fragment.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer(minLength: 4)
                                Text("请求 \(step.requestNumber)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle()) }
                                .buttonStyle(ReadingQuietButtonStyle())
                                .accessibilityLabel("查看请求\(step.requestNumber)的操作：\(step.title)")
                                .help("打开第 \(step.requestNumber) 次模型请求，并展开这项软件操作的参数与返回")
                        }
                        }
                    }
                    if showsDetailsButton {
                        Button { store.showAIRequestHistory(state) } label: { Label("请求记录与详情", systemImage: "clock.arrow.circlepath").font(.system(size: 12)) }.buttonStyle(ReadingQuietButtonStyle()).foregroundStyle(Palette.accent).frame(minHeight: 30)
                    }
                }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Hidden detail text is not laid out until expanded, including long source
/// excerpts and JSON. The whole row has hover and keyboard feedback.
struct AITraceDisclosure<Content: View>: View {
    let title: String
    var subtitle = ""
    var expandOnAppear = false
    @ViewBuilder let content: () -> Content
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 9) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 6)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(ReadingQuietButtonStyle()).help((expanded ? "收起" : "展开") + title)
                .accessibilityLabel((expanded ? "收起" : "展开") + title)
            if expanded { content().padding(.leading, 8) }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { if expandOnAppear { expanded = true } }
    }
}

struct AITraceTextView: View, Equatable {
    let content: AITraceText
    @State private var readable: String?
    @State private var readableSource: String?
    @State private var showRaw = false
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.content == rhs.content }
    private var currentReadable: String? { readableSource == content.text ? readable : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if content.isPartial {
                Text("仅保留了这段文字的前 \(content.text.utf8.count) 字节（原长 \(content.originalBytes) 字节）；不是模型看到的全部内容。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if currentReadable != nil {
                HStack {
                    Text(showRaw ? "原始文字" : "阅读显示 · 仅排版").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(showRaw ? "阅读显示" : "原始文字") { showRaw.toggle() }
                        .font(.system(size: 11)).buttonStyle(ReadingQuietButtonStyle())
                        .help("阅读显示把结构化字段中的文字展开成正常换行；原始文字保留实际收发内容，不改变模型请求。")
                }
            }
            let text = showRaw ? content.text : currentReadable ?? content.text
            AITraceNativeTextView(text: text)
                .frame(height: text.utf8.count > 1000 ? 260 : max(64, min(260, CGFloat(text.filter { $0 == "\n" }.count + 2) * 20 + 24)))
                .background(Palette.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }.task(id: content.text) {
            let source = content
            let value = await Task.detached(priority: .userInitiated) { source.readableJSON() }.value
            guard !Task.isCancelled else { return }
            readable = value; readableSource = source.text
        }
    }
}
