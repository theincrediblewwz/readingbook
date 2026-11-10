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
    /// Exercise the production wait against a separate, unmounted store so a
    /// synthetic readiness signal cannot race the real canvas in this host.
    func checkWorkspaceSettlement() async throws {
        let fixture = AppStore(sharedAIRequests: AIRequestCoordinator(transport: { _ in throw CancellationError() }))
        var book = store.book!
        book.id = "settlement-fixture"
        let route = "settlement-map"
        book.views.append(.init(id: route, title: "就绪回执", kind: .knowledge, rendererID: "reading.composition",
            composition: ReadingWorkbench.definition(for: ReadingWorkbench.timeMapTemplateID)))
        fixture.libraryRootURL = output.appendingPathComponent("settlement-library")
        fixture.books = [book]; fixture.bookID = book.id; fixture.selectedUnitID = "u2"; fixture.route = route
        let owner = ReadingQueryHostOwner(root: fixture.libraryRootURL, bookID: book.id, sourceHash: book.sourceHash, runID: nil)
        func reset() {
            fixture.bookID = book.id; fixture.books = [book]; fixture.selectedUnitID = "u2"; fixture.route = route
            fixture.renderedComponentPresentation = .init(mountID: UUID(), root: fixture.libraryRootURL, bookID: book.id,
                sourceHash: book.sourceHash, route: route, unobscured: true)
            fixture.renderedCompositionState = .init(contextID: fixture.readingVisibilityContextID, selectedIDs: [], maps: [], clocks: [], observationStatus: .pending)
        }
        reset()
        let ready = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(60))
            fixture.renderedCompositionState = .init(contextID: fixture.readingVisibilityContextID, selectedIDs: [], maps: [], clocks: [], observationStatus: .ready)
        }
        let started = ContinuousClock.now
        let settled = try await fixture.readSettledWorkspaceAfterOpening(route, owner: owner)
        try await ready.value
        try check("openWaitUsesRendererReadySignal", settled?.observationStatus == .ready && started.duration(to: .now) < .seconds(1))
        try check("openWaitDoesNotNavigateOrPersist", fixture.route == route && fixture.book?.views == book.views && fixture.book?.chats.map(\.id) == book.chats.map(\.id))
        reset()
        let pendingStart = ContinuousClock.now
        let pending = try await fixture.readSettledWorkspaceAfterOpening(route, owner: owner)
        let duration = pendingStart.duration(to: .now)
        try check("openWaitHasBoundedPendingDeadline", pending?.observationStatus == .pending && duration >= .milliseconds(900) && duration < .seconds(3))
        reset()
        fixture.renderedCompositionState = .init(contextID: fixture.readingVisibilityContextID, selectedIDs: [], maps: [], clocks: [], observationStatus: .empty)
        let empty = try await fixture.readSettledWorkspaceAfterOpening(route, owner: owner)
        try check("openWaitReturnsExplicitEmpty", empty?.observationStatus == .empty && empty?.visibleObjects?.objectIDs == [])
        reset()
        let cursor = Task { @MainActor in try await Task.sleep(for: .milliseconds(40)); fixture.selectedUnitID = "u1" }
        let moved = try await fixture.readSettledWorkspaceAfterOpening(route, owner: owner)
        try await cursor.value
        try check("openWaitRejectsChangedReaderCursor", moved == nil && fixture.selectedUnitID == "u1")
        reset()
        let changed = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(40))
            try fixture.installComponentView(route: route, snapshot: ReadingQuerySnapshot.freeze(scope: .page, in: book,
                context: .init(unitID: "u1", page: 1)), context: .init(unitID: "u1", page: 1))
        }
        let rescoped = try await fixture.readSettledWorkspaceAfterOpening(route, owner: owner)
        try await changed.value
        try check("openWaitRejectsChangedSourceScope", rescoped == nil && fixture.activeComponentView?.snapshot?.scope == .page)
        reset()
        let departure = Task { @MainActor in try await Task.sleep(for: .milliseconds(40)); fixture.bookID = "different-book" }
        var ownerCancelled = false
        do { _ = try await fixture.readSettledWorkspaceAfterOpening(route, owner: owner) } catch is CancellationError { ownerCancelled = true }
        try await departure.value
        try check("openWaitCancelsAfterBookSwitch", ownerCancelled)
        reset()
        let cancelled = Task { @MainActor in try await fixture.readSettledWorkspaceAfterOpening(route, owner: owner) }
        try await Task.sleep(for: .milliseconds(40)); cancelled.cancel()
        var taskCancelled = false
        do { _ = try await cancelled.value } catch is CancellationError { taskCancelled = true }
        try check("openWaitHonorsRequestCancellation", taskCancelled)
        reset(); fixture.showingSettings = true
        let covered = try await fixture.readSettledWorkspaceAfterOpening(route, owner: owner)
        try check("openWaitRejectsCoveredWorkspace", covered == nil)
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
        store.loadWorkspaceMemory()
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
        store.querySourceRange = .init(pageStart: 2, pageEnd: 3)
        try await ask(.range, moveCursorAfterSend: true)
        try check("explicitRangeQuestionIsFrozen", store.activeComponentView?.snapshot?.scope == .range && Set(store.activeComponentView?.snapshot?.unitIDs ?? []) == ["u2", "u2b", "u3"])
        try check("explicitRangeObjectsAreExact", Set(store.componentDataBook?.entities.map(\.id) ?? []) == ["guan", "zhang", "cao"])
        try check("explicitRangeTemporalEventsAreExact", Set(store.temporalEvents.map(\.object.id)) == ["event-u2", "event-u2b", "event-u3"])
        let rangeRecords = await transport.allRecords()
        let rangeMessages = rangeRecords.last?["messages"] as? [[String: Any]] ?? []
        let providedSource = rangeMessages.compactMap { $0["content"] as? String }.first { $0.contains("【原文 [unit:") } ?? ""
        try check("explicitRangeSuppliesWholeChosenTextOnce", providedSource.contains("关羽来到这里") && providedSource.contains("张飞来到这里") && providedSource.contains("曹操来到这里") && !providedSource.contains("刘备来到这里"))
        try check("rangeCursorMoveDoesNotExpandComponent", store.selectedUnitID == "u1" && store.componentDataBook?.units.contains(where: { $0.id == "u1" }) == false)
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
        store.timeFrom = 12; store.timeTo = 18; store.timeCursor = 15
        store.renderedCompositionState = nil
        try check("compositionNeverAdoptsStandaloneClock", store.makeReadingWorkspaceSnapshot()?.timeFrom == nil)
        store.renderedCompositionState = .init(contextID: store.readingVisibilityContextID, selectedIDs: ["liu"],
            maps: [.init(partID: "map", latitude: 30, longitude: 110, latitudeDelta: 3, longitudeDelta: 3,
                objectIDs: ["liu"], visibleRouteIDs: [], projectedRouteIDs: [])],
            clocks: [.init(groupID: "main", axis: "gregorian", from: 1, to: 2, current: 1.5)])
        let rendered = store.makeReadingWorkspaceSnapshot()
        try check("compositionReportsOwnClockAndSelection", rendered?.timeFrom == 1 && rendered?.currentTime == 1.5 && rendered?.selectedObjectIDs == ["liu"])
        try check("compositionReportsOwnedMapViewport", rendered?.visibleObjects?.objectIDs == ["liu"] && rendered?.mapViewports?.first?.partID == "map")
        store.publish(try await repository.save(store.book!))
        try check("compositionRejectsOldPublicationViewport", store.makeReadingWorkspaceSnapshot()?.mapViewports == nil && store.makeReadingWorkspaceSnapshot()?.selectedObjectIDs == [])
        store.renderedCompositionState = nil
        try check("ordinaryReopenExplainsReaderBoundary", store.componentSourceControlTitle == "跟随阅读位置")
        try check("previousSourceChoiceHasNoProjection", store.restorableComponentSource?.snapshot.scope == .book)
        store.restoreComponentSource()
        try check("explicitRestoreReturnsFrozenSource", store.activeComponentView?.snapshot?.scope == .book && store.componentDataBook?.entities.contains { $0.id == "cao" } == true)
        store.followReaderComponentSource()
        try check("followReaderDoesNotEraseLastChoice", store.activeComponentView == nil && store.restorableComponentSource != nil && store.temporalBoundary.allowedUnitIDs?.contains("u3") == false)
        let otherRoute = "mindmap"
        store.route = otherRoute
        let secondPage = try ReadingQuerySnapshot.freeze(scope: .page, in: store.book!, context: .init(unitID: "u2", page: 2))
        try store.installComponentView(route: otherRoute, snapshot: secondPage, context: .init(unitID: "u2", page: 2))
        store.route = scopedRoute
        try check("sourceChoicesRemainIndependentByRoute", store.restorableComponentSource?.snapshot.scope == .book)
        store.restoreComponentSource()
        try check("componentRestoreSurvivesOtherScopeChoice", store.activeComponentView?.snapshot?.scope == .book)
        store.flushWorkspaceMemory(); store.readingComponentView = nil
        store.rememberedReadingComponentSources = [:]; store.lastReadingComponentSource = nil; store.loadWorkspaceMemory()
        try check("workspaceReloadDoesNotAutomaticallyWidenReader", store.activeComponentView == nil)
        try check("sourceChoiceReloadRetainsOriginalRoute", store.restorableComponentSource?.snapshot.scope == .book)
        store.route = otherRoute; store.restoreComponentSource()
        try check("sourceChoiceReloadRetainsOtherRoute", store.activeComponentView?.snapshot?.scope == .page && Set(store.componentDataBook?.units.map(\.id) ?? []) == ["u2", "u2b"])
        store.route = scopedRoute; store.followReaderComponentSource()
        let lastChoice = store.lastReadingComponentSource
        store.route = "reader"
        try check("sourceChoiceCannotApplyToAnotherRoute", store.restorableComponentSource == nil)
        store.route = scopedRoute
        var wrongChoice = store.book!; wrongChoice.sourceHash = "different-source"; store.books = [wrongChoice]
        store.restoreComponentSource()
        try check("changedSourceCannotRestoreOldChoice", store.restorableComponentSource == nil && store.activeComponentView == nil)
        store.books = [saved]; store.lastReadingComponentSource = lastChoice
        let page = try ReadingQuerySnapshot.freeze(scope: .page, in: store.book!, context: .init(unitID: "u2", page: 2))
        try store.installComponentView(route: scopedRoute, snapshot: page, context: .init(unitID: "u2", page: 2))
        var updated = store.book!
        updated.entities.append(.init(id: "new-guan", typeID: "person", name: "关羽", evidence: [.init(unitID: "u2", quote: "关羽来到这里。")]))
        updated.entities.append(.init(id: "masked", typeID: "person", name: "后文身份", aliases: ["关羽"],
            evidence: [.init(unitID: "u2", quote: "关羽来到这里。"), .init(unitID: "u3", quote: "曹操来到这里。")]))
        store.publish(try await repository.save(updated))
        try check("newAnalysisRefreshesSameSharedScope", store.componentDataBook?.entities.contains { $0.id == "new-guan" } == true && store.activeComponentView?.snapshot?.scopeFingerprint == page.scopeFingerprint)
        try check("componentTitlesUseScopedIdentity", store.componentDataBook?.entities.first { $0.id == "masked" }?.name == "关羽" && store.objectTitle("masked") == "关羽")
        try check("componentTitleCannotRevealExcludedObject", store.objectTitle("cao") == "cao")
        updated.units[1].text = "原文已被替换。"; store.refreshComponentData(updated)
        try check("invalidatedSnapshotNeverFallsBackToWholeBook", store.activeComponentView?.issue != nil && store.componentDataBook == nil)
        updated.sourceHash = "replaced-source"; store.books = [updated]; store.refreshComponentData(updated)
        try check("sourceHashChangeNeverFallsBackToWholeBook", store.activeComponentView?.issue != nil && store.componentDataBook == nil)
        store.books = [saved]; store.bookID = saved.id; store.readingComponentView = nil
        try store.installComponentView(route: scopedRoute, snapshot: try ReadingQuerySnapshot.freeze(scope: .book, in: saved), context: nil)
        let previousRoot = store.libraryRootURL
        store.querySourceRange = .init(pageStart: 2, pageEnd: 3); store.queryScope = .range
        store.libraryRootURL = output.appendingPathComponent("other-library")
        try check("libraryChangeClearsScope", store.readingComponentView == nil && store.lastReadingComponentSource == nil)
        try check("libraryChangeClearsExplicitQueryRange", store.querySourceRange == nil && store.queryScope == .page)
        store.libraryRootURL = previousRoot
        var other = saved; other.id = "other-book"; store.books.append(other)
        try store.installComponentView(route: scopedRoute, snapshot: try ReadingQuerySnapshot.freeze(scope: .book, in: saved), context: nil)
        store.querySourceRange = .init(pageStart: 2, pageEnd: 3); store.queryScope = .range
        store.bookID = other.id
        try check("bookChangeClearsScope", store.readingComponentView == nil && store.lastReadingComponentSource == nil)
        try check("bookChangeClearsExplicitQueryRange", store.querySourceRange == nil && store.queryScope == .page)
        store.bookID = saved.id; store.selectedUnitID = "u2"; store.route = scopedRoute
        try store.installComponentView(route: scopedRoute, snapshot: try ReadingQuerySnapshot.freeze(scope: .book, in: saved), context: nil)
        try await checkWorkspaceSettlement()
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
