import AppKit
import SwiftUI
import WebKit
import CryptoKit
@testable import ReadingBook
@testable import ReadingCore

// Native bounded-idle correctness probe, V7: absolute input pacing and pre-assertion timing witnesses.
// No shipping test API, private Coordinator access, AppStore, AI or clipboard.
private final class BoundedIdleDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func set(_ value: Any?, forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = value }
}
@MainActor private final class BoundedIdleReceipts {
    var selection: RenderedMarkdownSelection?
    var sourceSelection: SourceReadingSelection?
    var selections: [RenderedMarkdownSelection] = []
    var saved: [RenderedMarkdownSelection] = []
    var selectionEvents = 0
    var sourceEvents = 0
    var taps: [String] = []
    var hovers: [SourceReadingHover] = []
    var links: [URL] = []
    var linkTokens: [Int] = []
    var total: Int { selectionEvents + sourceEvents + saved.count + taps.count + hovers.count + links.count }
}
@MainActor private final class BoundedIdleModel: ObservableObject {
    @Published var markdown: String
    @Published var source: String
    @Published var directory: URL?
    @Published var decorations: [SourceReadingDecoration]
    @Published var focusedID: String?
    @Published var plainText = false
    @Published var dark = false
    @Published var active = true
    @Published var selectionCallbacksEnabled = true
    @Published var saveEnabled = true
    @Published var mounted = true
    @Published var independentPresented = false
    var outerHeight: CGFloat = 0
    @Published var refreshToken = 0
    @Published var independentOverride: Bool? = true
    let independentReceipts = BoundedIdleReceipts()
    var independentActivityValues: [Bool] = []
    let typography = ReadingTypographySettings(defaults: BoundedIdleDefaults())
    let receipts: BoundedIdleReceipts
    let selectionCallback: (RenderedMarkdownSelection?) -> Void
    let sourceCallback: (SourceReadingSelection?) -> Void
    let saveCallback: (RenderedMarkdownSelection) -> Void
    let tapCallback: (String) -> Void
    let hoverCallback: (SourceReadingHover?) -> Void
    var bodyPasses = 0
    var selection: RenderedMarkdownSelection? { receipts.selection }
    var sourceSelection: SourceReadingSelection? { receipts.sourceSelection }
    var selections: [RenderedMarkdownSelection] { receipts.selections }
    var saved: [RenderedMarkdownSelection] { receipts.saved }
    init(markdown: String, directory: URL?, decorations: [SourceReadingDecoration]) {
        self.markdown = markdown; source = markdown; self.directory = directory; self.decorations = decorations
        let holder = BoundedIdleReceipts(); receipts = holder
        selectionCallback = { holder.selection = $0; holder.selectionEvents += 1; if let value = $0 { holder.selections.append(value) } }
        sourceCallback = { holder.sourceSelection = $0; holder.sourceEvents += 1 }
        saveCallback = { holder.saved.append($0) }
        tapCallback = { holder.taps.append($0) }
        hoverCallback = { if let value = $0 { holder.hovers.append(value) } }
    }
}
private struct BoundedIdleHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
@MainActor private struct BoundedIdleHost: View {
    @ObservedObject var model: BoundedIdleModel
    var body: some View {
        let _ = model.bodyPasses += 1
        let token = model.refreshToken
        ScrollView {
            if model.mounted {
                RichMarkdownView(markdown: model.markdown, baseDirectory: model.directory,
                    onSelectionChange: model.selectionCallbacksEnabled ? model.selectionCallback : nil,
                    onSelectionSave: model.saveEnabled ? model.saveCallback : nil,
                    sourceText: model.source, plainText: model.plainText,
                    sourceDecorations: model.decorations, focusedDecorationID: model.focusedID,
                    onSourceDecorationTap: model.tapCallback,
                    onSourceSelection: model.selectionCallbacksEnabled ? model.sourceCallback : nil,
                    onSourceDecorationHover: model.hoverCallback)
                    .readingTextContext(.source)
                    .background { GeometryReader { g in Color.clear.preference(key: BoundedIdleHeightKey.self, value: g.size.height) } }
                    .onPreferenceChange(BoundedIdleHeightKey.self) { model.outerHeight = $0 }
                    .padding(16).opacity(model.active ? 1 : 0).allowsHitTesting(model.active)
                    .environment(\.isReaderPanelActive, model.active)
            }
        }
        .environmentObject(model.typography)
        .environment(\.colorScheme, model.dark ? .dark : .light)
        .environment(\.openURL, OpenURLAction { model.receipts.links.append($0); model.receipts.linkTokens.append(token); return .handled })
        .sheet(isPresented:$model.independentPresented) {
            BoundedIdleIndependentPreview(model:model)
                .environmentObject(model.typography)
                // Explicitly supply the inherited inactive presenter state;
                // the renderer override must not mutate this input authority.
                .environment(\.isReaderPanelActive,model.active)
                .environment(\.colorScheme,model.dark ? .dark : .light)
        }
    }
}
@MainActor private struct BoundedIdleIndependentPreview: View {
    @ObservedObject var model: BoundedIdleModel
    @Environment(\.isReaderPanelActive) private var inheritedActive
    var body: some View {
        VStack(spacing:0) {
            Text("Owned independently visible preview").frame(height:36)
            ScrollView {
                RichMarkdownView(markdown:model.markdown,baseDirectory:model.directory,
                    onSelectionChange:{ value in
                        model.independentReceipts.selection = value
                        model.independentReceipts.selectionEvents += 1
                        if let value { model.independentReceipts.selections.append(value) }
                    },sourceText:model.source,plainText:model.plainText,sourceDecorations:model.decorations,
                    onSourceSelection:{ value in
                        model.independentReceipts.sourceSelection = value
                        model.independentReceipts.sourceEvents += 1
                    },presentationActiveOverride:model.independentOverride)
                    .readingTextContext(.source).padding(16)
            }
        }.frame(width:620,height:480)
            .onAppear { model.independentActivityValues.append(inheritedActive) }
            .onChange(of:inheritedActive) { _,value in model.independentActivityValues.append(value) }
    }
}
@MainActor private final class BoundedIdleDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await NativeMarkdownBoundedIdleProbe.run(CommandLine.arguments) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main @MainActor enum NativeMarkdownBoundedIdleProbe {
    private static var delegate: BoundedIdleDelegate?
    static let checkNames: [String] = ["firstAndReplacedDocumentRequireActualAcknowledgementWithoutCSSIdle", "idle120FlushesLatestExactPresentationAndPreservesDocument", "continuousChangesFlushByFirst250WindowWithoutStarvation", "sameTupleActualNativeRefreshDoesNotResetIdle", "deadlineDuringRealWebKitFlightStaysDueAndFlushesAtNextSlot", "activeAndRealFocusSetClearBypassIdle", "sourceDirectoryPlainDecorationAndSelectionPermissionDoNotWait", "saveOnlyRevocationImmediatelyDisablesCapturedNativeAction", "oldGenerationCannotReapplyOldSourceAfterReplacement", "nativeFailureAndDismantleCancelAllPendingWakes", "independentSheetOverridePreservesInactiveParentAndDeniedSave", "visibleAndNotesLeafScopesRemainExactInCompiledSource"]
    static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let value=BoundedIdleDelegate();delegate=value;app.delegate=value;app.run()
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
    private static func liveSelection(_ text: String, model: BoundedIdleModel, web: WKWebView, host: NSView) async throws {
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

    private static func exact(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    private static func records(_ web: WKWebView) async throws -> [[String: Any]] {
        guard let value = try await js(web, "return window.__bridgeProbeCalls") as? [[String: Any]] else {
            throw Failure(message: "Actual renderer call witness missing")
        }
        return value
    }
    private static func exactLastRender(_ web: WKWebView, markdown: String, source: String) async throws -> Bool {
        guard let last = try await records(web).last(where: { $0["method"] as? String == "render" }),
              let actualMarkdown = last["markdown"] as? String, let actualSource = last["sourceText"] as? String else { return false }
        return exact(actualMarkdown, markdown) && exact(actualSource, source)
    }
    private static func css(_ web: WKWebView) async throws -> [String: Any] {
        try await object(web, "return {theme:document.documentElement.dataset.theme,fontSize:document.documentElement.style.fontSize,fontFamily:document.documentElement.style.fontFamily}")
    }
    private static func freshMenu(_ web: WKWebView) throws -> NSMenu {
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: web.window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0) else { throw Failure(message: "Cannot create owned menu event") }
        let menu = NSMenu(title: "Hidden presentation owned menu"); web.willOpenMenu(menu, with: event); return menu
    }
    private static func retained(_ item: NSMenuItem, cannotSave model: BoundedIdleModel) -> Bool {
        let before = model.saved.count; _ = invoke(item); return model.saved.count == before
    }
    private static func callbackSourceIsExact(_ model: BoundedIdleModel, text: String) -> Bool {
        let range = (model.source as NSString).range(of: text, options: .literal)
        return range.location != NSNotFound && model.sourceSelection?.isExact == true
            && model.sourceSelection?.rangeLocation == range.location && model.sourceSelection?.rangeLength == range.length
            && model.sourceSelection.map { exact($0.text, text) } == true
            && model.selection.map { exact($0.sourceMarkdown, model.markdown) } == true
    }
    private static func finalDOMEqualsActualRenderer(_ web: WKWebView, markdown: String, source: String, revision: Int) async throws -> Bool {
        truth(try await js(web, """
        const actual=document.getElementById('content'), control=document.createElement('article');
        control.innerHTML=window.ReadingBookMarkdown.renderHTML(markdown,{sourceText:source,plainText:false,
          allowImages:false,revision:revision,sourceDecorations:[]});
        // The final fixture has no decorations/focus and no directory grant.
        return actual.innerHTML === control.innerHTML;
        """, ["markdown": markdown, "source": source, "revision": revision]))
    }

    private static func rawField(_ owner: Any, _ name: String) throws -> Any {
        let entries = Mirror(reflecting: owner).children.filter { $0.label == name }
        guard entries.count == 1 else { throw Failure(message: "Mirror field missing/ambiguous: " + name) }
        return entries[0].value
    }
    private static func unwrapped(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional ? mirror.children.first?.value : value
    }
    private static func field<T>(_ owner: Any, _ name: String, _ type: T.Type) throws -> T {
        guard let value = try rawField(owner, name) as? T else { throw Failure(message: "Mirror type mismatch: " + name) }
        return value
    }
    @MainActor private struct StateProof {
        let markdown: String, source: String, theme: String, family: String, style: String, context: String
        let fontSize: Double, enabled: Bool, plain: Bool
        let directory: URL?
        let decorations: [SourceReadingDecoration]
        init(_ raw: Any) throws {
            let expected = Set(["markdown", "directory", "theme", "readingStyle", "readingContext", "fontFamily", "fontSize", "selectionEnabled", "sourceText", "plainText", "decorations"])
            let labels = Mirror(reflecting: raw).children.compactMap(\.label)
            try require(labels.count == expected.count && Set(labels) == expected, "Unknown private State inventory")
            markdown = try field(raw, "markdown", String.self); source = try field(raw, "sourceText", String.self)
            theme = try field(raw, "theme", String.self); family = try field(raw, "fontFamily", String.self)
            style = try field(raw, "readingStyle", String.self); context = try field(raw, "readingContext", String.self)
            fontSize = try field(raw, "fontSize", Double.self); enabled = try field(raw, "selectionEnabled", Bool.self)
            plain = try field(raw, "plainText", Bool.self); decorations = try field(raw, "decorations", [SourceReadingDecoration].self)
            let dir = try rawField(raw, "directory")
            try require(dir is URL?, "Mirror type mismatch: directory")
            directory = dir as? URL
        }
        func equals(_ other: StateProof) -> Bool {
            exact(markdown, other.markdown) && exact(source, other.source) && theme == other.theme && family == other.family &&
                style == other.style && context == other.context && fontSize == other.fontSize && enabled == other.enabled &&
                plain == other.plain && directory == other.directory && decorations == other.decorations
        }
        var evidence: [String: Any] {
            ["markdownUTF8Base64": Data(markdown.utf8).base64EncodedString(), "sourceUTF8Base64": Data(source.utf8).base64EncodedString(),
             "theme": theme, "fontFamily": family, "fontSize": fontSize, "readingStyle": style, "readingContext": context,
             "selectionEnabled": enabled, "plainText": plain, "directory": directory?.absoluteString as Any? ?? NSNull(),
             "decorationIDs": decorations.map(\.id)]
        }
    }
    @MainActor private struct NativeProof {
        let pending: StateProof, displayed: StateProof
        let revision: Int
        let height: Double
        var evidence: [String: Any] { ["ownerVerified": true, "ready": true, "rendering": false, "pending": pending.evidence,
            "displayed": displayed.evidence, "revision": revision, "height": height] }
    }
    private static func native(_ web: WKWebView) throws -> NativeProof? {
        guard let owner = web.navigationDelegate else { return nil }
        let typeName = String(reflecting: type(of: owner))
        try require(typeName.hasSuffix("MarkdownWebView.Coordinator"), "Unexpected actual navigation owner: " + typeName)
        let rawWeb = try rawField(owner, "webView")
        guard let owned = unwrapped(rawWeb) as? WKWebView, owned === web else { throw Failure(message: "Actual owner.webView identity differs") }
        let ready = try field(owner, "ready", Bool.self), rendering = try field(owner, "rendering", Bool.self)
        let revision = try field(owner, "revision", Int.self)
        guard ready && !rendering else { return nil }
        guard let p = unwrapped(try rawField(owner, "pending")), let d = unwrapped(try rawField(owner, "displayed")) else { return nil }
        let pending = try StateProof(p), displayed = try StateProof(d)
        guard pending.equals(displayed) else { return nil }
        let height = try field(owner, "height", Binding<CGFloat>.self)
        return NativeProof(pending: pending, displayed: displayed, revision: revision, height: Double(height.wrappedValue))
    }

    private static let metricsScript = """
    const root=document.getElementById('content'), r=root.getBoundingClientRect(), sc=document.scrollingElement;
    const mark=root.querySelector('[data-source-decoration="deep"]'), m=mark?.getBoundingClientRect();
    const s=window.getSelection();
    return {articleHeight:r.height,articleTop:r.top,expectedHeight:Math.ceil(r.height+2),
      innerHeight:window.innerHeight,innerWidth:window.innerWidth,scrollX:window.scrollX,scrollY:window.scrollY,
      scrollingTop:sc?.scrollTop ?? 0,scrollingLeft:sc?.scrollLeft ?? 0,
      activeElement:document.activeElement?.tagName || '',selection:s?.toString() || '',
      deep: m ? {x:m.x,y:m.y,width:m.width,height:m.height,relativeY:m.top-r.top} : null,
      fontsReady:document.fonts.status==='loaded',theme:document.documentElement.dataset.theme,
      fontSize:document.documentElement.style.fontSize,fontFamily:document.documentElement.style.fontFamily};
    """
    private static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? .nan }
    private static func externalScroll(_ web: WKWebView) -> NSScrollView? {
        var current = web.superview
        while let view = current { if let scroll = view as? NSScrollView { return scroll }; current = view.superview }
        return nil
    }
    private static func deepActuallyVisible(_ web: WKWebView, dom: [String:Any]) -> Bool {
        guard let mark=dom["deep"] as? [String:Any], let window=web.window, let root=window.contentView else { return false }
        let x=number(mark["x"]), y=number(mark["y"]), w=number(mark["width"]), h=number(mark["height"])
        guard [x,y,w,h].allSatisfy(\.isFinite), w>0,h>0 else { return false }
        let local=NSRect(x:x,y:web.isFlipped ? y : Double(web.bounds.height)-y-h,width:w,height:h)
        let clip=web.visibleRect.intersection(web.bounds)
        guard !clip.isNull else { return false }
        let actual=web.convert(clip,to:root).intersection(root.bounds)
        let marker=web.convert(local,to:root).intersection(actual)
        return !marker.isNull && marker.width>=min(24,w*0.3) && marker.height>=min(8,h*0.3)
    }
    private static func write(_ name: String, _ value: Any, output: URL) throws {
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
            .write(to:output.appendingPathComponent(name),options:.withoutOverwriting)
    }
    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func ms(_ later: UInt64, _ earlier: UInt64) -> Double {
        later >= earlier ? Double(later-earlier)/1_000_000 : -.infinity
    }
    @MainActor private final class Events: NSObject, WKScriptMessageHandler {
        weak var web: WKWebView?
        var rows: [[String:Any]] = []
        func userContentController(_ controller: WKUserContentController,didReceive message: WKScriptMessage) {
            guard message.webView === web,message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.scheme=="readingbook-renderer",message.frameInfo.request.url?.host=="bundle",
                  message.frameInfo.request.url?.path=="/index.html",
                  let body=message.body as? [String:Any] else { return }
            var row=body;row["nativeReceivedNs"]=NativeMarkdownBoundedIdleProbe.now();rows.append(row)
        }
        func matches(_ kind:String,_ tag:String) -> [[String:Any]] {
            rows.filter{$0["kind"] as? String==kind && $0["tag"] as? String==tag}
        }
    }
    @MainActor private struct Scheduling {
        let ready:Bool, rendering:Bool, active:Bool, due:Bool
        let revision:Int, confirmed:Int?, generation:UInt64, first:UInt64?, last:UInt64, wakePresent:Bool
        let pending:StateProof?,displayed:StateProof?
        var evidence:[String:Any] {
            ["observedNs":NativeMarkdownBoundedIdleProbe.now(),"ready":ready,"rendering":rendering,"active":active,"due":due,
             "revision":revision,"confirmedRevision":confirmed as Any? ?? NSNull(),"generation":generation,
             "firstChangeNs":first as Any? ?? NSNull(),"lastChangeNs":last,"wakePresent":wakePresent,
             "pending":pending?.evidence as Any? ?? NSNull(),"displayed":displayed?.evidence as Any? ?? NSNull()]
        }
    }
    private static func scheduling(_ web:WKWebView) throws -> Scheduling {
        guard let owner=web.navigationDelegate else { throw Failure(message:"Actual coordinator owner absent") }
        try require(String(reflecting:type(of:owner)).hasSuffix("MarkdownWebView.Coordinator"),"Unexpected actual Coordinator type")
        let owned=unwrapped(try rawField(owner,"webView")) as? WKWebView
        try require(owned === web,"Mirror read belongs to another actual WK")
        func optional<T>(_ name:String,_ type:T.Type) throws -> T? {
            let raw=try rawField(owner,name)
            guard let value=unwrapped(raw) else { return nil }
            guard let typed=value as? T else { throw Failure(message:"Optional Mirror field type mismatch: "+name) }
            return typed
        }
        let p=unwrapped(try rawField(owner,"pending")),d=unwrapped(try rawField(owner,"displayed"))
        return Scheduling(ready:try field(owner,"ready",Bool.self),rendering:try field(owner,"rendering",Bool.self),
            active:try field(owner,"presentationActive",Bool.self),due:try field(owner,"presentationFlushDue",Bool.self),
            revision:try field(owner,"revision",Int.self),confirmed:try optional("confirmedDocumentRevision",Int.self),
            generation:try field(owner,"presentationGeneration",UInt64.self),first:try optional("presentationFirstChange",UInt64.self),
            last:try field(owner,"presentationLastChange",UInt64.self),wakePresent:unwrapped(try rawField(owner,"presentationWake")) != nil,
            pending:try p.map(StateProof.init),displayed:try d.map(StateProof.init))
    }
    private static func waitFast(_ label:String,host:NSView,seconds:Double=5,_ predicate:() async throws -> Bool) async throws {
        let end=ContinuousClock.now + .milliseconds(Int64(seconds*1000))
        while ContinuousClock.now<end {
            host.layoutSubtreeIfNeeded()
            if try await predicate(){return}
            try await Task.sleep(for:.milliseconds(3))
        }
        throw Failure(message:"Timed out: "+label)
    }
    private static func stable(_ web:WKWebView,model:BoundedIdleModel,host:NSView,font:Double?=nil) async throws -> NativeProof {
        var value:NativeProof?
        try await wait("real latest source/CSS and full native height",host:host) {
            guard let p=try native(web),exact(p.displayed.markdown,model.markdown),exact(p.displayed.source,model.source),
                  font.map({p.displayed.fontSize==$0}) ?? true else{return false}
            let dom=try await object(web,metricsScript)
            guard truth(dom["fontsReady"]),abs(number(dom["expectedHeight"])-p.height)<=2.5,
                  abs(Double(web.bounds.height)-p.height)<=2.5,abs(Double(model.outerHeight)-p.height)<=2.5 else{return false}
            value=p;return true
        }
        guard let value else{throw Failure(message:"Missing stable native/source proof")};return value
    }
    private static func install(_ web:WKWebView,helper:String,events:Events) async throws {
        events.web=web;web.configuration.userContentController.add(events,name:"boundedProbeEvent")
        _ = try await js(web,helper+"\nreturn true")
        _ = try await js(web,"""
        window.__bridgeProbeCalls=[];window.__boundedStage='setup';window.__boundedBusy=null;window.__boundedThrow=null;
        const original=window.ReadingBookMarkdown;
        const send=body=>window.webkit.messageHandlers.boundedProbeEvent.postMessage(body);
        window.ReadingBookMarkdown=Object.freeze(Object.fromEntries(Object.entries(original).map(([name,fn])=>[name,(...args)=>{
          const tag=window.__boundedStage,o=name==='render'?args[1]:name==='updatePresentation'?args[0]:name==='updateDecorations'?args[1]:null;
          const busy=window.__boundedBusy;
          if(busy && busy.method===name){
            window.__boundedBusy=null;send({kind:'busy-enter',tag:busy.tag,jsNow:performance.now()});
            const end=performance.now()+busy.milliseconds;while(performance.now()<end){}
            send({kind:'busy-exit',tag:busy.tag,jsNow:performance.now()});
          }
          if(window.__boundedThrow===name){window.__boundedThrow=null;send({kind:'injected-failure',tag,method:name,jsNow:performance.now()});throw new Error('Owned bounded-idle failure control')}
          const record={method:name,tag,revision:o?.revision,fontSize:o?.fontSize,theme:o?.theme,
            selectionEnabled:o?.selectionEnabled,markdown:name==='render'?args[0]:null,sourceText:name==='render'?o?.sourceText:null};
          window.__bridgeProbeCalls.push(record);
          const result=fn.apply(original,args);send({...record,markdown:null,sourceText:null,kind:'renderer',jsNow:performance.now()});
          return result;
        }])));return true;
        """)
    }
    private static func stage(_ web:WKWebView,_ value:String) async throws { _ = try await js(web,"window.__boundedStage=value;return true",["value":value]) }
    private static func firstWindow(_ web:WKWebView,model:BoundedIdleModel,host:NSView,font:Double) async throws -> Scheduling {
        model.active=false;model.typography.setPointSize(font,for:.source)
        var value:Scheduling?
        try await waitFast("actual new CSS window",host:host) {
            let p=try scheduling(web)
            guard let first=p.first,p.last>=first,p.pending?.fontSize==font,p.displayed?.fontSize != font,!p.due,!p.active else{return false}
            value=p;return true
        }
        guard let value else{throw Failure(message:"CSS window absent")};return value
    }
    private static func dispatch(_ web:WKWebView,host:NSView,font:Double) async throws -> (Scheduling,UInt64) {
        var value:Scheduling?,at:UInt64=0
        try await waitFast("actual latest tuple dispatched",host:host,seconds:3) {
            let p=try scheduling(web)
            guard p.displayed?.fontSize==font,p.first==nil else{return false}
            value=p;at=now();return true
        }
        guard let value else{throw Failure(message:"Actual dispatch readout absent")};return(value,at)
    }
    private static func markBusy(_ web:WKWebView,method:String,tag:String,fail:Bool=false) async throws {
        _ = try await js(web,"window.__boundedBusy={method,milliseconds:750,tag};window.__boundedThrow=fail?method:null;return true",
                         ["method":method,"tag":tag,"fail":fail])
    }
    private static func scope(_ source:URL,observations:inout[String:Any]) throws -> Bool {
        let names=["ReadingViews.swift","ChatSaveViews.swift","ReadingContinuationHistoryView.swift","MarkdownRenderer.swift"]
        let texts=try Dictionary(uniqueKeysWithValues:names.map{($0,try String(contentsOf:source.appendingPathComponent("Sources/ReadingBook/"+$0),encoding:.utf8))})
        guard let reading=texts["ReadingViews.swift"],let chat=texts["ChatSaveViews.swift"],let history=texts["ReadingContinuationHistoryView.swift"],
              let renderer=texts["MarkdownRenderer.swift"] else{return false}
        let leaf="MarkdownText(markdown: previewBody).readingTextContext(.notes)\n                                    .environment(\\.isReaderPanelActive, active)"
        let actual=["notesLeaf":reading.components(separatedBy:leaf).count==2,
            "nativeEditorUnchanged":reading.contains("editable: !store.isRecognizingPDF && active, visible: !preview && active)"),
            "history":chat.contains("ChatMarkdownBody(markdown: MarkdownReferenceLinks.render(message.content, bookID: project.id, project: project), presentationActiveOverride: true)"),
            "savePreview":chat.contains("context: .notes, presentationActiveOverride: true)"),
            "continuation":history.contains("RichMarkdownView(markdown: markdown, presentationActiveOverride: true)"),
            "originalFullFrame":renderer.contains("}.frame(height: max(1, contentHeight))"),
            "notNativeHidden":!renderer.contains("webView.isHidden ="),
            "boundedConstants":renderer.contains(".milliseconds(120)") && renderer.contains(".milliseconds(250)")]
        observations["staticLeafScope"]=["checks":actual,"filesSHA256":texts.mapValues(hash),"sourceRoot":source.path,
            "scope":"Static actual-source only; native Notes/Undo and existing29/152/70 remain separate mandatory regressions."]
        return actual.values.allSatisfy{$0}
    }
    private static func independent(model:BoundedIdleModel,parent:NSWindow,host:NSView,base:WKWebView,helper:String,
        output:URL,selected:String,observations:inout[String:Any]) async throws -> Bool {
        model.active=false;model.independentOverride=true;model.independentPresented=true
        var chosen:WKWebView?,modal:NSWindow?
        try await wait("actual independent sheet with real full-height WK",host:host) {
            guard let sheet=parent.attachedSheet ?? NSApp.windows.first(where:{$0.sheetParent === parent}),
                  sheet.isVisible,sheet.isKeyWindow,let content=sheet.contentView else{return false}
            let values=webViews(content)
            guard values.count==1,let web=values.first,let proof=try native(web),proof.height>1024 else{return false}
            chosen=web;modal=sheet;return true
        }
        guard let preview=chosen,let sheet=modal else{throw Failure(message:"Actual independent sheet absent")}
        let events=Events();try await install(preview,helper:helper,events:events)
        let initial=try scheduling(preview)
        let before=model.independentReceipts.selections.count
        _ = try await js(preview,"return window.ReadingBookBridgeObservations.selectUniqueText(text)",["text":selected])
        try await wait("independent real source selection",host:host) {
            model.independentReceipts.selections.count>before && model.independentReceipts.sourceSelection?.isExact==true
        }
        _ = try await js(preview,"return window.ReadingBookBridgeObservations.capture('independent')")
        model.typography.setPointSize(30,for:.source)
        try await waitFast("visible override immediate CSS",host:host) {
            let p=try scheduling(preview)
            return p.active && p.first==nil && p.displayed?.fontSize==30 && !p.rendering
        }
        let menuDenied = try freshMenu(preview).items.allSatisfy{$0.title != "保存选区为语义摘记…"}
        model.independentOverride=nil
        let nilWindow=try await firstWindow(preview,model:model,host:host,font:31)
        let nilActivity=try scheduling(preview).active
        model.independentOverride=true
        _ = try await dispatch(preview,host:host,font:31)
        try await wait("restored full preview acknowledged",host:host) { try native(preview)?.displayed.fontSize==31 }
        let identity=allTrue(try await object(preview,"return window.ReadingBookBridgeObservations.comparePresentation('independent')"))
        let final=try scheduling(preview),baseState=try scheduling(base)
        observations["independent"]=["initial":initial.evidence,"nilWindow":nilWindow.evidence,"restored":final.evidence,
            "parent":baseState.evidence,"inheritedActivity":model.independentActivityValues,"saveDenied":menuDenied,
            "identity":identity,"actualSheetParent":sheet.sheetParent === parent || parent.attachedSheet === sheet,"events":events.rows]
        let exactSelection=model.independentReceipts.selection.map{exact($0.sourceMarkdown,model.markdown)&&exact($0.text,selected)}==true
        let passed=initial.active && !nilActivity && final.active && identity && menuDenied && exactSelection &&
            !model.active && !baseState.active && model.independentActivityValues.allSatisfy{!$0} &&
            preview.window === sheet && final.first==nil && model.independentReceipts.saved.isEmpty
        _ = try await snapshot(preview,label:"independent-final",directory:output)
        preview.configuration.userContentController.removeScriptMessageHandler(forName:"boundedProbeEvent")
        model.independentPresented=false
        try await wait("independent sheet dismissed",host:host) { parent.attachedSheet==nil && !NSApp.windows.contains{$0.sheetParent === parent && $0.isVisible} }
        parent.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        return passed
    }

    static func run(_ arguments:[String]) async {
        guard arguments.count==5,arguments.last=="--show-window" else {
            fputs("Usage: NativeMarkdownBoundedIdleProbe WORKSPACE NEW_OUTPUT DOM_OBSERVER --show-window\n",stderr);exit(2)
        }
        let root=URL(fileURLWithPath:arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
        let output=URL(fileURLWithPath:arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        let observer=URL(fileURLWithPath:arguments[3]).standardizedFileURL.resolvingSymlinksInPath()
        var checks:[String:Bool]=[:],executed:[String]=[],observations:[String:Any]=[:]
        var window:NSWindow?,retainedWeb:WKWebView?
        func check(_ index:Int,_ actual:Bool) throws {
            let name=checkNames[index];try require(checks[name]==nil,"Duplicate actual check "+name)
            checks[name]=actual;executed.append(name);try require(actual,"Actual native check failed: "+name)
        }
        do {
            try require(Set(checkNames).count==checkNames.count,"Duplicate expected check name")
            let env=ProcessInfo.processInfo.environment
            try require(output.path.hasPrefix(root.path+"/") && observer.path.hasPrefix(root.path+"/"),"All evidence must stay in workspace")
            for key in ["CFFIXED_USER_HOME","TMPDIR","READINGBOOK_IDLE_SOURCE_ROOT"] {
                guard let raw=env[key] else{throw Failure(message:"Runner must set "+key)}
                let value=URL(fileURLWithPath:raw).standardizedFileURL.resolvingSymlinksInPath()
                let isCompiledCheckout = key == "READINGBOOK_IDLE_SOURCE_ROOT" && value.path == root.path
                try require(isCompiledCheckout || value.path.hasPrefix(root.path+"/"),"Isolated path escaped workspace: "+key)
            }
            let sourceRoot=URL(fileURLWithPath:env["READINGBOOK_IDLE_SOURCE_ROOT"]!).standardizedFileURL.resolvingSymlinksInPath()
            try require(!FileManager.default.fileExists(atPath:output.path),"Fresh output required; retain every failure")
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            let a=output.appendingPathComponent("images-a",isDirectory:true),b=output.appendingPathComponent("images-b",isDirectory:true)
            for (dir,width) in [(a,2),(b,3)] {
                try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                guard let image=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,
                    hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) else{throw Failure(message:"Owned raster allocation failed")}
                for x in 0..<width{for y in 0..<2{image.setColor(.systemBlue,atX:x,y:y)}}
                guard let bytes=image.representation(using:.png,properties:[:]) else{throw Failure(message:"Owned raster encoding failed")}
                try bytes.write(to:dir.appendingPathComponent("control.png"),options:.withoutOverwriting)
            }
            let selected="深处真实选择😀e\u{301}唯一原文。",other="另外一个精确范围唯一句。"
            let paragraphs=(0..<64).map{"第\($0)段正文，中文e\u{301}与😀，不能用显示窗口替换完整来源。"}
            let original="# 有界样式 é\n\n行内 $x^2+1$。\n\n$$a^2+b^2=c^2$$\n\n| 项目 | 值 |\n| --- | --- |\n| 原文 | 42 |\n\n![authorized-control](control.png)\n\n[原文](readingbook://book/idle-fixture/unit/u1)\n\n"+paragraphs.joined(separator:"\n\n")+"\n\n"+selected+"\n\n"+other+"\n\nIDLE-END"
            let originalBytes=Data(original.utf8);try originalBytes.write(to:output.appendingPathComponent("source.md"),options:.withoutOverwriting)
            func decoration(_ id:String,_ quote:String,in source:String)->SourceReadingDecoration {
                let range=(source as NSString).range(of:quote,options:.literal)
                return .init(id:id,targetID:"u1",quote:quote,rangeLocation:range.location,rangeLength:range.length)
            }
            let model=BoundedIdleModel(markdown:original,directory:a,decorations:[decoration("deep",selected,in:original),decoration("other",other,in:original)])
            model.active=false
            let host=NSHostingView(rootView:BoundedIdleHost(model:model));host.frame=NSRect(x:0,y:0,width:850,height:700)
            let owned=NSWindow(contentRect:host.frame,styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window=owned;owned.isReleasedWhenClosed=false;owned.isRestorable=false;owned.contentView=host;owned.title="ReadingBook bounded-idle correctness"
            owned.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);host.layoutSubtreeIfNeeded()
            guard let web=webViews(host).first else{throw Failure(message:"Earliest synchronous real WK mount unavailable; cannot claim first-ACK coverage")}
            retainedWeb=web
            let earliest=try scheduling(web)
            let firstWasUnconfirmed=earliest.confirmed==nil && earliest.first==nil
            observations["earliestActualOwner"]=earliest.evidence
            try await wait("owned foreground real original body",host:host) {
                let actual=truth(try? await js(web,"return !!window.ReadingBookMarkdown&&document.querySelectorAll('.katex').length>=2&&!!document.querySelector('[data-source-decoration=deep]')&&Array.from(document.images).some(i=>i.complete&&i.naturalWidth===2)"))
                return NSApp.isActive && owned.isVisible && owned.isKeyWindow && actual
            }
            let helper=try String(contentsOf:observer,encoding:.utf8),events=Events()
            try await install(web,helper:helper,events:events)
            let warm=try await stable(web,model:model,host:host)
            let geometry=try await object(web,metricsScript)
            try require(warm.height>1024 && number((geometry["deep"] as? [String:Any])?["relativeY"])>1024,"Actual fixture must have a genuinely deep source position")
            try await liveSelection(selected,model:model,web:web,host:host)
            try require(callbackSourceIsExact(model,text:selected),"Actual initial source range not exact")
            _ = try await snapshot(web,label:"initial",directory:output)

            // A real production full-render call is held in the remote JS event
            // loop. Native acknowledgements are not intercepted or invented.
            try await stage(web,"first-ack");try await markBusy(web,method:"render",tag:"first-ack")
            let decomposed=original.replacingOccurrences(of:"# 有界样式 é",with:"# 有界样式 e\u{301}")
            try require(original==decomposed && !exact(original,decomposed),"Unicode control must be canonical-equivalent but byte-distinct")
            model.markdown=decomposed;model.source=decomposed
            try await waitFast("real unconfirmed source flight entered",host:host) {
                let p=try scheduling(web)
                return !events.matches("busy-enter","first-ack").isEmpty && p.rendering && p.confirmed==nil
            }
            model.typography.setPointSize(23,for:.source)
            var unconfirmed:Scheduling?
            try await waitFast("unconfirmed CSS pending did not open idle window",host:host) {
                let p=try scheduling(web)
                guard p.pending?.fontSize==23,p.rendering,p.confirmed==nil else{return false}
                unconfirmed=p;return true
            }
            guard let unconfirmed else{throw Failure(message:"Unconfirmed source-flight witness absent")}
            let (_,firstAckDispatch)=try await dispatch(web,host:host,font:23)
            let acknowledged=try await stable(web,model:model,host:host,font:23)
            guard let exitRow=events.matches("busy-exit","first-ack").first,let exitAt=exitRow["nativeReceivedNs"] as? UInt64 else{throw Failure(message:"Actual JS busy exit absent")}
            let firstExact=try await exactLastRender(web,markdown:decomposed,source:decomposed)
            let acknowledgedSchedule=try scheduling(web)
            try check(0,firstWasUnconfirmed && unconfirmed.first==nil && unconfirmed.due &&
                ms(firstAckDispatch,exitAt)<=100 && acknowledgedSchedule.confirmed==acknowledged.revision &&
                firstExact && exact(acknowledged.displayed.source,decomposed))
            observations["firstAcknowledgement"]=["during":unconfirmed.evidence,"acknowledged":acknowledged.evidence,
                "actualLatestDispatchNs":firstAckDispatch,"busyExitNs":exitAt,"dispatchAfterExitMs":ms(firstAckDispatch,exitAt)]

            model.active=true;model.typography.setPointSize(18,for:.source)
            _ = try await stable(web,model:model,host:host,font:18)
            try await clearSelection(web,host:host);try await liveSelection(selected,model:model,web:web,host:host)
            _ = try await js(web,"return window.ReadingBookBridgeObservations.capture('idle')")
            try await stage(web,"idle120")
            let idle=try await firstWindow(web,model:model,host:host,font:21)
            guard let idleFirst=idle.first else{throw Failure(message:"Actual idle first time absent")}
            let (_,idleAt)=try await dispatch(web,host:host,font:21)
            let idleFinal=try await stable(web,model:model,host:host,font:21)
            let idleIdentity=allTrue(try await object(web,"return window.ReadingBookBridgeObservations.comparePresentation('idle')"))
            let idleMs=ms(idleAt,idleFirst)
            try check(1,idleMs>=119 && idleMs<=180 && idleIdentity && idleFinal.revision==acknowledged.revision &&
                callbackSourceIsExact(model,text:selected) && exact(idleFinal.displayed.source,model.source))
            observations["idle120"]=["window":idle.evidence,"dispatchNs":idleAt,"observedDispatchDeltaMs":idleMs,
                "acceptedSchedulerObservationJitterMs":60,"notAWebKitCompletionSLA":true]

            try await stage(web,"hard250")
            let hard=try await firstWindow(web,model:model,host:host,font:22)
            guard let hardFirst=hard.first else{throw Failure(message:"Hard window first time absent")}
            var hardRows:[[String:Any]]=[],target=22.0,hardAt:UInt64=0,firstStayed=true
            // Observation/layout cost must not accumulate into each input gap.
            // Keep the original >=5 changes and239..310ms acceptance unchanged.
            var nextHardChange=hardFirst+32_000_000
            while ms(now(),hardFirst)<400 {
                let beforeNextChange=now()
                if beforeNextChange<nextHardChange {
                    try await Task.sleep(for:.nanoseconds(Int64(nextHardChange-beforeNextChange)))
                }
                nextHardChange += 32_000_000
                host.layoutSubtreeIfNeeded()
                let prior=try scheduling(web)
                if prior.first==nil,prior.displayed?.fontSize==target {hardAt=now();break}
                firstStayed = firstStayed && prior.first==hardFirst
                target += 1;model.typography.setPointSize(target,for:.source)
                try await waitFast("next continuous real CSS tuple",host:host) {try scheduling(web).pending?.fontSize==target}
                let p=try scheduling(web)
                hardRows.append(["observedNs":now(),"firstNs":p.first as Any? ?? NSNull(),"lastNs":p.last,"font":target,"due":p.due])
                if p.first==nil,p.displayed?.fontSize==target { hardAt=now();break }
            }
            if hardAt==0 {let result=try await dispatch(web,host:host,font:target);hardAt=result.1}
            _ = try await stable(web,model:model,host:host,font:target)
            let hardMs=ms(hardAt,hardFirst)
            observations["hard250"]=["first":hard.evidence,"changes":hardRows,"firstDispatchNs":hardAt,"observedDeltaMs":hardMs,
                "acceptedSchedulerObservationJitterMs":60,"firstWindowPreserved":firstStayed]
            try check(2,firstStayed && hardRows.count>=5 && hardMs>=239 && hardMs<=310)

            model.active=true;model.typography.setPointSize(18,for:.source)
            _ = try await stable(web,model:model,host:host,font:18)
            try await stage(web,"same-tuple")
            let same=try await firstWindow(web,model:model,host:host,font:24)
            guard let sameFirst=same.first else{throw Failure(message:"Same tuple window absent")}
            var sameRows:[[String:Any]]=[],sameKept=true
            for _ in 0..<3 {
                try await Task.sleep(for:.milliseconds(22))
                model.refreshToken += 1;let token=model.refreshToken
                try await waitFast("actual host refresh body",host:host) {model.bodyPasses>0}
                _ = try await js(web,"document.querySelector('a[href^=\"readingbook:\"]').click();return true")
                try await waitFast("actual current native openURL closure proves update",host:host) {model.receipts.linkTokens.last==token}
                let p=try scheduling(web)
                sameKept = sameKept && p.first==sameFirst && p.last==same.last && p.generation==same.generation
                sameRows.append(["observedNs":now(),"firstNs":p.first as Any? ?? NSNull(),"lastNs":p.last,"generation":p.generation,"actualOpenURLToken":token])
            }
            let (_,sameAt)=try await dispatch(web,host:host,font:24)
            _ = try await stable(web,model:model,host:host,font:24)
            let sameMs=ms(sameAt,sameFirst)
            try check(3,sameKept && sameRows.count==3 && sameMs>=119 && sameMs<=180)
            observations["sameTuple"]=["first":same.evidence,"actualNativeRefreshes":sameRows,"dispatchNs":sameAt,"dispatchDeltaMs":sameMs]

            model.active=true;model.typography.setPointSize(18,for:.source)
            _ = try await stable(web,model:model,host:host,font:18)
            try await stage(web,"single-flight");try await markBusy(web,method:"updatePresentation",tag:"single-flight")
            model.typography.setPointSize(19,for:.source)
            try await waitFast("real original CSS flight entered",host:host) {
                let p=try scheduling(web)
                return !events.matches("busy-enter","single-flight").isEmpty && p.rendering && p.displayed?.fontSize==19
            }
            let inFlight=try await firstWindow(web,model:model,host:host,font:26)
            guard let flightFirst=inFlight.first else{throw Failure(message:"In-flight first time absent")}
            while ms(now(),flightFirst)<280 {try await Task.sleep(for:.milliseconds(7))}
            let due=try scheduling(web)
            let (_,flightAt)=try await dispatch(web,host:host,font:26)
            _ = try await stable(web,model:model,host:host,font:26)
            guard let flightExit=events.matches("busy-exit","single-flight").first?["nativeReceivedNs"] as? UInt64 else{throw Failure(message:"Real flight exit missing")}
            try check(4,due.rendering && due.due && due.first==flightFirst && !due.wakePresent &&
                ms(flightAt,flightExit)<=100 && ms(flightAt,flightFirst)>250)
            observations["singleFlight"]=["window":inFlight.evidence,"pastDeadline":due.evidence,"dispatchNs":flightAt,"busyExitNs":flightExit,
                "nextSlotDispatchAfterExitMs":ms(flightAt,flightExit),"originalFlightWasRealRemoteJS":true]

            // Focus/active priority uses actual native/source handlers. No driver
            // scrollTo is used to make the source marker visible.
            try await stage(web,"active-focus")
            let activeWait=try await firstWindow(web,model:model,host:host,font:27)
            guard let activeFirst=activeWait.first else{throw Failure(message:"Active priority window missing")}
            model.active=true
            let (_,activeAt)=try await dispatch(web,host:host,font:27)
            _ = try await stable(web,model:model,host:host,font:27)
            try await clearSelection(web,host:host)
            let focusWait=try await firstWindow(web,model:model,host:host,font:28)
            guard let focusFirst=focusWait.first else{throw Failure(message:"Focus priority window missing")}
            model.focusedID="deep"
            let (_,focusAt)=try await dispatch(web,host:host,font:28)
            try await wait("real source focus marker",host:host) {truth(try? await js(web,"return !!document.querySelector('.source-focused[data-source-decoration=deep]')"))}
            model.active=true
            _ = try await stable(web,model:model,host:host,font:28)
            let focusBefore=try await object(web,metricsScript)
            var focusClipSamples:[[String:Any]]=[]
            observations["activeFocusBeforeNativeClip"]=["geometry":focusBefore,"uptimeNs":now(),
                "bounds":NSStringFromRect(web.bounds),"visibleRect":NSStringFromRect(web.visibleRect),"isFlipped":web.isFlipped]
            try await wait("existing native source focus scroll completed",host:host) {
                let geometry=try await object(web,metricsScript)
                let visible=deepActuallyVisible(web,dom:geometry)
                focusClipSamples.append(["uptimeNs":now(),"bounds":NSStringFromRect(web.bounds),
                    "visibleRect":NSStringFromRect(web.visibleRect),"isFlipped":web.isFlipped,"geometry":geometry,"deepVisible":visible])
                observations["activeFocusNaturalClipSamples"]=focusClipSamples
                return visible
            }
            let focusGeometry=try await object(web,metricsScript)
            let actuallyVisible=deepActuallyVisible(web,dom:focusGeometry)
            model.focusedID=nil
            try await wait("real source highlight clear",host:host) {truth(try? await js(web,"return document.querySelectorAll('.source-focused').length===0"))}
            model.active=false;model.focusedID="missing-decoration";host.layoutSubtreeIfNeeded();try await settle(host)
            model.focusedID=nil;model.typography.setPointSize(29,for:.source);let clearInput=now()
            let (_,clearAt)=try await dispatch(web,host:host,font:29)
            let cleared=try scheduling(web)
            observations["activeFocus"]=["activeWindow":activeWait.evidence,"activeDispatchNs":activeAt,
                "focusWindow":focusWait.evidence,"focusDispatchNs":focusAt,"actualDeepGeometry":focusGeometry,
                "clearInputNs":clearInput,"clearDispatchNs":clearAt,"cleared":cleared.evidence,
                "activeElapsedMs":ms(activeAt,activeFirst),"focusElapsedMs":ms(focusAt,focusFirst),
                "clearElapsedMs":ms(clearAt,clearInput),"actualDeepVisible":actuallyVisible,
                "webBounds":NSStringFromRect(web.bounds),"webVisibleRect":NSStringFromRect(web.visibleRect),
                "webFrame":NSStringFromRect(web.frame),"webIsFlipped":web.isFlipped]
            try check(5,ms(activeAt,activeFirst)<119 && ms(focusAt,focusFirst)<119 && actuallyVisible &&
                ms(clearAt,clearInput)<100 && cleared.first==nil)
            var immediate:[String:Any]=[:],allImmediate=true
            try await stage(web,"non-css")
            let dirWindow=try await firstWindow(web,model:model,host:host,font:22)
            model.directory=b
            let (_,dirAt)=try await dispatch(web,host:host,font:22)
            try await wait("actual new raster bytes",host:host) {truth(try? await js(web,"return Array.from(document.images).some(i=>i.complete&&i.naturalWidth===3)"))}
            let dirState=try scheduling(web)
            let dirOkay=dirState.displayed?.directory==b && dirState.first==nil && dirWindow.first.map{ms(dirAt,$0)<119}==true
            immediate["directoryB"]=["window":dirWindow.evidence,"after":dirState.evidence,"actualDispatchNs":dirAt,"passed":dirOkay];allImmediate = allImmediate && dirOkay
            _ = try await stable(web,model:model,host:host,font:22)
            let revokeWindow=try await firstWindow(web,model:model,host:host,font:23)
            model.directory=nil
            let (_,revokeAt)=try await dispatch(web,host:host,font:23)
            try await wait("actual image grant revoked",host:host) {truth(try? await js(web,"return document.images.length===0&&document.querySelectorAll('.image-placeholder').length===1"))}
            let revokeState=try scheduling(web)
            let revokeOkay=revokeState.displayed?.directory==nil && revokeWindow.first.map{ms(revokeAt,$0)<119}==true
            immediate["directoryNil"]=["window":revokeWindow.evidence,"after":revokeState.evidence,"actualDispatchNs":revokeAt,"passed":revokeOkay];allImmediate = allImmediate && revokeOkay
            _ = try await stable(web,model:model,host:host,font:23)
            let plainWindow=try await firstWindow(web,model:model,host:host,font:24)
            model.plainText=true
            let (_,plainAt)=try await dispatch(web,host:host,font:24)
            try await wait("literal plain source rendered",host:host) {truth(try? await js(web,"return document.querySelectorAll('.katex,table').length===0&&document.getElementById('content').textContent.includes('$x^2+1$')"))}
            let plainState=try scheduling(web)
            let plainOkay=plainState.displayed?.plain==true && plainWindow.first.map{ms(plainAt,$0)<119}==true
            immediate["plainText"]=["window":plainWindow.evidence,"after":plainState.evidence,"actualDispatchNs":plainAt,"passed":plainOkay];allImmediate = allImmediate && plainOkay
            model.active=true;model.plainText=false;model.typography.setPointSize(18,for:.source)
            _ = try await stable(web,model:model,host:host,font:18)
            try await clearSelection(web,host:host)
            let decoWindow=try await firstWindow(web,model:model,host:host,font:25)
            model.decorations=[]
            let (_,decoAt)=try await dispatch(web,host:host,font:25)
            try await wait("removed decoration left real DOM",host:host) {truth(try? await js(web,"return document.querySelectorAll('[data-source-decoration]').length===0"))}
            let decoState=try scheduling(web)
            let decoOkay=decoState.displayed?.decorations.isEmpty==true && decoWindow.first.map{ms(decoAt,$0)<119}==true
            immediate["decorations"]=["window":decoWindow.evidence,"after":decoState.evidence,"actualDispatchNs":decoAt,"passed":decoOkay];allImmediate = allImmediate && decoOkay
            _ = try await stable(web,model:model,host:host,font:25)
            try await liveSelection(selected,model:model,web:web,host:host)
            let (_,permissionAction)=try ownSaveMenu(web)
            try require(permissionAction.isEnabled,"Selection permission positive menu control must be enabled")
            let permissionWindow=try await firstWindow(web,model:model,host:host,font:26)
            model.selectionCallbacksEnabled=false
            let (_,permissionAt)=try await dispatch(web,host:host,font:26)
            let deniedProof=try scheduling(web),deniedBefore=model.receipts.total,savedBeforePermission=model.saved.count
            _ = invoke(permissionAction)
            _ = try await js(web,"return window.ReadingBookBridgeObservations.selectUniqueText(text)",["text":other])
            try await settle(host)
            let deniedMenu=try freshMenu(web).items.first{$0.title=="保存选区为语义摘记…"}
            let permissionOkay=deniedProof.displayed?.enabled==false && model.receipts.total==deniedBefore &&
                model.saved.count==savedBeforePermission && deniedMenu?.isEnabled==false &&
                permissionWindow.first.map{ms(permissionAt,$0)<119}==true
            immediate["selectionPermission"]=["window":permissionWindow.evidence,"after":deniedProof.evidence,"actualDispatchNs":permissionAt,"passed":permissionOkay]
            allImmediate = allImmediate && permissionOkay
            model.selectionCallbacksEnabled=true
            _ = try await stable(web,model:model,host:host,font:26)
            try await clearSelection(web,host:host);try await liveSelection(selected,model:model,web:web,host:host)
            try check(6,allImmediate && callbackSourceIsExact(model,text:selected));observations["nonCSS"]=immediate

            try await stage(web,"save-only")
            let (_,saveAction)=try ownSaveMenu(web);let savePositive=model.saved.count
            try require(saveAction.isEnabled && invoke(saveAction) && model.saved.count==savePositive+1,"Save-only positive control failed")
            let saveWindow=try await firstWindow(web,model:model,host:host,font:27)
            model.saveEnabled=false
            try await waitFast("native save item actually removed",host:host) {try freshMenu(web).items.allSatisfy{$0.title != "保存选区为语义摘记…"}}
            let saveRevokedAt=now(),saveBefore=model.saved.count
            _ = invoke(saveAction)
            let saveState=try scheduling(web)
            try check(7,model.saved.count==saveBefore && saveWindow.first.map{ms(saveRevokedAt,$0)<119}==true &&
                saveState.pending?.enabled==true && !model.saveEnabled)
            observations["saveOnly"]=["window":saveWindow.evidence,"after":saveState.evidence,"actualRevocationNs":saveRevokedAt]
            model.saveEnabled=true;model.active=true;model.typography.setPointSize(18,for:.source)
            _ = try await stable(web,model:model,host:host,font:18)
            try await clearSelection(web,host:host);try await liveSelection(selected,model:model,web:web,host:host)

            try await stage(web,"old-generation")
            let (_,oldSourceAction)=try ownSaveMenu(web)
            guard let oldSelection=model.selection else{throw Failure(message:"Old source selection control missing")}
            try require(oldSourceAction.isEnabled,"Old source action must first be enabled")
            let sourceWindow=try await firstWindow(web,model:model,host:host,font:28)
            let finalSource=model.markdown+"\n\nNEW-SOURCE-GENERATION-EXACT"
            model.markdown=finalSource;model.source=finalSource
            let (_,sourceAt)=try await dispatch(web,host:host,font:28)
            let finalProof=try await stable(web,model:model,host:host,font:28)
            let oldSourceRejected=retained(oldSourceAction,cannotSave:model)
            let callsAfterReplacement=try await records(web)
            try await Task.sleep(for:.milliseconds(330))
            let afterOldDeadline=try scheduling(web),callsAfterDeadline=try await records(web)
            let exactRender=try await exactLastRender(web,markdown:finalSource,source:finalSource)
            try check(8,oldSourceRejected && finalProof.revision>oldSelection.revision && afterOldDeadline.generation>sourceWindow.generation &&
                afterOldDeadline.first==nil && callsAfterDeadline.count==callsAfterReplacement.count && exactRender &&
                sourceWindow.first.map{ms(sourceAt,$0)<119}==true && exact(afterOldDeadline.displayed?.source ?? "",finalSource))
            observations["oldGeneration"]=["before":sourceWindow.evidence,"after":afterOldDeadline.evidence,"sourceDispatchNs":sourceAt,
                "oldActionRejected":oldSourceRejected,"rendererCallCountAfterReplacement":callsAfterReplacement.count,
                "rendererCallCountAfterOldDeadline":callsAfterDeadline.count]

            // A real callAsyncJavaScript failure, not a synthesized native
            // completion. The observer throws once after its controlled busy
            // segment; all other renderer calls pass through unchanged.
            model.active=true;model.typography.setPointSize(18,for:.source)
            _ = try await stable(web,model:model,host:host,font:18)
            try await stage(web,"failure");try await markBusy(web,method:"updatePresentation",tag:"failure",fail:true)
            model.typography.setPointSize(19,for:.source)
            try await waitFast("real soon-to-fail JS flight",host:host) {
                let actual=try scheduling(web)
                return !events.matches("busy-enter","failure").isEmpty && actual.rendering
            }
            let failureWindow=try await firstWindow(web,model:model,host:host,font:20)
            try await waitFast("actual native failure path cleared scheduler",host:host,seconds:4) {
                let p=try scheduling(web)
                return !events.matches("injected-failure","failure").isEmpty && !p.rendering && p.confirmed==nil &&
                    p.displayed==nil && p.first==nil && !p.wakePresent
            }
            let failed=try scheduling(web),failureCalls=try await records(web)
            try await Task.sleep(for:.milliseconds(330))
            let afterFailure=try scheduling(web),afterFailureCalls=try await records(web)
            let failureCancelled=afterFailure.confirmed==nil && afterFailure.displayed==nil && afterFailure.first==nil &&
                !afterFailure.wakePresent && afterFailure.generation>failureWindow.generation && failureCalls.count==afterFailureCalls.count
            observations["nativeFailure"]=["window":failureWindow.evidence,"actualFailure":failed.evidence,"afterQuiet":afterFailure.evidence,
                "expectedInjectedJSError":"Owned bounded-idle failure control","noTimerRetry":failureCancelled]
            model.active=true;model.typography.setPointSize(18,for:.source)
            _ = try await stable(web,model:model,host:host,font:18)
            try await clearSelection(web,host:host);try await liveSelection(selected,model:model,web:web,host:host)

            let independentOkay=try await independent(model:model,parent:owned,host:host,base:web,helper:helper,output:output,
                selected:selected,observations:&observations)
            try check(10,independentOkay)
            try check(11,try scope(sourceRoot,observations:&observations))
            model.active=true;model.typography.setPointSize(18,for:.source)
            _ = try await stable(web,model:model,host:host,font:18)
            try await clearSelection(web,host:host);try await liveSelection(selected,model:model,web:web,host:host)
            let (_,teardownAction)=try ownSaveMenu(web)
            guard let oldOwner=web.navigationDelegate else{throw Failure(message:"Actual old owner missing")}
            let teardownWindow=try await firstWindow(web,model:model,host:host,font:21)
            let beforeUnmount=try await records(web)
            model.mounted=false
            try await wait("real representable dismantle",host:host) {webViews(host).isEmpty && web.navigationDelegate==nil}
            try await settle(host)
            let callbacksAfter=model.receipts.total,savesAfter=model.saved.count
            _ = invoke(teardownAction)
            try await Task.sleep(for:.milliseconds(330));host.layoutSubtreeIfNeeded()
            let callsAfterUnmount=try await records(web)
            let oldReady=try field(oldOwner,"ready",Bool.self),oldGeneration=try field(oldOwner,"presentationGeneration",UInt64.self)
            let oldWake=unwrapped(try rawField(oldOwner,"presentationWake"))
            let oldFirst=unwrapped(try rawField(oldOwner,"presentationFirstChange"))
            let oldConfirmed=unwrapped(try rawField(oldOwner,"confirmedDocumentRevision"))
            let teardownCancelled = !oldReady && oldGeneration>teardownWindow.generation && oldWake==nil && oldFirst==nil && oldConfirmed==nil &&
                beforeUnmount.count==callsAfterUnmount.count && callbacksAfter==model.receipts.total && savesAfter==model.saved.count &&
                web.navigationDelegate==nil && webViews(host).isEmpty
            try check(9,failureCancelled && teardownCancelled)
            observations["dismantle"]=["window":teardownWindow.evidence,"nativeGenerationAfter":oldGeneration,"nativeReadyAfter":oldReady,
                "callbacksBeforeQuiet":callbacksAfter,"callbacksAfterQuiet":model.receipts.total,"rendererCallsBefore":beforeUnmount.count,
                "rendererCallsAfter":callsAfterUnmount.count,"oldOwnerIntentionallyRetainedForNegativeControl":true]
            observations["events"]=events.rows
            observations["sourceFixture"]=["sourceSHA256":hash(original),"sourceUTF8Bytes":originalBytes.count,
                "originalFileUnchanged":try Data(contentsOf:output.appendingPathComponent("source.md"))==originalBytes]
            observations["clock"]="DispatchTime.now().uptimeNanoseconds; integer native fields and received events preserved. Remote performance.now only supplemental."
            observations["scope"]="Real Rich/WK, exact native State and scheduling readout, DOM Range/source/menu, public JS controlled-busy/failure negative controls. No physical input/provider/AppStore/real library/clipboard. Timing acceptance includes stated observation jitter, not a physical WebKit completion SLA."
        } catch {
            observations["error"]=error.localizedDescription
            if let web=retainedWeb {
                observations["failureNative"]=["frame":NSStringFromRect(web.frame),"bounds":NSStringFromRect(web.bounds),
                    "visibleRect":NSStringFromRect(web.visibleRect),"isFlipped":web.isFlipped,
                    "windowKey":web.window?.isKeyWindow == true,"appActive":NSApp.isActive]
                observations["failureScheduling"]=(try? scheduling(web))?.evidence
                observations["failureGeometry"]=try? await object(web,metricsScript)
                observations["failureDOM"]=try? await snapshot(web,label:"failure-dom",directory:output)
            }
        }
        retainedWeb?.configuration.userContentController.removeScriptMessageHandler(forName:"boundedProbeEvent")
        window?.close()
        let passed=observations["error"]==nil && Set(checks.keys)==Set(checkNames) && checks.values.allSatisfy{$0}
        let result:[String:Any]=["schema":1,"probe":"bounded-idle","passed":passed,"checks":checks,"checkCount":checks.count,
            "expectedCheckNames":checkNames,"expectedCheckCount":checkNames.count,"executedCheckNames":executed,
            "observations":observations,"pid":ProcessInfo.processInfo.processIdentifier]
        if FileManager.default.fileExists(atPath:output.path) {
            try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("result.json"),options:.atomic)
        }
        if !passed{fputs("Native bounded-idle regression failed; preserve actual result and runtime log\n",stderr)}
        exit(passed ? 0 : 1)
    }
}
