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
        readingCompanionSection = selectedObjectID == nil ? "layers" : "mentions"; readingCompanionVisible = true
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
        selectedObjectID = id; readingCompanionSection = "mentions"; readingCompanionVisible = true
    }
    func askAboutReadingContext() { route = "query" }
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
        guard let initial = book, let unit = selectedUnit, !isBusy, providerReady else { return }
        guard !unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { showingOCR = true; return }
        let oldAuditIDs = Set(initial.audit.filter { $0.name == "reading_enrich" }.map(\.id))
        isBusy = true; readingExperienceError = nil; readingCompanionVisible = true
        task = Task {
            defer { isBusy = false }
            do {
                await reader.resetBudget()
                while let current = book, current.id == initial.id {
                    try Task.checkCancellation(); activity = "逐段核对并增强：\(unit.locator)"
                    let result = try await reader.enrichCurrent(project: current, unitID: unit.id, settings: settings, apiKey: apiKey)
                    try Task.checkCancellation(); try await repository.save(result); publish(result)
                    requestsUsed = await reader.requestCount
                    if result.audit.contains(where: { $0.name == "reading_enrich" && !oldAuditIDs.contains($0.id) }) { activity = "当前片段的阅读增强已保存，请结合原文核对。"; break }
                }
            } catch { handle(error) }
        }
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
