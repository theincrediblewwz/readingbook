import SwiftUI
import ReadingCore

struct SmartReadingProgressPanel: View {
    var maximumExpandedHeight: CGFloat = 360
    @EnvironmentObject private var store: AppStore
    @Environment(\.readingReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var minimized = false
    private var session: SmartReadingSession? { store.book?.smartReading }
    private var progress: SmartReadingProgress? { store.smartReadingProgress }
    private var awaiting: Bool { store.book?.bookSchemes?.pending != nil }
    private var currentReceipts: [ParagraphReceipt] {
        guard let book = store.book, let id = progress?.currentUnitID,
              let unit = book.units.first(where: { $0.id == id }) else { return [] }
        return (try? ReadingLedger.receipts(for: unit, in: book)) ?? []
    }
    private var title: String {
        if store.aiProgress.isRunning && store.aiProgress.bookID == store.bookID { return store.aiProgress.title }
        if store.isSmartReadingRunning { return session?.status == .planning ? "正在制定阅读方案" : "正在分析" }
        if awaiting { return "阅读方案待确认" }
        if session?.status == .completed { return "本轮已结束" }
        return session == nil ? "智能阅读" : "智能阅读已暂停"
    }
    private var compactTitle: String {
        if store.isSmartReadingRunning { return session?.status == .planning ? "制定方案" : "分析中" }
        if awaiting { return "待确认" }
        return session?.status == .completed ? "已结束" : session == nil ? "智能阅读" : "已暂停"
    }
    private var statusIcon: String {
        (store.isSmartReadingRunning || store.aiProgress.isRunning) ? "sparkles" : session?.status == .completed ? "checkmark.circle" : "book.pages"
    }
    private var countText: String? {
        guard let progress, session?.isPlanConfirmed == true else { return nil }
        return "\(progress.completed)/\(progress.total)"
    }
    var body: some View {
      Group {
        if minimized {
            Button { minimized = false; expanded = true } label: {
                Image(systemName: statusIcon).font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.accent)
                    .frame(width: 52, height: 52).contentShape(Circle())
            }.buttonStyle(.plain).readingGlass(radius: 26, interactive: true)
                .help("\(title)；点击展开进度")
                .accessibilityLabel("展开智能阅读进度")
                .accessibilityValue(title + (countText.map { "，已处理 " + $0 } ?? ""))
                .contextMenu {
                    if store.isSmartReadingRunning || store.aiProgress.isRunning { Button("停止任务，保留已保存内容") { store.pause() } }
                }
        } else {
        VStack(spacing: 0) {
            compactHeader
            if expanded, let progress, session?.isPlanConfirmed == true {
                Divider().opacity(0.3)
                ScrollView {
                  VStack(alignment: .leading, spacing: 12) {
                    if store.aiProgress.hasActivity, store.aiProgress.bookID == store.bookID {
                        AIProgressStatusView(state: store.aiProgressState)
                        Divider().opacity(0.3)
                    }
                    if let scope = session?.scopeTitle { Text(scope).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    statusRow("预读并确定阅读方案", completed: store.book?.plan != nil && !awaiting)
                    if progress.isStandardAnalysis {
                        statusRow("已分析 · \(progress.completed)/\(progress.total)", completed: progress.completed == progress.total)
                    } else {
                        statusRow("逐段核对 · \(progress.receiptCount)/\(progress.receiptTotal)", completed: progress.receiptTotal > 0 && progress.receiptCount == progress.receiptTotal)
                    }
                    if progress.excludedCount > 0 || progress.blankCount > 0 {
                        Text("\(progress.excludedCount) 个片段暂缓未读，\(progress.blankCount) 个片段由你确认空白。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !progress.currentStepTitle.isEmpty { Text(progress.currentStepTitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(Array(currentReceipts.suffix(4))) { receipt in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                                    Text(receipt.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                            ForEach(progress.steps) { step in statusRow(step.title, completed: step.isCompleted) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    if let message = session?.lastMessage { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
                    Text("已保存的处理状态；你仍可翻页阅读。").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button { store.requestedWorkspaceRoute = awaiting ? "book.scheme" : "workflow" } label: { Text(awaiting ? "确认方案" : "阅读方案") }.buttonStyle(ReadingToolbarButtonStyle())
                        Spacer(minLength: 0)
                        if !store.isBusy && !awaiting && session?.status != .completed { Button { store.startReading() } label: { Label("继续", systemImage: "play.fill") }.buttonStyle(ReadingToolbarButtonStyle(selected: true)) }
                        resultMenu
                    }
                  }.padding(17)
                }.frame(maxHeight: maximumExpandedHeight)
            } else if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    if store.aiProgress.hasActivity, store.aiProgress.bookID == store.bookID { AIProgressStatusView(state: store.aiProgressState) }
                    if session != nil || !store.aiProgress.hasActivity {
                      Text(session?.lastMessage ?? (awaiting ? "预读不计入正文覆盖。确认方案后，才开始所选范围的逐段分析。" : "上次预读尚未确认，可重新制定方案，原文与已有分析仍保留。"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4)
                    Button { store.requestedWorkspaceRoute = awaiting ? "book.scheme" : "workflow" } label: { Label(awaiting ? "查看并确认方案" : "重新设置范围", systemImage: "slider.horizontal.3") }.buttonStyle(ReadingToolbarButtonStyle())
                    }
                }.padding(17)
            }
        }.frame(width: expanded ? 306 : 260).readingGlass(radius: expanded ? 23 : 26)
        }
      }
            .onChange(of: store.bookID) { _, _ in expanded = false; minimized = false }
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: expanded)
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: minimized)
    }
    private var compactHeader: some View {
        HStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: statusIcon).font(.system(size: 18)).foregroundStyle(Palette.accent)
                    Text(expanded ? "智能阅读" : store.aiProgress.isRunning && store.aiProgress.bookID == store.bookID ? store.aiProgress.phaseTitle : compactTitle).font(.system(size: 14, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    if let countText { Text(countText).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85).layoutPriority(1) }
                }.padding(.leading, 15).padding(.trailing, 5).frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
            }.buttonStyle(.plain).help("\(title)；点击\(expanded ? "收起" : "展开")检查点")
                .accessibilityLabel(expanded ? "收起智能阅读详情" : "展开智能阅读详情")
                .accessibilityValue(title + (countText.map { "，已处理 " + $0 } ?? ""))
            if store.isSmartReadingRunning || (store.aiProgress.isRunning && store.aiProgress.bookID == store.bookID) {
                Button { store.pause() } label: { Image(systemName: "pause") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("停止任务，保留已保存内容").accessibilityLabel("停止任务")
            }
            Button { expanded = false; minimized = true } label: { Image(systemName: "minus") }
                .buttonStyle(ReadingToolbarButtonStyle()).help("缩为悬浮图标，不影响分析").accessibilityLabel("缩为智能阅读图标")
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
            .menuStyle(.borderlessButton).help("查看已创建的组件")
    }
}
