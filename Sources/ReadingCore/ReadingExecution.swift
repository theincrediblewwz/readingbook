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
        guard let session = project.smartReading, let configuration = session.selection.execution else { return [] }
        try configuration.validate()
        let allowed = allowedUnitIDs ?? Set(session.unitIDs)
        guard allowed.isSubset(of: Set(session.unitIDs)) else { throw ReadingError.invalid("分析块超出本轮范围。") }
        let units = try selectedUnits(in: project, allowedUnitIDs: allowed).filter { !ReadingLedger.isDeferred(unitID: $0.id, in: project) && !isConfirmedBlank($0, in: project) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let planData = try encoder.encode(project.plan)
        let fingerprint = try BookImporter.sha256(Data(try configuration.fingerprint().utf8) + planData)
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
            let id = "chunk-" + String(try BookImporter.sha256(Data((project.sourceHash + "|" + fingerprint + "|" + sourceKey).utf8)).prefix(48))
            let chapters = Set(group.map(\.chapter))
            let isChapterEnd = groups.dropFirst(index + 1).first.map { !chapters.contains($0.first?.chapter ?? "") } ?? true
            let stepIDs = configuration.enabledSteps.filter { $0.frequency == .chunk || ($0.frequency == .chapter && isChapterEnd) || ($0.frequency == .book && index == groups.count - 1) }.map(\.id)
            let pages = Array(Set(group.compactMap(\.page))).sorted()
            let title = pages.first.map { start in pages.last == start ? "第 \(start) 页" : "第 \(start)–\(pages.last ?? start) 页" } ?? group.first?.chapter ?? "本部分"
            return ReadingAnalysisChunk(id: id, title: title, unitIDs: ids, configurationHash: fingerprint, stepIDs: stepIDs)
        }
    }
    public static func isChunkComplete(_ chunk: ReadingAnalysisChunk, in project: BookProject) -> Bool {
        guard let session = project.smartReading else { return false }
        return (session.analysisCheckpoints ?? []).contains { checkpoint in
            checkpoint.id == chunk.id && checkpoint.unitIDs == chunk.unitIDs && checkpoint.configurationHash == chunk.configurationHash &&
                Set(checkpoint.completedStepIDs) == Set(chunk.stepIDs) && chunk.unitIDs.allSatisfy { checkpoint.unitHashes[$0] == session.unitHashes[$0] }
        }
    }
    public static func nextAnalysisChunk(in project: BookProject, allowedUnitIDs: Set<String>? = nil) throws -> ReadingAnalysisChunk? {
        try analysisChunks(in: project, allowedUnitIDs: allowedUnitIDs).first { !isChunkComplete($0, in: project) }
    }
    /// Standard authority is granted by readChunk, not merely by a stored mode.
    public static func requireAnalysisAuthority(unitIDs: Set<String>, in project: BookProject) throws {
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
        if configuration.precision == .close { try ReadingLedger.requireComplete(unitIDs: unitIDs, in: project) }
    }
    static func completeAnalysis(arguments: Data, in project: inout BookProject, allowedUnitIDs: Set<String>) throws -> String {
        struct Submission: Decodable { var unitIDs: [String]; var markdown: String; var evidence: [Evidence]; var completedStepIDs: [String] }
        guard let raw = try JSONSerialization.jsonObject(with: arguments) as? [String: Any], Set(raw.keys) == Set(["unitIDs", "markdown", "evidence", "completedStepIDs"]) else { throw ReadingError.invalid("分析完成参数不完整。") }
        try requireAnalysisAuthority(unitIDs: allowedUnitIDs, in: project)
        guard let grant = ReadingAnalysisAuthority.current else { throw ReadingError.invalid("标准分析必须由宿主当前原文块发起。") }
        let value = try JSONDecoder().decode(Submission.self, from: arguments)
        guard Set(value.unitIDs) == allowedUnitIDs, value.unitIDs.count == allowedUnitIDs.count,
              Set(value.completedStepIDs) == Set(grant.chunk.stepIDs), value.completedStepIDs.count == grant.chunk.stepIDs.count,
              !value.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.markdown.count <= 16_000,
              (1...128).contains(value.evidence.count), Set(value.evidence.map(\.unitID)) == allowedUnitIDs,
              value.evidence.allSatisfy({ evidence in allowedUnitIDs.contains(evidence.unitID) && !evidence.quote.isEmpty && evidence.quote.count <= 32_768 && project.units.first(where: { $0.id == evidence.unitID })?.text.contains(evidence.quote) == true }) else {
            throw ReadingError.invalid("分析范围、步骤或原文引用未通过核验；未增加已分析覆盖。")
        }
        let checkpoint = ReadingAnalysisCheckpoint(id: grant.chunk.id, unitIDs: grant.chunk.unitIDs, unitHashes: grant.unitHashes,
            configurationHash: grant.chunk.configurationHash, completedStepIDs: grant.chunk.stepIDs, markdown: value.markdown,
            evidence: value.evidence, updatedAt: Date())
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
        try registry.register(RegisteredReadingTool(pluginID: info.id, schema: schema, phases: [.reading]) { data, project, allowed in
            try SmartReadingRuntime.completeAnalysis(arguments: data, in: &project, allowedUnitIDs: allowed)
        })
    }
}
