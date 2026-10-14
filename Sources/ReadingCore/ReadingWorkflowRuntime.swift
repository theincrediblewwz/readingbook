import Foundation

/// A declaration binds one human-readable method step to a registered host action.
/// Configuration is data; it never contains executable code or extra capabilities.
public struct ReadingStepExecution: Codable, Hashable, Sendable {
    public var stepIndex: Int
    public var actionID: String
    public var configuration: [String: String]
    public var maxAttempts: Int
    public init(stepIndex: Int, actionID: String, configuration: [String: String] = [:], maxAttempts: Int = 3) {
        self.stepIndex = stepIndex; self.actionID = actionID
        self.configuration = configuration; self.maxAttempts = maxAttempts
    }
    private enum CodingKeys: String, CodingKey { case stepIndex, actionID, configuration, maxAttempts }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stepIndex = try container.decode(Int.self, forKey: .stepIndex)
        actionID = try container.decode(String.self, forKey: .actionID)
        configuration = try container.decodeIfPresent([String: String].self, forKey: .configuration) ?? [:]
        maxAttempts = try container.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? 3
    }
}

public struct ReadingWorkflowInput: Codable, Hashable, Sendable {
    public var unitID: String
    public var unitHash: String
    public var paragraphIDs: [String]
    public var previousStepIDs: [String]
    public var instruction: String
    public var configuration: [String: String]
}

public struct ReadingWorkflowOutput: Codable, Hashable, Sendable {
    public var result: String
    public var paragraphIDs: [String]
    public var evidence: [Evidence]
    public var issues: [String]
    public var noChangesReason: String? = nil
    public init(result: String, paragraphIDs: [String], evidence: [Evidence], issues: [String] = [], noChangesReason: String? = nil) {
        self.result = result; self.paragraphIDs = paragraphIDs; self.evidence = evidence; self.issues = issues; self.noChangesReason = noChangesReason
    }
}

public enum ReadingWorkflowStatus: String, Codable, Sendable { case running, completed, failed }

/// Budget exhaustion is resumable interruption, not a failed model attempt.
public struct ReadingWorkflowBudgetPause: LocalizedError, Sendable {
    public var message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ReadingWorkflowStepRun: Codable, Identifiable, Hashable, Sendable {
    public var id: String { stepID }
    public var stepID: String
    public var unitID: String
    public var unitHash: String
    public var methodID: String
    public var methodHash: String
    public var stepIndex: Int
    public var actionID: String
    public var input: ReadingWorkflowInput
    public var inputHash: String
    public var status: ReadingWorkflowStatus
    public var attempts: Int
    public var toolNames: [String]
    /// Host-observed successful tools which changed shared knowledge collections.
    public var knowledgeWriteTools: [String]? = nil
    public var output: ReadingWorkflowOutput?
    public var error: String?
    public var updatedAt: Date
}

public struct ReadingWorkflowActionDescriptor: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var allowedTools: [String]
    public init(id: String, title: String, detail: String, allowedTools: [String] = []) {
        self.id = id; self.title = title; self.detail = detail; self.allowedTools = allowedTools
    }
}

public struct ReadingWorkflowTask: Sendable {
    public var requirement: ReadingStepRequirement
    public var execution: ReadingStepExecution
    public var action: ReadingWorkflowActionDescriptor
    public var input: ReadingWorkflowInput
}

public struct ReadingWorkflowServices: Sendable {
    /// Only AI actions invoke this service. The host supplies its bounded model/tool loop.
    public var model: @Sendable (ReadingWorkflowTask, BookProject) async throws -> BookProject
    public init(model: @escaping @Sendable (ReadingWorkflowTask, BookProject) async throws -> BookProject) { self.model = model }
}

public struct ReadingWorkflowAction: Sendable {
    public var descriptor: ReadingWorkflowActionDescriptor
    public var execute: @Sendable (ReadingWorkflowTask, BookProject, ReadingWorkflowServices) async throws -> BookProject
    public init(descriptor: ReadingWorkflowActionDescriptor,
                execute: @escaping @Sendable (ReadingWorkflowTask, BookProject, ReadingWorkflowServices) async throws -> BookProject) {
        self.descriptor = descriptor; self.execute = execute
    }
}

/// Actions are executable handlers. JSON methods select registered IDs, never supply handlers.
public struct ReadingWorkflowActionRegistry: Sendable {
    private var actions: [String: ReadingWorkflowAction] = [:]
    public init() {}
    public mutating func register(_ action: ReadingWorkflowAction) throws {
        let descriptor = action.descriptor
        guard descriptor.id.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil, actions[descriptor.id] == nil,
              !descriptor.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, descriptor.title.count <= 400, descriptor.detail.count <= 4000,
              descriptor.allowedTools.count <= 64, Set(descriptor.allowedTools).count == descriptor.allowedTools.count,
              descriptor.allowedTools.allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil }) else { throw ReadingError.invalid("流程动作标识、说明或工具声明不合法，或注册重复。") }
        actions[action.descriptor.id] = action
    }
    public var descriptors: [ReadingWorkflowActionDescriptor] { actions.values.map(\.descriptor).sorted { $0.id < $1.id } }
    public func action(id: String) -> ReadingWorkflowAction? { actions[id] }

    public static var builtIn: ReadingWorkflowActionRegistry {
        var registry = ReadingWorkflowActionRegistry()
        let common = ["knowledge_search", "methods_define", "reading_plan", "workflow_step_complete"]
        let knowledge = ["types_define", "cards_upsert", "events_upsert", "relations_link", "views_configure", "map_attach", "timeline_attach"]
        let descriptors = [
            ReadingWorkflowActionDescriptor(id: "ai.analyze", title: "原文分析", detail: "依据当前原文执行这一条阅读步骤，提交可核对的分析与引用；需要时实际调用知识工具保存适用对象。旧自然语言方法通过此受控动作执行。", allowedTools: common + knowledge),
            ReadingWorkflowActionDescriptor(id: "facts.extract", title: "知识抽取", detail: "实际调用知识工具创建或补充适用对象和关联，再提交抽取结果；没有适用对象须明确解释，不强造人物或事件。", allowedTools: common + knowledge),
            ReadingWorkflowActionDescriptor(id: "reading.review", title: "复盘核对", detail: "对照已执行步骤与原文核对条件、矛盾、遗漏和不确定处，提交复盘结果；不能以先前分析代替原文。", allowedTools: common)
        ]
        for descriptor in descriptors {
            registry.actions[descriptor.id] = ReadingWorkflowAction(descriptor: descriptor) { task, project, services in
                try await services.model(task, project)
            }
        }
        let verification = ReadingWorkflowActionDescriptor(id: "citations.verify", title: "引用核验", detail: "由宿主实际核对当前单元已保存对象及步骤的引文和关联；检查来源一致性，不证明内容语义正确。", allowedTools: [])
        registry.actions[verification.id] = ReadingWorkflowAction(descriptor: verification) { task, project, _ in
            var candidate = project
            let output = try ReadingWorkflowRuntime.verifyCitations(task: task, in: project)
            try ReadingWorkflowRuntime.complete(stepID: task.requirement.stepID, output: output, to: &candidate, allowedUnitIDs: [task.requirement.unitID])
            return candidate
        }
        return registry
    }
}

public enum ReadingWorkflowRuntime {
    public static var actions: [ReadingWorkflowActionDescriptor] { ReadingWorkflowActionRegistry.builtIn.descriptors }

    public static func validate(method: ReadingMethod, registry: ReadingWorkflowActionRegistry? = .builtIn) throws {
        guard let executions = method.executions else { return }
        guard executions.count == method.steps.count, Set(executions.map(\.stepIndex)) == Set(method.steps.indices) else {
            throw ReadingError.invalid("可执行读书法须为每条步骤提供唯一动作绑定。")
        }
        for execution in executions {
            guard execution.actionID.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil,
                  registry.map({ $0.action(id: execution.actionID) != nil }) ?? true, (1...8).contains(execution.maxAttempts),
                  execution.configuration.count <= 16,
                  execution.configuration.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 128 && $0.value.count <= 4000 }) else {
                throw ReadingError.invalid("读书法引用了未注册动作，或动作配置、重试上限不合法。")
            }
        }
    }

    public static func execution(for requirement: ReadingStepRequirement, in project: BookProject,
                                 registry: ReadingWorkflowActionRegistry? = .builtIn) throws -> ReadingStepExecution {
        guard let method = project.methods.first(where: { $0.id == requirement.methodID }) else { throw ReadingError.invalid("流程方法不存在。") }
        try validate(method: method, registry: registry)
        return method.executions?.first(where: { $0.stepIndex == requirement.stepIndex }) ?? ReadingStepExecution(stepIndex: requirement.stepIndex, actionID: "ai.analyze")
    }

    public static func nextTask(for unit: SourceUnit, in project: BookProject,
                                registry: ReadingWorkflowActionRegistry = .builtIn) throws -> ReadingWorkflowTask? {
        try ReadingLedger.requireComplete(unitIDs: [unit.id], in: project)
        let requirements = try ReadingLedger.stepRequirements(for: unit, in: project, registry: registry)
        let records = project.workflowRuns ?? []
        let completed = Set(records.filter { $0.unitID == unit.id && $0.status == .completed }.map(\.stepID))
        guard let requirement = requirements.first(where: { !completed.contains($0.stepID) }) else { return nil }
        let binding = try execution(for: requirement, in: project, registry: registry)
        guard let action = registry.action(id: binding.actionID) else { throw ReadingError.invalid("流程动作未注册：\(binding.actionID)") }
        let input = ReadingWorkflowInput(unitID: unit.id, unitHash: try hash(unit.text),
                                         paragraphIDs: try ReadingLedger.receipts(for: unit, in: project).map(\.paragraphID),
                                         previousStepIDs: requirements.prefix(while: { $0.stepID != requirement.stepID }).map(\.stepID),
                                         instruction: requirement.stepText, configuration: binding.configuration)
        return ReadingWorkflowTask(requirement: requirement, execution: binding, action: action.descriptor, input: input)
    }

    /// One action per call. A failed action rolls back its writes and returns only
    /// its failure checkpoint; the caller saves it and pauses before a user retry.
    public static func perform(_ task: ReadingWorkflowTask, in project: BookProject, services: ReadingWorkflowServices,
                               registry: ReadingWorkflowActionRegistry = .builtIn) async throws -> BookProject {
        try Task.checkCancellation()
        guard let unit = project.units.first(where: { $0.id == task.requirement.unitID }),
              let expected = try nextTask(for: unit, in: project, registry: registry),
              expected.requirement == task.requirement, expected.input == task.input, expected.execution == task.execution,
              let action = registry.action(id: task.action.id), action.descriptor == task.action else { throw ReadingError.invalid("流程执行输入已过期或动作不存在。") }
        let old = (project.workflowRuns ?? []).first { $0.stepID == task.requirement.stepID }
        guard (old?.attempts ?? 0) < task.execution.maxAttempts else { throw ReadingError.invalid("本步骤已达到 \(task.execution.maxAttempts) 次重试上限。请在流程检查点明确重置重试后再继续。") }
        var staged = project
        let requirement = task.requirement
        let run = ReadingWorkflowStepRun(stepID: requirement.stepID, unitID: requirement.unitID, unitHash: task.input.unitHash,
                                         methodID: requirement.methodID, methodHash: requirement.methodHash, stepIndex: requirement.stepIndex,
                                         actionID: task.execution.actionID, input: task.input, inputHash: try encodedHash(task.input),
                                         status: .running, attempts: (old?.attempts ?? 0) + 1, toolNames: [], output: nil, error: nil, updatedAt: Date())
        set(run, in: &staged)
        do {
            let result = try await action.execute(task, staged, services)
            try Task.checkCancellation()
            guard let saved = (result.workflowRuns ?? []).first(where: { $0.stepID == run.stepID }), saved.status == .completed,
                  saved.inputHash == run.inputHash, saved.attempts == run.attempts else { throw ReadingError.invalid("流程动作没有提交已校验的步骤输出。") }
            try validateStoredRecords(in: result, registry: registry)
            return result
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            var failed = run
            failed.status = .failed; failed.error = String(error.localizedDescription.prefix(1600)); failed.updatedAt = Date()
            if error is ReadingWorkflowBudgetPause {
                failed.attempts = old?.attempts ?? 0
                failed.error = "预算暂停（不计入失败重试次数）：" + String(error.localizedDescription.prefix(1500))
            }
            var result = project
            set(failed, in: &result)
            result.audit.append(ToolAudit(name: "workflow_step_failed", summary: "\(run.actionID) · \(run.stepID)：\(failed.error ?? "执行失败")"))
            return result
        }
    }

    public static func failureMessage(in project: BookProject, unitID: String? = nil) -> String? {
        let activeIDs = Set(project.units.filter { unitID == nil || $0.id == unitID }.flatMap { (try? ReadingLedger.stepRequirements(for: $0, in: project).map(\.stepID)) ?? [] })
        return (project.workflowRuns ?? []).last { $0.status == .failed && activeIDs.contains($0.stepID) }.map {
            "阅读步骤执行失败，检查点已保存（\($0.actionID)，第 \($0.attempts) 次）：\($0.error ?? "请重试")"
        }
    }

    /// Explicit user retry after the declared limit; completed outputs are retained.
    public static func resetRetry(stepID: String, in project: inout BookProject) throws {
        guard let index = project.workflowRuns?.firstIndex(where: { $0.stepID == stepID && $0.status == .failed }) else { throw ReadingError.invalid("没有可重置的失败步骤。") }
        project.workflowRuns?[index].attempts = 0
        project.audit.append(ToolAudit(name: "workflow_retry_reset", summary: "用户重置步骤 \(stepID) 的重试预算。"))
    }

    public static func recordTool(_ name: String, in project: inout BookProject, previous: BookProject? = nil) {
        guard let index = project.workflowRuns?.firstIndex(where: { $0.status == .running }) else { return }
        if !(project.workflowRuns?[index].toolNames.contains(name) ?? true) { project.workflowRuns?[index].toolNames.append(name) }
        if let previous, previous.entities != project.entities || previous.events != project.events || previous.relations != project.relations {
            var writes = project.workflowRuns?[index].knowledgeWriteTools ?? []
            if !writes.contains(name) { writes.append(name) }
            project.workflowRuns?[index].knowledgeWriteTools = writes
        }
    }

    public static var completionTool: [String: Any] {
        let id: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 128, "pattern": "^[A-Za-z0-9_.-]+$"]
        return ["type": "function", "function": ["name": "workflow_step_complete", "description": "完成宿主当前唯一运行步骤。只提交这一步实际结果、已通过片段ID、连续精确原文引文及疑点；不结束整页。宿主校验并保存后才执行下一动作。",
                "parameters": ["type": "object", "additionalProperties": false,
                               "properties": ["stepID": id, "result": ["type": "string", "minLength": 1, "maxLength": 2000],
                                              "paragraphIDs": ["type": "array", "items": id, "minItems": 1, "maxItems": 512],
                                              "evidence": ["type": "array", "minItems": 1, "maxItems": 64, "items": ["type": "object", "additionalProperties": false, "properties": ["unitID": id, "quote": ["type": "string", "minLength": 1, "maxLength": 32768]], "required": ["unitID", "quote"]]],
                                              "issues": ["type": "array", "maxItems": 12, "items": ["type": "string", "minLength": 1, "maxLength": 400]],
                                              "noChangesReason": ["type": "string", "minLength": 1, "maxLength": 400, "description": "知识抽取没有实际写入工具时必须明确说明本步无适用对象的原因；不能声称创建了未写入知识。"]],
                               "required": ["stepID", "result", "paragraphIDs", "evidence", "issues"]]]]
    }

    public static func complete(arguments: Data, to project: inout BookProject, allowedUnitIDs: Set<String>) throws -> String {
        struct Submission: Decodable { var stepID: String; var result: String; var paragraphIDs: [String]; var evidence: [Evidence]; var issues: [String]; var noChangesReason: String? }
        guard arguments.count <= 256 * 1024,
              let object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              Set(["stepID", "result", "paragraphIDs", "evidence", "issues"]).isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: Set(["stepID", "result", "paragraphIDs", "evidence", "issues", "noChangesReason"])) else { throw ReadingError.invalid("步骤输出字段或大小不合法。") }
        let value = try JSONDecoder().decode(Submission.self, from: arguments)
        try complete(stepID: value.stepID, output: ReadingWorkflowOutput(result: value.result, paragraphIDs: value.paragraphIDs, evidence: value.evidence, issues: value.issues, noChangesReason: value.noChangesReason), to: &project, allowedUnitIDs: allowedUnitIDs)
        return "当前步骤输出已验证；宿主将保存检查点，再执行下一动作。"
    }

    public static func complete(stepID: String, output: ReadingWorkflowOutput, to project: inout BookProject, allowedUnitIDs: Set<String>) throws {
        guard let index = project.workflowRuns?.firstIndex(where: { $0.stepID == stepID && $0.status == .running }),
              let run = project.workflowRuns?[index], allowedUnitIDs == [run.unitID] else { throw ReadingError.invalid("步骤输出不是宿主当前运行步骤。") }
        try ReadingLedger.requireComplete(unitIDs: allowedUnitIDs, in: project)
        try validate(output: output, unitID: run.unitID, project: project)
        try validateActionOutput(output, run: run)
        var candidate = project
        let terminalTool = run.actionID == "citations.verify" ? "citations.verify" : "workflow_step_complete"
        if !(candidate.workflowRuns?[index].toolNames.contains(terminalTool) ?? true) { candidate.workflowRuns?[index].toolNames.append(terminalTool) }
        candidate.workflowRuns?[index].status = .completed
        candidate.workflowRuns?[index].output = output
        candidate.workflowRuns?[index].error = nil
        candidate.workflowRuns?[index].updatedAt = Date()
        if let previous = (candidate.readingStepResults ?? []).first(where: { $0.stepID == stepID }) {
            guard previous.result == output.result, previous.paragraphIDs == output.paragraphIDs else { throw ReadingError.invalid("该步骤已有不同的历史输出，不能静默覆盖。") }
        } else {
            let result = ReadingStepResult(stepID: stepID, unitID: run.unitID, methodID: run.methodID, methodHash: run.methodHash,
                                           stepIndex: run.stepIndex, result: output.result, paragraphIDs: output.paragraphIDs, createdAt: Date())
            candidate.readingStepResults = (candidate.readingStepResults ?? []) + [result]
        }
        candidate.audit.append(ToolAudit(name: "workflow_step_complete", summary: "\(run.actionID) · \(stepID)"))
        project = candidate
    }

    public static func requireComplete(unitIDs: Set<String>, in project: BookProject,
                                       registry: ReadingWorkflowActionRegistry = .builtIn) throws {
        try validateStoredRecords(in: project, registry: registry)
        for unitID in unitIDs {
            let runs = (project.workflowRuns ?? []).filter { $0.unitID == unitID }
            // Historical finishes have no action runs; do not invent or invalidate them.
            if runs.isEmpty { continue }
            guard let unit = project.units.first(where: { $0.id == unitID }) else { throw ReadingError.invalid("流程原文不存在。") }
            let required = Set(try ReadingLedger.stepRequirements(for: unit, in: project, registry: registry).map(\.stepID))
            let completed = Set(runs.filter { $0.status == .completed && $0.output != nil }.map(\.stepID))
            guard required.isSubset(of: completed) else { throw ReadingError.invalid("仍有未执行或失败的流程步骤，不能结束当前单元。") }
        }
    }

    /// Reading archives remains possible without the optional native action loaded.
    /// Execution/finish callers pass a real registry and reject missing handlers.
    public static func validateStoredRecords(in project: BookProject, registry: ReadingWorkflowActionRegistry? = nil) throws {
        let runs = project.workflowRuns ?? []
        guard runs.count <= 100_000, Set(runs.map(\.stepID)).count == runs.count, runs.filter({ $0.status == .running }).count <= 1 else { throw ReadingError.invalid("流程检查点重复、过多或同时运行多个步骤。") }
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(runs.map { ($0.stepID, $0) }, uniquingKeysWith: { first, _ in first })
        let receiptsByUnit = Dictionary(grouping: project.paragraphReceipts ?? [], by: \.unitID)
        var unitHashes: [String: String] = [:], paragraphCache: [String: Set<String>] = [:]
        var requirementCache: [String: [ReadingStepRequirement]] = [:]
        for run in runs {
            guard let unit = units[run.unitID] else { throw ReadingError.invalid("流程检查点原文不存在。") }
            let unitHash: String
            if let cached = unitHashes[unit.id] { unitHash = cached }
            else { unitHash = try hash(unit.text); unitHashes[unit.id] = unitHash }
            guard run.unitHash == unitHash,
                  run.input.unitID == run.unitID, run.input.unitHash == run.unitHash, run.inputHash == (try encodedHash(run.input)),
                  (0...8).contains(run.attempts), run.toolNames.count <= 64, Set(run.toolNames).count == run.toolNames.count else { throw ReadingError.invalid("流程检查点来源、输入哈希或次数无效。") }
            let key = unit.id + "|" + run.methodID
            let requirements: [ReadingStepRequirement]
            if let cached = requirementCache[key] { requirements = cached }
            else {
                var scoped = project; scoped.plan = ReadingPlan(methodIDs: [run.methodID])
                requirements = try ReadingLedger.stepRequirements(for: unit, in: scoped, registry: registry); requirementCache[key] = requirements
            }
            guard let requirement = requirements.first(where: { $0.stepID == run.stepID }),
                  requirement.methodHash == run.methodHash, requirement.stepIndex == run.stepIndex,
                  requirement.stepText == run.input.instruction else { throw ReadingError.invalid("流程检查点方法来源已变化。") }
            let binding = try execution(for: requirement, in: project, registry: registry)
            guard run.actionID == binding.actionID, run.input.configuration == binding.configuration,
                  run.attempts <= binding.maxAttempts else { throw ReadingError.invalid("流程检查点动作绑定无效。") }
            guard run.toolNames.allSatisfy({ $0.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil }) else { throw ReadingError.invalid("流程检查点工具标识无效。") }
            let writes = run.knowledgeWriteTools ?? []
            guard Set(writes).count == writes.count, Set(writes).isSubset(of: Set(run.toolNames)) else { throw ReadingError.invalid("流程知识写入凭据无效。") }
            let available: Set<String>
            if let cached = paragraphCache[unit.id] { available = cached }
            else {
                var scoped = project; scoped.units = [unit]; scoped.paragraphReceipts = receiptsByUnit[unit.id] ?? []
                available = Set(try ReadingLedger.receipts(for: unit, in: scoped).map(\.paragraphID)); paragraphCache[unit.id] = available
            }
            guard Set(run.input.paragraphIDs) == available, run.input.paragraphIDs.count == available.count,
                  Set(run.input.previousStepIDs).count == run.input.previousStepIDs.count,
                  run.input.previousStepIDs.allSatisfy({ id in id != run.stepID && byID[id]?.unitID == run.unitID && byID[id]?.status == .completed }) else { throw ReadingError.invalid("流程输入片段或先前步骤检查点无效。") }
            if run.status == .completed {
                let terminalTool = run.actionID == "citations.verify" ? "citations.verify" : "workflow_step_complete"
                guard let output = run.output, run.error == nil, run.attempts > 0, run.toolNames.contains(terminalTool),
                      (project.readingStepResults ?? []).contains(where: { $0.stepID == run.stepID && $0.unitID == run.unitID && $0.methodID == run.methodID && $0.methodHash == run.methodHash && $0.stepIndex == run.stepIndex && $0.result == output.result && $0.paragraphIDs == output.paragraphIDs }) else { throw ReadingError.invalid("已完成流程缺少工具凭据、步骤结果或仍有错误。") }
                try validate(output: output, unitID: run.unitID, project: project, sourceUnit: unit, availableParagraphIDs: available)
                try validateActionOutput(output, run: run)
            } else if run.status == .failed {
                guard run.output == nil, let error = run.error, !error.isEmpty, error.count <= 1600 else { throw ReadingError.invalid("失败流程缺少错误信息。") }
            }
        }
    }

    fileprivate static func verifyCitations(task: ReadingWorkflowTask, in project: BookProject) throws -> ReadingWorkflowOutput {
        guard let unit = project.units.first(where: { $0.id == task.requirement.unitID }) else { throw ReadingError.invalid("核验原文不存在。") }
        let ids = Set(project.entities.map(\.id) + project.events.map(\.id) + project.documents.map(\.id))
        var evidence = project.entities.flatMap(\.evidence) + project.events.flatMap(\.evidence) + project.relations.flatMap(\.evidence)
        evidence += (project.workflowRuns ?? []).filter { $0.unitID == unit.id && $0.status == .completed }.flatMap { $0.output?.evidence ?? [] }
        let local = evidence.filter { $0.unitID == unit.id }
        guard local.allSatisfy({ !$0.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && unit.text.contains($0.quote) }),
              project.relations.allSatisfy({ ids.contains($0.fromID) && ids.contains($0.toID) }),
              project.events.allSatisfy({ event in (event.placeIDs + event.participantIDs).allSatisfy { id in project.entities.contains { $0.id == id } } }) else {
            throw ReadingError.invalid("引用核验失败：存在不匹配引文或失效对象关联。")
        }
        let quote = String(unit.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        return ReadingWorkflowOutput(result: "宿主已逐项核对本单元 \(local.count) 条已保存引文及现有对象关联：引文均为原文连续子串，未发现失效关联。此校验只验证引用一致性，不证明推理或抽取语义正确。", paragraphIDs: task.input.paragraphIDs,
                                     evidence: [Evidence(unitID: unit.id, quote: quote)], issues: [])
    }

    private static func validate(output: ReadingWorkflowOutput, unitID: String, project: BookProject,
                                  sourceUnit: SourceUnit? = nil, availableParagraphIDs: Set<String>? = nil) throws {
        guard let unit = sourceUnit ?? project.units.first(where: { $0.id == unitID }),
              !output.result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, output.result.count <= 2000,
              !output.paragraphIDs.isEmpty, output.paragraphIDs.count <= 512,
              Set(output.paragraphIDs).count == output.paragraphIDs.count,
              !output.evidence.isEmpty, output.evidence.count <= 64,
              output.evidence.allSatisfy({ $0.unitID == unitID && !$0.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && unit.text.contains($0.quote) }),
              output.issues.count <= 12, output.issues.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 400 }),
              output.noChangesReason.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 400 }) ?? true else { throw ReadingError.invalid("流程输出缺少有效结果、片段或精确原文证据。") }
        let paragraphs: Set<String>
        if let availableParagraphIDs { paragraphs = availableParagraphIDs }
        else { paragraphs = Set(try ReadingLedger.receipts(for: unit, in: project).map(\.paragraphID)) }
        guard Set(output.paragraphIDs).isSubset(of: paragraphs) else { throw ReadingError.invalid("流程输出引用了未通过的片段。") }
    }

    private static func validateActionOutput(_ output: ReadingWorkflowOutput, run: ReadingWorkflowStepRun) throws {
        if run.actionID == "facts.extract", (run.knowledgeWriteTools ?? []).isEmpty, output.noChangesReason == nil {
            throw ReadingError.invalid("知识抽取没有实际知识写入凭据；请调用知识工具，或用noChangesReason明确说明无适用对象。")
        }
    }

    private static func set(_ run: ReadingWorkflowStepRun, in project: inout BookProject) {
        var runs = project.workflowRuns ?? []
        if let index = runs.firstIndex(where: { $0.stepID == run.stepID }) { runs[index] = run } else { runs.append(run) }
        project.workflowRuns = runs
    }
    private static func hash(_ text: String) throws -> String { try BookImporter.sha256(Data(text.utf8)) }
    private static func encodedHash<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try BookImporter.sha256(encoder.encode(value))
    }
}
