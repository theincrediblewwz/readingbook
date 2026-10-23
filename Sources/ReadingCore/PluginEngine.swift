import Foundation
import CoreFoundation

/// Built-in plugins share this command boundary. Commands mutate a copy and commit only after validation.
/// Types, methods and views are declarative configuration; knowledge changes always require source evidence.
public enum PluginEngine {
    private static let maximumPayloadBytes = 262_144
    /// Model-callable renderers implemented by the native component registry.
    /// Unknown renderer metadata may be archived by declaration packs, but AI
    /// cannot claim an uninstalled renderer is executable.
    public static let modelRendererKinds: [String: ComponentKind] = [
        "reading.layers": .knowledge, "reading.atlas": .knowledge, "book.scheme": .workflow
    ]
    /// Retirement affects discovery and new execution, never archive decoding.
    public static func isRetiredRenderer(_ id: String) -> Bool {
        ["math.verify", "reading.mentions", "reading.decisions"].contains(id)
    }
    public static func isRetiredAction(_ id: String) -> Bool { id == "math.verify" }
    public static func isActiveMethod(_ method: ReadingMethod) -> Bool {
        !["math-verification-v1", "layered-reading-v1"].contains(method.id) && !(method.executions ?? []).contains { isRetiredAction($0.actionID) }
    }
    public static func activeMethods(in project: BookProject) -> [ReadingMethod] {
        project.methods.filter { isActiveMethod($0) && !isDisabledMethod($0.id, in: project) }
    }
    public static var activeWorkflowActions: [ReadingWorkflowActionDescriptor] {
        ReadingWorkflowRuntime.actions.filter { !isRetiredAction($0.id) }.map { value in
            var result = value
            if result.id == "reading.enrich" {
                result.detail = "把已读原文锚定到适用词语提及、白话或概念解释与资料对齐，实际调用 reading_enrich 保存产物；不适用的类型不强行生成。复用已有实体，资料须有已导入的原文依据。"
            }
            return result
        }
    }
    public static func requireActivePlan(in project: BookProject) throws {
        guard let plan = project.plan else { return }
        guard plan.methodIDs.allSatisfy({ id in project.methods.first(where: { $0.id == id }).map(isActiveMethod) ?? true }) else {
            throw invalid("此阅读方案包含已停用的数学核查或旧版思考卡步骤，请重新预读并确认新方案；已有阅读记录与笔记保留。")
        }
    }

    public static func seed(_ project: inout BookProject) {
        let defaults: [EntityType] = [
            EntityType(id: "person", name: "人物", icon: "person.crop.rectangle", fields: [TypeField(key: "role", label: "身份"), TypeField(key: "affiliation", label: "所属"), TypeField(key: "description", label: "原文描述")]),
            EntityType(id: "place", name: "地点", icon: "mappin.and.ellipse", fields: [TypeField(key: "region", label: "地区"), TypeField(key: "historicalName", label: "历史地名")]),
            EntityType(id: "organization", name: "组织", icon: "person.3", fields: [TypeField(key: "purpose", label: "目的")]),
            EntityType(id: "concept", name: "概念", icon: "lightbulb", fields: [TypeField(key: "definition", label: "定义"), TypeField(key: "examples", label: "例子")]),
            EntityType(id: "definition", name: "定义", icon: "text.book.closed", fields: [TypeField(key: "statement", label: "定义内容"), TypeField(key: "scope", label: "适用范围")]),
            EntityType(id: "theorem", name: "定理", icon: "function", fields: [TypeField(key: "statement", label: "命题"), TypeField(key: "assumptions", label: "前提"), TypeField(key: "proof", label: "证明要点")]),
            EntityType(id: "method", name: "方法", icon: "list.number", fields: [TypeField(key: "purpose", label: "用途"), TypeField(key: "procedure", label: "步骤")]),
            EntityType(id: "argument", name: "论证", icon: "arrow.triangle.branch", fields: [TypeField(key: "premises", label: "前提"), TypeField(key: "conclusion", label: "结论")]),
            EntityType(id: "object", name: "事物", icon: "cube", fields: [TypeField(key: "significance", label: "意义")])
        ]
        for type in defaults where !project.types.contains(where: { $0.id == type.id }) { project.types.append(type) }
        let methods = [
            ReadingMethod(id: "narrative", name: "叙事追踪", goal: "沿原文追踪角色、事件、时空和因果，保留不确定之处。", steps: ["按原文顺序逐单元阅读，包含脚注与题注", "依据证据创建合适的实体与事件", "连接人物、地点、时间及因果", "章节结束回顾变化和未解问题"]),
            ReadingMethod(id: "analytical", name: "论证精读", goal: "辨明问题、概念、论据、推理和反例。", steps: ["逐单元识别作者的问题与主张", "提取定义、前提、结论及证据", "区分作者陈述与读者推断", "回查矛盾、反例和概念变化"]),
            ReadingMethod(id: "textbook", name: "教材学习", goal: "连接定义、定理、证明、例题和先修依赖。", steps: ["逐单元阅读正文、公式、图表与注释", "提取概念、条件、定理和方法", "连接先修依赖并记录证明步骤", "列出理解问题和可练习内容"]),
            ReadingMethod(id: "research", name: "研究笔记", goal: "整理研究问题、方法、材料、发现与局限。", steps: ["逐单元读取材料和方法细节", "记录可核对的发现与证据", "区分来源事实、作者解释和推断", "整理局限、争议及后续问题"]),
            ReadingMethod(id: "active-retelling", name: "主动复述", goal: "逐段用自己的话简短复述，再核对术语、条件与遗漏，提出理解问题。", steps: ["逐段简短复述正文、公式含义及注释，不补充书外信息", "核对术语、限制条件、推理连接及不确定处", "记录自己尚未理解的问题和需要回查的原文"]),
            ReadingMethod(id: "layered-reading-v2", name: "多层伴读", goal: "把已读词句连接到适用的释义、译文、知识对象与资料对齐，使理解可以回到精确原文。", steps: ["复用已有实体及别名，为当前原文建立适用提及、释义或译文与资料对齐；不适用的类型不强造，所有内容锚定原文"])
        ]
        let actionBindings: [String: [String]] = [
            "narrative": ["ai.analyze", "facts.extract", "facts.extract", "reading.review"],
            "analytical": ["ai.analyze", "facts.extract", "ai.analyze", "reading.review"],
            "textbook": ["ai.analyze", "facts.extract", "facts.extract", "reading.review"],
            "research": ["ai.analyze", "facts.extract", "ai.analyze", "reading.review"],
            "active-retelling": ["ai.analyze", "ai.analyze", "reading.review"],
            "layered-reading-v2": ["reading.enrich"]
        ]
        for method in methods where !project.methods.contains(where: { $0.id == method.id }) {
            var executable = method
            executable.steps.append("由宿主核验本单元保存的引文和对象关联；语义疑点继续保留待核对。")
            let actions = (actionBindings[method.id] ?? method.steps.map { _ in "ai.analyze" }) + ["citations.verify"]
            executable.executions = actions.enumerated().map { ReadingStepExecution(stepIndex: $0.offset, actionID: $0.element) }
            project.methods.append(executable)
        }
        for unit in project.units where project.coverage[unit.id] == nil { project.coverage[unit.id] = CoverageEntry() }
        // Views are selected by the reading plan, rather than forcing person cards onto every book.
    }

    /// OpenAI Chat Completions function tools. Optional fields may be omitted; no tool edits user documents.
    private static var builtInToolSchemas: [[String: Any]] {
        let string: [String: Any] = ["type": "string", "maxLength": 32_768]
        let id: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 128, "pattern": "^[A-Za-z0-9_.-]+$", "description": "稳定 ID：1–128 位 ASCII 字母、数字、点、下划线或短横线；实体、事件、文档和关系之间不能重名。"]
        let text: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 400]
        let evidence = object(["unitID": id, "quote": ["type": "string", "minLength": 1, "maxLength": 32_768]], required: ["unitID", "quote"])
        let evidenceList = array(evidence, minimum: 1, maximum: 256)
        let field = object(["key": id, "label": text, "required": ["type": "boolean"]], required: ["key", "label"])
        let type = object(["id": id, "name": text, "icon": ["type": "string", "maxLength": 128], "fields": array(field, maximum: 64)], required: ["id", "name"])
        let view = object(["id": id, "title": text, "kind": ["type": "string", "enum": ComponentKind.allCases.map(\.rawValue)], "typeIDs": array(id, maximum: 128),
                           "rendererID": ["type": "string", "enum": modelRendererKinds.keys.sorted(), "description": "选择实际编译注册的增强阅读渲染器；不提供则使用kind对应默认组件。"],
                           "scope": ["type": "string", "enum": ["current", "book"]],
                           "configuration": ["type": "object", "additionalProperties": ["type": "string", "maxLength": 4000], "maxProperties": 16]], required: ["id", "title", "kind"])
        let execution = object(["stepIndex": ["type": "integer", "minimum": 0, "maximum": 23], "actionID": ["type": "string", "enum": activeWorkflowActions.map(\.id)], "configuration": ["type": "object", "additionalProperties": ["type": "string", "maxLength": 4000], "maxProperties": 16], "maxAttempts": ["type": "integer", "minimum": 1, "maximum": 8]], required: ["stepIndex", "actionID"])
        let method = object(["id": id, "name": text, "goal": ["type": "string", "minLength": 1, "maxLength": 4_000], "steps": array(["type": "string", "minLength": 1, "maxLength": 4_000], minimum: 1, maximum: 24), "executions": array(execution, minimum: 1, maximum: 24)], required: ["id", "name", "goal", "steps"])
        let entity = object([
            "id": id, "typeID": id, "name": text, "summary": string,
            "properties": ["type": "object", "additionalProperties": ["type": "string", "maxLength": 8_000], "maxProperties": 64],
            "aliases": array(text, maximum: 64),
            "latitude": ["type": ["number", "null"], "minimum": -90, "maximum": 90],
            "longitude": ["type": ["number", "null"], "minimum": -180, "maximum": 180],
            "locationNote": ["type": ["string", "null"], "maxLength": 4_000], "evidence": evidenceList
        ], required: ["id", "typeID", "name", "evidence"])
        let event = object([
            "id": id, "name": text, "summary": string, "dateText": ["type": "string", "maxLength": 4_000],
            "startYear": ["type": ["integer", "null"], "minimum": -1_000_000_000_000, "maximum": 1_000_000_000_000], "endYear": ["type": ["integer", "null"], "minimum": -1_000_000_000_000, "maximum": 1_000_000_000_000],
            "placeIDs": array(id, maximum: 128), "participantIDs": array(id, maximum: 128), "evidence": evidenceList
        ], required: ["id", "name", "evidence"])
        let relation = object(["id": id, "fromID": id, "toID": id, "label": text, "evidence": evidenceList], required: ["id", "fromID", "toID", "label", "evidence"])
        let attach = object(["eventID": id, "viewID": id, "title": text, "evidence": evidenceList], required: ["eventID", "evidence"])
        let receipt = object(["paragraphID": id, "textHash": id, "summary": ["type": "string", "minLength": 1, "maxLength": 1200], "startQuote": ["type": "string", "maxLength": 96], "endQuote": ["type": "string", "maxLength": 96], "issues": array(text, maximum: 12)], required: ["paragraphID", "textHash", "summary", "startQuote", "endQuote", "issues"])
        let stepResult = object(["stepID": id, "result": ["type": "string", "minLength": 1, "maxLength": 2000], "paragraphIDs": array(id, minimum: 1, maximum: 512)], required: ["stepID", "result", "paragraphIDs"])
        return [
            function("knowledge_search", "只读查询本书已经保存的实体、事件与文档标题，按名称、别名和概述匹配。创建对象前用它查找索引样本之外的既有对象，避免重复。不会读取未提供的 Markdown 正文，不增加阅读覆盖。", object(["query": ["type": "string", "minLength": 1, "maxLength": 400], "limit": ["type": "integer", "minimum": 1, "maximum": 12]], required: ["query"])),
            function("types_define", "定义通用卡片类型。人物只是默认类型之一；可自定义概念、定理等类型。相同 ID 的既有类型不能被不同定义覆盖。", object(["types": array(type, minimum: 1, maximum: 64)], required: ["types"])),
            function("cards_upsert", "依据当前源单元证据创建或合并实体卡。typeID 必须已存在，properties 的键须已在该类型 fields 声明；坐标必须成对并有依据。重用同一稳定 ID，保留旧证据和信息。", object(["entities": array(entity, minimum: 1, maximum: 128)], required: ["entities"])),
            function("events_upsert", "创建或合并同一知识事件；placeIDs 和 participantIDs 引用既有实体 ID。地图与时间轴共用这个事件 ID。未知年份省略，dateText 保留原文及不确定性。", object(["events": array(event, minimum: 1, maximum: 128)], required: ["events"])),
            function("relations_link", "以证据连接已经存在的实体、事件或文档，不创建悬空引用，不编辑文档正文。", object(["relations": array(relation, minimum: 1, maximum: 128)], required: ["relations"])),
            function("views_configure", "添加或配置当前书适用的组件视图。kind选择默认组件；rendererID可选reading.layers、reading.atlas或book.scheme，使用共享原文、对象和阅读层，不创建独有知识副本。增强插件scope默认current，可选book；configuration为受限声明数据，不执行代码。typeIDs只引用已有类型。", object(["views": array(view, minimum: 1, maximum: 32)], required: ["views"])),
            function("methods_define", "定义读书法的目标、步骤及可执行动作绑定。executions按stepIndex逐项覆盖步骤，actionID从宿主动作注册表选择；未提供时按兼容AI分析动作执行。每步有输入输出、校验与检查点，不能跳过逐段回执。", object(["methods": array(method, minimum: 1, maximum: 32)], required: ["methods"])),
            function("reading_plan", "预读后选择已有读书法，可先自定义；正文阶段只允许增加方法，不能减少现有步骤。正文阶段成功后返回当前全部宿主stepID，finish须完整交齐。该操作不增加正文覆盖。", object(["methodIDs": array(id, minimum: 1, maximum: 16), "rationale": ["type": "string", "minLength": 1, "maxLength": 8_000], "focus": array(text, maximum: 32)], required: ["methodIDs", "rationale", "focus"])),
            function("read_receipt", "仅提交宿主当前batchID清单内的全部片段回执；不得自编清单、遗漏、重复或加入片段。summary用自己的话极简复述本段，保留关键条件、公式和注释；空白段写空白分隔。textHash原样复制，startQuote/endQuote精确复制宿主给出的首尾锚点，issues明确疑点。回执验证齐全后才开放知识抽取。", object(["batchID": id, "receipts": array(receipt, minimum: 1, maximum: 24)], required: ["batchID", "receipts"])),
            function("reading_finish", "全部片段回执齐全后，提交本次全部获准源单元的细读笔记及每个宿主stepID对应的执行结果。stepResults须精确覆盖选定读书法全部步骤，引用本单元paragraphIDs；不适用也写出原因。unitIDs必须与获准单元完全一致；evidence逐一覆盖且quote为连续原文。源提取警告和回执疑点保留待复核。", object(["unitIDs": array(id, minimum: 1, maximum: 128), "markdown": ["type": "string", "minLength": 1, "maxLength": 160_000], "evidence": evidenceList, "stepResults": array(stepResult, minimum: 1, maximum: 384)], required: ["unitIDs", "markdown", "evidence", "stepResults"])),
            function("map_attach", "把已有事件接入地图视图。必须先创建事件及其引用的地点；只使用同一 eventID，不复制事件。没有坐标的地点仍保持待定位，禁止猜造坐标。", attach),
            function("timeline_attach", "把已有事件接入时间轴视图。使用与地图、卡片相同的 eventID；未知时间保留待考文本，不虚构年份。", attach)
        ]
    }

    public static let registry: PluginToolRegistry = {
        do { return try makeRegistry() } catch { preconditionFailure("内置插件注册失败：\(error)") }
    }()
    public static var tools: [[String: Any]] { registry.schemas() }
    public static func apply(name: String, arguments: Data, to project: inout BookProject, allowedUnitIDs: Set<String>, registry: PluginToolRegistry = PluginEngine.registry, phase: PluginToolPhase? = nil) throws -> String {
        try registry.apply(name: name, arguments: arguments, to: &project, allowedUnitIDs: allowedUnitIDs, phase: phase)
    }

    public static func install(_ manifest: PluginManifest, into project: inout BookProject) throws {
        guard try JSONEncoder().encode(manifest).count <= maximumPayloadBytes else { throw invalid("插件声明包超过 256 KiB。") }
        try validateID(manifest.id)
        guard !manifest.id.hasPrefix("builtin.") else { throw invalid("builtin.为内置插件保留标识。") }
        try nonempty(manifest.name, field: "插件名称", maximum: 400)
        guard (1...1_000_000).contains(manifest.version), manifest.description.count <= 8_000 else { throw invalid("插件版本或说明不合法。") }
        guard project.plugins.count < 64, !project.plugins.contains(where: { $0.id == manifest.id }) else { throw invalid("插件 ID 已安装或插件数量达到上限；不会覆盖已有插件。") }
        guard manifest.types.count <= 64, manifest.methods.count <= 32, manifest.views.count <= 32,
              !manifest.types.isEmpty || !manifest.methods.isEmpty || !manifest.views.isEmpty else { throw invalid("插件须包含类型、读书法或视图，且不能超过数量上限。") }
        try uniqueIDs(manifest.types.map(\.id)); try uniqueIDs(manifest.methods.map(\.id)); try uniqueIDs(manifest.views.map(\.id))
        var candidate = project
        for type in manifest.types {
            guard !candidate.types.contains(where: { $0.id == type.id }) else { throw invalid("插件类型 ID 冲突：\(type.id)") }
            try validate(type); candidate.types.append(type)
        }
        for method in manifest.methods {
            guard !candidate.methods.contains(where: { $0.id == method.id }) else { throw invalid("插件读书法 ID 冲突：\(method.id)") }
            guard isActiveMethod(method) else { throw invalid("声明包包含已停用的读书法或动作，请更新声明包后导入。") }
            try validate(method); candidate.methods.append(method)
        }
        for view in manifest.views {
            guard !candidate.views.contains(where: { $0.id == view.id }) else { throw invalid("插件视图 ID 冲突：\(view.id)") }
            guard !isRetiredRenderer(view.rendererID ?? view.id) else { throw invalid("声明包包含已停用组件，请更新声明包后导入。") }
            try validate(view, project: candidate); candidate.views.append(view)
        }
        try validateDefinitionCounts(candidate)
        candidate.plugins.append(manifest)
        candidate.audit.append(ToolAudit(name: "plugin_install", summary: "安装声明式插件 \(manifest.name) v\(manifest.version)"))
        project = candidate
    }

    /// The same declaration validators serve previews and actual installs. Existing
    /// disabled declarations may be archived; only a new plan must use enabled methods.
    public static func validateSchemeConfiguration(_ configuration: BookSchemeConfiguration, in project: BookProject) throws {
        var candidate = project; configuration.assign(to: &candidate)
        try validateDefinitionCounts(candidate)
        try uniqueIDs(candidate.types.map(\.id)); try uniqueIDs(candidate.methods.map(\.id)); try uniqueIDs(candidate.views.map(\.id))
        guard candidate.plugins.count <= 64 else { throw invalid("声明包数量达到上限。") }
        try uniqueIDs(candidate.plugins.map(\.id))
        guard Set(candidate.disabledPluginIDs).isSubset(of: Set(candidate.plugins.map(\.id))) else { throw invalid("停用列表引用了不存在的声明包。") }
        for plugin in candidate.plugins {
            try validateID(plugin.id); try nonempty(plugin.name, field: "插件名称", maximum: 400)
            guard !plugin.id.hasPrefix("builtin."), (1...1_000_000).contains(plugin.version), plugin.description.count <= 8000,
                  plugin.types.count <= 64, plugin.methods.count <= 32, plugin.views.count <= 32,
                  try JSONEncoder().encode(plugin).count <= maximumPayloadBytes else { throw invalid("声明包内容、版本或大小不合法。") }
        }
        let disabled = candidate.disabledPluginIDs; candidate.disabledPluginIDs = []
        for type in candidate.types { try validate(type) }
        for method in candidate.methods {
            try validate(method)
            guard isActiveMethod(method) || project.methods.contains(method) else { throw invalid("新方案不能加入已停用的读书法或动作。") }
        }
        for view in candidate.views {
            try validate(view, project: candidate)
            guard !isRetiredRenderer(view.rendererID ?? view.id) || project.views.contains(view) else { throw invalid("新方案不能加入已停用组件。") }
        }
        candidate.disabledPluginIDs = disabled
        for old in project.types {
            guard candidate.types.contains(old) else { throw invalid("方案不能覆盖或删除已保存类型：\(old.id)") }
        }
        for old in project.methods {
            guard candidate.methods.contains(old) else { throw invalid("方案不能覆盖或删除已有读书法：\(old.id)") }
        }
        if let plan = candidate.plan {
            guard (1...16).contains(plan.methodIDs.count), plan.rationale.count <= 8000, plan.focus.count <= 32,
                  plan.focus.allSatisfy({ !$0.isEmpty && $0.count <= 400 }) else { throw invalid("阅读方案内容或方法数量超过上限。") }
            try uniqueIDs(plan.methodIDs)
            guard plan.methodIDs.allSatisfy({ id in candidate.methods.contains { $0.id == id && isActiveMethod($0) } && !isDisabledMethod(id, in: candidate) }) else { throw invalid("方案引用了不存在或已停用的读书法，请重新选择当前可用的方法。") }
        }
    }

    private static func search(_ input: [String: Any], project: BookProject) throws -> String {
        try keys(input, allowed: ["query", "limit"])
        let query = try string(input, key: "query", maximum: 400)
        let limit = try integer(input, key: "limit") ?? 8
        guard (1...12).contains(limit) else { throw invalid("查询 limit 必须在 1–12 之间。") }
        var matches: [[String: Any]] = []
        for entity in project.entities where matches.count < limit {
            guard ([entity.name, entity.summary] + entity.aliases).contains(where: { $0.localizedCaseInsensitiveContains(query) }) else { continue }
            matches.append(["kind": "entity", "id": entity.id, "typeID": entity.typeID, "name": String(entity.name.prefix(120)), "aliases": entity.aliases.prefix(3).map { String($0.prefix(60)) }, "summary": String(entity.summary.prefix(180)), "sourceUnitIDs": Array(Set(entity.evidence.map(\.unitID))).sorted().prefix(3).map { $0 }])
        }
        for event in project.events where matches.count < limit {
            guard [event.name, event.summary].contains(where: { $0.localizedCaseInsensitiveContains(query) }) else { continue }
            matches.append(["kind": "event", "id": event.id, "name": String(event.name.prefix(120)), "summary": String(event.summary.prefix(180)), "dateText": String(event.dateText.prefix(120)), "placeIDs": Array(event.placeIDs.prefix(3)), "participantIDs": Array(event.participantIDs.prefix(3))])
        }
        for document in project.activeDocuments where matches.count < limit {
            if document.title.localizedCaseInsensitiveContains(query) { matches.append(["kind": "document-metadata", "id": document.id, "title": String(document.title.prefix(160))]) }
        }
        var bounded = false
        while true {
            let data = try JSONSerialization.data(withJSONObject: ["ok": true, "matches": matches, "limit": limit, "bounded": bounded], options: [.sortedKeys])
            guard let text = String(data: data, encoding: .utf8) else { throw invalid("查询结果编码失败。") }
            if text.count <= 14_000 { return text }
            guard !matches.isEmpty else { throw invalid("查询结果无法满足长度限制。") }
            matches.removeLast(); bounded = true
        }
    }

    /// Disabling a declaration pack prevents new use; historical objects and their schemas remain intact.
    public static func setEnabled(_ enabled: Bool, pluginID: String, in project: inout BookProject) throws {
        try validateID(pluginID)
        guard let plugin = project.plugins.first(where: { $0.id == pluginID }) else { throw invalid("插件尚未安装：\(pluginID)") }
        let wasDisabled = project.disabledPluginIDs.contains(pluginID)
        guard wasDisabled == enabled else { return }
        var candidate = project
        if enabled { candidate.disabledPluginIDs.removeAll { $0 == pluginID } }
        else { candidate.disabledPluginIDs.append(pluginID) }
        candidate.audit.append(ToolAudit(name: enabled ? "plugin_enable" : "plugin_disable", summary: "\(enabled ? "启用" : "停用")声明包 \(plugin.name)；已有知识及类型保留。"))
        project = candidate
    }

    private struct BuiltInPlugin: ReadingToolPlugin {
        let info: ReadingPluginInfo
        let tools: [RegisteredReadingTool]
        func register(in registry: inout PluginToolRegistry) throws { for tool in tools { try registry.register(tool) } }
    }
    private static func makeRegistry() throws -> PluginToolRegistry {
        let index = Dictionary(uniqueKeysWithValues: builtInToolSchemas.compactMap { schema -> (String, [String: Any])? in
            guard let function = schema["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            return (name, schema)
        })
        @Sendable func input(_ data: Data) throws -> [String: Any] {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid("工具参数必须是JSON对象。") }
            return value
        }
        var registry = PluginToolRegistry()
        try registry.install(BuiltInPlugin(info: ReadingPluginInfo(id: "builtin.knowledge", name: "知识要素"), tools: [
            try RegisteredReadingTool(pluginID: "builtin.knowledge", schema: index["knowledge_search"]!, phases: [.reading, .workflow], requiresReceipts: false, readOnly: true) { data, project, allowed in try search(input(data), project: project) },
            try RegisteredReadingTool(pluginID: "builtin.knowledge", schema: index["types_define"]!, phases: [.planning, .reading, .workflow], requiresReceipts: false, readOnly: false) { data, project, allowed in try defineTypesTool(input(data), project: &project, allowed: allowed) },
            try RegisteredReadingTool(pluginID: "builtin.knowledge", schema: index["cards_upsert"]!, phases: [.reading, .workflow], requiresReceipts: true, readOnly: false) { data, project, allowed in try cardsTool(input(data), project: &project, allowed: allowed) },
            try RegisteredReadingTool(pluginID: "builtin.knowledge", schema: index["events_upsert"]!, phases: [.reading, .workflow], requiresReceipts: true, readOnly: false) { data, project, allowed in try eventsTool(input(data), project: &project, allowed: allowed) },
            try RegisteredReadingTool(pluginID: "builtin.knowledge", schema: index["relations_link"]!, phases: [.reading, .workflow], requiresReceipts: true, readOnly: false) { data, project, allowed in try relationsTool(input(data), project: &project, allowed: allowed) }
        ]))
        try registry.install(BuiltInPlugin(info: ReadingPluginInfo(id: "builtin.workspace", name: "阅读组件"), tools: [
            try RegisteredReadingTool(pluginID: "builtin.workspace", schema: index["views_configure"]!, phases: [.planning, .reading, .workflow], requiresReceipts: false, readOnly: false) { data, project, allowed in try configureViewsTool(input(data), project: &project, allowed: allowed) },
            try RegisteredReadingTool(pluginID: "builtin.workspace", schema: index["map_attach"]!, phases: [.reading, .workflow], requiresReceipts: true, readOnly: false) { data, project, allowed in try attachTool(input(data), project: &project, allowed: allowed, kind: .map) },
            try RegisteredReadingTool(pluginID: "builtin.workspace", schema: index["timeline_attach"]!, phases: [.reading, .workflow], requiresReceipts: true, readOnly: false) { data, project, allowed in try attachTool(input(data), project: &project, allowed: allowed, kind: .timeline) }
        ]))
        try registry.install(BuiltInPlugin(info: ReadingPluginInfo(id: "builtin.reading", name: "顺序阅读"), tools: [
            try RegisteredReadingTool(pluginID: "builtin.reading", schema: index["methods_define"]!, phases: [.planning, .reading, .workflow], requiresReceipts: false, readOnly: false) { data, project, allowed in try defineMethodsTool(input(data), project: &project, allowed: allowed) },
            try RegisteredReadingTool(pluginID: "builtin.reading", schema: index["reading_plan"]!, phases: [.planning, .reading, .workflow], requiresReceipts: false, readOnly: false) { data, project, allowed in try planTool(input(data), project: &project, allowed: allowed) },
            try RegisteredReadingTool(pluginID: "builtin.reading", schema: index["read_receipt"]!, phases: [.receipt], requiresReceipts: false, readOnly: false) { data, project, allowed in try recordReceiptsTool(input(data), project: &project, allowed: allowed) },
            try RegisteredReadingTool(pluginID: "builtin.reading", schema: index["reading_finish"]!, phases: [.reading], requiresReceipts: true, readOnly: false) { data, project, allowed in try finishTool(input(data), project: &project, allowed: allowed) },
            try RegisteredReadingTool(pluginID: "builtin.reading", schema: ReadingWorkflowRuntime.completionTool, phases: [.workflow], requiresReceipts: true) { data, project, allowed in try ReadingWorkflowRuntime.complete(arguments: data, to: &project, allowedUnitIDs: allowed) }
        ]))
        try registry.install(ReadingExperienceToolPlugin())
        return registry
    }

    private static func recordReceiptsTool(_ input: [String: Any], project: inout BookProject, allowed: Set<String>) throws -> String {
        return try recordReceipts(input, project: &project, allowed: allowed)
    }

    private static func defineTypesTool(_ input: [String: Any], project: inout BookProject, allowed: Set<String>) throws -> String {
        try keys(input, allowed: ["types"])
        let values = try objects(input, key: "types", maximum: 64).map(parseType)
        try uniqueIDs(values.map(\.id))
        for value in values {
            guard !isDisabledType(value.id, in: project) else { throw invalid("该类型由已停用声明包提供：\(value.id)") }
            try validate(value)
            if let old = project.types.first(where: { $0.id == value.id }) {
                guard old == value else { throw invalid("类型 ID 已有不同定义：\(value.id)") }
            } else { project.types.append(value) }
        }
        try validateDefinitionCounts(project)
        return "已登记 \(values.count) 个通用类型。"
    }

    private static func defineMethodsTool(_ input: [String: Any], project: inout BookProject, allowed: Set<String>) throws -> String {
        try keys(input, allowed: ["methods"])
        let values = try objects(input, key: "methods", maximum: 32).map(parseMethod)
        try uniqueIDs(values.map(\.id))
        for value in values {
            guard isActiveMethod(value) else { throw invalid("该读书法使用已停用能力，请选择当前可用的流程动作。") }
            guard !isDisabledMethod(value.id, in: project) else { throw invalid("该读书法由已停用声明包提供：\(value.id)") }
            try validate(value)
            if let old = project.methods.first(where: { $0.id == value.id }) {
                guard old == value else { throw invalid("读书法 ID 已有不同定义：\(value.id)") }
            } else { project.methods.append(value) }
        }
        try validateDefinitionCounts(project)
        return "已登记 \(values.count) 个读书法。"
    }

    private static func configureViewsTool(_ input: [String: Any], project: inout BookProject, allowed: Set<String>) throws -> String {
        try keys(input, allowed: ["views"])
        let values = try objects(input, key: "views", maximum: 32).map(parseView)
        try uniqueIDs(values.map(\.id))
        for value in values { try upsertView(value, project: &project) }
        return "已配置 \(values.count) 个组件视图。"
    }

    private static func planTool(_ input: [String: Any], project: inout BookProject, allowed: Set<String>) throws -> String {
        try keys(input, allowed: ["methodIDs", "rationale", "focus"])
        let ids = try strings(input, key: "methodIDs", required: true, maximum: 16)
        guard !ids.isEmpty else { throw invalid("阅读计划至少选择一种读书法。") }
        try uniqueIDs(ids)
        guard ids.allSatisfy({ id in project.methods.contains(where: { $0.id == id && isActiveMethod($0) }) }) else { throw invalid("阅读计划引用了不存在或已停用的读书法，请重新预读并确认新方案。") }
        guard !ids.contains(where: { isDisabledMethod($0, in: project) }) else { throw invalid("阅读计划不能选择已停用声明包提供的读书法。") }
        if !allowed.isEmpty {
            guard let old = project.plan, Set(old.methodIDs).isSubset(of: Set(ids)) else { throw invalid("正文阶段只能增加读书法，不能删减原方案以跳过步骤；重新改选请另行预读。") }
        }
        let rationale = try string(input, key: "rationale", maximum: 8_000)
        let focus = try strings(input, key: "focus", required: true, maximum: 32)
        project.plan = ReadingPlan(methodIDs: ids, rationale: rationale, focus: focus)
        if !allowed.isEmpty {
            let requirements = try project.units.filter { allowed.contains($0.id) }.flatMap { try ReadingLedger.stepRequirements(for: $0, in: project) }
            let data = try JSONEncoder().encode(requirements)
            guard let text = String(data: data, encoding: .utf8), text.count <= 14_000 else { throw invalid("新增读书法步骤超出当前可返回清单预算；请使用更精简的步骤。") }
            return "已扩展方案；reading_finish须交齐以下全部步骤：\n" + text
        }
        return "已选择 \(ids.count) 种读书法；正文覆盖未改变。"
    }

    private static func cardsTool(_ input: [String: Any], project: inout BookProject, allowed: Set<String>) throws -> String {
        try keys(input, allowed: ["entities"])
        let values = try objects(input, key: "entities", maximum: 128)
        try uniqueIDs(try values.map { try string($0, key: "id", maximum: 128) })
        for value in values { try upsertEntity(value, project: &project, allowed: allowed) }
        return "已创建或合并 \(values.count) 张实体卡，证据已保留。"
    }

    private static func eventsTool(_ input: [String: Any], project: inout BookProject, allowed: Set<String>) throws -> String {
        try keys(input, allowed: ["events"])
        let values = try objects(input, key: "events", maximum: 128)
        try uniqueIDs(try values.map { try string($0, key: "id", maximum: 128) })
        for value in values { try upsertEvent(value, project: &project, allowed: allowed) }
        return "已创建或合并 \(values.count) 个共享事件。"
    }

    private static func relationsTool(_ input: [String: Any], project: inout BookProject, allowed: Set<String>) throws -> String {
        try keys(input, allowed: ["relations"])
        let values = try objects(input, key: "relations", maximum: 128)
        try uniqueIDs(try values.map { try string($0, key: "id", maximum: 128) })
        for value in values {
            try keys(value, allowed: ["id", "fromID", "toID", "label", "evidence"])
            let id = try identifier(value, key: "id"), from = try identifier(value, key: "fromID"), to = try identifier(value, key: "toID")
            let label = try string(value, key: "label", maximum: 400)
            let evidence = try parseEvidence(value, project: project, allowed: allowed)
            guard objectExists(from, in: project), objectExists(to, in: project) else { throw invalid("关系引用了不存在的实体、事件或文档。") }
            guard !project.entities.contains(where: { $0.id == id }), !project.events.contains(where: { $0.id == id }), !project.documents.contains(where: { $0.id == id }) else { throw invalid("关系 ID 与已有知识对象冲突。") }
            if let index = project.relations.firstIndex(where: { $0.id == id }) {
                guard project.relations[index].fromID == from, project.relations[index].toID == to, project.relations[index].label == label else { throw invalid("关系 ID 已指向不同关系。") }
                project.relations[index].evidence = union(project.relations[index].evidence, evidence)
            } else { project.relations.append(KnowledgeRelation(id: id, fromID: from, toID: to, label: label, evidence: evidence)) }
        }
        return "已连接 \(values.count) 条有证据的关系。"
    }

    private static func attachTool(_ input: [String: Any], project: inout BookProject, allowed: Set<String>, kind: ComponentKind) throws -> String {
        try keys(input, allowed: ["eventID", "viewID", "title", "evidence"])
        let id = try identifier(input, key: "eventID")
        guard let index = project.events.firstIndex(where: { $0.id == id }) else { throw invalid("请先创建事件，再把同一事件 ID 接入组件。") }
        let evidence = try parseEvidence(input, project: project, allowed: allowed)
                if kind == .map {
            guard !project.events[index].placeIDs.isEmpty,
                  project.events[index].placeIDs.allSatisfy({ place in project.entities.contains(where: { $0.id == place }) }) else { throw invalid("地图事件必须引用已经存在的地点实体。") }
        }
        let viewID = try optionalString(input, key: "viewID", maximum: 128) ?? kind.rawValue
        try validateID(viewID)
        guard !isDisabledView(viewID, in: project) else { throw invalid("该视图由已停用声明包提供：\(viewID)") }
        let requestedTitle = try optionalString(input, key: "title", maximum: 400)
        if let viewIndex = project.views.firstIndex(where: { $0.id == viewID }) {
            guard project.views[viewIndex].kind == kind else { throw invalid("视图 ID 已属于其他组件。") }
            if let title = requestedTitle { project.views[viewIndex].title = title }
        } else {
            try upsertView(ViewDefinition(id: viewID, title: requestedTitle ?? kind.title, kind: kind), project: &project)
        }
        project.events[index].evidence = union(project.events[index].evidence, evidence)
        return "已将同一事件 \(id) 接入\(kind.title)（视图 \(viewID)）；未复制事件。"
    }

    private static func finishTool(_ input: [String: Any], project: inout BookProject, allowed: Set<String>) throws -> String {
        try ReadingWorkflowRuntime.requireComplete(unitIDs: allowed, in: project)
        return try finish(input, project: &project, allowed: allowed)
    }

    private static func upsertEntity(_ input: [String: Any], project: inout BookProject, allowed: Set<String>) throws {
        try keys(input, allowed: ["id", "typeID", "name", "summary", "properties", "aliases", "latitude", "longitude", "locationNote", "evidence"])
        let id = try identifier(input, key: "id"), typeID = try identifier(input, key: "typeID")
        guard let type = project.types.first(where: { $0.id == typeID }) else { throw invalid("实体类型尚未定义：\(typeID)") }
        guard project.entities.contains(where: { $0.id == id }) || !isDisabledType(typeID, in: project) else { throw invalid("该类型由已停用声明包提供，不能据此新建实体：\(typeID)") }
        guard !project.events.contains(where: { $0.id == id }), !project.documents.contains(where: { $0.id == id }), !project.relations.contains(where: { $0.id == id }) else { throw invalid("实体 ID 与已有知识对象冲突。") }
        let name = try string(input, key: "name", maximum: 400)
        let summary = try optionalString(input, key: "summary", maximum: 32_768, allowEmpty: true) ?? ""
        let properties = try stringMap(input, key: "properties")
        guard Set(properties.keys).isSubset(of: Set(type.fields.map(\.key))) else { throw invalid("实体属性必须先在类型的 fields 中声明。") }
        let aliases = try strings(input, key: "aliases", maximum: 64)
        let latitude = try number(input, key: "latitude"), longitude = try number(input, key: "longitude")
        guard (latitude == nil) == (longitude == nil) else { throw invalid("经纬度必须成对提供，未知时都省略。") }
        if let latitude = latitude, let longitude = longitude {
            guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw invalid("经纬度超出有效范围。") }
        }
        let locationNote = try optionalString(input, key: "locationNote", maximum: 4_000, allowEmpty: true)
        let evidence = try parseEvidence(input, project: project, allowed: allowed)
        if let index = project.entities.firstIndex(where: { $0.id == id }) {
            var old = project.entities[index]
            guard old.typeID == typeID else { throw invalid("已有实体不能通过 upsert 改变类型。") }
            if let oldLatitude = old.latitude, let latitude = latitude, oldLatitude != latitude { throw invalid("坐标与已有实体冲突；请保留原坐标并另行复核。") }
            if let oldLongitude = old.longitude, let longitude = longitude, oldLongitude != longitude { throw invalid("坐标与已有实体冲突；请保留原坐标并另行复核。") }
            if old.name != name { old.aliases = union(old.aliases, [name]) }
            old.aliases = union(old.aliases, aliases)
            old.summary = merge(old.summary, summary)
            for (key, value) in properties { old.properties[key] = merge(old.properties[key] ?? "", value) }
            old.latitude = old.latitude ?? latitude; old.longitude = old.longitude ?? longitude
            if let locationNote = locationNote { old.locationNote = merge(old.locationNote ?? "", locationNote) }
            old.evidence = union(old.evidence, evidence)
            try requiredFields(type, properties: old.properties)
            project.entities[index] = old
        } else {
            try requiredFields(type, properties: properties)
            project.entities.append(KnowledgeEntity(id: id, typeID: typeID, name: name, summary: summary, properties: properties, aliases: union([], aliases), latitude: latitude, longitude: longitude, locationNote: locationNote, evidence: evidence))
        }
    }

    private static func upsertEvent(_ input: [String: Any], project: inout BookProject, allowed: Set<String>) throws {
        try keys(input, allowed: ["id", "name", "summary", "dateText", "startYear", "endYear", "placeIDs", "participantIDs", "evidence"])
        let id = try identifier(input, key: "id"), name = try string(input, key: "name", maximum: 400)
        guard !project.entities.contains(where: { $0.id == id }), !project.documents.contains(where: { $0.id == id }), !project.relations.contains(where: { $0.id == id }) else { throw invalid("事件 ID 与已有知识对象冲突。") }
        let summary = try optionalString(input, key: "summary", maximum: 32_768, allowEmpty: true) ?? ""
        let dateText = try optionalString(input, key: "dateText", maximum: 4_000) ?? "时间待考"
        let start = try integer(input, key: "startYear"), end = try integer(input, key: "endYear")
        guard start.map({ (-1_000_000_000_000...1_000_000_000_000).contains($0) }) ?? true,
              end.map({ (-1_000_000_000_000...1_000_000_000_000).contains($0) }) ?? true else { throw invalid("年份超出可安全显示的范围。") }
        if let start = start, let end = end, start > end { throw invalid("事件开始年份不能晚于结束年份。") }
        let places = try strings(input, key: "placeIDs", maximum: 128), participants = try strings(input, key: "participantIDs", maximum: 128)
        for reference in places + participants {
            try validateID(reference)
            guard project.entities.contains(where: { $0.id == reference }) else { throw invalid("事件引用了不存在的实体：\(reference)") }
        }
        let evidence = try parseEvidence(input, project: project, allowed: allowed)
        if let index = project.events.firstIndex(where: { $0.id == id }) {
            var old = project.events[index]
            if let existing = old.startYear, let start = start, existing != start { throw invalid("事件开始年份与已有记录冲突。") }
            if let existing = old.endYear, let end = end, existing != end { throw invalid("事件结束年份与已有记录冲突。") }
            old.startYear = old.startYear ?? start; old.endYear = old.endYear ?? end
            if let first = old.startYear, let last = old.endYear, first > last { throw invalid("合并后的事件时间顺序不合法。") }
            old.summary = merge(old.summary, summary)
            if old.name != name { old.summary = merge(old.summary, "其他名称：\(name)") }
            if input["dateText"] != nil { old.dateText = old.dateText == "时间待考" ? dateText : merge(old.dateText, dateText) }
            old.placeIDs = union(old.placeIDs, places); old.participantIDs = union(old.participantIDs, participants)
            old.evidence = union(old.evidence, evidence)
            project.events[index] = old
        } else {
            project.events.append(KnowledgeEvent(id: id, name: name, summary: summary, dateText: dateText, startYear: start, endYear: end, placeIDs: union([], places), participantIDs: union([], participants), evidence: evidence))
        }
    }

    private static func finish(_ input: [String: Any], project: inout BookProject, allowed: Set<String>) throws -> String {
        try keys(input, allowed: ["unitIDs", "markdown", "evidence", "stepResults"])
        let ids = try strings(input, key: "unitIDs", required: true, maximum: 128)
        try uniqueIDs(ids)
        guard !allowed.isEmpty, Set(ids) == allowed else { throw invalid("reading_finish 必须完整覆盖本次获准的全部单元，不能遗漏或加入其他单元。") }
        guard allowed.allSatisfy({ id in project.units.contains(where: { $0.id == id }) }) else { throw invalid("阅读范围包含不存在的源单元。") }
        let evidence = try parseEvidence(input, project: project, allowed: allowed)
        guard Set(evidence.map(\.unitID)) == allowed else { throw invalid("细读笔记须为每个获准单元提供原文证据。") }
        let markdown = try string(input, key: "markdown", maximum: 160_000)
        let units = project.units.filter { allowed.contains($0.id) }.sorted { $0.order < $1.order }
        let requirements = try units.flatMap { try ReadingLedger.stepRequirements(for: $0, in: project) }
        let outputs = try objects(input, key: "stepResults", maximum: 384)
        let outputIDs = try outputs.map { try identifier($0, key: "stepID") }
        try uniqueIDs(outputIDs)
        guard Set(outputIDs) == Set(requirements.map(\.stepID)) else { throw invalid("读书法步骤结果必须完整覆盖宿主给出的全部 stepID，不得缺项或自编。") }
        for output in outputs {
            try keys(output, allowed: ["stepID", "result", "paragraphIDs"])
            let stepID = try identifier(output, key: "stepID")
            guard let requirement = requirements.first(where: { $0.stepID == stepID }), let unit = units.first(where: { $0.id == requirement.unitID }) else { throw invalid("步骤来源不存在。") }
            let paragraphIDs = try strings(output, key: "paragraphIDs", required: true, maximum: 512)
            try uniqueIDs(paragraphIDs)
            let available = Set(try ReadingLedger.receipts(for: unit, in: project).map(\.paragraphID))
            guard !paragraphIDs.isEmpty, Set(paragraphIDs).isSubset(of: available) else { throw invalid("步骤结果须引用当前单元已校验的片段。") }
            let result = try string(output, key: "result", maximum: 2000)
            let saved = ReadingStepResult(stepID: stepID, unitID: unit.id, methodID: requirement.methodID, methodHash: requirement.methodHash, stepIndex: requirement.stepIndex, result: result, paragraphIDs: paragraphIDs, createdAt: Date())
            var records = project.readingStepResults ?? []
            if let index = records.firstIndex(where: { $0.stepID == stepID }) {
                guard records[index].result == result, records[index].paragraphIDs == paragraphIDs else { throw invalid("已保存步骤结果不能通过重试静默覆盖。") }
            } else { records.append(saved) }
            project.readingStepResults = records
        }
        let sourceNotes = evidence.map { item -> String in
            let locator = units.first(where: { $0.id == item.unitID })?.locator ?? item.unitID
            let quoted = item.quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
            return "\n\n来源：\(locator)〔\(item.unitID)〕\n\n\(quoted)"
        }.joined()
        let body = markdown + "\n\n---\n原文依据（处理覆盖不等同于理解无遗漏）" + sourceNotes
        let id = "insight." + stableDigest(project.sourceHash + "\n" + ids.sorted().joined(separator: "\n"))
        let existing = project.insights.firstIndex(where: { $0.id == id })
        let repeated = existing.map { project.insights[$0].markdown == body } ?? false
        if let index = existing {
            project.insights[index].markdown = merge(project.insights[index].markdown, body)
        } else { project.insights.append(ReadingInsight(id: id, unitIDs: units.map(\.id), markdown: body)) }
        for unit in units {
            var entry = project.coverage[unit.id] ?? CoverageEntry()
            if !repeated { entry.attempts += 1 }
            let issues = try ReadingLedger.receipts(for: unit, in: project).flatMap(\.issues)
            if let warning = unit.warning {
                entry.status = .needsReview; entry.message = "AI 已处理；源内容待复核：\(warning.isEmpty ? "源提取存在警告" : warning)"
            } else if !issues.isEmpty {
                entry.status = .needsReview; entry.message = "AI 已处理；逐段回执存在待核对问题：" + issues.prefix(3).joined(separator: "；")
            } else if entry.status == .needsReview {
                entry.message = entry.message.isEmpty ? "AI 已处理；保留已有待复核标记。" : entry.message
            } else { entry.status = .completed; entry.message = "逐单元处理已提交，原文依据可核对。" }
            if !repeated { entry.updatedAt = Date() }
            project.coverage[unit.id] = entry
        }
        project.lastUnitID = units.last?.id
        project.receiptBatch = nil
        return "已提交 \(units.count) 个单元的细读笔记；\(units.filter { project.coverage[$0.id]?.status == .needsReview }.count) 个单元仍待复核。"
    }

    private static func recordReceipts(_ input: [String: Any], project: inout BookProject, allowed: Set<String>) throws -> String {
        try keys(input, allowed: ["batchID", "receipts"])
        let batchID = try identifier(input, key: "batchID")
        guard let batch = project.receiptBatch, batch.id == batchID, allowed == [batch.unitID],
              let unit = project.units.first(where: { $0.id == batch.unitID }) else { throw invalid("回执不属于宿主当前获准批次。") }
        let manifest = try ReadingLedger.paragraphs(for: unit, in: project)
        let selected = manifest.filter { batch.paragraphIDs.contains($0.id) }
        let expected = try ReadingLedger.makeBatch(unit: unit, paragraphs: selected)
        guard expected == batch else { throw invalid("宿主批次原文哈希或片段清单已变化。") }
        let values = try objects(input, key: "receipts", maximum: 24)
        let ids = try values.map { try identifier($0, key: "paragraphID") }
        try uniqueIDs(ids)
        guard Set(ids) == Set(batch.paragraphIDs) else { throw invalid("逐段回执必须精确覆盖当前清单，不能遗漏、重复或添加片段。") }
        var records = project.paragraphReceipts ?? []
        _ = try ReadingLedger.receipts(for: unit, in: project)
        for value in values {
            try keys(value, allowed: ["paragraphID", "textHash", "summary", "startQuote", "endQuote", "issues"])
            let id = try identifier(value, key: "paragraphID")
            guard let paragraph = selected.first(where: { $0.id == id }),
                  let start = value["startQuote"] as? String, let end = value["endQuote"] as? String else { throw invalid("回执缺少精确首尾锚点。") }
            let receipt = ParagraphReceipt(paragraphID: id, unitID: unit.id, unitHash: paragraph.unitHash, textHash: try identifier(value, key: "textHash"), utf8Start: paragraph.utf8Start, utf8End: paragraph.utf8End, summary: try string(value, key: "summary", maximum: 1200), startQuote: start, endQuote: end, issues: try strings(value, key: "issues", required: true, maximum: 12), createdAt: Date())
            guard ReadingLedger.matches(receipt, paragraph: paragraph) else { throw invalid("片段回执哈希、范围或首尾原文锚点不匹配：\(id)") }
            if let old = records.first(where: { $0.paragraphID == id }) {
                guard old.summary == receipt.summary, old.startQuote == receipt.startQuote, old.endQuote == receipt.endQuote, old.issues == receipt.issues else { throw invalid("已通过回执不能用重试改写；请保留原核对记录。") }
            } else { records.append(receipt) }
        }
        project.paragraphReceipts = records
        return "已校验并保存 \(values.count) 个片段回执；此检查点尚未完成本单元知识抽取。"
    }

    private static func parseType(_ input: [String: Any]) throws -> EntityType {
        try keys(input, allowed: ["id", "name", "icon", "fields"])
        let fields = try objects(input, key: "fields", required: false, maximum: 64).map { field -> TypeField in
            try keys(field, allowed: ["key", "label", "required"])
            let required: Bool
            if let value = field["required"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid("字段 required 必须为布尔值。") }
                required = number.boolValue
            } else { required = false }
            return TypeField(key: try identifier(field, key: "key"), label: try string(field, key: "label", maximum: 400), required: required)
        }
        return EntityType(id: try identifier(input, key: "id"), name: try string(input, key: "name", maximum: 400), icon: try optionalString(input, key: "icon", maximum: 128) ?? "square.stack", fields: fields)
    }

    private static func parseMethod(_ input: [String: Any]) throws -> ReadingMethod {
        try keys(input, allowed: ["id", "name", "goal", "steps", "executions"])
        var method = ReadingMethod(id: try identifier(input, key: "id"), name: try string(input, key: "name", maximum: 400), goal: try string(input, key: "goal", maximum: 4_000), steps: try strings(input, key: "steps", required: true, maximum: 24, stringMaximum: 4_000))
        if input["executions"] != nil {
            method.executions = try objects(input, key: "executions", maximum: 24).map { item in
                try keys(item, allowed: ["stepIndex", "actionID", "configuration", "maxAttempts"])
                guard let index = try integer(item, key: "stepIndex") else { throw invalid("执行步骤缺少stepIndex。") }
                return ReadingStepExecution(stepIndex: index, actionID: try string(item, key: "actionID", maximum: 128), configuration: try stringMap(item, key: "configuration"), maxAttempts: try integer(item, key: "maxAttempts") ?? 3)
            }
        }
        try ReadingWorkflowRuntime.validate(method: method)
        return method
    }

    private static func parseView(_ input: [String: Any]) throws -> ViewDefinition {
        try keys(input, allowed: ["id", "title", "kind", "typeIDs", "rendererID", "scope", "configuration"])
        guard !isRetiredRenderer(try identifier(input, key: "id")) else { throw invalid("该组件已停用，不能重新添加。") }
        let raw = try string(input, key: "kind", maximum: 128)
        guard let kind = ComponentKind(rawValue: raw) else { throw invalid("未知组件类型：\(raw)") }
        let rendererID = try optionalString(input, key: "rendererID", maximum: 128)
        if let rendererID {
            guard let expectedKind = modelRendererKinds[rendererID] else { throw invalid("视图渲染器尚未注册，不能声称可执行：\(rendererID)") }
            guard expectedKind == kind else { throw invalid("视图渲染器 \(rendererID) 应使用 \(expectedKind.rawValue) 类型。") }
        }
        let scope = try optionalString(input, key: "scope", maximum: 80) ?? (rendererID == nil ? nil : "current")
        if let scope, !["current", "book"].contains(scope) { throw invalid("视图scope须为current或book。") }
        let configuration: [String: String]?
        if input["configuration"] == nil { configuration = nil }
        else { configuration = try stringMap(input, key: "configuration") }
        return ViewDefinition(id: try identifier(input, key: "id"), title: try string(input, key: "title", maximum: 400), kind: kind, typeIDs: try strings(input, key: "typeIDs", maximum: 128), rendererID: rendererID, scope: scope, configuration: configuration)
    }

    private static func validate(_ type: EntityType) throws {
        try validateID(type.id); try nonempty(type.name, field: "类型名称", maximum: 400)
        try nonempty(type.icon, field: "类型图标", maximum: 128)
        guard type.fields.count <= 64 else { throw invalid("类型字段不能超过 64 个。") }
        try uniqueIDs(type.fields.map(\.key))
        for field in type.fields { try nonempty(field.label, field: "字段标签", maximum: 400) }
    }

    private static func validate(_ method: ReadingMethod) throws {
        try validateID(method.id); try nonempty(method.name, field: "读书法名称", maximum: 400)
        try nonempty(method.goal, field: "读书法目标", maximum: 4_000)
        guard (1...24).contains(method.steps.count) else { throw invalid("读书法应包含 1 至 24 个步骤。") }
        for step in method.steps { try nonempty(step, field: "读书法步骤", maximum: 4_000) }
        try ReadingWorkflowRuntime.validate(method: method)
    }

    private static func validate(_ view: ViewDefinition, project: BookProject) throws {
        try validateID(view.id); try nonempty(view.title, field: "视图标题", maximum: 400)
        guard !isDisabledView(view.id, in: project) else { throw invalid("该视图由已停用声明包提供：\(view.id)") }
        guard view.typeIDs.count <= 128 else { throw invalid("视图类型筛选数量超过上限。") }
        try uniqueIDs(view.typeIDs)
        guard view.typeIDs.allSatisfy({ id in project.types.contains(where: { $0.id == id }) }) else { throw invalid("视图引用了尚未定义的实体类型。") }
        guard !view.typeIDs.contains(where: { isDisabledType($0, in: project) }) else { throw invalid("视图不能新选用已停用声明包提供的类型。") }
        if let rendererID = view.rendererID {
            try validateID(rendererID)
            let expectedKind = modelRendererKinds[rendererID] ?? (isRetiredRenderer(rendererID) ? ComponentKind.knowledge : nil)
            if let expectedKind, expectedKind != view.kind { throw invalid("视图渲染器 \(rendererID) 应使用 \(expectedKind.rawValue) 类型。") }
        }
        if let scope = view.scope { try nonempty(scope, field: "组件上下文范围", maximum: 80) }
        if let configuration = view.configuration {
            guard configuration.count <= 16, configuration.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 128 && $0.value.count <= 4000 }) else { throw invalid("组件声明配置超过数量或长度上限。") }
        }
    }

    private static func upsertView(_ view: ViewDefinition, project: inout BookProject) throws {
        try validate(view, project: project)
        if let index = project.views.firstIndex(where: { $0.id == view.id }) {
            guard project.views[index].kind == view.kind, project.views[index].rendererID == view.rendererID else { throw invalid("视图 ID 已属于其他组件或渲染器。") }
            project.views[index] = view
        } else { project.views.append(view) }
        try validateDefinitionCounts(project)
    }

    private static func validateDefinitionCounts(_ project: BookProject) throws {
        guard project.types.count <= 512, project.methods.count <= 128, project.views.count <= 128 else { throw invalid("工作区声明数量达到上限。") }
    }

    private static func isDisabledType(_ id: String, in project: BookProject) -> Bool {
        project.plugins.contains { plugin in
            project.disabledPluginIDs.contains(plugin.id) && plugin.types.contains { $0.id == id }
        }
    }

    private static func isDisabledMethod(_ id: String, in project: BookProject) -> Bool {
        project.plugins.contains { plugin in
            project.disabledPluginIDs.contains(plugin.id) && plugin.methods.contains { $0.id == id }
        }
    }

    private static func isDisabledView(_ id: String, in project: BookProject) -> Bool {
        project.plugins.contains { plugin in
            project.disabledPluginIDs.contains(plugin.id) && plugin.views.contains { $0.id == id }
        }
    }

    private static func requiredFields(_ type: EntityType, properties: [String: String]) throws {
        for field in type.fields where field.required {
            guard let value = properties[field.key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("实体缺少必填属性：\(field.key)") }
        }
    }

    private static func parseEvidence(_ input: [String: Any], project: BookProject, allowed: Set<String>) throws -> [Evidence] {
        let values = try objects(input, key: "evidence", maximum: 256)
        let result = try values.map { value -> Evidence in
            try keys(value, allowed: ["unitID", "quote"])
            let id = try identifier(value, key: "unitID"), quote = try string(value, key: "quote", maximum: 32_768)
            guard allowed.contains(id), let unit = project.units.first(where: { $0.id == id }) else { throw invalid("证据超出本次获准源单元或源单元不存在：\(id)") }
            guard unit.text.contains(quote) else { throw invalid("证据摘录不是源单元中的原文：\(id)") }
            return Evidence(unitID: id, quote: quote)
        }
        return union([], result)
    }

    private static func objectExists(_ id: String, in project: BookProject) -> Bool {
        project.entities.contains { $0.id == id } || project.events.contains { $0.id == id } || project.documents.contains { $0.id == id }
    }

    private static func keys(_ input: [String: Any], allowed: Set<String>) throws {
        let unknown = Set(input.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw invalid("未支持的参数字段：\(unknown.sorted().joined(separator: ", "))") }
    }

    private static func objects(_ input: [String: Any], key: String, required: Bool = true, maximum: Int) throws -> [[String: Any]] {
        guard let value = input[key] else {
            if required { throw invalid("缺少数组：\(key)") }; return []
        }
        guard let values = value as? [Any], values.count <= maximum, !required || !values.isEmpty else { throw invalid("\(key) 必须是非空对象数组且不超过 \(maximum) 项。") }
        return try values.map { value in
            guard let object = value as? [String: Any] else { throw invalid("\(key) 中每项必须是对象。") }; return object
        }
    }

    private static func string(_ input: [String: Any], key: String, maximum: Int) throws -> String {
        guard let value = input[key] as? String else { throw invalid("缺少字符串：\(key)") }
        try nonempty(value, field: key, maximum: maximum); return value
    }

    private static func optionalString(_ input: [String: Any], key: String, maximum: Int, allowEmpty: Bool = false) throws -> String? {
        guard let value = input[key], !(value is NSNull) else { return nil }
        guard let text = value as? String, text.count <= maximum else { throw invalid("\(key) 必须是字符串且不超过 \(maximum) 字符。") }
        if !allowEmpty { try nonempty(text, field: key, maximum: maximum) }; return text
    }

    private static func strings(_ input: [String: Any], key: String, required: Bool = false, maximum: Int, stringMaximum: Int = 400) throws -> [String] {
        guard let value = input[key] else { if required { throw invalid("缺少字符串数组：\(key)") }; return [] }
        guard let values = value as? [Any], values.count <= maximum else { throw invalid("\(key) 必须是字符串数组且不超过 \(maximum) 项。") }
        return try values.map { value in
            guard let text = value as? String else { throw invalid("\(key) 中每项必须是字符串。") }
            try nonempty(text, field: key, maximum: stringMaximum); return text
        }
    }

    private static func stringMap(_ input: [String: Any], key: String) throws -> [String: String] {
        guard let value = input[key] else { return [:] }
        guard let values = value as? [String: Any], values.count <= 64 else { throw invalid("\(key) 必须是最多 64 项的字符串属性对象。") }
        var result: [String: String] = [:]
        for (key, value) in values {
            try validateID(key)
            guard let text = value as? String, text.count <= 8_000 else { throw invalid("实体属性值必须为字符串且不超过 8000 字符。") }
            result[key] = text
        }
        return result
    }

    private static func number(_ input: [String: Any], key: String) throws -> Double? {
        guard let value = input[key], !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw invalid("\(key) 必须是有限数值。") }
        return number.doubleValue
    }

    private static func integer(_ input: [String: Any], key: String) throws -> Int? {
        guard let number = try number(input, key: key) else { return nil }
        guard number.rounded(.towardZero) == number, let result = Int(exactly: number) else { throw invalid("\(key) 必须是有效整数。") }
        return result
    }

    private static func identifier(_ input: [String: Any], key: String) throws -> String {
        let id = try string(input, key: key, maximum: 128); try validateID(id); return id
    }

    private static func validateID(_ id: String) throws {
        let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard !id.isEmpty, id != ".", id != "..", id.count <= 128, id.unicodeScalars.allSatisfy({ permitted.contains($0) }) else { throw invalid("ID 不能为空或仅为点，且须为最多 128 位 ASCII 字母、数字、点、下划线或短横线。") }
    }

    private static func nonempty(_ value: String, field: String, maximum: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= maximum else { throw invalid("\(field) 不能为空且不能超过 \(maximum) 字符。") }
    }

    private static func uniqueIDs(_ ids: [String]) throws {
        guard Set(ids).count == ids.count else { throw invalid("同一声明中出现重复 ID。") }
        for id in ids { try validateID(id) }
    }

    private static func union<T: Hashable>(_ old: [T], _ new: [T]) -> [T] {
        var seen = Set<T>(); return (old + new).filter { seen.insert($0).inserted }
    }

    private static func merge(_ old: String, _ new: String) -> String {
        if new.isEmpty || old.contains(new) { return old }
        if old.isEmpty { return new }; return old + "\n\n" + new
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }

    private static func invalid(_ message: String) -> ReadingError { .invalid(message) }
    private static func object(_ properties: [String: Any], required: [String]) -> [String: Any] { ["type": "object", "properties": properties, "required": required, "additionalProperties": false] }
    private static func array(_ items: [String: Any], minimum: Int = 0, maximum: Int) -> [String: Any] { ["type": "array", "items": items, "minItems": minimum, "maxItems": maximum] }
    private static func function(_ name: String, _ description: String, _ parameters: [String: Any]) -> [String: Any] { ["type": "function", "function": ["name": name, "description": description, "parameters": parameters]] }
}
