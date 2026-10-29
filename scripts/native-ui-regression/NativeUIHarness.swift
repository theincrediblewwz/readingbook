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
    func record(_ label: String) {
        lock.lock(); lastAction = label; completed += 1; lock.unlock()
        if ProcessInfo.processInfo.environment["HARNESS_MODE"] == "samebook" {
            let event: [String: Any] = ["event": "native-samebook-phase", "action": label,
                "wallTimeEpochSeconds": Date().timeIntervalSince1970,
                "uptimeSeconds": ProcessInfo.processInfo.systemUptime]
            if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) {
                FileHandle.standardError.write(data); FileHandle.standardError.write(Data([0x0A]))
            }
        }
    }
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
        if mode == "samebook" { await runSameBookPDFScenario(); return }
        if mode == "boundary" { await runPDFBoundaryScenario(); return }
        if mode == "navigation" { await runBookPickerScenario(); return }
        if mode == "continuation" { await runContinuationScenario(); return }
        if mode == "urgent-search-overlay" { await runUrgentSearchOverlayScenario(); return }
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
    private func pdfWait(_ description: String, onTimeout: (() -> Void)? = nil, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            window?.contentView?.layoutSubtreeIfNeeded()
            let forcedStyle = ProcessInfo.processInfo.environment["HARNESS_PDF_SCROLLER_STYLE"]
                ?? (ProcessInfo.processInfo.environment["HARNESS_FORCE_LEGACY_SCROLLERS"] == "1" ? "legacy" : "")
            if ["legacy", "overlay"].contains(forcedStyle), let root = window?.contentView {
                let style: NSScroller.Style = forcedStyle == "legacy" ? .legacy : .overlay
                for pdf in descendants(root, PDFView.self) {
                    for scroll in descendants(pdf, NSScrollView.self) where scroll.scrollerStyle != style {
                        scroll.scrollerStyle = style
                    }
                }
                root.layoutSubtreeIfNeeded()
            }
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        onTimeout?()
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

/// Source admission, not a synthetic nil-URL shortcut: exercise the production
/// AppStore selection path with mounted public PDFKit objects and private fixtures.
@MainActor extension Runner {
    private func sameBookPDF(_ url: URL, label: String) throws -> Data {
        var media = CGRect(x: 0, y: 0, width: 420, height: 595)
        guard let graphics = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw ReadingError.invalid("Unable to create same-book PDF fixture")
        }
        for number in 1...8 {
            graphics.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics, flipped: false)
            NSString(string: "\(label) - page \(number)").draw(at: NSPoint(x: 35, y: 500),
                withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
            NSString(string: "Private test fixture. Keep notes, analysis and annotations.").draw(at: NSPoint(x: 35, y: 460),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState(); graphics.endPDFPage()
        }
        graphics.closePDF()
        return try Data(contentsOf: url)
    }
    private func sameBookState(_ label: String, controller: PDFReaderController) -> [String: Any] {
        let pdf = pdfObjects()?.2, document = pdf?.document
        let current: Int
        if let page = pdf?.currentPage, let document { current = document.index(for: page) + 1 } else { current = -1 }
        let destination = pdf?.currentDestination
        let destinationPage: Int
        if let page = destination?.page, let document { destinationPage = document.index(for: page) + 1 } else { destinationPage = -1 }
        return ["label": label, "selectedPage": store.selectedUnit?.page ?? -1,
            "controllerPage": controller.page, "viewCurrentPage": current,
            "destinationPage": destinationPage, "workspacePage": store.workspaceMemory.pdf?.page ?? -1,
            "destinationX": destination.map { Double($0.point.x) } ?? -1,
            "destinationY": destination.map { Double($0.point.y) } ?? -1,
            "workspaceX": store.workspaceMemory.pdf?.location?.x ?? -1,
            "workspaceY": store.workspaceMemory.pdf?.location?.y ?? -1,
            "scale": Double(pdf?.scaleFactor ?? 0), "ready": controller.isReady]
    }
    private func pdfViewportGeometry(_ pdf: PDFView) -> [String: Any] {
        guard let clip = pdf.documentView?.enclosingScrollView?.contentView else { return ["clipPresent": false] }
        let box = clip.bounds
        let corner = CGPoint(x: box.minX, y: clip.isFlipped ? box.minY : box.maxY)
        var value: [String: Any] = ["clipPresent": true, "clipBounds": NSStringFromRect(box), "clipFlipped": clip.isFlipped,
            "viewportCornerX": Double(corner.x), "viewportCornerY": Double(corner.y),
            "contentInsets": String(describing: clip.enclosingScrollView?.contentInsets)]
        if let destination = pdf.currentDestination, let page = destination.page {
            let getter = clip.convert(pdf.convert(destination.point, from: page), from: pdf)
            value["getterOffsetFromViewportX"] = Double(getter.x - corner.x)
            value["getterOffsetFromViewportY"] = Double(getter.y - corner.y)
        }
        if let page = pdf.page(for: CGPoint(x: pdf.bounds.midX, y: pdf.bounds.midY), nearest: false), let doc = pdf.document {
            value["geometricCenterPage"] = doc.index(for: page) + 1
        }
        return value
    }
    private func pdfLifecycleState(_ label: String, controller: PDFReaderController) -> [String: Any] {
        var value = sameBookState(label, controller: controller)
        let root = window?.contentView
        let containers = root.map { descendants($0, PDFReaderContainerView.self) } ?? []
        let thumbnails = root.map { descendants($0, PDFThumbnailView.self) } ?? []
        let views = root.map { descendants($0, PDFView.self) } ?? []
        value["containerCount"] = containers.count; value["thumbnailCount"] = thumbnails.count
        value["pdfViewCount"] = views.count; value["pdfObjectsPresent"] = pdfObjects() != nil
        value["sourceURL"] = store.sourceFileURL?.absoluteString ?? ""
        value["bookID"] = store.bookID ?? ""; value["selectedUnitID"] = store.selectedUnitID ?? ""
        value["sourceMode"] = store.readingSourceMode; value["route"] = store.route
        value["isBusy"] = store.isBusy; value["restoringWorkspaceMemory"] = store.restoringWorkspaceMemory
        value["storageWorking"] = store.storageState.working; value["editorDirty"] = store.editorDirty
        value["navigationGeneration"] = store.navigationGeneration; value["navigationToken"] = store.pdfNavigationToken
        value["displayID"] = store.pdfDisplayReloadID.uuidString
        value["interactionResetID"] = store.pdfInteractionResetID.uuidString
        value["workspaceRevision"] = store.workspaceMemoryRevision
        value["latestCaptureSequence"] = store.pdfWorkspaceMemoryLatestCaptureSequence
        value["memoryOwner"] = store.pdfWorkspaceMemoryOwner.map { String(describing: $0) } ?? ""
        value["errorMessage"] = store.errorMessage ?? ""
        value["windowVisible"] = window?.isVisible ?? false; value["windowKey"] = window?.isKeyWindow ?? false
        value["nativeViews"] = views.map { pdf -> [String: Any] in
            let doc = pdf.document
            return ["viewID": String(describing: ObjectIdentifier(pdf)), "documentID": doc.map { String(describing: ObjectIdentifier($0)) } ?? "",
                "documentPresent": doc != nil, "documentURL": doc?.documentURL?.absoluteString ?? "", "pageCount": doc?.pageCount ?? -1,
                "currentPage": pdf.currentPage.flatMap { page in doc.map { $0.index(for: page) + 1 } } ?? -1,
                "destinationPage": pdf.currentDestination?.page.flatMap { page in doc.map { $0.index(for: page) + 1 } } ?? -1,
                "scale": Double(pdf.scaleFactor), "bounds": NSStringFromRect(pdf.bounds), "frame": NSStringFromRect(pdf.frame),
                "attachedToTestWindow": pdf.window === window, "displayMode": pdf.displayMode.rawValue,
                "viewportGeometry": self.pdfViewportGeometry(pdf)]
        }
        return value
    }
    func runPDFBoundaryScenario() async {
        var assertions: [String: Any] = ["mode": mode, "realNetworkRequests": 0]
        var states: [[String: Any]] = []
        do {
            let source = output.appendingPathComponent("boundary-8-pages.pdf")
            let sourceBytes = try sameBookPDF(source, label: "Continuous boundary fixture")
            let sourceHash = SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined()
            var project = BookProject(title: "Continuous PDF boundary correctness", originalName: source.lastPathComponent,
                sourceHash: sourceHash, units: (1...8).map { SourceUnit(id: "boundary-page-\($0)", order: $0 - 1,
                    chapter: "Boundary", page: $0, text: "Continuous boundary fixture - page \($0)") })
            PluginEngine.seed(&project)
            project.insights.append(ReadingInsight(id: "boundary-saved-analysis", unitIDs: [project.units[3].id],
                markdown: "## Saved analysis\n\nPreserve boundary analysis and $x^2$."))
            project.readerAnnotations = [ReaderAnnotation(sourceHash: sourceHash, page: 4, text: "", rangeLocation: 0, rangeLength: 0,
                quads: [ReaderQuadRect(x: 30, y: 450, width: 250, height: 70)], comment: "Keep boundary annotation", kind: .region)]
            project = try await store.repository.create(project, sourceURL: source)
            let note = DocumentRecord(id: "boundary-preserved-note", title: "Preserved boundary note")
            let noteBody = "# Preserve boundary notes\n\nKeep e\u{301}, 🙂 and $x^2$.\n"
            project = try await store.repository.saveDocument(project: project, document: note, markdown: noteBody)
            let owner = store.repository, canonical = await owner.sourceURL(for: project)
            let projectURL = library.appendingPathComponent("books/\(project.id)/project.json")
            let projectBefore = try Data(contentsOf: projectURL)
            store.books = [project]; await store.selectBook(project.id, preferredRoute: "reader")
            store.queryComposerDraft.text = draft
            let controller = PDFReaderController()
            let root = ReaderWorkspaceView(showPDF: .constant(true), showOutline: .constant(false), bookmarksOnly: .constant(false))
                .environmentObject(store).environmentObject(controller).environmentObject(ReadingTypographySettings())
                .modifier(ReadingPreferencesEnvironment())
            let host = CountingHost(rootView: AnyView(root))
            window = NSWindow(contentRect: NSRect(x: 70, y: 70, width: 800, height: 600),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "ReadingBook isolated continuous PDF boundary regression"
            window.contentView = host; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            metrics.scenario(); metrics.record("boundary-normal-admission")
            try await pdfWait("boundary PDF initially ready") { controller.isReady && self.pdfObjects()?.2.document?.pageCount == 8 }
            if let pdf = pdfObjects()?.2, let target = pdf.document?.page(at: 3) {
                pdf.layoutDocumentView()
                let box = target.bounds(for: pdf.displayBox)
                let projected = pdf.convert(CGPoint(x: box.midX, y: box.midY), from: target)
                try pdfRequire(!pdf.bounds.contains(projected), "Offscreen lookup control must be outside the current viewport")
                try pdfRequire(pdf.page(for: projected, nearest: false) === target,
                    "Public geometric page lookup did not resolve the offscreen control")
                assertions["offscreenGeometricPageLookupSupported"] = true
            } else { throw ReadingError.invalid("Offscreen geometric lookup control missing") }
            func anchor(_ pdf: PDFView, page: Int) throws -> CGPoint {
                guard let destination = pdf.currentDestination, let destinationPage = destination.page,
                      let target = pdf.document?.page(at: page - 1) else { throw ReadingError.invalid("Boundary anchor missing") }
                return pdf.convert(pdf.convert(destination.point, from: destinationPage), to: target)
            }
            func landmark(_ pdf: PDFView, page: Int) throws -> CGPoint {
                guard let target = pdf.document?.page(at: page - 1) else { throw ReadingError.invalid("Boundary landmark missing") }
                let box = target.bounds(for: pdf.displayBox)
                let point = pdf.convert(CGPoint(x: box.midX, y: box.midY), from: target)
                return CGPoint(x: point.x - pdf.bounds.minX, y: point.y - pdf.bounds.minY)
            }
            func snapshot(_ label: String, page: Int) {
                var row = self.sameBookState(label, controller: controller)
                if let pdf = self.pdfObjects()?.2, let point = try? anchor(pdf, page: page) {
                    row["targetPage"] = page; row["targetAnchorX"] = Double(point.x); row["targetAnchorY"] = Double(point.y)
                    row["pdfViewBounds"] = NSStringFromRect(pdf.bounds)
                    row["viewportGeometry"] = self.pdfViewportGeometry(pdf)
                    if let mark = try? landmark(pdf, page: page) {
                        row["landmarkViewportX"] = Double(mark.x); row["landmarkViewportY"] = Double(mark.y)
                    }
                }
                states.append(row); self.writeJSON("boundary-observations.json", ["states": states])
            }
            store.updateWorkspaceMemory { $0.pdf = WorkspacePDFMemory(page: 4, scale: 3.43, fitMode: "custom", continuous: true,
                thumbnails: false, direction: .vertical) }
            store.selectedUnitID = project.units[3].id; store.pdfNavigationToken += 1; store.workspaceMemoryRevision += 1
            try await pdfWait("explicit continuous page four") {
                controller.page == 4 && self.store.selectedUnit?.page == 4 && controller.isContinuous
                    && controller.direction == .vertical && controller.fitMode == "custom" && abs(controller.zoomPercent - 343) <= 1
            }
            try await Task.sleep(nanoseconds: 350_000_000)
            guard let initial = pdfObjects(), let initialDocument = initial.2.document else { throw ReadingError.invalid("Boundary PDF missing") }
            snapshot("after-explicit-page-four", page: 4)
            let defaultPageFourLandmark = try landmark(initial.2, page: 4)
            // PDFKit clamps go(to:) destinations to the target page. Instead
            // scroll its real document clip across the boundary, requiring
            // PDFKit itself still reports page four as the current reading page.
            guard let scroll = descendants(initial.2, NSScrollView.self).first(where: { $0.documentView != nil }) else {
                throw ReadingError.invalid("Native PDF scroll view missing")
            }
            let clip = scroll.contentView, originalClipOrigin = clip.bounds.origin
            var observedPredecessorDestination = false
            for offset in [0.0, -0.25, -0.5, -1.0, -2.0, -4.0, -8.0, -16.0, -32.0, -64.0,
                           0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0] {
                if let current = initial.2.currentPage, let destination = initial.2.currentDestination?.page,
                   initialDocument.index(for: current) == 3 && initialDocument.index(for: destination) == 2,
                   controller.page == 4 && store.selectedUnit?.page == 4 {
                    observedPredecessorDestination = true; break
                }
                clip.scroll(to: NSPoint(x: originalClipOrigin.x, y: originalClipOrigin.y + offset))
                scroll.reflectScrolledClipView(clip)
                try await Task.sleep(nanoseconds: 80_000_000)
                snapshot("native-boundary-offset-\(offset)", page: 4)
                states[states.count - 1]["clipOriginX"] = Double(clip.bounds.origin.x)
                states[states.count - 1]["clipOriginY"] = Double(clip.bounds.origin.y)
                states[states.count - 1]["requestedClipOffsetY"] = offset
                writeJSON("boundary-observations.json", ["states": states])
            }
            if let current = initial.2.currentPage, let destination = initial.2.currentDestination?.page {
                observedPredecessorDestination = initialDocument.index(for: current) == 3 && initialDocument.index(for: destination) == 2
                    && controller.page == 4 && store.selectedUnit?.page == 4
            }
            try pdfRequire(observedPredecessorDestination, "Fixture did not exercise a real current-page-four/destination-page-three boundary")
            snapshot("at-real-cross-page-boundary", page: 4)
            assertions["realNativeCurrentPageFourDestinationPageThreeObserved"] = true
            let beforeAnchor = try anchor(initial.2, page: 4), displayID = store.pdfDisplayReloadID
            let beforeLandmark = try landmark(initial.2, page: 4)
            guard let oldDestination = initial.2.currentDestination, let oldPage = oldDestination.page else {
                throw ReadingError.invalid("Real legacy destination missing")
            }
            let oldBox = oldPage.bounds(for: initial.2.displayBox)
            // This is exactly the pre-fix capture algorithm applied to the real
            // native boundary already observed above. Do not fabricate a native
            // currentPage or use a post-fix receipt as supposed legacy input.
            let legacyMemory = WorkspacePDFMemory(page: initialDocument.index(for: oldPage) + 1,
                location: WorkspacePoint(x: Double((oldDestination.point.x - oldBox.minX) / oldBox.width),
                    y: Double((oldDestination.point.y - oldBox.minY) / oldBox.height)),
                scale: Double(initial.2.scaleFactor), fitMode: "custom", continuous: true,
                thumbnails: false, direction: .vertical)
            try pdfRequire(legacyMemory.page == 3 && (legacyMemory.location?.y ?? 0) < 0 && legacyMemory.isValid,
                "Legacy input must be the actual pre-fix page-three negative-y capture")
            if let destinationPage = initial.2.currentDestination?.page {
                assertions["initialDestinationPage"] = initialDocument.index(for: destinationPage) + 1
            }
            metrics.record("boundary-explicit-capture")
            NotificationCenter.default.post(name: Notification.Name("ReadingBookCaptureWorkspaceMemory"), object: nil)
            store.flushWorkspaceMemory(); let beforeMemory = store.workspaceMemory.pdf
            snapshot("after-capture-before-reselect", page: 4)
            metrics.record("boundary-real-samebook-reselect")
            await store.selectBook(project.id, preferredRoute: "reader")
            try await pdfWait("boundary reselect ready") { controller.isReady && self.pdfObjects() != nil && !self.store.isBusy }
            try await Task.sleep(nanoseconds: 350_000_000)
            snapshot("after-samebook-reselect", page: 4)
            try pdfRequire(beforeMemory?.page == 4, "Continuous capture saved predecessor instead of displayed page four")
            try pdfRequire(controller.page == 4 && store.selectedUnit?.page == 4 && store.workspaceMemory.pdf?.page == 4,
                "Continuous page-four reselect became predecessor")
            try pdfRequire(pdfObjects()?.2.document === initialDocument && store.pdfDisplayReloadID == displayID,
                "Boundary repair lost verified same-book document reuse")
            let afterAnchor = try anchor(initial.2, page: 4)
            let afterLandmark = try landmark(initial.2, page: 4)
            try pdfRequire(abs(beforeAnchor.x - afterAnchor.x) < 2 && abs(beforeAnchor.y - afterAnchor.y) < 2,
                "Same-book boundary reselect shifted viewport")
            try pdfRequire(abs(beforeLandmark.x - afterLandmark.x) < 2 && abs(beforeLandmark.y - afterLandmark.y) < 2,
                "Same-book boundary reselect moved the fixed page landmark in its viewport")
            assertions["continuousCaptureAndReselectKeepPageViewportAndDocument"] = true
            metrics.record("boundary-explicit-remount")
            store.sourceFileURL = nil
            try await pdfWait("boundary dismantled") { self.pdfObjects() == nil }
            await store.selectBook(project.id, preferredRoute: "reader")
            try await pdfWait("boundary remounted on saved page") { controller.isReady && controller.page == 4 && self.store.selectedUnit?.page == 4 && self.pdfObjects() != nil }
            try await Task.sleep(nanoseconds: 350_000_000)
            snapshot("after-explicit-remount", page: 4)
            guard let remounted = pdfObjects()?.2 else { throw ReadingError.invalid("Remounted PDF missing") }
            let remountedAnchor = try anchor(remounted, page: 4)
            let remountedLandmark = try landmark(remounted, page: 4)
            try pdfRequire(remounted.document !== initialDocument && store.workspaceMemory.pdf?.page == 4,
                "Boundary remount lost saved page or reused removed document")
            try pdfRequire(abs(beforeAnchor.x - remountedAnchor.x) < 2 && abs(beforeAnchor.y - remountedAnchor.y) < 2,
                "Boundary disk restoration shifted persisted viewport")
            try pdfRequire(abs(beforeLandmark.x - remountedLandmark.x) < 2 && abs(beforeLandmark.y - remountedLandmark.y) < 2,
                "Boundary remount moved the fixed page landmark in its viewport")
            assertions["continuousDiskRestorationKeepsPageAndViewport"] = true
            let workspaceName = SHA256.hash(data: Data((project.id + "|" + project.sourceHash).utf8)).map { String(format: "%02x", $0) }.joined()
            let workspaceURL = library.appendingPathComponent("Workspace/\(workspaceName).json")
            func mountPersistedMemory(_ memory: WorkspacePDFMemory, label: String) async throws {
                self.store.sourceFileURL = nil
                try await self.pdfWait(label + " reader unmounted") { self.pdfObjects() == nil }
                self.store.updateWorkspaceMemory { $0.pdf = memory }; self.store.flushWorkspaceMemory()
                let onDisk = try JSONDecoder().decode(BookWorkspaceMemory.self, from: Data(contentsOf: workspaceURL))
                try self.pdfRequire(onDisk.pdf == memory, label + " fixture was not persisted before source admission")
                snapshot(label + "-persisted-before-admission", page: 4)
                await self.store.selectBook(project.id, preferredRoute: "reader")
                states.append(self.pdfLifecycleState(label + "-after-source-admission", controller: controller))
                self.writeJSON("boundary-observations.json", ["states": states])
            }
            metrics.record("boundary-real-legacy-negative-page-three-memory")
            try await mountPersistedMemory(legacyMemory, label: "legacy-page-three-negative-y")
            try await pdfWait("legacy geometry restores physical page four and corrects saved identity", onTimeout: {
                states.append(self.pdfLifecycleState("legacy-restoration-timeout", controller: controller))
                self.writeJSON("boundary-observations.json", ["states": states])
            }) {
                guard let pdf = self.pdfObjects()?.2, let current = pdf.currentPage, let doc = pdf.document else { return false }
                return controller.isReady && controller.page == 4 && doc.index(for: current) == 3
                    && self.store.selectedUnit?.page == 4 && self.store.workspaceMemory.pdf?.page == 4
            }
            snapshot("after-real-legacy-memory-restoration", page: 4)
            guard let legacyRestored = pdfObjects()?.2 else { throw ReadingError.invalid("Legacy restored reader missing") }
            let legacyLandmark = try landmark(legacyRestored, page: 4)
            try pdfRequire(abs(beforeLandmark.x - legacyLandmark.x) < 2 && abs(beforeLandmark.y - legacyLandmark.y) < 2,
                "Legacy predecessor memory no longer restores the original physical viewport")
            assertions["actualLegacyPredecessorMemoryRestoresAndCorrectsLogicalPage"] = true
            metrics.record("boundary-implausible-finite-anchor")
            let implausible = WorkspacePDFMemory(page: 4, location: WorkspacePoint(x: 1e10, y: -1e10),
                scale: 3.43, fitMode: "custom", continuous: true, thumbnails: false, direction: .vertical)
            try pdfRequire(implausible.isValid, "Extreme-anchor fixture must pass the existing serialized model validity boundary")
            try await mountPersistedMemory(implausible, label: "implausible-finite-anchor")
            try await pdfWait("implausible location ignored while normal page-four position remains ready") {
                guard let location = self.store.workspaceMemory.pdf?.location else { return false }
                return controller.isReady && controller.page == 4 && self.store.selectedUnit?.page == 4
                    && self.store.workspaceMemory.pdf?.page == 4 && abs(location.x) < 100 && abs(location.y) < 100
            }
            snapshot("after-implausible-anchor-ignored", page: 4)
            guard let safeRestored = pdfObjects()?.2 else { throw ReadingError.invalid("Safe restored reader missing") }
            let safeLandmark = try landmark(safeRestored, page: 4)
            try pdfRequire(abs(defaultPageFourLandmark.x - safeLandmark.x) < 2
                && abs(defaultPageFourLandmark.y - safeLandmark.y) < 2,
                "Implausible anchor moved the viewport away from ordinary explicit page-four navigation")
            assertions["implausibleFiniteSavedAnchorRejectedWithoutNativeJump"] = true
            for page in [1, 8, 4] {
                metrics.record("boundary-explicit-page-\(page)"); store.navigateToUnit(project.units[page - 1].id)
                try await pdfWait("boundary explicit page \(page)") { controller.isReady && controller.page == page && self.store.selectedUnit?.page == page }
                try await Task.sleep(nanoseconds: 300_000_000)
                NotificationCenter.default.post(name: Notification.Name("ReadingBookCaptureWorkspaceMemory"), object: nil)
                store.flushWorkspaceMemory(); snapshot("after-explicit-page-and-capture-\(page)", page: page)
                try pdfRequire(store.workspaceMemory.pdf?.page == page, "Boundary capture changed explicit page \(page)")
            }
            assertions["firstLastAndMiddleExplicitPagesPreserved"] = true
            try pdfRequire(!controller.thumbnailsVisible && controller.isContinuous && controller.direction == .vertical
                && abs(controller.zoomPercent - 343) <= 1 && store.queryComposerDraft.text == draft && !store.editorDirty,
                "Boundary navigation changed preferences or question draft")
            try pdfRequire(try Data(contentsOf: canonical) == sourceBytes && Data(contentsOf: source) == sourceBytes
                && Data(contentsOf: projectURL) == projectBefore, "Boundary navigation rewrote source, analysis or annotations")
            try pdfRequire(try await owner.readDocument(bookID: project.id, document: note) == noteBody, "Boundary navigation rewrote saved notes")
            assertions["originalSourceProjectAnalysisAnnotationsNotesAndDraftPreserved"] = true
            // A second immutable source carries actual file-level rotation and
            // crop metadata. Do not mutate the already admitted PDFDocument.
            let geometryBase = output.appendingPathComponent("boundary-geometry-base.pdf")
            let geometrySource = output.appendingPathComponent("boundary-geometry-source.pdf")
            let geometryBaseBytes = try sameBookPDF(geometryBase, label: "Geometry boundary fixture")
            guard let geometryPDF = PDFDocument(data: geometryBaseBytes), geometryPDF.pageCount == 8 else {
                throw ReadingError.invalid("Geometry PDF fixture unavailable")
            }
            geometryPDF.page(at: 3)?.rotation = 90
            geometryPDF.page(at: 4)?.rotation = 270
            geometryPDF.page(at: 5)?.setBounds(CGRect(x: 35, y: 45, width: 330, height: 490), for: .cropBox)
            try pdfRequire(geometryPDF.write(to: geometrySource), "Geometry PDF metadata could not be persisted")
            let geometryBytes = try Data(contentsOf: geometrySource)
            let geometryHash = SHA256.hash(data: geometryBytes).map { String(format: "%02x", $0) }.joined()
            var geometryProject = BookProject(title: "Rotation and crop PDF correctness", originalName: geometrySource.lastPathComponent,
                sourceHash: geometryHash, units: (1...8).map { SourceUnit(id: "geometry-page-\($0)", order: $0 - 1,
                    chapter: "Geometry", page: $0, text: "Geometry boundary fixture - page \($0)") })
            PluginEngine.seed(&geometryProject)
            geometryProject = try await owner.create(geometryProject, sourceURL: geometrySource)
            store.books.append(geometryProject)
            await store.selectBook(geometryProject.id, preferredRoute: "reader")
            try await pdfWait("physical geometry source ready") { controller.isReady && self.store.bookID == geometryProject.id && self.pdfObjects() != nil }
            let geometryCanonical = await owner.sourceURL(for: geometryProject)
            let geometryProjectURL = library.appendingPathComponent("books/\(geometryProject.id)/project.json")
            let geometryProjectBefore = try Data(contentsOf: geometryProjectURL)
            func geometryRoundTrip(page: Int, direction: PDFReadingDirection, label: String, remount: Bool = false) async throws {
                metrics.record("boundary-geometry-" + label)
                self.store.updateWorkspaceMemory { $0.pdf = WorkspacePDFMemory(page: page, scale: 3.43, fitMode: "custom",
                    continuous: true, thumbnails: false, direction: direction) }
                self.store.selectedUnitID = geometryProject.units[page - 1].id
                self.store.pdfNavigationToken += 1; self.store.workspaceMemoryRevision += 1
                try await self.pdfWait(label + " explicit native navigation") {
                    controller.isReady && controller.page == page && self.store.selectedUnit?.page == page
                        && controller.direction == direction && controller.isContinuous && abs(controller.zoomPercent - 343) <= 1
                }
                try await Task.sleep(nanoseconds: 350_000_000)
                guard let native = self.pdfObjects()?.2, let nativeDocument = native.document,
                      let target = nativeDocument.page(at: page - 1) else { throw ReadingError.invalid(label + " native page missing") }
                if label == "rotation-90" { try self.pdfRequire(target.rotation == 90, "90-degree rotation was not loaded from source") }
                if label == "rotation-270" { try self.pdfRequire(target.rotation == 270, "270-degree rotation was not loaded from source") }
                if label == "nonzero-crop" {
                    let box = target.bounds(for: .cropBox)
                    try self.pdfRequire(box.minX == 35 && box.minY == 45 && box.width == 330 && box.height == 490,
                        "Nonzero crop origin was not loaded from source")
                }
                if direction == .horizontal {
                    guard let scroll = self.descendants(native, NSScrollView.self).first(where: { $0.documentView != nil }) else {
                        throw ReadingError.invalid("Horizontal native scroll view missing")
                    }
                    let clip = scroll.contentView, base = clip.bounds.origin
                    clip.scroll(to: NSPoint(x: base.x + 12, y: base.y)); scroll.reflectScrolledClipView(clip)
                    try await Task.sleep(nanoseconds: 120_000_000)
                    try self.pdfRequire(abs(clip.bounds.origin.x - base.x) > 1,
                        "Horizontal fixture did not actually move its native document clip")
                }
                try self.pdfRequire(native.currentPage === target && controller.page == page && self.store.selectedUnit?.page == page,
                    label + " setup moved to another physical page")
                let before = try landmark(native, page: page), nativeDisplayID = self.store.pdfDisplayReloadID
                snapshot(label + "-before-capture", page: page)
                NotificationCenter.default.post(name: Notification.Name("ReadingBookCaptureWorkspaceMemory"), object: nil)
                self.store.flushWorkspaceMemory()
                try self.pdfRequire(self.store.workspaceMemory.pdf?.page == page, label + " capture changed logical page")
                await self.store.selectBook(geometryProject.id, preferredRoute: "reader")
                try await self.pdfWait(label + " reselect ready") { controller.isReady && controller.page == page && self.store.selectedUnit?.page == page }
                try await Task.sleep(nanoseconds: 350_000_000)
                snapshot(label + "-after-reselect", page: page)
                guard let current = self.pdfObjects()?.2 else { throw ReadingError.invalid(label + " reselected reader missing") }
                let after = try landmark(current, page: page)
                try self.pdfRequire(abs(before.x - after.x) < 2 && abs(before.y - after.y) < 2,
                    label + " reselect moved fixed page landmark")
                try self.pdfRequire(current.document === nativeDocument && self.store.pdfDisplayReloadID == nativeDisplayID
                    && self.store.workspaceMemory.pdf?.page == page && controller.direction == direction && controller.isContinuous,
                    label + " reselect lost native reuse, page or display preferences")
                if remount {
                    self.store.sourceFileURL = nil
                    try await self.pdfWait(label + " reader dismantled") { self.pdfObjects() == nil }
                    await self.store.selectBook(geometryProject.id, preferredRoute: "reader")
                    try await self.pdfWait(label + " reader remounted") { controller.isReady && controller.page == page && self.store.selectedUnit?.page == page }
                    try await Task.sleep(nanoseconds: 350_000_000)
                    snapshot(label + "-after-remount", page: page)
                    guard let new = self.pdfObjects()?.2 else { throw ReadingError.invalid(label + " remounted reader missing") }
                    let restored = try landmark(new, page: page)
                    try self.pdfRequire(new.document !== nativeDocument && abs(before.x - restored.x) < 2 && abs(before.y - restored.y) < 2,
                        label + " disk restore moved fixed landmark or reused dismantled document")
                }
                assertions[label + "PhysicalLandmarkAndLogicalPagePreserved"] = true
            }
            try await geometryRoundTrip(page: 4, direction: .vertical, label: "rotation-90")
            try await geometryRoundTrip(page: 5, direction: .vertical, label: "rotation-270")
            try await geometryRoundTrip(page: 6, direction: .vertical, label: "nonzero-crop", remount: true)
            try await geometryRoundTrip(page: 3, direction: .horizontal, label: "horizontal-continuous", remount: true)
            try pdfRequire(try Data(contentsOf: geometryCanonical) == geometryBytes && Data(contentsOf: geometrySource) == geometryBytes
                && Data(contentsOf: geometryProjectURL) == geometryProjectBefore,
                "Geometry restoration changed source rotation/crop bytes or project")
            let originalNoteAfterGeometry = try await owner.readDocument(bookID: project.id, document: note)
            try pdfRequire(try Data(contentsOf: canonical) == sourceBytes && Data(contentsOf: projectURL) == projectBefore
                && originalNoteAfterGeometry == noteBody,
                "Geometry source switching changed original analysis, annotations or notes")
            assertions["geometrySourceAndOriginalContentPreserved"] = true
            assertions["status"] = "passed"
        } catch {
            assertions["status"] = "failed"; assertions["reason"] = error.localizedDescription
            try? capturePDFView("boundary-failure.png")
        }
        metrics.settling(); try? await Task.sleep(nanoseconds: 250_000_000)
        assertions["states"] = states; assertions["metrics"] = metrics.snapshot()
        assertions["forcedLegacyScrollers"] = ProcessInfo.processInfo.environment["HARNESS_FORCE_LEGACY_SCROLLERS"] == "1"
        assertions["scrollerStyleOverride"] = ProcessInfo.processInfo.environment["HARNESS_PDF_SCROLLER_STYLE"]
            ?? (ProcessInfo.processInfo.environment["HARNESS_FORCE_LEGACY_SCROLLERS"] == "1" ? "legacy" : "")
        assertions["windowVisible"] = window?.isVisible ?? false
        assertions["testScope"] = "real continuous PDF capture/reselect/disk restoration; source/notes/analysis preserved; no FPS, AI or original user library"
        writeJSON("result.json", assertions)
        timer?.cancel(); window?.orderOut(nil); NSApp.terminate(nil)
    }
    func runSameBookPDFScenario() async {
        var assertions: [String: Any] = ["mode": mode, "realNetworkRequests": 0]
        var states: [[String: Any]] = []
        do {
            let source = output.appendingPathComponent("samebook-8-pages.pdf")
            let sourceBytes = try sameBookPDF(source, label: "Original same-book fixture")
            let sourceHash = SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined()
            var project = BookProject(title: "Same-book source admission fixture", originalName: source.lastPathComponent, sourceHash: sourceHash,
                units: (1...8).map { SourceUnit(id: "samebook-page-\($0)", order: $0 - 1, chapter: "Fixture", page: $0,
                    text: "Original same-book fixture - page \($0)") })
            PluginEngine.seed(&project)
            project.insights.append(ReadingInsight(id: "samebook-saved-analysis", unitIDs: [project.units[3].id], markdown: "## Saved analysis\n\nKeep this old analysis and $x^2$."))
            let annotation = ReaderAnnotation(sourceHash: sourceHash, page: 4, text: "", rangeLocation: 0, rangeLength: 0,
                quads: [ReaderQuadRect(x: 30, y: 450, width: 250, height: 70)], comment: "Keep this saved region", kind: .region)
            project.readerAnnotations = [annotation]
            project = try await store.repository.create(project, sourceURL: source)
            let note = DocumentRecord(id: "samebook-preserved-note", title: "Preserved same-book note")
            let noteBody = "# Preserve me\n\nKeep e\u{301}, 🙂, source links and $x^2$.\n"
            project = try await store.repository.saveDocument(project: project, document: note, markdown: noteBody)
            let originalOwner = store.repository, originalRoot = store.libraryRootURL
            let canonical = await originalOwner.sourceURL(for: project)
            let projectURL = library.appendingPathComponent("books/\(project.id)/project.json")
            let projectBefore = try Data(contentsOf: projectURL)
            store.books = [project]
            await store.selectBook(project.id, preferredRoute: "reader")
            // Initial book admission legitimately clears the composer belonging
            // to no book. Only the later same-book selections must retain this.
            store.queryComposerDraft.text = draft
            let controller = PDFReaderController()
            let root = ReaderWorkspaceView(showPDF: .constant(true), showOutline: .constant(false), bookmarksOnly: .constant(false))
                .environmentObject(store).environmentObject(controller).environmentObject(ReadingTypographySettings())
                .modifier(ReadingPreferencesEnvironment())
            let host = CountingHost(rootView: AnyView(root))
            window = NSWindow(contentRect: NSRect(x: 70, y: 70, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "ReadingBook isolated same-book PDF admission regression"
            window.contentView = host; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            metrics.scenario(); metrics.record("samebook-normal-initial-admission")
            try await pdfWait("normal source admission mounts the physical PDF") { self.pdfObjects() != nil && controller.isReady && controller.pageCount == 8 }
            guard let initial = pdfObjects(), let initialDocument = initial.2.document else { throw ReadingError.invalid("Same-book PDF object missing") }
            try pdfRequire(initial.1.pdfView == nil && !controller.thumbnailsVisible, "Initial admission must leave hidden thumbnails detached")
            try pdfRequire(initialDocument.page(at: 3)?.annotations.contains(where: { $0.contents == annotation.comment }) == true,
                "Saved annotation must be present in the actual native PDF")
            assertions["normalRepositoryAdmissionAndSavedAnnotationRendered"] = true
            let rejectedReceiptMemory = WorkspacePDFMemory(page: 8, location: WorkspacePoint(x: 0.81, y: 0.17),
                scale: 2.2, fitMode: "custom", continuous: true, thumbnails: true, direction: .vertical)
            func rejectDeferredReceipt(_ owner: PDFWorkspaceMemoryOwner, label: String) async throws {
                // Match the lifecycle callback's deferred delivery shape. Read
                // the immediate before/after values inside the same main-queue
                // turn so unrelated legitimate captures cannot mask a mutation.
                let rejected: Bool = await withCheckedContinuation { continuation in
                    DispatchQueue.main.async {
                        let changedOwner = self.store.pdfWorkspaceMemoryOwner != owner
                        let before = self.store.workspaceMemory
                        self.store.updatePDFWorkspaceMemory(rejectedReceiptMemory, owner: owner)
                        continuation.resume(returning: changedOwner && self.store.workspaceMemory == before)
                    }
                }
                try self.pdfRequire(rejected, "A stale deferred viewport receipt changed the new owner: " + label)
                assertions[label + "DeferredViewportReceiptRejected"] = true
            }
            guard let initialReceiptOwner = store.pdfWorkspaceMemoryOwner else { throw ReadingError.invalid("Initial PDF memory receipt owner missing") }
            metrics.record("samebook-navigation-receipt-invalidation")
            store.navigateToUnit(project.units[3].id)
            try await pdfWait("explicit page-four navigation advances receipt ownership") {
                controller.isReady && controller.page == 4 && self.store.selectedUnit?.page == 4
                    && self.store.pdfWorkspaceMemoryOwner?.navigationToken != initialReceiptOwner.navigationToken
            }
            try await rejectDeferredReceipt(initialReceiptOwner, label: "oldNavigationToken")
            try pdfRequire(pdfObjects()?.2.document === initialDocument, "Normal navigation receipt invalidation must not reload the document")

            // Deliberately choose a noninitial page and nondefault settings. No
            // PerfProbe normalization or rewrite-to-page-one hook exists here.
            let requested = WorkspacePDFMemory(page: 4, location: WorkspacePoint(x: 0.15, y: 0.75), scale: 1.35,
                fitMode: "custom", continuous: false, thumbnails: false, direction: .horizontal)
            store.updateWorkspaceMemory { $0.pdf = requested }
            store.selectedUnitID = project.units[3].id; store.pdfNavigationToken += 1; store.workspaceMemoryRevision += 1
            try await pdfWait("arbitrary page and saved viewport ready") {
                controller.page == 4 && self.store.selectedUnit?.page == 4 && controller.fitMode == "custom"
                    && !controller.isContinuous && controller.direction == .horizontal && abs(controller.zoomPercent - 135) <= 1
            }
            try await Task.sleep(nanoseconds: 350_000_000)
            NotificationCenter.default.post(name: Notification.Name("ReadingBookCaptureWorkspaceMemory"), object: nil)
            store.flushWorkspaceMemory()
            let beforeMemory = store.workspaceMemory.pdf
            try pdfRequire(beforeMemory?.page == 4, "Discrete page-four setup must save page four")
            guard let destination = initial.2.currentDestination, let destinationPage = destination.page,
                  let currentReceiptOwner = store.pdfWorkspaceMemoryOwner, var staleMemory = beforeMemory else {
                throw ReadingError.invalid("Page-four synchronous capture setup missing")
            }
            let box = destinationPage.bounds(for: initial.2.displayBox)
            let nativeLocation = WorkspacePoint(x: Double((destination.point.x - box.minX) / box.width),
                y: Double((destination.point.y - box.minY) / box.height))
            staleMemory.page = 2; staleMemory.location = WorkspacePoint(x: 0.91, y: 0.11)
            metrics.record("samebook-explicit-capture-is-synchronous")
            // No await/layout/yield between poisoning the stored value and the
            // explicit notification: select/quit must be able to flush now.
            store.workspaceMemory.pdf = staleMemory
            NotificationCenter.default.post(name: Notification.Name("ReadingBookCaptureWorkspaceMemory"), object: nil)
            guard let synchronous = store.workspaceMemory.pdf, let synchronousLocation = synchronous.location else {
                throw ReadingError.invalid("Explicit capture did not immediately deliver its viewport")
            }
            try pdfRequire(synchronous.page == 4 && abs(synchronousLocation.x - nativeLocation.x) < 0.000001
                && abs(synchronousLocation.y - nativeLocation.y) < 0.000001,
                "Explicit capture was deferred or lost the noninitial native page/viewport")
            store.flushWorkspaceMemory()
            let workspaceName = SHA256.hash(data: Data((project.id + "|" + project.sourceHash).utf8)).map { String(format: "%02x", $0) }.joined()
            let persistedWorkspace = try JSONDecoder().decode(BookWorkspaceMemory.self,
                from: Data(contentsOf: library.appendingPathComponent("Workspace/\(workspaceName).json")))
            try pdfRequire(persistedWorkspace.pdf == synchronous, "Immediate flush did not preserve the explicit synchronous capture")
            assertions["explicitNotificationCapturesAndFlushesNoninitialViewportSynchronously"] = true
            metrics.record("samebook-current-viewport-receipt-accepted")
            var accepted = synchronous; accepted.location = WorkspacePoint(x: nativeLocation.x + 0.01, y: nativeLocation.y - 0.01)
            store.updatePDFWorkspaceMemory(accepted, owner: currentReceiptOwner)
            try pdfRequire(store.workspaceMemory.pdf == accepted, "A valid current-owner viewport receipt was ignored")
            store.updatePDFWorkspaceMemory(synchronous, owner: currentReceiptOwner); store.flushWorkspaceMemory()
            try pdfRequire(store.workspaceMemory.pdf == synchronous, "Valid receipt restoration failed")
            assertions["currentOwnerViewportReceiptAccepted"] = true
            metrics.record("samebook-increasing-viewport-capture-receipts")
            var memoryA = synchronous; memoryA.location = WorkspacePoint(x: nativeLocation.x + 0.02, y: nativeLocation.y - 0.02)
            var memoryB = synchronous; memoryB.location = WorkspacePoint(x: nativeLocation.x + 0.03, y: nativeLocation.y - 0.03)
            let firstNormalReceipt = PDFWorkspaceMemoryReceipt(memory: memoryA)
            let secondNormalReceipt = PDFWorkspaceMemoryReceipt(memory: memoryB)
            try pdfRequire(secondNormalReceipt.captureSequence > firstNormalReceipt.captureSequence,
                "Native capture sequence did not increase at capture time")
            store.updatePDFWorkspaceMemory(firstNormalReceipt, owner: currentReceiptOwner)
            try pdfRequire(store.workspaceMemory.pdf == memoryA && store.pdfWorkspaceMemoryLatestCaptureSequence == firstNormalReceipt.captureSequence,
                "First normal current-owner receipt was not applied")
            store.updatePDFWorkspaceMemory(secondNormalReceipt, owner: currentReceiptOwner)
            try pdfRequire(store.workspaceMemory.pdf == memoryB && store.pdfWorkspaceMemoryLatestCaptureSequence == secondNormalReceipt.captureSequence,
                "A later normal receipt was blocked by the ordering barrier")
            assertions["increasingNormalViewportReceiptsAccepted"] = true
            // A capture suppressed during restoration must still be consumed.
            // Re-delivery after restoration cannot turn it into a fresh write.
            let suppressedReceipt = PDFWorkspaceMemoryReceipt(memory: memoryA)
            store.restoringWorkspaceMemory = true
            store.updatePDFWorkspaceMemory(suppressedReceipt, owner: currentReceiptOwner)
            let suppressedAtCapture = store.workspaceMemory.pdf == memoryB
                && store.pdfWorkspaceMemoryLatestCaptureSequence == suppressedReceipt.captureSequence
            store.restoringWorkspaceMemory = false
            store.updatePDFWorkspaceMemory(suppressedReceipt, owner: currentReceiptOwner)
            try pdfRequire(suppressedAtCapture && store.workspaceMemory.pdf == memoryB
                && store.pdfWorkspaceMemoryLatestCaptureSequence == suppressedReceipt.captureSequence,
                "A duplicate viewport receipt became writable after restoration")
            assertions["duplicateSuppressedViewportReceiptCannotBecomeFresh"] = true
            let restoredNormalReceipt = PDFWorkspaceMemoryReceipt(memory: synchronous)
            store.updatePDFWorkspaceMemory(restoredNormalReceipt, owner: currentReceiptOwner)
            try pdfRequire(store.workspaceMemory.pdf == synchronous, "Normal receipt after an ordering barrier was not applied")

            metrics.record("samebook-old-deferred-versus-new-sync-capture")
            let oldDeferredReceipt = PDFWorkspaceMemoryReceipt(memory: rejectedReceiptMemory)
            let newSynchronousReceipt = PDFWorkspaceMemoryReceipt(memory: synchronous)
            store.updatePDFWorkspaceMemory(newSynchronousReceipt, owner: currentReceiptOwner)
            try pdfRequire(store.workspaceMemory.pdf == synchronous
                && store.pdfWorkspaceMemoryLatestCaptureSequence == newSynchronousReceipt.captureSequence,
                "The newer synchronous viewport capture was not accepted immediately")
            let delayedReceiptRejected: Bool = await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    let before = self.store.workspaceMemory
                    let watermark = self.store.pdfWorkspaceMemoryLatestCaptureSequence
                    self.store.updatePDFWorkspaceMemory(oldDeferredReceipt, owner: currentReceiptOwner)
                    continuation.resume(returning: self.store.workspaceMemory == before
                        && self.store.pdfWorkspaceMemoryLatestCaptureSequence == watermark
                        && watermark >= newSynchronousReceipt.captureSequence)
                }
            }
            try pdfRequire(delayedReceiptRejected && store.workspaceMemory.pdf?.page == 4
                && store.workspaceMemory.pdf != rejectedReceiptMemory,
                "An older same-owner deferred capture overwrote a newer synchronous position")
            store.flushWorkspaceMemory()
            let afterDeferredDrain = try JSONDecoder().decode(BookWorkspaceMemory.self,
                from: Data(contentsOf: library.appendingPathComponent("Workspace/\(workspaceName).json")))
            try pdfRequire(afterDeferredDrain.pdf?.page == 4 && afterDeferredDrain.pdf != rejectedReceiptMemory,
                "The stale deferred capture reached the saved workspace")
            assertions["oldSameOwnerDeferredReceiptCannotOverwriteNewSynchronousCapture"] = true
            states.append(sameBookState("before-verified-reselect", controller: controller))
            let stableDisplayID = store.pdfDisplayReloadID
            var memoryBeforeLastReselect = beforeMemory
            for cycle in 0..<max(2, min(cycles, 8)) {
                metrics.record("samebook-seed-native-find-and-selection-\(cycle)")
                controller.command(.showSearch)
                try await pdfWait("native PDF search opens") { controller.isSearchVisible }
                guard let search = descendants(initial.0, NSSearchField.self).first else {
                    throw ReadingError.invalid("Native PDF search field missing")
                }
                search.stringValue = "page 4"
                try pdfRequire(search.sendAction(search.action, to: search.target), "Native PDF search action was not delivered")
                try await pdfWait("real PDF search produces a page-four match") {
                    !initialDocument.isFinding && initial.2.highlightedSelections?.isEmpty == false && controller.page == 4
                }
                guard let page = initialDocument.page(at: 3), let text = page.string else {
                    throw ReadingError.invalid("Page-four selection source missing")
                }
                let range = (text as NSString).range(of: "Original")
                guard range.location != NSNotFound, let nativeSelection = page.selection(for: range) else {
                    throw ReadingError.invalid("Native PDFSelection could not be created")
                }
                initial.2.setCurrentSelection(nativeSelection, animate: false)
                try await pdfWait("native selection reaches product source state") {
                    initial.2.currentSelection?.string == "Original" && controller.hasSelection
                        && self.store.sourceReadingSelection?.text == "Original" && self.store.sourceReadingSelection?.page == 4
                }
                // Native find legitimately moves the viewport. Preserve this
                // new user position, not the pre-search point from setup.
                NotificationCenter.default.post(name: Notification.Name("ReadingBookCaptureWorkspaceMemory"), object: nil)
                store.flushWorkspaceMemory(); memoryBeforeLastReselect = store.workspaceMemory.pdf
                states.append(sameBookState("with-native-find-and-selection-\(cycle)", controller: controller))
                metrics.record("samebook-verified-reselect-\(cycle)")
                let token = store.pdfNavigationToken, generation = store.navigationGeneration
                guard let ownerBeforeReselect = store.pdfWorkspaceMemoryOwner else { throw ReadingError.invalid("Reselect receipt owner missing") }
                await store.selectBook(project.id, preferredRoute: "reader")
                try await pdfWait("verified same-book reselect clears native interaction and stays ready") {
                    controller.isReady && controller.page == 4 && self.store.selectedUnit?.page == 4
                        && initial.2.currentSelection == nil && initial.2.highlightedSelections?.isEmpty != false
                        && !initialDocument.isFinding && !controller.isSearchVisible && self.store.sourceReadingSelection == nil
                }
                try await rejectDeferredReceipt(ownerBeforeReselect, label: "oldVerifiedReselect")
                try pdfRequire(pdfObjects()?.0 === initial.0 && pdfObjects()?.2 === initial.2 && pdfObjects()?.2.document === initialDocument,
                    "Verified unchanged source must retain its native container, PDFView and PDFDocument")
                try pdfRequire(store.pdfDisplayReloadID == stableDisplayID && store.pdfNavigationToken > token && store.navigationGeneration > generation,
                    "Retention must keep display identity while completing the real navigation generation flow")
                try pdfRequire(!controller.isContinuous && controller.direction == .horizontal && controller.fitMode == "custom" && abs(controller.zoomPercent - 135) <= 1,
                    "Reselect lost saved scale, direction or continuous mode")
                try pdfRequire(initial.1.pdfView == nil && !controller.thumbnailsVisible, "Reselect rebound hidden thumbnails")
                try pdfRequire(store.queryComposerDraft.text == draft && !store.editorDirty, "Reselect changed the question draft")
                states.append(sameBookState("after-verified-reselect-\(cycle)", controller: controller))
            }
            if let old = memoryBeforeLastReselect?.location, let current = store.workspaceMemory.pdf?.location {
                try pdfRequire(abs(old.x - current.x) < 0.02 && abs(old.y - current.y) < 0.02,
                    "Verified reselect changed the saved viewport anchor")
            }
            assertions["verifiedReselectPreservesAllNativeIdentities"] = true
            assertions["navigationGenerationsStillAdvance"] = true
            assertions["arbitraryPageViewportAndPreferencesRestored"] = true
            assertions["questionDraftAndHiddenThumbnailsPreserved"] = true
            assertions["nativeSelectionStoreSelectionFindAndSearchResetWithoutDocumentReload"] = true

            let guardedToken = store.pdfNavigationToken, guardedDisplay = store.pdfDisplayReloadID
            store.isBusy = true; await store.selectBook(project.id, preferredRoute: "reader"); store.isBusy = false
            try pdfRequire(store.pdfNavigationToken == guardedToken && store.pdfDisplayReloadID == guardedDisplay,
                "Busy selection must not mutate source admission")
            store.editorTitle = "Keep this unsaved draft"; store.editorMarkdown = "# Unsaved Markdown stays intact\n"; store.editorDirty = true
            await store.selectBook(project.id, preferredRoute: "reader")
            try pdfRequire(store.editorDirty && store.editorMarkdown == "# Unsaved Markdown stays intact\n"
                && store.pdfNavigationToken == guardedToken && store.pdfDisplayReloadID == guardedDisplay,
                "Dirty selection must preserve the edit and native source identity")
            store.discardDraftForWorkspaceNavigation()
            assertions["busyAndDirtySelectionProtection"] = true

            // Keep the prior explicit teardown/reload semantics: this is a
            // user-visible remount, not an eligible mounted-reader retention.
            metrics.record("samebook-explicit-nil-teardown")
            guard let ownerBeforeTeardown = store.pdfWorkspaceMemoryOwner else { throw ReadingError.invalid("Teardown receipt owner missing") }
            store.sourceFileURL = nil
            try await pdfWait("explicit URL removal dismantles reader") { self.pdfObjects() == nil }
            await store.selectBook(project.id, preferredRoute: "reader")
            try await pdfWait("explicit remount ready") { self.pdfObjects() != nil && controller.isReady && controller.page == 4 }
            try pdfRequire(pdfObjects()?.0 !== initial.0 && pdfObjects()?.2.document !== initialDocument,
                "Explicitly removed source must not resurrect the previous native document")
            try await rejectDeferredReceipt(ownerBeforeTeardown, label: "oldExplicitDisplay")
            assertions["explicitNilStillForcesFreshMount"] = true

            func reselectExpectingFresh(_ label: String, ready: Bool) async throws {
                guard let old = self.pdfObjects(), let oldDocument = old.2.document else { throw ReadingError.invalid("Missing old PDF for " + label) }
                let reload = self.store.pdfDisplayReloadID
                guard let ownerBeforeSourceChange = self.store.pdfWorkspaceMemoryOwner else { throw ReadingError.invalid("Source-change receipt owner missing") }
                metrics.record("samebook-source-change-" + label)
                await self.store.selectBook(project.id, preferredRoute: "reader")
                try await self.pdfWait("forced source reload: " + label) {
                    guard let current = self.pdfObjects() else { return false }
                    return current.0 !== old.0 && current.2.document !== oldDocument && (!ready || controller.isReady)
                }
                try await rejectDeferredReceipt(ownerBeforeSourceChange, label: "oldSourceDisplay-" + label)
                try self.pdfRequire(self.store.pdfDisplayReloadID != reload, "Source mismatch did not force a fresh display ID: " + label)
                if !ready { try self.pdfRequire(self.pdfObjects()?.2.document == nil || !controller.isReady, "Invalid source kept a ready stale document: " + label) }
                assertions[label + "InvalidatesOldDocument"] = true
            }
            func restoreOriginal(_ label: String) async throws {
                if FileManager.default.fileExists(atPath: canonical.path) { try FileManager.default.removeItem(at: canonical) }
                try sourceBytes.write(to: canonical, options: .atomic)
                self.store.errorMessage = nil
                await self.store.selectBook(project.id, preferredRoute: "reader")
                try await self.pdfWait("restored original: " + label) {
                    controller.isReady && self.pdfObjects()?.2.document?.page(at: 0)?.string?.contains("Original same-book fixture") == true
                }
                try self.pdfRequire(try Data(contentsOf: canonical) == sourceBytes, "Restoration changed original bytes: " + label)
            }

            let alternate = output.appendingPathComponent("replacement-8-pages.pdf")
            let alternateBytes = try sameBookPDF(alternate, label: "Replacement different source")
            try alternateBytes.write(to: canonical, options: .atomic)
            try await reselectExpectingFresh("samePathReplacement", ready: true)
            try pdfRequire(pdfObjects()?.2.document?.page(at: 0)?.string?.contains("Replacement different source") == true,
                "Replacement selection must display new bytes rather than the cached original")
            try await restoreOriginal("replacement")

            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 30)], ofItemAtPath: canonical.path)
            try await reselectExpectingFresh("unchangedBytesChangedMetadata", ready: true)
            try pdfRequire(try Data(contentsOf: canonical) == sourceBytes, "Metadata-only test changed source bytes")
            try await restoreOriginal("metadata")

            try Data(repeating: 0x5A, count: sourceBytes.count).write(to: canonical)
            try await reselectExpectingFresh("sameSizeInPlaceCorruption", ready: false)
            try await restoreOriginal("same-size corruption")

            try FileManager.default.removeItem(at: canonical)
            try await reselectExpectingFresh("deletedSource", ready: false)
            try await restoreOriginal("deletion")

            try FileManager.default.removeItem(at: canonical)
            try FileManager.default.createSymbolicLink(at: canonical, withDestinationURL: source)
            try await reselectExpectingFresh("symlinkSource", ready: false)
            try await restoreOriginal("symlink")

            // Equal bookID/hash in another repository must not inherit a prior
            // library's lease, even while a reader for it remains mounted.
            metrics.record("samebook-other-root-admission")
            let otherRoot = library.deletingLastPathComponent().appendingPathComponent("samebook-other-library", isDirectory: true)
            let otherOwner = LibraryRepository(rootURL: otherRoot)
            var other = BookProject(id: project.id, title: "Same identifiers, other owner", originalName: project.originalName,
                sourceHash: sourceHash, units: project.units)
            PluginEngine.seed(&other); other = try await otherOwner.create(other, sourceURL: source)
            guard let oldOwnerDocument = pdfObjects()?.2.document else { throw ReadingError.invalid("Missing pre-owner-change document") }
            let oldOwnerDisplay = store.pdfDisplayReloadID
            guard let oldRootReceipt = store.pdfWorkspaceMemoryOwner else { throw ReadingError.invalid("Root-change receipt owner missing") }
            store.repository = otherOwner; store.libraryRootURL = otherRoot; store.books = [other]
            await store.selectBook(other.id, preferredRoute: "reader")
            try await pdfWait("new library reader") { controller.isReady && self.pdfObjects()?.2.document !== oldOwnerDocument }
            try await rejectDeferredReceipt(oldRootReceipt, label: "oldLibraryRoot")
            try pdfRequire(store.pdfDisplayReloadID != oldOwnerDisplay && store.sourceFileURL?.path.hasPrefix(otherRoot.path + "/") == true,
                "Same identifiers in another library reused an old source lease")
            metrics.record("samebook-original-root-readmission")
            store.repository = originalOwner; store.libraryRootURL = originalRoot; store.books = [project]
            await store.selectBook(project.id, preferredRoute: "reader")
            try await pdfWait("original owner restored") { controller.isReady && self.store.sourceFileURL == canonical }
            assertions["differentLibraryOwnerCannotReuseLease"] = true

            // Replacing an already-unlocked source with a differently encrypted
            // file must not inherit its old bookID-based unlocked fast return.
            metrics.record("samebook-encrypted-fixtures")
            let encryptedA = output.appendingPathComponent("encrypted-a.pdf"), encryptedB = output.appendingPathComponent("encrypted-b.pdf")
            guard let encryptorA = PDFDocument(data: sourceBytes), let encryptorB = PDFDocument(data: sourceBytes),
                  encryptorA.write(to: encryptedA, withOptions: [.ownerPasswordOption: "owner-a", .userPasswordOption: "fixture-pass-a"]),
                  encryptorB.write(to: encryptedB, withOptions: [.ownerPasswordOption: "owner-b", .userPasswordOption: "fixture-pass-b"]) else {
                throw ReadingError.invalid("Unable to create encrypted source fixtures")
            }
            let encryptedBytes = try Data(contentsOf: encryptedA)
            let encryptedHash = SHA256.hash(data: encryptedBytes).map { String(format: "%02x", $0) }.joined()
            var encrypted = BookProject(title: "Encrypted same-book source fixture", originalName: encryptedA.lastPathComponent,
                sourceHash: encryptedHash, units: (1...8).map { SourceUnit(id: "encrypted-page-\($0)", order: $0-1, chapter: "Encrypted", page: $0, text: "Encrypted fixture page \($0)") })
            PluginEngine.seed(&encrypted); encrypted = try await originalOwner.create(encrypted, sourceURL: encryptedA)
            metrics.record("samebook-encrypted-initial-admission")
            store.books = [project, encrypted]
            await store.selectBook(encrypted.id, preferredRoute: "reader")
            try await pdfWait("encrypted source requests a password") { self.store.pdfPasswordRequest != nil && !self.store.isBusy }
            guard let passwordRequest = store.pdfPasswordRequest else { throw ReadingError.invalid("Missing encrypted source prompt") }
            metrics.record("samebook-encrypted-unlock")
            store.submitPDFPassword("fixture-pass-a", for: passwordRequest)
            try await pdfWait("encrypted source unlocked") {
                controller.isReady && self.store.pdfUnlockedBookIDs.contains(encrypted.id) && !self.store.isBusy
                    && self.pdfObjects()?.2.document?.isEncrypted == true && self.pdfObjects()?.2.document?.isLocked == false
            }
            guard let unlocked = pdfObjects()?.2.document else { throw ReadingError.invalid("Unlocked document missing") }
            metrics.record("samebook-encrypted-verified-reselect")
            await store.selectBook(encrypted.id, preferredRoute: "reader")
            try await pdfWait("unchanged encrypted session stays ready") { controller.isReady && self.store.pdfPasswordRequest == nil }
            try pdfRequire(pdfObjects()?.2.document === unlocked, "Unchanged verified encrypted source must retain the same unlocked native document")
            let encryptedCanonical = await originalOwner.sourceURL(for: encrypted)
            try Data(contentsOf: encryptedB).write(to: encryptedCanonical, options: .atomic)
            let encryptedReload = store.pdfDisplayReloadID
            metrics.record("samebook-encryption-replacement")
            await store.selectBook(encrypted.id, preferredRoute: "reader")
            try await pdfWait("changed encryption requests a new password") {
                self.store.pdfPasswordRequest != nil && !self.store.isBusy && self.pdfObjects()?.2.document !== unlocked
            }
            try pdfRequire(store.pdfDisplayReloadID != encryptedReload && !store.pdfUnlockedBookIDs.contains(encrypted.id)
                && store.pdfPassword(for: encrypted.id) == nil && pdfObjects()?.2.document !== unlocked,
                "A replaced encrypted file inherited the stale unlocked source admission")
            if let request = store.pdfPasswordRequest { store.cancelPDFPasswordRequest(request.id) }
            try encryptedBytes.write(to: encryptedCanonical, options: .atomic)
            assertions["unchangedEncryptedSessionRetainedAndReplacementInvalidated"] = true
            metrics.record("samebook-final-original-readmission")
            await store.selectBook(project.id, preferredRoute: "reader")
            try await pdfWait("final original ready") { controller.isReady && self.store.bookID == project.id }

            metrics.record("samebook-final-preservation-checks")
            try pdfRequire(try Data(contentsOf: canonical) == sourceBytes && Data(contentsOf: source) == sourceBytes,
                "Original PDF bytes were not restored and preserved")
            try pdfRequire(try Data(contentsOf: projectURL) == projectBefore, "Selection tests rewrote the original project/analysis/annotations")
            try pdfRequire(try await originalOwner.readDocument(bookID: project.id, document: note) == noteBody,
                "Selection tests changed saved user Markdown")
            let analysisEncoder = JSONEncoder(); analysisEncoder.outputFormatting = [.sortedKeys]
            try pdfRequire(try analysisEncoder.encode(store.book?.insights ?? []) == analysisEncoder.encode(project.insights)
                && store.book?.readerAnnotations == project.readerAnnotations,
                "Selection tests changed saved analysis or annotations")
            assertions["originalProjectNotesAnalysisAndAnnotationsPreserved"] = true
            assertions["queryAndAIIdle"] = !store.isQueryBusy && !store.isSmartReadingRunning
            assertions["status"] = "passed"
        } catch {
            assertions["status"] = "failed"; assertions["reason"] = error.localizedDescription
            try? capturePDFView("samebook-failure.png")
        }
        metrics.settling(); try? await Task.sleep(nanoseconds: 250_000_000)
        assertions["states"] = states; assertions["metrics"] = metrics.snapshot()
        assertions["windowVisible"] = window?.isVisible ?? false
        assertions["testScope"] = "real selectBook + ReaderWorkspaceView/native PDF objects, arbitrary saved page/viewport, changed/missing/symlink/corrupt source invalidation and session ownership; no FPS, paid AI or user library"
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

/// Ignores cancellation until released, like a provider returning after input changed.
private actor UrgentSearchExpansionGate {
    private var continuation: CheckedContinuation<LibrarySearchExpansionPlan, Error>?
    private(set) var started = false
    private(set) var returned = false
    private(set) var calls = 0
    func request(_ query: String, _ language: LibrarySearchLanguageProfile) async throws -> LibrarySearchExpansionPlan {
        guard !started else { throw ReadingError.invalid("Fixture expansion invoked twice") }
        started = true; calls += 1
        let plan: LibrarySearchExpansionPlan = try await withCheckedThrowingContinuation { continuation = $0 }
        returned = true
        return plan
    }
    func release(_ keywords: [String]) throws {
        guard let continuation else { throw ReadingError.invalid("Fixture expansion was not waiting") }
        self.continuation = nil
        continuation.resume(returning: try LibrarySearchExpansionPlan(keywords: keywords))
    }
}

@MainActor extension Runner {
    private func urgentWait(_ description: String, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            window?.contentView?.layoutSubtreeIfNeeded()
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ReadingError.invalid("Urgent search regression timeout: " + description)
    }
    private func urgentSearchSessionChecks(_ projects: [BookProject]) async throws -> [String: Any] {
        let snapshots = projects.map { LibrarySourceSnapshot(project: $0) }
        let firstID = projects[0].id, secondID = projects[1].id, root = library.standardizedFileURL.path
        let session = LibrarySearchSession()
        var assertions: [String: Any] = ["realNetworkRequests": 0]
        func local(_ query: String, bookID: String?, root: String, snapshots input: [LibrarySourceSnapshot]? = nil) async throws {
            session.schedule(query: query, snapshots: input ?? snapshots, bookID: bookID, root: root, debounce: false)
            try await urgentWait("local query \(query)") { !session.searching && session.response?.query == query }
            try pdfRequire(session.errorMessage.isEmpty, "Local fixture search failed: " + session.errorMessage)
        }
        func begin(_ gate: UrgentSearchExpansionGate) async throws {
            session.expand { query, language in try await gate.request(query, language) }
            try await urgentWait("controlled expansion started") { await gate.started }
            try pdfRequire(session.expanding, "Expansion state did not remain active while waiting")
        }
        func release(_ gate: UrgentSearchExpansionGate, words: [String]) async throws {
            try await gate.release(words)
            try await urgentWait("controlled expansion returned") { await gate.returned }
            try await Task.sleep(nanoseconds: 60_000_000)
            try pdfRequire(await gate.calls == 1, "One explicit expansion invoked the operation more than once")
        }
        try await local("貂蝉", bookID: firstID, root: root)
        let localIDs = session.response!.matches.map(\.id)
        try pdfRequire(localIDs.count == 8, "Simplified query did not find eight real Traditional locations")
        session.cancel()
        try pdfRequire(session.response?.matches.map(\.id) == localIDs && !session.searching && !session.expanding,
            "Cancel cleared verified local results")
        assertions["cancelPreservesVerifiedLocalResults"] = true

        let queryGate = UrgentSearchExpansionGate()
        try await begin(queryGate)
        try await local("安静", bookID: firstID, root: root)
        let replacementIDs = session.response!.matches.map(\.id)
        try await release(queryGate, words: ["貂蝉"])
        try pdfRequire(session.response?.query == "安静" && session.response?.matches.map(\.id) == replacementIDs
            && session.expandedKeywords.isEmpty && !session.expanding, "Late AI replaced the newer query")
        assertions["lateExpansionCannotReplaceNewQuery"] = true

        try await local("貂蝉", bookID: firstID, root: root)
        let scopeGate = UrgentSearchExpansionGate()
        try await begin(scopeGate)
        try await local("貂蝉", bookID: secondID, root: root)
        try pdfRequire(session.response?.matches.isEmpty == true, "Second-book fixture unexpectedly contains the keyword")
        try await release(scopeGate, words: ["貂蝉"])
        try pdfRequire(session.response?.matches.isEmpty == true && session.response?.searchedBookCount == 1
            && session.expandedKeywords.isEmpty, "Late AI escaped the changed book scope")
        assertions["lateExpansionCannotEscapeNewBookScope"] = true

        try await local("貂蝉", bookID: firstID, root: root)
        let rootGate = UrgentSearchExpansionGate()
        try await begin(rootGate)
        var otherRoot = snapshots
        otherRoot[0].sourceHash = "different-root-source"
        otherRoot[0].units = [SourceUnit(id: "different-root-unit", order: 0, chapter: "另一原文", text: "另一书库的独立原文。")]
        try await local("貂蝉", bookID: firstID, root: root + "/other-root", snapshots: otherRoot)
        try await release(rootGate, words: ["貂蝉"])
        try pdfRequire(session.response?.matches.isEmpty == true && session.response?.scannedUnitCount == 1
            && session.expandedKeywords.isEmpty, "Late AI published an old library's source")
        assertions["lateExpansionCannotPublishOldLibrary"] = true

        try await local("貂蝉", bookID: firstID, root: root)
        let sourceGate = UrgentSearchExpansionGate()
        try await begin(sourceGate)
        var edited = snapshots
        edited[0].units = [SourceUnit(id: "ocr-replaced-unit", order: 0, chapter: "OCR新版", text: "OCR版本已改变，不再包含旧词。")]
        try await local("貂蝉", bookID: firstID, root: root, snapshots: edited)
        try await release(sourceGate, words: ["貂蝉"])
        try pdfRequire(session.response?.matches.isEmpty == true && session.response?.scannedUnitCount == 1,
            "Late AI published an obsolete OCR snapshot with unchanged PDF hash")
        assertions["lateExpansionCannotPublishOldOCRText"] = true

        try await local("貂蝉", bookID: firstID, root: root)
        let cancelGate = UrgentSearchExpansionGate()
        try await begin(cancelGate)
        let beforeCancel = session.response!.matches
        session.cancel()
        try await release(cancelGate, words: ["模型杜撰的不存在词"])
        try pdfRequire(session.response?.matches == beforeCancel && !session.expanding && !session.searching
            && session.expandedKeywords.isEmpty, "Canceled AI changed displayed local results")
        assertions["lateCanceledExpansionPreservesDisplayedResults"] = true

        try await local("貂蝉", bookID: firstID, root: root)
        let oldGate = UrgentSearchExpansionGate(), newGate = UrgentSearchExpansionGate()
        try await begin(oldGate)
        try await local("貂禅", bookID: firstID, root: root)
        try pdfRequire(session.response?.matches.isEmpty == true, "Typo silently became a source hit")
        try await begin(newGate)
        try await release(oldGate, words: ["貂蝉"])
        try pdfRequire(session.expanding && session.response?.query == "貂禅" && session.response?.matches.isEmpty == true
            && session.expandedKeywords.isEmpty, "Old completion cleared/replaced a newer expansion")
        try await release(newGate, words: ["貂蝉", "模型杜撰的不存在词"])
        try await urgentWait("new expansion finishes") { !session.expanding && session.response?.matches.count == 8 }
        guard let expanded = session.response else { throw ReadingError.invalid("Expanded result missing") }
        try pdfRequire(expanded.query == "貂禅" && expanded.matches.allSatisfy { $0.bookID == firstID && $0.quote == "貂蟬" && $0.matchedQuery == "貂蝉" },
            "Expanded keywords became model quotes or escaped the frozen scope")
        for match in expanded.matches { try match.validate(in: projects[0]) }
        assertions["oldCompletionCannotClearNewExpansion"] = true
        assertions["expandedKeywordsOnlyProduceActualScopedSourceMatches"] = true

        session.schedule(query: "貂禅", snapshots: snapshots, bookID: firstID, root: root, debounce: true)
        session.expand { _, _ in try LibrarySearchExpansionPlan.parse("{\"keywords\":[\"貂蝉\"]}") }
        try await urgentWait("expansion wins over pending debounce") { !session.expanding && session.response?.matches.count == 8 }
        let winningIDs = session.response!.matches.map(\.id)
        try await Task.sleep(nanoseconds: 320_000_000)
        try pdfRequire(session.response?.matches.map(\.id) == winningIDs && session.expandedKeywords == ["貂蝉"]
            && session.response?.searchedQueries == ["貂禅", "貂蝉"], "Older local work overwrote expanded response")
        assertions["pendingLocalWorkCannotOverwriteExpansion"] = true

        let emptyGate = UrgentSearchExpansionGate()
        try await begin(emptyGate)
        session.schedule(query: "", snapshots: snapshots, bookID: firstID, root: root, debounce: false)
        try await release(emptyGate, words: ["貂蝉"])
        try pdfRequire(session.response == nil && !session.searching && !session.expanding
            && session.expandedKeywords.isEmpty, "Cleared input received late results")
        assertions["clearedInputCannotReceiveLateResults"] = true
        session.cancel()
        return assertions
    }
}

@MainActor extension Runner {
    func runUrgentSearchOverlayScenario() async {
        var assertions: [String: Any] = ["mode": mode, "synthetic": true, "realNetworkRequests": 0]
        var states: [[String: Any]] = []
        do {
            var projects: [BookProject] = [], originals: [String: Data] = [:]
            for label in ["A", "B"] {
                let source = output.appendingPathComponent("urgent-search-\(label).pdf")
                let bytes = try sameBookPDF(source, label: "Urgent search fixture \(label)")
                let units = (1...8).map { page in
                    SourceUnit(id: "urgent-\(label)-u\(page)", order: page - 1, chapter: "合成章节", page: page,
                        text: label == "A" ? "第\(page)頁：😀e\u{301} 貂蟬在此，安靜閱讀。" : "第\(page)頁：另一原書只有曹操，不含第一本的名字。")
                }
                var project = BookProject(title: "Urgent overlay fixture \(label)", originalName: source.lastPathComponent,
                    sourceHash: try BookImporter.sha256(bytes), units: units)
                PluginEngine.seed(&project)
                project.insights.append(ReadingInsight(id: "urgent-saved-analysis-\(label)", unitIDs: [units[3].id],
                    markdown: "## Saved analysis\n\nPreserve saved analysis, $x^2$, e\u{301} and 🙂."))
                project = try await store.repository.create(project, sourceURL: source)
                projects.append(project); originals[project.id] = bytes
            }
            let note = DocumentRecord(id: "urgent-preserved-note", title: "Preserved overlay note")
            let noteBody = "# Preserved overlay note\n\nKeep e\u{301}, 🙂 and $x^2$ exactly.\n"
            projects[0] = try await store.repository.saveDocument(project: projects[0], document: note, markdown: noteBody)
            let projectBytes = try Dictionary(uniqueKeysWithValues: projects.map {
                ($0.id, try Data(contentsOf: library.appendingPathComponent("books/\($0.id)/project.json")))
            })
            store.books = projects
            await store.selectBook(projects[0].id, preferredRoute: "reader")
            store.navigateToUnit(projects[0].units[3].id)
            let root = WorkspaceView().environmentObject(store).environmentObject(ReadingTypographySettings())
                .modifier(ReadingPreferencesEnvironment()).background(FrostWindowAppearance())
            window = NSWindow(contentRect: NSRect(x: 70, y: 70, width: 1280, height: 860), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "ReadingBook urgent search and overlay regression · Offline fixtures"
            window.contentView = CountingHost(rootView: AnyView(root)); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            metrics.scenario(); metrics.record("urgent-reader-initial-mount")
            try await pdfWait("workspace real PDF page four") {
                guard let pdf = self.pdfObjects()?.2, let document = pdf.document, let page = pdf.currentPage else { return false }
                return document.index(for: page) + 1 == 4 && self.store.selectedUnit?.page == 4
            }
            guard var baseline = pdfObjects(), var baselineDocument = baseline.2.document else { throw ReadingError.invalid("Retained reader baseline missing") }
            func retainedReader(_ label: String, page: Int = 4) throws {
                guard let current = self.pdfObjects(), let document = current.2.document, let nativePage = current.2.currentPage else {
                    throw ReadingError.invalid("Reader disappeared beneath overlay: " + label)
                }
                try self.pdfRequire(current.0 === baseline.0 && current.2 === baseline.2 && document === baselineDocument,
                    "Overlay replaced retained native reader/document: " + label)
                try self.pdfRequire(self.store.route == "reader" && self.store.selectedUnit?.page == page && document.index(for: nativePage) + 1 == page,
                    "Overlay changed reader route/page: " + label)
                states.append(["label": label, "route": self.store.route, "selectedPage": self.store.selectedUnit?.page ?? -1,
                    "nativePage": document.index(for: nativePage) + 1, "pdfViewID": String(describing: ObjectIdentifier(current.2)),
                    "documentID": String(describing: ObjectIdentifier(document)), "notesPresented": self.store.isNotesPresented,
                    "auxiliaryKind": self.store.auxiliaryPresentation?.kind.rawValue ?? "", "editorDirty": self.store.editorDirty])
            }
            try pdfRequire(WorkspaceAuxiliaryNavigation.commit(.route("librarySearch"), store: store), "Search presentation rejected")
            guard let firstSearch = store.auxiliaryPresentation else { throw ReadingError.invalid("Search owner missing") }
            try await Task.sleep(nanoseconds: 180_000_000)
            try retainedReader("search-open")
            try pdfRequire(WorkspaceAuxiliaryNavigation.commit(.dismissAuxiliary(firstSearch.id), store: store), "Reader search close rejected")
            try await Task.sleep(nanoseconds: 100_000_000)
            try retainedReader("search-close-reader")
            assertions["searchOpenCloseRetainsReaderDocumentAndPage"] = true
            try capturePDFView("urgent-reader-after-search-close.png")

            for priorRoute in ["library", "query"] {
                try pdfRequire(WorkspaceAuxiliaryNavigation.commit(.route(priorRoute), store: store), "Unable to enter prior route fixture")
                try pdfRequire(WorkspaceAuxiliaryNavigation.commit(.route("librarySearch"), store: store), "Prior-route search rejected")
                guard let owner = store.auxiliaryPresentation else { throw ReadingError.invalid("Prior-route search owner missing") }
                try pdfRequire(store.route == priorRoute && WorkspaceAuxiliaryNavigation.commit(.dismissAuxiliary(owner.id), store: store)
                    && store.route == priorRoute, "Search close did not preserve its actual prior route")
            }
            assertions["searchCloseReturnsToLibraryAndQueryPriorRoutes"] = true
            try pdfRequire(WorkspaceAuxiliaryNavigation.commit(.route("reader"), store: store), "Restore reader rejected")
            try await pdfWait("reader remount after deliberate base-route navigation") { self.pdfObjects()?.2.document != nil && self.store.route == "reader" }
            guard let restored = pdfObjects(), let restoredDocument = restored.2.document else { throw ReadingError.invalid("Restored reader missing") }
            baseline = restored; baselineDocument = restoredDocument
            store.navigateToUnit(projects[0].units[3].id)
            try await pdfWait("restored page four") { self.pdfObjects()?.2.currentPage.flatMap { page in self.pdfObjects()?.2.document?.index(for: page) } == 3 }

            try pdfRequire(WorkspaceAuxiliaryNavigation.commit(.route("librarySearch"), store: store), "Result search rejected")
            guard let resultOwner = store.auxiliaryPresentation,
                  let match = try LibraryTextSearch.search(query: "貂蝉", snapshots: [LibrarySourceSnapshot(project: projects[0])]).matches.first(where: { $0.page == 6 }) else {
                throw ReadingError.invalid("Actual source result fixture missing")
            }
            try match.validate(in: store.book!)
            store.navigateToUnit(match.unitID)
            try pdfRequire(WorkspaceAuxiliaryNavigation.commit(.searchResult(resultOwner.id), store: store), "Valid result callback rejected")
            try await pdfWait("actual source result page six") { self.pdfObjects()?.2.currentPage.flatMap { page in self.pdfObjects()?.2.document?.index(for: page) } == 5 }
            try retainedReader("source-result-commits-reader", page: 6)
            try pdfRequire(store.auxiliaryPresentation == nil && !store.hasWorkspaceAuxiliary && store.route != "library", "Result callback overrode reader with library")
            assertions["sourceResultCommitsReaderRatherThanLibrary"] = true
            store.navigateToUnit(projects[0].units[3].id)
            try await pdfWait("page four before notes") { self.pdfObjects()?.2.currentPage.flatMap { page in self.pdfObjects()?.2.document?.index(for: page) } == 3 }

            await store.openDocument(note)
            try await pdfWait("notes native editor mounted") {
                guard let host = self.window.contentView else { return false }
                return self.store.isNotesForeground && self.descendants(host, NSTextView.self).contains { String(describing: type(of: $0)).contains("NoteMarkdownTextView") }
            }
            guard let notesOwner = store.notesPresentation, let host = window.contentView,
                  let editor = descendants(host, NSTextView.self).first(where: { String(describing: type(of: $0)).contains("NoteMarkdownTextView") }),
                  let undo = editor.undoManager else { throw ReadingError.invalid("Owned note editor/Undo missing") }
            let addition = "\nUnsaved native note draft 🙂 e\u{301}."
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.breakUndoCoalescing(); editor.insertText(addition, replacementRange: editor.selectedRange()); editor.breakUndoCoalescing()
            try await pdfWait("native edit reaches AppStore binding") { self.store.editorDirty && self.store.editorMarkdown == noteBody + addition }
            let dirtyBody = store.editorMarkdown, selection = editor.selectedRange()
            try pdfRequire(undo.canUndo, "Native note edit did not populate owned Undo")
            for kind in [WorkspaceAuxiliaryKind.search, .trash] {
                try pdfRequire(WorkspaceAuxiliaryNavigation.commit(.route(kind.rawValue), store: store), "Dirty-note overlay admission rejected")
                guard let owner = store.auxiliaryPresentation else { throw ReadingError.invalid("Covered-note overlay missing") }
                try await Task.sleep(nanoseconds: 150_000_000)
                try retainedReader("dirty-notes-covered-by-" + kind.rawValue)
                try pdfRequire(store.notesPresentation?.id == notesOwner.id && !store.isNotesForeground, "Covering notes replaced presentation owner")
                if kind == .search {
                    let selectedBefore = store.selectedUnitID, tokenBefore = store.pdfNavigationToken
                    let resultIntent = WorkspaceNavigationIntent.searchResult(owner.id)
                    try pdfRequire(WorkspaceAuxiliaryNavigation.admission(for: resultIntent, store: store) == .requiresNotesDecision(notesOwner)
                        && !WorkspaceAuxiliaryNavigation.commit(resultIntent, store: store) && store.selectedUnitID == selectedBefore
                        && store.pdfNavigationToken == tokenBefore && store.editorMarkdown == dirtyBody && store.editorDirty,
                        "Dirty search result navigated or discarded notes before its decision")
                    assertions["dirtyResultCannotNavigateBeforeNotesDecision"] = true
                }
                try pdfRequire(WorkspaceAuxiliaryNavigation.commit(.dismissAuxiliary(owner.id), store: store), "Covered-note overlay close rejected")
                try await pdfWait("notes return after overlay") { self.store.isNotesForeground && editor.isEditable }
                let current = descendants(host, NSTextView.self).first { String(describing: type(of: $0)).contains("NoteMarkdownTextView") }
                try pdfRequire(current === editor && editor.undoManager === undo && undo.canUndo && editor.selectedRange() == selection
                    && store.editorMarkdown == dirtyBody && store.editorDirty && store.notesPresentation?.id == notesOwner.id,
                    "Overlay close destroyed note selection/Undo/draft/session")
            }
            assertions["searchAndTrashRetainNativeNoteSessionUndoSelectionAndDraft"] = true
            let dirtyClose = WorkspaceNavigationIntent.dismissAuxiliary(notesOwner.id)
            try pdfRequire(WorkspaceAuxiliaryNavigation.admission(for: dirtyClose, store: store) == .requiresNotesDecision(notesOwner)
                && !WorkspaceAuxiliaryNavigation.commit(dirtyClose, store: store), "Dirty notes closed without a decision")
            try await Task.sleep(nanoseconds: 80_000_000)
            try pdfRequire(store.notesPresentation?.id == notesOwner.id && store.editorMarkdown == dirtyBody
                && store.editorDirty && editor.undoManager === undo && undo.canUndo, "Continue editing lost dirty note state")
            assertions["dirtyCloseContinueEditingPreservesDraft"] = true
            try capturePDFView("urgent-dirty-notes-retained.png")
            store.discardDraftForWorkspaceNavigation()
            try pdfRequire(WorkspaceAuxiliaryNavigation.commit(dirtyClose, store: store) && store.notesPresentation == nil, "Resolved note close rejected")
            await store.openDocument(note)
            guard let freshNotes = store.notesPresentation else { throw ReadingError.invalid("Fresh notes presentation missing") }
            try pdfRequire(freshNotes.id != notesOwner.id && WorkspaceAuxiliaryNavigation.admission(for: dirtyClose, store: store) == .ignored
                && !WorkspaceAuxiliaryNavigation.commit(dirtyClose, store: store) && store.notesPresentation?.id == freshNotes.id, "Obsolete notes owner closed newer session")
            assertions["obsoleteNotesOwnerCannotCloseNewSession"] = true
            try pdfRequire(WorkspaceAuxiliaryNavigation.commit(.dismissAuxiliary(freshNotes.id), store: store), "Clean notes close rejected")
            try await Task.sleep(nanoseconds: 80_000_000)
            try retainedReader("notes-close-reader")

            store.presentWorkspaceAuxiliary(.search)
            guard let crossBook = store.auxiliaryPresentation else { throw ReadingError.invalid("Cross-book search missing") }
            // Match LibrarySearchView's cross-book admission: restoration may
            // retain its base route, while the owned result callback commits reader.
            await store.selectBook(projects[1].id)
            try pdfRequire(store.bookID == projects[1].id && store.auxiliaryPresentation?.id == crossBook.id && crossBook.matches(store), "Root-owned search invalidated by permitted cross-book admission")
            try pdfRequire(WorkspaceAuxiliaryNavigation.commit(.searchResult(crossBook.id), store: store) && store.route == "reader" && store.auxiliaryPresentation == nil, "Cross-book result could not commit reader")
            assertions["rootOwnedSearchCanCommitAfterCrossBookSelection"] = true
            store.presentWorkspaceAuxiliary(.search)
            guard let staleSearch = store.auxiliaryPresentation else { throw ReadingError.invalid("Stale search fixture missing") }
            try pdfRequire(WorkspaceAuxiliaryNavigation.commit(.dismissAuxiliary(staleSearch.id), store: store), "Search close rejected")
            store.presentWorkspaceAuxiliary(.search)
            guard let freshSearch = store.auxiliaryPresentation else { throw ReadingError.invalid("Fresh search fixture missing") }
            try pdfRequire(freshSearch.id != staleSearch.id && WorkspaceAuxiliaryNavigation.admission(for: .searchResult(staleSearch.id), store: store) == .ignored
                && !WorkspaceAuxiliaryNavigation.commit(.dismissAuxiliary(staleSearch.id), store: store) && store.auxiliaryPresentation?.id == freshSearch.id, "Obsolete search callback affected new search")
            let beforeRootRoute = store.route
            store.libraryRootURL = library.appendingPathComponent("different-owner-root", isDirectory: true)
            try pdfRequire(!freshSearch.matches(store) && !store.hasWorkspaceAuxiliary
                && !WorkspaceAuxiliaryNavigation.commit(.searchResult(freshSearch.id), store: store) && store.route == beforeRootRoute, "Old-library callback changed new owner")
            store.libraryRootURL = library
            assertions["obsoleteSearchAndLibraryOwnersAreRejected"] = true

            metrics.record("urgent-controlled-search-session-workers")
            assertions["searchSession"] = try await urgentSearchSessionChecks(projects)
            for project in projects {
                let canonical = await store.repository.sourceURL(for: project)
                try pdfRequire(try Data(contentsOf: canonical) == originals[project.id]
                    && Data(contentsOf: library.appendingPathComponent("books/\(project.id)/project.json")) == projectBytes[project.id], "Search/overlay changed original source/saved analysis")
            }
            try pdfRequire(try await store.repository.readDocument(bookID: projects[0].id, document: note) == noteBody, "Search/overlay changed saved note bytes")
            try pdfRequire(!store.isQueryBusy && !store.isSmartReadingRunning && !store.isCompanionGenerating, "Offline regression started product AI lane")
            assertions["originalSourceSavedNotesAndAnalysisBytesPreserved"] = true
            assertions["status"] = "passed"
        } catch {
            assertions["status"] = "failed"; assertions["reason"] = error.localizedDescription
            try? capturePDFView("urgent-search-overlay-failure.png")
        }
        metrics.settling(); try? await Task.sleep(nanoseconds: 250_000_000)
        assertions["states"] = states; assertions["metrics"] = metrics.snapshot(); assertions["windowVisible"] = window?.isVisible ?? false
        assertions["testScope"] = "Real AppStore/repository/Workspace native PDF and note/Undo identity; production admission/commit and actual search-session workers with delayed fake operations. Programmatic transitions, not pointer gestures, real providers or FPS."
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
