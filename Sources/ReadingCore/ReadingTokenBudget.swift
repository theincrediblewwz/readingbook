import Foundation

/// Untrusted provider usage is checked before addition. A corrupt positive Int
/// must pause an operation, not overflow before the existing protection gate.
enum ReadingTokenBudget {
    static func charge(_ cost: Int, to consumed: inout Int, limit: Int) throws {
        guard cost > 0, consumed >= 0, limit > 0, consumed <= limit else { throw ReadingError.invalid("模型 token 计数或任务预算无效。") }
        let sum = consumed.addingReportingOverflow(cost)
        guard !sum.overflow, sum.partialValue <= limit else { throw ReadingWorkflowBudgetPause(message: "本次分析达到 token 保护上限，当前单元未提交。") }
        consumed = sum.partialValue
    }

    static func operationLimit(for settings: ProviderSettings) throws -> Int {
        // Validate before derived arithmetic, even when a caller directly uses
        // the Core API with damaged or unsaved settings.
        guard (64...1_048_576).contains(settings.maxOutputTokens),
              (1...10_000).contains(settings.maxRequestsPerRun),
              settings.contextWindowTokens.map({ (1024...4_194_304).contains($0) }) ?? true else { throw ReadingError.invalid("请求或 token 预算超出允许范围。") }
        return min(4_194_304, max(1024, settings.contextWindowTokens ?? max(196_000, settings.maxOutputTokens + 64_000)))
    }
}
