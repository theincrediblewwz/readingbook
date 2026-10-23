import Foundation

/// An actor can reuse exact validated records across saves. No caller can seed
/// this cache with unvalidated data, and source/run checks are never cached.
public struct MathVerificationValidationCache: Sendable {
    fileprivate var records = Set<MathVerificationRecord>()
    public init() {}
}

public extension MathVerificationTools {
    /// The cached path still validates current evidence and authorization. Only
    /// deterministic arithmetic over an exactly equal record can be reused.
    static func validateRecord(_ record: MathVerificationRecord, allowedUnitIDs: Set<String>, in project: BookProject,
                               cache: inout MathVerificationValidationCache) throws {
        if cache.records.contains(record) {
            guard record.request.origin == .aiStructured, record.request.matrix != nil, !record.request.evidence.isEmpty,
                  Set(record.request.evidence).count == record.request.evidence.count,
                  record.request.input == record.request.evidence.map(\.quote).joined(separator: "\n\n") else { throw StoredExtensionValidation.invalid("AI核查须保留真实原文及AI转录标记。") }
            for evidence in record.request.evidence {
                guard allowedUnitIDs.contains(evidence.unitID), let unit = project.units.first(where: { $0.id == evidence.unitID }),
                      !evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      unit.text.range(of: evidence.quote, options: .literal) != nil else { throw StoredExtensionValidation.invalid("数学核查证据超出获准原文或来源已变化。") }
            }
        } else {
            try validateRecord(record, allowedUnitIDs: allowedUnitIDs, in: project)
            if cache.records.count >= maximumRecords { cache.records.removeAll(keepingCapacity: true) }
            cache.records.insert(record)
        }
    }
    /// Imports and ordinary saves validate every record, including standalone
    /// manual calculations and trash, rather than only records named by a run.
    static func validateStoredRecords(in project: BookProject) throws {
        var cache = MathVerificationValidationCache()
        try validateStoredRecords(in: project, cache: &cache)
    }
    static func validateStoredRecords(in project: BookProject, cache: inout MathVerificationValidationCache) throws {
        let records = project.mathVerifications ?? []
        try StoredExtensionValidation.ids(records.map(\.id), maximum: maximumRecords)
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let runs = Dictionary((project.workflowRuns ?? []).map { ($0.stepID, $0) }, uniquingKeysWith: { first, _ in first })
        for record in records {
            try StoredExtensionValidation.date(record.createdAt)
            if let date = record.deletedAt { try StoredExtensionValidation.date(date) }
            try StoredExtensionValidation.ids(record.request.evidence.map(\.unitID), maximum: 32, unique: false)
            guard Set(record.request.evidence).count == record.request.evidence.count else { throw StoredExtensionValidation.invalid("数学记录含重复原文证据。") }
            for evidence in record.request.evidence {
                guard let unit = units[evidence.unitID], !evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      unit.text.range(of: evidence.quote, options: .literal) != nil else { throw StoredExtensionValidation.invalid("数学核查的原文证据已变化或不存在。") }
            }
            if record.request.origin == .aiStructured {
                guard (record.workflowStepID == nil) == (record.workflowAttempt == nil) else { throw StoredExtensionValidation.invalid("数学流程归属不完整。") }
                if let stepID = record.workflowStepID, let attempt = record.workflowAttempt {
                    guard let run = runs[stepID], (1...8).contains(attempt), run.attempts == attempt,
                          record.request.evidence.allSatisfy({ $0.unitID == run.unitID }) else { throw StoredExtensionValidation.invalid("数学核查引用了不存在或不匹配的流程尝试。") }
                }
                if !cache.records.contains(record) {
                    try validateRecord(record, allowedUnitIDs: Set(record.request.evidence.map(\.unitID)), in: project)
                }
            } else {
                guard record.workflowStepID == nil, record.workflowAttempt == nil else { throw StoredExtensionValidation.invalid("手动数学核查不能冒充 AI 流程产物。") }
                if !cache.records.contains(record) {
                    let result = try MathVerificationEngine.verify(record.request)
                    guard record.title == result.title, record.normalizedMatrix == result.normalizedMatrix,
                          record.resultMatrix == result.resultMatrix, record.steps == result.steps,
                          record.status == result.status, record.summary == result.summary,
                          record.solution == result.solution else { throw StoredExtensionValidation.invalid("保存的数学结果与输入重新计算不一致。") }
                }
            }
        }
        // Publish only after every record passed. Current IDs are bounded above,
        // so deleted books or changing histories cannot grow an unbounded cache.
        cache.records = Set(records)
    }
}

public extension BookSchemeRuntime {
    /// A stale preview or undo conflict is recoverable user state. Validate its
    /// structure here, leaving comparisons to the live configuration/source to
    /// the explicit apply/revert gates.
    static func validateStoredState(in project: BookProject) throws {
        guard let state = project.bookSchemes else { return }
        try StoredExtensionValidation.ids(state.history.map(\.id), maximum: 20)
        try StoredExtensionValidation.ids(state.templates.map(\.id), maximum: 32)
        for revision in state.history {
            try StoredExtensionValidation.text(revision.title, maximum: 400)
            try StoredExtensionValidation.date(revision.appliedAt)
            if let date = revision.revertedAt { try StoredExtensionValidation.date(date) }
            try StoredExtensionValidation.configuration(revision.before)
            try StoredExtensionValidation.configuration(revision.after)
        }
        for template in state.templates {
            guard template.schemaVersion == 1 else { throw StoredExtensionValidation.invalid("不支持保存的方案模板版本。") }
            try StoredExtensionValidation.text(template.name, maximum: 120)
            try StoredExtensionValidation.date(template.createdAt)
            try StoredExtensionValidation.configuration(template.configuration)
        }
        if let pending = state.pending {
            try StoredExtensionValidation.ids([pending.id], maximum: 1)
            try StoredExtensionValidation.text(pending.title, maximum: 400)
            try StoredExtensionValidation.text(pending.origin, maximum: 80)
            try StoredExtensionValidation.date(pending.createdAt)
            guard pending.notes.count <= 32 else { throw StoredExtensionValidation.invalid("方案说明超过上限。") }
            for note in pending.notes { try StoredExtensionValidation.text(note, maximum: 4000) }
            if let hash = pending.sourceFingerprint {
                guard hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw StoredExtensionValidation.invalid("方案原文散列格式不合法。") }
            }
            try StoredExtensionValidation.configuration(pending.before)
            try StoredExtensionValidation.configuration(pending.proposed)
            guard pending.selection.typeIDs.isSubset(of: Set(pending.proposed.types.map(\.id))),
                  pending.selection.methodIDs.isSubset(of: Set(pending.proposed.methods.map(\.id))),
                  pending.selection.viewIDs.isSubset(of: Set(pending.proposed.views.map(\.id))) else { throw StoredExtensionValidation.invalid("待确认方案的选择引用了不存在的定义。") }
        }
    }
}

private enum StoredExtensionValidation {
    static func invalid(_ message: String) -> ReadingError { .invalid("扩展元数据：" + message) }
    static func ids(_ values: [String], maximum: Int, unique: Bool = true) throws {
        guard values.count <= maximum, (!unique || Set(values).count == values.count),
              values.allSatisfy({ $0.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil }) else { throw invalid("记录标识重复、格式错误或数量超过上限。") }
    }
    static func text(_ value: String, maximum: Int, allowEmpty: Bool = false) throws {
        guard value.count <= maximum, !value.contains("\0"), allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("文本内容为空、含空字符或超过长度上限。") }
    }
    static func date(_ value: Date) throws {
        guard value.timeIntervalSince1970.isFinite else { throw invalid("记录日期无效。") }
    }
    static func configuration(_ value: BookSchemeConfiguration) throws {
        // Match the archive declaration ceiling, not the stricter new-install
        // ceiling: older accumulated definitions remain loadable and removable.
        try ids(value.types.map(\.id), maximum: 1000)
        try ids(value.methods.map(\.id), maximum: 1000)
        try ids(value.views.map(\.id), maximum: 1000)
        try ids(value.plugins.map(\.id), maximum: 1000)
        try ids(value.disabledPluginIDs, maximum: 1000)
        let types = Set(value.types.map(\.id)), methods = Set(value.methods.map(\.id)), plugins = Set(value.plugins.map(\.id))
        guard Set(value.disabledPluginIDs).isSubset(of: plugins) else { throw invalid("方案停用标识引用了不存在的声明包。") }
        for type in value.types { try typeDefinition(type) }
        for method in value.methods { try methodDefinition(method) }
        for view in value.views { try viewDefinition(view, typeIDs: types) }
        if let plan = value.plan {
            try ids(plan.methodIDs, maximum: 16)
            guard !plan.methodIDs.isEmpty, Set(plan.methodIDs).isSubset(of: methods), plan.focus.count <= 32 else { throw invalid("方案计划的读书法或关注项无效。") }
            try text(plan.rationale, maximum: 8000, allowEmpty: true)
            for item in plan.focus { try text(item, maximum: 400) }
        }
        for plugin in value.plugins {
            guard (1...1_000_000).contains(plugin.version) else { throw invalid("声明包版本无效。") }
            try text(plugin.name, maximum: 400); try text(plugin.description, maximum: 8000, allowEmpty: true)
            try ids(plugin.types.map(\.id), maximum: 1000)
            try ids(plugin.methods.map(\.id), maximum: 1000)
            try ids(plugin.views.map(\.id), maximum: 1000)
            guard plugin.types.allSatisfy({ value.types.contains($0) }),
                  plugin.methods.allSatisfy({ value.methods.contains($0) }) else { throw invalid("声明包定义与方案保存的类型或方法不一致。") }
            for type in plugin.types { try typeDefinition(type) }
            for method in plugin.methods { try methodDefinition(method) }
            // Disabled packs can retain historical views not in this workspace.
            let packTypes = types.union(plugin.types.map(\.id))
            for view in plugin.views { try viewDefinition(view, typeIDs: packTypes) }
        }
    }
    private static func typeDefinition(_ value: EntityType) throws {
        try text(value.name, maximum: 400); try text(value.icon, maximum: 128)
        try ids(value.fields.map(\.key), maximum: 100)
        for field in value.fields { try text(field.label, maximum: 400) }
    }
    private static func methodDefinition(_ value: ReadingMethod) throws {
        try text(value.name, maximum: 400); try text(value.goal, maximum: 4000)
        guard (1...24).contains(value.steps.count) else { throw invalid("方案方法步骤数无效。") }
        for step in value.steps { try text(step, maximum: 4000) }
        // Unknown native actions are archival data. Execution still requires a
        // registered action, and importing metadata grants no capabilities.
        try ReadingWorkflowRuntime.validate(method: value, registry: nil)
    }
    private static func viewDefinition(_ value: ViewDefinition, typeIDs: Set<String>) throws {
        try text(value.title, maximum: 400)
        try ids(value.typeIDs, maximum: 128)
        guard Set(value.typeIDs).isSubset(of: typeIDs) else { throw invalid("方案视图引用了不存在的类型。") }
        if let renderer = value.rendererID { try ids([renderer], maximum: 1) }
        if let scope = value.scope, !["current", "book"].contains(scope) { throw invalid("方案视图范围无效。") }
        if let configuration = value.configuration {
            guard configuration.count <= 16 else { throw invalid("方案视图配置数量超过上限。") }
            for (key, val) in configuration {
                try text(key, maximum: 128); try text(val, maximum: 4000, allowEmpty: true)
                guard key.utf8.count <= 128, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw invalid("方案视图配置键含控制字符或超过字节上限。") }
            }
        }
    }
}
