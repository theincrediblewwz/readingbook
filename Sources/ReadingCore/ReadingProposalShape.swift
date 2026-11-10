import Foundation

/// Check the declared business envelope before Codable can silently discard
/// unknown fields. This does not close user-defined property/configuration maps
/// or replace the normal evidence, identity, permission and review checks.
struct ReadingProposalShapeError: LocalizedError {
    let issues: [[String: String]]
    let groupMoves: [[String: String]]
    var errorDescription: String? {
        "提案有放错位置或未声明的字段；没有忽略内容，也没有进入审阅。请按shapeIssues修正；groupMoves可整体移动原草案，不必重写资料或重读原文。"
    }
}

enum ReadingProposalShape {
    /// Report malformed identity references before temporal checks interpret a
    /// failed cast as an empty list of evidence anchors.
    static func validateReferences(name: String, data: Data) throws {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let group = ReadingProposalTools.group(for: name) else { return }
        if let batch = raw["batch"] as? [String: Any] { try validate(batch, wrapped: true) }
        else { try validate([group.rawValue: raw], wrapped: false) }
    }

    static func schema(_ group: ControlledChangeGroup) -> [String: Any] {
        switch group {
        case .knowledge: return ReadingProposalSchemas.knowledge
        case .graph: return ReadingProposalSchemas.graph
        case .documents: return ReadingProposalSchemas.documents
        case .bookScheme: return ReadingProposalSchemas.bookScheme
        }
    }
    static func validate(_ groups: [String: Any], wrapped: Bool) throws {
        var issues = [[String: String]](), moves = [[String: String]]()
        let definitions: [ControlledChangeGroup] = [.knowledge, .graph, .documents, .bookScheme]
        var visited = 0
        func pointer(_ tokens: [String]) -> String {
            "/" + tokens.map { $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined(separator: "/")
        }
        func walk(_ value: Any, _ schema: [String: Any], _ tokens: [String]) {
            guard issues.count < 24 else { return }
            visited += 1
            guard visited <= 16_384 else {
                issues.append(["path": pointer(tokens), "reason": "提案结构过大，请拆成较小的业务批次。"]); return
            }
            if tokens.last == "sourceAnchorIDs" {
                guard let ids = value as? [Any] else {
                    issues.append(["path": pointer(tokens), "reason": "sourceAnchorIDs须为锚点编号字符串数组。使用本批anchors.clientID或已保存的锚点id，不要放对象。"]); return
                }
                for (index, id) in ids.enumerated() where !(id is String) && issues.count < 24 {
                    issues.append(["path": pointer(tokens + [String(index)]), "reason": "这里须填写锚点编号字符串，例如本批anchors.clientID；不要填写{clientID:...}对象。先修正引用的结构，再核对时间或引文。"])
                }
            }
            if let object = value as? [String: Any], let fields = schema["properties"] as? [String: Any] {
                if schema["additionalProperties"] as? Bool == false {
                    for key in Set(object.keys).subtracting(fields.keys).sorted() where issues.count < 24 {
                        var issue = ["path": pointer(tokens + [key]), "reason": "此位置未声明该字段，不能静默丢弃。"]
                        if tokens.count == (wrapped ? 2 : 0) {
                            let candidates = definitions.filter { (self.schema($0)["properties"] as? [String: Any])?[key] != nil }
                            if candidates.count == 1, let target = candidates.first {
                                issue["belongsTo"] = "/batch/" + target.rawValue + "/" + key
                            }
                        }
                        issues.append(issue)
                    }
                }
                for key in object.keys.sorted() {
                    if let child = fields[key] as? [String: Any] { walk(object[key]!, child, tokens + [key]) }
                }
            } else if let array = value as? [Any], let item = schema["items"] as? [String: Any] {
                for (index, child) in array.enumerated() { walk(child, item, tokens + [String(index)]) }
            }
        }
        for group in definitions {
            guard let value = groups[group.rawValue] else { continue }
            let fields = schema(group)["properties"] as? [String: Any] ?? [:]
            if wrapped, let object = value as? [String: Any], !Set(object.keys).isSubset(of: fields.keys) {
                let destinations = definitions.filter { other in
                    guard other != group, groups[other.rawValue] == nil,
                          let allowed = schema(other)["properties"] as? [String: Any] else { return false }
                    return Set(object.keys).isSubset(of: allowed.keys)
                }
                if destinations.count == 1, let destination = destinations.first {
                    moves.append(["from": "/batch/" + group.rawValue, "path": "/batch/" + destination.rawValue,
                        "targetTool": destination.rawValue == "bookScheme" ? "book_scheme_propose" : destination.rawValue == "knowledge" ? "knowledge_changes_propose" : destination.rawValue == "graph" ? "graph_changes_propose" : "document_changes_propose"])
                }
            }
            walk(value, schema(group), wrapped ? ["batch", group.rawValue] : [])
        }
        if !issues.isEmpty { throw ReadingProposalShapeError(issues: issues, groupMoves: moves) }
    }
}
