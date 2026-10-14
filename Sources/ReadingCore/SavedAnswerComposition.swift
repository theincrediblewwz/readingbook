import Foundation

public enum SavedAnswerPartKind: String, Equatable, Sendable {
    case fullAnswer, markdownExcerpt, renderedText
}

/// Captures the answer revision as content, rather than trusting a later lookup
/// of the same message ID. Rendered excerpts are explicitly semantic plain text.
public struct SavedAnswerPart: Equatable, Sendable {
    public let messageID: String
    public let sourceContent: String
    public let text: String
    public let kind: SavedAnswerPartKind
    public init(messageID: String, sourceContent: String, text: String, kind: SavedAnswerPartKind) {
        self.messageID = messageID; self.sourceContent = sourceContent; self.text = text; self.kind = kind
    }
    public init(answer: ChatMessage) {
        self.init(messageID: answer.id, sourceContent: answer.content, text: answer.content, kind: .fullAnswer)
    }
}

/// Pure content preparation. Only an explicit application save writes a document.
/// Identity excludes the chosen title, so repeating the same selection cannot
/// overwrite a user's later edits or produce a second copy under a new title.
public struct SavedAnswerComposition: Sendable {
    public let bookID: String
    public let documentID: String
    public let suggestedTitle: String
    public let markdown: String
    public let evidence: [Evidence]
    public let linkedIDs: [String]
    public let messageIDs: [String]
    public let parts: [SavedAnswerPart]

    public static func build(project: BookProject, parts requested: [SavedAnswerPart], title: String? = nil) throws -> SavedAnswerComposition {
        guard !requested.isEmpty, requested.count <= 64,
              Set(requested.map(\.messageID)).count == requested.count else {
            throw invalid("请选择 1–64 条不同的 AI 回答。")
        }
        let wanted = Dictionary(uniqueKeysWithValues: requested.map { ($0.messageID, $0) })
        let matches = project.chats.filter { wanted[$0.id] != nil }
        guard matches.count == requested.count, Set(matches.map(\.id)).count == matches.count,
              matches.allSatisfy({ $0.role == "assistant" && legalID($0.id) }) else { throw invalid("所选回答不在当前会话中，或并非合法的 AI 回答。") }

        var ordered: [SavedAnswerPart] = [], sections: [String] = [], evidence: [Evidence] = [], linked = Set<String>()
        let units = Dictionary(uniqueKeysWithValues: project.units.map { ($0.id, $0) })
        var firstQuestion = ""
        for (number, answer) in matches.enumerated() {
            guard let part = wanted[answer.id], part.sourceContent == answer.content,
                  !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  part.text.utf8.count <= 2_000_000 else { throw invalid("回答已变化或选区为空，请从当前回答重新选择。") }
            switch part.kind {
            case .fullAnswer:
                guard part.text == answer.content else { throw invalid("完整回答不能被替换为编辑后的内容。") }
            case .markdownExcerpt:
                guard answer.content.range(of: part.text, options: .literal) != nil else {
                    throw invalid("Markdown 片段必须是对应原答的连续原文；编辑后的文字不能冒充 AI 原答。")
                }
            case .renderedText:
                guard part.text.count <= 32_768 else { throw invalid("渲染区选段过长，请分段保存。") }
            }
            ordered.append(part)
            let preceding = project.chats.prefix(while: { $0.id != answer.id })
            let question = preceding.last(where: { $0.role == "user" })?.content ?? "（这条回答没有关联的提问）"
            if firstQuestion.isEmpty { firstQuestion = question }
            let label: String
            let content: String
            switch part.kind {
            case .fullAnswer: label = "完整回答"; content = part.text
            case .markdownExcerpt: label = "Markdown 原文片段"; content = part.text
            case .renderedText:
                label = "渲染区语义摘录"
                content = "> 以下为用户从渲染区选取的语义文本，不等同于 Markdown / TeX 源码。公式请以原回答源码核对。\n\n" + literalBlock(part.text)
            }
            var section = "## \(number + 1). \(label)\n\n### 对应问题\n\n\(question)\n\n### 回答内容\n\n\(content)\n\n<!-- conversation-message: \(answer.id) -->\n"
            let referenceHeading = part.kind == .fullAnswer ? "原回答的原文依据" : "原回答的原文依据（不代表摘录逐句引证）"
            var referenceLines: [String] = []
            for item in answer.evidence {
                guard let unit = units[item.unitID], !item.quote.isEmpty,
                      unit.text.range(of: item.quote, options: .literal) != nil else { throw invalid("原回答存在失效的原文证据，保存已停止。") }
                if !evidence.contains(item) { evidence.append(item) }
                linked.insert(item.unitID)
                referenceLines.append("- [\(unit.locator)](readingbook://book/\(project.id)/unit/\(item.unitID))\n\n" + item.quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n"))
            }
            if !referenceLines.isEmpty { section += "\n### \(referenceHeading)\n\n" + referenceLines.joined(separator: "\n\n") + "\n" }
            let referencedDocuments = documentReferences(in: answer.content, project: project)
            if !referencedDocuments.isEmpty {
                section += "\n### 原回答引用的文档\n\n"
                for document in referencedDocuments {
                    linked.insert(document.id)
                    section += "- [\(plainLabel(document.title))](readingbook://book/\(project.id)/document/\(document.id))\n"
                }
            }
            sections.append(section)
        }
        let proposed = String(firstQuestion.replacingOccurrences(of: "\n", with: " ").prefix(70))
        let suggested = matches.count > 1 ? "回答摘记 · \(proposed)" : proposed
        let chosen = (title ?? suggested).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chosen.isEmpty, chosen.count <= 200, !chosen.contains("\0") else { throw invalid("文档标题需为 1–200 字符。") }
        let body = "# \(plainLabel(chosen))\n\n" + sections.joined(separator: "\n---\n\n")
        guard body.utf8.count <= 4 * 1_024 * 1_024 else { throw invalid("合并文档过大，请减少选择的回答。") }
        let identity = ordered.map { ["messageID": $0.messageID, "source": $0.sourceContent, "kind": $0.kind.rawValue, "text": $0.text] }
        let digest = try BookImporter.sha256(JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]))
        // Preserve the 0.2/0.3 whole-answer save identity where it is a legal ID.
        let wholeID = "answer-\(ordered[0].messageID)"
        let documentID = ordered.count == 1 && ordered[0].kind == .fullAnswer && legalID(wholeID) ? wholeID : "answer-selection-\(digest)"
        return SavedAnswerComposition(bookID: project.id, documentID: documentID, suggestedTitle: chosen, markdown: body,
                                      evidence: evidence, linkedIDs: linked.sorted(), messageIDs: ordered.map(\.messageID), parts: ordered)
    }

    private static func legalID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
    }
    private static func plainLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "#", with: "\\#")
    }
    private static func literalBlock(_ value: String) -> String {
        var fence = "```"
        while value.contains(fence) { fence += "`" }
        return "\(fence)text\n\(value)\n\(fence)"
    }
    private static func documentReferences(in text: String, project: BookProject) -> [DocumentRecord] {
        var ids = Set<String>()
        if let regex = try? NSRegularExpression(pattern: #"\[doc:([A-Za-z0-9_.-]+)\]"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { ids.insert(String(text[range])) }
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"readingbook://[^\s\)\]>\"']+"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text), let url = URL(string: String(text[range])) else { continue }
                let pieces = url.pathComponents.filter { $0 != "/" }
                if url.host == "book", pieces.count == 3, pieces[0] == project.id, pieces[1] == "document" { ids.insert(pieces[2]) }
                else if url.host == "document", pieces.count == 1 { ids.insert(pieces[0]) }
            }
        }
        return project.documents.filter { ids.contains($0.id) }
    }
    private static func invalid(_ message: String) -> ReadingError { .invalid(message) }
}
