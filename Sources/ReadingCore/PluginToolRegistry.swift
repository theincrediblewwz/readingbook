import Foundation

/// Phases are host boundaries, not prompts that a plugin can opt out of.
public enum PluginToolPhase: String, CaseIterable, Hashable, Sendable { case planning, receipt, reading, workflow }

public struct ReadingPluginInfo: Hashable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Native extensions and built-ins use the same registration contract.
/// Declaration packs configure these capabilities; they never execute arbitrary code.
public protocol ReadingToolPlugin {
    var info: ReadingPluginInfo { get }
    func register(in registry: inout PluginToolRegistry) throws
}

public struct RegisteredReadingTool: Sendable {
    fileprivate let registrationID = UUID()
    public let name: String
    public let pluginID: String
    public let phases: Set<PluginToolPhase>
    public let requiresReceipts: Bool
    public let readOnly: Bool
    private let schemaSnapshot: ReadingToolSchemaSnapshot
    private let handler: @Sendable (Data, inout BookProject, Set<String>) throws -> String

    public init(pluginID: String, schema: [String: Any], phases: Set<PluginToolPhase>, requiresReceipts: Bool = false, readOnly: Bool = false,
                execute: @escaping @Sendable (Data, inout BookProject, Set<String>) throws -> String) throws {
        guard let function = schema["function"] as? [String: Any], let name = function["name"] as? String,
              name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
              !pluginID.isEmpty, !phases.isEmpty, function["parameters"] is [String: Any] else {
            throw ReadingError.invalid("插件工具必须有合法名称、参数结构、归属和可用阶段。")
        }
        self.name = name; self.pluginID = pluginID; self.phases = phases
        self.requiresReceipts = requiresReceipts; self.readOnly = readOnly
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        guard schemaData.count <= 262_144 else { throw ReadingError.invalid("插件工具声明过大。") }
        schemaSnapshot = try ReadingToolSchemaSnapshot(data: schemaData)
        handler = execute
    }
    public var schema: [String: Any] { schemaSnapshot.dictionary }
    func execute(_ arguments: Data, project: inout BookProject, allowed: Set<String>) throws -> String { try handler(arguments, &project, allowed) }
}

/// This wrapper alone owns a default, immutable JSON parse. Its only initializer
/// accepts encoded bytes, so caller-owned NSMutable containers cannot enter it.
/// Foundation JSON scalars/containers are immutable with options []; the returned
/// Swift Dictionary has copy-on-write value semantics. No mutable references or
/// setters are exposed. Any erases these guarantees from compiler checking.
private struct ReadingToolSchemaSnapshot: @unchecked Sendable {
    private let value: [String: Any]
    init(data: Data) throws {
        guard let dictionary = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw ReadingError.invalid("插件工具声明必须是JSON对象。")
        }
        value = dictionary
    }
    var dictionary: [String: Any] { value }
}

/// A value registry belongs to an AIReader run. Registration is atomic; no global
/// mutable singleton means another book cannot change a running session's tools.
public struct PluginToolRegistry: Sendable {
    private var storage: [String: RegisteredReadingTool] = [:]
    private var order: [String] = []
    public private(set) var plugins: [ReadingPluginInfo] = []
    public init() {}
    public mutating func install(_ plugin: any ReadingToolPlugin) throws {
        guard !plugins.contains(where: { $0.id == plugin.info.id }) else { throw ReadingError.invalid("原生插件已注册：\(plugin.info.id)") }
        var candidate = self
        try plugin.register(in: &candidate)
        guard candidate.order.count > order.count, Array(candidate.order.prefix(order.count)) == order,
              candidate.plugins == plugins,
              order.allSatisfy({ storage[$0]?.registrationID == candidate.storage[$0]?.registrationID }),
              candidate.order.dropFirst(order.count).allSatisfy({ candidate.storage[$0]?.pluginID == plugin.info.id }) else {
            throw ReadingError.invalid("插件必须注册属于自己的工具。")
        }
        candidate.plugins.append(plugin.info); self = candidate
    }
    public mutating func register(_ tool: RegisteredReadingTool) throws {
        guard storage[tool.name] == nil else { throw ReadingError.invalid("插件工具重名，保留原注册：\(tool.name)") }
        storage[tool.name] = tool; order.append(tool.name)
    }
    public mutating func remove(pluginID: String) {
        let names = Set(order.filter { storage[$0]?.pluginID == pluginID })
        for name in names { storage.removeValue(forKey: name) }
        order.removeAll { names.contains($0) }; plugins.removeAll { $0.id == pluginID }
    }
    public func definition(named name: String) -> RegisteredReadingTool? { storage[name] }
    public func names(for phase: PluginToolPhase) -> Set<String> { Set(order.filter { storage[$0]?.phases.contains(phase) == true }) }
    public func schemas(for phase: PluginToolPhase? = nil) -> [[String: Any]] {
        order.compactMap { name in guard let tool = storage[name], phase == nil || tool.phases.contains(phase!) else { return nil }; return tool.schema }
    }

    /// Validated copy -> handler -> invariants -> audit -> publish. A failing handler
    /// cannot half-write the project or advance coverage.
    public func apply(name: String, arguments: Data, to project: inout BookProject, allowedUnitIDs: Set<String>, phase: PluginToolPhase? = nil) throws -> String {
        guard arguments.count <= 262_144,
              (try? JSONSerialization.jsonObject(with: arguments)) is [String: Any] else { throw ReadingError.invalid("工具参数必须是小于256 KiB的JSON对象。") }
        guard let tool = storage[name], phase == nil || tool.phases.contains(phase!) else { throw ReadingError.invalid("当前阶段没有注册插件工具：\(name)") }
        if tool.requiresReceipts { try SmartReadingRuntime.requireAnalysisAuthority(unitIDs: allowedUnitIDs, in: project) }
        var candidate = project
        let result = try tool.execute(arguments, project: &candidate, allowed: allowedUnitIDs)
        // A successful read-only call already has to preserve the entire encoded
        // project. Prove that once before the overlapping field checks. A failed
        // encode or any difference keeps the original validation/error path.
        // Standard completion has an additional host-authority gate even for an
        // unchanged project, so it must always use the full path below.
        if tool.readOnly, !(tool.pluginID == "builtin.standard-reading" && name == "reading_analysis" && phase == .reading) {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            if let original = try? encoder.encode(project), let unchanged = try? encoder.encode(candidate), original == unchanged {
                try ManualTrashRuntime.validateReservedRecords(in: candidate)
                return result
            }
        }
        if name == "views_configure", ReadingAnalysisAuthority.current != nil {
            guard project.views.allSatisfy({ old in candidate.views.contains(old) }),
                  candidate.views.filter({ view in !project.views.contains(where: { $0.id == view.id }) }).allSatisfy({ $0.configuration?["presentation"] == "inline" && $0.composition != nil }) else {
                throw ReadingError.invalid("后台阅读只新增独立内嵌组件，已有视图和布局保留。")
            }
        }
        guard candidate.id == project.id, candidate.sourceHash == project.sourceHash, candidate.originalName == project.originalName,
              candidate.units == project.units,
              zip(candidate.units, project.units).allSatisfy({ $0.text.utf8.elementsEqual($1.text.utf8) }),
              candidate.documents == project.documents else {
            throw ReadingError.invalid("插件不能修改原书或用户Markdown文档。")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(candidate.generatedOutline) == encoder.encode(project.generatedOutline),
              try encoder.encode(candidate.originalBookOutline) == encoder.encode(project.originalBookOutline) else {
            throw ReadingError.invalid("插件不能改写宿主目录；请由读者从目录界面生成。")
        }
        guard try encoder.encode(candidate.bookSchemes) == encoder.encode(project.bookSchemes) else {
            throw ReadingError.invalid("插件不能直接改写书本方案的预览、应用和撤销记录；请由用户在宿主界面确认。")
        }
        let standardCompletion = tool.pluginID == "builtin.standard-reading" && name == "reading_analysis" && phase == .reading
        var candidateSession = candidate.smartReading, previousSession = project.smartReading
        if standardCompletion {
            try SmartReadingRuntime.requireAnalysisAuthority(unitIDs: allowedUnitIDs, in: project)
            let old = previousSession?.analysisCheckpoints ?? [], next = candidateSession?.analysisCheckpoints ?? []
            guard next.count == old.count || next.count == old.count + 1, Array(next.prefix(old.count)) == old else { throw ReadingError.invalid("标准分析只能追加当前原文块的检查点。") }
            candidateSession?.analysisCheckpoints = nil; previousSession?.analysisCheckpoints = nil
        }
        guard try encoder.encode(candidateSession) == encoder.encode(previousSession) else {
            throw ReadingError.invalid("插件不能改写宿主冻结的智能阅读范围、确认状态或进度任务。")
        }
        guard try encoder.encode(candidate.manualTrash) == encoder.encode(project.manualTrash) else {
            throw ReadingError.invalid("插件不能修改用户回收站或代替用户恢复已删除内容。")
        }
        try ManualTrashRuntime.validateReservedRecords(in: candidate)
        if candidate.mathVerifications != project.mathVerifications {
            guard tool.pluginID == "builtin.math-verification", name == "math_verify", tool.requiresReceipts,
                  phase == nil || phase == .reading || phase == .workflow, !allowedUnitIDs.isEmpty else {
                throw ReadingError.invalid("数学核查记录只能由已通过逐段回执的宿主数学工具追加。")
            }
            try MathVerificationTools.validateTransition(from: project.mathVerifications, to: candidate.mathVerifications,
                                                          allowedUnitIDs: allowedUnitIDs, in: candidate)
        }
        guard try encoder.encode(candidate.readerAnnotations) == encoder.encode(project.readerAnnotations),
              try encoder.encode(candidate.chats) == encoder.encode(project.chats), candidate.bookmarks == project.bookmarks else {
            throw ReadingError.invalid("插件不能修改用户批注、会话或书签。")
        }
        if candidate.readingExperience != project.readingExperience {
            guard tool.requiresReceipts, phase == nil || phase == .reading || phase == .workflow,
                  !allowedUnitIDs.isEmpty else { throw ReadingError.invalid("新增阅读层必须通过当前原文逐段回执门禁，不能在预读或回执阶段写入。") }
            try ReadingExperienceTools.validateTransition(from: project.readingExperience, to: candidate.readingExperience,
                                                          allowedUnitIDs: allowedUnitIDs, in: candidate)
        }
        if candidate.temporalKnowledge != project.temporalKnowledge {
            guard tool.pluginID == "builtin.temporal-knowledge", name == "knowledge_temporal", tool.requiresReceipts,
                  phase == nil || phase == .reading || phase == .workflow, !allowedUnitIDs.isEmpty else {
                throw ReadingError.invalid("时态知识只能通过宿主当前逐段回执与来源门禁追加，不能从预读、只读查询或任意插件改写。")
            }
            try TemporalKnowledgeToolPlugin.validateTransition(from: project.temporalKnowledge, to: candidate.temporalKnowledge,
                                                               allowedUnitIDs: allowedUnitIDs, in: candidate)
        }
        guard try encoder.encode(candidate.controlledChanges) == encoder.encode(project.controlledChanges), candidate.graphGroups == project.graphGroups else {
            throw ReadingError.invalid("阅读插件不能伪造受控变更凭据或修改用户画布分组。")
        }
        let hostReadingTool = tool.pluginID == "builtin.reading"
        let insightsUnchanged = try encoder.encode(candidate.insights) == encoder.encode(project.insights)
        let finish = hostReadingTool && name == "reading_finish"
        let receipt = hostReadingTool && name == "read_receipt"
        let step = hostReadingTool && name == "workflow_step_complete"
        if !hostReadingTool {
            guard try encoder.encode(candidate.audit) == encoder.encode(project.audit), candidate.appliedOperationIDs == project.appliedOperationIDs else { throw ReadingError.invalid("插件不能伪造宿主操作历史。") }
        }
        if !finish {
            guard try encoder.encode(candidate.coverage) == encoder.encode(project.coverage),
                  (standardCompletion || insightsUnchanged),
                  try encoder.encode(candidate.syntheses) == encoder.encode(project.syntheses), candidate.lastUnitID == project.lastUnitID else {
                throw ReadingError.invalid("插件不能直接修改阅读覆盖或伪造综合结果；请通过宿主完成门禁。")
            }
            if standardCompletion {
                guard candidate.insights.count >= project.insights.count, candidate.insights.count <= project.insights.count + 1,
                      try encoder.encode(Array(candidate.insights.prefix(project.insights.count))) == encoder.encode(project.insights) else { throw ReadingError.invalid("标准分析不能改写已有分析。") }
            }
        }
        if !receipt {
            guard try encoder.encode(candidate.paragraphReceipts) == encoder.encode(project.paragraphReceipts) else { throw ReadingError.invalid("插件不能改写逐段回执。") }
            // Finishing retires the active host batch, but never changes the
            // admitted receipts or replaces it with a fabricated batch.
            guard candidate.receiptBatch == project.receiptBatch || (finish && candidate.receiptBatch == nil) else { throw ReadingError.invalid("插件不能改写当前回执批次。") }
        }
        if !step && !finish {
            guard try encoder.encode(candidate.readingStepResults) == encoder.encode(project.readingStepResults),
                  try encoder.encode(candidate.workflowRuns) == encoder.encode(project.workflowRuns) else { throw ReadingError.invalid("插件不能直接改写流程检查点。") }
        }
        if tool.readOnly {
            guard try encoder.encode(candidate) == encoder.encode(project) else { throw ReadingError.invalid("只读插件工具尝试修改项目。") }
            return result
        }
        try AnalysisSourceGuard.validate(arguments: arguments, before: project, after: candidate)
        candidate.audit.append(ToolAudit(name: name, summary: result))
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "tool": name, "pluginID": tool.pluginID, "summary": result], options: [.sortedKeys])
        guard let response = String(data: data, encoding: .utf8) else { throw ReadingError.invalid("无法编码插件结果。") }
        project = candidate
        return response
    }
}
