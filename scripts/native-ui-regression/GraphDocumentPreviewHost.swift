import AppKit
import Foundation
import SwiftUI
import WebKit
@testable import ReadingBook
@testable import ReadingCore

private actor PreviewTransport {
    var calls = 0
    func perform(_ request: ProviderClient.Prepared) throws -> ProviderClient.Result {
        calls += 1; throw ReadingError.invalid("No model calls")
    }
}

@MainActor private final class PreviewHost: NSObject, NSApplicationDelegate {
    var output: URL!
    var window: NSWindow!
    var host: NSHostingView<AnyView>!
    var store: AppStore!
    var checks: [String: Bool] = [:]
    var observations: [[String: Any]] = []
    let firstBody = "王允问吕布为何长叹，吕布答自己被谗言所困。"
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); try finish(nil) } catch { try? finish(String(describing: error)) }
            if CommandLine.arguments.contains("--inspect") {
                try? Data("ready".utf8).write(to: output.appendingPathComponent("ready"))
                while !FileManager.default.fileExists(atPath: output.appendingPathComponent("end-inspection").path) {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            NSApp.terminate(nil)
        }
    }
    func check(_ name: String, _ value: Bool) throws {
        checks[name] = value
        guard value else { throw ReadingError.invalid(name) }
    }
    func elements() -> [NSAccessibilityProtocol] {
        var result: [NSAccessibilityProtocol] = [], visited = Set<ObjectIdentifier>()
        func walk(_ object: Any, _ depth: Int) {
            guard depth < 28, let element = object as? NSAccessibilityProtocol,
                  visited.insert(ObjectIdentifier(element)).inserted else { return }
            result.append(element)
            for child in element.accessibilityChildren() ?? [] { walk(child, depth + 1) }
            if let view = object as? NSView { for child in view.subviews { walk(child, depth + 1) } }
        }
        walk(host as Any, 0); return result
    }
    func objects() -> [NSObject] {
        var result: [NSObject] = [], visited = Set<ObjectIdentifier>()
        func walk(_ object: Any, _ depth: Int) {
            guard depth < 40, let value = object as? NSObject,
                  visited.insert(ObjectIdentifier(value)).inserted else { return }
            result.append(value)
            // SwiftUI virtual accessibility children can implement the public
            // AppKit selectors without declaring the whole formal protocol.
            if value.responds(to: NSSelectorFromString("accessibilityChildren")), let children = value.value(forKey: "accessibilityChildren") as? [Any] {
                for child in children { walk(child, depth + 1) }
            }
            if let view = object as? NSView { for child in view.subviews { walk(child, depth + 1) } }
        }
        walk(host as Any, 0); return result
    }
    func texts() -> [String] {
        objects().flatMap { value in
            ["accessibilityLabel", "accessibilityValue"].compactMap { key in
                value.responds(to: NSSelectorFromString(key)) ? value.value(forKey: key) as? String : nil
            }
        }
    }
    func object(_ label: String) -> NSObject? {
        objects().first { $0.responds(to: NSSelectorFromString("accessibilityLabel")) && ($0.value(forKey: "accessibilityLabel") as? String) == label }
    }
    func frame(_ label: String) -> CGRect? {
        guard let value = object(label), value.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
        return (value.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
    }
    func press(_ label: String) throws {
        guard let rect = frame(label), rect.width > 0, rect.height > 0 else { throw ReadingError.invalid("Missing action frame: " + label) }
        let point = window.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY))
        let location = host.convert(point, from: nil)
        guard let receiver = host.hitTest(location) else { throw ReadingError.invalid("Missing action receiver") }
        observations.append(["action": label, "frame": [rect.minX, rect.minY, rect.width, rect.height], "hitReceiver": String(describing: type(of: receiver)), "input": "Own window sendEvent, never OS post"])
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0) else { throw ReadingError.invalid("Event") }
            window.sendEvent(event)
        }
    }
    func waitFor(_ name: String, _ condition: @escaping () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        repeat {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if condition() { checks[name] = true; return }
            try await Task.sleep(for: .milliseconds(30))
        } while ProcessInfo.processInfo.systemUptime < deadline
        observations.append(["stage": name, "texts": texts()]); try check(name, false)
    }
    func waitForSummary() async throws {
        func webViews(_ root: NSView) -> [WKWebView] {
            if let web = root as? WKWebView { return [web] }
            return root.subviews.flatMap(webViews)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        repeat {
            for web in webViews(host) {
                if let text = try? await web.evaluateJavaScript("document.body.textContent") as? String, text.contains(firstBody) {
                    checks["eventSummaryVisible"] = true; return
                }
            }
            try await Task.sleep(for: .milliseconds(30))
        } while ProcessInfo.processInfo.systemUptime < deadline
        try check("eventSummaryVisible", false)
    }
    func show<V: View>(_ view: V) {
        host.rootView = AnyView(view.environmentObject(store).environmentObject(ReadingTypographySettings()).environment(\.readingReduceMotion, true))
    }
    func run() async throws {
        output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        try check("isolatedLibrary", output.path.hasPrefix(FileManager.default.currentDirectoryPath + "/logs/") && Bundle.main.bundleIdentifier != "org.readingbook.app")
        let library = output.appendingPathComponent("library")
        UserDefaults.standard.setVolatileDomain(["library.root.path.v1": library.path, "service-profiles": Data("[]".utf8), "query-memory-enabled": false], forName: UserDefaults.argumentDomain)
        let quote = "請問將軍，為何在此長歎？布曰：『正為公女耳。』允佯驚曰：『許多時尚未與將軍耶？』"
        let source = output.appendingPathComponent("excerpt.txt"), bytes = Data(quote.utf8)
        try bytes.write(to: source)
        var book = BookProject(title: "三国演义节选 · 人工绑定隔离验收", originalName: "excerpt.txt", sourceHash: try BookImporter.sha256(bytes), units: [.init(id: "u104", order: 0, chapter: "原文节选", page: 104, text: quote)])
        PluginEngine.seed(&book)
        let evidence = [Evidence(unitID: "u104", quote: quote)]
        book.entities = [.init(id: "wang", typeID: "person", name: "王允", evidence: evidence), .init(id: "lu", typeID: "person", name: "吕布", evidence: evidence)]
        book.events = [.init(id: "question", name: "王允问吕布", summary: firstBody, dateText: "测试刻度，非史年考订", startYear: 1, participantIDs: ["wang", "lu"], evidence: evidence)]
        let definition = ViewDefinition(id: "composed", title: "共用笔记导图", kind: .knowledge, rendererID: "reading.composition", composition: .init(sources: [.init(id: "notes", collection: .documents, scope: .book, limit: 20)], parts: [.init(id: "graph", primitive: .documentGraph, sourceID: "notes", title: "笔记")], layout: [.init(id: "root", kind: .part, partID: "graph")], rootID: "root"))
        book.views = [definition]
        let repository = LibraryRepository(rootURL: library)
        book = try await repository.create(book, sourceURL: source)
        for index in 0..<3 {
            book = try await repository.saveDocument(project: book, document: .init(id: "d\(index)", title: "阅读理解\(index)", linkedIDs: ["question"], evidence: evidence), markdown: "# 阅读理解\(index)\n\n" + (index == 0 ? firstBody : "独立笔记\(index)，同一处原文的不同理解。"))
            book.nodes.append(.init(id: "n\(index)", targetID: "d\(index)", x: Double(index) * 280, y: 0))
        }
        book = try await repository.save(book)
        let baseline = try JSONEncoder().encode(book)
        let transport = PreviewTransport()
        store = AppStore(sharedAIRequests: AIRequestCoordinator(transport: { try await transport.perform($0) }))
        store.libraryRootURL = library; store.repository = repository; store.books = [book]; store.bookID = book.id
        store.selectedUnitID = "u104"; store.readingScopeCurrent = false
        store.workspaceMemory = .init(bookID: book.id, sourceHash: book.sourceHash)
        window = NSWindow(contentRect: .init(x: 80, y: 60, width: 1250, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ReadingBook 内容摘要与时间联动 · 隔离验收"; window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnyView(Color.clear)); window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        store.route = "mindmap"; show(DocumentGraphView())
        try await waitFor("standaloneShowsSavedBody", { self.texts().contains { $0.contains(self.firstBody) } })
        try check("allThreeNodesHaveBodyHints", (0..<3).allSatisfy { index in self.texts().contains { $0.contains("阅读理解\(index)") && $0.contains(index == 0 ? self.firstBody : "独立笔记\(index)") } })
        let owner = GraphDocumentPreviewOwner(repository: repository.publicationOwner, bookID: book.id, sourceHash: book.sourceHash, revision: 1, scope: nil)
        let item = GraphItem(id: "n", targetID: "d0", title: "标题", subtitle: "fallback", x: 0, y: 0, documentIDs: ["empty", "d0"])
        let snapshot = GraphDocumentPreviewSnapshot(owner: owner, texts: ["empty": "", "d0": firstBody])
        try check("mountedDocumentsUseFirstNonemptyBody", snapshot.text(for: item, owner: owner) == firstBody)
        var changed = owner; changed.revision += 1
        try check("oldRevisionDoesNotAppear", snapshot.text(for: item, owner: changed) == "fallback")
        changed = owner; changed.repository = UUID()
        try check("otherLibraryDoesNotAppear", snapshot.text(for: item, owner: changed) == "fallback")
        changed = owner; changed.bookID = "other"
        try check("otherBookDoesNotAppear", snapshot.text(for: item, owner: changed) == "fallback")
        changed = owner; changed.scope = UUID()
        try check("otherScopeDoesNotAppear", snapshot.text(for: item, owner: changed) == "fallback")
        let doc = book.activeDocuments.first { $0.id == "d0" }!
        let content = try await repository.readDocumentSnapshot(bookID: book.id, document: doc)
        book = try await repository.saveDocument(project: book, document: doc, markdown: "# 阅读理解0\n\n重新编辑后的正文，不显示旧预览。", expectedContentHash: content.contentHash)
        store.publish(book)
        try await waitFor("sameNodeRefreshesEditedMarkdown", { self.texts().contains { $0.contains("重新编辑后的正文") } })
        try check("oldBodyLeavesNativeNode", !texts().contains { $0.contains(self.firstBody) })
        store.route = definition.id; show(CompositionWorkspaceView(definition: definition))
        try await waitFor("compositionShowsSameSavedMarkdown", { self.texts().contains { $0.contains("重新编辑后的正文") } })
        store.route = "manual-map"; store.selectedObjectID = "question"; store.timeFrom = -4; store.timeTo = 6
        store.workspaceMemory.panels["map.timeline"] = .init(isPresented: true, collapsed: false)
        show(SpatialTimelineView())
        try await waitFor("eventTitleVisible", { self.texts().contains("王允问吕布") })
        try await waitFor("sourceActionVisible", { self.texts().contains { $0.contains("回到原句") } })
        try await waitFor("participantsRetainDirectActions", { self.texts().contains("参与者：吕布") && self.texts().contains("参与者：王允") })
        try await waitForSummary()
        let contentFrame = window.convertToScreen(host.convert(host.bounds, to: nil))
        try check("eventSourceActionWithinViewport", frame("回到原句").map { contentFrame.contains($0) } == true)
        let endpoint = frame("时间范围终点")
        store.timeFrom = 3; store.timeTo = 5
        try await waitFor("filteredDetailPresent", { self.texts().contains { $0.contains("此事件不在当前时间范围内") } })
        // The endpoint moves horizontally with its new value; changing the
        // event detail must not shift the time axis vertically under a hand.
        let afterEndpoint = frame("时间范围终点")
        observations.append(["timeAxisBefore": endpoint.map { [$0.midX, $0.midY] } ?? [], "timeAxisAfter": afterEndpoint.map { [$0.midX, $0.midY] } ?? []])
        try check("filterKeepsTimeAxisVerticalPosition", endpoint.flatMap { before in afterEndpoint.map { after in abs(before.midY - after.midY) < 1.5 } } == true)
        store.timeFrom = -4; store.timeTo = 6
        try await waitFor("sourceActionVisible", { self.texts().contains { $0.contains("回到原句") } })
        try press("参与者：吕布")
        try await waitFor("participantActionSelectsCanonicalPerson", { self.store.selectedTemporalEntityID == "lu" })
        window.setContentSize(CGSize(width: 820, height: 820))
        try await Task.sleep(for: .milliseconds(150))
        if object("展开时间卡片") != nil { try press("展开时间卡片") }
        try await waitFor("narrowDetailsAndSourceStayInViewport", {
            let bounds = self.window.convertToScreen(self.host.convert(self.host.bounds, to: nil))
            return self.frame("回到原句").map { bounds.contains($0) && $0.height >= 40 } == true
        })
        try press("回到原句")
        try await waitFor("sourceActionNavigatesToSameUnit", { self.store.route == "reader" && self.store.selectedUnitID == "u104" })
        try await waitFor("sourceNavigationReturnsToReader", { self.store.route == "reader" && self.store.selectedUnitID == "u104" })
        let loaded = try await repository.loadAll().first!
        try check("noDuplicateDocumentsOrNodes", loaded.activeDocuments.count == 3 && loaded.nodes.count == 3 && Set(loaded.nodes.map(\.targetID)) == Set(loaded.activeDocuments.map(\.id)))
        try check("sourceBytesUnchanged", try Data(contentsOf: source) == bytes)
        try check("onlyIntentionalMarkdownEdit", loaded.events == book.events && loaded.entities == book.entities && loaded.units == book.units && !baseline.isEmpty)
        try check("noModelRequests", await transport.calls == 0)
    }
    func finish(_ error: String?) throws {
        let record: [String: Any] = ["status": error == nil ? "passed" : "failed", "error": error ?? NSNull(), "checks": checks, "checkCount": checks.count, "observations": observations, "realNetworkRequests": 0, "originalLibraryUsed": false, "fixture": "Actual public-domain sentence, manually bound objects and notes; not AI full-book analysis", "scope": "Unmodified product GraphSurface, DocumentGraphView, CompositionWorkspaceView and SpatialTimelineView, own-process AppKit accessibility"]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
    }
}
@main private enum Main {
    static func main() {
        let app = NSApplication.shared, delegate = PreviewHost()
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run(); withExtendedLifetime(delegate) {}
    }
}
