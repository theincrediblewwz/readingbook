import SwiftUI
import ReadingCore
import os

private let pageEvidenceSignposter = OSSignposter(subsystem: "org.readingbook.app", category: "PageEvidence")

/// Disposable page presentation only. Canonical anchors and evidence stay in
/// the book; neither a receipt update nor another page invalidates this key.
@MainActor final class ReadingPageSnapshotCache {
    struct ObjectInput: Hashable, Sendable {
        let id: String
        let names: [String]
        let evidence: [Evidence]
        let event: Bool
    }
    struct Input: Hashable, Sendable {
        let owner: String
        let units: [SourceUnit]
        let objects: [ObjectInput]
        let anchors: [SourceAnchor]
        let mentions: [SourceMention]
        // String equality normalizes Unicode. A cache must also distinguish
        // literal imported bytes, as the anchor validator does.
        let literalBytes: [Data]
    }
    struct Snapshot: Sendable {
        let input: Input
        let index: ReadingExperienceState
        let decorations: [SourceReadingDecoration]
    }
    struct Request: Sendable {
        let project: BookProject
        let selectedUnitID: String?
        let owner: String
        let scope: String
    }
    struct Prepared: Sendable {
        let snapshot: Snapshot
        let base: ReadingExperienceState
        let index: ReadingExperienceState
        let changed: Bool
    }
    var pendingScope: String?
    var queued: Request?
    var current: Snapshot?
    var currentBase: ReadingExperienceState?
    var entries: [Input: Snapshot] = [:]
    var order: [Input] = []
    func reset() { pendingScope = nil; queued = nil; current = nil; currentBase = nil; entries = [:]; order = [] }
    func remember(_ value: Snapshot) {
        entries[value.input] = value; order.removeAll { $0 == value.input }; order.append(value.input)
        while order.count > 6 { entries.removeValue(forKey: order.removeFirst()) }
    }
    nonisolated static func prepare(_ request: Request, entries: [Input: Snapshot], current: Snapshot?, previousBase: ReadingExperienceState?) -> Prepared? {
        let book = request.project
        guard !Task.isCancelled, let unit = book.units.first(where: { $0.id == request.selectedUnitID }) else { return nil }
        let units = unit.page.map { page in book.units.filter { $0.page == page } } ?? [unit]
        let unitIDs = Set(units.map(\.id)), base = book.readingExperience ?? ReadingExperienceState()
        let anchors = base.anchors.filter { unitIDs.contains($0.unitID) }, ids = Set(anchors.map(\.id))
        var objects: [ObjectInput] = []
        for object in book.entities {
            guard !Task.isCancelled else { return nil }
            let evidence = object.evidence.filter { unitIDs.contains($0.unitID) }
            if !evidence.isEmpty { objects.append(.init(id: object.id, names: [object.name] + object.aliases, evidence: evidence, event: false)) }
        }
        for object in book.events {
            guard !Task.isCancelled else { return nil }
            let evidence = object.evidence.filter { unitIDs.contains($0.unitID) }
            if !evidence.isEmpty { objects.append(.init(id: object.id, names: [object.name], evidence: evidence, event: true)) }
        }
        let input = Input(owner: request.owner, units: units, objects: objects, anchors: anchors,
            mentions: base.mentions.filter { ids.contains($0.anchorID) },
            literalBytes: units.map { Data($0.text.utf8) }
                + objects.flatMap { $0.names.map { Data($0.utf8) } + $0.evidence.map { Data($0.quote.utf8) } }
                + anchors.flatMap { [Data($0.quote.utf8), Data($0.prefix.utf8), Data($0.suffix.utf8)] })
        let snapshot = entries[input] ?? build(input, project: book)
        guard !Task.isCancelled else { return nil }
        let changed = current?.input != input || previousBase != base
        var index = base
        if changed {
            let anchorIDs = Set(base.anchors.map(\.id)), mentionIDs = Set(base.mentions.map(\.id))
            index.anchors.append(contentsOf: snapshot.index.anchors.filter { !anchorIDs.contains($0.id) })
            index.mentions.append(contentsOf: snapshot.index.mentions.filter { !mentionIDs.contains($0.id) })
        }
        return Prepared(snapshot: snapshot, base: base, index: index, changed: changed)
    }
    nonisolated static func build(_ input: Input, project: BookProject) -> Snapshot {
        let interval = pageEvidenceSignposter.beginInterval("BuildPageSnapshot")
        defer { pageEvidenceSignposter.endInterval("BuildPageSnapshot", interval) }
        var compact = project
        compact.units = input.units
        compact.entities = input.objects.filter { !$0.event }.map {
            KnowledgeEntity(id: $0.id, typeID: "snapshot", name: $0.names.first ?? "", aliases: Array($0.names.dropFirst()), evidence: $0.evidence)
        }
        compact.events = input.objects.filter(\.event).map { KnowledgeEvent(id: $0.id, name: $0.names.first ?? "", evidence: $0.evidence) }
        let initial = ReadingExperienceState(anchors: input.anchors, mentions: input.mentions)
        let index = ReadingExperienceRuntime.indexEvidence(in: compact, state: initial, unitIDs: Set(input.units.map(\.id)))
        var offsets: [String: Int] = [:], offset = 0
        for unit in input.units { offsets[unit.id] = offset; offset += (unit.text as NSString).length }
        let mentions = Dictionary(grouping: index.mentions, by: \.anchorID)
        let decorations = index.anchors.compactMap { anchor -> SourceReadingDecoration? in
            guard !Task.isCancelled, let start = offsets[anchor.unitID],
                  let range = try? ReadingExperienceRuntime.resolve(anchor, in: compact) else { return nil }
            return SourceReadingDecoration(id: anchor.id, targetID: mentions[anchor.id]?.first?.targetID ?? anchor.id, quote: anchor.quote,
                rangeLocation: start + range.utf16Location, rangeLength: range.utf16Length, prefix: anchor.prefix, suffix: anchor.suffix,
                interaction: mentions[anchor.id]?.isEmpty == false ? .term : .passage)
        }
        return Snapshot(input: input, index: index, decorations: decorations)
    }
}

@MainActor extension AppStore {
    var visibleSourceUnits: [SourceUnit] {
        guard let book, let unit = selectedUnit else { return [] }
        if let page = unit.page { return book.units.filter { $0.page == page } }
        return [unit]
    }
    func refreshReadingExperienceIndex() {
        readingContextCacheKey = nil
        guard let book else {
            readingIndexTask?.cancel(); readingIndexGeneration &+= 1; readingPageSnapshots.reset()
            readingExperienceIndex = ReadingExperienceState(); return
        }
        let owner = libraryRootURL.path + "|" + book.id + "|" + book.sourceHash
        let scope = owner + "|" + (selectedUnit?.page.map { "page:\($0)" } ?? "unit:" + (selectedUnitID ?? ""))
        let request = ReadingPageSnapshotCache.Request(project: book, selectedUnitID: selectedUnitID, owner: owner, scope: scope)
        // Copy-on-write snapshots are cheap here. All evidence scans, byte
        // hashing, equality checks and canonical-index merges run off main.
        // Coalesce same-page publications instead of repeatedly cancelling it.
        if readingPageSnapshots.pendingScope == scope { readingPageSnapshots.queued = request; return }
        readingIndexTask?.cancel(); readingIndexGeneration &+= 1
        readingPageSnapshots.pendingScope = scope; readingPageSnapshots.queued = nil
        let generation = readingIndexGeneration
        readingIndexTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 45_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.readingIndexGeneration == generation else { return }
            var next = self.readingPageSnapshots.queued ?? request
            self.readingPageSnapshots.queued = nil
            while !Task.isCancelled {
                let frozen = next, entries = self.readingPageSnapshots.entries
                let current = self.readingPageSnapshots.current, base = self.readingPageSnapshots.currentBase
                let calculation = Task.detached(priority: .userInitiated) {
                    ReadingPageSnapshotCache.prepare(frozen, entries: entries, current: current, previousBase: base)
                }
                let prepared = await withTaskCancellationHandler(operation: { await calculation.value }, onCancel: { calculation.cancel() })
                guard !Task.isCancelled, self.readingIndexGeneration == generation, self.bookID == book.id,
                      self.readingPageSnapshots.pendingScope == scope,
                      self.libraryRootURL.path + "|" + book.id + "|" + (self.book?.sourceHash ?? "") == owner else { return }
                if let prepared {
                    self.readingPageSnapshots.remember(prepared.snapshot)
                    // Continuous background saves must not starve this page's
                    // incremental results. Publish an accepted projection before
                    // consuming the latest queued update, provided the actual
                    // visible source still has exactly the same IDs and bytes.
                    // This check touches only page units, never all book facts.
                    let units = self.visibleSourceUnits, expected = prepared.snapshot.input.units
                    let sourceStillMatches = units.count == expected.count && zip(expected, units).allSatisfy { left, right in
                        left.id == right.id && left.page == right.page && left.text.utf8.elementsEqual(right.text.utf8)
                    }
                    if sourceStillMatches {
                        self.readingPageSnapshots.current = prepared.snapshot; self.readingPageSnapshots.currentBase = prepared.base
                        if prepared.changed { self.readingExperienceIndex = prepared.index; self.readingContextCacheKey = nil }
                    }
                }
                if let queued = self.readingPageSnapshots.queued {
                    self.readingPageSnapshots.queued = nil; next = queued; continue
                }
                self.readingPageSnapshots.pendingScope = nil; self.readingIndexTask = nil
                break
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
        return ReadingContext(sourceHash: book?.sourceHash, unitID: document == nil ? (selection?.unitID ?? anchor?.unitID ?? selectedUnitID) : nil,
                              selectedAnchorID: document == nil ? persistentAnchor : nil, selectedText: document == nil ? (selection?.quote ?? anchor?.quote) : nil,
                              selectedPrefix: document == nil ? (selection?.prefix ?? anchor?.prefix) : nil, selectedSuffix: document == nil ? (selection?.suffix ?? anchor?.suffix) : nil,
                              objectID: object, documentID: document?.id,
                              page: document == nil ? selectedUnit?.page : nil, timeFrom: timeFrom, timeTo: timeTo)
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
        guard snapshot.input.units.map(\.id) == units.map(\.id),
              snapshot.input.literalBytes.prefix(units.count).elementsEqual(units.map { Data($0.text.utf8) }) else { return [] }
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
                    try await repository.save(starting); publish(starting)
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
                        try await repository.save(result); publish(result)
                        requestsUsed = await reader.requestCount
                        if completed { break }
                    }
                }
                try Task.checkCancellation()
                guard var finished = book, finished.id == snapshot.bookID, finished.sourceHash == snapshot.sourceHash else { throw CancellationError() }
                finished.audit.append(try progress.audit("companion_scope_finished"))
                try await repository.save(finished); publish(finished)
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
        do { current.readingExperience = try ReadingExperienceRuntime.trashItem(id: id, kind: kind, state: state); try await repository.save(current); publish(current); activity = "已移入伴读回收站，可在伴读菜单恢复。" }
        catch { readingExperienceError = error.localizedDescription }
    }
    func restoreReadingItem(_ id: String) async {
        guard var current = book, let state = current.readingExperience, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do { current.readingExperience = try ReadingExperienceRuntime.restoreTrashedItem(id: id, state: state, in: current); try await repository.save(current); publish(current) }
        catch { readingExperienceError = error.localizedDescription }
    }
}
