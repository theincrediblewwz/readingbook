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
        func expand(_ value: Any, depth: Int, sourceRows: Bool = false) throws -> Any {
            guard depth < 32 else { throw invalid("整理批次的嵌套层级过深。") }
            if let row = value as? [String: Any] {
                if sourceRows, let ref = row["sourceRef"] {
                    guard let ref = ref as? String, Set(row.keys).isSubset(of: ["sourceRef", "clientID"]),
                          let source = sourceReferences[ref], sourceExcerpts.contains(where: {
                              $0.0 == source.unitID && SourceTextLiteral.contains(source.quote, in: $0.1)
                          }) else { throw invalid("原文引用编号未在本次实际提供，或与手写引文混用；请使用当前原文的sourceRef。") }
                    var result: [String: Any] = ["unitID": source.unitID, "quote": source.quote]
                    if let clientID = row["clientID"] { result["clientID"] = clientID }
                    return result
                }
                var result: [String: Any] = [:]
                for (key, child) in row { result[key] = try expand(child, depth: depth + 1, sourceRows: key == "evidence" || key == "anchors") }
                return result
            }
            if let rows = value as? [Any] { return try rows.map { try expand($0, depth: depth + 1, sourceRows: sourceRows) } }
            return value
        }
        let value = try expand(JSONSerialization.jsonObject(with: data), depth: 0)
        let resolved = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard resolved.count <= 262_144 else { throw invalid("引用展开后的整理批次过大，请拆成较小批次。") }
        return resolved
    }
}
