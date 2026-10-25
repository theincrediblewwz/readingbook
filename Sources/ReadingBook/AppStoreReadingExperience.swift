import SwiftUI
import ReadingCore
import os

private let pageEvidenceSignposter = OSSignposter(subsystem: "org.readingbook.app", category: "PageEvidence")

/// Disposable page presentation only. Canonical anchors and evidence stay in
/// the book; neither a receipt update nor another page invalidates this key.
@MainActor final class ReadingPageSnapshotCache {
    struct ObjectInput: Hashable, Sendable {
        let id: String; let names: [String]; let evidence: [Evidence]; let event: Bool
    }
    struct Input: Hashable, Sendable {
        let owner: String; let units: [SourceUnit]; let objects: [ObjectInput]
        let anchors: [SourceAnchor]; let mentions: [SourceMention]; let literalBytes: [Data]
    }
    struct Snapshot: Sendable {
        let key: Int
        let input: Input
        let index: ReadingExperienceState
        let decorations: [SourceReadingDecoration]
    }
    struct Request: Sendable {
        let project: BookProject; let selectedUnitID: String?; let owner: String; let scope: String; let visiblePages: [Int]
    }
    struct Prepared: Sendable {
        let snapshots: [Snapshot]; let selected: Snapshot; let base: ReadingExperienceState
        let index: ReadingExperienceState; let changed: Bool
        let unitIndices: [String: Int]; let pageIndices: [Int: [Int]]
        let boundariesByPage: [Int: KnowledgeReadBoundary]
        let currentBoundary: KnowledgeReadBoundary?
        let anchorsByID: [String: SourceAnchor]
    }
    var pendingScope: String?
    var queued: Request?
    var current: Snapshot?
    var currentBase: ReadingExperienceState?
    // The worker computes this small key. Hashing Input (which includes source
    // bytes) or comparing full snapshots never happens during publication.
    var entries: [Int: Snapshot] = [:]
    var order: [Int] = []
    var window: [Snapshot] = []
    var presentationRevision = 0
    var visiblePDFPages: [Int] = []
    var unitIndices: [String: Int] = [:]
    var pageIndices: [Int: [Int]] = [:]
    var boundariesByPage: [Int: KnowledgeReadBoundary] = [:]
    var currentBoundary: KnowledgeReadBoundary?
    var anchorsByID: [String: SourceAnchor] = [:]
    func reset() {
        pendingScope = nil; queued = nil; current = nil; currentBase = nil; entries = [:]; order = []
        window = []; presentationRevision &+= 1; visiblePDFPages = []; unitIndices = [:]; pageIndices = [:]; boundariesByPage = [:]
        currentBoundary = nil; anchorsByID = [:]
    }
    func remember(_ value: Snapshot) {
        entries[value.key] = value; order.removeAll { $0 == value.key }; order.append(value.key)
        while order.count > 24 { entries.removeValue(forKey: order.removeFirst()) }
    }
    nonisolated static func prepare(_ request: Request, entries: [Int: Snapshot], current: Snapshot?, previousBase: ReadingExperienceState?, includeWindow: Bool = true) -> Prepared? {
        let book = request.project
        var unitIndices: [String: Int] = [:], pageIndices: [Int: [Int]] = [:]
        for (index, unit) in book.units.enumerated() {
            unitIndices[unit.id] = index
            if let page = unit.page { pageIndices[page, default: []].append(index) }
        }
        guard !Task.isCancelled, let position = request.selectedUnitID.flatMap({ unitIndices[$0] }) else { return nil }
        let selectedUnit = book.units[position], base = book.readingExperience ?? ReadingExperienceState()
        let pages = selectedUnit.page.map { includeWindow ? ReadingSentenceAnchors.pageWindow(current: $0, visible: request.visiblePages, available: Set(pageIndices.keys)) : [$0] } ?? []
        let groups = pages.isEmpty ? [[selectedUnit]] : pages.map { (pageIndices[$0] ?? []).map { book.units[$0] } }
        let anchorsByUnit = Dictionary(grouping: base.anchors, by: \.unitID)
        let mentionsByAnchor = Dictionary(grouping: base.mentions, by: \.anchorID)
        var snapshots: [Snapshot] = [], boundaries: [Int: KnowledgeReadBoundary] = [:]
        for units in groups {
            guard !Task.isCancelled else { return nil }
            let unitIDs = Set(units.map(\.id))
            if let page = units.first?.page, let last = units.max(by: { $0.order < $1.order }) {
                boundaries[page] = try? KnowledgeReadBoundary.throughSourceUnit(last.id, in: book)
            }
            let anchors = units.flatMap { anchorsByUnit[$0.id] ?? [] }
            var objects: [ObjectInput] = []
            for object in book.entities {
                let evidence = object.evidence.filter { unitIDs.contains($0.unitID) }
                if !evidence.isEmpty { objects.append(.init(id: object.id, names: [object.name] + object.aliases, evidence: evidence, event: false)) }
            }
            for object in book.events {
                let evidence = object.evidence.filter { unitIDs.contains($0.unitID) }
                if !evidence.isEmpty { objects.append(.init(id: object.id, names: [object.name], evidence: evidence, event: true)) }
            }
            let input = Input(owner: request.owner, units: units, objects: objects, anchors: anchors,
                mentions: anchors.flatMap { mentionsByAnchor[$0.id] ?? [] },
                literalBytes: units.map { Data($0.text.utf8) } + objects.flatMap { $0.names.map { Data($0.utf8) } + $0.evidence.map { Data($0.quote.utf8) } }
                    + anchors.flatMap { [Data($0.quote.utf8), Data($0.prefix.utf8), Data($0.suffix.utf8)] })
            var hasher = Hasher(); input.hash(into: &hasher); let key = hasher.finalize()
            // Exact equality on the worker protects against a compact-key
            // collision; literalBytes also rejects Unicode-normalized matches.
            let saved = entries[key].flatMap { $0.input == input ? $0 : nil }
            snapshots.append(saved ?? build(input, key: key, project: book))
        }
        guard !Task.isCancelled, let selected = snapshots.first(where: { $0.input.units.contains(where: { $0.id == selectedUnit.id }) }) else { return nil }
        var index = base
        var anchorIDs = Set(base.anchors.map(\.id)), mentionIDs = Set(base.mentions.map(\.id))
        for snapshot in snapshots {
            for anchor in snapshot.index.anchors where anchorIDs.insert(anchor.id).inserted { index.anchors.append(anchor) }
            for mention in snapshot.index.mentions where mentionIDs.insert(mention.id).inserted { index.mentions.append(mention) }
        }
        let changed = current?.input != selected.input || previousBase != base || current?.index != selected.index
        return Prepared(snapshots: snapshots, selected: selected, base: base, index: index, changed: changed,
            unitIndices: unitIndices, pageIndices: pageIndices, boundariesByPage: boundaries,
            currentBoundary: selectedUnit.page.flatMap { boundaries[$0] } ?? (try? KnowledgeReadBoundary.throughSourceUnit(selectedUnit.id, in: book)),
            anchorsByID: Dictionary(index.anchors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }
    nonisolated static func build(_ input: Input, key: Int, project: BookProject) -> Snapshot {
        let interval = pageEvidenceSignposter.beginInterval("BuildPageSnapshot")
        defer { pageEvidenceSignposter.endInterval("BuildPageSnapshot", interval) }
        var compact = project; compact.units = input.units
        compact.entities = input.objects.filter { !$0.event }.map {
            KnowledgeEntity(id: $0.id, typeID: "snapshot", name: $0.names.first ?? "", aliases: Array($0.names.dropFirst()), evidence: $0.evidence)
        }
        compact.events = input.objects.filter(\.event).map { KnowledgeEvent(id: $0.id, name: $0.names.first ?? "", evidence: $0.evidence) }
        let initial = ReadingExperienceState(anchors: input.anchors, mentions: input.mentions)
        var index = ReadingExperienceRuntime.indexEvidence(in: compact, state: initial, unitIDs: Set(input.units.map(\.id)))
        var existing = Set(index.anchors.map(\.id)), candidates = Set<String>()
        for unit in input.units {
            for anchor in ReadingSentenceAnchors.anchors(in: unit, project: compact) where existing.insert(anchor.id).inserted {
                index.anchors.append(anchor); candidates.insert(anchor.id)
            }
        }
        var offsets: [String: Int] = [:], offset = 0
        for unit in input.units { offsets[unit.id] = offset; offset += (unit.text as NSString).length }
        let mentions = Dictionary(grouping: index.mentions, by: \.anchorID)
        let units = Dictionary(input.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let decorations = index.anchors.compactMap { anchor -> SourceReadingDecoration? in
            guard !Task.isCancelled, let start = offsets[anchor.unitID], let location = anchor.utf16Location, let length = anchor.utf16Length else { return nil }
            return SourceReadingDecoration(id: anchor.id, targetID: mentions[anchor.id]?.first?.targetID ?? anchor.id, quote: anchor.quote,
                rangeLocation: start + location, rangeLength: length, prefix: anchor.prefix, suffix: anchor.suffix,
                interaction: mentions[anchor.id]?.isEmpty == false ? .term : .passage,
                page: units[anchor.unitID]?.page, passive: candidates.contains(anchor.id))
        }
        return Snapshot(key: key, input: input, index: index, decorations: decorations)
    }
}

@MainActor extension AppStore {
    var visibleSourceUnits: [SourceUnit] {
        guard let book, let id = selectedUnitID else { return [] }
        let cache = readingPageSnapshots
        let selected = cache.unitIndices[id].flatMap { book.units.indices.contains($0) && book.units[$0].id == id ? book.units[$0] : nil }
            ?? book.units.first(where: { $0.id == id })
        guard let unit = selected else { return [] }
        if let page = unit.page {
            if let indices = cache.pageIndices[page], indices.allSatisfy({ book.units.indices.contains($0) && book.units[$0].page == page }) {
                return indices.map { book.units[$0] }
            }
            return book.units.filter { $0.page == page }
        }
        return [unit]
    }
    func updateVisiblePDFPages(_ pages: [Int]) {
        let next = Array(Set(pages.filter { $0 > 0 })).sorted()
        guard readingPageSnapshots.visiblePDFPages != next else { return }
        readingPageSnapshots.visiblePDFPages = next
        refreshReadingExperienceIndex()
    }
    func refreshReadingExperienceIndex() {
        readingContextCacheKey = nil
        guard let book else {
            readingIndexTask?.cancel(); readingIndexGeneration &+= 1; readingPageSnapshots.reset()
            readingExperienceIndex = ReadingExperienceState(); return
        }
        let owner = libraryRootURL.path + "|" + book.id + "|" + book.sourceHash
        let visible = readingPageSnapshots.visiblePDFPages
        let scope = owner + "|" + (selectedUnitID ?? "") + "|" + visible.map(String.init).joined(separator: ",")
        let request = ReadingPageSnapshotCache.Request(project: book, selectedUnitID: selectedUnitID, owner: owner, scope: scope, visiblePages: visible)
        if readingPageSnapshots.pendingScope == scope { readingPageSnapshots.queued = request; return }
        readingIndexTask?.cancel(); readingIndexGeneration &+= 1
        readingPageSnapshots.pendingScope = scope; readingPageSnapshots.queued = nil
        let generation = readingIndexGeneration
        readingIndexTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 35_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.readingIndexGeneration == generation else { return }
            var next = self.readingPageSnapshots.queued ?? request
            self.readingPageSnapshots.queued = nil
            while !Task.isCancelled {
                let frozen = next
                // Publish the current page first; neighboring sentence indexes
                // must never hold the page the reader is already looking at.
                let needsFirstPage = self.readingPageSnapshots.current?.input.units.contains(where: { $0.id == frozen.selectedUnitID }) != true
                for includeWindow in (needsFirstPage ? [false, true] : [true]) {
                let entries = self.readingPageSnapshots.entries
                let current = self.readingPageSnapshots.current, base = self.readingPageSnapshots.currentBase
                let calculation = Task.detached(priority: .userInitiated) {
                    ReadingPageSnapshotCache.prepare(frozen, entries: entries, current: current, previousBase: base, includeWindow: includeWindow)
                }
                let prepared = await withTaskCancellationHandler(operation: { await calculation.value }, onCancel: { calculation.cancel() })
                guard !Task.isCancelled, self.readingIndexGeneration == generation, self.bookID == book.id,
                      self.readingPageSnapshots.pendingScope == scope,
                      self.libraryRootURL.path + "|" + book.id + "|" + (self.book?.sourceHash ?? "") == owner else { return }
                if let prepared {
                    self.readingPageSnapshots.unitIndices = prepared.unitIndices; self.readingPageSnapshots.pageIndices = prepared.pageIndices
                    self.readingPageSnapshots.boundariesByPage = prepared.boundariesByPage
                    self.readingPageSnapshots.currentBoundary = prepared.currentBoundary; self.readingPageSnapshots.anchorsByID = prepared.anchorsByID
                    for snapshot in prepared.snapshots { self.readingPageSnapshots.remember(snapshot) }
                    let units = self.visibleSourceUnits, expected = prepared.selected.input.units
                    let sourceStillMatches = units.count == expected.count && zip(expected, units).allSatisfy { left, right in
                        left.id == right.id && left.page == right.page && left.text.utf8.elementsEqual(right.text.utf8)
                    }
                    if sourceStillMatches {
                        var nextIndex = prepared.index
                        // Citation links may create one unsaved anchor just
                        // before this worker finishes. Keep only the currently
                        // requested, still literal focus through the refresh.
                        if let focused = self.focusedReadingAnchorID,
                           !nextIndex.anchors.contains(where: { $0.id == focused }),
                           let anchor = self.readingExperienceIndex.anchors.first(where: { $0.id == focused }),
                           let currentBook = self.book,
                           (try? ReadingExperienceRuntime.resolve(anchor, in: currentBook)) != nil {
                            nextIndex.anchors.append(anchor)
                            self.readingPageSnapshots.anchorsByID[anchor.id] = anchor
                        }
                        self.readingPageSnapshots.current = prepared.selected; self.readingPageSnapshots.currentBase = prepared.base
                        let windowChanged = self.readingPageSnapshots.window.map(\.key) != prepared.snapshots.map(\.key)
                        self.readingPageSnapshots.window = prepared.snapshots
                        if prepared.changed || windowChanged {
                            self.readingExperienceIndex = nextIndex; self.readingContextCacheKey = nil
                            self.readingPageSnapshots.presentationRevision &+= 1
                        }
                    }
                }
                }
                if let queued = self.readingPageSnapshots.queued { self.readingPageSnapshots.queued = nil; next = queued; continue }
                self.readingPageSnapshots.pendingScope = nil; self.readingIndexTask = nil; break
            }
        }
    }
    var currentReadingContext: ReadingContext {
        let object = selectedObjectID.flatMap { id in
            book?.entities.contains { $0.id == id } == true || book?.events.contains { $0.id == id } == true ? id : nil
        }
        let anchor = focusedReadingAnchorID.flatMap { id in readingExperienceIndex.anchors.first { $0.id == id } }
        let persistentAnchor = anchor.flatMap { value in book?.readingExperience?.anchors.contains { $0.id == value.id } == true ? value.id : nil }
        let selection = selectedSourceAnchor
        let document = book?.activeDocuments.first { $0.id == readingContextDocumentID }
        let sourceUnitID = selection?.unitID ?? anchor?.unitID ?? selectedUnitID
        let sourceUnit = sourceUnitID.flatMap { id in
            readingPageSnapshots.unitIndices[id].flatMap { index in
                guard let book, book.units.indices.contains(index), book.units[index].id == id else { return nil as SourceUnit? }
                return book.units[index]
            } ?? book?.units.first(where: { $0.id == id })
        }
        // A sentence on a genuinely visible neighboring PDF page has its own
        // source context, while native selections retain their start/end pages.
        let sourcePage = sourceReadingSelection?.page ?? sourceUnit?.page
        return ReadingContext(sourceHash: book?.sourceHash, unitID: document == nil ? sourceUnitID : nil,
                              selectedAnchorID: document == nil ? persistentAnchor : nil, selectedText: document == nil ? (selection?.quote ?? anchor?.quote) : nil,
                              selectedPrefix: document == nil ? (selection?.prefix ?? anchor?.prefix) : nil, selectedSuffix: document == nil ? (selection?.suffix ?? anchor?.suffix) : nil,
                              objectID: object, documentID: document?.id,
                              page: document == nil ? sourcePage : nil, timeFrom: timeFrom, timeTo: timeTo,
                              selectionEndPage: document == nil ? sourceReadingSelection?.endPage : nil)
    }
    var readingContextItems: ReadingContextItems {
        guard let book else { return ReadingContextItems() }
        let context = currentReadingContext
        if readingContextCacheKey == context { return readingContextCache }
        let result = ReadingExperienceRuntime.contextualItems(in: book, context: context, state: readingExperienceIndex)
        readingContextCache = result; readingContextCacheKey = context
        return result
    }
    var readingContextDescription: String {
        if let document = book?.activeDocuments.first(where: { $0.id == readingContextDocumentID }) { return "Markdown · \(document.title)" }
        var parts = [selectedUnit?.locator ?? "这本书"]
        if selectedSourceAnchor != nil { parts.append("所选原句") }
        if let document = book?.activeDocuments.first(where: { $0.id == readingContextDocumentID }) { parts.append(document.title) }
        if let id = selectedObjectID, book?.entities.contains(where: { $0.id == id }) == true || book?.events.contains(where: { $0.id == id }) == true { parts.append(objectTitle(id)) }
        return parts.joined(separator: " · ")
    }
    var selectedSourceAnchor: SourceAnchor? {
        guard let book, let selection = sourceReadingSelection, !selection.text.isEmpty else { return nil }
        let units = selection.page.map { page in book.units.filter { $0.page == page } } ?? visibleSourceUnits
        var offset = 0
        var matches: [SourceAnchor] = []
        for unit in units {
            let length = (unit.text as NSString).length
            if selection.isExact, let location = selection.rangeLocation, let count = selection.rangeLength,
               location >= offset, location + count <= offset + length,
               let range = Range(NSRange(location: location - offset, length: count), in: unit.text),
               String(unit.text[range]) == selection.text {
                let prefix = String(unit.text[..<range.lowerBound].suffix(240))
                let suffix = String(unit.text[range.upperBound...].prefix(240))
                return try? ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: unit.id, quote: selection.text, prefix: prefix, suffix: suffix, in: book)
            }
            if let anchor = try? ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: unit.id, quote: selection.text, in: book) { matches.append(anchor) }
            offset += length
        }
        return matches.count == 1 ? matches[0] : nil
    }
    var sourceReadingDecorations: [SourceReadingDecoration] {
        guard let book, let snapshot = readingPageSnapshots.current,
              snapshot.input.owner == libraryRootURL.path + "|" + book.id + "|" + book.sourceHash else { return [] }
        let units = visibleSourceUnits
        guard snapshot.input.units.count == units.count,
              zip(snapshot.input.units, units).allSatisfy({ $0.id == $1.id && $0.text.utf8.elementsEqual($1.text.utf8) }) else { return [] }
        var values = snapshot.decorations
        // Explicit citation navigation may add one transient anchor. Resolve
        // that single focus, rather than revalidating every mark in View.body.
        if let id = focusedReadingAnchorID, !values.contains(where: { $0.id == id }),
           let anchor = readingExperienceIndex.anchors.first(where: { $0.id == id }),
           let unit = units.first(where: { $0.id == anchor.unitID }) {
            var compact = book; compact.units = units
            if let resolved = try? ReadingExperienceRuntime.resolve(anchor, in: compact) {
                let start = units.prefix { $0.id != unit.id }.reduce(0) { $0 + ($1.text as NSString).length }
                values.append(SourceReadingDecoration(id: anchor.id, targetID: id, quote: anchor.quote, rangeLocation: start + resolved.utf16Location,
                    rangeLength: resolved.utf16Length, prefix: anchor.prefix, suffix: anchor.suffix))
            }
        }
        return values
    }
    var pdfSourceReadingDecorationRevision: Int { readingPageSnapshots.presentationRevision }
    func inlineReadingBoundary(for id: String?) -> KnowledgeReadBoundary {
        guard let book, book.temporalKnowledge?.profile?.avoidsSpoilers ?? true,
              let id, let anchor = readingPageSnapshots.anchorsByID[id], anchor.sourceHash == book.sourceHash,
              let position = readingPageSnapshots.unitIndices[anchor.unitID], book.units.indices.contains(position),
              book.units[position].id == anchor.unitID else { return temporalBoundary }
        guard let page = book.units[position].page, readingPageSnapshots.visiblePDFPages.contains(page),
              let boundary = readingPageSnapshots.boundariesByPage[page] else {
            if readingPageSnapshots.current?.input.units.contains(where: { $0.id == anchor.unitID }) == true,
               let boundary = readingPageSnapshots.currentBoundary { return boundary }
            return temporalBoundary
        }
        // Hovering a genuinely visible next page is explicit source context;
        // prefetch alone never broadens the read boundary or reading position.
        return boundary
    }
    var pdfSourceReadingDecorations: [SourceReadingDecoration] {
        guard let book else { return [] }
        let cache = readingPageSnapshots, owner = libraryRootURL.path + "|" + book.id + "|" + book.sourceHash
        var values = cache.window.flatMap { snapshot -> [SourceReadingDecoration] in
            guard snapshot.input.owner == owner,
                  snapshot.input.units.allSatisfy({ unit in
                      guard let index = cache.unitIndices[unit.id], book.units.indices.contains(index) else { return false }
                      return book.units[index].id == unit.id && book.units[index].text.utf8.elementsEqual(unit.text.utf8)
                  }) else { return [] }
            return snapshot.decorations
        }
        if let id = focusedReadingAnchorID, !values.contains(where: { $0.id == id }),
           let anchor = readingExperienceIndex.anchors.first(where: { $0.id == id }),
           let unit = book.units.first(where: { $0.id == anchor.unitID }), let page = unit.page,
           let resolved = try? ReadingExperienceRuntime.resolve(anchor, in: book) {
            values.append(SourceReadingDecoration(id: anchor.id, targetID: id, quote: anchor.quote,
                rangeLocation: resolved.utf16Location, rangeLength: resolved.utf16Length,
                prefix: anchor.prefix, suffix: anchor.suffix, page: page))
        }
        return values
    }
    func sourceDecorationTapped(_ id: String) {
        guard let anchor = readingExperienceIndex.anchors.first(where: { $0.id == id }) else { return }
        focusedReadingAnchorID = anchor.id; sourceReadingSelection = nil; readingContextDocumentID = nil
        selectedObjectID = readingExperienceIndex.mentions.first { $0.anchorID == id }?.targetID
        readingCompanionSection = selectedObjectID == nil ? "layers" : "mentions"; readingCompanionVisible = true; readingCompanionTab = "companion"
    }
    func focusReadingAnchor(_ id: String) {
        guard let book, let anchor = readingExperienceIndex.anchors.first(where: { $0.id == id }) ?? book.readingExperience?.anchors.first(where: { $0.id == id }) else { return }
        guard (try? ReadingExperienceRuntime.resolve(anchor, in: book)) != nil else { readingExperienceError = "此处引用已失效，请核对原文版本。"; return }
        navigateToUnit(anchor.unitID)
        if !readingExperienceIndex.anchors.contains(where: { $0.id == id }) { readingExperienceIndex.anchors.append(anchor) }
        focusedReadingAnchorID = id; route = "reader"
    }
    func followReadingEvidence(_ evidence: Evidence) {
        guard let book else { return }
        navigateToUnit(evidence.unitID); route = "reader"
        if let anchor = try? ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: evidence.unitID, quote: evidence.quote, in: book) {
            if !readingExperienceIndex.anchors.contains(where: { $0.id == anchor.id }) { readingExperienceIndex.anchors.append(anchor) }
            focusedReadingAnchorID = anchor.id
        } else { activity = "已回到原文片段；引句有歧义或不能精确匹配，请对照核查。" }
    }
    func showReadingObject(_ id: String) {
        if let document = book?.activeDocuments.first(where: { $0.id == id }) { Task { await openDocument(document) }; return }
        selectedObjectID = id; readingCompanionSection = "mentions"; readingCompanionVisible = true; readingCompanionTab = "companion"
    }
    func askAboutReadingContext() {
        if let documentID = readingContextDocumentID { queryScope = .notes; queryDocumentIDs = [documentID] }
        else if sourceReadingSelection != nil || selectedSourceAnchor != nil { queryScope = .selection }
        else { queryScope = .page }
        if route == "reader" { readingCompanionTab = "chat"; readingCompanionVisible = true }
        else { requestedWorkspaceRoute = "query" }
    }
    func newReadingNote(title: String, markdown: String, anchorIDs: [String]) {
        guard let book, !editorDirty, !isBusy else { errorMessage = "请先保存当前草稿或等待任务结束。"; return }
        let anchors = anchorIDs.compactMap { id in readingExperienceIndex.anchors.first { $0.id == id } ?? book.readingExperience?.anchors.first { $0.id == id } }
        newDocument(); editorTitle = title
        let references = anchors.map { anchor in
            var link = URLComponents(); link.scheme = "readingbook"; link.host = "book"; link.path = "/\(book.id)/unit/\(anchor.unitID)"
            link.queryItems = [URLQueryItem(name: "quote", value: anchor.quote), URLQueryItem(name: "prefix", value: anchor.prefix), URLQueryItem(name: "suffix", value: anchor.suffix)]
            return "> " + anchor.quote.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n[回到原文](\(link.string ?? ""))"
        }.joined(separator: "\n\n")
        draftEvidence = anchors.map { Evidence(unitID: $0.unitID, quote: $0.quote) }
        editorMarkdown = "# \(title)\n\n\(markdown)\n\n\(references)\n\n## 我的理解\n\n"
    }
    func noteSelectedSource() {
        guard let anchor = selectedSourceAnchor else { readingExperienceError = "请在一个原文片段内选择文字；无法精确定位的公式可先打开对照稿。"; return }
        if !readingExperienceIndex.anchors.contains(where: { $0.id == anchor.id }) { readingExperienceIndex.anchors.append(anchor) }
        newReadingNote(title: "关于\(selectedUnit?.chapter ?? "原文")的理解", markdown: "", anchorIDs: [anchor.id])
    }
    func enhanceCurrentSource() {
        enhanceSourceScope(scope: .page)
    }
    /// Freeze all unit identities before starting. Turning a PDF page changes
    /// the viewport, never the in-flight generation scope or its receipt gate.
    @discardableResult
    func enhanceSourceScope(scope: ReadingQueryScope) -> ReadingQuerySnapshot? {
        guard [.page, .chapter].contains(scope), let initial = book, let unit = selectedUnit, !isBusy else { return nil }
        let snapshot: ReadingQuerySnapshot
        do {
            snapshot = try ReadingQuerySnapshot.freeze(scope: scope, in: initial,
                context: ReadingContext(sourceHash: initial.sourceHash, unitID: unit.id, page: unit.page))
        } catch { readingExperienceError = error.localizedDescription; return nil }
        let allowedIDs = Set(snapshot.unitIDs)
        guard !allowedIDs.isEmpty else { return nil }
        guard !initial.units.contains(where: { allowedIDs.contains($0.id) && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !readerConfirmedBlank($0, in: initial) }) else {
            readingExperienceError = "所选范围仍有未识别的原文，请先完成 OCR 或核对空白页。"; showingOCR = true; return nil
        }
        let actionableIDs = snapshot.unitIDs.filter { id in initial.units.first(where: { $0.id == id }).map { !readerConfirmedBlank($0, in: initial) } ?? false }
        guard !actionableIDs.isEmpty else { readingExperienceError = "这部分已由你对照原书确认为空白，无需生成伴读。"; return nil }
        let unfinished = CompanionScopeProgress.unfinished(for: snapshot, in: initial)
        let progress = unfinished ?? CompanionScopeProgress(scopeFingerprint: snapshot.scopeFingerprint, runID: UUID().uuidString)
        let remainingIDs = actionableIDs.filter { !progress.completedUnitIDs.contains($0) }
        guard remainingIDs.isEmpty || providerReady else { return nil }
        var frozenSettings = settings
        frozenSettings.transportSessionID = "readingbook-\(initial.id)-companion"
        let frozenKey = apiKey
        isBusy = true; readingExperienceError = nil; readingCompanionVisible = true; readingCompanionTab = "companion"
        task = Task {
            let aiRunID = await beginAIProgress(title: "生成伴读 · \(snapshot.displayTitle)")
            defer { finishAIProgress(aiRunID); activeReadingUnitID = nil; isBusy = false }
            do {
                if unfinished == nil {
                    try Task.checkCancellation()
                    guard var starting = book, starting.id == snapshot.bookID, starting.sourceHash == snapshot.sourceHash else { throw CancellationError() }
                    starting.audit.append(try progress.audit("companion_scope_started"))
                    // Persist the run before its first paid request so a restart
                    // can distinguish a continuation from a deliberate refresh.
                    publish(try await repository.save(starting))
                }
                await reader.resetBudget()
                for (index, unitID) in remainingIDs.enumerated() {
                    guard let starting = book, starting.id == snapshot.bookID, starting.sourceHash == snapshot.sourceHash else { throw CancellationError() }
                    let oldAuditIDs = Set(starting.audit.filter { $0.name == "reading_enrich" }.map(\.id))
                    while true {
                        try Task.checkCancellation()
                        guard let current = book, current.id == snapshot.bookID, current.sourceHash == snapshot.sourceHash,
                              let source = current.units.first(where: { $0.id == unitID }) else { throw CancellationError() }
                        activeReadingUnitID = unitID
                        updateAIProgressDetail(aiRunID, detail: source.page.map { "第 \($0) 页" } ?? source.chapter)
                        activity = "正在准备伴读 · \(actionableIDs.count - remainingIDs.count + index + 1)/\(actionableIDs.count) · \(source.locator)"
                        let previousReceipts = try ReadingLedger.receipts(for: source, in: current).count
                        // enrichCurrent first checkpoints bounded paragraph receipts,
                        // and only then permits the real reading_enrich tool write.
                        var result = try await reader.enrichCurrent(project: current, unitID: unitID, settings: frozenSettings, apiKey: frozenKey)
                        try Task.checkCancellation()
                        guard bookID == snapshot.bookID else { throw CancellationError() }
                        let completed = result.audit.contains { $0.name == "reading_enrich" && !oldAuditIDs.contains($0.id) }
                        let receiptCount = try ReadingLedger.receipts(for: source, in: result).count
                        guard completed || receiptCount > previousReceipts else { throw ReadingError.invalid("这部分没有新增核对回执或伴读结果，已停止以避免重复请求。") }
                        if completed { result.audit.append(try progress.audit("companion_scope_checkpoint", unitID: unitID)) }
                        markAIProgressSaving(aiRunID)
                        publish(try await repository.save(result))
                        requestsUsed = await reader.requestCount
                        if completed { break }
                    }
                }
                try Task.checkCancellation()
                guard var finished = book, finished.id == snapshot.bookID, finished.sourceHash == snapshot.sourceHash else { throw CancellationError() }
                finished.audit.append(try progress.audit("companion_scope_finished"))
                publish(try await repository.save(finished))
                activity = "\(snapshot.displayTitle)的伴读已保存，请结合原文核对。"
            } catch { finishAIProgress(aiRunID, error: error); readingExperienceError = error is CancellationError ? nil : error.localizedDescription; handle(error) }
        }
        return snapshot
    }
    private func readerConfirmedBlank(_ unit: SourceUnit, in project: BookProject) -> Bool {
        unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && project.coverage[unit.id]?.status == .completed &&
        project.coverage[unit.id]?.message == "用户确认此单元为原书空白。" &&
        project.insights.contains { $0.id == "blank-\(unit.id)" && $0.unitIDs == [unit.id] && $0.markdown == "用户对照原书确认此单元为空白，无需 AI 提取文字。" }
    }
    func removeReadingItem(_ id: String, kind: String) async {
        guard var current = book, let state = current.readingExperience, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            current.readingExperience = try ReadingExperienceRuntime.trashItem(id: id, kind: kind, state: state)
            current = try await repository.save(current)
            if let focusedReadingAnchorID, state.anchors.contains(where: { $0.id == focusedReadingAnchorID }),
               current.readingExperience?.anchors.contains(where: { $0.id == focusedReadingAnchorID }) != true { self.focusedReadingAnchorID = nil }
            publish(current); activity = "已移入伴读回收站，可在伴读菜单恢复。"
        }
        catch { readingExperienceError = error.localizedDescription }
    }
    func restoreReadingItem(_ id: String) async {
        guard var current = book, let state = current.readingExperience, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do { current.readingExperience = try ReadingExperienceRuntime.restoreTrashedItem(id: id, state: state, in: current); publish(try await repository.save(current)) }
        catch { readingExperienceError = error.localizedDescription }
    }
}
