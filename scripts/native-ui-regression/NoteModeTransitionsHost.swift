import AppKit
import PDFKit
import SwiftUI
@testable import ReadingBook
@testable import ReadingCore

/// Checks the rendered SwiftUI/AppKit margin, not just the published PDF points.
/// Without this distinction an oversized ZStack can shift every correct point.
@MainActor final class NoteModeTransitionsRunner: NSObject, NSApplicationDelegate {
    let output: URL
    let controller = PDFReaderController()
    var store: AppStore!, window: NSWindow!, original: PDFDocument!, source: URL!
    var page = 2, checks: [String: Bool] = [:], samples: [[String: Any]] = []
    init(_ output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
    func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
    }
    func settle() async {
        for _ in 0..<12 { window.contentView?.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) }
    }
    func topLeft(_ rect: CGRect, in reader: NSView) -> CGRect {
        reader.isFlipped ? rect : CGRect(x: rect.minX, y: reader.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }
    func snapshot(_ tag: String, requireNote: Bool = true) {
        guard let root = window.contentView, let reader = descendants(root, PDFReaderContainerView.self).first,
              let pdf = descendants(reader, PDFView.self).first, let document = pdf.document else { checks[tag + ".reader"] = false; return }
        let surfaces = controller.notePositions.surfaces
        var hosts = descendants(root, PositionNoteNativeHost.self)
        var rows: [[String: Any]] = [], allFrames = true
        for surface in surfaces {
            let frames = hosts.map { topLeft(reader.convert($0.bounds, from: $0), in: reader) }
            func distance(_ rect: CGRect) -> CGFloat {
                max(abs(rect.minX-surface.frame.minX), abs(rect.minY-surface.frame.minY),
                    abs(rect.width-surface.frame.width), abs(rect.height-surface.frame.height))
            }
            let best = frames.indices.min { distance(frames[$0]) < distance(frames[$1]) }
            let actual = best.map { frames[$0] } ?? .null
            let error = best.map { distance(frames[$0]) } ?? 1_000_000
            rows.append(["page": surface.id, "expected": NSStringFromRect(surface.frame), "actualHost": NSStringFromRect(actual),
                         "errorPoints": error, "noteIDs": surface.noteIDs.sorted()])
            if let best { hosts.remove(at: best) }
            allFrames = allFrames && error <= 1
        }
        checks[tag + ".renderedHostMatchesPageGutter"] = !surfaces.isEmpty && allFrames
        let visible = Set(pdf.visiblePages.map { document.index(for: $0) + 1 })
        let placements = store.activeNotePlacements
        var anchorErrors: [String: Double] = [:]
        for (id, placement) in placements where visible.contains(placement.page ?? -1) {
            guard let number = placement.page, let originalPage = original.page(at: number-1), let native = document.page(at: number-1) else { continue }
            // This PDF was loaded independently from source bytes before the UI
            // document acquired any display-only boxes.
            let box = originalPage.bounds(for: .cropBox)
            let p = CGPoint(x: box.minX + box.width * placement.x, y: box.minY + box.height * placement.y)
            let local = reader.convert(pdf.convert(p, from: native), from: pdf)
            let expected = reader.isFlipped ? local : CGPoint(x: local.x, y: reader.bounds.height-local.y)
            let actual = controller.notePositions.points[id]
            anchorErrors[id] = actual.map { hypot($0.x-expected.x, $0.y-expected.y) } ?? 1_000_000
        }
        checks[tag + ".anchorsMatchIndependentSourcePage"] = !anchorErrors.isEmpty && anchorErrors.values.allSatisfy { $0 < 0.5 }
        if requireNote {
            checks[tag + ".boundPageRemainsVisible"] = visible.contains(page)
            checks[tag + ".noteHasOwnSurface"] = surfaces.contains { $0.id == page && !$0.noteIDs.isEmpty }
        }
        let sameOwner = controller.notePositions.owner == store.collectionOwnerKey
        checks[tag + ".interactiveLayerVisible"] = sameOwner && !controller.notePositions.navigationObscured && !controller.notePositions.paperTurnActive
        samples.append(["tag": tag, "page": controller.page, "fit": controller.fitMode, "direction": controller.direction.rawValue,
                        "continuous": controller.isContinuous, "paperBook": controller.paperBookMode, "scale": pdf.scaleFactor,
                        "viewport": NSStringFromRect(reader.bounds), "surfaces": rows, "anchorErrors": anchorErrors,
                        "visiblePages": visible.sorted(), "hostCount": descendants(root, PositionNoteNativeHost.self).count,
                        "scrollerStyle": descendants(pdf, NSScrollView.self).first?.scrollerStyle == .overlay ? "overlay" : "legacy"])
        write()
    }
    func write() {
        let record: [String: Any] = ["status": checks.values.allSatisfy { $0 } ? "passed" : "failed", "checks": checks,
            "samples": samples, "realModelRequests": 0]
        try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("result.json"))
    }
    func pan(_ direction: PDFReadingDirection, points: CGFloat) async {
        if let root = window.contentView, let pdf = descendants(root, PDFView.self).first,
           let scroll = descendants(pdf, NSScrollView.self).first {
            let clip = scroll.contentView, old = clip.bounds.origin
            let proposed = direction == .horizontal ? CGPoint(x: old.x+points, y: old.y)
                : CGPoint(x: old.x, y: old.y + points * (clip.documentView?.isFlipped == true ? 1 : -1))
            clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: proposed, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
        }
        await settle()
    }
    func run() async {
        do {
            UserDefaults.standard.setVolatileDomain(["library.root.path.v1": output.appendingPathComponent("library").path,
                "service-profiles": Data("[]".utf8), "appearance.reduceMotion": true, "reader.hoverAutoTranslation": false,
                "AppleShowScrollBars": ProcessInfo.processInfo.environment["NOTE_SCROLLER_STYLE"] == "overlay" ? "WhenScrolling" : "Always"], forName: UserDefaults.argumentDomain)
            store = AppStore()
            if ProcessInfo.processInfo.environment["NOTE_USE_LIBRARY"] == "1" {
                store.books = try await store.repository.loadAll()
                let book = store.books[0]; page = store.activeNotePlacements.values.compactMap(\.page).first ?? 104
                store.bookID = book.id; store.selectedUnitID = book.units.first { $0.page == page }?.id
                source = await store.repository.sourceURL(for: book)
            } else {
                source = output.appendingPathComponent("synthetic.pdf")
                var box = CGRect(x: 0, y: 0, width: 600, height: 800)
                let context = CGContext(source as CFURL, mediaBox: &box, nil)!
                for number in 1...4 {
                    context.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                    for line in 0..<16 { NSString(string: "Page \(number) line \(line): keep the note beside this page.").draw(at: .init(x: 30, y: 750-line*43), withAttributes: [.font: NSFont.systemFont(ofSize: 18)]) }
                    NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
                }; context.closePDF()
                var book = BookProject(title: "便签模式切换 · 合成书", originalName: "synthetic.pdf", sourceHash: try BookImporter.sha256(Data(contentsOf: source)),
                    units: (1...4).map { .init(id: "p\($0)", order: $0-1, chapter: "第\($0)章", page: $0, text: "Page \($0)") })
                PluginEngine.seed(&book); book = try await store.repository.create(book, sourceURL: source)
                for number in [2,3] {
                    book = try await store.repository.saveDocument(project: book, document: .init(id: "note-\(number)", title: "位置笔记"),
                        markdown: "Only page \(number).", notePlacement: .init(sourceHash: book.sourceHash, unitID: "p\(number)", page: number, x: 0.89, y: 0.90))
                }
                store.books = [book]; store.bookID = book.id; store.selectedUnitID = "p2"
                source = await store.repository.sourceURL(for: book)
            }
            let sourceBefore = try Data(contentsOf: source); original = PDFDocument(data: sourceBefore)!
            let projectBefore = store.book!, placementsBefore = store.activeNotePlacements
            store.sourceFileURL = source; store.workspaceMemory = .init(bookID: projectBefore.id, sourceHash: projectBefore.sourceHash)
            let view = ReaderWorkspaceView(showPDF: .constant(true), showOutline: .constant(false), bookmarksOnly: .constant(false))
                .environmentObject(store).environmentObject(controller).environmentObject(ReadingTypographySettings()).modifier(ReadingPreferencesEnvironment())
            window = NSWindow(contentRect: .init(x: 100, y: 80, width: 1470, height: 856), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
            window.title = "ReadingBook 便签模式切换 · 隔离回归"; window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            for _ in 0..<200 { if controller.isReady { break }; try await Task.sleep(for: .milliseconds(20)) }
            controller.command(.setContinuous(true)); controller.command(.setDirection(.vertical)); controller.command(.jump(page)); controller.command(.fitPage); await settle()
            // Reproduce the user's previous-page / noted-page boundary in the
            // very same mounted reader, then change scale without a jump.
            await pan(.vertical, points: -180); snapshot("boundary-page")
            controller.command(.fitWidth); await settle(); snapshot("boundary-width")
            controller.command(.setDirection(.horizontal)); await settle(); snapshot("boundary-horizontal")
            for continuous in [true,false] {
                controller.command(.setContinuous(continuous)); await settle()
                for direction in [PDFReadingDirection.vertical, .horizontal] {
                    controller.command(.setDirection(direction)); controller.command(.jump(page)); await settle()
                    for width in [false,true] {
                        controller.command(width ? .fitWidth : .fitPage); await settle()
                        let tag = "\(continuous ? "continuous" : "single")-\(direction.rawValue)-\(width ? "width" : "page")"
                        snapshot(tag)
                        await pan(direction, points: 70); snapshot(tag + "-pan")
                        controller.command(.next); await settle(); controller.command(.prev); await settle(); snapshot(tag + "-turn-back")
                    }
                }
            }
            controller.command(.setPaperBook(true)); controller.command(.jump(page)); await settle(); snapshot("paper-book-page")
            controller.command(.fitWidth); await settle(); snapshot("paper-book-width")
            controller.command(.next); await settle(); controller.command(.prev); await settle(); snapshot("paper-book-turn-back")
            controller.command(.setPaperBook(false)); controller.command(.setContinuous(true)); controller.command(.setDirection(.vertical)); controller.command(.jump(page)); await settle()
            for width in [820,1100,1470] {
                window.setContentSize(.init(width: width, height: 856)); controller.command(.fitWidth); await settle(); snapshot("resize-\(width)")
                controller.command(.zoomIn); await settle(); snapshot("custom-zoom-\(width)")
            }
            checks["sourceBytesUnchanged"] = try Data(contentsOf: source) == sourceBefore
            checks["storedAnchorsUnchanged"] = store.activeNotePlacements == placementsBefore
            checks["bookContentUnchanged"] = store.book?.documents == projectBefore.documents && store.book?.readerCollections == projectBefore.readerCollections
            write()
        } catch { checks["completed"] = false; samples.append(["error": String(describing: error)]); write() }
        NSApp.terminate(nil)
    }
}
@main enum NoteModeTransitionsMain {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let runner = NoteModeTransitionsRunner(URL(fileURLWithPath: CommandLine.arguments[1])); app.delegate = runner; app.run(); withExtendedLifetime(runner) {}
    }
}
