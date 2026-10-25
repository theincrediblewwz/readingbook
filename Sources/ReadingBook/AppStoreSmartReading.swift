import Foundation
import ReadingCore

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

    func prepareSmartReading(_ selection: SmartReadingSelection) {
        guard let original = book, canStartReading, providerReady else { return }
        guard original.bookSchemes?.pending == nil else { openBookScheme(); return }
        let selectedID = selectedUnitID
        var requestSettings = settings
        requestSettings.transportSessionID = "readingbook-" + original.id + "-reading"
        let requestKey = apiKey
        isSmartReadingRunning = true; smartReadingPlanReady = false
        activity = "正在准备阅读范围…"
        readingTask = Task {
            let aiRunID = await beginAIProgress(title: "制定阅读方案", backgroundReading: true)
            do {
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
                let frozen = try await repository.commitAIResult(base: original, result: candidate, operationID: "reading-scope-" + session.id)
                publish(frozen)
                updateAIProgressDetail(aiRunID, detail: session.scopeTitle)
                await readingReader.resetBudget()
                var planned = try await readingReader.plan(project: frozen, settings: requestSettings, apiKey: requestKey,
                    allowedUnitIDs: analysisIDs, preferredMethodIDs: selection.preferredMethodIDs)
                try Task.checkCancellation()
                planned.smartReading?.status = .awaitingConfirmation
                planned.smartReading?.updatedAt = Date(); planned.smartReading?.lastMessage = "方案准备好了，确认后开始分析。"
                markAIProgressSaving(aiRunID)
                let saved = try await repository.commitAIResult(base: frozen, result: planned, operationID: "reading-plan-" + session.id)
                publish(saved); smartReadingPlanReady = true
                activity = "阅读方案已生成，请确认方法与组件。"
                finishAIProgress(aiRunID)
            } catch { finishAIProgress(aiRunID, error: error); await finishSmartReadingAfterError(error, bookID: original.id) }
            requestsUsed = await sharedAIRequests.requestsUsed
            activeReadingUnitID = nil; isSmartReadingRunning = false; readingTask = nil
        }
    }

    func confirmSmartReading(_ selection: BookSchemeSelection) {
        guard let original = book, let session = original.smartReading, canStartReading else { return }
        isSmartReadingRunning = true; isCommittingLocalWrite = true; activity = "正在保存阅读安排…"
        readingTask = Task {
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
                let saved = try await repository.commitAIResult(base: original, result: candidate, operationID: "reading-confirm-" + session.id)
                publish(saved); smartReadingPlanReady = false
                isCommittingLocalWrite = false; isSmartReadingRunning = false; readingTask = nil
                startReading()
            } catch {
                isCommittingLocalWrite = false
                await finishSmartReadingAfterError(error, bookID: original.id)
                isSmartReadingRunning = false; readingTask = nil
            }
        }
    }

    /// A new range is a new session; old analysis and exact receipts are retained.
    func startSmartReadingWithExistingPlan(_ selection: SmartReadingSelection) {
        guard let original = book, canStartReading else { return }
        guard original.bookSchemes?.pending == nil else { errorMessage = "请先采纳或放弃待确认方案。"; return }
        guard let plan = original.plan, !plan.methodIDs.isEmpty else { errorMessage = "请先预读这本书。"; return }
        let selectedID = selectedUnitID
        isSmartReadingRunning = true; activity = "正在调整本轮范围…"
        readingTask = Task {
            do {
                try PluginEngine.requireActivePlan(in: original)
                var adjusted = selection; adjusted.preferredMethodIDs = []
                var session = try await freezeReadingSelection(adjusted, project: original, currentUnitID: selectedID)
                session.analysisCheckpoints = original.smartReading?.analysisCheckpoints
                session.isPlanConfirmed = true; session.status = .ready
                session.lastMessage = "沿用已生效方案，按本次范围和方式分析。"
                var candidate = original; candidate.smartReading = session
                adjusted.execution?.configureRequestedViews(in: &candidate)
                try Task.checkCancellation()
                let saved = try await repository.commitAIResult(base: original, result: candidate, operationID: "reading-rescope-" + session.id)
                publish(saved); smartReadingPlanReady = false
                isSmartReadingRunning = false; readingTask = nil; startReading()
            } catch {
                await finishSmartReadingAfterError(error, bookID: original.id)
                isSmartReadingRunning = false; readingTask = nil
            }
        }
    }

    func startReading() {
        guard let original = book, canStartReading, providerReady else { return }
        guard let existing = original.smartReading else { requestedWorkspaceRoute = "workflow"; activity = "先选择本轮分析范围与方式。"; return }
        if original.bookSchemes?.pending != nil { smartReadingPlanReady = true; openBookScheme(); return }
        if original.plan == nil || !existing.isPlanConfirmed { prepareSmartReading(existing.selection); return }
        var requestSettings = settings
        requestSettings.transportSessionID = "readingbook-" + original.id + "-reading"
        let requestKey = apiKey, sessionID = existing.id, readingBookID = original.id
        isSmartReadingRunning = true; activity = "正在准备本轮阅读…"
        readingTask = Task {
            let aiRunID = await beginAIProgress(title: "智能阅读 · " + existing.scopeTitle, backgroundReading: true)
            do {
                let analysisIDs = try await validatedAnalysisIDs(existing, project: original)
                let unitIDs = Set(existing.unitIDs)
                guard !smartReadingNeedsOCR(in: original, unitIDs: unitIDs) else { throw ReadingError.invalid("所选范围还有未识别页面，请先 OCR。") }
                var started = original
                started.smartReading?.status = .running; started.smartReading?.updatedAt = Date(); started.smartReading?.lastMessage = nil
                try Task.checkCancellation()
                let frozen = try await repository.commitAIResult(base: original, result: started, operationID: "reading-start-" + UUID().uuidString)
                publish(frozen); await readingReader.resetBudget()
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
                        let saved = try await repository.commitAIResult(base: input, result: result, operationID: "reading-unit-" + UUID().uuidString)
                        publish(saved); requestsUsed = await sharedAIRequests.requestsUsed
                        if let failure = ReadingWorkflowRuntime.failureMessage(in: saved, unitID: unit.id) { throw ReadingError.invalid(failure) }
                    }
                    while !analysisIDs.isEmpty, let latest = book, !(await readingReader.synthesisComplete(project: latest, allowedUnitIDs: analysisIDs)) {
                        try Task.checkCancellation(); try requireSmartReadingSession(latest, bookID: readingBookID, sessionID: sessionID)
                        updateAIProgressDetail(aiRunID, detail: "整理本轮读后回顾")
                        var result = try await readingReader.synthesizeNext(project: latest, settings: requestSettings, apiKey: requestKey, allowedUnitIDs: analysisIDs)
                        try Task.checkCancellation(); result.smartReading?.updatedAt = Date(); markAIProgressSaving(aiRunID)
                        let saved = try await repository.commitAIResult(base: latest, result: result, operationID: "reading-review-" + UUID().uuidString)
                        publish(saved); requestsUsed = await sharedAIRequests.requestsUsed
                    }
                }
                guard var latest = book else { throw CancellationError() }
                try requireSmartReadingSession(latest, bookID: readingBookID, sessionID: sessionID)
                let base = latest
                latest.smartReading?.status = .completed; latest.smartReading?.currentUnitID = nil; latest.smartReading?.updatedAt = Date()
                let message = existing.selection.execution != nil ? "本轮分析已保存，逐段核对另行记录。" : "本轮处理结果已保存。"
                latest.smartReading?.lastMessage = message
                let saved = try await repository.commitAIResult(base: base, result: latest, operationID: "reading-finish-" + UUID().uuidString)
                publish(saved); activity = message; finishAIProgress(aiRunID)
            } catch { finishAIProgress(aiRunID, error: error); await finishSmartReadingAfterError(error, bookID: readingBookID) }
            requestsUsed = await sharedAIRequests.requestsUsed
            activeReadingUnitID = nil; isSmartReadingRunning = false; readingTask = nil
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
        else { queryTask?.cancel(); task?.cancel(); activity = "正在停止，已保存内容保留。" }
    }

    private func freezeReadingSelection(_ selection: SmartReadingSelection, project: BookProject, currentUnitID: String?) async throws -> SmartReadingSession {
        let worker = Task.detached(priority: .userInitiated) { try SmartReadingRuntime.freeze(selection, in: project, currentUnitID: currentUnitID) }
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
    private func finishSmartReadingAfterError(_ error: Error, bookID: String) async {
        let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
        let budget = error is ReadingWorkflowBudgetPause || error.localizedDescription.contains("预算")
        let message = cancelled ? "已暂停，已保存的内容保留。" : budget ? "本轮预算已用完，已保存内容保留；继续时开始新一轮。" : String(error.localizedDescription.prefix(2000))
        if let base = book, base.id == bookID, base.smartReading != nil {
            var current = base
            current.smartReading?.status = cancelled || budget ? .paused : .failed
            current.smartReading?.updatedAt = Date(); current.smartReading?.lastMessage = message
            do { let saved = try await repository.commitAIResult(base: base, result: current, operationID: "reading-state-" + UUID().uuidString); publish(saved) }
            catch { errorMessage = "状态保存失败，已有内容保留：" + error.localizedDescription }
        }
        activity = message
        if !cancelled && !budget { handle(error) }
    }
}
