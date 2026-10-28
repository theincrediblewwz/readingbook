import AppKit
import SwiftUI
import Foundation
import CryptoKit
import PDFKit
import WebKit
import Darwin
@testable import ReadingBook
@testable import ReadingCore

final class Metrics: @unchecked Sendable {
    struct Pulse: Sendable { let queuedAt: Double; let phase: String; let action: String }
    let lock = NSLock()
    let startedAt = ProcessInfo.processInfo.systemUptime
    var lastBeat = ProcessInfo.processInfo.systemUptime
    var maximumLag = 0.0
    var maximumStartupLag = 0.0
    var maximumInteractiveLag = 0.0
    var interactiveStartedAt: Double?
    var maximumLagByPhase: [String: Double] = [:]
    var worstHeartbeat: [String: Any] = [:]
    var slowHeartbeats: [[String: Any]] = []
    var slowHeartbeatCount = 0
    var beats = 0
    var layouts = 0
    var completed = 0
    var lastAction = "initialization"
    var phase = "starting"
    var watchdogFired = false
    func scenario() {
        lock.lock(); defer { lock.unlock() }
        if interactiveStartedAt == nil { interactiveStartedAt = ProcessInfo.processInfo.systemUptime }
        phase = "scenario"
    }
    func settling() { lock.lock(); phase = "settling"; lock.unlock() }
    func record(_ label: String) { lock.lock(); lastAction = label; completed += 1; lock.unlock() }
    func layout() { lock.lock(); layouts += 1; lock.unlock() }
    func pulse() -> Pulse {
        lock.lock(); defer { lock.unlock() }
        // Attribute the waiting interval to its phase/action before enqueueing.
        return Pulse(queuedAt: ProcessInfo.processInfo.systemUptime, phase: phase, action: lastAction)
    }
    func beat(_ pulse: Pulse) {
        let delivered = ProcessInfo.processInfo.systemUptime
        let lag = delivered - pulse.queuedAt
        lock.lock(); defer { lock.unlock() }
        // A pulse can straddle the first-open boundary. Charge only its
        // waiting-interval overlap to interaction, without losing that overlap
        // just because the pulse was originally queued during startup.
        let interactiveOverlap = interactiveStartedAt.map { max(0, delivered - max(pulse.queuedAt, $0)) } ?? 0
        let sample: [String: Any] = ["queuedPhase": pulse.phase, "queuedAction": pulse.action,
            "deliveredPhase": phase, "interactiveOverlapSeconds": interactiveOverlap,
            "lagSeconds": lag, "queuedSecondsSinceStart": pulse.queuedAt - startedAt,
            "deliveredSecondsSinceStart": delivered - startedAt]
        if lag > maximumLag { maximumLag = lag; worstHeartbeat = sample }
        maximumLagByPhase[pulse.phase] = max(maximumLagByPhase[pulse.phase] ?? 0, lag)
        if pulse.phase == "starting" { maximumStartupLag = max(maximumStartupLag, lag) }
        maximumInteractiveLag = max(maximumInteractiveLag, interactiveOverlap)
        if lag > 0.5 {
            slowHeartbeatCount += 1; slowHeartbeats.append(sample)
            if slowHeartbeats.count > 100 {
                slowHeartbeats.sort { ($0["lagSeconds"] as? Double ?? 0) > ($1["lagSeconds"] as? Double ?? 0) }
                slowHeartbeats.removeLast()
            }
        }
        lastBeat = delivered; beats += 1
    }
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["phase": phase, "lastAction": lastAction, "actions": completed, "heartbeats": beats,
                "layouts": layouts, "maximumMainQueueLagSeconds": maximumLag,
                "maximumStartupQueueLagSeconds": maximumStartupLag,
                "maximumInteractiveQueueLagSeconds": maximumInteractiveLag,
                "maximumQueueLagSecondsByPhase": maximumLagByPhase,
                "worstHeartbeat": worstHeartbeat, "slowHeartbeatCount": slowHeartbeatCount,
                "slowHeartbeatsOverHalfSecond": slowHeartbeats,
                "secondsSinceHeartbeat": ProcessInfo.processInfo.systemUptime - lastBeat]
    }
}
let metrics = Metrics()

@MainActor final class CountingHost: NSHostingView<AnyView> {
    override func layout() { metrics.layout(); super.layout() }
}

struct PanelHarnessRoot: View {
    @ObservedObject var store: AppStore
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white
                ReaderFloatingPanel(title: "伴读与对话", icon: "sparkles", width: max(376, ReadingCompanionToolbarMetrics.minimumPanelWidth), height: 620,
                    minimumWidth: ReadingCompanionToolbarMetrics.minimumPanelWidth,
                    isPresented: $store.readingCompanionVisible, viewport: geometry.size,
                    showsRestoreButton: false, unifiedDismiss: true, resizable: true, showsCompanionTabs: true) {
                    ReaderAIPanel()
                }
            }
        }
    }
}

@MainActor final class Runner: NSObject, NSApplicationDelegate {
    let output: URL
    let library: URL
    let mode: String
    let cycles: Int
    var store: AppStore!
    var window: NSWindow!
    var timer: DispatchSourceTimer?
    let synthetic: Bool
    let draft = "Native layout regression draft; never send."
    init(output: URL, library: URL, mode: String, cycles: Int, synthetic: Bool) {
        self.output = output; self.library = library; self.mode = mode; self.cycles = cycles; self.synthetic = synthetic
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        startHeartbeat()
        Task { await runScenario() }
    }
    func writeJSON(_ name: String, _ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent(name), options: .atomic)
        }
    }
    func startHeartbeat() {
        let localOutput = output
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler {
            let pulse = metrics.pulse()
            let state = metrics.snapshot()
            if (state["secondsSinceHeartbeat"] as? Double ?? 0) > 5 {
                metrics.lock.lock()
                let first = !metrics.watchdogFired
                metrics.watchdogFired = true
                metrics.lock.unlock()
                if first {
                    if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: localOutput.appendingPathComponent("hang-heartbeat.json"), options: .atomic)
                    }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    process.arguments = [String(getpid()), "5", "10", "-file", localOutput.appendingPathComponent("hang.sample.txt").path]
                    try? process.run(); process.waitUntilExit()
                    exit(70)
                }
            }
            DispatchQueue.main.async { metrics.beat(pulse) }
        }
        t.resume(); timer = t
    }
    func syntheticBook() -> BookProject {
        let units = (1...1484).map { page in
            SourceUnit(id: String(format: "unit-%06d",page), order: page, chapter: "Synthetic chapter \((page-1)/20 + 1)", page: page,
                lineStart: 1, lineEnd: 8, text: "Synthetic source page \(page). This paragraph has no private text. It exercises the actual companion projection and native menu layout.\nA second paragraph preserves line and sentence boundaries.")
        }
        return BookProject(id: "11111111-1111-4111-8111-111111111111", title: "Synthetic 1484-page layout fixture", originalName: "fixture.txt", sourceHash: "native-ui-regression-synthetic", units: units)
    }
    func runScenario() async {
        // Empty serialized service profiles force AppStore.init to avoid every credential read.
        UserDefaults.standard.setVolatileDomain([
            "service-profiles": Data("[]".utf8), "library.root.path.v1": library.path,
            "appearance.reduceMotion": false, "reader.hoverAutoTranslation": false,
            "NSQuitAlwaysKeepsWindows": false, "ApplePersistenceIgnoreState": true
        ], forName: UserDefaults.argumentDomain)
        store = AppStore()
        guard store.apiKey.isEmpty, store.savedServices.isEmpty else { fatalError("Harness service isolation failed") }
        store.settings = ProviderSettings(baseURL: "http://127.0.0.1:1/disabled", model: "")
        if mode == "pdf" { await runPDFScenario(); return }
        if mode == "navigation" { await runBookPickerScenario(); return }
        if mode == "continuation" { await runContinuationScenario(); return }
        if synthetic {
            store.books = [syntheticBook()]
            store.bookID = store.books[0].id
            store.workspaceMemory = BookWorkspaceMemory(bookID: store.books[0].id, sourceHash: store.books[0].sourceHash)
            store.selectedUnitID = store.books[0].units[181].id
        } else {
            await store.load()
            guard store.book != nil else {
                writeJSON("result.json", ["status": "failed", "reason": "isolated library failed to load"])
                exit(2)
            }
        }
        store.route = "reader"
        store.readingCompanionVisible = false
        store.queryComposerDraft.text = draft
        let root: AnyView
        if mode == "panel" { root = AnyView(PanelHarnessRoot(store: store).environmentObject(store).environmentObject(ReadingTypographySettings()).modifier(ReadingPreferencesEnvironment())) }
        else { root = AnyView(WorkspaceView().environmentObject(store).environmentObject(ReadingTypographySettings()).modifier(ReadingPreferencesEnvironment()).background(FrostWindowAppearance())) }
        let host = CountingHost(rootView: root)
        window = NSWindow(contentRect: NSRect(x: 0, y: 50, width: 1470, height: 843), styleMask: [.titled,.closable,.resizable,.miniaturizable,.fullSizeContentView], backing: .buffered, defer: false)
        window.title = "ReadingBook Native UI Regression"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 500_000_000)
        metrics.scenario()
        let sizes = [CGSize(width:1470,height:843), CGSize(width:800,height:600), CGSize(width:970,height:650), CGSize(width:1200,height:760)]
        let pages = [1,8,182,800,1484]
        for cycle in 0..<cycles {
            metrics.record("open-\(cycle)")
            store.readingCompanionVisible = true
            try? await Task.sleep(nanoseconds: 90_000_000)
            metrics.record("chat-\(cycle)")
            store.readingCompanionTab = "chat"
            try? await Task.sleep(nanoseconds: 90_000_000)
            metrics.record("resize-\(cycle)")
            window.setContentSize(sizes[cycle % sizes.count])
            try? await Task.sleep(nanoseconds: 90_000_000)
            metrics.record("companion-\(cycle)")
            store.readingCompanionTab = "companion"
            if let unit = store.book?.units.first(where: { $0.page == pages[cycle % pages.count] }) {
                metrics.record("page-\(pages[cycle % pages.count])")
                store.selectedUnitID = unit.id
            }
            try? await Task.sleep(nanoseconds: 90_000_000)
            metrics.record("close-\(cycle)")
            store.readingCompanionVisible = false
            try? await Task.sleep(nanoseconds: 90_000_000)
        }
        metrics.settling()
        try? await Task.sleep(nanoseconds: 500_000_000)
        var state = metrics.snapshot()
        var failures: [String] = []
        if store.queryComposerDraft.text != draft { failures.append("composer draft changed") }
        if store.isQueryBusy || store.isSmartReadingRunning { failures.append("unexpected query or analysis running") }
        if !window.isVisible || (state["layouts"] as? Int ?? 0) == 0 || (state["heartbeats"] as? Int ?? 0) == 0 {
            failures.append("native window/layout/heartbeat unavailable")
        }
        // First open is interactive: never pre-open or add a warm-up. Retain the global peak.
        if (state["maximumInteractiveQueueLagSeconds"] as? Double ?? 99) >= 1.5 {
            failures.append("interactive main-queue lag exceeded 1.5 seconds")
        }
        if (state["maximumStartupQueueLagSeconds"] as? Double ?? 99) >= 5 {
            failures.append("startup main-queue lag exceeded 5 seconds")
        }
        state["status"] = failures.isEmpty ? "passed" : "failed"
        state["failureReasons"] = failures
        state["lagBudgetsSeconds"] = ["startup": 5.0, "interactiveIncludingFirstOpen": 1.5]
        state["watchdogAllPhasesSeconds"] = 5.0
        state["cycles"] = cycles; state["mode"] = mode; state["synthetic"] = synthetic
        state["fixtureUnitCount"] = store.book?.units.count ?? 0
        state["sourceFormat"] = store.sourceFileURL?.pathExtension ?? "synthetic-source-units"
        state["windowVisible"] = window.isVisible
        state["draftPreserved"] = store.queryComposerDraft.text == draft
        state["noQueryRunning"] = !store.isQueryBusy
        state["noAnalysisRunning"] = !store.isSmartReadingRunning
        state["testScope"] = "real product views and AppStore; programmatic state transitions; no pointer gesture or paid AI coverage"
        writeJSON("result.json", state)
        timer?.cancel()
        window.orderOut(nil)
        NSApp.terminate(nil)
    }
}

/// Invoke the same production closure used by the title popover. This is a
/// headless AppStore/repository regression; actual view wiring is separate QA.
@MainActor extension Runner {
    private func bookPickerWait(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ReadingError.invalid("Book-picker regression timeout: " + description)
    }
    func runBookPickerScenario() async {
        var assertions: [String: Any] = [:]
        do {
            var projects: [BookProject] = []
            var sourceBytes: [String: Data] = [:]
            for suffix in ["A", "B"] {
                let source = output.appendingPathComponent("navigation-\(suffix).txt")
                let bytes = Data("Navigation fixture \(suffix). Original text stays unchanged.\n".utf8)
                try bytes.write(to: source)
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                var project = BookProject(title: "Book-picker fixture \(suffix)", originalName: source.lastPathComponent, sourceHash: hash,
                    units: [SourceUnit(id: "navigation-\(suffix)-u1", order: 0, chapter: "Fixture", page: 1, text: String(decoding: bytes, as: UTF8.self))])
                PluginEngine.seed(&project)
                project = try await store.repository.create(project, sourceURL: source)
                projects.append(project); sourceBytes[project.id] = bytes
            }
            let note = DocumentRecord(id: "navigation-note", title: "Navigation preserves notes")
            let noteBody = "# Navigation note\n\nPreserve e\u{301}, 🙂 and $x^2$.\n"
            projects[0] = try await store.repository.saveDocument(project: projects[0], document: note, markdown: noteBody)
            let canonicalBefore = try Dictionary(uniqueKeysWithValues: projects.map { project in
                (project.id, try Data(contentsOf: library.appendingPathComponent("books/\(project.id)/project.json")))
            })
            store.books = projects; store.bookID = projects[0].id; store.selectedUnitID = projects[0].units[0].id
            store.workspaceMemory = BookWorkspaceMemory(bookID: projects[0].id, sourceHash: projects[0].sourceHash)
            store.route = "library"; store.flushWorkspaceMemory()
            var secondMemory = BookWorkspaceMemory(bookID: projects[1].id, sourceHash: projects[1].sourceHash)
            secondMemory.route = "library"
            let secondKey = projects[1].id + "|" + projects[1].sourceHash
            let secondName = SHA256.hash(data: Data(secondKey.utf8)).map { String(format: "%02x", $0) }.joined()
            try JSONEncoder().encode(secondMemory).write(to: library.appendingPathComponent("Workspace/\(secondName).json"), options: .atomic)
            await store.selectBook(projects[0].id)
            try pdfRequire(store.route == "library", "Ordinary selection must still restore its persisted library route")
            assertions["ordinarySelectionRestoresLibraryRoute"] = true
            store.bookID = nil
            metrics.scenario(); metrics.record("book-action-without-active-book")
            WorkspaceBookPickerNavigation.action(for: projects[0], store: store)()
            try await bookPickerWait("no active book enters reader") { self.store.bookID == projects[0].id && self.store.route == "reader" && !self.store.isBusy }
            assertions["bookSelectionWithoutActiveBookWorks"] = true
            store.route = "library"; store.flushWorkspaceMemory()
            let currentAction = WorkspaceBookPickerNavigation.action(for: projects[0], store: store)
            let generation = store.navigationGeneration
            store.isBusy = true; currentAction()
            try await Task.sleep(nanoseconds: 30_000_000)
            try pdfRequire(store.navigationGeneration == generation && store.route == "library", "Busy navigation must not start selection")
            store.isBusy = false
            store.editorTitle = "Unsaved navigation draft"; store.editorMarkdown = "# Keep this dirty draft\n"; store.editorDirty = true
            currentAction(); try await Task.sleep(nanoseconds: 30_000_000)
            try pdfRequire(store.navigationGeneration == generation && store.route == "library" && store.editorDirty
                && store.editorMarkdown == "# Keep this dirty draft\n", "Dirty navigation must preserve the draft and route")
            store.discardDraftForWorkspaceNavigation()
            assertions["busyAndDirtySelectionGatesPreserved"] = true
            let questionDraft = "Preserve this same-book question draft."
            store.queryComposerDraft.text = questionDraft
            metrics.record("book-action-current-from-library")
            currentAction()
            try await bookPickerWait("current book finishes in reader") { self.store.bookID == projects[0].id && self.store.route == "reader" && !self.store.isBusy }
            try pdfRequire(store.sourceFileURL != nil && store.queryComposerDraft.text == questionDraft, "Same-book navigation must keep its source and question draft")
            assertions["currentBookActionOverridesLibraryRoute"] = true
            assertions["sameBookQuestionDraftPreserved"] = true
            metrics.record("book-action-other-from-reader")
            WorkspaceBookPickerNavigation.action(for: projects[1], store: store)()
            try await bookPickerWait("other book finishes in reader") { self.store.bookID == projects[1].id && self.store.route == "reader" && !self.store.isBusy }
            try pdfRequire(store.selectedUnitID == projects[1].units[0].id && store.sourceFileURL != nil, "Other book must open its own source and unit")
            try pdfRequire(try Data(contentsOf: store.sourceFileURL!) == sourceBytes[projects[1].id], "Other book must show its own original bytes")
            assertions["otherBookActionOverridesItsLibraryRoute"] = true
            let staleAction = WorkspaceBookPickerNavigation.action(for: projects[0], store: store)
            let settledGeneration = store.navigationGeneration
            store.books[0].sourceHash = "changed-fixture-source"; staleAction()
            try await Task.sleep(nanoseconds: 30_000_000)
            try pdfRequire(store.navigationGeneration == settledGeneration && store.bookID == projects[1].id, "Changed target source must reject a stale action")
            store.books = projects
            store.books.removeAll { $0.id == projects[0].id }; staleAction()
            try await Task.sleep(nanoseconds: 30_000_000)
            try pdfRequire(store.navigationGeneration == settledGeneration && store.bookID == projects[1].id, "Removed target book must reject a stale action")
            store.books = projects
            let root = store.libraryRootURL
            store.libraryRootURL = output.appendingPathComponent("unopened-other-library")
            staleAction(); try await Task.sleep(nanoseconds: 30_000_000)
            try pdfRequire(store.navigationGeneration == settledGeneration && store.bookID == projects[1].id, "Changed library must reject a stale action")
            store.libraryRootURL = root
            assertions["changedSourceRemovedBookAndOtherLibraryRejected"] = true
            for project in projects {
                let canonical = await store.repository.sourceURL(for: project)
                try pdfRequire(try Data(contentsOf: canonical) == sourceBytes[project.id], "Navigation changed a canonical original")
                try pdfRequire(try Data(contentsOf: library.appendingPathComponent("books/\(project.id)/project.json")) == canonicalBefore[project.id], "Navigation rewrote the canonical project")
            }
            try pdfRequire(try await store.repository.readDocument(bookID: projects[0].id, document: note) == noteBody, "Navigation changed the saved note")
            assertions["originalsProjectsAndMarkdownBytesPreserved"] = true
            assertions["realNetworkRequests"] = 0
            assertions["status"] = "passed"
        } catch {
            assertions["status"] = "failed"; assertions["reason"] = error.localizedDescription
        }
        metrics.settling(); try? await Task.sleep(nanoseconds: 250_000_000)
        assertions["mode"] = mode; assertions["synthetic"] = true
        assertions["metrics"] = metrics.snapshot()
        assertions["windowCreated"] = window != nil
        assertions["testScope"] = "headless real production WorkspaceBookPickerNavigation action, AppStore/repository and saved workspace restoration; view wiring/selection/import affordances require separate UI QA"
        writeJSON("result.json", assertions)
        timer?.cancel(); NSApp.terminate(nil)
    }
}

/// A separate correctness scenario in the same isolated runner. It inspects
/// public native PDFKit objects; there is no private KVC or product test hook.
@MainActor extension Runner {
    private func pdfRequire(_ value: Bool, _ message: String) throws {
        guard value else { throw ReadingError.invalid(message) }
    }
    private func pdfWait(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            window?.contentView?.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ReadingError.invalid("PDF regression timeout: " + description)
    }
    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        ([root as? T].compactMap { $0 }) + root.subviews.flatMap { descendants($0, type) }
    }
    private func capturePDFView(_ name: String) throws {
        guard let window, let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw ReadingError.invalid("Native screenshot unavailable")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ReadingError.invalid("PNG encoding failed") }
        try data.write(to: output.appendingPathComponent(name))
    }
    private func pdfObjects() -> (PDFReaderContainerView, PDFThumbnailView, PDFView)? {
        guard let root = window?.contentView,
              let container = descendants(root, PDFReaderContainerView.self).first,
              let thumbnail = descendants(container, PDFThumbnailView.self).first,
              let pdf = descendants(container, PDFView.self).first else { return nil }
        return (container, thumbnail, pdf)
    }
    private func clickThumbnail(_ thumbnail: PDFThumbnailView, page: Int) async throws {
        // PDFKit uses a native collection view. Its public layout supplies the
        // target rectangle; normal local NSApplication events perform selection.
        // Never send a global event to the installed app or another window.
        var collection: NSCollectionView?
        try await pdfWait("PDFKit thumbnail collection") {
            collection = self.descendants(thumbnail, NSCollectionView.self).first {
                $0.numberOfSections > 0 && $0.numberOfItems(inSection: 0) >= page
            }
            return collection != nil
        }
        guard let collection else { throw ReadingError.invalid("PDFKit collection unavailable") }
        let path = IndexPath(item: page - 1, section: 0)
        collection.scrollToItems(at: [path], scrollPosition: .centeredVertically)
        collection.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 70_000_000)
        guard let attributes = collection.layoutAttributesForItem(at: path) else { throw ReadingError.invalid("Thumbnail item has no layout") }
        // PDFThumbnailView is nonflipped while its collection is flipped on
        // current macOS. Scroll its public outer clip using converted geometry.
        let target = collection.convert(attributes.frame, to: thumbnail)
        if let scroll = thumbnail.enclosingScrollView {
            let clip = scroll.contentView
            let y = min(max(0, target.midY - clip.bounds.height / 2), max(0, thumbnail.bounds.height - clip.bounds.height))
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y)); scroll.reflectScrolledClipView(clip)
        } else { thumbnail.scrollToVisible(target) }
        try await Task.sleep(nanoseconds: 70_000_000)
        let point = collection.convert(NSPoint(x: attributes.frame.midX, y: attributes.frame.midY), to: nil)
        writeJSON("thumbnail-native-layout.json", ["page": page, "itemFrame": NSStringFromRect(attributes.frame),
            "collectionFrame": NSStringFromRect(collection.frame), "collectionVisibleRect": NSStringFromRect(collection.visibleRect),
            "thumbnailFrame": NSStringFromRect(thumbnail.frame), "thumbnailVisibleRect": NSStringFromRect(thumbnail.visibleRect),
            "windowPoint": NSStringFromPoint(point), "contentBounds": NSStringFromRect(window.contentView!.bounds)])
        try pdfRequire(window.contentView?.bounds.contains(window.contentView!.convert(point, from: nil)) == true,
            "Thumbnail click must stay within its own test window")
        let now = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: now,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: now + 0.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else {
            throw ReadingError.invalid("Unable to construct window-local thumbnail click")
        }
        NSApp.postEvent(down, atStart: false); NSApp.postEvent(up, atStart: false)
    }
    func runPDFScenario() async {
        var assertions: [String: Any] = [:]
        do {
            let source = output.appendingPathComponent("native-8-pages.pdf")
            var media = CGRect(x: 0, y: 0, width: 420, height: 595)
            guard let graphics = CGContext(source as CFURL, mediaBox: &media, nil) else { throw ReadingError.invalid("Unable to create fixture PDF") }
            for number in 1...8 {
                graphics.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics, flipped: false)
                NSString(string: "Native PDF fixture - page \(number)").draw(at: NSPoint(x: 35, y: 500),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
                NSString(string: "Synthetic source only; no private text.").draw(at: NSPoint(x: 35, y: 460),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])
                NSGraphicsContext.restoreGraphicsState()
                graphics.endPDFPage()
            }
            graphics.closePDF()
            let sourceBytes = try Data(contentsOf: source)
            let sourceHash = SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined()
            var project = BookProject(title: "Native PDF correctness fixture", originalName: source.lastPathComponent, sourceHash: sourceHash,
                units: (1...8).map { SourceUnit(id: "pdf-page-\($0)", order: $0 - 1, chapter: "Fixture", page: $0, text: "Native PDF fixture - page \($0)") })
            PluginEngine.seed(&project)
            project = try await store.repository.create(project, sourceURL: source)
            let note = DocumentRecord(id: "pdf-regression-note", title: "Preserved fixture note"), noteBody = "# Preserve me\n\nPDF navigation must not rewrite user notes.\n"
            project = try await store.repository.saveDocument(project: project, document: note, markdown: noteBody)
            store.books = [project]; store.bookID = project.id; store.selectedUnitID = project.units[0].id
            store.workspaceMemory = BookWorkspaceMemory(bookID: project.id, sourceHash: project.sourceHash)
            store.sourceFileURL = nil; store.readingCompanionVisible = false
            let controller = PDFReaderController()
            let root = ReaderWorkspaceView(showPDF: .constant(true), showOutline: .constant(false), bookmarksOnly: .constant(false))
                .environmentObject(store).environmentObject(controller).environmentObject(ReadingTypographySettings())
                .modifier(ReadingPreferencesEnvironment())
            let host = CountingHost(rootView: AnyView(root))
            window = NSWindow(contentRect: NSRect(x: 70, y: 70, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "ReadingBook isolated native PDF correctness regression"
            window.contentView = host; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            metrics.scenario(); metrics.record("pdf-source-url-deliberately-withheld")
            var waitingSamples = 0
            let waitingDeadline = ProcessInfo.processInfo.systemUptime + 0.35
            repeat {
                host.layoutSubtreeIfNeeded(); waitingSamples += 1
                try pdfRequire(descendants(host, WKWebView.self).isEmpty, "Waiting for a PDF URL must not mount the extracted-text WebKit reader")
                try pdfRequire(descendants(host, PDFReaderContainerView.self).isEmpty, "Missing PDF URL must not mount a stale PDF container")
                try await Task.sleep(nanoseconds: 10_000_000)
            } while ProcessInfo.processInfo.systemUptime < waitingDeadline
            try capturePDFView("pdf-waiting-for-source.png")
            assertions["waitingURLSamplesWithoutTemporaryTextReader"] = waitingSamples
            store.sourceFileURL = await store.repository.sourceURL(for: project)
            try await pdfWait("physical PDF mounted and ready") { self.pdfObjects() != nil && controller.isReady && controller.pageCount == 8 }
            guard let initial = pdfObjects(), let initialDocument = initial.2.document else { throw ReadingError.invalid("Native PDF objects unavailable") }
            try pdfRequire(initial.1.pdfView == nil && !controller.thumbnailsVisible, "Closed thumbnails must not bind PDFView on initial physical-PDF load")
            assertions["initialClosedThumbnailsUnbound"] = true
            metrics.record("pdf-open-thumbnails-and-native-click")
            controller.command(.setThumbnails(true))
            try await pdfWait("visible thumbnails bind native PDFView") { initial.1.pdfView === initial.2 && controller.thumbnailsVisible && !controller.thumbnailFrame.isEmpty }
            try await clickThumbnail(initial.1, page: 3)
            try await pdfWait("native thumbnail selection navigates the actual PDF") { controller.page == 3 && initial.2.currentPage === initialDocument.page(at: 2) }
            try pdfRequire(initial.1.selectedPages?.contains(where: { $0 === initialDocument.page(at: 2) }) == true, "Thumbnail selection must follow the displayed PDF page")
            try capturePDFView("pdf-thumbnail-selected-page-3.png")
            assertions["openThumbnailsBoundToActualPDFView"] = true
            assertions["nativeThumbnailClickNavigatedPage3"] = true
            for cycle in 0..<cycles {
                metrics.record("pdf-thumbnail-close-reopen-\(cycle)")
                controller.command(.setThumbnails(false))
                try await pdfWait("close detaches thumbnails") { initial.1.pdfView == nil && !controller.thumbnailsVisible }
                controller.command(.setThumbnails(true))
                try await pdfWait("reopen rebinds thumbnails") { initial.1.pdfView === initial.2 && controller.thumbnailsVisible }
                controller.command(.jump((cycle % 8) + 1))
                try await pdfWait("navigation after rebind") { controller.page == (cycle % 8) + 1 }
            }
            assertions["closeReopenNavigationCycles"] = cycles
            controller.command(.setThumbnails(false))
            try await pdfWait("final close detaches thumbnails") { initial.1.pdfView == nil && !controller.thumbnailsVisible }
            store.pdfNavigationToken += 1
            try await Task.sleep(nanoseconds: 80_000_000)
            try pdfRequire(pdfObjects()?.2.document === initialDocument && initial.1.pdfView == nil,
                "An ordinary same-URL SwiftUI update must reuse its document and keep closed thumbnails detached")
            assertions["sameURLUpdateKeptClosedThumbnailsDetached"] = true

            let restored = WorkspacePDFMemory(page: 6, scale: 1, fitMode: "page", continuous: false, thumbnails: true, direction: .horizontal)
            store.updateWorkspaceMemory { $0.pdf = restored }
            store.selectedUnitID = project.units[5].id; store.workspaceMemoryRevision += 1
            try await pdfWait("same-URL saved visible preferences") {
                initial.1.pdfView === initial.2 && controller.thumbnailsVisible && controller.page == 6
                    && !controller.isContinuous && controller.direction == .horizontal && controller.fitMode == "page"
            }
            assertions["sameURLMemoryRevisionRestoredVisibleBindingAndPreferences"] = true
            var hidden = restored; hidden.thumbnails = false
            store.updateWorkspaceMemory { $0.pdf = hidden }; store.workspaceMemoryRevision += 1
            try await pdfWait("same-URL saved hidden preferences") { initial.1.pdfView == nil && !controller.thumbnailsVisible }
            assertions["sameURLMemoryRevisionRestoredHiddenUnbinding"] = true
            store.updateWorkspaceMemory { $0.pdf = restored }; store.workspaceMemoryRevision += 1
            try await pdfWait("saved visible preferences before reload") { initial.1.pdfView === initial.2 && controller.thumbnailsVisible }
            NotificationCenter.default.post(name: Notification.Name("ReadingBookCaptureWorkspaceMemory"), object: nil)
            store.flushWorkspaceMemory()
            store.sourceFileURL = nil
            try await pdfWait("old reader dismantled for same-book reload") { self.pdfObjects() == nil }
            try pdfRequire(initial.1.pdfView == nil, "Dismantling the old reader must unbind its thumbnail view")
            await store.selectBook(project.id)
            try await pdfWait("same-book reload restores visible thumbnail workspace") {
                guard let current = self.pdfObjects() else { return false }
                return current.0 !== initial.0 && current.1.pdfView === current.2 && controller.isReady
                    && controller.page == 6 && controller.thumbnailsVisible && !controller.isContinuous
                    && controller.direction == .horizontal && controller.fitMode == "page"
            }
            assertions["sameBookReloadRestoredVisibleThumbnailsAndPreferences"] = true
            guard let reloaded = pdfObjects() else { throw ReadingError.invalid("Reloaded native reader missing") }
            controller.command(.setThumbnails(false))
            try await pdfWait("reloaded thumbnails close") { reloaded.1.pdfView == nil && !controller.thumbnailsVisible }
            NotificationCenter.default.post(name: Notification.Name("ReadingBookCaptureWorkspaceMemory"), object: nil)
            store.flushWorkspaceMemory(); store.sourceFileURL = nil
            try await pdfWait("hidden reader dismantled") { self.pdfObjects() == nil }
            await store.selectBook(project.id)
            try await pdfWait("same-book reload retains hidden thumbnails") {
                self.pdfObjects()?.1.pdfView == nil && self.pdfObjects() != nil && controller.isReady && !controller.thumbnailsVisible && controller.page == 6
            }
            assertions["sameBookReloadKeptHiddenThumbnailsUnbound"] = true
            try capturePDFView("pdf-restored-hidden-thumbnails-page-6.png")
            try pdfRequire(try Data(contentsOf: source) == sourceBytes, "PDF fixture bytes changed")
            try pdfRequire(try Data(contentsOf: store.sourceFileURL!) == sourceBytes, "Canonical source PDF bytes changed")
            try pdfRequire(try await store.repository.readDocument(bookID: project.id, document: note) == noteBody, "User Markdown changed during PDF navigation")
            assertions["sourceAndMarkdownBytesPreserved"] = true
            assertions["realNetworkRequests"] = 0
            assertions["status"] = "passed"
        } catch {
            assertions["status"] = "failed"; assertions["reason"] = error.localizedDescription
            try? capturePDFView("pdf-failure.png")
        }
        metrics.settling()
        try? await Task.sleep(nanoseconds: 250_000_000)
        assertions["mode"] = mode; assertions["synthetic"] = true; assertions["physicalPDFPageCount"] = 8
        assertions["windowVisible"] = window?.isVisible ?? false
        assertions["metrics"] = metrics.snapshot()
        assertions["testScope"] = "real ReaderWorkspaceView/PDFKit, public native object binding, window-local thumbnail click, canonical workspace persistence; correctness, not FPS"
        writeJSON("result.json", assertions)
        timer?.cancel(); window?.orderOut(nil); NSApp.terminate(nil)
    }
}

/// Real workflow views, local deterministic data; no configured model or socket.
@MainActor extension Runner {
    func runContinuationScenario() async {
        var assertions: [String: Any] = ["realNetworkRequests": 0, "mode": mode]
        do {
            let units = (1...200).map { page in
                SourceUnit(id: "continuation-u\(page)", order: page-1, chapter: "第\((page-1)/20+1)章", page: page,
                    text: "第\(page)页的合成原文。刘备在此，以下内容仅用于离线续读界面测试。")
            }
            let bytes = Data(units.map(\.text).joined(separator: "\n\n").utf8)
            let source = library.deletingLastPathComponent().appendingPathComponent("continuation-fixture.txt")
            try bytes.write(to: source)
            var project = BookProject(id: "22222222-2222-4222-8222-222222222222", title: "续读交互 · 合成200页", originalName: source.lastPathComponent,
                sourceHash: try BookImporter.sha256(bytes), units: units)
            PluginEngine.seed(&project)
            project.methods.append(ReadingMethod(id: "continuation-method", name: "理解原文", goal: "保留已完成讲解并处理缺口", steps: ["说明原文"] ))
            project.plan = ReadingPlan(methodIDs: ["continuation-method"])
            let configuration = ReadingExecutionConfiguration(granularity: .page, steps: [.init(id: "understand", title: "说明原文")])
            project.smartReading = try SmartReadingRuntime.freeze(.init(scope: .pageRange, pageStart: 1, pageEnd: 100, execution: configuration), in: project, currentUnitID: nil)
            project.smartReading?.isPlanConfirmed = true
            let hashes = project.smartReading!.unitHashes
            for work in try SmartReadingRuntime.analysisChunks(in: project) {
                let checkpoint = ReadingAnalysisCheckpoint(id: work.id, unitIDs: work.unitIDs,
                    unitHashes: Dictionary(uniqueKeysWithValues: work.unitIDs.map { ($0, hashes[$0]!) }),
                    configurationHash: work.configurationHash, completedStepIDs: work.stepIDs,
                    markdown: "## 已保存的讲解\n\n这段原文讲的是刘备在此。保留公式 $x^2$，不重新生成。",
                    evidence: work.unitIDs.map { id in Evidence(unitID: id, quote: units.first { $0.id == id }!.text) }, updatedAt: Date())
                project.smartReading!.analysisCheckpoints = (project.smartReading!.analysisCheckpoints ?? []) + [checkpoint]
                project.insights.append(ReadingInsight(id: "analysis-"+work.id, unitIDs: work.unitIDs, markdown: checkpoint.markdown))
            }
            project.smartReading?.status = .completed
            let previous = project
            project.smartReading = try SmartReadingRuntime.freeze(.init(scope: .pageRange, pageStart: 50, pageEnd: 200, execution: configuration), in: project, currentUnitID: nil)
            project.smartReading?.isPlanConfirmed = true
            try ReadingContinuationRuntime.preserveHistory(from: previous, in: &project)
            let owner = LibraryRepository(rootURL: library)
            project = try await owner.create(project, sourceURL: source)
            store.repository = owner; store.libraryRootURL = library; store.books = [project]
            store.bookID = project.id; store.selectedUnitID = units[49].id
            store.route = "workflow"; store.queryComposerDraft.text = draft
            let before = try Data(contentsOf: source)
            let preview = try await store.previewReadingContinuation(project.smartReading!.selection, intent: .continueMissing)
            guard preview.reusedUnitCount == 51, preview.newUnitCount == 100 else { throw ReadingError.invalid("真实原生预览的重叠计数不正确。") }
            let root = AnyView(WorkspaceView().environmentObject(store).environmentObject(ReadingTypographySettings()).modifier(ReadingPreferencesEnvironment()).background(FrostWindowAppearance()))
            let host = CountingHost(rootView: root)
            window = NSWindow(contentRect: NSRect(x: 0, y: 50, width: 1180, height: 900), styleMask: [.titled,.closable,.resizable,.miniaturizable,.fullSizeContentView], backing: .buffered, defer: false)
            window.title = "ReadingBook Continuation UI · Offline fixture"; window.contentView = host
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            metrics.scenario()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let sizes = [CGSize(width: 1180, height: 900), CGSize(width: 660, height: 780), CGSize(width: 860, height: 820)]
            for cycle in 0..<cycles {
                metrics.record("continuation-resize-\(cycle)")
                window.setContentSize(sizes[cycle % sizes.count])
                try await Task.sleep(nanoseconds: 180_000_000)
                if cycle < sizes.count { try capturePDFView("continuation-size-\(cycle).png") }
            }
            let hold = min(300, max(0, Int(ProcessInfo.processInfo.environment["HARNESS_HOLD_SECONDS"] ?? "0") ?? 0))
            if hold > 0 {
                writeJSON("ready.json", ["status": "ready", "holdSeconds": hold, "windowTitle": window.title])
                try await Task.sleep(nanoseconds: UInt64(hold)*1_000_000_000)
            }
            guard !store.isSmartReadingRunning, !store.isQueryBusy, store.queryComposerDraft.text == draft,
                  try Data(contentsOf: source) == before else { throw ReadingError.invalid("离线界面测试改动了原文、草稿或启动了AI。") }
            assertions["status"] = "passed"; assertions["reusedUnits"] = preview.reusedUnitCount
            assertions["newUnits"] = preview.newUnitCount; assertions["nativeWindowVisible"] = window.isVisible
            assertions["manualVisualQAHoldSeconds"] = hold; assertions["resizeCycles"] = cycles
            assertions["originalSourceAndDraftPreserved"] = true
        } catch { assertions["status"] = "failed"; assertions["reason"] = error.localizedDescription }
        metrics.settling(); try? await Task.sleep(nanoseconds: 250_000_000)
        assertions["metrics"] = metrics.snapshot()
        writeJSON("result.json", assertions); timer?.cancel(); window?.orderOut(nil); NSApp.terminate(nil)
    }
}

@main struct NativeUIHarness {
    @MainActor static func main() {
        let env = ProcessInfo.processInfo.environment
        guard let workspace = env["HARNESS_WORKSPACE"], let outputPath = env["HARNESS_OUTPUT"], let libraryPath = env["HARNESS_LIBRARY"],
              outputPath.hasPrefix(workspace + "/"), libraryPath.hasPrefix(workspace + "/") else { fatalError("Workspace-local output and library required") }
        let output = URL(fileURLWithPath:outputPath, isDirectory:true)
        let library = URL(fileURLWithPath:libraryPath, isDirectory:true)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories:true)
        try! FileManager.default.createDirectory(at: library, withIntermediateDirectories:true)
        let app = NSApplication.shared
        app.setActivationPolicy(env["HARNESS_MODE"] == "navigation" ? .prohibited : .regular)
        let runner = Runner(output:output,library:library,mode:env["HARNESS_MODE"] ?? "workspace",cycles:Int(env["HARNESS_CYCLES"] ?? "24") ?? 24,synthetic:env["HARNESS_SYNTHETIC"] != "0")
        app.delegate = runner
        withExtendedLifetime(runner) { app.run() }
    }
}
