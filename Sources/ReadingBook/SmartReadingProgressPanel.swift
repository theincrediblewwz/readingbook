import SwiftUI
import ReadingCore

struct SmartReadingProgressPanel: View {
    @ObservedObject var activityState: AIProgressObservableState
    @ObservedObject var companionState: AIProgressObservableState
    @ObservedObject var queryState: AIProgressObservableState
    var maximumExpandedHeight: CGFloat = 360
    var compactInteraction: FloatingLauncherInteraction?
    var resetCompactPosition: (() -> Void)?
    @EnvironmentObject private var store: AppStore
    @Environment(\.readingReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var minimized = false
    private var session: SmartReadingSession? { store.book?.smartReading }
    private var progress: SmartReadingProgress? { store.smartReadingProgress }
    private var awaiting: Bool { store.book?.bookSchemes?.pending != nil }
    private func owns(_ value: AIProgressPresentationState) -> Bool {
        value.bookID == store.bookID && value.libraryRoot == store.libraryRootURL
    }
    private var hasCompanion: Bool { owns(companionState.value) && companionState.value.isRunning }
    private var hasQuery: Bool { owns(queryState.value) && queryState.value.isRunning }
    private var hasActivity: Bool { owns(activityState.value) && activityState.value.isRunning }
    private var readingRunning: Bool { store.isSmartReadingRunning && owns(activityState.value) }
    private var hasReading: Bool { hasActivity || readingRunning || awaiting || (!hasCompanion && !hasQuery) }
    private var headerCount: Int { (hasCompanion ? 1 : 0) + (hasQuery ? 1 : 0) + (hasReading ? 1 : 0) }
    private var detailHeight: CGFloat { max(0, maximumExpandedHeight - CGFloat(headerCount) * 52 - 1) }
    private var currentReceipts: [ParagraphReceipt] {
        guard let book = store.book, let id = progress?.currentUnitID,
              let unit = book.units.first(where: { $0.id == id }) else { return [] }
        return (try? ReadingLedger.receipts(for: unit, in: book)) ?? []
    }
    private var readingTitle: String {
        if hasActivity { return activityState.value.title }
        if readingRunning { return session?.status == .planning ? "正在制定阅读方案" : "正在分析" }
        if awaiting { return "阅读方案待确认" }
        if session?.status == .completed { return "本轮已结束" }
        return session == nil ? "智能阅读" : "智能阅读已暂停"
    }
    private var title: String {
        if headerCount > 1 { return "AI任务进度" }
        if hasCompanion { return "伴读生成" }
        if hasQuery { return "阅读对话" }
        return readingTitle
    }
    private var compactTitle: String {
        if readingRunning { return session?.status == .planning ? "制定方案" : "分析中" }
        if awaiting { return "待确认" }
        return session?.status == .completed ? "已结束" : session == nil ? "智能阅读" : "已暂停"
    }
    private var statusIcon: String {
        (hasCompanion || hasQuery || readingRunning || hasActivity) ? "sparkles" : session?.status == .completed ? "checkmark.circle" : "book.pages"
    }
    private var countText: String? {
        guard let progress, session?.isPlanConfirmed == true else { return nil }
        if let continuation = store.readingContinuationProgress {
            return "已存 \(continuation.available)/\(continuation.total)"
        }
        return "已存 \(progress.completed)/\(progress.total)"
    }
    private var progressAccessibilityValue: String {
        var values: [String] = []
        if hasCompanion { values.append("伴读：" + companionState.value.phaseTitle) }
        if hasQuery { values.append("对话：" + queryState.value.phaseTitle) }
        if hasReading { values.append(hasActivity ? readingTitle + "：" + activityState.value.phaseTitle : readingTitle) }
        if let countText, hasReading { values.append("本次范围 " + countText + " 个内容单元，包含沿用") }
        return values.joined(separator: "，")
    }
    var body: some View {
        Group {
            if minimized { minimizedControl }
            else {
                VStack(spacing: 0) {
                    if hasCompanion { laneHeader("伴读", state: companionState.value, icon: "sparkles") }
                    if hasQuery { laneHeader("对话", state: queryState.value, icon: "bubble.left.and.bubble.right") }
                    if hasReading { readingHeader }
                    if expanded, detailHeight > 0 {
                        Divider().opacity(0.3)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if hasCompanion {
                                    detailLabel("伴读生成", icon: "sparkles")
                                    AIProgressStatusView(state: companionState)
                                }
                                if hasQuery {
                                    if hasCompanion { Divider().opacity(0.3) }
                                    detailLabel("阅读对话", icon: "bubble.left.and.bubble.right")
                                    AIProgressStatusView(state: queryState)
                                }
                                if hasReading {
                                    if hasCompanion || hasQuery { Divider().opacity(0.3) }
                                    readingDetails
                                }
                            }.padding(17)
                        }.frame(maxHeight: detailHeight)
                    }
                }.frame(width: expanded ? 306 : 260).readingGlass(radius: expanded ? 23 : 26)
            }
        }
        .onChange(of: store.bookID) { _, _ in expanded = false; minimized = false }
        .onChange(of: store.libraryRootURL) { _, _ in expanded = false; minimized = false }
        .animation(ReadingMotion.animation(reduce: reduceMotion), value: expanded)
        .animation(ReadingMotion.animation(reduce: reduceMotion), value: minimized)
    }
    private func detailLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
    }
    @ViewBuilder private var readingDetails: some View {
        if owns(activityState.value), activityState.value.hasActivity { AIProgressStatusView(state: activityState) }
        if let progress, session?.isPlanConfirmed == true {
            VStack(alignment: .leading, spacing: 12) {
                if let continuation = store.readingContinuationProgress {
                    ReadingContinuationSavedProgressView(available: continuation.available, total: continuation.total,
                        inherited: continuation.inherited, newlySaved: continuation.newlySaved, blocked: continuation.blocked,
                        scopeSummary: continuation.scopeSummary, wholeBookSummary: continuation.wholeBookSummary,
                        hasBaselineDetails: continuation.hasBaselineDetails, compact: true)
                } else {
                    if let scope = session?.scopeTitle { Text(scope).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    statusRow("本次范围已保存 · \(progress.completed)/\(progress.total) 个内容单元", completed: progress.completed == progress.total)
                }
                statusRow("预读并确定阅读方案", completed: store.book?.plan != nil && !awaiting)
                if !progress.isStandardAnalysis { statusRow("逐段回执 · \(progress.receiptCount)/\(progress.receiptTotal)", completed: progress.receiptTotal > 0 && progress.receiptCount == progress.receiptTotal) }
                if progress.excludedCount > 0 || progress.blankCount > 0 {
                    Text("\(progress.excludedCount) 个片段暂缓未读，\(progress.blankCount) 个片段由你确认空白。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !progress.currentStepTitle.isEmpty { Text(progress.currentStepTitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
                ForEach(Array(currentReceipts.suffix(4))) { receipt in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                        Text(receipt.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                ForEach(progress.steps) { step in statusRow(step.title, completed: step.isCompleted) }
                if let message = session?.lastMessage { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
                HStack(spacing: 10) {
                    Button { store.requestedWorkspaceRoute = awaiting ? "book.scheme" : "workflow" } label: { Text(awaiting ? "确认方案" : "阅读方案") }
                        .buttonStyle(ReadingToolbarButtonStyle()).help("打开阅读方案和已保存的分析进度，不重新请求模型。")
                    Spacer(minLength: 0)
                    if store.canStartReading && !awaiting {
                        Button { store.requestedWorkspaceRoute = "workflow"; expanded = false } label: { Label("继续 / 调整", systemImage: "play.fill") }
                            .buttonStyle(ReadingToolbarButtonStyle(selected: true)).help("选择范围，查看沿用与缺项安排后继续；已有分析保留。")
                    }
                    resultMenu
                }
            }
        } else if session != nil || !owns(activityState.value) || !activityState.value.hasActivity {
            VStack(alignment: .leading, spacing: 12) {
                Text(session?.lastMessage ?? (awaiting ? "预读不计入正文覆盖。确认方案后，才开始所选范围的逐段分析。" : "上次预读尚未确认，可重新制定方案，原文与已有分析仍保留。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4)
                Button { store.requestedWorkspaceRoute = awaiting ? "book.scheme" : "workflow" } label: { Label(awaiting ? "查看并确认方案" : "重新设置范围", systemImage: "slider.horizontal.3") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("查看或调整阅读范围和方案；打开此页不会立即调用模型。")
            }
        }
    }
    private func expandProgress() { minimized = false; expanded = true }
    private var minimizedControl: some View {
        Button(action: expandProgress) {
            Image(systemName: statusIcon).font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.accent)
                .frame(width: 52, height: 52).contentShape(Circle())
        }.buttonStyle(ReadingQuietButtonStyle()).readingGlass(radius: 26, interactive: true)
            .overlay { minimizedPointerInput }
            .help("\(title)；点击展开进度，拖动调整位置")
            .accessibilityLabel("展开" + title + "进度").accessibilityValue(Text(progressAccessibilityValue))
            .contextMenu { minimizedActions }
    }
    @ViewBuilder private var minimizedPointerInput: some View {
        if let compactInteraction { FloatingLauncherPointerInput(interaction: compactInteraction, activate: expandProgress) }
    }
    @ViewBuilder private var minimizedActions: some View {
        if hasCompanion { Button("停止伴读，保留已保存内容") { store.cancelAIActivity(companionState.value.runID) } }
        if hasQuery { Button("停止本次对话，伴读继续") { store.cancelAIActivity(queryState.value.runID) } }
        if readingRunning { Button("暂停智能阅读，其他任务继续", action: cancelReadingActivity) }
        else if hasActivity { Button("停止本次" + readingTitle, action: cancelReadingActivity) }
        if let resetCompactPosition { Button("还原浮钮位置", action: resetCompactPosition) }
    }
    private func laneHeader(_ title: String, state: AIProgressPresentationState, icon: String) -> some View {
        HStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: icon).foregroundStyle(Palette.accent)
                    Text(title + " · " + state.phaseTitle).font(.system(size: 14, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }.padding(.leading, 15).padding(.trailing, 5).frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
            }.buttonStyle(ReadingQuietButtonStyle()).help("\(title)正在进行；点击查看模型响应与请求详情")
                .accessibilityLabel(title + "进度").accessibilityValue(Text(state.phaseTitle))
            Button { store.cancelAIActivity(state.runID) } label: { Image(systemName: "pause") }
                .buttonStyle(ReadingToolbarButtonStyle()).help("只停止本次\(title)，其他AI任务继续").accessibilityLabel("停止本次" + title)
            Button { expanded = false; minimized = true } label: { Image(systemName: "minus") }
                .buttonStyle(ReadingToolbarButtonStyle()).help("缩为进度图标，所有任务继续").accessibilityLabel("缩为任务进度图标")
        }.padding(.trailing, 4).frame(height: 52)
    }
    private func cancelReadingActivity() {
        guard owns(activityState.value) else { return }
        if readingRunning { store.pauseReading() }
        else { store.cancelAIActivity(activityState.value.runID) }
    }
    private var readingHeader: some View {
        HStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: statusIcon).font(.system(size: 18)).foregroundStyle(Palette.accent)
                    Text(expanded ? readingTitle : hasActivity ? activityState.value.phaseTitle : compactTitle)
                        .font(.system(size: 14, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    if let countText { Text(countText).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85).layoutPriority(1) }
                }.padding(.leading, 15).padding(.trailing, 5).frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
            }.buttonStyle(ReadingQuietButtonStyle()).help("\(readingTitle)；点击\(expanded ? "收起" : "展开")进度")
                .accessibilityLabel(expanded ? "收起阅读任务详情" : "展开阅读任务详情").accessibilityValue(Text(progressAccessibilityValue))
            if readingRunning || hasActivity {
                Button(action: cancelReadingActivity) { Image(systemName: "pause") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("停止这项阅读任务，伴读与对话继续").accessibilityLabel("停止本次阅读任务")
            }
            Button { expanded = false; minimized = true } label: { Image(systemName: "minus") }
                .buttonStyle(ReadingToolbarButtonStyle()).help("缩为悬浮图标，不影响任务").accessibilityLabel("缩为任务进度图标")
        }.padding(.trailing, 4).frame(height: 52)
    }
    private func statusRow(_ title: String, completed: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: completed ? "checkmark.circle.fill" : "circle").foregroundStyle(completed ? Palette.accent : Color.secondary.opacity(0.4))
            Text(title).font(.system(size: 12)).foregroundStyle(completed ? Color.primary : Color.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var resultMenu: some View {
        let views = WorkspaceComponentRegistry.shared.navigationViews(store.book?.views ?? [])
        return Menu {
            ForEach(views) { view in Button { store.requestedWorkspaceRoute = view.id } label: { Label(view.title, systemImage: view.kind.icon) } }
            if views.isEmpty { Text("适用组件会随分析创建") }
        } label: { Image(systemName: "square.grid.2x2").frame(width: 24, height: 28) }
            .menuStyle(.borderlessButton).modifier(ReadingHoverSurface()).help("查看已创建的组件，不重新生成。")
    }
}
