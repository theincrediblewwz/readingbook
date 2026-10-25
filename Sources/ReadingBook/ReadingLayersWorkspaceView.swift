import SwiftUI
import ReadingCore

/// Reading explanations are arranged around source fragments, independently of
/// the object/evidence catalogue. No generated text replaces an imported source.
struct ReadingLayersWorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    var definition: ViewDefinition?
    @State private var sourceID: String?
    @State private var search = ""
    @State private var unitScope = "book"
    @State private var layerKind = "all"
    @State private var showsDirectory = true
    @State private var showsDirectoryPopover = false
    @State private var initialized = false
    @State private var expandedSource = false
    @State private var sourceRenderedHeight: CGFloat = 0
    @State private var removal: LayerRemoval?
    @State private var restorationNotice = ""

    private var unit: SourceUnit? { store.book?.units.first { $0.id == sourceID } }
    private var readingState: ReadingExperienceState { store.book?.readingExperience ?? ReadingExperienceState() }
    private var anchors: [SourceAnchor] { readingState.anchors }
    private var recoverableItems: [ReadingExperienceTrashItem] { (readingState.trash ?? []).filter { $0.kind == "layer" || $0.kind == "alignment" } }
    private var scopedAnchorIDs: Set<String>? {
        sourceID.map { id in Set(anchors.filter { $0.unitID == id }.map(\.id)) }
    }
    private var layers: [ReadingLayer] {
        let ids = scopedAnchorIDs
        return readingState.layers.filter { layer in
            (layerKind == "all" || layer.kind == layerKind) && (ids == nil || !ids!.isDisjoint(with: layer.sourceAnchorIDs))
        }
    }
    private var alignments: [ReferenceAlignment] {
        guard layerKind == "all" || layerKind == "reference" else { return [] }
        let ids = scopedAnchorIDs
        return readingState.alignments.filter { ids == nil || !ids!.isDisjoint(with: $0.sourceAnchorIDs) }
    }
    private var kinds: [String] {
        var result = ["all", "explanation", "translation", "commentary", "glossary", "reference"]
        for kind in readingState.layers.map(\.kind) where !result.contains(kind) { result.append(kind) }
        return result
    }
    /// A directory entry represents saved companion content, not every source
    /// page. Empty pages remain available in the original reader.
    private var contentUnitIDs: Set<String> {
        let populatedLayers = readingState.layers.filter {
            (layerKind == "all" || $0.kind == layerKind) && !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let populatedAlignments = (layerKind == "all" || layerKind == "reference")
            ? readingState.alignments.filter { !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } : []
        let usedAnchors = Set(populatedLayers.flatMap(\.sourceAnchorIDs) + populatedAlignments.flatMap(\.sourceAnchorIDs))
        return Set(anchors.filter { usedAnchors.contains($0.id) }.map(\.unitID))
    }
    private var units: [SourceUnit] {
        let original = unitScope == "page" ? store.visibleSourceUnits : (store.book?.units ?? [])
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let populated = contentUnitIDs
        return original.filter { populated.contains($0.id) && (query.isEmpty || $0.locator.localizedCaseInsensitiveContains(query) || $0.chapter.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query)) }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1000
            HStack(alignment: .top, spacing: 20) {
                if wide && showsDirectory {
                    directory(close: { showsDirectory = false }).frame(width: 304).readingGlass(radius: 22)
                }
                paper(wide: wide).frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(.horizontal, 24).padding(.top, 96).padding(.bottom, 24)
                .onAppear {
                    if !initialized { showsDirectory = wide; initializeSelection(); initialized = true }
                }
                .onChange(of: wide) { _, value in if !value { showsDirectory = false } }
        }
        .background(Palette.canvas)
        .onChange(of: store.bookID) { _, _ in initializeSelection(); layerKind = "all"; search = ""; restorationNotice = "" }
        .onChange(of: store.selectedUnitID) { _, id in if sourceID != nil { sourceID = id; expandedSource = false } }
        .confirmationDialog("移除这条伴读内容？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { item in
            Button("移入伴读回收站", role: .destructive) { Task { await store.removeReadingItem(item.id, kind: item.kind) } }
        } message: { item in Text("\(item.title)\n原书和已保存的 Markdown 保留，可从伴读恢复菜单恢复。") }
    }

    private func initializeSelection() {
        unitScope = definition?.scope == "book" ? "book" : "page"
        sourceID = definition?.scope == "book" ? nil : (store.selectedUnitID ?? store.book?.units.first?.id)
        expandedSource = false
    }
    private func choose(_ unit: SourceUnit) {
        sourceID = unit.id; expandedSource = false
        store.navigateToUnit(unit.id); store.selectedObjectID = nil
        showsDirectoryPopover = false
    }
    private func directory(close: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            HStack {
                Label("原文片段", systemImage: "text.alignleft").font(.system(size: 18, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "sidebar.left") }.buttonStyle(ReadingToolbarButtonStyle()).help("收起原文片段")
            }.padding(.horizontal, 18).padding(.top, 8)
            TextField("查找段落或章节", text: $search).textFieldStyle(.roundedBorder).controlSize(.large).padding(.horizontal, 16)
            Picker("原文范围", selection: $unitScope) { Text("全书").tag("book"); Text("当前页 / 单元").tag("page") }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16)
            Button { sourceID = nil; showsDirectoryPopover = false } label: {
                Label("查看全书伴读", systemImage: "books.vertical").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(ReadingToolbarButtonStyle(selected: sourceID == nil)).padding(.horizontal, 10)
            Divider().opacity(0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(units) { value in sourceRow(value).id(value.id) }
                        if units.isEmpty { Text(contentUnitIDs.isEmpty ? "还没有已保存的伴读内容" : "此范围没有匹配的伴读片段").font(.system(size: 14)).foregroundStyle(.secondary).padding(22) }
                    }.padding(12)
                }.onChange(of: sourceID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                    .onAppear { if let sourceID { proxy.scrollTo(sourceID, anchor: .center) } }
            }
        }.frame(maxHeight: .infinity)
    }
    private func sourceRow(_ value: SourceUnit) -> some View {
        Button { choose(value) } label: {
            HStack(alignment: .top, spacing: 12) {
                Text("\(value.order + 1)").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Palette.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 9) {
                    Text(value.locator).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).lineLimit(2)
                    Text(value.text.isEmpty ? "尚未识别文本，请对照原书" : value.text).font(.system(size: 15, design: .serif)).lineSpacing(4).lineLimit(3).multilineTextAlignment(.leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(14).frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                .background(sourceID == value.id ? Palette.accent.opacity(0.1) : Palette.paper.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(sourceID == value.id ? Palette.accent.opacity(0.4) : Palette.line.opacity(0.7), lineWidth: 0.7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func paper(wide: Bool) -> some View {
        VStack(spacing: 0) {
            paperHeader(wide: wide).padding(22)
            if !restorationNotice.isEmpty {
                HStack(spacing: 10) {
                    Label(restorationNotice, systemImage: "checkmark.circle").font(.system(size: 14)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { restorationNotice = "" } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).accessibilityLabel("关闭恢复提示")
                }.padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 4)
                    .background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 22).padding(.bottom, 12)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(kinds, id: \.self) { kind in
                        Button(kindTitle(kind)) { layerKind = kind }.buttonStyle(ReadingToolbarButtonStyle(selected: layerKind == kind))
                    }
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider().padding(.horizontal, 22)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if !contentUnitIDs.isEmpty { sourceQuote }
                    if let error = store.readingExperienceError { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.system(size: 14)).textSelection(.enabled) }
                    ForEach(layers) { layer in layerCard(layer) }
                    ForEach(alignments) { alignment in alignmentCard(alignment) }
                    if layers.isEmpty && alignments.isEmpty { emptyCompanion }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().opacity(0.6)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { footerActions; Spacer(minLength: 0); attribution }
                VStack(alignment: .leading, spacing: 8) { footerActions; attribution }
            }.padding(16)
        }.background(Palette.paper, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.line, lineWidth: 0.75))
    }
    private func paperHeader(wide: Bool) -> some View {
        HStack(spacing: 12) {
            Text(definition?.title ?? "多层伴读").font(.system(size: 25, weight: .semibold, design: .serif)).lineLimit(1)
            Spacer(minLength: 8)
            if !wide || !showsDirectory {
                Button {
                    if wide { showsDirectory = true } else { showsDirectoryPopover = true }
                } label: { Label("原文片段", systemImage: "sidebar.left") }.buttonStyle(ReadingToolbarButtonStyle())
                    .popover(isPresented: $showsDirectoryPopover) { directory(close: { showsDirectoryPopover = false }).frame(width: 320, height: 510).environmentObject(store) }
            }
            Menu {
                if recoverableItems.isEmpty { Text("暂无已移除的释义、译文或资料对读") }
                ForEach(recoverableItems) { item in
                    Button("恢复 · \(item.kind == "alignment" ? "资料对读" : kindTitle(item.layer?.kind ?? "explanation")) · \(item.title)") { restore(item) }.disabled(store.isBusy)
                }
            } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.menuStyle(.borderlessButton).help("伴读回收与恢复")
        }
    }
    @ViewBuilder private var sourceQuote: some View {
        if let unit {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(unit.locator).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary); Spacer(); Button("回到原书") { store.navigateToUnit(unit.id); store.route = "reader" }.buttonStyle(ReadingToolbarButtonStyle()) }
                // Always pass the complete source to Markdown/KaTeX. A folded
                // viewport clips presentation only and cannot split a TeX pair.
                RichMarkdownView(markdown: unit.text, sourceText: unit.text)
                    .readingTextContext(.source)
                    .id(unit.id)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: LayerSourceHeightPreference.self, value: geometry.size.height)
                        }.allowsHitTesting(false)
                    }
                    .frame(maxHeight: expandedSource ? nil : 220, alignment: .top)
                    .clipped()
                    .onPreferenceChange(LayerSourceHeightPreference.self) { sourceRenderedHeight = $0 }
                if sourceRenderedHeight > 220 { Button(expandedSource ? "收起完整原文" : "展开完整原文") { expandedSource.toggle() }.buttonStyle(ReadingToolbarButtonStyle()) }
                if unit.text.isEmpty { Label("此片段尚未获得可读文字，原书仍保留。", systemImage: "doc.viewfinder").foregroundStyle(.secondary) }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Palette.accent).frame(width: 3).padding(.vertical, 14) }
        } else {
            Text("全书伴读 · 从左侧选择原文片段可缩小范围。不同来源分别标注，解释不会改写原书。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }
    private func layerCard(_ layer: ReadingLayer) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            itemHeading(layer.title, label: kindTitle(layer.kind) + " · " + layer.sourceLabel, id: layer.id, kind: "layer")
            MarkdownText(markdown: layer.markdown).readingTextContext(.companion)
            provenance(layer.provenance)
            sourceLinks(layer.sourceAnchorIDs)
            Button { store.newReadingNote(title: layer.title, markdown: layer.markdown + "\n\n_\(layer.sourceLabel)_", anchorIDs: layer.sourceAnchorIDs) } label: { Label("整理为 Markdown 草稿", systemImage: "square.and.pencil") }
                .buttonStyle(ReadingToolbarButtonStyle()).disabled(store.isBusy || store.editorDirty)
        }.softPanel()
    }
    private func alignmentCard(_ item: ReferenceAlignment) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            itemHeading(item.title, label: "资料对读 · " + (item.status == "proposed" ? "待核对" : item.status), id: item.id, kind: "alignment")
            MarkdownText(markdown: item.markdown).readingTextContext(.companion)
            provenance(item.provenance)
            sourceLinks(item.sourceAnchorIDs)
            Button { store.newReadingNote(title: item.title, markdown: item.markdown, anchorIDs: item.sourceAnchorIDs) } label: { Label("整理为 Markdown 草稿", systemImage: "square.and.pencil") }
                .buttonStyle(ReadingToolbarButtonStyle()).disabled(store.isBusy || store.editorDirty)
        }.softPanel()
    }
    private func itemHeading(_ title: String, label: String, id: String, kind: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 9) { Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent); Text(title).font(.system(size: 23, weight: .semibold, design: .serif)) }
            Spacer(minLength: 0)
            Menu { Button("移入伴读回收站", role: .destructive) { restorationNotice = ""; removal = LayerRemoval(id: id, kind: kind, title: title) }.disabled(store.isBusy) } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.menuStyle(.borderlessButton)
        }
    }
    private func sourceLinks(_ ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ids, id: \.self) { id in
                if let anchor = anchors.first(where: { $0.id == id }) {
                    Button { store.focusReadingAnchor(id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(store.book?.units.first(where: { $0.id == anchor.unitID })?.locator ?? "原文依据", systemImage: "arrow.uturn.backward").font(.system(size: 13, weight: .medium))
                            Text(anchor.quote).font(.system(size: 15, design: .serif)).lineLimit(4).multilineTextAlignment(.leading)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(14).background(Palette.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                }
            }
        }
    }
    @ViewBuilder private func provenance(_ value: ReadingProvenance?) -> some View {
        if let value {
            HStack(spacing: 12) {
                Text([value.label, value.workTitle, value.locator].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(.secondary)
                if let string = value.url, let url = URL(string: string), ["http", "https"].contains(url.scheme ?? "") { Link("标明的来源", destination: url).font(.system(size: 13)) }
            }
        }
    }
    private var emptyCompanion: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("这一范围还没有\(layerKind == "all" ? "伴读内容" : kindTitle(layerKind))", systemImage: "text.book.closed").font(.system(size: 19, weight: .medium))
            Text(unit == nil ? "从原文片段中选一段，再让自己的 AI 补充解释、译文或相关资料。" : "原文已经在上方显示。可以切换内容类型，或增强这个片段；生成内容另行保存并保留出处。")
                .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
        }.padding(22).frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 16))
    }
    private var footerActions: some View {
        HStack(spacing: 12) {
            Button { if let unit { store.navigateToUnit(unit.id); store.selectedObjectID = nil }; store.askAboutReadingContext() } label: { Label("问这一片段", systemImage: "bubble.left").frame(minHeight: 44) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(unit == nil).help("使用当前原文片段全文提问；在上方拖选文字可复制。")
            Button { if let unit { store.navigateToUnit(unit.id); store.selectedObjectID = nil }; store.enhanceCurrentSource() } label: { Label(store.isBusy ? "正在处理…" : "增强当前片段", systemImage: "sparkles") }.buttonStyle(ReadingToolbarButtonStyle()).disabled(unit == nil || store.isBusy)
        }
    }
    private var attribution: some View { Text("AI 解释另列来源，请对照原文核对。追问后主动保存才成为笔记。").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func restore(_ item: ReadingExperienceTrashItem) {
        let expectedBookID = store.bookID
        restorationNotice = ""; store.readingExperienceError = nil
        Task { @MainActor in
            await store.restoreReadingItem(item.id)
            guard store.bookID == expectedBookID else { return }
            if !(store.book?.readingExperience?.trash ?? []).contains(where: { $0.id == item.id }) {
                restorationNotice = "已恢复“\(String(item.title.prefix(80)))”到原文位置。若未显示，请切换原文片段或内容筛选。"
            }
        }
    }
    private func kindTitle(_ kind: String) -> String {
        ["all": "全部", "explanation": "释义", "translation": "译文", "commentary": "评注", "glossary": "名物 / 术语", "reference": "资料对读"][kind] ?? kind
    }
}

private struct LayerRemoval: Identifiable { let id: String; let kind: String; let title: String }

private struct LayerSourceHeightPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
