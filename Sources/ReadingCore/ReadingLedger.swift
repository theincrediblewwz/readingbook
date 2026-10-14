import Foundation

/// An exact, host-generated fragment of an existing source unit. Ranges are half-open UTF-8 byte offsets.
/// Imported units can themselves begin/end mid-paragraph; this manifest makes no semantic-boundary claim.
public struct ReadingParagraph: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var unitID: String
    public var unitHash: String
    public var order: Int
    public var utf8Start: Int
    public var utf8End: Int
    public var lineStart: Int
    public var lineEnd: Int
    public var textHash: String
    public var text: String
    public var kind: String
    public var startQuote: String { String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24)) }
    public var endQuote: String { String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(24)) }
}

public struct ParagraphReceipt: Codable, Identifiable, Hashable, Sendable {
    public var id: String { paragraphID }
    public var paragraphID: String
    public var unitID: String
    public var unitHash: String
    public var textHash: String
    public var utf8Start: Int
    public var utf8End: Int
    public var summary: String
    public var startQuote: String
    public var endQuote: String
    public var issues: [String]
    public var createdAt: Date
}

public struct ReadingReceiptBatch: Codable, Hashable, Sendable {
    public var id: String
    public var unitID: String
    public var unitHash: String
    public var paragraphIDs: [String]
}

public struct ReadingStepRequirement: Codable, Identifiable, Hashable, Sendable {
    public var id: String { stepID }
    public var stepID: String
    public var unitID: String
    public var methodID: String
    public var methodHash: String
    public var stepIndex: Int
    public var stepText: String
}

public struct ReadingStepResult: Codable, Identifiable, Hashable, Sendable {
    public var id: String { stepID }
    public var stepID: String
    public var unitID: String
    public var methodID: String
    public var methodHash: String
    public var stepIndex: Int
    public var result: String
    public var paragraphIDs: [String]
    public var createdAt: Date
}

public enum ReadingLedger {
    private static let deferredMessage = "用户保留本单元为待识别，未读取其中内容。"

    public static func isDeferred(unitID: String, in project: BookProject) -> Bool {
        guard let unit = project.units.first(where: { $0.id == unitID }),
              project.coverage[unitID]?.status == .needsReview,
              project.coverage[unitID]?.message == deferredMessage else { return false }
        return project.insights.contains {
            $0.id == "deferred-\(unitID)" && $0.unitIDs == [unitID] &&
            $0.markdown == "【未读取，待识别】\(unit.locator)。该单元尚无可靠文本，不得推断其中的事实。"
        }
    }

    public static func hasReadingAnalysis(unitID: String, in project: BookProject) -> Bool {
        guard !isDeferred(unitID: unitID, in: project) else { return false }
        return project.insights.contains { $0.unitIDs.contains(unitID) && !$0.id.hasPrefix("deferred-") && !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public static func hasStoredWork(unitIDs: Set<String>, in project: BookProject) -> Bool {
        (project.paragraphReceipts ?? []).contains { unitIDs.contains($0.unitID) } ||
        (project.readingStepResults ?? []).contains { unitIDs.contains($0.unitID) } ||
        (project.workflowRuns ?? []).contains { unitIDs.contains($0.unitID) }
    }

    /// Blank separators stay attached to a fragment. Concatenating the manifest texts exactly reproduces unit.text.
    /// Fenced code and display-math blocks remain together; long ordinary blocks are explicitly labelled fragments.
    public static func paragraphs(for unit: SourceUnit, in project: BookProject) throws -> [ReadingParagraph] {
        guard project.units.contains(where: { $0.id == unit.id && $0.text == unit.text }), unit.text.utf8.count <= 2_000_000 else {
            throw ReadingError.invalid("逐段清单来源不存在、已变化或过大。")
        }
        if unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        let unitHash = try digest(unit.text)
        var blocks: [(String, String)] = []
        var pending = "", protectedEnd: String? = nil
        func flush(_ kind: String = "paragraph") {
            guard !pending.isEmpty else { return }
            if kind == "paragraph", pending.count > 1000 {
                var remainder = pending
                while !remainder.isEmpty {
                    let part = String(remainder.prefix(1000))
                    blocks.append((part, "fragment")); remainder.removeFirst(part.count)
                }
            } else { blocks.append((pending, kind)) }
            pending = ""
        }
        // NSString preserves newline byte sequences, including CRLF, unlike a split/join round trip.
        unit.text.enumerateSubstrings(in: unit.text.startIndex..<unit.text.endIndex, options: [.byLines, .substringNotRequired]) { _, range, enclosing, _ in
            let line = String(unit.text[enclosing])
            let content = String(unit.text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let end = protectedEnd {
                pending += line
                if content.hasPrefix(end) { flush(end == "```" || end == "~~~" ? "code" : "math"); protectedEnd = nil }
            } else if content.hasPrefix("```") || content.hasPrefix("~~~") {
                flush(); protectedEnd = String(content.prefix(3)); pending = line
            } else if content == "$$" || content == "\\[" {
                flush(); protectedEnd = content == "$$" ? "$$" : "\\]"; pending = line
            } else {
                if content.hasPrefix("#"), !pending.isEmpty { flush() }
                pending += line
                if content.isEmpty || content.hasPrefix("#") { flush() }
            }
        }
        flush(protectedEnd == nil ? "paragraph" : "unclosed-block")
        var merged: [(String, String)] = [], leadingWhitespace = ""
        for block in blocks {
            if block.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if merged.isEmpty { leadingWhitespace += block.0 }
                else { merged[merged.count - 1].0 += block.0 }
            } else {
                merged.append((leadingWhitespace + block.0, block.1)); leadingWhitespace = ""
            }
        }
        blocks = merged
        // enumerateSubstrings can omit a source consisting only of unusual newline scalars.
        guard blocks.map({ $0.0 }).joined() == unit.text else { throw ReadingError.invalid("逐段范围未精确覆盖原文，停止读取。") }
        var offset = 0, currentLine = unit.lineStart
        return try blocks.enumerated().map { index, block in
            let start = offset, lineStart = currentLine
            offset += block.0.utf8.count
            let newlineCount = block.0.reduce(0) { $0 + ($1.isNewline ? 1 : 0) }
            currentLine += newlineCount
            let endLine = max(lineStart, currentLine - (block.0.last?.isNewline == true ? 1 : 0))
            let hash = try digest(block.0)
            let id = "p-" + (try digest("paragraph-v1\n\(project.sourceHash)\n\(unit.id)\n\(unitHash)\n\(start)\n\(offset)"))
            return ReadingParagraph(id: id, unitID: unit.id, unitHash: unitHash, order: index, utf8Start: start, utf8End: offset, lineStart: lineStart, lineEnd: endLine, textHash: hash, text: block.0, kind: block.1)
        }
    }

    public static func receipts(for unit: SourceUnit, in project: BookProject) throws -> [ParagraphReceipt] {
        let manifest = try paragraphs(for: unit, in: project)
        let byID = Dictionary(uniqueKeysWithValues: manifest.map { ($0.id, $0) })
        var seen = Set<String>(), valid: [ParagraphReceipt] = []
        for receipt in project.paragraphReceipts ?? [] where receipt.unitID == unit.id {
            guard seen.insert(receipt.paragraphID).inserted, let paragraph = byID[receipt.paragraphID],
                  matches(receipt, paragraph: paragraph) else { throw ReadingError.invalid("已保存逐段回执重复、原文变化或锚点不匹配：\(unit.id)") }
            valid.append(receipt)
        }
        return valid.sorted { $0.utf8Start < $1.utf8Start }
    }

    public static func requireComplete(unitIDs: Set<String>, in project: BookProject) throws {
        guard !unitIDs.isEmpty else { throw ReadingError.invalid("知识抽取没有获准原文单元。") }
        for id in unitIDs {
            guard let unit = project.units.first(where: { $0.id == id }), !unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReadingError.invalid("空白/未识别单元不能用AI回执冒充已读。") }
            let manifest = try paragraphs(for: unit, in: project), saved = try receipts(for: unit, in: project)
            guard !manifest.isEmpty, Set(manifest.map(\.id)) == Set(saved.map(\.paragraphID)) else { throw ReadingError.invalid("当前单元逐段回执未齐，不能抽取知识或完成阅读：\(id)") }
        }
    }

    public static func stepRequirements(for unit: SourceUnit, in project: BookProject,
                                         registry: ReadingWorkflowActionRegistry? = nil) throws -> [ReadingStepRequirement] {
        guard let plan = project.plan, !plan.methodIDs.isEmpty, Set(plan.methodIDs).count == plan.methodIDs.count else { throw ReadingError.invalid("读书方案缺失或重复。") }
        let unitHash = try digest(unit.text)
        var requirements: [ReadingStepRequirement] = []
        for methodID in plan.methodIDs {
            guard let method = project.methods.first(where: { $0.id == methodID }), !method.steps.isEmpty else { throw ReadingError.invalid("读书法缺失或没有步骤。") }
            try ReadingWorkflowRuntime.validate(method: method, registry: registry)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let methodHash = try BookImporter.sha256(encoder.encode(method))
            for (index, text) in method.steps.enumerated() {
                let stepID = "s-" + (try digest("step-v1\n\(unit.id)\n\(unitHash)\n\(methodHash)\n\(index)"))
                requirements.append(ReadingStepRequirement(stepID: stepID, unitID: unit.id, methodID: methodID, methodHash: methodHash, stepIndex: index, stepText: text))
            }
        }
        return requirements
    }

    public static func makeBatch(unit: SourceUnit, paragraphs: [ReadingParagraph]) throws -> ReadingReceiptBatch {
        guard !paragraphs.isEmpty, paragraphs.count <= 24, paragraphs.allSatisfy({ $0.unitID == unit.id }) else { throw ReadingError.invalid("逐段回执批次无效。") }
        let hash = try digest(unit.text), ids = paragraphs.map(\.id)
        return ReadingReceiptBatch(id: "b-" + (try digest(hash + "\n" + ids.joined(separator: "\n"))), unitID: unit.id, unitHash: hash, paragraphIDs: ids)
    }

    /// Storage/import validation is deliberately independent from the completion gate: old projects may have no ledger.
    public static func validateStoredRecords(in project: BookProject) throws {
        let unitIDs = Set(project.units.map(\.id))
        let records = project.paragraphReceipts ?? [], steps = project.readingStepResults ?? []
        guard Set(records.map(\.paragraphID)).count == records.count, Set(steps.map(\.stepID)).count == steps.count,
              records.allSatisfy({ unitIDs.contains($0.unitID) }), steps.allSatisfy({ unitIDs.contains($0.unitID) }) else { throw ReadingError.invalid("逐段账本有重复标识或不存在的源单元。") }
        let byUnit = Dictionary(grouping: records, by: \.unitID), stepsByUnit = Dictionary(grouping: steps, by: \.unitID)
        let unitsByID = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let touched = Set(byUnit.keys).union(stepsByUnit.keys)
        for id in touched {
            guard let unit = unitsByID[id] else { throw ReadingError.invalid("账本原文单元不存在。") }
            var scoped = project
            scoped.units = [unit]; scoped.paragraphReceipts = byUnit[id] ?? []
            let saved = try receipts(for: unit, in: scoped), available = Set(saved.map(\.paragraphID))
            var methodCache: [String: [ReadingStepRequirement]] = [:]
            for step in stepsByUnit[id] ?? [] {
                let requirements: [ReadingStepRequirement]
                if let cached = methodCache[step.methodID] { requirements = cached }
                else {
                    scoped.plan = ReadingPlan(methodIDs: [step.methodID], rationale: "验证历史步骤", focus: [])
                    requirements = try stepRequirements(for: unit, in: scoped)
                    methodCache[step.methodID] = requirements
                }
                guard requirements.contains(where: { $0.stepID == step.stepID && $0.methodHash == step.methodHash && $0.stepIndex == step.stepIndex }),
                      !step.result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, step.result.count <= 2000,
                      !step.paragraphIDs.isEmpty, Set(step.paragraphIDs).count == step.paragraphIDs.count,
                      Set(step.paragraphIDs).isSubset(of: available) else { throw ReadingError.invalid("读书法步骤账本的哈希、结果或片段引用无效。") }
            }
        }
        if let batch = project.receiptBatch {
            guard let unit = project.units.first(where: { $0.id == batch.unitID }) else { throw ReadingError.invalid("阅读批次来源不存在。") }
            let manifest = try paragraphs(for: unit, in: project).filter { batch.paragraphIDs.contains($0.id) }
            guard try makeBatch(unit: unit, paragraphs: manifest) == batch else { throw ReadingError.invalid("保存的阅读批次与原文不匹配。") }
        }
        try ReadingWorkflowRuntime.validateStoredRecords(in: project)
    }

    static func matches(_ receipt: ParagraphReceipt, paragraph: ReadingParagraph) -> Bool {
        receipt.unitID == paragraph.unitID && receipt.unitHash == paragraph.unitHash && receipt.textHash == paragraph.textHash && receipt.utf8Start == paragraph.utf8Start && receipt.utf8End == paragraph.utf8End && receipt.startQuote == paragraph.startQuote && receipt.endQuote == paragraph.endQuote && !receipt.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && receipt.summary.count <= 1200 && receipt.issues.count <= 12 && receipt.issues.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 400 }
    }

    private static func digest(_ text: String) throws -> String { try BookImporter.sha256(Data(text.utf8)) }
}
