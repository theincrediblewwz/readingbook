import SwiftUI
import ReadingCore

struct SmartReadingProgressPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    private var session: SmartReadingSession? { store.book?.smartReading }
    private var progress: SmartReadingProgress? { store.smartReadingProgress }
    private var awaiting: Bool { store.book?.bookSchemes?.pending != nil }
    private var currentReceipts: [ParagraphReceipt] {
        guard let book = store.book, let id = progress?.currentUnitID,
              let unit = book.units.first(where: { $0.id == id }) else { return [] }
        return (try? ReadingLedger.receipts(for: unit, in: book)) ?? []
    }
    private var title: String {
        if store.isSmartReadingRunning { return session?.status == .planning ? "正在制定阅读方案" : "正在分析" }
        if awaiting { return "阅读方案待确认" }
        if session?.status == .completed { return "本轮已结束" }
        return session == nil ? "为这本书开启智能阅读" : "智能阅读已暂停"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button {
                    if session == nil { store.requestedWorkspaceRoute = "workflow" }
                    else { withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { expanded.toggle() } }
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: store.isSmartReadingRunning ? "sparkles" : session?.status == .completed ? "checkmark.circle" : "book.pages").font(.system(size: 20)).foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                            if let progress, session?.isPlanConfirmed == true {
                                Text("\(session?.scopeTitle ?? "本轮") · 已处理 \(progress.completed)/\(progress.total)")
                                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                                ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))).tint(Palette.accent).frame(height: 3)
                            } else { Text(session?.scopeTitle ?? "选择方式与范围，随时可以开始").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: session == nil ? "chevron.right" : expanded ? "chevron.down" : "chevron.up").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }.padding(.vertical, 14).padding(.leading, 17).padding(.trailing, 8).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(session == nil ? "设置智能阅读" : "展开或收起智能阅读状态")
                if store.isSmartReadingRunning {
                    Button { store.pause() } label: { Image(systemName: "pause") }.buttonStyle(ReadingToolbarButtonStyle()).help("暂停分析，保留检查点").padding(.trailing, 7)
                }
            }
            if expanded, let progress, session?.isPlanConfirmed == true {
                Divider().opacity(0.3)
                VStack(alignment: .leading, spacing: 12) {
                    statusRow("预读并确定阅读方案", completed: store.book?.plan != nil && !awaiting)
                    statusRow("逐段阅读 · \(progress.receiptCount)/\(progress.receiptTotal)", completed: progress.receiptTotal > 0 && progress.receiptCount == progress.receiptTotal)
                    if progress.excludedCount > 0 || progress.blankCount > 0 {
                        Text("\(progress.excludedCount) 个片段暂缓未读，\(progress.blankCount) 个片段由你确认空白。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !progress.currentStepTitle.isEmpty { Text(progress.currentStepTitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(Array(currentReceipts.suffix(4))) { receipt in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                                    Text(receipt.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                            ForEach(progress.steps) { step in statusRow(step.title, completed: step.isCompleted) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 190)
                    if let message = session?.lastMessage { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
                    Text("已保存的处理状态；你仍可翻页阅读。").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button { store.requestedWorkspaceRoute = awaiting ? "book.scheme" : "workflow" } label: { Text(awaiting ? "确认方案" : "阅读方案") }.buttonStyle(ReadingToolbarButtonStyle())
                        Spacer(minLength: 0)
                        if !store.isBusy && !awaiting && session?.status != .completed { Button { store.startReading() } label: { Label("继续", systemImage: "play.fill") }.buttonStyle(ReadingToolbarButtonStyle(selected: true)) }
                        resultMenu
                    }
                }.padding(17)
            } else if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    Text(session?.lastMessage ?? (awaiting ? "预读不计入正文覆盖。确认方案后，才开始所选范围的逐段分析。" : "上次预读尚未确认，可重新制定方案，原文与已有分析仍保留。"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button { store.requestedWorkspaceRoute = awaiting ? "book.scheme" : "workflow" } label: { Label(awaiting ? "查看并确认方案" : "重新设置范围", systemImage: "slider.horizontal.3") }.buttonStyle(ReadingToolbarButtonStyle())
                }.padding(17)
            }
        }.frame(width: 306).readingGlass(radius: 23)
            .onChange(of: store.bookID) { _, _ in expanded = false }
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: expanded)
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
