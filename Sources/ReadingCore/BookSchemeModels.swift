import Foundation

/// Configuration only. Source, knowledge, Markdown and reading ledgers never enter a scheme snapshot.
public struct BookSchemeConfiguration: Codable, Sendable {
    public var types: [EntityType]
    public var methods: [ReadingMethod]
    public var views: [ViewDefinition]
    public var plan: ReadingPlan?
    public var plugins: [PluginManifest]
    public var disabledPluginIDs: [String]
    public var profile: BookProfile? = nil
    public init(project: BookProject) {
        types = project.types; methods = project.methods
        views = project.views.filter { $0.rendererID != "book.scheme" }
        plan = project.plan; plugins = project.plugins; disabledPluginIDs = project.disabledPluginIDs
        profile = project.temporalKnowledge?.profile
    }
    public func fingerprint() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try BookImporter.sha256(encoder.encode(self))
    }
    public func assign(to project: inout BookProject) {
        let management = project.views.filter { $0.rendererID == "book.scheme" }
        project.types = types; project.methods = methods; project.views = views + management
        project.plan = plan; project.plugins = plugins; project.disabledPluginIDs = disabledPluginIDs
        if project.temporalKnowledge != nil || profile != nil {
            var metadata = project.temporalKnowledge ?? TemporalKnowledgeState(); metadata.profile = profile; project.temporalKnowledge = metadata
        }
    }
}

public struct BookSchemeSelection: Codable, Sendable {
    public var typeIDs: Set<String>
    public var methodIDs: Set<String>
    public var viewIDs: Set<String>
    public init(configuration: BookSchemeConfiguration) {
        typeIDs = Set(configuration.types.map(\.id)); methodIDs = Set(configuration.plan?.methodIDs ?? [])
        viewIDs = Set(configuration.views.map(\.id))
    }
    private enum CodingKeys: String, CodingKey { case typeIDs, methodIDs, viewIDs }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(typeIDs.sorted(), forKey: .typeIDs)
        try values.encode(methodIDs.sorted(), forKey: .methodIDs)
        try values.encode(viewIDs.sorted(), forKey: .viewIDs)
    }
}

public struct BookSchemeProposal: Codable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var title: String
    public var origin: String
    public var createdAt: Date = Date()
    public var before: BookSchemeConfiguration
    public var proposed: BookSchemeConfiguration
    public var selection: BookSchemeSelection
    public var notes: [String]
    /// A proposal cannot be applied to a changed OCR/source layer.
    public var sourceFingerprint: String? = nil
    public init(title: String, origin: String, before: BookSchemeConfiguration, proposed: BookSchemeConfiguration, notes: [String] = []) {
        self.title = title; self.origin = origin; self.before = before; self.proposed = proposed
        self.selection = BookSchemeSelection(configuration: proposed); self.notes = notes
    }
}

public struct BookSchemeRevision: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var appliedAt: Date = Date()
    public var revertedAt: Date? = nil
    public var before: BookSchemeConfiguration
    public var after: BookSchemeConfiguration
    public init(proposal: BookSchemeProposal, after: BookSchemeConfiguration) {
        id = proposal.id; title = proposal.title; before = proposal.before; self.after = after
    }
}

public struct BookSchemeTemplate: Codable, Identifiable, Sendable {
    public var schemaVersion: Int = 1
    public var id: String = UUID().uuidString
    public var name: String
    public var createdAt: Date = Date()
    public var configuration: BookSchemeConfiguration
    public init(name: String, configuration: BookSchemeConfiguration) { self.name = name; self.configuration = configuration }
}

public struct BookSchemeState: Codable, Sendable {
    public var pending: BookSchemeProposal? = nil
    public var history: [BookSchemeRevision] = []
    public var templates: [BookSchemeTemplate] = []
    public init() {}
}
