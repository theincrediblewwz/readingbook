import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ReadingCore

@MainActor extension AppStore {
    func openBookScheme() {
        guard book != nil else { return }
        route = "book.scheme"
    }

    func applyBookScheme(_ selection: BookSchemeSelection) {
        mutateBookScheme("书本方案已采纳；已有原文、知识和文档保留，可主动继续智能阅读。", onSaved: { self.smartReadingPlanReady = false }) { project in
            try BookSchemeRuntime.applyPending(selection: selection, in: &project)
            if project.smartReading != nil {
                project.smartReading?.status = .ready; project.smartReading?.isPlanConfirmed = true
                project.smartReading?.updatedAt = Date(); project.smartReading?.lastMessage = "方案已确认；点击继续才开始新的请求。"
            }
        }
    }
    func saveBookSchemeSelection(_ selection: BookSchemeSelection, onSaved: (() -> Void)? = nil) {
        mutateBookScheme("方案调整已保存，尚未启用。", onSaved: onSaved) { try BookSchemeRuntime.updateSelection(selection, in: &$0) }
    }
    func discardBookScheme() {
        mutateBookScheme("待确认方案已放弃，继续使用原来的配置。", onSaved: { self.smartReadingPlanReady = false }) { project in
            let unconfirmed = project.smartReading?.isPlanConfirmed == false
            BookSchemeRuntime.discardPending(in: &project)
            if unconfirmed {
                if project.plan == nil { project.smartReading = nil }
                else {
                    project.smartReading?.status = .ready; project.smartReading?.isPlanConfirmed = true
                    project.smartReading?.updatedAt = Date()
                    project.smartReading?.lastMessage = "已放弃新方案。可沿用此前方案分析已选范围，或重新选择方法和范围；不会自动请求。"
                }
            }
        }
    }
    func revertBookScheme() {
        mutateBookScheme("最近一次方案更新已撤销；用户 Markdown、知识对象和阅读记录保留。") { try BookSchemeRuntime.revertLatest(in: &$0) }
    }
    func saveBookSchemeTemplate(name: String, onSaved: (() -> Void)? = nil) {
        mutateBookScheme("已保存当前生效方案模板，可预览复用或导出。", onSaved: onSaved) { _ = try BookSchemeRuntime.saveTemplate(name: name, in: &$0) }
    }
    func stageBookSchemeTemplate(_ template: BookSchemeTemplate) {
        mutateBookScheme("模板已生成待确认方案，当前配置尚未改变。") { try BookSchemeRuntime.stageTemplate(template, in: &$0) }
    }
    func deleteBookSchemeTemplate(_ id: String) {
        mutateBookScheme("方案模板已删除；已生效方案和阅读内容保留。") { BookSchemeRuntime.removeTemplate(id: id, in: &$0) }
    }

    func previewImportPlugin(onError: ((String) -> Void)? = nil) {
        guard var current = book, !isBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.message = "选择声明式插件 manifest.json；同 ID 新版本会先显示升级预览。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_000_000 else { throw ReadingError.invalid("声明包超过 1 MB。") }
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url))
            try BookSchemeRuntime.stagePlugin(manifest, in: &current)
            guard bookID == current.id else { throw ReadingError.invalid("书籍已切换，请重新导入。") }
            isBusy = true; isCommittingLocalWrite = true
            Task {
                defer { isBusy = false; isCommittingLocalWrite = false }
                do {
                    try await repository.save(current); publish(current)
                    isBusy = false; openBookScheme(); showingPlugins = false
                    activity = "\(manifest.name) 的声明方案待确认，尚未安装或升级。"
                } catch { if let onError { onError(error.localizedDescription) } else { errorMessage = error.localizedDescription } }
            }
        } catch { if let onError { onError(error.localizedDescription) } else { errorMessage = error.localizedDescription } }
    }

    func exportBookSchemeTemplate(_ template: BookSchemeTemplate) {
        guard !isBusy else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "\(template.name).book-scheme.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(template).write(to: url, options: [.atomic]); activity = "已导出声明式方案模板；不包含原书和笔记。"
        } catch { errorMessage = error.localizedDescription }
    }
    func importBookSchemeTemplate() {
        guard book != nil, !isBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.message = "导入方案模板并预览；确认之前不改本书配置。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_000_000 else { throw ReadingError.invalid("模板超过 1 MB。") }
            let template = try JSONDecoder().decode(BookSchemeTemplate.self, from: Data(contentsOf: url))
            stageBookSchemeTemplate(template)
        } catch { errorMessage = error.localizedDescription }
    }

    private func mutateBookScheme(_ message: String, onSaved: (() -> Void)? = nil, change: (inout BookProject) throws -> Void) {
        guard var current = book, !isBusy, !isSavingDocument else { return }
        do {
            try change(&current); isBusy = true; isCommittingLocalWrite = true
            Task {
                defer { isBusy = false; isCommittingLocalWrite = false }
                do { try await repository.save(current); publish(current); activity = message; onSaved?() }
                catch { errorMessage = error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
