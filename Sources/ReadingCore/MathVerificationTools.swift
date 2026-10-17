import Foundation

public struct MathVerificationToolPlugin: ReadingToolPlugin {
    public let info = ReadingPluginInfo(id: "builtin.math-verification", name: "精确数学核查")
    public init() {}
    public func register(in registry: inout PluginToolRegistry) throws {
        try registry.register(RegisteredReadingTool(pluginID: info.id, schema: MathVerificationTools.schema,
                                                   phases: [.reading, .workflow], requiresReceipts: true) { data, project, allowed in
            try MathVerificationTools.apply(arguments: data, to: &project, allowedUnitIDs: allowed)
        })
    }
}

public enum MathVerificationTools {
    public static let maximumRecords = 256
    public static var schema: [String: Any] {
        let rational: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 40,
                                        "description": "精确整数、a/b 分数或最多六位小数。禁止符号、幂、科学计数法。"]
        let row = array(rational, minimum: 1, maximum: MathVerificationEngine.maximumColumns)
        let matrix = array(row, minimum: 1, maximum: MathVerificationEngine.maximumRows)
        let operation = object(["kind": ["type": "string", "enum": ["swap", "scale", "add"]],
                                "targetRow": ["type": "integer", "minimum": 1, "maximum": 8],
                                "sourceRow": ["type": "integer", "minimum": 1, "maximum": 8], "factor": rational], required: ["kind", "targetRow"])
        let step = object(["operation": operation, "expected": matrix], required: ["operation", "expected"])
        let evidence = object(["unitID": ["type": "string", "minLength": 1, "maxLength": 128],
                               "quote": ["type": "string", "minLength": 1, "maxLength": 32768]], required: ["unitID", "quote"])
        return ["type": "function", "function": ["name": "math_verify", "description": "使用本机精确有理数计算核查数字矩阵。solveLinearSystem对增广矩阵（末列为常数）执行逐步Gauss-Jordan，给出唯一/无穷/无解及精确回代；checkRowSteps核对每条swap/scale/add行变换和声称的expected完整矩阵，首处不符立即停止。行号从1开始，交换/倍加必须不同的行，倍乘/倍加非零。最多8行9列128步；超出Int64精确范围直接拒绝，不用浮点近似。先完成当前原文逐段回执；input必须为evidence.quote按双换行连接的真实原文，matrix是AI转录值。核查通过仅证明结构化数字运算成立，不证明转录与原文一致、OCR无误或一般数学证明正确。禁止伪造人工复核标记，不编辑原文和用户Markdown。",
            "parameters": object(["title": ["type": "string", "minLength": 1, "maxLength": 200],
                                   "input": ["type": "string", "minLength": 1, "maxLength": 32768],
                                   "mode": ["type": "string", "enum": ["solveLinearSystem", "checkRowSteps"]], "matrix": matrix,
                                   "steps": array(step, minimum: 0, maximum: MathVerificationEngine.maximumSteps),
                                   "evidence": array(evidence, minimum: 1, maximum: 32)], required: ["title", "input", "mode", "matrix", "evidence"])]]
    }

    private struct Submission: Decodable {
        var title: String
        var input: String
        var mode: MathVerificationMode
        var matrix: [[String]]
        var steps: [MathRowStep]?
        var evidence: [Evidence]
    }
    public static func apply(arguments: Data, to project: inout BookProject, allowedUnitIDs: Set<String>) throws -> String {
        guard arguments.count <= 262_144, let json = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else { throw invalid("参数须为小于256 KiB的JSON对象。") }
        try keys(json, allowed: ["title", "input", "mode", "matrix", "steps", "evidence"])
        for step in json["steps"] as? [[String: Any]] ?? [] {
            try keys(step, allowed: ["operation", "expected"])
            if let operation = step["operation"] as? [String: Any] { try keys(operation, allowed: ["kind", "targetRow", "sourceRow", "factor"]) }
        }
        for source in json["evidence"] as? [[String: Any]] ?? [] { try keys(source, allowed: ["unitID", "quote"]) }
        let value = try JSONDecoder().decode(Submission.self, from: arguments)
        try ReadingLedger.requireComplete(unitIDs: allowedUnitIDs, in: project)
        guard !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.evidence.isEmpty, value.evidence.count <= 32, Set(value.evidence).count == value.evidence.count,
              value.input == value.evidence.map(\.quote).joined(separator: "\n\n") else { throw invalid("input必须为不重复证据quote按双换行连接的原文，不能改写或冒充人工复核值。") }
        for evidence in value.evidence {
            guard allowedUnitIDs.contains(evidence.unitID), !evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let unit = project.units.first(where: { $0.id == evidence.unitID }), unit.text.range(of: evidence.quote, options: .literal) != nil else {
                throw invalid("证据必须为本次获准单元的连续原文。")
            }
        }
        guard (project.mathVerifications ?? []).count < maximumRecords else { throw invalid("本书核查记录已达256条，请先导出整理；不会覆盖旧记录或回收站。") }
        let request = MathVerificationRequest(title: value.title, input: value.input, mode: value.mode, matrix: value.matrix,
                                              steps: value.steps ?? [], evidence: value.evidence, origin: .aiStructured)
        var record = try MathVerificationEngine.verify(request)
        if let run = (project.workflowRuns ?? []).first(where: { $0.status == .running }) {
            guard allowedUnitIDs == [run.unitID] else { throw invalid("当前数学调用与宿主运行步骤原文不一致。") }
            record.workflowStepID = run.stepID; record.workflowAttempt = run.attempts
        }
        var records = project.mathVerifications ?? []; records.append(record)
        let previous = project.mathVerifications
        project.mathVerifications = records
        do { try validateTransition(from: previous, to: records, allowedUnitIDs: allowedUnitIDs, in: project) }
        catch { project.mathVerifications = previous; throw error }
        // The outer tool response already has a JSON envelope. Include a bounded
        // machine-readable exact result so AI can use real fractions instead of guessing.
        let response: [String: Any] = ["recordID": record.id, "status": record.status.rawValue, "summary": record.summary,
                                        "normalizedMatrix": record.normalizedMatrix, "resultMatrix": record.resultMatrix,
                                        "solution": record.solution?.particular ?? [], "freeVariables": record.solution?.freeVariables ?? [],
                                        "nullspaceBasis": record.solution?.nullspaceBasis ?? [], "scopeWarning": record.scopeWarning,
                                        "differences": record.steps.last?.differences.map { ["row": $0.row, "column": $0.column, "expected": $0.expected, "submitted": $0.submitted] as [String: Any] } ?? []]
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else { throw invalid("结果编码失败。") }
        return result
    }

    /// Call this from the host registry whenever any plugin changes mathVerifications.
    /// Records are append-only for AI; user trash/restore remains a host UI operation.
    public static func validateTransition(from old: [MathVerificationRecord]?, to new: [MathVerificationRecord]?,
                                          allowedUnitIDs: Set<String>, in project: BookProject) throws {
        let previous = old ?? []
        guard let new, new.count <= maximumRecords, new.count >= previous.count,
              Array(new.prefix(previous.count)) == previous, Set(new.map(\.id)).count == new.count else {
            throw invalid("插件只能新增核查记录，不能改写、删除、恢复或重排历史记录。")
        }
        for record in new.dropFirst(previous.count) {
            guard record.deletedAt == nil else { throw invalid("AI不能把新增核查写入回收站。") }
            if let run = (project.workflowRuns ?? []).first(where: { $0.status == .running }) {
                guard record.workflowStepID == run.stepID, record.workflowAttempt == run.attempts else { throw invalid("数学记录必须归属于宿主本次运行步骤，不能借用旧运行凭据。") }
            } else {
                guard record.workflowStepID == nil, record.workflowAttempt == nil else { throw invalid("无宿主运行步骤时不能伪造步骤归属。") }
            }
            try validateRecord(record, allowedUnitIDs: allowedUnitIDs, in: project)
        }
    }
    /// Verifies a historical calculation without undoing the user's trash state.
    public static func validateRecord(_ record: MathVerificationRecord, allowedUnitIDs: Set<String>, in project: BookProject) throws {
        guard record.request.origin == .aiStructured, record.request.matrix != nil, !record.request.evidence.isEmpty,
              Set(record.request.evidence).count == record.request.evidence.count,
              record.request.input == record.request.evidence.map(\.quote).joined(separator: "\n\n") else { throw invalid("AI核查须保留真实原文及AI转录标记。") }
        for evidence in record.request.evidence {
            guard allowedUnitIDs.contains(evidence.unitID), let unit = project.units.first(where: { $0.id == evidence.unitID }),
                  !evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, unit.text.range(of: evidence.quote, options: .literal) != nil else {
                throw invalid("AI核查证据超出获准原文或来源已变化。")
            }
        }
        let calculated = try MathVerificationEngine.verify(record.request)
        guard record.title == calculated.title, record.normalizedMatrix == calculated.normalizedMatrix,
              record.resultMatrix == calculated.resultMatrix, record.steps == calculated.steps, record.status == calculated.status,
              record.summary == calculated.summary, record.solution == calculated.solution else { throw invalid("插件不能伪造计算结果或通过状态。") }
    }
    private static func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    private static func array(_ items: [String: Any], minimum: Int, maximum: Int) -> [String: Any] {
        ["type": "array", "items": items, "minItems": minimum, "maxItems": maximum]
    }
    private static func keys(_ value: [String: Any], allowed: Set<String>) throws {
        guard Set(value.keys).isSubset(of: allowed) else { throw invalid("不能包含未知字段或自报核查结果。") }
    }
    private static func invalid(_ message: String) -> ReadingError { .invalid("数学核查：" + message) }
}
