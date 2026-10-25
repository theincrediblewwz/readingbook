import Foundation
import CoreFoundation

/// A query boundary, not a relevance hint. Extra notes/layout are explicit host capabilities.
public enum ReadingQueryScope: String, Codable, CaseIterable, Hashable, Sendable {
    case selection, page, chapter, book, notes
    public var title: String {
        switch self { case .selection: return "选中内容"; case .page: return "当前页"; case .chapter: return "当前章节"; case .book: return "全书原文"; case .notes: return "我的笔记" }
    }
}

public typealias ReadingDocumentLoader = @Sendable (DocumentRecord) async throws -> String

struct QuerySourceSlice: Hashable, Sendable {
    let unitID: String
    let locator: String
    let chapter: String
    let text: String
    let textHash: String
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

    public static func freeze(scope: ReadingQueryScope, in project: BookProject, context suppliedContext: ReadingContext? = nil,
                              documentIDs: [String]? = nil, appendedDocumentIDs: [String] = [],
                              authorizedNodeIDs: [String] = []) throws -> ReadingQuerySnapshot {
        if let sourceHash = suppliedContext?.sourceHash, sourceHash != project.sourceHash { throw ReadingError.invalid("提问范围属于其他原书版本。") }
        let context: ReadingContext?
        if scope == .selection { context = suppliedContext }
        else { context = try suppliedContext.map { try ReadingExperienceRuntime.validatedContext($0, in: project) } }
        let ordered = project.units.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        let current = context.flatMap { value in value.unitID.flatMap { id in ordered.first { $0.id == id } } }
        var units: [SourceUnit] = [], documents: [DocumentRecord] = []
        var selectedSlices: [QuerySourceSlice]?
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
        case .chapter:
            guard let current else { throw ReadingError.invalid("请先打开原文，再使用当前章节范围。") }
            units = ordered.filter { $0.chapter == current.chapter }; title += " · " + current.chapter
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
        let appended = Set(appendedDocumentIDs), active = project.activeDocuments
        guard appendedDocumentIDs.count <= 1024, appended.count == appendedDocumentIDs.count,
              appended.isSubset(of: Set(active.map(\.id))) else { throw ReadingError.invalid("附加笔记包含重复、已删除或不存在的文档，或超过范围上限。") }
        if scope != .notes, !appended.isEmpty {
            documents = active.filter { appended.contains($0.id) }
            title += " · 附加 \(documents.count) 篇笔记"
        }
        let layoutIDs = Set(authorizedNodeIDs)
        guard authorizedNodeIDs.count <= 1024, layoutIDs.count == authorizedNodeIDs.count,
              layoutIDs.isSubset(of: Set(project.nodes.map(\.id))) else { throw ReadingError.invalid("附加布局必须是当前书中真实、无重复的物理节点，且不超过1024个。") }
        let sortedLayoutIDs = layoutIDs.sorted()
        if !sortedLayoutIDs.isEmpty { title += " · 附加 \(sortedLayoutIDs.count) 个布局节点" }
        let sources = try selectedSlices ?? units.map { unit in
            let text = unit.text
            return QuerySourceSlice(unitID: unit.id, locator: unit.locator, chapter: unit.chapter, text: text,
                                    textHash: try BookImporter.sha256(Data(text.utf8)))
        }
        guard Set(sources.map(\.unitID)).count == sources.count else { throw ReadingError.invalid("原文单元身份重复，不能建立可靠查询范围。") }
        let payload: [String: Any] = ["scope": scope.rawValue, "bookID": project.id, "sourceHash": project.sourceHash,
            "sources": sources.map { ["id": $0.unitID, "hash": $0.textHash] },
            "documents": documents.map { ["id": $0.id, "updatedAt": String($0.updatedAt.timeIntervalSince1970), "path": $0.relativePath] },
            "authorizedNodeIDs": sortedLayoutIDs]
        let fingerprint = try BookImporter.sha256(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        return ReadingQuerySnapshot(scope: scope, bookID: project.id, sourceHash: project.sourceHash,
            scopeFingerprint: fingerprint, displayTitle: title, authorizedNodeIDs: sortedLayoutIDs, sources: sources, documents: documents,
            sourceByID: Dictionary(uniqueKeysWithValues: sources.map { ($0.unitID, $0) }))
    }

    private static func selectionSlices(quote: String, context: ReadingContext, project: BookProject, ordered: [SourceUnit]) throws -> [QuerySourceSlice] {
        guard quote.utf8.count <= 400_000 else { throw ReadingError.invalid("选段过长，请缩小选择或改用章节范围。") }
        guard (context.selectedPrefix?.utf8.count ?? 0) <= 1000, (context.selectedSuffix?.utf8.count ?? 0) <= 1000 else { throw ReadingError.invalid("选段定位前后文过长，请重新选择。") }
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
        // The importer separates units/pages. Only these explicit boundaries may
        // be rejoined; never normalize whitespace or substitute OCR characters.
        for separator in ["\n", ""] {
            var joined = "", ranges: [(SourceUnit, NSRange)] = []
            for (index, unit) in candidates.enumerated() {
                if index > 0 { joined += separator }
                let start = (joined as NSString).length
                joined += unit.text; ranges.append((unit, NSRange(location: start, length: (unit.text as NSString).length)))
            }
            let source = joined as NSString
            var search = NSRange(location: 0, length: source.length)
            while search.length > 0 {
                let found = source.range(of: quote, options: [.literal], range: search)
                if found.location == NSNotFound { break }
                let prefix = context.selectedPrefix ?? "", suffix = context.selectedSuffix ?? ""
                let prefixLength = (prefix as NSString).length, suffixLength = (suffix as NSString).length
                let prefixMatches = found.location >= prefixLength && source.substring(with: NSRange(location: found.location - prefixLength, length: prefixLength)).utf8.elementsEqual(prefix.utf8)
                let suffixMatches = source.length - NSMaxRange(found) >= suffixLength && source.substring(with: NSRange(location: NSMaxRange(found), length: suffixLength)).utf8.elementsEqual(suffix.utf8)
                if prefixMatches && suffixMatches {
                    var slices: [QuerySourceSlice] = [], identities: [String] = []
                    for (unit, range) in ranges {
                        let intersection = NSIntersectionRange(found, range)
                        if intersection.length > 0 {
                            let text = source.substring(with: intersection)
                            slices.append(QuerySourceSlice(unitID: unit.id, locator: unit.locator, chapter: unit.chapter, text: text, textHash: try BookImporter.sha256(Data(text.utf8))))
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
}

public struct ReadingAnswerResult: Sendable {
    public var message: ChatMessage
    public var memory: ConversationMemory?
    public var scope: ReadingQuerySnapshot
    public var diagnostics: ReadingAnswerDiagnostics
}

/// Shared conservative estimator: ProviderClient also budgets UTF-8 transport bytes.
enum QueryBudget {
    static func inputBytes(_ messages: [[String: Any]], tools: [[String: Any]], model: String = "") throws -> Int {
        // Same body fields and byte-based upper estimate as ProviderClient.
        // Use the longer output key and largest legal numeral conservatively.
        var body: [String: Any] = ["model": model.trimmingCharacters(in: .whitespacesAndNewlines), "messages": messages,
            "stream": false, "n": 1, "max_completion_tokens": 1_048_576]
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto" }
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
    var hostReceipts: [String] = []
    var taskCreatedNodeIDs = Set<String>()
    var sourceExcerpts: [(String, String)] = []
    var documentExcerpts: [(String, String)] = []
    var conversationExcerpts: [(String, String)] = []
    var toolCalls = 0
    private var cache: [String: String] = [:]
    var documentHashes: [String: String] = [:]
    private var cachedBytes = 0

    init(snapshot: ReadingQuerySnapshot, history: [ChatMessage], loader: ReadingDocumentLoader?, providedDocuments: [String: String],
         project: BookProject? = nil, workspace: ReadingWorkspaceSnapshot? = nil, hostTools: ReadingHostToolAccess? = nil, proposalAccess: ReadingProposalToolAccess? = nil) {
        self.snapshot = snapshot; self.history = history; self.loader = loader; self.providedDocuments = providedDocuments
        self.project = project; self.workspace = workspace; self.hostTools = hostTools; self.proposalAccess = proposalAccess
    }

    /// Repack only genuinely supplied text for a standalone final request.
    /// Dropped/truncated fragments lose their citation permission as well.
    mutating func finalEvidence(maximumBytes: Int) throws -> String? {
        var receipts: [[String: Any]] = []
        for value in hostReceipts.suffix(4) {
            guard let original = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { continue }
            var summary: [String: Any] = [:]
            for key in ["status", "message", "summary", "proposalID", "digest", "operationID", "applied", "replayed"] {
                if let string = original[key] as? String { summary[key] = String(string.prefix(300)) }
                else if let values = original[key] as? [String] { summary[key] = values.prefix(4).map { String($0.prefix(120)) } }
                else if let number = original[key] as? NSNumber { summary[key] = number }
            }
            if !summary.isEmpty { receipts.append(summary) }
        }
        while !receipts.isEmpty {
            if try json(["hostToolReceipts": receipts, "actualReadFragments": []]).utf8.count <= maximumBytes { break }
            receipts.removeFirst()
        }
        func payload(_ rows: [[String: Any]]) -> [String: Any] { ["hostToolReceipts": receipts, "actualReadFragments": rows] }
        var rows: [[String: Any]] = []
        var sources: [(String, String)] = [], documents: [(String, String)] = [], conversation: [(String, String)] = []
        var seen = Set<String>()
        let all = sourceExcerpts.reversed().map { ("unit", $0.0, $0.1) }
            + documentExcerpts.reversed().map { ("doc", $0.0, $0.1) }
            + conversationExcerpts.reversed().map { ("message", $0.0, $0.1) }
        for (kind, id, text) in all {
            try Task.checkCancellation()
            guard seen.insert(kind + ":" + id + ":" + text).inserted else { continue }
            var low = 0, high = text.count
            let hash: String
            if kind == "unit" { hash = snapshot.sources.first { $0.unitID == id }?.textHash ?? "" }
            else if kind == "doc" { hash = documentHashes[id] ?? "" }
            else if let message = history.first(where: { $0.id == id }) { hash = try BookImporter.sha256(Data(message.content.utf8)) }
            else { hash = "" }
            func row(_ length: Int) -> [String: Any] { ["kind": kind, "id": id, "hash": hash, "text": String(text.prefix(length)), "fragmentTruncated": length < text.count] }
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
            tool("source_outline", "仅列当前冻结范围内原文目录；nextOffset分页。目录不代表正文已读。", paging),
            tool("source_search", "检索当前范围原文，1至8关键词any/all；返回有界实际片段和定位，范围外无法读取。", search, ["keywords"]),
            tool("source_read", "按目录id/字符offset分段读取当前范围原文；选段范围只返回选段，按nextOffset续读，不增加阅读覆盖。", reading, ["id"]),
            tool("documents_list", "只列本次显式授权的笔记目录；原文范围不会自动附加笔记。目录不是正文。", paging),
            tool("documents_search", "按需检索已授权笔记全文，每批最多32篇，nextScanOffset续查后续文档，offset只在本批命中中分页；笔记不能冒充原书。", documentSearch, ["keywords"]),
            tool("document_read", "按id/offset读取已授权笔记片段，返回内容hash和续读位置，不修改文档。", reading, ["id"]),
            tool("conversation_search", "检索当前会话原始问答，返回消息id/角色/片段；旧AI回答不是原书证据。", search, ["keywords"]),
            tool("conversation_read", "按消息id/offset重读当前会话；不传id分页读消息目录。记忆不是原文。", reading)
        ]
    }

    mutating func execute(name: String, arguments: [String: Any], maximumBytes: Int) async throws -> String {
        let before = (sourceExcerpts.count, documentExcerpts.count, conversationExcerpts.count)
        let result = try await perform(name: name, arguments: arguments, maximumBytes: maximumBytes)
        guard result.utf8.count <= max(400, maximumBytes) else {
            sourceExcerpts.removeSubrange(before.0...); documentExcerpts.removeSubrange(before.1...); conversationExcerpts.removeSubrange(before.2...)
            return try json(["ok": false, "budgetLimited": true, "message": "本轮空间不足以返回完整结果，正文未提供给模型。"])
        }
        try recordReturnedEvidence(result)
        return result
    }
    private mutating func perform(name: String, arguments: [String: Any], maximumBytes: Int) async throws -> String {
        try Task.checkCancellation(); toolCalls += 1
        let cap = min(16_000, max(0, maximumBytes))
        guard cap >= 700 else { return try json(["ok": false, "budgetLimited": true, "message": "剩余空间不足，未继续读取；请说明尚未完成范围。"] ) }
        switch name {
        case "source_outline", "source_list":
            return try page(snapshot.sources.map { ["id": $0.unitID, "locator": $0.locator, "chapter": $0.chapter, "characters": $0.text.count, "hash": $0.textHash] as [String: Any] }, arguments, cap)
        case "documents_list":
            return try page(snapshot.documents.map { ["id": $0.id, "title": $0.title, "origin": $0.origin] as [String: Any] }, arguments, cap)
        case "source_read":
            let id = try identifier(arguments)
            guard let source = snapshot.sources.first(where: { $0.unitID == id }) else { throw invalid("原文ID不在本次冻结范围内。") }
            try checkHash(arguments, actual: source.textHash)
            let slice = try readSlice(source.text, arguments, cap)
            if !slice.text.isEmpty { sourceExcerpts.append((id, slice.text)) }
            return try json(["ok": true, "id": id, "locator": source.locator, "hash": source.textHash, "offset": slice.start,
                "totalCharacters": source.text.count, "text": slice.text, "nextOffset": slice.next as Any? ?? NSNull(), "scope": snapshot.scope.rawValue])
        case "document_read":
            let id = try identifier(arguments)
            guard let document = snapshot.documents.first(where: { $0.id == id }) else { throw invalid("文档ID不在本次授权笔记范围内。") }
            let body = try await load(document), slice = try readSlice(body, arguments, cap)
            try checkHash(arguments, actual: documentHashes[id] ?? "")
            if !slice.text.isEmpty { documentExcerpts.append((id, slice.text)) }
            return try json(["ok": true, "id": id, "title": document.title, "origin": document.origin, "hash": documentHashes[id] ?? "",
                "offset": slice.start, "totalCharacters": body.count, "text": slice.text, "nextOffset": slice.next as Any? ?? NSNull()])
        case "conversation_read":
            if arguments["id"] == nil { return try page(history.map { ["id": $0.id, "role": $0.role, "characters": $0.content.count] as [String: Any] }, arguments, cap) }
            let id = try identifier(arguments)
            guard let message = history.first(where: { $0.id == id }) else { throw invalid("消息不在当前会话内。") }
            try checkHash(arguments, actual: BookImporter.sha256(Data(message.content.utf8)))
            let slice = try readSlice(message.content, arguments, cap)
            if !slice.text.isEmpty { conversationExcerpts.append((id, slice.text)) }
            return try json(["ok": true, "id": id, "role": message.role, "hash": BookImporter.sha256(Data(message.content.utf8)),
                "offset": slice.start, "totalCharacters": message.content.count, "text": slice.text, "nextOffset": slice.next as Any? ?? NSNull()])
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
        func match(_ text: String) -> (Int, String)? {
            let matches = terms.compactMap { text.range(of: $0, options: .caseInsensitive) }
            guard !matches.isEmpty, !all || matches.count == terms.count,
                  let first = matches.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
            let start = text.index(first.lowerBound, offsetBy: -70, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(start, offsetBy: 320, limitedBy: text.endIndex) ?? text.endIndex
            return (text.distance(from: text.startIndex, to: start), String(text[start..<end]))
        }
        func add(_ id: String, _ text: String, _ metadata: [String: Any]) {
            guard let (start, snippet) = match(text) else { return }
            defer { total += 1 }
            guard total >= offset, hits.count < limit else { return }
            var value = metadata; value["id"] = id; value["offset"] = start; value["snippet"] = snippet
            hits.append(value)
        }
        if name == "source_search" {
            for source in snapshot.sources { try Task.checkCancellation(); add(source.unitID, source.text, ["locator": source.locator, "hash": source.textHash]) }
        } else if name == "documents_search" {
            scanStart = try number(arguments, "scanOffset", fallback: 0, maximum: snapshot.documents.count)
            let batch = Array(snapshot.documents.dropFirst(scanStart).prefix(32))
            if scanStart + batch.count < snapshot.documents.count { nextScan = scanStart + batch.count }
            for document in batch {
                try Task.checkCancellation()
                do { let text = try await load(document); scanned += 1; add(document.id, text, ["title": document.title, "origin": document.origin, "hash": documentHashes[document.id] ?? ""]) }
                catch { try QueryBudget.propagateControl(error); failures += 1 }
            }
        } else {
            for message in history { try Task.checkCancellation(); add(message.id, message.content, ["role": message.role, "hash": try BookImporter.sha256(Data(message.content.utf8))]) }
        }
        while !hits.isEmpty {
            if try json(["hits": hits]).utf8.count <= cap - 450 { break }
            hits.removeLast()
        }
        for hit in hits { if let id = hit["id"] as? String, let text = hit["snippet"] as? String {
            if name == "source_search" { sourceExcerpts.append((id, text)) }
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
    private func readSlice(_ text: String, _ args: [String: Any], _ cap: Int) throws -> (text: String, start: Int, next: Int?) {
        let offset = try number(args, "offset", fallback: 0, maximum: text.count)
        let length = try number(args, "length", fallback: 3000, maximum: 12000)
        guard length > 0 else { throw invalid("length须为1至12000。") }
        let start = text.index(text.startIndex, offsetBy: offset)
        // JSON escaping can expand a byte sixfold. Reserve metadata and never slice serialized JSON.
        let available = max(1, (cap - 600) / 6)
        var end = start, used = 0, count = 0
        while end < text.endIndex && count < length {
            let next = text.index(after: end), size = text[end..<next].utf8.count
            if used + size > available { break }; used += size; count += 1; end = next
        }
        guard end > start || start == text.endIndex else { throw invalid("剩余空间不足以返回完整字符，未读取。") }
        return (String(text[start..<end]), offset, end < text.endIndex ? offset + count : nil)
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
