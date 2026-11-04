import AppKit
import Darwin
import Foundation
import SwiftUI
@testable import ReadingBook
@testable import ReadingCore

/// Exercises the production chat engine, repository, registry, navigation and
/// real workspace with an in-memory model transport. No network or real books.
private actor ComponentTransport {
    var mode = "organize"
    var expectedQuestion = ""
    var calls: [[String: Any]] = []
    func configure(_ value: String) { mode = value }
    func question(_ text: String) { expectedQuestion = text }
    func perform(_ request: ProviderClient.Prepared) throws -> ProviderClient.Result {
        guard request.request.url?.host == "127.0.0.1", request.request.value(forHTTPHeaderField: "Authorization") == nil,
              let body = request.request.httpBody, let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ReadingError.invalid("探针不允许真实网络或密钥。")
        }
        let messages = payload["messages"] as? [[String: Any]] ?? []
        let user = messages.lastIndex { $0["role"] as? String == "user" } ?? -1
        let results = Array(messages.dropFirst(user + 1).filter { $0["role"] as? String == "tool" })
        let names = (payload["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        guard messages.contains(where: { $0["role"] as? String == "user" && $0["content"] as? String == expectedQuestion }) else { throw ReadingError.invalid("问题未原样进入模型请求。") }
        calls.append(["mode": mode, "question": expectedQuestion, "toolNames": names,
            "results": results.map { $0["content"] as? String ?? "" }, "requestBytes": body.count])
        if payload["tool_choice"] as? String == "none" {
            return answer(mode == "organize" ? "已把人物关系加入图谱：刘备与关羽同行，依据是“刘备与关羽同行”。[unit:u1]" : "已打开已有组件，使用保存的资料。")
        }
        let name: String, arguments: [String: Any]
        if mode == "organize" {
            switch results.count {
            case 0: name = "components_list"; arguments = [:]
            case 1: name = "component_show"; arguments = ["componentID": "relations"]
            case 2: name = "source_read"; arguments = ["id": "u1"]
            case 3:
                guard names.contains("knowledge_changes_propose") else { throw ReadingError.invalid("整理权限未接通。") }
                name = "knowledge_changes_propose"
                let proof: [[String: Any]] = [["unitID": "u1", "quote": "刘备与关羽同行。"]]
                arguments = ["newEntityIDs": ["liu", "guan"], "newRelationIDs": ["together"],
                    "entities": ["liu": "刘备", "guan": "关羽"].sorted { $0.key < $1.key }.map { id, title in
                        ["id": id, "typeID": "person", "name": title, "summary": "", "properties": [:], "aliases": [], "evidence": proof] as [String: Any]
                    }, "relations": [["id": "together", "fromID": "liu", "toID": "guan", "label": "同行", "evidence": proof]]]
            case 4: name = "component_show"; arguments = ["componentID": "relations"]
            default: return answer("已把人物关系加入图谱：刘备与关羽同行，依据是“刘备与关羽同行”。[unit:u1]")
            }
        } else if mode == "composition" {
            if results.isEmpty { name = "components_list"; arguments = [:] }
            else if results.count == 1 {
                name = "component_show"
                arguments = ["componentID": "reading.composition", "title": "人物与原文对照", "composition": [
                    "sources": [["id": "people", "collection": "objects", "scope": "current", "selectionGroup": "people", "timeGroup": "story"]],
                    "parts": [["id": "list", "primitive": "object.list", "sourceID": "people", "selectionGroup": "people", "timeGroup": "story"],
                              ["id": "quote", "primitive": "source.excerpt", "sourceID": "people", "selectionGroup": "people", "timeGroup": "story"]],
                    "layout": [["id": "root", "kind": "row", "children": ["left", "right"]], ["id": "left", "kind": "part", "partID": "list"], ["id": "right", "kind": "part", "partID": "quote"]], "rootID": "root"]]
            } else { return answer("已打开人物与原文对照视图，使用已有资料。") }
        } else {
            if results.isEmpty { name = "component_show"; arguments = ["componentID": "relations"] }
            else { return answer("已打开已有关系图谱，没有重复创建。") }
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), as: UTF8.self)
        return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [.init(id: UUID().uuidString,
            type: "function", function: .init(name: name, arguments: json))], reasoning_content: nil), finishReason: "tool_calls", tokenCost: 40)
    }
    private func answer(_ text: String) -> ProviderClient.Result {
        .init(message: .init(role: "assistant", content: text, refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 40)
    }
    func records() -> [[String: Any]] { calls }
}
private extension Array { subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }

@MainActor private final class ComponentHost: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var store: AppStore!
    var checks: [String: Bool] = [:]
    var output: URL!
    var transport: ComponentTransport!
    var questionIndex = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); try await finish(error: nil) }
            catch { try? await finish(error: error) }
            NSApp.terminate(nil)
        }
    }
    private func check(_ name: String, _ condition: @autoclosure () -> Bool) throws {
        checks[name] = condition(); if checks[name] != true { throw ReadingError.invalid("原生检查失败：" + name) }
    }
    private func wait(_ condition: @escaping @MainActor () -> Bool, seconds: Double = 15) async throws {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            if ProcessInfo.processInfo.systemUptime > until { throw ReadingError.invalid("等待条件超时。") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 120_000_000)
    }
    private func ask(_ text: String, organizing: Bool = false) async throws {
        questionIndex += 1
        await transport.question(text)
        store.ask(text, allowsOrganizing: organizing)
        try check("query\(questionIndex)Started", store.isQueryBusy)
        try await wait { !self.store.isQueryBusy }
        try check("query\(questionIndex)Completed", store.queryRetryQuestion == nil && store.errorMessage == nil)
    }
    private func run() async throws {
        output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard output.path.hasPrefix(FileManager.default.currentDirectoryPath + "/logs/"), Bundle.main.bundleIdentifier != "org.readingbook.app" else { throw ReadingError.invalid("仅允许工作目录隔离宿主。") }
        let library = output.appendingPathComponent("library")
        UserDefaults.standard.setVolatileDomain(["library.root.path.v1": library.path, "service-profiles": Data("[]".utf8),
            "reading.hoverTranslation": false, "query-memory-enabled": false], forName: UserDefaults.argumentDomain)
        let text = "刘备与关羽同行。\n张飞来到这里。\n后文尚未分享。"
        let source = output.appendingPathComponent("book.txt"); try Data(text.utf8).write(to: source)
        var fixture = BookProject(title: "中途调用组件 · 隔离合成书", originalName: "book.txt", sourceHash: try BookImporter.sha256(Data(text.utf8)), units: [
            .init(id: "u1", order: 0, chapter: "开头", page: 1, text: "刘备与关羽同行。"),
            .init(id: "u2", order: 1, chapter: "相逢", page: 2, text: "张飞来到这里。"),
            .init(id: "u3", order: 2, chapter: "后文", page: 3, text: "后文尚未分享。")])
        PluginEngine.seed(&fixture); fixture.views = []; fixture.lastUnitID = "u2"
        let repository = LibraryRepository(rootURL: library)
        fixture = try await repository.create(fixture, sourceURL: source)
        let note = DocumentRecord(id: "reader-note", title: "保留的读者笔记"), noteBody = "保留 e\u{301} 🙂 $x^2$。"
        fixture = try await repository.saveDocument(project: fixture, document: note, markdown: noteBody)
        transport = ComponentTransport(); let transport = transport!
        store = AppStore(sharedAIRequests: AIRequestCoordinator(transport: { try await transport.perform($0) }))
        store.libraryRootURL = library; store.repository = repository; store.books = [fixture]; store.bookID = fixture.id
        store.selectedUnitID = "u2"; store.route = "reader"; store.queryScope = .readSoFar
        store.settings = .init(baseURL: "http://127.0.0.1:1/disabled", model: "offline-fixture", maxRequestsPerRun: 16,
            maxOutputTokens: 1_000, contextWindowTokens: 128_000)
        store.apiKey = ""; store.queryMemoryEnabled = false; store.readingScopeCurrent = false
        window = NSWindow(contentRect: .init(x: 80, y: 70, width: 1120, height: 760), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "ReadingBook 中途组件 · 隔离回归"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView().environmentObject(store).environmentObject(ReadingTypographySettings()))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait { self.window.isVisible }
        store.queryInteractionMode = .functional
        let explicit = "给我弄个关系图谱组件，帮我理一理读到这里的人物关系。"
        try await ask(explicit, organizing: true)
        let organized = store.book!
        try check("newRelationsViewOpened", store.route == organized.views.first { $0.kind == .relations }?.id)
        try check("evidencedAnalysisSavedAfterViewAppend", organized.entities.count == 2 && organized.relations.count == 1)
        try check("noFutureEvidence", organized.entities.flatMap(\.evidence).allSatisfy { $0.unitID == "u1" } && organized.relations.allSatisfy { $0.evidence.allSatisfy { $0.unitID == "u1" } })
        try check("oneViewDespiteRepeatedShow", organized.views.count == 1)
        try check("originalQuestionExact", organized.chats.first { $0.role == "user" }?.content == explicit)
        await transport.configure("reuse"); store.queryInteractionMode = .reading
        try await ask("我记不太清了，帮我理一理这些人物剧情的关系。")
        try check("implicitRequestPipelineReusesExisting", store.book?.views.count == 1 && store.route == organized.views[0].id)
        try check("readingModeDidNotChangeAnalysis", store.book?.entities == organized.entities && store.book?.relations == organized.relations)
        await transport.configure("composition")
        try await ask("把人物列表和原文放在一起看吧。")
        try check("customCompositionCreatedAndOpened", store.book?.views.count == 2 && store.book?.views.last?.rendererID == "reading.composition" && store.route == store.book?.views.last?.id)
        try await ask("再打开刚才的人物原文对照。")
        try check("identicalCompositionReused", store.book?.views.count == 2)
        let before = store.book!, access = store.readingViewToolAccess(bookID: fixture.id, sourceHash: fixture.sourceHash)
        _ = try await access.performViewAction("component_show", Data(#"{"componentID":"relations"}"#.utf8))
        try await Task.sleep(nanoseconds: 250_000_000)
        var usageBefore = rusage(), usageAfter = rusage()
        getrusage(RUSAGE_SELF, &usageBefore)
        let epochBefore = store.currentBookRevision, start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<8 {
            let receipt = try await access.performViewAction("component_show", Data(#"{"componentID":"relations"}"#.utf8))
            guard String(decoding: receipt, as: UTF8.self).contains("\"opened\":true") else { throw ReadingError.invalid("重复打开未得到真实回执。") }
        }
        getrusage(RUSAGE_SELF, &usageAfter)
        func milliseconds(_ usage: rusage) -> Double {
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)*1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)/1000
        }
        let measured: [String: Any] = ["operations": 8, "currentBookPublications": store.currentBookRevision-epochBefore,
            "cpuMs": milliseconds(usageAfter)-milliseconds(usageBefore), "elapsedMs": (ProcessInfo.processInfo.systemUptime-start)*1000,
            "sameViewReused": store.book?.views == before.views, "realNetworkRequests": 0]
        try JSONSerialization.data(withJSONObject: measured, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("repeat-show-cost.json"))
        try check("repeatedShowDoesNotRepublishBook", store.currentBookRevision == epochBefore && store.book?.views == before.views)
        store.editorDirty = true
        let dirty = try await access.performViewAction("component_show", Data(#"{"componentID":"cards"}"#.utf8))
        try check("dirtyDraftNotNavigatedOrDiscarded", String(decoding: dirty, as: UTF8.self).contains("needs_confirmation") && store.book?.views == before.views && store.editorDirty)
        store.editorDirty = false
        let unknown = try await access.performViewAction("component_show", Data(#"{"componentID":"not.installed"}"#.utf8))
        try check("unknownRendererRejected", String(decoding: unknown, as: UTF8.self).contains("unsupported") && store.book?.views == before.views)
        let runID = UUID(); store.queryRunID = runID
        let runAccess = store.readingViewToolAccess(bookID: fixture.id, sourceHash: fixture.sourceHash, runID: runID)
        store.queryRunID = UUID()
        do { _ = try await runAccess.performViewAction("component_show", Data(#"{"componentID":"cards"}"#.utf8)); throw ReadingError.invalid("旧请求不应执行。") }
        catch is CancellationError { checks["staleRunRejected"] = true }
        store.queryRunID = nil
        store.libraryRootURL = output.appendingPathComponent("other-library")
        do { _ = try await access.performViewAction("component_show", Data(#"{"componentID":"cards"}"#.utf8)); throw ReadingError.invalid("旧书库操作不应执行。") }
        catch is CancellationError { checks["sameBookAcrossRootsRejected"] = true }
        store.libraryRootURL = library
        let reloaded = try await repository.loadAll().first!
        try check("configurationAndAnalysisSurviveReload", reloaded.views == before.views && reloaded.entities == before.entities && reloaded.relations == before.relations)
        let savedNote = try await repository.readDocument(bookID: fixture.id, document: note)
        try check("noteBytesAndSourceUnitsPreserved", savedNote == noteBody && reloaded.units == fixture.units && reloaded.sourceHash == fixture.sourceHash)
        let records = await transport.records()
        try check("pureReadingHasComponentsButNoWrites", records.filter { $0["mode"] as? String != "organize" }.allSatisfy {
            let names = $0["toolNames"] as? [String] ?? []; return names.contains("component_show") && !names.contains("knowledge_changes_propose") && !names.contains("view_select")
        })
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("model-transport.json"))
        try JSONEncoder().encode(reloaded).write(to: output.appendingPathComponent("final-fixture.json"))
        if CommandLine.arguments.contains("--inspect") {
            store.route = "reader"
            try Data("ready".utf8).write(to: output.appendingPathComponent("inspection-ready"))
            while !FileManager.default.fileExists(atPath: output.appendingPathComponent("end-inspection").path) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        window.close()
    }
    private func finish(error: Error?) async throws {
        if let transport { try JSONSerialization.data(withJSONObject: await transport.records(), options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("model-transport-at-exit.json")) }
        let result: [String: Any] = ["status": error == nil ? "passed" : "failed", "error": error?.localizedDescription ?? "", "checks": checks,
            "realNetworkRequests": 0, "originalLibraryUsed": false, "mountedProductionWorkspace": true,
            "storeError": store?.errorMessage ?? "", "retryQuestion": store?.queryRetryQuestion ?? "", "disclosure": store?.queryDisclosure ?? ""]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
    }
}
@main private enum DynamicComponentMain {
    static func main() { let app = NSApplication.shared; let delegate = ComponentHost(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run(); withExtendedLifetime(delegate) {} }
}
