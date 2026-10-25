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
    }
    struct Request: Identifiable, Equatable {
        var id: UUID
        var number: Int
        var startedAt = Date()
        var finishedAt: Date?
        var reasoning = 0
        var output = 0
        var bytes = 0
    }
    var requests: [Request] = []
    var runID: UUID?
    fileprivate var mailbox: AIProgressMailbox?
    var bookID: String?
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
            requests.append(Request(id: id, number: event.requestNumber ?? requests.count + 1))
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
        }
        if event.phase == .performingTool {
            toolName = event.toolName; toolIndex = event.toolIndex; toolTotal = event.toolTotal
            toolSteps.append(ToolStep(title: Self.toolTitle(event.toolName), succeeded: nil, requestNumber: number, requestID: requestID))
            if toolSteps.count > 300 { toolSteps.removeFirst(toolSteps.count - 300) }
        } else if event.phase == .toolCompleted {
            let requiresReview = event.toolStatus == "needs_confirmation"
            if let index = toolSteps.lastIndex(where: { ($0.requestID == requestID && $0.requestNumber == number) && $0.title == Self.toolTitle(event.toolName) && $0.succeeded == nil && !$0.requiresReview }) {
                toolSteps[index].requiresReview = requiresReview; toolSteps[index].summary = event.toolSummary ?? ""
                if !requiresReview { toolSteps[index].succeeded = event.toolSucceeded == true }
            }
            if !requiresReview { if event.toolSucceeded == true { completedTools += 1 } else { failedTools += 1 } }
        }
    }
    static func toolTitle(_ name: String?) -> String {
        switch name ?? "" {
        case "source_outline", "source_list": return "查看原书目录"
        case "source_search": return "查找相关原文"
        case "source_read": return "阅读原文片段"
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
        min(5, max(1, min(book?.smartReading?.selection.execution?.maximumConcurrentRequests ?? 2,
            book?.plan?.recommendedParallelism ?? 5)))
    }
    @discardableResult func beginAIProgress(title: String, ocr: Bool = false, backgroundReading: Bool = false) async -> UUID {
        var run: AIRequestRun?
        if !ocr { run = try? await sharedAIRequests.beginManagedRun(settings: settings, maximumConcurrency: aiConcurrencyLimit) }
        return await prepareProgress(title: title, query: false, ocr: ocr, worker: backgroundReading ? readingReader : reader, requestRun: run)
    }
    @discardableResult func beginQueryProgress(title: String) async -> UUID {
        let run = try? await sharedAIRequests.beginManagedRun(settings: settings, maximumConcurrency: aiConcurrencyLimit)
        return await prepareProgress(title: title, query: true, ocr: false, worker: queryReader, requestRun: run)
    }
    private func progressValue(_ runID: UUID) -> AIProgressPresentationState? {
        if aiProgress.runID == runID { return aiProgress }
        if queryProgressState.value.runID == runID { return queryProgressState.value }
        return nil
    }
    private func setProgress(_ value: AIProgressPresentationState) {
        if value.runID == queryProgressState.value.runID { queryProgressState.value = value }
        else { aiProgress = value }
    }
    private func prepareProgress(title: String, query: Bool, ocr: Bool, worker: AIReader, requestRun: AIRequestRun?) async -> UUID {
        let runID = UUID(), sourceBookID = bookID, frozenRepository = repository
        _ = (query ? queryProgressState.value : aiProgress).mailbox?.take(close: true)
        let mailbox = AIProgressMailbox(requestRun: requestRun) {
            if let sourceBookID { _ = try? await frozenRepository.refreshReadableViews(id: sourceBookID, archived: false) }
        }
        var value = AIProgressPresentationState()
        value.mailbox = mailbox; value.runID = runID; value.bookID = sourceBookID
        value.title = title; value.startedAt = Date(); value.status = .running
        if query { queryProgressState.value = value } else { aiProgress = value }
        let handler = workerProgressHandler(runID)
        if ocr { await pdfOCRReader.setProgressHandler(handler) } else { await worker.setProgressHandler(handler) }
        return runID
    }
    func workerProgressHandler(_ runID: UUID) -> AIProgressHandler {
        let relay = AIWorkerProgressRelay()
        let mailbox = progressValue(runID)?.mailbox, sourceBookID = bookID
        return { [weak self] event in
            guard let mailbox, mailbox.append(relay.tag(event)) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.bookID == sourceBookID, self.progressValue(runID)?.isRunning == true else { return }
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
        } else { value.status = .completed }
        setProgress(value)
        if let bookID = value.bookID, let sourceHash = book?.sourceHash, self.bookID == bookID {
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
    @Environment(\.readingReduceMotion) private var reduceMotion
    @State private var showingDetails = false
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
                            Text(progress.requestNumber > 0 ? "第 \(progress.requestNumber) 次请求" : "尚未发送请求")
                            Spacer()
                            if [.performingTool, .toolCompleted].contains(progress.phase), let index = progress.toolIndex, let total = progress.toolTotal {
                                Text("本批操作 \(index)/\(total)")
                            } else if progress.completedTools > 0 { Text("\(progress.completedTools) 项操作通过") }
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(Array(progress.toolSteps.suffix(3))) { step in
                            HStack(spacing: 7) {
                                Image(systemName: step.requiresReview ? "clock" : step.succeeded == nil ? "circle.dotted" : step.succeeded == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                                    .foregroundStyle(step.succeeded == false ? Palette.copper : Palette.accent)
                                Button(step.title) { showingDetails = true }.buttonStyle(.plain).font(.system(size: 12)).lineLimit(1)
                                if step.requiresReview { Text("审阅后应用").font(.system(size: 11)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Button { showingDetails = true } label: { Label("请求记录与详情", systemImage: "clock.arrow.circlepath").font(.system(size: 12)) }.buttonStyle(.plain).foregroundStyle(Palette.accent).frame(minHeight: 30)
                }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .sheet(isPresented: $showingDetails) { AIRequestHistoryView(state: state) }
        }
    }
}

struct AIRequestHistoryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var state: AIProgressObservableState
    @State private var savedRequests: [AIRequestHistoryRecord] = []
    private var currentRequests: [AIProgressPresentationState.Request] {
        state.value.bookID == store.bookID ? state.value.requests : []
    }
    private var representedRequestIDs: Set<String> {
        Set(currentRequests.map { $0.id.uuidString }).union(savedRequests.map(\.id))
    }
    private var otherOperations: [ToolAudit] {
        let represented = representedRequestIDs
        return Array((store.book?.audit ?? []).filter { $0.requestID.map { !represented.contains($0) } ?? true }.suffix(200).reversed())
    }
    private func requestStatus(_ request: AIProgressPresentationState.Request) -> String {
        if request.finishedAt != nil { return "模型已返回" }
        if state.value.isRunning { return "进行中" }
        return state.value.status == .paused ? "已停止，未返回" : "未完成"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("请求记录", systemImage: "clock.arrow.circlepath").font(.system(size: 17, weight: .semibold))
                Spacer(); DockIconButton(title: "关闭请求记录", icon: "xmark") { dismiss() }
            }.padding(.horizontal, 20).frame(height: 56)
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if currentRequests.isEmpty && savedRequests.isEmpty && (store.book?.audit.isEmpty ?? true) {
                        EmptyState(title: "还没有请求记录", detail: "分析或提问后，可在这里查看过程与结果。", icon: "clock.arrow.circlepath")
                            .frame(minHeight: 260)
                    }
                    ForEach(currentRequests.reversed()) { request in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("思考 \(request.reasoning) · 输出 \(request.output) 字符").font(.system(size: 12)).foregroundStyle(.secondary)
                                ForEach(state.value.toolSteps.filter { $0.requestID.map { $0 == request.id } ?? ($0.requestNumber == request.number) }) { step in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: step.succeeded == true ? "checkmark.circle.fill" : step.succeeded == false ? "exclamationmark.circle" : "clock").foregroundStyle(Palette.accent)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(step.title)
                                            if step.succeeded == nil && !step.requiresReview && !state.value.isRunning {
                                                Text("未完成").font(.system(size: 12)).foregroundStyle(.secondary)
                                            }
                                            if !step.summary.isEmpty { Text(step.summary).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled) }
                                        }
                                    }
                                }
                            }.padding(.top, 10)
                        } label: {
                            HStack { Text("第 \(request.number) 次请求"); Spacer(); Text(requestStatus(request)).foregroundStyle(.secondary) }
                        }.padding(14).background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if !savedRequests.isEmpty { Text("以前的请求").font(.system(size: 14, weight: .semibold)).padding(.top, 6) }
                    ForEach(savedRequests.reversed()) { request in
                        DisclosureGroup(request.title + " · 第 \(request.number) 次请求") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(request.startedAt, style: .date).font(.system(size: 12)).foregroundStyle(.secondary)
                                Text("\(max(0, Int(request.finishedAt.timeIntervalSince(request.startedAt)))) 秒 · 思考 \(request.reasoningCharacters) · 输出 \(request.answerCharacters) 字符").font(.system(size: 13))
                                ForEach((store.book?.audit ?? []).filter { $0.requestID == request.id }) { audit in
                                    Text(AIProgressPresentationState.toolTitle(audit.name)).font(.system(size: 14, weight: .medium))
                                    ForEach(audit.resultDetails ?? [], id: \.self) { Text($0).font(.system(size: 13)).foregroundStyle(.secondary) }
                                }
                            }.padding(.top, 8)
                        }.padding(12)
                    }
                    if !otherOperations.isEmpty { Text("其他已保存操作").font(.system(size: 14, weight: .semibold)).padding(.top, 6) }
                    ForEach(otherOperations) { audit in
                        DisclosureGroup(AIProgressPresentationState.toolTitle(audit.name)) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(audit.createdAt, style: .date).font(.system(size: 12)).foregroundStyle(.secondary)
                                ForEach(audit.resultDetails ?? [], id: \.self) { Text($0).font(.system(size: 14)) }
                                Text(audit.summary).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                            }.padding(.top, 8)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(20)
            }
        }.frame(minWidth: 460, idealWidth: 640, minHeight: 380, idealHeight: 600).readingGlass(radius: 22, prominent: true)
            .task(id: store.bookID) {
                savedRequests = []
                guard let id = store.bookID else { return }
                let records = try? await store.repository.aiRequestHistory(bookID: id)
                guard store.bookID == id, !Task.isCancelled else { return }
                let currentIDs = Set(currentRequests.map { $0.id.uuidString })
                savedRequests = (records ?? []).filter { !currentIDs.contains($0.id) }
            }
    }
}
