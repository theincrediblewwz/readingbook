import Foundation

public struct OCRPageProvenance: Codable, Hashable, Sendable {
    public var page: Int
    public var model: String
    public var createdAt: Date
    public var issues: [String]
    public var unitIDs: [String]
}

/// Recognition changes an unused text layer, never the original PDF or old evidence.
public enum OCRIntegration {
    public static func unavailableReason(project: BookProject, page: Int) -> String? {
        guard URL(fileURLWithPath: project.originalName).pathExtension.lowercased() == "pdf" else { return "只有 PDF 可以逐页识别。" }
        let units = project.units.filter { $0.page == page }
        guard !units.isEmpty else { return "页码不存在。" }
        let ids = Set(units.map(\.id))
        let protectedAnchors = (project.readingExperience?.anchors ?? []) + (project.readingExperience?.trash ?? []).flatMap(\.anchors)
        if protectedAnchors.contains(where: { ids.contains($0.unitID) }) { return "此页已有阅读增强或原文锚点，不能覆盖引用正文。请导入为新项目后识别。" }
        if units.contains(where: { project.coverage[$0.id]?.status == .completed }) { return "此页已有完成记录，重新导入原书为新项目后可以重新识别。" }
        if ReadingLedger.hasStoredWork(unitIDs: ids, in: project) { return "此页已有段落回执或读书步骤记录，不能改写账本引用的原文。请导入为新项目后识别。" }
        if project.insights.contains(where: { !ids.isDisjoint(with: $0.unitIDs) && !isEmptyDeferredPlaceholder($0, in: project) }) || project.syntheses.contains(where: { !ids.isDisjoint(with: $0.unitIDs) }) { return "此页已有阅读分析，不能替换其引用正文。" }
        var evidence: [Evidence] = project.entities.flatMap(\.evidence)
        evidence.append(contentsOf: project.events.flatMap(\.evidence))
        evidence.append(contentsOf: project.relations.flatMap(\.evidence))
        evidence.append(contentsOf: project.documents.flatMap(\.evidence))
        evidence.append(contentsOf: project.chats.flatMap(\.evidence))
        if evidence.contains(where: { ids.contains($0.unitID) }) || project.documents.contains(where: { !ids.isDisjoint(with: $0.linkedIDs) }) || project.nodes.contains(where: { ids.contains($0.targetID) }) { return "此页已有笔记或知识引用，不能覆盖。请将原书导入为新项目再识别。" }
        if project.chats.contains(where: { message in ids.contains { message.content.contains("[unit:\($0)]") || message.content.contains("/unit/\($0)") } }) { return "对话含有此页引用，不能替换引用正文。" }
        return nil
    }

    public static func applying(_ result: OCRPageResult, to project: BookProject) throws -> BookProject {
        if let reason = unavailableReason(project: project, page: result.page) { throw ReadingError.invalid(reason) }
        guard result.markdown.utf8.count <= 512 * 1024, !result.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReadingError.invalid("OCR 转录为空或超过单页限制。") }
        let old = project.units.filter { $0.page == result.page }
        let oldIDs = Set(old.map(\.id))
        guard let firstOrder = old.first?.order else { throw ReadingError.invalid("OCR 页不存在。") }
        let fingerprint = String(try BookImporter.sha256(Data(result.markdown.utf8)).prefix(16))
        let notice = "大模型 OCR 转录，尚未人工核对；数学符号、图表和阅读顺序请对照原始 PDF。" + (result.issues.isEmpty ? "" : "\n" + result.issues.joined(separator: "\n"))
        var replacements = try BookImporter.splitText(result.markdown, chapter: old.first?.chapter ?? project.title, page: result.page, warning: notice)
        for index in replacements.indices { replacements[index].id = "ocr-p\(result.page)-\(fingerprint)-\(index)" }
        var updated = project
        // A deferred marker records that no reading took place. Once its empty
        // source is replaced, remove only that exact app-generated placeholder.
        updated.insights.removeAll { !oldIDs.isDisjoint(with: $0.unitIDs) && isEmptyDeferredPlaceholder($0, in: project) }
        updated.units.removeAll { oldIDs.contains($0.id) }
        updated.units.insert(contentsOf: replacements, at: min(firstOrder, updated.units.count))
        guard updated.units.count <= BookImporter.maximumUnits else { throw ReadingError.invalid("OCR 结果超过内容单元上限。") }
        for index in updated.units.indices { updated.units[index].order = index }
        for id in oldIDs { updated.coverage.removeValue(forKey: id) }
        for unit in replacements { var entry = CoverageEntry(); entry.message = notice; updated.coverage[unit.id] = entry }
        if updated.bookmarks.contains(where: { oldIDs.contains($0) }) {
            updated.bookmarks.removeAll { oldIDs.contains($0) }; if let first = replacements.first { updated.bookmarks.append(first.id) }
        }
        if let last = updated.lastUnitID, oldIDs.contains(last) { updated.lastUnitID = nil }
        updated.ocrPages = (updated.ocrPages ?? []).filter { $0.page != result.page }
        updated.ocrPages?.append(OCRPageProvenance(page: result.page, model: result.model, createdAt: result.createdAt, issues: result.issues, unitIDs: replacements.map(\.id)))
        updated.plan = nil // Previews based on the old extraction must be redone.
        updated.audit.append(ToolAudit(name: "pdf_ocr", summary: "第 \(result.page) 页使用 \(result.model) 逐页转录，保留原 PDF；待人工核对，阅读覆盖尚未增加。"))
        return updated
    }

    private static func isEmptyDeferredPlaceholder(_ insight: ReadingInsight, in project: BookProject) -> Bool {
        guard insight.unitIDs.count == 1, let id = insight.unitIDs.first,
              insight.id == "deferred-\(id)",
              let unit = project.units.first(where: { $0.id == id }),
              unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              project.coverage[id]?.status == .needsReview,
              project.coverage[id]?.message == "用户保留本单元为待识别，未读取其中内容。" else { return false }
        return insight.markdown == "【未读取，待识别】\(unit.locator)。该单元尚无可靠文本，不得推断其中的事实。"
    }
}

public enum ProviderProbe {
    public static func validate(settings: ProviderSettings, apiKey: String) throws {
        _ = try ProviderClient.prepare(messages: [["role": "user", "content": "检查配置"]], tools: [], settings: settings, apiKey: apiKey, remainingTokens: settings.contextWindowTokens ?? max(196_000, settings.maxOutputTokens + 64_000))
    }
    public static func test(settings: ProviderSettings, apiKey: String) async throws -> String {
        var probe = settings; probe.maxOutputTokens = min(512, settings.maxOutputTokens)
        let prepared = try ProviderClient.prepare(messages: [["role": "user", "content": "请仅回复 OK。"]], tools: [], settings: probe, apiKey: apiKey, remainingTokens: probe.contextWindowTokens ?? 196_000)
        let result: ProviderClient.Result
        do { result = try await ProviderClient.perform(prepared) }
        catch {
            if error.localizedDescription.contains("输出被截断") { return "服务已返回有效响应，但短测试达到输出上限；推理模型可提高输出预算后实际验证。" }
            throw error
        }
        guard result.finishReason == "stop", let content = result.message.content, !content.isEmpty else { throw ReadingError.invalid("服务未返回完整文本。") }
        return "文本连接正常：" + String(content.prefix(60)) + "。工具调用与图像能力需另行实际使用确认。"
    }
}
