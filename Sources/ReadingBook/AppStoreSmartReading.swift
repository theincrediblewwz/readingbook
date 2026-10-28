import Foundation
import CryptoKit
import ReadingCore

struct SmartReadingPlanRegeneration: Identifiable, Sendable {
    let id = UUID()
    let root: URL
    let bookID: String
    let sourceHash: String
    let bookTitle: String
    let selection: SmartReadingSelection
    let existingPlanFingerprint: String

    static func fingerprint(_ plan: ReadingPlan?) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try SHA256.hash(data: encoder.encode(plan)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor extension AppStore {
    var smartReadingSession: SmartReadingSession? { book?.smartReading }
    var smartReadingProgress: SmartReadingProgress? {
        let key = (bookID ?? "") + ":" + String(projectRevision)
        if smartReadingProgressCacheKey != key {
            smartReadingProgressCacheKey = key
            smartReadingProgressTask?.cancel()
            guard let snapshot = book else { smartReadingProgressCache = nil; return nil }
            let previousCache = smartReadingUnitProgressCache
            smartReadingProgressTask = Task { [weak self] in
                let worker = Task.detached(priority: .utility) {
                    var cache = previousCache
                    let value = try? SmartReadingRuntime.progress(in: snapshot, cache: &cache, validateSource: false)
                    return (cache, value)
                }
                let computed = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, let self, self.smartReadingProgressCacheKey == key, self.bookID == snapshot.id else { return }
                self.objectWillChange.send()
                self.smartReadingUnitProgressCache = computed.0; self.smartReadingProgressCache = computed.1
            }
        }
        return smartReadingProgressCache
    }

    func makePlan() { prepareSmartReading(book?.smartReading?.selection ?? SmartReadingSelection(execution: .init())) }

    func cancelPlanRegeneration() { pendingPlanRegeneration = nil }

    func confirmPlanRegeneration() {
        guard let request = pendingPlanRegeneration else { return }
        pendingPlanRegeneration = nil
        guard let current = book, current.id == request.bookID, current.sourceHash == request.sourceHash,
              libraryRootURL == request.root, canStartReading else { return }
        do {
            guard try SmartReadingPlanRegeneration.fingerprint(current.plan) == request.existingPlanFingerprint else {
                errorMessage = "阅读方案已在确认期间改变，请重新检查后再生成；已有内容保留。"; return
            }
            prepareSmartReading(request.selection, confirmingExisting: true)
        } catch { errorMessage = error.localizedDescription }
    }

    func prepareSmartReading(_ selection: SmartReadingSelection, confirmingExisting: Bool = false) {
        guard let original = book, canStartReading, providerReady else { return }
        guard original.bookSchemes?.pending == nil else { openBookScheme(); return }
        if original.plan != nil, !confirmingExisting {
            do {
                pendingPlanRegeneration = SmartReadingPlanRegeneration(root: libraryRootURL, bookID: original.id,
                    sourceHash: original.sourceHash, bookTitle: original.title, selection: selection,
                    existingPlanFingerprint: try SmartReadingPlanRegeneration.fingerprint(original.plan))
            } catch { errorMessage = error.localizedDescription }
            return
        }
        let selectedID = selectedUnitID
        var requestSettings = settings
        requestSettings.transportSessionID = "readingbook-" + original.id + "-reading"
        let requestKey = apiKey
        let owner = repository, requestRoot = libraryRootURL
        let run = UUID(); readingRunID = run
        isSmartReadingRunning = true; smartReadingPlanReady = false
        activity = "正在准备阅读范围…"
        readingTask = Task {
            defer { finishReadingRun(run) }
            let aiRunID = await beginAIProgress(title: "制定阅读方案", backgroundReading: true, settings: requestSettings)
            var committedSessionID: String?
            do {
                let original = try await ensureBookChapterOutline(project: original)
                var session = try await freezeReadingSelection(selection, project: original, currentUnitID: selectedID)
                let ids = Set(session.unitIDs)
                guard !smartReadingNeedsOCR(in: original, unitIDs: ids) else {
                    showingOCR = true; activity = "所选范围还有未识别页面，请先 OCR；尚未发送请求。"
                    finishAIProgress(aiRunID); isSmartReadingRunning = false; readingTask = nil; return
                }
                let analysisIDs = try await validatedAnalysisIDs(session, project: original)
                guard !analysisIDs.isEmpty else {
                    activity = "所选范围只有空白或暂缓内容，无需预读。"
                    finishAIProgress(aiRunID); isSmartReadingRunning = false; readingTask = nil; return
                }
                session.analysisCheckpoints = original.smartReading?.analysisCheckpoints
                session.status = .planning
                var candidate = original; candidate.smartReading = session
                selection.execution?.configureRequestedViews(in: &candidate)
                try Task.checkCancellation()
                guard readingRunID == run, libraryRootURL == requestRoot, repository.publicationOwner == owner.publicationOwner,
                      bookID == original.id, book?.sourceHash == original.sourceHash else { throw CancellationError() }
                updateAIProgressDetail(aiRunID, detail: session.scopeTitle)
                await readingReader.resetBudget()
                // The candidate range, session and requested views remain local
                // until a complete, valid plan returns. Failure/cancellation must
                // leave the previously confirmed session usable as it was.
                var planned = try await readingReader.plan(project: candidate, settings: requestSettings, apiKey: requestKey,
                    allowedUnitIDs: analysisIDs, preferredMethodIDs: selection.preferredMethodIDs)
                try Task.checkCancellation()
                guard readingRunID == run, libraryRootURL == requestRoot, repository.publicationOwner == owner.publicationOwner,
                      bookID == original.id, book?.sourceHash == original.sourceHash else { throw CancellationError() }
                planned.smartReading?.status = .awaitingConfirmation
                planned.smartReading?.updatedAt = Date(); planned.smartReading?.lastMessage = "方案准备好了，确认后查看本次处理安排。"
                try ReadingContinuationRuntime.preserveHistory(from: original, in: &planned)
                markAIProgressSaving(aiRunID)
                let saved = try await owner.commitAIResult(base: original, result: planned, operationID: "reading-plan-" + session.id)
                committedSessionID = session.id
                guard readingRunID == run, libraryRootURL == requestRoot, repository.publicationOwner == owner.publicationOwner,
                      bookID == original.id, book?.sourceHash == original.sourceHash else { throw CancellationError() }
                publish(saved); smartReadingPlanReady = true
                activity = "阅读方案已生成，请确认方法与组件。"
                finishAIProgress(aiRunID)
            } catch {
                finishAIProgress(aiRunID, error: error)
                await finishSmartReadingAfterError(error, bookID: original.id, sessionID: committedSessionID,
                                                  repository: owner, root: requestRoot, runID: run)
            }
            guard readingRunID == run else { return }
            requestsUsed = await sharedAIRequests.requestsUsed
        }
    }

    func confirmSmartReading(_ selection: BookSchemeSelection) {
        guard let original = book, let session = original.smartReading, canStartReading else { return }
        let owner = repository, root = libraryRootURL, run = UUID()
        readingRunID = run
        isSmartReadingRunning = true; isCommittingLocalWrite = true; activity = "正在保存阅读安排…"
        readingTask = Task {
            defer {
                if readingRunID == run { isCommittingLocalWrite = false }
                finishReadingRun(run)
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    var current = original
                    try SmartReadingRuntime.validate(session, in: current)
                    try BookSchemeRuntime.applyPending(selection: selection, in: &current)
                    current.smartReading?.status = .ready; current.smartReading?.updatedAt = Date()
                    current.smartReading?.isPlanConfirmed = true; current.smartReading?.lastMessage = "方案已确认。"
                    return current
                }
                let candidate = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard readingRunID == run, libraryRootURL == root, repository.publicationOwner == owner.publicationOwner,
                      bookID == original.id, book?.sourceHash == original.sourceHash,
                      book?.smartReading?.id == session.id else { throw CancellationError() }
                let saved = try await owner.commitAIResult(base: original, result: candidate, operationID: "reading-confirm-" + session.id,
                                                         expectedReadingSessionID: session.id)
                guard readingRunID == run, libraryRootURL == root, repository.publicationOwner == owner.publicationOwner,
                      bookID == original.id else { throw CancellationError() }
                publish(saved); smartReadingPlanReady = false
                isCommittingLocalWrite = false
                requestedWorkspaceRoute = "workflow"
                activity = "方案已确认，请查看本次范围与已有成果安排后开始。"
            } catch {
                if readingRunID == run { isCommittingLocalWrite = false }
                await finishSmartReadingAfterError(error, bookID: original.id, sessionID: session.id,
                                                  repository: owner, root: root, runID: run)
            }
        }
    }

    /// A new range is a new session; old analysis and exact receipts are retained.
    func startSmartReadingWithExistingPlan(_ selection: SmartReadingSelection) {
        startReadingContinuation(selection, intent: .continueMissing)
    }

    func startReading() {
        guard providerReady else { return }
        startReading(frozenSettings: settings, frozenKey: apiKey)
    }

    func startReading(frozenSettings: ProviderSettings, frozenKey: String) {
        guard let original = book, canStartReading else { return }
        guard !frozenSettings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请先选择模型服务。"; return
        }
        guard let existing = original.smartReading else { requestedWorkspaceRoute = "workflow"; activity = "先选择本轮分析范围与方式。"; return }
        if original.bookSchemes?.pending != nil { smartReadingPlanReady = true; openBookScheme(); return }
        if original.plan == nil || !existing.isPlanConfirmed { prepareSmartReading(existing.selection); return }
        var requestSettings = frozenSettings
        requestSettings.transportSessionID = "readingbook-" + original.id + "-reading"
        let requestKey = frozenKey, sessionID = existing.id, readingBookID = original.id
        let owner = repository, root = libraryRootURL, run = UUID()
        readingRunID = run
        isSmartReadingRunning = true; activity = "正在准备本轮阅读…"
        readingTask = Task {
            defer { finishReadingRun(run) }
            let aiRunID = await beginAIProgress(title: "智能阅读 · " + existing.scopeTitle, backgroundReading: true, settings: requestSettings)
            do {
                let original = try await ensureBookChapterOutline(project: original)
                guard readingRunID == run, libraryRootURL == root, repository.publicationOwner == owner.publicationOwner,
                      bookID == readingBookID, book?.sourceHash == original.sourceHash else { throw CancellationError() }
                let worker = Task.detached(priority: .userInitiated) {
                    var candidate = original
                    // This entry point owns admission; a persisted running flag
                    // after app termination is not a live worker/catalog.
                    if candidate.smartReading?.status == .running { candidate.smartReading?.status = .paused }
                    try SmartReadingRuntime.freezeChapterBoundaries(in: &candidate)
                    return candidate
                }
                var started = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let session = started.smartReading else { throw CancellationError() }
                let analysisIDs = try await validatedAnalysisIDs(session, project: started)
                let unitIDs = Set(session.unitIDs)
                guard !smartReadingNeedsOCR(in: original, unitIDs: unitIDs) else { throw ReadingError.invalid("所选范围还有未识别页面，请先 OCR。") }
                started.smartReading?.status = .running; started.smartReading?.updatedAt = Date(); started.smartReading?.lastMessage = nil
                try Task.checkCancellation()
                let frozen = try await owner.commitAIResult(base: original, result: started, operationID: "reading-start-" + UUID().uuidString, expectedReadingSessionID: sessionID)
                guard readingRunID == run, libraryRootURL == root, repository.publicationOwner == owner.publicationOwner,
                      bookID == readingBookID, book?.sourceHash == original.sourceHash else { throw CancellationError() }
                publish(frozen); await readingReader.resetBudget()
                await readingReader.setPublicationHandler(readingPublicationHandler(bookID: readingBookID, sessionID: sessionID, progressID: aiRunID))
                if existing.selection.execution != nil {
                    try await runConfiguredAnalysis(bookID: readingBookID, sessionID: sessionID, allowedUnitIDs: unitIDs,
                        settings: requestSettings, apiKey: requestKey, progressID: aiRunID)
                } else {
                    while let latest = book {
                        try Task.checkCancellation(); try requireSmartReadingSession(latest, bookID: readingBookID, sessionID: sessionID)
                        let worker = Task.detached(priority: .utility) { try SmartReadingRuntime.nextUnit(in: latest, allowedUnitIDs: unitIDs) }
                        guard let unit = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }) else { break }
                        activeReadingUnitID = unit.id
                        updateAIProgressDetail(aiRunID, detail: unit.page.map { "第 \($0) 页" } ?? unit.chapter)
                        var input = latest; input.smartReading?.currentUnitID = unit.id
                        var result = try await readingReader.readNext(project: input, settings: requestSettings, apiKey: requestKey, allowedUnitIDs: unitIDs)
                        try Task.checkCancellation(); result.smartReading?.updatedAt = Date()
                        markAIProgressSaving(aiRunID)
                        let saved = try await owner.commitAIResult(base: input, result: result, operationID: "reading-unit-" + UUID().uuidString, expectedReadingSessionID: sessionID)
                        guard readingRunID == run, libraryRootURL == root, repository.publicationOwner == owner.publicationOwner,
                              bookID == readingBookID, book?.sourceHash == original.sourceHash else { throw CancellationError() }
                        publish(saved); requestsUsed = await sharedAIRequests.requestsUsed
                        if let failure = ReadingWorkflowRuntime.failureMessage(in: saved, unitID: unit.id) { throw ReadingError.invalid(failure) }
                    }
                    // Continuation previews enumerate the chosen work. The
                    // old implicit synthesis is not an extra selected step.
                    while existing.continuation == nil, !analysisIDs.isEmpty, let latest = book, !(await readingReader.synthesisComplete(project: latest, allowedUnitIDs: analysisIDs)) {
                        try Task.checkCancellation(); try requireSmartReadingSession(latest, bookID: readingBookID, sessionID: sessionID)
                        updateAIProgressDetail(aiRunID, detail: "整理本轮读后回顾")
                        var result = try await readingReader.synthesizeNext(project: latest, settings: requestSettings, apiKey: requestKey, allowedUnitIDs: analysisIDs)
                        try Task.checkCancellation(); result.smartReading?.updatedAt = Date(); markAIProgressSaving(aiRunID)
                        let saved = try await owner.commitAIResult(base: latest, result: result, operationID: "reading-review-" + UUID().uuidString, expectedReadingSessionID: sessionID)
                        guard readingRunID == run, libraryRootURL == root, repository.publicationOwner == owner.publicationOwner,
                              bookID == readingBookID, book?.sourceHash == original.sourceHash else { throw CancellationError() }
                        publish(saved); requestsUsed = await sharedAIRequests.requestsUsed
                    }
                }
                guard let latest = book, readingRunID == run, libraryRootURL == root,
                      repository.publicationOwner == owner.publicationOwner else { throw CancellationError() }
                try requireSmartReadingSession(latest, bookID: readingBookID, sessionID: sessionID)
                let base = latest
                let message = existing.selection.execution != nil ? "本轮分析已保存，逐段核对另行记录。" : "本轮处理结果已保存。"
                let finish = Task.detached(priority: .userInitiated) {
                    var completed = base
                    completed.smartReading?.status = .completed; completed.smartReading?.currentUnitID = nil; completed.smartReading?.updatedAt = Date()
                    completed.smartReading?.lastMessage = message
                    try ReadingContinuationRuntime.completePreparedGeneration(in: &completed)
                    return completed
                }
                let completed = try await withTaskCancellationHandler(operation: { try await finish.value }, onCancel: { finish.cancel() })
                try Task.checkCancellation()
                guard readingRunID == run, libraryRootURL == root, repository.publicationOwner == owner.publicationOwner,
                      bookID == readingBookID else { throw CancellationError() }
                let saved = try await owner.commitAIResult(base: base, result: completed, operationID: "reading-finish-" + UUID().uuidString, expectedReadingSessionID: sessionID)
                guard readingRunID == run, libraryRootURL == root, repository.publicationOwner == owner.publicationOwner,
                      bookID == readingBookID else { throw CancellationError() }
                publish(saved); activity = message; finishAIProgress(aiRunID)
            } catch {
                finishAIProgress(aiRunID, error: error)
                await finishSmartReadingAfterError(error, bookID: readingBookID, sessionID: sessionID,
                                                  repository: owner, root: root, runID: run)
            }
            guard readingRunID == run else { return }
            requestsUsed = await sharedAIRequests.requestsUsed
        }
    }

    func runConfiguredAnalysis(bookID: String, sessionID: String, allowedUnitIDs: Set<String>, settings: ProviderSettings, apiKey: String, progressID: UUID) async throws {
        try await runConfiguredReading(bookID: bookID, sessionID: sessionID, allowedUnitIDs: allowedUnitIDs,
            settings: settings, apiKey: apiKey, progressID: progressID)
    }

    func pauseReading() {
        guard !isCommittingLocalWrite else { return }
        readingTask?.cancel()
        activity = "正在停止，已保存内容保留。"
    }
    func pause() {
        guard !restoringWorkspaceMemory, !isSavingDocument, !isExportingProject, !isImportingBookCommit, !isCommittingLocalWrite else { return }
        if isSmartReadingRunning { pauseReading() }
        else if isCompanionGenerating { cancelCompanion(); activity = "正在停止伴读，已保存内容保留。" }
        else { queryTask?.cancel(); task?.cancel(); connectionTestTask?.cancel(); activity = "正在停止，已保存内容保留。" }
    }

    private func freezeReadingSelection(_ selection: SmartReadingSelection, project: BookProject, currentUnitID: String?) async throws -> SmartReadingSession {
        let position = [selectedSourceAnchor, focusedReadingSourceAnchor, readerChapterAnchor].compactMap { $0 }.first {
            $0.sourceHash == project.sourceHash && $0.unitID == currentUnitID
        }
        let worker = Task.detached(priority: .userInitiated) {
            let offset = try position.map { try ReadingExperienceRuntime.resolve($0, in: project).utf16Location }
            return try SmartReadingRuntime.freeze(selection, in: project, currentUnitID: currentUnitID, currentOffsetUTF16: offset)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    private func validatedAnalysisIDs(_ session: SmartReadingSession, project: BookProject) async throws -> Set<String> {
        let worker = Task.detached(priority: .userInitiated) {
            try SmartReadingRuntime.validate(session, in: project)
            return try SmartReadingRuntime.analysisUnitIDs(in: project, allowedUnitIDs: Set(session.unitIDs))
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    private func smartReadingNeedsOCR(in project: BookProject, unitIDs: Set<String>) -> Bool {
        project.units.contains { unitIDs.contains($0.id) && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !ReadingLedger.isDeferred(unitID: $0.id, in: project) && !SmartReadingRuntime.isConfirmedBlank($0, in: project) }
    }
    private func requireSmartReadingSession(_ project: BookProject, bookID: String, sessionID: String) throws {
        guard project.id == bookID, let session = project.smartReading, session.id == sessionID, session.sourceHash == project.sourceHash else { throw CancellationError() }
    }
    private func finishSmartReadingAfterError(_ error: Error, bookID: String, sessionID: String?,
                                             repository frozenRepository: LibraryRepository? = nil,
                                             root frozenRoot: URL? = nil, runID: UUID? = nil) async {
        let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
        let budget = error is ReadingWorkflowBudgetPause || error.localizedDescription.contains("预算")
        let message = cancelled ? "已暂停，已保存的内容保留。" : budget ? "本轮预算已用完，已保存内容保留；继续时开始新一轮。" : String(error.localizedDescription.prefix(2000))
        var finalMessage = message
        let owner = frozenRepository ?? repository, originalLibrary = frozenRoot ?? libraryRootURL
        func ownsPresentation() -> Bool {
            libraryRootURL == originalLibrary && repository.publicationOwner == owner.publicationOwner
                && self.bookID == bookID && (runID == nil || readingRunID == runID)
        }
        if let sessionID {
            if cancelled && ownsPresentation() { activity = "正在保存暂停状态…" }
            do {
                let saved = try await owner.checkpointReadingStop(bookID: bookID, sessionID: sessionID, failed: !cancelled && !budget, message: message)
                guard ownsPresentation(), book?.smartReading?.id == sessionID else { return }
                if let saved { publish(saved) }
                else { finalMessage = "该轮任务已结束，当前阅读安排保持原样。" }
            } catch {
                guard ownsPresentation() else { return }
                finalMessage = cancelled ? "已停止；暂停状态暂未保存，已生成内容保留。" : "任务已停止；状态暂未保存，已生成内容保留。"
                errorMessage = finalMessage
            }
        }
        guard ownsPresentation() else { return }
        activity = finalMessage
        if !cancelled && !budget { handle(error) }
    }
}
