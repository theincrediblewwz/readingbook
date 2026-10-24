import SwiftUI
import ReadingCore

/// The synchronous final drain prevents an already-received final counter from
/// being lost when the caller finishes before a queued MainActor UI update.
fileprivate final class AIProgressMailbox: Equatable, @unchecked Sendable {
    let finishAction: @Sendable () async -> Void
    private let lock = NSLock()
    private var events: [AIProgressEvent] = []
    private var scheduled = false
    private var closed = false
    init(finishAction: @escaping @Sendable () async -> Void) { self.finishAction = finishAction }
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
    }
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
    var reasoningCharacters: Int { priorReasoning + requestReasoning }
    var answerCharacters: Int { priorAnswer + requestAnswer }
    var receivedBytes: Int { priorBytes + requestBytes }
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
        if event.phase == .waitingForResponse, let id = event.requestID, id != activeRequestID {
            priorReasoning += requestReasoning; priorAnswer += requestAnswer; priorBytes += requestBytes
            requestReasoning = 0; requestAnswer = 0; requestBytes = 0; activeRequestID = id
        }
        if let id = event.requestID, id != activeRequestID { return }
        phase = event.phase
        if let number = event.requestNumber { requestNumber = max(requestNumber, number) }
        if let count = event.reasoningCharacters { requestReasoning = max(requestReasoning, count) }
        if let count = event.answerCharacters { requestAnswer = max(requestAnswer, count) }
        if let count = event.receivedBytes { requestBytes = max(requestBytes, count) }
        if event.phase == .performingTool {
            toolName = event.toolName; toolIndex = event.toolIndex; toolTotal = event.toolTotal
            toolSteps.append(ToolStep(title: Self.toolTitle(event.toolName), succeeded: nil))
            if toolSteps.count > 8 { toolSteps.removeFirst(toolSteps.count - 8) }
        } else if event.phase == .toolCompleted {
            let requiresReview = event.toolStatus == "needs_confirmation"
            if let index = toolSteps.lastIndex(where: { $0.succeeded == nil && !$0.requiresReview }) {
                toolSteps[index].requiresReview = requiresReview
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

@MainActor extension AppStore {
    @discardableResult func beginAIProgress(title: String, ocr: Bool = false) async -> UUID {
        let runID = UUID(), sourceBookID = bookID
        _ = aiProgress.mailbox?.take(close: true)
        let frozenRepository = repository
        let mailbox = AIProgressMailbox {
            if let sourceBookID { _ = try? await frozenRepository.refreshReadableViews(id: sourceBookID, archived: false) }
        }
        var value = AIProgressPresentationState()
        value.mailbox = mailbox
        value.runID = runID; value.bookID = sourceBookID; value.title = title; value.startedAt = Date(); value.status = .running
        aiProgress = value
        let handler: AIProgressHandler = { [weak self] event in
            guard mailbox.append(event) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.aiProgress.runID == runID, self.bookID == sourceBookID, self.aiProgress.isRunning else { return }
                self.flushAIProgress(runID)
            }
        }
        if ocr { await pdfOCRReader.setProgressHandler(handler) }
        else { await reader.setProgressHandler(handler) }
        return runID
    }
    func markAIProgressSaving(_ runID: UUID) {
        guard aiProgress.runID == runID, aiProgress.isRunning else { return }
        flushAIProgress(runID)
        aiProgress.phase = .saving
    }
    func updateAIProgressDetail(_ runID: UUID, detail: String) {
        guard aiProgress.runID == runID, aiProgress.isRunning else { return }
        aiProgress.detail = String(detail.prefix(160))
    }
    func finishAIProgress(_ runID: UUID, error: Error? = nil) {
        guard aiProgress.runID == runID, aiProgress.isRunning else { return }
        flushAIProgress(runID, close: true)
        let finishAction = aiProgress.mailbox?.finishAction
        Task { await finishAction?() }
        aiProgress.finishedAt = Date()
        if let error {
            aiProgress.status = error is CancellationError || (error as? URLError)?.code == .cancelled || error is ReadingWorkflowBudgetPause ? .paused : .failed
        } else { aiProgress.status = .completed }
    }
    private func flushAIProgress(_ runID: UUID, close: Bool = false) {
        guard aiProgress.runID == runID else { return }
        let events = aiProgress.mailbox?.take(close: close) ?? []
        guard !events.isEmpty else { return }
        var value = aiProgress
        for event in events { value.apply(event) }
        aiProgress = value
    }
}

struct AIProgressStatusView: View {
    @ObservedObject var state: AIProgressObservableState
    var compact = false
    @Environment(\.readingReduceMotion) private var reduceMotion
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
                                Text(step.title).font(.system(size: 12)).lineLimit(1)
                                if step.requiresReview { Text("审阅后应用").font(.system(size: 11)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
