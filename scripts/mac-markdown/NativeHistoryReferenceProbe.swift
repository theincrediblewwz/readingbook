// DRAFT: standalone Debug regression linked to completed @testable product
// objects. No shipping factory, copied navigation, private product test API,
// timing benchmark, installed app, real library, providers or OS input.
import AppKit
import SwiftUI
import WebKit
import Foundation
import CryptoKit
import Darwin
@testable import ReadingBook
@testable import ReadingCore

private struct HistoryReferenceFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private func historyReferenceRequire(_ value: Bool, _ message: String) throws {
    if !value { throw HistoryReferenceFailure(message: message) }
}
private func historyReferenceHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func historyReferenceEncoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
}
private final class HistoryReferenceDefaults: UserDefaults, @unchecked Sendable {
    private let gate = NSLock()
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { gate.lock(); defer { gate.unlock() }; return values[key] }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func set(_ value: Any?, forKey key: String) { gate.lock(); defer { gate.unlock() }; values[key] = value }
}
private final class HistoryBindingReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    func append(_ note: Notification) {
        lock.lock(); defer { lock.unlock() }
        events.append(note.userInfo.map { Dictionary(uniqueKeysWithValues: $0.map { (String(describing: $0.key), $0.value) }) } ?? [:])
    }
    func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return events }
}
@MainActor private final class HistoryReferenceDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await NativeHistoryReferenceProbe.run() } }
}

@main @MainActor enum NativeHistoryReferenceProbe {
    private static var delegate: HistoryReferenceDelegate?
    private static var checks: [String: Bool] = [:]
    private static var rows: [[String: Any]] = []
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let owner = HistoryReferenceDelegate(); delegate = owner; app.delegate = owner; app.run()
    }
    private static func check(_ name: String, _ value: Bool) throws {
        checks[name] = value; try historyReferenceRequire(value, name)
    }
    private static func exact(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    private static func views<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        ([root as? T].compactMap { $0 }) + root.subviews.flatMap { views($0, type) }
    }
    private static func sheet(of parent: NSWindow) -> NSWindow? {
        parent.attachedSheet ?? NSApp.windows.first { $0.sheetParent === parent }
    }
    private static func js(_ web: WKWebView, _ script: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let raw: Any = try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { continuation.resume(with: $0) }
        }
        guard let value = raw as? [String: Any] else { throw HistoryReferenceFailure(message: "Expected actual renderer object") }
        return value
    }
    private static func wait(_ label: String, _ predicate: () async throws -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < end {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw HistoryReferenceFailure(message: "Timed out: " + label)
    }
    private static func write(_ name: String, _ value: Any, to output: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(name), options: .withoutOverwriting)
    }

    // Fail closed on a changed private layout; never read/write a coordinator
    // through unsafe pointers or accept DOM alone as source/ready authority.
    private static func rawField(_ owner: Any, _ name: String) throws -> Any {
        let entries = Mirror(reflecting: owner).children.filter { $0.label == name }
        guard entries.count == 1 else { throw HistoryReferenceFailure(message: "Mirror field missing/ambiguous: " + name) }
        return entries[0].value
    }
    private static func unwrapped(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional ? mirror.children.first?.value : value
    }
    private static func field<T>(_ owner: Any, _ name: String, _ type: T.Type) throws -> T {
        guard let value = try rawField(owner, name) as? T else { throw HistoryReferenceFailure(message: "Mirror type mismatch: " + name) }
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
            try historyReferenceRequire(labels.count == expected.count && Set(labels) == expected, "Unknown private State inventory")
            markdown = try field(raw, "markdown", String.self); source = try field(raw, "sourceText", String.self)
            theme = try field(raw, "theme", String.self); family = try field(raw, "fontFamily", String.self)
            style = try field(raw, "readingStyle", String.self); context = try field(raw, "readingContext", String.self)
            fontSize = try field(raw, "fontSize", Double.self); enabled = try field(raw, "selectionEnabled", Bool.self)
            plain = try field(raw, "plainText", Bool.self); decorations = try field(raw, "decorations", [SourceReadingDecoration].self)
            let dir = try rawField(raw, "directory")
            try historyReferenceRequire(dir is URL?, "Mirror type mismatch: directory")
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
        try historyReferenceRequire(typeName.hasSuffix("MarkdownWebView.Coordinator"), "Unexpected actual navigation owner: " + typeName)
        let rawWeb = try rawField(owner, "webView")
        guard let owned = unwrapped(rawWeb) as? WKWebView, owned === web else { throw HistoryReferenceFailure(message: "Actual owner.webView identity differs") }
        let ready = try field(owner, "ready", Bool.self), rendering = try field(owner, "rendering", Bool.self)
        let revision = try field(owner, "revision", Int.self)
        guard ready && !rendering else { return nil }
        guard let p = unwrapped(try rawField(owner, "pending")), let d = unwrapped(try rawField(owner, "displayed")) else { return nil }
        let pending = try StateProof(p), displayed = try StateProof(d)
        guard pending.equals(displayed) else { return nil }
        let height = try field(owner, "height", Binding<CGFloat>.self)
        return NativeProof(pending: pending, displayed: displayed, revision: revision, height: Double(height.wrappedValue))
    }
    private static func geometry(_ web: WKWebView, in sheet: NSWindow, dom: [String: Any]) -> [String: Double]? {
        guard web.window === sheet, sheet.isVisible, sheet.isKeyWindow, !web.isHiddenOrHasHiddenAncestor,
              let root = sheet.contentView, web.bounds.width > 200, web.bounds.height > 0,
              let heading = dom["heading"] as? [String: NSNumber], let cssWidth = (dom["innerWidth"] as? NSNumber)?.doubleValue,
              cssWidth > 0, let x = heading["x"]?.doubleValue, let y = heading["y"]?.doubleValue,
              let width = heading["width"]?.doubleValue, let height = heading["height"]?.doubleValue else { return nil }
        let clipped = web.visibleRect.intersection(web.bounds)
        guard !clipped.isNull else { return nil }
        let actual = web.convert(clipped, to: root).intersection(root.visibleRect)
        guard !actual.isNull, actual.width >= 200, actual.height >= min(80, web.bounds.height * 0.20) else { return nil }
        let scale = web.bounds.width / cssWidth
        let localY = web.isFlipped ? web.bounds.minY + y * scale : web.bounds.maxY - (y + height) * scale
        let localHeading = NSRect(x: web.bounds.minX + x * scale, y: localY, width: width * scale, height: height * scale)
        let visibleHeading = web.convert(localHeading, to: root).intersection(actual)
        guard !visibleHeading.isNull, visibleHeading.width >= min(80, localHeading.width * 0.4),
              visibleHeading.height >= min(12, localHeading.height * 0.4) else { return nil }
        return ["x": actual.minX, "y": actual.minY, "width": actual.width, "height": actual.height,
            "webHeight": web.bounds.height, "webWidth": web.bounds.width, "headingX": visibleHeading.minX,
            "headingY": visibleHeading.minY, "headingWidth": visibleHeading.width, "headingHeight": visibleHeading.height]
    }
    private static let targetDOM = """
        const root=document.getElementById('content'), h=root?.querySelector('h3'), r=h?.getBoundingClientRect();
        return {marker:h?.textContent || '',hasEnd:root?.textContent.includes(end) || false,
          tables:root?.querySelectorAll('table').length || 0,math:root?.querySelectorAll('.katex').length || 0,
          errors:root?.querySelectorAll('.math-error').length || 0,fontsReady:document.fonts.status==='loaded',
          height:root?.getBoundingClientRect().height || 0,innerWidth:window.innerWidth,
          heading:r ? {x:r.x,y:r.y,width:r.width,height:r.height} : null};
        """
    private static func target(parent: NSWindow, message: ChatMessage, expected: String, fontSize: Double? = nil) async throws -> (WKWebView, NSWindow, NativeProof, [String: Any]) {
        var result: (WKWebView, NSWindow, NativeProof, [String: Any])?
        var last: [Double]?, stable = 0
        try await wait("actual history target " + message.id) {
            guard let modal = sheet(of: parent), modal.sheetParent === parent || parent.attachedSheet === modal,
                  let root = modal.contentView else { return false }
            for web in views(root, WKWebView.self) {
                guard let proof = try native(web), exact(proof.displayed.markdown, expected), exact(proof.displayed.source, expected),
                      proof.displayed.context == ReadingTextContext.conversation.rawValue,
                      !proof.displayed.plain, proof.displayed.decorations.isEmpty,
                      fontSize.map({ proof.displayed.fontSize == $0 }) ?? true else { continue }
                let dom = try await js(web, targetDOM, ["end": "RBH-END-" + message.id])
                guard dom["marker"] as? String == "RBH-" + message.id, dom["hasEnd"] as? Bool == true,
                      (dom["tables"] as? Int ?? 0) == 1, (dom["math"] as? Int ?? 0) >= 2,
                      (dom["errors"] as? Int ?? -1) == 0, dom["fontsReady"] as? Bool == true,
                      let measured = geometry(web, in: modal, dom: dom), let domHeight = (dom["height"] as? NSNumber)?.doubleValue,
                      proof.height > 0, abs(proof.height - web.bounds.height) <= 2.5,
                      abs(proof.height - ceil(domHeight) - 2) <= 2.5 else { continue }
                let signature = [measured["x"]!, measured["y"]!, measured["width"]!, measured["height"]!, measured["webHeight"]!, measured["headingY"]!, domHeight]
                if let previous = last, previous.count == signature.count, zip(previous, signature).allSatisfy({ abs($0 - $1) <= 0.5 }) { stable += 1 }
                else { last = signature; stable = 1 }
                if stable >= 3 {
                    result = (web, modal, proof, ["dom": dom, "actualNativeGeometry": measured, "stableSamples": stable,
                        "actualAttachedSheet": true, "nativeWebIsFlipped": web.isFlipped])
                    return true
                }
            }
            return false
        }
        guard let result else { throw HistoryReferenceFailure(message: "Missing stable target") }
        return result
    }
    private static func completeDOM(_ web: WKWebView, expected: String, revision: Int) async throws -> [String: Any] {
        try await js(web, """
            const root=document.getElementById('content'), oracle=document.createElement('article');
            oracle.innerHTML=window.ReadingBookMarkdown.renderHTML(markdown,{sourceText:markdown,plainText:false,allowImages:true,revision:revision});
            return {exactHTML:root.innerHTML===oracle.innerHTML,actualHTML:root.innerHTML,expectedHTML:oracle.innerHTML,
              actualText:root.textContent,expectedText:oracle.textContent,
              links:Array.from(root.querySelectorAll('a')).map(a=>({text:a.textContent,href:a.getAttribute('href')})),
              mathErrors:root.querySelectorAll('.math-error').length,fontsReady:document.fonts.status==='loaded'};
            """, ["markdown": expected, "revision": revision])
    }
    private static func fixture(_ count: Int) throws -> BookProject {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        var project = BookProject(id: "44444444-4444-4444-8444-444444444444", title: "Synthetic saved conversation", originalName: "history-fixture.txt",
            sourceHash: historyReferenceHash(Data("合成原文，只用于本批历史界面。".utf8)), units: [
                SourceUnit(id: "history-u1", order: 0, chapter: "Current", page: 1, text: "合成原文，只用于本批历史界面。"),
                SourceUnit(id: "history-u2", order: 1, chapter: "Past context", page: 2, text: "历史问答的合成原文。")])
        project.importedAt = epoch
        project.sourceHash = historyReferenceHash(Data(project.units.map(\.text).joined(separator: "\n\n").utf8))
        let snapshot = try ReadingQuerySnapshot.freeze(scope: .page, in: project, context: .init(unitID: "history-u2", page: 2))
        let context = try ReadingChatContext(snapshot: snapshot, avoidsSpoilers: true)
        project.chats = (0..<count).map { index in
            let id = String(format: "history-%06d", index)
            var content = "### RBH-\(id)\n\n原始第 \(index + 1) 条。Unicode: e\u{301}、é、😀。\n\n"
            content += "行内 $x_i^2$，以及\n\n$$a^2+b^2=c^2$$\n\n| 项目 | 值 |\n| --- | --- |\n| 原始序号 | \(index) |\n| 来源 | 本地合成 |\n\n"
            content += "[unit:history-u2] [doc:history-note] [message:history-000000]\n\n"
            while content.utf8.count < 1400 { content += "本地合成解释保留真实 Markdown。Local history text e\u{301} 😀.\n\n" }
            content += "RBH-END-\(id)\n"
            var message = ChatMessage(id: id, role: index.isMultiple(of: 2) ? "user" : "assistant", content: content,
                evidence: [.init(unitID: "history-u2", quote: "合成原文")])
            message.createdAt = epoch + Double(index); message.conversationMode = .functional
            message.answerStyle = .research; message.readingContext = context
            return message
        }
        try historyReferenceRequire(project.chats.allSatisfy { (1024...2048).contains($0.content.utf8.count) }, "Fixture must retain 1–2KiB messages")
        return project
    }
    private static func rect(_ value: NSRect) -> [String: Any] {
        if value.isNull { return ["isNull": true] }
        return ["x": Double(value.minX), "y": Double(value.minY), "width": Double(value.width), "height": Double(value.height)]
    }
    private static func captureViewport(_ parent: NSWindow, name: String, output: URL, receipts: HistoryBindingReceipts) async throws {
        var snapshot: [String: Any] = ["label": name, "uptimeNanoseconds": DispatchTime.now().uptimeNanoseconds,
            "bindingOnAppearOnChangeEvents": receipts.snapshot(), "parentVisible": parent.isVisible]
        if let modal = sheet(of: parent), let root = modal.contentView {
            snapshot["sheet"] = ["visible": modal.isVisible, "key": modal.isKeyWindow, "bounds": rect(root.bounds),
                "visibleRect": rect(root.visibleRect), "isFlipped": root.isFlipped,
                "attachedToExpectedParent": modal.sheetParent === parent || parent.attachedSheet === modal]
            var observations: [[String: Any]] = []
            for web in views(root, WKWebView.self) {
                var row: [String: Any] = ["webBounds": rect(web.bounds), "webVisibleRect": rect(web.visibleRect),
                    "webFrame": rect(web.frame), "webBoundsInSheet": rect(web.convert(web.bounds, to: root)),
                    "boundsClippedVisibleRectInSheet": rect(web.convert(web.visibleRect.intersection(web.bounds), to: root).intersection(root.visibleRect)),
                    "isFlipped": web.isFlipped, "webBelongsToSheet": web.window === modal,
                    "hiddenOrAncestorHidden": web.isHiddenOrHasHiddenAncestor]
                if let scroll = outerScrollView(web) {
                    row["scroll"] = ["clipBounds": rect(scroll.contentView.bounds), "clipVisibleRect": rect(scroll.contentView.visibleRect),
                        "clipIsFlipped": scroll.contentView.isFlipped, "documentBounds": scroll.documentView.map { rect($0.bounds) } ?? [:],
                        "documentIsFlipped": scroll.documentView?.isFlipped as Any? ?? NSNull()]
                }
                do {
                    if let owner = web.navigationDelegate {
                        row["ownerType"] = String(reflecting: type(of: owner))
                        row["nativeFlags"] = ["ready": try field(owner, "ready", Bool.self), "rendering": try field(owner, "rendering", Bool.self),
                            "revision": try field(owner, "revision", Int.self), "height": Double(try field(owner, "height", Binding<CGFloat>.self).wrappedValue)]
                        for key in ["pending", "displayed"] {
                            if let raw = unwrapped(try rawField(owner, key)) { row[key] = try StateProof(raw).evidence }
                        }
                    }
                    let dom = try await js(web, """
                        const root=document.getElementById('content'), h=root?.querySelector('h3'), r=h?.getBoundingClientRect();
                        return {html:root?.innerHTML || '',text:root?.textContent || '',marker:h?.textContent || '',
                          height:root?.getBoundingClientRect().height || 0,innerWidth:window.innerWidth,
                          heading:r?{x:r.x,y:r.y,width:r.width,height:r.height}:null,fontsReady:document.fonts.status==='loaded',
                          theme:document.documentElement.dataset.theme,fontSize:document.documentElement.style.fontSize,
                          fontFamily:document.documentElement.style.fontFamily};
                        """)
                    row["actualDOM"] = dom; row["admittedHeadingGeometry"] = geometry(web, in: modal, dom: dom) as Any? ?? NSNull()
                } catch { row["captureError"] = String(describing: error) }
                observations.append(row)
            }
            snapshot["webs"] = observations
        } else { snapshot["missingActualSheet"] = true }
        try write(name + ".json", snapshot, to: output)
    }
    private static func outerScrollView(_ web: WKWebView) -> NSScrollView? {
        var current = web.superview
        while let view = current {
            if let scroll = view as? NSScrollView, scroll.documentView != nil { return scroll }
            current = view.superview
        }
        return nil
    }
    private static func userScrollDoesNotSnapBack(_ web: WKWebView, store: AppStore, name: String) async throws -> [String: Any] {
        guard let scroll = outerScrollView(web), let document = scroll.documentView else { throw HistoryReferenceFailure(message: "Actual history native scroll view absent") }
        let clip = scroll.contentView, before = clip.bounds.origin
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        let desired = before.y < maximum * 0.5 ? min(maximum, before.y + 1100) : max(0, before.y - 1100)
        try check(name + ".scroll-has-room", abs(desired - before.y) >= 800)
        // Public AppKit native scroll path. No OS mouse/keyboard event is sent.
        // Bounds notifications drive SwiftUI's real scroll-position binding.
        clip.scroll(to: NSPoint(x: before.x, y: desired)); scroll.reflectScrolledClipView(clip)
        try await wait(name + ".native-scroll-moved") { abs(clip.bounds.origin.y - before.y) >= 800 }
        try await Task.sleep(for: .milliseconds(300))
        let moved = clip.bounds.origin
        store.objectWillChange.send() // unrelated parent refresh; no model/draft edit
        try await Task.sleep(for: .milliseconds(700))
        let after = clip.bounds.origin
        let tolerance = min(100, abs(moved.y - before.y) * 0.25)
        try check(name + ".native-scroll-not-pulled-to-reference", abs(after.y - moved.y) <= tolerance && abs(after.y - before.y) >= 600)
        return ["method": "actual ancestor NSClipView.scroll(to:) + reflectScrolledClipView; not physical wheel input",
            "before": ["x": before.x, "y": before.y], "moved": ["x": moved.x, "y": moved.y],
            "afterUnrelatedBodyRefresh": ["x": after.x, "y": after.y], "allowedLayoutDrift": tolerance]
    }
    private static func sameRowResizeDoesNotReset(_ web: WKWebView, modal: NSWindow, expected: String, name: String, output: URL) async throws {
        guard let scroll = outerScrollView(web), let document = scroll.documentView else { throw HistoryReferenceFailure(message: "Actual same-row native scroll absent") }
        let clip = scroll.contentView, initial = clip.bounds.origin
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: initial.x, y: min(maximum, initial.y + 460))); scroll.reflectScrolledClipView(clip)
        try await wait(name + ".same-row-scroll-away-from-heading") {
            let visible = web.visibleRect.intersection(web.bounds)
            return !visible.isNull && visible.minY >= 250 && visible.height >= 100
        }
        let before = web.visibleRect.intersection(web.bounds)
        try check(name + ".same-row-user-scroll-moved", before.minY >= 250)
        let widthBefore = modal.contentView?.bounds.width ?? 0
        let requested = widthBefore < 700 ? widthBefore + 100 : widthBefore - 100
        modal.setContentSize(NSSize(width: requested, height: modal.contentView?.bounds.height ?? 600))
        try await wait(name + ".same-row-actual-resize") { abs((modal.contentView?.bounds.width ?? 0) - widthBefore) >= 70 }
        try check(name + ".same-row-actual-width-changed", true)
        var after: NSRect?, proof: NativeProof?, geometry: [String: Any]?
        try await wait(name + ".same-row-resize-retains-interior") {
            guard let state = try native(web), exact(state.displayed.markdown, expected), exact(state.displayed.source, expected) else { return false }
            let dom = try await js(web, targetDOM, ["end": "RBH-END-history-000058"])
            let visible = web.visibleRect.intersection(web.bounds)
            guard !visible.isNull, visible.minY >= 100, visible.height >= 100,
                  let domHeight = (dom["height"] as? NSNumber)?.doubleValue,
                  abs(state.height - web.bounds.height) <= 2.5, abs(state.height - ceil(domHeight) - 2) <= 2.5,
                  dom["fontsReady"] as? Bool == true else { return false }
            after = visible; proof = state; geometry = dom; return true
        }
        try await Task.sleep(for: .milliseconds(600))
        let late = web.visibleRect.intersection(web.bounds)
        try check(name + ".same-row-resize-no-top-reset", !late.isNull && late.minY >= 100 && late.height >= 100)
        guard let proof, let after, let geometry else { throw HistoryReferenceFailure(message: "Same-row source evidence missing") }
        let oracle = try await completeDOM(web, expected: expected, revision: proof.revision)
        try check(name + ".same-row-resize-full-source-and-dom", oracle["exactHTML"] as? Bool == true)
        try write("same-row-resize.json", ["beforeLocalVisible": rect(before), "afterLocalVisible": rect(after),
            "lateLocalVisible": rect(late), "widthBefore": widthBefore, "widthRequested": requested,
            "widthAfter": modal.contentView?.bounds.width ?? 0, "native": proof.evidence, "dom": geometry,
            "scope": "Native same-row scroll before resize; no target re-request or driver scroll-to-reference"], to: output)
        try write("same-row-complete-dom.json", oracle, to: output)
    }
    private static func runCase(count: Int, index: Int, output: URL, scratch: URL, observer: String) async throws {
        let name = "messages-\(count)-focus-\(index)"
        let caseOutput = output.appendingPathComponent(name, isDirectory: true)
        let caseScratch = scratch.appendingPathComponent(name, isDirectory: true)
        let library = caseScratch.appendingPathComponent("library", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: caseOutput, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let disabled = ProviderSettings(baseURL: "http://127.0.0.1:1/disabled", model: "")
        UserDefaults.standard.setVolatileDomain(["service-profiles": Data("[]".utf8), "provider": try historyReferenceEncoded(disabled),
            "library.root.path.v1": library.path, "appearance.reduceMotion": true, "reader.hoverAutoTranslation": false,
            "NSQuitAlwaysKeepsWindows": false, "ApplePersistenceIgnoreState": true], forName: UserDefaults.argumentDomain)
        let store = AppStore()
        try check(name + ".isolated-empty-profiles", store.savedServices.isEmpty && store.apiKey.isEmpty)
        try check(name + ".isolated-owned-library", store.libraryRootURL.standardizedFileURL == library &&
            store.libraryRootURL.resolvingSymlinksInPath().path == library.resolvingSymlinksInPath().path && store.libraryRootURL.hasDirectoryPath)
        store.settings = disabled
        var project = try fixture(count)
        let sourceURL = caseScratch.appendingPathComponent("history-fixture.txt")
        let original = Data(project.units.map(\.text).joined(separator: "\n\n").utf8)
        try original.write(to: sourceURL, options: .withoutOverwriting)
        project = try await store.repository.create(project, sourceURL: sourceURL)
        var note = DocumentRecord(id: "history-note", title: "Synthetic saved note")
        note.createdAt = Date(timeIntervalSince1970: 1_700_000_000); note.updatedAt = note.createdAt
        let noteBody = "# Synthetic note\n\nOriginal note e\u{301} 😀 and $x^2$ stay unchanged.\n"
        project = try await store.repository.saveDocument(project: project, document: note, markdown: noteBody)
        store.books = [project]; store.bookID = project.id; store.sourceFileURL = await store.repository.sourceURL(for: project)
        store.selectedUnitID = "history-u1"; store.route = "query"
        store.queryInteractionMode = .reading; store.queryAnswerStyle = .mentor
        let draft = "Unsent history probe draft e\u{301} 😀; never dispatch."
        store.queryComposerDraft.text = draft
        let projectBefore = try historyReferenceEncoded(project)
        let projectURL = library.appendingPathComponent("books/\(project.id)/project.json")
        let diskBefore = try Data(contentsOf: projectURL)
        try projectBefore.write(to: caseOutput.appendingPathComponent("project-before.json"), options: .withoutOverwriting)
        let typography = ReadingTypographySettings(defaults: HistoryReferenceDefaults())
        typography.setFamily("system", for: .conversation); typography.setPointSize(18, for: .conversation)
        // Same internal public-to-module assembly as the production view. No
        // SavedConversationHistory, private row slice or copied navigation.
        let host = NSHostingView(rootView: EnhancedBookChatView().environmentObject(store).environmentObject(typography)
            .modifier(ReadingPreferencesEnvironment()))
        let parent = NSWindow(contentRect: NSRect(x: 40, y: 60, width: 900, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.isRestorable = false
        parent.title = "ReadingBook history-reference regression (owned)"; parent.contentView = host
        let bindingReceipts = HistoryBindingReceipts()
        let bindingObserver = NotificationCenter.default.addObserver(forName: .init("org.readingbook.history.reference.binding-probe"), object: nil, queue: nil) { bindingReceipts.append($0) }
        defer {
            NotificationCenter.default.removeObserver(bindingObserver)
            if let modal = sheet(of: parent) { parent.endSheet(modal); modal.orderOut(nil) }
            parent.contentView = nil; parent.orderOut(nil); parent.close()
        }
        parent.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait(name + ".empty-real-parent") { NSApp.isActive && parent.isKeyWindow && parent.isVisible &&
            host.bounds.width > 500 && host.bounds.height > 500 && views(host, WKWebView.self).isEmpty }
        try check(name + ".parent-does-not-prewarm-history", store.currentQueryHistory.isEmpty && sheet(of: parent) == nil)
        let message = project.chats[index]
        let prepared = MarkdownReferenceLinks.render(message.content, bookID: project.id, project: project)
        do {
        await store.openInternalURL(URL(string: "readingbook://book/\(project.id)/message/\(message.id)")!)
        let (web, modal, proof, viewport) = try await target(parent: parent, message: message, expected: prepared, fontSize: 18)
        try check(name + ".target-complete-source-and-heading-visible", true)
        let expectedDirectory = store.sourceFileURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs", isDirectory: true)
        try check(name + ".target-source-directory-and-read-only-permission", proof.displayed.directory == expectedDirectory && !proof.displayed.enabled)
        let initialDOM = try await completeDOM(web, expected: prepared, revision: proof.revision)
        try check(name + ".target-complete-dom", initialDOM["exactHTML"] as? Bool == true)
        _ = try await js(web, observer + "\nreturn {installed:!!window.ReadingBookBridgeObservations}")
        try write("target-native.json", proof.evidence, to: caseOutput)
        try write("target-viewport.json", viewport, to: caseOutput)
        try write("target-complete-dom.json", initialDOM, to: caseOutput)
        try write("target-dom-observer.json", try await js(web, "return window.ReadingBookBridgeObservations.describe()"), to: caseOutput)
        var row: [String: Any] = ["name": name, "messageCount": count, "focusIndex": index, "targetID": message.id,
            "projectSHA256": historyReferenceHash(projectBefore), "preparedUTF8Base64": Data(prepared.utf8).base64EncodedString()]
        if count == 60 && index == 58 {
            typography.setPointSize(22, for: .conversation)
            let (afterFont, _, fontProof, fontViewport) = try await target(parent: parent, message: message, expected: prepared, fontSize: 22)
            try check(name + ".font-change-retains-target-wk-and-document", afterFont === web && fontProof.revision == proof.revision)
            try write("font-viewport.json", fontViewport, to: caseOutput)
            let widthBefore = modal.contentView?.bounds.width ?? 0
            let requestedWidth = widthBefore < 700 ? widthBefore + 120 : widthBefore - 120
            try await captureViewport(parent, name: "before-width", output: caseOutput, receipts: bindingReceipts)
            modal.setContentSize(NSSize(width: requestedWidth, height: modal.contentView?.bounds.height ?? 600))
            try await wait(name + ".actual-width-changed") { abs((modal.contentView?.bounds.width ?? 0) - widthBefore) >= 70 }
            try await captureViewport(parent, name: "after-width-immediate", output: caseOutput, receipts: bindingReceipts)
            let (afterWidth, _, widthProof, widthViewport) = try await target(parent: parent, message: message, expected: prepared, fontSize: 22)
            try check(name + ".width-change-retains-target-wk-and-document", afterWidth === web && widthProof.revision == proof.revision)
            let finalDOM = try await completeDOM(afterWidth, expected: prepared, revision: widthProof.revision)
            try check(name + ".reflow-complete-dom", finalDOM["exactHTML"] as? Bool == true)
            try write("width-viewport.json", widthViewport, to: caseOutput)
            try write("reflow-complete-dom.json", finalDOM, to: caseOutput)
            row["reflow"] = ["fontSize": 22, "sheetWidthBefore": widthBefore, "sheetWidthRequested": requestedWidth,
                "sheetWidthAfter": modal.contentView?.bounds.width ?? 0]
            try await sameRowResizeDoesNotReset(afterWidth, modal: modal, expected: prepared, name: name, output: caseOutput)
        }
        if count == 1000 && index == 500 { row["nativeScroll"] = try await userScrollDoesNotSnapBack(web, store: store, name: name) }
        guard let afterProject = store.book, let originalPath = store.sourceFileURL else { throw HistoryReferenceFailure(message: "Original project/source unexpectedly cleared") }
        let projectAfter = try historyReferenceEncoded(afterProject)
        try projectAfter.write(to: caseOutput.appendingPathComponent("project-after.json"), options: .withoutOverwriting)
        try check(name + ".all-project-message-fields-and-bytes-unchanged", projectAfter == projectBefore)
        let diskAfter = try Data(contentsOf: projectURL)
        try check(name + ".canonical-project-file-unchanged", diskAfter == diskBefore)
        let savedNote = try await store.repository.readDocument(bookID: project.id, document: note)
        let sourceAfter = try Data(contentsOf: originalPath)
        try check(name + ".saved-note-source-and-unsent-draft-bytes-unchanged", Data(savedNote.utf8) == Data(noteBody.utf8) &&
            sourceAfter == original && exact(store.queryComposerDraft.text, draft))
        try check(name + ".request-consumed-without-ai", store.queryHistoryMessageID == nil && !store.isQueryBusy &&
            !store.isSmartReadingRunning && !store.isCompanionGenerating && store.savedServices.isEmpty && store.apiKey.isEmpty)
        try write("binding-events.json", bindingReceipts.snapshot(), to: caseOutput)
        try write("case.json", row, to: caseOutput); rows.append(row)
        } catch {
            try? await captureViewport(parent, name: "failure-viewport", output: caseOutput, receipts: bindingReceipts)
            throw error
        }
    }
    static func run() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 5, arguments.last == "--show-window" else {
            fputs("Usage: NativeHistoryReferenceProbe WORKSPACE NEW_OUTPUT_DIRECTORY DOM_OBSERVER --show-window\n", stderr); exit(2)
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let observer = URL(fileURLWithPath: arguments[3]).standardizedFileURL.resolvingSymlinksInPath()
        let env = ProcessInfo.processInfo.environment
        guard output.path.hasPrefix(root.path + "/"), observer.path.hasPrefix(root.path + "/"),
              let fixedHome = env["CFFIXED_USER_HOME"], fixedHome.hasPrefix(root.path + "/.build/"),
              (env["TMPDIR"] ?? "").hasPrefix(root.path + "/.build/"),
              !FileManager.default.fileExists(atPath: output.path) else {
            fputs("Fresh workspace output and workspace-local isolated home/TMPDIR required\n", stderr); exit(2)
        }
        let isolatedHome = URL(fileURLWithPath: fixedHome, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let isolatedTMP = URL(fileURLWithPath: env["TMPDIR"]!, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard isolatedHome.path.hasPrefix(root.path + "/.build/"), isolatedTMP.path.hasPrefix(root.path + "/.build/") else { exit(2) }
        let scratch = isolatedHome.deletingLastPathComponent()
            .appendingPathComponent("history-runs", isDirectory: true).appendingPathComponent(output.lastPathComponent, isDirectory: true)
        var failure: String?
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try historyReferenceRequire(!FileManager.default.fileExists(atPath: scratch.path), "Never reuse fixture scratch")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let helper = try String(contentsOf: observer, encoding: .utf8)
            let cases = [(60, 0), (60, 58), (60, 59), (1000, 0), (1000, 500), (1000, 998)]
            for (count, index) in cases {
                try await runCase(count: count, index: index, output: output, scratch: scratch, observer: helper)
                try await Task.sleep(for: .milliseconds(100))
            }
            try check("all-six-real-history-reference-cases-completed", rows.count == cases.count)
        } catch { failure = String(describing: error) }
        let passed = failure == nil && rows.count == 6 && !checks.isEmpty && checks.values.allSatisfy { $0 }
        var result: [String: Any] = ["schema": 1, "passed": passed, "checks": checks, "cases": rows,
            "pid": getpid(), "observerSHA256": (try? Data(contentsOf: observer)).map(historyReferenceHash) ?? "unreadable",
            "scope": "actual EnhancedBookChatView -> AppStore.openInternalURL(book/message) -> real history sheet; full target source/HTML and h3 in actual clipped native viewport; correctness only",
            "privateReadout": "fail-closed Mirror for fixed Coordinator owner/ready/rendering/revision/height and complete fixed State inventory; no private type casts or shipping factory",
            "scrollScope": "public native NSClipView scroll plus unrelated body refresh; no physical wheel/OS input",
            "productBuildStartedByProbe": false, "realLibraryOpened": false, "realAIRequests": 0,
            "generalClipboardModified": false, "productionModifiedByProbe": false]
        if let failure { result["failure"] = failure }
        try? write("result.json", result, to: output)
        exit(passed ? 0 : 1)
    }
}
