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
    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { HStack(spacing: 10) {
                Label("伴读", systemImage: "text.book.closed").font(.headline)
                Spacer()
                if section == "context" { Menu {
                    Button("解释与译文") { store.readingCompanionSection = "layers" }
                    Button("原文中的对象") { store.readingCompanionSection = "mentions" }
                    Button("资料对读") { store.readingCompanionSection = "references" }
                } label: { Image(systemName: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).frame(width: 40, height: 40).help("选择伴读内容") }
                if !recoverableItems.isEmpty {
                    Menu {
                        ForEach(recoverableItems) { item in Button("恢复 \(item.title)") { Task { await store.restoreReadingItem(item.id) } }.disabled(store.isBusy) }
                    } label: { Image(systemName: "arrow.uturn.backward") }.menuStyle(.borderlessButton).frame(width: 40, height: 40).help("恢复已移除的伴读")
                }
                if let onClose { Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("收起伴读") }
            }.padding(.horizontal, 16).padding(.top, 8) }
            if !showsHeader {
                HStack {
                    Menu {
                        Button("此处伴读") { store.readingCompanionSection = "context" }
                        Button("解释与译文") { store.readingCompanionSection = "layers" }
                        Button("原文对象") { store.readingCompanionSection = "mentions" }
                        Button("资料对读") { store.readingCompanionSection = "references" }
                    } label: { Label("伴读内容", systemImage: "ellipsis").font(.system(size: 13)).frame(minHeight: 44) }
                        .menuStyle(.borderlessButton)
                    Spacer(minLength: 6)
                    if !recoverableItems.isEmpty {
                        Menu { ForEach(recoverableItems) { item in Button("恢复 \(item.title)") { Task { await store.restoreReadingItem(item.id) } }.disabled(store.isBusy) } } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.menuStyle(.borderlessButton).help("恢复已移除的伴读")
                    }
                }.padding(.horizontal, 16)
            }
            HStack(alignment: .top, spacing: 8) {
                if scope != "book" {
                    Menu {
                        Button { companionScope = .page } label: { Label("当前页", systemImage: "doc.text") }
                        Button { companionScope = .chapter } label: { Label("当前章节", systemImage: "book.closed") }
                    } label: {
                        Label(companionScope == .page ? "当前页" : "当前章节", systemImage: frozenScope == nil ? "book.closed" : "lock")
                            .font(.system(size: 14, weight: .medium)).padding(.horizontal, 12).frame(minHeight: 44)
                            .background(Palette.paper.opacity(0.55), in: Capsule())
                    }.menuStyle(.borderlessButton).fixedSize().disabled(store.isBusy).help(scopeTitle)
                } else { Text("全书已有伴读").font(.subheadline).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if frozenScope != nil {
                    Button("跟随原文") { frozenScope = nil }.font(.caption).buttonStyle(.borderless).disabled(store.isBusy)
                }
            }.padding(.horizontal, 24).padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let error = store.readingExperienceError { Text(error).font(.caption).foregroundStyle(Palette.copper) }
                    if crossScopeCount > 0 {
                        Button { if let component = WorkspaceComponentRegistry.shared.component(id: "reading.layers") { store.activate(component) } } label: {
                            Label("另有 \(crossScopeCount) 条解释涉及其他页，查看完整来源", systemImage: "arrow.up.right.square")
                                .font(.caption).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        }.buttonStyle(.borderless).disabled(store.isBusy)
                    }
                    if scope != "book" {
                        if let quote = selectedQuote {
                            Text(quote).font(.system(size: 17, design: .serif)).lineSpacing(7).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                                .background(Palette.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(alignment: .leading) { Capsule().fill(Palette.accent).frame(width: 3).padding(.vertical, 14) }
                        }
                        DisclosureGroup("原文与上下文", isExpanded: $showsSourceContext) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(scopeTitle).font(.caption).foregroundStyle(.secondary)
                                ForEach(sourceUnits) { unit in if !unit.text.isEmpty { MarkdownText(markdown: unit.text) } }
                                if sourceUnits.allSatisfy({ $0.text.isEmpty }) { Text("此处尚无可靠识别文本，请先对照原 PDF。") }
                            }.padding(.top, 12)
                        }.font(.system(size: 13)).foregroundStyle(Palette.accent)
                    }
                    if effectiveSection == "mentions" { objectSection }
                    else if effectiveSection == "references" { referenceSection }
                    else { layerSection }
                }.padding(.horizontal, 24).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
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
            HStack(spacing: 8) {
                Button(action: askThisScope) { Label("问这部分", systemImage: "bubble.left").frame(maxWidth: .infinity) }
                    .buttonStyle(ReadingActionButtonStyle()).disabled(sourceUnits.isEmpty || store.isBusy)
                Button(action: noteThisScope) { Label("记入笔记", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                    .buttonStyle(ReadingActionButtonStyle(prominent: true)).disabled(sourceUnits.isEmpty || store.isBusy)
            if scope != "book" {
                Button {
                    // The host freezes a fresh page/chapter snapshot before any paid request.
                    if let first = sourceUnits.first { store.navigateToUnit(first.id) }
                    if let snapshot = store.enhanceSourceScope(scope: companionScope) { frozenScope = snapshot }
                } label: {
                    Group { if store.isBusy { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") } }
                        .frame(minWidth: 28, minHeight: 32)
                }.buttonStyle(.borderedProminent).controlSize(.large).frame(minWidth: 44, minHeight: 44)
                    .disabled(sourceUnits.isEmpty || store.isBusy).help("补充这部分的解释")
                    .accessibilityLabel("补充这部分的解释")
                    .accessibilityHint("按上方选择的页或章生成伴读解释")
            }
        }.padding(.horizontal, 14).padding(.vertical, 10).fixedSize(horizontal: false, vertical: true)
    }
    private func askThisScope() {
        guard !store.isBusy, let first = sourceUnits.first else { return }
        store.navigateToUnit(first.id)
        store.queryScope = scope == "book" ? .book : (frozenScope?.scope ?? companionScope)
        // This is an explicit transfer. General question controls keep their
        // independent scope until the reader presses this action.
        store.requestedWorkspaceRoute = "query"
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
            empty("读到这里，可以再想一想", detail: "选一段原文来聊，或点下方的星光，为这一页补充解释。")
        }
        ForEach(items.layers) { layer in
            VStack(alignment: .leading, spacing: 10) {
                itemHeader(layer.title, label: layer.sourceLabel, id: layer.id, kind: "layer")
                MarkdownText(markdown: layer.markdown)
                provenance(layer.provenance)
                anchorButtons(layer.sourceAnchorIDs)
                Button("整理成我的 Markdown 草稿") { store.newReadingNote(title: layer.title, markdown: layer.markdown + "\n\n_\(layer.sourceLabel)_", anchorIDs: layer.sourceAnchorIDs) }.buttonStyle(.borderless).font(.caption)
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
                Button("整理成 Markdown 草稿") { store.newReadingNote(title: alignment.title, markdown: alignment.markdown, anchorIDs: alignment.sourceAnchorIDs) }.buttonStyle(.borderless).font(.caption)
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
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(entity.summary).font(.system(size: 14)).textSelection(.enabled)
                        if !entity.aliases.isEmpty { Text("别名：" + entity.aliases.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
                        ForEach(entity.properties.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .top) { Text(key).foregroundStyle(.secondary); Text(entity.properties[key] ?? "").textSelection(.enabled) }.font(.caption)
                        }
                    }
                    appearances(entity.id, evidence: entity.evidence)
                    relatedObjects(entity.id)
                }.padding(.top, 10)
            } label: {
                HStack { Image(systemName: entity.latitude == nil ? "square.stack" : "mappin"); Text(entity.name).font(.subheadline.weight(.semibold)); Spacer(); Text(store.book?.types.first { $0.id == entity.typeID }?.name ?? entity.typeID).font(.caption).foregroundStyle(.secondary) }
            }.readingCompanionCard()
        }
        ForEach(items.events) { event in
            VStack(alignment: .leading, spacing: 10) {
                Text(event.name).font(.subheadline.weight(.semibold)); Text(event.dateText).font(.caption).foregroundStyle(.secondary)
                if !avoidsSpoilers { Text(event.summary).font(.system(size: 14)).textSelection(.enabled) }
                appearances(event.id, evidence: event.evidence)
                if !event.placeIDs.isEmpty {
                    Button("在时间与地图中查看") { store.selectedObjectID = event.id; store.readingScopeCurrent = true; store.activate(.map) }.buttonStyle(.borderless).font(.caption)
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
            Image(systemName: "sparkles").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.accent).padding(.bottom, 8)
            Text(title).font(.system(size: 21, weight: .medium, design: .serif))
            Text(detail).font(.system(size: 16, design: .serif)).foregroundStyle(.secondary).lineSpacing(7)
        }.frame(maxWidth: .infinity, minHeight: 190, alignment: .center).padding(.vertical, 22)
    }
    private func itemHeader(_ title: String, label: String, id: String, kind: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline.weight(.semibold)); Text(label).font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Menu { Button("移除增强条目", role: .destructive) { removal = ReadingItemRemoval(id: id, kind: kind, title: title) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 32, height: 32)
        }
    }
    @ViewBuilder private func provenance(_ value: ReadingProvenance?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 4) {
                Text([value.label, value.workTitle, value.locator].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                if let string = value.url, let url = URL(string: string), ["http", "https"].contains(url.scheme ?? "") { Link("查看标明的来源", destination: url).font(.caption) }
            }
        }
    }
    private func anchorButtons(_ ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ids, id: \.self) { id in
                if let anchor = store.readingExperienceIndex.anchors.first(where: { $0.id == id }) ?? store.book?.readingExperience?.anchors.first(where: { $0.id == id }) {
                    Button { store.focusReadingAnchor(id) } label: { Label(String(anchor.quote.prefix(100)), systemImage: "arrow.uturn.backward").font(.caption).lineLimit(3).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                }
            }
        }
    }
    private func appearances(_ id: String, evidence: [Evidence]) -> some View {
        let allowed = Set(sourceUnits.map(\.id))
        let visible = avoidsSpoilers ? evidence.filter { allowed.contains($0.unitID) } : evidence
        return VStack(alignment: .leading, spacing: 6) {
            Text("原文出现处").font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(visible.prefix(24).enumerated()), id: \.offset) { _, source in
                Button { store.follow(source) } label: { Text(source.quote).font(.caption).lineLimit(3).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
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
                Button { store.showReadingObject(other) } label: { Label("\(relation.label) · \(store.objectTitle(other))", systemImage: "point.3.connected.trianglepath.dotted").font(.caption).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
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
