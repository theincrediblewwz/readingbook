import SwiftUI
import ReadingCore

/// Only host-validated receipts receive a check mark; source quality stays visible even while details are collapsed.
struct ReadingLedgerView: View {
    @EnvironmentObject var store: AppStore
    @State private var chosenUnitID = ""
    @State private var expanded = false
    @State private var showSteps = false
    @State private var showingUnits = false
    @State private var unitSearch = ""
    @State private var retryStepID: String?
    private var unit: SourceUnit? {
        let id = chosenUnitID.isEmpty ? (store.activeReadingUnitID ?? store.selectedUnitID) : chosenUnitID
        return store.book?.units.first { $0.id == id } ?? store.book?.units.first
    }
    var body: some View {
        if let book = store.book, let unit {
            let manifest = try? ReadingLedger.paragraphs(for: unit, in: book)
            let savedReceipts = try? ReadingLedger.receipts(for: unit, in: book)
            let requirements = try? ReadingLedger.stepRequirements(for: unit, in: book)
            let paragraphs = manifest ?? [], receipts = savedReceipts ?? []
            let acceptedIDs = Set(receipts.map(\.paragraphID))
            let status = book.coverage[unit.id]?.status ?? .pending
            let deferred = ReadingLedger.isDeferred(unitID: unit.id, in: book)
            let issueCount = receipts.filter { !$0.issues.isEmpty }.count
            VStack(alignment: .leading, spacing: 12) {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Button { showingUnits = true } label: {
                                HStack(spacing: 5) { Text(unit.locator).lineLimit(1); Image(systemName: "chevron.down").font(.caption2) }
                            }.frame(maxWidth: .infinity, alignment: .leading).help("搜索或切换要核对的原文单元")
                            Button("定位原文") { store.navigateToUnit(unit.id); store.route = "reader" }
                        }.font(.caption).controlSize(.regular)
                        if manifest != nil && paragraphs.isEmpty {
                            Text("没有可读文字，请先 OCR 或对照原页确认空白；空提取不算 AI 已读。").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(paragraphs) { paragraph in
                            paragraphRow(paragraph, receipt: receipts.first { $0.paragraphID == paragraph.id }, accepted: acceptedIDs.contains(paragraph.id))
                        }
                        if let requirements, !requirements.isEmpty {
                            stepSection(requirements, unit: unit, book: book)
                        }
                        Text("回执核对清单、文本版本与引句。原页提取与复述是否准确，仍须结合原文判断。").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 10)
                } label: {
                    HStack(spacing: 8) {
                        Label("逐段阅读账本", systemImage: "checklist").font(.system(size: 17, weight: .semibold))
                        Spacer(minLength: 0)
                        Text("\(acceptedIDs.count)/\(paragraphs.count) 段").font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(Palette.accent)
                    }
                }
                ProgressView(value: Double(acceptedIDs.count), total: Double(max(1, paragraphs.count))).tint(Palette.accent).accessibilityLabel("核验回执覆盖")
                if !expanded { Text(unit.locator).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1) }
                if manifest == nil || savedReceipts == nil {
                    warning("清单或回执校验异常，旧记录保留，请检查来源版本。")
                } else if deferred {
                    warning("已延期，尚未读取；此内容不计入已读综合。")
                } else if !paragraphs.isEmpty && receipts.isEmpty && (status == .completed || (status == .needsReview && ReadingLedger.hasReadingAnalysis(unitID: unit.id, in: book))) {
                    warning("历史结果没有逐段回执，不计作本版逐段核验。")
                }
                if let sourceWarning = unit.warning, !sourceWarning.isEmpty { warning(sourceWarning) }
                else if status == .needsReview && !deferred {
                    let message = book.coverage[unit.id]?.message ?? ""
                    warning(message.isEmpty ? "此单元仍需对照原文核对。" : message)
                }
                if status == .failed {
                    let message = book.coverage[unit.id]?.message ?? ""
                    warning(message.isEmpty ? "本单元处理失败，已保存回执保留。" : message)
                }
                if issueCount > 0 { warning("\(issueCount) 段回执记录了疑点，展开逐项核对。") }
                if let failure = (book.workflowRuns ?? []).last(where: { $0.unitID == unit.id && $0.status == .failed }) {
                    warning(failure.error ?? "步骤执行失败，检查点已保留。")
                    Button("查看失败步骤") { expanded = true; showSteps = true }.font(.caption).buttonStyle(.borderless)
                }
                if requirements == nil && book.plan != nil { warning("读书法步骤清单暂不可用，请检查当前方案。") }
            }.padding(18).readingGlass(radius: 20)
                .confirmationDialog("重置此步骤的重试预算？", isPresented: Binding(get: { retryStepID != nil }, set: { if !$0 { retryStepID = nil } })) {
                    if let id = retryStepID { Button("重置预算，保留已完成步骤") { Task { await store.resetWorkflowRetry(id, inBook: book.id); retryStepID = nil } } }
                } message: { Text("只清零失败步骤的尝试次数。已完成输出、原书与笔记保留；点击继续精读才会发出新请求。") }
                .popover(isPresented: $showingUnits, arrowEdge: .bottom) { unitPicker(book) }
                .onChange(of: store.bookID) { _, _ in chosenUnitID = ""; expanded = false; showSteps = false; showingUnits = false; unitSearch = "" }
        }
    }
    private func paragraphRow(_ paragraph: ReadingParagraph, receipt: ParagraphReceipt?, accepted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: accepted ? "checkmark.circle.fill" : "circle").foregroundStyle(accepted ? Palette.accent : .secondary)
                Text("第 \(paragraph.order + 1) \(paragraph.kind == "fragment" ? "片段" : "段") · 行 \(paragraph.lineStart)–\(paragraph.lineEnd)").lineLimit(1)
                Spacer(minLength: 0)
                Text(accepted ? "回执已核验" : "待处理").foregroundStyle(.secondary).lineLimit(1)
            }.font(.system(size: 13))
            if let receipt {
                Text(receipt.summary).font(.system(size: 16)).lineSpacing(4).textSelection(.enabled)
                ForEach(Array(receipt.issues.enumerated()), id: \.offset) { _, issue in warning(issue) }
            }
            DisclosureGroup("对照本段原文") {
                Text(paragraph.text).font(.system(size: 16, design: .monospaced)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.font(.system(size: 13)).foregroundStyle(.secondary)
        }.padding(14).background(Palette.accent.opacity(accepted ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 12))
    }
    private func warning(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(Palette.copper).lineLimit(expanded ? nil : 2).help(message)
    }
    private func stepSection(_ requirements: [ReadingStepRequirement], unit: SourceUnit, book: BookProject) -> some View {
        let results = (book.readingStepResults ?? []).filter { $0.unitID == unit.id }
        let completed = requirements.filter { step in results.contains { $0.stepID == step.stepID && $0.methodHash == step.methodHash } }.count
        return DisclosureGroup(isExpanded: $showSteps) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(requirements) { step in
                    let result = results.first { $0.stepID == step.stepID && $0.methodHash == step.methodHash }
                    let run = (book.workflowRuns ?? []).first { $0.stepID == step.stepID }
                    VStack(alignment: .leading, spacing: 6) {
                        Label(step.stepText, systemImage: result == nil ? "circle" : "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(result == nil ? .secondary : Palette.accent)
                        if let result { Text(result.result).font(.system(size: 16)).lineSpacing(4).textSelection(.enabled) }
                        else { Text("尚无本步骤结果").font(.caption).foregroundStyle(.secondary) }
                        if let run {
                            HStack {
                                Text(ReadingWorkflowRuntime.actions.first { $0.id == run.actionID }?.title ?? run.actionID)
                                Text(run.status == .completed ? "已执行" : run.status == .failed ? "执行失败" : "执行中")
                                Spacer(minLength: 4)
                                Text("尝试 \(run.attempts) 次")
                            }.font(.caption).foregroundStyle(run.status == .failed ? Palette.copper : .secondary)
                            DisclosureGroup("输入、工具与执行输出") {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("输入：本单元 \(run.input.paragraphIDs.count) 个已核对片段，\(run.input.previousStepIDs.count) 个前序步骤输出。")
                                    if !run.input.configuration.isEmpty { Text(run.input.configuration.keys.sorted().map { "\($0)：\(run.input.configuration[$0] ?? "")" }.joined(separator: "\n")) }
                                    Text(run.toolNames.isEmpty ? "尚无成功工具调用记录" : "已调用：" + run.toolNames.joined(separator: " · "))
                                    if let output = run.output {
                                        Text(output.result).textSelection(.enabled)
                                        if let reason = output.noChangesReason { Text("未新增知识：" + reason).foregroundStyle(.secondary) }
                                        ForEach(Array(output.issues.enumerated()), id: \.offset) { _, issue in warning(issue) }
                                    }
                                    if let error = run.error { warning(error) }
                                }.padding(.top, 6)
                            }.font(.caption)
                            if run.status == .failed, let execution = try? ReadingWorkflowRuntime.execution(for: step, in: book), run.attempts >= execution.maxAttempts {
                                Button("重置此步骤的重试预算…") { retryStepID = step.stepID }.font(.caption).disabled(store.isBusy)
                            }
                        } else if result != nil {
                            Text("历史步骤结果；未记录独立动作执行。").font(.caption).foregroundStyle(.secondary)
                        } else if let execution = try? ReadingWorkflowRuntime.execution(for: step, in: book) {
                            Text("待执行：" + (ReadingWorkflowRuntime.actions.first { $0.id == execution.actionID }?.title ?? execution.actionID)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(.top, 10)
        } label: { HStack { Text("读书法步骤"); Spacer(); Text("\(completed)/\(requirements.count)").monospacedDigit().foregroundStyle(.secondary) } }.font(.subheadline)
    }
    private func unitPicker(_ book: BookProject) -> some View {
        let filtered = unitSearch.isEmpty ? book.units : book.units.filter { $0.locator.localizedCaseInsensitiveContains(unitSearch) || $0.chapter.localizedCaseInsensitiveContains(unitSearch) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("选择核对单元").font(.subheadline.weight(.medium))
            TextField("搜索页码或章节", text: $unitSearch).textFieldStyle(.roundedBorder)
            Button("跟随当前阅读位置") { chosenUnitID = ""; showingUnits = false }.font(.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { item in
                        Button { chosenUnitID = item.id; showingUnits = false } label: {
                            HStack { Text(item.locator).lineLimit(2); Spacer(); if item.id == unit?.id { Image(systemName: "checkmark").foregroundStyle(Palette.accent) } }.font(.subheadline).padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if filtered.isEmpty { Text("没有匹配的原文单元").font(.caption).foregroundStyle(.secondary).padding(8) }
                }
            }.frame(maxHeight: 320)
        }.padding(14).frame(width: 330)
    }
}
