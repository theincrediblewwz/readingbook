import Foundation

/// A saved scope review is about its complete frozen input, not the page used
/// to carry its bounded source/tool authority.
public struct ReadingAnalysisScopeJob: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case chapter, book }
    public var kind: Kind
    public var scopeUnitIDs: [String]
    public var sourceRanges: [ReadingSourceRange]?
    public var dependencyIDs: [String]
    public var inputFingerprint: String
    public var localConfigurationHash: String? = nil
}

/// Construct once for a projection. Work IDs are not fabricated checkpoints:
/// every success maps back to one actual immutable saved record.
public struct ReadingAnalysisCompletionIndex: Sendable {
    private let checkpoints: [String: ReadingAnalysisCheckpoint]
    private let unitHashes: [String: String]
    private var versionCache: [String: String] = [:]
    public init(in project: BookProject) {
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var accepted: [String: ReadingAnalysisCheckpoint] = [:], sourceHashes: [String: String] = [:]
        let records = project.smartReading?.analysisCheckpoints ?? []
        if records.count <= 100_000 {
            let duplicateIDs = Set(Dictionary(grouping: records, by: \.id).filter { $0.value.count > 1 }.keys)
            for record in records where !duplicateIDs.contains(record.id) {
                if Self.valid(record, units: units, sourceHashes: &sourceHashes) { accepted[record.id] = record }
            }
        }
        checkpoints = accepted
        unitHashes = project.smartReading?.unitHashes ?? [:]
    }
    private static func valid(_ record: ReadingAnalysisCheckpoint, units: [String: SourceUnit], sourceHashes: inout [String: String]) -> Bool {
        guard record.id.range(of: "^chunk-[a-f0-9]{48}$", options: .regularExpression) != nil,
              (1...12).contains(record.unitIDs.count), Set(record.unitIDs).count == record.unitIDs.count,
              Set(record.unitHashes.keys) == Set(record.unitIDs),
              record.configurationHash.count == 64, record.configurationHash.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              record.completedStepIDs.count <= 24, Set(record.completedStepIDs).count == record.completedStepIDs.count,
              record.completedStepIDs.allSatisfy({ $0.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil }),
              !record.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, record.markdown.count <= 16_000,
              record.updatedAt.timeIntervalSince1970.isFinite, (1...128).contains(record.evidence.count),
              Set(record.evidence.map(\.unitID)) == Set(record.unitIDs),
              (try? SmartReadingRuntime.validateAnalysisScopeMetadata(record, units: units)) != nil else { return false }
        for id in record.unitIDs {
            guard let unit = units[id] else { return false }
            let actual: String
            if let cached = sourceHashes[id] { actual = cached }
            else {
                guard let digest = try? BookImporter.sha256(Data(unit.text.utf8)) else { return false }
                sourceHashes[id] = digest; actual = digest
            }
            guard record.unitHashes[id] == actual else { return false }
        }
        var admitted: [String: [String]] = [:]
        if let ranges = record.sourceRanges {
            guard !ranges.isEmpty, ranges.count <= 128, Set(ranges.map(\.unitID)) == Set(record.unitIDs),
                  record.chapterID.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) == true else { return false }
            var merged: [ReadingSourceRange] = []
            for range in ranges {
                guard let unit = units[range.unitID], (try? range.validate(in: unit)) != nil else { return false }
                if let previous = merged.last, let previousUnit = units[previous.unitID] {
                    guard unit.order > previousUnit.order || (range.unitID == previous.unitID && range.startUTF16 >= previous.endUTF16) else { return false }
                    if range.unitID == previous.unitID && range.startUTF16 == previous.endUTF16 {
                        merged[merged.count - 1].endUTF16 = range.endUTF16
                        continue
                    }
                }
                merged.append(range)
            }
            for range in merged {
                guard let unit = units[range.unitID], let text = try? range.text(in: unit) else { return false }
                admitted[range.unitID, default: []].append(text)
            }
        } else {
            guard record.chapterID == nil else { return false }
            for id in record.unitIDs { if let text = units[id]?.text { admitted[id] = [text] } }
        }
        return record.evidence.allSatisfy { evidence in
            !evidence.quote.isEmpty && evidence.quote.count <= 32_768 &&
                admitted[evidence.unitID]?.contains(where: { SourceTextLiteral.contains(evidence.quote, in: $0) }) == true
        }
    }
    public func checkpointIDs(for chunk: ReadingAnalysisChunk) -> [String] { checkpoint(for: chunk).map { [$0.id] } ?? [] }
    public func isComplete(_ chunk: ReadingAnalysisChunk) -> Bool { checkpoint(for: chunk) != nil }
    func checkpoint(for chunk: ReadingAnalysisChunk) -> ReadingAnalysisCheckpoint? {
        guard let saved = checkpoints[chunk.id], saved.unitIDs == chunk.unitIDs,
              saved.configurationHash == chunk.configurationHash, saved.sourceRanges == chunk.sourceRanges,
              saved.chapterID == chunk.chapterID, saved.scopeJob == chunk.scopeJob,
              chunk.unitIDs.allSatisfy({ saved.unitHashes[$0] == unitHashes[$0] }) else { return nil }
        let actual = Set(saved.completedStepIDs), required = Set(chunk.stepIDs)
        // A historical composite completed all these exact local requirements.
        // Preserve its real output; do not synthesize one output per old step.
        guard chunk.scopeJob == nil ? required.isSubset(of: actual) : required == actual else { return nil }
        if let savedComponents = saved.requiredComponentKinds, let requiredComponents = chunk.requiredComponentKinds,
           !Set(requiredComponents).isSubset(of: Set(savedComponents)) { return nil }
        return saved
    }
    mutating func versionFingerprint(for chunk: ReadingAnalysisChunk) throws -> String {
        if let cached = versionCache[chunk.id] { return cached }
        guard let saved = checkpoint(for: chunk) else { return "pending:" + chunk.id }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let value = try BookImporter.sha256(encoder.encode(saved))
        versionCache[chunk.id] = value
        return value
    }
}

extension SmartReadingRuntime {
    static func validateAnalysisScopeMetadata(_ checkpoint: ReadingAnalysisCheckpoint, units: [String: SourceUnit]) throws {
        if let components = checkpoint.requiredComponentKinds {
            guard components.count <= 8, Set(components).count == components.count,
                  Set(components).isSubset(of: Set(ReadingExecutionConfiguration.offeredComponents)) else {
                throw ReadingError.invalid("分析工作的组件要求无效。")
            }
        }
        guard let job = checkpoint.scopeJob else { return }
        guard !job.scopeUnitIDs.isEmpty, job.scopeUnitIDs.count <= BookImporter.maximumUnits,
              Set(job.scopeUnitIDs).count == job.scopeUnitIDs.count, job.scopeUnitIDs.allSatisfy({ units[$0] != nil }),
              !checkpoint.completedStepIDs.isEmpty,
              !job.dependencyIDs.isEmpty, job.dependencyIDs.count <= 100_000,
              Set(job.dependencyIDs).count == job.dependencyIDs.count,
              job.dependencyIDs.allSatisfy({ $0.range(of: "^chunk-[a-f0-9]{48}$", options: .regularExpression) != nil }),
              job.inputFingerprint.count == 64, job.inputFingerprint.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              job.localConfigurationHash.map({ $0.count == 64 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }) ?? true,
              (job.sourceRanges?.count ?? 0) <= 200_000 else { throw ReadingError.invalid("范围回顾的依赖或冻结范围无效。") }
        let scopeIDs = Set(job.scopeUnitIDs)
        for range in job.sourceRanges ?? [] {
            guard scopeIDs.contains(range.unitID), let unit = units[range.unitID] else { throw ReadingError.invalid("范围回顾来源不存在。") }
            try range.validate(in: unit)
        }
    }

    static func readingGenerationFingerprint(_ base: String, in project: BookProject) throws -> String {
        guard let generation = project.smartReading?.continuation?.generationID else { return base }
        return try BookImporter.sha256(Data(("reading-generation-v1|" + generation + "|" + base).utf8))
    }

    static func scopeAnalysisJobs(raw: [ReadingAnalysisChunk], localGroups: [[ReadingAnalysisChunk]], in project: BookProject) throws -> [ReadingAnalysisChunk] {
        guard raw.count == localGroups.count else { throw ReadingError.invalid("补充分析投影与原文块不一致，未安排请求。") }
        guard let configuration = project.smartReading?.selection.execution else { return [] }
        var index = ReadingAnalysisCompletionIndex(in: project)
        let sources = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let order = Dictionary(project.units.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var insightsByUnit: [String: [ReadingInsight]] = [:]
        for insight in project.insights { for id in insight.unitIDs { insightsByUnit[id, default: []].append(insight) } }
        var deferredIDs = Set<String>(), blankIDs = Set<String>()
        for unit in project.units {
            var scoped = project; scoped.units = [unit]; scoped.insights = insightsByUnit[unit.id] ?? []
            if ReadingLedger.isDeferred(unitID: unit.id, in: scoped) { deferredIDs.insert(unit.id) }
            if isConfirmedBlank(unit, in: scoped) { blankIDs.insert(unit.id) }
        }
        func chapterKey(_ chunk: ReadingAnalysisChunk) -> String { chunk.chapterID ?? chunk.unitIDs.first.flatMap { sources[$0]?.chapter } ?? "" }
        var result: [ReadingAnalysisChunk] = [], local: [ReadingAnalysisChunk] = [], chapterReviews: [ReadingAnalysisChunk] = []
        func review(carrier: ReadingAnalysisChunk, kind: ReadingAnalysisScopeJob.Kind, steps: [String], dependencies: [ReadingAnalysisChunk], scopeSources: [ReadingAnalysisChunk]) throws -> ReadingAnalysisChunk {
            let ids = kind == .book ? Set(project.smartReading?.unitIDs ?? scopeSources.flatMap(\.unitIDs)) : Set(scopeSources.flatMap(\.unitIDs))
            let scopeIDs = ids.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
            let ranges = kind == .book ? project.smartReading?.sourceRanges : (scopeSources.contains { $0.sourceRanges != nil } ? Array(Set(scopeSources.flatMap { $0.sourceRanges ?? [] })).sorted {
                let a = order[$0.unitID] ?? 0, b = order[$1.unitID] ?? 0
                return a == b ? $0.startUTF16 < $1.startUTF16 : a < b
            } : nil)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let scopeProof = scopeIDs.map { id in
                id + ":" + (project.smartReading?.unitHashes[id] ?? "") + ":deferred=" + String(deferredIDs.contains(id))
                    + ":blank=" + String(blankIDs.contains(id))
            }
            let identity = try BookImporter.sha256(Data(("reading-scope-work-v1|" + carrier.configurationHash + "|" + kind.rawValue).utf8)
                + encoder.encode(scopeProof) + encoder.encode(ranges) + encoder.encode(steps))
            let versions = try dependencies.map { [$0.id, try index.versionFingerprint(for: $0)] }
            let input = try BookImporter.sha256(encoder.encode(versions))
            var job = carrier
            job.configurationHash = identity
            job.id = "chunk-" + String(try BookImporter.sha256(Data((identity + "|" + input).utf8)).prefix(48))
            job.stepIDs = steps
            job.requiredComponentKinds = []
            job.scopeJob = ReadingAnalysisScopeJob(kind: kind, scopeUnitIDs: scopeIDs, sourceRanges: ranges,
                dependencyIDs: dependencies.map(\.id), inputFingerprint: input, localConfigurationHash: carrier.configurationHash)
            job.title = kind == .book ? "本轮结束步骤 · " + (project.smartReading?.scopeTitle ?? "所选范围") : "章末步骤 · " + carrier.title
            return job
        }
        for (position, chunk) in raw.enumerated() {
            try Task.checkCancellation()
            result += localGroups[position]; local += localGroups[position]
            let chapterSteps = configuration.enabledSteps.filter { $0.frequency == .chapter && chunk.stepIDs.contains($0.id) }.map(\.id)
            if !chapterSteps.isEmpty {
                let key = chapterKey(chunk)
                let deps = local.filter { chapterKey($0) == key }
                let scope = Array(raw.prefix(position + 1)).filter { chapterKey($0) == key }
                let job = try review(carrier: chunk, kind: .chapter, steps: chapterSteps, dependencies: deps, scopeSources: scope)
                result.append(job); chapterReviews.append(job)
            }
        }
        let bookSteps = configuration.enabledSteps.filter { $0.frequency == .book }.map(\.id)
        if let carrier = raw.last, !bookSteps.isEmpty {
            result.append(try review(carrier: carrier, kind: .book, steps: bookSteps,
                dependencies: local + chapterReviews, scopeSources: raw))
        }
        return result
    }

    public static func analysisDependenciesComplete(_ chunk: ReadingAnalysisChunk, in project: BookProject) throws -> Bool {
        guard let job = chunk.scopeJob else { return true }
        guard let session = project.smartReading else { return false }
        try validate(session, in: project)
        let current = try analysisChunks(in: project)
        guard current.contains(chunk) else { return false }
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let index = ReadingAnalysisCompletionIndex(in: project)
        return !job.dependencyIDs.isEmpty && job.dependencyIDs.allSatisfy { id in byID[id].map { index.isComplete($0) } == true }
    }
}
