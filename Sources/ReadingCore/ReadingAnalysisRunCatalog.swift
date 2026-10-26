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
                          dispatchCount: Int, currentQueue: ReadingAnalysisRunQueue? = nil) throws -> ReadingAnalysisRunUpdate {
        try Task.checkCancellation()
        guard project.id == bookID, let session = project.smartReading, session.id == sessionID else { throw CancellationError() }
        guard project.sourceHash == sourceHash, session.unitIDs == scopeUnitIDs, session.unitHashes == unitHashes else {
            throw ReadingError.invalid("分析原文或范围已经改变，请重新安排任务；已保存内容保留。")
        }
        try SmartReadingRuntime.validate(session, in: project)
        let currentLayout = try SmartReadingRuntime.selectedUnits(in: project, allowedUnitIDs: Set(session.unitIDs)).map(Layout.init)
        let currentChunks = try SmartReadingRuntime.analysisChunks(in: project, allowedUnitIDs: allowedUnitIDs)
        let scheduled = currentQueue?.scheduledChunks ?? chunks
        func sameWork(_ values: [ReadingAnalysisChunk]) -> Bool {
            values.count == chunks.count && zip(values, chunks).allSatisfy { value, original in
                value.title.utf8.elementsEqual(original.title.utf8) && value.unitIDs == original.unitIDs &&
                    value.configurationHash == original.configurationHash && value.stepIDs == original.stepIDs &&
                    value.sourceRanges == original.sourceRanges && value.chapterID == original.chapterID
            }
        }
        guard currentLayout == layout, sameWork(currentChunks), sameWork(scheduled) else {
            throw ReadingError.invalid("分析块或阅读配置已经改变，请重新安排任务；已保存内容保留。")
        }
        let complete = try Self.completedIDs(chunks: currentChunks, session: session)
        let additions = complete.subtracting(previouslyCompleted)
        let addedInSourceOrder = currentChunks.compactMap { additions.contains($0.id) ? $0.id : nil }
        let replacement: ReadingAnalysisRunQueue?
        let identitiesChanged = scheduled.map(\.id) != currentChunks.map(\.id)
        if !identitiesChanged && previouslyCompleted.isSubset(of: complete) { replacement = nil }
        else {
            let originalByID = Dictionary(chunks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let scheduledByID = Dictionary(scheduled.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
            var aliases: [String: String] = [:]
            for id in running {
                let work: ReadingAnalysisChunk?
                if let currentQueue { work = currentQueue.runningChunk(id) }
                else { work = originalByID[id] }
                guard let work else { throw ReadingError.invalid("进行中的分析块已不在当前队列，已保存内容保留。") }
                let position = scheduledByID[work.id]
                guard let position, position < currentChunks.count else { throw ReadingError.invalid("进行中的分析块无法对应当前任务，已保存内容保留。") }
                let target = currentChunks[position].id
                if id != target { aliases[id] = target }
            }
            replacement = try ReadingAnalysisRunQueue(chunks: currentChunks, steps: steps, chapters: chapters,
                completed: complete, running: running, dispatchCount: dispatchCount, runningAliases: aliases)
        }
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
                  checkpoint.sourceRanges == chunk.sourceRanges, checkpoint.chapterID == chunk.chapterID,
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
