// Diagnostic-only hooks for the actual Release application and scene.
import Foundation
import AppKit
import SwiftUI
import WebKit
import CoreFoundation
import ReadingCore

@MainActor enum PerfProbe {
    struct Config: Codable {
        var workspace: String; var output: String; var library: String
        var mode: String; var source: String?; var bookID: String?
        var width: Double; var height: Double; var scale: Double
        var warmRepeats: Int; var memoryOffsets: [Double]; var hold: Bool
    }
    static var config: Config!
    static weak var window: NSWindow?
    private static var started = false
    private static var lastPDF: (page: Int, token: Int, zoom: Int, count: Int)?
    private static var companionPage: Int?
    private static var companionProjectionCount = 0
    private static var companionReceiptSequence = 0
    private static var lastCompanionCached = false
    private static var heartbeat: DispatchSourceTimer?
    private static let beatLock = NSLock()
    nonisolated(unsafe) private static var lastBeat = ProcessInfo.processInfo.systemUptime
    static func bootstrap(mainEntry: UInt64) {
        do {
            guard let path = ProcessInfo.processInfo.environment["READINGBOOK_PERF_CONFIG"] else { throw CocoaError(.fileNoSuchFile) }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            config = try JSONDecoder().decode(Config.self, from: data)
            let workspace = URL(fileURLWithPath: config.workspace).standardizedFileURL.resolvingSymlinksInPath()
            func checked(_ path: String) throws -> String {
                let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                guard target.pathComponents.count > workspace.pathComponents.count,
                      target.pathComponents.starts(with: workspace.pathComponents) else { throw CocoaError(.fileReadNoPermission) }
                return target.path
            }
            config.workspace = workspace.path
            config.output = try checked(config.output); config.library = try checked(config.library)
            if let source = config.source { config.source = try checked(source) }
            UserDefaults.standard.setVolatileDomain([
                "service-profiles": Data("[]".utf8), "library.root.path.v1": config.library,
                "reading.hoverTranslation": false, "appearance.reduceMotion": false,
                "appearance.reduceTransparency": false, "reading.defaultContinuous": true,
                "reading.defaultDirection": "vertical", "NSQuitAlwaysKeepsWindows": false,
                "ApplePersistenceIgnoreState": true,
                "workspace-last-book-v1": config.bookID ?? ""
            ], forName: UserDefaults.argumentDomain)
            try PerfTrace.configure(URL(fileURLWithPath: config.output), mainEntry: mainEntry)
            PerfTrace.event("probe.configured", ["instrumentation": "actual-App-scene Release-O; no AX; no pixel timestamp", "mode": config.mode])
            startHeartbeat()
        } catch { fputs("Performance probe requires a valid workspace-local configuration.\n", stderr); exit(2) }
    }
    private static func startHeartbeat() {
        let output = config.output
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler {
            let queued = PerfTrace.ticks()
            beatLock.lock(); let gap = ProcessInfo.processInfo.systemUptime - lastBeat; beatLock.unlock()
            if gap > 10 {
                PerfTrace.event("watchdog.main-stall", ["gapSeconds": gap]); PerfTrace.flush()
                let sample = Process(); sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                sample.arguments = [String(getpid()), "5", "10", "-file", URL(fileURLWithPath: output).appendingPathComponent("hang.sample.txt").path]
                try? sample.run(); sample.waitUntilExit(); exit(70)
            }
            DispatchQueue.main.async {
                beatLock.lock(); lastBeat = ProcessInfo.processInfo.systemUptime; beatLock.unlock()
                PerfTrace.event("heartbeat", ["queuedTicks": queued])
            }
        }
        timer.resume(); heartbeat = timer
    }
    static func normalizeMemory(_ store: AppStore) {
        guard store.book != nil else { return }
        var memory = store.workspaceMemory
        memory.pdf = WorkspacePDFMemory(page: 1, scale: config.scale, fitMode: "custom", continuous: true, thumbnails: false, direction: .vertical)
        memory.readerShowsPDF = true; memory.readingSourceMode = "original"; memory.readerOutline = false
        memory.route = "reader"
        memory.panels["reader.companion"] = WorkspacePanelMemory(isPresented: false, collapsed: false)
        memory.panels["reader.outline"] = WorkspacePanelMemory(isPresented: false, collapsed: false)
        store.workspaceMemory = memory
        PerfTrace.event("configuration.pdf-memory", ["scale": config.scale])
    }
    static func pdfReady(page: Int, token: Int, zoom: Int, count: Int) {
        lastPDF = (page, token, zoom, count)
        PerfTrace.event("reader.layout-ready", ["page": page, "token": token, "zoomPercent": zoom, "pageCount": count])
        foreground("pdf-layout-ready")
    }
    static func attach(_ attached: NSWindow) {
        window = attached
        PerfTrace.event("window.attached")
    }
    static func companionReady(page: Int?, cached: Bool = false) {
        companionReceiptSequence += 1
        if !cached { companionProjectionCount += 1 }
        companionPage = page; lastCompanionCached = cached
        PerfTrace.event(cached ? "companion.projection-cache-confirmed" : "companion.projection-applied", ["page": page ?? -1, "receiptSequence": companionReceiptSequence])
    }
    static func webViewReady(_ view: WKWebView) {
        // Optional diagnostic-only attribution; never count arbitrary system WebKit PIDs.
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard view.responds(to: selector), let implementation = view.method(for: selector) else {
            PerfTrace.event("webcontent.attribution-unavailable"); return
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
        PerfTrace.registerWebPID(unsafeBitCast(implementation, to: Getter.self)(view, selector))
    }
    static func storeLoaded(_ store: AppStore) {
        guard !started else { return }; started = true
        guard store.apiKey.isEmpty, store.savedServices.isEmpty else { fail("service isolation failed") }
        store.settings = ProviderSettings(baseURL: "http://127.0.0.1:1/disabled", model: "")
        Task { await scenario(store) }
    }
    private static func wait(_ label: String, timeout: Double = 90, _ ready: @escaping @MainActor () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if ready() {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { DispatchQueue.main.async { continuation.resume() } }
                }
                if ready() { PerfTrace.event(label); foreground(label); return }
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        fail("readiness timeout: " + label)
    }
    private static func foreground(_ label: String) {
        PerfTrace.event("window.foreground", ["label": label, "appActive": NSApp.isActive, "keyWindow": window?.isKeyWindow ?? false,
            "windowVisible": window?.isVisible ?? false, "occlusionVisible": window?.occlusionState.contains(.visible) ?? false])
    }
    private static func readerReady(_ store: AppStore, page: Int? = nil) -> Bool {
        guard let pdf = lastPDF, let unitPage = page ?? store.selectedUnit?.page else { return false }
        return !store.isBusy && window?.isVisible == true && pdf.page == unitPage && pdf.token == store.pdfNavigationToken && pdf.zoom == Int((config.scale * 100).rounded())
    }
    private static func page(_ page: Int, _ store: AppStore, round: Int) async {
        guard let unit = store.book?.units.first(where: { $0.page == page }) else { fail("page unavailable") }
        foreground("action-page")
        PerfTrace.event("action.begin", ["kind": "page", "page": page, "round": round])
        store.navigateToUnit(unit.id)
        await wait("action.page.main-queue-echo") { readerReady(store, page: page) }
        PerfTrace.event("action.end", ["kind": "page", "page": page, "round": round])
    }
    private static func scenario(_ store: AppStore) async {
        await wait("window.state-main-queue-echo") { window?.isVisible == true }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        PerfTrace.event("window.activation-request")
        await wait("window.foreground-main-queue-echo") { NSApp.isActive && window?.isKeyWindow == true }
        foreground("scenario-start")
        if config.mode == "import" {
            guard let source = config.source else { fail("import source missing") }
            PerfTrace.event("action.begin", ["kind": "import", "round": 0])
            store.importBook(URL(fileURLWithPath: source))
            await wait("import.reader.main-queue-echo", timeout: 180) { store.book != nil && readerReady(store) }
            PerfTrace.event("action.end", ["kind": "import", "round": 0])
        } else {
            await wait("startup.reader.main-queue-echo") { readerReady(store) }
        }
        if let window { PerfTrace.event("configuration.window", ["contentWidth": window.contentView?.bounds.width ?? -1, "contentHeight": window.contentView?.bounds.height ?? -1]) }
        let repeats = max(1, config.warmRepeats)
        for round in 0..<repeats {
            foreground("round-" + String(round))
            if round > 0, let id = store.bookID {
                PerfTrace.event("action.begin", ["kind": "reopen-book", "round": round])
                await store.selectBook(id)
                await wait("action.reopen-book.main-queue-echo") { readerReady(store) }
                PerfTrace.event("action.end", ["kind": "reopen-book", "round": round])
            }
            for number in [1,8,182,800,1484] { await page(number, store, round: round) }
            await page(182, store, round: round)
            if round == 0 && (store.readingCompanionVisible || companionReceiptSequence != 0) { fail("first companion open was already warmed") }
            store.readingCompanionTab = "companion"
            let previousReceipt = companionReceiptSequence
            PerfTrace.event("action.begin", ["kind": "companion-open", "round": round, "previousProjectionCount": companionProjectionCount, "previousReceipt": previousReceipt])
            store.readingCompanionVisible = true
            await wait("action.companion-open.main-queue-echo") { store.readingCompanionVisible && companionPage == store.selectedUnit?.page && companionReceiptSequence > previousReceipt }
            PerfTrace.event("action.end", ["kind": "companion-open", "round": round, "cachedProjection": lastCompanionCached, "receiptSequence": companionReceiptSequence])
            for tab in ["chat", "companion"] {
                PerfTrace.event("action.begin", ["kind": "tab-" + tab, "round": round])
                store.readingCompanionTab = tab
                await wait("action.tab.main-queue-echo") { store.readingCompanionTab == tab }
                PerfTrace.event("action.end", ["kind": "tab-" + tab, "round": round])
            }
            PerfTrace.event("action.begin", ["kind": "companion-close", "round": round])
            store.readingCompanionVisible = false
            await wait("action.companion-close.main-queue-echo") { !store.readingCompanionVisible }
            PerfTrace.event("action.end", ["kind": "companion-close", "round": round])
        }
        await wait("preparation.reported-idle", timeout: 60) { store.readingPreparationState.current == nil && !store.isBusy }
        let idle = ProcessInfo.processInfo.systemUptime
        for offset in config.memoryOffsets.sorted() {
            let remaining = max(0, idle + offset - ProcessInfo.processInfo.systemUptime)
            if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            PerfTrace.event("memory.checkpoint", ["secondsAfterReportedIdle": offset, "actualSecondsAfterReportedIdle": ProcessInfo.processInfo.systemUptime - idle, "reportedPreparationIdle": store.readingPreparationState.current == nil])
            foreground("memory-" + String(Int(offset)))
            PerfTrace.sampleResources("checkpoint-" + String(Int(offset)))
        }
        PerfTrace.event("run.completed", ["noQuery": !store.isQueryBusy, "noAnalysis": !store.isSmartReadingRunning, "pixelFirstScreenMeasured": false])
        PerfTrace.flush()
        if !config.hold { heartbeat?.cancel(); NSApp.terminate(nil) }
    }
    private static func fail(_ reason: String) -> Never {
        PerfTrace.event("run.failed", ["reason": reason]); PerfTrace.flush(); exit(2)
    }
}

struct PerfWindowProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) {}
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            PerfProbe.attach(window)
        }
    }
}
