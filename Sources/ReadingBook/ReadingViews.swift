import SwiftUI
import PDFKit
import ReadingCore

struct ReaderWorkspaceView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.readingReduceMotion) private var reduceMotion
    @Environment(\.workspaceCanvasBlocked) private var interactionBlocked
    @Binding var showPDF: Bool
    @Binding var showOutline: Bool
    @Binding var bookmarksOnly: Bool
    @EnvironmentObject var pdfController: PDFReaderController
    @State private var outlineFrame = CGRect.zero
    @State private var companionFrame = CGRect.zero
    @StateObject private var inlineReading = ReaderInlineState()
    private var isPDF: Bool { store.sourceFileURL?.pathExtension.lowercased() == "pdf" }
    private var pdfChrome: [CGRect] {
        guard isPDF, showPDF, store.readingSourceMode == "original" else { return [] }
        return [pdfController.chromeFrame, pdfController.thumbnailFrame].filter { !$0.isEmpty && !$0.isNull }
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Group {
                    if let unit = store.selectedUnit {
                        if store.readingSourceMode != "original" {
                            ReadingParallelView(mode: store.readingSourceMode, onSourceDecorationTap: sourceTapped, onSourceDecorationHover: sourceHovered)
                        }
                        else if isPDF, showPDF, let url = store.sourceFileURL {
                            let requestToken = store.pdfNavigationToken
                            let sourceBookID = store.bookID
                            let memoryKey = store.workspaceMemoryKey
                            PDFReaderView(controller: pdfController, url: url, sourceHash: store.book?.sourceHash ?? "", page: unit.page, navigationToken: requestToken, password: store.pdfPassword(for: store.bookID), annotations: store.book?.readerAnnotations ?? [], canEditAnnotations: !store.isBusy, onPageChange: { page in
                                guard store.pdfNavigationToken == requestToken else { return }
                                if store.selectedUnit?.page != page {
                                    store.selectedUnitID = store.book?.units.first { $0.page == page }?.id
                                }
                            }, onUnlock: { password in
                                guard store.bookID == sourceBookID, store.pdfNavigationToken == requestToken, let sourceBookID else { return }
                                store.rememberPDFPassword(password, bookID: sourceBookID)
                            }, onSaveAnnotations: { annotations in
                                guard store.bookID == sourceBookID else { return false }
                                return await store.saveReaderAnnotations(annotations)
                            }, onTrashAnnotation: { id, trashed in
                                guard store.bookID == sourceBookID else { return false }
                                return await store.setReaderAnnotationTrashed(id, trashed: trashed)
                            }, sourceDecorations: store.sourceReadingDecorations,
                               focusedDecorationID: store.focusedReadingAnchorID,
                               onSourceDecorationTap: sourceTapped,
                               onSourceSelection: { selection in store.sourceReadingSelection = selection; if selection != nil { store.focusedReadingAnchorID = nil } },
                               onSourceDecorationHover: sourceHovered,
                               workspaceMemory: store.workspaceMemory.pdf, memoryRevision: store.workspaceMemoryRevision,
                               onWorkspaceMemory: { memory in store.updateWorkspaceMemory({ $0.pdf = memory }, expectedKey: memoryKey) })
                        } else { sourceText(unit) }
                    } else {
                        EmptyState(title: "选择一个章节", detail: "从阅读工具中的目录选择原文内容。", icon: "book.pages")
                    }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.paper)
                ReaderFloatingPanel(title: "目录与书签", icon: "list.bullet", width: 302, height: 560, trailing: false, isPresented: $showOutline, viewport: geometry.size, bottomReserve: 88, avoidRects: pdfChrome,
                    showsRestoreButton: false, unifiedDismiss: true,
                    onFrameChange: { value in if outlineFrame != value { outlineFrame = value } }) { ReaderOutlinePanel(bookmarksOnly: $bookmarksOnly) }
                ReaderFloatingPanel(title: "伴读与对话", icon: "sparkles", width: 376, height: 620, isPresented: $store.readingCompanionVisible, viewport: geometry.size, bottomReserve: 88,
                    avoidRects: pdfChrome + (outlineFrame.isEmpty ? [] : [outlineFrame]), elevated: true, showsRestoreButton: false, unifiedDismiss: true, resizable: true,
                    onFrameChange: { frame in if companionFrame != frame { companionFrame = frame } }) {
                    ReaderAIPanel()
                }
                ReaderInlineCard(state: inlineReading, viewport: geometry.size,
                    obstacles: pdfChrome + [outlineFrame, companionFrame].filter { !$0.isEmpty }).zIndex(9)
            }
                .coordinateSpace(name: ReaderInlineCoordinateSpace.name)
                .background {
                    let offset = geometry.frame(in: .global).origin
                    Color.clear.preference(key: WorkspaceChromeBoundsPreference.self, value: pdfChromeBounds(offset: offset)).allowsHitTesting(false)
                }
                .onChange(of: showOutline) { _, value in
                    if value { pdfController.command(.setThumbnails(false)); if geometry.size.width < 1000 { store.readingCompanionVisible = false } }
                }
                .onChange(of: store.readingCompanionVisible) { _, value in
                    if value && geometry.size.width < 1000 { showOutline = false }
                    if !value { store.queryAllowsOrganizing = false }
                }
                .animation(ReadingMotion.animation(reduce: reduceMotion), value: store.readingCompanionVisible)
                .onChange(of: store.bookID) { _, _ in inlineReading.clear() }
                .onChange(of: store.selectedUnitID) { _, _ in inlineReading.clear() }
                .onChange(of: store.readingSourceMode) { _, _ in inlineReading.clear() }
                .onChange(of: store.sourceReadingSelection != nil) { _, selecting in if selecting { inlineReading.clear() } }
                .onChange(of: interactionBlocked) { _, blocked in if blocked { inlineReading.clear() } }
                .onDisappear { inlineReading.clear() }
        }
    }
    private func pdfChromeBounds(offset: CGPoint) -> [String: CGRect] {
        guard isPDF, showPDF, store.readingSourceMode == "original" else { return [:] }
        var bounds: [String: CGRect] = [:]
        if !pdfController.chromeFrame.isEmpty { bounds["pdf-search"] = pdfController.chromeFrame.offsetBy(dx: offset.x, dy: offset.y) }
        if !pdfController.thumbnailFrame.isEmpty { bounds["pdf-thumbnails"] = pdfController.thumbnailFrame.offsetBy(dx: offset.x, dy: offset.y) }
        return bounds
    }
    private func sourceText(_ unit: SourceUnit) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !isPDF { Text(unit.chapter).font(.system(size: 18, weight: .medium, design: .serif)).lineLimit(1).help(unit.chapter) }
                if let warning = unit.warning ?? (store.book?.coverage[unit.id]?.status == .needsReview ? store.book?.coverage[unit.id]?.message : nil) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("内容待核对", systemImage: "doc.text.magnifyingglass").font(.subheadline.weight(.medium))
                        Text(warning).font(.caption).foregroundStyle(.secondary)
                        Button(unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "我已对照原页，确认这确实是空白内容" : "我已对照原文核对内容及回执中的问题") { Task { await store.markReviewed(unit.id) } }.font(.caption).disabled(store.isBusy)
                        if unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Button("保留为待识别，先继续其他内容") { Task { await store.deferUnit(unit.id) } }.font(.caption).disabled(store.isBusy) }
                    }.padding(14).background(Palette.copper.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                if ["md", "markdown"].contains(store.sourceFileURL?.pathExtension.lowercased() ?? "") || store.book?.ocrPages?.contains(where: { $0.page == unit.page }) == true {
                    anchoredSource(sourceMarkdown(unit), plain: false)
                } else {
                    let text = isPDF ? store.visibleSourceUnits.map(\.text).joined() : unit.text
                    anchoredSource(text.isEmpty ? "此单元尚未获得可读文本，请对照原始文件核查。" : text, plain: true)
                }
                let insights = store.book?.insights.filter { $0.unitIDs.contains(unit.id) } ?? []
                ForEach(insights) { insight in
                    VStack(alignment: .leading, spacing: 12) {
                        Label("阅读留下的线索", systemImage: "sparkles").font(.caption).foregroundStyle(Palette.accent)
                        MarkdownText(markdown: insight.markdown)
                        Button("保存为我的文档") { Task { await store.saveInsight(insight) } }.font(.caption).disabled(store.isBusy)
                    }.softPanel()
                }
            }.frame(maxWidth: 740).padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 100).frame(maxWidth: .infinity)
        }.background(Palette.paper)
    }
    private func anchoredSource(_ text: String, plain: Bool) -> some View {
        RichMarkdownView(markdown: text, sourceText: text, plainText: plain,
                         sourceDecorations: store.sourceReadingDecorations,
                         focusedDecorationID: store.focusedReadingAnchorID,
                         onSourceDecorationTap: sourceTapped,
                         onSourceSelection: { selection in store.sourceReadingSelection = selection; if selection != nil { store.focusedReadingAnchorID = nil } },
                         onSourceDecorationHover: sourceHovered)
    }
    private func sourceHovered(_ value: SourceReadingHover?) {
        guard !interactionBlocked else { inlineReading.clear(); return }
        inlineReading.receive(value, book: store.book, index: store.readingExperienceIndex, boundary: store.temporalBoundary)
    }
    private func sourceTapped(_ id: String) {
        if var value = inlineReading.lastHover, value.id == id { value.activated = true; sourceHovered(value) }
        else { store.sourceDecorationTapped(id) }
    }
    private func sourceMarkdown(_ unit: SourceUnit) -> String {
        if let page = unit.page, store.book?.ocrPages?.contains(where: { $0.page == page }) == true {
            return store.book?.units.filter { $0.page == page }.map(\.text).joined() ?? unit.text
        }
        return unit.text
    }
    private func move(_ offset: Int) {
        guard let units = store.book?.units, let current = store.selectedUnitID, let index = units.firstIndex(where: { $0.id == current }), units.indices.contains(index + offset) else { return }
        store.navigateToUnit(units[index + offset].id)
    }
}

/// The receipt ledger and developer-facing execution detail stay available on
/// demand; they no longer form the reader's default method screen.
struct ReadingProcessingDetailsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var showMethods = false
    @State private var showReview = false
    @State private var showAudit = false
    @State private var showSynthesis = false
    var body: some View {
        VStack(spacing: 0) {
            CompactWorkspaceHeader("处理详情") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { preReadButton; executionButton }
                    Menu {
                        Button(store.book?.plan == nil ? "预读选法" : "重新预读") { store.makePlan() }.disabled(store.isBusy)
                        Button(store.isBusy ? "暂停任务" : "开始 / 继续分析") { store.isBusy ? store.pause() : store.startReading() }.disabled(cannotPause)
                    } label: { Image(systemName: "play.circle") }.help("预读、精读与暂停")
                }
            }
            ScrollView {
                if let book = store.book {
                    VStack(alignment: .leading, spacing: 12) {
                        overview(book)
                        reviewSummary(book)
                        if let records = book.smartReading?.analysisCheckpoints, !records.isEmpty {
                            DisclosureGroup("最近分析说明") {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(Array(records.suffix(6).reversed())) { checkpoint in
                                        let notes = SmartReadingRuntime.analysisCheckpointNotes(checkpoint, in: book)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(checkpoint.updatedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                                            if notes.isEmpty { Text("本部分分析已保存。").font(.caption).foregroundStyle(.secondary) }
                                            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                        }
                                    }
                                }.padding(.top, 8)
                            }.softPanel()
                        }
                        ReadingLedgerView()
                        if let plan = book.plan {
                            DisclosureGroup(isExpanded: $showMethods) {
                                VStack(alignment: .leading, spacing: 14) {
                                    MarkdownText(markdown: plan.rationale)
                                    ForEach(book.methods.filter { plan.methodIDs.contains($0.id) }) { method in
                                        DisclosureGroup(method.name) {
                                            VStack(alignment: .leading, spacing: 10) {
                                                Text(method.goal).foregroundStyle(.secondary)
                                                ForEach(Array(method.steps.enumerated()), id: \.offset) { index, step in
                                                    HStack(alignment: .top, spacing: 8) { Text("\(index + 1).").foregroundStyle(.secondary); Text(step) }
                                                }
                                            }.font(.system(size: 16)).lineSpacing(4).padding(.top, 8)
                                        }.font(.subheadline.weight(.medium))
                                    }
                                    if !plan.focus.isEmpty { Text("关注：" + plan.focus.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                                    Button { dismiss(); store.requestedWorkspaceRoute = "plugins" } label: { Label("管理方法定义", systemImage: "slider.horizontal.3").frame(minHeight: 44) }.buttonStyle(ReadingToolbarButtonStyle()).help("查看或编辑可执行的读书方法")
                                }.padding(.top, 12)
                            } label: {
                                HStack { Text("读书方案").font(.subheadline.weight(.medium)); Spacer(); Text(book.methods.filter { plan.methodIDs.contains($0.id) }.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }.softPanel()
                        } else {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "book.closed").foregroundStyle(Palette.accent)
                                VStack(alignment: .leading, spacing: 5) { Text("先预读选法，再顺序精读").font(.subheadline.weight(.medium)); Text("预读目录与样本，选择方法、类型和组件；不会增加全文覆盖。").font(.caption).foregroundStyle(.secondary) }
                            }.softPanel()
                        }
                        if !book.audit.isEmpty {
                            DisclosureGroup(isExpanded: $showAudit) {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(Array(book.audit.suffix(16).reversed())) { audit in
                                        HStack(alignment: .top, spacing: 10) {
                                            VStack(alignment: .leading, spacing: 3) { Text(audit.name).font(.caption.monospaced()); Text(audit.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                            Spacer(minLength: 4); Text(audit.createdAt, style: .time).font(.caption2).foregroundStyle(.tertiary)
                                        }
                                    }
                                }.padding(.top, 10)
                            } label: { HStack { Text("插件调用记录").font(.subheadline.weight(.medium)); Spacer(); Text("最近 \(min(16, book.audit.count)) 条").font(.caption).foregroundStyle(.secondary) } }.softPanel()
                        }
                        if let synthesis = book.syntheses.last(where: { $0.title == "全书综合" }) {
                            DisclosureGroup("全书综合", isExpanded: $showSynthesis) { MarkdownText(markdown: synthesis.markdown).padding(.top, 12) }.font(.subheadline.weight(.medium)).softPanel()
                        }
                        Text("执行进度与源质量分别核对；模型理解、复杂图表和公式仍需结合原文判断。").font(.caption).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: 1080).frame(maxWidth: .infinity)
                }
            }
        }.background(Palette.canvas)
    }
    private var cannotPause: Bool { store.isSavingDocument || store.isExportingProject || store.isImportingBookCommit || store.isCommittingLocalWrite }
    private var preReadButton: some View { Button(store.book?.plan == nil ? "预读选法" : "重新预读") { store.makePlan() }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.isBusy) }
    private var executionButton: some View {
        Button { store.isBusy ? store.pause() : store.startReading() } label: {
            Label(store.isBusy ? (cannotPause ? "处理中" : "暂停") : (store.book?.insights.isEmpty == false ? "继续分析" : "开始分析"), systemImage: store.isBusy ? "pause.fill" : "play.fill")
        }.buttonStyle(.borderedProminent).controlSize(.large).frame(minHeight: 44).disabled(cannotPause)
    }
    private func overview(_ book: BookProject) -> some View {
        let analyzedIDs = Set(book.insights.filter { !$0.id.hasPrefix("deferred-") && !$0.id.hasPrefix("blank-") }.flatMap(\.unitIDs))
        let analyzed = book.units.filter { analyzedIDs.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { metric("内容单元", value: book.units.count); metric("AI 分析", value: analyzed); metric("待核对", value: book.reviewCount); metric("逐段回执", value: book.paragraphReceipts?.count ?? 0) }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow { metric("内容单元", value: book.units.count); metric("AI 分析", value: analyzed) }
                    GridRow { metric("待核对", value: book.reviewCount); metric("逐段回执", value: book.paragraphReceipts?.count ?? 0) }
                }
            }
            ProgressView(value: book.progress).tint(Palette.accent)
                .help("核对完成 \(book.completedCount) / \(book.units.count)；AI 已分析但源质量待核对的单元另计。")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { flowStep("预读", done: book.plan != nil); flowStep("精读", done: book.completedCount > 0); flowStep("关联", done: !book.entities.isEmpty || !book.events.isEmpty); flowStep("核对", done: book.isFullyProcessed); Spacer(minLength: 0); Text("已核对 \(book.completedCount)/\(book.units.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Text("已核对完成 \(book.completedCount) / \(book.units.count) 单元").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 7) {
                if store.isBusy { ProgressView().controlSize(.mini) }
                Text(store.activity).font(.system(size: 14)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.softPanel()
    }
    private func metric(_ title: String, value: Int) -> some View {
        HStack(spacing: 7) { Text(title).foregroundStyle(.secondary); Text(value, format: .number).fontWeight(.semibold).monospacedDigit() }.font(.system(size: 15)).fixedSize()
    }
    private func flowStep(_ title: String, done: Bool) -> some View {
        Label(title, systemImage: done ? "checkmark.circle.fill" : "circle").font(.system(size: 14)).foregroundStyle(done ? Palette.accent : .secondary).fixedSize()
    }
    @ViewBuilder private func reviewSummary(_ book: BookProject) -> some View {
        let units = book.units.filter { $0.warning != nil || book.coverage[$0.id]?.status == .needsReview || book.coverage[$0.id]?.status == .failed }
        if !units.isEmpty {
            DisclosureGroup(isExpanded: $showReview) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(units) { unit in
                        Button { store.navigateToUnit(unit.id); store.route = "reader" } label: {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) { Text(unit.locator).font(.caption.weight(.medium)); Text(reviewMessage(unit, in: book)).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                Spacer(minLength: 0); Image(systemName: "arrow.up.right").font(.caption)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.top, 10)
            } label: {
                Label("需核对 \(book.reviewCount) · 失败 \(units.filter { book.coverage[$0.id]?.status == .failed }.count)", systemImage: "exclamationmark.circle").font(.subheadline.weight(.medium)).foregroundStyle(Palette.copper)
            }.padding(12).background(Palette.copper.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private func reviewMessage(_ unit: SourceUnit, in book: BookProject) -> String {
        if ReadingLedger.isDeferred(unitID: unit.id, in: book) { return "已延期，尚未读取；补齐识别后再继续。" }
        let message = unit.warning ?? book.coverage[unit.id]?.message ?? ""
        return message.isEmpty ? "请对照原文核对内容。" : message
    }
}

struct MarkdownText: View {
    @EnvironmentObject var store: AppStore
    var markdown: String
    var body: some View {
        RichMarkdownView(markdown: preparedMarkdown, baseDirectory: store.sourceFileURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs", isDirectory: true))
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "readingbook" { Task { await store.openInternalURL(url) }; return .handled }
                return ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
            })
    }
    private var preparedMarkdown: String {
        MarkdownReferenceLinks.render(markdown, bookID: store.bookID ?? "", project: store.book)
    }
}

struct DocumentEditorView: View {
    @EnvironmentObject var store: AppStore
    @State private var preview = true
    @State private var discardingDraft = false
    @State private var showingDocuments = true
    @State private var listCollapsed = false
    @State private var measuredWindow = false
    @State private var listOrigin = CGPoint(x: 12, y: 100)
    @State private var dragOrigin = CGPoint.zero
    @State private var listDragging = false
    @State private var panelEpoch = 0
    @State private var documentSearch = ""
    @State private var showingSources = false
    @State private var memoryScope: String?
    private var hasDocument: Bool { store.selectedDocumentID != nil || store.editorDirty }
    private var currentDocument: DocumentRecord? { store.book?.activeDocuments.first { $0.id == store.selectedDocumentID } }
    private var documents: [DocumentRecord] {
        let all = store.book?.activeDocuments ?? []
        return documentSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(documentSearch.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1036
            let listFrame = clampedListOrigin(listOrigin, viewport: geometry.size)
            // Only an actually left-docked list shapes the paper. Moving it away
            // releases the old space immediately; the viewport itself stays full.
            let leftInset: CGFloat = showingDocuments && wide && !listCollapsed && listFrame.x < 40 ? listFrame.x + 360 : 24
            ZStack(alignment: .topLeading) {
                Palette.canvas.ignoresSafeArea()
                documentPaper
                    .padding(.leading, leftInset).padding(.trailing, 24).padding(.top, 80).padding(.bottom, 88)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showingDocuments {
                    documentPanel(viewport: geometry.size)
                }
                FloatingReadingDock(id: "notes-tools", viewport: geometry.size) { editorToolbar(compact: geometry.size.width < 960) }
                    .environmentObject(store)
            }
            .background {
                let stable = clampedListOrigin(listDragging ? dragOrigin : listOrigin, viewport: geometry.size)
                let height = listPanelHeight(viewport: geometry.size)
                let frame = showingDocuments ? CGRect(x: stable.x, y: stable.y, width: 340, height: height) : CGRect.zero
                let offset = geometry.frame(in: .global).origin
                Color.clear.preference(key: WorkspaceChromeBoundsPreference.self, value: frame.isEmpty ? [:] : ["notes-list": frame.offsetBy(dx: offset.x, dy: offset.y)])
            }
            .onAppear {
                guard !measuredWindow else { return }; measuredWindow = true
                restoreListMemory(viewport: geometry.size, defaultShown: wide)
                if store.selectedDocumentID == nil && store.editorDirty { preview = false }
            }
            .onChange(of: geometry.size) { previous, next in
                if previous.width >= 1036 && next.width < 1036 { showingDocuments = false }
                listOrigin = clampedListOrigin(listOrigin, viewport: next)
                panelEpoch += 1; listDragging = false
            }
            .onChange(of: store.workspaceMemoryRevision) { _, _ in restoreListMemory(viewport: geometry.size, defaultShown: wide) }
        }
        .confirmationDialog("放弃尚未保存的修改？", isPresented: $discardingDraft) {
            Button("放弃修改", role: .destructive) { store.discardDraft() }
        } message: { Text("清除当前草稿，恢复最近保存的内容；已保存的 Markdown 不会删除。") }
        .onChange(of: store.bookID) { _, _ in documentSearch = ""; preview = true; panelEpoch += 1 }
        .onChange(of: store.selectedDocumentID) { _, next in if next == nil && store.editorDirty { preview = false } }
        .onChange(of: store.editorDirty) { _, dirty in if dirty && store.selectedDocumentID == nil { preview = false } }
        .onChange(of: showingDocuments) { _, _ in saveListMemory() }
        .onChange(of: listCollapsed) { _, _ in saveListMemory() }
        .onChange(of: listOrigin) { _, _ in if !listDragging { saveListMemory() } }
        .onDisappear { saveListMemory() }
    }
    private func restoreListMemory(viewport: CGSize, defaultShown: Bool) {
        memoryScope = store.workspaceMemoryKey
        let saved = store.workspaceMemory.panels["notes.list"]
        listCollapsed = saved?.collapsed ?? false; showingDocuments = saved?.isPresented ?? defaultShown
        listOrigin = clampedListOrigin(saved?.origin.map { CGPoint(x: $0.x, y: $0.y) } ?? CGPoint(x: 12, y: 100), viewport: viewport)
    }
    private func saveListMemory() {
        guard let memoryScope else { return }
        let saved = WorkspacePanelMemory(origin: WorkspacePoint(x: listOrigin.x, y: listOrigin.y), isPresented: showingDocuments, collapsed: listCollapsed)
        store.updateWorkspaceMemory({ $0.panels["notes.list"] = saved }, expectedKey: memoryScope)
    }
    private var documentPaper: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Label(currentDocument?.origin == "user" || currentDocument == nil ? "用户笔记" : "已保存的 AI 摘记", systemImage: currentDocument?.origin == "user" || currentDocument == nil ? "doc.text" : "sparkles")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !noteEvidence.isEmpty {
                    Button { showingSources.toggle() } label: { Label("来源 · \(noteEvidence.count)", systemImage: "quote.bubble") }
                        .buttonStyle(ReadingToolbarButtonStyle()).help("查看这篇笔记的原文依据")
                        .popover(isPresented: $showingSources) {
                            ScrollView { EvidenceList(evidence: noteEvidence).padding(20) }.frame(width: 460, height: 340)
                        }
                }
                if store.isSavingDocument { ProgressView().controlSize(.small); Text("正在保存").font(.system(size: 13)).foregroundStyle(.secondary) }
                else if store.editorDirty { Label("未保存", systemImage: "circle.fill").font(.system(size: 13)).foregroundStyle(Palette.copper) }
                else if let document = currentDocument { Text(document.updatedAt, style: .time).font(.system(size: 13)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 28).padding(.vertical, 18)
            if let error = store.documentError, hasDocument {
                VStack(alignment: .leading, spacing: 10) {
                    Label(error, systemImage: "exclamationmark.circle").font(.system(size: 14)).foregroundStyle(Palette.copper).textSelection(.enabled)
                    if store.editorDirty, store.selectedDocumentID != nil {
                        Button("另存为新笔记") { Task { await store.saveCurrentDocument(asNew: true) } }
                            .buttonStyle(.bordered).disabled(store.isBusy || store.isSavingDocument)
                    }
                }.padding(.horizontal, 28).padding(.bottom, 12)
            }
            if hasDocument {
                if preview {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            Text(store.editorTitle.isEmpty ? "未命名笔记" : store.editorTitle).font(.system(size: 30, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            MarkdownText(markdown: previewBody)
                        }.padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 30)
                    }
                } else {
                    TextField("文档标题", text: Binding(get: { store.editorTitle }, set: { store.editorTitle = $0; store.editorDirty = true }), axis: .vertical)
                        .font(.system(size: 28, weight: .semibold)).textFieldStyle(.plain).lineLimit(1...3)
                        .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 18).disabled(store.isRecognizingPDF).accessibilityLabel("文档标题")
                    TextEditor(text: Binding(get: { store.editorMarkdown }, set: { store.editorMarkdown = $0; store.editorDirty = true }))
                        .font(.system(size: 16, design: .monospaced)).lineSpacing(6).scrollContentBackground(.hidden)
                        .padding(.horizontal, 22).padding(.bottom, 22).disabled(store.isRecognizingPDF)
                }
            } else {
                EmptyState(title: "写下你的理解", detail: "选择一篇笔记，或新建一篇真实的 Markdown 文档。", icon: "square.and.pencil", actionTitle: "新建笔记", action: { store.newDocument(); preview = false })
            }
        }.frame(maxWidth: 1050, maxHeight: .infinity).background(Palette.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.line.opacity(0.85), lineWidth: 0.8))
            .shadow(color: Palette.accent.opacity(0.035), radius: 18, y: 6).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var noteEvidence: [Evidence] { currentDocument?.evidence ?? store.draftEvidence }
    private var previewBody: String {
        // The paper already owns the document title. Strip only an identical first
        // heading from the preview; the user's Markdown source is never rewritten.
        let lines = store.editorMarkdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "# " + store.editorTitle.trimmingCharacters(in: .whitespacesAndNewlines) else { return store.editorMarkdown }
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
    private func editorToolbar(compact: Bool) -> some View {
        HStack(spacing: 4) {
            DockIconButton(title: "笔记列表", icon: "list.bullet.rectangle", isSelected: showingDocuments) { showingDocuments.toggle(); if showingDocuments { listCollapsed = false } }
            DockDivider()
            DockIconButton(title: preview ? "编辑笔记" : "预览笔记", icon: preview ? "square.and.pencil" : "eye", isSelected: !preview) { preview.toggle() }.disabled(!hasDocument)
            DockIconButton(title: store.isSavingDocument ? "保存中" : "保存笔记", icon: "square.and.arrow.down") { Task { await store.saveCurrentDocument() } }.disabled(!store.editorDirty || store.isBusy)
            DockDivider()
            documentMenu
        }.fixedSize(horizontal: true, vertical: true)
    }
    private var documentMenu: some View {
        Menu {
            if store.editorDirty {
                Button("放弃未保存修改…", role: .destructive) { discardingDraft = true }.disabled(store.isSavingDocument)
                Divider()
            }
            if let document = currentDocument {
                Button { Task { await store.addDocumentToGraph(document) } } label: { Label("加入导图", systemImage: "point.3.connected.trianglepath.dotted") }.disabled(store.isBusy)
                Button { store.exportMarkdown() } label: { Label("导出 .md…", systemImage: "square.and.arrow.up") }.disabled(store.editorDirty || store.isBusy)
                Button("移入回收站…", role: .destructive) { store.requestDeletion(.document, id: document.id, title: document.title) }.disabled(store.isBusy || store.editorDirty)
            }
            Button { store.showingTrash = true } label: { Label("查看回收站", systemImage: "trash") }
            Button("新建笔记") { store.newDocument(); preview = false }.disabled(store.editorDirty || store.isBusy)
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }.menuStyle(.borderlessButton).fixedSize().help("草稿、导图与文档管理")
    }
    private func documentPanel(viewport: CGSize) -> some View {
        let height = listPanelHeight(viewport: viewport)
        let origin = clampedListOrigin(listOrigin, viewport: viewport)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("我的笔记").font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .overlay { FloatingPanelPointerInput(epoch: panelEpoch, begin: { dragOrigin = listOrigin; listDragging = true }, drag: { delta, finished in
                        listOrigin = clampedListOrigin(CGPoint(x: dragOrigin.x + delta.width, y: dragOrigin.y + delta.height), viewport: viewport)
                        if finished { listDragging = false; saveListMemory() }
                    }, cancel: { listOrigin = clampedListOrigin(dragOrigin, viewport: viewport); listDragging = false }).accessibilityHidden(true) }
                    .help("拖动标题移动笔记列表").accessibilityLabel("我的笔记").accessibilityHint("拖动标题可移动列表；右侧可折叠或关闭")
                DockIconButton(title: listCollapsed ? "展开笔记列表" : "收起笔记列表", icon: listCollapsed ? "plus" : "minus") { if listCollapsed { listCollapsed = false } else { showingDocuments = false } }
            }.padding(.horizontal, 12)
            if !listCollapsed { documentPicker }
        }.frame(width: 340, height: height).readingGlass(radius: 20).position(x: origin.x + 170, y: origin.y + height / 2)
    }
    private func listPanelHeight(viewport: CGSize) -> CGFloat {
        listCollapsed ? ReadingLayout.panelHeaderHeight : min(640, max(180, viewport.height - 96 - 88))
    }
    private func clampedListOrigin(_ value: CGPoint, viewport: CGSize) -> CGPoint {
        let height = listPanelHeight(viewport: viewport)
        return CGPoint(x: min(max(12, value.x), max(12, viewport.width - 352)), y: min(max(96, value.y), max(96, viewport.height - height - 88)))
    }
    private var documentPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索笔记…", text: $documentSearch).textFieldStyle(.plain).font(.system(size: 15))
                if !documentSearch.isEmpty { Button { documentSearch = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清空笔记搜索").frame(width: 44, height: 44) }
            }.padding(.horizontal, 12).frame(minHeight: 46).background(Palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line.opacity(0.8)))
            if store.editorDirty { Text("有未保存的修改，请先保存或放弃再切换。").font(.system(size: 13)).foregroundStyle(Palette.copper).fixedSize(horizontal: false, vertical: true) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(documents) { document in
                        Button {
                            Task { await store.openDocument(document) }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: document.origin == "user" ? "doc.text" : "sparkles").font(.system(size: 23)).foregroundStyle(Palette.accent).frame(width: 28)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(document.title).font(.system(size: 16, weight: .medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(document.updatedAt, format: .dateTime.month().day().hour().minute()).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                if store.selectedDocumentID == document.id { Image(systemName: "checkmark").foregroundStyle(Palette.accent).font(.caption.weight(.semibold)) }
                            }.padding(.horizontal, 12).padding(.vertical, 14).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading).contentShape(Rectangle())
                                .background(store.selectedDocumentID == document.id ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).disabled(store.isBusy || (store.editorDirty && store.selectedDocumentID != document.id))
                            .contextMenu {
                                Button { Task { await store.addDocumentToGraph(document) } } label: { Label("加入导图", systemImage: "point.3.connected.trianglepath.dotted") }.disabled(store.isBusy)
                                Button("移入回收站…", role: .destructive) { store.requestDeletion(.document, id: document.id, title: document.title) }.disabled(store.isBusy || store.editorDirty)
                            }
                    }
                    if documents.isEmpty { Text(documentSearch.isEmpty ? "还没有笔记，从新建开始。" : "没有匹配的笔记").font(.caption).foregroundStyle(.secondary).padding(12) }
                }
            }.frame(maxHeight: .infinity)
            Divider().opacity(0.5)
            Button { store.newDocument(); preview = false } label: { Label("新建笔记", systemImage: "plus.circle.fill").font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity, minHeight: 46).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(Palette.accent).background(Palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12)).disabled(store.editorDirty || store.isBusy)
        }.padding(.horizontal, 16).padding(.bottom, 16)
    }
}
