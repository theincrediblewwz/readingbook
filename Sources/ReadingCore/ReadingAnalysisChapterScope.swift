import Foundation

extension SmartReadingRuntime {
    /// Only call before a run starts. Completed historical whole-unit work is
    /// retained verbatim; unfinished work adopts one immutable chapter meaning.
    @discardableResult public static func freezeChapterBoundaries(in project: inout BookProject) throws -> Bool {
        guard var session = project.smartReading, session.chapterIndex == nil,
              session.selection.execution != nil, session.status != .running else { return false }
        let index: BookChapterIndex?
        do { index = try BookChapterRuntime.index(in: project) }
        catch {
            guard session.scope != .currentChapter, session.selection.execution?.granularity == .page else { throw error }
            return false
        }
        guard let index else {
            let granularity = session.selection.execution?.granularity == .adaptive ? project.plan?.recommendedGranularity : session.selection.execution?.granularity
            if granularity == .chapter, project.originalName.lowercased().hasSuffix(".pdf"), project.units.allSatisfy({ $0.chapter == project.title }) {
                throw ReadingError.invalid("还没有可靠的章节范围，请先读取或生成目录，或选择按页分析。")
            }
            return false
        }
        let scopeUnits = try selectedUnits(in: project, allowedUnitIDs: Set(session.unitIDs))
        guard chapterIndexCovers(index, units: scopeUnits) else {
            if session.selection.execution?.granularity == .page && session.scope != .currentChapter { return false }
            throw ReadingError.invalid("所选范围的目录尚未整理完整，请继续整理目录，或选择按页分析。")
        }
        let legacy = try legacyAnalysisChunks(in: project)
        let retained = legacy.filter { isChunkComplete($0, in: project) }
        session.chapterIndex = index
        let scopeIDs = Set(session.unitIDs)
        session.sourceRanges = index.segments.flatMap(\.ranges).filter { scopeIDs.contains($0.unitID) }
        session.retainedAnalysisChunks = retained
        session.retainedAnalysisWorkHash = try chapterWorkFingerprint(in: project)
        if session.scope == .currentChapter { session.scopeTitle = "原任务范围 · " + String(session.scopeTitle.prefix(300)) }
        try validateFrozenChapterScope(session, in: project)
        project.smartReading = session
        return true
    }

    static func validateFrozenChapterScope(_ session: SmartReadingSession, in project: BookProject) throws {
        guard let index = session.chapterIndex, let ranges = session.sourceRanges,
              !index.segments.isEmpty, index.segments.count <= 100_000,
              ranges.count <= 200_000 else { throw ReadingError.invalid("冻结的章节目录与当前原文不一致，请重新选择范围；旧结果保留。") }
        try BookChapterRuntime.validate(index: index, in: project)
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let order = Dictionary(try selectedUnits(in: project).enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(session.unitIDs)
        func validate(_ values: [ReadingSourceRange]) throws {
            var previous: ReadingSourceRange?
            for value in values {
                try Task.checkCancellation()
                guard let unit = units[value.unitID], let position = order[value.unitID] else { throw ReadingError.invalid("章节范围的原文单元不存在。") }
                try value.validate(in: unit)
                if let previous, let earlier = order[previous.unitID] {
                    guard position > earlier || (position == earlier && value.startUTF16 >= previous.endUTF16) else { throw ReadingError.invalid("章节原文范围重叠或顺序错误。") }
                }
                previous = value
            }
        }
        try validate(ranges)
        guard ranges.allSatisfy({ ids.contains($0.unitID) }),
              Set(ranges.map(\.unitID)) == Set(session.unitIDs.filter { !(units[$0]?.text.isEmpty ?? true) }) else {
            throw ReadingError.invalid("章节范围与本轮原文清单不一致。")
        }
        let covered = mergedChapterRanges(index)
        for range in ranges {
            guard covered[range.unitID].map({ $0.startUTF16 <= range.startUTF16 && $0.endUTF16 >= range.endUTF16 }) == true else {
                throw ReadingError.invalid("章节目录未完整覆盖所选原文。")
            }
        }
        if (session.scope == .currentChapter || session.scope == .chapterRange) && session.retainedAnalysisChunks == nil {
            if session.scope == .chapterRange {
                guard ranges == (try selectedChapterRanges(session.selection, index: index, in: project)),
                      Set(ranges.map(\.unitID)) == ids else { throw ReadingError.invalid("保存的多章范围与冻结目录不一致。") }
            } else {
                guard (index.chapters + index.segments.filter { $0.id.hasPrefix("chapter-preface-") }).contains(where: { $0.isComplete && $0.ranges == ranges }) else { throw ReadingError.invalid("保存的当前章范围不完整。") }
            }
        } else {
            let expected = try selectedUnits(in: project, allowedUnitIDs: ids)
            switch session.scope {
            case .wholeBook:
                guard session.unitIDs == (try selectedUnits(in: project)).map(\.id) else { throw ReadingError.invalid("保存的全书范围不完整。") }
            case .currentPage:
                guard let page = expected.first?.page, expected.allSatisfy({ $0.page == page }),
                      Set(expected.map(\.id)) == Set(project.units.filter { $0.page == page }.map(\.id)) else { throw ReadingError.invalid("保存的当前页范围不一致。") }
            case .pageRange:
                guard let first = session.selection.pageStart, let last = session.selection.pageEnd, first > 0, last >= first,
                      Set(expected.map(\.id)) == Set(project.units.filter { $0.page.map { (first...last).contains($0) } ?? false }.map(\.id)) else { throw ReadingError.invalid("保存的页码范围不一致。") }
            case .currentChapter: break
            case .chapterRange:
                guard ranges == (try selectedChapterRanges(session.selection, index: index, in: project)) else { throw ReadingError.invalid("保存的多章范围与冻结目录不一致。") }
            }
            let grouped = Dictionary(grouping: ranges, by: \.unitID)
            for unit in expected where !unit.text.isEmpty && session.scope != .currentChapter && session.scope != .chapterRange {
                let local = grouped[unit.id] ?? []
                guard local.first?.startUTF16 == 0, local.last?.endUTF16 == (unit.text as NSString).length,
                      zip(local, local.dropFirst()).allSatisfy({ pair in pair.0.endUTF16 == pair.1.startUTF16 }) else { throw ReadingError.invalid("页码或全书范围缺少原文片段。") }
            }
        }
        if let retained = session.retainedAnalysisChunks {
            guard retained.count <= 100_000, Set(retained.map(\.id)).count == retained.count,
                  session.retainedAnalysisWorkHash.map({ $0.count == 64 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }) == true,
                  retained.allSatisfy({ $0.sourceRanges == nil && $0.chapterID == nil && Set($0.unitIDs).isSubset(of: ids) }) else { throw ReadingError.invalid("保留的历史分析块无效。") }
            var snapshot = project; snapshot.smartReading = session
            guard retained.allSatisfy({ isChunkComplete($0, in: snapshot) }) else { throw ReadingError.invalid("保留的历史分析凭据不完整，未改写任务。") }
        }
    }

    static func chapterAnalysisChunks(in project: BookProject, allowedUnitIDs: Set<String>?) throws -> [ReadingAnalysisChunk] {
        guard let session = project.smartReading, let configuration = session.selection.execution,
              let index = session.chapterIndex, let selected = session.sourceRanges else { return [] }
        try configuration.validate()
        let allowed = allowedUnitIDs ?? Set(session.unitIDs)
        guard allowed.isSubset(of: Set(session.unitIDs)) else { throw ReadingError.invalid("分析块超出本轮范围。") }
        let source = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let base = try chapterWorkFingerprint(in: project)
        let retained = session.retainedAnalysisWorkHash == base ? (session.retainedAnalysisChunks ?? []).filter { Set($0.unitIDs).isSubset(of: allowed) } : []
        let retainedIDs = Set(retained.flatMap(\.unitIDs))
        let eligible = allowed.subtracting(retainedIDs)
        let selectionByUnit = Dictionary(grouping: selected, by: \.unitID)
        var confirmedBlankByID: [String: Bool] = [:]
        func confirmedBlank(_ unit: SourceUnit) -> Bool {
            if let checked = confirmedBlankByID[unit.id] { return checked }
            let checked = isConfirmedBlank(unit, in: project)
            confirmedBlankByID[unit.id] = checked
            return checked
        }
        struct Group { var chapter: BookChapterRange; var ranges: [ReadingSourceRange] }
        var groups: [Group] = []
        let granularity = configuration.granularity == .adaptive ? (project.plan?.recommendedGranularity ?? .adaptive) : configuration.granularity
        for chapter in index.segments {
            var pending: [ReadingSourceRange] = [], characterCount = 0, previousPage: Int?
            func finish() { if !pending.isEmpty { groups.append(Group(chapter: chapter, ranges: pending)); pending = []; characterCount = 0 } }
            for declared in chapter.ranges where eligible.contains(declared.unitID) {
                try Task.checkCancellation()
                guard let unit = source[declared.unitID], !ReadingLedger.isDeferred(unitID: unit.id, in: project), !confirmedBlank(unit) else { continue }
                for selected in selectionByUnit[unit.id] ?? [] {
                    let start = max(selected.startUTF16, declared.startUTF16), end = min(selected.endUTF16, declared.endUTF16)
                    guard end > start else { continue }
                    let selectedRange = ReadingSourceRange(unitID: unit.id, startUTF16: start, endUTF16: end)
                    let text = try selectedRange.text(in: unit)
                    var cursor = text.startIndex, utf16Start = start
                    while cursor < text.endIndex {
                        try Task.checkCancellation()
                        let next = text.index(cursor, offsetBy: 20_000, limitedBy: text.endIndex) ?? text.endIndex
                        let part = text[cursor..<next], count = part.count
                        let range = ReadingSourceRange(unitID: unit.id, startUTF16: utf16Start, endUTF16: utf16Start + part.utf16.count)
                        let pageBoundary = granularity == .page && !pending.isEmpty && (previousPage != unit.page || unit.page == nil)
                        if !pending.isEmpty && (pageBoundary || (!pending.contains(where: { $0.unitID == unit.id }) && Set(pending.map(\.unitID)).count >= 12) || characterCount + count > 20_000) { finish() }
                        pending.append(range); characterCount += count; previousPage = unit.page
                        cursor = next; utf16Start = range.endUTF16
                    }
                }
            }
            finish()
        }
        // Explicitly confirmed blank tails need no AI work. A deferred tail is
        // still unread and must not turn the preceding content into a chapter end.
        func workEnd(_ chapter: BookChapterRange) -> ReadingSourceRange? {
            chapter.ranges.last { range in
                guard let unit = source[range.unitID] else { return true }
                return !confirmedBlank(unit)
            }
        }
        let chapterEnds = Dictionary(index.chapters.compactMap { chapter -> (String, ReadingSourceRange)? in
            workEnd(chapter).map { (chapter.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let checkpointsByID = Dictionary((session.analysisCheckpoints ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = try groups.enumerated().map { offset, group -> ReadingAnalysisChunk in
            let ranges = group.ranges
            var seen = Set<String>()
            let ids = ranges.map(\.unitID).filter { seen.insert($0).inserted }
            let declaredEnd = chapterEnds[group.chapter.id] ?? workEnd(group.chapter)
            let actualEnd = ranges.last
            let chapterEnd = declaredEnd.map { declared in actualEnd.map { $0.unitID == declared.unitID && $0.endUTF16 == declared.endUTF16 } ?? false } ?? false
            let steps = configuration.enabledSteps.filter { $0.frequency == .chunk || ($0.frequency == .chapter && chapterEnd && group.chapter.isComplete) || ($0.frequency == .book && offset == groups.count - 1) }.map(\.id)
            let proof = ranges.map { "\($0.unitID):\(session.unitHashes[$0.unitID] ?? ""):\($0.startUTF16):\($0.endUTF16)" }.joined(separator: "|")
            let identity = try BookImporter.sha256(Data((base + "|" + group.chapter.id).utf8))
            let baseID = "chunk-" + String(try BookImporter.sha256(Data((project.sourceHash + "|" + identity + "|" + proof).utf8)).prefix(48))
            let localSteps = configuration.enabledSteps.filter { $0.frequency == .chunk }.map(\.id)
            let id = try analysisChunkID(baseID: baseID, stepIDs: localSteps, checkpointsByID: checkpointsByID)
            return ReadingAnalysisChunk(id: id, title: group.chapter.title, unitIDs: ids, configurationHash: identity, stepIDs: steps,
                sourceRanges: ranges, chapterID: group.chapter.id)
        }
        result += retained
        let positions = Dictionary(project.units.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return result.sorted {
            let a = positions[$0.unitIDs.first ?? ""] ?? Int.max, b = positions[$1.unitIDs.first ?? ""] ?? Int.max
            if a != b { return a < b }
            let x = $0.sourceRanges?.first?.startUTF16 ?? 0, y = $1.sourceRanges?.first?.startUTF16 ?? 0
            return x == y ? $0.id < $1.id : x < y
        }
    }

    private static func mergedChapterRanges(_ index: BookChapterIndex) -> [String: ReadingSourceRange] {
        var result: [String: ReadingSourceRange] = [:]
        for range in index.segments.flatMap(\.ranges) {
            if var prior = result[range.unitID], prior.endUTF16 == range.startUTF16 {
                prior.endUTF16 = range.endUTF16; result[range.unitID] = prior
            } else if result[range.unitID] == nil { result[range.unitID] = range }
        }
        return result
    }
    static func chapterIndexCovers(_ index: BookChapterIndex, units: [SourceUnit]) -> Bool {
        let covered = mergedChapterRanges(index)
        return units.allSatisfy { unit in
            unit.text.isEmpty || covered[unit.id].map { $0.startUTF16 == 0 && $0.endUTF16 == unit.text.utf16.count } == true
        }
    }

    private static func chapterWorkFingerprint(in project: BookProject) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let configuration = project.smartReading?.selection.execution else { throw ReadingError.invalid("缺少本轮阅读配置。") }
        var work = configuration; work.maximumConcurrentRequests = 1; work.steps = configuration.enabledSteps
        var plan = project.plan; plan?.rationale = ""; plan?.recommendedParallelism = nil
        if configuration.granularity != .adaptive { plan?.recommendedGranularity = nil }
        let directions = readingDirections(in: project)
        let directionData = directions.isEmpty ? Data() : try JSONSerialization.data(withJSONObject: directions, options: [.sortedKeys])
        return try readingGenerationFingerprint(BookImporter.sha256(Data("reading-chapters-v1|".utf8) + Data(try work.fingerprint().utf8) + encoder.encode(plan) + directionData), in: project)
    }

    /// Source projection only: never save these copied units or hash them as originals.
    public static func analysisSourceUnits(in project: BookProject, allowedUnitIDs: Set<String>? = nil, ranges: [ReadingSourceRange]? = nil) throws -> [SourceUnit] {
        let units = try selectedUnits(in: project, allowedUnitIDs: allowedUnitIDs)
        guard let ranges = ranges ?? project.smartReading?.sourceRanges else { return units }
        let grouped = Dictionary(grouping: ranges, by: \.unitID)
        return try units.compactMap { unit in
            guard let local = grouped[unit.id], !local.isEmpty else { return unit.text.isEmpty ? unit : nil }
            guard zip(local, local.dropFirst()).allSatisfy({ pair in pair.0.endUTF16 == pair.1.startUTF16 }) else {
                throw ReadingError.invalid("所选原文片段不连续，请分别处理；未拼接为完整原文。")
            }
            var copy = unit
            copy.text = try local.map { try $0.text(in: unit) }.joined()
            return copy
        }
    }

    static func rangesContained(_ values: [ReadingSourceRange], in granted: [ReadingSourceRange]) -> Bool {
        let byUnit = Dictionary(grouping: granted, by: \.unitID)
        for value in values {
            var frontier = value.startUTF16
            for item in byUnit[value.unitID] ?? [] where item.endUTF16 > frontier {
                if item.startUTF16 > frontier { break }
                frontier = max(frontier, item.endUTF16)
                if frontier >= value.endUTF16 { break }
            }
            if frontier < value.endUTF16 { return false }
        }
        return true
    }

    /// New evidence must be literal inside this worker's exact slice. Existing
    /// knowledge may still be retrieved as derived context, never as new evidence.
    public static func analysisEvidenceAdmitted(_ evidence: Evidence, in project: BookProject) -> Bool {
        evidenceAdmitted(evidence, ranges: AnalysisSourceGuard.currentRanges, in: project)
    }
    static func evidenceAdmitted(_ evidence: Evidence, ranges: [ReadingSourceRange]?, in project: BookProject) -> Bool {
        guard !evidence.quote.isEmpty, let unit = project.units.first(where: { $0.id == evidence.unitID }) else { return false }
        guard let ranges else { return SourceTextLiteral.contains(evidence.quote, in: unit.text) }
        return ranges.filter { $0.unitID == evidence.unitID }.contains { range in
            guard let text = try? range.text(in: unit) else { return false }
            return SourceTextLiteral.contains(evidence.quote, in: text)
        }
    }
    public static func analysisAnchorAdmitted(_ anchor: SourceAnchor, in project: BookProject) -> Bool {
        guard let resolved = try? ReadingExperienceRuntime.resolve(anchor, in: project) else { return false }
        guard let ranges = AnalysisSourceGuard.currentRanges else { return true }
        return ranges.contains { $0.unitID == anchor.unitID && resolved.utf16Location >= $0.startUTF16 &&
            resolved.utf16Location <= $0.endUTF16 && resolved.utf16Length <= $0.endUTF16 - resolved.utf16Location }
    }
}
