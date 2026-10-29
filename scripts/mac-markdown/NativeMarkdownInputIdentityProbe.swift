import AppKit
import SwiftUI
import WebKit
import CryptoKit
@testable import ReadingBook
@testable import ReadingCore

private final class InputMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let gate = NSLock()
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { gate.lock(); defer { gate.unlock() }; return values[key] }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func set(_ value: Any?, forKey key: String) { gate.lock(); defer { gate.unlock() }; values[key] = value }
}
@MainActor private final class InputReceipts {
    var selections: [RenderedMarkdownSelection] = []
    var sources: [SourceReadingSelection] = []
}
@MainActor private final class InputModel: ObservableObject {
    @Published var markdown: String
    @Published var source: String
    @Published var dark = false
    let callbacksEnabled: Bool
    let setterPath: Bool
    let typography = ReadingTypographySettings(defaults: InputMemoryDefaults())
    let receipts: InputReceipts
    let selectionCallback: (RenderedMarkdownSelection?) -> Void
    let sourceCallback: (SourceReadingSelection?) -> Void
    var bodyPasses = 0
    init(body: String, callbacks: Bool, setter: Bool) {
        markdown = body; source = body; callbacksEnabled = callbacks; setterPath = setter
        let holder = InputReceipts(); receipts = holder
        // Allocate callback contexts exactly once, outside body.
        selectionCallback = { if let selection = $0 { holder.selections.append(selection) } }
        sourceCallback = { if let selection = $0 { holder.sources.append(selection) } }
    }
}
@MainActor private struct InputSurface: View {
    @ObservedObject var model: InputModel
    private var rendered: RichMarkdownView {
        if model.setterPath {
            var value = RichMarkdownView(markdown: model.markdown,
                onSelectionChange: model.callbacksEnabled ? model.selectionCallback : nil)
            value.sourceText = model.source
            value.onSourceSelection = model.callbacksEnabled ? model.sourceCallback : nil
            return value
        }
        return RichMarkdownView(markdown: model.markdown,
            onSelectionChange: model.callbacksEnabled ? model.selectionCallback : nil,
            sourceText: model.source,
            onSourceSelection: model.callbacksEnabled ? model.sourceCallback : nil)
    }
    var body: some View {
        let _ = model.bodyPasses += 1
        ScrollView { rendered.readingTextContext(.source).padding(16) }
            .environmentObject(model.typography).preferredColorScheme(model.dark ? .dark : .light)
    }
}
@MainActor private final class InputDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await NativeMarkdownInputIdentityProbe.run() } }
}
@main @MainActor enum NativeMarkdownInputIdentityProbe {
    private static var delegate: InputDelegate?
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let value = InputDelegate(); delegate = value; app.delegate = value; app.run()
    }
    private static func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func exact(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    private static func views(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(views) }
    private static func js(_ web: WKWebView, _ script: String, _ arguments: [String: Any] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { continuation.resume(with: $0) }
        }
    }
    private static func truth(_ value: Any?) -> Bool { (value as? NSNumber)?.boolValue == true }
    private static func wait(_ label: String, _ predicate: () async throws -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < end {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw Failure(message: "Timed out: " + label)
    }
    private static func body(_ token: String) -> String { "# 输入原始字节\n\n身份 " + token + " 唯一位置。\n\n稳定句子。\n\n$x^2$\n" }
    private static func runCase(name: String, target: String, oldBody: String, newBody: String,
                                callbacks: Bool, setter: Bool, window: NSWindow,
                                helper: String, output: URL) async throws -> [String: Any] {
        let model = InputModel(body: oldBody, callbacks: callbacks, setter: setter)
        let hosting = NSHostingView(rootView: InputSurface(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 850, height: 700)
        window.contentView = hosting; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait(name + ".foreground") { NSApp.isActive && window.isKeyWindow && window.isVisible }
        try await wait(name + ".actual WK") { views(hosting).count == 1 }
        guard let web = views(hosting).first else { throw Failure(message: "Real WK view absent") }
        try await wait(name + ".initial math and automatic height") {
            truth(try? await js(web, "return !!window.ReadingBookMarkdown && document.querySelectorAll('.katex').length === 1")) && web.frame.height > 40
        }
        _ = try await js(web, helper + "\nreturn true")
        _ = try await js(web, "return window.ReadingBookBridgeObservations.capture('input')")
        // Actual production API call-through observation after first full render.
        _ = try await js(web, """
        window.__inputCalls = [];
        const real = window.ReadingBookMarkdown;
        window.ReadingBookMarkdown = Object.freeze(Object.fromEntries(Object.entries(real).map(([name, fn]) => [name, (...args) => {
          if (name === 'render') window.__inputCalls.push({method:name,markdown:args[0],sourceText:args[1]?.sourceText,revision:args[1]?.revision});
          if (name === 'updatePresentation') window.__inputCalls.push({method:name,theme:args[0]?.theme,revision:args[0]?.revision});
          return fn(...args);
        }])));
        return true;
        """)
        let passesBefore = model.bodyPasses
        if target == "markdown" { model.markdown = newBody } else { model.source = newBody }
        model.dark = true
        try await wait(name + ".real native presentation response") {
            truth(try? await js(web, "return document.documentElement.dataset.theme === 'dark' && window.__inputCalls.some(call => call.method === 'updatePresentation' || call.method === 'render')"))
        }
        // Retain any late full render; this is correctness, not a timing sample.
        try await Task.sleep(for: .milliseconds(500))
        let calls = try await js(web, "return window.__inputCalls") as? [[String: Any]] ?? []
        let renders = calls.filter { $0["method"] as? String == "render" }
        let expectedMarkdown = target == "markdown" ? newBody : oldBody
        let expectedSource = target == "sourceText" ? newBody : oldBody
        let last = renders.last
        let expectations: [String: Bool] = [
            "host-body-reran": model.bodyPasses > passesBefore,
            "full-render-delivered": !renders.isEmpty,
            "exact-markdown-delivered": (last?["markdown"] as? String).map { exact($0, expectedMarkdown) } == true,
            "exact-source-delivered": (last?["sourceText"] as? String).map { exact($0, expectedSource) } == true]
        var row: [String: Any] = ["name": name, "target": target, "callbacks": callbacks ? "stored-once" : "all-nil",
            "inputAPI": setter ? "sourceText-setter" : "initializer",
            "oldUTF8Bytes": oldBody.utf8.count, "newUTF8Bytes": newBody.utf8.count,
            "oldSHA256": sha(oldBody), "newSHA256": sha(newBody), "canonicalEqual": oldBody == newBody,
            "bodyPassesBefore": passesBefore, "bodyPassesAfter": model.bodyPasses,
            "calls": calls, "actualRenderCount": renders.count, "checks": expectations,
            "expectedMarkdownSHA256": sha(expectedMarkdown), "expectedSourceSHA256": sha(expectedSource)]
        row["replacementDOM"] = try await js(web, "return window.ReadingBookBridgeObservations.compareReplacement('input')")
        if callbacks {
            let receipts = model.receipts.selections.count
            _ = try await js(web, "return window.ReadingBookBridgeObservations.selectUniqueText(text)", ["text": "稳定句子。"])
            try await wait(name + ".actual stable callback") { model.receipts.selections.count > receipts }
            row["nativeSelectionMarkdownSHA256"] = model.receipts.selections.last.map { sha($0.sourceMarkdown) } ?? "none"
            row["nativeSourceRangeLocation"] = model.receipts.sources.last?.rangeLocation ?? -1
            row["expectedSourceRangeLocation"] = (expectedSource as NSString).range(of: "稳定句子。", options: .literal).location
        }
        let snapshot = try await js(web, "return window.ReadingBookBridgeObservations.describe()")
        try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]).write(to: output.appendingPathComponent(name + "-dom.json"))
        // Fresh model/host next case; never per-change .id reset.
        window.contentView = nil
        try await Task.sleep(for: .milliseconds(100))
        return row
    }
    static func run() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 || arguments.count == 5 else { exit(2) }
        let root = URL(fileURLWithPath: arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
        let output = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        let observer = URL(fileURLWithPath: arguments[3]).standardizedFileURL.resolvingSymlinksInPath()
        var rows: [[String: Any]] = [], checks: [String: Bool] = [:], failure: String?
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 850, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isRestorable = false
        window.title = "ReadingBook raw Unicode input regression (owned)"
        do {
            guard output.path.hasPrefix(root.path + "/"), observer.path.hasPrefix(root.path + "/"),
                  !FileManager.default.fileExists(atPath: output.path) else { throw Failure(message: "New workspace output required") }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let helper = try String(contentsOf: observer, encoding: .utf8)
            let variants = [("ascii-control", "A", "B", false),
                ("canonical-length-change", "é", "e\u{301}", true),
                ("canonical-same-length-reorder", "a\u{301}\u{323}", "a\u{323}\u{301}", true)]
            for setter in [false, true] {
                for callbacks in [true, false] {
                    for target in ["markdown", "sourceText"] {
                        for (variant, old, new, canonical) in variants {
                            let name = (setter ? "setter" : "init") + "-" + (callbacks ? "stable-callback" : "no-callback") + "-" + target + "-" + variant
                            let oldBody = body(old), newBody = body(new)
                            checks[name + ".fixture-byte-distinct"] = !exact(oldBody, newBody)
                            checks[name + ".fixture-canonical-control"] = (oldBody == newBody) == canonical
                            if variant == "canonical-same-length-reorder" { checks[name + ".same-UTF8-length"] = oldBody.utf8.count == newBody.utf8.count }
                            let row = try await runCase(name: name, target: target, oldBody: oldBody, newBody: newBody,
                                callbacks: callbacks, setter: setter, window: window, helper: helper, output: output)
                            if let values = row["checks"] as? [String: Bool] { for (key, value) in values { checks[name + "." + key] = value } }
                            rows.append(row)
                        }
                    }
                }
            }
        } catch { failure = error.localizedDescription }
        window.close()
        let passed = failure == nil && rows.count == 24 && !checks.isEmpty && checks.values.allSatisfy { $0 }
        var result: [String: Any] = ["passed": passed, "checks": checks, "cases": rows,
            "pid": ProcessInfo.processInfo.processIdentifier, "productionModifiedByProbe": false,
            "scope": "actual RichMarkdownView init/setter, stored-once/all-nil callbacks, exact input bytes and real native API call-through; correctness only"]
        if let failure { result["failure"] = failure }
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        exit(passed ? 0 : 1)
    }
}
