import SwiftUI
import PDFKit
import ReadingCore

struct ReaderWorkspaceView: View {
    @EnvironmentObject var store: AppStore
    @Binding var showPDF: Bool
    @Binding var showOutline: Bool
    @EnvironmentObject var pdfController: PDFReaderController
    private var isPDF: Bool { store.sourceFileURL?.pathExtension.lowercased() == "pdf" }
    var body: some View {
        GeometryReader { geometry in
            let inlineOutline = geometry.size.width >= 760
            HStack(spacing: 0) {
                if showOutline && inlineOutline {
                    outline.frame(width: 224)
                    Divider()
                }
                VStack(spacing: 0) {
                    if let unit = store.selectedUnit {
                        if store.readingSourceMode != "original" { ReadingParallelView(mode: store.readingSourceMode) }
                        else if isPDF, showPDF, let url = store.sourceFileURL {
                            let requestToken = store.pdfNavigationToken
                            let sourceBookID = store.bookID
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
                               onSourceDecorationTap: store.sourceDecorationTapped,
                               onSourceSelection: { selection in store.sourceReadingSelection = selection; if selection != nil { store.focusedReadingAnchorID = nil } })
                        } else { sourceText(unit) }
                    } else {
                        EmptyState(title: "选择一个章节", detail: "从左上角目录选择原文内容。", icon: "book.pages")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                if store.readingCompanionVisible && geometry.size.width >= 1050 {
                    ReadingCompanionPanel(onClose: { store.readingCompanionVisible = false })
                        .frame(width: 360, height: max(0, geometry.size.height - 98)).readingGlass(radius: 22)
                        .padding(.top, 80).padding(.bottom, 18).padding(.trailing, 12)
                }
            }
            .overlay(alignment: .trailing) {
                if store.readingCompanionVisible && geometry.size.width < 1050 {
                    ReadingCompanionPanel(onClose: { store.readingCompanionVisible = false })
                        .frame(width: min(380, max(0, geometry.size.width - 24)), height: max(0, geometry.size.height - 98))
                        .readingGlass(radius: 22).padding(.horizontal, 12).padding(.top, 80)
                }
            }
            .overlay(alignment: .topLeading) {
                if showOutline && !inlineOutline {
                    outline.frame(width: min(310, geometry.size.width - 24), height: min(500, geometry.size.height - 98))
                        .clipShape(RoundedRectangle(cornerRadius: 14)).shadow(color: .black.opacity(0.14), radius: 22, y: 8).padding(.horizontal, 12).padding(.top, 80)
                }
            }
        }
    }
    private var outline: some View {
        VStack(spacing: 0) {
            HStack {
                Text("目录与原文").font(.subheadline.weight(.medium))
                Spacer()
                Button { showOutline = false } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("收起目录").accessibilityLabel("收起目录")
            }.padding(14)
            TextField("搜索原文或章节", text: $store.search).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 10)
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredUnits) { unit in
                            Button { store.navigateToUnit(unit.id) } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    statusIcon(unit)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(isPDF ? "第 \(unit.page ?? 1) 页" : unit.chapter).font(.subheadline.weight(.medium)).lineLimit(1)
                                        Text("行 \(unit.lineStart)–\(unit.lineEnd)").font(.caption2).foregroundStyle(.secondary)
                                        Text(unit.text.isEmpty ? "尚未识别文本" : String(unit.text.prefix(64)).replacingOccurrences(of: "\n", with: " ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    if store.book?.bookmarks.contains(unit.id) == true { Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(Palette.copper) }
                                }.padding(12).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                                    .background(store.selectedUnitID == unit.id ? Palette.accent.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(unit.id)
                                .accessibilityLabel("\(unit.locator)，点击定位原文")
                        }
                        if filteredUnits.isEmpty { Text("没有匹配的原文").font(.caption).foregroundStyle(.secondary).padding(20) }
                    }.padding(8)
                }.onChange(of: store.selectedUnitID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                    .onAppear { if let id = store.selectedUnitID { proxy.scrollTo(id, anchor: .center) } }
            }
        }.background(Color(nsColor: .textBackgroundColor))
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
            }.frame(maxWidth: 740).padding(.horizontal, 24).padding(.top, 84).padding(.bottom, 24).frame(maxWidth: .infinity)
        }.background(Palette.paper)
    }
    private func anchoredSource(_ text: String, plain: Bool) -> some View {
        RichMarkdownView(markdown: text, sourceText: text, plainText: plain,
                         sourceDecorations: store.sourceReadingDecorations,
                         focusedDecorationID: store.focusedReadingAnchorID,
                         onSourceDecorationTap: store.sourceDecorationTapped,
                         onSourceSelection: { selection in store.sourceReadingSelection = selection; if selection != nil { store.focusedReadingAnchorID = nil } })
    }
    private func sourceMarkdown(_ unit: SourceUnit) -> String {
        if let page = unit.page, store.book?.ocrPages?.contains(where: { $0.page == page }) == true {
            return store.book?.units.filter { $0.page == page }.map(\.text).joined() ?? unit.text
        }
        return unit.text
    }
    private var filteredUnits: [SourceUnit] {
        let units = store.book?.units ?? []
        return store.search.isEmpty ? units : units.filter { $0.chapter.localizedCaseInsensitiveContains(store.search) || $0.text.localizedCaseInsensitiveContains(store.search) || $0.locator.localizedCaseInsensitiveContains(store.search) }
    }
    private func statusIcon(_ unit: SourceUnit) -> some View {
        let status = store.book?.coverage[unit.id]?.status ?? .pending
        return Image(systemName: status == .completed ? "checkmark.circle.fill" : status == .needsReview || unit.warning != nil ? "exclamationmark.circle" : "circle")
            .font(.caption).foregroundStyle(status == .completed ? Palette.accent : .secondary).padding(.top, 2)
    }
    private func move(_ offset: Int) {
        guard let units = store.book?.units, let current = store.selectedUnitID, let index = units.firstIndex(where: { $0.id == current }), units.indices.contains(index + offset) else { return }
        store.navigateToUnit(units[index + offset].id)
    }
}

struct ReadingWorkflowView: View {
    @EnvironmentObject var store: AppStore
    @State private var showMethods = false
    @State private var showReview = false
    @State private var showAudit = false
    @State private var showSynthesis = false
    var body: some View {
        VStack(spacing: 0) {
            CompactWorkspaceHeader("阅读流程") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { preReadButton; executionButton }
                    Menu {
                        Button(store.book?.plan == nil ? "预读选法" : "重新预读") { store.makePlan() }.disabled(store.isBusy)
                        Button(store.isBusy ? "暂停任务" : "开始 / 继续精读") { store.isBusy ? store.pause() : store.startReading() }.disabled(cannotPause)
                    } label: { Image(systemName: "play.circle") }.help("预读、精读与暂停")
                }
            }
            ScrollView {
                if let book = store.book {
                    VStack(alignment: .leading, spacing: 12) {
                        overview(book)
                        reviewSummary(book)
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
                    }.padding(16).frame(maxWidth: 1000).frame(maxWidth: .infinity)
                }
            }
        }
    }
    private var cannotPause: Bool { store.isSavingDocument || store.isExportingProject || store.isImportingBookCommit || store.isCommittingLocalWrite }
    private var preReadButton: some View { Button(store.book?.plan == nil ? "预读选法" : "重新预读") { store.makePlan() }.disabled(store.isBusy) }
    private var executionButton: some View {
        Button { store.isBusy ? store.pause() : store.startReading() } label: {
            Label(store.isBusy ? (cannotPause ? "处理中" : "暂停") : (store.book?.insights.isEmpty == false ? "继续精读" : "开始精读"), systemImage: store.isBusy ? "pause.fill" : "play.fill")
        }.buttonStyle(.borderedProminent).disabled(cannotPause)
    }
    private func overview(_ book: BookProject) -> some View {
        let analyzedIDs = Set(book.insights.filter { !$0.id.hasPrefix("deferred-") && !$0.id.hasPrefix("blank-") }.flatMap(\.unitIDs))
        let analyzed = book.units.filter { analyzedIDs.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: 9) {
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
                Text(store.activity).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.softPanel()
    }
    private func metric(_ title: String, value: Int) -> some View {
        HStack(spacing: 5) { Text(title).foregroundStyle(.secondary); Text(value, format: .number).fontWeight(.medium).monospacedDigit() }.font(.caption).fixedSize()
    }
    private func flowStep(_ title: String, done: Bool) -> some View {
        Label(title, systemImage: done ? "checkmark.circle.fill" : "circle").font(.caption).foregroundStyle(done ? Palette.accent : .secondary).fixedSize()
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
        var text = markdown
        for kind in ["unit", "doc"] {
            let pattern = "\\[\(kind):([A-Za-z0-9._-]+)\\]"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[\(kind == "unit" ? "原文" : "文档") $1](readingbook://book/\(store.bookID ?? "")/\(kind == "unit" ? "unit" : "document")/$1)")
            }
        }
        return text
    }
}

struct DocumentEditorView: View {
    @EnvironmentObject var store: AppStore
    @State private var preview = false
    @State private var discardingDraft = false
    @State private var showingDocuments = false
    @State private var documentSearch = ""
    private var hasDocument: Bool { store.selectedDocumentID != nil || store.editorDirty }
    private var currentDocument: DocumentRecord? { store.book?.activeDocuments.first { $0.id == store.selectedDocumentID } }
    private var documents: [DocumentRecord] {
        let all = store.book?.activeDocuments ?? []
        return documentSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(documentSearch.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) { editorToolbar(compact: false); editorToolbar(compact: true) }
                .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
                .background(Palette.surface).overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 0.5) }
                .popover(isPresented: $showingDocuments, arrowEdge: .bottom) { documentPicker }
            if store.editorDirty || store.isSavingDocument {
                HStack(spacing: 7) {
                    if store.isSavingDocument { ProgressView().controlSize(.mini) }
                    else { Circle().fill(Palette.copper).frame(width: 5, height: 5) }
                    Text(store.isSavingDocument ? "正在保存 Markdown；期间的新编辑会保留为草稿。" : "有未保存修改，切换笔记前请保存或放弃。").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 16).padding(.vertical, 5)
            }
            if let error = store.documentError, hasDocument {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Palette.copper).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
            }
            if hasDocument {
                if preview {
                    ScrollView { MarkdownText(markdown: store.editorMarkdown).padding(22).frame(maxWidth: 850).frame(maxWidth: .infinity) }.background(Palette.paper)
                } else {
                    TextEditor(text: Binding(get: { store.editorMarkdown }, set: { store.editorMarkdown = $0; store.editorDirty = true }))
                        .font(.system(size: 16, design: .monospaced)).scrollContentBackground(.hidden).padding(16).background(Palette.paper).disabled(store.isRecognizingPDF)
                }
            } else {
                EmptyState(title: "写下你的理解", detail: "从左上角选择笔记，或新建一篇真实的 Markdown 文档。", icon: "square.and.pencil", actionTitle: "新建笔记", action: { store.newDocument() })
            }
        }
        .confirmationDialog("放弃尚未保存的修改？", isPresented: $discardingDraft) {
            Button("放弃修改", role: .destructive) { store.discardDraft() }
        } message: { Text("清除当前草稿，恢复最近保存的内容；已保存的 Markdown 不会删除。") }
        .onChange(of: store.bookID) { _, _ in showingDocuments = false; documentSearch = ""; preview = false }
    }
    private func editorToolbar(compact: Bool) -> some View {
        HStack(spacing: compact ? 7 : 10) {
            Button { showingDocuments.toggle() } label: {
                if compact { Image(systemName: "doc.on.doc") }
                else { Label("笔记", systemImage: "doc.on.doc") }
            }.help("选择或搜索 Markdown 笔记")
            if hasDocument {
                TextField("文档标题", text: Binding(get: { store.editorTitle }, set: { store.editorTitle = $0; store.editorDirty = true }))
                    .font(.system(size: 17, weight: .medium)).textFieldStyle(.plain)
                    .frame(minWidth: compact ? 80 : 160).layoutPriority(1).disabled(store.isRecognizingPDF)
                    .accessibilityLabel("文档标题")
                    .accessibilityHint("直接编辑标题，保存后即完成笔记重命名。")
                    .help("直接编辑标题，保存或按 ⌘S 完成重命名")
            } else { Text("我的理解").font(.system(size: 17, weight: .semibold)).lineLimit(1); Spacer(minLength: 0) }
            if compact {
                Button { preview.toggle() } label: { Image(systemName: preview ? "square.and.pencil" : "eye") }.help(preview ? "返回编辑" : "预览 Markdown").disabled(!hasDocument)
            } else {
                Picker("显示模式", selection: $preview) { Text("编辑").tag(false); Text("预览").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 116).disabled(!hasDocument)
            }
            Button(store.isSavingDocument ? "保存中" : "保存") { Task { await store.saveCurrentDocument() } }
                .buttonStyle(.borderedProminent).disabled(!store.editorDirty || store.isBusy).help(store.editorDirty ? "保存 Markdown 与标题修改" : "当前文档已保存")
            documentMenu
        }.controlSize(.regular)
    }
    private var documentMenu: some View {
        Menu {
            if store.editorDirty {
                Button("放弃未保存修改…", role: .destructive) { discardingDraft = true }.disabled(store.isSavingDocument)
                Divider()
            }
            if let document = currentDocument {
                Button("加入导图") { Task { await store.addDocumentToGraph(document) } }.disabled(store.isBusy)
                Button("导出 .md…") { store.exportMarkdown() }.disabled(store.editorDirty || store.isBusy)
                Button("移入回收站…", role: .destructive) { store.requestDeletion(.document, id: document.id, title: document.title) }.disabled(store.isBusy || store.editorDirty)
            }
            Button("查看回收站") { store.showingTrash = true }
        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help("草稿、导图与文档管理")
    }
    private var documentPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Markdown 笔记").font(.subheadline.weight(.medium)); Spacer()
                Button { showingDocuments = false; store.newDocument(); preview = false } label: { Label("新建", systemImage: "plus") }.controlSize(.regular).disabled(store.editorDirty || store.isBusy)
            }
            TextField("搜索笔记标题", text: $documentSearch).textFieldStyle(.roundedBorder)
            if store.editorDirty { Text("当前有草稿，请先保存或放弃，再切换笔记。").font(.caption).foregroundStyle(Palette.copper) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(documents) { document in
                        Button {
                            showingDocuments = false
                            Task { await store.openDocument(document) }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: document.origin == "user" ? "doc.text" : "sparkles").foregroundStyle(Palette.accent)
                                Text(document.title).font(.system(size: 14)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                if store.selectedDocumentID == document.id { Image(systemName: "checkmark").foregroundStyle(Palette.accent).font(.caption.weight(.semibold)) }
                            }.padding(.horizontal, 9).padding(.vertical, 8).contentShape(Rectangle())
                                .background(store.selectedDocumentID == document.id ? Palette.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).disabled(store.isBusy || (store.editorDirty && store.selectedDocumentID != document.id))
                            .contextMenu {
                                Button("加入导图") { Task { await store.addDocumentToGraph(document) } }.disabled(store.isBusy)
                                Button("移入回收站…", role: .destructive) { showingDocuments = false; store.requestDeletion(.document, id: document.id, title: document.title) }.disabled(store.isBusy || store.editorDirty)
                            }
                    }
                    if documents.isEmpty { Text(documentSearch.isEmpty ? "还没有笔记，从新建开始。" : "没有匹配的笔记").font(.caption).foregroundStyle(.secondary).padding(12) }
                }
            }.frame(maxHeight: 330)
        }.padding(14).frame(width: 330)
    }
}
