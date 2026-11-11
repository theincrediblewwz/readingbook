import Foundation

/// A closed, declarative view request. It never contains executable code or
/// knowledge edits; the host resolves the renderer from its actual registry.
public struct ReadingComponentRequest: Codable, Sendable {
    public let componentID: String?
    public let viewID: String?
    public let title: String?
    public let composition: CompositionDefinition?
    public let templateID: String?
    public let confirmationOnly: Bool?
    public let layout: [CompositionLayoutNode]?
    public let rootID: String?
    public let layoutRevision: String?
    public let restoreLayout: Bool?
    public let markerAssets: [String: [String: String]]?
    public init(componentID: String? = nil, viewID: String? = nil, title: String? = nil, composition: CompositionDefinition? = nil, templateID: String? = nil, confirmationOnly: Bool? = nil, layout: [CompositionLayoutNode]? = nil, rootID: String? = nil, layoutRevision: String? = nil, restoreLayout: Bool? = nil, markerAssets: [String: [String: String]]? = nil) {
        self.componentID = componentID; self.viewID = viewID; self.title = title; self.composition = composition
        self.templateID = templateID
        self.confirmationOnly = confirmationOnly
        self.layout = layout; self.rootID = rootID; self.layoutRevision = layoutRevision; self.restoreLayout = restoreLayout
        self.markerAssets = markerAssets
    }
    public var resolvedComposition: CompositionDefinition? { templateID.flatMap(ReadingWorkbench.definition(for:)) ?? composition }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32_768, let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys).isSubset(of: ["componentID", "viewID", "title", "composition", "templateID", "confirmationOnly", "layout", "rootID", "layoutRevision", "restoreLayout", "markerAssets"]) else { throw ReadingError.invalid("组件请求结构无效。") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.componentID != nil || value.viewID != nil,
              value.componentID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
              value.viewID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
              value.title.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 400 }) ?? true,
              value.composition == nil || (value.componentID == "reading.composition" && value.viewID == nil) else { throw ReadingError.invalid("组件名称、标题或组合定义无效。") }
        guard value.templateID == nil || (ReadingWorkbench.templateIDs.contains(value.templateID!) && value.componentID == "reading.composition" && value.composition == nil && value.viewID == nil) else { throw ReadingError.invalid("工作台模板无效或与已有视图参数冲突。") }
        if value.layout != nil || value.markerAssets != nil || value.restoreLayout == true {
            guard value.viewID != nil, value.composition == nil, value.templateID == nil, value.title == nil,
                  value.layoutRevision?.utf8.count == 64, value.rootID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
                  value.layout.map({ !$0.isEmpty && $0.count <= 48 }) ?? true,
                  !(value.restoreLayout == true && (value.layout != nil || value.rootID != nil || value.markerAssets != nil)) else { throw ReadingError.invalid("显示调整需已有viewID、最新layoutRevision和layout或markerAssets；恢复上次显示时只加restoreLayout:true。") }
            if let maps = value.markerAssets {
                guard !maps.isEmpty, maps.count <= 24, maps.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw ReadingError.invalid("markerAssets需按1至24个地图元件ID提供映射。") }
                for mappings in maps.values { try SpatialMarkerAssets.validate(mappings) }
            }
        } else if value.rootID != nil || value.layoutRevision != nil { throw ReadingError.invalid("布局版本与rootID只用于明确的布局调整。") }
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
         function("component_show", "按用户当前需求复用或加入组件。已有视图可调整布局或地图素材，保留一份上次显示配置；不改资料绑定、分析或正文。自定义组件使用组合声明，不执行代码，以宿主回执为准。",
            ["componentID": ["type": "string", "minLength": 1, "maxLength": 128, "description": "新建时填目录中的组件种类id，例如reading.composition；不是已保存视图的id。"],
             "viewID": ["type": "string", "minLength": 1, "maxLength": 128, "description": "打开已保存视图只需此项：填components_list返回的views.id，宿主自动识别种类并返回layout/rootID/layoutRevision。小调整用同一viewID加最新版本与layout，不走整本方案。新建才填componentID。"],
             "layout": ["type": "array", "minItems": 1, "maxItems": 48, "items": CompositionSchema.layoutNode, "description": "仅调整已有视图的完整几何布局；引用原有parts.id，不重发sources/parts。"],
             "markerAssets": ["type": "object", "minProperties": 1, "maxProperties": 24, "additionalProperties": CompositionSchema.markerAssets,
                "description": "已有视图的地图元件ID→kind到素材ID的映射；与viewID、最新layoutRevision一起传。仅替换列出的地图映射，不重建组件或事实。地图元件ID和素材目录由打开视图返回。"],
             "rootID": ["type": "string", "maxLength": 128, "description": "调整后的根layout.id；省略沿用原根。"],
             "layoutRevision": ["type": "string", "minLength": 64, "maxLength": 64, "description": "先打开同一视图取得的版本；不猜，不覆盖并发修改。"],
             "restoreLayout": ["type": "boolean", "description": "true恢复上次布局与地图素材；仍需viewID和最新layoutRevision，不传layout或markerAssets。"],
             "title": ["type": "string", "minLength": 1, "maxLength": 400],
             "confirmationOnly": ["type": "boolean", "description": "仅纯打开或切换且无其他任务时设true，宿主随后结束任务；解释、布局/素材调整或整理必须false。先打开查看版本、尚未提交所需调整时也必须false。"],
             "templateID": ["type": "string", "enum": ReadingWorkbench.templateIDs, "description": "两个可选布局：reading-time-map（地图、时间轴与人物）、reading-workbench（人物、关系与笔记）；也可直接组合元件。勿同时传composition/viewID；displayPurpose、actualView仅为返回字段。"],
             "composition": CompositionSchema.definition], required: [])]
    }
}

extension ReadingQuerySession {
    func componentPresentationConfirmation() -> String? {
        guard let lastComponentReceipt, let data = lastComponentReceipt.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["ok"] as? Bool == true, value["status"] as? String == "success", value["opened"] as? Bool == true,
              value["analysisCreated"] as? Bool == false, value["confirmationOnly"] as? Bool == true,
              value["viewID"] as? String != nil, value["rendererID"] as? String != nil else { return nil }
        let title = String((value["componentTitle"] as? String ?? "阅读组件").prefix(80))
        return "已打开“\(title)”。原有资料保留，这次没有重新生成分析。"
    }
    /// UI effects and the model's narrative are separate completion states. An
    /// already completed operation must not disappear behind malformed prose.
    /// A failed later request clears this receipt and cannot reuse old success.
    func componentCompletionFallback() -> String? {
        guard let lastComponentReceipt, let data = lastComponentReceipt.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["ok"] as? Bool == true, value["status"] as? String == "success", value["opened"] as? Bool == true,
              value["analysisCreated"] as? Bool == false, value["viewID"] as? String != nil, value["rendererID"] as? String != nil else { return nil }
        let title = String((value["componentTitle"] as? String ?? "阅读组件").prefix(80))
        return "已打开“\(title)”。模型这次没有返回有效的文字说明，可继续追问。组件操作已完成，不代表新增分析已经完成。"
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
        let matches = current.views.filter { saved in
            if composition { return saved.rendererID == view.rendererID && saved.composition == view.composition && (ReadingWorkbench.isWorkbench(view) || saved.title == view.title) }
            return saved.rendererID == view.rendererID && (view.rendererID != nil || equivalentKinds.union([view.kind]).contains(saved.kind))
        }
        let isDisabled: (ViewDefinition) -> Bool = { candidate in
            current.plugins.contains { current.disabledPluginIDs.contains($0.id) && $0.views.contains { $0.id == candidate.id } }
        }
        if let match = matches.first(where: { $0.configuration?["presentation"] != "inline" }) {
            guard !isDisabled(match) else { throw ReadingError.invalid("此组件属于停用的声明包，请先在插件页启用；没有创建重复副本。") }
            return .init(project: current, view: match, created: false)
        }
        // An inline-only renderer is not a navigable component. Preserve its
        // declaration and add a sidebar view, without bypassing disabled packs.
        guard !matches.contains(where: isDisabled) else { throw ReadingError.invalid("此组件属于停用的声明包，请先在插件页启用；没有创建重复副本。") }
        guard current.views.count < 128, !current.views.contains(where: { $0.id == view.id }) else { throw ReadingError.invalid("组件数量达到上限或标识已存在。") }
        if let definition = view.composition { try CompositionRuntime.validate(definition, in: current) }
        let before = current
        current.views.append(view)
        try Task.checkCancellation()
        let saved = try saveCanonicalProject(current)
        try followOwnComponentAppend(grant: grant, before: before, after: saved)
        return .init(project: saved, view: view, created: true)
    }
}
