import Foundation
import ReadingCore

@MainActor extension AppStore {
    var smartReadingSession: SmartReadingSession? { book?.smartReading }
    var smartReadingProgress: SmartReadingProgress? {
        let key = (bookID ?? "") + ":" + String(projectRevision)
        if smartReadingProgressCacheKey != key {
            smartReadingProgressCacheKey = key
            if let book { smartReadingProgressCache = try? SmartReadingRuntime.progress(in: book, cache: &smartReadingUnitProgressCache, validateSource: false) }
            else { smartReadingProgressCache = nil }
        }
        return smartReadingProgressCache
    }

    /// Compatibility entry: a user action always precedes a paid preview request.
    func makePlan() { prepareSmartReading(book?.smartReading?.selection ?? SmartReadingSelection()) }

    func prepareSmartReading(_ selection: SmartReadingSelection) {
        guard var current = book, !isBusy, !isSavingDocument, providerReady else { return }
        guard current.bookSchemes?.pending == nil else { openBookScheme(); return }
        do {
            var session = try SmartReadingRuntime.freeze(selection, in: current, currentUnitID: selectedUnitID)
            guard !smartReadingNeedsOCR(in: current, unitIDs: Set(session.unitIDs)) else {
                showingOCR = true; activity = "所选范围还有未识别页面，请先 OCR 或对照原书处理；尚未发送请求。"; return
            }
            let analysisIDs = try SmartReadingRuntime.analysisUnitIDs(in: current, allowedUnitIDs: Set(session.unitIDs))
            guard !analysisIDs.isEmpty else { activity = "所选范围只有已确认空白或明确暂缓的内容，无需发送预读请求。"; return }
            session.status = .planning; current.smartReading = session
            let frozen = current
            var requestSettings = settings
            requestSettings.transportSessionID = "readingbook-" + current.id + "-reading"
            let requestKey = apiKey
            isBusy = true; isSmartReadingRunning = true; smartReadingPlanReady = false
            activity = "AI 正在预读所选范围，并选择适合这本书的方法…"
            task = Task {
                let aiRunID = await beginAIProgress(title: "制定阅读方案")
                updateAIProgressDetail(aiRunID, detail: frozen.smartReading?.scopeTitle ?? "所选范围")
                defer { finishAIProgress(aiRunID) }
                do {
                    try Task.checkCancellation()
                    try await repository.save(frozen); publish(frozen)
                    await reader.resetBudget()
                    var planned = try await reader.plan(project: frozen, settings: requestSettings, apiKey: requestKey,
                                                        allowedUnitIDs: analysisIDs, preferredMethodIDs: selection.preferredMethodIDs)
                    try Task.checkCancellation()
                    planned.smartReading?.status = .awaitingConfirmation
                    planned.smartReading?.updatedAt = Date()
                    planned.smartReading?.lastMessage = "预读方案已生成，确认后才分析原文。"
                    markAIProgressSaving(aiRunID)
                    try await repository.save(planned); publish(planned)
                    smartReadingPlanReady = true
                    activity = "预读方案已生成，请确认方法与组件；原文覆盖尚未增加。"
                } catch { finishAIProgress(aiRunID, error: error); await finishSmartReadingAfterError(error, bookID: frozen.id) }
                requestsUsed = await reader.requestCount
                activeReadingUnitID = nil; isSmartReadingRunning = false; isBusy = false
            }
        } catch { handle(error) }
    }

    /// The button invoking this API is an explicit “confirm and start” action.
    /// Saving the configuration must succeed before the next model request begins.
    func confirmSmartReading(_ selection: BookSchemeSelection) {
        guard var current = book, let session = current.smartReading, !isBusy, !isSavingDocument else { return }
        do {
            try SmartReadingRuntime.validate(session, in: current)
            try BookSchemeRuntime.applyPending(selection: selection, in: &current)
            current.smartReading?.status = .ready; current.smartReading?.updatedAt = Date()
            current.smartReading?.isPlanConfirmed = true
            current.smartReading?.lastMessage = "方案已确认，准备分析所选范围。"
            let approved = current
            isBusy = true; isCommittingLocalWrite = true
            Task {
                do {
                    try await repository.save(approved); publish(approved)
                    smartReadingPlanReady = false
                    isCommittingLocalWrite = false; isBusy = false
                    startReading()
                } catch {
                    isCommittingLocalWrite = false; isBusy = false; handle(error)
                }
            }
        } catch { handle(error) }
    }

    /// The reader explicitly chooses the already displayed plan. New method
    /// preferences in the setup controls do not silently alter that old plan.
    func startSmartReadingWithExistingPlan(_ selection: SmartReadingSelection) {
        guard var current = book, !isBusy, !isSavingDocument else { return }
        guard current.bookSchemes?.pending == nil else { errorMessage = "请先采纳或放弃待确认方案，再沿用当前方案。"; return }
        guard let plan = current.plan, !plan.methodIDs.isEmpty else { errorMessage = "当前没有可沿用的阅读方案，请先预读。"; return }
        do {
            try PluginEngine.requireActivePlan(in: current)
            var existingPlanSelection = selection
            existingPlanSelection.preferredMethodIDs = []
            var session = try SmartReadingRuntime.freeze(existingPlanSelection, in: current, currentUnitID: selectedUnitID)
            session.isPlanConfirmed = true; session.status = .ready
            session.lastMessage = "沿用此前已生效方案，分析本次所选范围。"
            current.smartReading = session
            try SmartReadingRuntime.validate(session, in: current)
            let approved = current
            isBusy = true; isCommittingLocalWrite = true
            Task {
                do {
                    try await repository.save(approved); publish(approved)
                    smartReadingPlanReady = false
                    isCommittingLocalWrite = false; isBusy = false
                    startReading()
                } catch {
                    isCommittingLocalWrite = false; isBusy = false; handle(error)
                }
            }
        } catch { handle(error) }
    }

    func startReading() {
        guard var current = book, !isBusy, !isSavingDocument, providerReady else { return }
        guard current.smartReading != nil else {
            requestedWorkspaceRoute = "workflow"
            activity = "请先确认本轮分析方式与范围；也可以直接沿用已有方案。"
            return
        }
        if current.bookSchemes?.pending != nil { smartReadingPlanReady = true; openBookScheme(); return }
        if current.plan == nil { prepareSmartReading(current.smartReading?.selection ?? SmartReadingSelection()); return }
        do {
            var session: SmartReadingSession
            if let existing = current.smartReading {
                session = existing
                if !session.isPlanConfirmed { prepareSmartReading(session.selection); return }
            } else {
                session = try SmartReadingRuntime.freeze(SmartReadingSelection(), in: current, currentUnitID: selectedUnitID)
                session.isPlanConfirmed = true // An explicitly resumed legacy plan remains executable.
            }
            try SmartReadingRuntime.validate(session, in: current)
            let unitIDs = Set(session.unitIDs)
            let analysisIDs = try SmartReadingRuntime.analysisUnitIDs(in: current, allowedUnitIDs: unitIDs)
            guard !smartReadingNeedsOCR(in: current, unitIDs: unitIDs) else {
                showingOCR = true; activity = "所选范围尚有未识别页面，请先 OCR；未发送请求。"; return
            }
            session.status = .running; session.updatedAt = Date(); session.lastMessage = nil
            session.currentUnitID = try SmartReadingRuntime.nextUnit(in: current, allowedUnitIDs: unitIDs)?.id
            current.smartReading = session
            let frozen = current, sessionID = session.id, readingBookID = current.id
            var requestSettings = settings
            requestSettings.transportSessionID = "readingbook-" + readingBookID + "-reading"
            let requestKey = apiKey
            isBusy = true; isSmartReadingRunning = true; activity = "准备在后台分析\(session.scopeTitle)…"
            task = Task {
                let aiRunID = await beginAIProgress(title: "智能阅读 · \(frozen.smartReading?.scopeTitle ?? "所选范围")")
                defer { finishAIProgress(aiRunID) }
                do {
                    try Task.checkCancellation(); try await repository.save(frozen); publish(frozen)
                    await reader.resetBudget()
                    while let latest = book {
                        try Task.checkCancellation()
                        try requireSmartReadingSession(latest, bookID: readingBookID, sessionID: sessionID)
                        guard let unit = try SmartReadingRuntime.nextUnit(in: latest, allowedUnitIDs: unitIDs) else { break }
                        activeReadingUnitID = unit.id
                        updateAIProgressDetail(aiRunID, detail: unit.page.map { "第 \($0) 页" } ?? unit.chapter)
                        activity = "后台分析：\(unit.locator)；你可以继续翻阅原书。"
                        var input = latest
                        input.smartReading?.currentUnitID = unit.id
                        var result = try await reader.readNext(project: input, settings: requestSettings, apiKey: requestKey, allowedUnitIDs: unitIDs)
                        try Task.checkCancellation()
                        result.smartReading?.updatedAt = Date()
                        let nextUnitID = try SmartReadingRuntime.nextUnit(in: result, allowedUnitIDs: unitIDs)?.id
                        result.smartReading?.currentUnitID = nextUnitID
                        markAIProgressSaving(aiRunID)
                        try await repository.save(result); publish(result)
                        requestsUsed = await reader.requestCount
                        if let failure = ReadingWorkflowRuntime.failureMessage(in: result, unitID: unit.id) { throw ReadingError.invalid(failure) }
                    }
                    activeReadingUnitID = nil
                    while !analysisIDs.isEmpty, let latest = book, !(await reader.synthesisComplete(project: latest, allowedUnitIDs: analysisIDs)) {
                        try Task.checkCancellation()
                        try requireSmartReadingSession(latest, bookID: readingBookID, sessionID: sessionID)
                        activity = "正在整理所选范围的读后综合…"
                        updateAIProgressDetail(aiRunID, detail: "整理所选范围的读后综合")
                        var result = try await reader.synthesizeNext(project: latest, settings: requestSettings, apiKey: requestKey, allowedUnitIDs: analysisIDs)
                        try Task.checkCancellation(); result.smartReading?.updatedAt = Date()
                        markAIProgressSaving(aiRunID)
                        try await repository.save(result); publish(result); requestsUsed = await reader.requestCount
                    }
                    guard var latest = book else { throw CancellationError() }
                    try requireSmartReadingSession(latest, bookID: readingBookID, sessionID: sessionID)
                    latest.smartReading?.status = .completed; latest.smartReading?.currentUnitID = nil
                    latest.smartReading?.updatedAt = Date()
                    let reviewCount = latest.units.filter { unitIDs.contains($0.id) && (latest.coverage[$0.id]?.status == .needsReview || $0.warning != nil) }.count
                    let excludedCount = latest.units.filter { unitIDs.contains($0.id) && ReadingLedger.isDeferred(unitID: $0.id, in: latest) }.count
                    let blankCount = latest.units.filter { unitIDs.contains($0.id) && SmartReadingRuntime.isConfirmedBlank($0, in: latest) }.count
                    let message = (analysisIDs.isEmpty ? "本轮没有可分析的文字。" : "本轮可分析内容已处理并保存综合。") +
                        (excludedCount > 0 ? "\(excludedCount) 处明确暂缓，仍未读取。" : "") + (blankCount > 0 ? "\(blankCount) 处由你确认为空白。" : "") +
                        (reviewCount > 0 ? "其中 \(reviewCount) 处仍需核对原文。" : "处理覆盖不等于理解无遗漏。")
                    latest.smartReading?.lastMessage = message
                    try await repository.save(latest); publish(latest); activity = message
                } catch { finishAIProgress(aiRunID, error: error); await finishSmartReadingAfterError(error, bookID: readingBookID) }
                requestsUsed = await reader.requestCount
                activeReadingUnitID = nil; isSmartReadingRunning = false; isBusy = false
            }
        } catch { handle(error) }
    }

    func pause() {
        guard !restoringWorkspaceMemory, !isSavingDocument, !isExportingProject, !isImportingBookCommit, !isCommittingLocalWrite else { return }
        task?.cancel(); activity = "正在暂停，已保存检查点可在下次继续。"
    }

    private func smartReadingNeedsOCR(in project: BookProject, unitIDs: Set<String>) -> Bool {
        project.units.contains { unitIDs.contains($0.id) && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !ReadingLedger.isDeferred(unitID: $0.id, in: project) && !SmartReadingRuntime.isConfirmedBlank($0, in: project) }
    }

    private func requireSmartReadingSession(_ project: BookProject, bookID: String, sessionID: String) throws {
        // The initial manifest is fully validated before the run. The write lock
        // prevents host OCR/editing during this task, and AI tools cannot edit source.
        guard project.id == bookID, let session = project.smartReading, session.id == sessionID,
              session.sourceHash == project.sourceHash else { throw CancellationError() }
    }

    private func finishSmartReadingAfterError(_ error: Error, bookID: String) async {
        let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
        let budget = error is ReadingWorkflowBudgetPause || error.localizedDescription.contains("预算")
        if var current = book, current.id == bookID, current.smartReading != nil {
            current.smartReading?.status = cancelled || budget ? .paused : .failed
            current.smartReading?.updatedAt = Date()
            current.smartReading?.lastMessage = String(error.localizedDescription.prefix(2000))
            do { try await repository.save(current); publish(current) }
            catch { errorMessage = "暂停状态保存失败：" + error.localizedDescription }
        }
        if cancelled { activity = "智能阅读已暂停；从最后一次成功保存的检查点继续。" }
        else if budget { activity = "本轮预算已用完，检查点已保留；点击继续才会开始新一轮请求。" }
        else { handle(error) }
    }
}
