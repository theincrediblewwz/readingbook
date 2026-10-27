import SwiftUI
import ReadingCore

/// The popup is a disposable projection of existing records, never a second
/// writer. Provider requests are separately enabled by an explicit action or
/// the reader's hover-translation preference after its cancellable dwell.
struct ReaderInlineContent: Sendable {
    let anchor: SourceAnchor
    let title: String
    let kind: String
    let markdown: String
    let savedMarkdown: String?
    let objectID: String?
    let context: ReadingContext
    let composition: ViewDefinition?
    let compositionCurrentScope: CompositionCurrentScope
    static func freeze(_ id: String, book: BookProject, index: ReadingExperienceState, boundary: KnowledgeReadBoundary) -> Self? {
        guard !Task.isCancelled,
              let anchor = index.anchors.first(where: { $0.id == id }) ?? book.readingExperience?.anchors.first(where: { $0.id == id }),
              boundary.allowedUnitIDs?.contains(anchor.unitID) != false,
              let resolved = try? ReadingExperienceRuntime.resolve(anchor, in: book) else { return nil }
        let target = index.mentions.first(where: { $0.anchorID == id })?.targetID ?? book.readingExperience?.mentions.first(where: { $0.anchorID == id })?.targetID
        // Plain sentences have no object to project. In particular, do not
        // rebuild every saved knowledge version just to display a sentence.
        let projection = target.map { _ in ReadingSpoilerProjection.Context(project: book, allowedUnitIDs: boundary.allowedUnitIDs) }
        let entity: KnowledgeEntity?, event: KnowledgeEvent?
        if let target, let projection {
            entity = book.entities.first { $0.id == target }.flatMap { projection.entity($0) }
            event = book.events.first { $0.id == target }.flatMap { projection.event($0) }
        } else { entity = nil; event = nil }
        guard !Task.isCancelled else { return nil }
        let syntax = ReadingSentenceAnchors.syntax(for: resolved.unit, in: book)
        let passageBoundaries = target == nil ? ReadingSentenceAnchors.boundaryIndex(in: resolved.unit.text, chapterTitle: resolved.unit.chapter, syntax: syntax) : nil
        guard passageBoundaries?.crossesStructuralBoundary(resolved.range) != true else { return nil }
        let evidence = entity?.evidence ?? event?.evidence ?? []
        var units: [String: SourceUnit] = [:]
        if !evidence.isEmpty {
            for unit in book.units {
                guard !Task.isCancelled else { return nil }
                if units[unit.id] == nil { units[unit.id] = unit }
            }
        }
        // A later full-book aggregate must not leak back into an earlier page.
        // This has the same conservative reuse gate as the query/search path:
        // exact stored excerpts, all at or before the current reading cursor.
        let summaryIsSafe = !evidence.isEmpty && evidence.allSatisfy { item in
            guard !Task.isCancelled, boundary.allowedUnitIDs?.contains(item.unitID) != false, let unit = units[item.unitID],
                  unit.order <= resolved.unit.order, !item.quote.isEmpty,
                  let range = unit.text.range(of: item.quote, options: .literal) else { return false }
            return unit.text[range].utf8.elementsEqual(item.quote.utf8)
        }
        let summary = summaryIsSafe ? (entity?.summary ?? event?.summary ?? "") : ""
        let hasSummary = !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !Task.isCancelled else { return nil }
        var localLayers: [ReadingLayer] = []
        if !hasSummary {
            let state = book.readingExperience ?? ReadingExperienceState()
            var anchors: [String: SourceAnchor] = [:]
            for candidate in state.anchors {
                guard !Task.isCancelled else { return nil }
                if candidate.unitID == anchor.unitID, anchors[candidate.id] == nil { anchors[candidate.id] = candidate }
            }
            let structuralBoundaries = passageBoundaries ?? ReadingSentenceAnchors.boundaryIndex(in: resolved.unit.text, chapterTitle: resolved.unit.chapter, syntax: syntax)
            var localProject = book; localProject.units = [resolved.unit]
            let resolveLocal: ((SourceAnchor) throws -> ResolvedSourceAnchor)? = state.layers.isEmpty ? nil :
                try? ReadingExperienceRuntime.anchorResolver(sourceHash: book.sourceHash, unitID: resolved.unit.id, in: localProject)
            var rangesByID: [String: NSRange] = [:], invalidIDs = Set<String>()
            func precedes(_ lhs: ReadingLayer, _ rhs: ReadingLayer) -> Bool {
                lhs.id < rhs.id
            }
            for layer in state.layers {
                guard !Task.isCancelled else { return nil }
                // Translation has its own exact-source cache and tab. Mixing
                // it into this projection made a saved translation displace
                // the analysis, including after a background publication.
                guard layer.kind != "translation", !layer.sourceAnchorIDs.isEmpty else { continue }
                var ranges: [NSRange] = [], valid = true
                for value in layer.sourceAnchorIDs {
                    guard !Task.isCancelled else { return nil }
                    guard let candidate = anchors[value], !invalidIDs.contains(value) else { valid = false; break }
                    if let range = rangesByID[value] { ranges.append(range); continue }
                    guard let resolveLocal, let source = try? resolveLocal(candidate),
                          !structuralBoundaries.crossesStructuralBoundary(source.range) else {
                        invalidIDs.insert(value); valid = false; break
                    }
                    rangesByID[value] = source.range; ranges.append(source.range)
                }
                guard valid else { continue }
                let matches = ranges.contains { NSIntersectionRange($0, resolved.range).length > 0 }
                if matches {
                    // Only three layers can be shown. Preserve the exact old
                    // ordering without sorting/retaining all matching layers.
                    localLayers.append(layer); localLayers.sort(by: precedes)
                    if localLayers.count > 3 { localLayers.removeLast() }
                }
            }
        }
        guard !Task.isCancelled else { return nil }
        let title = entity?.name ?? event?.name ?? "读到这里"
        let markdown: String
        if hasSummary { markdown = summary }
        else if !localLayers.isEmpty { markdown = localLayers.map(\.markdown).joined(separator: "\n\n") }
        else { markdown = "这里还没有保存更多介绍。可以围绕这句话，继续和 AI 聊聊。" }
        let objectID = entity?.id ?? event?.id
        let context = ReadingContext(sourceHash: book.sourceHash, unitID: anchor.unitID, selectedText: anchor.quote,
            selectedPrefix: anchor.prefix, selectedSuffix: anchor.suffix, objectID: objectID, page: resolved.page)
        let configured = book.views.first { view in
            guard !Task.isCancelled, view.composition != nil, view.configuration?["presentation"] == "inline" else { return false }
            let objects = view.configuration?["objectIDs"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
            return objects.isEmpty || objectID.map { objects.contains($0) } == true
        }
        guard !Task.isCancelled else { return nil }
        let composition = configured ?? projection.flatMap { contextualComposition(objectID: objectID, unitID: anchor.unitID, book: book, projection: $0, boundary: boundary) }
        guard !Task.isCancelled else { return nil }
        return Self(anchor: anchor, title: title, kind: entity.flatMap { value in book.types.first(where: { $0.id == value.typeID })?.name } ?? (event == nil ? "译注" : "事件"),
            markdown: markdown, savedMarkdown: hasSummary || !localLayers.isEmpty ? markdown : nil, objectID: objectID, context: context,
            composition: composition, compositionCurrentScope: configured == nil ? .page : .automatic)
    }
    private static func contextualComposition(objectID: String?, unitID: String, book: BookProject, projection: ReadingSpoilerProjection.Context,
                                             boundary: KnowledgeReadBoundary) -> ViewDefinition? {
        guard !Task.isCancelled, let objectID else { return nil }
        var events: [KnowledgeEvent] = []
        for event in book.events {
            guard !Task.isCancelled else { return nil }
            if (event.id == objectID || event.participantIDs.contains(objectID)), event.evidence.contains(where: { $0.unitID == unitID }),
               let projected = projection.event(event), projected.id == objectID || projected.participantIDs.contains(objectID) { events.append(projected) }
        }
        let places = Set(events.flatMap(\.placeIDs) + [objectID])
        var visiblePlaces: [KnowledgeEntity] = []
        for entity in book.entities {
            guard !Task.isCancelled else { return nil }
            if places.contains(entity.id), entity.evidence.contains(where: { $0.unitID == unitID }), let projected = projection.entity(entity) { visiblePlaces.append(projected) }
        }
        let hasMap = visiblePlaces.contains { $0.latitude != nil && $0.longitude != nil }
        var hasTime = events.contains { $0.startYear != nil || $0.endYear != nil }
        if !hasTime, !events.isEmpty {
            // A modern event may have only dated/narrative metadata, without
            // the legacy year fields. Use the same provenance gate as the
            // timeline; future metadata must not create an apparent entry.
            let eventIDs = Set(events.map(\.id))
            let parentIDs = Set((book.temporalKnowledge?.eventMetadata ?? []).filter { eventIDs.contains($0.eventID) }.compactMap(\.parentEventID)).subtracting(eventIDs)
            var scoped = book; scoped.events = events
            // A dated child can refer to a visible parent that does not itself
            // involve this person. Keep that reference for the provenance gate;
            // only the originally related events can make this timeline appear.
            for event in book.events where parentIDs.contains(event.id) {
                guard !Task.isCancelled else { return nil }
                if let value = projection.event(event) { scoped.events.append(value) }
            }
            hasTime = (try? TemporalKnowledgeRuntime.events(in: scoped, boundary: boundary))?.contains {
                eventIDs.contains($0.object.id) && ($0.extent.start != nil || $0.extent.end != nil || $0.extent.narrativeStart != nil)
            } == true
        }
        var sources: [CompositionDataSource] = [], parts: [CompositionPart] = [], layout: [CompositionLayoutNode] = []
        if hasTime {
            let relation: CompositionSelectionRelation = book.events.contains(where: { $0.id == objectID }) ? .selected : .events
            sources.append(CompositionDataSource(id: "inline-events", collection: .events, relation: relation, sort: .time, limit: 12))
            parts.append(CompositionPart(id: "inline-time", primitive: .timeline, sourceID: "inline-events", title: "与此相关的时间"))
            layout.append(CompositionLayoutNode(id: "inline-time-node", kind: .part, partID: "inline-time"))
        }
        if hasMap {
            sources.append(CompositionDataSource(id: "inline-places", collection: .objects, relation: visiblePlaces.contains(where: { $0.id == objectID && $0.latitude != nil }) ? .selected : .places, limit: 12))
            parts.append(CompositionPart(id: "inline-map", primitive: .map, sourceID: "inline-places", title: "书中位置"))
            layout.append(CompositionLayoutNode(id: "inline-map-node", kind: .part, partID: "inline-map"))
        }
        guard !parts.isEmpty else { return nil }
        let root: String
        if layout.count == 1 { root = layout[0].id }
        else { root = "inline-context"; layout.append(CompositionLayoutNode(id: root, kind: .column, children: layout.map(\.id))) }
        var view = ViewDefinition(id: "reader-inline-context", title: "相关内容", kind: .map)
        view.composition = CompositionDefinition(sources: sources, parts: parts, layout: layout, rootID: root)
        return view
    }
}

@MainActor final class ReaderInlineState: ObservableObject {
    private struct Input: Sendable {
        let scope: String; let serial: Int; let book: BookProject
        let index: ReadingExperienceState; let boundary: KnowledgeReadBoundary
    }
    @Published var hover: SourceReadingHover?
    @Published var content: ReaderInlineContent?
    @Published var pinned = false
    @Published private(set) var automaticTranslationActive = false
    private var pendingID: String?
    private var task: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var inputs: [String: Input] = [:]
    private var scope: String?
    private var serial = 0
    private var interactionGeneration = 0
    private var displayedSerial: Int?
    private var inside = false
    private var sourceInside = false
    private var closing = false
    var lastHover: SourceReadingHover?
    func receive(_ value: SourceReadingHover?, book: BookProject?, index: ReadingExperienceState, scope: String,
                 boundary: (String) -> KnowledgeReadBoundary) {
        if self.scope != nil, self.scope != scope { clear() }
        if let value { lastHover = value }
        if pinned && value?.activated != true {
            sourceInside = value?.id == hover?.id
            automaticTranslationActive = inside || sourceInside
            return
        }
        guard let value, let book else { leave(); return }
        sourceInside = true
        if var current = hover, current.id == value.id && !value.activated {
            // The same sentence can wrap across lines or move after a scroll.
            // Refresh only its presentation geometry, preserving content and
            // dwell intent. A pinned card returned above keeps its position.
            current.rect = value.rect; current.point = value.point
            if hover != current { hover = current }
            automaticTranslationActive = true; cancelPending(); refreshDisplayed(); return
        }
        if pendingID == value.id && !value.activated { return }
        automaticTranslationActive = false
        cancelPending(); invalidateRefresh(); pendingID = value.id
        updateInputs(book: book, index: index, scope: scope, boundary: boundary)
        let generation = interactionGeneration
        task = Task { [weak self] in
            if !value.activated { do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return } }
            guard let self else { return }
            // A project/index update also updates the waiting hover. Preserve
            // its delay, but never finish with the old captured book snapshot.
            while !Task.isCancelled, self.interactionGeneration == generation, self.pendingID == value.id {
                guard let input = self.inputs[value.id], input.scope == self.scope else { return }
                let worker = Task.detached(priority: .userInitiated) { ReaderInlineContent.freeze(value.id, book: input.book, index: input.index, boundary: input.boundary) }
                let frozen = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, self.interactionGeneration == generation, self.pendingID == value.id,
                      self.scope == input.scope else { return }
                guard self.inputs[value.id]?.serial == input.serial else { continue }
                guard let content = frozen else { self.clear(); return }
                // lastHover also receives same-ID events during the dwell and
                // background projection. Only its latest geometry is reused;
                // source identity and activation still belong to this request.
                var presentation = value
                if let latest = self.lastHover, latest.id == value.id {
                    presentation.rect = latest.rect; presentation.point = latest.point
                }
                self.content = content; self.hover = presentation; self.pinned = value.activated
                self.automaticTranslationActive = self.sourceInside || self.inside
                self.pendingID = nil; self.task = nil; self.displayedSerial = input.serial; self.inputs = [value.id: input]
                return
            }
        }
    }
    /// Called only for actual project/index publications, never from body-time
    /// array comparisons. This refresh cannot move, pin or reopen the popup.
    func refresh(book: BookProject?, index: ReadingExperienceState, scope: String,
                 boundary: (String) -> KnowledgeReadBoundary) {
        guard hover != nil || pendingID != nil else { return }
        guard let book, self.scope == scope else { clear(); return }
        updateInputs(book: book, index: index, scope: scope, boundary: boundary)
        if pendingID == nil { refreshDisplayed() }
    }
    private func updateInputs(book: BookProject, index: ReadingExperienceState, scope: String,
                              boundary: (String) -> KnowledgeReadBoundary) {
        self.scope = scope; serial &+= 1
        let ids = Set([hover?.id, pendingID].compactMap { $0 })
        inputs = Dictionary(uniqueKeysWithValues: ids.map { ($0, Input(scope: scope, serial: serial, book: book, index: index, boundary: boundary($0))) })
    }
    private func invalidateRefresh() {
        interactionGeneration &+= 1; refreshTask?.cancel(); refreshTask = nil
    }
    private func cancelPending() {
        task?.cancel(); task = nil; closing = false
        if pendingID != nil { pendingID = nil; invalidateRefresh() }
    }
    private func refreshDisplayed() {
        guard refreshTask == nil, pendingID == nil, let id = hover?.id,
              let input = inputs[id], displayedSerial != input.serial else { return }
        let generation = interactionGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.interactionGeneration == generation, self.pendingID == nil, self.hover?.id == id {
                guard let input = self.inputs[id], input.scope == self.scope else { return }
                let worker = Task.detached(priority: .userInitiated) { ReaderInlineContent.freeze(id, book: input.book, index: input.index, boundary: input.boundary) }
                let frozen = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, self.interactionGeneration == generation, self.pendingID == nil,
                      self.hover?.id == id, self.scope == input.scope else { return }
                guard self.inputs[id]?.serial == input.serial else { continue }
                self.refreshTask = nil
                guard let content = frozen else { self.clear(); return }
                // A word rebound to another object is a different interaction,
                // not permission to open a new automatic teacher request.
                guard self.content?.objectID == content.objectID else { self.clear(); return }
                self.content = content; self.displayedSerial = input.serial; self.inputs = [id: input]
                return
            }
        }
    }
    func leave() { sourceInside = false; automaticTranslationActive = inside; scheduleClose() }
    func pointer(_ value: Bool) {
        inside = value; automaticTranslationActive = inside || (sourceInside && pendingID == nil)
        if value { cancelPending(); refreshDisplayed() } else { scheduleClose() }
    }
    func pin() { cancelPending(); pinned = true; refreshDisplayed() }
    func clear() {
        task?.cancel(); task = nil; closing = false; pendingID = nil; invalidateRefresh()
        inputs = [:]; scope = nil; displayedSerial = nil; hover = nil; content = nil; pinned = false
        inside = false; sourceInside = false; automaticTranslationActive = false; lastHover = nil
    }
    private func scheduleClose() {
        guard !pinned, !closing else { return }
        if pendingID != nil { invalidateRefresh() }
        task?.cancel(); pendingID = nil
        guard hover != nil || content != nil else { task = nil; inputs = [:]; scope = nil; displayedSerial = nil; return }
        closing = true
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.closing = false; self.task = nil
            guard !self.inside, !self.pinned else { return }; self.clear()
        }
    }
}

struct ReaderInlineCard: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var state: ReaderInlineState
    let viewport: CGSize
    var obstacles: [CGRect] = []
    @State private var showsComposition = false
    private var width: CGFloat { min(430, max(280, viewport.width - 48)) }
    private var height: CGFloat { min(showsComposition ? 560 : 380, max(220, viewport.height - 150)) }
    private var placement: CGRect? {
        guard let anchor = state.hover?.rect else { return nil }
        let bounds = CGRect(x: 20, y: 84, width: max(0, viewport.width - 40), height: max(0, viewport.height - 170))
        let left = anchor.minX - bounds.minX - 14, right = bounds.maxX - anchor.maxX - 14
        let above = anchor.minY - bounds.minY - 14, below = bounds.maxY - anchor.maxY - 14
        let side = max(left, right) >= 280
        let cardWidth = side ? min(width, max(left, right)) : min(width, bounds.width)
        let cardHeight = side ? min(height, bounds.height) : min(height, max(above, below))
        guard cardHeight >= 140 else { return nil }
        let preferred = side ? (right >= left ? CGPoint(x: anchor.maxX + 14, y: anchor.minY) : CGPoint(x: anchor.minX - cardWidth - 14, y: anchor.minY))
            : CGPoint(x: anchor.minX, y: below >= above ? anchor.maxY + 14 : anchor.minY - cardHeight - 14)
        // Try a compact scrollable form before giving up a crowded viewport.
        // Never cover the quoted line or silently move an existing panel.
        for candidate in [CGSize(width: cardWidth, height: cardHeight),
                          CGSize(width: min(300, cardWidth), height: min(220, cardHeight)),
                          CGSize(width: min(280, cardWidth), height: 140)] {
            if let result = FloatingChromeGeometry.place(size: candidate, preferredOrigin: preferred,
                within: bounds, avoiding: obstacles + [anchor.insetBy(dx: -4, dy: -4)], gap: 6) { return result }
        }
        return nil
    }
    var body: some View {
        if let content = state.content, let placement {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) { Text(content.title).font(.system(size: 19, weight: .semibold)); Text(content.kind).font(.system(size: 12)).foregroundStyle(.secondary) }
                    Spacer(minLength: 8)
                    Button { state.pin() } label: { Image(systemName: state.pinned ? "pin.fill" : "pin") }.buttonStyle(ReadingToolbarButtonStyle()).help("固定在这里")
                    Button { state.clear() } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("关闭").keyboardShortcut(.cancelAction)
                }.padding(.leading, 18).padding(.trailing, 6).padding(.vertical, 7)
                Divider().opacity(0.3)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let objectID = content.objectID {
                            if let saved = content.savedMarkdown { MarkdownText(markdown: saved) }
                            if state.pinned && store.queryAnswerStyle == .mentor {
                                TeacherBackgroundCard(objectID: objectID, unitID: content.anchor.unitID)
                            }
                        } else {
                            SentenceTranslationCard(anchor: content.anchor, fallbackMarkdown: content.savedMarkdown,
                                automaticHoverState: state, automaticHoverActive: state.automaticTranslationActive)
                        }
                        if let composition = content.composition {
                            DisclosureGroup("时间与相关内容", isExpanded: $showsComposition) {
                                if showsComposition { CompositionWorkspaceView(definition: composition, embedded: true, contextOverride: content.context, currentScope: content.compositionCurrentScope).frame(height: 340) }
                            }.font(.system(size: 14, weight: .medium))
                        }
                        HStack {
                            Button("继续聊聊") {
                                let question = content.objectID == nil ? "给我讲讲这句话的意思。" : "给我讲讲\(content.title)，像一起读书时那样。"
                                if store.openReadingConversation(anchor: content.anchor, objectID: content.objectID, question: question) { state.clear() }
                            }.buttonStyle(ReadingToolbarButtonStyle())
                            Spacer()
                            Button("在伴读中打开") { store.sourceDecorationTapped(content.anchor.id); state.clear() }.buttonStyle(ReadingToolbarButtonStyle())
                        }
                    }.padding(18)
                }
            }.frame(width: placement.width, height: placement.height).readingGlass(radius: 24, prominent: true)
                .environment(\.markdownReadingStyle, "companion")
                .readingTextContext(.companion)
                .onHover { state.pointer($0) }.onChange(of: content.anchor.id) { _, _ in showsComposition = false }
                .workspaceChromeBounds("reader-inline")
                .position(x: placement.midX, y: placement.midY)
        } else if let content = state.content, state.pinned {
            // A click must still reach its saved content when no safe popup
            // slot exists. Reuse the existing companion instead of covering
            // source text, moving other panels or sending a model request.
            Color.clear.frame(width: 0, height: 0).task(id: content.anchor.id) {
                store.sourceDecorationTapped(content.anchor.id)
                state.clear()
            }
        }
    }
}
