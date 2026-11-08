import Foundation
import CoreFoundation

/// A query boundary, not a relevance hint. Extra notes/layout are explicit host capabilities.
public enum ReadingQueryScope: String, Codable, CaseIterable, Hashable, Sendable {
    case selection, page, readSoFar, chapter, range, book, notes
    public var title: String {
        switch self { case .selection: return "选中内容"; case .page: return "当前页"; case .readSoFar: return "读到这里"; case .chapter: return "当前章节"; case .range: return "指定范围"; case .book: return "全书原文"; case .notes: return "我的笔记" }
    }
}

public typealias ReadingDocumentLoader = @Sendable (DocumentRecord) async throws -> String

struct QuerySourceSlice: Hashable, Sendable {
    let unitID: String
    let locator: String
    let chapter: String
    let text: String
    let textHash: String
    var sourceRange: ReadingSourceRange? = nil
    var canonicalTextHash: String? = nil
}

public struct ReadingQuerySnapshot: Sendable {
    public let scope: ReadingQueryScope
    public let bookID: String
    public let sourceHash: String
    public let scopeFingerprint: String
    public let displayTitle: String
    /// Physical layout identities explicitly shared by the host, never inferred from visibility.
    public let authorizedNodeIDs: [String]
    public var unitIDs: [String] { sources.map(\.unitID) }
    public var documentIDs: [String] { documents.map(\.id) }
    let sources: [QuerySourceSlice]
    let documents: [DocumentRecord]
    private let sourceByID: [String: QuerySourceSlice]
    public func admits(_ evidence: Evidence) -> Bool {
        guard !evidence.quote.isEmpty, let source = sourceByID[evidence.unitID],
              let range = source.text.range(of: evidence.quote, options: .literal) else { return false }
        return source.text[range].utf8.elementsEqual(evidence.quote.utf8)
    }

    /// Exact, disposable reader projection. A unit shared by two chapters
    /// does not grant its other text merely because its ID is in the scope.
    public func sourceRanges(in project: BookProject, unitIDs: Set<String>? = nil) throws -> [ReadingSourceRange] {
        guard project.id == bookID, project.sourceHash == sourceHash else { throw ReadingError.invalid("提问范围属于其他原书。") }
        guard unitIDs?.allSatisfy({ sourceByID[$0] != nil }) ?? true else { throw ReadingError.invalid("原文不属于已冻结的提问范围。") }
        let units = Dictionary(grouping: project.units, by: \.id)
        return try sources.filter { unitIDs?.contains($0.unitID) ?? true }.compactMap { source in
            try Task.checkCancellation()
            guard let matches = units[source.unitID], matches.count == 1, let unit = matches.first else { throw ReadingError.invalid("提问原文单元不存在或身份重复。") }
            if unit.text.isEmpty, source.text.isEmpty { return nil }
            let range = source.sourceRange ?? ReadingSourceRange(unitID: unit.id, startUTF16: 0, endUTF16: (unit.text as NSString).length)
            guard try range.text(in: unit).utf8.elementsEqual(source.text.utf8),
                  source.canonicalTextHash.map({ $0 == (try? BookImporter.sha256(Data(unit.text.utf8))) }) ?? true else {
                throw ReadingError.invalid("提问原文已变化，请重新选择范围。")
            }
            return range
        }
    }
    public func scopedSourceUnits(in project: BookProject) throws -> [SourceUnit] {
        let ranges = try sourceRanges(in: project)
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let byID = Dictionary(uniqueKeysWithValues: ranges.map { ($0.unitID, $0) })
        return try sources.map { source in
            guard var unit = units[source.unitID] else { throw ReadingError.invalid("提问原文不存在。") }
            if let range = byID[source.unitID] { unit.text = try range.text(in: unit) }
            else { guard source.text.isEmpty, unit.text.isEmpty else { throw ReadingError.invalid("提问原文范围不存在。") } }
            unit.chapter = source.chapter
            return unit
        }
    }
    /// Reuse one canonical unit resolver for all anchors of a frozen scope.
    /// Equal quotations elsewhere in a shared unit are not the same position.
    public func anchorAdmitter(in project: BookProject) throws -> (SourceAnchor) -> Bool {
        let ranges = Dictionary(grouping: try sourceRanges(in: project), by: \.unitID)
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var resolvers: [String: (SourceAnchor) throws -> ResolvedSourceAnchor] = [:]
        var failed = Set<String>()
        return { anchor in
            guard !Task.isCancelled, let allowed = ranges[anchor.unitID], !failed.contains(anchor.unitID),
                  anchor.sourceHash == project.sourceHash, let unit = units[anchor.unitID] else { return false }
            if resolvers[unit.id] == nil {
                let local = BookProject(id: project.id, title: project.title, originalName: project.originalName, sourceHash: project.sourceHash, units: [unit])
                guard let resolve = try? ReadingExperienceRuntime.anchorResolver(sourceHash: project.sourceHash, unitID: unit.id, in: local) else {
                    failed.insert(unit.id); return false
                }
                resolvers[unit.id] = resolve
            }
            guard let resolve = resolvers[unit.id], let position = try? resolve(anchor) else { return false }
            return allowed.contains { position.utf16Location >= $0.startUTF16 && position.utf16Location <= $0.endUTF16 &&
                position.utf16Length <= $0.endUTF16 - position.utf16Location }
        }
    }
    /// Legacy facts carry only a quotation, without its occurrence offset.
    /// A repeated name outside this excerpt cannot prove which occurrence
    /// supplied an old aggregate summary. Keep its identity, withhold that prose.
    public func savedEvidenceAdmitter(in project: BookProject) throws -> (Evidence) -> Bool {
        try Self.savedEvidenceAdmitter(in: project, ranges: sourceRanges(in: project))
    }
    public static func savedEvidenceAdmitter(in project: BookProject, ranges: [ReadingSourceRange]) throws -> (Evidence) -> Bool {
        let grouped = Dictionary(grouping: ranges, by: \.unitID)
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for range in ranges {
            try Task.checkCancellation()
            guard let unit = units[range.unitID] else { throw ReadingError.invalid("原文证据的章节范围不存在。") }
            try range.validate(in: unit)
        }
        struct Key: Hashable { var unitID: String; var quote: Data }
        var checked: [Key: Bool] = [:]
        return { evidence in
            let key = Key(unitID: evidence.unitID, quote: Data(evidence.quote.utf8))
            if let previous = checked[key] { return previous }
            guard !Task.isCancelled, !evidence.quote.isEmpty, let unit = units[evidence.unitID], let granted = grouped[evidence.unitID] else {
                checked[key] = false; return false
            }
            let source = unit.text as NSString
            if granted.count == 1, granted[0].startUTF16 == 0, granted[0].endUTF16 == source.length {
                let valid = SourceTextLiteral.contains(evidence.quote, in: unit.text)
                checked[key] = valid; return valid
            }
            var search = NSRange(location: 0, length: source.length), seen = false
            while search.length > 0 {
                if Task.isCancelled { return false }
                let found = source.range(of: evidence.quote, options: [.literal], range: search)
                if found.location == NSNotFound { break }
                seen = true
                var frontier = found.location
                for range in granted where range.endUTF16 > frontier {
                    if range.startUTF16 > frontier { break }
                    frontier = max(frontier, range.endUTF16)
                    if frontier >= NSMaxRange(found) { break }
                }
                guard frontier >= NSMaxRange(found) else { checked[key] = false; return false }
                let next = found.location + 1
                search = NSRange(location: next, length: max(0, source.length - next))
            }
            checked[key] = seen; return seen
        }
    }

    /// Derive once from a freshly frozen scope. The visible data capabilities
    /// stay identical; only derived conversation-memory identity changes.
    public func withContextIdentity(_ identity: String) throws -> ReadingQuerySnapshot {
        guard !identity.isEmpty, identity.utf8.count <= 160 else { throw ReadingError.invalid("对话模式标识无效。") }
        let payload = ["scope": scopeFingerprint, "conversation": identity, "version": "1"]
        let fingerprint = try BookImporter.sha256(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        return ReadingQuerySnapshot(scope: scope, bookID: bookID, sourceHash: sourceHash,
            scopeFingerprint: fingerprint, displayTitle: displayTitle, authorizedNodeIDs: authorizedNodeIDs,
            sources: sources, documents: documents, sourceByID: sourceByID)
    }

    /// Local presentation may include already saved, source-bound documents.
    /// This derived snapshot is never returned as a model or write grant.
    func componentSnapshot(in project: BookProject) throws -> ReadingQuerySnapshot {
        _ = try sourceRanges(in: project)
        let explicit = Set(documentIDs)
        let visible = project.activeDocuments.filter { document in
            explicit.contains(document.id) || scope == .book ||
                (!document.evidence.isEmpty && document.evidence.allSatisfy(admits))
        }
        return ReadingQuerySnapshot(scope: scope, bookID: bookID, sourceHash: sourceHash,
            scopeFingerprint: scopeFingerprint, displayTitle: displayTitle, authorizedNodeIDs: [],
            sources: sources, documents: visible, sourceByID: sourceByID)
    }

    public static func freeze(scope: ReadingQueryScope, in project: BookProject, context suppliedContext: ReadingContext? = nil,
                              documentIDs: [String]? = nil, appendedDocumentIDs: [String] = [],
                              authorizedNodeIDs: [String] = []) throws -> ReadingQuerySnapshot {
        try Task.checkCancellation()
        if let sourceHash = suppliedContext?.sourceHash, sourceHash != project.sourceHash { throw ReadingError.invalid("提问范围属于其他原书版本。") }
        let context: ReadingContext?
        if scope == .selection { context = suppliedContext }
        else { context = try suppliedContext.map { try ReadingExperienceRuntime.validatedContext($0, in: project) } }
        // A notes-only question does not use source ordering. In particular,
        // opening a short note must not sort a very large book first.
        let ordered = scope == .notes ? [] : project.units.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        let current = context.flatMap { value in value.unitID.flatMap { id in ordered.first { $0.id == id } } }
        var units: [SourceUnit] = [], documents: [DocumentRecord] = []
        var selectedSlices: [QuerySourceSlice]?
        var chapterRanges: [ReadingSourceRange]?
        var title = scope.title
        switch scope {
        case .selection:
            guard let context, let quote = context.selectedText, !quote.isEmpty else { throw ReadingError.invalid("请先选中一段原文，再使用选中内容范围。") }
            selectedSlices = try selectionSlices(quote: quote, context: context, project: project, ordered: ordered)
            title += " · \(selectedSlices?.count ?? 0) 单元的选段"
        case .page:
            guard let current else { throw ReadingError.invalid("请先打开原文页，再使用当前页范围。") }
            units = current.page.map { page in ordered.filter { $0.page == page } } ?? [current]
            title += " · " + current.locator
        case .readSoFar:
            guard let current, let last = ordered.lastIndex(where: { unit in current.page.map { unit.page == $0 } == true || unit.id == current.id }) else {
                throw ReadingError.invalid("请先打开原文，再选择读到这里。")
            }
            units = Array(ordered[...last])
            title += " · 从开头至" + current.locator + "（含当前页）"
        case .chapter:
            guard let current else { throw ReadingError.invalid("请先打开原文，再使用当前章节范围。") }
            let chapter: BookChapterRange
            if let index = try BookChapterRuntime.index(in: project) {
                let anchor = context?.selectedSourceAnchor ?? context?.selectedAnchorID.flatMap { id in project.readingExperience?.anchors.first { $0.id == id } }
                let offset = try anchor.map { try ReadingExperienceRuntime.resolve($0, in: project).range.location }
                chapter = try index.chapter(unitID: current.id, offsetUTF16: offset)
            } else if let legacy = try BookChapterRuntime.legacyChapter(in: project, unitID: current.id) { chapter = legacy }
            else { throw ReadingError.invalid("还没有可信的章节范围，请先在目录中整理章节，或选择当前页。") }
            guard chapter.isComplete else { throw ReadingError.invalid("这一章的结尾尚未确定，请继续整理目录，或选择当前页。") }
            let byID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
            chapterRanges = chapter.ranges
            selectedSlices = try chapter.ranges.map { range in
                try Task.checkCancellation()
                guard let unit = byID[range.unitID] else { throw ReadingError.invalid("章节原文位置不存在。") }
                let text = try range.text(in: unit)
                return QuerySourceSlice(unitID: unit.id, locator: unit.locator, chapter: chapter.title, text: text,
                    textHash: try BookImporter.sha256(Data(text.utf8)), sourceRange: range,
                    canonicalTextHash: try BookImporter.sha256(Data(unit.text.utf8)))
            }
            title += " · " + chapter.title
        case .range:
            guard let choice = context?.queryRange else { throw ReadingError.invalid("请先选择本次提问的起止页码或章节。") }
            let selected = try choice.resolve(in: project)
            let byID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            chapterRanges = selected.ranges
            selectedSlices = try selected.ranges.map { range in
                try Task.checkCancellation()
                guard let unit = byID[range.unitID] else { throw ReadingError.invalid("所选范围的原文不存在。") }
                let text = try range.text(in: unit)
                return QuerySourceSlice(unitID: unit.id, locator: unit.locator, chapter: unit.chapter, text: text,
                    textHash: try BookImporter.sha256(Data(text.utf8)), sourceRange: range,
                    canonicalTextHash: try BookImporter.sha256(Data(unit.text.utf8)))
            }
            title += " · " + selected.title
        case .book: units = ordered
        case .notes:
            let active = project.activeDocuments
            if let documentIDs {
                let allowed = Set(documentIDs)
                guard allowed.count == documentIDs.count, allowed.isSubset(of: Set(active.map(\.id))) else { throw ReadingError.invalid("笔记范围包含重复、已删除或不存在的文档。") }
                documents = active.filter { allowed.contains($0.id) }
            } else { documents = active }
            title += " · \(documents.count) 篇"
        }
        let appended = Set(appendedDocumentIDs)
        guard appendedDocumentIDs.count <= 1024, appended.count == appendedDocumentIDs.count else { throw ReadingError.invalid("附加笔记包含重复、已删除或不存在的文档，或超过范围上限。") }
        if !appended.isEmpty {
            let active = project.activeDocuments
            guard appended.isSubset(of: Set(active.map(\.id))) else { throw ReadingError.invalid("附加笔记包含重复、已删除或不存在的文档，或超过范围上限。") }
            if scope != .notes {
                documents = active.filter { appended.contains($0.id) }
                title += " · 附加 \(documents.count) 篇笔记"
            }
        }
        let layoutIDs = Set(authorizedNodeIDs)
        guard authorizedNodeIDs.count <= 1024, layoutIDs.count == authorizedNodeIDs.count else { throw ReadingError.invalid("附加布局必须是当前书中真实、无重复的物理节点，且不超过1024个。") }
        if !layoutIDs.isEmpty {
            guard layoutIDs.isSubset(of: Set(project.nodes.map(\.id))) else { throw ReadingError.invalid("附加布局必须是当前书中真实、无重复的物理节点，且不超过1024个。") }
        }
        let sortedLayoutIDs = layoutIDs.sorted()
        if !sortedLayoutIDs.isEmpty { title += " · 附加 \(sortedLayoutIDs.count) 个布局节点" }
        let sources = try selectedSlices ?? units.map { unit in
            try Task.checkCancellation()
            let text = unit.text
            return QuerySourceSlice(unitID: unit.id, locator: unit.locator, chapter: unit.chapter, text: text,
                                    textHash: try BookImporter.sha256(Data(text.utf8)))
        }
        try Task.checkCancellation()
        guard Set(sources.map(\.unitID)).count == sources.count else { throw ReadingError.invalid("原文单元身份重复，不能建立可靠查询范围。") }
        var payload: [String: Any] = ["scope": scope.rawValue, "bookID": project.id, "sourceHash": project.sourceHash,
            "sources": sources.map { ["id": $0.unitID, "hash": $0.textHash] },
            "documents": documents.map { ["id": $0.id, "updatedAt": String($0.updatedAt.timeIntervalSince1970), "path": $0.relativePath] },
            "authorizedNodeIDs": sortedLayoutIDs]
        if let chapterRanges {
            payload["chapterRanges"] = chapterRanges.map { ["id": $0.unitID, "start": $0.startUTF16, "end": $0.endUTF16] as [String: Any] }
        }
        if scope == .selection {
            payload["selectionRanges"] = sources.compactMap(\.sourceRange).map { ["id": $0.unitID, "start": $0.startUTF16, "end": $0.endUTF16] as [String: Any] }
        }
        let fingerprint = try BookImporter.sha256(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        try Task.checkCancellation()
        return ReadingQuerySnapshot(scope: scope, bookID: project.id, sourceHash: project.sourceHash,
            scopeFingerprint: fingerprint, displayTitle: title, authorizedNodeIDs: sortedLayoutIDs, sources: sources, documents: documents,
            sourceByID: Dictionary(uniqueKeysWithValues: sources.map { ($0.unitID, $0) }))
    }

    private static func selectionSlices(quote: String, context: ReadingContext, project: BookProject, ordered: [SourceUnit]) throws -> [QuerySourceSlice] {
        try Task.checkCancellation()
        guard quote.utf8.count <= 400_000 else { throw ReadingError.invalid("选段过长，请缩小选择或改用章节范围。") }
        // Inline sentence anchors retain up to 1024 UTF-8 bytes on each side.
        // The query boundary must accept that same bounded, literal context;
        // a lower limit makes normal mid-page hover conversations unsendable.
        guard (context.selectedPrefix?.utf8.count ?? 0) <= 1_024, (context.selectedSuffix?.utf8.count ?? 0) <= 1_024 else { throw ReadingError.invalid("选段定位前后文过长，请重新选择。") }
        if context.selectedSourceAnchor != nil {
            // A card knows the exact source unit and literal range. A page-wide
            // re-search can incorrectly reject identical sentences in another
            // unit on the same page. Only this full, revalidated anchor proof
            // may bypass that search; ordinary native drags retain it below.
            let validated = try ReadingExperienceRuntime.validatedContext(context, in: project)
            guard let anchor = validated.selectedSourceAnchor,
                  let unit = ordered.first(where: { $0.id == anchor.unitID }),
                  quote.utf8.elementsEqual(anchor.quote.utf8) else { throw ReadingError.invalid("原句锚点与提问范围不一致。") }
            try Task.checkCancellation()
            let resolved = try ReadingExperienceRuntime.resolve(anchor, in: project)
            return [QuerySourceSlice(unitID: unit.id, locator: unit.locator, chapter: unit.chapter,
                text: anchor.quote, textHash: try BookImporter.sha256(Data(anchor.quote.utf8)),
                sourceRange: ReadingSourceRange(unitID: unit.id, startUTF16: resolved.range.location, endUTF16: NSMaxRange(resolved.range)),
                canonicalTextHash: try BookImporter.sha256(Data(unit.text.utf8)))]
        }
        if context.selectedAnchorID != nil {
            _ = try ReadingExperienceRuntime.validatedContext(context, in: project)
        }
        let candidates: [SourceUnit]
        if let first = context.page {
            let last = context.selectionEndPage ?? first
            guard first >= 1, last >= first, last - first < 128,
                  ordered.contains(where: { $0.page == first }), ordered.contains(where: { $0.page == last }) else { throw ReadingError.invalid("选段起止页不存在或范围过大；请改用当前页或章节范围。") }
            candidates = ordered.filter { $0.page.map { $0 >= first && $0 <= last } ?? false }
        } else if let id = context.unitID, let unit = ordered.first(where: { $0.id == id }) { candidates = [unit] }
        else { throw ReadingError.invalid("选段缺少可靠的原文位置；请改用当前页或章节范围。") }
        guard candidates.count <= 256, candidates.reduce(0, { $0 + $1.text.utf8.count }) <= 2_097_152 else { throw ReadingError.invalid("选段定位范围过大，请改用章节范围。") }
        var matches: [String: [QuerySourceSlice]] = [:]
        let prefix = context.selectedPrefix ?? "", suffix = context.selectedSuffix ?? ""
        let prefixLength = (prefix as NSString).length, suffixLength = (suffix as NSString).length
        // The importer separates units/pages. Only these explicit boundaries may
        // be rejoined; never normalize whitespace or substitute OCR characters.
        for separator in ["\n", ""] {
            try Task.checkCancellation()
            var joined = "", ranges: [(SourceUnit, NSRange)] = []
            for (index, unit) in candidates.enumerated() {
                try Task.checkCancellation()
                if index > 0 { joined += separator }
                let start = (joined as NSString).length
                joined += unit.text; ranges.append((unit, NSRange(location: start, length: (unit.text as NSString).length)))
            }
            let source = joined as NSString
            var search = NSRange(location: 0, length: source.length)
            while search.length > 0 {
                try Task.checkCancellation()
                let found = source.range(of: quote, options: [.literal], range: search)
                if found.location == NSNotFound { break }
                let prefixMatches = found.location >= prefixLength && source.substring(with: NSRange(location: found.location - prefixLength, length: prefixLength)).utf8.elementsEqual(prefix.utf8)
                let suffixMatches = source.length - NSMaxRange(found) >= suffixLength && source.substring(with: NSRange(location: NSMaxRange(found), length: suffixLength)).utf8.elementsEqual(suffix.utf8)
                if prefixMatches && suffixMatches {
                    var slices: [QuerySourceSlice] = [], identities: [String] = []
                    for (unit, range) in ranges {
                        try Task.checkCancellation()
                        let intersection = NSIntersectionRange(found, range)
                        if intersection.length > 0 {
                            let text = source.substring(with: intersection)
                            slices.append(QuerySourceSlice(unitID: unit.id, locator: unit.locator, chapter: unit.chapter, text: text, textHash: try BookImporter.sha256(Data(text.utf8)),
                                sourceRange: ReadingSourceRange(unitID: unit.id, startUTF16: intersection.location - range.location, endUTF16: NSMaxRange(intersection) - range.location),
                                canonicalTextHash: try BookImporter.sha256(Data(unit.text.utf8))))
                            identities.append("\(unit.id):\(intersection.location - range.location):\(intersection.length)")
                        }
                    }
                    if !slices.isEmpty { matches[identities.joined(separator: "|")] = slices }
                    if matches.count > 1 { throw ReadingError.invalid("选段在当前原文中有多处相同匹配，请扩大选区以消歧，或改用当前页/章节范围。") }
                }
                let next = found.location + 1
                search = NSRange(location: next, length: max(0, source.length - next))
            }
        }
        try Task.checkCancellation()
        guard matches.count == 1, let slices = matches.values.first else { throw ReadingError.invalid("无法在原文中唯一、精确定位这段选区（可能跨页、重复或OCR文字不同）；请改用当前页/章节范围，未扩大到其他内容。") }
        return slices
    }
}

public struct ReadingAnswerDiagnostics: Sendable {
    public var disclosure: String
    public var notices: [String]
    public var toolCalls: Int
    public var sourceReadIDs: [String]
    public var documentReadIDs: [String]
    public var awaitingReview: Bool = false
}

public struct ReadingAnswerResult: Sendable {
    public var message: ChatMessage
    public var memory: ConversationMemory?
    public var scope: ReadingQuerySnapshot
    public var diagnostics: ReadingAnswerDiagnostics
}

/// Shared conservative estimator: ProviderClient also budgets UTF-8 transport bytes.
enum QueryBudget {
    /// One question freezes its model and tool catalogue. JSON encodes the
    /// messages array independently of its enclosing object, so replacing the
    /// empty [] contributes exactly its encoded size minus two bytes. Keep the
    /// provider's existing upper estimate and validate the real request later.
    struct Envelope {
        private let withoutTools: Int
        private let withTools: Int
        init(tools: [[String: Any]], model: String) throws {
            withoutTools = try QueryBudget.inputBytes([], tools: [], model: model) - 2
            withTools = try QueryBudget.inputBytes([], tools: tools, model: model) - 2
        }
        func inputBytes(_ messages: [[String: Any]], includingTools: Bool = true) throws -> Int {
            guard JSONSerialization.isValidJSONObject(messages) else { throw ReadingError.invalid("模型消息包含无法编码的JSON值，未发送请求。") }
            return try JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys]).count + (includingTools ? withTools : withoutTools)
        }
    }
    static func inputBytes(_ messages: [[String: Any]], tools: [[String: Any]], model: String = "") throws -> Int {
        // Same body fields and byte-based upper estimate as ProviderClient.
        // Use the longer output key and largest legal numeral conservatively.
        var body: [String: Any] = ["model": model.trimmingCharacters(in: .whitespacesAndNewlines), "messages": messages,
            "stream": false, "n": 1, "max_completion_tokens": 1_048_576]
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto" }
        guard JSONSerialization.isValidJSONObject(body) else { throw ReadingError.invalid("模型消息或工具声明包含无法编码的JSON值，未发送请求。") }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]).count + 256
    }
    static func fitHistory(_ history: [ChatMessage], maximumBytes: Int) -> [[String: Any]] {
        var result: [[String: Any]] = [], used = 0
        for message in history.reversed() where ["user", "assistant"].contains(message.role) && !message.content.isEmpty {
            let value: [String: Any] = ["role": message.role, "content": message.content]
            let bytes = (try? JSONSerialization.data(withJSONObject: value).count) ?? Int.max
            guard bytes <= max(0, maximumBytes - used) else { break }
            result.append(value); used += bytes
        }
        return Array(result.reversed())
    }
    static func propagateControl(_ error: Error) throws {
        try Task.checkCancellation()
        if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
        if let pause = error as? ReadingWorkflowBudgetPause { throw pause }
    }
}

/// Read-only session. Source/document capability lists are frozen before the model runs.
/// Neither a tool argument nor a historical message can widen them or advance coverage.
struct ReadingQuerySession {
    let snapshot: ReadingQuerySnapshot
    let history: [ChatMessage]
    let loader: ReadingDocumentLoader?
    let providedDocuments: [String: String]
    var project: BookProject?
    var workspace: ReadingWorkspaceSnapshot?
    let hostTools: ReadingHostToolAccess?
    let proposalAccess: ReadingProposalToolAccess?
    /// Host-only authority. A .book snapshot over a pre-cropped component
    /// project is not permission to expose the original canonical identity.
    let allowsFullIdentity: Bool
    /// Host-only rendering/answer preference. Internal component sessions keep
    /// research defaults and cannot opt into teacher context via tool arguments.
    let answerPreferences: ReadingAnswerPreferences
    /// Internal cropped analysis sessions retain a canonical anchor validator;
    /// a full-unit anchor hash cannot be resolved against a copied excerpt.
    let anchorAdmission: ((SourceAnchor) -> Bool)?
    let savedEvidenceAdmission: ((Evidence) -> Bool)?
    var hostReceipts: [String] = []
    var lastComponentReceipt: String?
    var taskCreatedNodeIDs = Set<String>()
    var sourceExcerpts: [(String, String)] = []
    var sourceReferences: [String: Evidence] = [:]
    private var toolReferencedSourceIDs = Set<String>()
    private var sourceWasPreloaded = false
    private var modelRequestedSource = false
    var documentExcerpts: [(String, String)] = []
    var conversationExcerpts: [(String, String)] = []
    var toolCalls = 0
    var hasOnlyPreloadedSources: Bool {
        sourceWasPreloaded && !modelRequestedSource && !sourceExcerpts.isEmpty && documentExcerpts.isEmpty && conversationExcerpts.isEmpty
    }
    mutating func recordSourceExcerpt(_ id: String, text: String) {
        guard !text.isEmpty else { return }
        // Citation obligations reflect an actual read, even when the bytes
        // were already supplied. Cache de-duplication is a separate concern.
        modelRequestedSource = true
        toolReferencedSourceIDs.insert(id)
        guard !sourceExcerpts.contains(where: { $0.0 == id && $0.1.range(of: text, options: .literal) != nil }) else { return }
        sourceExcerpts.append((id, text))
    }
    private var cache: [String: String] = [:]
    var documentHashes: [String: String] = [:]
    private var cachedBytes = 0

    mutating func invalidateReviewedDocumentCache() {
        // Keep hashes/excerpts: a changed note must fail the existing revision
        // check, rather than silently returning a pre-review cached body.
        cache.removeAll(keepingCapacity: true); cachedBytes = 0
    }

    init(snapshot: ReadingQuerySnapshot, history: [ChatMessage], loader: ReadingDocumentLoader?, providedDocuments: [String: String],
         project: BookProject? = nil, workspace: ReadingWorkspaceSnapshot? = nil, hostTools: ReadingHostToolAccess? = nil, proposalAccess: ReadingProposalToolAccess? = nil,
         allowsFullIdentity: Bool = false,
         answerPreferences: ReadingAnswerPreferences = .init(style: .research, avoidsSpoilers: true),
         anchorAdmission: ((SourceAnchor) -> Bool)? = nil,
         savedEvidenceAdmission: ((Evidence) -> Bool)? = nil) {
        self.snapshot = snapshot; self.history = history; self.loader = loader; self.providedDocuments = providedDocuments
        self.project = project; self.workspace = workspace; self.hostTools = hostTools; self.proposalAccess = proposalAccess
        self.allowsFullIdentity = allowsFullIdentity && snapshot.scope == .book
        self.answerPreferences = answerPreferences
        self.anchorAdmission = anchorAdmission
        self.savedEvidenceAdmission = savedEvidenceAdmission
    }

    /// The reader explicitly chose this page/selection. Supply a bounded,
    /// source-labelled excerpt before asking the model, rather than relying on
    /// it to discover and call a read tool before understanding "this page".
    /// An explicit bounded range may be supplied in full if its entire encoded
    /// body fits. Large ranges/book/notes keep on-demand reads; there is no
    /// arbitrary subset masquerading as the chosen range.
    mutating func initialSource(maximumBytes: Int) throws -> String? {
        if snapshot.scope == .range {
            guard maximumBytes >= 512 else { return nil }
            let sourceOrders = Dictionary((project?.units ?? []).map { ($0.id, $0.order) }, uniquingKeysWith: { first, _ in first })
            var rows: [[String: Any]] = [], bytes = try json(["actualReadFragments": [], "hostToolReceipts": []]).utf8.count
            for source in snapshot.sources {
                try Task.checkCancellation()
                guard source.text.utf8.count <= maximumBytes - bytes else { return nil }
                var row: [String: Any] = ["kind": "unit", "id": source.unitID, "hash": source.textHash, "locator": source.locator,
                    "text": source.text, "fragmentTruncated": false, "citation": "[unit:\(source.unitID)]"]
                if let order = sourceOrders[source.unitID] { row["order"] = order }
                if source.text.count <= 32_768 { row["sourceRef"] = try sourceReferenceID(unitID: source.unitID, text: source.text) }
                let added = try json(row).utf8.count + (rows.isEmpty ? 0 : 1)
                guard added <= maximumBytes - bytes else { return nil }
                bytes += added; rows.append(row)
            }
            let full = try json(["actualReadFragments": rows, "hostToolReceipts": []])
            guard full.utf8.count <= maximumBytes else { return nil }
            sourceExcerpts = snapshot.sources.map { ($0.unitID, $0.text) }; sourceWasPreloaded = !sourceExcerpts.isEmpty
            try registerInitialSourceReferences()
            return full
        }
        guard snapshot.scope == .page || snapshot.scope == .selection, maximumBytes >= 512 else { return nil }
        var candidate = self
        candidate.sourceExcerpts = snapshot.sources.prefix(32).reversed().map { ($0.unitID, $0.text) }
        let supplied = try candidate.finalEvidence(maximumBytes: maximumBytes)
        if supplied != nil {
            sourceExcerpts = candidate.sourceExcerpts; sourceWasPreloaded = !sourceExcerpts.isEmpty
            try registerInitialSourceReferences()
        }
        return supplied
    }

    /// Repack only genuinely supplied text for a standalone final request.
    /// Dropped/truncated fragments lose their citation permission as well.
    mutating func finalEvidence(maximumBytes: Int) throws -> String? {
        var receipts = closingHostReceiptSummaries()
        while !receipts.isEmpty {
            if try json(["hostToolReceipts": receipts, "actualReadFragments": []]).utf8.count <= maximumBytes { break }
            receipts.removeFirst()
        }
        func payload(_ rows: [[String: Any]]) -> [String: Any] { ["hostToolReceipts": receipts, "actualReadFragments": rows] }
        var rows: [[String: Any]] = []
        var sources: [(String, String)] = [], documents: [(String, String)] = [], conversation: [(String, String)] = []
        var seen = Set<String>()
        let recentSources = Array(sourceExcerpts.reversed())
        let prioritizedSources = recentSources.filter { toolReferencedSourceIDs.contains($0.0) }
            + recentSources.filter { !toolReferencedSourceIDs.contains($0.0) }
        let all = prioritizedSources.map { ("unit", $0.0, $0.1) }
            + documentExcerpts.reversed().map { ("doc", $0.0, $0.1) }
            + conversationExcerpts.reversed().map { ("message", $0.0, $0.1) }
        let sourceOrders = Dictionary((project?.units ?? []).map { ($0.id, $0.order) }, uniquingKeysWith: { first, _ in first })
        for (kind, id, text) in all {
            try Task.checkCancellation()
            guard seen.insert(kind + ":" + id + ":" + text).inserted else { continue }
            var low = 0, high = text.count
            let hash: String
            if kind == "unit" { hash = snapshot.sources.first { $0.unitID == id }?.textHash ?? "" }
            else if kind == "doc" { hash = documentHashes[id] ?? "" }
            else if let message = history.first(where: { $0.id == id }) { hash = try BookImporter.sha256(Data(message.content.utf8)) }
            else { hash = "" }
            func row(_ length: Int) -> [String: Any] {
                var value: [String: Any] = ["kind": kind, "id": id, "hash": hash, "text": String(text.prefix(length)), "fragmentTruncated": length < text.count, "citation": "[\(kind):\(id)]"]
                if kind == "unit", let order = sourceOrders[id] { value["order"] = order }
                return value
            }
            while low < high {
                let middle = low + (high - low + 1) / 2
                if try json(payload(rows + [row(middle)])).utf8.count <= maximumBytes { low = middle } else { high = middle - 1 }
            }
            guard low > 0 else { continue }
            let retained = String(text.prefix(low)); rows.append(row(low))
            if kind == "unit" { sources.append((id, retained)) }
            else if kind == "doc" { documents.append((id, retained)) }
            else { conversation.append((id, retained)) }
        }
        sourceExcerpts = sources; documentExcerpts = documents; conversationExcerpts = conversation
        return rows.isEmpty && receipts.isEmpty ? nil : try json(payload(rows))
    }

    static var tools: [[String: Any]] {
        let string: [String: Any] = ["type": "string", "maxLength": 400]
        let offset: [String: Any] = ["type": "integer", "minimum": 0]
        func tool(_ name: String, _ description: String, _ fields: [String: Any], _ required: [String] = []) -> [String: Any] {
            ["type": "function", "function": ["name": name, "description": description,
                "parameters": ["type": "object", "additionalProperties": false, "properties": fields, "required": required]]]
        }
        let paging: [String: Any] = ["offset": offset, "limit": ["type": "integer", "minimum": 1, "maximum": 20]]
        var search = paging; search["keywords"] = ["type": "array", "items": string, "minItems": 1, "maxItems": 8]
        search["mode"] = ["type": "string", "enum": ["any", "all"]]
        var documentSearch = search; documentSearch["scanOffset"] = offset
        let reading: [String: Any] = ["id": string, "offset": offset, "length": ["type": "integer", "minimum": 1, "maximum": 12000], "expectedHash": string]
        return [
            tool("source_outline", "仅列当前冻结范围内原文单元索引，并非PDF书签目录；nextOffset分页。索引不代表正文已读。", paging),
            tool("source_search", "检索当前范围原文，自动简繁互搜，1至8关键词any/all；返回有界原文字形和定位，范围外无法读取。", search, ["keywords"]),
            tool("source_read", "按目录id/字符offset分段读取当前范围原文；选段范围只返回选段，按nextOffset续读，不增加阅读覆盖。", reading, ["id"]),
            tool("source_locate", "按已知原文ID查询本范围的页码、章回和实际叙事序号；不重读正文，不增加引用或阅读覆盖。", ["ids": ["type": "array", "items": string, "minItems": 1, "maxItems": 20]], ["ids"]),
            tool("documents_list", "只列本次显式授权的笔记目录；原文范围不会自动附加笔记。目录不是正文。", paging),
            tool("documents_search", "按需检索已授权笔记全文，每批最多32篇，nextScanOffset续查后续文档，offset只在本批命中中分页；笔记不能冒充原书。", documentSearch, ["keywords"]),
            tool("document_read", "按id/offset读取已授权笔记片段，返回内容hash和续读位置，不修改文档。", reading, ["id"]),
            tool("conversation_search", "检索当前会话原始问答，返回消息id/角色/片段；旧AI回答不是原书证据。", search, ["keywords"]),
            tool("conversation_read", "按消息id/offset重读当前会话；不传id分页读消息目录。记忆不是原文。", reading)
        ]
    }

    mutating func execute(name: String, arguments: [String: Any], maximumBytes: Int) async throws -> String {
        let before = (sourceExcerpts.count, documentExcerpts.count, conversationExcerpts.count)
        let requestedBefore = modelRequestedSource
        let result = try await perform(name: name, arguments: arguments, maximumBytes: maximumBytes)
        guard result.utf8.count <= max(400, maximumBytes) else {
            sourceExcerpts.removeSubrange(before.0...); documentExcerpts.removeSubrange(before.1...); conversationExcerpts.removeSubrange(before.2...)
            modelRequestedSource = requestedBefore
            return try json(["ok": false, "budgetLimited": true, "message": "本轮空间不足以返回完整结果，正文未提供给模型。"])
        }
        try recordReturnedEvidence(result)
        if sourceExcerpts.count > before.0 { modelRequestedSource = true }
        return result
    }
    private mutating func perform(name: String, arguments: [String: Any], maximumBytes: Int) async throws -> String {
        try Task.checkCancellation(); toolCalls += 1
        let cap = min(16_000, max(0, maximumBytes))
        guard cap >= 700 else { return try json(["ok": false, "budgetLimited": true, "message": "剩余空间不足，未继续读取；请说明尚未完成范围。"] ) }
        switch name {
        case "source_locate":
            guard let ids = arguments["ids"] as? [String], (1...20).contains(ids.count), Set(ids).count == ids.count,
                  Set(arguments.keys) == ["ids"] else { throw invalid("定位需1至20个不重复的原文ID。") }
            let sources = Dictionary(snapshot.sources.map { ($0.unitID, $0) }, uniquingKeysWith: { first, _ in first })
            let orders = Dictionary((project?.units ?? []).map { ($0.id, $0.order) }, uniquingKeysWith: { first, _ in first })
            var rows: [[String: Any]] = try ids.map { id in
                guard let source = sources[id] else { throw invalid("原文ID不在本次冻结范围内。") }
                var row: [String: Any] = ["id": id, "locator": source.locator, "chapter": source.chapter]
                if let order = orders[id] { row["order"] = order }
                return row
            }
            func result() throws -> String { try json(["ok": true, "locations": rows, "bodyProvided": false, "omittedCount": ids.count - rows.count]) }
            while !rows.isEmpty, try result().utf8.count > cap { rows.removeLast() }
            let value = try result()
            guard value.utf8.count <= cap else { throw invalid("剩余空间不足以返回定位信息。") }
            return value
        case "source_outline", "source_list":
            return try page(snapshot.sources.map { ["id": $0.unitID, "locator": $0.locator, "chapter": $0.chapter, "characters": $0.text.count, "hash": $0.textHash] as [String: Any] }, arguments, cap)
        case "documents_list":
            return try page(snapshot.documents.map { ["id": $0.id, "title": $0.title, "origin": $0.origin] as [String: Any] }, arguments, cap)
        case "source_read":
            let id = try identifier(arguments)
            guard let source = snapshot.sources.first(where: { $0.unitID == id }) else { throw invalid("原文ID不在本次冻结范围内。") }
            try checkHash(arguments, actual: source.textHash)
            let slice = try readSlice(source.text, arguments, cap, metadata: ["ok": true, "id": id, "citation": "[unit:\(id)]", "locator": source.locator, "hash": source.textHash, "scope": snapshot.scope.rawValue])
            recordSourceExcerpt(id, text: slice.text)
            return slice.result
        case "document_read":
            let id = try identifier(arguments)
            guard let document = snapshot.documents.first(where: { $0.id == id }) else { throw invalid("文档ID不在本次授权笔记范围内。") }
            let body = try await load(document)
            try checkHash(arguments, actual: documentHashes[id] ?? "")
            let slice = try readSlice(body, arguments, cap, metadata: ["ok": true, "id": id, "title": document.title, "origin": document.origin, "hash": documentHashes[id] ?? ""])
            if !slice.text.isEmpty { documentExcerpts.append((id, slice.text)) }
            return slice.result
        case "conversation_read":
            if arguments["id"] == nil { return try page(history.map { ["id": $0.id, "role": $0.role, "characters": $0.content.count] as [String: Any] }, arguments, cap) }
            let id = try identifier(arguments)
            guard let message = history.first(where: { $0.id == id }) else { throw invalid("消息不在当前会话内。") }
            try checkHash(arguments, actual: BookImporter.sha256(Data(message.content.utf8)))
            let slice = try readSlice(message.content, arguments, cap, metadata: ["ok": true, "id": id, "role": message.role, "hash": BookImporter.sha256(Data(message.content.utf8))])
            if !slice.text.isEmpty { conversationExcerpts.append((id, slice.text)) }
            return slice.result
        case "source_search", "documents_search", "conversation_search":
            return try await search(name: name, arguments: arguments, cap: cap)
        default: return try await executeExtended(name: name, arguments: arguments, maximumBytes: cap)
        }
    }

    private mutating func load(_ document: DocumentRecord) async throws -> String {
        if let body = cache[document.id] { return body }
        let body: String
        if let provided = providedDocuments[document.id] { body = provided }
        else if let loader { body = try await loader(document) }
        else { throw invalid("宿主未提供该笔记的正文读取权限。") }
        try Task.checkCancellation()
        guard body.utf8.count <= 2 * 1024 * 1024 else { throw invalid("该笔记超过单篇2 MiB读取上限；未把截断内容冒充完整文档。") }
        let hash = try BookImporter.sha256(Data(body.utf8))
        if let old = documentHashes[document.id], old != hash { throw invalid("笔记在本次问答中发生变化，请基于新版本重试。") }
        documentHashes[document.id] = hash
        if cachedBytes + body.utf8.count <= 8 * 1024 * 1024 { cache[document.id] = body; cachedBytes += body.utf8.count }
        return body
    }

    private mutating func search(name: String, arguments: [String: Any], cap: Int) async throws -> String {
        guard let terms = arguments["keywords"] as? [String], (1...8).contains(terms.count),
              terms.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 160 }),
              arguments["mode"] == nil || ["any", "all"].contains(arguments["mode"] as? String ?? "") else { throw invalid("检索需1至8个非空关键词，mode为any/all。") }
        let offset = try number(arguments, "offset", fallback: 0, maximum: Int.max)
        let limit = try number(arguments, "limit", fallback: 8, maximum: 20)
        guard limit > 0 else { throw invalid("limit须为1至20。") }
        let all = arguments["mode"] as? String == "all"
        var hits: [[String: Any]] = [], total = 0, failures = 0, scanned = 0
        var nextScan: Int?, scanStart = 0
        var matcher = try LibraryTextSearch.Matcher(queries: terms)
        func match(_ text: String) throws -> (Int, String)? {
            let matches = try matcher.ranges(in: text)
            guard !matches.isEmpty, !all || matches.count == terms.count,
                  let first = matches.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
            let start = text.index(first.lowerBound, offsetBy: -70, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(start, offsetBy: 320, limitedBy: text.endIndex) ?? text.endIndex
            return (text.distance(from: text.startIndex, to: start), String(text[start..<end]))
        }
        func add(_ id: String, _ text: String, _ metadata: [String: Any]) throws {
            guard let (start, snippet) = try match(text) else { return }
            defer { total += 1 }
            guard total >= offset, hits.count < limit else { return }
            var value = metadata; value["id"] = id; value["offset"] = start; value["snippet"] = snippet
            hits.append(value)
        }
        if name == "source_search" {
            for source in snapshot.sources { try Task.checkCancellation(); try add(source.unitID, source.text, ["locator": source.locator, "hash": source.textHash]) }
        } else if name == "documents_search" {
            scanStart = try number(arguments, "scanOffset", fallback: 0, maximum: snapshot.documents.count)
            let batch = Array(snapshot.documents.dropFirst(scanStart).prefix(32))
            if scanStart + batch.count < snapshot.documents.count { nextScan = scanStart + batch.count }
            for document in batch {
                try Task.checkCancellation()
                do { let text = try await load(document); scanned += 1; try add(document.id, text, ["title": document.title, "origin": document.origin, "hash": documentHashes[document.id] ?? ""]) }
                catch { try QueryBudget.propagateControl(error); failures += 1 }
            }
        } else {
            for message in history { try Task.checkCancellation(); try add(message.id, message.content, ["role": message.role, "hash": try BookImporter.sha256(Data(message.content.utf8))]) }
        }
        while !hits.isEmpty {
            if try json(["hits": hits]).utf8.count <= cap - 450 { break }
            hits.removeLast()
        }
        for hit in hits { if let id = hit["id"] as? String, let text = hit["snippet"] as? String {
            if name == "source_search" { recordSourceExcerpt(id, text: text) }
            else if name == "documents_search" { documentExcerpts.append((id, text)) }
            else { conversationExcerpts.append((id, text)) }
        } }
        let next: Any = !hits.isEmpty && offset + hits.count < total ? offset + hits.count : NSNull()
        return try json(["ok": true, "hits": hits, "totalMatches": total, "nextOffset": next, "unreadableDocuments": failures,
            "scannedDocuments": scanned, "scanOffset": scanStart, "nextScanOffset": nextScan as Any? ?? NSNull(),
            "complete": failures == 0 && nextScan == nil && scanStart == 0, "budgetLimited": hits.isEmpty && offset < total,
            "note": "仅当前范围/当前扫描批次的命中片段，不代表全文已读；后续笔记按nextScanOffset继续检索，不增加覆盖。无法返回完整条目时不提供重复游标。"])
    }

    func page(_ rows: [[String: Any]], _ arguments: [String: Any], _ cap: Int) throws -> String {
        let offset = try number(arguments, "offset", fallback: 0, maximum: rows.count)
        let limit = try number(arguments, "limit", fallback: 12, maximum: 20)
        guard limit > 0 else { throw invalid("limit须为1至20。") }
        var selected = Array(rows.dropFirst(offset).prefix(limit))
        while !selected.isEmpty {
            if try json(["items": selected]).utf8.count <= cap - 250 { break }
            selected.removeLast()
        }
        return try json(["ok": true, "items": selected, "total": rows.count, "nextOffset": !selected.isEmpty && offset + selected.count < rows.count ? (offset + selected.count) as Any : NSNull(),
            "budgetLimited": selected.isEmpty && offset < rows.count, "bodyProvided": false])
    }
    private func readSlice(_ text: String, _ args: [String: Any], _ cap: Int, metadata: [String: Any]) throws -> (text: String, result: String) {
        let offset = try number(args, "offset", fallback: 0, maximum: text.count)
        let length = try number(args, "length", fallback: 3000, maximum: 12000)
        guard length > 0 else { throw invalid("length须为1至12000。") }
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: length, limitedBy: text.endIndex) ?? text.endIndex
        let candidate = String(text[start..<end]), count = candidate.count, total = text.count
        func response(_ size: Int) throws -> (text: String, result: String) {
            let excerpt = String(candidate.prefix(size))
            var row = metadata; row["offset"] = offset; row["totalCharacters"] = total; row["text"] = excerpt
            row["nextOffset"] = offset + size < total ? offset + size as Any : NSNull()
            return (excerpt, try json(row))
        }
        // Measure the complete wire envelope, including metadata, escaping and
        // nextOffset. Never shorten serialized JSON or split a grapheme.
        let full = try response(count)
        if full.result.utf8.count <= cap { return full }
        var low = 0, high = count
        while low < high {
            try Task.checkCancellation()
            let middle = low + (high - low + 1) / 2
            if try response(middle).result.utf8.count <= cap { low = middle } else { high = middle - 1 }
        }
        guard low > 0 || start == text.endIndex else { throw invalid("剩余空间不足以返回完整字符与定位信息，未读取。") }
        let bounded = try response(low)
        guard bounded.result.utf8.count <= cap else { throw invalid("剩余空间不足以返回定位信息，未读取。") }
        return bounded
    }
    func identifier(_ args: [String: Any]) throws -> String {
        guard let id = args["id"] as? String, !id.isEmpty, id.count <= 400 else { throw invalid("请提供合法ID。") }; return id
    }
    func checkHash(_ args: [String: Any], actual: String) throws {
        if let expected = args["expectedHash"] {
            guard let hash = expected as? String, hash == actual else { throw invalid("正文hash与请求版本不同，未返回正文；请重新读取目录。") }
        }
    }
    func number(_ args: [String: Any], _ key: String, fallback: Int, maximum: Int) throws -> Int {
        guard let raw = args[key] else { return fallback }
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, value.doubleValue.rounded(.towardZero) == value.doubleValue,
              value.doubleValue >= 0, value.doubleValue <= Double(min(maximum, Int.max - 1024)) else { throw invalid("\(key)超出范围或不是整数。") }
        return value.intValue
    }
    func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    func invalid(_ message: String) -> ReadingError { .invalid(message) }
}
