import Foundation

public struct Evidence: Codable, Hashable, Sendable {
    public var unitID: String
    public var quote: String
    public init(unitID: String, quote: String) { self.unitID = unitID; self.quote = quote }
}

public struct SourceUnit: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var order: Int
    public var chapter: String
    public var page: Int?
    public var lineStart: Int
    public var lineEnd: Int
    public var text: String
    public var warning: String?
    public init(id: String, order: Int, chapter: String, page: Int? = nil, lineStart: Int = 1, lineEnd: Int = 1, text: String, warning: String? = nil) {
        self.id = id; self.order = order; self.chapter = chapter; self.page = page
        self.lineStart = lineStart; self.lineEnd = lineEnd; self.text = text; self.warning = warning
    }
    public var locator: String { page.map { "第 \($0) 页 · 行 \(lineStart)–\(lineEnd)" } ?? "\(chapter) · 行 \(lineStart)–\(lineEnd)" }
}

public enum UnitStatus: String, Codable, Sendable { case pending, completed, failed, needsReview }
public struct CoverageEntry: Codable, Sendable {
    public var status: UnitStatus = .pending
    public var attempts: Int = 0
    public var message: String = ""
    public var updatedAt: Date = Date()
    public init() {}
}

public struct TypeField: Codable, Hashable, Sendable {
    public var key: String
    public var label: String
    public var required: Bool
    public init(key: String, label: String, required: Bool = false) { self.key = key; self.label = label; self.required = required }
}
public struct EntityType: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var icon: String
    public var fields: [TypeField]
    public init(id: String, name: String, icon: String = "square.stack", fields: [TypeField] = []) { self.id = id; self.name = name; self.icon = icon; self.fields = fields }
}
public struct KnowledgeEntity: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var typeID: String
    public var name: String
    public var summary: String
    public var properties: [String: String]
    public var aliases: [String]
    public var latitude: Double?
    public var longitude: Double?
    public var locationNote: String?
    public var evidence: [Evidence]
    public init(id: String, typeID: String, name: String, summary: String = "", properties: [String: String] = [:], aliases: [String] = [], latitude: Double? = nil, longitude: Double? = nil, locationNote: String? = nil, evidence: [Evidence] = []) {
        self.id = id; self.typeID = typeID; self.name = name; self.summary = summary; self.properties = properties; self.aliases = aliases
        self.latitude = latitude; self.longitude = longitude; self.locationNote = locationNote; self.evidence = evidence
    }
}
public struct KnowledgeEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var dateText: String
    public var startYear: Int?
    public var endYear: Int?
    public var placeIDs: [String]
    public var participantIDs: [String]
    public var evidence: [Evidence]
    public init(id: String, name: String, summary: String = "", dateText: String = "时间待考", startYear: Int? = nil, endYear: Int? = nil, placeIDs: [String] = [], participantIDs: [String] = [], evidence: [Evidence] = []) {
        self.id = id; self.name = name; self.summary = summary; self.dateText = dateText; self.startYear = startYear; self.endYear = endYear
        self.placeIDs = placeIDs; self.participantIDs = participantIDs; self.evidence = evidence
    }
}
public struct KnowledgeRelation: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var fromID: String
    public var toID: String
    public var label: String
    public var evidence: [Evidence]
    public init(id: String, fromID: String, toID: String, label: String, evidence: [Evidence] = []) { self.id = id; self.fromID = fromID; self.toID = toID; self.label = label; self.evidence = evidence }
}
public enum ComponentKind: String, Codable, CaseIterable, Sendable {
    case cards, timeline, map, mindmap, relations, knowledge, editor, query, workflow
    public var title: String {
        switch self {
        case .cards: return "要素卡片"; case .timeline: return "时间轴"; case .map: return "地图"
        case .mindmap: return "思维导图"; case .relations: return "关系图谱"; case .knowledge: return "知识库"
        case .editor: return "写下理解"; case .query: return "与书对话"; case .workflow: return "智能阅读"
        }
    }
    public var icon: String {
        switch self {
        case .cards: return "rectangle.stack"; case .timeline: return "clock"; case .map: return "map"
        case .mindmap: return "point.3.connected.trianglepath.dotted"; case .relations: return "point.3.filled.connected.trianglepath.dotted"
        case .knowledge: return "books.vertical"; case .editor: return "square.and.pencil"; case .query: return "bubble.left.and.bubble.right"; case .workflow: return "arrow.triangle.branch"
        }
    }
}
public struct ViewDefinition: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: ComponentKind
    public var typeIDs: [String]
    /// Namespaced renderer capabilities can extend the legacy component list.
    /// Unknown IDs remain in the archive and receive a readable fallback.
    public var rendererID: String? = nil
    public var scope: String? = nil
    public var configuration: [String: String]? = nil
    public var composition: CompositionDefinition? = nil
    public init(id: String, title: String, kind: ComponentKind, typeIDs: [String] = [], rendererID: String? = nil, scope: String? = nil, configuration: [String: String]? = nil, composition: CompositionDefinition? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.typeIDs = typeIDs
        self.rendererID = rendererID; self.scope = scope; self.configuration = configuration; self.composition = composition
    }
    private enum CodingKeys: String, CodingKey { case id, title, kind, typeIDs, rendererID, scope, configuration, composition }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id); title = try values.decode(String.self, forKey: .title)
        let rawKind = try values.decode(String.self, forKey: .kind)
        kind = ComponentKind(rawValue: rawKind) ?? .knowledge
        typeIDs = try values.decodeIfPresent([String].self, forKey: .typeIDs) ?? []
        rendererID = try values.decodeIfPresent(String.self, forKey: .rendererID)
        if ComponentKind(rawValue: rawKind) == nil, rendererID == nil { rendererID = rawKind }
        scope = try values.decodeIfPresent(String.self, forKey: .scope)
        configuration = try values.decodeIfPresent([String: String].self, forKey: .configuration)
        composition = try values.decodeIfPresent(CompositionDefinition.self, forKey: .composition)
    }
}
public struct ReadingMethod: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var goal: String
    public var steps: [String]
    /// Absent in older projects. Legacy text steps keep their original hash and
    /// are executed by the controlled analysis action when next read.
    public var executions: [ReadingStepExecution]? = nil
    public init(id: String, name: String, goal: String, steps: [String], executions: [ReadingStepExecution]? = nil) {
        self.id = id; self.name = name; self.goal = goal; self.steps = steps; self.executions = executions
    }
}
public struct ReadingPlan: Codable, Sendable {
    public var methodIDs: [String]
    public var rationale: String
    public var focus: [String]
    /// The host still clamps this suggestion to the reader and provider limits.
    public var recommendedParallelism: Int? = nil
    public var recommendedGranularity: ReadingAnalysisGranularity? = nil
    public init(methodIDs: [String] = [], rationale: String = "", focus: [String] = []) { self.methodIDs = methodIDs; self.rationale = rationale; self.focus = focus }
}
public struct ReadingInsight: Codable, Identifiable, Sendable {
    public var id: String
    public var unitIDs: [String]
    public var markdown: String
    public var createdAt: Date
    public init(id: String, unitIDs: [String], markdown: String, createdAt: Date = Date()) { self.id = id; self.unitIDs = unitIDs; self.markdown = markdown; self.createdAt = createdAt }
}
public struct ReadingSynthesis: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var level: Int
    public var unitIDs: [String]
    public var markdown: String
    public init(id: String, title: String, level: Int, unitIDs: [String], markdown: String) { self.id = id; self.title = title; self.level = level; self.unitIDs = unitIDs; self.markdown = markdown }
}
public struct DocumentRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var relativePath: String
    public var origin: String
    public var linkedIDs: [String]
    public var evidence: [Evidence]
    public var createdAt: Date
    public var updatedAt: Date
    /// Missing in older JSON is decoded as nil; Markdown bodies stay in docs/ while trashed.
    public var trashedAt: Date? = nil
    public init(id: String = UUID().uuidString, title: String, relativePath: String = "", origin: String = "user", linkedIDs: [String] = [], evidence: [Evidence] = []) {
        self.id = id; self.title = title; self.relativePath = relativePath.isEmpty ? "docs/\(id).md" : relativePath
        self.origin = origin; self.linkedIDs = linkedIDs; self.evidence = evidence; self.createdAt = Date(); self.updatedAt = Date()
    }
}
public struct CanvasNode: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var targetID: String
    public var x: Double
    public var y: Double
    public var title: String? = nil
    public var documentIDs: [String]? = nil
    public var isStandalone: Bool? = nil
    public init(id: String = UUID().uuidString, targetID: String, x: Double = 0, y: Double = 0) { self.id = id; self.targetID = targetID; self.x = x; self.y = y }
}
public struct CanvasEdge: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var fromID: String
    public var toID: String
    public var label: String
    public init(id: String = UUID().uuidString, fromID: String, toID: String, label: String = "延伸") { self.id = id; self.fromID = fromID; self.toID = toID; self.label = label }
}
public struct ChatMessage: Codable, Identifiable, Sendable {
    public var id: String
    public var role: String
    public var content: String
    public var evidence: [Evidence]
    public var createdAt: Date
    public var conversationMode: ReadingConversationMode? = nil
    public var answerStyle: ReadingAnswerStyle? = nil
    public var readingContext: ReadingChatContext? = nil
    public init(id: String = UUID().uuidString, role: String, content: String, evidence: [Evidence] = []) { self.id = id; self.role = role; self.content = content; self.evidence = evidence; self.createdAt = Date() }
}
public struct ToolAudit: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var createdAt: Date
    public var requestID: String? = nil
    public var requestNumber: Int? = nil
    public var resultDetails: [String]? = nil
    public init(id: String = UUID().uuidString, name: String, summary: String) { self.id = id; self.name = name; self.summary = summary; self.createdAt = Date() }
}
public struct PluginManifest: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var version: Int
    public var description: String
    public var types: [EntityType]
    public var methods: [ReadingMethod]
    public var views: [ViewDefinition]
    public init(id: String, name: String, version: Int = 1, description: String, types: [EntityType] = [], methods: [ReadingMethod] = [], views: [ViewDefinition] = []) {
        self.id = id; self.name = name; self.version = version; self.description = description; self.types = types; self.methods = methods; self.views = views
    }
}

public struct BookProject: Codable, Identifiable, Sendable {
    public var schemaVersion: Int = 1
    public var id: String
    public var title: String
    public var originalName: String
    public var sourceHash: String
    public var importedAt: Date = Date()
    public var units: [SourceUnit]
    public var coverage: [String: CoverageEntry] = [:]
    public var types: [EntityType] = []
    public var entities: [KnowledgeEntity] = []
    public var events: [KnowledgeEvent] = []
    public var relations: [KnowledgeRelation] = []
    public var views: [ViewDefinition] = []
    public var methods: [ReadingMethod] = []
    public var plan: ReadingPlan? = nil
    public var insights: [ReadingInsight] = []
    public var syntheses: [ReadingSynthesis] = []
    public var documents: [DocumentRecord] = []
    public var nodes: [CanvasNode] = []
    public var edges: [CanvasEdge] = []
    public var chats: [ChatMessage] = []
    public var audit: [ToolAudit] = []
    public var aiRequestHistory: [AIRequestHistoryRecord]? = nil
    public var plugins: [PluginManifest] = []
    public var disabledPluginIDs: [String] = []
    public var appliedOperationIDs: [String] = []
    public var lastUnitID: String? = nil
    public var bookmarks: [String] = []
    /// Optional for compatibility with projects created before page OCR existed.
    public var ocrPages: [OCRPageProvenance]? = nil
    /// Absent in older projects: historical completion is never backfilled with invented receipts.
    public var paragraphReceipts: [ParagraphReceipt]? = nil
    public var readingStepResults: [ReadingStepResult]? = nil
    /// Real action checkpoints are never synthesized for historical completion.
    public var workflowRuns: [ReadingWorkflowStepRun]? = nil
    public var receiptBatch: ReadingReceiptBatch? = nil
    /// Frozen user-selected analysis scope; absent in older libraries.
    public var smartReading: SmartReadingSession? = nil
    public var readerAnnotations: [ReaderAnnotation]? = nil
    /// Optional additive metadata; older books are not rewritten or backfilled.
    public var readingExperience: ReadingExperienceState? = nil
    /// Additive host-managed configuration proposals; old archives omit them.
    public var bookSchemes: BookSchemeState? = nil
    /// Deterministic calculations are kept separate from AI prose and source text.
    public var mathVerifications: [MathVerificationRecord]? = nil
    /// Optional temporal sidecar; legacy object IDs and original JSON arrays remain canonical.
    public var temporalKnowledge: TemporalKnowledgeState? = nil
    public var graphGroups: [CanvasGroup]? = nil
    public var controlledChanges: ControlledChangeState? = nil
    /// Host-owned recovery snapshots for ordinary manual removals; absent in older books.
    public var manualTrash: ManualTrashState? = nil
    /// Host-owned AI knowledge history and clearly separated teacher context.
    /// Optional so existing projects keep their original objects and documents.
    public var readingKnowledge: ReadingKnowledgeState? = nil
    /// Host-generated navigation, never a replacement for the original PDF outline.
    /// Missing on older books; source and extraction versions are checked before reuse.
    public var generatedOutline: GeneratedBookOutline? = nil
    /// In-memory delivery order only; never part of library data, grants or caches.
    public internal(set) var publicationStamp: LibraryPublicationStamp? = nil
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, originalName, sourceHash, importedAt, units, coverage, types, entities, events, relations
        case views, methods, plan, insights, syntheses, documents, nodes, edges, chats, audit, aiRequestHistory
        case plugins, disabledPluginIDs, appliedOperationIDs, lastUnitID, bookmarks, ocrPages, paragraphReceipts
        case readingStepResults, workflowRuns, receiptBatch, smartReading, readerAnnotations, readingExperience
        case bookSchemes, mathVerifications, temporalKnowledge, graphGroups, controlledChanges, manualTrash, readingKnowledge, generatedOutline
    }
    public init(id: String = UUID().uuidString, title: String, originalName: String, sourceHash: String, units: [SourceUnit]) {
        self.id = id; self.title = title; self.originalName = originalName; self.sourceHash = sourceHash; self.units = units
    }
    public var completedCount: Int { units.filter { coverage[$0.id]?.status == .completed }.count }
    public var progress: Double { units.isEmpty ? 0 : Double(completedCount) / Double(units.count) }
    public var reviewCount: Int { units.filter { coverage[$0.id]?.status == .needsReview || $0.warning != nil }.count }
    public var isFullyProcessed: Bool { !units.isEmpty && completedCount == units.count && reviewCount == 0 }
    public var activeDocuments: [DocumentRecord] { documents.filter { $0.trashedAt == nil } }
    public var trashedDocuments: [DocumentRecord] { documents.filter { $0.trashedAt != nil } }
}

public struct ProviderSettings: Codable, Sendable {
    public var baseURL: String
    public var model: String
    public var maxRequestsPerRun: Int
    public var maxOutputTokens: Int
    public var contextWindowTokens: Int? = nil
    public var tokenLimitParameter: String? = nil
    /// Host-assigned request context; never persisted with a connection profile.
    public var transportSessionID: String? = nil
    private enum CodingKeys: String, CodingKey {
        case baseURL, model, maxRequestsPerRun, maxOutputTokens, contextWindowTokens, tokenLimitParameter
    }
    public init(baseURL: String = "http://localhost:11434/v1", model: String = "", maxRequestsPerRun: Int = 100, maxOutputTokens: Int = 6000, contextWindowTokens: Int? = nil, tokenLimitParameter: String? = nil) {
        self.baseURL = baseURL; self.model = model; self.maxRequestsPerRun = maxRequestsPerRun; self.maxOutputTokens = maxOutputTokens
        self.contextWindowTokens = contextWindowTokens; self.tokenLimitParameter = tokenLimitParameter
    }
}
public enum ReadingError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}
