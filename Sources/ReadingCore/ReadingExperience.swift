import Foundation

/// An exact anchor in one imported source unit. UTF-16 offsets are unit-local;
/// they are never PDFKit page ranges, rendered Markdown ranges, or OCR rectangles.
public struct SourceAnchor: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var sourceHash: String
    public var unitID: String
    public var unitTextHash: String
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var utf16Location: Int?
    public var utf16Length: Int?
    public init(id: String, sourceHash: String, unitID: String, unitTextHash: String = "", quote: String, prefix: String = "", suffix: String = "", utf16Location: Int? = nil, utf16Length: Int? = nil) {
        self.id = id; self.sourceHash = sourceHash; self.unitID = unitID; self.unitTextHash = unitTextHash
        self.quote = quote; self.prefix = prefix; self.suffix = suffix
        self.utf16Location = utf16Location; self.utf16Length = utf16Length
    }
}

public struct ResolvedSourceAnchor: Hashable, Sendable {
    public var anchor: SourceAnchor
    public var unit: SourceUnit
    public var utf16Location: Int
    public var utf16Length: Int
    public var utf8Start: Int
    public var utf8End: Int
    public var range: NSRange { NSRange(location: utf16Location, length: utf16Length) }
    public var utf16Range: NSRange { range }
    public var unitID: String { unit.id }
    public var page: Int? { unit.page }
}

public struct SourceMention: Codable, Identifiable, Hashable, Sendable {
    public var targetID: String
    public var anchorID: String
    public var id: String { anchorID + "::" + targetID }
    public init(targetID: String, anchorID: String) { self.targetID = targetID; self.anchorID = anchorID }
}

/// Attribution does not claim that an external source has been fetched or verified.
public struct ReadingProvenance: Codable, Hashable, Sendable {
    public var label: String
    public var url: String?
    public var workTitle: String?
    public var locator: String?
    public init(label: String, url: String? = nil, workTitle: String? = nil, locator: String? = nil) {
        self.label = label; self.url = url; self.workTitle = workTitle; self.locator = locator
    }
}

/// Kinds remain extensible. Host defaults do not force every book into one subject's types.
public struct ReadingLayer: Codable, Identifiable, Hashable, Sendable {
    public static let defaultKinds = ["translation", "explanation", "glossary", "commentary", "reference"]
    public var id: String
    public var kind: String
    public var title: String
    public var markdown: String
    public var sourceAnchorIDs: [String]
    public var sourceLabel: String
    public var parallelGroupID: String?
    public var provenance: ReadingProvenance?
    public init(id: String = UUID().uuidString, kind: String, title: String, markdown: String, sourceAnchorIDs: [String], sourceLabel: String = "AI 解释，待核对", parallelGroupID: String? = nil, provenance: ReadingProvenance? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.markdown = markdown
        self.sourceAnchorIDs = sourceAnchorIDs; self.sourceLabel = sourceLabel
        self.parallelGroupID = parallelGroupID; self.provenance = provenance
    }
}

/// All anchors belong to this book. External attribution is not a cross-library location.
public struct ReferenceAlignment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var sourceAnchorIDs: [String]
    public var title: String
    public var markdown: String
    public var provenance: ReadingProvenance?
    public var status: String
    public init(id: String = UUID().uuidString, sourceAnchorIDs: [String], title: String, markdown: String, provenance: ReadingProvenance? = nil, status: String = "proposed") {
        self.id = id; self.sourceAnchorIDs = sourceAnchorIDs; self.title = title; self.markdown = markdown
        self.provenance = provenance; self.status = status
    }
}

public struct DecisionOption: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var markdown: String
    public init(id: String = UUID().uuidString, title: String, markdown: String) { self.id = id; self.title = title; self.markdown = markdown }
}

public struct DecisionCard: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var contextMarkdown: String
    public var options: [DecisionOption]
    public var historicalOutcomeMarkdown: String
    public var sourceAnchorIDs: [String]
    public var sourceLabel: String
    public init(id: String = UUID().uuidString, title: String, contextMarkdown: String, options: [DecisionOption], historicalOutcomeMarkdown: String = "", sourceAnchorIDs: [String], sourceLabel: String = "AI 分析，待核对") {
        self.id = id; self.title = title; self.contextMarkdown = contextMarkdown; self.options = options
        self.historicalOutcomeMarkdown = historicalOutcomeMarkdown; self.sourceAnchorIDs = sourceAnchorIDs; self.sourceLabel = sourceLabel
    }
}

/// Recovery retains the exact removed record and its source dependencies, never rendered copies.
public struct ReadingExperienceTrashItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var title: String
    public var createdAt: Date
    public var anchors: [SourceAnchor]
    public var layer: ReadingLayer?
    public var alignment: ReferenceAlignment?
    public var decision: DecisionCard?
    public init(id: String = UUID().uuidString, kind: String, title: String, createdAt: Date = Date(), anchors: [SourceAnchor], layer: ReadingLayer? = nil, alignment: ReferenceAlignment? = nil, decision: DecisionCard? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.createdAt = createdAt; self.anchors = anchors
        self.layer = layer; self.alignment = alignment; self.decision = decision
    }
}

/// Optional on BookProject. Missing historical data stays absent; no anchors or coverage are invented.
public struct ReadingExperienceState: Codable, Hashable, Sendable {
    public var version: Int
    public var anchors: [SourceAnchor]
    public var mentions: [SourceMention]
    public var layers: [ReadingLayer]
    public var alignments: [ReferenceAlignment]
    public var decisions: [DecisionCard]
    public var trash: [ReadingExperienceTrashItem]? = nil
    public init(version: Int = 1, anchors: [SourceAnchor] = [], mentions: [SourceMention] = [], layers: [ReadingLayer] = [], alignments: [ReferenceAlignment] = [], decisions: [DecisionCard] = [], trash: [ReadingExperienceTrashItem]? = nil) {
        self.version = version; self.anchors = anchors; self.mentions = mentions; self.layers = layers
        self.alignments = alignments; self.decisions = decisions; self.trash = trash
    }
}

/// Shared by source, cards, map, graph, Markdown and chat; also permits contexts without source selection.
public struct ReadingContext: Codable, Hashable, Sendable {
    public var sourceHash: String?
    public var unitID: String?
    public var selectedAnchorID: String?
    public var selectedText: String?
    public var selectedPrefix: String?
    public var selectedSuffix: String?
    public var objectID: String?
    public var documentID: String?
    public var page: Int?
    public var startYear: Int?
    public var endYear: Int?
    public var timeFrom: Double?
    public var timeTo: Double?
    /// Only a query selection may span pages; source anchors remain unit-local.
    public var selectionEndPage: Int? = nil
    public init(sourceHash: String? = nil, unitID: String? = nil, selectedAnchorID: String? = nil, selectedText: String? = nil, selectedPrefix: String? = nil, selectedSuffix: String? = nil, objectID: String? = nil, documentID: String? = nil, page: Int? = nil, startYear: Int? = nil, endYear: Int? = nil, timeFrom: Double? = nil, timeTo: Double? = nil, selectionEndPage: Int? = nil) {
        self.sourceHash = sourceHash; self.unitID = unitID; self.selectedAnchorID = selectedAnchorID
        self.selectedText = selectedText; self.objectID = objectID; self.documentID = documentID; self.page = page
        self.selectedPrefix = selectedPrefix; self.selectedSuffix = selectedSuffix
        self.startYear = startYear; self.endYear = endYear; self.timeFrom = timeFrom; self.timeTo = timeTo
        self.selectionEndPage = selectionEndPage
    }
}

public struct ReadingContextItems: Hashable, Sendable {
    public var anchors: [SourceAnchor]
    public var mentions: [SourceMention]
    public var entities: [KnowledgeEntity]
    public var events: [KnowledgeEvent]
    public var layers: [ReadingLayer]
    public var alignments: [ReferenceAlignment]
    public var decisions: [DecisionCard]
    public var entityIDs: [String] { entities.map(\.id) }
    public var eventIDs: [String] { events.map(\.id) }
    public init(anchors: [SourceAnchor] = [], mentions: [SourceMention] = [], entities: [KnowledgeEntity] = [], events: [KnowledgeEvent] = [], layers: [ReadingLayer] = [], alignments: [ReferenceAlignment] = [], decisions: [DecisionCard] = []) {
        self.anchors = anchors; self.mentions = mentions; self.entities = entities; self.events = events
        self.layers = layers; self.alignments = alignments; self.decisions = decisions
    }
}

public enum ReadingExperienceRuntime {
    /// Adjacent context disambiguates repeated quotations. An offset confirms a match;
    /// it never selects one of several otherwise ambiguous matches.
    public static func createAnchor(sourceHash: String, unitID: String, quote: String, prefix: String = "", suffix: String = "", in project: BookProject) throws -> SourceAnchor {
        guard !sourceHash.isEmpty, sourceHash == project.sourceHash else { throw invalid("原文来源版本已变化，不能建立锚点。") }
        let unit = try sourceUnit(unitID, in: project)
        return try createAnchor(sourceHash: sourceHash, unit: unit, quote: quote, prefix: prefix, suffix: suffix)
    }

    /// A disposable batch shares only the immutable source-unit check and hash.
    /// Every quote still passes the same ambiguity, byte and identity checks.
    static func anchorCreator(sourceHash: String, unitID: String, in project: BookProject) throws -> (String, String, String) throws -> SourceAnchor {
        guard !sourceHash.isEmpty, sourceHash == project.sourceHash else { throw invalid("原文来源版本已变化，不能建立锚点。") }
        let unit = try sourceUnit(unitID, in: project)
        let unitHash = try BookImporter.sha256(Data(unit.text.utf8))
        return { quote, prefix, suffix in
            try createAnchor(sourceHash: sourceHash, unit: unit, quote: quote, prefix: prefix, suffix: suffix, preparedUnitHash: unitHash)
        }
    }

    private static func createAnchor(sourceHash: String, unit: SourceUnit, quote: String, prefix: String, suffix: String, preparedUnitHash: String? = nil) throws -> SourceAnchor {
        try checkQuote(quote, prefix: prefix, suffix: suffix)
        let range = try uniqueRange(quote: quote, prefix: prefix, suffix: suffix, text: unit.text)
        guard let stringRange = Range(range, in: unit.text) else { throw invalid("原句不是有效的 Unicode 边界。") }
        // Store canonical context so different AI request aliases/context lengths yield an identical record.
        var canonicalPrefix = String(unit.text[..<stringRange.lowerBound].suffix(1_024))
        var canonicalSuffix = String(unit.text[stringRange.upperBound...].prefix(1_024))
        while canonicalPrefix.utf8.count > 1_024 { canonicalPrefix.removeFirst() }
        while canonicalSuffix.utf8.count > 1_024 { canonicalSuffix.removeLast() }
        let canonicalRange = try uniqueRange(quote: quote, prefix: canonicalPrefix, suffix: canonicalSuffix, text: unit.text)
        guard canonicalRange == range else { throw invalid("请改用更完整的原句建立稳定锚点。") }
        let unitHash = try preparedUnitHash ?? BookImporter.sha256(Data(unit.text.utf8))
        let id = try anchorIdentity(sourceHash: sourceHash, unitID: unit.id, unitTextHash: unitHash, quote: quote, range: range)
        return SourceAnchor(id: id, sourceHash: sourceHash, unitID: unit.id, unitTextHash: unitHash, quote: quote, prefix: canonicalPrefix, suffix: canonicalSuffix, utf16Location: range.location, utf16Length: range.length)
    }

    public static func resolve(_ anchor: SourceAnchor, in project: BookProject) throws -> ResolvedSourceAnchor {
        guard !anchor.sourceHash.isEmpty, anchor.sourceHash == project.sourceHash else { throw invalid("锚点属于其他原文版本。") }
        let unit = try sourceUnit(anchor.unitID, in: project)
        return try resolve(anchor, unit: unit)
    }

    /// Prepared only for one immutable source unit. It shares the source hash,
    /// while each stored anchor still proves its identity and unique quote.
    public static func anchorResolver(sourceHash: String, unitID: String, in project: BookProject) throws -> (SourceAnchor) throws -> ResolvedSourceAnchor {
        guard !sourceHash.isEmpty, sourceHash == project.sourceHash else { throw invalid("锚点属于其他原文版本。") }
        let unit = try sourceUnit(unitID, in: project)
        let unitHash = try BookImporter.sha256(Data(unit.text.utf8))
        return { anchor in
            guard anchor.sourceHash == sourceHash, anchor.unitID == unit.id else { throw invalid("锚点属于其他原文版本或单元。") }
            return try resolve(anchor, unit: unit, preparedUnitHash: unitHash)
        }
    }

    private static func resolve(_ anchor: SourceAnchor, unit: SourceUnit, preparedUnitHash: String? = nil) throws -> ResolvedSourceAnchor {
        try checkQuote(anchor.quote, prefix: anchor.prefix, suffix: anchor.suffix)
        let unitHash = try preparedUnitHash ?? BookImporter.sha256(Data(unit.text.utf8))
        guard !anchor.unitTextHash.isEmpty, anchor.unitTextHash == unitHash else { throw invalid("该页或片段文本已变化，旧锚点需要重新核对。") }
        let range = try uniqueRange(quote: anchor.quote, prefix: anchor.prefix, suffix: anchor.suffix, text: unit.text)
        guard (anchor.utf16Location == nil) == (anchor.utf16Length == nil) else { throw invalid("锚点范围不完整。") }
        if let location = anchor.utf16Location, let length = anchor.utf16Length {
            guard location == range.location, length == range.length else { throw invalid("锚点范围与原句不一致。") }
        }
        let id = try anchorIdentity(sourceHash: anchor.sourceHash, unitID: anchor.unitID, unitTextHash: unitHash, quote: anchor.quote, range: range)
        guard anchor.id == id, let stringRange = Range(range, in: unit.text) else { throw invalid("锚点身份或 Unicode 边界无效。") }
        let utf8Start = unit.text[..<stringRange.lowerBound].utf8.count
        let utf8End = utf8Start + unit.text[stringRange].utf8.count
        return ResolvedSourceAnchor(anchor: anchor, unit: unit, utf16Location: range.location, utf16Length: range.length, utf8Start: utf8Start, utf8End: utf8End)
    }

    public static func validateStoredState(_ state: ReadingExperienceState, in project: BookProject) throws { try validate(state, in: project) }

    public static func validate(_ state: ReadingExperienceState, in project: BookProject) throws {
        guard state.version == 1, state.anchors.count <= 100_000, state.mentions.count <= 200_000,
              state.layers.count <= 50_000, state.alignments.count <= 50_000, state.decisions.count <= 20_000 else { throw invalid("增强阅读版本或数量超出限制。") }
        try unique(state.anchors.map(\.id)); try unique(state.mentions.map(\.id)); try unique(state.layers.map(\.id))
        try unique(state.alignments.map(\.id)); try unique(state.decisions.map(\.id))
        for anchor in state.anchors { _ = try resolve(anchor, in: project) }
        let anchorIDs = Set(state.anchors.map(\.id))
        // Trashed document metadata is retained so restoring it preserves existing source links.
        let targets = Set(project.entities.map(\.id) + project.events.map(\.id) + project.documents.map(\.id))
        for mention in state.mentions {
            guard anchorIDs.contains(mention.anchorID), targets.contains(mention.targetID) else { throw invalid("原文提及引用了不存在的锚点或对象。") }
        }
        for layer in state.layers { try validateLayer(layer, state: state, in: project) }
        for alignment in state.alignments { try validateAlignment(alignment, state: state, in: project) }
        for decision in state.decisions { try validateDecision(decision, state: state, in: project) }
        let trash = state.trash ?? []
        guard trash.count <= 200 else { throw invalid("阅读增强回收站已达到 200 条上限。") }
        try unique(trash.map(\.id))
        for item in trash { try validateTrashItem(item, in: project) }
    }

    public static func validateLayer(_ layer: ReadingLayer, state: ReadingExperienceState, in project: BookProject) throws {
        try checkID(layer.id); try checkKind(layer.kind); try nonempty(layer.title, maximum: 400); try nonempty(layer.markdown, maximum: 64_000)
        try nonempty(layer.sourceLabel, maximum: 800); try checkReferences(layer.sourceAnchorIDs, state: state, minimum: 1)
        if let group = layer.parallelGroupID { try checkID(group) }
        if let provenance = layer.provenance { try checkProvenance(provenance) }
    }

    public static func validateAlignment(_ alignment: ReferenceAlignment, state: ReadingExperienceState, in project: BookProject) throws {
        try checkID(alignment.id); try nonempty(alignment.title, maximum: 400); try nonempty(alignment.markdown, maximum: 64_000)
        try checkReferences(alignment.sourceAnchorIDs, state: state, minimum: 2); try checkKind(alignment.status)
        if let provenance = alignment.provenance { try checkProvenance(provenance) }
    }

    public static func validateDecision(_ decision: DecisionCard, state: ReadingExperienceState, in project: BookProject) throws {
        try checkID(decision.id); try nonempty(decision.title, maximum: 400); try nonempty(decision.contextMarkdown, maximum: 32_000)
        try nonempty(decision.sourceLabel, maximum: 800); try checkReferences(decision.sourceAnchorIDs, state: state, minimum: 1)
        guard (2...12).contains(decision.options.count), decision.historicalOutcomeMarkdown.utf8.count <= 64_000 else { throw invalid("决策卡须有 2–12 个选项，结果正文不能超长。") }
        try unique(decision.options.map(\.id))
        for option in decision.options { try checkID(option.id); try nonempty(option.title, maximum: 400); try nonempty(option.markdown, maximum: 16_000) }
    }

    /// Rebuilds links only from existing evidence, never by globally searching titles.
    /// Uncertain candidates produce no link. No reading receipt or coverage is changed.
    public static func indexEvidence(in project: BookProject, state: ReadingExperienceState? = nil, unitIDs: Set<String>? = nil) -> ReadingExperienceState {
        var result = state ?? project.readingExperience ?? ReadingExperienceState()
        var anchorIDs = Set(result.anchors.map(\.id))
        var mentionIDs = Set(result.mentions.map(\.id))
        let entries: [(String, [String], [Evidence])] = project.entities.map { ($0.id, [$0.name] + $0.aliases, $0.evidence) } + project.events.map { ($0.id, [$0.name], $0.evidence) }
        for (targetID, names, evidence) in entries {
            if Task.isCancelled { return result }
            for source in evidence where unitIDs?.contains(source.unitID) ?? true {
                if Task.isCancelled { return result }
                guard let evidenceAnchor = try? createAnchor(sourceHash: project.sourceHash, unitID: source.unitID, quote: source.quote, in: project),
                      let unit = project.units.first(where: { $0.id == source.unitID }),
                      let evidenceRange = try? resolve(evidenceAnchor, in: project) else { continue }
                for name in Set(names) where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if Task.isCancelled { return result }
                    guard let nameRange = try? uniqueRange(quote: name, prefix: "", suffix: "", text: source.quote),
                          let swiftRange = Range(NSRange(location: evidenceRange.utf16Location + nameRange.location, length: nameRange.length), in: unit.text) else { continue }
                    let location = evidenceRange.utf16Location + nameRange.location
                    // Character slicing cannot split a surrogate pair or combining sequence.
                    let prefix = String(unit.text[..<swiftRange.lowerBound].suffix(64))
                    let suffix = String(unit.text[swiftRange.upperBound...].prefix(64))
                    guard let anchor = try? createAnchor(sourceHash: project.sourceHash, unitID: source.unitID, quote: name, prefix: prefix, suffix: suffix, in: project), anchor.utf16Location == location else { continue }
                    if anchorIDs.insert(anchor.id).inserted { result.anchors.append(anchor) }
                    let mention = SourceMention(targetID: targetID, anchorID: anchor.id)
                    if mentionIDs.insert(mention.id).inserted { result.mentions.append(mention) }
                }
            }
        }
        return result
    }

    public static func validatedContext(_ context: ReadingContext, in project: BookProject, state: ReadingExperienceState? = nil) throws -> ReadingContext {
        let state = state ?? project.readingExperience ?? ReadingExperienceState()
        var result = context
        if let hash = context.sourceHash, hash != project.sourceHash { throw invalid("阅读上下文属于其他原书版本。") }
        result.sourceHash = project.sourceHash
        if let unitID = context.unitID { _ = try sourceUnit(unitID, in: project) }
        if let anchorID = context.selectedAnchorID {
            guard let anchor = state.anchors.first(where: { $0.id == anchorID }) else { throw invalid("当前选段锚点不存在。") }
            let resolved = try resolve(anchor, in: project)
            guard context.unitID == nil || context.unitID == resolved.unitID else { throw invalid("当前选段与源单元不一致。") }
            guard context.page == nil || context.page == resolved.page else { throw invalid("当前选段与页码不一致。") }
            if let selected = context.selectedText, !selected.utf8.elementsEqual(anchor.quote.utf8) { throw invalid("当前选中文字与锚点不一致。") }
            result.unitID = resolved.unitID; result.page = resolved.page; result.selectedText = anchor.quote
            result.selectedPrefix = anchor.prefix; result.selectedSuffix = anchor.suffix
        } else if let selected = context.selectedText, !selected.isEmpty {
            guard let unitID = context.unitID else { throw invalid("选中文字必须明确属于一个源单元。") }
            let anchor = try createAnchor(sourceHash: project.sourceHash, unitID: unitID, quote: selected, prefix: context.selectedPrefix ?? "", suffix: context.selectedSuffix ?? "", in: project)
            result.selectedPrefix = anchor.prefix; result.selectedSuffix = anchor.suffix
        } else if context.selectedPrefix != nil || context.selectedSuffix != nil {
            throw invalid("选段前后文缺少对应的选中文字。")
        }
        if let page = context.page {
            guard page >= 1, project.units.contains(where: { $0.page == page }) else { throw invalid("阅读上下文页码不存在。") }
            if let unitID = result.unitID, project.units.first(where: { $0.id == unitID })?.page != page { throw invalid("阅读上下文页码与源单元不一致。") }
        }
        if let objectID = context.objectID {
            let owners = project.entities.filter { $0.id == objectID }.count + project.events.filter { $0.id == objectID }.count
            guard owners == 1 else { throw invalid("当前阅读对象不存在或标识歧义。") }
        }
        if let documentID = context.documentID, !project.activeDocuments.contains(where: { $0.id == documentID }) { throw invalid("当前 Markdown 文档不存在或已移入废纸篓。") }
        if let start = context.startYear, abs(Double(start)) > 1_000_000_000_000 { throw invalid("时间范围过大。") }
        if let end = context.endYear, abs(Double(end)) > 1_000_000_000_000 { throw invalid("时间范围过大。") }
        if let start = context.startYear, let end = context.endYear, start > end { throw invalid("时间范围起点晚于终点。") }
        for value in [context.timeFrom, context.timeTo].compactMap({ $0 }) {
            guard value.isFinite, abs(value) <= 1_000_000_000_000 else { throw invalid("时间范围不是有效数值。") }
        }
        let lower = context.timeFrom ?? context.startYear.map(Double.init)
        let upper = context.timeTo ?? context.endYear.map(Double.init)
        if let lower, let upper, lower > upper { throw invalid("时间范围起点晚于终点。") }
        return result
    }

    /// Invalid contexts yield no items rather than silently broadening to the whole book.
    public static func contextualItems(in project: BookProject, context: ReadingContext, state: ReadingExperienceState? = nil) -> ReadingContextItems {
        let state = state ?? project.readingExperience ?? ReadingExperienceState()
        guard let context = try? validatedContext(context, in: project, state: state) else { return ReadingContextItems() }
        var unitIDs = Set<String>()
        if let unitID = context.unitID { unitIDs.insert(unitID) }
        if let page = context.page, context.unitID == nil { unitIDs.formUnion(project.units.filter { $0.page == page }.map(\.id)) }
        let selectedRange: ResolvedSourceAnchor?
        if let id = context.selectedAnchorID, let anchor = state.anchors.first(where: { $0.id == id }) { selectedRange = try? resolve(anchor, in: project) }
        else if let quote = context.selectedText, !quote.isEmpty, let unitID = context.unitID,
                let anchor = try? createAnchor(sourceHash: project.sourceHash, unitID: unitID, quote: quote, prefix: context.selectedPrefix ?? "", suffix: context.selectedSuffix ?? "", in: project) { selectedRange = try? resolve(anchor, in: project) }
        else { selectedRange = nil }
        var explicitTargetIDs = Set<String>()
        if let id = context.objectID { explicitTargetIDs.insert(id) }
        if let id = context.documentID, let document = project.activeDocuments.first(where: { $0.id == id }) {
            explicitTargetIDs.insert(id); explicitTargetIDs.formUnion(document.linkedIDs)
        }
        let explicitAnchorIDs = Set(state.mentions.filter { explicitTargetIDs.contains($0.targetID) }.map(\.anchorID))
        let localAnchors = state.anchors.filter { anchor in
            guard (unitIDs.contains(anchor.unitID) || (unitIDs.isEmpty && explicitAnchorIDs.contains(anchor.id))), let resolved = try? resolve(anchor, in: project) else { return false }
            return selectedRange.map { $0.unitID == resolved.unitID && NSIntersectionRange($0.range, resolved.range).length > 0 } ?? true
        }
        let localIDs = Set(localAnchors.map(\.id))
        let mentions = state.mentions.filter { localIDs.contains($0.anchorID) }
        var targetIDs = Set(mentions.map(\.targetID)); targetIDs.formUnion(explicitTargetIDs)
        func evidenceIsLocal(_ evidence: [Evidence]) -> Bool {
            evidence.contains { source in
                guard unitIDs.contains(source.unitID),
                      let anchor = try? createAnchor(sourceHash: project.sourceHash, unitID: source.unitID, quote: source.quote, in: project),
                      let range = try? resolve(anchor, in: project) else { return false }
                guard let selectedRange else { return true }
                return range.unitID == selectedRange.unitID && NSIntersectionRange(range.range, selectedRange.range).length > 0
            }
        }
        var entities = project.entities.filter { targetIDs.contains($0.id) || evidenceIsLocal($0.evidence) }
        let entityIDs = Set(entities.map(\.id))
        let hasSourceScope = !unitIDs.isEmpty
        let hasObjectScope = context.objectID != nil || context.documentID != nil
        let lower = context.timeFrom ?? context.startYear.map(Double.init)
        let upper = context.timeTo ?? context.endYear.map(Double.init)
        let hasTimeScope = lower != nil || upper != nil
        var events = project.events.filter { event in
            let related = targetIDs.contains(event.id) || evidenceIsLocal(event.evidence) || (!entityIDs.isDisjoint(with: Set(event.placeIDs + event.participantIDs)) && hasObjectScope)
            guard related || (!hasSourceScope && !hasObjectScope && hasTimeScope) else { return false }
            guard hasTimeScope else { return true }
            guard let start = event.startYear else { return related }
            let end = event.endYear ?? start
            return Double(end) >= (lower ?? -.infinity) && Double(start) <= (upper ?? .infinity)
        }
        if !hasSourceScope && !hasObjectScope && !hasTimeScope { entities = []; events = [] }
        let relatedEntityIDs = Set(events.flatMap { $0.placeIDs + $0.participantIDs })
        let existingIDs = Set(entities.map(\.id))
        entities.append(contentsOf: project.entities.filter { relatedEntityIDs.contains($0.id) && !existingIDs.contains($0.id) })
        let layers = state.layers.filter { !Set($0.sourceAnchorIDs).isDisjoint(with: localIDs) }
        let alignments = state.alignments.filter { !Set($0.sourceAnchorIDs).isDisjoint(with: localIDs) }
        let decisions = state.decisions.filter { !Set($0.sourceAnchorIDs).isDisjoint(with: localIDs) }
        return ReadingContextItems(anchors: localAnchors, mentions: mentions, entities: entities, events: events, layers: layers, alignments: alignments, decisions: decisions)
    }

    /// Bounded saved data and exact selected text; it does not fetch external prose or user Markdown bodies.
    public static func contextJSON(_ context: ReadingContext, in project: BookProject, state: ReadingExperienceState? = nil, maximumUTF8Bytes: Int = 16_000) throws -> String {
        guard (2_048...64_000).contains(maximumUTF8Bytes) else { throw invalid("上下文预算须在 2–64 KiB 之间。") }
        let state = state ?? project.readingExperience ?? ReadingExperienceState()
        let context = try validatedContext(context, in: project, state: state)
        let items = contextualItems(in: project, context: context, state: state)
        var payload: [String: Any] = ["sourceHash": project.sourceHash, "contextIsHostValidated": true, "bounded": false]
        if let id = context.unitID { payload["unitID"] = id }
        if let page = context.page { payload["page"] = page }
        if let id = context.selectedAnchorID { payload["selectedAnchorID"] = id }
        if let text = context.selectedText { payload["selectedText"] = String(text.prefix(1_200)) }
        if let prefix = context.selectedPrefix { payload["selectedPrefix"] = prefix }
        if let suffix = context.selectedSuffix { payload["selectedSuffix"] = suffix }
        if let id = context.objectID { payload["objectID"] = id }
        if let id = context.documentID { payload["documentID"] = id }
        if let from = context.timeFrom ?? context.startYear.map(Double.init) { payload["timeFrom"] = from }
        if let to = context.timeTo ?? context.endYear.map(Double.init) { payload["timeTo"] = to }
        payload["entities"] = items.entities.prefix(24).map { ["id": $0.id, "name": String($0.name.prefix(160)), "typeID": $0.typeID, "summary": String($0.summary.prefix(300))] }
        payload["events"] = items.events.prefix(16).map { ["id": $0.id, "name": String($0.name.prefix(160)), "dateText": String($0.dateText.prefix(120)), "summary": String($0.summary.prefix(300)), "placeIDs": Array($0.placeIDs.prefix(24)), "participantIDs": Array($0.participantIDs.prefix(24))] as [String: Any] }
        payload["layers"] = items.layers.prefix(12).map { ["id": $0.id, "kind": $0.kind, "title": String($0.title.prefix(120)), "markdown": String($0.markdown.prefix(500)), "sourceLabel": String($0.sourceLabel.prefix(120))] }
        payload["alignments"] = items.alignments.prefix(8).map { ["id": $0.id, "title": String($0.title.prefix(120)), "markdown": String($0.markdown.prefix(400))] }
        while true {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            if data.count <= maximumUTF8Bytes, let text = String(data: data, encoding: .utf8) { return text }
            payload["bounded"] = true
            var removed = false
            for key in ["decisions", "alignments", "layers", "events", "entities"] {
                if var values = payload[key] as? [[String: Any]], !values.isEmpty { values.removeLast(); payload[key] = values; removed = true; break }
            }
            if !removed {
                for key in ["selectedPrefix", "selectedSuffix", "selectedText"] {
                    if let selected = payload[key] as? String, !selected.isEmpty {
                        payload[key] = key == "selectedPrefix" ? String(selected.suffix(selected.count / 2)) : String(selected.prefix(selected.count / 2))
                        removed = true; break
                    }
                }
            }
            guard removed else { throw invalid("上下文标识过大，无法满足预算。") }
        }
    }

    /// Move exactly one generated artifact into a bounded recovery area. Existing cleanup helpers remain pure hard removal.
    public static func trashItem(id: String, kind: String, state: ReadingExperienceState) throws -> ReadingExperienceState {
        guard (state.trash ?? []).count < 200 else { throw invalid("阅读增强回收站已满，请先恢复已有内容；本次条目没有移除。") }
        let layer: ReadingLayer?
        let alignment: ReferenceAlignment?
        let decision: DecisionCard?
        let title: String
        let sourceIDs: [String]
        var result: ReadingExperienceState
        switch kind {
        case "layer":
            let matches = state.layers.filter { $0.id == id }
            guard matches.count == 1, let value = matches.first else { throw invalid("要移除的阅读层不存在或标识重复。") }
            layer = value; alignment = nil; decision = nil; title = value.title; sourceIDs = value.sourceAnchorIDs
            result = removeLayer(id, from: state)
        case "alignment":
            let matches = state.alignments.filter { $0.id == id }
            guard matches.count == 1, let value = matches.first else { throw invalid("要移除的资料对齐不存在或标识重复。") }
            layer = nil; alignment = value; decision = nil; title = value.title; sourceIDs = value.sourceAnchorIDs
            result = removeAlignment(id, from: state)
        case "decision":
            let matches = state.decisions.filter { $0.id == id }
            guard matches.count == 1, let value = matches.first else { throw invalid("要移除的思考卡不存在或标识重复。") }
            layer = nil; alignment = nil; decision = value; title = value.title; sourceIDs = value.sourceAnchorIDs
            result = removeDecision(id, from: state)
        default: throw invalid("不支持移除的阅读增强类型。")
        }
        let ids = Set(sourceIDs)
        let anchors = state.anchors.filter { ids.contains($0.id) }
        guard anchors.count == ids.count, Set(anchors.map(\.id)).count == anchors.count else { throw invalid("条目的原文依赖缺失，未执行移除。") }
        var trash = result.trash ?? []
        trash.append(ReadingExperienceTrashItem(kind: kind, title: title, anchors: anchors, layer: layer, alignment: alignment, decision: decision))
        result.trash = trash
        return result
    }

    /// Restore only after source and collision checks. A newer record with the same ID is never overwritten.
    public static func restoreTrashedItem(id: String, state: ReadingExperienceState, in project: BookProject) throws -> ReadingExperienceState {
        let matches = (state.trash ?? []).filter { $0.id == id }
        guard matches.count == 1, let item = matches.first else { throw invalid("要恢复的增强条目不存在或标识重复。") }
        try validateTrashItem(item, in: project)
        var result = state
        for anchor in item.anchors { try mergeRestored(anchor, into: &result.anchors, id: { $0.id }) }
        if let layer = item.layer { try mergeRestored(layer, into: &result.layers, id: { $0.id }) }
        if let alignment = item.alignment { try mergeRestored(alignment, into: &result.alignments, id: { $0.id }) }
        if let decision = item.decision { try mergeRestored(decision, into: &result.decisions, id: { $0.id }) }
        result.trash?.removeAll { $0.id == id }
        try validate(result, in: project)
        return result
    }

    /// Cleanup never changes source text, entity records, or Markdown bodies.
    public static func removeTarget(_ id: String, from state: ReadingExperienceState) -> ReadingExperienceState {
        var result = state; result.mentions.removeAll { $0.targetID == id }; return pruningUnreferencedAnchors(result)
    }
    public static func removeAnchor(_ id: String, from state: ReadingExperienceState) -> ReadingExperienceState {
        var result = state
        result.anchors.removeAll { $0.id == id }; result.mentions.removeAll { $0.anchorID == id }
        result.layers.removeAll { $0.sourceAnchorIDs.contains(id) }
        result.alignments.removeAll { $0.sourceAnchorIDs.contains(id) }
        result.decisions.removeAll { $0.sourceAnchorIDs.contains(id) }
        return pruningUnreferencedAnchors(result)
    }
    public static func removeLayer(_ id: String, from state: ReadingExperienceState) -> ReadingExperienceState {
        var result = state; result.layers.removeAll { $0.id == id }; return pruningUnreferencedAnchors(result)
    }
    public static func removeAlignment(_ id: String, from state: ReadingExperienceState) -> ReadingExperienceState {
        var result = state; result.alignments.removeAll { $0.id == id }; return pruningUnreferencedAnchors(result)
    }
    public static func removeDecision(_ id: String, from state: ReadingExperienceState) -> ReadingExperienceState {
        var result = state; result.decisions.removeAll { $0.id == id }; return pruningUnreferencedAnchors(result)
    }

    private static func pruningUnreferencedAnchors(_ state: ReadingExperienceState) -> ReadingExperienceState {
        var result = state
        let used = Set(state.mentions.map(\.anchorID) + state.layers.flatMap(\.sourceAnchorIDs) + state.alignments.flatMap(\.sourceAnchorIDs) + state.decisions.flatMap(\.sourceAnchorIDs))
        result.anchors.removeAll { !used.contains($0.id) }; return result
    }
    private static func validateTrashItem(_ item: ReadingExperienceTrashItem, in project: BookProject) throws {
        try checkID(item.id); try nonempty(item.title, maximum: 400)
        guard item.createdAt.timeIntervalSinceReferenceDate.isFinite else { throw invalid("阅读增强回收时间无效。") }
        let count = (item.layer == nil ? 0 : 1) + (item.alignment == nil ? 0 : 1) + (item.decision == nil ? 0 : 1)
        guard count == 1, (item.kind == "layer" && item.layer != nil) || (item.kind == "alignment" && item.alignment != nil) || (item.kind == "decision" && item.decision != nil) else { throw invalid("阅读增强回收快照类型无效。") }
        let ids = item.layer?.sourceAnchorIDs ?? item.alignment?.sourceAnchorIDs ?? item.decision?.sourceAnchorIDs ?? []
        guard Set(item.anchors.map(\.id)) == Set(ids), item.anchors.count <= 128 else { throw invalid("阅读增强回收快照的原文依赖不完整。") }
        let snapshot = ReadingExperienceState(anchors: item.anchors, layers: item.layer.map { [$0] } ?? [], alignments: item.alignment.map { [$0] } ?? [], decisions: item.decision.map { [$0] } ?? [])
        try validate(snapshot, in: project)
    }
    private static func mergeRestored<T: Equatable>(_ value: T, into values: inout [T], id: (T) -> String) throws {
        let matches = values.filter { id($0) == id(value) }
        guard matches.count <= 1 else { throw invalid("恢复目标存在重复标识。") }
        if let existing = matches.first {
            guard existing == value else { throw invalid("同标识已有新内容，不能用回收快照覆盖。") }
        } else { values.append(value) }
    }
    private static func sourceUnit(_ id: String, in project: BookProject) throws -> SourceUnit {
        let matches = project.units.filter { $0.id == id }
        guard matches.count == 1, let unit = matches.first else { throw invalid("锚点源单元不存在或重复，不能跨页猜测。") }; return unit
    }
    private static func checkQuote(_ quote: String, prefix: String, suffix: String) throws {
        try nonempty(quote, maximum: 32_768)
        guard prefix.utf8.count <= 1_024, suffix.utf8.count <= 1_024 else { throw invalid("锚点前后文过长。") }
    }
    private static func uniqueRange(quote: String, prefix: String, suffix: String, text: String) throws -> NSRange {
        let source = text as NSString
        var cursor = 0
        var matches: [NSRange] = []
        while cursor <= source.length {
            let range = source.range(of: quote, options: [.literal], range: NSRange(location: cursor, length: source.length - cursor))
            if range.location == NSNotFound { break }
            if let swiftRange = Range(range, in: text) {
                let before = text[..<swiftRange.lowerBound]
                let after = text[swiftRange.upperBound...]
                if (prefix.isEmpty || before.utf8.suffix(prefix.utf8.count).elementsEqual(prefix.utf8)),
                   (suffix.isEmpty || after.utf8.prefix(suffix.utf8.count).elementsEqual(suffix.utf8)),
                   text[swiftRange].utf8.elementsEqual(quote.utf8) { matches.append(range) }
            }
            if matches.count > 1 { break }
            cursor = range.location + 1
        }
        guard matches.count == 1, let range = matches.first else { throw invalid(matches.isEmpty ? "原句不在指定片段，或前后文不匹配。" : "原句在指定片段有多个位置，请提供相邻前后文。") }; return range
    }
    private static func anchorIdentity(sourceHash: String, unitID: String, unitTextHash: String, quote: String, range: NSRange) throws -> String {
        let object: [String: Any] = ["sourceHash": sourceHash, "unitID": unitID, "unitTextHash": unitTextHash, "quote": quote, "utf16Location": range.location, "utf16Length": range.length]
        return "anchor." + (try BookImporter.sha256(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])))
    }
    private static func checkReferences(_ ids: [String], state: ReadingExperienceState, minimum: Int) throws {
        guard ids.count >= minimum, ids.count <= 128, Set(ids).count == ids.count else { throw invalid("阅读内容的原文锚点数量不足、过多或重复。") }
        let existing = Set(state.anchors.map(\.id))
        guard ids.allSatisfy(existing.contains) else { throw invalid("阅读内容引用了不存在的原文锚点。") }
    }
    private static func checkProvenance(_ value: ReadingProvenance) throws {
        try nonempty(value.label, maximum: 800)
        if let title = value.workTitle { try nonempty(title, maximum: 800) }
        if let locator = value.locator { try nonempty(locator, maximum: 800) }
        if let text = value.url {
            guard text.utf8.count <= 2_048, let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw invalid("出处链接须为不含凭据的 HTTP(S) 地址。") }
        }
    }
    private static func checkID(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128, value != ".", value != "..", value.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }) else { throw invalid("增强阅读标识无效。") }
    }
    private static func checkKind(_ value: String) throws {
        guard value.utf8.count <= 80 else { throw invalid("增强阅读类型过长。") }; try checkID(value)
    }
    private static func nonempty(_ value: String, maximum: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= maximum else { throw invalid("增强阅读正文或标题为空、过长。") }
    }
    private static func unique(_ values: [String]) throws { guard Set(values).count == values.count else { throw invalid("增强阅读标识重复。") } }
    private static func invalid(_ message: String) -> ReadingError { .invalid(message) }
}
