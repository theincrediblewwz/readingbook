import SwiftUI
import ReadingCore

private struct CompanionObjectGroup: Identifiable, Sendable {
    let id: String; let title: String; let icon: String; let entities: [KnowledgeEntity]
}
private struct CompanionProjection: Sendable {
    let items: ReadingContextItems
    let crossScopeCount: Int
    let groups: [CompanionObjectGroup]
    let entities: [String: KnowledgeEntity]
    let events: [String: KnowledgeEvent]
    let layers: [String: ReadingLayer]
    let alignments: [String: ReferenceAlignment]
    let layerPlan: ReadingCompanionRecordPlan
    let alignmentPlan: ReadingCompanionRecordPlan
    let sourceUnits: [SourceUnit]
    let scopeTitle: String
    let scopeMessage: String?
    let scopeStartAnchor: SourceAnchor?

    static func sameSource(_ old: [SourceUnit], _ current: [SourceUnit]) -> Bool {
        let sameBuffer = old.withUnsafeBufferPointer { left in
            current.withUnsafeBufferPointer { right in left.count == right.count && left.baseAddress == right.baseAddress }
        }
        if sameBuffer { return true }
        guard old.count == current.count else { return false }
        for (index, pair) in zip(old, current).enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return false }
            if pair.0.order != pair.1.order || pair.0.page != pair.1.page || !pair.0.id.utf8.elementsEqual(pair.1.id.utf8)
                || !pair.0.text.utf8.elementsEqual(pair.1.text.utf8) { return false }
        }
        return true
    }

    static func build(book: BookProject, index: ReadingExperienceState, scope: String,
                      companionScope: ReadingQueryScope, frozenScope: ReadingQuerySnapshot?,
                      selectedUnitID: String?, chapterAnchor: SourceAnchor?, focusedAnchorID: String?, avoidsSpoilers: Bool) -> Self? {
        guard !Task.isCancelled else { return nil }
        var state = book.readingExperience ?? ReadingExperienceState()
        let archived = Set(book.readerCollections?.archivedCompanionIDs ?? [])
        if !archived.isEmpty {
            state.layers.removeAll { archived.contains("layer:" + $0.id) }
            state.alignments.removeAll { archived.contains("alignment:" + $0.id) }
        }
        var items: ReadingContextItems
        let count: Int
        var selectedUnits: [SourceUnit] = []
        var title = "请先打开原文", scopeMessage: String?
        var scopeStartAnchor: SourceAnchor?
        if scope == "book" {
            selectedUnits = book.units.sorted { $0.order < $1.order }; title = "全书已有伴读"
            items = ReadingContextItems(anchors: state.anchors, mentions: state.mentions, entities: book.entities,
                events: book.events, layers: state.layers, alignments: state.alignments); count = 0
        } else {
            let selected = book.units.first { $0.id == selectedUnitID }
            var units: [SourceUnit] = [], ranges: [ReadingSourceRange]?
            do {
                if let frozenScope, frozenScope.bookID == book.id {
                    units = try frozenScope.scopedSourceUnits(in: book)
                    ranges = try frozenScope.sourceRanges(in: book)
                    title = frozenScope.displayTitle + " · 已固定"
                } else if let selected {
                    if companionScope == .chapter {
                        if let chapters = try BookChapterRuntime.index(in: book) {
                            let offset = try chapterAnchor.map { try ReadingExperienceRuntime.resolve($0, in: book).utf16Location }
                            let chapter = try chapters.chapter(unitID: selected.id, offsetUTF16: offset)
                            guard chapter.isComplete else { throw ReadingError.invalid("这一章的结尾尚未确定，请先继续整理目录。") }
                            ranges = chapter.ranges; title = chapter.title
                            let byID = Dictionary(book.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                            units = try chapter.ranges.map { range in
                                guard var unit = byID[range.unitID] else { throw ReadingError.invalid("目录原文位置已变化。") }
                                unit.text = try range.text(in: unit); unit.chapter = chapter.title; return unit
                            }
                        } else if book.originalName.lowercased().hasSuffix(".pdf") {
                            throw ReadingError.invalid("请先读取或整理目录，再查看当前章节。")
                        } else {
                            let ordered = book.units.sorted { $0.order < $1.order }
                            guard let cursor = ordered.firstIndex(where: { $0.id == selected.id }) else { return nil }
                            var first = cursor, last = cursor
                            while first > 0 && ordered[first - 1].chapter == selected.chapter { first -= 1 }
                            while last + 1 < ordered.count && ordered[last + 1].chapter == selected.chapter { last += 1 }
                            units = Array(ordered[first...last]); title = selected.chapter
                        }
                    } else {
                        units = selected.page.map { page in book.units.filter { $0.page == page } } ?? [selected]
                        title = selected.locator
                    }
                }
            } catch { scopeMessage = error.localizedDescription; title = "当前章节" }
            selectedUnits = units
            if let firstRange = ranges?.first, let original = book.units.first(where: { $0.id == firstRange.unitID }),
               let text = try? firstRange.text(in: original), !text.isEmpty {
                let quote = String(text.prefix(32)), ns = original.text as NSString
                let prefix = ns.substring(to: firstRange.startUTF16)
                let suffix = ns.substring(from: firstRange.startUTF16 + quote.utf16.count)
                scopeStartAnchor = try? ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: original.id,
                    quote: quote, prefix: String(prefix.suffix(48)), suffix: String(suffix.prefix(48)), in: book)
            }
            let allowed = Set(units.map(\.id))
            let byID = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let rangesByID = Dictionary(grouping: ranges ?? [], by: \.unitID)
            var resolvers: [String: (SourceAnchor) throws -> ResolvedSourceAnchor] = [:]
            func localAnchor(_ anchor: SourceAnchor) -> Bool {
                guard allowed.contains(anchor.unitID) else { return false }
                guard ranges != nil else { return true }
                if resolvers[anchor.unitID] == nil {
                    guard let resolver = try? ReadingExperienceRuntime.anchorResolver(sourceHash: book.sourceHash, unitID: anchor.unitID, in: book) else { return false }
                    resolvers[anchor.unitID] = resolver
                }
                guard let resolve = resolvers[anchor.unitID], let value = try? resolve(anchor) else { return false }
                return (rangesByID[anchor.unitID] ?? []).contains { $0.startUTF16 <= value.utf16Location && $0.endUTF16 >= value.utf16Location + value.utf16Length }
            }
            func localEvidence(_ evidence: Evidence) -> Bool {
                guard let unit = byID[evidence.unitID], !evidence.quote.isEmpty,
                      let match = unit.text.range(of: evidence.quote, options: .literal) else { return false }
                return unit.text[match].utf8.elementsEqual(evidence.quote.utf8)
            }
            var anchors = state.anchors.filter(localAnchor)
            let existing = Set(anchors.map(\.id))
            anchors.append(contentsOf: index.anchors.filter { localAnchor($0) && !existing.contains($0.id) })
            let anchorIDs = Set(anchors.map(\.id))
            var mentions = state.mentions.filter { anchorIDs.contains($0.anchorID) }
            let existingMentions = Set(mentions.map(\.id))
            mentions.append(contentsOf: index.mentions.filter { anchorIDs.contains($0.anchorID) && !existingMentions.contains($0.id) })
            let targets = Set(mentions.map(\.targetID))
            let cursor = selected.map { unit in unit.page.flatMap { page in book.units.filter { $0.page == page }.max { $0.order < $1.order } } ?? unit }
            let boundary = avoidsSpoilers ? cursor.flatMap { try? KnowledgeReadBoundary.throughSourceUnit($0.id, in: book).allowedUnitIDs } : nil
            let projection = ReadingSpoilerProjection.Context(project: book, allowedUnitIDs: boundary)
            var events: [KnowledgeEvent] = []
            for event in book.events {
                guard !Task.isCancelled else { return nil }
                if targets.contains(event.id) || event.evidence.contains(where: localEvidence), let value = projection.event(event) { events.append(value) }
            }
            let relatedEntities = Set(events.flatMap { $0.placeIDs + $0.participantIDs })
            var entities: [KnowledgeEntity] = []
            for entity in book.entities {
                guard !Task.isCancelled else { return nil }
                if targets.contains(entity.id) || relatedEntities.contains(entity.id) || entity.evidence.contains(where: localEvidence), let value = projection.entity(entity) { entities.append(value) }
            }
            func fullyLocal(_ ids: [String]) -> Bool { !ids.isEmpty && ids.allSatisfy { anchorIDs.contains($0) } }
            let layers = state.layers.filter { fullyLocal($0.sourceAnchorIDs) }, alignments = state.alignments.filter { fullyLocal($0.sourceAnchorIDs) }
            count = state.layers.filter { !anchorIDs.isDisjoint(with: $0.sourceAnchorIDs) && !fullyLocal($0.sourceAnchorIDs) }.count +
                state.alignments.filter { !anchorIDs.isDisjoint(with: $0.sourceAnchorIDs) && !fullyLocal($0.sourceAnchorIDs) }.count
            items = ReadingContextItems(anchors: anchors, mentions: mentions, entities: entities, events: events, layers: layers, alignments: alignments)
        }
        guard !Task.isCancelled else { return nil }
        // Old sentence-only output may cover a title and its opening prose.
        // Hide only invalid sentence translations in this disposable projection;
        // ordinary chapter analysis, source records and user notes stay intact.
        if items.layers.contains(where: { $0.provenance?.label == "sentence-translation" }) {
            let unitsByID = Dictionary(grouping: book.units, by: \.id)
            let anchorsByID = Dictionary(grouping: items.anchors, by: \.id)
            var boundaries: [String: ReadingPassageBoundaryIndex] = [:]
            var validity: [String: Bool] = [:]
            var resolvers: [String: (SourceAnchor) throws -> ResolvedSourceAnchor] = [:]
            var unavailableUnits = Set<String>()
            func validSentenceAnchor(_ id: String) -> Bool {
                if let saved = validity[id] { return saved }
                guard !Task.isCancelled, let anchors = anchorsByID[id], anchors.count == 1, let anchor = anchors.first,
                      anchor.sourceHash == book.sourceHash,
                      let matches = unitsByID[anchor.unitID], matches.count == 1, let unit = matches.first else {
                    validity[id] = false; return false
                }
                guard !unavailableUnits.contains(unit.id) else { validity[id] = false; return false }
                if resolvers[unit.id] == nil {
                    guard let resolver = try? ReadingExperienceRuntime.anchorResolver(sourceHash: book.sourceHash, unitID: unit.id, in: book) else {
                        unavailableUnits.insert(unit.id); validity[id] = false; return false
                    }
                    resolvers[unit.id] = resolver
                }
                guard let resolver = resolvers[unit.id], let resolved = try? resolver(anchor) else {
                    validity[id] = false; return false
                }
                let boundary: ReadingPassageBoundaryIndex
                if let saved = boundaries[unit.id] { boundary = saved }
                else {
                    boundary = ReadingSentenceAnchors.boundaryIndex(in: unit.text, chapterTitle: unit.chapter,
                        syntax: ReadingSentenceAnchors.syntax(for: unit, in: book))
                    boundaries[unit.id] = boundary
                }
                let valid = !boundary.crossesStructuralBoundary(resolved.range)
                validity[id] = valid; return valid
            }
            items.layers.removeAll { layer in
                guard layer.provenance?.label == "sentence-translation" else { return false }
                return layer.sourceAnchorIDs.count != 1 || !validSentenceAnchor(layer.sourceAnchorIDs[0])
            }
        }
        guard !Task.isCancelled else { return nil }
        let types = Dictionary(book.types.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(grouping: items.entities, by: \.typeID).map { id, entities in
            CompanionObjectGroup(id: "type:" + id, title: types[id]?.name ?? "其他线索", icon: types[id]?.icon ?? "folder", entities: entities)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return Self(items: items, crossScopeCount: count, groups: groups,
            entities: Dictionary(items.entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            events: Dictionary(items.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            layers: Dictionary(items.layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            alignments: Dictionary(items.alignments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            layerPlan: ReadingCompanionPresentation.layers(items.layers, focusedAnchorID: focusedAnchorID),
            alignmentPlan: ReadingCompanionPresentation.alignments(items.alignments, focusedAnchorID: focusedAnchorID),
            sourceUnits: selectedUnits, scopeTitle: title, scopeMessage: scopeMessage, scopeStartAnchor: scopeStartAnchor)
    }
}

/// One contextual panel shared by source reading and declared plugin views.
struct ReadingCompanionPanel: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject private var typography: ReadingTypographySettings
    @Environment(\.isReaderPanelActive) private var panelActive
    var section: String = "context"
    var scope: String = "current"
    var onClose: (() -> Void)?
    var showsHeader = true
    @State private var removal: ReadingItemRemoval?
    @State private var generationReview: CompanionGenerationIntent?
    @State private var companionScope: ReadingQueryScope = .page
    @State private var frozenScope: ReadingQuerySnapshot?
    @State private var items = ReadingContextItems()
    @State private var crossScopeCount = 0
    @State private var showsSourceContext = false
    @State private var expandedObjectGroups: Set<String> = []
    @State private var objectLimits: [String: Int] = [:]
    @State private var sourceContextLimit = 4
    @State private var layerLimit = 8
    @State private var alignmentLimit = 8
    @State private var objectGroups: [CompanionObjectGroup] = []
    @State private var entitiesByID: [String: KnowledgeEntity] = [:]
    @State private var eventsByID: [String: KnowledgeEvent] = [:]
    @State private var layersByID: [String: ReadingLayer] = [:]
    @State private var alignmentsByID: [String: ReferenceAlignment] = [:]
    @State private var layerPlan = ReadingCompanionRecordPlan()
    @State private var alignmentPlan = ReadingCompanionRecordPlan()
    @State private var historyExpanded = false
    @State private var archiveHistoryBook: BookProject?
    @State private var referenceHistoryExpanded = false
    @State private var expandedRecords: Set<String> = []
    @State private var projectionTask: Task<Void, Never>?
    @State private var projectionGeneration = 0
    @State private var projectionProgressID: UUID?
    @State private var projectionProgressOwner: String?
    @State private var displayedProjectionKey: String?
    @State private var displayedPublicationStamp: LibraryPublicationStamp?
    @State private var displayedScopeKey: String?
    @State private var projectedSourceUnits: [SourceUnit] = []
    @State private var projectedScopeTitle = "请先打开原文"
    @State private var scopeMessage: String?
    @State private var scopeStartAnchor: SourceAnchor?
    @State private var preparedChapterSource: [SourceUnit] = []
    @State private var preparedChapterOwner: String?
    private var avoidsSpoilers: Bool { scope != "book" && store.book?.temporalKnowledge?.profile?.avoidsSpoilers != false }
    private var sourceUnits: [SourceUnit] {
        panelActive && displayedScopeKey == scopeKey ? projectedSourceUnits : []
    }
    private var scopeTitle: String {
        displayedScopeKey == scopeKey ? projectedScopeTitle : "正在读取范围…"
    }
    private var projectionKey: String {
        // Page-derived anchors/mentions can arrive without a persisted edit.
        // Their publication must invalidate this projection as well.
        scopeKey + "|" + String(store.projectRevision) + "|index:" + String(store.readingExperienceIndexRevision)
    }
    private var scopeKey: String {
        [store.bookID ?? "", store.selectedUnitID ?? "", companionScope.rawValue, frozenScope?.scopeFingerprint ?? "", scope,
         store.readerChapterAnchor?.id ?? "", store.focusedReadingAnchorID ?? ""].joined(separator: "|")
    }
    private var effectiveSection: String {
        let value = section == "context" ? store.readingCompanionSection : section
        return value == "decisions" ? "layers" : value
    }
    private var recoverableItems: [ReadingExperienceTrashItem] {
        panelActive ? (store.book?.readingExperience?.trash ?? []).filter { $0.kind != "decision" } : []
    }
    private var contentTitle: String {
        effectiveSection == "mentions" ? "原文对象" : effectiveSection == "references" ? "资料对读" : "解释与译文"
    }
    private var contentIcon: String {
        effectiveSection == "mentions" ? "rectangle.stack" : effectiveSection == "references" ? "arrow.left.arrow.right" : "text.book.closed"
    }
    private var contentHelp: String {
        if effectiveSection == "mentions" { return "原文对象：查看当前页或章节中有出处的人物、地点、概念与事件。点击对象可展开已有资料。" }
        if effectiveSection == "references" { return "资料对读：并列查看有原文锚点的相关段落与资料，分别回到出处核对；AI解释不当作原文。" }
        return "解释与译文：查看当前范围的解读和译文。最新内容置前，先前记录默认收起，不改写原书。"
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
                HStack(spacing: 8) { companionSelectors }.fixedSize(horizontal: true, vertical: false)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ReaderPanelIntrinsicWidthPreference.self,
                                value: ["companion.selectors": geometry.size.width + 24])
                        }.allowsHitTesting(false)
                    }
                Spacer(minLength: 0)
                HStack(spacing: 8) { companionTools }.fixedSize(horizontal: true, vertical: false)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ReaderPanelIntrinsicWidthPreference.self,
                                value: ["companion.tools": geometry.size.width + 24])
                        }.allowsHitTesting(false)
                    }
            }.padding(.horizontal, 16).padding(.bottom, 4)
            if effectiveSection != "mentions" { companionCollectionBar }
            ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let error = store.readingExperienceError { Text(error).font(.system(size: 13)).foregroundStyle(Palette.copper) }
                    if crossScopeCount > 0 {
                        Button { if let component = WorkspaceComponentRegistry.shared.component(id: "reading.layers") { store.activate(component) } } label: {
                            Label("另有 \(crossScopeCount) 条解释涉及其他页，查看完整来源", systemImage: "arrow.up.right.square")
                                .font(.system(size: 13)).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.borderless).disabled(store.isBusy)
                    }
                    if scope != "book" {
                        if let scopeMessage { Text(scopeMessage).font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                        if let quote = selectedQuote {
                            Text(quote).font(typography.font(for: .source)).lineSpacing(6).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12).padding(.vertical, 4)
                                .overlay(alignment: .leading) { Capsule().fill(Palette.accent.opacity(0.55)).frame(width: 2) }
                        }
                        if showsSourceContext && !sourceUnits.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(scopeTitle, systemImage: "text.quote").font(.system(size: 13)).foregroundStyle(.secondary)
                                ForEach(Array(sourceUnits.prefix(sourceContextLimit))) { unit in if !unit.text.isEmpty { MarkdownText(markdown: unit.text).readingTextContext(.source) } }
                                if sourceUnits.count > sourceContextLimit { Button("继续显示原文") { sourceContextLimit += 4 }.buttonStyle(.borderless).frame(minHeight: 40) }
                                if sourceUnits.allSatisfy({ $0.text.isEmpty }) { Text("此处尚无可靠识别文本，请先对照原 PDF。") }
                            }.padding(.vertical, 8)
                        }
                    }
                    if effectiveSection == "mentions" { objectSection }
                    else if effectiveSection == "references" { referenceSection }
                    else { layerSection }
                }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading).id("companion-start")
            }
                .onChange(of: layerPlan.primaryID) { _, id in
                    if panelActive, id != nil, effectiveSection != "mentions", effectiveSection != "references" {
                        scroller.scrollTo("companion-start", anchor: .top)
                    }
                }
                .onChange(of: alignmentPlan.primaryID) { _, id in
                    if panelActive, id != nil, effectiveSection == "references" { scroller.scrollTo("companion-start", anchor: .top) }
                }
                .onChange(of: scopeKey) { _, _ in if panelActive { scroller.scrollTo("companion-start", anchor: .top) } }
            }
            Divider().opacity(0.4)
            companionFooter
        }
        .environment(\.markdownReadingStyle, "companion")
        .readingTextContext(.companion)
        .onAppear(perform: refreshItems)
        .onChange(of: panelActive) { _, active in
            if active { refreshItems() } else { cancelProjection() }
        }
        .onChange(of: projectionKey) { _, _ in refreshItems() }
        .onChange(of: companionScope) { _, _ in frozenScope = nil; sourceContextLimit = 4 }
        .onChange(of: store.bookID) { _, _ in frozenScope = nil; companionScope = .page; expandedObjectGroups = []; objectLimits = [:]; refreshItems() }
        .onChange(of: store.selectedObjectID) { _, _ in revealSelectedObjectGroup() }
        .onChange(of: scopeKey) { _, _ in
            layerLimit = 8; alignmentLimit = 8; objectLimits = [:]
            historyExpanded = false; referenceHistoryExpanded = false; expandedRecords = []; generationReview = nil
        }
        .onDisappear { cancelProjection(); preparedChapterSource = []; preparedChapterOwner = nil }
        .confirmationDialog("移除这条阅读增强？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { item in
            Button("移除", role: .destructive) { Task { await store.removeReadingItem(item.id, kind: item.kind) } }
        } message: { item in Text("\(item.title)\n原书和已保存的 Markdown 保留。") }
        .companionGenerationConfirmation($generationReview, generate: startEnhancement)
        .sheet(item: $archiveHistoryBook) { book in
            SavedConversationHistory(project: book, focusedMessageID: nil, initialKind: "companion", onClose: { archiveHistoryBook = nil }).environmentObject(store)
        }
    }
    @ViewBuilder private var companionSelectors: some View {
                if section == "context" {
                    Menu {
                        Button { store.readingCompanionSection = "layers" } label: { Label("解释与译文", systemImage: "text.book.closed") }
                            .help("查看当前范围的解读、译文和已保存记录，最新内容置前。")
                        Button { store.readingCompanionSection = "mentions" } label: { Label("原文对象", systemImage: "rectangle.stack") }
                            .help("查看原文中的人物、地点、概念与事件，并核对各自出现的出处。")
                        Button { store.readingCompanionSection = "references" } label: { Label("资料对读", systemImage: "arrow.left.arrow.right") }
                            .help("并列查看有出处的相关段落或资料，分别返回原文核对。")
                        if !recoverableItems.isEmpty {
                            Divider()
                            Menu {
                                ForEach(recoverableItems) { item in
                                    Button { Task { await store.restoreReadingItem(item.id) } } label: { Label(item.title, systemImage: "arrow.uturn.backward") }.disabled(store.isBusy)
                                }
                            } label: { Label("恢复已移除的伴读", systemImage: "arrow.uturn.backward") }
                        }
                    } label: { Label(contentTitle, systemImage: contentIcon).font(.system(size: 15, weight: .medium)).frame(minHeight: 44) }
                        .menuStyle(.borderlessButton).modifier(ReadingHoverSurface()).fixedSize().help(contentHelp)
                } else { Label(contentTitle, systemImage: contentIcon).font(.system(size: 15, weight: .medium)).lineLimit(1) }
                if scope != "book" {
                    Menu {
                        Button { companionScope = .page } label: { Label("当前页", systemImage: "doc.text") }
                        Button { companionScope = .chapter } label: { Label("当前章节", systemImage: "book.closed") }
                        if frozenScope != nil { Divider(); Button { frozenScope = nil } label: { Label("解除固定，跟随原文", systemImage: "lock.open") } }
                    } label: {
                        Label(companionScope == .page ? "当前页" : "当前章节", systemImage: frozenScope == nil ? "book.closed" : "lock")
                            .font(.system(size: 13, weight: .medium)).frame(minHeight: 44)
                    }.menuStyle(.borderlessButton).modifier(ReadingHoverSurface()).fixedSize().disabled(store.isCompanionGenerating)
                        .help(scopeTitle + "\n选择按当前页或完整章节生成；伴读生成期间固定这次范围，对话可独立使用。")
                } else { Text("全书").font(.system(size: 13)).foregroundStyle(.secondary) }
    }
    @ViewBuilder private var companionTools: some View {
                Menu {
                    Button("放大文字") { typography.setPointSize(typography.style(for: .companion).pointSize + 1, for: .companion) }
                        .disabled(typography.style(for: .companion).pointSize >= ReadingTextStyle.pointSizeRange.upperBound)
                        .help("只放大伴读文字，不改变原PDF缩放。")
                    Button("缩小文字") { typography.setPointSize(typography.style(for: .companion).pointSize - 1, for: .companion) }
                        .disabled(typography.style(for: .companion).pointSize <= ReadingTextStyle.pointSizeRange.lowerBound)
                        .help("只缩小伴读文字，不改变原PDF缩放。")
                    Button("恢复默认") { typography.reset(.companion) }
                    Divider()
                    ForEach(ReadingAnswerStyle.allCases, id: \.self) { style in
                        Button { store.queryAnswerStyle = style } label: { Label(style.title, systemImage: store.queryAnswerStyle == style ? "checkmark" : style.icon) }
                            .help(style == .mentor ? "补充必要背景并解释思路；书外知识与原文依据分开。" : "只围绕原文证据分析，不把不确定背景当成书中事实。")
                    }
                } label: { Image(systemName: "textformat.size").frame(width: 32, height: 44) }
                    .menuStyle(.borderlessButton).modifier(ReadingHoverSurface()).fixedSize().help("伴读字号与讲解方式")
                if showsHeader {
                    Button { NotificationCenter.default.post(name: Notification.Name("ReadingBookExpandCompanion"), object: nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(ReadingToolbarButtonStyle()).help("放大或还原伴读窗口").accessibilityLabel("放大伴读窗口")
                }
                if !recoverableItems.isEmpty && section != "context" {
                    Menu {
                        ForEach(recoverableItems) { item in
                            Button { Task { await store.restoreReadingItem(item.id) } } label: { Label("恢复 \(item.title)", systemImage: "arrow.uturn.backward") }.disabled(store.isBusy)
                        }
                    } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.menuStyle(.borderlessButton).modifier(ReadingHoverSurface()).fixedSize().help("恢复已移除的伴读")
                }
                if scope != "book" {
                    Button { showsSourceContext.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(ReadingToolbarButtonStyle(selected: showsSourceContext)).disabled(sourceUnits.isEmpty)
                        .help("查看原文与上下文").accessibilityLabel("原文与上下文")
                }
    }
    private var companionFooter: some View {
        HStack(spacing: 10) {
            Button(action: askThisScope) { Label("问这部分", systemImage: "bubble.left").frame(maxWidth: .infinity) }
                .buttonStyle(ReadingActionButtonStyle()).disabled(sourceUnits.isEmpty || !store.canStartQuery)
                .help("把当前页或章节交给对话输入区；确认问题后再发送，不会立即请求模型。")
            if hasCompanionContent {
                Button(action: noteThisScope) { Label("记入笔记", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                    .buttonStyle(ReadingActionButtonStyle(prominent: true)).disabled(sourceUnits.isEmpty || store.isBusy)
                    .help("把当前显示的伴读整理成可编辑笔记草稿，主动保存后才写入Markdown。")
                if scope != "book" { Button(action: enhanceThisScope) {
                    Image(systemName: "sparkles")
                }.buttonStyle(ReadingToolbarButtonStyle()).disabled(sourceUnits.isEmpty || !store.canStartCompanion)
                    .help("再次请求模型补充这一范围；已有分析会先提示确认，原有内容保留。").accessibilityLabel("补充这部分的解释") }
            } else {
                if scope != "book" {
                    Button(action: enhanceThisScope) { Label("生成解释", systemImage: "sparkles").frame(maxWidth: .infinity) }
                        .buttonStyle(ReadingActionButtonStyle(prominent: true)).disabled(sourceUnits.isEmpty || !store.canStartCompanion)
                        .help("按上方选择的页或章生成伴读解释")
                }
                Menu {
                    Button(action: noteThisScope) { Label("为这部分记笔记", systemImage: "square.and.pencil") }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 48) }
                    .menuStyle(.borderlessButton).modifier(ReadingHoverSurface()).fixedSize().disabled(sourceUnits.isEmpty || store.isBusy).help("更多操作")
            }
        }.padding(16).fixedSize(horizontal: false, vertical: true)
    }
    private func enhanceThisScope() {
        guard store.canStartCompanion, !sourceUnits.isEmpty,
              let intent = CompanionGenerationIntent(store: store, contextKey: scopeKey, scope: companionScope,
                title: scopeTitle, review: ReadingCompanionGenerationReview(items: items)) else { return }
        if intent.review.requiresConfirmation || crossScopeCount > 0 { generationReview = intent }
        else { startEnhancement(intent) }
    }
    private func startEnhancement(_ intent: CompanionGenerationIntent) {
        guard intent.stillMatches(store, contextKey: scopeKey), store.canStartCompanion else {
            store.readingExperienceError = "阅读范围或任务状态已变化，请重新选择后再生成。"; return
        }
        // The host freezes a fresh page/chapter snapshot before any paid request.
        if frozenScope?.scope == .chapter {
            guard let anchor = scopeStartAnchor, let first = sourceUnits.first else { store.readingExperienceError = "请回到该章节的原文再补充。"; return }
            store.navigateToChapter(BookOutlineEntry(id: anchor.id, title: projectedScopeTitle, page: first.page, anchor: anchor))
        } else if companionScope != .chapter, let first = sourceUnits.first { store.navigateToUnit(first.id) }
        let owner = store.bookID, root = store.libraryRootURL, requestedScope = intent.scope, selected = store.selectedUnitID
        Task {
            guard store.bookID == owner, store.libraryRootURL == root, store.book?.sourceHash == intent.sourceHash,
                  store.selectedUnitID == selected else { return }
            if let snapshot = await store.enhanceSourceScope(scope: requestedScope),
               store.bookID == owner, store.libraryRootURL == root, companionScope == requestedScope {
                frozenScope = snapshot
            }
        }
    }
    private func askThisScope() {
        guard store.canStartQuery, let first = sourceUnits.first else { return }
        if frozenScope?.scope == .chapter {
            guard let anchor = scopeStartAnchor else { store.readingExperienceError = "请回到该章节的原文再提问。"; return }
            store.navigateToChapter(BookOutlineEntry(id: anchor.id, title: projectedScopeTitle, page: first.page, anchor: anchor))
        } else if companionScope != .chapter { store.navigateToUnit(first.id) }
        store.queryScope = scope == "book" ? .book : (frozenScope?.scope ?? companionScope)
        // This is an explicit transfer. General question controls keep their
        // independent scope until the reader presses this action.
        if store.route == "reader" { store.readingCompanionTab = "chat"; store.readingCompanionVisible = true }
        else { store.requestedWorkspaceRoute = "query" }
    }
    private var selectedQuote: String? {
        guard panelActive, let anchor = store.selectedSourceAnchor, !anchor.quote.isEmpty,
              sourceUnits.contains(where: { $0.id == anchor.unitID && $0.text.range(of: anchor.quote, options: .literal) != nil }) else { return nil }
        return anchor.quote
    }
    private func noteThisScope() {
        if let layer = layerPlan.primaryID.flatMap({ layersByID[$0] }) ?? layerPlan.orderedIDs.first.flatMap({ layersByID[$0] }) {
            store.newReadingNote(title: layer.title, markdown: layer.markdown + "\n\n_\(layer.sourceLabel)_", anchorIDs: layer.sourceAnchorIDs)
        } else if let unit = sourceUnits.first { store.newNote(for: unit) }
    }
    private func refreshItems() {
        guard panelActive else { return }
        if let stamp = store.book?.publicationStamp, displayedProjectionKey == projectionKey,
           displayedPublicationStamp == stamp { return }
        cancelProjection()
        guard let book = store.book else {
            items = ReadingContextItems(); crossScopeCount = 0; objectGroups = []; entitiesByID = [:]; eventsByID = [:]
            layersByID = [:]; alignmentsByID = [:]; layerPlan = .init(); alignmentPlan = .init()
            projectedSourceUnits = []; scopeMessage = nil; displayedProjectionKey = nil; displayedPublicationStamp = nil; return
        }
        let expected = projectionKey, expectedScope = scopeKey, generation = projectionGeneration
        let root = store.libraryRootURL.path, index = store.readingExperienceIndex
        let requestedScope = scope, requestedCompanionScope = companionScope, frozen = frozenScope
        let selected = store.selectedUnitID, avoids = avoidsSpoilers, focusedAnchorID = store.focusedReadingAnchorID
        let chapterAnchor = store.chapterReadingAnchor(in: book, unitID: selected)
        let previousChapterSource = preparedChapterSource, previousChapterOwner = preparedChapterOwner
        let chapterOwner = root + "|" + book.id + "|" + book.sourceHash
        let progressID = UUID(), progressOwner = root + "|" + book.id
        projectionProgressID = progressID; projectionProgressOwner = progressOwner
        store.readingPreparationState.apply(.started(progressID, ReadingPreparationProgress(phase: .companion)), lane: "companion", owner: progressOwner)
        if displayedScopeKey != expectedScope {
            items = ReadingContextItems(); crossScopeCount = 0; objectGroups = []; entitiesByID = [:]; eventsByID = [:]
            layersByID = [:]; alignmentsByID = [:]; layerPlan = .init(); alignmentPlan = .init()
            projectedSourceUnits = []; scopeMessage = nil
        }
        projectionTask = Task {
            defer {
                if projectionGeneration == generation, projectionProgressID == progressID {
                    finishProjectionProgress()
                    projectionTask = nil
                }
            }
            do { try await Task.sleep(nanoseconds: 35_000_000) } catch { return }
            guard panelActive, !Task.isCancelled, projectionGeneration == generation,
                  store.bookID == book.id, store.libraryRootURL.path == root else { return }
            var current = book
            if requestedCompanionScope == .chapter, requestedScope != "book", frozen == nil {
                let checker = Task.detached(priority: .userInitiated) {
                    previousChapterOwner == chapterOwner && CompanionProjection.sameSource(previousChapterSource, book.units)
                }
                let unchanged = await withTaskCancellationHandler(operation: { await checker.value }, onCancel: { checker.cancel() })
                do {
                    try Task.checkCancellation()
                    if !unchanged { current = try await store.ensureBookChapterOutline(project: book) }
                    try Task.checkCancellation()
                    guard panelActive, projectionGeneration == generation, scopeKey == expectedScope,
                          store.bookID == book.id, store.libraryRootURL.path == root else { return }
                    preparedChapterSource = current.units; preparedChapterOwner = chapterOwner
                }
                catch {
                    guard panelActive, !Task.isCancelled, projectionGeneration == generation, scopeKey == expectedScope,
                          store.bookID == book.id, store.libraryRootURL.path == root else { return }
                    projectedSourceUnits = []; projectedScopeTitle = "当前章节"; scopeMessage = error.localizedDescription
                    displayedScopeKey = expectedScope; projectionTask = nil; return
                }
            }
            let preparedBook = current
            let worker = Task.detached(priority: .userInitiated) {
                CompanionProjection.build(book: preparedBook, index: index, scope: requestedScope, companionScope: requestedCompanionScope,
                    frozenScope: frozen, selectedUnitID: selected, chapterAnchor: chapterAnchor, focusedAnchorID: focusedAnchorID, avoidsSpoilers: avoids)
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard panelActive, !Task.isCancelled, projectionGeneration == generation, store.bookID == book.id,
                  store.libraryRootURL.path == root, projectionKey == expected, let result else { return }
            items = result.items; crossScopeCount = result.crossScopeCount
            objectGroups = result.groups; entitiesByID = result.entities; eventsByID = result.events
            layersByID = result.layers; alignmentsByID = result.alignments; layerPlan = result.layerPlan; alignmentPlan = result.alignmentPlan
            projectedSourceUnits = result.sourceUnits; projectedScopeTitle = result.scopeTitle; scopeMessage = result.scopeMessage
            scopeStartAnchor = result.scopeStartAnchor
            displayedScopeKey = expectedScope; displayedProjectionKey = expected; displayedPublicationStamp = book.publicationStamp
            revealSelectedObjectGroup()
        }
    }
    private func finishProjectionProgress() {
        guard let id = projectionProgressID, let owner = projectionProgressOwner else { return }
        projectionProgressID = nil; projectionProgressOwner = nil
        guard owner == store.libraryRootURL.path + "|" + (store.bookID ?? "") else { return }
        store.readingPreparationState.apply(.finished(id), lane: "companion", owner: owner)
    }
    private func cancelProjection() {
        projectionTask?.cancel(); projectionTask = nil; projectionGeneration &+= 1
        finishProjectionProgress()
    }
    @ViewBuilder private var layerSection: some View {
        if let id = store.focusedReadingAnchorID,
           let anchor = store.readingExperienceIndex.anchors.first(where: { $0.id == id }) ?? store.book?.readingExperience?.anchors.first(where: { $0.id == id }) {
            SentenceTranslationCard(anchor: anchor)
        } else if items.layers.isEmpty {
            empty(scope == "book" ? "还没有保存的伴读" : "这一页，还可以读得更深", detail: scope == "book" ? "回到原文页，生成解释或留下笔记。" : "生成解释，或围绕当前内容提一个问题。")
        }
        let historyIDs = layerPlan.orderedIDs.filter { $0 != layerPlan.primaryID || store.readerCollections.collapsedReferenceIDs.contains("layer:" + $0) }
        if let id = layerPlan.primaryID, let layer = layersByID[id], !store.readerCollections.collapsedReferenceIDs.contains("layer:" + id) {
            VStack(alignment: .leading, spacing: 8) {
                itemHeader(layer.title, label: layer.sourceLabel, id: layer.id, kind: "layer") { EmptyView() }
                layerContent(layer)
            }.readingCompanionSection(inset: 8).id("companion-current-layer")
        }
        if historyExpanded && !historyIDs.isEmpty {
            historyContainer {
                    ForEach(Array(historyIDs.prefix(layerLimit)), id: \.self) { id in
                        if let layer = layersByID[id] {
                            VStack(alignment: .leading, spacing: 6) {
                                historyRecordHeader(layer.title, source: layer.sourceLabel, id: layer.id, kind: "layer")
                    if expandedRecords.contains("layer:" + id) { layerContent(layer) }
                            }.padding(8).background(Palette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    if historyIDs.count > layerLimit {
                        Button("继续显示记录 · 还有 \(historyIDs.count - layerLimit) 条") { layerLimit += 8 }
                            .buttonStyle(.borderless).font(.system(size: 12)).frame(minHeight: 28).help("按保存顺序从新到旧继续列出；点击每条标题查看完整内容。")
                    }
            }
        }
        if !items.alignments.isEmpty { referenceSection }
    }
    private func layerContent(_ layer: ReadingLayer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CompanionRecordBody(markdown: layer.markdown).id("layer-body:" + layer.id)
            provenance(layer.provenance)
            CompanionRecordActions(sources: recordSources(layer.sourceAnchorIDs), externalSource: sourceURL(layer.provenance), markdown: layer.markdown,
                onSource: store.focusReadingAnchor) {
                store.newReadingNote(title: layer.title, markdown: layer.markdown + "\n\n_\(layer.sourceLabel)_", anchorIDs: layer.sourceAnchorIDs)
            }
        }
    }
    @ViewBuilder private var referenceSection: some View {
        if items.alignments.isEmpty { empty("资料对读", detail: "把同一书内相关段落放在一起，分别回到出处。外部资料需有来源，AI 的解释会单独标识。") }
        let showPrimary = effectiveSection == "references"
        if showPrimary, let id = alignmentPlan.primaryID, let alignment = alignmentsByID[id], !store.readerCollections.collapsedReferenceIDs.contains("alignment:" + id) {
            VStack(alignment: .leading, spacing: 8) {
                itemHeader(alignment.title, label: "资料对齐 · \(alignment.status == "proposed" ? "待核对" : alignment.status)", id: alignment.id, kind: "alignment") { EmptyView() }
                alignmentContent(alignment)
            }.readingCompanionSection(inset: 8)
        }
        let historyIDs = alignmentPlan.orderedIDs.filter { !showPrimary || $0 != alignmentPlan.primaryID || store.readerCollections.collapsedReferenceIDs.contains("alignment:" + $0) }
        if referenceHistoryExpanded && !historyIDs.isEmpty {
            historyContainer {
                    ForEach(Array(historyIDs.prefix(alignmentLimit)), id: \.self) { id in
                        if let alignment = alignmentsByID[id] {
                            VStack(alignment: .leading, spacing: 6) {
                                historyRecordHeader(alignment.title, source: "资料对读 · " + alignment.status, id: alignment.id, kind: "alignment")
                                if expandedRecords.contains("alignment:" + id) { alignmentContent(alignment) }
                            }.padding(8).background(Palette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    if historyIDs.count > alignmentLimit {
                        Button("继续显示对读 · 还有 \(historyIDs.count - alignmentLimit) 条") { alignmentLimit += 8 }
                            .buttonStyle(.borderless).font(.system(size: 12)).frame(minHeight: 28).help("按保存顺序从新到旧继续列出对读记录。")
                    }
            }
        }
    }
    private func alignmentContent(_ alignment: ReferenceAlignment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CompanionRecordBody(markdown: alignment.markdown).id("alignment-body:" + alignment.id)
            provenance(alignment.provenance)
            CompanionRecordActions(sources: recordSources(alignment.sourceAnchorIDs), externalSource: sourceURL(alignment.provenance), markdown: alignment.markdown,
                onSource: store.focusReadingAnchor) {
                store.newReadingNote(title: alignment.title, markdown: alignment.markdown, anchorIDs: alignment.sourceAnchorIDs)
            }
        }
    }
    private func historyRecordHeader(_ title: String, source: String, id: String, kind: String) -> some View {
        let key = kind + ":" + id, expanded = expandedRecords.contains(key)
        return HStack(spacing: 6) {
            Button {
                if expanded { expandedRecords.remove(key) } else { expandedRecords.insert(key) }
                Task { await store.organizeReaderCollections(.collapse([key], expanded)) }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        Text(source).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(expanded ? "收起" : "查看").font(.system(size: 11)).foregroundStyle(Palette.accent)
                }.frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(ReadingQuietButtonStyle()).help("查看或收起这条已保存记录；原始内容保留。")
                .accessibilityValue(expanded ? "已展开" : "已收起")
            removalMenu(title, id: id, kind: kind)
        }
    }
    private func historyContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVStack(alignment: .leading, spacing: 8, content: content).padding(8)
            .background(Palette.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private var companionRecordIDs: [String] {
        layerPlan.orderedIDs.map { "layer:" + $0 } + alignmentPlan.orderedIDs.map { "alignment:" + $0 }
    }
    private var foldedCompanionIDs: [String] {
        let collapsed = Set(store.readerCollections.collapsedReferenceIDs)
        return companionRecordIDs.filter { id in
            if collapsed.contains(id) { return true }
            if expandedRecords.contains(id) { return false }
            let primary = effectiveSection == "references" ? alignmentPlan.primaryID.map({ "alignment:" + $0 }) : layerPlan.primaryID.map({ "layer:" + $0 })
            return id != primary
        }
    }
    private var companionCollectionBar: some View {
        HStack(spacing: 6) {
            if !foldedCompanionIDs.isEmpty {
                Button {
                    let expanded = historyExpanded || referenceHistoryExpanded
                    historyExpanded = !expanded; referenceHistoryExpanded = !expanded
                    if expanded { expandedRecords = [] }
                } label: { Label("已收起 \(foldedCompanionIDs.count)", systemImage: "tray.full").font(.system(size: 12, weight: .medium)).frame(minHeight: 32) }
                    .buttonStyle(ReadingQuietButtonStyle()).foregroundStyle(Palette.accent)
                    .help("查看或收起当前伴读记录列表。它们仍可参与当前范围的上下文；移入历史后不再自动带入。")
            }
            Spacer(minLength: 4)
            if !companionRecordIDs.isEmpty {
                Button {
                    expandedRecords = []; historyExpanded = false; referenceHistoryExpanded = false
                    Task { await store.organizeReaderCollections(.collapse(companionRecordIDs, true)) }
                } label: { Image(systemName: "rectangle.compress.vertical").frame(width: 32, height: 32) }
                    .buttonStyle(ReadingQuietButtonStyle()).help("一键收起当前范围全部伴读，保留上下文。").accessibilityLabel("收起全部伴读")
                    .disabled(store.isOrganizingCollections)
            }
            if !foldedCompanionIDs.isEmpty {
                Button {
                    let ids = foldedCompanionIDs
                    Task { await store.organizeReaderCollections(.archive(ids, store.newHistoryFolderTitle)); expandedRecords = [] }
                } label: { Label("移入历史", systemImage: "archivebox").font(.system(size: 12)).frame(minHeight: 32) }
                    .buttonStyle(ReadingQuietButtonStyle()).help("把收起的解释和对读完整收纳到历史文件夹，退出自动上下文；内容保留，可恢复和引用。")
                    .disabled(store.isOrganizingCollections)
            }
            Button { archiveHistoryBook = store.book } label: { Image(systemName: "folder").frame(width: 32, height: 32) }
                .buttonStyle(ReadingQuietButtonStyle()).help("查看历史伴读文件夹，恢复或引用旧记录。").accessibilityLabel("历史伴读文件夹")
        }.padding(.horizontal, 16).padding(.bottom, 4)
    }
    @ViewBuilder private var objectSection: some View {
        if items.entities.isEmpty && items.events.isEmpty { empty("读到的人与事", detail: "这一页整理好的人物、地点和线索会留在这里。") }
        ForEach(objectGroups) { group in
            DisclosureGroup(isExpanded: groupBinding(group.id)) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let selected = store.selectedObjectID.flatMap({ entitiesByID[$0] }), group.id == "type:" + selected.typeID,
                       !group.entities.prefix(objectLimits[group.id] ?? 24).contains(where: { $0.id == selected.id }) { entityRow(selected) }
                    ForEach(Array(group.entities.prefix(objectLimits[group.id] ?? 24))) { entity in entityRow(entity) }
                    moreObjects(group.id, shown: min(objectLimits[group.id] ?? 24, group.entities.count), total: group.entities.count)
                }.padding(.top, 10)
            } label: { groupLabel(group.title, icon: group.icon, count: group.entities.count) }
                .readingCompanionSection()
        }
        if !items.events.isEmpty {
            DisclosureGroup(isExpanded: groupBinding("events")) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let selected = store.selectedObjectID.flatMap({ eventsByID[$0] }),
                       !items.events.prefix(objectLimits["events"] ?? 24).contains(where: { $0.id == selected.id }) { eventRow(selected) }
                    ForEach(Array(items.events.prefix(objectLimits["events"] ?? 24))) { event in eventRow(event) }
                    moreObjects("events", shown: min(objectLimits["events"] ?? 24, items.events.count), total: items.events.count)
                }.padding(.top, 10)
            } label: { groupLabel("事件", icon: "calendar", count: items.events.count) }.readingCompanionSection()
        }
    }
    private func groupBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expandedObjectGroups.contains(id) }, set: { if $0 { expandedObjectGroups.insert(id) } else { expandedObjectGroups.remove(id) } })
    }
    private func groupLabel(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 10) { Image(systemName: "folder").foregroundStyle(Palette.accent); Text(title).font(.system(size: 15, weight: .semibold)); Spacer(minLength: 8); Text("\(count)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary) }.frame(minHeight: 36)
    }
    @ViewBuilder private func moreObjects(_ id: String, shown: Int, total: Int) -> some View {
        if shown < total { Button("继续显示 · 还有 \(total - shown) 项") { objectLimits[id] = shown + 24 }.font(.system(size: 13)).buttonStyle(.borderless).frame(minHeight: 40) }
    }
    private func revealSelectedObjectGroup() {
        guard let id = store.selectedObjectID else { return }
        if let entity = entitiesByID[id] {
            let group = "type:" + entity.typeID; expandedObjectGroups.insert(group)
        } else if eventsByID[id] != nil { expandedObjectGroups.insert("events") }
    }
    private func canShowSummary(_ evidence: [Evidence]) -> Bool {
        guard avoidsSpoilers else { return true }
        let allowed = Set(sourceUnits.map(\.id))
        return !evidence.isEmpty && evidence.allSatisfy { allowed.contains($0.unitID) }
    }
    private func entityRow(_ entity: KnowledgeEntity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            objectHeading(entity.name, id: entity.id)
            if store.selectedObjectID == entity.id {
                VStack(alignment: .leading, spacing: 10) {
                    if store.queryAnswerStyle == .mentor {
                        TeacherBackgroundCard(objectID: entity.id, unitID: store.currentReadingContext.unitID)
                    }
                    if canShowSummary(entity.evidence) {
                        if !entity.summary.isEmpty { MarkdownText(markdown: entity.summary) }
                        if !entity.aliases.isEmpty { Text("也称：" + entity.aliases.joined(separator: "、")).font(.system(size: 13)).foregroundStyle(.secondary) }
                        ForEach(entity.properties.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .top) {
                                Text(store.book?.types.first(where: { $0.id == entity.typeID })?.fields.first(where: { $0.key == key })?.label ?? key).font(.system(size: 13)).foregroundStyle(.secondary)
                                Text(entity.properties[key] ?? "").font(typography.font(for: .companion)).textSelection(.enabled)
                            }
                        }
                    }
                    appearances(entity.id, evidence: entity.evidence)
                    relatedObjects(entity.id)
                    Button { discussObject(entity.name) } label: { Label("聊聊\(entity.name)", systemImage: "bubble.left") }.buttonStyle(.borderless).font(.system(size: 13)).frame(minHeight: 40)
                }.padding(.top, 8)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func eventRow(_ event: KnowledgeEvent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            objectHeading(event.name, id: event.id)
            if store.selectedObjectID == event.id {
                VStack(alignment: .leading, spacing: 10) {
                    if store.queryAnswerStyle == .mentor {
                        TeacherBackgroundCard(objectID: event.id, unitID: store.currentReadingContext.unitID)
                    }
                    if !event.dateText.isEmpty { Text(event.dateText).font(.system(size: 13)).foregroundStyle(.secondary) }
                    if canShowSummary(event.evidence), !event.summary.isEmpty { MarkdownText(markdown: event.summary) }
                    appearances(event.id, evidence: event.evidence)
                    if !event.placeIDs.isEmpty { Button { store.selectedObjectID = event.id; store.readingScopeCurrent = true; store.activate(.map) } label: { Label("在时间与地图中查看", systemImage: "map") }.buttonStyle(.borderless).font(.system(size: 13)).frame(minHeight: 40) }
                }.padding(.top, 8)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func objectHeading(_ title: String, id: String) -> some View {
        let expanded = store.selectedObjectID == id
        return Button { store.selectedObjectID = expanded ? nil : id } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
                Text(title).font(.system(size: 15, weight: expanded ? .semibold : .medium)).foregroundStyle(expanded ? Palette.accent : Palette.ink)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(ReadingQuietButtonStyle()).accessibilityLabel(title).accessibilityValue(expanded ? "已展开" : "已收起")
    }
    private func discussObject(_ name: String) {
        guard store.canStartQuery else { return }
        askThisScope()
        store.queryComposerDraft.text = "读到“\(name)”，可以给我讲讲它吗？"
    }
    @ViewBuilder private var decisionSection: some View {
        if items.decisions.isEmpty { empty("停下来想一想", detail: "历史可先做选择再看后果；数学可先判断推理路径，再展开解析。思考只保留在本机，主动保存才形成 Markdown。") }
        ForEach(items.decisions) { card in
            ReadingDecisionView(card: card, onRemove: { removal = ReadingItemRemoval(id: card.id, kind: "decision", title: card.title) })
        }
    }
    private func empty(_ title: String, detail: String) -> some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 24, weight: .medium)).foregroundStyle(Palette.accent)
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(detail).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5)
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 140, alignment: .center).padding(.vertical, 8)
    }
    private func itemHeader<Actions: View>(_ title: String, label: String, id: String, kind: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(2).help(title)
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).help(label)
            }
            Spacer(minLength: 0)
            actions()
            removalMenu(title, id: id, kind: kind)
        }
    }
    private func removalMenu(_ title: String, id: String, kind: String) -> some View {
        CompanionRecordManagementControl(title: title, id: id, kind: kind) {
            removal = ReadingItemRemoval(id: id, kind: kind, title: title)
        }
    }
    @ViewBuilder private func provenance(_ value: ReadingProvenance?) -> some View {
        if let value {
            Text([value.label == "sentence-translation" ? "句译" : value.label, value.workTitle, value.locator].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private func sourceURL(_ provenance: ReadingProvenance?) -> URL? {
        guard let string = provenance?.url, let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
    private func recordSources(_ ids: [String]) -> [CompanionRecordSource] {
        ReadingCompanionPresentation.sources(ids, indexedAnchors: store.readingExperienceIndex.anchors,
            storedAnchors: store.book?.readingExperience?.anchors ?? [], units: store.book?.units ?? [])
    }

    private func appearances(_ id: String, evidence: [Evidence]) -> some View {
        let allowed = Set(sourceUnits.map(\.id))
        let visible = avoidsSpoilers ? evidence.filter { allowed.contains($0.unitID) } : evidence
        return VStack(alignment: .leading, spacing: 6) {
            Text("原文出现处").font(.system(size: 13)).foregroundStyle(.secondary)
            ForEach(Array(visible.prefix(24).enumerated()), id: \.offset) { _, source in
                Button { store.follow(source) } label: { Text(source.quote).font(.system(size: 13)).lineLimit(3).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(ReadingQuietButtonStyle()).foregroundStyle(Palette.accent)
            }
        }
    }
    private func relatedObjects(_ id: String) -> some View {
        let allowed = Set(sourceUnits.map(\.id))
        let relations = (store.book?.relations ?? []).filter {
            ($0.fromID == id || $0.toID == id) && (!avoidsSpoilers || (!$0.evidence.isEmpty && $0.evidence.allSatisfy { allowed.contains($0.unitID) }))
        }
        let book = store.book
        let boundary = avoidsSpoilers && !relations.isEmpty ? store.temporalBoundary.allowedUnitIDs : nil
        let projection = relations.isEmpty ? nil : book.map { ReadingSpoilerProjection.Context(project: $0, allowedUnitIDs: boundary) }
        let entities = relations.isEmpty ? [:] : Dictionary((book?.entities ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let events = relations.isEmpty ? [:] : Dictionary((book?.events ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func visibleTitle(_ other: String) -> String? {
            if let entity = entities[other] { return projection?.entity(entity)?.name }
            if let event = events[other] { return projection?.event(event)?.name }
            return nil
        }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(relations.prefix(16)) { relation in
                let other = relation.fromID == id ? relation.toID : relation.fromID
                if let title = visibleTitle(other) {
                    Button { store.showReadingObject(other) } label: { Label("\(relation.label) · \(title)", systemImage: "point.3.connected.trianglepath.dotted").font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(ReadingQuietButtonStyle())
                }
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
            HStack { Text(card.title).font(.subheadline.weight(.semibold)); Spacer(); Menu { Button("移除", role: .destructive, action: onRemove) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).modifier(ReadingHoverSurface()).frame(width: 32, height: 32) }
            Text(card.sourceLabel).font(.caption2).foregroundStyle(.secondary)
            MarkdownText(markdown: card.contextMarkdown)
            ForEach(card.options) { option in
                Button { choice = option.id } label: {
                    HStack(alignment: .top, spacing: 10) { Image(systemName: choice == option.id ? "checkmark.circle.fill" : "circle"); Text(option.title).font(.subheadline); Spacer(minLength: 0) }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .background(Palette.accent.opacity(choice == option.id ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(ReadingQuietButtonStyle())
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
        }.readingCompanionSection().id(card.id)
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
    func readingCompanionSection(inset: CGFloat = 12) -> some View {
        frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, inset)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line.opacity(0.4)).frame(height: 0.5) }
    }
}

private struct CompanionRecordManagementControl: View {
    @EnvironmentObject private var store: AppStore
    let title: String
    let id: String
    let kind: String
    let onRemove: () -> Void
    @State private var owner: WorkspacePickerOwner?
    @State private var presented = false
    var body: some View {
        Button { owner = WorkspacePickerOwner(store: store); presented = true } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
            .buttonStyle(ReadingQuietButtonStyle()).help("管理这条伴读：收纳到历史，或移入可恢复的回收站。")
            .popover(isPresented: $presented) {
                ManagementActionPopover(title: "这条伴读", options: [
                    .init(id: "archive", title: "移入历史", detail: "保留完整内容，退出自动上下文；之后可恢复或引用。", icon: "archivebox"),
                    .init(id: "trash", title: "移入伴读回收站…", detail: "确认后移除这条伴读，原书和笔记保留。", icon: "trash", destructive: true)
                ], width: 360, close: { presented = false }, select: { action in
                    guard let owner, owner.matches(store), let book = store.book,
                          ReaderCollectionRuntime.reference(kind + ":" + id, in: book) != nil else { return }
                    presented = false
                    Task { @MainActor in
                        await Task.yield(); guard owner.matches(store) else { return }
                        if action == "archive" { await store.organizeReaderCollections(.archive([kind + ":" + id], store.newHistoryFolderTitle), owner: owner) }
                        else if action == "trash" { onRemove() }
                    }
                })
            }
            .onChange(of: store.collectionOwnerKey) { _, _ in presented = false; owner = nil }
    }
}
