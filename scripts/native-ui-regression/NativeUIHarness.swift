import AppKit
import SwiftUI
import Foundation
import CryptoKit
import Darwin
@testable import ReadingBook
import ReadingCore

final class Metrics: @unchecked Sendable {
    struct Pulse: Sendable { let queuedAt: Double; let phase: String; let action: String }
    let lock = NSLock()
    let startedAt = ProcessInfo.processInfo.systemUptime
    var lastBeat = ProcessInfo.processInfo.systemUptime
    var maximumLag = 0.0
    var maximumStartupLag = 0.0
    var maximumInteractiveLag = 0.0
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
    func scenario() { lock.lock(); phase = "scenario"; lock.unlock() }
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
        let sample: [String: Any] = ["queuedPhase": pulse.phase, "queuedAction": pulse.action,
            "lagSeconds": lag, "queuedSecondsSinceStart": pulse.queuedAt - startedAt,
            "deliveredSecondsSinceStart": delivered - startedAt]
        if lag > maximumLag { maximumLag = lag; worstHeartbeat = sample }
        maximumLagByPhase[pulse.phase] = max(maximumLagByPhase[pulse.phase] ?? 0, lag)
        if pulse.phase == "starting" { maximumStartupLag = max(maximumStartupLag, lag) }
        else { maximumInteractiveLag = max(maximumInteractiveLag, lag) }
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
