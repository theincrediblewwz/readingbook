import SwiftUI
import ReadingCore
import os

private let pageEvidenceSignposter = OSSignposter(subsystem: "org.readingbook.app", category: "PageEvidence")

private struct CompanionScopePreparation: Sendable {
    let snapshot: ReadingQuerySnapshot
    let actionableIDs: [String]
    let remainingIDs: [String]
    let progress: CompanionScopeProgress
    let isContinuation: Bool
    let needsOCR: Bool
}

/// Disposable page presentation only. Canonical anchors and evidence stay in
/// the book; neither a receipt update nor another page invalidates this key.
@MainActor final class ReadingPageSnapshotCache {
    struct ObjectInput: Hashable, Sendable {
        let id: String; let names: [String]; let evidence: [Evidence]; let event: Bool
    }
    struct Input: Hashable, Sendable {
        let owner: String; let units: [SourceUnit]; let objects: [ObjectInput]
        let anchors: [SourceAnchor]; let mentions: [SourceMention]; let literalBytes: [Data]
        let markdownUnitIDs: Set<String>
        let sourceUnitsAreUnique: Bool
    }
    struct Snapshot: Sendable {
        let key: Int
        let input: Input
        let index: ReadingExperienceState
        let decorations: [SourceReadingDecoration]
        let sourceStamp: LibraryPublicationStamp?
        let pageSourceText: PDFPageSourceText?
        /// Conservative history-cache charge, not an RSS measurement. Shared
        /// strings may be counted twice; active pages are outside this budget.
        let estimatedRetainedCost: Int
    }
    struct Request: Sendable {
        let project: BookProject; let selectedUnitID: String?; let owner: String; let scope: String; let visiblePages: [Int]
        let revision: Int
    }
    struct Prepared: Sendable {
        let snapshots: [Snapshot]; let selected: Snapshot; let base: ReadingExperienceState
        let index: ReadingExperienceState; let changed: Bool; let decorationsChanged: Bool
        let unitIndices: [String: Int]; let pageIndices: [Int: [Int]]
        let boundariesByPage: [Int: KnowledgeReadBoundary]
        let currentBoundary: KnowledgeReadBoundary?
        let anchorsByID: [String: SourceAnchor]
    }
    var pendingScope: String?
    var pendingRevision: Int?
    var queued: Request?
    var current: Snapshot?
    var currentBase: ReadingExperienceState?
    // The worker computes this small key. Hashing Input (which includes source
    // bytes) or comparing full snapshots never happens during publication.
    var entries: [Int: Snapshot] = [:]
    var order: [Int] = []
    private var historyEstimatedCost = 0
    private static let historyCostLimit = 24 * 1_024 * 1_024
    var window: [Snapshot] = []
    var presentationRevision = 0
    var visiblePDFPages: [Int] = []
    var unitIndices: [String: Int] = [:]
    var pageIndices: [Int: [Int]] = [:]
    var boundariesByPage: [Int: KnowledgeReadBoundary] = [:]
    var currentBoundary: KnowledgeReadBoundary?
    var anchorsByID: [String: SourceAnchor] = [:]
    func reset() {
        pendingScope = nil; pendingRevision = nil; queued = nil; current = nil; currentBase = nil; entries = [:]; order = []
        historyEstimatedCost = 0
        window = []; presentationRevision &+= 1; visiblePDFPages = []; unitIndices = [:]; pageIndices = [:]; boundariesByPage = [:]
        currentBoundary = nil; anchorsByID = [:]
    }
    func remember(_ value: Snapshot) {
        if let old = entries.removeValue(forKey: value.key) { historyEstimatedCost -= old.estimatedRetainedCost }
        order.removeAll { $0 == value.key }
        // Oversized current/window snapshots still publish normally. Only the
        // optional history is skipped; no source text or marks are discarded.
        guard value.estimatedRetainedCost <= Self.historyCostLimit else { return }
        entries[value.key] = value; order.append(value.key)
        // Both operands are bounded by historyCostLimit before this addition.
        historyEstimatedCost += value.estimatedRetainedCost
        while order.count > 24 || historyEstimatedCost > Self.historyCostLimit {
            if let removed = entries.removeValue(forKey: order.removeFirst()) { historyEstimatedCost -= removed.estimatedRetainedCost }
        }
    }
    nonisolated static func prepare(_ request: Request, entries: [Int: Snapshot], current: Snapshot?, currentWindow: [Snapshot] = [], previousBase: ReadingExperienceState?, previousDecorations: [[SourceReadingDecoration]] = [], includeWindow: Bool = true) -> Prepared? {
        let book = request.project
        // These pages are already retained for display. Reuse them on exact
        // input equality even when an oversized page is not admitted to history.
        // Keys only narrow candidates; they never authorize a source match.
        let activeByKey = Dictionary(grouping: currentWindow + (current.map { [$0] } ?? []), by: \.key)
        var unitIndices: [String: Int] = [:], pageIndices: [Int: [Int]] = [:]
        var duplicateUnitIDs = Set<String>()
        for (index, unit) in book.units.enumerated() {
            guard !Task.isCancelled else { return nil }
            if unitIndices.updateValue(index, forKey: unit.id) != nil { duplicateUnitIDs.insert(unit.id) }
            if let page = unit.page { pageIndices[page, default: []].append(index) }
        }
        guard !Task.isCancelled, let position = request.selectedUnitID.flatMap({ unitIndices[$0] }) else { return nil }
        let selectedUnit = book.units[position], base = book.readingExperience ?? ReadingExperienceState()
        let pages = selectedUnit.page.map { includeWindow ? ReadingSentenceAnchors.pageWindow(current: $0, visible: request.visiblePages, available: Set(pageIndices.keys)) : [$0] } ?? []
        let groups = pages.isEmpty ? [[selectedUnit]] : pages.map { (pageIndices[$0] ?? []).map { book.units[$0] } }
        var anchorsByUnit: [String: [SourceAnchor]] = [:], mentionsByAnchor: [String: [SourceMention]] = [:]
        for anchor in base.anchors {
            guard !Task.isCancelled else { return nil }
            anchorsByUnit[anchor.unitID, default: []].append(anchor)
        }
        for mention in base.mentions {
            guard !Task.isCancelled else { return nil }
            mentionsByAnchor[mention.anchorID, default: []].append(mention)
        }
        var snapshots: [Snapshot] = [], boundaries: [Int: KnowledgeReadBoundary] = [:]
        for units in groups {
            guard !Task.isCancelled else { return nil }
            let unitIDs = Set(units.map(\.id))
            if let page = units.first?.page, let last = units.max(by: { $0.order < $1.order }) {
                boundaries[page] = try? KnowledgeReadBoundary.throughSourceUnit(last.id, in: book)
            }
            let anchors = units.flatMap { anchorsByUnit[$0.id] ?? [] }
            var objects: [ObjectInput] = []
            func localEvidence(_ values: [Evidence]) -> [Evidence]? {
                var result: [Evidence] = []
                for item in values {
                    guard !Task.isCancelled else { return nil }
                    if unitIDs.contains(item.unitID) { result.append(item) }
                }
                return result
            }
            for object in book.entities {
                guard !Task.isCancelled, let evidence = localEvidence(object.evidence) else { return nil }
                if !evidence.isEmpty { objects.append(.init(id: object.id, names: [object.name] + object.aliases, evidence: evidence, event: false)) }
            }
            for object in book.events {
                guard !Task.isCancelled, let evidence = localEvidence(object.evidence) else { return nil }
                if !evidence.isEmpty { objects.append(.init(id: object.id, names: [object.name], evidence: evidence, event: true)) }
            }
            var literalBytes: [Data] = []
            for unit in units {
                guard !Task.isCancelled else { return nil }
                literalBytes.append(Data(unit.text.utf8)); literalBytes.append(Data(unit.chapter.utf8))
            }
            for object in objects {
                for name in object.names {
                    guard !Task.isCancelled else { return nil }; literalBytes.append(Data(name.utf8))
                }
                for item in object.evidence {
                    guard !Task.isCancelled else { return nil }; literalBytes.append(Data(item.quote.utf8))
                }
            }
            for anchor in anchors {
                guard !Task.isCancelled else { return nil }
                literalBytes.append(contentsOf: [Data(anchor.quote.utf8), Data(anchor.prefix.utf8), Data(anchor.suffix.utf8)])
            }
            let input = Input(owner: request.owner, units: units, objects: objects, anchors: anchors,
                mentions: anchors.flatMap { mentionsByAnchor[$0.id] ?? [] },
                literalBytes: literalBytes, markdownUnitIDs: Set(units.filter {
                    ReadingSentenceAnchors.syntax(for: $0, in: book) == .markdown
                }.map(\.id)), sourceUnitsAreUnique: units.allSatisfy { !duplicateUnitIDs.contains($0.id) })
            guard !Task.isCancelled else { return nil }
            var hasher = Hasher(); input.hash(into: &hasher); let key = hasher.finalize()
            // Exact equality on the worker protects against a compact-key
            // collision; literalBytes also rejects Unicode-normalized matches.
            guard !Task.isCancelled else { return nil }
            var reusable: Snapshot?
            if let saved = entries[key], saved.input == input { reusable = saved }
            if reusable == nil {
                for saved in activeByKey[key] ?? [] {
                    guard !Task.isCancelled else { return nil }
                    if saved.input == input { reusable = saved; break }
                }
            }
            if let saved = reusable {
                snapshots.append(Snapshot(key: saved.key, input: saved.input, index: saved.index, decorations: saved.decorations,
                    sourceStamp: book.publicationStamp, pageSourceText: saved.pageSourceText, estimatedRetainedCost: saved.estimatedRetainedCost))
            } else {
                guard let snapshot = build(input, key: key, project: book) else { return nil }
                snapshots.append(snapshot)
            }
        }
        guard !Task.isCancelled, let selected = snapshots.first(where: { $0.input.units.contains(where: { $0.id == selectedUnit.id }) }) else { return nil }
        var index = base
        var anchorIDs = Set(base.anchors.map(\.id)), mentionIDs = Set(base.mentions.map(\.id))
        for snapshot in snapshots {
            for anchor in snapshot.index.anchors {
                guard !Task.isCancelled else { return nil }
                if anchorIDs.insert(anchor.id).inserted { index.anchors.append(anchor) }
            }
            for mention in snapshot.index.mentions {
                guard !Task.isCancelled else { return nil }
                if mentionIDs.insert(mention.id).inserted { index.mentions.append(mention) }
            }
        }
        let changed = current?.input != selected.input || previousBase != base || current?.index != selected.index
        let decorationsChanged = previousDecorations.flatMap { $0 } != snapshots.flatMap(\.decorations)
        return Prepared(snapshots: snapshots, selected: selected, base: base, index: index, changed: changed, decorationsChanged: decorationsChanged,
            unitIndices: unitIndices, pageIndices: pageIndices, boundariesByPage: boundaries,
            currentBoundary: selectedUnit.page.flatMap { boundaries[$0] } ?? (try? KnowledgeReadBoundary.throughSourceUnit(selectedUnit.id, in: book)),
            anchorsByID: Dictionary(index.anchors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }
    nonisolated static func build(_ input: Input, key: Int, project: BookProject) -> Snapshot? {
        let interval = pageEvidenceSignposter.beginInterval("BuildPageSnapshot")
        defer { pageEvidenceSignposter.endInterval("BuildPageSnapshot", interval) }
        guard !Task.isCancelled else { return nil }
        var compact = project; compact.units = input.units
        compact.entities = input.objects.filter { !$0.event }.map {
            KnowledgeEntity(id: $0.id, typeID: "snapshot", name: $0.names.first ?? "", aliases: Array($0.names.dropFirst()), evidence: $0.evidence)
        }
        compact.events = input.objects.filter(\.event).map { KnowledgeEvent(id: $0.id, name: $0.names.first ?? "", evidence: $0.evidence) }
        let initial = ReadingExperienceState(anchors: input.anchors, mentions: input.mentions)
        guard input.sourceUnitsAreUnique else {
            // A page-local compact project cannot prove a globally duplicated
            // source ID. Keep the stored records; do not guess automatic marks.
            return makeSnapshot(input, key: key, index: initial, decorations: [],
                sourceStamp: project.publicationStamp, pageSourceText: nil)
        }
        var index = ReadingExperienceRuntime.indexEvidence(in: compact, state: initial, unitIDs: Set(input.units.map(\.id)))
        guard !Task.isCancelled else { return nil }
        var existing = Set(index.anchors.map(\.id)), candidates = Set<String>()
        for unit in input.units {
            guard !Task.isCancelled else { return nil }
            for anchor in ReadingSentenceAnchors.anchors(in: unit, project: compact) where existing.insert(anchor.id).inserted {
                index.anchors.append(anchor); candidates.insert(anchor.id)
            }
        }
        var offsets: [String: Int] = [:], offset = 0
        for unit in input.units {
            guard !Task.isCancelled else { return nil }
            offsets[unit.id] = offset; offset += (unit.text as NSString).length
        }
        let mentions = Dictionary(grouping: index.mentions, by: \.anchorID)
        let units = Dictionary(input.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var structuralBoundaries: [String: ReadingPassageBoundaryIndex] = [:]
        for unit in units.values {
            guard !Task.isCancelled else { return nil }
            structuralBoundaries[unit.id] = ReadingSentenceAnchors.boundaryIndex(in: unit.text, chapterTitle: unit.chapter,
                syntax: ReadingSentenceAnchors.syntax(for: unit, in: project))
        }
        let storedIDs = Set(input.anchors.map(\.id))
        var resolvers: [String: (SourceAnchor) throws -> ResolvedSourceAnchor] = [:]
        var unavailableUnits = Set<String>()
        let decorations = index.anchors.compactMap { anchor -> SourceReadingDecoration? in
            guard !Task.isCancelled, let start = offsets[anchor.unitID] else { return nil }
            let range: NSRange
            if storedIDs.contains(anchor.id) {
                // A repository stamp identifies a frozen publication; it is
                // not proof that a hand-edited stored anchor is still valid.
                // Resolve canonical records including dual-nil legacy ranges.
                guard !unavailableUnits.contains(anchor.unitID) else { return nil }
                if resolvers[anchor.unitID] == nil {
                    guard let resolver = try? ReadingExperienceRuntime.anchorResolver(sourceHash: project.sourceHash, unitID: anchor.unitID, in: project) else {
                        unavailableUnits.insert(anchor.unitID); return nil
                    }
                    resolvers[anchor.unitID] = resolver
                }
                guard let resolver = resolvers[anchor.unitID], let resolved = try? resolver(anchor) else { return nil }
                range = resolved.range
            } else {
                // New evidence/sentence anchors came from this build's host
                // factories and already passed the exact source checks.
                guard let location = anchor.utf16Location, let length = anchor.utf16Length else { return nil }
                range = NSRange(location: location, length: length)
            }
            let isTerm = mentions[anchor.id]?.isEmpty == false
            guard isTerm || structuralBoundaries[anchor.unitID]?.crossesStructuralBoundary(range) == false else { return nil }
            return SourceReadingDecoration(id: anchor.id, targetID: mentions[anchor.id]?.first?.targetID ?? anchor.id, quote: anchor.quote,
                rangeLocation: start + range.location, rangeLength: range.length, prefix: anchor.prefix, suffix: anchor.suffix,
                interaction: mentions[anchor.id]?.isEmpty == false ? .term : .passage,
                page: units[anchor.unitID]?.page, passive: candidates.contains(anchor.id))
        }
        // prepare groups every canonical unit of one PDF page in book order.
        // This immutable proof is constructed once on the worker, never in a
        // View getter or per native quote lookup.
        let pageSourceText: PDFPageSourceText?
        guard !Task.isCancelled else { return nil }
        if !Task.isCancelled, let page = input.units.first?.page,
           input.units.allSatisfy({ $0.page == page }) {
            pageSourceText = try? PDFPageSourceText(page: page, text: input.units.map(\.text).joined())
        } else { pageSourceText = nil }
        return makeSnapshot(input, key: key, index: index, decorations: decorations,
            sourceStamp: project.publicationStamp, pageSourceText: pageSourceText)
    }
    /// Computed once when the worker builds a snapshot, never in remember or a
    /// View getter. This bounds historical payload estimates, not App memory:
    /// live windows, canonical books and in-flight work retain their own values.
    nonisolated private static func makeSnapshot(_ input: Input, key: Int, index: ReadingExperienceState,
                                                decorations: [SourceReadingDecoration], sourceStamp: LibraryPublicationStamp?,
                                                pageSourceText: PDFPageSourceText?) -> Snapshot? {
        var cost = MemoryLayout<Snapshot>.stride
        func add(_ bytes: Int) {
            let (sum, overflow) = cost.addingReportingOverflow(bytes)
            cost = overflow ? Int.max : sum
        }
        func storage(_ count: Int, _ stride: Int) {
            let (bytes, overflow) = count.multipliedReportingOverflow(by: stride)
            add(overflow ? Int.max : bytes)
        }
        func text(_ value: String) { add(value.utf8.count); add(32) }
        func anchor(_ value: SourceAnchor) {
            text(value.id); text(value.sourceHash); text(value.unitID); text(value.unitTextHash)
            text(value.quote); text(value.prefix); text(value.suffix)
        }
        func mention(_ value: SourceMention) { text(value.anchorID); text(value.targetID) }
        text(input.owner)
        storage(input.units.count, MemoryLayout<SourceUnit>.stride)
        for unit in input.units {
            guard !Task.isCancelled else { return nil }
            text(unit.id); text(unit.chapter); text(unit.text)
            if let warning = unit.warning { text(warning) }
        }
        storage(input.objects.count, MemoryLayout<ObjectInput>.stride)
        for object in input.objects {
            guard !Task.isCancelled else { return nil }
            text(object.id); storage(object.names.count, MemoryLayout<String>.stride)
            for name in object.names { guard !Task.isCancelled else { return nil }; text(name) }
            storage(object.evidence.count, MemoryLayout<Evidence>.stride)
            for item in object.evidence { guard !Task.isCancelled else { return nil }; text(item.unitID); text(item.quote) }
        }
        storage(input.literalBytes.count, MemoryLayout<Data>.stride)
        for bytes in input.literalBytes { guard !Task.isCancelled else { return nil }; add(bytes.count); add(32) }
        storage(input.markdownUnitIDs.count, MemoryLayout<String>.stride + 32)
        for id in input.markdownUnitIDs { guard !Task.isCancelled else { return nil }; text(id) }
        storage(input.anchors.count, MemoryLayout<SourceAnchor>.stride)
        for value in input.anchors { guard !Task.isCancelled else { return nil }; anchor(value) }
        storage(input.mentions.count, MemoryLayout<SourceMention>.stride)
        for value in input.mentions { guard !Task.isCancelled else { return nil }; mention(value) }
        // This page-only index contains anchors/mentions, not layer bodies or
        // whole-book analyses. Count shared source strings conservatively again.
        storage(index.anchors.count, MemoryLayout<SourceAnchor>.stride)
        for value in index.anchors { guard !Task.isCancelled else { return nil }; anchor(value) }
        storage(index.mentions.count, MemoryLayout<SourceMention>.stride)
        for value in index.mentions { guard !Task.isCancelled else { return nil }; mention(value) }
        storage(decorations.count, MemoryLayout<SourceReadingDecoration>.stride)
        for value in decorations {
            guard !Task.isCancelled else { return nil }
            text(value.id); text(value.targetID); text(value.quote)
            if let prefix = value.prefix { text(prefix) }
            if let suffix = value.suffix { text(suffix) }
        }
        if let source = pageSourceText { text(source.text); text(source.identity) }
        guard !Task.isCancelled else { return nil }
        return Snapshot(key: key, input: input, index: index, decorations: decorations,
            sourceStamp: sourceStamp, pageSourceText: pageSourceText, estimatedRetainedCost: cost)
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
        let request = ReadingPageSnapshotCache.Request(project: book, selectedUnitID: selectedUnitID, owner: owner, scope: scope, visiblePages: visible,
                                                      revision: projectRevision)
        if readingPageSnapshots.pendingScope == scope {
            // Repeated layout/visibility notifications for the same publication
            // do not need a second calculation. Keep only the newest real edit.
            if readingPageSnapshots.pendingRevision != request.revision {
                readingPageSnapshots.pendingRevision = request.revision; readingPageSnapshots.queued = request
            }
            return
        }
        readingIndexTask?.cancel(); readingIndexGeneration &+= 1
        readingPageSnapshots.pendingScope = scope; readingPageSnapshots.pendingRevision = request.revision; readingPageSnapshots.queued = nil
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
                let currentWindow = self.readingPageSnapshots.window
                let previousDecorations = currentWindow.map(\.decorations)
                let calculation = Task.detached(priority: .userInitiated) {
                    ReadingPageSnapshotCache.prepare(frozen, entries: entries, current: current, currentWindow: currentWindow, previousBase: base, previousDecorations: previousDecorations, includeWindow: includeWindow)
                }
                let prepared = await withTaskCancellationHandler(operation: { await calculation.value }, onCancel: { calculation.cancel() })
                guard !Task.isCancelled, self.readingIndexGeneration == generation, self.bookID == book.id,
                      self.readingPageSnapshots.pendingScope == scope,
                      self.libraryRootURL.path + "|" + book.id + "|" + (self.book?.sourceHash ?? "") == owner else { return }
                // An edit can arrive without changing page, source text or
                // scope. Never republish that edit's old mentions/layers. Keep
                // the exact-input page cache, then calculate the newest request
                // immediately; do not restart cold on every AI publication.
                if let prepared { for snapshot in prepared.snapshots { self.readingPageSnapshots.remember(snapshot) } }
                guard self.readingPageSnapshots.pendingRevision == frozen.revision else { break }
                if let prepared {
                    self.readingPageSnapshots.unitIndices = prepared.unitIndices; self.readingPageSnapshots.pageIndices = prepared.pageIndices
                    self.readingPageSnapshots.boundariesByPage = prepared.boundariesByPage
                    self.readingPageSnapshots.currentBoundary = prepared.currentBoundary; self.readingPageSnapshots.anchorsByID = prepared.anchorsByID
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
                        }
                        if prepared.decorationsChanged { self.readingPageSnapshots.presentationRevision &+= 1 }
                    }
                }
                }
                if let queued = self.readingPageSnapshots.queued { self.readingPageSnapshots.queued = nil; next = queued; continue }
                self.readingPageSnapshots.pendingScope = nil; self.readingPageSnapshots.pendingRevision = nil; self.readingIndexTask = nil; break
            }
        }
    }
    var currentReadingContext: ReadingContext {
        let object = selectedObjectID.flatMap { id in
            book?.entities.contains { $0.id == id } == true || book?.events.contains { $0.id == id } == true ? id : nil
        }
        let anchor = focusedReadingSourceAnchor
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
    var focusedReadingSourceAnchor: SourceAnchor? {
        guard let book, let id = focusedReadingAnchorID,
              let anchor = readingPageSnapshots.anchorsByID[id] ?? readingExperienceIndex.anchors.first(where: { $0.id == id }),
              anchor.sourceHash == book.sourceHash else { return nil }
        return anchor
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
              snapshot.input.units.contains(where: { $0.id == selectedUnitID }),
              readingSnapshotIsCurrent(snapshot, in: book) else { return [] }
        let units = visibleSourceUnits
        var values = snapshot.decorations
        // Explicit citation navigation may add one transient anchor. Resolve
        // that single focus, rather than revalidating every mark in View.body.
        if let id = focusedReadingAnchorID, !values.contains(where: { $0.id == id }),
           let anchor = readingExperienceIndex.anchors.first(where: { $0.id == id }),
           let unit = units.first(where: { $0.id == anchor.unitID }) {
            if let resolved = try? ReadingExperienceRuntime.resolve(anchor, in: book) {
                let start = units.prefix { $0.id != unit.id }.reduce(0) { $0 + ($1.text as NSString).length }
                values.append(SourceReadingDecoration(id: anchor.id, targetID: id, quote: anchor.quote, rangeLocation: start + resolved.utf16Location,
                    rangeLength: resolved.utf16Length, prefix: anchor.prefix, suffix: anchor.suffix))
            }
        }
        return values
    }
    var pdfSourceReadingDecorationRevision: Int { readingPageSnapshots.presentationRevision }
    private func readingSnapshotIsCurrent(_ snapshot: ReadingPageSnapshotCache.Snapshot, in book: BookProject) -> Bool {
        guard snapshot.input.owner == libraryRootURL.path + "|" + book.id + "|" + book.sourceHash else { return false }
        if let current = book.publicationStamp, snapshot.sourceStamp == current { return true }
        // A note/AI publication changes the general stamp without necessarily
        // changing source text. Preserve existing marks via exact source bytes
        // while the worker prepares its next stamp. Nil never proves equality.
        let ids = Set(snapshot.input.units.map(\.id)), page = snapshot.input.units.first?.page
        var currentUnits: [SourceUnit] = [], seen = Set<String>()
        for unit in book.units {
            if ids.contains(unit.id), !seen.insert(unit.id).inserted { return false }
            if let page {
                if unit.page == page { currentUnits.append(unit) }
            } else if ids.contains(unit.id) { currentUnits.append(unit) }
        }
        return currentUnits.count == snapshot.input.units.count && zip(snapshot.input.units, currentUnits).allSatisfy {
            $0.id == $1.id && $0.page == $1.page && $0.text.utf8.elementsEqual($1.text.utf8) && $0.chapter.utf8.elementsEqual($1.chapter.utf8) &&
                snapshot.input.markdownUnitIDs.contains($1.id) == (ReadingSentenceAnchors.syntax(for: $1, in: book) == .markdown)
        }
    }
    var pdfSourcePageTexts: [Int: PDFPageSourceText] {
        guard let book else { return [:] }
        guard let stamp = book.publicationStamp else { return [:] }
        var result: [Int: PDFPageSourceText] = [:]
        let owner = libraryRootURL.path + "|" + book.id + "|" + book.sourceHash
        for snapshot in readingPageSnapshots.window where snapshot.input.owner == owner && snapshot.sourceStamp == stamp {
            if let value = snapshot.pageSourceText { result[value.page] = value }
        }
        return result
    }
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
        let cache = readingPageSnapshots
        var values = cache.window.flatMap { snapshot -> [SourceReadingDecoration] in
            guard readingSnapshotIsCurrent(snapshot, in: book) else { return [] }
            return snapshot.decorations
        }
        if let id = focusedReadingAnchorID, !values.contains(where: { $0.id == id }),
           let anchor = readingExperienceIndex.anchors.first(where: { $0.id == id }),
           let unit = book.units.first(where: { $0.id == anchor.unitID }), let page = unit.page,
           let resolved = try? ReadingExperienceRuntime.resolve(anchor, in: book) {
            let pageUnits = book.units.filter { $0.page == page }
            let start = pageUnits.prefix { $0.id != unit.id }.reduce(0) { $0 + ($1.text as NSString).length }
            values.append(SourceReadingDecoration(id: anchor.id, targetID: id, quote: anchor.quote,
                rangeLocation: start + resolved.utf16Location, rangeLength: resolved.utf16Length,
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
    /// Opening a conversation is an explicit selection of the card's original
    /// anchor, not a request to read whichever native selection remains behind
    /// the popup. No anchor or chat is persisted merely by opening this panel.
    @discardableResult
    func openReadingConversation(anchor: SourceAnchor, objectID: String?, question: String) -> Bool {
        guard let book, !storageState.working,
              (try? ReadingExperienceRuntime.resolve(anchor, in: book)) != nil else {
            readingExperienceError = "这句话的原文位置已变化，请重新悬停后再聊。"; return false
        }
        sourceReadingSelection = nil; readingContextDocumentID = nil
        if let position = readingExperienceIndex.anchors.firstIndex(where: { $0.id == anchor.id }) {
            readingExperienceIndex.anchors[position] = anchor
        } else { readingExperienceIndex.anchors.append(anchor) }
        readingPageSnapshots.anchorsByID[anchor.id] = anchor
        selectedObjectID = objectID.flatMap { id in
            book.entities.contains(where: { $0.id == id }) || book.events.contains(where: { $0.id == id }) ? id : nil
        }
        focusedReadingAnchorID = anchor.id
        queryScope = .selection; readingCompanionVisible = true; readingCompanionTab = "chat"
        queryComposerDraft.text = question
        return true
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
        Task { _ = await enhanceSourceScope(scope: .page) }
    }
    /// Freeze all unit identities before starting. Turning a PDF page changes
    /// the viewport, never the in-flight generation scope or its receipt gate.
    @discardableResult
    func enhanceSourceScope(scope: ReadingQueryScope) async -> ReadingQuerySnapshot? {
        guard !Task.isCancelled, [.page, .chapter].contains(scope), let initial = book, let unit = selectedUnit, !isBusy else { return nil }
        let root = libraryRootURL, runID = UUID(), ownerRepository = repository
        var context = ReadingContext(sourceHash: initial.sourceHash, unitID: unit.id, page: unit.page)
        if scope == .chapter { context.selectedSourceAnchor = chapterReadingAnchor(in: initial, unitID: unit.id) }
        let frozenContext = context
        var frozenSettings = settings
        frozenSettings.transportSessionID = "readingbook-\(initial.id)-companion"
        let frozenKey = apiKey
        companionScopeRunID = runID
        isBusy = true; readingExperienceError = nil; readingCompanionVisible = true; readingCompanionTab = "companion"
        activity = "正在准备伴读范围…"
        return await withCheckedContinuation { continuation in
        task = Task {
            var returnedScope = false
            let aiRunID = await beginAIProgress(title: "准备伴读范围")
            defer {
                if !returnedScope { continuation.resume(returning: nil) }
                finishAIProgress(aiRunID)
                if companionScopeRunID == runID { activeReadingUnitID = nil; isBusy = false; task = nil; companionScopeRunID = nil }
            }
            do {
                try Task.checkCancellation()
                var current = initial
                if scope == .chapter { current = try await ensureBookChapterOutline(project: initial) }
                try Task.checkCancellation()
                guard companionScopeRunID == runID, bookID == initial.id, libraryRootURL == root,
                      book?.sourceHash == initial.sourceHash else { throw CancellationError() }
                let preparationProject = current
                let worker = Task.detached(priority: .userInitiated) {
                    let snapshot = try ReadingQuerySnapshot.freeze(scope: scope, in: preparationProject, context: frozenContext)
                    let byID = Dictionary(preparationProject.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    var actionable: [String] = [], needsOCR = false
                    for id in snapshot.unitIDs {
                        try Task.checkCancellation()
                        guard let source = byID[id] else { throw ReadingError.invalid("伴读原文位置已变化。") }
                        if SmartReadingRuntime.isConfirmedBlank(source, in: preparationProject) { continue }
                        if source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { needsOCR = true }
                        actionable.append(id)
                    }
                    let unfinished = CompanionScopeProgress.unfinished(for: snapshot, in: preparationProject)
                    let progress = unfinished ?? CompanionScopeProgress(scopeFingerprint: snapshot.scopeFingerprint, runID: UUID().uuidString)
                    return CompanionScopePreparation(snapshot: snapshot, actionableIDs: actionable,
                        remainingIDs: actionable.filter { !progress.completedUnitIDs.contains($0) }, progress: progress,
                        isContinuation: unfinished != nil, needsOCR: needsOCR)
                }
                let prepared = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard companionScopeRunID == runID, bookID == initial.id, libraryRootURL == root,
                      let latest = book, latest.sourceHash == initial.sourceHash else { throw CancellationError() }
                let validator = Task.detached(priority: .userInitiated) { _ = try prepared.snapshot.sourceRanges(in: latest) }
                try await withTaskCancellationHandler(operation: { try await validator.value }, onCancel: { validator.cancel() })
                try Task.checkCancellation()
                guard companionScopeRunID == runID, bookID == initial.id, libraryRootURL == root,
                      book?.sourceHash == initial.sourceHash else { throw CancellationError() }
                guard !prepared.needsOCR else {
                    readingExperienceError = "所选范围仍有未识别的原文，请先完成 OCR 或核对空白页。"; showingOCR = true; return
                }
                let snapshot = prepared.snapshot, actionableIDs = prepared.actionableIDs, remainingIDs = prepared.remainingIDs, progress = prepared.progress
                guard !actionableIDs.isEmpty else { readingExperienceError = "这部分已由你对照原书确认为空白，无需生成伴读。"; return }
                guard remainingIDs.isEmpty || providerReady else { return }
                returnedScope = true; continuation.resume(returning: snapshot)
                if aiProgress.runID == aiRunID { aiProgress.title = "生成伴读 · " + snapshot.displayTitle }
                updateAIProgressDetail(aiRunID, detail: snapshot.displayTitle)
                if !prepared.isContinuation {
                    try Task.checkCancellation()
                    guard companionScopeRunID == runID, libraryRootURL == root, var starting = book,
                          starting.id == snapshot.bookID, starting.sourceHash == snapshot.sourceHash else { throw CancellationError() }
                    let before = starting
                    starting.audit.append(try progress.audit("companion_scope_started"))
                    // Persist the run before its first paid request so a restart
                    // can distinguish a continuation from a deliberate refresh.
                    let saved = try await ownerRepository.commitAIResult(base: before, result: starting, operationID: "companion-scope-start-" + progress.runID)
                    guard companionScopeRunID == runID, libraryRootURL == root, bookID == snapshot.bookID else { throw CancellationError() }
                    publish(saved)
                }
                await reader.resetBudget()
                for (index, unitID) in remainingIDs.enumerated() {
                    guard companionScopeRunID == runID, libraryRootURL == root, let starting = book,
                          starting.id == snapshot.bookID, starting.sourceHash == snapshot.sourceHash else { throw CancellationError() }
                    let oldAuditIDs = Set(starting.audit.filter { $0.name == "reading_enrich" }.map(\.id))
                    while true {
                        try Task.checkCancellation()
                        guard companionScopeRunID == runID, libraryRootURL == root, let current = book,
                              current.id == snapshot.bookID, current.sourceHash == snapshot.sourceHash,
                              let source = current.units.first(where: { $0.id == unitID }) else { throw CancellationError() }
                        activeReadingUnitID = unitID
                        updateAIProgressDetail(aiRunID, detail: source.page.map { "第 \($0) 页" } ?? source.chapter)
                        activity = "正在准备伴读 · \(actionableIDs.count - remainingIDs.count + index + 1)/\(actionableIDs.count) · \(source.locator)"
                        let previousReceipts = try ReadingLedger.receipts(for: source, in: current).count
                        let checker = Task.detached(priority: .userInitiated) {
                            try snapshot.sourceRanges(in: current, unitIDs: [unitID])
                        }
                        let ranges = try await withTaskCancellationHandler(operation: { try await checker.value }, onCancel: { checker.cancel() })
                        let wholeUnit = ranges.count == 1 && ranges[0].startUTF16 == 0 && ranges[0].endUTF16 == source.text.utf16.count
                        // Whole units keep the existing bounded receipt path.
                        // A unit shared by chapters uses the host's exact slice
                        // capability instead of widening a chapter to the page.
                        var result = try await reader.enrichCurrent(project: current, unitID: unitID, settings: frozenSettings, apiKey: frozenKey,
                            sourceRanges: wholeUnit ? nil : ranges)
                        try Task.checkCancellation()
                        guard companionScopeRunID == runID, libraryRootURL == root, bookID == snapshot.bookID else { throw CancellationError() }
                        let completed = result.audit.contains { $0.name == "reading_enrich" && !oldAuditIDs.contains($0.id) }
                        let receiptCount = try ReadingLedger.receipts(for: source, in: result).count
                        guard completed || receiptCount > previousReceipts else { throw ReadingError.invalid("这部分没有新增核对回执或伴读结果，已停止以避免重复请求。") }
                        if completed { result.audit.append(try progress.audit("companion_scope_checkpoint", unitID: unitID)) }
                        markAIProgressSaving(aiRunID)
                        let saved = try await ownerRepository.commitAIResult(base: current, result: result, operationID: "companion-batch-" + UUID().uuidString)
                        guard companionScopeRunID == runID, libraryRootURL == root, bookID == snapshot.bookID else { throw CancellationError() }
                        publish(saved)
                        requestsUsed = await reader.requestCount
                        if completed { break }
                    }
                }
                try Task.checkCancellation()
                guard companionScopeRunID == runID, libraryRootURL == root, var finished = book,
                      finished.id == snapshot.bookID, finished.sourceHash == snapshot.sourceHash else { throw CancellationError() }
                let before = finished
                finished.audit.append(try progress.audit("companion_scope_finished"))
                let saved = try await ownerRepository.commitAIResult(base: before, result: finished, operationID: "companion-scope-finish-" + progress.runID)
                guard companionScopeRunID == runID, libraryRootURL == root, bookID == snapshot.bookID else { throw CancellationError() }
                publish(saved)
                activity = "\(snapshot.displayTitle)的伴读已保存，请结合原文核对。"
            } catch {
                finishAIProgress(aiRunID, error: error)
                guard companionScopeRunID == runID, bookID == initial.id, libraryRootURL == root else { return }
                readingExperienceError = error is CancellationError ? nil : error.localizedDescription; handle(error)
            }
        }
        }
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
