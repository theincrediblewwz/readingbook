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
    private let schemaData: Data
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
        schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        guard schemaData.count <= 262_144 else { throw ReadingError.invalid("插件工具声明过大。") }
        handler = execute
    }
    public var schema: [String: Any] { (try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any]) ?? [:] }
    func execute(_ arguments: Data, project: inout BookProject, allowed: Set<String>) throws -> String { try handler(arguments, &project, allowed) }
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
        if tool.requiresReceipts { try ReadingLedger.requireComplete(unitIDs: allowedUnitIDs, in: project) }
        var candidate = project
        let result = try tool.execute(arguments, project: &candidate, allowed: allowedUnitIDs)
        guard candidate.id == project.id, candidate.sourceHash == project.sourceHash, candidate.originalName == project.originalName,
              candidate.units == project.units, candidate.documents == project.documents else {
            throw ReadingError.invalid("插件不能修改原书或用户Markdown文档。")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(candidate.readerAnnotations) == encoder.encode(project.readerAnnotations),
              try encoder.encode(candidate.chats) == encoder.encode(project.chats), candidate.bookmarks == project.bookmarks else {
            throw ReadingError.invalid("插件不能修改用户批注、会话或书签。")
        }
        let hostReadingTool = tool.pluginID == "builtin.reading"
        let finish = hostReadingTool && name == "reading_finish"
        let receipt = hostReadingTool && name == "read_receipt"
        let step = hostReadingTool && name == "workflow_step_complete"
        if !hostReadingTool {
            guard try encoder.encode(candidate.audit) == encoder.encode(project.audit), candidate.appliedOperationIDs == project.appliedOperationIDs else { throw ReadingError.invalid("插件不能伪造宿主操作历史。") }
        }
        if !finish {
            guard try encoder.encode(candidate.coverage) == encoder.encode(project.coverage),
                  candidate.insights.count == project.insights.count,
                  try encoder.encode(candidate.insights) == encoder.encode(project.insights),
                  try encoder.encode(candidate.syntheses) == encoder.encode(project.syntheses), candidate.lastUnitID == project.lastUnitID else {
                throw ReadingError.invalid("插件不能直接修改阅读覆盖或伪造综合结果；请通过宿主完成门禁。")
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
        candidate.audit.append(ToolAudit(name: name, summary: result))
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "tool": name, "pluginID": tool.pluginID, "summary": result], options: [.sortedKeys])
        guard let response = String(data: data, encoding: .utf8) else { throw ReadingError.invalid("无法编码插件结果。") }
        project = candidate
        return response
    }
}
