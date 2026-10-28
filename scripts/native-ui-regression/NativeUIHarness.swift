import AppKit
import SwiftUI
import Foundation
import CryptoKit
import Darwin
@testable import ReadingBook
import ReadingCore

final class Metrics: @unchecked Sendable {
    let lock = NSLock()
    var lastBeat = ProcessInfo.processInfo.systemUptime
    var maximumLag = 0.0
    var beats = 0
    var layouts = 0
    var completed = 0
    var lastAction = "launch"
    var phase = "starting"
    var watchdogFired = false
    func scenario() { lock.lock(); phase = "scenario"; lock.unlock() }
    func record(_ label: String) { lock.lock(); lastAction = label; completed += 1; lock.unlock() }
    func layout() { lock.lock(); layouts += 1; lock.unlock() }
    func beat(_ queued: Double) { lock.lock(); maximumLag = max(maximumLag, ProcessInfo.processInfo.systemUptime - queued); lastBeat = ProcessInfo.processInfo.systemUptime; beats += 1; lock.unlock() }
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["phase": phase, "lastAction": lastAction, "actions": completed, "heartbeats": beats,
                "layouts": layouts, "maximumMainQueueLagSeconds": maximumLag,
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
                ReaderFloatingPanel(title: "伴读与对话", icon: "sparkles", width: 376, height: 620,
                    isPresented: $store.readingCompanionVisible, viewport: geometry.size,
                    showsRestoreButton: false, unifiedDismiss: true, resizable: true) {
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
            let queued = ProcessInfo.processInfo.systemUptime
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
            DispatchQueue.main.async { metrics.beat(queued) }
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
            store.readingCompanionVisible = true
            metrics.record("open-\(cycle)")
            try? await Task.sleep(nanoseconds: 90_000_000)
            store.readingCompanionTab = "chat"
            metrics.record("chat-\(cycle)")
            try? await Task.sleep(nanoseconds: 90_000_000)
            window.setContentSize(sizes[cycle % sizes.count])
            metrics.record("resize-\(cycle)")
            try? await Task.sleep(nanoseconds: 90_000_000)
            store.readingCompanionTab = "companion"
            metrics.record("companion-\(cycle)")
            if let unit = store.book?.units.first(where: { $0.page == pages[cycle % pages.count] }) {
                store.selectedUnitID = unit.id
                metrics.record("page-\(pages[cycle % pages.count])")
            }
            try? await Task.sleep(nanoseconds: 90_000_000)
            store.readingCompanionVisible = false
            metrics.record("close-\(cycle)")
            try? await Task.sleep(nanoseconds: 90_000_000)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        var state = metrics.snapshot()
        state["status"] = (store.queryComposerDraft.text == draft && !store.isQueryBusy && !store.isSmartReadingRunning && window.isVisible && (state["layouts"] as? Int ?? 0) > 0 && (state["heartbeats"] as? Int ?? 0) > 0 && (state["maximumMainQueueLagSeconds"] as? Double ?? 99) < 1.5) ? "passed" : "failed"
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
        app.setActivationPolicy(.regular)
        let runner = Runner(output:output,library:library,mode:env["HARNESS_MODE"] ?? "workspace",cycles:Int(env["HARNESS_CYCLES"] ?? "24") ?? 24,synthetic:env["HARNESS_SYNTHETIC"] != "0")
        app.delegate = runner
        withExtendedLifetime(runner) { app.run() }
    }
}
