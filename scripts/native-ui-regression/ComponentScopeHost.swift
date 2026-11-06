import AppKit
import Foundation
import SwiftUI
@testable import ReadingBook
@testable import ReadingCore

/// Real AppStore/chat/navigation with an offline model. The source choice is
/// captured by the production question path, not injected by the view fixture.
private actor ScopeTransport {
    var composition = false
    var calls = 0
    var records: [[String: Any]] = []
    func configure(composition: Bool = false) { self.composition = composition }
    func count() -> Int { calls }
    func perform(_ request: ProviderClient.Prepared) async throws -> ProviderClient.Result {
        guard request.request.url?.host == "127.0.0.1", request.request.value(forHTTPHeaderField: "Authorization") == nil,
              let data = request.request.httpBody,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReadingError.invalid("隔离模型拒绝网络和密钥。") }
        calls += 1
        let messages = body["messages"] as? [[String: Any]] ?? []
        let user = messages.lastIndex { $0["role"] as? String == "user" } ?? -1
        let results = messages.dropFirst(user + 1).filter { $0["role"] as? String == "tool" }
        records.append(["messages": messages, "tools": body["tools"] ?? []])
        try await Task.sleep(nanoseconds: 150_000_000)
        if !results.isEmpty || body["tool_choice"] as? String == "none" {
            return .init(message: .init(role: "assistant", content: "已按这次提问的范围打开已有资料。", refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: 12)
        }
        var args: [String: Any] = ["componentID": "relations"]
        if composition {
            args = ["componentID": "reading.composition", "title": "人物范围对照", "composition": [
                "sources": [["id": "people", "collection": "objects", "scope": "current"]],
                "parts": [["id": "list", "primitive": "object.list", "sourceID": "people"]],
                "layout": [["id": "root", "kind": "part", "partID": "list"]], "rootID": "root"]]
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self)
        return .init(message: .init(role: "assistant", content: nil, refusal: nil, tool_calls: [
            .init(id: UUID().uuidString, type: "function", function: .init(name: "component_show", arguments: json))], reasoning_content: nil),
            finishReason: "tool_calls", tokenCost: 12)
    }
    func allRecords() -> [[String: Any]] { records }
}

@MainActor private final class ScopeHost: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var store: AppStore!
    let transport = ScopeTransport()
    var output: URL!
    var checks: [String: Bool] = [:]
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); try await finish(nil) }
            catch { try? await finish(error) }
            NSApp.terminate(nil)
        }
    }
    func check(_ name: String, _ value: @autoclosure () -> Bool) throws {
        checks[name] = value(); if checks[name] != true { throw ReadingError.invalid("范围检查失败：" + name) }
    }
    func wait(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !predicate() {
            if ProcessInfo.processInfo.systemUptime > deadline { throw ReadingError.invalid("范围检查超时。") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 120_000_000)
    }
    func ask(_ scope: ReadingQueryScope, moveCursorAfterSend: Bool = false, composition: Bool = false) async throws {
        await transport.configure(composition: composition)
        store.route = "query"; store.queryScope = scope
        let before = await transport.count()
        store.ask("请按本次范围打开人物关系。")
        guard store.isQueryBusy else { throw ReadingError.invalid("提问没有开始。") }
        if moveCursorAfterSend {
            while await transport.count() == before { try await Task.sleep(nanoseconds: 10_000_000) }
            store.selectedUnitID = "u1"
        }
        try await wait { !self.store.isQueryBusy }
        guard store.queryRetryQuestion == nil, store.errorMessage == nil else { throw ReadingError.invalid(store.errorMessage ?? store.queryRetryQuestion ?? "提问失败") }
    }
    func run() async throws {
        output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard output.path.hasPrefix(FileManager.default.currentDirectoryPath + "/logs/"), Bundle.main.bundleIdentifier != "org.readingbook.app" else { throw ReadingError.invalid("只能使用隔离书库。") }
        let library = output.appendingPathComponent("library")
        UserDefaults.standard.setVolatileDomain(["library.root.path.v1": library.path, "service-profiles": Data("[]".utf8),
            "reading.hoverTranslation": false, "query-memory-enabled": false], forName: UserDefaults.argumentDomain)
        var fixture = BookProject(title: "组件范围一致性 · 隔离合成书", originalName: "source.txt", sourceHash: "scope-source", units: [
            .init(id: "u1", order: 0, chapter: "开头", page: 1, text: "刘备来到这里。"),
            .init(id: "u2", order: 1, chapter: "本页", page: 2, text: "关羽来到这里。"),
            .init(id: "u2b", order: 2, chapter: "本页", page: 2, text: "张飞来到这里。"),
            .init(id: "u3", order: 3, chapter: "后文", page: 3, text: "曹操来到这里。")])
        PluginEngine.seed(&fixture); fixture.views = []; fixture.lastUnitID = "u2"
        fixture.temporalKnowledge = .init(profile: .init(avoidsSpoilers: true))
        fixture.entities = zip(["liu", "guan", "zhang", "cao"], fixture.units).map { id, unit in
            .init(id: id, typeID: "person", name: String(unit.text.prefix(2)), summary: unit.text, evidence: [.init(unitID: unit.id, quote: unit.text)])
        }
        fixture.events = fixture.units.map { .init(id: "event-" + $0.id, name: $0.text, dateText: "时间待考", evidence: [.init(unitID: $0.id, quote: $0.text)]) }
        let source = output.appendingPathComponent("source.txt")
        let sourceData = Data(fixture.units.map(\.text).joined(separator: "\n").utf8)
        fixture.sourceHash = try BookImporter.sha256(sourceData)
        try sourceData.write(to: source)
        let repository = LibraryRepository(rootURL: library)
        fixture = try await repository.create(fixture, sourceURL: source)
        let note = DocumentRecord(id: "reader-note", title: "保留原笔记"), noteText = "原笔记 e\u{301} 🙂 不变。"
        fixture = try await repository.saveDocument(project: fixture, document: note, markdown: noteText)
        let transport = transport
        store = AppStore(sharedAIRequests: AIRequestCoordinator(transport: { try await transport.perform($0) }))
        store.libraryRootURL = library; store.repository = repository; store.books = [fixture]; store.bookID = fixture.id
        store.selectedUnitID = "u2"; store.route = "reader"; store.readingScopeCurrent = true
        store.settings = .init(baseURL: "http://127.0.0.1:1/disabled", model: "offline-fixture", maxRequestsPerRun: 8,
            maxOutputTokens: 1000, contextWindowTokens: 128_000)
        store.apiKey = ""; store.queryMemoryEnabled = false
        window = NSWindow(contentRect: .init(x: 80, y: 70, width: 1120, height: 760), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "ReadingBook 范围一致性 · 隔离检查"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView().environmentObject(store).environmentObject(ReadingTypographySettings()))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait { self.window.isVisible }
        try await ask(.book)
        try check("fullBookQuestionScopePreserved", store.activeComponentView?.snapshot?.scope == .book && store.activeComponentView?.snapshot?.unitIDs.contains("u3") == true)
        try check("fullBookOpensFutureObjects", store.componentDataBook?.entities.contains { $0.id == "cao" } == true)
        try check("fullBookDisablesImplicitCursorFilter", store.readingScopeCurrent && !store.componentUsesCurrentContext)
        try check("fullBookTemporalEventsIncludeFuture", store.temporalEvents.contains { $0.object.id == "event-u3" })
        try check("fullBookProfileUnchanged", store.book?.temporalKnowledge?.profile?.avoidsSpoilers == true)
        let route = store.route, calls = await transport.count(), count = store.book!.views.count
        store.toggleComponentWholeBook()
        try check("followReaderRestoresOriginalBoundary", store.activeComponentView?.snapshot == nil && store.temporalBoundary.allowedUnitIDs?.contains("u3") == false && store.componentUsesCurrentContext)
        store.toggleComponentWholeBook()
        try check("manualWholeBookIsLocalOnly", store.activeComponentView?.snapshot?.scope == .book && store.book!.views.count == count && store.queryScope == .book)
        let callsAfterToggle = await transport.count()
        try check("manualScopeMakesNoModelRequest", callsAfterToggle == calls)
        store.selectedUnitID = "u2"
        try await ask(.page, moveCursorAfterSend: true)
        try check("inFlightCursorChangeDoesNotChangeQuestionScope", Set(store.activeComponentView?.snapshot?.unitIDs ?? []) == ["u2", "u2b"])
        try check("pageObjectsAreExact", Set(store.componentDataBook?.entities.map(\.id) ?? []) == ["guan", "zhang"])
        try check("pageTemporalEventsAreExact", Set(store.temporalEvents.map(\.object.id)) == ["event-u2", "event-u2b"])
        try check("questionContextRemainsFrozen", store.componentReadingContext.unitID == "u2" && store.currentReadingContext.unitID == "u1")
        let revision = store.currentBookRevision
        let access = store.readingViewToolAccess(bookID: fixture.id, sourceHash: fixture.sourceHash, snapshot: store.activeComponentView?.snapshot, context: store.componentReadingContext)
        let epoch = store.componentDataScopeID
        _ = try await access.performViewAction("component_show", Data(#"{"componentID":"relations"}"#.utf8))
        try check("sameScopeShowDoesNotRepublishOrReplaceScope", store.currentBookRevision == revision && store.componentDataScopeID == epoch && store.route == route)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(store.book!)
        store.toggleComponentWholeBook(); store.toggleComponentWholeBook()
        let afterToggle = try encoder.encode(store.book!)
        try check("scopeSwitchDoesNotPersistProjectedBook", afterToggle == before)
        store.selectedUnitID = "u2"
        try await ask(.readSoFar)
        try check("readSoFarIncludesWholeCurrentPage", Set(store.componentDataBook?.entities.map(\.id) ?? []) == ["liu", "guan", "zhang"])
        try check("readSoFarExcludesFuture", !store.temporalEvents.contains { $0.object.id == "event-u3" })
        try await ask(.book, composition: true)
        guard let view = store.book?.views.first(where: { $0.rendererID == "reading.composition" }), let definition = view.composition,
              let snapshot = store.activeComponentView?.snapshot else { throw ReadingError.invalid("组合组件未创建。") }
        let prepared = try CompositionRuntime.prepare(definition, in: store.book!, context: store.componentReadingContext,
            boundary: store.temporalBoundary, sourceSnapshot: snapshot)
        let composed = try CompositionRuntime.project(prepared)
        try check("currentBindingCompositionUsesWholeQuestionScope", composed["people"]?.items.contains { $0.id == "cao" } == true)
        let saved = try await repository.loadAll().first!
        try check("automaticViewSaveAndReuseUnchanged", saved.views.count == 2 && saved.views.contains { $0.id == view.id })
        try check("originalAnalysisIDsAndContentPreserved", saved.entities == fixture.entities && saved.events == fixture.events && saved.units == fixture.units)
        let savedNote = try await repository.readDocument(bookID: fixture.id, document: note)
        try check("originalNotePreserved", savedNote == noteText)
        let scopedRoute = store.route
        store.route = "reader"
        try check("leavingComponentRestoresReaderBoundary", store.readingComponentView == nil && store.temporalBoundary.allowedUnitIDs?.contains("u3") == false)
        store.route = scopedRoute
        try check("ordinaryReopenUsesExistingReaderPolicy", store.activeComponentView == nil && store.temporalBoundary.allowedUnitIDs?.contains("u3") == false)
        let page = try ReadingQuerySnapshot.freeze(scope: .page, in: store.book!, context: .init(unitID: "u2", page: 2))
        try store.installComponentView(route: scopedRoute, snapshot: page, context: .init(unitID: "u2", page: 2))
        var updated = store.book!
        updated.entities.append(.init(id: "new-guan", typeID: "person", name: "关羽", evidence: [.init(unitID: "u2", quote: "关羽来到这里。")]))
        store.publish(try await repository.save(updated))
        try check("newAnalysisRefreshesSameSharedScope", store.componentDataBook?.entities.contains { $0.id == "new-guan" } == true && store.activeComponentView?.snapshot?.scopeFingerprint == page.scopeFingerprint)
        updated.units[1].text = "原文已被替换。"; store.refreshComponentData(updated)
        try check("invalidatedSnapshotNeverFallsBackToWholeBook", store.activeComponentView?.issue != nil && store.componentDataBook == nil)
        updated.sourceHash = "replaced-source"; store.books = [updated]; store.refreshComponentData(updated)
        try check("sourceHashChangeNeverFallsBackToWholeBook", store.activeComponentView?.issue != nil && store.componentDataBook == nil)
        store.books = [saved]; store.bookID = saved.id; store.readingComponentView = nil
        try store.installComponentView(route: scopedRoute, snapshot: try ReadingQuerySnapshot.freeze(scope: .book, in: saved), context: nil)
        let previousRoot = store.libraryRootURL
        store.libraryRootURL = output.appendingPathComponent("other-library")
        try check("libraryChangeClearsScope", store.readingComponentView == nil)
        store.libraryRootURL = previousRoot
        var other = saved; other.id = "other-book"; store.books.append(other)
        try store.installComponentView(route: scopedRoute, snapshot: try ReadingQuerySnapshot.freeze(scope: .book, in: saved), context: nil)
        store.bookID = other.id
        try check("bookChangeClearsScope", store.readingComponentView == nil)
        store.bookID = saved.id; store.selectedUnitID = "u2"; store.route = scopedRoute
        try store.installComponentView(route: scopedRoute, snapshot: try ReadingQuerySnapshot.freeze(scope: .book, in: saved), context: nil)
        if CommandLine.arguments.contains("--inspect") {
            try Data("ready".utf8).write(to: output.appendingPathComponent("inspection-ready"))
            while !FileManager.default.fileExists(atPath: output.appendingPathComponent("end-inspection").path) { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        window.close()
    }
    func finish(_ error: Error?) async throws {
        try JSONSerialization.data(withJSONObject: await transport.allRecords(), options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("model-transport.json"))
        let result: [String: Any] = ["status": error == nil ? "passed" : "failed", "error": error?.localizedDescription ?? "", "checks": checks,
            "realNetworkRequests": 0, "originalLibraryUsed": false, "mountedProductionWorkspace": true]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
    }
}
@main private enum ScopeMain {
    static func main() { let app = NSApplication.shared; let delegate = ScopeHost(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run(); withExtendedLifetime(delegate) {} }
}
