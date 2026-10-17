import Foundation

/// Bounded, declarative transactions. No executable code or knowledge is imported by a scheme.
public enum BookSchemeRuntime {
    public static func stageAIProposal(from original: BookProject, proposed: BookProject) throws -> BookProject {
        guard original.bookSchemes?.pending == nil else { throw ReadingError.invalid("请先采纳或放弃当前待确认方案，再重新预读。") }
        var result = original
        let next = BookSchemeConfiguration(project: proposed)
        try PluginEngine.validateSchemeConfiguration(next, in: original)
        var state = original.bookSchemes ?? BookSchemeState()
        state.pending = BookSchemeProposal(title: "AI 预读方案", origin: "ai", before: BookSchemeConfiguration(project: original), proposed: next,
            notes: ["仅依据目录与开头样本；不增加逐段或全文阅读覆盖。", "确认后才启用组件与方法；已有回执、知识对象和 Markdown 不变。"])
        state.pending?.sourceFingerprint = try sourceFingerprint(original)
        result.bookSchemes = state
        result.audit.append(contentsOf: proposed.audit.dropFirst(original.audit.count))
        result.audit.append(ToolAudit(name: "scheme_preview", summary: "AI 预读已生成待确认方案，生产配置未改变。"))
        return result
    }

    public static func updateSelection(_ selection: BookSchemeSelection, in project: inout BookProject) throws {
        guard var state = project.bookSchemes, var pending = state.pending else { throw ReadingError.invalid("没有待确认的书本方案。") }
        pending.selection = selection; state.pending = pending; project.bookSchemes = state
    }

    public static func applyPending(selection: BookSchemeSelection? = nil, in project: inout BookProject) throws {
        guard var state = project.bookSchemes, let pending = state.pending else { throw ReadingError.invalid("没有待确认的书本方案。") }
        guard pending.sourceFingerprint == (try sourceFingerprint(project)) else { throw ReadingError.invalid("原文或 OCR 已改变，请放弃旧预览并重新生成书本方案。") }
        guard try BookSchemeConfiguration(project: project).fingerprint() == pending.before.fingerprint() else {
            throw ReadingError.invalid("预览后配置已经改变。请放弃此预览并重新生成，避免覆盖后续编辑。")
        }
        let selected = selection ?? pending.selection
        var next = pending.proposed
        let priorTypes = Set(pending.before.types.map(\.id))
        guard selected.typeIDs.isSubset(of: Set(next.types.map(\.id))), selected.methodIDs.isSubset(of: Set(next.methods.map(\.id))), selected.viewIDs.isSubset(of: Set(next.views.map(\.id))) else { throw ReadingError.invalid("方案选择引用了不存在的定义。") }
        next.views.removeAll { !selected.viewIDs.contains($0.id) }
        // Historical definitions remain even if unused in the next plan.
        next.types.removeAll { !priorTypes.contains($0.id) && !selected.typeIDs.contains($0.id) }
        // The method picker chooses execution, not deletion from the catalogue.
        if var plan = next.plan {
            let preferred = plan.methodIDs.filter { selected.methodIDs.contains($0) }
            plan.methodIDs = preferred + next.methods.filter { selected.methodIDs.contains($0.id) && !preferred.contains($0.id) }.map(\.id)
            guard !plan.methodIDs.isEmpty else { throw ReadingError.invalid("阅读方案至少选择一种实际执行的读书法。") }
            next.plan = plan
        } else if !selected.methodIDs.isEmpty {
            next.plan = ReadingPlan(methodIDs: next.methods.filter { selected.methodIDs.contains($0.id) }.map(\.id), rationale: "用户选择的书本方案", focus: [])
        }
        // A declaration pack is installed as a whole. Opting out of any new definition
        // requires deselecting its dependent view/method or importing a smaller pack.
        for plugin in next.plugins {
            if let prior = pending.before.plugins.first(where: { $0.id == plugin.id }), try encoded(prior) == encoded(plugin) { continue }
            guard plugin.types.allSatisfy({ t in next.types.contains { $0.id == t.id } }),
                  plugin.methods.allSatisfy({ m in next.methods.contains { $0.id == m.id } }),
                  plugin.views.allSatisfy({ v in next.views.contains { $0.id == v.id } }) else {
                throw ReadingError.invalid("声明包 \(plugin.name) 需要完整定义；请保留包内项目，或放弃本次导入。")
            }
        }
        try PluginEngine.validateSchemeConfiguration(next, in: project)
        var candidate = project; next.assign(to: &candidate)
        state.history.append(BookSchemeRevision(proposal: pending, after: BookSchemeConfiguration(project: candidate)))
        if state.history.count > 20 { state.history.removeFirst(state.history.count - 20) }
        state.pending = nil; candidate.bookSchemes = state
        candidate.audit.append(ToolAudit(name: "scheme_apply", summary: "采纳\(pending.title)；只更新声明配置，已有原文、知识与文档保留。"))
        project = candidate
    }

    public static func discardPending(in project: inout BookProject) {
        project.bookSchemes?.pending = nil
        project.audit.append(ToolAudit(name: "scheme_discard", summary: "放弃待确认方案，已生效配置保持原样。"))
    }

    public static func revertLatest(in project: inout BookProject) throws {
        guard var state = project.bookSchemes, state.pending == nil,
              let index = state.history.lastIndex(where: { $0.revertedAt == nil }) else { throw ReadingError.invalid("请先处理待确认方案；当前没有可撤销的版本。") }
        let revision = state.history[index]
        guard try BookSchemeConfiguration(project: project).fingerprint() == revision.after.fingerprint() else { throw ReadingError.invalid("这次更新之后已有配置编辑，不能安全撤销；后续编辑不会被覆盖。") }
        var restore = revision.before
        // A type/method may now back a real card or a recorded workflow step. Keep
        // immutable schemas instead of deleting the objects or invalidating receipts.
        let usedTypes = Set(project.entities.map(\.typeID))
        for type in project.types where usedTypes.contains(type.id) && !restore.types.contains(where: { $0.id == type.id }) { restore.types.append(type) }
        let usedMethods = Set((project.workflowRuns ?? []).map(\.methodID))
        for method in project.methods where usedMethods.contains(method.id) && !restore.methods.contains(where: { $0.id == method.id }) { restore.methods.append(method) }
        var candidate = project; restore.assign(to: &candidate)
        state.history[index].revertedAt = Date(); candidate.bookSchemes = state
        candidate.audit.append(ToolAudit(name: "scheme_revert", summary: "撤销\(revision.title)的配置；已被知识或流程使用的类型、方法和全部用户内容保留。"))
        project = candidate
    }

    @discardableResult public static func saveTemplate(name: String, in project: inout BookProject) throws -> BookSchemeTemplate {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 120 else { throw ReadingError.invalid("模板名称需为 1–120 字。") }
        var state = project.bookSchemes ?? BookSchemeState()
        guard state.templates.count < 32 else { throw ReadingError.invalid("最多保存 32 个方案模板，请先删除不再使用的模板。") }
        let template = BookSchemeTemplate(name: cleaned, configuration: BookSchemeConfiguration(project: project))
        state.templates.append(template); project.bookSchemes = state; return template
    }

    public static func removeTemplate(id: String, in project: inout BookProject) { project.bookSchemes?.templates.removeAll { $0.id == id } }

    public static func stageTemplate(_ template: BookSchemeTemplate, in project: inout BookProject) throws {
        guard template.schemaVersion == 1, template.name.count <= 120,
              try JSONEncoder().encode(template).count <= 1_000_000 else { throw ReadingError.invalid("方案模板版本或大小不受支持。") }
        guard project.bookSchemes?.pending == nil else { throw ReadingError.invalid("请先处理当前待确认方案。") }
        let before = BookSchemeConfiguration(project: project)
        var next = before
        for type in template.configuration.types {
            if let existing = next.types.first(where: { $0.id == type.id }) { guard existing == type else { throw ReadingError.invalid("模板类型 ID 与本书不同定义冲突：\(type.id)") } }
            else { next.types.append(type) }
        }
        for method in template.configuration.methods {
            if let existing = next.methods.first(where: { $0.id == method.id }) { guard existing == method else { throw ReadingError.invalid("模板方法 ID 与本书不同定义冲突：\(method.id)") } }
            else { next.methods.append(method) }
        }
        // Templates describe the next workspace; unselected old views remain in history.
        next.views = template.configuration.views; next.plan = template.configuration.plan
        for plugin in template.configuration.plugins {
            if let old = next.plugins.first(where: { $0.id == plugin.id }) {
                guard try encoded(old) == encoded(plugin) else { throw ReadingError.invalid("模板声明包版本与本书冲突，请单独预览该插件升级。") }
            } else { next.plugins.append(plugin) }
        }
        let templatePlugins = Set(template.configuration.plugins.map(\.id))
        next.disabledPluginIDs.removeAll { templatePlugins.contains($0) }
        next.disabledPluginIDs.append(contentsOf: template.configuration.disabledPluginIDs.filter { templatePlugins.contains($0) })
        try PluginEngine.validateSchemeConfiguration(next, in: project)
        var state = project.bookSchemes ?? BookSchemeState()
        state.pending = BookSchemeProposal(title: "模板 · \(template.name)", origin: "template", before: before, proposed: next,
            notes: ["仅复用类型、读书法和组件配置，不携带原书、知识或 Markdown。"])
        state.pending?.sourceFingerprint = try sourceFingerprint(project)
        project.bookSchemes = state
    }

    public static func stagePlugin(_ manifest: PluginManifest, in project: inout BookProject) throws {
        guard project.bookSchemes?.pending == nil else { throw ReadingError.invalid("请先处理当前待确认方案。") }
        let before = BookSchemeConfiguration(project: project)
        var candidate = project
        var notes = ["声明包只包含受限数据；不会安装或执行任意代码。"]
        if let old = project.plugins.first(where: { $0.id == manifest.id }) {
            guard manifest.version > old.version else { throw ReadingError.invalid("同 ID 插件须提供更高版本；已有版本不会被覆盖。") }
            // Validate the incoming declaration through the existing install boundary,
            // then remap changed immutable definitions instead of overwriting them.
            var sandbox = BookProject(title: "声明校验", originalName: "", sourceHash: "", units: [])
            PluginEngine.seed(&sandbox)
            sandbox.types.removeAll { t in manifest.types.contains { $0.id == t.id } }
            sandbox.methods.removeAll { m in manifest.methods.contains { $0.id == m.id } }
            // Dependencies not included in this pack may legitimately use book types.
            for type in project.types where !sandbox.types.contains(where: { $0.id == type.id }) && !manifest.types.contains(where: { $0.id == type.id }) { sandbox.types.append(type) }
            try PluginEngine.install(manifest, into: &sandbox)
            var upgraded = manifest
            var typeMap: [String: String] = [:]; var methodMap: [String: String] = [:]
            for index in upgraded.types.indices {
                let type = upgraded.types[index]
                if let current = candidate.types.first(where: { $0.id == type.id }), current != type {
                    guard old.types.contains(where: { isVersion(of: type.id, id: $0.id) }) else { throw ReadingError.invalid("升级类型与其他声明冲突：\(type.id)") }
                    let id = try versionID(type.id, pluginID: manifest.id, version: manifest.version)
                    upgraded.types[index].id = id; typeMap[type.id] = id
                }
                let value = upgraded.types[index]
                if let existing = candidate.types.first(where: { $0.id == value.id }) { guard existing == value else { throw ReadingError.invalid("版本化类型 ID 冲突。") } }
                else { candidate.types.append(value) }
            }
            for index in upgraded.methods.indices {
                let method = upgraded.methods[index]
                if let current = candidate.methods.first(where: { $0.id == method.id }), current != method {
                    guard old.methods.contains(where: { isVersion(of: method.id, id: $0.id) }) else { throw ReadingError.invalid("升级方法与其他声明冲突：\(method.id)") }
                    let id = try versionID(method.id, pluginID: manifest.id, version: manifest.version)
                    upgraded.methods[index].id = id; methodMap[method.id] = id
                }
                let value = upgraded.methods[index]
                for prior in old.methods where isVersion(of: method.id, id: prior.id) { methodMap[prior.id] = value.id }
                if let existing = candidate.methods.first(where: { $0.id == value.id }) { guard existing == value else { throw ReadingError.invalid("版本化方法 ID 冲突。") } }
                else { candidate.methods.append(value) }
            }
            candidate.views.removeAll { v in old.views.contains { $0.id == v.id } }
            for index in upgraded.views.indices {
                upgraded.views[index].typeIDs = upgraded.views[index].typeIDs.map { typeMap[$0] ?? $0 }
                let view = upgraded.views[index]
                guard !candidate.views.contains(where: { $0.id == view.id }) else { throw ReadingError.invalid("升级视图与其他组件 ID 冲突：\(view.id)") }
                candidate.views.append(view)
            }
            if var plan = candidate.plan { plan.methodIDs = plan.methodIDs.map { methodMap[$0] ?? $0 }; candidate.plan = plan }
            candidate.plugins.removeAll { $0.id == old.id }; candidate.plugins.append(upgraded)
            notes.append("\(old.name) v\(old.version) → v\(manifest.version)。改动的类型与方法使用新 ID；旧卡片与流程回执保留原引用。")
            notes.append("已完成的单元不会重新计数；尚未完成的单元按采纳后的步骤继续。")
        } else { try PluginEngine.install(manifest, into: &candidate) }
        let next = BookSchemeConfiguration(project: candidate)
        try PluginEngine.validateSchemeConfiguration(next, in: project)
        var state = project.bookSchemes ?? BookSchemeState()
        state.pending = BookSchemeProposal(title: "\(manifest.name) v\(manifest.version)", origin: "plugin", before: before, proposed: next, notes: notes)
        state.pending?.sourceFingerprint = try sourceFingerprint(project)
        project.bookSchemes = state
    }

    private static func versionID(_ id: String, pluginID: String, version: Int) throws -> String {
        let suffix = String(try BookImporter.sha256(Data("\(pluginID):\(version):\(id)".utf8)).prefix(12))
        return String(id.prefix(108)) + ".v" + suffix
    }
    private static func isVersion(of original: String, id: String) -> Bool { id == original || id.hasPrefix(String(original.prefix(108)) + ".v") }
    private static func sourceFingerprint(_ project: BookProject) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var marks = [project.sourceHash, project.title, project.originalName]
        for unit in project.units { marks.append(try BookImporter.sha256(encoder.encode(unit))) }
        return try BookImporter.sha256(Data(marks.joined(separator: "\n").utf8))
    }
    private static func encoded<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
}
