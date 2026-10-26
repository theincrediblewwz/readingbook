import Foundation

public enum ReadingAnalysisPrecision: String, Codable, CaseIterable, Hashable, Sendable {
    case standard, close
    public var title: String { self == .standard ? "标准阅读" : "逐段精读" }
}
public enum ReadingAnalysisGranularity: String, Codable, CaseIterable, Hashable, Sendable {
    case adaptive, page, chapter
    public var title: String { self == .adaptive ? "AI 自适应" : self == .page ? "按页" : "按章" }
}
public enum ReadingStepFrequency: String, Codable, CaseIterable, Hashable, Sendable {
    case chunk, chapter, book
    public var title: String { self == .chunk ? "每部分" : self == .chapter ? "每章" : "本轮结束" }
}
public struct ReadingExecutionStep: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var actionID: String
    public var frequency: ReadingStepFrequency
    public var enabled: Bool
    public init(id: String = UUID().uuidString, title: String, actionID: String = "ai.analyze", frequency: ReadingStepFrequency = .chunk, enabled: Bool = true) {
        self.id = id; self.title = title; self.actionID = actionID; self.frequency = frequency; self.enabled = enabled
    }
}
public struct ReadingExecutionConfiguration: Codable, Hashable, Sendable {
    public var precision: ReadingAnalysisPrecision
    public var granularity: ReadingAnalysisGranularity
    public var componentKinds: [ComponentKind]
    public var steps: [ReadingExecutionStep]
    public var maximumConcurrentRequests: Int
    public init(precision: ReadingAnalysisPrecision = .standard, granularity: ReadingAnalysisGranularity = .adaptive,
                componentKinds: [ComponentKind] = [], steps: [ReadingExecutionStep] = ReadingExecutionConfiguration.defaultSteps, maximumConcurrentRequests: Int = 3) {
        self.precision = precision; self.granularity = granularity; self.componentKinds = componentKinds
        self.steps = steps; self.maximumConcurrentRequests = maximumConcurrentRequests
    }
    public static var defaultSteps: [ReadingExecutionStep] { [
        ReadingExecutionStep(id: "understand", title: "讲清这一部分的内容", actionID: "ai.analyze"),
        ReadingExecutionStep(id: "organize", title: "整理重要人物、事件和联系", actionID: "facts.extract"),
        ReadingExecutionStep(id: "companion", title: "补充合适的译注和解释", actionID: "reading.enrich"),
        ReadingExecutionStep(id: "review", title: "读完后回顾变化与问题", actionID: "reading.review", frequency: .book)
    ] }
    public static var offeredComponents: [ComponentKind] { [.cards, .map, .timeline, .mindmap, .relations, .knowledge] }
    public var enabledSteps: [ReadingExecutionStep] { steps.filter(\.enabled) }
    public func validate() throws {
        let actions: Set<String> = ["ai.analyze", "facts.extract", "reading.enrich", "reading.review", "citations.verify"]
        guard (1...5).contains(maximumConcurrentRequests), componentKinds.count <= 8,
              Set(componentKinds).count == componentKinds.count, Set(componentKinds).isSubset(of: Set(Self.offeredComponents)),
              (0...24).contains(steps.count), Set(steps.map(\.id)).count == steps.count,
              steps.allSatisfy({ $0.id.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 500 && actions.contains($0.actionID) }) else {
            throw ReadingError.invalid("阅读步骤、组件或并行上限无效；尚未发送请求。")
        }
    }
    public func fingerprint() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try BookImporter.sha256(encoder.encode(self))
    }
    /// Explicit reader choices add view declarations; empty data stays an honest empty state.
    /// No object, source evidence, document, or coverage is manufactured here.
    public func configureRequestedViews(in project: inout BookProject) {
        for kind in componentKinds where !project.views.contains(where: { $0.kind == kind }) {
            let id = "reader-requested-" + kind.rawValue
            guard !project.views.contains(where: { $0.id == id }) else { continue }
            project.views.append(ViewDefinition(id: id, title: kind.title, kind: kind))
        }
    }
}

public struct ReadingAnalysisChunk: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var unitIDs: [String]
    public var configurationHash: String
    public var stepIDs: [String]
    /// Nil in historical whole-unit work. Exact source offsets never replace original unit identities.
    public var sourceRanges: [ReadingSourceRange]? = nil
    public var chapterID: String? = nil
}
public struct ReadingAnalysisCheckpoint: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var unitIDs: [String]
    public var unitHashes: [String: String]
    public var configurationHash: String
    public var completedStepIDs: [String]
    public var markdown: String
    public var evidence: [Evidence]
    public var updatedAt: Date
    public var sourceRanges: [ReadingSourceRange]? = nil
    public var chapterID: String? = nil
    public var noChangesReasons: [String: String]? = nil
    /// Computed by the host; never accepted from model tool arguments.
    public var hostCitationSummary: String? = nil
}

/// A task-local host capability, never a JSON field or a persisted active chunk.
/// Parallel workers cannot widen each other's permitted source.
enum ReadingAnalysisAuthority {
    struct Grant: Sendable {
        var bookID: String; var sessionID: String; var sourceHash: String
        var chunk: ReadingAnalysisChunk; var unitHashes: [String: String]
    }
    @TaskLocal static var current: Grant?
}

extension SmartReadingRuntime {
    public static func analysisChunks(in project: BookProject, allowedUnitIDs: Set<String>? = nil) throws -> [ReadingAnalysisChunk] {
        if project.smartReading?.chapterIndex != nil { return try chapterAnalysisChunks(in: project, allowedUnitIDs: allowedUnitIDs) }
        return try legacyAnalysisChunks(in: project, allowedUnitIDs: allowedUnitIDs)
    }
    static func legacyAnalysisChunks(in project: BookProject, allowedUnitIDs: Set<String>? = nil) throws -> [ReadingAnalysisChunk] {
        guard let session = project.smartReading, let configuration = session.selection.execution else { return [] }
        try configuration.validate()
        let allowed = allowedUnitIDs ?? Set(session.unitIDs)
        guard allowed.isSubset(of: Set(session.unitIDs)) else { throw ReadingError.invalid("分析块超出本轮范围。") }
        let units = try selectedUnits(in: project, allowedUnitIDs: allowed).filter { !ReadingLedger.isDeferred(unitID: $0.id, in: project) && !isConfirmedBlank($0, in: project) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Worker counts and prose explaining a plan cannot invalidate completed
        // reading. Actual source, enabled steps, focus and grouping still do.
        var workConfiguration = configuration
        workConfiguration.maximumConcurrentRequests = 1
        workConfiguration.steps = configuration.enabledSteps
        var workPlan = project.plan
        workPlan?.rationale = ""; workPlan?.recommendedParallelism = nil
        if configuration.granularity != .adaptive { workPlan?.recommendedGranularity = nil }
        let directions = readingDirections(in: project)
        let directionData = directions.isEmpty ? Data() : try JSONSerialization.data(withJSONObject: directions, options: [.sortedKeys])
        let fingerprint = try BookImporter.sha256(Data("reading-work-v2|".utf8) + Data(try workConfiguration.fingerprint().utf8) + encoder.encode(workPlan) + directionData)
        // 0.20 originally hashed the scheduling knobs too. Recognize only exact
        // known old configurations, once per whole-book projection, keeping all
        // source/steps/focus checks. Unknown historical rationale is not guessed.
        var legacyFingerprints = Set<String>()
        // Earlier 0.20 did not send confirmed method goals/focus to analysis.
        // Its products survive, but cannot count as work using a new direction.
        let newProductContract = !configuration.componentKinds.isEmpty || configuration.enabledSteps.contains { ["facts.extract", "reading.enrich", "citations.verify"].contains($0.actionID) }
        if directions.isEmpty && (project.plan?.focus.isEmpty ?? true) && !newProductContract && !(session.analysisCheckpoints ?? []).isEmpty {
            let hashes = try (1...5).map { count -> String in
                var legacy = configuration; legacy.maximumConcurrentRequests = count
                return try legacy.fingerprint()
            }
            let parallelismOptions: [Int?] = [nil, 1, 2, 3, 4, 5]
            let plans = try parallelismOptions.map { count -> Data in
                var legacy = project.plan; legacy?.recommendedParallelism = count
                return try encoder.encode(legacy)
            }
            for hash in hashes { for plan in plans { legacyFingerprints.insert(try BookImporter.sha256(Data(hash.utf8) + plan)) } }
        }
        let checkpoints = Dictionary(grouping: session.analysisCheckpoints ?? [], by: \.unitIDs)
        let checkpointsByID = Dictionary((session.analysisCheckpoints ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let granularity = configuration.granularity == .adaptive ? (project.plan?.recommendedGranularity ?? .adaptive) : configuration.granularity
        var groups: [[SourceUnit]] = [], pending: [SourceUnit] = [], characters = 0
        for unit in units {
            let boundary: Bool
            switch granularity {
            case .page: boundary = pending.last.map { $0.page != unit.page || ($0.page == nil && $0.id != unit.id) } ?? false
            case .chapter: boundary = pending.last.map { $0.chapter != unit.chapter } ?? false
            case .adaptive: boundary = pending.last.map { $0.chapter != unit.chapter } ?? false
            }
            if !pending.isEmpty && (boundary || pending.count >= 12 || characters + unit.text.count > 20_000) { groups.append(pending); pending = []; characters = 0 }
            pending.append(unit); characters += unit.text.count
        }
        if !pending.isEmpty { groups.append(pending) }
        return try groups.enumerated().map { index, group in
            let ids = group.map(\.id)
            let sourceKey = ids.map { $0 + ":" + (session.unitHashes[$0] ?? "") }.joined(separator: "|")
            var id = "chunk-" + String(try BookImporter.sha256(Data((project.sourceHash + "|" + fingerprint + "|" + sourceKey).utf8)).prefix(48))
            let chapters = Set(group.map(\.chapter))
            let isChapterEnd = groups.dropFirst(index + 1).first.map { !chapters.contains($0.first?.chapter ?? "") } ?? true
            let stepIDs = configuration.enabledSteps.filter { $0.frequency == .chunk || ($0.frequency == .chapter && isChapterEnd) || ($0.frequency == .book && index == groups.count - 1) }.map(\.id)
            var identity = fingerprint
            if let previous = try checkpoints[ids]?.first(where: { checkpoint in
                guard legacyFingerprints.contains(checkpoint.configurationHash), Set(checkpoint.completedStepIDs) == Set(stepIDs),
                      ids.allSatisfy({ checkpoint.unitHashes[$0] == session.unitHashes[$0] }) else { return false }
                let expected = "chunk-" + String(try BookImporter.sha256(Data((project.sourceHash + "|" + checkpoint.configurationHash + "|" + sourceKey).utf8)).prefix(48))
                return checkpoint.id == expected
            }) { id = previous.id; identity = previous.configurationHash }
            let pages = Array(Set(group.compactMap(\.page))).sorted()
            let title = pages.first.map { start in pages.last == start ? "第 \(start) 页" : "第 \(start)–\(pages.last ?? start) 页" } ?? group.first?.chapter ?? "本部分"
            id = try analysisChunkID(baseID: id, stepIDs: stepIDs, checkpointsByID: checkpointsByID)
            return ReadingAnalysisChunk(id: id, title: title, unitIDs: ids, configurationHash: identity, stepIDs: stepIDs)
        }
    }
    /// Excluding or restoring a tail can move chapter/book steps without changing
    /// this block's source. Preserve the old checkpoint and use a stable identity
    /// for the new step contract rather than colliding with its immutable record.
    static func analysisChunkID(baseID: String, stepIDs: [String], checkpointsByID: [String: ReadingAnalysisCheckpoint]) throws -> String {
        guard let previous = checkpointsByID[baseID], Set(previous.completedStepIDs) != Set(stepIDs) else { return baseID }
        let payload: [String: Any] = ["version": "reading-chunk-steps-v1", "baseID": baseID, "stepIDs": stepIDs.sorted()]
        return "chunk-" + String(try BookImporter.sha256(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])).prefix(48))
    }
    public static func isChunkComplete(_ chunk: ReadingAnalysisChunk, in project: BookProject) -> Bool {
        guard let session = project.smartReading else { return false }
        return (session.analysisCheckpoints ?? []).contains { checkpoint in
            checkpoint.id == chunk.id && checkpoint.unitIDs == chunk.unitIDs && checkpoint.configurationHash == chunk.configurationHash &&
                checkpoint.sourceRanges == chunk.sourceRanges && checkpoint.chapterID == chunk.chapterID &&
                Set(checkpoint.completedStepIDs) == Set(chunk.stepIDs) && chunk.unitIDs.allSatisfy { checkpoint.unitHashes[$0] == session.unitHashes[$0] }
        }
    }
    public static func nextAnalysisChunk(in project: BookProject, allowedUnitIDs: Set<String>? = nil) throws -> ReadingAnalysisChunk? {
        try analysisChunks(in: project, allowedUnitIDs: allowedUnitIDs).first { !isChunkComplete($0, in: project) }
    }
    static func readingDirections(in project: BookProject) -> [[String: String]] {
        (project.plan?.methodIDs ?? []).compactMap { id in
            guard let method = project.methods.first(where: { $0.id == id }), !method.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ["method": method.name, "goal": method.goal]
        }
    }
    public static func analysisCheckpointNotes(_ checkpoint: ReadingAnalysisCheckpoint, in project: BookProject) -> [String] {
        var notes: [String] = []
        let steps = project.smartReading?.selection.execution?.steps ?? []
        for (key, reason) in (checkpoint.noChangesReasons ?? [:]).sorted(by: { $0.key < $1.key }) {
            let title: String
            if key.hasPrefix("component:"), let kind = ComponentKind(rawValue: String(key.dropFirst(10))) { title = kind.title }
            else { title = steps.first(where: { "step:" + $0.id == key })?.title ?? "阅读步骤" }
            notes.append(title + "：" + reason)
        }
        if let summary = checkpoint.hostCitationSummary { notes.append(summary) }
        return notes
    }
    private static func verifyAnalysisProducts(in project: BookProject, grant: ReadingAnalysisAuthority.Grant,
                                               reasons: [String: String], submissionEvidence: [Evidence]) throws -> String? {
        guard let configuration = project.smartReading?.selection.execution else { throw ReadingError.invalid("阅读方式已改变。") }
        let steps = configuration.enabledSteps.filter { grant.chunk.stepIDs.contains($0.id) }, allowed = Set(grant.chunk.unitIDs)
        let keys = Set(steps.map { "step:" + $0.id } + configuration.componentKinds.map { "component:" + $0.rawValue })
        guard reasons.count <= 30, Set(reasons.keys).isSubset(of: keys), reasons.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 400 }) else {
            throw ReadingError.invalid("无新增说明须逐项对应当前步骤或组件，每项不超过400字。")
        }
        func literal(_ quote: String, unitID: String) -> Bool {
            analysisEvidenceAdmitted(Evidence(unitID: unitID, quote: quote), in: project)
        }
        func exact(_ values: [Evidence]) -> Bool {
            let local = values.filter { allowed.contains($0.unitID) }
            if grant.chunk.sourceRanges != nil { return local.contains { literal($0.quote, unitID: $0.unitID) } }
            return !local.isEmpty && local.allSatisfy { literal($0.quote, unitID: $0.unitID) }
        }
        let anchors = (project.readingExperience?.anchors ?? []).filter { allowed.contains($0.unitID) && literal($0.quote, unitID: $0.unitID) && analysisAnchorAdmitted($0, in: project) }
        let anchorIDs = Set(anchors.map(\.id))
        let mentioned = Set((project.readingExperience?.mentions ?? []).filter { anchorIDs.contains($0.anchorID) }.map(\.targetID))
        let currentSlices = try grant.chunk.sourceRanges.map { ranges -> [String: String] in
            let projected = try analysisSourceUnits(in: project, allowedUnitIDs: allowed, ranges: ranges)
            return Dictionary(uniqueKeysWithValues: projected.map { ($0.id, $0.text) })
        }
        let reuse = SavedKnowledgeReuse(project: project, currentUnitIDs: allowed, currentSlices: currentSlices, currentRanges: grant.chunk.sourceRanges)
        let entities = project.entities.filter { (exact($0.evidence) || mentioned.contains($0.id)) && reuse?.admits($0.evidence) == true }
        let events = project.events.filter { (exact($0.evidence) || mentioned.contains($0.id)) && reuse?.admits($0.evidence) == true }
        let relations = project.relations.filter { exact($0.evidence) && (grant.chunk.sourceRanges == nil || reuse?.admits($0.evidence) == true) }, objectIDs = Set(entities.map(\.id) + events.map(\.id))
        let hasLayers = (project.readingExperience?.layers ?? []).contains { !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.sourceAnchorIDs.isEmpty && Set($0.sourceAnchorIDs).isSubset(of: anchorIDs) }
        let hasMentions = (project.readingExperience?.mentions ?? []).contains { anchorIDs.contains($0.anchorID) && objectIDs.contains($0.targetID) }
        let hasFacts = !objectIDs.isEmpty || !relations.isEmpty
        for step in steps {
            let available = step.actionID == "facts.extract" ? hasFacts : step.actionID == "reading.enrich" ? hasLayers || hasMentions : true
            guard available || reasons["step:" + step.id] != nil else {
                throw ReadingError.invalid("“\(step.title)”尚无可核验产物或复用内容；不适用时请单独说明原因。")
            }
        }
        for kind in configuration.componentKinds {
            let available: Bool
            switch kind {
            case .cards, .knowledge: available = hasFacts
            case .map: available = entities.contains { entity in
                guard let latitude = entity.latitude, let longitude = entity.longitude else { return false }
                return latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            }
            case .timeline:
                let dated = events.contains { $0.startYear != nil || $0.endYear != nil }
                let temporalAnchors = Set((project.temporalKnowledge?.anchors ?? []).filter { allowed.contains($0.unitID) && literal($0.quote, unitID: $0.unitID) }.map(\.id)).union(anchorIDs)
                let temporal = (project.temporalKnowledge?.eventMetadata ?? []).contains { objectIDs.contains($0.eventID) && $0.extent?.start != nil && !$0.sourceAnchorIDs.isEmpty && Set($0.sourceAnchorIDs).isSubset(of: temporalAnchors) }
                available = dated || temporal
            case .mindmap: available = project.nodes.contains { objectIDs.contains($0.targetID) }
            case .relations: available = !relations.isEmpty
            default: available = false
            }
            guard available || reasons["component:" + kind.rawValue] != nil else {
                throw ReadingError.invalid("“\(kind.title)”尚无可核验内容；请保存适用内容，或说明没有可靠数据的原因，不要补造坐标和年代。")
            }
        }
        guard steps.contains(where: { $0.actionID == "citations.verify" }) else { return nil }
        let evidence = project.entities.flatMap(\.evidence) + project.events.flatMap(\.evidence) + project.relations.flatMap(\.evidence) + submissionEvidence
        let local = evidence.filter { allowed.contains($0.unitID) }
        let entityIDs = Set(project.entities.map(\.id)), targetIDs = entityIDs.union(project.events.map(\.id))
        guard local.allSatisfy({ evidence in !evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && project.units.first(where: { $0.id == evidence.unitID }).map { SourceTextLiteral.contains(evidence.quote, in: $0.text) } == true }),
              project.relations.allSatisfy({ targetIDs.contains($0.fromID) && targetIDs.contains($0.toID) }),
              project.events.allSatisfy({ Set($0.placeIDs + $0.participantIDs).isSubset(of: entityIDs) }) else {
            throw ReadingError.invalid("宿主引用核验未通过：存在不匹配引文或失效对象关联，未标记该步完成。")
        }
        return "宿主核对了本部分\(local.count)条已保存引文及对象关联；只验证来源一致性，不代表分析质量或逐段核对完成。"
    }
    /// Standard authority is granted by readChunk, not merely by a stored mode.
    public static func requireAnalysisAuthority(unitIDs: Set<String>, in project: BookProject) throws {
        if try ReadingEnrichmentAuthority.validate(in: project, unitIDs: unitIDs) { return }
        guard let grant = ReadingAnalysisAuthority.current else { try ReadingLedger.requireComplete(unitIDs: unitIDs, in: project); return }
        guard let session = project.smartReading, let configuration = session.selection.execution,
              grant.bookID == project.id, grant.sessionID == session.id, grant.sourceHash == project.sourceHash,
              Set(grant.chunk.unitIDs) == unitIDs, !unitIDs.isEmpty, unitIDs.isSubset(of: Set(session.unitIDs)) else {
            throw ReadingError.invalid("本次分析没有当前原文块的宿主权限。")
        }
        for id in unitIDs {
            guard let unit = project.units.first(where: { $0.id == id }), let expected = grant.unitHashes[id],
                  session.unitHashes[id] == expected, try BookImporter.sha256(Data(unit.text.utf8)) == expected else { throw ReadingError.invalid("当前分析块的原文已变化，未保存结果。") }
        }
        if let ranges = grant.chunk.sourceRanges {
            guard let selected = session.sourceRanges, let chapterID = grant.chunk.chapterID,
                  session.chapterIndex?.segments.contains(where: { $0.id == chapterID }) == true,
                  Set(ranges.map(\.unitID)) == unitIDs,
                  ranges.allSatisfy({ range in selected.contains { $0.unitID == range.unitID && $0.startUTF16 <= range.startUTF16 && $0.endUTF16 >= range.endUTF16 } }) else { throw ReadingError.invalid("本次章节片段已不属于冻结范围。") }
            for range in ranges { _ = try range.text(in: project) }
        }
        if configuration.precision == .close { try ReadingLedger.requireComplete(unitIDs: unitIDs, in: project) }
    }
    static func completeAnalysis(arguments: Data, in project: inout BookProject, allowedUnitIDs: Set<String>) throws -> String {
        struct Submission: Decodable { var unitIDs: [String]; var markdown: String; var evidence: [Evidence]; var completedStepIDs: [String]; var noChangesReasons: [String: String]? }
        let required: Set<String> = ["unitIDs", "markdown", "evidence", "completedStepIDs"]
        guard let raw = try JSONSerialization.jsonObject(with: arguments) as? [String: Any], required.isSubset(of: Set(raw.keys)), Set(raw.keys).isSubset(of: required.union(["noChangesReasons"])) else { throw ReadingError.invalid("分析完成参数不完整。") }
        try requireAnalysisAuthority(unitIDs: allowedUnitIDs, in: project)
        guard let grant = ReadingAnalysisAuthority.current else { throw ReadingError.invalid("标准分析必须由宿主当前原文块发起。") }
        let value = try JSONDecoder().decode(Submission.self, from: arguments)
        guard Set(value.unitIDs) == allowedUnitIDs, value.unitIDs.count == allowedUnitIDs.count,
              Set(value.completedStepIDs) == Set(grant.chunk.stepIDs), value.completedStepIDs.count == grant.chunk.stepIDs.count,
              !value.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.markdown.count <= 16_000,
              (1...128).contains(value.evidence.count), Set(value.evidence.map(\.unitID)) == allowedUnitIDs,
              value.evidence.allSatisfy({ evidence in allowedUnitIDs.contains(evidence.unitID) && !evidence.quote.isEmpty && evidence.quote.count <= 32_768 && analysisEvidenceAdmitted(evidence, in: project) }) else {
            throw ReadingError.invalid("分析范围、步骤或原文引用未通过核验；未增加已分析覆盖。")
        }
        let reasons = value.noChangesReasons ?? [:]
        let hostSummary = try verifyAnalysisProducts(in: project, grant: grant, reasons: reasons, submissionEvidence: value.evidence)
        var checkpoint = ReadingAnalysisCheckpoint(id: grant.chunk.id, unitIDs: grant.chunk.unitIDs, unitHashes: grant.unitHashes,
            configurationHash: grant.chunk.configurationHash, completedStepIDs: grant.chunk.stepIDs, markdown: value.markdown,
            evidence: value.evidence, updatedAt: Date())
        checkpoint.sourceRanges = grant.chunk.sourceRanges; checkpoint.chapterID = grant.chunk.chapterID
        checkpoint.noChangesReasons = reasons.isEmpty ? nil : reasons
        checkpoint.hostCitationSummary = hostSummary
        var records = project.smartReading?.analysisCheckpoints ?? []
        if records.contains(where: { $0.id == checkpoint.id }) { return "本部分的分析已保存，保留已有结果。" }
        guard records.count < 100_000 else { throw ReadingError.invalid("分析检查点数量达到上限。") }
        records.append(checkpoint); project.smartReading?.analysisCheckpoints = records
        project.insights.append(ReadingInsight(id: "analysis-" + checkpoint.id, unitIDs: checkpoint.unitIDs, markdown: checkpoint.markdown))
        return "已保存\(grant.chunk.title)的分析与已验证产物；未生成或补造逐段核对回执。"
    }
}

struct StandardReadingToolPlugin: ReadingToolPlugin {
    let info = ReadingPluginInfo(id: "builtin.standard-reading", name: "标准阅读分析")
    func register(in registry: inout PluginToolRegistry) throws {
        let id: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 128]
        let schema: [String: Any] = ["type": "function", "function": ["name": "reading_analysis", "description": "提交宿主本次原文块的自然阅读分析。unitIDs和completedStepIDs须与宿主清单完全一致，每个原文单元至少有一条连续精确引文；实际组件内容须先调用知识/阅读层工具保存。只增加标准分析覆盖，绝不伪造逐段复述或精读完成。", "parameters": ["type": "object", "additionalProperties": false, "properties": ["unitIDs": ["type": "array", "items": id, "minItems": 1, "maxItems": 12], "markdown": ["type": "string", "minLength": 1, "maxLength": 16000], "completedStepIDs": ["type": "array", "items": id, "maxItems": 24], "evidence": ["type": "array", "minItems": 1, "maxItems": 128, "items": ["type": "object", "additionalProperties": false, "properties": ["unitID": id, "quote": ["type": "string", "minLength": 1, "maxLength": 32768]], "required": ["unitID", "quote"]]]], "required": ["unitIDs", "markdown", "completedStepIDs", "evidence"]]]]
        var completionSchema = schema, function = schema["function"] as! [String: Any]
        var parameters = function["parameters"] as! [String: Any], properties = parameters["properties"] as! [String: Any]
        properties["noChangesReasons"] = ["type": "object", "maxProperties": 30, "additionalProperties": ["type": "string", "minLength": 1, "maxLength": 400]]
        parameters["properties"] = properties; function["parameters"] = parameters
        function["description"] = (function["description"] as! String) + " 已启用的要素/伴读步骤和所选组件须有实际内容或有来源的复用；无适用数据时在noChangesReasons逐项用step:<步骤ID>或component:<组件kind>说明，不制造坐标或年代。引用核验由宿主计算，不能传hostCitationSummary。"
        completionSchema["function"] = function
        try registry.register(RegisteredReadingTool(pluginID: info.id, schema: completionSchema, phases: [.reading]) { data, project, allowed in
            try SmartReadingRuntime.completeAnalysis(arguments: data, in: &project, allowedUnitIDs: allowed)
        })
        let scope: [String: Any] = ["type": "string", "enum": ["chapter", "book"]]
        let outline: [String: Any] = ["type": "function", "function": ["name": "analysis_outline",
            "description": "查看本轮已保存分析的目录，供章末或本轮回顾按需取用。只返回当前原文之前、本轮范围内的记录；chapter限当前章，book需已启用本轮结束步骤。目录不是全文阅读或新原文证据。",
            "parameters": ["type": "object", "additionalProperties": false, "properties": ["scope": scope,
                "offset": ["type": "integer", "minimum": 0], "limit": ["type": "integer", "minimum": 1, "maximum": 80]], "required": ["scope"]]]]
        let read: [String: Any] = ["type": "function", "function": ["name": "analysis_read",
            "description": "按analysis_outline的ID读取最多3条已保存分析，总响应不超过12KiB。派生资料只用于回顾，不开放其他原文、用户笔记或写入范围；被截断时不能声称已通读全文。",
            "parameters": ["type": "object", "additionalProperties": false, "properties": ["scope": scope,
                "checkpointIDs": ["type": "array", "items": id, "minItems": 1, "maxItems": 3]], "required": ["scope", "checkpointIDs"]]]]
        try registry.register(RegisteredReadingTool(pluginID: info.id, schema: outline, phases: [.reading], readOnly: true) { data, project, allowed in
            try ReadingAnalysisReviewTools.outline(arguments: data, in: project, allowedUnitIDs: allowed)
        })
        try registry.register(RegisteredReadingTool(pluginID: info.id, schema: read, phases: [.reading], readOnly: true) { data, project, allowed in
            try ReadingAnalysisReviewTools.read(arguments: data, in: project, allowedUnitIDs: allowed)
        })
    }
}

/// These are derived-analysis retrieval capabilities, never source-reading grants.
/// In particular their returned unit IDs cannot widen a worker's write authority.
enum ReadingAnalysisReviewTools {
    private enum Scope: String, Codable { case chapter, book }
    private struct OutlineRequest: Decodable { var scope: Scope; var offset: Int?; var limit: Int? }
    private struct ReadRequest: Decodable { var scope: Scope; var checkpointIDs: [String] }
    private struct Metadata: Codable {
        var id: String; var title: String; var unitCount: Int; var firstOrder: Int; var lastOrder: Int
        var configurationMatchesCurrent: Bool
        var firstUTF16: Int? = nil
        var lastUTF16: Int? = nil
    }
    private struct Candidate { var checkpoint: ReadingAnalysisCheckpoint; var metadata: Metadata }
    private struct OutlineResponse: Encodable {
        let kind = "derived_analysis_outline"
        var scope: Scope; var total: Int; var offset: Int; var nextOffset: Int?; var items: [Metadata]
        let notice = "这只是已保存分析的目录，尚未读取其中内容；不增加已分析覆盖或新原文权限。"
    }
    private struct ReadItem: Encodable { var metadata: Metadata; var unitIDs: [String]; var markdown: String; var truncated: Bool }
    private struct ReadResponse: Encodable {
        let kind = "derived_saved_analysis"
        var scope: Scope; var items: [ReadItem]
        let notice = "以下是先前保存的派生分析，可能仍需核对；不是本次新读原文，不能作为新引用或扩大写入范围。截断的内容不代表已通读。"
    }
    private static func decode<T: Decodable>(_ type: T.Type, arguments: Data, keys: Set<String>) throws -> T {
        guard let raw = try JSONSerialization.jsonObject(with: arguments) as? [String: Any], Set(raw.keys).isSubset(of: keys) else {
            throw ReadingError.invalid("分析检索参数含有未声明字段。")
        }
        return try JSONDecoder().decode(type, from: arguments)
    }
    private static func candidates(scope: Scope, in project: BookProject, allowedUnitIDs: Set<String>) throws -> [Candidate] {
        guard let grant = ReadingAnalysisAuthority.current, let session = project.smartReading,
              let configuration = session.selection.execution else { throw ReadingError.invalid("只有当前分析块可按已启用步骤查阅先前分析。") }
        try SmartReadingRuntime.requireAnalysisAuthority(unitIDs: allowedUnitIDs, in: project)
        let activeSteps = configuration.enabledSteps.filter { grant.chunk.stepIDs.contains($0.id) }
        let required: ReadingStepFrequency = scope == .chapter ? .chapter : .book
        guard activeSteps.contains(where: { $0.frequency == required }) else {
            throw ReadingError.invalid(scope == .chapter ? "本次没有启用章末步骤，未读取其他分析。" : "本次没有启用本轮结束步骤，未读取其他分析。")
        }
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = grant.chunk.unitIDs.compactMap { units[$0] }.sorted { $0.order < $1.order }
        guard let first = current.first, let last = current.last, current.count == grant.chunk.unitIDs.count else { throw ReadingError.invalid("当前分析块原文缺失。") }
        let scopeIDs = Set(session.unitIDs)
        let currentStart = grant.chunk.sourceRanges?.first?.startUTF16 ?? 0
        var hashes: [String: String] = [:], result: [Candidate] = []
        for checkpoint in session.analysisCheckpoints ?? [] {
            try Task.checkCancellation()
            let ids = Set(checkpoint.unitIDs)
            guard !ids.isEmpty, ids.count == checkpoint.unitIDs.count, ids.isSubset(of: scopeIDs),
                  Set(checkpoint.unitHashes.keys) == ids else { continue }
            let sources = checkpoint.unitIDs.compactMap { units[$0] }.sorted { $0.order < $1.order }
            guard sources.count == checkpoint.unitIDs.count, let start = sources.first, let end = sources.last,
                  (end.order < first.order || (end.id == first.id && (checkpoint.sourceRanges?.last?.endUTF16 ?? (end.text as NSString).length) <= currentStart)),
                  Set(checkpoint.evidence.map(\.unitID)) == ids else { continue }
            if let selected = session.sourceRanges {
                let checkpointRanges = checkpoint.sourceRanges ?? sources.filter { !$0.text.isEmpty }.map {
                    ReadingSourceRange(unitID: $0.id, startUTF16: 0, endUTF16: ($0.text as NSString).length)
                }
                guard SmartReadingRuntime.rangesContained(checkpointRanges, in: selected) else { continue }
            }
            if scope == .chapter {
                if let chapterID = grant.chunk.chapterID {
                    guard checkpoint.chapterID == chapterID else { continue }
                } else if !sources.allSatisfy({ $0.chapter == last.chapter }) { continue }
            }
            guard checkpoint.evidence.allSatisfy({ SmartReadingRuntime.evidenceAdmitted($0, ranges: checkpoint.sourceRanges, in: project) }) else { continue }
            var unchanged = true
            for unit in sources {
                guard checkpoint.unitHashes[unit.id] == session.unitHashes[unit.id] else { unchanged = false; break }
                let actual: String
                if let known = hashes[unit.id] { actual = known }
                else { actual = try BookImporter.sha256(Data(unit.text.utf8)); hashes[unit.id] = actual }
                if checkpoint.unitHashes[unit.id] != actual { unchanged = false; break }
            }
            guard unchanged, checkpoint.evidence.allSatisfy({ evidence in units[evidence.unitID].map { SourceTextLiteral.contains(evidence.quote, in: $0.text) } == true }) else { continue }
            let pages = Array(Set(sources.compactMap(\.page))).sorted()
            let title = pages.first.map { page in pages.last == page ? "第 \(page) 页" : "第 \(page)–\(pages.last ?? page) 页" } ?? String(start.chapter.prefix(100))
            var metadata = Metadata(id: checkpoint.id, title: title, unitCount: sources.count, firstOrder: start.order, lastOrder: end.order,
                configurationMatchesCurrent: checkpoint.configurationHash == grant.chunk.configurationHash)
            metadata.firstUTF16 = checkpoint.sourceRanges?.first?.startUTF16
            metadata.lastUTF16 = checkpoint.sourceRanges?.last?.endUTF16
            result.append(Candidate(checkpoint: checkpoint, metadata: metadata))
        }
        return result.sorted { left, right in
            if left.metadata.firstOrder != right.metadata.firstOrder { return left.metadata.firstOrder < right.metadata.firstOrder }
            if (left.metadata.firstUTF16 ?? 0) != (right.metadata.firstUTF16 ?? 0) { return (left.metadata.firstUTF16 ?? 0) < (right.metadata.firstUTF16 ?? 0) }
            if left.metadata.lastOrder != right.metadata.lastOrder { return left.metadata.lastOrder < right.metadata.lastOrder }
            if (left.metadata.lastUTF16 ?? Int.max) != (right.metadata.lastUTF16 ?? Int.max) { return (left.metadata.lastUTF16 ?? Int.max) < (right.metadata.lastUTF16 ?? Int.max) }
            return left.metadata.id < right.metadata.id
        }
    }
    static func outline(arguments: Data, in project: BookProject, allowedUnitIDs: Set<String>) throws -> String {
        let request = try decode(OutlineRequest.self, arguments: arguments, keys: ["scope", "offset", "limit"])
        let offset = request.offset ?? 0, limit = request.limit ?? 40
        guard (0...100_000).contains(offset), (1...80).contains(limit) else { throw ReadingError.invalid("分析目录页码或数量无效，每次最多80条。") }
        let records = try candidates(scope: request.scope, in: project, allowedUnitIDs: allowedUnitIDs)
        let rows = records.dropFirst(offset).prefix(limit).map(\.metadata)
        let next = offset + rows.count < records.count ? offset + rows.count : nil
        return String(decoding: try JSONEncoder().encode(OutlineResponse(scope: request.scope, total: records.count, offset: offset, nextOffset: next, items: rows)), as: UTF8.self)
    }
    static func read(arguments: Data, in project: BookProject, allowedUnitIDs: Set<String>) throws -> String {
        let request = try decode(ReadRequest.self, arguments: arguments, keys: ["scope", "checkpointIDs"])
        guard (1...3).contains(request.checkpointIDs.count), Set(request.checkpointIDs).count == request.checkpointIDs.count else { throw ReadingError.invalid("每次读取1至3条不同的已保存分析。") }
        let available = Dictionary(try candidates(scope: request.scope, in: project, allowedUnitIDs: allowedUnitIDs).map { ($0.metadata.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [ReadItem] = []
        for id in request.checkpointIDs {
            guard let record = available[id] else { throw ReadingError.invalid("所选分析不在当前获准回顾范围，未读取内容。") }
            items.append(ReadItem(metadata: record.metadata, unitIDs: record.checkpoint.unitIDs, markdown: record.checkpoint.markdown, truncated: false))
        }
        let encoder = JSONEncoder()
        var data = try encoder.encode(ReadResponse(scope: request.scope, items: items))
        while data.count > 12 * 1024 {
            guard let index = items.indices.max(by: { items[$0].markdown.utf8.count < items[$1].markdown.utf8.count }), !items[index].markdown.isEmpty else {
                throw ReadingError.invalid("分析元信息超出12KiB限制，请减少读取条数。")
            }
            items[index].markdown = String(items[index].markdown.prefix(items[index].markdown.count / 2)); items[index].truncated = true
            data = try encoder.encode(ReadResponse(scope: request.scope, items: items))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
