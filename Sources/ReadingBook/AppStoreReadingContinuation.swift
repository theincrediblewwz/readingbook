import Foundation
import ReadingCore

struct ReadingContinuationDisplayProgress: Sendable {
    var available: Int
    var total: Int
    var inherited: Int
    var newlySaved: Int
    var blocked: Int
    var scopeSummary: String
    var wholeBookSummary: String?
    var hasBaselineDetails: Bool
}

@MainActor extension AppStore {
    func readingContinuationChapters() async throws -> [BookChapterRange] {
        guard let original = book else { return [] }
        let root = libraryRootURL, owner = repository.publicationOwner, revision = projectRevision
        let snapshot = try await readingContinuationSourceSnapshot(project: original)
        let worker = Task.detached(priority: .userInitiated) {
            try BookChapterRuntime.index(in: snapshot)?.chapters ?? []
        }
        let chapters = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        guard libraryRootURL == root, repository.publicationOwner == owner, bookID == original.id,
              book?.sourceHash == original.sourceHash, projectRevision == revision else { throw CancellationError() }
        return chapters
    }

    /// One background projection per canonical publication. A SwiftUI body
    /// never scans all checkpoints/history, and counts do not prove completion.
    var readingContinuationProgress: ReadingContinuationDisplayProgress? {
        guard let snapshot = book, snapshot.smartReading != nil else {
            readingContinuationProgressTask?.cancel()
            readingContinuationProgressCacheKey = nil; readingContinuationProgressCache = nil
            return nil
        }
        let root = libraryRootURL, owner = repository.publicationOwner
        let key = root.path + "|" + owner.uuidString + "|" + snapshot.id + "|" + String(projectRevision)
        if readingContinuationProgressCacheKey != key {
            readingContinuationProgressTask?.cancel()
            readingContinuationProgressCacheKey = key
            // A count belonging to another book or revision is not a useful
            // loading placeholder for this request.
            readingContinuationProgressCache = nil
            readingContinuationProgressTask = Task { [weak self] in
                let worker = Task.detached(priority: .utility) { () throws -> ReadingContinuationDisplayProgress in
                    try Task.checkCancellation()
                    guard let session = snapshot.smartReading else { throw CancellationError() }
                    let complete = try SmartReadingRuntime.completedLocalUnitIDs(in: snapshot)
                    let baseline = Set(session.continuation?.baselineCompletedUnitIDs ?? [])
                    let scope = Set(session.unitIDs)
                    let scoped = snapshot.units.filter { scope.contains($0.id) }
                    let blank = scoped.filter { SmartReadingRuntime.isConfirmedBlank($0, in: snapshot) }.count
                    let blocked = scoped.filter {
                        ReadingLedger.isDeferred(unitID: $0.id, in: snapshot)
                            || ($0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                && !SmartReadingRuntime.isConfirmedBlank($0, in: snapshot))
                    }.count
                    let knownUnits = Set(snapshot.units.map(\.id))
                    let historical = Set(snapshot.insights.filter {
                        !$0.id.hasPrefix("deferred-") && !$0.id.hasPrefix("blank-")
                    }.flatMap(\.unitIDs)).intersection(knownUnits)
                    let whole = "全书历史：\(historical.count)/\(knownUnits.count) 个内容单元曾保存 AI 内容，当前要求的完成情况另计。"
                    var summary = session.scopeTitle
                    if blank > 0 { summary += " · \(blank) 个单元已确认空白" }
                    if blocked > 0 { summary += " · \(blocked) 个单元待处理或暂缓" }
                    return ReadingContinuationDisplayProgress(available: complete.count, total: scoped.count,
                        inherited: complete.intersection(baseline).count,
                        newlySaved: session.continuation == nil ? 0 : complete.subtracting(baseline).count,
                        blocked: blocked, scopeSummary: summary, wholeBookSummary: whole,
                        hasBaselineDetails: session.continuation != nil)
                }
                let value = await withTaskCancellationHandler(operation: { try? await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, let self, self.libraryRootURL == root,
                      self.repository.publicationOwner == owner, self.bookID == snapshot.id,
                      self.readingContinuationProgressCacheKey == key else { return }
                self.objectWillChange.send()
                self.readingContinuationProgressCache = value
            }
        }
        return readingContinuationProgressCache
    }

    func previewReadingContinuation(_ selection: SmartReadingSelection,
                                    intent: ReadingContinuationIntent) async throws -> ReadingContinuationPreview {
        guard let original = book else { throw ReadingError.invalid("请先选择一本书。") }
        let root = libraryRootURL, owner = repository.publicationOwner
        let revision = projectRevision, stamp = original.publicationStamp
        let unitID = selectedUnitID
        let anchor = chapterReadingAnchor(in: original, unitID: unitID)
        let contextFollowsCursor = selection.scope == .currentPage || selection.scope == .currentChapter
        let snapshot = try await readingContinuationSourceSnapshot(project: original)
        let worker = Task.detached(priority: .userInitiated) {
            let offset = try anchor.map { try ReadingExperienceRuntime.resolve($0, in: snapshot).utf16Location }
            return try ReadingContinuationRuntime.preview(selection: selection, intent: intent,
                in: snapshot, currentUnitID: unitID, currentOffsetUTF16: offset)
        }
        let preview = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        guard libraryRootURL == root, repository.publicationOwner == owner,
              bookID == original.id, book?.sourceHash == original.sourceHash,
              projectRevision == revision, book?.publicationStamp == stamp,
              !contextFollowsCursor || selectedUnitID == unitID else { throw CancellationError() }
        return preview
    }

    func startReadingContinuation(_ selection: SmartReadingSelection, intent: ReadingContinuationIntent,
                                  expectedPreview: ReadingContinuationPreview? = nil) {
        guard let original = book, canStartReading, providerReady else { return }
        guard original.plan != nil, original.smartReading?.isPlanConfirmed != false else {
            requestedWorkspaceRoute = "workflow"; activity = "请先确认阅读方案，再查看本次范围安排。"; return
        }
        guard original.bookSchemes?.pending == nil else { openBookScheme(); return }
        guard intent != .reanalyze || expectedPreview != nil else {
            errorMessage = "请先查看本次重做范围并确认，已有分析保持原样。"; return
        }
        // UI confirmation is pinned to this exact book/source/intent. Core
        // rechecks its semantic fingerprint against the latest canonical state.
        if let preview = expectedPreview {
            guard preview.bookID == original.id, preview.sourceHash == original.sourceHash, preview.intent == intent else {
                errorMessage = "书籍或操作已经改变，请重新查看本次安排。"; return
            }
        }
        let run = UUID(), root = libraryRootURL, owner = repository
        let unitID = selectedUnitID
        let anchor = chapterReadingAnchor(in: original, unitID: unitID)
        let followsCursor = selection.scope == .currentPage || selection.scope == .currentChapter
        let frozenSettings = settings, frozenKey = apiKey
        readingRunID = run; isSmartReadingRunning = true
        activity = "正在核验本次范围与已有成果…"
        readingTask = Task {
            defer { finishReadingRun(run) }
            do {
                let base = try await ensureBookChapterOutline(project: original)
                try Task.checkCancellation()
                guard readingRunID == run, libraryRootURL == root, repository.publicationOwner == owner.publicationOwner,
                      bookID == original.id, book?.sourceHash == original.sourceHash,
                      !followsCursor || selectedUnitID == unitID else { throw CancellationError() }
                let worker = Task.detached(priority: .userInitiated) {
                    let offset = try anchor.map { try ReadingExperienceRuntime.resolve($0, in: base).utf16Location }
                    return try ReadingContinuationRuntime.prepare(selection: selection, intent: intent, in: base,
                        currentUnitID: unitID, currentOffsetUTF16: offset,
                        expectedPreviewFingerprint: expectedPreview?.fingerprint)
                }
                let prepared = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard readingRunID == run, libraryRootURL == root, repository.publicationOwner == owner.publicationOwner,
                      bookID == original.id, book?.sourceHash == original.sourceHash else { throw CancellationError() }
                guard prepared.preview.hasWork else {
                    activity = "所选范围已有兼容的完整成果，无需重复请求。"; return
                }
                guard let preparedSession = prepared.candidate.smartReading else {
                    throw ReadingError.invalid("本次范围未能建立，已有成果保持原样。")
                }
                let saved = try await owner.commitAIResult(base: base, result: prepared.candidate,
                    operationID: "reading-continuation-" + preparedSession.id,
                    expectedReadingSessionID: base.smartReading?.id)
                guard readingRunID == run, libraryRootURL == root, repository.publicationOwner == owner.publicationOwner,
                      bookID == original.id, book?.sourceHash == original.sourceHash else { throw CancellationError() }
                publish(saved); smartReadingPlanReady = false
                finishReadingRun(run)
                startReading(frozenSettings: frozenSettings, frozenKey: frozenKey)
            } catch {
                guard readingRunID == run, libraryRootURL == root, repository.publicationOwner == owner.publicationOwner,
                      bookID == original.id else { return }
                handle(error)
            }
        }
    }

    func finishReadingRun(_ run: UUID) {
        guard readingRunID == run else { return }
        readingRunID = nil; readingTask = nil; isSmartReadingRunning = false; activeReadingUnitID = nil
    }
}
