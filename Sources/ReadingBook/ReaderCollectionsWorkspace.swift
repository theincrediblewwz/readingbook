import SwiftUI
import ReadingCore

@MainActor extension AppStore {
    var readerCollections: ReaderCollectionState { book.map { ReaderCollectionRuntime.state(in: $0) } ?? .init() }
    var collectionOwnerKey: String { libraryRootURL.path + "|" + (bookID ?? "") + "|" + (book?.sourceHash ?? "") }
    var foldedQueryAnswers: [ChatMessage] {
        let collapsed = Set(readerCollections.collapsedReferenceIDs)
        return currentQueryHistory.filter { $0.role == "assistant" && collapsed.contains("chat:" + $0.id) }
    }
    var visibleQueryHistory: [ChatMessage] {
        guard let book else { return [] }
        let hidden = ReaderCollectionRuntime.turnMessageIDs(for: Set(foldedQueryAnswers.map(\.id)), in: book)
        return currentQueryHistory.filter { !hidden.contains($0.id) }
    }
    func organizeReaderCollections(_ command: ReaderCollectionCommand, owner: WorkspacePickerOwner? = nil) async {
        guard !isOrganizingCollections, !readerEditUndo.applying, !storageState.working, owner?.matches(self) ?? true, let project = book else { return }
        let root = libraryRootURL, repository = repository
        isOrganizingCollections = true; defer { isOrganizingCollections = false }
        do {
            let expected: ReadingNotePlacementExpectation?
            if case .setNotePlacement(let id, _) = command { expected = .unchanged(project.readerCollections?.notePlacements?[id]) } else { expected = nil }
            let result = try await repository.organizeReaderCollections(bookID: project.id, sourceHash: project.sourceHash, command: command, expectedPlacement: expected)
            guard libraryRootURL == root, bookID == project.id, book?.sourceHash == project.sourceHash else { return }
            if case .setNotePlacement(let id, _) = command,
               result.readerCollections?.notePlacements?[id] != project.readerCollections?.notePlacements?[id] {
                readerEditUndo.record(.placement(documentID: id, expected: result.readerCollections?.notePlacements?[id], desired: project.readerCollections?.notePlacements?[id]), title: "便签位置", owner: WorkspacePickerOwner(store: self))
            }
            publish(result); queryMemoryRevision += 1
        } catch { if libraryRootURL == root && bookID == project.id { errorMessage = error.localizedDescription } }
    }
    func collapseCurrentQueryAnswers() async {
        await organizeReaderCollections(.collapse(currentQueryHistory.filter { $0.role == "assistant" }.map { "chat:" + $0.id }, true))
    }
    func archiveFoldedQueryAnswers() async {
        let ids = foldedQueryAnswers.map { "chat:" + $0.id }
        guard !ids.isEmpty else { return }
        await organizeReaderCollections(.archive(ids, newHistoryFolderTitle))
    }
    var newHistoryFolderTitle: String {
        Date.now.formatted(.dateTime.month().day()) + " · " + (selectedUnit?.page.map { "第\($0)页" } ?? "阅读讨论")
    }
    func setReferencedAnswer(_ id: String, included: Bool, forCompanion: Bool = false) {
        guard !(forCompanion ? isCompanionGenerating : isQueryBusy), let book, ReaderCollectionRuntime.reference(id, in: book) != nil else { return }
        var selected = forCompanion ? companionReferencedAnswerIDs : queryReferencedAnswerIDs
        if included {
            guard selected.count < 16 || selected.contains(id) else { errorMessage = "一次最多引用16条历史回答。"; return }
            selected.insert(id)
        } else { selected.remove(id) }
        if forCompanion { companionReferencedAnswerIDs = selected } else { queryReferencedAnswerIDs = selected }
    }
    func returnToOriginalReading() {
        guard finishWorkspaceNotesEditing() else { return }
        requestedWorkspaceRoute = "reader"
        readingCompanionVisible = false
        selectedObjectID = nil
        pdfNavigationToken += 1
    }
}

/// One attempt per empty/collapsed conversation cycle. Reopening the panel does
/// not spend another request; occupied -> all collapsed/archived starts a cycle.
@MainActor final class ReadingQuestionSuggestionState: ObservableObject {
    @Published private(set) var questions: [String] = []
    private var owner = ""
    private var attempted = false
    private var occupied = false
    private var loaded = false
    private var loading = false
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func cancelActive() { task?.cancel(); task = nil; generation = UUID() }
    func reset() { cancelActive(); questions = []; owner = ""; attempted = false; occupied = false; loaded = false; loading = false }
    func refresh(store: AppStore, active: Bool, eligible: Bool) {
        let key = store.collectionOwnerKey + "|" + store.queryScope.rawValue + "|" + (store.selectedUnitID ?? "") + "|" + store.currentQueryPreferences.contextIdentity + "|" + store.settings.baseURL + "|" + store.settings.model
        if key != owner { reset(); owner = key }
        let cache = ReadingSuggestionCache.shared, cacheRoot = store.libraryRootURL
        if !eligible {
            let changed = !occupied || !loaded
            occupied = true; loaded = true; loading = false; cancelActive()
            if changed { Task { try? await cache.write(.init(occupied: true), root: cacheRoot, identity: key) } }
            return
        }
        if active, !loaded {
            guard !loading else { return }; loading = true
            let token = generation
            task = Task { [weak self, weak store] in
                let value = await cache.read(root: cacheRoot, identity: key)
                guard let self, let store, !Task.isCancelled, self.owner == key, self.generation == token else { return }
                self.loaded = true; self.loading = false
                if let value { self.questions = value.questions; self.attempted = !value.questions.isEmpty; self.occupied = value.occupied }
                self.refresh(store: store, active: active, eligible: eligible)
            }
            return
        }
        if occupied {
            occupied = false; attempted = false; questions = []; cancelActive()
            Task { try? await cache.write(.init(), root: cacheRoot, identity: key) }
        }
        guard active, !attempted, !store.isQueryBusy, !store.storageState.working,
              !store.settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let book = store.book else { return }
        attempted = true
        let context = store.queryReadingContext, scope = store.queryScope, documents = store.queryDocumentIDs.map { $0.sorted() }
        let root = store.libraryRootURL, coordinator = store.sharedAIRequests, limit = store.aiConcurrencyLimit
        var settings = store.settings; settings.transportSessionID = "readingbook-" + book.id + "-questions"
        let apiKey = store.apiKey, token = generation
        task = Task { [weak self, weak store] in
            var run: AIRequestRun?
            defer { if let run { run.finish(); Task { await coordinator.endRun(run) } } }
            do {
                // Opening the panel shares just the current selected scope.
                let worker = Task.detached(priority: .utility) { try ReadingQuerySnapshot.freeze(scope: scope, in: book, context: context, documentIDs: documents) }
                let snapshot = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                run = try await coordinator.beginManagedRun(settings: settings, maximumConcurrency: limit, independentBudget: true)
                let reader = AIReader(coordinator: coordinator, lane: .background)
                await reader.setRequestRun(run)
                let result = try await reader.suggestReadingQuestions(snapshot: snapshot, title: book.title, settings: settings, apiKey: apiKey)
                try Task.checkCancellation()
                guard let self, let store, self.generation == token, self.owner == key,
                      store.libraryRootURL == root, store.bookID == book.id, store.book?.sourceHash == book.sourceHash else { return }
                self.questions = result.questions
                try? await cache.write(.init(questions: result.questions), root: root, identity: key)
            } catch {
                // Offline, missing configuration, cancellation and invalid model
                // responses have no fixed fallback masquerading as a suggestion.
                guard let self, self.generation == token else { return }
                self.questions = []
            }
        }
    }
}
