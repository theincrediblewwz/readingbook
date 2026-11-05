import Foundation
import ReadingCore

extension AppStore {
    /// Process-local identity only, never persisted, displayed or logged.
    var readingSearchAIIdentity: Int {
        [selectedServiceID ?? "", settings.baseURL, settings.model, String(settings.maxOutputTokens),
         String(settings.maxRequestsPerRun), String(settings.contextWindowTokens ?? 0),
         settings.tokenLimitParameter ?? "", apiKey].hashValue
    }

    func inferNativeSearchKeywords(_ query: String, owner: WorkspacePickerOwner) async throws -> LibrarySearchExpansionPlan {
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
        return plan
    }
}

extension AppStore {
    func makeInlinePDFSearch(_ query: String, owner: WorkspacePickerOwner, repositoryOwner: UUID) -> ReaderInlineAISearchModel? {
        guard owner.matches(self), repository.publicationOwner == repositoryOwner, let book else { return nil }
        let identity = readingSearchAIIdentity
        var verifiedRevision: Int?
        var verifiedUnits: [SourceUnit] = []
        return ReaderInlineAISearchModel(query: query,snapshot: .init(project: book),settings: settings,
            start: { [weak self] session in
                guard let self, owner.matches(self), self.repository.publicationOwner == repositoryOwner,
                      self.readingSearchAIIdentity == identity else { throw ReadingError.invalid("原书或模型已变化，请重新查找。") }
                var configuration=self.settings;configuration.transportSessionID="readingbook-inline-search-"+UUID().uuidString
                session.start(settings: configuration,apiKey: self.apiKey,coordinator: self.sharedAIRequests,concurrency: self.aiConcurrencyLimit,
                    validate: { [weak self,weak session] in
                        try Task.checkCancellation()
                        guard let self, let session, owner.matches(self), self.repository.publicationOwner == repositoryOwner,
                              self.readingSearchAIIdentity == identity, let project=self.book, let plan=session.plan else {
                            throw ReadingError.invalid("原书或模型已变化，请重新查找。")
                        }
                        let revision=self.currentBookRevision
                        // Retain the validated value snapshot. A unit edit must
                        // copy its array storage while this alias is alive. Test
                        // buffer identity only within both valid borrow scopes;
                        // never store an address or use Unicode-folded equality
                        // as proof that original bytes stayed unchanged.
                        let sameUnits = project.units.withUnsafeBufferPointer { current in
                            verifiedUnits.withUnsafeBufferPointer { previous in
                                current.count == previous.count && current.baseAddress == previous.baseAddress
                            }
                        }
                        guard verifiedRevision != revision || !sameUnits else { return }
                        let snapshot=LibrarySourceSnapshot(project: project)
                        let worker=Task.detached(priority: .utility) { try plan.validate(snapshot: snapshot) }
                        try await withTaskCancellationHandler(operation: { try await worker.value },onCancel: { worker.cancel() })
                        let stillSameUnits = self.book?.units.withUnsafeBufferPointer { current in
                            snapshot.units.withUnsafeBufferPointer { validated in
                                current.count == validated.count && current.baseAddress == validated.baseAddress
                            }
                        } ?? false
                        guard !Task.isCancelled, owner.matches(self), self.repository.publicationOwner == repositoryOwner,
                              self.readingSearchAIIdentity == identity, self.currentBookRevision == revision, stillSameUnits else {
                            throw ReadingError.invalid("原书正在更新，请重新准备查找。")
                        }
                        verifiedRevision=revision; verifiedUnits=snapshot.units
                    })
            },validateResult: { [weak self] hit in
                guard let self, owner.matches(self), self.repository.publicationOwner == repositoryOwner,
                      self.readingSearchAIIdentity == identity, let current=self.book else { throw ReadingError.invalid("原书或模型已变化，请重新查找。") }
                try hit.validate(in: current)
            })
    }
}
