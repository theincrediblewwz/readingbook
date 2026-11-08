import Foundation

extension ReadingQuerySession {
    /// The host keeps its canonical evidence envelope for clipping, version
    /// checks and budgets. The model reads the original text with real line
    /// breaks, rather than another JSON string inside its message content.
    func modelSourceText(_ payload: String) throws -> String {
        guard let value = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let rows = value["actualReadFragments"] as? [[String: Any]] else {
            throw invalid("阅读资料的内部封装不完整，未发送正文。")
        }
        var sections: [String] = []
        if let receipts = value["hostToolReceipts"] as? [[String: Any]], !receipts.isEmpty {
            sections.append("软件回执（非正文）：\n" + (try json(receipts)))
        }
        for row in rows {
            guard let kind = row["kind"] as? String, ["unit", "doc", "message"].contains(kind),
                  let id = row["id"] as? String, !id.contains("\n"), !id.contains("\r"),
                  let text = row["text"] as? String, let partial = row["fragmentTruncated"] as? Bool else {
                throw invalid("阅读片段的内部身份不完整，未发送正文。")
            }
            let label = kind == "unit" ? "原文" : kind == "doc" ? "已分享笔记" : "旧问答"
            var heading = "【\(label) [\(kind):\(id)]｜\(partial ? "节选" : "本范围完整")】"
            let reference = row["sourceRef"] as? String ?? (try? sourceReferenceID(unitID: id, text: text))
            if kind == "unit", text.count <= 32_768,
               sourceReferences[id] != Evidence(unitID: id, quote: text),
               let reference, sourceReferences[reference] == Evidence(unitID: id, quote: text) {
                // Unusual source IDs cannot be a proposal reference. Preserve
                // the actual issued reference instead of guessing a new one.
                heading += "\n整理引用编号：" + reference
            }
            sections.append(heading + "\n" + text)
        }
        let text = sections.joined(separator: "\n\n")
        guard text.utf8.count <= payload.utf8.count else { throw invalid("阅读资料排版超过已核对预算，未发送正文。") }
        return text
    }

    /// A short reference means the exact initial fragment, not the entire
    /// canonical page. Never overwrite an already issued reference or grant
    /// evidence for an index entry which was not actually supplied.
    mutating func registerInitialSourceReferences() throws {
        // Reserve canonical hashes first, so a deliberately unusual unit ID
        // cannot overwrite another fragment's existing reference.
        var entries: [Evidence] = []
        for (id, text) in sourceExcerpts where text.count <= 32_768 {
            let evidence = Evidence(unitID: id, quote: text)
            let stable = try sourceReferenceID(unitID: id, text: text)
            guard sourceReferences[stable] == nil || sourceReferences[stable] == evidence else {
                throw invalid("原文引用身份发生冲突，未重新绑定。")
            }
            sourceReferences[stable] = evidence
            entries.append(evidence)
        }
        for evidence in entries {
            let id = evidence.unitID
            guard (try? ControlledChangeCoding.requireID(id)) != nil,
                  sourceReferences[id] == nil || sourceReferences[id] == evidence else { continue }
            sourceReferences[id] = evidence
        }
    }
}
