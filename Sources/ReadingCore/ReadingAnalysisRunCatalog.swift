import Foundation

/// Only a work/scheduling projection is retained. Workers must still receive
/// the latest BookProject, and AIReader retains its normal source authority gate.
/// No publication stamp is used as evidence that source or checkpoints survived.
public struct ReadingAnalysisRunCatalog: Sendable {
    private struct Layout: Sendable, Equatable {
        var id: String; var chapter: String; var order: Int; var page: Int?
        var lineStart: Int; var lineEnd: Int
        init(_ unit: SourceUnit) {
            id = unit.id; chapter = unit.chapter; order = unit.order; page = unit.page
            lineStart = unit.lineStart; lineEnd = unit.lineEnd
        }
        static func == (left: Self, right: Self) -> Bool {
            left.id.utf8.elementsEqual(right.id.utf8) && left.chapter.utf8.elementsEqual(right.chapter.utf8) &&
                left.order == right.order && left.page == right.page && left.lineStart == right.lineStart && left.lineEnd == right.lineEnd
        }
    }
    public let chunks: [ReadingAnalysisChunk]
    public let initialCompletedIDs: Set<String>
    private let bookID: String, sessionID: String, sourceHash: String
    private let allowedUnitIDs: Set<String>, scopeUnitIDs: [String], unitHashes: [String: String]
    private let steps: [ReadingExecutionStep], chapters: [String: String], layout: [Layout]

    /// Call off the main actor. Validation and whole-book grouping remain
    /// deliberate safety work; they are not repeated for each ready selection.
    public init(in project: BookProject, allowedUnitIDs: Set<String>) throws {
        guard let session = project.smartReading, let configuration = session.selection.execution else { throw ReadingError.invalid("请先确认本轮阅读方案。") }
        try SmartReadingRuntime.validate(session, in: project)
        let chunks = try SmartReadingRuntime.analysisChunks(in: project, allowedUnitIDs: allowedUnitIDs)
        self.bookID = project.id; self.sessionID = session.id; self.sourceHash = project.sourceHash
        self.allowedUnitIDs = allowedUnitIDs; self.scopeUnitIDs = session.unitIDs; self.unitHashes = session.unitHashes
        self.chunks = chunks; self.steps = configuration.steps
        self.chapters = Dictionary(uniqueKeysWithValues: project.units.map { ($0.id, $0.chapter) })
        self.layout = try SmartReadingRuntime.selectedUnits(in: project, allowedUnitIDs: Set(session.unitIDs)).map(Layout.init)
        self.initialCompletedIDs = try Self.completedIDs(chunks: chunks, session: session)
        try Task.checkCancellation()
    }

    public func makeQueue(completed: Set<String>, running: Set<String> = [], dispatchCount: Int = 0) throws -> ReadingAnalysisRunQueue {
        try ReadingAnalysisRunQueue(chunks: chunks, steps: steps, chapters: chapters, completed: completed, running: running, dispatchCount: dispatchCount)
    }

    /// Recheck every new canonical snapshot off-main, including our own commits:
    /// a merge can include unseen disk changes. New knowledge is freely allowed.
    /// Removed/changed checkpoints rebuild the queue rather than trusting counts,
    /// array suffixes, a saved terminal flag, or a publication ordinal.
    /// This deliberately retains O(P + K) checkpoint projection plus full source
    /// validation/grouping work per canonical snapshot, on the background task.
    /// It does not replace AIReader's per-dispatch checks or repository validation.
    public func reconcile(in project: BookProject, previouslyCompleted: Set<String>, running: Set<String>,
                          dispatchCount: Int) throws -> ReadingAnalysisRunUpdate {
        try Task.checkCancellation()
        guard project.id == bookID, let session = project.smartReading, session.id == sessionID else { throw CancellationError() }
        guard project.sourceHash == sourceHash, session.unitIDs == scopeUnitIDs, session.unitHashes == unitHashes else {
            throw ReadingError.invalid("分析原文或范围已经改变，请重新安排任务；已保存内容保留。")
        }
        try SmartReadingRuntime.validate(session, in: project)
        let currentLayout = try SmartReadingRuntime.selectedUnits(in: project, allowedUnitIDs: Set(session.unitIDs)).map(Layout.init)
        guard currentLayout == layout, try SmartReadingRuntime.analysisChunks(in: project, allowedUnitIDs: allowedUnitIDs) == chunks else {
            throw ReadingError.invalid("分析块或阅读配置已经改变，请重新安排任务；已保存内容保留。")
        }
        let complete = try Self.completedIDs(chunks: chunks, session: session)
        let additions = complete.subtracting(previouslyCompleted)
        let addedInSourceOrder = chunks.compactMap { additions.contains($0.id) ? $0.id : nil }
        let replacement: ReadingAnalysisRunQueue?
        if previouslyCompleted.isSubset(of: complete) { replacement = nil }
        else { replacement = try makeQueue(completed: complete, running: running, dispatchCount: dispatchCount) }
        try Task.checkCancellation()
        return ReadingAnalysisRunUpdate(completedIDs: complete, newlyCompletedIDs: addedInSourceOrder, replacementQueue: replacement)
    }

    private static func completedIDs(chunks: [ReadingAnalysisChunk], session: SmartReadingSession) throws -> Set<String> {
        var checkpoints: [String: ReadingAnalysisCheckpoint] = [:]
        for checkpoint in session.analysisCheckpoints ?? [] {
            try Task.checkCancellation(); checkpoints[checkpoint.id] = checkpoint
        }
        var complete = Set<String>()
        for chunk in chunks {
            try Task.checkCancellation()
            guard let checkpoint = checkpoints[chunk.id], checkpoint.unitIDs == chunk.unitIDs,
                  checkpoint.configurationHash == chunk.configurationHash,
                  Set(checkpoint.completedStepIDs) == Set(chunk.stepIDs),
                  chunk.unitIDs.allSatisfy({ checkpoint.unitHashes[$0] == session.unitHashes[$0] }) else { continue }
            complete.insert(chunk.id)
        }
        return complete
    }
}

public struct ReadingAnalysisRunUpdate: Sendable {
    public let completedIDs: Set<String>
    public let newlyCompletedIDs: [String]
    public let replacementQueue: ReadingAnalysisRunQueue?
}
