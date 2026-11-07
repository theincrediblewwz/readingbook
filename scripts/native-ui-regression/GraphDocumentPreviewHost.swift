import AppKit
import Foundation
import SwiftUI
import WebKit
import Vision
import MapKit
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
    private var forceRaster: Bool { CommandLine.arguments.contains("--raster-observation") }
    private var rasterRows: [(text: String, frame: CGRect)] = []
    private var rasterAt = 0.0
    private var rasterCaptureCount = 0
    private var rasterImage: CGImage?
    private var rasterButtons: [String: CGRect] = [:]
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); try finish(nil) } catch {
                captureState("failed-native-state")
                try? finish(String(describing: error))
            }
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
    func readObject(_ value: NSObject, _ key: String) -> Any? {
        let selector = NSSelectorFromString(key)
        guard value.responds(to: selector) else { return nil }
        return value.perform(selector)?.takeUnretainedValue()
    }
    func captureState(_ stage: String) {
        guard let host, let window else { return }
        var hierarchy: [[String: Any]] = []
        func walk(_ view: NSView, _ depth: Int) {
            guard depth < 20 else { return }
            hierarchy.append(["class": String(describing: type(of: view)), "depth": depth,
                "bounds": NSStringFromRect(view.bounds), "hidden": view.isHiddenOrHasHiddenAncestor,
                "accessibilityChildrenKVC": (view.value(forKey: "accessibilityChildren") as? [Any])?.count ?? -1,
                "accessibilityChildrenSelector": (view.perform(NSSelectorFromString("accessibilityChildren"))?.takeUnretainedValue() as? [Any])?.count ?? -1])
            for child in view.subviews { walk(child, depth + 1) }
        }
        walk(host, 0)
        observations.append(["stage": stage, "windowVisible": window.isVisible, "windowKey": window.isKeyWindow,
            "hostBounds": NSStringFromRect(host.bounds), "objects": objects().count, "hierarchy": hierarchy])
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: output.appendingPathComponent(stage + ".png"))
            }
        }
    }
    func objects() -> [NSObject] {
        var result: [NSObject] = [], visited = Set<ObjectIdentifier>()
        func walk(_ object: Any, _ depth: Int) {
            guard depth < 40, let value = object as? NSObject,
                  visited.insert(ObjectIdentifier(value)).inserted else { return }
            result.append(value)
            // SwiftUI virtual accessibility children can implement the public
            // AppKit selectors without declaring the whole formal protocol.
            if let children = readObject(value, "accessibilityChildren") as? [Any] {
                for child in children { walk(child, depth + 1) }
            }
            if let view = object as? NSView { for child in view.subviews { walk(child, depth + 1) } }
        }
        walk(host as Any, 0); return result
    }
    func accessibilityTexts() -> [String] {
        objects().flatMap { value in
            ["accessibilityLabel", "accessibilityValue"].compactMap { key in
                readObject(value, key) as? String
            }
        }
    }
    func comparable(_ text: String) -> String {
        String(text.precomposedStringWithCanonicalMapping.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    func refreshRaster() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - rasterAt > 0.12 else { return }
        rasterAt = now; rasterRows = []; rasterImage = nil; rasterButtons = [:]; rasterCaptureCount += 1
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return }
        rasterImage = image
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return }
        for result in request.results ?? [] {
            guard let value = result.topCandidates(1).first else { continue }
            let box = result.boundingBox
            let rect = CGRect(x: box.minX * host.bounds.width,
                y: (host.isFlipped ? 1 - box.maxY : box.minY) * host.bounds.height,
                width: box.width * host.bounds.width, height: box.height * host.bounds.height)
            rasterRows.append((value.string, rect))
        }
    }
    func nativeViews() -> [NSView] {
        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
        return walk(host)
    }
    func timelineTrack() -> NSView? {
        nativeViews().first { String(reflecting: type(of: $0)).contains("TimelinePointerInput.PointerView") && !$0.isHiddenOrHasHiddenAncestor }
    }
    func texts() -> [String] {
        let accessible = forceRaster ? [] : accessibilityTexts()
        if !accessible.isEmpty { return accessible }
        refreshRaster()
        let nodes = nativeViews().compactMap { $0 as? GraphPointerBridge.PointerView }
            .filter { $0.reservePorts && $0.bounds.width > 100 && !$0.isHiddenOrHasHiddenAncestor }
        let groups = nodes.map { node in
            let frame = node.convert(node.bounds, to: host).insetBy(dx: -2, dy: -2)
            return rasterRows.filter { frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
                .map(\.text).joined()
        }
        return rasterRows.map(\.text) + groups + [rasterRows.map(\.text).joined()]
    }
    func hasText(_ text: String) -> Bool { texts().contains { comparable($0).contains(comparable(text)) } }
    func object(_ label: String) -> NSObject? {
        objects().first { readObject($0, "accessibilityLabel") as? String == label }
    }
    func frame(_ label: String) -> CGRect? {
        if !forceRaster, let value = object(label), value.responds(to: NSSelectorFromString("accessibilityFrame")),
           let rect = (value.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue { return rect }
        // CI can render SwiftUI correctly without exposing its virtual AX tree.
        // Read the real pixels and native view geometry; never copy model text
        // into a fake label or invoke the product action closure directly.
        if label == "时间范围终点", let track = timelineTrack() {
            return window.convertToScreen(track.convert(track.bounds, to: nil))
        }
        refreshRaster()
        if label == "展开时间卡片", let header = nativeViews().first(where: { view in
            guard String(reflecting: type(of: view)).contains("FloatingPanelPointerInput.PointerView") && !view.isHiddenOrHasHiddenAncestor else { return false }
            let frame = view.convert(view.bounds, to: host)
            return rasterRows.contains { comparable($0.text).contains("时间与地图") && frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        }) {
            let h = header.convert(header.bounds, to: host)
            var buttons: [CGRect] = []
            for view in nativeViews() where !view.isHiddenOrHasHiddenAncestor && abs(view.bounds.height - 44) < 0.5 && abs(view.bounds.width - 44) < 0.5 {
                let frame = view.convert(view.bounds, to: host)
                if frame.minX >= h.maxX && abs(frame.midY - h.midY) < 1.5 && !buttons.contains(frame) { buttons.append(frame) }
            }
            buttons.sort { $0.minX < $1.minX }
            // The actual header has its collapse/expand button immediately
            // before Close. A wrong hit still fails the source-visibility gate.
            if buttons.count >= 2 { return window.convertToScreen(host.convert(buttons[buttons.count - 2], to: nil)) }
        }
        refreshRaster()
        let needle = label.hasPrefix("参与者：") ? String(label.dropFirst(4)) : label
        if let cached = rasterButtons[label] { return cached }
        guard let image = rasterImage else { return nil }
        var sampled: [CGRect] = []
        for view in nativeViews() where !view.isHiddenOrHasHiddenAncestor && String(describing: type(of: view)).contains("FocusRing") {
            guard view.bounds.height >= (label.hasPrefix("参与者：") ? 36 : 40), view.bounds.height <= 60,
                  view.bounds.width >= 30, view.bounds.width <= 200 else { continue }
            let frame = view.convert(view.bounds, to: host)
            guard host.bounds.contains(frame), !sampled.contains(frame) else { continue }; sampled.append(frame)
            let sx = CGFloat(image.width) / host.bounds.width, sy = CGFloat(image.height) / host.bounds.height
            let crop = CGRect(x: frame.minX * sx, y: (host.isFlipped ? frame.minY : host.bounds.height - frame.maxY) * sy,
                width: frame.width * sx, height: frame.height * sy).integral
            guard let cropped = image.cropping(to: crop) else { continue }
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = false
            guard (try? VNImageRequestHandler(cgImage: cropped).perform([request])) != nil else { continue }
            let actual = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
            if comparable(actual).contains(comparable(needle)) {
                let found = window.convertToScreen(host.convert(frame, to: nil)); rasterButtons[label] = found; return found
            }
        }
        return nil
    }
    func press(_ label: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        var ready: CGRect?
        repeat {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); rasterAt = 0
            if let rect = frame(label), rect.width > 0, rect.height > 0 { ready = rect; break }
            try await Task.sleep(for: .milliseconds(30))
        } while ProcessInfo.processInfo.systemUptime < deadline
        guard let rect = ready else { throw ReadingError.invalid("Missing action frame: " + label) }
        let point = window.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY))
        let location = host.superview?.convert(point, from: nil) ?? point
        guard let receiver = host.hitTest(location) else { throw ReadingError.invalid("Missing action receiver") }
        var ancestor: NSView? = receiver
        while let current = ancestor {
            guard !(current is MKMapView) else { throw ReadingError.invalid("Action frame actually hits map: " + label) }
            ancestor = current.superview
        }
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
        try await waitFor("standaloneShowsSavedBody", { self.hasText(self.firstBody) })
        try check("allThreeNodesHaveBodyHints", (0..<3).allSatisfy { index in self.texts().contains { self.comparable($0).contains("阅读理解\(index)") && self.comparable($0).contains(self.comparable(index == 0 ? self.firstBody : "独立笔记\(index)")) } })
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
        try await waitFor("sameNodeRefreshesEditedMarkdown", { self.hasText("重新编辑后的正文") })
        try check("oldBodyLeavesNativeNode", !hasText(firstBody))
        store.route = definition.id; show(CompositionWorkspaceView(definition: definition))
        try await waitFor("compositionShowsSameSavedMarkdown", { self.hasText("重新编辑后的正文") })
        store.route = "manual-map"; store.selectedObjectID = "question"; store.timeFrom = -4; store.timeTo = 6
        store.workspaceMemory.panels["map.timeline"] = .init(isPresented: true, collapsed: false)
        show(SpatialTimelineView())
        try await waitFor("eventTitleVisible", { self.hasText("王允问吕布") })
        try await waitFor("sourceActionVisible", { self.frame("回到原句") != nil })
        try await waitFor("participantsRetainDirectActions", { self.frame("参与者：吕布") != nil && self.frame("参与者：王允") != nil })
        try await waitForSummary()
        let contentFrame = window.convertToScreen(host.convert(host.bounds, to: nil))
        try check("eventSourceActionWithinViewport", frame("回到原句").map { contentFrame.contains($0) } == true)
        let endpoint = frame("时间范围终点")
        store.timeFrom = 3; store.timeTo = 5
        try await waitFor("filteredDetailPresent", { self.hasText("此事件不在当前时间范围内") })
        // The endpoint moves horizontally with its new value; changing the
        // event detail must not shift the time axis vertically under a hand.
        let afterEndpoint = frame("时间范围终点")
        observations.append(["timeAxisBefore": endpoint.map { [$0.midX, $0.midY] } ?? [], "timeAxisAfter": afterEndpoint.map { [$0.midX, $0.midY] } ?? []])
        try check("filterKeepsTimeAxisVerticalPosition", endpoint.flatMap { before in afterEndpoint.map { after in abs(before.midY - after.midY) < 1.5 } } == true)
        store.timeFrom = -4; store.timeTo = 6
        try await waitFor("sourceActionVisible", { self.frame("回到原句") != nil })
        try await press("参与者：吕布")
        try await waitFor("participantActionSelectsCanonicalPerson", { self.store.selectedTemporalEntityID == "lu" })
        window.setContentSize(CGSize(width: 820, height: 820))
        try await Task.sleep(for: .milliseconds(150))
        if object("展开时间卡片") != nil || timelineTrack() == nil { try await press("展开时间卡片") }
        try await waitFor("narrowDetailsAndSourceStayInViewport", {
            let bounds = self.window.convertToScreen(self.host.convert(self.host.bounds, to: nil))
            return self.frame("回到原句").map { bounds.contains($0) && $0.height >= 40 } == true
        })
        try await press("回到原句")
        try await waitFor("sourceActionNavigatesToSameUnit", { self.store.route == "reader" && self.store.selectedUnitID == "u104" })
        try await waitFor("sourceNavigationReturnsToReader", { self.store.route == "reader" && self.store.selectedUnitID == "u104" })
        let loaded = try await repository.loadAll().first!
        try check("noDuplicateDocumentsOrNodes", loaded.activeDocuments.count == 3 && loaded.nodes.count == 3 && Set(loaded.nodes.map(\.targetID)) == Set(loaded.activeDocuments.map(\.id)))
        try check("sourceBytesUnchanged", try Data(contentsOf: source) == bytes)
        try check("onlyIntentionalMarkdownEdit", loaded.events == book.events && loaded.entities == book.entities && loaded.units == book.units && !baseline.isEmpty)
        try check("noModelRequests", await transport.calls == 0)
    }
    func finish(_ error: String?) throws {
        let record: [String: Any] = ["status": error == nil ? "passed" : "failed", "error": error ?? NSNull(), "checks": checks, "checkCount": checks.count, "observations": observations, "rasterCaptureCount": rasterCaptureCount, "forcedRasterObservation": forceRaster, "realNetworkRequests": 0, "originalLibraryUsed": false, "fixture": "Actual public-domain sentence, manually bound objects and notes; not AI full-book analysis", "scope": "Unmodified product GraphSurface, DocumentGraphView, CompositionWorkspaceView and SpatialTimelineView; in-process AX or actual Vision raster/native-view geometry when SwiftUI virtual AX is absent; real window events"]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
    }
}
@main private enum Main {
    static func main() {
        let app = NSApplication.shared, delegate = PreviewHost()
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run(); withExtendedLifetime(delegate) {}
    }
}
