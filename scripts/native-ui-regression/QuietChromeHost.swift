import AppKit
import SwiftUI
import PDFKit
import ImageIO
@testable import ReadingCore
@testable import ReadingBook

@MainActor final class QuietChromeRunner: NSObject, NSApplicationDelegate, ObservableObject {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUIET_CHROME_DIR"]!)
    var store: AppStore!, window: NSWindow!, tools: NSWindow!
    @Published var notice = "准备合成书库"
    var serial = 0
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await start() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func start() async {
        do {
            installMenus()
            UserDefaults.standard.setVolatileDomain(["library.root.path.v1": directory.appendingPathComponent("library").path,
                "service-profiles": Data("[]".utf8), "reader.hoverAutoTranslation": false,
                "appearance.reduceMotion": false, "NSQuitAlwaysKeepsWindows": false], forName: UserDefaults.argumentDomain)
            store = AppStore()
            if ProcessInfo.processInfo.environment["QUIET_USE_LIBRARY"] != "1" {
            let source = directory.appendingPathComponent("fixture.pdf")
            var box = CGRect(x: 0, y: 0, width: 600, height: 800)
            let graphics = CGContext(source as CFURL, mediaBox: &box, nil)!
            for page in 1...14 {
                graphics.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics, flipped: false)
                for line in 0..<14 {
                    let text = line == 2 || line == 5 ? "Same sentence. This is the second part." : "Page \(page), line \(line). Reading should stay calm and clear."
                    NSString(string: text).draw(at: CGPoint(x: 35, y: 720 - line * 40), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black])
                }
                NSGraphicsContext.restoreGraphicsState(); graphics.endPDFPage()
            }
            graphics.closePDF()
            let imported = try await BookImporter.importFile(at: source)
            for index in 1...20 {
                var project = BookProject(title: "隔离书 \(String(format: "%02d", index)) · 这是一个需要完整显示的长书名", originalName: "fixture.pdf", sourceHash: imported.sourceHash, units: imported.units)
                PluginEngine.seed(&project); project = try await store.repository.create(project, sourceURL: source)
                store.books.append(project)
            }
            }
            if ProcessInfo.processInfo.environment["QUIET_USE_LIBRARY"] == "1" { store.books = try await store.repository.loadAll() }
            let first = store.books[0]
            store.bookID = first.id; store.selectedUnitID = first.units.first?.id
            store.sourceFileURL = await store.repository.sourceURL(for: first)
            store.workspaceMemory = .init(bookID: first.id, sourceHash: first.sourceHash)
            store.refreshReadingExperienceIndex(); store.route = "library"
            window = NSWindow(contentRect: .init(x: 190, y: 80, width: 1080, height: 740), styleMask: [.titled,.closable,.resizable,.fullSizeContentView], backing: .buffered, defer: false)
            window.title = "ReadingBook 清爽阅读与封面 · 隔离测试"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: WorkspaceView().environmentObject(store).environmentObject(ReadingTypographySettings()).modifier(ReadingPreferencesEnvironment()))
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            if ProcessInfo.processInfo.environment["QUIET_USE_LIBRARY"] == "1" {
                store.bookID = nil
                await store.selectBook(first.id, preferredRoute: "reader")
                window.setContentSize(.init(width: 1470, height: 856)); window.setFrameOrigin(.zero)
            }
            tools = NSWindow(contentRect: .init(x: 0, y: 160, width: 185, height: 460), styleMask: [.titled,.closable], backing: .buffered, defer: false)
            tools.title = "隔离检查控制"; tools.contentView = NSHostingView(rootView: QuietChromeControls(runner: self)); tools.orderFront(nil)
            notice = "隔离书库，无真实模型请求"
            try await record("ready")
            watchMenus()
        } catch { notice = error.localizedDescription; try? Data(notice.utf8).write(to: directory.appendingPathComponent("error.txt")) }
    }
    func descendants<T: NSView>(_ root: NSView, _: T.Type) -> [T] { (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, T.self) } }
    func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { allViews($0) } }
    func installMenus() {
        let main = NSMenu(), app = NSMenuItem(), edit = NSMenuItem(), tests = NSMenuItem()
        let appMenu = NSMenu(title: "测试应用"), editMenu = NSMenu(title: "编辑"), testMenu = NSMenu(title: "隔离检查")
        app.submenu = appMenu; edit.submenu = editMenu; tests.submenu = testMenu
        main.addItem(app); main.addItem(edit); main.addItem(tests); NSApp.mainMenu = main
        appMenu.addItem(withTitle: "结束测试", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { editMenu.addItem(withTitle: title, action: action, keyEquivalent: key) }
        for (title, action, key) in [("阅读", #selector(goReader), "1"), ("书库", #selector(goLibrary), "2"),
            ("合成封面", #selector(crop), "3"), ("记录现场", #selector(capture), "4"), ("添加合成便签", #selector(seedNote), "5"),
            ("窄窗", #selector(narrow), "7"), ("宽窗", #selector(wide), "8")] {
            let item = testMenu.addItem(withTitle: title, action: action, keyEquivalent: key); item.target = self
        }
    }
    @objc func goReader() { route("reader") }
    @objc func goLibrary() { route("library") }
    @objc func narrow() { window.setContentSize(.init(width: 800, height: 640)) }
    @objc func wide() { window.setContentSize(.init(width: 1080, height: 740)) }
    @objc func seedNote() {
        guard let project = store.book, let unit = project.units.first else { return }
        Task {
            do {
                let saved = try await store.repository.saveDocument(project: project, document: .init(id: "menu-note", title: "定位测试便签"), markdown: "隔离便签，原书不改。", notePlacement: .init(sourceHash: project.sourceHash, unitID: unit.id, page: unit.page, x: 0.4, y: 0.45))
                store.publish(saved); store.positionNoteRequest = nil
            } catch { notice = error.localizedDescription }
        }
    }
    func route(_ route: String) { store.route = route; window.makeKeyAndOrderFront(nil) }
    @objc func crop() {
        guard let project = store.book else { return }
        do {
            let context = CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for (i, color) in [NSColor.systemRed, .systemGreen, .systemBlue, .systemOrange].enumerated() {
                context.setFillColor(color.cgColor); context.fill(CGRect(x: i * 200, y: 0, width: 200, height: 500))
            }
            let output = NSMutableData(), destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
            try (output as Data).write(to: directory.appendingPathComponent("crop-source.png"))
            store.bookCoverCropRequest = BookCoverCropRequest(project: project, owner: WorkspacePickerOwner(store: store), image: try BookCoverCropImage(data: output as Data))
            window.makeKeyAndOrderFront(nil)
        } catch { notice = error.localizedDescription }
    }
    @objc func capture() { serial += 1; Task { try? await record("capture-\(serial)") } }
    func watchMenus() {
        Task { @MainActor in
            var previous = "", index = 0
            while window.isVisible {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let root = window.contentView, let pdf = descendants(root, PDFView.self).first,
                      let context = Mirror(reflecting: pdf).children.first(where: { $0.label == "readingContext" })?.value as? ReadingContextPopover,
                      let popover = Mirror(reflecting: context).children.first(where: { $0.label == "popover" })?.value as? NSPopover,
                      popover.isShown, let popWindow = popover.contentViewController?.view.window else { previous = ""; continue }
                let key = NSStringFromRect(popover.positioningRect) + NSStringFromRect(popWindow.frame)
                guard key != previous else { continue }; previous = key; index += 1
                let rect = popover.positioningRect, screen = window.convertToScreen(pdf.convert(rect, to: nil as NSView?))
                let value: [String: Any] = ["positioningRect": NSStringFromRect(rect), "anchorScreen": NSStringFromRect(screen),
                    "popoverScreen": NSStringFromRect(popWindow.frame), "pdfBounds": NSStringFromRect(pdf.bounds),
                    "pdfFrame": NSStringFromRect(pdf.frame), "pdfFlipped": pdf.isFlipped,
                    "pointerWindow": NSStringFromPoint(window.mouseLocationOutsideOfEventStream),
                    "window": NSStringFromRect(window.frame)]
                try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("menu-geometry-\(index).json"))
            }
        }
    }
    func record(_ tag: String) async throws {
        var value: [String: Any] = ["tag": tag, "pid": ProcessInfo.processInfo.processIdentifier, "route": store.route,
            "bookCount": store.books.count, "bookID": store.bookID ?? "", "window": NSStringFromRect(window.frame),
            "error": store.errorMessage ?? "", "realModelRequests": 0]
        if let book = store.book {
            let source = await store.repository.sourceURL(for: book)
            value["book"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(book))
            value["decorationCount"] = store.pdfSourceReadingDecorations.count
            value["sourceSHA256"] = try BookImporter.sha256(Data(contentsOf: source))
            if let data = try await store.repository.bookCoverData(for: book) { try data.write(to: directory.appendingPathComponent(tag + "-cover.jpg")) }
        }
        if let root = window.contentView, let pdf = descendants(root, PDFView.self).first {
            value["pdfIdentity"] = String(describing: ObjectIdentifier(pdf)); value["scale"] = pdf.scaleFactor
            value["page"] = pdf.currentPage.flatMap { pdf.document?.index(for: $0) }.map { $0 + 1 }
            value["annotationCount"] = pdf.document?.page(at: 0)?.annotations.count ?? 0
            value["pdfFrame"] = NSStringFromRect(root.convert(pdf.bounds, from: pdf))
            if let results = allViews(root).compactMap({ $0 as? PDFSearchResultsList }).first {
                value["searchEntries"] = results.entries.prefix(100).map { entry -> [String: Any] in
                    let text = (pdf.document?.page(at: entry.page - 1)?.string ?? "") as NSString
                    let valid = entry.range.location >= 0 && entry.range.location <= text.length && entry.range.length <= text.length - entry.range.location
                    return ["index": entry.index, "page": entry.page, "range": NSStringFromRange(entry.range), "match": entry.match,
                        "pageTextLength": text.length, "nativeMatch": valid ? text.substring(with: entry.range) : "INVALID"]
                }
            }
            if let thumbnails = allViews(root).compactMap({ $0 as? PDFThumbnailView }).first {
                value["thumbnailSize"] = NSStringFromSize(thumbnails.thumbnailSize)
                value["thumbnailColumns"] = thumbnails.maximumNumberOfColumns
            }
            value["nativeViews"] = allViews(root).filter { $0 is NSButton || $0 is NSScrollView || $0 is PDFThumbnailView || $0 is NSSearchField || $0 is PositionNoteNativeHost || String(describing: type(of: $0)).contains("Glass") || String(describing: type(of: $0)).contains("FloatingPanel") }.map { view -> [String: Any] in
                let rect = root.convert(view.bounds, from: view), center = CGPoint(x: rect.midX, y: rect.midY)
                let hit = root.hitTest(root.superview?.convert(center, from: root) ?? center)
                return ["type": String(describing: type(of: view)), "frame": NSStringFromRect(view.frame), "bounds": NSStringFromRect(view.bounds),
                    "rootRect": NSStringFromRect(rect), "hidden": view.isHiddenOrHasHiddenAncestor,
                    "label": (view as? NSButton)?.toolTip ?? (view as? NSSearchField)?.placeholderString ?? "",
                    "hit": hit.map { String(describing: type(of: $0)) } ?? "none", "hitOwnControl": hit === view || hit?.isDescendant(of: view) == true]
            }
        }
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent(tag + ".json"))
        notice = "已记录 " + tag
    }
}

struct QuietChromeControls: View {
    @ObservedObject var runner: QuietChromeRunner
    var body: some View {
        VStack(spacing: 10) {
            Text(runner.notice).font(.caption).multilineTextAlignment(.center)
            Button("阅读") { runner.route("reader") }
            Button("书库") { runner.route("library") }
            Button("裁剪合成封面") { runner.crop() }
            Button("窄窗") { runner.window.setContentSize(.init(width: 800, height: 640)) }
            Button("恢复宽窗") { runner.window.setContentSize(.init(width: 1080, height: 740)) }
            Button("切换另一书") { if runner.store.books.count > 1 { Task { await runner.store.selectBook(runner.store.books[1].id, preferredRoute: "reader") } } }
            Button("保存现场") { runner.capture() }
            Button("结束测试") { NSApp.terminate(nil) }
        }.buttonStyle(.bordered).padding(10).frame(width: 175)
    }
}
@main enum QuietChromeMain {
    static func main() { let app = NSApplication.shared; app.setActivationPolicy(.regular); let runner = QuietChromeRunner(); app.delegate = runner; app.run(); withExtendedLifetime(runner) {} }
}
