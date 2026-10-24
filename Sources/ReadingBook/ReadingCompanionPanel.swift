import SwiftUI
import ReadingCore

/// One contextual panel shared by source reading and declared plugin views.
struct ReadingCompanionPanel: View {
    @EnvironmentObject var store: AppStore
    var section: String = "context"
    var scope: String = "current"
    var onClose: (() -> Void)?
    var showsHeader = true
    @State private var removal: ReadingItemRemoval?
    @State private var companionScope: ReadingQueryScope = .page
    @State private var frozenScope: ReadingQuerySnapshot?
    @State private var items = ReadingContextItems()
    @State private var crossScopeCount = 0
    @State private var showsSourceContext = false
    private var avoidsSpoilers: Bool { scope != "book" && store.book?.temporalKnowledge?.profile?.avoidsSpoilers != false }
    private var sourceUnits: [SourceUnit] {
        guard let book = store.book else { return [] }
        if let frozenScope, frozenScope.bookID == book.id {
            let ids = Set(frozenScope.unitIDs); return book.units.filter { ids.contains($0.id) }.sorted { $0.order < $1.order }
        }
        if scope == "book" { return book.units.sorted { $0.order < $1.order } }
        guard let unit = store.selectedUnit else { return [] }
        if companionScope == .chapter { return book.units.filter { $0.chapter == unit.chapter }.sorted { $0.order < $1.order } }
        return unit.page.map { page in book.units.filter { $0.page == page }.sorted { $0.order < $1.order } } ?? [unit]
    }
    private var scopeTitle: String {
        if let frozenScope { return frozenScope.displayTitle + " · 已固定" }
        if scope == "book" { return "全书已有伴读" }
        if companionScope == .chapter { return store.selectedUnit?.chapter ?? "当前章节" }
        return store.selectedUnit?.locator ?? "请先打开原文"
    }
    private var projectionKey: String {
        [store.bookID ?? "", String(store.projectRevision), store.selectedUnitID ?? "", companionScope.rawValue,
         frozenScope?.scopeFingerprint ?? "", scope].joined(separator: "|")
    }
    private var effectiveSection: String {
        let value = section == "context" ? store.readingCompanionSection : section
        return value == "decisions" ? "layers" : value
    }
    private var recoverableItems: [ReadingExperienceTrashItem] {
        (store.book?.readingExperience?.trash ?? []).filter { $0.kind != "decision" }
    }
    private var contentTitle: String {
        effectiveSection == "mentions" ? "原文对象" : effectiveSection == "references" ? "资料对读" : "解释与译文"
    }
    private var contentIcon: String {
        effectiveSection == "mentions" ? "rectangle.stack" : effectiveSection == "references" ? "arrow.left.arrow.right" : "text.book.closed"
    }
    private var hasCompanionContent: Bool {
        if effectiveSection == "mentions" { return !items.entities.isEmpty || !items.events.isEmpty }
        if effectiveSection == "references" { return !items.alignments.isEmpty }
        return !items.layers.isEmpty || !items.alignments.isEmpty
    }
    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack(spacing: 10) {
                    Label("伴读", systemImage: "text.book.closed").font(.system(size: 16, weight: .semibold))
                    Spacer(minLength: 0)
                    if let onClose { Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("收起伴读") }
                }.padding(.horizontal, 16).frame(height: 52)
            }
            HStack(spacing: 8) {
                if section == "context" {
                    Menu {
                        Button { store.readingCompanionSection = "layers" } label: { Label("解释与译文", systemImage: "text.book.closed") }
                        Button { store.readingCompanionSection = "mentions" } label: { Label("原文对象", systemImage: "rectangle.stack") }
                        Button { store.readingCompanionSection = "references" } label: { Label("资料对读", systemImage: "arrow.left.arrow.right") }
                        if !recoverableItems.isEmpty {
                            Divider()
                            Menu {
                                ForEach(recoverableItems) { item in
                                    Button { Task { await store.restoreReadingItem(item.id) } } label: { Label(item.title, systemImage: "arrow.uturn.backward") }.disabled(store.isBusy)
                                }
                            } label: { Label("恢复已移除的伴读", systemImage: "arrow.uturn.backward") }
                        }
                    } label: { Label(contentTitle, systemImage: contentIcon).font(.system(size: 15, weight: .medium)).frame(minHeight: 44) }
                        .menuStyle(.borderlessButton).fixedSize().help("选择伴读内容")
                } else { Label(contentTitle, systemImage: contentIcon).font(.system(size: 15, weight: .medium)).lineLimit(1) }
                if scope != "book" {
                    Menu {
                        Button { companionScope = .page } label: { Label("当前页", systemImage: "doc.text") }
                        Button { companionScope = .chapter } label: { Label("当前章节", systemImage: "book.closed") }
                        if frozenScope != nil { Divider(); Button { frozenScope = nil } label: { Label("解除固定，跟随原文", systemImage: "lock.open") } }
                    } label: {
                        Label(companionScope == .page ? "当前页" : "当前章节", systemImage: frozenScope == nil ? "book.closed" : "lock")
                            .font(.system(size: 13, weight: .medium)).frame(minHeight: 44)
                    }.menuStyle(.borderlessButton).fixedSize().disabled(store.isBusy).help(scopeTitle)
                } else { Text("全书").font(.system(size: 13)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if !recoverableItems.isEmpty && section != "context" {
                    Menu {
                        ForEach(recoverableItems) { item in
                            Button { Task { await store.restoreReadingItem(item.id) } } label: { Label("恢复 \(item.title)", systemImage: "arrow.uturn.backward") }.disabled(store.isBusy)
                        }
                    } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.menuStyle(.borderlessButton).fixedSize().help("恢复已移除的伴读")
                }
                if scope != "book" {
                    Button { showsSourceContext.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(ReadingToolbarButtonStyle(selected: showsSourceContext)).disabled(sourceUnits.isEmpty)
                        .help("查看原文与上下文").accessibilityLabel("原文与上下文")
                }
            }.padding(.horizontal, 16).padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.aiProgress.hasActivity, store.aiProgress.bookID == store.bookID {
                        AIProgressStatusView(state: store.aiProgressState, compact: true)
                    }
                    if let error = store.readingExperienceError { Text(error).font(.system(size: 13)).foregroundStyle(Palette.copper) }
                    if crossScopeCount > 0 {
                        Button { if let component = WorkspaceComponentRegistry.shared.component(id: "reading.layers") { store.activate(component) } } label: {
                            Label("另有 \(crossScopeCount) 条解释涉及其他页，查看完整来源", systemImage: "arrow.up.right.square")
                                .font(.system(size: 13)).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.borderless).disabled(store.isBusy)
                    }
                    if scope != "book" {
                        if let quote = selectedQuote {
                            Text(quote).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                                .background(Palette.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(alignment: .leading) { Capsule().fill(Palette.accent).frame(width: 3).padding(.vertical, 14) }
                        }
                        if showsSourceContext && !sourceUnits.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(scopeTitle, systemImage: "text.quote").font(.system(size: 13)).foregroundStyle(.secondary)
                                ForEach(sourceUnits) { unit in if !unit.text.isEmpty { MarkdownText(markdown: unit.text) } }
                                if sourceUnits.allSatisfy({ $0.text.isEmpty }) { Text("此处尚无可靠识别文本，请先对照原 PDF。") }
                            }.padding(14).background(Palette.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    if effectiveSection == "mentions" { objectSection }
                    else if effectiveSection == "references" { referenceSection }
                    else { layerSection }
                }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().opacity(0.4)
            companionFooter
        }
        .environment(\.markdownReadingStyle, "companion")
        .onAppear(perform: refreshItems)
        .onChange(of: projectionKey) { _, _ in refreshItems() }
        .onChange(of: companionScope) { _, _ in frozenScope = nil }
        .onChange(of: store.bookID) { _, _ in frozenScope = nil; companionScope = .page; refreshItems() }
        .confirmationDialog("移除这条阅读增强？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { item in
            Button("移除", role: .destructive) { Task { await store.removeReadingItem(item.id, kind: item.kind) } }
        } message: { item in Text("\(item.title)\n原书和已保存的 Markdown 保留。") }
    }
    private var companionFooter: some View {
        HStack(spacing: 10) {
            Button(action: askThisScope) { Label("问这部分", systemImage: "bubble.left").frame(maxWidth: .infinity) }
                .buttonStyle(ReadingActionButtonStyle()).disabled(sourceUnits.isEmpty || store.isBusy)
            if hasCompanionContent {
                Button(action: noteThisScope) { Label("记入笔记", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                    .buttonStyle(ReadingActionButtonStyle(prominent: true)).disabled(sourceUnits.isEmpty || store.isBusy)
                if scope != "book" { Button(action: enhanceThisScope) {
                    Group { if store.isBusy { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") } }
                }.buttonStyle(ReadingToolbarButtonStyle()).disabled(sourceUnits.isEmpty || store.isBusy).help("补充这部分的解释").accessibilityLabel("补充这部分的解释") }
            } else {
                if scope != "book" {
                    Button(action: enhanceThisScope) { Label(store.isBusy ? "生成中…" : "生成解释", systemImage: "sparkles").frame(maxWidth: .infinity) }
                        .buttonStyle(ReadingActionButtonStyle(prominent: true)).disabled(sourceUnits.isEmpty || store.isBusy)
                        .help("按上方选择的页或章生成伴读解释")
                }
                Menu {
                    Button(action: noteThisScope) { Label("为这部分记笔记", systemImage: "square.and.pencil") }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 48) }
                    .menuStyle(.borderlessButton).fixedSize().disabled(sourceUnits.isEmpty || store.isBusy).help("更多操作")
            }
        }.padding(16).fixedSize(horizontal: false, vertical: true)
    }
    private func enhanceThisScope() {
        // The host freezes a fresh page/chapter snapshot before any paid request.
        if let first = sourceUnits.first { store.navigateToUnit(first.id) }
        if let snapshot = store.enhanceSourceScope(scope: companionScope) { frozenScope = snapshot }
    }
    private func askThisScope() {
        guard !store.isBusy, let first = sourceUnits.first else { return }
        store.navigateToUnit(first.id)
        store.queryScope = scope == "book" ? .book : (frozenScope?.scope ?? companionScope)
        // This is an explicit transfer. General question controls keep their
        // independent scope until the reader presses this action.
        if store.route == "reader" { store.readingCompanionTab = "chat"; store.readingCompanionVisible = true }
        else { store.requestedWorkspaceRoute = "query" }
    }
    private var selectedQuote: String? {
        guard let anchor = store.selectedSourceAnchor, sourceUnits.contains(where: { $0.id == anchor.unitID }), !anchor.quote.isEmpty else { return nil }
        return anchor.quote
    }
    private func noteThisScope() {
        if let layer = items.layers.first {
            store.newReadingNote(title: layer.title, markdown: layer.markdown + "\n\n_\(layer.sourceLabel)_", anchorIDs: layer.sourceAnchorIDs)
        } else if let unit = sourceUnits.first { store.newNote(for: unit) }
    }
    private func refreshItems() {
        guard let book = store.book else { items = ReadingContextItems(); crossScopeCount = 0; return }
        let state = book.readingExperience ?? ReadingExperienceState()
        if scope == "book" {
            crossScopeCount = 0
            items = ReadingContextItems(anchors: state.anchors, mentions: state.mentions, entities: book.entities, events: book.events, layers: state.layers, alignments: state.alignments)
            return
        }
        let allowed = Set(sourceUnits.map(\.id))
        var anchors = state.anchors.filter { allowed.contains($0.unitID) }
        let existing = Set(anchors.map(\.id))
        anchors.append(contentsOf: store.readingExperienceIndex.anchors.filter { allowed.contains($0.unitID) && !existing.contains($0.id) })
        let anchorIDs = Set(anchors.map(\.id))
        var mentions = state.mentions.filter { anchorIDs.contains($0.anchorID) }
        let existingMentions = Set(mentions.map(\.id))
        mentions.append(contentsOf: store.readingExperienceIndex.mentions.filter { anchorIDs.contains($0.anchorID) && !existingMentions.contains($0.id) })
        let targets = Set(mentions.map(\.targetID))
        let events = book.events.filter { targets.contains($0.id) || $0.evidence.contains { allowed.contains($0.unitID) } }
        let relatedEntities = Set(events.flatMap { $0.placeIDs + $0.participantIDs })
        func fullyLocal(_ ids: [String]) -> Bool { !ids.isEmpty && ids.allSatisfy { anchorIDs.contains($0) } }
        let layers = state.layers.filter { fullyLocal($0.sourceAnchorIDs) }
        let alignments = state.alignments.filter { fullyLocal($0.sourceAnchorIDs) }
        crossScopeCount = state.layers.filter { !anchorIDs.isDisjoint(with: $0.sourceAnchorIDs) && !fullyLocal($0.sourceAnchorIDs) }.count +
            state.alignments.filter { !anchorIDs.isDisjoint(with: $0.sourceAnchorIDs) && !fullyLocal($0.sourceAnchorIDs) }.count
        items = ReadingContextItems(anchors: anchors, mentions: mentions,
            entities: book.entities.filter { targets.contains($0.id) || relatedEntities.contains($0.id) || $0.evidence.contains { allowed.contains($0.unitID) } },
            events: events,
            layers: layers, alignments: alignments)
    }
    @ViewBuilder private var layerSection: some View {
        if items.layers.isEmpty {
            empty(scope == "book" ? "还没有保存的伴读" : "这一页，还可以读得更深", detail: scope == "book" ? "回到原文页，生成解释或留下笔记。" : "生成解释，或围绕当前内容提一个问题。")
        }
        ForEach(items.layers) { layer in
            VStack(alignment: .leading, spacing: 10) {
                itemHeader(layer.title, label: layer.sourceLabel, id: layer.id, kind: "layer")
                MarkdownText(markdown: layer.markdown)
                provenance(layer.provenance)
                anchorButtons(layer.sourceAnchorIDs)
                Button { store.newReadingNote(title: layer.title, markdown: layer.markdown + "\n\n_\(layer.sourceLabel)_", anchorIDs: layer.sourceAnchorIDs) } label: { Label("存为笔记草稿", systemImage: "square.and.pencil") }.buttonStyle(.borderless).font(.system(size: 13)).frame(minHeight: 44)
            }.readingCompanionCard()
        }
        if !items.alignments.isEmpty { referenceSection }
    }
    @ViewBuilder private var referenceSection: some View {
        if items.alignments.isEmpty { empty("资料对读", detail: "把同一书内相关段落放在一起，分别回到出处。外部资料需有来源，AI 的解释会单独标识。") }
        ForEach(items.alignments) { alignment in
            VStack(alignment: .leading, spacing: 10) {
                itemHeader(alignment.title, label: "资料对齐 · \(alignment.status == "proposed" ? "待核对" : alignment.status)", id: alignment.id, kind: "alignment")
                MarkdownText(markdown: alignment.markdown)
                provenance(alignment.provenance)
                anchorButtons(alignment.sourceAnchorIDs)
                Button { store.newReadingNote(title: alignment.title, markdown: alignment.markdown, anchorIDs: alignment.sourceAnchorIDs) } label: { Label("存为笔记草稿", systemImage: "square.and.pencil") }.buttonStyle(.borderless).font(.system(size: 13)).frame(minHeight: 44)
            }.readingCompanionCard()
        }
    }
    @ViewBuilder private var objectSection: some View {
        if items.entities.isEmpty && items.events.isEmpty { empty("原文中的对象", detail: "名称和引用都对应同一个对象。人物、地点、定理、概念等由 AI 按书建立。") }
        ForEach(items.entities) { entity in
            DisclosureGroup(isExpanded: Binding(get: { store.selectedObjectID == entity.id }, set: { store.selectedObjectID = $0 ? entity.id : nil })) {
                VStack(alignment: .leading, spacing: 10) {
                    if avoidsSpoilers {
                        Text("这里先看本范围的原文出现处；全书概述和属性留到对象详情再展开。")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    } else {
                        Text(entity.summary).font(.system(size: 15)).textSelection(.enabled)
                        if !entity.aliases.isEmpty { Text("别名：" + entity.aliases.joined(separator: "、")).font(.system(size: 13)).foregroundStyle(.secondary) }
                        ForEach(entity.properties.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .top) { Text(key).foregroundStyle(.secondary); Text(entity.properties[key] ?? "").textSelection(.enabled) }.font(.system(size: 13))
                        }
                    }
                    appearances(entity.id, evidence: entity.evidence)
                    relatedObjects(entity.id)
                }.padding(.top, 10)
            } label: {
                HStack { Image(systemName: entity.latitude == nil ? "square.stack" : "mappin"); Text(entity.name).font(.system(size: 16, weight: .semibold)); Spacer(); Text(store.book?.types.first { $0.id == entity.typeID }?.name ?? entity.typeID).font(.system(size: 13)).foregroundStyle(.secondary) }
            }.readingCompanionCard()
        }
        ForEach(items.events) { event in
            VStack(alignment: .leading, spacing: 10) {
                Text(event.name).font(.system(size: 16, weight: .semibold)); Text(event.dateText).font(.system(size: 13)).foregroundStyle(.secondary)
                if !avoidsSpoilers { Text(event.summary).font(.system(size: 15)).textSelection(.enabled) }
                appearances(event.id, evidence: event.evidence)
                if !event.placeIDs.isEmpty {
                    Button { store.selectedObjectID = event.id; store.readingScopeCurrent = true; store.activate(.map) } label: { Label("在时间与地图中查看", systemImage: "map") }.buttonStyle(.borderless).font(.system(size: 13)).frame(minHeight: 44)
                }
            }.readingCompanionCard()
        }
    }
    @ViewBuilder private var decisionSection: some View {
        if items.decisions.isEmpty { empty("停下来想一想", detail: "历史可先做选择再看后果；数学可先判断推理路径，再展开解析。思考只保留在本机，主动保存才形成 Markdown。") }
        ForEach(items.decisions) { card in
            ReadingDecisionView(card: card, onRemove: { removal = ReadingItemRemoval(id: card.id, kind: "decision", title: card.title) })
        }
    }
    private func empty(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 24, weight: .medium)).foregroundStyle(Palette.accent)
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(detail).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5)
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 140, alignment: .center).padding(.vertical, 8)
    }
    private func itemHeader(_ title: String, label: String, id: String, kind: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 16, weight: .semibold)); Text(label).font(.system(size: 13)).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Menu { Button(role: .destructive) { removal = ReadingItemRemoval(id: id, kind: kind, title: title) } label: { Label("移入伴读回收站", systemImage: "trash") } } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.menuStyle(.borderlessButton).fixedSize()
        }
    }
    @ViewBuilder private func provenance(_ value: ReadingProvenance?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 4) {
                Text([value.label, value.workTitle, value.locator].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(.secondary)
                if let string = value.url, let url = URL(string: string), ["http", "https"].contains(url.scheme ?? "") { Link(destination: url) { Label("查看来源", systemImage: "arrow.up.right.square") }.font(.system(size: 13)).frame(minHeight: 44) }
            }
        }
    }
    private func anchorButtons(_ ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ids, id: \.self) { id in
                if let anchor = store.readingExperienceIndex.anchors.first(where: { $0.id == id }) ?? store.book?.readingExperience?.anchors.first(where: { $0.id == id }) {
                    Button { store.focusReadingAnchor(id) } label: { Label(String(anchor.quote.prefix(100)), systemImage: "arrow.uturn.backward").font(.system(size: 13)).lineLimit(3).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                }
            }
        }
    }
    private func appearances(_ id: String, evidence: [Evidence]) -> some View {
        let allowed = Set(sourceUnits.map(\.id))
        let visible = avoidsSpoilers ? evidence.filter { allowed.contains($0.unitID) } : evidence
        return VStack(alignment: .leading, spacing: 6) {
            Text("原文出现处").font(.system(size: 13)).foregroundStyle(.secondary)
            ForEach(Array(visible.prefix(24).enumerated()), id: \.offset) { _, source in
                Button { store.follow(source) } label: { Text(source.quote).font(.system(size: 13)).lineLimit(3).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
            }
        }
    }
    private func relatedObjects(_ id: String) -> some View {
        let allowed = Set(sourceUnits.map(\.id))
        let relations = (store.book?.relations ?? []).filter {
            ($0.fromID == id || $0.toID == id) && (!avoidsSpoilers || (!$0.evidence.isEmpty && $0.evidence.allSatisfy { allowed.contains($0.unitID) }))
        }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(relations.prefix(16)) { relation in
                let other = relation.fromID == id ? relation.toID : relation.fromID
                Button { store.showReadingObject(other) } label: { Label("\(relation.label) · \(store.objectTitle(other))", systemImage: "point.3.connected.trianglepath.dotted").font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
            }
        }
    }
}

private struct ReadingItemRemoval: Identifiable { let id: String; let kind: String; let title: String }

private struct ReadingDecisionView: View {
    @EnvironmentObject var store: AppStore
    let card: DecisionCard
    var onRemove: () -> Void
    @State private var choice: String?
    @State private var thought = ""
    @State private var revealed = false
    private var draftKey: String { "decision-draft-\(store.bookID ?? "")-\(card.id)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(card.title).font(.subheadline.weight(.semibold)); Spacer(); Menu { Button("移除", role: .destructive, action: onRemove) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 32, height: 32) }
            Text(card.sourceLabel).font(.caption2).foregroundStyle(.secondary)
            MarkdownText(markdown: card.contextMarkdown)
            ForEach(card.options) { option in
                Button { choice = option.id } label: {
                    HStack(alignment: .top, spacing: 10) { Image(systemName: choice == option.id ? "checkmark.circle.fill" : "circle"); Text(option.title).font(.subheadline); Spacer(minLength: 0) }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .background(Palette.accent.opacity(choice == option.id ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
                if choice == option.id { MarkdownText(markdown: option.markdown) }
            }
            TextField("我这样判断的理由…", text: $thought, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
            if revealed { MarkdownText(markdown: card.historicalOutcomeMarkdown) }
            Button(revealed ? "收起解析" : "看原书结果与解析") { revealed.toggle() }.disabled(choice == nil).buttonStyle(.borderless)
            Button("保存我的思考为 Markdown 草稿") {
                let selected = card.options.first { $0.id == choice }?.title ?? "尚未选择"
                let outcome = revealed ? "\n\n## 原书结果与解析\n\n\(card.historicalOutcomeMarkdown)" : ""
                store.newReadingNote(title: card.title, markdown: "\(card.contextMarkdown)\n\n## 我的选择\n\n\(selected)\n\n\(thought)\(outcome)\n\n_\(card.sourceLabel)_", anchorIDs: card.sourceAnchorIDs)
            }.font(.caption).buttonStyle(.borderless)
        }.readingCompanionCard().id(card.id)
        .onAppear {
            let draft = UserDefaults.standard.dictionary(forKey: draftKey) ?? [:]
            choice = (draft["choice"] as? String).flatMap { id in card.options.contains { $0.id == id } ? id : nil }
            thought = draft["thought"] as? String ?? ""; revealed = draft["revealed"] as? Bool ?? false
        }
        .onChange(of: choice) { _, _ in persistThought() }
        .onChange(of: thought) { _, _ in persistThought() }
        .onChange(of: revealed) { _, _ in persistThought() }
    }
    private func persistThought() { UserDefaults.standard.set(["choice": choice ?? "", "thought": String(thought.prefix(100_000)), "revealed": revealed] as [String: Any], forKey: draftKey) }
}

struct ReadingExperienceWorkspaceView: View {
    @EnvironmentObject var store: AppStore
    var section: String
    var definition: ViewDefinition?
    @ViewBuilder
    var body: some View {
        if section == "layers" { ReadingLayersWorkspaceView(definition: definition) }
        else if section == "mentions" { SourceIndexWorkspaceView(definition: definition) }
        else {
            ReadingCompanionPanel(section: section, scope: definition?.scope ?? "current")
                .frame(maxWidth: 900).padding(22).readingGlass(radius: 22)
                .padding(.horizontal, 24).padding(.top, 96).padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas)
        }
    }
}

private extension View {
    func readingCompanionCard() -> some View { padding(14).background(Palette.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 14)) }
}
