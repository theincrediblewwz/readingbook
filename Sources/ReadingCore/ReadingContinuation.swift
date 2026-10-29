import Foundation

/// A reader decision, not an AI-provided completion claim.
public enum ReadingContinuationIntent: String, Codable, CaseIterable, Hashable, Sendable {
    case continueMissing, supplement, reanalyze
}

public struct ReadingContinuationDetailRow: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public init(id: String, title: String, detail: String) {
        self.id = id; self.title = title; self.detail = detail
    }
}

public enum ReadingContinuationWorkStatus: String, Codable, Hashable, Sendable {
    case reusable, missing, boundaryReread, requestedAgain
}

public struct ReadingContinuationWorkItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var unitIDs: [String]
    public var stepIDs: [String]
    public var status: ReadingContinuationWorkStatus
    public var reason: String
    public var proofCheckpointIDs: [String]
}

/// Counts refer to imported content units. Page count is available only when
/// every selected unit has a real page number; a split page is counted once.
public struct ReadingContinuationPreview: Codable, Hashable, Identifiable, Sendable {
    public var id: String { fingerprint }
    public var bookID: String
    public var sourceHash: String
    public var intent: ReadingContinuationIntent
    public var scopeTitle: String
    public var scopeFingerprint: String
    public var fingerprint: String
    public var selectedUnitCount: Int
    public var selectedPageCount: Int?
    public var reusedUnitCount: Int
    public var newUnitCount: Int
    public var partialUnitCount: Int
    public var redoUnitCount: Int
    public var blockedUnitCount: Int
    public var incompatibleUnitCount: Int
    public var reusableChunkCount: Int
    public var pendingChunkCount: Int
    public var completedScopeJobCount: Int
    public var pendingScopeJobCount: Int
    public var rangeText: String
    public var detailRows: [ReadingContinuationDetailRow]
    public var workItems: [ReadingContinuationWorkItem]
    public var hasWork: Bool
}

/// Archive the previous frozen session without duplicating checkpoint prose.
/// Its checkpoint IDs continue to refer to the retained canonical collection.
public struct ReadingContinuationArchivedSession: Codable, Identifiable, Sendable {
    public var id: String
    public var selection: SmartReadingSelection
    public var scopeTitle: String
    public var unitIDs: [String]
    public var unitHashes: [String: String]
    public var sourceHash: String
    public var status: SmartReadingStatus
    public var isPlanConfirmed: Bool
    public var currentUnitID: String?
    public var updatedAt: Date
    public var lastMessage: String?
    public var analysisCheckpointIDs: [String]
    public var chapterIndex: BookChapterIndex?
    public var sourceRanges: [ReadingSourceRange]?
    public var retainedAnalysisChunks: [ReadingAnalysisChunk]?
    public var retainedAnalysisWorkHash: String?
    public var intent: ReadingContinuationIntent?
    public var generationIntent: ReadingContinuationIntent?
    public var generationID: String?
    public var activeGenerationID: String?
    public var activeSessionID: String?
    public var planFingerprint: String?
    public var localWorkInventory: [ReadingContinuationLocalWorkGroup]?
}

/// Optional host metadata. Baselines are actual IDs/ranges validated before
/// this request, never counts subsequently subtracted from accumulated totals.
public struct ReadingContinuationMetadata: Codable, Sendable {
    public var version: Int = 1
    public var intent: ReadingContinuationIntent
    public var generationIntent: ReadingContinuationIntent
    /// Nil is the existing legacy work namespace, not an invented generation.
    public var generationID: String?
    public var activeGenerationID: String?
    public var activeSessionID: String?
    public var parentSessionID: String?
    public var requestedAt: Date
    public var baselineCompletedWorkIDs: [String]
    public var baselineCheckpointIDs: [String]
    public var baselineCompletedUnitIDs: [String]
    public var baselineSourceRanges: [ReadingSourceRange]
    public var requestedWorkIDs: [String]
    public var history: [ReadingContinuationArchivedSession]
    public var projectionVersion: Int? = nil
    public var planFingerprint: String? = nil
    public var availableCheckpointIDsAtStart: [String]? = nil
    public var inventoryFingerprint: String? = nil
    public var localWorkInventory: [ReadingContinuationLocalWorkGroup]? = nil
    public var baselineLegacyReceiptIDs: [String]? = nil
    public var baselineLegacyStepIDs: [String]? = nil

    public init(intent: ReadingContinuationIntent = .continueMissing, generationID: String? = nil,
                activeGenerationID: String? = nil, activeSessionID: String? = nil,
                parentSessionID: String? = nil, generationIntent: ReadingContinuationIntent? = nil,
                requestedAt: Date = Date(), baselineCompletedWorkIDs: [String] = [],
                baselineCheckpointIDs: [String] = [], baselineCompletedUnitIDs: [String] = [],
                baselineSourceRanges: [ReadingSourceRange] = [], requestedWorkIDs: [String] = [],
                history: [ReadingContinuationArchivedSession] = []) {
        self.intent = intent; self.generationIntent = generationIntent ?? intent
        self.generationID = generationID; self.activeGenerationID = activeGenerationID
        self.activeSessionID = activeSessionID; self.parentSessionID = parentSessionID
        self.requestedAt = requestedAt; self.baselineCompletedWorkIDs = baselineCompletedWorkIDs
        self.baselineCheckpointIDs = baselineCheckpointIDs; self.baselineCompletedUnitIDs = baselineCompletedUnitIDs
        self.baselineSourceRanges = baselineSourceRanges; self.requestedWorkIDs = requestedWorkIDs
        self.history = history
    }
}

public struct ReadingContinuationPreparation: Sendable {
    public var candidate: BookProject
    public var preview: ReadingContinuationPreview
}

public struct ReadingContinuationLocalWorkGroup: Codable, Hashable, Sendable {
    public var rawKey: String
    public var works: [ReadingAnalysisChunk]
    public init(rawKey: String, works: [ReadingAnalysisChunk]) {
        self.rawKey = rawKey; self.works = works
    }
}

public enum ReadingContinuationRuntime {}

extension SmartReadingRuntime {
    /// Real same-level chapter ranges only. Parent/child overlap is never
    /// flattened into an accidental whole-volume selection.
    public static func selectedChapterRanges(_ selection: SmartReadingSelection, index: BookChapterIndex,
                                             in project: BookProject) throws -> [ReadingSourceRange] {
        guard selection.scope == .chapterRange, let startID = selection.chapterStartID, let endID = selection.chapterEndID,
              !startID.isEmpty, !endID.isEmpty, startID.utf8.count <= 1024, endID.utf8.count <= 1024,
              index.chapters.count <= 100_000, Set(index.chapters.map(\.id)).count == index.chapters.count,
              index.sourceFingerprint == (try BookOutlineRuntime.fingerprint(in: project)) else {
            throw ReadingError.invalid("请选择当前原书可信目录中的起止章节。")
        }
        let ordered = project.units.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        let positions = Dictionary(ordered.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let units = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard positions.count == ordered.count, let first = index.chapters.first(where: { $0.id == startID }),
              let last = index.chapters.first(where: { $0.id == endID }), first.level == last.level else {
            throw ReadingError.invalid("起止章节必须存在且属于同一层级，不能隐式扩大到父卷。")
        }
        func location(_ chapter: BookChapterRange) -> (Int, Int) {
            guard let r = chapter.ranges.first else { return (Int.max, Int.max) }
            return (positions[r.unitID] ?? Int.max, r.startUTF16)
        }
        let peers = index.chapters.filter { $0.level == first.level }.sorted {
            let a = location($0), b = location($1)
            return a.0 == b.0 ? (a.1 == b.1 ? $0.id < $1.id : a.1 < b.1) : a.0 < b.0
        }
        guard let start = peers.firstIndex(where: { $0.id == startID }), let end = peers.firstIndex(where: { $0.id == endID }),
              start <= end, peers[start...end].allSatisfy({ $0.isComplete && !$0.ranges.isEmpty }) else {
            throw ReadingError.invalid("章节顺序无效或章尾尚未确定，请选择完整的同层章节。")
        }
        let ranges = peers[start...end].flatMap(\.ranges)
        guard !ranges.isEmpty, ranges.count <= 200_000 else { throw ReadingError.invalid("章节范围为空或过大。") }
        for r in ranges {
            guard let unit = units[r.unitID] else { throw ReadingError.invalid("章节引用了不存在的原文。") }
            try r.validate(in: unit)
        }
        let sorted = ranges.sorted {
            let a = positions[$0.unitID] ?? Int.max, b = positions[$1.unitID] ?? Int.max
            return a == b ? $0.startUTF16 < $1.startUTF16 : a < b
        }
        var normalized: [ReadingSourceRange] = []
        for r in sorted {
            if let previous = normalized.last, previous.unitID == r.unitID, r.startUTF16 <= previous.endUTF16 {
                normalized[normalized.count - 1].endUTF16 = max(previous.endUTF16, r.endUTF16)
            } else { normalized.append(r) }
        }
        return normalized
    }
}

extension ReadingContinuationRuntime {
    /// Source locations only: page numbers do not prove whole-page coverage.
    /// Unknown IDs are disclosed rather than assigned invented positions.
    public static func rangeDescription(unitIDs: [String], in project: BookProject) -> String {
        let requested = Set(unitIDs)
        guard !requested.isEmpty else { return "没有对应的所选内容。" }
        let ordered = project.units.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        let selected = ordered.enumerated().filter { requested.contains($0.element.id) }
        let missing = requested.subtracting(selected.map { $0.element.id }).count
        guard !selected.isEmpty else { return "\(missing)个来源单元未匹配当前原文，范围不可确认。" }
        func intervals(_ values: [Int]) -> String {
            guard let first = values.first else { return "" }
            var result: [String] = [], start = first, end = first
            for value in values.dropFirst() {
                if value - end == 1 { end = value }
                else { result.append(start == end ? "\(start)" : "\(start)–\(end)"); start = value; end = value }
            }
            result.append(start == end ? "\(start)" : "\(start)–\(end)")
            return result.joined(separator: "、")
        }
        let location: String
        if selected.allSatisfy({ ($0.element.page ?? 0) > 0 }) {
            let pages = Array(Set(selected.compactMap { $0.element.page })).sorted()
            location = "涉及第\(intervals(pages))页（共\(pages.count)页，\(selected.count)个内容单元）；页码仅定位所选内容，不代表整页已完成；未选片段不计为完成。"
        } else {
            location = "全书内容单元\(intervals(selected.map { $0.offset + 1 }))（共\(selected.count)个）；仅描述所选内容，未选片段不计为完成。"
        }
        return missing == 0 ? location : location + "另有\(missing)个来源单元未匹配当前原文，未推断其范围。"
    }

    private static func makePreview(projected: BookProject, original: BookProject, intent: ReadingContinuationIntent) throws -> ReadingContinuationPreview {
        guard let s = projected.smartReading else { throw ReadingError.invalid("缺少原文范围。") }
        let units = try SmartReadingRuntime.selectedUnits(in: projected, allowedUnitIDs: Set(s.unitIDs))
        let blockedIDs = Set(units.filter { blocked($0, in: projected) }.map(\.id))
        let blanks = Set(units.filter { SmartReadingRuntime.isConfirmedBlank($0, in: projected) }.map(\.id))
        let p: Projection
        if s.selection.execution != nil { p = try configuredProjection(in: projected, original: original, intent: intent) }
        else { let l = try legacyProjection(in: projected); p = Projection(items: l.items, work: [], completeIDs: Set(l.items.filter { $0.status == .reusable }.map(\.id))) }
        let byUnit = Dictionary(grouping: p.work.filter { $0.scopeJob == nil }.flatMap { w in w.unitIDs.map { ($0, w.id) } }, by: { $0.0 })
        let prior = original.smartReading?.analysisCheckpoints ?? []
        var known = Set(original.insights.filter { !$0.id.hasPrefix("blank-") && !$0.id.hasPrefix("deferred-") }.flatMap(\.unitIDs))
        known.formUnion(prior.flatMap(\.unitIDs)); known.formUnion((original.paragraphReceipts ?? []).map(\.unitID))
        known.formUnion((original.readingStepResults ?? []).map(\.unitID)); known.formUnion((original.workflowRuns ?? []).map(\.unitID))
        let incompatible = Set(prior.flatMap { cp in cp.unitIDs.filter { s.unitHashes[$0] != nil && s.unitHashes[$0] != cp.unitHashes[$0] } })
        var reused = 0, added = 0, partial = 0, redo = 0
        var reusedUnits: [String] = [], firstUnits: [String] = [], partialUnits: [String] = [], redoUnits: [String] = []
        var blockedUnits: [String] = [], blankUnits: [String] = []
        for u in units {
            if blockedIDs.contains(u.id) { blockedUnits.append(u.id); continue }
            if blanks.contains(u.id) { reused += 1; blankUnits.append(u.id); continue }
            let own = byUnit[u.id] ?? []
            let complete = s.selection.execution != nil ? (!own.isEmpty && own.allSatisfy { p.completeIDs.contains($0.1) }) : p.items.contains { $0.unitIDs == [u.id] && $0.status == .reusable }
            if intent == .reanalyze && known.contains(u.id) { redo += 1; redoUnits.append(u.id) }
            else if complete { reused += 1; reusedUnits.append(u.id) }
            else if known.contains(u.id) { partial += 1; partialUnits.append(u.id) }
            else { added += 1; firstUnits.append(u.id) }
        }
        let scopes = Set(p.work.filter { $0.scopeJob != nil }.map(\.id)), doneScopes = Set(p.work.filter { $0.scopeJob != nil && p.completeIDs.contains($0.id) }.map(\.id)).count
        let pending = p.items.filter { $0.status != .reusable }
        let hasWork = pending.contains { !$0.unitIDs.allSatisfy { blockedIDs.contains($0) || blanks.contains($0) } }
        let pages = units.allSatisfy { $0.page != nil } ? Set(units.compactMap(\.page)).count : nil
        let scope = try digest(ScopeIdentity(bookID: projected.id, sourceHash: projected.sourceHash, scope: s.scope, unitIDs: s.unitIDs, unitHashes: s.unitHashes, sourceRanges: s.sourceRanges))
        var cfg = s.selection.execution; cfg?.maximumConcurrentRequests = 1
        let fp = try digest(PreviewIdentity(scope: scope, plan: try planFingerprint(in: projected), intent: intent, configuration: cfg, items: p.items, blockedUnitIDs: blockedIDs.sorted(), incompatibleUnitIDs: incompatible.sorted()))
        var rows = [ReadingContinuationDetailRow(id: "units", title: "内容单元", detail: "沿用\(reused)，新增\(added)，已有记录需补\(partial)，明确重做\(redo)。")]
        let ranges: [(String, String, [String])] = [
            ("range-reused", "沿用范围", reusedUnits), ("range-first", "首次分析范围", firstUnits),
            ("range-partial", "已有记录需补范围", partialUnits), ("range-redo", "明确重做范围", redoUnits),
            ("range-blocked", "尚未读取范围", blockedUnits), ("range-blank", "已确认空白范围", blankUnits)
        ]
        for (id, title, ids) in ranges where !ids.isEmpty {
            var detail = rangeDescription(unitIDs: ids, in: projected)
            if id == "range-blank" { detail += "仅沿用人工确认的空白状态，不计为AI分析完成。" }
            rows.append(.init(id: id, title: title, detail: detail))
        }
        if s.selection.execution == nil { rows.append(.init(id: "legacy", title: "沿用逐段账本", detail: "继续真实回执与方法步骤，不自动切换阅读方式或增加本轮回顾。")) }
        else if original.smartReading?.selection.execution == nil {
            rows.append(.init(id: "legacy-conversion", title: "明确启用配置阅读", detail: "旧逐段成果保留，但不能自动证明新增配置步骤已完成；不自动增加本轮回顾。"))
        }
        if !blanks.isEmpty { rows.append(.init(id: "blank", title: "已确认空白", detail: "\(blanks.count)个单元沿用人工确认的空白状态，不调用模型。")) }
        if !scopes.isEmpty { rows.append(.init(id: "scope", title: "已启用的范围步骤", detail: "已保存\(doneScopes)，待保存\(scopes.count-doneScopes)；只执行已启用的章末或本轮结束步骤，等待本次前置成果齐全。")) }
        let boundary = pending.filter { $0.status == .boundaryReread }.count
        if boundary > 0 { rows.append(.init(id: "boundary", title: "边界补读", detail: "\(boundary)个旧复合范围无法精确拆分；保留旧成果并补读，不制造局部完成。")) }
        if !blockedIDs.isEmpty { rows.append(.init(id: "blocked", title: "尚未读取", detail: "\(blockedIDs.count)个单元未识别或暂缓，不计为完成；请先OCR或调整范围。")) }
        if !incompatible.isEmpty { rows.append(.init(id: "source", title: "旧来源不匹配", detail: "\(incompatible.count)个单元的旧记录来源已变；历史保留，不能直接沿用。")) }
        if !hasWork && blockedIDs.isEmpty { rows.append(.init(id: "no-work", title: "无需新请求", detail: "要求已有真实成果；没有新增目标时不会再次生成。")) }
        return ReadingContinuationPreview(bookID: projected.id, sourceHash: projected.sourceHash, intent: intent, scopeTitle: s.scopeTitle, scopeFingerprint: scope, fingerprint: fp,
            selectedUnitCount: units.count, selectedPageCount: pages, reusedUnitCount: reused, newUnitCount: added, partialUnitCount: partial, redoUnitCount: redo, blockedUnitCount: blockedIDs.count,
            incompatibleUnitCount: incompatible.count, reusableChunkCount: p.completeIDs.count, pendingChunkCount: pending.count, completedScopeJobCount: doneScopes, pendingScopeJobCount: scopes.count-doneScopes,
            rangeText: s.scopeTitle + (pages.map { " · \($0)页 / \(units.count)个内容单元" } ?? " · \(units.count)个内容单元"), detailRows: rows, workItems: p.items, hasWork: hasWork)
    }
}

extension ReadingContinuationRuntime {
    private struct Projection {
        var items: [ReadingContinuationWorkItem]
        var work: [ReadingAnalysisChunk]
        var completeIDs: Set<String>
    }
    private static func configuredProjection(in project: BookProject, original: BookProject, intent: ReadingContinuationIntent) throws -> Projection {
        let work = try SmartReadingRuntime.analysisChunks(in: project), index = ReadingAnalysisCompletionIndex(in: project)
        var oldByUnit: [String: [ReadingAnalysisCheckpoint]] = [:]
        for checkpoint in original.smartReading?.analysisCheckpoints ?? [] where checkpoint.scopeJob == nil {
            for id in checkpoint.unitIDs { oldByUnit[id, default: []].append(checkpoint) }
        }
        var completed = Set<String>(), items: [ReadingContinuationWorkItem] = []
        for item in work {
            try Task.checkCancellation()
            let proofs = intent == .reanalyze ? [] : index.checkpointIDs(for: item)
            if !proofs.isEmpty { completed.insert(item.id) }
            var seen = Set<String>()
            let old = item.unitIDs.flatMap { oldByUnit[$0] ?? [] }.filter { seen.insert($0.id).inserted }
            let boundary = item.scopeJob == nil && old.contains { saved in
                (saved.unitIDs != item.unitIDs || saved.sourceRanges != item.sourceRanges) &&
                    item.unitIDs.contains { saved.unitHashes[$0] == project.smartReading?.unitHashes[$0] }
            }
            let status: ReadingContinuationWorkStatus = !proofs.isEmpty ? .reusable :
                intent == .reanalyze ? .requestedAgain : boundary ? .boundaryReread : .missing
            let reason: String
            if status == .reusable { reason = "由真实已保存检查点证明，不再次调用模型。" }
            else if let scope = item.scopeJob { reason = scope.kind == .book ? "执行已选本轮结束步骤，等待本次前置成果保存齐全。" : "执行已选章末步骤，等待本章前置成果保存齐全。" }
            else if status == .requestedAgain { reason = "明确请求重新分析；旧版本保留，新版本完成保存后才切换。" }
            else if boundary { reason = "旧复合范围无法精确拆成当前边界；保留旧成果，并透明补读此边界。" }
            else { reason = "仅执行此任务仍缺的步骤与组件；沿用的工作另列。" }
            items.append(ReadingContinuationWorkItem(id: item.id, title: item.title, unitIDs: item.unitIDs,
                stepIDs: item.stepIDs, status: status, reason: reason, proofCheckpointIDs: proofs))
        }
        return Projection(items: items, work: work, completeIDs: completed)
    }
    private struct ScopeIdentity: Encodable {
        var bookID: String; var sourceHash: String; var scope: SmartReadingScope
        var unitIDs: [String]; var unitHashes: [String: String]; var sourceRanges: [ReadingSourceRange]?
    }
    private struct PreviewIdentity: Encodable {
        var scope: String; var plan: String; var intent: ReadingContinuationIntent
        var configuration: ReadingExecutionConfiguration?; var items: [ReadingContinuationWorkItem]
        var blockedUnitIDs: [String]; var incompatibleUnitIDs: [String]
    }
}

extension ReadingContinuationRuntime {
    private struct LegacyProjection {
        var items: [ReadingContinuationWorkItem]
        var completed: [String]
    }
    private static func blocked(_ unit: SourceUnit, in project: BookProject) -> Bool {
        ReadingLedger.isDeferred(unitID: unit.id, in: project) ||
            (unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !SmartReadingRuntime.isConfirmedBlank(unit, in: project))
    }
    private static func legacyProjection(in project: BookProject) throws -> LegacyProjection {
        guard let session = project.smartReading else { throw ReadingError.invalid("缺少本轮原文范围。") }
        let receipts = Dictionary(grouping: project.paragraphReceipts ?? [], by: \.unitID)
        let results = Dictionary(grouping: project.readingStepResults ?? [], by: \.unitID)
        let runs = Dictionary(grouping: project.workflowRuns ?? [], by: \.unitID)
        var insights: [String: [ReadingInsight]] = [:]
        for value in project.insights { for id in value.unitIDs { insights[id, default: []].append(value) } }
        var items: [ReadingContinuationWorkItem] = [], complete: [String] = []
        let plan = try planFingerprint(in: project)
        for unit in try SmartReadingRuntime.selectedUnits(in: project, allowedUnitIDs: Set(session.unitIDs)) {
            try Task.checkCancellation()
            if blocked(unit, in: project) || SmartReadingRuntime.isConfirmedBlank(unit, in: project) { continue }
            var scoped = project; scoped.units = [unit]
            scoped.paragraphReceipts = receipts[unit.id] ?? []; scoped.readingStepResults = results[unit.id] ?? []
            scoped.workflowRuns = runs[unit.id] ?? []; scoped.insights = insights[unit.id] ?? []
            let finished = SmartReadingRuntime.isUnitComplete(unit, in: scoped)
            if finished { complete.append(unit.id) }
            let id = "legacy-" + String(try digest([project.id, project.sourceHash, unit.id, session.unitHashes[unit.id] ?? "", plan]).prefix(48))
            let saved = (try? ReadingLedger.receipts(for: unit, in: scoped).count) ?? 0
            let total = (try? ReadingLedger.paragraphs(for: unit, in: scoped).count) ?? 0
            items.append(ReadingContinuationWorkItem(id: id, title: unit.locator, unitIDs: [unit.id], stepIDs: [],
                status: finished ? .reusable : .missing,
                reason: finished ? "真实逐段回执、方法步骤与流程输出已齐全。" : "沿用原逐段流程；已保存\(saved)/\(total)条回执，继续缺失步骤。",
                proofCheckpointIDs: []))
        }
        return LegacyProjection(items: items, completed: complete)
    }

    public static func validateStoredState(_ session: SmartReadingSession, in project: BookProject) throws {
        guard let metadata = session.continuation else { return }
        func token(_ value: String) -> Bool {
            value.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil
        }
        func identifiers(_ values: [String], maximum: Int = 200_000) -> Bool {
            values.count <= maximum && Set(values).count == values.count && values.allSatisfy(token)
        }
        guard metadata.version == 1, metadata.projectionVersion == nil || metadata.projectionVersion == 1,
              metadata.requestedAt.timeIntervalSince1970.isFinite,
              metadata.generationID.map(token) ?? true, metadata.activeGenerationID.map(token) ?? true,
              metadata.activeSessionID.map(token) ?? true, metadata.parentSessionID.map(token) ?? true,
              identifiers(metadata.baselineCompletedWorkIDs), identifiers(metadata.baselineCheckpointIDs),
              identifiers(metadata.requestedWorkIDs), identifiers(metadata.baselineCompletedUnitIDs),
              identifiers(metadata.availableCheckpointIDsAtStart ?? []),
              identifiers(metadata.baselineLegacyReceiptIDs ?? []), identifiers(metadata.baselineLegacyStepIDs ?? []),
              Set(metadata.baselineCompletedWorkIDs).isSubset(of: Set(metadata.requestedWorkIDs)),
              Set(metadata.baselineCheckpointIDs).isSubset(of: Set(metadata.availableCheckpointIDsAtStart ?? [])),
              Set(metadata.baselineCompletedUnitIDs).isSubset(of: Set(session.unitIDs)),
              metadata.history.count <= 1000, Set(metadata.history.map(\.id)).count == metadata.history.count,
              metadata.history.reduce(0, { $0 + $1.unitIDs.count }) <= 1_000_000 else {
            throw ReadingError.invalid("续读版本、来源或历史清单无效；旧记录保留。")
        }
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let completedUnits = Set(metadata.baselineCompletedUnitIDs)
        guard metadata.baselineSourceRanges.count <= 200_000 else { throw ReadingError.invalid("续读基线原文范围过大。") }
        for range in metadata.baselineSourceRanges {
            guard completedUnits.contains(range.unitID), let unit = units[range.unitID] else {
                throw ReadingError.invalid("续读基线含有未证明的源单元。")
            }
            try range.validate(in: unit)
        }
        for old in metadata.history {
            guard token(old.id), old.sourceHash.count <= 128, !old.sourceHash.isEmpty,
                  identifiers(old.unitIDs, maximum: BookImporter.maximumUnits),
                  Set(old.unitIDs) == Set(old.unitHashes.keys), old.unitHashes.values.allSatisfy({ $0.count == 64 }),
                  identifiers(old.analysisCheckpointIDs), old.updatedAt.timeIntervalSince1970.isFinite,
                  old.scopeTitle.count <= 4000, (old.lastMessage?.count ?? 0) <= 4000,
                  old.generationID.map(token) ?? true, old.activeGenerationID.map(token) ?? true,
                  old.activeSessionID.map(token) ?? true,
                  (old.sourceRanges?.count ?? 0) <= 200_000,
                  (old.localWorkInventory?.count ?? 0) <= 100_000,
                  old.localWorkInventory?.allSatisfy({ $0.rawKey.count == 64 && $0.works.count <= 40 }) ?? true else {
                throw ReadingError.invalid("历史阅读范围或检查点引用无效。")
            }
            let sourceIDs = Set(old.unitIDs)
            guard (old.sourceRanges ?? []).allSatisfy({ sourceIDs.contains($0.unitID) && $0.startUTF16 >= 0 && $0.endUTF16 > $0.startUTF16 }) else {
                throw ReadingError.invalid("历史范围引用了未选原文。")
            }
        }
        if let activeID = metadata.activeSessionID {
            let generation = activeID == session.id ? metadata.generationID : metadata.history.first(where: { $0.id == activeID })?.generationID
            guard activeID == session.id || metadata.history.contains(where: { $0.id == activeID }), generation == metadata.activeGenerationID else {
                throw ReadingError.invalid("当前分析版本没有对应的保留来源。")
            }
        }
        if let inventory = metadata.localWorkInventory {
            let raw = try SmartReadingRuntime.unprojectedLocalAnalysisChunks(in: project)
            guard metadata.inventoryFingerprint == (try digest(raw.map { try rawKey($0, in: project) })) else {
                throw ReadingError.invalid("已保存任务清单与当前步骤或原文不符。")
            }
            try validateInventory(inventory, raw: raw, in: project)
            _ = try projectLocalWork(raw, in: project)
        }
    }
}

extension ReadingContinuationRuntime {
    /// Planning can replace the frozen session. Preserve version provenance
    /// only after its new plan/session exists; never carry its old work cache
    /// or completion baseline into a different plan.
    public static func preserveHistory(from oldProject: BookProject, in newProject: inout BookProject) throws {
        guard let old = oldProject.smartReading, var next = newProject.smartReading else { return }
        guard oldProject.id == newProject.id else { throw ReadingError.invalid("不能把另一原书的分析历史移入当前书。") }
        var history = old.continuation?.history ?? []
        if old.id != next.id, !history.contains(where: { $0.id == old.id }) {
            guard history.count < 1000 else { throw ReadingError.invalid("分析历史达到安全上限；旧任务仍保留。") }
            history.append(try archive(old, in: oldProject))
        }
        var checkpoints = next.analysisCheckpoints ?? []
        var indices = Dictionary(checkpoints.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for saved in old.analysisCheckpoints ?? [] {
            if let offset = indices[saved.id] {
                guard try encoder.encode(checkpoints[offset]) == encoder.encode(saved) else {
                    throw ReadingError.invalid("同一分析检查点出现不同正文；旧内容保留，未替换方案。")
                }
            } else { indices[saved.id] = checkpoints.count; checkpoints.append(saved) }
        }
        var metadata = ReadingContinuationMetadata(intent: old.continuation?.intent ?? .continueMissing,
            generationID: old.continuation?.generationID, activeGenerationID: old.continuation?.activeGenerationID,
            activeSessionID: old.continuation?.activeSessionID ?? (old.status == .completed ? old.id : nil),
            parentSessionID: old.id, generationIntent: old.continuation?.generationIntent,
            history: history)
        metadata.planFingerprint = try planFingerprint(in: newProject)
        next.analysisCheckpoints = checkpoints; next.continuation = metadata
        newProject.smartReading = next
        try validateStoredState(next, in: newProject)
    }

    public static func prepare(selection: SmartReadingSelection, intent: ReadingContinuationIntent = .continueMissing,
                               in project: BookProject, currentUnitID: String? = nil, currentOffsetUTF16: Int? = nil,
                               expectedPreviewFingerprint: String? = nil) throws -> ReadingContinuationPreparation {
        let shown = try preview(selection: selection, intent: intent, in: project, currentUnitID: currentUnitID,
            currentOffsetUTF16: currentOffsetUTF16)
        if let expectedPreviewFingerprint, expectedPreviewFingerprint != shown.fingerprint {
            throw ReadingError.invalid("原文、步骤或已保存成果已变化，请重新查看预览；原有内容保留。")
        }
        try PluginEngine.requireActivePlan(in: project)
        var candidate = try requestProject(selection: selection, intent: intent, in: project, currentUnitID: currentUnitID,
            currentOffsetUTF16: currentOffsetUTF16, freshGeneration: intent == .reanalyze ? UUID().uuidString : nil, requestedAt: Date())
        guard var session = candidate.smartReading, var metadata = session.continuation else {
            throw ReadingError.invalid("未建立有效的续读任务。")
        }
        if session.selection.execution != nil {
            let raw = try SmartReadingRuntime.unprojectedLocalAnalysisChunks(in: candidate)
            let groups = try projectLocalWork(raw, in: candidate), keys = try raw.map { try rawKey($0, in: candidate) }
            metadata.localWorkInventory = zip(keys, groups).map { ReadingContinuationLocalWorkGroup(rawKey: $0, works: $1) }
            metadata.inventoryFingerprint = try digest(keys)
            session.continuation = metadata; candidate.smartReading = session
            let work = try SmartReadingRuntime.analysisChunks(in: candidate), index = ReadingAnalysisCompletionIndex(in: candidate)
            let complete = work.filter { index.isComplete($0) }
            metadata.requestedWorkIDs = work.map(\.id)
            metadata.baselineCompletedWorkIDs = complete.map(\.id)
            metadata.baselineCheckpointIDs = Array(Set(complete.flatMap { index.checkpointIDs(for: $0) })).sorted()
            let byUnit = Dictionary(grouping: work.filter { $0.scopeJob == nil }.flatMap { item in item.unitIDs.map { ($0, item) } }, by: { $0.0 })
            metadata.baselineCompletedUnitIDs = session.unitIDs.filter { id in
                let own = byUnit[id] ?? []
                return !own.isEmpty && own.allSatisfy { index.isComplete($0.1) }
            }
        } else {
            let legacy = try legacyProjection(in: candidate)
            metadata.requestedWorkIDs = legacy.items.map(\.id)
            metadata.baselineCompletedWorkIDs = legacy.items.filter { $0.status == .reusable }.map(\.id)
            metadata.baselineCompletedUnitIDs = legacy.completed
            let ids = Set(legacy.completed)
            metadata.baselineLegacyReceiptIDs = (project.paragraphReceipts ?? []).filter { ids.contains($0.unitID) }.map(\.paragraphID)
            metadata.baselineLegacyStepIDs = (project.readingStepResults ?? []).filter { ids.contains($0.unitID) }.map(\.stepID)
        }
        let completed = Set(metadata.baselineCompletedUnitIDs)
        metadata.baselineSourceRanges = session.sourceRanges?.filter { completed.contains($0.unitID) } ?? candidate.units.compactMap {
            completed.contains($0.id) && !$0.text.isEmpty ? ReadingSourceRange(unitID: $0.id, startUTF16: 0, endUTF16: $0.text.utf16.count) : nil
        }
        session.continuation = metadata; candidate.smartReading = session
        session.selection.execution?.configureRequestedViews(in: &candidate)
        try validateStoredState(session, in: candidate)
        return ReadingContinuationPreparation(candidate: candidate, preview: shown)
    }
    public static func completePreparedGeneration(in project: inout BookProject) throws {
        guard var session = project.smartReading, var metadata = session.continuation else { return }
        try SmartReadingRuntime.validate(session, in: project)
        let units = try SmartReadingRuntime.selectedUnits(in: project, allowedUnitIDs: Set(session.unitIDs))
        guard !units.contains(where: { blocked($0, in: project) }) else {
            throw ReadingError.invalid("仍有未识别或暂缓原文；部分结果保留，尚未切换当前分析版本。")
        }
        if session.selection.execution != nil {
            let work = try SmartReadingRuntime.analysisChunks(in: project), index = ReadingAnalysisCompletionIndex(in: project)
            let onlyBlank = units.allSatisfy { SmartReadingRuntime.isConfirmedBlank($0, in: project) }
            guard (onlyBlank || !work.isEmpty), work.allSatisfy({ index.isComplete($0) }) else {
                throw ReadingError.invalid("本轮步骤或范围回顾尚未保存齐全；旧版本仍为当前版本。")
            }
        } else {
            let legacy = try legacyProjection(in: project)
            let blanks = units.filter { SmartReadingRuntime.isConfirmedBlank($0, in: project) }.map(\.id)
            guard Set(legacy.completed).union(blanks) == Set(session.unitIDs) else {
                throw ReadingError.invalid("逐段账本或流程输出未齐全，旧版本仍保留。")
            }
        }
        metadata.activeGenerationID = metadata.generationID; metadata.activeSessionID = session.id
        session.continuation = metadata; project.smartReading = session
    }
}

extension ReadingContinuationRuntime {
    private static func archive(_ session: SmartReadingSession, in project: BookProject) throws -> ReadingContinuationArchivedSession {
        var ids: [String] = []
        if session.selection.execution != nil {
            let index = ReadingAnalysisCompletionIndex(in: project)
            ids = Array(Set(try SmartReadingRuntime.analysisChunks(in: project).flatMap { index.checkpointIDs(for: $0) })).sorted()
        }
        return ReadingContinuationArchivedSession(id: session.id, selection: session.selection, scopeTitle: session.scopeTitle,
            unitIDs: session.unitIDs, unitHashes: session.unitHashes, sourceHash: session.sourceHash, status: session.status,
            isPlanConfirmed: session.isPlanConfirmed, currentUnitID: session.currentUnitID, updatedAt: session.updatedAt,
            lastMessage: session.lastMessage, analysisCheckpointIDs: ids, chapterIndex: session.chapterIndex,
            sourceRanges: session.sourceRanges, retainedAnalysisChunks: session.retainedAnalysisChunks,
            retainedAnalysisWorkHash: session.retainedAnalysisWorkHash, intent: session.continuation?.intent,
            generationIntent: session.continuation?.generationIntent, generationID: session.continuation?.generationID,
            activeGenerationID: session.continuation?.activeGenerationID, activeSessionID: session.continuation?.activeSessionID,
            planFingerprint: try session.continuation?.planFingerprint ?? planFingerprint(in: project),
            localWorkInventory: session.continuation?.localWorkInventory)
    }
    private static func effectiveSelection(_ selection: SmartReadingSelection, intent: ReadingContinuationIntent) -> SmartReadingSelection {
        var result = selection
        if result.execution == nil, intent != .continueMissing {
            var configured = ReadingExecutionConfiguration()
            configured.steps.removeAll { $0.frequency == .book || $0.actionID == "reading.review" }
            result.execution = configured
        }
        return result
    }
    private static func requestProject(selection: SmartReadingSelection, intent: ReadingContinuationIntent, in project: BookProject,
                                       currentUnitID: String?, currentOffsetUTF16: Int?, freshGeneration: String? = nil,
                                       requestedAt: Date) throws -> BookProject {
        var session = try SmartReadingRuntime.freeze(effectiveSelection(selection, intent: intent), in: project,
            currentUnitID: currentUnitID, currentOffsetUTF16: currentOffsetUTF16)
        let prior = project.smartReading
        var history = prior?.continuation?.history ?? []
        if let prior, !history.contains(where: { $0.id == prior.id }) {
            guard history.count < 1000 else { throw ReadingError.invalid("分析历史达到安全上限；保留现有内容，未建立新任务。") }
            history.append(try archive(prior, in: project))
        }
        var metadata = ReadingContinuationMetadata(intent: intent, generationID: freshGeneration ?? prior?.continuation?.generationID,
            activeGenerationID: prior?.continuation?.activeGenerationID,
            activeSessionID: prior?.continuation?.activeSessionID ?? (prior?.status == .completed ? prior?.id : nil),
            parentSessionID: prior?.id, generationIntent: intent == .reanalyze ? intent : prior?.continuation?.generationIntent ?? intent,
            requestedAt: requestedAt, history: history)
        metadata.projectionVersion = 1; metadata.planFingerprint = try planFingerprint(in: project)
        metadata.availableCheckpointIDsAtStart = (prior?.analysisCheckpoints ?? []).map(\.id)
        session.analysisCheckpoints = prior?.analysisCheckpoints; session.continuation = metadata
        session.status = .ready; session.isPlanConfirmed = prior?.isPlanConfirmed ?? (project.plan != nil)
        session.lastMessage = intent == .reanalyze ? "独立分析版本；旧成果保留，完成保存后才切换当前版本。"
            : intent == .supplement ? "保留旧成果，仅补充新增或缺失的步骤与组件。" : "继续补齐尚未完成的内容。"
        var result = project; result.smartReading = session
        return result
    }
    public static func preview(selection: SmartReadingSelection, intent: ReadingContinuationIntent = .continueMissing,
                               in project: BookProject, currentUnitID: String? = nil,
                               currentOffsetUTF16: Int? = nil) throws -> ReadingContinuationPreview {
        let projected = try requestProject(selection: selection, intent: intent, in: project, currentUnitID: currentUnitID,
            currentOffsetUTF16: currentOffsetUTF16, requestedAt: .distantPast)
        return try makePreview(projected: projected, original: project, intent: intent)
    }
}

extension ReadingContinuationRuntime {
    private struct PlanProof: Encodable {
        var plan: ReadingPlan?
        var methods: [ReadingMethod]
    }
    private struct SourceProof: Encodable {
        var bookID: String
        var sourceHash: String
        var unitIDs: [String]
        var unitHashes: [String: String]
        var ranges: [ReadingSourceRange]?
        var chapterID: String?
    }
    private struct RawProof: Encodable {
        var source: SourceProof
        var generationID: String?
        var configurationHash: String
        var stepIDs: [String]
        var components: [ComponentKind]
    }
    private struct Candidate {
        var work: ReadingAnalysisChunk
        var configuration: ReadingExecutionConfiguration
    }
    private struct DeltaProof: Encodable {
        var version = "reading-local-delta-v1"
        var rawKey: String
        var steps: [String]
        var components: [ComponentKind]
        var baseMissing: Bool
    }
    private static func deltaHash(raw: ReadingAnalysisChunk, steps: [String], components: [ComponentKind],
                                  baseMissing: Bool, in project: BookProject) throws -> String {
        try digest(DeltaProof(rawKey: try rawKey(raw, in: project), steps: steps,
            components: components, baseMissing: baseMissing))
    }
    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try BookImporter.sha256(encoder.encode(value))
    }
    private static func planFingerprint(in project: BookProject) throws -> String {
        var plan = project.plan
        plan?.rationale = ""; plan?.recommendedParallelism = nil; plan?.recommendedGranularity = nil
        let ids = Set(plan?.methodIDs ?? [])
        return try digest(PlanProof(plan: plan, methods: project.methods.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }))
    }
    private static func sourceProof(_ chunk: ReadingAnalysisChunk, in project: BookProject) -> SourceProof {
        let hashes = project.smartReading?.unitHashes ?? [:]
        return SourceProof(bookID: project.id, sourceHash: project.sourceHash, unitIDs: chunk.unitIDs,
            unitHashes: Dictionary(chunk.unitIDs.map { ($0, hashes[$0] ?? "") }, uniquingKeysWith: { a, _ in a }),
            ranges: chunk.sourceRanges, chapterID: chunk.chapterID)
    }
    private static func rawKey(_ chunk: ReadingAnalysisChunk, in project: BookProject) throws -> String {
        try digest(RawProof(source: sourceProof(chunk, in: project), generationID: project.smartReading?.continuation?.generationID,
            configurationHash: chunk.configurationHash, stepIDs: chunk.stepIDs,
            components: chunk.requiredComponentKinds ?? project.smartReading?.selection.execution?.componentKinds ?? []))
    }
    private static func sourceDigest(_ source: SourceProof) throws -> String {
        return try digest(source)
    }
    private static func sourceDigest(_ chunk: ReadingAnalysisChunk, in project: BookProject) throws -> String {
        try sourceDigest(sourceProof(chunk, in: project))
    }

    // One immutable snapshot for this synchronous projection. Complete chunk
    // values distinguish same-ID contracts; historical snapshots never share
    // this memo. The context is private, transient and cannot be deserialized.
    private final class ProjectionProofMemo {
        let project: BookProject
        private var rawKeys: [ReadingAnalysisChunk: String] = [:]
        private var sources: [ReadingAnalysisChunk: String] = [:]
        private var targets: [ReadingAnalysisChunk: (Set<String>, Set<ComponentKind>)] = [:]
        init(in project: BookProject) { self.project = project }
        func rawKey(_ chunk: ReadingAnalysisChunk) throws -> String {
            if let value = rawKeys[chunk] { return value }
            let value = try ReadingContinuationRuntime.rawKey(chunk, in: project)
            rawKeys[chunk] = value; return value
        }
        func sourceID(_ chunk: ReadingAnalysisChunk) throws -> String {
            if let value = sources[chunk] { return value }
            let value = try ReadingContinuationRuntime.sourceDigest(chunk, in: project)
            sources[chunk] = value; return value
        }
        func targetSets(_ chunk: ReadingAnalysisChunk) -> (Set<String>, Set<ComponentKind>) {
            if let value = targets[chunk] { return value }
            let value = (Set(chunk.stepIDs), Set(chunk.requiredComponentKinds ?? project.smartReading?.selection.execution?.componentKinds ?? []))
            targets[chunk] = value; return value
        }
    }

    private static func materialize(_ archive: ReadingContinuationArchivedSession, checkpoints: [ReadingAnalysisCheckpoint]) -> SmartReadingSession {
        var session = SmartReadingSession(id: archive.id, selection: archive.selection, scopeTitle: archive.scopeTitle,
            unitIDs: archive.unitIDs, unitHashes: archive.unitHashes, sourceHash: archive.sourceHash,
            status: archive.status, isPlanConfirmed: archive.isPlanConfirmed, currentUnitID: archive.currentUnitID,
            updatedAt: archive.updatedAt, lastMessage: archive.lastMessage)
        session.analysisCheckpoints = checkpoints
        session.chapterIndex = archive.chapterIndex; session.sourceRanges = archive.sourceRanges
        session.retainedAnalysisChunks = archive.retainedAnalysisChunks
        session.retainedAnalysisWorkHash = archive.retainedAnalysisWorkHash
        session.continuation = ReadingContinuationMetadata(intent: archive.intent ?? .continueMissing,
            generationID: archive.generationID, generationIntent: archive.generationIntent)
        return session
    }

    /// A single source-indexed pass over historical inputs. Only real, complete
    /// checkpoints can split off reusable work. Remaining requirements form one
    /// explicit delta; a new component never makes an old explanation run again.
    public static func projectLocalWork(_ chunks: [ReadingAnalysisChunk], in project: BookProject) throws -> [[ReadingAnalysisChunk]] {
        guard let session = project.smartReading, let configuration = session.selection.execution,
              let metadata = session.continuation, metadata.projectionVersion == 1 else { return chunks.map { [$0] } }
        let memo = ProjectionProofMemo(in: project)
        let keys = try chunks.map { try memo.rawKey($0) }
        let inventoryHash = try digest(keys)
        if let inventory = metadata.localWorkInventory {
            guard metadata.inventoryFingerprint == inventoryHash else {
                throw ReadingError.invalid("本轮分析任务清单与原文或要求不符，已有内容保留。")
            }
            guard inventory.count == chunks.count, zip(inventory, keys).allSatisfy({ $0.rawKey == $1 }) else {
                throw ReadingError.invalid("本轮分析任务清单已改变，已保存内容保留。")
            }
            try validateInventory(inventory, raw: chunks, in: project, memo: memo)
        }
        if metadata.intent == .reanalyze {
            let result = chunks.map { [$0] }
            guard metadata.localWorkInventory.map({ $0.map(\.works) == result }) ?? true else {
                throw ReadingError.invalid("重新分析任务不能引用旧版本任务。")
            }
            return result
        }
        let allowedProofs = Set(metadata.availableCheckpointIDsAtStart ?? [])
        var proofProject = project
        proofProject.smartReading?.analysisCheckpoints = (session.analysisCheckpoints ?? []).filter { allowedProofs.contains($0.id) }
        let proofIndex = ReadingAnalysisCompletionIndex(in: proofProject)
        var savedBySource: [String: [ReadingAnalysisCheckpoint]] = [:]
        for saved in proofProject.smartReading?.analysisCheckpoints ?? [] where saved.scopeJob == nil {
            guard !saved.unitIDs.isEmpty, Set(saved.unitIDs).count == saved.unitIDs.count,
                  Set(saved.unitIDs) == Set(saved.unitHashes.keys) else { continue }
            let source = SourceProof(bookID: project.id, sourceHash: project.sourceHash, unitIDs: saved.unitIDs,
                unitHashes: saved.unitHashes, ranges: saved.sourceRanges, chapterID: saved.chapterID)
            savedBySource[try sourceDigest(source), default: []].append(saved)
        }
        let currentPlan = try planFingerprint(in: project)
        var candidates: [String: [Candidate]] = [:]
        func add(_ work: ReadingAnalysisChunk, configuration old: ReadingExecutionConfiguration, sourceProject: BookProject, currentSnapshot: Bool = false) throws {
            guard work.scopeJob == nil, old.precision == configuration.precision, proofIndex.isComplete(work) else { return }
            let key = try currentSnapshot ? memo.sourceID(work) : sourceDigest(work, in: sourceProject)
            candidates[key, default: []].append(Candidate(work: work, configuration: old))
        }
        for chunk in chunks { try add(chunk, configuration: configuration, sourceProject: project, currentSnapshot: true) }
        for archive in metadata.history {
            try Task.checkCancellation()
            guard archive.sourceHash == project.sourceHash, archive.generationID == metadata.generationID,
                  archive.planFingerprint.map({ $0 == currentPlan }) ?? true,
                  let oldConfiguration = archive.selection.execution else { continue }
            var previous = project
            previous.smartReading = materialize(archive, checkpoints: proofProject.smartReading?.analysisCheckpoints ?? [])
            // Inventories describe work but cannot prove that a contract existed.
            // Reconstruct the host contract; stale outlines remain historical.
            guard let oldWork = try? SmartReadingRuntime.unprojectedLocalAnalysisChunks(in: previous) else { continue }
            for template in oldWork {
                try add(template, configuration: oldConfiguration, sourceProject: previous)
                let source = try sourceDigest(template, in: previous)
                for saved in savedBySource[source] ?? [] {
                    guard let components = saved.requiredComponentKinds,
                          Set(saved.completedStepIDs).count == saved.completedStepIDs.count,
                          Set(components).count == components.count,
                          Set(saved.completedStepIDs).isSubset(of: Set(template.stepIDs)),
                          Set(components).isSubset(of: Set(template.requiredComponentKinds ?? oldConfiguration.componentKinds)) else { continue }
                    let hashes = try [false, true].map { try deltaHash(raw: template, steps: saved.completedStepIDs,
                        components: components, baseMissing: $0, in: previous) }
                    guard hashes.contains(where: { saved.configurationHash == $0 && saved.id == "chunk-" + String($0.prefix(48)) }) else { continue }
                    var delta = template
                    delta.id = saved.id; delta.configurationHash = saved.configurationHash
                    delta.stepIDs = saved.completedStepIDs; delta.requiredComponentKinds = components
                    try add(delta, configuration: oldConfiguration, sourceProject: previous)
                }
            }
        }
        let steps = Dictionary(configuration.enabledSteps.filter { $0.frequency == .chunk }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var groups: [[ReadingAnalysisChunk]] = []
        for raw in chunks {
            try Task.checkCancellation()
            var missingSteps = Set(raw.stepIDs)
            let requestedComponents = raw.requiredComponentKinds ?? configuration.componentKinds
            var missingComponents = Set(requestedComponents)
            var baseMissing = true, works: [ReadingAnalysisChunk] = [], seen = Set<String>()
            let source = try memo.sourceID(raw)
            let options = (candidates[source] ?? []).sorted {
                let a = $0.work.stepIDs.count + ($0.work.requiredComponentKinds ?? $0.configuration.componentKinds).count
                let b = $1.work.stepIDs.count + ($1.work.requiredComponentKinds ?? $1.configuration.componentKinds).count
                return a == b ? $0.work.id < $1.work.id : a > b
            }
            for candidate in options where seen.insert(candidate.work.id).inserted {
                let oldSteps = Dictionary(candidate.configuration.enabledSteps.filter { $0.frequency == .chunk }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let reusedSteps = candidate.work.stepIDs.filter { missingSteps.contains($0) && oldSteps[$0] == steps[$0] }
                let reusedComponents = (candidate.work.requiredComponentKinds ?? candidate.configuration.componentKinds).filter { missingComponents.contains($0) }
                guard baseMissing || !reusedSteps.isEmpty || !reusedComponents.isEmpty else { continue }
                var reused = candidate.work
                reused.stepIDs = reusedSteps; reused.requiredComponentKinds = reusedComponents
                // The old output remains immutable. This descriptor asks only
                // which subset it already proves; it is never saved as output.
                guard proofIndex.isComplete(reused) else { continue }
                works.append(reused); baseMissing = false
                missingSteps.subtract(reusedSteps); missingComponents.subtract(reusedComponents)
            }
            if baseMissing || !missingSteps.isEmpty || !missingComponents.isEmpty {
                var delta = raw
                delta.stepIDs = raw.stepIDs.filter { missingSteps.contains($0) }
                delta.requiredComponentKinds = requestedComponents.filter { missingComponents.contains($0) }
                if !works.isEmpty {
                    let contract = try deltaHash(raw: raw, steps: delta.stepIDs,
                        components: delta.requiredComponentKinds ?? [], baseMissing: baseMissing, in: project)
                    delta.configurationHash = contract; delta.id = "chunk-" + String(contract.prefix(48))
                }
                works.append(delta)
            }
            groups.append(works)
        }
        let inventory = zip(keys, groups).map { ReadingContinuationLocalWorkGroup(rawKey: $0, works: $1) }
        try validateInventory(inventory, raw: chunks, in: project, memo: memo)
        // Frozen proof IDs keep the regenerated inventory stable as outputs
        // arrive. Persisted descriptors cannot invent a source/step contract.
        guard metadata.localWorkInventory.map({ $0 == inventory }) ?? true else {
            throw ReadingError.invalid("已保存分析清单缺少可验证的原文与步骤合同；内容保留。")
        }
        return groups
    }

    private static func validateInventory(_ groups: [ReadingContinuationLocalWorkGroup], raw: [ReadingAnalysisChunk], in project: BookProject, memo: ProjectionProofMemo? = nil) throws {
        guard groups.count == raw.count else { throw ReadingError.invalid("分析任务清单数量不一致。") }
        let configured = project.smartReading?.selection.execution?.componentKinds ?? []
        var allIDs = Set<String>()
        for (group, source) in zip(groups, raw) {
            guard !group.works.isEmpty, group.works.count <= 40, group.rawKey == (try memo?.rawKey(source) ?? rawKey(source, in: project)) else {
                throw ReadingError.invalid("分析任务清单缺少原文或要求。")
            }
            let sourceID = try memo?.sourceID(source) ?? sourceDigest(source, in: project)
            let (targetSteps, targetComponents) = memo?.targetSets(source) ?? (Set(source.stepIDs), Set(source.requiredComponentKinds ?? configured))
            var providedSteps = Set<String>(), providedComponents = Set<ComponentKind>()
            for work in group.works {
                guard work.scopeJob == nil, allIDs.insert(work.id).inserted,
                      !work.unitIDs.isEmpty, Set(work.unitIDs).count == work.unitIDs.count,
                      Set(work.stepIDs).count == work.stepIDs.count,
                      Set(work.requiredComponentKinds ?? configured).count == (work.requiredComponentKinds ?? configured).count,
                      work.id.range(of: "^chunk-[a-f0-9]{48}$", options: .regularExpression) != nil,
                      work.configurationHash.count == 64,
                      try (memo?.sourceID(work) ?? sourceDigest(work, in: project)) == sourceID,
                      Set(work.stepIDs).isSubset(of: targetSteps),
                      Set(work.requiredComponentKinds ?? configured).isSubset(of: targetComponents) else {
                    throw ReadingError.invalid("本轮分析任务超出已确认原文或步骤，已有内容保留。")
                }
                providedSteps.formUnion(work.stepIDs); providedComponents.formUnion(work.requiredComponentKinds ?? configured)
            }
            guard providedSteps == targetSteps, providedComponents == targetComponents else {
                throw ReadingError.invalid("本轮补充任务遗漏了已选步骤或组件。")
            }
        }
    }
}
