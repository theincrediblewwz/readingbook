import SwiftUI
import ReadingCore

/// One floating search owns its work. Changing input, scope, library, or source
/// cancels both workers; a late provider response cannot replace newer results.
@MainActor final class LibrarySearchSession: ObservableObject {
    @Published private(set) var response: LibrarySearchResponse?
    @Published private(set) var languageProfile: LibrarySearchLanguageProfile?
    @Published private(set) var expandedKeywords: [String] = []
    @Published private(set) var searching = false
    @Published private(set) var expanding = false
    @Published var errorMessage = ""

    private struct Input: Sendable {
        let query: String
        let snapshots: [LibrarySourceSnapshot]
        let bookID: String?
        let root: String
    }
    private var input: Input?
    private var generation = UUID()
    private var localTask: Task<Void, Never>?
    private var expansionTask: Task<Void, Never>?

    func schedule(query: String, snapshots: [LibrarySourceSnapshot], bookID: String?, root: String, debounce: Bool = true) {
        cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = Input(query: text, snapshots: snapshots, bookID: bookID, root: root)
        input = next; response = nil; languageProfile = nil; expandedKeywords = []; errorMessage = ""
        guard !text.isEmpty else { return }
        let owner = generation
        searching = true
        localTask = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(nanoseconds: 240_000_000) }
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    let result = try LibraryTextSearch.search(query: text, snapshots: snapshots, bookID: bookID)
                    let language = try LibrarySearchLanguageProfile.identify(in: snapshots, bookID: bookID)
                    return (result, language)
                }
                let (result, language) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, self.generation == owner else { return }
                self.response = result; self.languageProfile = language; self.searching = false
            } catch {
                guard let self, self.generation == owner, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription; self.searching = false
            }
        }
    }

    /// Explicitly user-started. Existing local results remain usable while the
    /// model suggests words; only real matches from the frozen scope are shown.
    func expand(using operation: @escaping @Sendable (String, LibrarySearchLanguageProfile) async throws -> LibrarySearchExpansionPlan) {
        guard let input, !input.query.isEmpty, !expanding else { return }
        localTask?.cancel(); expansionTask?.cancel(); generation = UUID()
        let owner = generation
        searching = false; expanding = true; errorMessage = ""
        expansionTask = Task { [weak self] in
            do {
                let languageWorker = Task.detached(priority: .userInitiated) {
                    try LibrarySearchLanguageProfile.identify(in: input.snapshots, bookID: input.bookID)
                }
                let language = try await withTaskCancellationHandler(operation: { try await languageWorker.value }, onCancel: { languageWorker.cancel() })
                let plan = try await operation(input.query, language)
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    try LibraryTextSearch.search(query: input.query, snapshots: input.snapshots,
                                                 bookID: input.bookID, additionalQueries: plan.keywords)
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, self.generation == owner else { return }
                self.response = result; self.languageProfile = language; self.expandedKeywords = plan.keywords
                self.expanding = false
            } catch {
                guard let self, self.generation == owner, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription; self.expanding = false
            }
        }
    }

    /// Stop does not erase already verified local results.
    func cancel() {
        generation = UUID(); localTask?.cancel(); expansionTask?.cancel()
        localTask = nil; expansionTask = nil; searching = false; expanding = false
    }
}
