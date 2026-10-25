import SwiftUI
import ReadingCore

@MainActor final class SentenceTranslationState: ObservableObject {
    struct Entry {
        var runID = UUID()
        var progress = AIProgressPresentationState()
        var markdown: String?
        var message: String?
        var running = false
        var cached = false
    }
    @Published private(set) var entries: [String: Entry] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    func key(anchor: SourceAnchor, store: AppStore) -> String {
        store.libraryRootURL.path + "|" + (store.bookID ?? "") + "|" + anchor.sourceHash + "|" + anchor.unitTextHash + "|" + anchor.id
    }
    func cancelAll() { for task in tasks.values { task.cancel() }; tasks.removeAll(); entries = [:] }
    func cancel(anchor: SourceAnchor, store: AppStore) { tasks[key(anchor: anchor, store: store)]?.cancel() }
    func load(anchor: SourceAnchor, store: AppStore, generate: Bool) {
        let key = key(anchor: anchor, store: store)
        guard tasks[key] == nil, let project = store.book else { return }
        if entries[key]?.markdown != nil { return }
        guard tasks.count < 3 else { return }
        let repository = store.repository, root = store.libraryRootURL, coordinator = store.sharedAIRequests
        var settings = store.settings; settings.transportSessionID = "readingbook-" + project.id + "-sentence"
        let requestSettings = settings, apiKey = store.apiKey, limit = store.aiConcurrencyLimit
        var entry = Entry(); entry.running = true; entry.progress.startedAt = Date(); entry.progress.status = .running
        entry.progress.bookID = project.id; entry.progress.title = "句旁翻译"
        let runID = entry.runID, mailbox = ReadingAssistanceProgressMailbox()
        entries[key] = entry
        tasks[key] = Task { [weak self, weak store] in
            var began = false
            defer {
                if began { Task { await coordinator.endRun() } }
                if self?.entries[key]?.runID == runID { self?.tasks[key] = nil }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    let request = try SentenceTranslationRequest.freeze(anchor: anchor, in: project)
                    return (request, request.cachedLayer(in: project))
                }
                let (request, cached) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, self.entries[key]?.runID == runID else { return }
                if let cached { self.finish(key, runID: runID, markdown: cached.markdown, cached: true); return }
                guard generate else { self.finish(key, runID: runID); return }
                guard !requestSettings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.finish(key, runID: runID, message: "连接模型后，可以翻译这句话。"); return
                }
                try await coordinator.beginRun(settings: requestSettings, maximumConcurrency: limit); began = true
                let reader = AIReader(coordinator: coordinator, lane: .foreground)
                await reader.setProgressHandler { [weak self] event in
                    guard mailbox.append(event) else { return }
                    Task { @MainActor [weak self] in self?.flush(mailbox, key: key, runID: runID) }
                }
                let markdown = try await reader.translateSentence(request: request, settings: requestSettings, apiKey: apiKey)
                try Task.checkCancellation()
                self.flush(mailbox, key: key, runID: runID, close: true)
                if var value = self.entries[key], value.runID == runID { value.progress.phase = .saving; self.entries[key] = value }
                let records = self.history(key, status: "returned")
                let saved = try await repository.saveSentenceTranslation(request: request, markdown: markdown, model: requestSettings.model, requestHistory: records)
                self.finish(key, runID: runID, markdown: request.cachedLayer(in: saved)?.markdown ?? markdown)
                if let store, store.bookID == project.id, store.libraryRootURL == root {
                    store.publish(saved); store.requestsUsed = await coordinator.requestsUsed
                }
            } catch {
                guard let self, self.entries[key]?.runID == runID else { return }
                self.flush(mailbox, key: key, runID: runID, close: true)
                let stopped = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                let records = self.history(key, status: stopped ? "paused" : "failed")
                if !records.isEmpty {
                    _ = await Task.detached { try? await repository.recordAIRequestHistory(bookID: project.id, sourceHash: project.sourceHash, records: records) }.value
                }
                self.finish(key, runID: runID, message: stopped ? "已停止，已有译文保留。" : error.localizedDescription)
            }
        }
    }
    private func flush(_ mailbox: ReadingAssistanceProgressMailbox, key: String, runID: UUID, close: Bool = false) {
        let events = mailbox.take(close: close)
        guard var entry = entries[key], entry.runID == runID, entry.running else { return }
        for event in events { entry.progress.apply(event) }
        entries[key] = entry
    }
    private func finish(_ key: String, runID: UUID, markdown: String? = nil, message: String? = nil, cached: Bool = false) {
        guard var entry = entries[key], entry.runID == runID else { return }
        entry.running = false; entry.markdown = markdown; entry.message = message; entry.cached = cached
        entry.progress.finishedAt = Date(); entry.progress.status = message == nil ? .completed : .paused
        entries[key] = entry
        if entries.count > 48, let old = entries.first(where: { !$0.value.running && $0.key != key })?.key { entries[old] = nil }
    }
    private func history(_ key: String, status: String) -> [AIRequestHistoryRecord] {
        (entries[key]?.progress.requests ?? []).map {
            AIRequestHistoryRecord(id: $0.id.uuidString, title: "句旁翻译", number: $0.number, startedAt: $0.startedAt,
                finishedAt: max($0.startedAt, $0.finishedAt ?? Date()), status: status,
                reasoningCharacters: $0.reasoning, answerCharacters: $0.output)
        }
    }
}

struct SentenceTranslationCard: View {
    @EnvironmentObject private var store: AppStore
    let anchor: SourceAnchor
    var fallbackMarkdown: String? = nil
    var body: some View { SentenceTranslationCardBody(state: store.sentenceTranslation, anchor: anchor, fallbackMarkdown: fallbackMarkdown) }
}

private struct SentenceTranslationCardBody: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var state: SentenceTranslationState
    let anchor: SourceAnchor
    let fallbackMarkdown: String?
    private var key: String { state.key(anchor: anchor, store: store) }
    var body: some View {
        let entry = state.entries[key]
        VStack(alignment: .leading, spacing: 10) {
            if let markdown = entry?.markdown {
                HStack { Text("句译").font(.system(size: 12, weight: .medium)); Spacer(); Text(entry?.cached == true ? "本地已存" : "已保存").font(.system(size: 11)).foregroundStyle(.secondary) }
                MarkdownText(markdown: markdown).clipShape(RoundedRectangle(cornerRadius: 14))
            } else if let entry, entry.running {
                HStack {
                    ProgressView().controlSize(.small); Text(entry.progress.phaseTitle).font(.system(size: 13))
                    Spacer(); Button { state.cancel(anchor: anchor, store: store) } label: { Image(systemName: "stop.circle") }.buttonStyle(.plain).help("停止翻译")
                }
                if entry.progress.reasoningCharacters > 0 || entry.progress.answerCharacters > 0 {
                    Text("思考 \(entry.progress.reasoningCharacters.formatted()) · 输出 \(entry.progress.answerCharacters.formatted()) 字符").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                if let fallbackMarkdown { MarkdownText(markdown: fallbackMarkdown).clipShape(RoundedRectangle(cornerRadius: 14)) }
                if let message = entry?.message { Text(message).font(.system(size: 13)).foregroundStyle(.secondary) }
                Button { state.load(anchor: anchor, store: store, generate: true) } label: { Label("翻译这句", systemImage: "character.bubble") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("生成后保存在本书，下次直接读取")
            }
        }.padding(12).background(Palette.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .task(id: key) { state.load(anchor: anchor, store: store, generate: false) }
    }
}
