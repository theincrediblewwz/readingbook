import SwiftUI
import ReadingCore

@MainActor extension AppStore {
    var visibleSourceUnits: [SourceUnit] {
        guard let book, let unit = selectedUnit else { return [] }
        if let page = unit.page { return book.units.filter { $0.page == page } }
        return [unit]
    }
    func refreshReadingExperienceIndex() {
        readingContextCacheKey = nil
        guard let book else { readingExperienceIndex = ReadingExperienceState(); return }
        readingExperienceIndex = ReadingExperienceRuntime.indexEvidence(in: book, unitIDs: Set(visibleSourceUnits.map(\.id)))
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
        guard let book else { return [] }
        var offsets: [String: Int] = [:]; var offset = 0
        for unit in visibleSourceUnits { offsets[unit.id] = offset; offset += (unit.text as NSString).length }
        let mentions = Dictionary(grouping: readingExperienceIndex.mentions, by: \.anchorID)
        return readingExperienceIndex.anchors.compactMap { anchor in
            guard let start = offsets[anchor.unitID], let resolved = try? ReadingExperienceRuntime.resolve(anchor, in: book) else { return nil }
            return SourceReadingDecoration(id: anchor.id, targetID: mentions[anchor.id]?.first?.targetID ?? anchor.id, quote: anchor.quote,
                                           rangeLocation: start + resolved.utf16Location, rangeLength: resolved.utf16Length, prefix: anchor.prefix, suffix: anchor.suffix)
        }
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
            defer { activeReadingUnitID = nil; isBusy = false }
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
            } catch { readingExperienceError = error is CancellationError ? nil : error.localizedDescription; handle(error) }
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
