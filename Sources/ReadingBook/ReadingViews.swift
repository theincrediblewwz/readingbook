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
                        if isPDF, showPDF, let url = store.sourceFileURL {
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
                            })
                        } else { sourceText(unit) }
                    } else {
                        EmptyState(title: "选择一个章节", detail: "从左上角目录选择原文内容。", icon: "book.pages")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
            }
            .overlay(alignment: .topLeading) {
                if showOutline && !inlineOutline {
                    outline.frame(width: min(310, geometry.size.width - 24), height: min(500, geometry.size.height - 24))
                        .clipShape(RoundedRectangle(cornerRadius: 14)).shadow(color: .black.opacity(0.14), radius: 22, y: 8).padding(12)
                }
            }
        }
    }
    private var outline: some View {
        VStack(spacing: 0) {
            HStack {
                Text("目录与原文").font(.subheadline.weight(.medium))
                Spacer()
                Button { showOutline = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("收起目录")
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
            VStack(alignment: .leading, spacing: 22) {
                if !isPDF { Text(unit.chapter).font(.system(size: 28, weight: .regular, design: .serif)) }
                if let warning = unit.warning ?? (store.book?.coverage[unit.id]?.status == .needsReview ? store.book?.coverage[unit.id]?.message : nil) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("内容待核对", systemImage: "doc.text.magnifyingglass").font(.subheadline.weight(.medium))
                        Text(warning).font(.caption).foregroundStyle(.secondary)
                        Button(unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "我已对照原页，确认这确实是空白内容" : "我已对照原文核对内容及回执中的问题") { Task { await store.markReviewed(unit.id) } }.font(.caption).disabled(store.isBusy)
                        if unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Button("保留为待识别，先继续其他内容") { Task { await store.deferUnit(unit.id) } }.font(.caption).disabled(store.isBusy) }
                    }.padding(14).background(Palette.copper.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                if ["md", "markdown"].contains(store.sourceFileURL?.pathExtension.lowercased() ?? "") || store.book?.ocrPages?.contains(where: { $0.page == unit.page }) == true {
                    MarkdownText(markdown: sourceMarkdown(unit))
                } else {
                    Text(unit.text.isEmpty ? "此单元尚未获得可读文本，请对照原始文件核查。" : unit.text)
                        .font(.system(size: 17, weight: .regular, design: .serif)).lineSpacing(10).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                let insights = store.book?.insights.filter { $0.unitIDs.contains(unit.id) } ?? []
                ForEach(insights) { insight in
                    VStack(alignment: .leading, spacing: 12) {
                        Label("阅读留下的线索", systemImage: "sparkles").font(.caption).foregroundStyle(Palette.accent)
                        MarkdownText(markdown: insight.markdown)
                        Button("保存为我的文档") { Task { await store.saveInsight(insight) } }.font(.caption).disabled(store.isBusy)
                    }.softPanel()
                }
            }.frame(maxWidth: 740).padding(.horizontal, 28).padding(.vertical, 26).frame(maxWidth: .infinity)
        }.background(Palette.paper)
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
    var body: some View {
        ScrollView {
            if let book = store.book {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) { Text("阅读有迹可循").font(.system(size: 30, design: .serif)); Text("先判断怎样读，再逐段处理，让线索连接成结构。").foregroundStyle(.secondary) }
                        Spacer(); Button("重新预读") { store.makePlan() }.disabled(store.isBusy)
                    }
                    HStack(spacing: 16) {
                        let analyzedIDs = Set(book.insights.filter { !$0.id.hasPrefix("deferred-") && !$0.id.hasPrefix("blank-") }.flatMap(\.unitIDs))
                        metric("内容单元", value: "\(book.units.count)", detail: "按源顺序登记")
                        metric("AI 分析", value: "\(book.units.filter { analyzedIDs.contains($0.id) }.count)", detail: "源质量核对另计")
                        metric("待核对", value: "\(book.reviewCount)", detail: "提取或图文异常")
                        metric("逐段回执", value: "\(book.paragraphReceipts?.count ?? 0)", detail: "本版开始留存")
                    }
                    HStack(spacing: 0) {
                        flowStep("1", "预读选法", done: book.plan != nil)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        flowStep("2", "顺序精读", done: book.completedCount > 0)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        flowStep("3", "连接要素", done: !book.entities.isEmpty || !book.events.isEmpty)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        flowStep("4", "核对与沉淀", done: book.isFullyProcessed)
                    }.softPanel()
                    ReadingLedgerView()
                    if let plan = book.plan {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("AI 选择的读法").font(.headline); MarkdownText(markdown: plan.rationale)
                            ForEach(book.methods.filter { plan.methodIDs.contains($0.id) }) { method in
                                VStack(alignment: .leading, spacing: 9) {
                                    Text(method.name).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
                                    Text(method.goal).font(.caption).foregroundStyle(.secondary)
                                    ForEach(Array(method.steps.enumerated()), id: \.offset) { index, step in HStack(alignment: .top) { Text(String(index + 1)).foregroundStyle(.tertiary); Text(step) }.font(.subheadline) }
                                }.padding(.vertical, 8)
                            }
                            if !plan.focus.isEmpty { Text("关注：" + plan.focus.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        }.softPanel()
                    } else { EmptyState(title: "让 AI 先认识这本书", detail: "预读目录与样本后，它会选择读书法、内容类型和组件。预读不会增加全文覆盖率。", actionTitle: "开始预读", action: { store.makePlan() }).frame(height: 245) }
                    if !book.audit.isEmpty {
                        VStack(alignment: .leading, spacing: 13) {
                            Text("最近调用的插件能力").font(.headline)
                            ForEach(Array(book.audit.suffix(16).reversed())) { audit in
                                HStack(alignment: .top, spacing: 14) { Image(systemName: "puzzlepiece.extension").foregroundStyle(Palette.accent); VStack(alignment: .leading, spacing: 4) { Text(audit.name).font(.caption.monospaced()); Text(audit.summary).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(audit.createdAt, style: .time).font(.caption2).foregroundStyle(.tertiary) }
                            }
                        }.softPanel()
                    }
                    if let synthesis = book.syntheses.last(where: { $0.title == "全书综合" }) {
                        VStack(alignment: .leading, spacing: 14) { Text("全书综合").font(.headline); MarkdownText(markdown: synthesis.markdown) }.softPanel()
                    }
                    Text("处理覆盖率表示登记内容的执行进度。模型理解、复杂图表与公式仍需要结合原文判断。").font(.caption).foregroundStyle(.secondary)
                }.padding(30).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }
        }
    }
    private func metric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 32, weight: .light, design: .rounded)); Text(detail).font(.caption2).foregroundStyle(.tertiary) }.frame(maxWidth: .infinity, alignment: .leading).softPanel()
    }
    private func flowStep(_ number: String, _ title: String, done: Bool) -> some View {
        VStack(spacing: 10) { Text(done ? "✓" : number).font(.subheadline).frame(width: 32, height: 32).background(Palette.accent.opacity(done ? 0.18 : 0.06), in: Circle()); Text(title).font(.caption) }.frame(maxWidth: .infinity)
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
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("我的 Markdown").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Button { store.newDocument() } label: { Image(systemName: "plus") }.buttonStyle(.plain) }.padding(.horizontal, 16).padding(.top, 18)
                List(store.book?.activeDocuments ?? []) { document in
                    Button { Task { await store.openDocument(document) } } label: { Label(document.title, systemImage: document.origin == "user" ? "doc.text" : "sparkles").font(.subheadline).lineLimit(2).padding(.vertical, 5) }.buttonStyle(.plain)
                        .listRowBackground(store.selectedDocumentID == document.id ? Palette.accent.opacity(0.1) : .clear)
                        .contextMenu {
                            Button("加入导图") { Task { await store.addDocumentToGraph(document) } }
                            Button("移入回收站", role: .destructive) { store.requestDeletion(.document, id: document.id, title: document.title) }
                        }
                }.listStyle(.sidebar)
            }.frame(minWidth: 170, idealWidth: 200, maxWidth: 250)
            if store.selectedDocumentID != nil || store.editorDirty {
                VStack(spacing: 0) {
                    VStack(spacing: 12) {
                        HStack {
                        TextField("文档标题", text: Binding(get: { store.editorTitle }, set: { store.editorTitle = $0; store.editorDirty = true })).font(.headline).textFieldStyle(.plain)
                        if let document = store.book?.activeDocuments.first(where: { $0.id == store.selectedDocumentID }) {
                            Button { store.requestDeletion(.document, id: document.id, title: document.title) } label: { Image(systemName: "trash") }.help("文档移入回收站").disabled(store.isBusy)
                        }
                        }
                        HStack {
                        Toggle("预览", isOn: $preview).toggleStyle(.button)
                        Spacer(minLength: 0)
                        if store.editorDirty { Button("放弃修改") { discardingDraft = true }.disabled(store.isSavingDocument) }
                        Button("导出 .md") { store.exportMarkdown() }.disabled(store.selectedDocumentID == nil || store.editorDirty)
                        Button(store.editorDirty ? "保存" : "已保存") { Task { await store.saveCurrentDocument() } }.buttonStyle(.borderedProminent).disabled(!store.editorDirty || store.isBusy)
                        }
                    }.padding(20)
                    Divider().opacity(0.4)
                    if preview { ScrollView { MarkdownText(markdown: store.editorMarkdown).padding(36).frame(maxWidth: 850).frame(maxWidth: .infinity) }.background(Palette.paper) }
                    else { TextEditor(text: Binding(get: { store.editorMarkdown }, set: { store.editorMarkdown = $0; store.editorDirty = true })).font(.system(size: 15, design: .monospaced)).scrollContentBackground(.hidden).padding(25).background(Palette.paper) }
                }.frame(minWidth: 360, maxWidth: .infinity).disabled(store.isRecognizingPDF)
            } else { EmptyState(title: "给理解留一个位置", detail: "你写下的想法与主动保存的 AI 回答，都是真实的 Markdown 文件。它们也会出现在文档导图中。", icon: "square.and.pencil", actionTitle: "写下理解", action: { store.newDocument() }) }
        }
        .confirmationDialog("放弃尚未保存的修改？", isPresented: $discardingDraft) {
            Button("放弃修改", role: .destructive) { store.discardDraft() }
        } message: { Text("清除当前草稿，恢复最近保存的内容；已保存的 Markdown 不会删除。") }
    }
}

struct BookChatView: View {
    @EnvironmentObject var store: AppStore
    @State private var question = ""
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        if store.book?.chats.isEmpty != false { EmptyState(title: "顺着一个问题，读得更深", detail: "回答会检索本书原文与已保存文档。你可以把值得留下的回答保存成 Markdown 节点。", icon: "bubble.left.and.bubble.right").frame(minHeight: 280) }
                        ForEach(store.book?.chats ?? []) { message in
                            VStack(alignment: .leading, spacing: 13) {
                                HStack { Label(message.role == "user" ? "你的问题" : "一起理解", systemImage: message.role == "user" ? "person.crop.circle" : "sparkles").font(.caption.weight(.semibold)).foregroundStyle(message.role == "user" ? .secondary : Palette.accent); Spacer(); if message.role == "assistant" { Button("保存为文档节点") { Task { await store.saveAnswer(message) } }.font(.caption).disabled(store.isBusy) } }
                                MarkdownText(markdown: message.content)
                                if message.role == "assistant" { EvidenceList(evidence: message.evidence) }
                            }.padding(22).background(message.role == "user" ? Palette.accent.opacity(0.05) : Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16)).id(message.id)
                        }
                    }.padding(30).frame(maxWidth: 880).frame(maxWidth: .infinity)
                }.onChange(of: store.book?.chats.count) { _, _ in if let last = store.book?.chats.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
            HStack(alignment: .bottom, spacing: 14) {
                TextField("从这本书出发，问一个问题…", text: $question, axis: .vertical).lineLimit(2...6).textFieldStyle(.plain).onSubmit { send() }
                Button { send() } label: { Image(systemName: "arrow.up").font(.headline).frame(width: 30, height: 30) }.buttonStyle(.borderedProminent).disabled(store.isBusy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(18).readingGlass().padding(.horizontal, 30).padding(.bottom, 22)
        }
    }
    private func send() { guard !store.isBusy, !question.isEmpty else { return }; let input = question; question = ""; store.ask(input) }
}
