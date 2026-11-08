import Foundation

/// A failed wire shape is returned to the model, not silently stripped of
/// contradictory fields. Only references actually issued in this task appear.
struct ReadingSourceReferenceError: LocalizedError {
    struct Issue: Codable, Sendable {
        let path: String
        let sourceRef: String
        let reason: String
        let removeFields: [String]
        let sourceRefIsValid: Bool
        let correctedShapeExample: [String: String]?
    }
    let issueValues: [Issue]
    let affectedCount: Int
    var issues: [[String: Any]] {
        guard let data = try? JSONEncoder().encode(issueValues),
              let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return values
    }
    var errorDescription: String? { "原文引用格式未通过核验；请按sourceReferenceIssues修正全部\(affectedCount)处后重交。整批未保存。" }
    static let repairRule = "采用sourceRef的每一项，只保留sourceRef及可选clientID；删除unitID、quote、prefix、suffix等其他字段。采用手写引文时只传真实unitID与逐字quote，不传sourceRef。不自动替换、删字段或扩大原文范围。"
}
