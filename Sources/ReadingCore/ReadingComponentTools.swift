import Foundation

/// A closed, declarative view request. It never contains executable code or
/// knowledge edits; the host resolves the renderer from its actual registry.
public struct ReadingComponentRequest: Codable, Sendable {
    public let componentID: String
    public let viewID: String?
    public let title: String?
    public let composition: CompositionDefinition?
    public init(componentID: String, viewID: String? = nil, title: String? = nil, composition: CompositionDefinition? = nil) {
        self.componentID = componentID; self.viewID = viewID; self.title = title; self.composition = composition
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32_768, let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys).isSubset(of: ["componentID", "viewID", "title", "composition"]) else { throw ReadingError.invalid("组件请求结构无效。") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard !value.componentID.isEmpty, value.componentID.utf8.count <= 128,
              value.viewID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
              value.title.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 400 }) ?? true,
              value.composition == nil || (value.componentID == "reading.composition" && value.viewID == nil) else { throw ReadingError.invalid("组件名称、标题或组合定义无效。") }
        return value
    }
}

public struct ReadingComponentDirectoryRequest: Codable, Sendable {
    public var offset: Int = 0
    public var limit: Int = 8
    public static func decode(_ data: Data) throws -> Self {
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys).isSubset(of: ["offset", "limit"]) else { throw ReadingError.invalid("组件目录分页参数无效。") }
        struct Options: Decodable { var offset: Int?; var limit: Int? }
        let options = try JSONDecoder().decode(Options.self, from: data)
        let value = Self(offset: options.offset ?? 0, limit: options.limit ?? 8)
        guard (0...128).contains(value.offset), (1...8).contains(value.limit) else { throw ReadingError.invalid("组件目录分页超出界限。") }
        return value
    }
}

extension ReadingQueryToolCatalog {
    static let componentNames: Set<String> = ["components_list", "component_show"]
    static var componentSchemas: [[String: Any]] {
        [function("components_list", "发现宿主实际安装的组件和用途，并分页返回本书已有视图。应先发现再选组件，不凭空猜ID；不返回书中内容。",
            ["offset": ["type": "integer", "minimum": 0, "maximum": 128], "limit": ["type": "integer", "minimum": 1, "maximum": 8]]),
         function("component_show", "按用户当前需求复用或加入一个组件并打开。仅保存新增的视图配置，不新增分析、不覆盖已有布局或正文。自定义组件使用受限组合声明，不能执行代码。结果以真实宿主回执为准。",
            ["componentID": ["type": "string", "minLength": 1, "maxLength": 128],
             "viewID": ["type": "string", "minLength": 1, "maxLength": 128, "description": "复用components_list返回的已有视图；不改其配置。"],
             "title": ["type": "string", "minLength": 1, "maxLength": 400],
             "composition": CompositionSchema.definition], required: ["componentID"])]
    }
}

public struct ReadingComponentInstallation: Sendable {
    public let project: BookProject
    public let view: ViewDefinition
    public let created: Bool
}

extension LibraryRepository {
    /// Load and append in a single actor turn. A frozen chat project must never
    /// overwrite edits, analyses, notes or other components saved in the meantime.
    public func ensureReadingComponent(bookID: String, sourceHash: String, view: ViewDefinition,
                                       equivalentKinds: Set<ComponentKind> = [], grant: ControlledWriteGrant? = nil) throws -> ReadingComponentInstallation {
        try Task.checkCancellation()
        let directory = try bookDirectory(bookID, mustExist: true)
        try recoverDocument(in: directory)
        var current = try readProject(in: directory)
        guard current.sourceHash == sourceHash else { throw ReadingError.invalid("原书版本已改变，未加入组件。") }
        guard view.scope == "current", view.configuration == nil, !view.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReadingError.invalid("只能按需追加当前范围的组件配置。")
        }
        let composition = view.rendererID == "reading.composition"
        guard composition == (view.composition != nil) else { throw ReadingError.invalid("组合组件缺少有效定义。") }
        let match = current.views.first { saved in
            if composition { return saved.rendererID == view.rendererID && saved.composition == view.composition && saved.title == view.title }
            return saved.rendererID == view.rendererID && (view.rendererID != nil || equivalentKinds.union([view.kind]).contains(saved.kind))
        }
        if let match {
            let disabled = current.plugins.contains { current.disabledPluginIDs.contains($0.id) && $0.views.contains { $0.id == match.id } }
            guard !disabled else { throw ReadingError.invalid("此组件属于停用的声明包，请先在插件页启用；没有创建重复副本。") }
            return .init(project: current, view: match, created: false)
        }
        guard current.views.count < 128, !current.views.contains(where: { $0.id == view.id }) else { throw ReadingError.invalid("组件数量达到上限或标识已存在。") }
        if let definition = view.composition {
            guard definition.sources.allSatisfy({ $0.scope == .current }) else { throw ReadingError.invalid("新组件不能扩大原文范围。") }
            try CompositionRuntime.validate(definition, in: current)
        }
        let before = current
        current.views.append(view)
        try Task.checkCancellation()
        let saved = try saveCanonicalProject(current)
        try followOwnComponentAppend(grant: grant, before: before, after: saved)
        return .init(project: saved, view: view, created: true)
    }
}
