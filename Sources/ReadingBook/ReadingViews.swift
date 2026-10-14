import SwiftUI
import PDFKit
import ReadingCore

struct ReaderWorkspaceView: View {
    @EnvironmentObject var store: AppStore
    @State private var showPDF = false
    var body: some View {
        HSplitView {
            VStack(spacing: 12) {
                TextField("搜索原文或章节", text: $store.search).textFieldStyle(.roundedBorder).padding(.horizontal, 14).padding(.top, 16)
                ScrollViewReader { proxy in
                    List {
                        ForEach(filteredUnits) { unit in
                            Button { store.selectedUnitID = unit.id } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    statusIcon(unit)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(unit.chapter).font(.caption.weight(.medium)).lineLimit(1)
                                        Text(unit.locator).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                        Text(unit.text.prefix(48)).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    if store.book?.bookmarks.contains(unit.id) == true { Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(Palette.copper) }
                                }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).listRowBackground(store.selectedUnitID == unit.id ? Palette.accent.opacity(0.10) : .clear).id(unit.id)
                        }
                    }.listStyle(.sidebar)
                    .onChange(of: store.selectedUnitID) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) }; if let bookID = store.bookID { UserDefaults.standard.set(id, forKey: "position-\(bookID)") } } }
                }
            }.frame(minWidth: 195, idealWidth: 225, maxWidth: 280)
            if let unit = store.selectedUnit {
                VStack(spacing: 0) {
                    HStack {
                        Button { move(-1) } label: { Image(systemName: "chevron.left") }.disabled(unit.order == 0)
                        Button { move(1) } label: { Image(systemName: "chevron.right") }.disabled(unit.order >= (store.book?.units.count ?? 0) - 1)
                        Text(unit.locator).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if store.sourceFileURL?.pathExtension.lowercased() == "pdf" { Toggle("原始 PDF", isOn: $showPDF).toggleStyle(.switch).controlSize(.small) }
                        Button { Task { await store.toggleBookmark(unit.id) } } label: { Image(systemName: store.book?.bookmarks.contains(unit.id) == true ? "bookmark.fill" : "bookmark") }.help("书签").disabled(store.isBusy)
                        Button { store.newNote(for: unit) } label: { Label("记一笔", systemImage: "square.and.pencil") }
                    }.buttonStyle(.borderless).padding(.horizontal, 25).padding(.vertical, 14)
                    Divider().opacity(0.4)
                    if showPDF, let url = store.sourceFileURL { OriginalPDFView(url: url, page: unit.page ?? 1) }
                    else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 22) {
                                Text(unit.chapter).font(.system(size: 30, weight: .regular, design: .serif)).padding(.bottom, 8)
                                if let warning = unit.warning {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Label("内容待核对", systemImage: "doc.text.magnifyingglass").font(.subheadline.weight(.medium))
                                        Text(warning).font(.caption).foregroundStyle(.secondary)
                                        Button(unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "我已对照原页，确认这确实是空白内容" : "我已对照原文，确认此单元内容完整") { Task { await store.markReviewed(unit.id) } }.font(.caption).disabled(store.isBusy)
                                        if unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Button("保留为待识别，先继续其他内容") { Task { await store.deferUnit(unit.id) } }.font(.caption).disabled(store.isBusy) }
                                    }.padding(14).background(Palette.copper.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                }
                                Text(unit.text.isEmpty ? "此单元尚未获得可读文本，请对照原始文件核查。" : unit.text)
                                    .font(.system(size: 17, weight: .regular, design: .serif)).lineSpacing(10).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                Divider().padding(.vertical, 20)
                                let insights = store.book?.insights.filter { $0.unitIDs.contains(unit.id) } ?? []
                                ForEach(insights) { insight in
                                    VStack(alignment: .leading, spacing: 12) {
                                        Label("阅读留下的线索", systemImage: "sparkles").font(.caption).foregroundStyle(Palette.accent)
                                        MarkdownText(markdown: insight.markdown)
                                        Button("保存为我的文档") { Task { await store.saveInsight(insight) } }.font(.caption).disabled(store.isBusy)
                                    }.softPanel()
                                }
                            }.frame(maxWidth: 740).padding(.horizontal, 40).padding(.vertical, 40).frame(maxWidth: .infinity)
                        }.background(Palette.paper)
                    }
                }.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            } else { EmptyState(title: "选择一个章节", detail: "原文与 AI 结论的依据都会在这里展开。", icon: "book.pages") }
        }
    }
    private var filteredUnits: [SourceUnit] {
        let units = store.book?.units ?? []
        return store.search.isEmpty ? units : units.filter { $0.chapter.localizedCaseInsensitiveContains(store.search) || $0.text.localizedCaseInsensitiveContains(store.search) }
    }
    private func statusIcon(_ unit: SourceUnit) -> some View {
        let status = store.book?.coverage[unit.id]?.status ?? .pending
        return Image(systemName: status == .completed ? "checkmark.circle.fill" : status == .needsReview || unit.warning != nil ? "exclamationmark.circle" : "circle")
            .font(.caption2).foregroundStyle(status == .completed ? Palette.accent : .secondary).padding(.top, 2)
    }
    private func move(_ offset: Int) {
        guard let units = store.book?.units, let current = store.selectedUnitID, let index = units.firstIndex(where: { $0.id == current }), units.indices.contains(index + offset) else { return }
        store.selectedUnitID = units[index + offset].id
    }
}

struct OriginalPDFView: NSViewRepresentable {
    var url: URL
    var page: Int
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; view.document = PDFDocument(url: url); return view }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
        if let target = view.document?.page(at: max(0, page - 1)), view.currentPage != target { view.go(to: target) }
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
                        metric("内容单元", value: "\(book.units.count)", detail: "按源顺序登记")
                        metric("已处理", value: "\(Int(book.progress * 100))%", detail: "\(book.completedCount) 个单元已核对")
                        metric("待核对", value: "\(book.reviewCount)", detail: "提取或图文异常")
                        metric("知识线索", value: "\(book.entities.count + book.events.count)", detail: "要素与事件")
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
        Text(rendered).font(.body).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "readingbook" { Task { await store.openInternalURL(url) }; return .handled }
                return ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
            })
    }
    private var rendered: AttributedString {
        var text = markdown
        for kind in ["unit", "doc"] {
            let pattern = "\\[\(kind):([A-Za-z0-9._-]+)\\]"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[\(kind == "unit" ? "原文" : "文档") $1](readingbook://book/\(store.bookID ?? "")/\(kind == "unit" ? "unit" : "document")/$1)")
            }
        }
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full))) ?? AttributedString(text)
    }
}

struct DocumentEditorView: View {
    @EnvironmentObject var store: AppStore
    @State private var preview = false
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("我的 Markdown").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Button { store.newDocument() } label: { Image(systemName: "plus") }.buttonStyle(.plain) }.padding(.horizontal, 16).padding(.top, 18)
                List(store.book?.documents ?? []) { document in
                    Button { Task { await store.openDocument(document) } } label: { Label(document.title, systemImage: document.origin == "user" ? "doc.text" : "sparkles").font(.subheadline).lineLimit(2).padding(.vertical, 5) }.buttonStyle(.plain)
                        .listRowBackground(store.selectedDocumentID == document.id ? Palette.accent.opacity(0.1) : .clear)
                }.listStyle(.sidebar)
            }.frame(minWidth: 170, idealWidth: 200, maxWidth: 250)
            if store.selectedDocumentID != nil || store.editorDirty {
                VStack(spacing: 0) {
                    HStack {
                        TextField("文档标题", text: Binding(get: { store.editorTitle }, set: { store.editorTitle = $0; store.editorDirty = true })).font(.headline).textFieldStyle(.plain)
                        Toggle("预览", isOn: $preview).toggleStyle(.button)
                        Button("导出 .md") { store.exportMarkdown() }.disabled(store.selectedDocumentID == nil || store.editorDirty)
                        Button(store.editorDirty ? "保存" : "已保存") { Task { await store.saveCurrentDocument() } }.buttonStyle(.borderedProminent).disabled(!store.editorDirty || store.isBusy)
                    }.padding(20)
                    Divider().opacity(0.4)
                    if preview { ScrollView { MarkdownText(markdown: store.editorMarkdown).padding(36).frame(maxWidth: 850).frame(maxWidth: .infinity) }.background(Palette.paper) }
                    else { TextEditor(text: Binding(get: { store.editorMarkdown }, set: { store.editorMarkdown = $0; store.editorDirty = true })).font(.system(size: 15, design: .monospaced)).scrollContentBackground(.hidden).padding(25).background(Palette.paper) }
                }.frame(minWidth: 400, maxWidth: .infinity)
            } else { EmptyState(title: "给理解留一个位置", detail: "你写下的想法与主动保存的 AI 回答，都是真实的 Markdown 文件。它们也会出现在文档导图中。", icon: "square.and.pencil", actionTitle: "写下理解", action: { store.newDocument() }) }
        }
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
