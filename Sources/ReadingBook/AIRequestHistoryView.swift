import SwiftUI
import ReadingCore

struct AIRequestHistoryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var state: AIProgressObservableState
    var onClose: (() -> Void)? = nil
    var usesNativeWindowSurface = false
    @State private var savedRequests: [AIRequestHistoryRecord] = []
    @State private var selectedRequestID: UUID?
    @State private var showingArchive = false

    private var currentRequests: [AIProgressPresentationState.Request] {
        state.value.bookID == store.bookID && state.value.libraryRoot == store.libraryRootURL ? state.value.requests : []
    }
    private var selectedRequest: AIProgressPresentationState.Request? {
        currentRequests.first { $0.id == selectedRequestID } ?? currentRequests.last
    }
    private var otherOperations: [ToolAudit] {
        let represented = Set(currentRequests.map { $0.id.uuidString }).union(savedRequests.map(\.id))
        return Array((store.book?.audit ?? []).filter { $0.requestID.map { !represented.contains($0) } ?? true }.suffix(200).reversed())
    }
    private func steps(_ request: AIProgressPresentationState.Request) -> [AIProgressPresentationState.ToolStep] {
        state.value.toolSteps.filter { $0.requestID.map { $0 == request.id } ?? ($0.requestNumber == request.number) }
    }
    private func status(_ request: AIProgressPresentationState.Request) -> String {
        if request.finishedAt == nil { return state.value.isRunning ? "进行中" : "未完整返回" }
        if request.response?.finishReason == "length" { return "输出被截断" }
        if steps(request).contains(where: \.requiresReview) { return "已返回 · 待审阅" }
        if steps(request).contains(where: { $0.succeeded == false }) { return "已返回 · 操作未通过" }
        return "已返回"
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("请求记录与详情", systemImage: "clock.arrow.circlepath").font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 12)
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                    .help("查看每次实际发送的内容、AI公开返回和软件执行结果。文字只保留在当前任务的有界内存中；以前的请求只保留时间与操作记录。")
                DockIconButton(title: "关闭请求记录", icon: "xmark", action: close)
            }.padding(.horizontal, 20).frame(height: 56).background(FrostWindowDragRegion())
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                requestList.frame(width: 160)
                Divider().opacity(0.35)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !showingArchive, let request = selectedRequest { requestContent(request).id(request.id) }
                        else { archiveContent }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                }.accessibilityIdentifier("ai-request-detail-content")
            }
        }.frame(minWidth: 680, idealWidth: 900, minHeight: 440, idealHeight: 660)
            .modifier(AIRequestHistorySurface(nativeWindow: usesNativeWindowSurface))
            .task(id: (store.bookID ?? "") + "|" + store.libraryRootURL.path) {
                savedRequests = []
                guard let id = store.bookID else { return }
                let root = store.libraryRootURL
                let records = try? await store.repository.aiRequestHistory(bookID: id)
                guard store.bookID == id, store.libraryRootURL == root, !Task.isCancelled else { return }
                let current = Set(currentRequests.map { $0.id.uuidString })
                savedRequests = (records ?? []).filter { !current.contains($0.id) }
            }
            .onChange(of: store.bookID) { _, _ in onClose?() }
            .onChange(of: store.libraryRootURL) { _, _ in onClose?() }
    }

    private var requestList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(currentRequests.reversed()) { request in
                        Button { selectedRequestID = request.id; showingArchive = false } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("请求 \(request.number)").font(.system(size: 14, weight: .semibold))
                                Text(status(request)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(Rectangle())
                        }.buttonStyle(ReadingQuietButtonStyle())
                            .background(!showingArchive && selectedRequest?.id == request.id ? Palette.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("查看第 \(request.number) 次请求").help("查看这次发送内容、AI返回和执行结果")
                    }
                }.padding(8)
            }
            Divider().opacity(0.3)
            Button { showingArchive = true } label: {
                Label("以前的记录", systemImage: "archivebox").font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 42)
            }.buttonStyle(ReadingQuietButtonStyle()).help("以前请求的时间、计数与已保存操作；不重新请求模型")
        }
    }

    @ViewBuilder private func requestContent(_ request: AIProgressPresentationState.Request) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("请求 \(request.number)").font(.system(size: 20, weight: .semibold))
            Text(status(request)).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        Text("\(request.output) 个输出字符 · \(max(0, Int((request.finishedAt ?? Date()).timeIntervalSince(request.startedAt)))) 秒")
            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
        if request.id == currentRequests.last?.id, !state.value.failureMessage.isEmpty {
            Text(state.value.failureMessage).font(.system(size: 13)).foregroundStyle(Palette.copper).textSelection(.enabled)
        }
        AITraceDisclosure(title: "发送给 AI", subtitle: request.trace.map { "\($0.messages.count) 条文字" } ?? "未保留文字") {
            if let trace = request.trace {
                ForEach(trace.messages) { message in
                    AITraceDisclosure(title: traceRole(message.role), subtitle: String(message.content.text.prefix(45)).replacingOccurrences(of: "\n", with: " ")) {
                        AITraceTextView(content: message.content).equatable()
                    }
                }
                if trace.omittedMessages > 0 { notice("另有 \(trace.omittedMessages) 条未保留在诊断记录中；实际发送没有因此缩短。") }
                if !trace.toolNames.isEmpty {
                    AITraceDisclosure(title: "本次可用工具", subtitle: "\(trace.toolNames.count) 项") {
                        Text(trace.toolNames.map { AIProgressPresentationState.toolTitle($0) + "（" + $0 + "）" }.joined(separator: "\n"))
                            .font(.system(size: 12)).textSelection(.enabled)
                    }
                }
            } else { notice(request.traceExpired ? "为控制内存，较早记录的文字已释放；计数和操作状态保留。" : "这次没有保留发送文字。") }
        }
        Divider().opacity(0.35)
        AITraceDisclosure(title: "AI 返回", subtitle: responseSummary(request)) {
            if let response = request.response {
                if response.finishReason == "length" { notice("模型报告输出达到上限。这是未完整结束的返回，不表示整理已经完成。") }
                if let content = response.content { AITraceTextView(content: content).equatable() }
                if let refusal = response.refusal { Text("模型未接受这次请求").font(.system(size: 13, weight: .medium)); AITraceTextView(content: refusal).equatable() }
                if response.content == nil && !response.toolCalls.isEmpty { notice("本次没有正文回答，AI 返回了以下操作请求；是否执行请看下方软件回执。") }
                ForEach(response.toolCalls) { call in
                    AITraceDisclosure(title: AIProgressPresentationState.toolTitle(call.name), subtitle: "AI 提出的操作") {
                        AITraceTextView(content: call.arguments).equatable()
                    }
                }
                if response.omittedToolCalls > 0 { notice("另有 \(response.omittedToolCalls) 项未留存在有界诊断记录中。") }
            } else { notice(request.traceExpired ? "这次返回文字已释放；计数与执行记录仍保留。" : request.finishedAt == nil && state.value.isRunning ? "模型尚未完整返回。" : "这次没有保留完整的返回文字。") }
        }
        Divider().opacity(0.35)
        Text("软件执行结果").font(.system(size: 14, weight: .semibold))
        let operations = steps(request)
        if operations.isEmpty { notice(request.response?.toolCalls.isEmpty == false ? "尚无执行回执；提出操作不等于已保存。" : "这次没有执行工具操作。") }
        ForEach(operations) { step in
            AITraceDisclosure(title: step.title, subtitle: step.requiresReview ? "待审阅，尚未应用" : step.succeeded == true ? "已返回回执" : step.succeeded == false ? "未通过" : "处理中") {
                if !step.summary.isEmpty { Text(step.summary).font(.system(size: 13)).textSelection(.enabled) }
                if let trace = step.trace {
                    ForEach(trace.fragments) { fragment in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(fragment.title).font(.system(size: 13, weight: .medium))
                            Text(fragment.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            AITraceTextView(content: AITraceText(fragment.text)).equatable()
                        }
                    }
                    AITraceDisclosure(title: "实际执行的参数") { AITraceTextView(content: trace.arguments).equatable() }
                    AITraceDisclosure(title: "软件返回的完整文字") { AITraceTextView(content: trace.result).equatable() }
                } else if step.traceExpired { notice("这条较早记录的文字已释放。") }
            }
        }
    }

    private func responseSummary(_ request: AIProgressPresentationState.Request) -> String {
        guard let response = request.response else { return request.finishedAt == nil && state.value.isRunning ? "等待返回" : "未保留文字" }
        if !response.toolCalls.isEmpty { return "\(response.toolCalls.count) 项操作请求" }
        return response.refusal != nil ? "未接受请求" : response.content != nil ? "文字回答" : "无正文"
    }
    private func notice(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func traceRole(_ role: String) -> String {
        switch role { case "system": return "软件要求"; case "user": return "问题与已分享资料"; case "assistant": return "前一轮公开回答或操作"; case "tool": return "软件返回的资料"; default: return "本次文字" }
    }
    private var archiveContent: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            Text("以前的请求与操作").font(.system(size: 18, weight: .semibold))
            notice("以前的记录保留时间、计数与操作结果，没有保存完整收发文字。")
            if savedRequests.isEmpty && otherOperations.isEmpty { EmptyState(title: "还没有以前的记录", detail: "本次请求可在左边逐条查看。", icon: "clock.arrow.circlepath") }
            ForEach(savedRequests.reversed()) { request in
                AITraceDisclosure(title: request.title + " · 第 \(request.number) 次请求", subtitle: "\(max(0, Int(request.finishedAt.timeIntervalSince(request.startedAt)))) 秒") {
                    Text(request.startedAt, style: .date).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("输出 \(request.answerCharacters) 字符").font(.system(size: 12))
                    ForEach((store.book?.audit ?? []).filter { $0.requestID == request.id }) { audit in
                        Text(AIProgressPresentationState.toolTitle(audit.name)).font(.system(size: 13, weight: .medium))
                        ForEach(audit.resultDetails ?? [], id: \.self) { Text($0).font(.system(size: 13)).foregroundStyle(.secondary) }
                    }
                }
            }
            ForEach(otherOperations) { audit in
                AITraceDisclosure(title: AIProgressPresentationState.toolTitle(audit.name)) {
                    Text(audit.createdAt, style: .date).font(.system(size: 12)).foregroundStyle(.secondary)
                    ForEach(audit.resultDetails ?? [], id: \.self) { Text($0).font(.system(size: 13)) }
                    Text(audit.summary).font(.system(size: 13)).textSelection(.enabled)
                }
            }
        }
    }
}

/// A real window already supplies its rounded edge and exterior shadow.
/// Do not draw a second glass rim inside that system frame.
private struct AIRequestHistorySurface: ViewModifier {
    let nativeWindow: Bool
    @Environment(\.readingReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if nativeWindow {
            content.background(Palette.surface.opacity(reduceTransparency ? 1 : 0.84)).background(.regularMaterial)
        } else {
            content.readingGlass(radius: 22, prominent: true)
        }
    }
}
