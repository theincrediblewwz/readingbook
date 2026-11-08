import Foundation

extension ReadingQuerySession {
    func sourceReferenceID(unitID: String, text: String) throws -> String {
        "source-" + String(try BookImporter.sha256(Data((snapshot.scopeFingerprint + "\n" + unitID + "\n" + text).utf8)).prefix(32))
    }

    /// Expand only host-issued references to text actually supplied in this
    /// session. No fuzzy quotation repair, new citation authority or stored
    /// format is introduced. The existing literal/proposal checks run next.
    func resolveSourceReferences(in data: Data) throws -> Data {
        guard data.count <= 262_144 else { throw invalid("整理批次过大，请先保存少量核心资料。") }
        var issues: [ReadingSourceReferenceError.Issue] = [], affected = 0
        func expand(_ value: Any, depth: Int, path: String, sourceRows: Bool = false) throws -> Any {
            guard depth < 32 else { throw invalid("整理批次的嵌套层级过深。") }
            if let row = value as? [String: Any] {
                if sourceRows, let ref = row["sourceRef"] {
                    let reference = ref as? String
                    let source = reference.flatMap { sourceReferences[$0] }
                    let extra = Set(row.keys).subtracting(["sourceRef", "clientID"]).sorted()
                    let supplied = source.map { source in sourceExcerpts.contains(where: {
                              $0.0 == source.unitID && SourceTextLiteral.contains(source.quote, in: $0.1)
                          }) } ?? false
                    guard let source, supplied, extra.isEmpty else {
                        affected += 1
                        if issues.count < 4 {
                            var example: [String: String]?
                            if supplied, let reference {
                                example = ["sourceRef": reference]
                                if let id = row["clientID"] as? String { example?["clientID"] = String(id.prefix(128)) }
                            }
                            issues.append(.init(path: String(path.prefix(240)), sourceRef: String((reference ?? "[非字符串]").prefix(128)),
                                reason: supplied ? "这个sourceRef有效，但与其他字段混用；请删除removeFields列出的字段后重交。" : "这个引用不是本次实际提供且仍可用的sourceRef；请核对本轮原文编号。",
                                removeFields: extra, sourceRefIsValid: supplied, correctedShapeExample: example))
                        }
                        return row
                    }
                    var result: [String: Any] = ["unitID": source.unitID, "quote": source.quote]
                    if let clientID = row["clientID"] { result["clientID"] = clientID }
                    return result
                }
                var result: [String: Any] = [:]
                for key in row.keys.sorted() { result[key] = try expand(row[key]!, depth: depth + 1, path: path + "." + key, sourceRows: key == "evidence" || key == "anchors") }
                return result
            }
            if let rows = value as? [Any] { return try rows.enumerated().map { try expand($0.element, depth: depth + 1, path: path + "[\($0.offset)]", sourceRows: sourceRows) } }
            return value
        }
        let value = try expand(JSONSerialization.jsonObject(with: data), depth: 0, path: "$")
        if affected > 0 { throw ReadingSourceReferenceError(issueValues: issues, affectedCount: affected) }
        let resolved = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard resolved.count <= 262_144 else { throw invalid("引用展开后的整理批次过大，请拆成较小批次。") }
        return resolved
    }
}
