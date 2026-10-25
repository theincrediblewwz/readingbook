import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers
import ImageIO
import os

private let markdownSignposter = OSSignposter(subsystem: "org.readingbook.app", category: "Markdown")

/// A transient selection from this exact trusted render. Rendered text is a semantic
/// excerpt, not a claim that its bytes equal the Markdown source (especially math).
struct RenderedMarkdownSelection: Equatable {
    let text: String
    let sourceMarkdown: String
    let revision: Int
    let containsMath: Bool
}

/// Transient presentation data. Offsets address the exact sourceText UTF-16,
/// never rendered math, transformed Markdown, or OCR coordinates on a PDF page.
struct SourceReadingDecoration: Equatable, Sendable {
    let id: String
    let targetID: String
    let quote: String
    var rangeLocation: Int? = nil
    var rangeLength: Int? = nil
    var prefix: String? = nil
    var suffix: String? = nil
}

struct SourceReadingSelection: Equatable, Sendable {
    let text: String
    var rangeLocation: Int? = nil
    var rangeLength: Int? = nil
    var isExact: Bool = false
    var page: Int? = nil
    var endPage: Int? = nil
}

struct SourceReadingHover: Equatable, Sendable {
    let id: String
    var rect: CGRect
    var point: CGPoint
    var activated = false
    func offsetBy(dx: CGFloat, dy: CGFloat) -> Self {
        var copy = self; copy.rect = rect.offsetBy(dx: dx, dy: dy); copy.point = CGPoint(x: point.x + dx, y: point.y + dy); return copy
    }
}
enum ReaderInlineCoordinateSpace { static let name = "readingbook.inline.reader" }

/// Offline Markdown + KaTeX. The surrounding SwiftUI ScrollView owns vertical scrolling.
/// A base directory is an explicit grant for relative raster images only, never file links.
private struct MarkdownReadingStyleKey: EnvironmentKey { static let defaultValue = "body" }
private struct MarkdownTextScaleKey: EnvironmentKey { static let defaultValue = 1.0 }
extension EnvironmentValues {
    var markdownReadingStyle: String {
        get { self[MarkdownReadingStyleKey.self] }
        set { self[MarkdownReadingStyleKey.self] = newValue }
    }
    var markdownTextScale: Double {
        get { self[MarkdownTextScaleKey.self] }
        set { self[MarkdownTextScaleKey.self] = newValue }
    }
}

struct RichMarkdownView: View {
    let markdown: String
    var baseDirectory: URL?
    var onSelectionChange: ((RenderedMarkdownSelection?) -> Void)?
    var onSelectionSave: ((RenderedMarkdownSelection) -> Void)?
    var sourceText: String?
    var plainText: Bool
    var sourceDecorations: [SourceReadingDecoration]
    var focusedDecorationID: String?
    var onSourceDecorationTap: ((String) -> Void)?
    var onSourceSelection: ((SourceReadingSelection?) -> Void)?
    var onSourceDecorationHover: ((SourceReadingHover?) -> Void)?
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.markdownReadingStyle) private var readingStyle
    @Environment(\.markdownTextScale) private var textScale
    @State private var contentHeight: CGFloat = 40

    init(markdown: String, baseDirectory: URL? = nil,
         onSelectionChange: ((RenderedMarkdownSelection?) -> Void)? = nil,
         onSelectionSave: ((RenderedMarkdownSelection) -> Void)? = nil,
         sourceText: String? = nil, plainText: Bool = false,
         sourceDecorations: [SourceReadingDecoration] = [], focusedDecorationID: String? = nil,
         onSourceDecorationTap: ((String) -> Void)? = nil,
          onSourceSelection: ((SourceReadingSelection?) -> Void)? = nil,
          onSourceDecorationHover: ((SourceReadingHover?) -> Void)? = nil) {
        self.markdown = markdown
        self.baseDirectory = baseDirectory
        self.onSelectionChange = onSelectionChange
        self.onSelectionSave = onSelectionSave
        self.sourceText = sourceText; self.plainText = plainText
        self.sourceDecorations = sourceDecorations; self.focusedDecorationID = focusedDecorationID
        self.onSourceDecorationTap = onSourceDecorationTap; self.onSourceSelection = onSourceSelection
        self.onSourceDecorationHover = onSourceDecorationHover
    }

    var body: some View {
        Group {
            if let resources = MarkdownResources.directory {
              GeometryReader { geometry in
                MarkdownWebView(markdown: markdown, baseDirectory: baseDirectory,
                                resources: resources, theme: colorScheme == .dark ? "dark" : "light", readingStyle: readingStyle, textScale: textScale,
                                height: $contentHeight, onOpenURL: { openURL($0) },
                                onSelectionChange: onSelectionChange, onSelectionSave: onSelectionSave,
                                sourceText: sourceText ?? markdown, plainText: plainText,
                                sourceDecorations: sourceDecorations, focusedDecorationID: focusedDecorationID,
                                onSourceDecorationTap: onSourceDecorationTap, onSourceSelection: onSourceSelection,
                                onSourceDecorationHover: { value in
                                    guard let onSourceDecorationHover else { return }
                                    let origin = geometry.frame(in: .named(ReaderInlineCoordinateSpace.name)).origin
                                    onSourceDecorationHover(value.map { $0.offsetBy(dx: origin.x, dy: origin.y) })
                                })
              }.frame(height: max(32, contentHeight)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text("离线 Markdown / 公式资源缺失，请重新安装完整的 ReadingBook.app。")
                    .foregroundStyle(.secondary).padding()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `swift build`'s generated accessor doesn't search a hand-packed app's Resources.
/// Resolve the shipped bundle first; use Bundle.module only for a development launch.
enum ReadingBookResources {
    static let bundle: Bundle? = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("ReadingBook_ReadingBook.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        guard Bundle.main.bundleURL.pathExtension.lowercased() != "app" else { return nil }
        return Bundle.module
    }()
}

private enum MarkdownResources {
    static let directory = ReadingBookResources.bundle?.url(forResource: "index", withExtension: "html", subdirectory: "Markdown")?.deletingLastPathComponent()
}

private struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    let baseDirectory: URL?
    let resources: URL
    let theme: String
    let readingStyle: String
    let textScale: Double
    @Binding var height: CGFloat
    var onOpenURL: (URL) -> Void
    var onSelectionChange: ((RenderedMarkdownSelection?) -> Void)?
    var onSelectionSave: ((RenderedMarkdownSelection) -> Void)?
    let sourceText: String
    let plainText: Bool
    let sourceDecorations: [SourceReadingDecoration]
    let focusedDecorationID: String?
    var onSourceDecorationTap: ((String) -> Void)?
    var onSourceSelection: ((SourceReadingSelection?) -> Void)?
    var onSourceDecorationHover: ((SourceReadingHover?) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(height: $height, onOpenURL: onOpenURL, onSelectionChange: onSelectionChange) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let handler = MarkdownSchemeHandler(resources: resources)
        configuration.setURLSchemeHandler(handler, forURLScheme: MarkdownSchemeHandler.scheme)
        configuration.userContentController.add(context.coordinator, name: "readingbookSize")
        configuration.userContentController.add(context.coordinator, name: "readingbookLink")
        configuration.userContentController.add(context.coordinator, name: "readingbookSelection")
        configuration.userContentController.add(context.coordinator, name: "readingbookSourceTap")
        configuration.userContentController.add(context.coordinator, name: "readingbookSourceFocus")
        configuration.userContentController.add(context.coordinator, name: "readingbookSourceHover")
        let webView = MarkdownContentWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.selectionForAction = { [weak coordinator = context.coordinator] in coordinator?.selectionForAction() }
        if onSelectionSave != nil {
            webView.saveSelection = { [weak coordinator = context.coordinator] selection in coordinator?.saveSelection(selection) }
        }
        context.coordinator.webView = webView
        context.coordinator.schemeHandler = handler
        webView.load(URLRequest(url: URL(string: "readingbook-renderer://bundle/index.html")!))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.onOpenURL = onOpenURL
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onSelectionSave = onSelectionSave
        context.coordinator.onSourceDecorationTap = onSourceDecorationTap
        context.coordinator.onSourceSelection = onSourceSelection
        context.coordinator.onSourceDecorationHover = onSourceDecorationHover
        if let contentView = webView as? MarkdownContentWebView {
            if onSelectionSave != nil {
                contentView.saveSelection = { [weak coordinator = context.coordinator] selection in coordinator?.saveSelection(selection) }
            } else { contentView.saveSelection = nil }
        }
        context.coordinator.update(markdown: markdown, baseDirectory: baseDirectory, theme: theme, readingStyle: readingStyle, textScale: textScale,
                                   sourceText: sourceText, plainText: plainText, decorations: sourceDecorations,
                                   focusedID: focusedDecorationID)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "readingbookSize")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "readingbookLink")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "readingbookSelection")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "readingbookSourceTap")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "readingbookSourceFocus")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "readingbookSourceHover")
        coordinator.invalidate()
        if let contentView = webView as? MarkdownContentWebView { contentView.selectionForAction = nil; contentView.saveSelection = nil }
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        struct State: Equatable {
            let markdown: String; let directory: URL?; let theme: String; let readingStyle: String; let textScale: Double; let selectionEnabled: Bool
            let sourceText: String; let plainText: Bool; let decorations: [SourceReadingDecoration]
            func sharesDocument(with other: State) -> Bool {
                directory == other.directory && plainText == other.plainText
                    && markdown.utf8.elementsEqual(other.markdown.utf8) && sourceText.utf8.elementsEqual(other.sourceText.utf8)
            }
            static func == (lhs: State, rhs: State) -> Bool {
                lhs.theme == rhs.theme && lhs.readingStyle == rhs.readingStyle && lhs.textScale == rhs.textScale
                    && lhs.selectionEnabled == rhs.selectionEnabled && lhs.decorations == rhs.decorations && lhs.sharesDocument(with: rhs)
            }
        }
        var height: Binding<CGFloat>
        var onOpenURL: (URL) -> Void
        var onSelectionChange: ((RenderedMarkdownSelection?) -> Void)?
        var onSelectionSave: ((RenderedMarkdownSelection) -> Void)?
        var onSourceDecorationTap: ((String) -> Void)?
        var onSourceSelection: ((SourceReadingSelection?) -> Void)?
        var onSourceDecorationHover: ((SourceReadingHover?) -> Void)?
        weak var webView: WKWebView?
        var schemeHandler: MarkdownSchemeHandler?
        private var pending: State?
        private var displayed: State?
        private var ready = false
        private var revision = 0
        private var lastSelection: RenderedMarkdownSelection?
        private var focusedID: String?
        private var displayedFocusID: String?
        private var rendering = false

        init(height: Binding<CGFloat>, onOpenURL: @escaping (URL) -> Void,
             onSelectionChange: ((RenderedMarkdownSelection?) -> Void)?) {
            self.height = height; self.onOpenURL = onOpenURL; self.onSelectionChange = onSelectionChange
        }

        func update(markdown: String, baseDirectory: URL?, theme: String, readingStyle: String, textScale: Double, sourceText: String,
                    plainText: Bool, decorations: [SourceReadingDecoration], focusedID: String?) {
            pending = State(markdown: markdown, directory: baseDirectory, theme: theme, readingStyle: readingStyle, textScale: textScale.isFinite ? min(1.6, max(0.8, textScale)) : 1,
                            selectionEnabled: onSelectionChange != nil || onSourceSelection != nil,
                            sourceText: sourceText, plainText: plainText, decorations: Array(decorations.prefix(1_000)))
            self.focusedID = focusedID
            renderPending()
            focusPending()
        }

        func invalidate() { ready = false; rendering = false; revision += 1; pending = nil; displayed = nil; lastSelection = nil; onSelectionChange = nil; onSelectionSave = nil; onSourceSelection = nil; onSourceDecorationTap = nil; onSourceDecorationHover = nil }

        // Native menu/keyboard actions only reuse a selection admitted by the
        // existing main-frame bridge, and revalidate it when the action fires.
        func selectionForAction() -> RenderedMarkdownSelection? {
            guard ready, onSelectionSave != nil, let state = displayed, state == pending, state.selectionEnabled,
                  let selection = lastSelection, selection.revision == revision,
                  selection.sourceMarkdown == state.markdown else { return nil }
            return selection
        }
        func saveSelection(_ selection: RenderedMarkdownSelection) {
            guard selectionForAction() == selection else { return }
            onSelectionSave?(selection)
        }

        private func renderPending() {
            guard ready, !rendering, let webView, let state = pending, state != displayed else { return }
            let previous = displayed
            let replacesDocument = previous.map { !state.sharesDocument(with: $0) } ?? true
            displayed = state; rendering = true
            if replacesDocument { revision += 1 }
            displayedFocusID = nil
            if replacesDocument { lastSelection = nil }
            let renderedRevision = revision
            if replacesDocument {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.revision == renderedRevision else { return }
                    self.onSelectionChange?(nil)
                    self.onSourceSelection?(nil)
                }
                schemeHandler?.authorize(state.directory, revision: revision)
            }
            let decorations: [[String: Any]] = state.decorations.map { decoration in
                var item: [String: Any] = ["id": decoration.id, "targetID": decoration.targetID, "quote": decoration.quote]
                if let location = decoration.rangeLocation, let length = decoration.rangeLength {
                    item["rangeLocation"] = location; item["rangeLength"] = length
                }
                return item
            }
            let options: [String: Any] = ["allowImages": state.directory != nil, "theme": state.theme, "readingStyle": state.readingStyle, "textScale": state.textScale,
                                          "revision": revision, "selectionEnabled": state.selectionEnabled,
                                          "sourceText": state.sourceText, "plainText": state.plainText,
                                          "sourceDecorations": decorations]
            // WebKit serializes these arguments. Markdown is never interpolated into JS/HTML.
            let script = replacesDocument
                ? "window.ReadingBookMarkdown.render(markdown, options)"
                : "window.ReadingBookMarkdown.updatePresentation(options); window.ReadingBookMarkdown.updateDecorations(options.sourceDecorations, options)"
            let intervalName: StaticString = replacesDocument ? "RenderMarkdownBody" : "UpdateMarkdownPresentation"
            let interval = markdownSignposter.beginInterval(intervalName)
            webView.callAsyncJavaScript(script,
                                       arguments: ["markdown": state.markdown, "options": options],
                                       in: nil, in: .page) { [weak self] result in
                markdownSignposter.endInterval(intervalName, interval)
                guard let self, self.revision == renderedRevision else { return }
                self.rendering = false
                if case .failure(let error) = result {
                    self.displayed = nil
                    NSLog("ReadingBook offline renderer: %@", error.localizedDescription)
                } else { self.renderPending(); self.focusPending() }
            }
        }

        private func focusPending() {
            guard ready, !rendering, displayed == pending, let focusedID, displayedFocusID != focusedID,
                  displayed?.decorations.contains(where: { $0.id == focusedID }) == true, let webView else { return }
            displayedFocusID = focusedID
            webView.callAsyncJavaScript("window.ReadingBookMarkdown.focusDecoration(id)", arguments: ["id": focusedID], in: nil, in: .page) { _ in }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true; renderPending()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.scheme == MarkdownSchemeHandler.scheme, url.host == "bundle", url.path == "/index.html", action.navigationType != .linkActivated {
                decisionHandler(.allow); return
            }
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated { open(url) }
        }

        private func open(_ url: URL) {
            guard ["readingbook", "https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
            onOpenURL(url)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.webView === webView,
                  message.frameInfo.request.url?.host == "bundle",
                  message.frameInfo.request.url?.scheme == MarkdownSchemeHandler.scheme,
                  message.frameInfo.request.url?.path == "/index.html",
                  let body = message.body as? [String: Any] else { return }
            if message.name == "readingbookSize", let measured = body["height"] as? NSNumber,
               let version = body["revision"] as? NSNumber, version.intValue == revision {
                let value = measured.doubleValue
                guard value.isFinite, (1...1_000_000).contains(value), abs(height.wrappedValue - CGFloat(value)) > 1 else { return }
                let measuredRevision = revision
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.revision == measuredRevision else { return }
                    self.height.wrappedValue = CGFloat(value)
                }
            } else if message.name == "readingbookLink", let href = body["href"] as? String,
                      let version = body["revision"] as? NSNumber, version.intValue == revision,
                      href.utf8.count <= 8_192, let url = URL(string: href) { open(url) }
            else if message.name == "readingbookSourceHover", let version = body["revision"] as? NSNumber, version.intValue == revision {
                if body["leaving"] as? Bool == true { onSourceDecorationHover?(nil); return }
                guard displayed == pending, let id = body["id"] as? String, displayed?.decorations.contains(where: { $0.id == id }) == true,
                      let rect = body["rect"] as? [String: NSNumber], let x = rect["x"]?.doubleValue, let y = rect["y"]?.doubleValue,
                      let width = rect["width"]?.doubleValue, let height = rect["height"]?.doubleValue,
                      [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0, abs(x) <= 1_000_000, abs(y) <= 1_000_000 else { return }
                onSourceDecorationHover?(SourceReadingHover(id: id, rect: CGRect(x: x, y: y, width: width, height: height), point: CGPoint(x: x + width / 2, y: y + height), activated: body["activated"] as? Bool == true))
            }
            else if message.name == "readingbookSourceTap", let version = body["revision"] as? NSNumber,
                    version.intValue == revision, let id = body["id"] as? String,
                    displayed == pending, displayed?.decorations.contains(where: { $0.id == id }) == true {
                onSourceDecorationTap?(id)
            } else if message.name == "readingbookSourceFocus", let version = body["revision"] as? NSNumber,
                      version.intValue == revision, let y = body["y"] as? NSNumber, let h = body["height"] as? NSNumber,
                      y.doubleValue.isFinite, h.doubleValue.isFinite, y.doubleValue >= 0, h.doubleValue > 0,
                      let webView, y.doubleValue <= Double(webView.bounds.height) {
                let top = CGFloat(y.doubleValue), length = min(CGFloat(h.doubleValue), webView.bounds.height - top)
                let localY = webView.isFlipped ? top : webView.bounds.height - top - length
                _ = webView.scrollToVisible(CGRect(x: 0, y: localY, width: webView.bounds.width, height: length))
            }
            else if message.name == "readingbookSelection", let version = body["revision"] as? NSNumber,
                    version.intValue == revision, let state = displayed, state == pending, state.selectionEnabled,
                    let selected = body["text"] as? String, selected.utf8.count <= 131_072,
                    let containsMath = body["containsMath"] as? Bool {
                if selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastSelection = nil; onSelectionChange?(nil); onSourceSelection?(nil) }
                else {
                    let selection = RenderedMarkdownSelection(text: selected, sourceMarkdown: state.markdown,
                                                              revision: revision, containsMath: containsMath)
                    lastSelection = selection; onSelectionChange?(selection)
                    var sourceSelection = SourceReadingSelection(text: selected)
                    if let location = body["sourceLocation"] as? NSNumber, let length = body["sourceLength"] as? NSNumber,
                       location.intValue >= 0, length.intValue > 0,
                       location.intValue <= (state.sourceText as NSString).length - length.intValue,
                       (state.sourceText as NSString).substring(with: NSRange(location: location.intValue, length: length.intValue)) == selected {
                        sourceSelection.rangeLocation = location.intValue; sourceSelection.rangeLength = length.intValue
                        sourceSelection.isExact = true
                    }
                    onSourceSelection?(sourceSelection)
                }
            }
        }
    }
}

/// The web document fits its content; vertical gestures belong to the SwiftUI parent.
/// Horizontal gestures remain in WebKit for wide equations, tables and code blocks.
private final class MarkdownContentWebView: WKWebView {
    var selectionForAction: (() -> RenderedMarkdownSelection?)?
    var saveSelection: ((RenderedMarkdownSelection) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard saveSelection != nil else { return }
        let item = NSMenuItem(title: "保存选区为语义摘记…", action: nil, keyEquivalent: "")
        item.toolTip = "先预览再保存；精确公式请选择 Markdown 源文片段。"
        if let selection = selectionForAction?() {
            let action = MarkdownSelectionMenuAction(owner: self, selection: selection)
            item.action = #selector(MarkdownSelectionMenuAction.invoke(_:)); item.target = action
            item.representedObject = action
        } else { item.isEnabled = false }
        menu.addItem(.separator()); menu.addItem(item)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "s",
           let responder = window?.firstResponder as? NSView, responder === self || responder.isDescendant(of: self),
           let selection = selectionForAction?() {
            saveSelection?(selection); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift) {
            super.scrollWheel(with: event)
        } else { nextResponder?.scrollWheel(with: event) }
    }
}

private final class MarkdownSelectionMenuAction: NSObject, NSMenuItemValidation {
    weak var owner: MarkdownContentWebView?
    let selection: RenderedMarkdownSelection
    init(owner: MarkdownContentWebView, selection: RenderedMarkdownSelection) { self.owner = owner; self.selection = selection }
    @objc func invoke(_ sender: NSMenuItem) {
        guard owner?.selectionForAction?() == selection else { return }
        owner?.saveSelection?(selection)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { owner?.selectionForAction?() == selection }
}

/// No file:// read grant is ever given to WebKit. Both bundled assets and explicitly
/// authorized local images pass through these exact path/type/size checks instead.
private final class MarkdownSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "readingbook-renderer"
    private let resources: URL
    private let lock = NSLock()
    private var imageDirectory: URL?
    private var imageRevision = 0

    init(resources: URL) { self.resources = resources.standardizedFileURL.resolvingSymlinksInPath() }

    func authorize(_ directory: URL?, revision: Int) {
        lock.lock(); defer { lock.unlock() }
        imageDirectory = directory?.standardizedFileURL.resolvingSymlinksInPath()
        imageRevision = revision
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard let url = task.request.url, url.scheme == Self.scheme, url.user == nil, url.password == nil, url.port == nil else { throw failure("无效资源地址") }
            let data: Data, mime: String
            if url.host == "bundle" {
                let path = try checkedPath(url, root: resources)
                let ext = path.pathExtension.lowercased()
                guard ["html", "css", "js", "woff2"].contains(ext), url.query == nil else { throw failure("非渲染资源") }
                data = try read(path, maximum: 4 * 1_024 * 1_024)
                mime = ["html": "text/html", "css": "text/css", "js": "application/javascript", "woff2": "font/woff2"][ext]!
            } else if url.host == "image" {
                lock.lock(); let root = imageDirectory; let version = imageRevision; lock.unlock()
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard let root, root.isFileURL, query.count == 1,
                      query[0].name == "v", query[0].value == String(version) else { throw failure("图片目录未授权") }
                let path = try checkedPath(url, root: root)
                let ext = path.pathExtension.lowercased()
                guard ["png", "jpg", "jpeg", "gif", "webp", "heic", "avif"].contains(ext) else { throw failure("仅允许本地栅格图片") }
                data = try read(path, maximum: 16 * 1_024 * 1_024)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                      let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
                      width.doubleValue > 0, height.doubleValue > 0,
                      width.doubleValue * height.doubleValue <= 40_000_000 else { throw failure("图片尺寸过大或格式无效") }
                mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            } else { throw failure("未知资源域") }
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": mime, "Content-Length": String(data.count),
                                                                "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store",
                                                                "Access-Control-Allow-Origin": "*"]) else { throw failure("资源响应无效") }
            task.didReceive(response); task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { }

    private func checkedPath(_ request: URL, root: URL) throws -> URL {
        let components = request.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !components.isEmpty, components.count <= 32, request.path.utf8.count <= 2_048,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw failure("资源路径越界") }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else { throw failure("资源根不是文件夹") }
        var path = root
        for component in components {
            path.appendPathComponent(String(component))
            let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw failure("不读取符号链接图片") }
        }
        guard path.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw failure("资源路径越界") }
        return path
    }

    private func read(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= maximum else { throw failure("资源过大或不是普通文件") }
        let data = try Data(contentsOf: url)
        guard data.count == size, data.count <= maximum else { throw failure("资源读取期间发生变化") }
        return data
    }

    private func failure(_ message: String) -> NSError { NSError(domain: "ReadingBook.Markdown", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
