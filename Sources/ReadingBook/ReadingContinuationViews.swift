import SwiftUI
import ReadingCore

extension ReadingContinuationIntent {
    var readerTitle: String {
        switch self {
        case .continueMissing: return "继续补齐"
        case .supplement: return "继续并补充"
        case .reanalyze: return "重新分析"
        }
    }
    var readerDetail: String {
        switch self {
        case .continueMissing: return "沿用兼容的已完成分析，只处理缺口和未完成项目。"
        case .supplement: return "保留原有成果，按下方选择补充组件或阅读步骤。"
        case .reanalyze: return "在所选范围生成新版本；旧分析与笔记保留。"
        }
    }
}

/// One live hierarchy: changing width never constructs a second set of controls.
struct ReadingContinuationIntentPicker: View {
    @Binding var selection: ReadingContinuationIntent
    var body: some View {
        SettingsContentGroup {
            intentRow(.continueMissing, isDefault: true)
            SettingsGroupDivider()
            intentRow(.supplement)
            SettingsGroupDivider()
            intentRow(.reanalyze)
        }.accessibilityElement(children: .contain).accessibilityLabel("本次分析方式")
    }
    private func intentRow(_ intent: ReadingContinuationIntent, isDefault: Bool = false) -> some View {
        HStack(spacing: 0) {
            Button { selection = intent } label: {
                HStack(spacing: 11) {
                    Image(systemName: selection == intent ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 18)).foregroundStyle(selection == intent ? Palette.accent : Color.secondary.opacity(0.55))
                        .frame(width: 22)
                    HStack(spacing: 6) {
                        Text(intent.readerTitle).font(.system(size: 15, weight: .medium))
                        if isDefault { Text("默认").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, 15).padding(.trailing, 8).frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(ReadingQuietButtonStyle()).help(intent.readerDetail)
                .accessibilityLabel(intent.readerTitle).accessibilityHint(intent.readerDetail)
                .accessibilityValue(selection == intent ? "已选中" : "未选中")
                .accessibilityAddTraits(selection == intent ? .isSelected : [])
                .accessibilityIdentifier("reading-continuation-intent-" + intent.rawValue)
            ReadingContinuationInfoButton(title: intent.readerTitle, detail: intent.readerDetail).padding(.trailing, 9)
        }.background(selection == intent ? Palette.accent.opacity(0.045) : Color.clear)
    }
}

struct ReadingContinuationPreviewView: View {
    let preview: ReadingContinuationPreview
    var compact = false
    @State private var showsDetails = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(preview.scopeTitle).font(.system(size: compact ? 13 : 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(scopeDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsPaneFieldGrid(minimumColumnWidth: compact ? 94 : 106, spacing: 12) {
                metric("沿用", value: preview.reusedUnitCount, icon: "checkmark.circle")
                metric("首次分析", value: preview.newUnitCount, icon: "sparkles")
                metric("补齐缺项", value: preview.partialUnitCount, icon: "circle.lefthalf.filled")
                if preview.redoUnitCount > 0 { metric("生成新版本", value: preview.redoUnitCount, icon: "arrow.clockwise") }
            }
            if preview.blockedUnitCount > 0 {
                Label("\(preview.blockedUnitCount) 个内容单元需先处理来源问题", systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(Palette.copper).fixedSize(horizontal: false, vertical: true)
            }
            if preview.incompatibleUnitCount > 0 {
                Label("\(preview.incompatibleUnitCount) 个内容单元的旧成果与本次要求不同", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if preview.pendingScopeJobCount > 0 {
                HStack(spacing: 7) {
                    Label("已启用的范围步骤 · \(preview.pendingScopeJobCount) 项待保存", systemImage: "text.alignleft")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    ReadingContinuationInfoButton(title: "范围步骤", detail: "执行当前方案已经启用的章末或本轮结束步骤，包括已选的总结、提取或核对。它们会等待相关前置成果保存齐全，不会重新生成已沿用的逐页讲解，也不会自动增加总结。")
                }
            }
            if !preview.detailRows.isEmpty {
                Button { showsDetails.toggle() } label: {
                    Label("处理详情", systemImage: "info.circle")
                        .font(.system(size: 12)).frame(minHeight: 30)
                }.buttonStyle(.borderless).help("查看哪些内容可沿用，哪些需要补齐；不会发起模型请求。")
                    .accessibilityValue(showsDetails ? "已展开" : "已收起")
                    .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("本次处理安排").font(.system(size: 15, weight: .semibold))
                                Spacer(minLength: 10)
                                DockIconButton(title: "关闭处理详情", icon: "xmark") { showsDetails = false }
                            }
                            ReadingContinuationPopoverScroll(maximumHeight: 320) {
                                VStack(alignment: .leading, spacing: 13) {
                                    ForEach(preview.detailRows) { row in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(row.title).font(.system(size: 13, weight: .medium))
                                            Text(row.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(16).frame(width: 350).background(Palette.paper)
                            .clipShape(RoundedRectangle(cornerRadius: 14)).onExitCommand { showsDetails = false }
                    }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("reading-continuation-preview")
    }
    private var scopeDetail: String {
        var parts = ["所选 \(preview.selectedUnitCount) 个内容单元"]
        if let pageCount = preview.selectedPageCount { parts.insert("涉及 \(pageCount) 页", at: 0) }
        parts.append("待执行 \(preview.pendingChunkCount) 个工作块")
        return parts.joined(separator: " · ")
    }
    private func metric(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.system(size: 12)).foregroundStyle(.secondary)
            Text("\(value)").font(.system(size: compact ? 20 : 24, weight: .medium, design: .rounded)).monospacedDigit()
            Text("内容单元").font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReadingContinuationInfoButton: View {
    let title: String
    let detail: String
    @State private var isPresented = false
    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }.buttonStyle(ReadingQuietButtonStyle()).help(detail).accessibilityLabel(title + "说明")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Text(title).font(.system(size: 15, weight: .semibold))
                        Spacer(minLength: 10)
                        DockIconButton(title: "关闭说明", icon: "xmark") { isPresented = false }
                    }
                    ReadingContinuationPopoverScroll(maximumHeight: 300) {
                        Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(16).frame(width: 310).background(Palette.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 14)).onExitCommand { isPresented = false }
            }
    }
}

/// Popovers keep short help short, while long provenance/reason lists remain
/// scrollable. Measure the same content tree, never a duplicate native control.
private struct ReadingContinuationPopoverScroll<Content: View>: View {
    var maximumHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 80
    var body: some View {
        ScrollView {
            content().background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ReadingContinuationPopoverHeightKey.self, value: geometry.size.height)
                }
            }
        }.frame(height: min(maximumHeight, max(24, contentHeight)))
            .onPreferenceChange(ReadingContinuationPopoverHeightKey.self) { value in
                guard value.isFinite, value > 0, abs(value - contentHeight) > 0.5 else { return }
                contentHeight = value
            }
    }
}
private struct ReadingContinuationPopoverHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ReadingContinuationSavedProgressView: View {
    let available: Int
    let total: Int
    let inherited: Int
    let newlySaved: Int
    let blocked: Int
    let scopeSummary: String
    var wholeBookSummary: String?
    var hasBaselineDetails = false
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            Text(scopeSummary).font(.system(size: compact ? 12 : 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: Double(max(0, min(available, total))), total: Double(max(1, total))).tint(Palette.accent)
                .accessibilityLabel("本次范围已保存")
                .accessibilityValue("\(available) / \(total) 个内容单元，包含沿用")
            savedRow("本次范围已保存", value: "\(available)/\(total)", note: "个内容单元，包含沿用")
            if hasBaselineDetails {
                savedRow("沿用已完成", value: "\(inherited)", note: "个内容单元")
                savedRow("本轮新完成", value: "\(newlySaved)", note: "个内容单元")
            } else {
                Text("旧任务未记录本轮完成明细").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if blocked > 0 {
                Label("\(blocked) 个内容单元需先处理来源或执行问题", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(Palette.copper).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 6) {
                Text("已保存范围与进度").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ReadingContinuationInfoButton(title: "已保存范围与进度", detail: (wholeBookSummary.map { $0 + "\n\n" } ?? "") + (hasBaselineDetails ?
                    "只统计已验证并保存的成果。本次范围的覆盖包含沿用成果；本轮新完成仅统计这次执行后真正完成全部本地要求的内容单元，不代表网络返回数或每个阶段的保存次数。模型返回不等于校验或保存完成。" :
                    "这个旧任务没有记录开始时的完整基线，因此不追溯猜测沿用和本轮新完成的数量。这里只显示可以证明已保存的本次范围进度，模型返回不等于校验或保存完成。"))
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("reading-continuation-saved-progress")
    }
    private func savedRow(_ title: String, value: String, note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).fontWeight(.medium).monospacedDigit()
            if !compact { Text(note).foregroundStyle(.secondary) }
        }.font(.system(size: compact ? 12 : 13)).accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) \(value) \(note)")
    }
}

/// The item supplied by the caller is immutable, so a sheet dismissal cannot
/// clear the owner or selection before its confirmation closure runs.
struct ReadingContinuationConfirmationView: View {
    let preview: ReadingContinuationPreview
    var canConfirm: Bool
    var onCancel: () -> Void
    var onConfirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("确认重新分析", systemImage: "arrow.clockwise").font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 12)
                DockIconButton(title: "取消重新分析", icon: "xmark", action: onCancel)
            }.padding(20)
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ReadingContinuationPreviewView(preview: preview)
                    Text("只针对以上范围和当前选择生成新版本。原书、笔记和旧分析保留；新结果成功保存前，旧成果仍然可用。取消或失败不会清空旧内容。")
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !canConfirm {
                        Label("书本、范围或设置已变化，请返回查看新的处理预览。", systemImage: "exclamationmark.circle")
                            .font(.system(size: 13)).foregroundStyle(Palette.copper).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(20)
            }.frame(maxHeight: 390)
            Divider().opacity(0.4)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("返回", action: onCancel).buttonStyle(SettingsActionButtonStyle()).keyboardShortcut(.cancelAction)
                Button("确认生成新版本", action: onConfirm).buttonStyle(SettingsActionButtonStyle(prominent: true))
                    .disabled(!canConfirm).accessibilityIdentifier("reading-continuation-confirm-redo")
            }.padding(16)
        }.frame(minWidth: 440, idealWidth: 520).background(Palette.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
