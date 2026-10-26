import SwiftUI
import ReadingCore

/// Navigation owns its small observable state. Stream counters must not
/// invalidate the PDF or every consumer of AppStore on every token.
@MainActor final class ReaderBookOutlineState: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, locked, failed }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var original: [BookOutlineEntry] = []
    @Published private(set) var generated: GeneratedBookOutline?
    @Published private(set) var generating = false
    let progressState = AIProgressObservableState()
    var progress: AIProgressPresentationState {
        get { progressState.value }
        set { progressState.value = newValue }
    }
    @Published private(set) var remainingRequestCount = 0
    @Published private(set) var message: String?
    private var preparation: BookOutlinePreparation?
    private var owner: String?
    private var task: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var metadataRun = UUID()
    private var runID: UUID?

    func cancel() { task?.cancel(); metadataTask?.cancel() }

    func load(owner: String, project: BookProject?, url: URL?, password: String?) async {
        if self.owner != owner { task?.cancel(); metadataTask?.cancel(); metadataRun = UUID(); runID = nil; generating = false }
        self.owner = owner
        original = []; generated = nil; preparation = nil; remainingRequestCount = 0; message = nil; phase = .loading
        guard let project, let url else { phase = .idle; return }
        let worker = Task.detached(priority: .userInitiated) {
            let original = try BookOutlineRuntime.originalPDFOutline(at: url, expectedSourceHash: project.sourceHash, password: password)
            try Task.checkCancellation()
            let preparation = original.isEmpty ? try BookOutlineRuntime.prepare(in: project) : nil
            return (original, preparation)
        }
        do {
            let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard self.owner == owner else { return }
            original = value.0; preparation = value.1; generated = value.1?.cached; phase = .ready
            remainingRequestCount = value.1?.remainingBatches.filter { $0.candidateCount > 0 }.count ?? 0
        } catch is PDFPasswordError {
            guard !Task.isCancelled, self.owner == owner else { return }
            phase = .locked; message = "解锁原书后显示目录。"
        } catch {
            guard !Task.isCancelled, self.owner == owner else { return }
            phase = .failed; message = error.localizedDescription
        }
    }

    /// Another window may publish a newer host directory without changing the
    /// source. Validate that metadata in a worker; do not reopen or rehash the PDF.
    func refreshDerived(from project: BookProject?) {
        guard phase == .ready, original.isEmpty, !generating, let preparation, let project, let owner,
              project.generatedOutline != generated else { return }
        metadataTask?.cancel()
        let generation = UUID(); metadataRun = generation
        metadataTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
                let worker = Task.detached(priority: .userInitiated) { try BookOutlineRuntime.prepare(in: project) }
                let checked = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, self.owner == owner, self.metadataRun == generation, !self.generating,
                      checked.sourceFingerprint == preparation.sourceFingerprint else { return }
                self.generated = checked.cached
                self.preparation = checked
                self.remainingRequestCount = checked.remainingBatches.filter { $0.candidateCount > 0 }.count
            } catch {
                guard !Task.isCancelled, let self, self.owner == owner, self.metadataRun == generation else { return }
                self.message = "目录更新需要重新核对，可重新打开目录。"
            }
        }
    }

    func generate(store: AppStore) {
        guard !generating, phase == .ready, original.isEmpty, let preparation,
              let project = store.book, let owner, !store.storageState.working else { return }
        let scanned = generated?.scannedUnitCount ?? 0
        let batches = preparation.batches.filter { $0.endUnit > scanned }
        guard !batches.isEmpty else { return }
        let needsModel = batches.contains { $0.candidateCount > 0 }
        guard !needsModel || !store.settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "连接模型后，可以整理本书目录。"; return
        }
        let root = store.libraryRootURL, repository = store.repository, coordinator = store.sharedAIRequests
        var requestSettings = store.settings; requestSettings.transportSessionID = "readingbook-" + project.id + "-outline"
        let settings = requestSettings, apiKey = store.apiKey, limit = store.aiConcurrencyLimit
        let run = UUID(), mailbox = ReadingAssistanceProgressMailbox()
        runID = run; generating = true; message = nil
        progress = AIProgressPresentationState(); progress.title = "整理目录"; progress.status = .running; progress.startedAt = Date()
        task = Task { [weak self, weak store] in
            var managed: AIRequestRun?
            defer {
                if let managed { managed.finish(); Task { await coordinator.endRun(managed) } }
                if self?.runID == run { self?.generating = false; self?.task = nil }
            }
            do {
                if needsModel { managed = try await coordinator.beginManagedRun(settings: settings, maximumConcurrency: limit) }
                let reader = AIReader(coordinator: coordinator, lane: .foreground)
                await reader.setProgressHandler { [weak self] event in
                    guard mailbox.append(event) else { return }
                    Task { @MainActor [weak self] in self?.flush(mailbox, run: run) }
                }
                for range in batches {
                    try Task.checkCancellation()
                    guard let self, self.owner == owner, self.runID == run,
                          let store, store.bookID == project.id, store.libraryRootURL == root, !store.storageState.working else { throw CancellationError() }
                    if (self.generated?.scannedUnitCount ?? 0) >= range.endUnit { continue }
                    let builder = Task.detached(priority: .userInitiated) { try preparation.request(for: range) }
                    let batch = try await withTaskCancellationHandler(operation: { try await builder.value }, onCancel: { builder.cancel() })
                    try Task.checkCancellation()
                    let entries: [BookOutlineEntry] = batch.candidates.isEmpty ? [] : try await reader.generateBookOutline(request: batch, settings: settings, apiKey: apiKey)
                    try Task.checkCancellation()
                    self.flush(mailbox, run: run)
                    let history: [AIRequestHistoryRecord] = batch.candidates.isEmpty ? [] : self.progress.requests.suffix(1).map {
                        AIRequestHistoryRecord(id: $0.id.uuidString, title: "整理目录", number: $0.number, startedAt: $0.startedAt,
                            finishedAt: max($0.startedAt, $0.finishedAt ?? Date()), status: "returned",
                            reasoningCharacters: $0.reasoning, answerCharacters: $0.output)
                    }
                    let saved = try await repository.saveBookOutline(batch: batch, entries: entries, requestHistory: history)
                    guard store.bookID == project.id, store.libraryRootURL == root, self.owner == owner, self.runID == run else { throw CancellationError() }
                    if store.publish(saved) { self.generated = saved.generatedOutline }
                    else {
                        // A newer in-memory publication won. Validate its source
                        // and outline in the background instead of displaying the
                        // older saved snapshot or rolling the visible directory back.
                        guard let current = store.book else { throw CancellationError() }
                        let revision = store.projectRevision
                        let checker = Task.detached(priority: .userInitiated) { try BookOutlineRuntime.prepare(in: current) }
                        let checked = try await withTaskCancellationHandler(operation: { try await checker.value }, onCancel: { checker.cancel() })
                        guard store.bookID == project.id, store.libraryRootURL == root, store.projectRevision == revision,
                              checked.sourceFingerprint == batch.sourceFingerprint,
                              let canonicalOutline = checked.cached, canonicalOutline.scannedUnitCount >= batch.endUnit else {
                            throw ReadingError.invalid("目录已保存，当前内容正在更新；重新打开目录后可继续。")
                        }
                        self.generated = canonicalOutline
                    }
                    if range.candidateCount > 0 { self.remainingRequestCount = max(0, self.remainingRequestCount - 1) }
                    store.requestsUsed = await coordinator.requestsUsed
                }
                guard let self, self.runID == run else { return }
                self.progress.status = .completed; self.progress.finishedAt = Date()
                self.message = self.generated?.entries.isEmpty == true ? "未找到可信的章节标题，可继续搜索原文。" : nil
            } catch {
                guard let self, self.runID == run else { return }
                self.flush(mailbox, run: run)
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                self.progress.status = .paused; self.progress.finishedAt = Date()
                self.message = cancelled ? "已暂停，整理出的目录已保留。" : error.localizedDescription
                let history = self.progress.requests.suffix(1).map {
                    AIRequestHistoryRecord(id: $0.id.uuidString, title: "整理目录", number: $0.number, startedAt: $0.startedAt,
                        finishedAt: max($0.startedAt, $0.finishedAt ?? Date()), status: cancelled ? "paused" : "failed",
                        reasoningCharacters: $0.reasoning, answerCharacters: $0.output)
                }
                if !history.isEmpty { _ = try? await repository.recordAIRequestHistory(bookID: project.id, sourceHash: project.sourceHash, records: history) }
            }
        }
    }

    private func flush(_ mailbox: ReadingAssistanceProgressMailbox, run: UUID) {
        let events = mailbox.take()
        guard runID == run else { return }
        for event in events { progress.apply(event) }
    }
}
