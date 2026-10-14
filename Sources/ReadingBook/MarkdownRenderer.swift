import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers
import ImageIO

/// Offline Markdown + KaTeX. The surrounding SwiftUI ScrollView owns vertical scrolling.
/// A base directory is an explicit grant for relative raster images only, never file links.
struct RichMarkdownView: View {
    let markdown: String
    var baseDirectory: URL?
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 40

    init(markdown: String, baseDirectory: URL? = nil) {
        self.markdown = markdown
        self.baseDirectory = baseDirectory
    }

    var body: some View {
        Group {
            if let resources = MarkdownResources.directory {
                MarkdownWebView(markdown: markdown, baseDirectory: baseDirectory,
                                resources: resources, theme: colorScheme == .dark ? "dark" : "light",
                                height: $contentHeight, onOpenURL: { openURL($0) })
                    .frame(height: max(32, contentHeight))
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
    @Binding var height: CGFloat
    var onOpenURL: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(height: $height, onOpenURL: onOpenURL) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let handler = MarkdownSchemeHandler(resources: resources)
        configuration.setURLSchemeHandler(handler, forURLScheme: MarkdownSchemeHandler.scheme)
        configuration.userContentController.add(context.coordinator, name: "readingbookSize")
        configuration.userContentController.add(context.coordinator, name: "readingbookLink")
        let webView = MarkdownContentWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.webView = webView
        context.coordinator.schemeHandler = handler
        webView.load(URLRequest(url: URL(string: "readingbook-renderer://bundle/index.html")!))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.onOpenURL = onOpenURL
        context.coordinator.update(markdown: markdown, baseDirectory: baseDirectory, theme: theme)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "readingbookSize")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "readingbookLink")
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        struct State: Equatable { let markdown: String; let directory: URL?; let theme: String }
        var height: Binding<CGFloat>
        var onOpenURL: (URL) -> Void
        weak var webView: WKWebView?
        var schemeHandler: MarkdownSchemeHandler?
        private var pending: State?
        private var displayed: State?
        private var ready = false
        private var revision = 0

        init(height: Binding<CGFloat>, onOpenURL: @escaping (URL) -> Void) {
            self.height = height; self.onOpenURL = onOpenURL
        }

        func update(markdown: String, baseDirectory: URL?, theme: String) {
            pending = State(markdown: markdown, directory: baseDirectory, theme: theme)
            renderPending()
        }

        private func renderPending() {
            guard ready, let webView, let state = pending, state != displayed else { return }
            displayed = state; revision += 1
            schemeHandler?.authorize(state.directory, revision: revision)
            // WebKit serializes these arguments. Markdown is never interpolated into JS/HTML.
            webView.callAsyncJavaScript("window.ReadingBookMarkdown.render(markdown, options)",
                                       arguments: ["markdown": state.markdown,
                                                   "options": ["allowImages": state.directory != nil, "theme": state.theme, "revision": revision]],
                                       in: nil, in: .page) { [weak self] result in
                if case .failure(let error) = result {
                    self?.displayed = nil
                    NSLog("ReadingBook offline renderer: %@", error.localizedDescription)
                }
            }
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
                  let body = message.body as? [String: Any] else { return }
            if message.name == "readingbookSize", let measured = body["height"] as? NSNumber,
               let version = body["revision"] as? NSNumber, version.intValue == revision {
                let value = measured.doubleValue
                guard value.isFinite, (1...1_000_000).contains(value), abs(height.wrappedValue - CGFloat(value)) > 1 else { return }
                DispatchQueue.main.async { [weak self] in self?.height.wrappedValue = CGFloat(value) }
            } else if message.name == "readingbookLink", let href = body["href"] as? String,
                      href.utf8.count <= 8_192, let url = URL(string: href) { open(url) }
        }
    }
}

/// The web document fits its content; vertical gestures belong to the SwiftUI parent.
/// Horizontal gestures remain in WebKit for wide equations, tables and code blocks.
private final class MarkdownContentWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift) {
            super.scrollWheel(with: event)
        } else { nextResponder?.scrollWheel(with: event) }
    }
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
