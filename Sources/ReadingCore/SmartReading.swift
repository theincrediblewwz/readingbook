import Foundation

public enum SmartReadingScope: String, Codable, CaseIterable, Sendable {
    case wholeBook, currentPage, currentChapter, pageRange, chapterRange
    public var displayTitle: String {
        switch self {
        case .wholeBook: return "整本书"
        case .currentPage: return "当前页"
        case .currentChapter: return "当前章"
        case .pageRange: return "指定页码"
        case .chapterRange: return "按章节"
        }
    }
}

/// Empty method preferences mean that the model chooses from the offered methods.
public struct SmartReadingSelection: Codable, Hashable, Sendable {
    public var scope: SmartReadingScope
    public var pageStart: Int?
    public var pageEnd: Int?
    public var preferredMethodIDs: [String]
    /// Absent in older sessions: their exact-receipt semantics remain unchanged.
    public var execution: ReadingExecutionConfiguration? = nil
    public var chapterStartID: String? = nil
    public var chapterEndID: String? = nil
    public init(scope: SmartReadingScope = .wholeBook, pageStart: Int? = nil, pageEnd: Int? = nil, preferredMethodIDs: [String] = [], execution: ReadingExecutionConfiguration? = nil, chapterStartID: String? = nil, chapterEndID: String? = nil) {
        self.scope = scope; self.pageStart = pageStart; self.pageEnd = pageEnd; self.preferredMethodIDs = preferredMethodIDs
        self.execution = execution
        self.chapterStartID = chapterStartID; self.chapterEndID = chapterEndID
    }
}

public enum SmartReadingStatus: String, Codable, Sendable {
    case ready, planning, awaitingConfirmation, running, paused, completed, failed
    public var displayTitle: String {
        switch self {
        case .ready: return "准备开始"
        case .planning: return "正在预读"
        case .awaitingConfirmation: return "等待确认方案"
        case .running: return "后台分析中"
        case .paused: return "已暂停"
        case .completed: return "本轮已结束"
        case .failed: return "需要处理后继续"
        }
    }
}

/// A host-frozen manifest. Moving the reader cursor cannot widen a running task.
/// It is additive metadata; source units, user documents and old receipts stay intact.
public struct SmartReadingSession: Codable, Identifiable, Sendable {
    public var id: String
    public var selection: SmartReadingSelection
    public var scope: SmartReadingScope { selection.scope }
    public var scopeTitle: String
    public var unitIDs: [String]
    public var unitHashes: [String: String]
    public var sourceHash: String
    public var status: SmartReadingStatus
    public var isPlanConfirmed: Bool
    public var currentUnitID: String?
    public var updatedAt: Date
    public var lastMessage: String?
    /// Standard analysis is distinct from the exact paragraph ledger.
    public var analysisCheckpoints: [ReadingAnalysisCheckpoint]? = nil
    /// Host-frozen navigation meaning for this run; live directory updates cannot move its boundaries.
    public var chapterIndex: BookChapterIndex? = nil
    public var sourceRanges: [ReadingSourceRange]? = nil
    /// Proven completed whole-unit chunks retained when an older paused run adopts real chapters.
    public var retainedAnalysisChunks: [ReadingAnalysisChunk]? = nil
    public var retainedAnalysisWorkHash: String? = nil
    /// Host-owned continuation/version metadata; absent in existing libraries.
    public var continuation: ReadingContinuationMetadata? = nil
    public init(id: String = UUID().uuidString, selection: SmartReadingSelection, scopeTitle: String, unitIDs: [String],
                unitHashes: [String: String], sourceHash: String, status: SmartReadingStatus = .ready,
                isPlanConfirmed: Bool = false, currentUnitID: String? = nil, updatedAt: Date = Date(), lastMessage: String? = nil) {
        self.id = id; self.selection = selection; self.scopeTitle = scopeTitle; self.unitIDs = unitIDs
        self.unitHashes = unitHashes; self.sourceHash = sourceHash; self.status = status
        self.isPlanConfirmed = isPlanConfirmed
        self.currentUnitID = currentUnitID; self.updatedAt = updatedAt; self.lastMessage = lastMessage
    }
}

public struct SmartReadingProgressStep: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var isCompleted: Bool
}

public struct SmartReadingProgress: Sendable {
    public var completed: Int
    public var total: Int
    public var receiptCount: Int
    public var receiptTotal: Int
    public var stepCount: Int
    public var stepTotal: Int
    /// Explicitly deferred source is still unread; confirmed blank source needs no AI receipt.
    public var excludedCount: Int
    public var blankCount: Int
    public var currentUnitID: String?
    public var currentStepTitle: String
    /// The current AI unit's actual method steps, rather than artificial timer ticks.
    public var steps: [SmartReadingProgressStep]
    public var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
    public var isStandardAnalysis = false
}

/// In-memory projection cache only. Storage/start validation still checks source hashes.
public struct SmartReadingProgressCache: Sendable {
    fileprivate var bookID = ""
    fileprivate var sourceHash = ""
    fileprivate var methodHash = ""
    fileprivate var entries: [String: Entry] = [:]
    public init() {}
    fileprivate struct Key: Equatable, Sendable {
        var unitHash: String
        var receiptCount: Int
        var receiptDate: Date?
        var resultCount: Int
        var runCount: Int
        var runDate: Date?
        var coverageDate: Date?
        var coverageStatus: UnitStatus?
        var coverageMessage: String?
        var insightCount: Int
    }
    fileprivate struct Entry: Sendable {
        var key: Key
        var completed: Bool
        var deferred: Bool
        var blank: Bool
        var receiptCount: Int
        var receiptTotal: Int
        var stepCount: Int
        var stepTotal: Int
        var steps: [SmartReadingProgressStep]
    }
}

public enum SmartReadingRuntime {
    /// A contextual selection follows the currently opened source only when
    /// explicitly starting a new scope, never by silently widening a running one.
    public static func selectionMatchesFrozenContext(_ selection: SmartReadingSelection, in project: BookProject, currentUnitID: String?, currentOffsetUTF16: Int? = nil) -> Bool {
        guard let session = project.smartReading, session.selection == selection else { return false }
        switch selection.scope {
        case .currentPage:
            guard let currentUnitID else { return false }
            return session.unitIDs.contains(currentUnitID)
        case .currentChapter:
            guard let currentUnitID else { return false }
            if let index = session.chapterIndex, let ranges = session.sourceRanges {
                guard let chapter = try? index.chapter(unitID: currentUnitID, offsetUTF16: currentOffsetUTF16) else { return false }
                return chapter.ranges == ranges
            }
            return session.unitIDs.contains(currentUnitID)
        case .wholeBook, .pageRange, .chapterRange: return true
        }
    }
    public static func freeze(_ selection: SmartReadingSelection, in project: BookProject, currentUnitID: String?, currentOffsetUTF16: Int? = nil) throws -> SmartReadingSession {
        try selection.execution?.validate()
        let ordered = project.units.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        guard !ordered.isEmpty, Set(ordered.map(\.id)).count == ordered.count else { throw ReadingError.invalid("原书内容为空或单元ID重复，无法开始智能阅读。") }
        let offered = Set(PluginEngine.recommendedMethods(in: project).map(\.id))
        guard selection.preferredMethodIDs.count <= 32, Set(selection.preferredMethodIDs).count == selection.preferredMethodIDs.count,
              Set(selection.preferredMethodIDs).isSubset(of: offered) else { throw ReadingError.invalid("读书法选择已变化，请重新选择当前可用方法。") }
        let current = currentUnitID.flatMap { id in ordered.first { $0.id == id } }
        var chapterIndex: BookChapterIndex?
        do { chapterIndex = try BookChapterRuntime.index(in: project) }
        catch {
            guard selection.scope != .currentChapter, selection.scope != .chapterRange, selection.execution?.granularity == .page else { throw error }
            chapterIndex = nil // An explicit page request never acquires unknown chapter meaning.
        }
        if chapterIndex == nil, selection.execution?.granularity == .chapter,
           project.originalName.lowercased().hasSuffix(".pdf"), ordered.allSatisfy({ unit in
               unit.chapter == project.title || unit.chapter.range(of: "^第\\s*[0-9０-９一二三四五六七八九十百千]+\\s*页$", options: .regularExpression) != nil
           }) { throw ReadingError.invalid("还没有可靠的章节范围，请先读取或生成目录，或选择按页分析。") }
        var sourceRanges: [ReadingSourceRange]?
        let selected: [SourceUnit]
        let title: String
        switch selection.scope {
        case .wholeBook:
            selected = ordered; title = "整本书"
        case .currentPage:
            guard let current, let page = current.page else { throw ReadingError.invalid("当前原文没有页码，请选择当前章或整本书。") }
            selected = ordered.filter { $0.page == page }; title = "第 \(page) 页"
        case .currentChapter:
            guard let current else { throw ReadingError.invalid("请先打开要分析的章节。") }
            if let chapterIndex {
                let chapter = try chapterIndex.chapter(unitID: current.id, offsetUTF16: currentOffsetUTF16)
                guard chapter.isComplete else { throw ReadingError.invalid("本章目录尚未整理完，请完成目录后再按章分析。") }
                let ids = Set(chapter.ranges.map(\.unitID))
                selected = ordered.filter { ids.contains($0.id) }; title = chapter.title
                sourceRanges = chapter.ranges
            } else {
                guard let chapter = try BookChapterRuntime.legacyChapter(in: project, unitID: current.id) else { throw ReadingError.invalid("还没有可靠的章节范围，请先读取或生成目录。") }
                let ids = Set(chapter.ranges.map(\.unitID))
                selected = ordered.filter { ids.contains($0.id) }; title = chapter.title
                let chapters = try BookChapterRuntime.legacyChapters(in: project)
                chapterIndex = BookChapterIndex(sourceFingerprint: try BookOutlineRuntime.fingerprint(in: project), chapters: chapters, segments: chapters)
                sourceRanges = chapter.ranges
            }
        case .chapterRange:
            guard let index = chapterIndex else { throw ReadingError.invalid("没有可信章节目录，暂不能选择章节范围；可以按页选择，不会自动调用AI生成目录。") }
            let ranges = try selectedChapterRanges(selection, index: index, in: project)
            let ids = Set(ranges.map(\.unitID))
            selected = ordered.filter { ids.contains($0.id) }; sourceRanges = ranges
            let first = index.chapters.first { $0.id == selection.chapterStartID }
            let last = index.chapters.first { $0.id == selection.chapterEndID }
            title = first?.id == last?.id ? (first?.title ?? "所选章节") : (first?.title ?? "起始章节") + "—" + (last?.title ?? "结束章节")
        case .pageRange:
            guard let start = selection.pageStart, let end = selection.pageEnd, start >= 1, end >= start,
                  let lastPage = ordered.compactMap(\.page).max(), end <= lastPage else { throw ReadingError.invalid("页码范围无效，请使用书中已有页码。") }
            selected = ordered.filter { $0.page.map { (start...end).contains($0) } ?? false }
            title = start == end ? "第 \(start) 页" : "第 \(start)–\(end) 页"
        }
        guard !selected.isEmpty else { throw ReadingError.invalid("所选范围没有可分析的原文。") }
        if let index = chapterIndex, selection.scope != .currentChapter, selection.scope != .chapterRange, !chapterIndexCovers(index, units: selected) {
            guard selection.execution?.granularity == .page else { throw ReadingError.invalid("所选范围的目录尚未整理完整，请继续整理目录，或选择按页分析。") }
            chapterIndex = nil
        }
        if let sourceRanges, (selection.scope == .currentChapter || selection.scope == .chapterRange),
           selection.execution == nil || selection.execution?.precision == .close {
            let byID = Dictionary(selected.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if sourceRanges.contains(where: { range in range.startUTF16 != 0 || range.endUTF16 != byID[range.unitID]?.text.utf16.count }) {
                throw ReadingError.invalid("章节在页内分界，逐段精读请改用页范围；按章可选标准阅读。")
            }
        }
        var hashes: [String: String] = [:]
        for unit in selected { try Task.checkCancellation(); hashes[unit.id] = try unitHash(unit) }
        var session = SmartReadingSession(selection: selection, scopeTitle: title, unitIDs: selected.map(\.id), unitHashes: hashes, sourceHash: project.sourceHash)
        if let chapterIndex {
            let ids = Set(session.unitIDs)
            session.chapterIndex = chapterIndex
            session.sourceRanges = sourceRanges ?? chapterIndex.segments.flatMap(\.ranges).filter { ids.contains($0.unitID) }
            try validateFrozenChapterScope(session, in: project)
        }
        return session
    }

    public static func validate(_ session: SmartReadingSession, in project: BookProject, prevalidatedUnitHashes: [String: String]? = nil) throws {
        try session.selection.execution?.validate()
        try ReadingContinuationRuntime.validateStoredState(session, in: project)
        let checkpoints = session.analysisCheckpoints ?? []
        guard checkpoints.count <= 100_000, Set(checkpoints.map(\.id)).count == checkpoints.count else { throw ReadingError.invalid("分析检查点数量或标识无效。") }
        let allUnits = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for checkpoint in checkpoints {
            guard checkpoint.id.range(of: "^chunk-[a-f0-9]{48}$", options: .regularExpression) != nil,
                  (1...12).contains(checkpoint.unitIDs.count), Set(checkpoint.unitIDs).count == checkpoint.unitIDs.count,
                  Set(checkpoint.unitHashes.keys) == Set(checkpoint.unitIDs), checkpoint.configurationHash.count == 64,
                  checkpoint.completedStepIDs.count <= 24, Set(checkpoint.completedStepIDs).count == checkpoint.completedStepIDs.count,
                  !checkpoint.markdown.isEmpty, checkpoint.markdown.count <= 16_000,
                  (checkpoint.noChangesReasons?.count ?? 0) <= 30,
                  (checkpoint.noChangesReasons ?? [:]).allSatisfy({ key, reason in
                      key.range(of: "^(step:[A-Za-z0-9_.-]{1,128}|component:(cards|map|timeline|mindmap|relations|knowledge))$", options: .regularExpression) != nil && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && reason.count <= 400
                  }),
                  checkpoint.hostCitationSummary.map({ !$0.isEmpty && $0.count <= 1000 }) ?? true,
                  checkpoint.updatedAt.timeIntervalSince1970.isFinite, (1...128).contains(checkpoint.evidence.count),
                  Set(checkpoint.evidence.map(\.unitID)) == Set(checkpoint.unitIDs),
                  checkpoint.unitIDs.allSatisfy({ allUnits[$0] != nil && checkpoint.unitHashes[$0]?.count == 64 }),
                  checkpoint.evidence.allSatisfy({ !$0.quote.isEmpty && $0.quote.count <= 32_768 && allUnits[$0.unitID]?.text.contains($0.quote) == true }) else { throw ReadingError.invalid("标准阅读分析检查点无效，原有内容保留。") }
            try validateAnalysisScopeMetadata(checkpoint, units: allUnits)
        }
        let positions = Dictionary(project.units.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for checkpoint in checkpoints {
            if let ranges = checkpoint.sourceRanges {
                guard !ranges.isEmpty, ranges.count <= 128,
                      Set(ranges.map(\.unitID)) == Set(checkpoint.unitIDs),
                      checkpoint.chapterID.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) == true else { throw ReadingError.invalid("分析检查点的章节范围无效。") }
                var previous: (order: Int, end: Int)?
                for range in ranges {
                    guard let unit = allUnits[range.unitID], let order = positions[range.unitID] else { throw ReadingError.invalid("分析检查点的原文不存在。") }
                    try range.validate(in: unit)
                    if let previous { guard order > previous.order || (order == previous.order && range.startUTF16 >= previous.end) else { throw ReadingError.invalid("分析检查点原文范围重叠。") } }
                    previous = (order, range.endUTF16)
                }
                guard checkpoint.evidence.allSatisfy({ evidenceAdmitted($0, ranges: ranges, in: project) }) else { throw ReadingError.invalid("分析检查点引文超出章节范围。") }
            } else if checkpoint.chapterID != nil { throw ReadingError.invalid("分析检查点缺少章节原文范围。") }
        }
        guard session.unitIDs.count <= BookImporter.maximumUnits, session.unitHashes.count <= BookImporter.maximumUnits,
              session.unitIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              session.selection.preferredMethodIDs.count <= 32,
              Set(session.selection.preferredMethodIDs).count == session.selection.preferredMethodIDs.count,
              session.selection.preferredMethodIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              session.unitHashes.values.allSatisfy({ $0.count == 64 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }),
              session.updatedAt.timeIntervalSince1970.isFinite else { throw ReadingError.invalid("智能阅读范围记录超出限制或格式无效。") }
        let units = try selectedUnits(in: project, allowedUnitIDs: Set(session.unitIDs))
        guard !session.id.isEmpty, session.id.count <= 128, session.sourceHash == project.sourceHash,
              session.unitIDs.count == units.count, session.unitIDs == units.map(\.id),
              Set(session.unitHashes.keys) == Set(session.unitIDs), session.scopeTitle.count <= 4000,
              (session.lastMessage?.count ?? 0) <= 4000,
              session.currentUnitID.map({ session.unitIDs.contains($0) }) ?? true else { throw ReadingError.invalid("智能阅读范围记录无效，请重新选择范围。") }
        if session.chapterIndex != nil {
            try validateFrozenChapterScope(session, in: project)
        } else {
            guard session.sourceRanges == nil, session.retainedAnalysisChunks == nil, session.retainedAnalysisWorkHash == nil else { throw ReadingError.invalid("智能阅读章节范围缺少冻结目录。") }
            let refrozen = try freezeScopeOnly(session.selection, in: project, currentUnitID: session.unitIDs.first)
            guard refrozen.map(\.id) == session.unitIDs else { throw ReadingError.invalid("智能阅读范围与保存的页章选择不一致。") }
        }
        for unit in units {
            try Task.checkCancellation()
            let expected = try prevalidatedUnitHashes?[unit.id] ?? unitHash(unit)
            guard session.unitHashes[unit.id] == expected else { throw ReadingError.invalid("所选原文在任务建立后已变化（可能已重新OCR），请重新选择范围并预读；旧分析保留。") }
        }
    }

    public static func validateStoredState(in project: BookProject, prevalidatedUnitHashes: [String: String]? = nil) throws {
        if let session = project.smartReading { try validate(session, in: project, prevalidatedUnitHashes: prevalidatedUnitHashes) }
    }

    /// The exact app-created marker is required; an empty extraction is never enough.
    public static func isConfirmedBlank(_ unit: SourceUnit, in project: BookProject) -> Bool {
        unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && project.coverage[unit.id]?.status == .completed &&
            project.coverage[unit.id]?.message == "用户确认此单元为原书空白。" &&
            project.insights.contains { $0.id == "blank-\(unit.id)" && $0.unitIDs == [unit.id] && $0.markdown == "用户对照原书确认此单元为空白，无需 AI 提取文字。" }
    }

    public static func analysisUnitIDs(in project: BookProject, allowedUnitIDs: Set<String>) throws -> Set<String> {
        Set(try selectedUnits(in: project, allowedUnitIDs: allowedUnitIDs).filter {
            !ReadingLedger.isDeferred(unitID: $0.id, in: project) && !isConfirmedBlank($0, in: project)
        }.map(\.id))
    }

    public static func selectedUnits(in project: BookProject, allowedUnitIDs: Set<String>? = nil) throws -> [SourceUnit] {
        let ordered = project.units.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        guard Set(ordered.map(\.id)).count == ordered.count else { throw ReadingError.invalid("源单元ID重复。") }
        guard let allowedUnitIDs else { return ordered }
        guard !allowedUnitIDs.isEmpty, allowedUnitIDs.isSubset(of: Set(ordered.map(\.id))) else { throw ReadingError.invalid("智能阅读范围为空或含有不存在的原文；未发送请求。") }
        return ordered.filter { allowedUnitIDs.contains($0.id) }
    }

    /// Historical coverage alone never satisfies a new task or changed method.
    public static func isUnitComplete(_ unit: SourceUnit, in project: BookProject) -> Bool {
        if project.smartReading?.selection.execution != nil {
            let chunks = ((try? analysisChunks(in: project)) ?? []).filter { $0.scopeJob == nil && $0.unitIDs.contains(unit.id) }
            let index = ReadingAnalysisCompletionIndex(in: project)
            return !chunks.isEmpty && chunks.allSatisfy { index.isComplete($0) }
        }
        return isComplete(unit, in: UnitIndex(project).project(for: unit, original: project))
    }

    /// Completion of the current frozen local selection, never proof that an
    /// unrequested remainder of a multi-chapter source unit has been analyzed.
    /// Blank/deferred units remain separate from AI analysis completion.
    public static func completedLocalUnitIDs(in project: BookProject) throws -> Set<String> {
        if project.smartReading?.selection.execution != nil {
            let local = try analysisChunks(in: project).filter { $0.scopeJob == nil }
            let index = ReadingAnalysisCompletionIndex(in: project)
            var done = Set<String>(), incomplete = Set<String>()
            for chunk in local {
                try Task.checkCancellation()
                if index.isComplete(chunk) { done.formUnion(chunk.unitIDs) }
                else { incomplete.formUnion(chunk.unitIDs) }
            }
            return done.subtracting(incomplete)
        }
        let index = UnitIndex(project)
        let selected = try selectedUnits(in: project, allowedUnitIDs: project.smartReading.map { Set($0.unitIDs) })
        var result = Set<String>()
        for unit in selected {
            try Task.checkCancellation()
            let scoped = index.project(for: unit, original: project)
            if !ReadingLedger.isDeferred(unitID: unit.id, in: scoped), !isConfirmedBlank(unit, in: scoped), isComplete(unit, in: scoped) {
                result.insert(unit.id)
            }
        }
        return result
    }

    private static func isComplete(_ unit: SourceUnit, in project: BookProject) -> Bool {
        guard !ReadingLedger.isDeferred(unitID: unit.id, in: project),
              project.coverage[unit.id]?.status == .completed || project.coverage[unit.id]?.status == .needsReview,
              ReadingLedger.hasReadingAnalysis(unitID: unit.id, in: project),
              (try? ReadingLedger.requireComplete(unitIDs: [unit.id], in: project)) != nil,
              let requirements = try? ReadingLedger.stepRequirements(for: unit, in: project), !requirements.isEmpty else { return false }
        let runs = Dictionary((project.workflowRuns ?? []).filter { $0.unitID == unit.id }.map { ($0.stepID, $0) }, uniquingKeysWith: { first, _ in first })
        let results = Dictionary((project.readingStepResults ?? []).filter { $0.unitID == unit.id }.map { ($0.stepID, $0) }, uniquingKeysWith: { first, _ in first })
        return requirements.allSatisfy { requirement in
            guard let run = runs[requirement.stepID], let result = results[requirement.stepID] else { return false }
            return run.status == .completed && run.output != nil && run.methodHash == requirement.methodHash &&
                (project.coverage[unit.id]?.updatedAt ?? .distantPast) >= run.updatedAt &&
                result.methodHash == requirement.methodHash && result.result == run.output?.result && result.paragraphIDs == run.output?.paragraphIDs
        }
    }

    public static func nextUnit(in project: BookProject, allowedUnitIDs: Set<String>) throws -> SourceUnit? {
        if project.smartReading?.selection.execution != nil {
            let next = try nextAnalysisChunk(in: project, allowedUnitIDs: allowedUnitIDs)?.unitIDs.first
            return project.units.first { $0.id == next }
        }
        let index = UnitIndex(project)
        return try selectedUnits(in: project, allowedUnitIDs: allowedUnitIDs).first {
            let scoped = index.project(for: $0, original: project)
            return !ReadingLedger.isDeferred(unitID: $0.id, in: scoped) && !isConfirmedBlank($0, in: scoped) && !isComplete($0, in: scoped)
        }
    }

    public static func progress(in project: BookProject) throws -> SmartReadingProgress? {
        var cache = SmartReadingProgressCache()
        return try progress(in: project, cache: &cache)
    }

    /// Native passes validateSource=false only for projects already validated on
    /// load/save. Immutable receipt counts and action timestamps invalidate just
    /// the changed unit; rendering does not rehash all source or rebuild manifests.
    public static func progress(in project: BookProject, cache: inout SmartReadingProgressCache, validateSource: Bool = true) throws -> SmartReadingProgress? {
        guard let session = project.smartReading else { return nil }
        if validateSource { try validate(session, in: project) }
        if session.selection.execution != nil {
            let chunks = try analysisChunks(in: project)
            let completion = ReadingAnalysisCompletionIndex(in: project)
            let completed = chunks.filter { completion.isComplete($0) }
            let completedChunkIDs = Set(completed.map(\.id)), scopeIDs = Set(session.unitIDs)
            let incompleteUnitIDs = Set(chunks.filter { $0.scopeJob == nil && !completedChunkIDs.contains($0.id) }.flatMap(\.unitIDs))
            let completedIDs = Set(completed.filter { $0.scopeJob == nil }.flatMap(\.unitIDs)).subtracting(incompleteUnitIDs)
            let next = chunks.first { !completedChunkIDs.contains($0.id) }
            let configuration = session.selection.execution
            let rows = (configuration?.steps ?? []).filter { next?.stepIDs.contains($0.id) == true }.map { SmartReadingProgressStep(id: $0.id, title: $0.title, isCompleted: false) }
            let scopedUnits = project.units.filter { scopeIDs.contains($0.id) }
            let excluded = scopedUnits.filter { ReadingLedger.isDeferred(unitID: $0.id, in: project) }.count
            let blank = scopedUnits.filter { isConfirmedBlank($0, in: project) }.count
            var value = SmartReadingProgress(completed: completedIDs.count, total: session.unitIDs.count,
                receiptCount: (project.paragraphReceipts ?? []).filter { scopeIDs.contains($0.unitID) }.count, receiptTotal: 0,
                stepCount: completed.reduce(0) { $0 + $1.stepIDs.count }, stepTotal: chunks.reduce(0) { $0 + $1.stepIDs.count },
                excludedCount: excluded, blankCount: blank, currentUnitID: next?.unitIDs.first, currentStepTitle: next?.title ?? "本轮分析已保存", steps: rows)
            value.isStandardAnalysis = true
            return value
        }
        let units = try selectedUnits(in: project, allowedUnitIDs: Set(session.unitIDs))
        let index = UnitIndex(project)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let methodHash = try BookImporter.sha256(encoder.encode((project.plan?.methodIDs ?? []).compactMap { id in project.methods.first { $0.id == id } }))
        if cache.bookID != project.id || cache.sourceHash != project.sourceHash || cache.methodHash != methodHash {
            cache = SmartReadingProgressCache(); cache.bookID = project.id; cache.sourceHash = project.sourceHash; cache.methodHash = methodHash
        }
        var completed = 0, receiptCount = 0, receiptTotal = 0, stepCount = 0, stepTotal = 0, excludedCount = 0, blankCount = 0
        var firstPendingID: String?, lastActionableID: String?
        for unit in units {
            let unitReceipts = index.receipts[unit.id] ?? [], unitRuns = index.runs[unit.id] ?? []
            let coverage = project.coverage[unit.id]
            let key = SmartReadingProgressCache.Key(unitHash: session.unitHashes[unit.id] ?? "", receiptCount: unitReceipts.count,
                receiptDate: unitReceipts.map(\.createdAt).max(), resultCount: index.results[unit.id]?.count ?? 0,
                runCount: unitRuns.count, runDate: unitRuns.map(\.updatedAt).max(), coverageDate: coverage?.updatedAt,
                coverageStatus: coverage?.status, coverageMessage: coverage?.message, insightCount: index.insights[unit.id]?.count ?? 0)
            let entry: SmartReadingProgressCache.Entry
            if let old = cache.entries[unit.id], old.key == key { entry = old }
            else {
                let scoped = index.project(for: unit, original: project)
                let deferred = ReadingLedger.isDeferred(unitID: unit.id, in: scoped), blank = isConfirmedBlank(unit, in: scoped)
                let paragraphs = try (deferred || blank ? [] : ReadingLedger.paragraphs(for: unit, in: scoped))
                let receipts = try (deferred || blank ? [] : ReadingLedger.receipts(for: unit, in: scoped))
                let requirements = deferred || blank ? [] : ((try? ReadingLedger.stepRequirements(for: unit, in: scoped)) ?? [])
                let runs = Dictionary(unitRuns.map { ($0.stepID, $0) }, uniquingKeysWith: { first, _ in first })
                let done = Set(requirements.filter { runs[$0.stepID]?.status == .completed && runs[$0.stepID]?.output != nil }.map(\.stepID))
                let rows = [SmartReadingProgressStep(id: "receipts-" + unit.id, title: "逐段阅读与简短复述", isCompleted: !paragraphs.isEmpty && paragraphs.count == receipts.count)] +
                    requirements.map { SmartReadingProgressStep(id: $0.stepID, title: $0.stepText, isCompleted: done.contains($0.stepID)) }
                entry = SmartReadingProgressCache.Entry(key: key, completed: !deferred && !blank && isComplete(unit, in: scoped),
                    deferred: deferred, blank: blank, receiptCount: receipts.count, receiptTotal: paragraphs.count,
                    stepCount: done.count, stepTotal: requirements.count, steps: rows)
                cache.entries[unit.id] = entry
            }
            if entry.deferred { excludedCount += 1; continue }
            if entry.blank { blankCount += 1; continue }
            lastActionableID = unit.id
            if entry.completed { completed += 1 } else if firstPendingID == nil { firstPendingID = unit.id }
            receiptCount += entry.receiptCount; receiptTotal += entry.receiptTotal
            stepCount += entry.stepCount; stepTotal += entry.stepTotal
        }
        let activeID = session.currentUnitID.flatMap { id -> String? in
            guard let entry = cache.entries[id], !entry.deferred, !entry.blank, !entry.completed else { return nil }; return id
        }
        let currentID = activeID ?? firstPendingID ?? lastActionableID
        let currentRows = currentID.flatMap { cache.entries[$0]?.steps } ?? []
        let title = session.status == .completed ? "本轮处理结果已保存" : (currentRows.first(where: { !$0.isCompleted })?.title ?? (completed + excludedCount + blankCount == units.count ? "整理所选范围的读后综合" : "保存本页分析"))
        return SmartReadingProgress(completed: completed, total: units.count, receiptCount: receiptCount, receiptTotal: receiptTotal,
                                    stepCount: stepCount, stepTotal: stepTotal, excludedCount: excludedCount, blankCount: blankCount,
                                    currentUnitID: currentID, currentStepTitle: title, steps: currentRows)
    }

    private static func unitHash(_ unit: SourceUnit) throws -> String { try BookImporter.sha256(Data(unit.text.utf8)) }

    private static func freezeScopeOnly(_ selection: SmartReadingSelection, in project: BookProject, currentUnitID: String?) throws -> [SourceUnit] {
        let units = try selectedUnits(in: project)
        let current = units.first { $0.id == currentUnitID }
        switch selection.scope {
        case .wholeBook: return units
        case .currentPage:
            guard let page = current?.page else { throw ReadingError.invalid("智能阅读保存的页码不存在。") }
            return units.filter { $0.page == page }
        case .currentChapter:
            guard let current else { throw ReadingError.invalid("智能阅读保存的章节不存在。") }
            return units.filter { $0.chapter == current.chapter }
        case .pageRange:
            guard let start = selection.pageStart, let end = selection.pageEnd, start > 0, end >= start,
                  let last = units.compactMap(\.page).max(), end <= last else { throw ReadingError.invalid("智能阅读保存的页码范围无效。") }
            return units.filter { $0.page.map { (start...end).contains($0) } ?? false }
        case .chapterRange:
            throw ReadingError.invalid("章节范围缺少已冻结的可信目录。")
        }
    }

    /// Avoid rescanning a whole book's receipts and action records for every unit.
    /// These are read-only projections, never passed back to repository.save.
    private struct UnitIndex {
        let receipts: [String: [ParagraphReceipt]]
        let results: [String: [ReadingStepResult]]
        let runs: [String: [ReadingWorkflowStepRun]]
        let insights: [String: [ReadingInsight]]
        init(_ project: BookProject) {
            receipts = Dictionary(grouping: project.paragraphReceipts ?? [], by: \.unitID)
            results = Dictionary(grouping: project.readingStepResults ?? [], by: \.unitID)
            runs = Dictionary(grouping: project.workflowRuns ?? [], by: \.unitID)
            var grouped: [String: [ReadingInsight]] = [:]
            for insight in project.insights { for id in insight.unitIDs { grouped[id, default: []].append(insight) } }
            insights = grouped
        }
        func project(for unit: SourceUnit, original: BookProject) -> BookProject {
            var value = BookProject(id: original.id, title: original.title, originalName: original.originalName, sourceHash: original.sourceHash, units: [unit])
            value.plan = original.plan; value.methods = original.methods
            value.coverage[unit.id] = original.coverage[unit.id]
            value.paragraphReceipts = receipts[unit.id]; value.readingStepResults = results[unit.id]
            value.workflowRuns = runs[unit.id]; value.insights = insights[unit.id] ?? []
            return value
        }
    }
}
