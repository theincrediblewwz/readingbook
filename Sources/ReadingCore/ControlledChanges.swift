import Foundation

public enum ControlledChangeGroup: String, Codable, Hashable, Sendable { case knowledge, graph, documents, bookScheme }
public enum ControlledChangeError: LocalizedError {
    case invalid(String), denied(String), conflict(String), unsupported(String)
    public var errorDescription: String? {
        switch self { case .invalid(let value), .denied(let value), .conflict(let value), .unsupported(let value): return value }
    }
}

/// Only the repository can issue these values. They are deliberately not
/// Decodable: model arguments cannot manufacture host authorization.
public struct ControlledWriteGrant: Hashable, Sendable {
    public let id: String
    public let bookID: String
    public let sourceHash: String
    public let baseRevision: String
    public let grantRevision: Int
    public let permissions: Set<ControlledChangeGroup>
    public let allowedUnitIDs: Set<String>
    public let editableDocumentIDs: Set<String>
    public let requiresReceipts: Bool
    public let reason: String
    public let expiresAt: Date
}

public struct ProposedSourceAnchor: Codable, Sendable {
    public var clientID: String
    public var unitID: String
    public var quote: String
    public var prefix: String?
    public var suffix: String?
    public init(clientID: String, unitID: String, quote: String, prefix: String? = nil, suffix: String? = nil) {
        self.clientID = clientID; self.unitID = unitID; self.quote = quote; self.prefix = prefix; self.suffix = suffix
    }
}

/// New-ID lists explicitly distinguish client aliases from existing host IDs.
/// New temporal and reading records are append-only, with client IDs remapped.
public struct ControlledKnowledgeChanges: Codable, Sendable {
    public var newTypeIDs: [String]?
    public var newEntityIDs: [String]?
    public var newEventIDs: [String]?
    public var newRelationIDs: [String]?
    public var types: [EntityType]?
    public var entities: [KnowledgeEntity]?
    public var events: [KnowledgeEvent]?
    public var relations: [KnowledgeRelation]?
    public var anchors: [ProposedSourceAnchor]?
    public var presences: [EntityPresence]?
    public var participations: [Participation]?
    public var eventMetadata: [EventTemporalMetadata]?
    public var relationMetadata: [RelationTemporalMetadata]?
    public var layers: [ReadingLayer]?
    public var alignments: [ReferenceAlignment]?
    public init(types: [EntityType]? = nil, entities: [KnowledgeEntity]? = nil, events: [KnowledgeEvent]? = nil, relations: [KnowledgeRelation]? = nil,
                newTypeIDs: [String]? = nil, newEntityIDs: [String]? = nil, newEventIDs: [String]? = nil, newRelationIDs: [String]? = nil,
                anchors: [ProposedSourceAnchor]? = nil, presences: [EntityPresence]? = nil, participations: [Participation]? = nil,
                eventMetadata: [EventTemporalMetadata]? = nil, relationMetadata: [RelationTemporalMetadata]? = nil, layers: [ReadingLayer]? = nil, alignments: [ReferenceAlignment]? = nil) {
        self.types = types; self.entities = entities; self.events = events; self.relations = relations
        self.newTypeIDs = newTypeIDs; self.newEntityIDs = newEntityIDs; self.newEventIDs = newEventIDs; self.newRelationIDs = newRelationIDs
        self.anchors = anchors; self.presences = presences; self.participations = participations; self.eventMetadata = eventMetadata; self.relationMetadata = relationMetadata; self.layers = layers; self.alignments = alignments
    }
}

public struct ControlledNodeCreation: Codable, Sendable {
    public var clientID: String; public var title: String; public var targetID: String?; public var documentIDs: [String]?
    public var x: Double; public var y: Double
    public init(clientID: String, title: String, targetID: String? = nil, documentIDs: [String]? = nil, x: Double = 0, y: Double = 0) {
        self.clientID = clientID; self.title = title; self.targetID = targetID; self.documentIDs = documentIDs; self.x = x; self.y = y
    }
}
public struct ControlledAttachment: Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case attach, detach }
    public var nodeID: String; public var documentIDs: [String]; public var mode: Mode
    public init(nodeID: String, documentIDs: [String], mode: Mode) { self.nodeID = nodeID; self.documentIDs = documentIDs; self.mode = mode }
}
public struct ControlledConnection: Codable, Sendable {
    public var clientID: String; public var fromNodeID: String; public var toNodeID: String; public var label: String
    public init(clientID: String, fromNodeID: String, toNodeID: String, label: String) { self.clientID = clientID; self.fromNodeID = fromNodeID; self.toNodeID = toNodeID; self.label = label }
}
public struct ControlledNodeMove: Codable, Sendable {
    public var nodeID: String; public var x: Double; public var y: Double
    public init(nodeID: String, x: Double, y: Double) { self.nodeID = nodeID; self.x = x; self.y = y }
}
public struct ControlledNodeRename: Codable, Sendable {
    public var nodeID: String; public var title: String
    public init(nodeID: String, title: String) { self.nodeID = nodeID; self.title = title }
}
public struct CanvasGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: String; public var title: String; public var nodeIDs: [String]; public var childGroupIDs: [String]
    public init(id: String, title: String, nodeIDs: [String] = [], childGroupIDs: [String] = []) { self.id = id; self.title = title; self.nodeIDs = nodeIDs; self.childGroupIDs = childGroupIDs }
}
public struct ControlledGroupCreation: Codable, Sendable {
    public var clientID: String; public var title: String; public var nodeIDs: [String]; public var childGroupIDs: [String]
    public init(clientID: String, title: String, nodeIDs: [String] = [], childGroupIDs: [String] = []) { self.clientID = clientID; self.title = title; self.nodeIDs = nodeIDs; self.childGroupIDs = childGroupIDs }
}
public struct ControlledGroupMove: Codable, Sendable {
    public var groupID: String; public var deltaX: Double; public var deltaY: Double
    public init(groupID: String, deltaX: Double, deltaY: Double) { self.groupID = groupID; self.deltaX = deltaX; self.deltaY = deltaY }
}
public struct ControlledGraphChanges: Codable, Sendable {
    public var createNodes: [ControlledNodeCreation]?
    public var attachments: [ControlledAttachment]?
    public var connections: [ControlledConnection]?
    public var moves: [ControlledNodeMove]?
    public var renames: [ControlledNodeRename]?
    public var removeNodeIDs: [String]?
    public var removeEdgeIDs: [String]?
    public var createGroups: [ControlledGroupCreation]?
    public var moveGroups: [ControlledGroupMove]?
    public init(createNodes: [ControlledNodeCreation]? = nil, attachments: [ControlledAttachment]? = nil, connections: [ControlledConnection]? = nil, moves: [ControlledNodeMove]? = nil, renames: [ControlledNodeRename]? = nil, removeNodeIDs: [String]? = nil, removeEdgeIDs: [String]? = nil, createGroups: [ControlledGroupCreation]? = nil, moveGroups: [ControlledGroupMove]? = nil) {
        self.createNodes = createNodes; self.attachments = attachments; self.connections = connections; self.moves = moves; self.renames = renames
        self.removeNodeIDs = removeNodeIDs; self.removeEdgeIDs = removeEdgeIDs; self.createGroups = createGroups; self.moveGroups = moveGroups
    }
}

public struct ControlledDocumentCreation: Codable, Sendable {
    public var clientID: String; public var title: String; public var markdown: String
    public var linkedIDs: [String]?; public var evidence: [Evidence]?
    public init(clientID: String, title: String, markdown: String, linkedIDs: [String]? = nil, evidence: [Evidence]? = nil) { self.clientID = clientID; self.title = title; self.markdown = markdown; self.linkedIDs = linkedIDs; self.evidence = evidence }
}
public struct ControlledDocumentEdit: Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case replace, append }
    public var documentID: String; public var expectedHash: String; public var mode: Mode; public var markdown: String
    public init(documentID: String, expectedHash: String, mode: Mode, markdown: String) { self.documentID = documentID; self.expectedHash = expectedHash; self.mode = mode; self.markdown = markdown }
}
public struct ControlledDocumentChanges: Codable, Sendable {
    public var create: [ControlledDocumentCreation]?
    public var edits: [ControlledDocumentEdit]?
    public init(create: [ControlledDocumentCreation]? = nil, edits: [ControlledDocumentEdit]? = nil) { self.create = create; self.edits = edits }
}
public struct ControlledBookSchemeChanges: Codable, Sendable {
    public var types: [EntityType]?; public var methods: [ReadingMethod]?; public var views: [ViewDefinition]?
    public var plan: ReadingPlan?; public var profile: BookProfile?
    public init(types: [EntityType]? = nil, methods: [ReadingMethod]? = nil, views: [ViewDefinition]? = nil, plan: ReadingPlan? = nil, profile: BookProfile? = nil) { self.types = types; self.methods = methods; self.views = views; self.plan = plan; self.profile = profile }
}
public struct ControlledChangeBatch: Codable, Sendable {
    public var knowledge: ControlledKnowledgeChanges?
    public var graph: ControlledGraphChanges?
    public var documents: ControlledDocumentChanges?
    public var bookScheme: ControlledBookSchemeChanges?
    public init(knowledge: ControlledKnowledgeChanges? = nil, graph: ControlledGraphChanges? = nil, documents: ControlledDocumentChanges? = nil, bookScheme: ControlledBookSchemeChanges? = nil) { self.knowledge = knowledge; self.graph = graph; self.documents = documents; self.bookScheme = bookScheme }
}

public struct ControlledDocumentPreview: Codable, Sendable {
    public var documentID: String; public var title: String; public var before: String?; public var after: String
    public var expectedHash: String?; public var afterHash: String
}
public struct ControlledChangeProposal: Codable, Sendable {
    public let id: String; public let operationID: String; public let bookID: String; public let digest: String; public let baseRevision: String
    public let groups: [ControlledChangeGroup]; public let requiresConfirmation: Bool
    public let idMap: [String: String]; public let summary: [String]; public let documents: [ControlledDocumentPreview]
}
public struct ControlledChangeApproval: Sendable {
    public let proposalID: String; public let digest: String
    let token: String
}
public enum ControlledChangeCollection: String, Codable, Sendable {
    case types, entities, events, relations, nodes, edges, graphGroups, documents
    case temporalAnchors, presences, participations, eventMetadata, relationMetadata, experienceAnchors, layers, alignments, bookSchemes
}
public struct ControlledRecordPatch: Codable, Sendable {
    public var collection: ControlledChangeCollection; public var id: String; public var before: Data?; public var after: Data?
}
public struct ControlledDocumentReceipt: Codable, Sendable {
    public var documentID: String; public var afterHash: String; public var beforeHash: String?; public var backupDocumentID: String?
}
public struct ControlledChangeReceipt: Codable, Identifiable, Sendable {
    public var id: String { operationID }
    public var operationID: String; public var originBookID: String; public var digest: String; public var grantID: String
    public var createdAt: Date; public var undoneAt: Date?
    public var idMap: [String: String]; public var groups: [ControlledChangeGroup]
    public var patches: [ControlledRecordPatch]; public var documents: [ControlledDocumentReceipt]
}
public struct ControlledChangeState: Codable, Sendable {
    public var version: Int = 1
    public var receipts: [ControlledChangeReceipt] = []
    public init() {}
}
public struct ControlledChangeCommitResult: Sendable {
    public var project: BookProject; public var receipt: ControlledChangeReceipt; public var replayed: Bool
}

struct PreparedControlledChange: Sendable {
    var proposal: ControlledChangeProposal
    var project: BookProject
    var bodies: [String: Data]
    var beforeBodies: [String: Data]
    var patches: [ControlledRecordPatch]
}

enum ControlledChangeCoding {
    static func data<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    static func hash<T: Encodable>(_ value: T) throws -> String { try BookImporter.sha256(data(value)) }
    static func validID(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil }
    static func requireID(_ value: String) throws { guard validID(value) else { throw ControlledChangeError.invalid("业务 ID 格式无效。") } }
    static func text(_ value: String, maximum: Int, empty: Bool = false) throws {
        guard value.utf8.count <= maximum, !value.contains("\0"), empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ControlledChangeError.invalid("业务文本为空或超过安全上限。") }
    }
}
