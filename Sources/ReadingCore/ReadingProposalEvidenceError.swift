import Foundation

/// A repair hint, not repaired evidence. Candidates come only from text already
/// supplied to this task; the model must submit an explicit corrected proposal.
struct ReadingProposalEvidenceError: LocalizedError {
    let issues: [[String: String]]
    var errorDescription: String? {
        "提案引文与本次实际提供的原文不符；请按evidenceIssues逐条核对后再提交。未保存修改。"
    }
}
