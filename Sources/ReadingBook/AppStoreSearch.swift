import Foundation
import ReadingCore

extension AppStore {
    /// Process-local identity only, never persisted, displayed or logged.
    var readingSearchAIIdentity: Int {
        [selectedServiceID ?? "", settings.baseURL, settings.model, String(settings.maxOutputTokens),
         String(settings.maxRequestsPerRun), String(settings.contextWindowTokens ?? 0),
         settings.tokenLimitParameter ?? "", apiKey].hashValue
    }

    func inferNativeSearchKeywords(_ query: String, owner: WorkspacePickerOwner) async throws -> [String] {
        let identity = readingSearchAIIdentity
        guard owner.matches(self) else { throw CancellationError() }
        var configuration = settings
        configuration.transportSessionID = "readingbook-native-search-" + UUID().uuidString
        let key = apiKey, coordinator = sharedAIRequests
        let run = try await coordinator.beginManagedRun(settings: configuration, maximumConcurrency: aiConcurrencyLimit)
        defer { run.finish(); Task { await coordinator.endRun(run) } }
        let sources = book.map { [LibrarySourceSnapshot(project: $0)] } ?? []
        let worker = Task.detached(priority: .utility) { try LibrarySearchLanguageProfile.identify(in: sources) }
        let profile = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        // The language hint for PDF discovery is supplementary; offline script
        // matching and actual source validation do not depend on recognition.
        guard !Task.isCancelled, owner.matches(self), readingSearchAIIdentity == identity else { throw CancellationError() }
        let reader = AIReader(coordinator: coordinator, lane: .foreground)
        let plan = try await reader.expandLibrarySearch(query: query, languageProfile: profile, settings: configuration, apiKey: key)
        guard !Task.isCancelled, owner.matches(self), readingSearchAIIdentity == identity else { throw CancellationError() }
        return plan.keywords
    }
}
