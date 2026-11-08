import Foundation

struct ReadingProposalMetadataError: LocalizedError {
    let issues: [[String: String]]
    var errorDescription: String? { "提案改变了已有事件的依据分类；请按metadataIssues保留已有分类，单独说明时间推算，再显式重交。整批未保存。" }
}
