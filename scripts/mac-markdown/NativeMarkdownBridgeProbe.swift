import AppKit
import SwiftUI
import WebKit
import CryptoKit
@testable import ReadingBook
@testable import ReadingCore

// Correctness diagnostic: links the actual product without exposing the
// private MarkdownWebView/Coordinator/State or copying their implementation.
private final class BridgeMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func set(_ value: Any?, forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = value }
}

@MainActor private final class BridgeModel: ObservableObject {
    @Published var markdown: String
    @Published var source: String
    @Published var directory: URL?
    @Published var decorations: [SourceReadingDecoration]
    @Published var focusedID: String?
    @Published var plainText = false
    @Published var dark = false
    @Published var mounted = true
    let typography = ReadingTypographySettings(defaults: BridgeMemoryDefaults())
    // Receipts do not publish SwiftUI changes themselves.
    var selection: RenderedMarkdownSelection?
    var sourceSelection: SourceReadingSelection?
    var selections: [RenderedMarkdownSelection] = []
    var saved: [RenderedMarkdownSelection] = []
    var sourceEvents = 0
    var taps: [String] = []
    var hovers: [SourceReadingHover] = []
    var links: [URL] = []
    init(markdown: String, directory: URL?, decorations: [SourceReadingDecoration]) {
        self.markdown = markdown; source = markdown; self.directory = directory; self.decorations = decorations
    }
}

@MainActor private struct BridgeHost: View {
    @ObservedObject var model: BridgeModel
    var body: some View {
        ScrollView {
            if model.mounted {
                RichMarkdownView(markdown: model.markdown, baseDirectory: model.directory,
                    onSelectionChange: { model.selection = $0; if let value = $0 { model.selections.append(value) } },
                    onSelectionSave: { model.saved.append($0) }, sourceText: model.source,
                    plainText: model.plainText, sourceDecorations: model.decorations,
                    focusedDecorationID: model.focusedID,
                    onSourceDecorationTap: { model.taps.append($0) },
                    onSourceSelection: { model.sourceSelection = $0; model.sourceEvents += 1 },
                    onSourceDecorationHover: { if let value = $0 { model.hovers.append(value) } })
                    .readingTextContext(.source).padding(16)
            }
        }
        .environmentObject(model.typography)
        .environment(\.colorScheme, model.dark ? .dark : .light)
        .environment(\.openURL, OpenURLAction { model.links.append($0); return .handled })
    }
}

@MainActor private final class BridgeApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await NativeMarkdownBridgeProbe.run(CommandLine.arguments) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main @MainActor enum NativeMarkdownBridgeProbe {
    private static var applicationDelegate: BridgeApplicationDelegate?
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(CommandLine.arguments.last == "--show-window" ? .regular : .prohibited)
        let delegate = BridgeApplicationDelegate(); applicationDelegate = delegate
        application.delegate = delegate; application.run()
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
    }
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func webViews(_ view: NSView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }
    private static func js(_ web: WKWebView, _ body: String, _ arguments: [String: Any] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in continuation.resume(with: result) }
        }
    }
    private static func object(_ web: WKWebView, _ body: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        guard let result = try await js(web, body, arguments) as? [String: Any] else { throw Failure(message: "Expected dictionary from real WK document") }
        return result
    }
    private static func pump(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        // Drain an owned AppKit run-loop turn like HostedNoteUndoProbe, rather
        // than treating Task.sleep as native window layout delivery.
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.015))
    }
    private static func wait(_ label: String, host: NSView, seconds: Double = 15, _ predicate: () async throws -> Bool) async throws {
        let end = ContinuousClock.now + .milliseconds(Int64(seconds * 1_000))
        while ContinuousClock.now < end {
            pump(host)
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw Failure(message: "Timed out: " + label)
    }
    private static func settle(_ host: NSView) async throws {
        for _ in 0..<10 { pump(host); try await Task.sleep(for: .milliseconds(30)) }
    }
    private static func truth(_ value: Any?) -> Bool { (value as? NSNumber)?.boolValue == true }
    private static func count(_ web: WKWebView, method: String) async throws -> Int {
        (try await js(web, "return window.__bridgeProbeCalls.filter(item => item.method === method).length", ["method": method]) as? NSNumber)?.intValue ?? -1
    }
    private static func snapshot(_ web: WKWebView, label: String, directory: URL) async throws -> [String: Any] {
        var value = try await object(web, "return window.ReadingBookBridgeObservations.describe()")
        if let html = value["html"] as? String { value["htmlUTF8SHA256"] = hash(html); value["htmlUTF8Bytes"] = html.utf8.count }
        if let text = value["text"] as? String { value["textUTF8SHA256"] = hash(text); value["textUTF8Bytes"] = text.utf8.count }
        let path = directory.appendingPathComponent(label + ".json")
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: path, options: .atomic)
        value.removeValue(forKey: "html"); value.removeValue(forKey: "text"); value["evidence"] = path.lastPathComponent
        return value
    }
    private static func liveSelection(_ text: String, model: BridgeModel, web: WKWebView, host: NSView) async throws {
        let previous = model.selections.count
        _ = try await js(web, "return window.ReadingBookBridgeObservations.selectUniqueText(text)", ["text": text])
        try await wait("actual selection callback for " + text, host: host) { model.selections.count > previous && model.selection?.text.utf8.elementsEqual(text.utf8) == true }
    }
    private static func clearSelection(_ web: WKWebView, host: NSView) async throws {
        _ = try await js(web, "window.getSelection().removeAllRanges(); return true"); try await settle(host)
    }
    private static func ownSaveMenu(_ web: WKWebView) throws -> (NSMenu, NSMenuItem) {
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: web.window?.windowNumber ?? 0,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0) else { throw Failure(message: "Cannot construct owned local menu event") }
        let menu = NSMenu(title: "Owned Markdown save action")
        // Actual WK subclass callback, no OS injection or menu popup.
        web.willOpenMenu(menu, with: event)
        guard let item = menu.items.first(where: { $0.title == "保存选区为语义摘记…" }) else { throw Failure(message: "Actual Markdown save item missing") }
        return (menu, item)
    }
    private static func invoke(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }; return NSApp.sendAction(action, to: item.target, from: item)
    }
    private static func allTrue(_ result: [String: Any]) -> Bool { !result.isEmpty && result.values.allSatisfy(truth) }

    static func run(_ arguments: [String]) async {
        guard arguments.count == 4 || arguments.count == 5 else {
            fputs("Usage: NativeMarkdownBridgeProbe WORKSPACE NEW_OUTPUT_DIRECTORY DOM_OBSERVER [--show-window]\n", stderr); exit(2)
        }
        let root = URL(fileURLWithPath: arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
        let output = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        let observer = URL(fileURLWithPath: arguments[3]).standardizedFileURL.resolvingSymlinksInPath()
        var checks: [String: Bool] = [:], observations: [String: Any] = [:]
        var window: NSWindow?
        do {
            try require(output.path.hasPrefix(root.path + "/") && observer.path.hasPrefix(root.path + "/"), "All paths must stay under workspace")
            try require(!FileManager.default.fileExists(atPath: output.path), "Choose a new output directory; never overwrite evidence")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            _ = NSApplication.shared
            let foreground = arguments.last == "--show-window"
            NSApp.setActivationPolicy(foreground ? .regular : .prohibited)
            let imagesA = output.appendingPathComponent("images-a"), imagesB = output.appendingPathComponent("images-b")
            for path in [imagesA, imagesB] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
            // Distinct valid rasters prove directory changes cannot reuse a grant.
            for (folder, width) in [(imagesA, 2), (imagesB, 3)] {
                let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 2,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                let color = NSColor(deviceRed: 0.15, green: 0.35, blue: 0.8, alpha: 1)
                for x in 0..<width { for y in 0..<2 { pixels.setColor(color, atX: x, y: y) } }
                try pixels.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("control.png"))
            }
            try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8).write(to: imagesA.appendingPathComponent("blocked.svg"))
            try FileManager.default.createSymbolicLink(at: imagesA.appendingPathComponent("symlink.png"), withDestinationURL: imagesA.appendingPathComponent("control.png"))
            let selectedText = "原位选择😀e\u{301}唯一词句。", secondText = "新增装饰的唯一段落。"
            let markdown = """
            # 离线桥接真实回归

            \(selectedText)

            \(secondText)

            **规范不同仍须保留** é / e\u{301}，行内 $x^2+1$。

            $$\\int_0^1 x\\,dx = \\frac{1}{2}$$

            | 中文 | 数值 |
            | --- | --- |
            | 离线 | 42 |

            ```swift
            let exact = "e\\u{301}"
            ```

            [回到原文](readingbook://book/bridge-fixture/unit/u1?quote=%E5%8E%9F%E6%96%87)
            [禁止文件链接](./not-authorized.md)

            ![authorized-control](control.png)
            ![external-blocked](https://example.invalid/image.png)
            ![traversal-blocked](../control.png)
            ![encoded-traversal-blocked](%2e%2e/control.png)
            ![svg-blocked](blocked.svg)
            ![symlink-blocked](symlink.png)
            """
            let sourceBytes = Data(markdown.utf8), sourceHash = hash(markdown)
            try sourceBytes.write(to: output.appendingPathComponent("source.md"))
            let firstRange = (markdown as NSString).range(of: selectedText, options: .literal)
            let secondRange = (markdown as NSString).range(of: secondText, options: .literal)
            let first = SourceReadingDecoration(id: "first", targetID: "u1", quote: selectedText,
                rangeLocation: firstRange.location, rangeLength: firstRange.length)
            let second = SourceReadingDecoration(id: "second", targetID: "u1", quote: secondText,
                rangeLocation: secondRange.location, rangeLength: secondRange.length)
            let model = BridgeModel(markdown: markdown, directory: imagesA, decorations: [first])
            let hosting = NSHostingView(rootView: BridgeHost(model: model))
            hosting.frame = NSRect(x: 0, y: 0, width: 850, height: 700)
            let ownedWindow = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window = ownedWindow; ownedWindow.isReleasedWhenClosed = false; ownedWindow.isRestorable = false
            ownedWindow.title = "ReadingBook isolated Markdown correctness"; ownedWindow.contentView = hosting
            if foreground {
                ownedWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await wait("owned foreground application and key window", host: hosting) {
                    NSApp.isActive && ownedWindow.isKeyWindow && ownedWindow.isVisible
                }
            }
            try await wait("one actual RichMarkdownView WKWebView", host: hosting) { webViews(hosting).count == 1 }
            guard let web = webViews(hosting).first else { throw Failure(message: "Missing actual WKWebView") }
            try await wait("actual Markdown/KaTeX/source mark and local raster", host: hosting) {
                truth(try? await js(web, "return !!window.ReadingBookMarkdown && document.querySelectorAll('.katex').length >= 2 && !!document.querySelector('[data-source-decoration=first]') && !!Array.from(document.images).find(i => i.alt === 'authorized-control' && i.complete && i.naturalWidth === 2)"))
            }
            let helper = try String(contentsOf: observer, encoding: .utf8)
            _ = try await js(web, helper + "\nreturn true")
            // Test-only call-through observation, not a renderer implementation.
            _ = try await js(web, """
            window.__bridgeProbeCalls = [];
            const real = window.ReadingBookMarkdown;
            window.ReadingBookMarkdown = Object.freeze(Object.fromEntries(Object.entries(real).map(([name, fn]) => [name, (...args) => {
              if (['render','updatePresentation','updateDecorations'].includes(name)) {
                const options = name === 'render' ? args[1] : name === 'updatePresentation' ? args[0] : args[1];
                window.__bridgeProbeCalls.push({method:name, revision:options?.revision,
                  optionFields:Object.keys(options || {}).sort(), markdown:name === 'render' ? args[0] : null,
                  sourceText:name === 'render' ? options?.sourceText : null});
              }
              return fn(...args);
            }])));
            return true;
            """)
            let initial = try await snapshot(web, label: "initial", directory: output)
            observations["initial"] = initial
            let counts = initial["counts"] as? [String: NSNumber] ?? [:]
            checks["realFixtureContainsMathTableCodeAndMarks"] = (counts["math"]?.intValue ?? 0) >= 2 && counts["tables"]?.intValue == 1 && counts["code"]?.intValue == 1 && (counts["marks"]?.intValue ?? 0) >= 1
            try await wait("symlink failure becomes placeholder", host: hosting) { truth(try? await js(web, "return Array.from(document.images).every(i => i.alt === 'authorized-control') && document.querySelectorAll('.image-placeholder').length === 5")) }
            checks["unsupportedAndUnauthorizedImagesDoNotLoad"] = true
            observations["initialNativeGeometry"] = ["webFrame": NSStringFromRect(web.frame),
                "webBounds": NSStringFromRect(web.bounds), "hostFrame": NSStringFromRect(hosting.frame),
                "windowContentFrame": NSStringFromRect(ownedWindow.contentView?.frame ?? .zero)]
            // Require the real renderer RAF -> size message -> SwiftUI Binding ->
            // native frame loop. Never send a synthetic positive size message to
            // make a throttled/inactive test fixture appear to pass.
            try await wait("automatic renderer height matches native layout", host: hosting) {
                let measured = (try? await js(web, "return Math.ceil(document.getElementById('content').getBoundingClientRect().height + 2)") as? NSNumber)?.doubleValue ?? 0
                return measured > 40 && abs(web.frame.height - measured) <= 1
            }
            observations["nativeHeightPositiveControl"] = ["nativeFrameHeight": web.frame.height,
                "source": "actual automatic renderer RAF/size/native layout", "foregroundRequested": foreground]
            checks["automaticRendererHeightMatchesNativeLayout"] = true
            try await liveSelection(selectedText, model: model, web: web, host: hosting)
            checks["realNativeSelectionExactUTF16AndBytes"] = model.sourceSelection?.isExact == true && model.sourceSelection?.rangeLocation == firstRange.location && model.sourceSelection?.rangeLength == firstRange.length && model.sourceSelection?.text.utf8.elementsEqual(selectedText.utf8) == true
            checks["nativeSelectionRetainsFullExactMarkdown"] = model.selection?.sourceMarkdown.utf8.elementsEqual(markdown.utf8) == true
            let captured = try await object(web, "return window.ReadingBookBridgeObservations.capture('presentation')")
            checks["nonemptyRealRangeBeforeStyle"] = truth(captured["liveSelection"]) && truth(captured["nonempty"])
            let (_, saveItem) = try ownSaveMenu(web)
            let savesBefore = model.saved.count
            checks["realNativeMenuActionSavesAdmittedSelection"] = saveItem.isEnabled && invoke(saveItem) && model.saved.count == savesBefore + 1 && model.saved.last?.sourceMarkdown.utf8.elementsEqual(markdown.utf8) == true
            model.dark = true; model.typography.setPointSize(23, for: .source)
            model.typography.setFamily("monospaced", for: .source)
            try await wait("true native presentation change", host: hosting) {
                truth(try? await js(web, "return document.documentElement.dataset.theme === 'dark' && document.documentElement.style.fontSize === '23px' && document.documentElement.style.fontFamily.includes('monospace')"))
            }
            try await settle(hosting)
            checks["presentationPreservesAllRealNodeAndRangeIdentities"] = allTrue(try await object(web, "return window.ReadingBookBridgeObservations.comparePresentation('presentation')"))
            checks["styleDidNotReplaceBody"] = try await count(web, method: "render") == 0

            let beforeMath = model.selections.count
            _ = try await js(web, """
            const math = document.querySelector('.math-inline');
            if (!math) throw new Error('Actual inline math missing');
            const range = document.createRange(); range.selectNodeContents(math);
            const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
            return true;
            """)
            try await wait("real math semantic selection callback", host: hosting) { model.selections.count > beforeMath && model.selection?.containsMath == true }
            checks["mathSelectionNeverClaimsExactTeXSourceRange"] = model.sourceSelection?.isExact == false && model.sourceSelection?.rangeLocation == nil && model.selection?.sourceMarkdown.utf8.elementsEqual(markdown.utf8) == true

            try await clearSelection(web, host: hosting)
            _ = try await js(web, "document.querySelector('a[href^=\"readingbook:\"]').click(); document.querySelector('[data-source-decoration=first]').click(); return true")
            try await wait("real link and mark callbacks", host: hosting) { model.links.count == 1 && model.taps == ["first"] && model.hovers.contains(where: { $0.id == "first" && $0.activated }) }
            checks["sourceAndLinkCallbacksReachProductionNativeHandlers"] = true
            let linkCount = model.links.count
            _ = try await js(web, "document.querySelector('a[data-unavailable-link]').click(); return true")
            try await settle(hosting)
            checks["unavailableFileLinkNeverOpens"] = model.links.count == linkCount

            try await liveSelection(selectedText, model: model, web: web, host: hosting)
            _ = try await js(web, "return window.ReadingBookBridgeObservations.capture('deferredDelta')")
            model.decorations = [first, second]
            try await wait("actual native decoration call", host: hosting) { try await count(web, method: "updateDecorations") > 0 }
            checks["activeRangeSurvivesDeferredDecorationUpdate"] = allTrue(try await object(web, "return window.ReadingBookBridgeObservations.comparePresentation('deferredDelta')"))
            try await clearSelection(web, host: hosting)
            try await wait("deferred desired decoration IDs eventually apply", host: hosting) {
                truth(try? await js(web, "return !!document.querySelector('[data-source-decoration=first]') && !!document.querySelector('[data-source-decoration=second]')"))
            }
            checks["deferredDeltaEventuallyApplies"] = true
            model.focusedID = "second"
            try await wait("positive focused-mark control", host: hosting) {
                truth(try? await js(web, "return !!document.querySelector('.source-focused[data-source-decoration=second]')"))
            }
            // Let the actual native focus completion settle before clearing the
            // model. No direct JS focusDecoration/DOM mutation is permitted.
            try await settle(hosting)
            checks["focusPositiveControlBeforeClear"] = truth(try await js(web, "return !!document.querySelector('.source-focused[data-source-decoration=second]')"))
            model.focusedID = nil
            try await Task.sleep(for: .milliseconds(500)); pump(hosting)
            checks["clearingFocusRemovesRealDOMHighlight"] = truth(try await js(web, "return document.querySelectorAll('.source-focused').length === 0"))
            observations["afterFocusClear"] = try await snapshot(web, label: "after-focus-clear", directory: output)
            model.decorations = [first]
            try await wait("removed mark cannot be resurrected by focus/batch", host: hosting) {
                truth(try? await js(web, "return !document.querySelector('[data-source-decoration=second]') && !document.querySelector('.source-focused[data-source-decoration=second]')"))
            }
            checks["removedFocusAndMarkStayRemoved"] = true

            try await liveSelection(selectedText, model: model, web: web, host: hosting)
            guard let admitted = model.selection else { throw Failure(message: "Admitted selection missing") }
            let (_, oldItem) = try ownSaveMenu(web)
            _ = try await js(web, "return window.ReadingBookBridgeObservations.capture('unicodeReplacement')")
            model.markdown = markdown.replacingOccurrences(of: "**规范不同仍须保留** é", with: "**规范不同仍须保留** e\u{301}")
            // Keep sourceText unchanged here: a changed source cannot accidentally
            // make a broken Markdown canonical-equality gate appear to pass.
            try await wait("byte-distinct Unicode forces a full render", host: hosting) { try await count(web, method: "render") > 0 }
            try await settle(hosting)
            checks["canonicalEquivalentBytesForceFullReplacement"] = allTrue(try await object(web, "return window.ReadingBookBridgeObservations.compareReplacement('unicodeReplacement')"))
            let savedBeforeStale = model.saved.count
            _ = invoke(oldItem)
            checks["oldNativeMenuActionCannotSaveAfterReplacement"] = model.saved.count == savedBeforeStale
            let callbacksBeforeStale = model.selections.count, tapsBeforeStale = model.taps.count, hoversBeforeStale = model.hovers.count
            let heightBeforeStale = web.frame.height
            _ = try await js(web, """
            window.webkit.messageHandlers.readingbookSelection.postMessage({text:'STALE',containsMath:false,sourceLocation:0,sourceLength:5,revision:old});
            window.webkit.messageHandlers.readingbookSourceTap.postMessage({id:'first',revision:old});
            window.webkit.messageHandlers.readingbookSourceHover.postMessage({id:'first',rect:{x:1,y:1,width:20,height:20},activated:true,revision:old});
            window.webkit.messageHandlers.readingbookSize.postMessage({height:99999,revision:old});
            return true;
            """, ["old": admitted.revision])
            try await settle(hosting)
            checks["staleSelectionAndTapMessagesRejected"] = model.selections.count == callbacksBeforeStale && model.taps.count == tapsBeforeStale
            checks["staleHoverAndHeightMessagesRejected"] = model.hovers.count == hoversBeforeStale && abs(web.frame.height - heightBeforeStale) <= 1
            let beforeSourceChange = try await count(web, method: "render")
            model.source = model.markdown + "\nSOURCE-ONLY-CHANGE"
            try await wait("source-only change forces replacement", host: hosting) { try await count(web, method: "render") > beforeSourceChange }
            checks["sourceOnlyChangeCannotReuseOldMapping"] = true
            let beforePlain = try await count(web, method: "render")
            model.plainText = true
            try await wait("plain-text mode replaces Markdown body", host: hosting) {
                let replaced = try await count(web, method: "render") > beforePlain
                let literal = truth(try? await js(web, "return document.querySelectorAll('.katex,table,pre code').length === 0 && document.getElementById('content').textContent.includes('$x^2+1$')"))
                return replaced && literal
            }
            checks["plainTextModeDoesNotReuseMarkdownOrMathDOM"] = true
            model.plainText = false; model.source = model.markdown
            try await wait("restored Markdown positive image control", host: hosting) {
                truth(try? await js(web, "return document.querySelectorAll('.katex').length >= 2 && Array.from(document.images).some(i => i.alt === 'authorized-control' && i.complete && i.naturalWidth === 2)"))
            }
            let beforeDirectory = try await count(web, method: "render")
            model.directory = imagesB
            try await wait("new authorized directory loads different raster bytes", host: hosting) {
                let replaced = try await count(web, method: "render") > beforeDirectory
                let newBytes = truth(try? await js(web, "return Array.from(document.images).some(i => i.alt === 'authorized-control' && i.complete && i.naturalWidth === 3)"))
                return replaced && newBytes
            }
            checks["sameImageNameDoesNotReuseOldDirectoryGrant"] = true
            model.directory = nil
            try await wait("revoked directory becomes placeholders", host: hosting) {
                truth(try? await js(web, "return document.images.length === 0 && document.querySelectorAll('.image-placeholder').length === 6"))
            }
            checks["revocationCannotRetainPriorImage"] = true

            // Queue real model reconciliations without awaiting each JS call.
            for index in 0..<32 {
                model.markdown = markdown + "\n\nRAPID-BODY-\(index)"
                model.source = model.markdown; model.dark = index % 2 == 0
                model.typography.setPointSize(Double(18 + index % 8), for: .source)
                hosting.layoutSubtreeIfNeeded(); await Task.yield()
            }
            model.markdown = markdown + "\n\nRAPID-FINAL-EXACT"
            model.source = model.markdown; model.dark = true
            model.typography.setPointSize(29, for: .source)
            try await wait("rapid mixed body/style reaches exact final state", host: hosting) {
                truth(try? await js(web, "return document.getElementById('content').textContent.includes('RAPID-FINAL-EXACT') && !document.getElementById('content').textContent.includes('RAPID-BODY-') && document.documentElement.dataset.theme === 'dark' && document.documentElement.style.fontSize === '29px'"))
            }
            try await settle(hosting)
            let callRecords = try await js(web, "return window.__bridgeProbeCalls")
            observations["productionRendererCalls"] = callRecords
            observations["final"] = try await snapshot(web, label: "final", directory: output)
            checks["rapidMixedUpdatesReachLastExactState"] = true
            if let records = callRecords as? [[String: Any]], let lastRender = records.last(where: { $0["method"] as? String == "render" }) {
                checks["lastFullRenderHasAllExactBodyAndSourceBytes"] = (lastRender["markdown"] as? String)?.utf8.elementsEqual(model.markdown.utf8) == true && (lastRender["sourceText"] as? String)?.utf8.elementsEqual(model.source.utf8) == true
            } else { checks["lastFullRenderHasAllExactBodyAndSourceBytes"] = false }
            let callbacksAtUnmount = model.selections.count + model.sourceEvents + model.taps.count + model.hovers.count + model.saved.count
            model.mounted = false
            try await wait("actual representable teardown", host: hosting) { webViews(hosting).isEmpty }
            try await settle(hosting)
            let settledCallbacks = model.selections.count + model.sourceEvents + model.taps.count + model.hovers.count + model.saved.count
            try await Task.sleep(for: .milliseconds(300))
            checks["noLateNativeCallbacksAfterDismantle"] = settledCallbacks == model.selections.count + model.sourceEvents + model.taps.count + model.hovers.count + model.saved.count
            observations["callbacksAtUnmountRequest"] = callbacksAtUnmount; observations["callbacksAfterTeardownSettled"] = settledCallbacks
            checks["fixtureSourceFilePreserved"] = try Data(contentsOf: output.appendingPathComponent("source.md")) == sourceBytes
            observations["fixtureSourceSHA256"] = sourceHash
            observations["fixtureSourceUTF8Bytes"] = sourceBytes.count
            observations["windowVisible"] = ownedWindow.isVisible
            observations["applicationActive"] = NSApp.isActive
            observations["observerSHA256"] = hash(helper)
            observations["scope"] = "real RichMarkdownView/WK DOM/native callback/menu; programmatic DOM range/events; no physical gestures, network, AppStore, real library, FPS or performance claim"
        } catch { observations["error"] = error.localizedDescription }
        window?.close()
        let passed = observations["error"] == nil && !checks.isEmpty && checks.values.allSatisfy { $0 }
        let result: [String: Any] = ["passed": passed, "checks": checks, "observations": observations,
            "pid": ProcessInfo.processInfo.processIdentifier]
        if FileManager.default.fileExists(atPath: output.path) {
            try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("result.json"), options: .atomic)
        }
        if !passed { fputs("Native Markdown bridge regression failed; inspect workspace result.json\n", stderr) }; exit(passed ? 0 : 1)
    }
}
