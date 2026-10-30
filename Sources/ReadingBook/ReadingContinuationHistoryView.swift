import SwiftUI
import AppKit
import ReadingCore

/// History is a reader. It cannot switch the active generation, resume a task,
/// rewrite a document, or resolve an old unit ID against a newer source.
struct ReadingContinuationHistoryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ReadingContinuationHistoryEntry] = []
    @State private var selectedID: String?
    @State private var detail: ReadingContinuationHistoryDetail?
    @State private var expandedRecords = Set<String>()
    @State private var listError: String?
    @State private var detailError: String?
    @State private var isLoading = true
    @State private var isLoadingDetail = false
    private struct Owner: Hashable {
        var root: URL
        var bookID: String?
        var sourceHash: String?
        var revision: Int
    }
    private struct DetailRequest: Hashable {
        var owner: Owner
        var selectedID: String?
    }
    private var owner: Owner {
        Owner(root: store.libraryRootURL, bookID: store.bookID, sourceHash: store.book?.sourceHash, revision: store.projectRevision)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label("分析历史", systemImage: "clock.arrow.circlepath").font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 0)
                ReadingContinuationInfoButton(title: "分析历史", detail: "这里展示过去的范围、任务状态和保留的分析正文。查看历史不会调用模型，也不会切换当前分析或改变原书、笔记及图谱布局。任务结束不表示其中所有分析要求均已完成。")
                DockIconButton(title: "关闭分析历史", icon: "xmark") { dismiss() }
            }.padding(.horizontal, 18).frame(height: 56)
            Divider().opacity(0.4)
            HStack(alignment: .top, spacing: 0) {
                historyList.frame(width: 218)
                Divider().opacity(0.4)
                historyDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: 700, height: 520).background(Palette.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .task(id: owner) { await loadHistory() }
            .task(id: DetailRequest(owner: owner, selectedID: selectedID)) { await loadDetail() }
            .onChange(of: store.bookID) { _, _ in dismiss() }
            .onChange(of: store.libraryRootURL) { _, _ in dismiss() }
            .onExitCommand { dismiss() }
            .accessibilityIdentifier("reading-continuation-history")
    }
    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if isLoading { ProgressView("读取本地记录…").font(.system(size: 12)).padding(10) }
                else if let listError { Text(listError).font(.system(size: 12)).foregroundStyle(Palette.copper).padding(10) }
                else if entries.isEmpty { Text("还没有历史任务。调整范围或重新分析后，过去的任务和分析会保留在这里。")
                        .font(.system(size: 13)).foregroundStyle(.secondary).padding(10) }
                ForEach(entries) { entry in
                    Button {
                        guard selectedID != entry.id else { return }
                        selectedID = entry.id; detail = nil; expandedRecords = []
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.scopeTitle).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            Text(entry.intent?.readerTitle ?? "原有分析任务").font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(entry.updatedAt, style: .date).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(entry.status.displayTitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedID == entry.id ? Palette.accent.opacity(0.09) : Palette.paper,
                                in: RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selectedID == entry.id ? Palette.accent.opacity(0.5) : Palette.line, lineWidth: 1) }
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).help("查看这次任务保留的分析，不切换当前版本。")
                        .accessibilityAddTraits(selectedID == entry.id ? .isSelected : [])
                        .accessibilityIdentifier("reading-history-session-" + entry.id)
                }
            }.padding(12)
        }
    }
    @ViewBuilder private var historyDetail: some View {
        if selectedID == nil {
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 28)).foregroundStyle(Palette.accent.opacity(0.7))
                Text("选择一次历史任务").font(.system(size: 15, weight: .medium))
                Text("点击后读取正文；当前分析保持不变。").font(.system(size: 12)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoadingDetail {
            ProgressView("读取已保存的分析…").font(.system(size: 13)).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detailError {
            Text(detailError).font(.system(size: 13)).foregroundStyle(Palette.copper).padding(20)
        } else if let detail {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(detail.entry.scopeTitle).font(.system(size: 16, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detail.entry.generationID.map { "分析版本 · " + String($0.prefix(12)) } ?? "原有分析流程")
                            .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        Label(detail.entry.isSourceCurrent ? "来源与当前原文一致" : "历史原文版本，仅查看分析",
                            systemImage: detail.entry.isSourceCurrent ? "checkmark.shield" : "clock")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("\(detail.entry.checkpointCount) 条保留分析 · \(detail.entry.legacyInsightCount) 条旧流程内容")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if !detail.warnings.isEmpty {
                        HStack(alignment: .center, spacing: 6) {
                            Label(detail.entry.missingCheckpointCount > 0 ? "部分历史引用不可用" : "历史记录说明", systemImage: "info.circle")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            ReadingContinuationInfoButton(title: "历史记录说明", detail: detail.warnings.joined(separator: "\n\n"))
                        }
                    }
                    ForEach(Array(detail.checkpoints.enumerated()), id: \.element.id) { index, checkpoint in
                        historyRecord(id: "checkpoint:" + checkpoint.id, title: "已保存分析 \(index + 1)",
                            date: checkpoint.updatedAt, markdown: checkpoint.markdown)
                    }
                    ForEach(Array(detail.legacyInsights.enumerated()), id: \.element.id) { index, insight in
                        historyRecord(id: "legacy:" + insight.id, title: "旧流程内容 \(index + 1)", date: insight.createdAt, markdown: insight.markdown)
                    }
                    if detail.checkpoints.isEmpty && detail.legacyInsights.isEmpty {
                        Text("这次任务没有可查看的正文记录；不会用当前结果替代历史分析。")
                            .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(18)
            }
        }
    }
    private func historyRecord(id: String, title: String, date: Date, markdown: String) -> some View {
        SettingsContentGroup {
            HStack(spacing: 5) {
                Button {
                    if expandedRecords.contains(id) { expandedRecords.remove(id) } else { expandedRecords.insert(id) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 13, weight: .medium))
                        HStack(spacing: 6) {
                            Text(date, style: .time)
                            Text(expandedRecords.contains(id) ? "收起全文" : "查看全文")
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 46, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("展开完整的历史 Markdown，保留公式和文本选择。")
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(markdown, forType: .string)
                } label: { Image(systemName: "doc.on.doc").frame(width: 30, height: 30) }
                    .buttonStyle(.borderless).help("复制完整 Markdown").accessibilityLabel("复制" + title + "的完整 Markdown")
            }.padding(.horizontal, 12)
            if expandedRecords.contains(id) {
                SettingsGroupDivider()
                RichMarkdownView(markdown: markdown, presentationActiveOverride: true)
                    .environment(\.openURL, OpenURLAction { url in
                        // Historical prose cannot authorize a jump against a
                        // newer current unit ID. External links retain normal handling.
                        ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
                    }).padding(12)
            }
        }
    }
    private func loadHistory() async {
        let requested = owner
        guard let snapshot = store.book else { entries = []; isLoading = false; return }
        isLoading = true; listError = nil
        do {
            let worker = Task.detached(priority: .utility) { try ReadingContinuationRuntime.history(in: snapshot) }
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, requested == owner else { return }
            entries = result; isLoading = false
            if let selectedID, !result.contains(where: { $0.id == selectedID }) { self.selectedID = nil; detail = nil }
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, requested == owner else { return }
            listError = error.localizedDescription; isLoading = false
        }
    }
    private func loadDetail() async {
        let requested = DetailRequest(owner: owner, selectedID: selectedID)
        guard let id = selectedID, let snapshot = store.book else { detail = nil; isLoadingDetail = false; return }
        isLoadingDetail = true; detailError = nil
        do {
            let worker = Task.detached(priority: .utility) { try ReadingContinuationRuntime.historyDetails(sessionID: id, in: snapshot) }
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, requested == DetailRequest(owner: owner, selectedID: selectedID) else { return }
            detail = result; isLoadingDetail = false
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, requested == DetailRequest(owner: owner, selectedID: selectedID) else { return }
            detailError = error.localizedDescription; isLoadingDetail = false
        }
    }
}
