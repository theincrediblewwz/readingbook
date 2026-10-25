import SwiftUI
import ReadingCore

/// Local counters are observed only by the small background card. Stream bytes
/// must not invalidate the book, original page, graph or whole companion list.
final class ReadingAssistanceProgressMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AIProgressEvent] = []
    private var scheduled = false
    private var closed = false
    func append(_ event: AIProgressEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        if let last = events.last, last.phase == event.phase, last.requestID == event.requestID { events[events.count - 1] = event }
        else { events.append(event) }
        guard !scheduled else { return false }; scheduled = true; return true
    }
    func take(close: Bool = false) -> [AIProgressEvent] {
        lock.lock(); defer { lock.unlock() }
        if close { closed = true }
        let result = events; events = []; scheduled = false; return result
    }
}

@MainActor final class TeacherBackgroundState: ObservableObject {
    struct Entry {
        var runID = UUID()
        var progress = AIProgressPresentationState()
        var record: TeacherBackgroundRecord?
        var fromCache = false
        var message: String?
        var running = false
    }
    @Published private(set) var entries: [String: Entry] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    func key(objectID: String, unitID: String? = nil, store: AppStore) -> String {
        store.libraryRootURL.path + "|" + (store.bookID ?? "") + "|" + (store.book?.sourceHash ?? "") + "|" + objectID + "|" + (unitID ?? store.selectedUnitID ?? "") + "|" + (store.book?.temporalKnowledge?.profile?.avoidsSpoilers != false ? "safe" : "open")
    }
    func cancelAll() {
        // Keep each run's counters until its cancellation handler has persisted
        // the request history. Keys already include library/book/source scope.
        for task in tasks.values { task.cancel() }
    }
    func cancel(objectID: String, unitID: String? = nil, store: AppStore) { tasks[key(objectID: objectID, unitID: unitID, store: store)]?.cancel() }

    func load(objectID: String, unitID: String? = nil, store: AppStore) {
        let key = key(objectID: objectID, unitID: unitID, store: store)
        guard tasks[key] == nil, let book = store.book else { return }
        guard tasks.count < 3 else {
            var value = Entry(); value.message = "已有几处介绍正在生成，稍后再试。"; entries[key] = value
            return
        }
        let root = store.libraryRootURL.path, bookID = book.id, repository = store.repository
        let currentUnitID = unitID ?? store.selectedUnitID, avoidsSpoilers = store.book?.temporalKnowledge?.profile?.avoidsSpoilers != false
        var requestSettings = store.settings
        requestSettings.transportSessionID = "readingbook-" + bookID + "-teacher"
        let settings = requestSettings
        let apiKey = store.apiKey, coordinator = store.sharedAIRequests, limit = store.aiConcurrencyLimit
        let configured = !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var entry = Entry(); entry.running = true; entry.progress.startedAt = Date(); entry.progress.status = .running
        entry.progress.title = "老师讲解"; entry.progress.bookID = bookID
        let runID = entry.runID, mailbox = ReadingAssistanceProgressMailbox()
        entries[key] = entry
        tasks[key] = Task { [weak self, weak store] in
            var began = false
            defer {
                if began { Task { await coordinator.endRun() } }
                if self?.entries[key]?.runID == runID { self?.tasks[key] = nil }
            }
            do {
                let frozen = Task.detached(priority: .userInitiated) {
                    let request = try TeacherBackgroundRequest.freeze(objectID: objectID, in: book,
                        currentUnitID: currentUnitID, avoidsSpoilers: avoidsSpoilers)
                    return (request, ReadingKnowledgeRuntime.background(for: request, in: book))
                }
                let (request, cached) = try await withTaskCancellationHandler(operation: { try await frozen.value }, onCancel: { frozen.cancel() })
                try Task.checkCancellation()
                guard let self, self.entries[key]?.runID == runID else { return }
                if let cached {
                    self.complete(key, runID: runID, record: cached, cached: true)
                    return
                }
                guard configured else {
                    self.complete(key, runID: runID, message: "设置模型后，就可以在这里听介绍。")
                    return
                }
                try await coordinator.beginRun(settings: settings, maximumConcurrency: limit); began = true
                let reader = AIReader(coordinator: coordinator, lane: .foreground)
                await reader.setProgressHandler { [weak self] event in
                    guard mailbox.append(event) else { return }
                    Task { @MainActor [weak self] in self?.flush(mailbox, key: key, runID: runID) }
                }
                let record = try await reader.teacherBackground(request: request, settings: settings, apiKey: apiKey)
                try Task.checkCancellation()
                self.flush(mailbox, key: key, runID: runID, close: true)
                if var state = self.entries[key], state.runID == runID {
                    state.progress.phase = .saving; self.entries[key] = state
                }
                let history = self.history(key, status: "returned")
                let saved = try await repository.saveTeacherBackground(bookID: bookID, record: record, requestHistory: history)
                self.complete(key, runID: runID, record: ReadingKnowledgeRuntime.background(for: request, in: saved) ?? record)
                if let store, store.bookID == bookID, store.libraryRootURL.path == root {
                    store.publish(saved); store.requestsUsed = await coordinator.requestsUsed
                }
            } catch {
                guard let self, self.entries[key]?.runID == runID else { return }
                self.flush(mailbox, key: key, runID: runID, close: true)
                let stopped = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                let records = self.history(key, status: stopped ? "paused" : "failed")
                if !records.isEmpty {
                    // History is independent metadata; a cancelled transport must
                    // not leave the same request shown as still running.
                    let saving = Task.detached { try? await repository.recordAIRequestHistory(bookID: bookID, sourceHash: book.sourceHash, records: records) }
                    _ = await saving.value
                }
                self.complete(key, runID: runID, message: stopped ? "已停止，已有介绍保留。" : error.localizedDescription)
            }
        }
    }
    private func flush(_ mailbox: ReadingAssistanceProgressMailbox, key: String, runID: UUID, close: Bool = false) {
        let events = mailbox.take(close: close)
        guard var value = entries[key], value.runID == runID, value.running else { return }
        for event in events { value.progress.apply(event) }
        entries[key] = value
    }
    private func complete(_ key: String, runID: UUID, record: TeacherBackgroundRecord? = nil, cached: Bool = false, message: String? = nil) {
        guard var value = entries[key], value.runID == runID else { return }
        value.running = false; value.progress.finishedAt = Date(); value.progress.status = message == nil ? .completed : .paused
        value.record = record; value.fromCache = cached; value.message = message; entries[key] = value
        if entries.count > 40, let oldest = entries.first(where: { !$0.value.running && $0.key != key })?.key { entries[oldest] = nil }
    }
    private func history(_ key: String, status: String) -> [AIRequestHistoryRecord] {
        guard let value = entries[key] else { return [] }
        return value.progress.requests.map { request in
            AIRequestHistoryRecord(id: request.id.uuidString, title: "老师讲解", number: request.number,
                startedAt: request.startedAt, finishedAt: max(request.startedAt, request.finishedAt ?? Date()), status: status,
                reasoningCharacters: request.reasoning, answerCharacters: request.output)
        }
    }
}
