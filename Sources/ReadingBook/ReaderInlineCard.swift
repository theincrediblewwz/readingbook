import SwiftUI
import ReadingCore

/// The popup is a disposable projection of existing records, never a second
/// writer and never a reason to send a provider request.
struct ReaderInlineContent: Sendable {
    let anchor: SourceAnchor
    let title: String
    let kind: String
    let markdown: String
    let objectID: String?
    let context: ReadingContext
    let composition: ViewDefinition?
    static func freeze(_ id: String, book: BookProject, index: ReadingExperienceState, boundary: KnowledgeReadBoundary) -> Self? {
        guard let anchor = index.anchors.first(where: { $0.id == id }) ?? book.readingExperience?.anchors.first(where: { $0.id == id }),
              boundary.allowedUnitIDs?.contains(anchor.unitID) != false,
              let resolved = try? ReadingExperienceRuntime.resolve(anchor, in: book) else { return nil }
        let target = index.mentions.first(where: { $0.anchorID == id })?.targetID ?? book.readingExperience?.mentions.first(where: { $0.anchorID == id })?.targetID
        let projection = ReadingSpoilerProjection.Context(project: book, allowedUnitIDs: boundary.allowedUnitIDs)
        let entity = book.entities.first { $0.id == target }.flatMap { projection.entity($0) }
        let event = book.events.first { $0.id == target }.flatMap { projection.event($0) }
        let state = book.readingExperience ?? ReadingExperienceState()
        let units = Dictionary(book.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let anchors = Dictionary(state.anchors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localLayers = state.layers.filter { layer in
            !layer.sourceAnchorIDs.isEmpty && layer.sourceAnchorIDs.allSatisfy { anchors[$0]?.unitID == anchor.unitID }
                && layer.sourceAnchorIDs.contains { value in
                    guard let candidate = anchors[value], let start = candidate.utf16Location, let length = candidate.utf16Length else { return value == id }
                    return NSIntersectionRange(NSRange(location: start, length: length), resolved.range).length > 0
                }
        }.sorted { lhs, rhs in
            let left = lhs.kind == "translation" ? 0 : 1, right = rhs.kind == "translation" ? 0 : 1
            return left == right ? lhs.id < rhs.id : left < right
        }
        let title = entity?.name ?? event?.name ?? (localLayers.first?.kind == "translation" ? "这句话的意思" : "读到这里")
        let evidence = entity?.evidence ?? event?.evidence ?? []
        // A later full-book aggregate must not leak back into an earlier page.
        // This has the same conservative reuse gate as the query/search path:
        // exact stored excerpts, all at or before the current reading cursor.
        let summaryIsSafe = !evidence.isEmpty && evidence.allSatisfy { item in
            guard boundary.allowedUnitIDs?.contains(item.unitID) != false, let unit = units[item.unitID],
                  unit.order <= resolved.unit.order, !item.quote.isEmpty,
                  let range = unit.text.range(of: item.quote, options: .literal) else { return false }
            return unit.text[range].utf8.elementsEqual(item.quote.utf8)
        }
        let summary = summaryIsSafe ? (entity?.summary ?? event?.summary ?? "") : ""
        let markdown: String
        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { markdown = summary }
        else if !localLayers.isEmpty { markdown = localLayers.prefix(3).map(\.markdown).joined(separator: "\n\n") }
        else { markdown = "这里还没有保存更多介绍。可以围绕这句话，继续和 AI 聊聊。" }
        let objectID = entity?.id ?? event?.id
        let context = ReadingContext(sourceHash: book.sourceHash, unitID: anchor.unitID, selectedText: anchor.quote,
            selectedPrefix: anchor.prefix, selectedSuffix: anchor.suffix, objectID: objectID, page: resolved.page)
        let configured = book.views.first { view in
            guard view.composition != nil, view.configuration?["presentation"] == "inline" else { return false }
            let objects = view.configuration?["objectIDs"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
            return objects.isEmpty || objectID.map { objects.contains($0) } == true
        }
        return Self(anchor: anchor, title: title, kind: entity.flatMap { value in book.types.first(where: { $0.id == value.typeID })?.name } ?? (event == nil ? "译注" : "事件"),
            markdown: markdown, objectID: objectID, context: context,
            composition: configured ?? contextualComposition(objectID: objectID, unitID: anchor.unitID, book: book, projection: projection))
    }
    private static func contextualComposition(objectID: String?, unitID: String, book: BookProject, projection: ReadingSpoilerProjection.Context) -> ViewDefinition? {
        guard let objectID else { return nil }
        let events = book.events.filter { ($0.id == objectID || $0.participantIDs.contains(objectID)) && $0.evidence.contains { $0.unitID == unitID } }
            .compactMap { projection.event($0) }
            .filter { $0.id == objectID || $0.participantIDs.contains(objectID) }
        let places = Set(events.flatMap(\.placeIDs) + [objectID])
        let visiblePlaces = book.entities.filter { places.contains($0.id) && $0.evidence.contains { $0.unitID == unitID } }
            .compactMap { projection.entity($0) }
        let hasMap = visiblePlaces.contains { $0.latitude != nil && $0.longitude != nil }
        let hasTime = events.contains { $0.startYear != nil }
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
    @Published var hover: SourceReadingHover?
    @Published var content: ReaderInlineContent?
    @Published var pinned = false
    private var pendingID: String?
    private var task: Task<Void, Never>?
    private var inside = false
    var lastHover: SourceReadingHover?
    func receive(_ value: SourceReadingHover?, book: BookProject?, index: ReadingExperienceState, boundary: KnowledgeReadBoundary) {
        if let value { lastHover = value }
        if pinned && value?.activated != true { return }
        guard let value, let book else { scheduleClose(); return }
        if hover?.id == value.id && !value.activated { task?.cancel(); pendingID = nil; return }
        if pendingID == value.id && !value.activated { return }
        task?.cancel(); pendingID = value.id
        task = Task { [weak self] in
            if !value.activated { do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return } }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) { ReaderInlineContent.freeze(value.id, book: book, index: index, boundary: boundary) }
            let frozen = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self, let content = frozen else { return }
            self.content = content; self.hover = value; self.pinned = value.activated; self.pendingID = nil
        }
    }
    func pointer(_ value: Bool) { inside = value; if value { task?.cancel(); pendingID = nil } else { scheduleClose() } }
    func pin() { task?.cancel(); pendingID = nil; pinned = true }
    func clear() { task?.cancel(); task = nil; pendingID = nil; hover = nil; content = nil; pinned = false; inside = false; lastHover = nil }
    private func scheduleClose() {
        guard !pinned else { return }
        task?.cancel(); pendingID = nil
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard let self, !self.inside, !self.pinned else { return }; self.clear()
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
                        MarkdownText(markdown: content.markdown).clipShape(RoundedRectangle(cornerRadius: 14))
                        if let composition = content.composition {
                            DisclosureGroup("时间与相关内容", isExpanded: $showsComposition) {
                                if showsComposition { CompositionWorkspaceView(definition: composition, embedded: true, contextOverride: content.context).frame(height: 340) }
                            }.font(.system(size: 14, weight: .medium))
                        }
                        HStack {
                            Button("继续聊聊") {
                                if let id = content.objectID { store.selectedObjectID = id }
                                store.focusedReadingAnchorID = content.anchor.id
                                store.queryScope = .selection; store.readingCompanionVisible = true; store.readingCompanionTab = "chat"
                                store.queryComposerDraft.text = content.objectID == nil ? "给我讲讲这句话的意思。" : "给我讲讲\(content.title)，像一起读书时那样。"
                                state.clear()
                            }.buttonStyle(ReadingToolbarButtonStyle())
                            Spacer()
                            Button("在伴读中打开") { store.sourceDecorationTapped(content.anchor.id); state.clear() }.buttonStyle(ReadingToolbarButtonStyle())
                        }
                    }.padding(18)
                }
            }.frame(width: placement.width, height: placement.height).readingGlass(radius: 24, prominent: true)
                .environment(\.markdownReadingStyle, "companion")
                .onHover { state.pointer($0) }.onChange(of: content.anchor.id) { _, _ in showsComposition = false }
                .position(x: placement.midX, y: placement.midY).workspaceChromeBounds("reader-inline")
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
