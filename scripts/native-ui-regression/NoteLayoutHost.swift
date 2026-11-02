import AppKit
import PDFKit
import SwiftUI
@testable import ReadingBook
@testable import ReadingCore

@MainActor final class NoteLayoutRunner: NSObject, NSApplicationDelegate {
    let directory: URL
    var store: AppStore!
    let controller = PDFReaderController()
    var window: NSWindow!
    init(directory: URL) { self.directory = directory }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
    }
    func settle() async {
        for _ in 0..<12 { window.contentView?.layoutSubtreeIfNeeded(); try? await Task.sleep(nanoseconds: 35_000_000) }
    }
    func snapshot(_ name: String) -> [String: Any] {
        guard let content = window.contentView, let pdf = descendants(content, PDFView.self).first,
              let container = descendants(content, PDFReaderContainerView.self).first,
              let page = pdf.currentPage, let scroll = descendants(pdf, NSScrollView.self).first else { return ["name": name, "missing": true] }
        // The native sheet may now include its real blank note gutter. This
        // guard measures the original printed content, not the added paper.
        let pageFrame = pdf.convert(page.readingSourceBounds(for: .cropBox), from: page)
        let pdfFrame = content.convert(pdf.bounds, from: pdf)
        let bar = scroll.verticalScroller.map { content.convert($0.bounds, from: $0) } ?? .zero
        return ["name": name, "pdfFrame": NSStringFromRect(pdfFrame), "container": NSStringFromRect(container.frame),
                "pageFrame": NSStringFromRect(pageFrame), "pageMaxX": Double(pageFrame.maxX), "pdfWidth": Double(pdf.bounds.width),
                "nativeSheetFrame": NSStringFromRect(pdf.convert(page.bounds(for: .cropBox), from: page)),
                "scale": Double(pdf.scaleFactor), "fitMode": controller.fitMode, "windowWidth": Double(content.bounds.width),
                "scrollbar": NSStringFromRect(bar), "scrollbarMaxX": Double(bar.maxX),
                "scrollerStyle": scroll.scrollerStyle == .legacy ? "legacy" : "overlay",
                "notePointCount": controller.noteAnchorPoints.count, "noteCount": store.activeNotePlacements.count]
    }
    func run() async {
        do {
            UserDefaults.standard.setVolatileDomain(["library.root.path.v1": directory.appendingPathComponent("library").path,
                "AppleShowScrollBars": ProcessInfo.processInfo.environment["NOTE_SCROLLER_STYLE"] == "overlay" ? "WhenScrolling" : "Always",
                "service-profiles": Data("[]".utf8), "appearance.reduceMotion": true, "reader.hoverAutoTranslation": false], forName: UserDefaults.argumentDomain)
            store = AppStore()
            let source = directory.appendingPathComponent("fixture.pdf")
            var media = CGRect(x: 0, y: 0, width: 600, height: 800)
            let graphics = CGContext(source as CFURL, mediaBox: &media, nil)!
            for _ in 0..<3 {
                graphics.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics, flipped: false)
                for i in 0..<18 { NSString(string: "第\(i)行：这是一份检查新增便签适宽与精确位置的合成原文。").draw(at: .init(x: 30, y: 740-i*38), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black]) }
                NSGraphicsContext.restoreGraphicsState(); graphics.endPDFPage()
            }
            graphics.closePDF()
            var project = BookProject(id: "00000000-0000-4000-8000-000000000232", title: "便签动态适宽 · 隔离合成书", originalName: "fixture.pdf", sourceHash: try BookImporter.sha256(Data(contentsOf: source)), units: (1...3).map { .init(id: "p\($0)", order: $0-1, chapter: "第一章", page: $0, text: "检查原文完整显示。") })
            PluginEngine.seed(&project); project = try await store.repository.create(project, sourceURL: source)
            store.books = [project]; store.bookID = project.id; store.selectedUnitID = "p1"; store.sourceFileURL = await store.repository.sourceURL(for: project)
            store.workspaceMemory = .init(bookID: project.id, sourceHash: project.sourceHash)
            let view = ReaderWorkspaceView(showPDF: .constant(true), showOutline: .constant(false), bookmarksOnly: .constant(false))
                .environmentObject(store).environmentObject(controller).environmentObject(ReadingTypographySettings()).modifier(ReadingPreferencesEnvironment())
            window = NSWindow(contentRect: .init(x: 120, y: 100, width: 1120, height: 780), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
            window.title = "ReadingBook 便签动态适宽 · 隔离测试"; window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            for _ in 0..<200 { if controller.isReady { break }; try await Task.sleep(nanoseconds: 20_000_000) }
            controller.command(.fitWidth); await settle()
            var samples = [snapshot("no-notes-fit-width")]
            store.beginPositionNote(page: 1, x: 0.48, y: 0.72); await settle()
            samples.append(snapshot("editor-open"))
            let note = DocumentRecord(id: "dynamic-note", title: "动态新增便签")
            project = try await store.repository.saveDocument(project: store.book!, document: note, markdown: "新建时必须立即给便签留白并完整适宽。", notePlacement: .init(sourceHash: project.sourceHash, unitID: "p1", page: 1, x: 0.48, y: 0.72))
            store.publish(project); store.positionNoteRequest = nil; await settle()
            samples.append(snapshot("after-first-note"))
            let before = samples[0], after = samples.last!
            var checks = ["fitModeRetainedAfterFirstNote": after["fitMode"] as? String == "width",
                          "scaleReducedAfterFirstNote": (after["scale"] as? Double ?? 0) < (before["scale"] as? Double ?? 0)-0.1,
                          "originalPageFullyVisible": (after["pageMaxX"] as? Double ?? .infinity) <= (after["windowWidth"] as? Double ?? 0)-292-17+2,
                          "scrollbarAtOuterEdge": abs((after["scrollbarMaxX"] as? Double ?? 0)-(after["windowWidth"] as? Double ?? 0))<2,
                          "newNoteHasVisibleAnchor": controller.noteAnchorPoints[note.id] != nil]
            for mode in ["page", "custom"] {
                controller.command(mode == "page" ? .fitPage : .zoomIn); await settle()
                let prior = snapshot("before-resize-"+mode); window.setContentSize(.init(width: mode == "page" ? 1040 : 960, height: 780)); await settle()
                let resized = snapshot("after-resize-"+mode); samples += [prior,resized]
                checks[mode+"ModeRetainedOnResize"] = resized["fitMode"] as? String == mode
            }
            // Independent glyph coordinates on the same text line must stay
            // distinct even though their paper slips share one side stack.
            window.setContentSize(.init(width: 1120, height: 780)); controller.command(.fitPage); await settle()
            let pdf = descendants(window.contentView!, PDFView.self).first!, page = pdf.document!.page(at: 0)!
            let crop = page.readingSourceBounds(for: .cropBox)
            let glyphs = (0..<min(page.numberOfCharacters, 100)).map { page.characterBounds(at: $0) }.filter { !$0.isEmpty && !$0.isNull }
            guard glyphs.count > 10 else { throw ReadingError.invalid("Fixture has no independently addressable glyphs") }
            for (index, glyph) in [glyphs[1], glyphs[9]].enumerated() {
                let id = "glyph-" + String(index)
                project = try await store.repository.saveDocument(project: store.book!, document: .init(id: id, title: id), markdown: "不同原字上的便签 \(index)",
                    notePlacement: .init(sourceHash: project.sourceHash, unitID: "p1", page: 1,
                        x: Double((glyph.midX - crop.minX) / crop.width), y: Double((glyph.midY - crop.minY) / crop.height)))
                store.publish(project)
            }
            await settle()
            let first = controller.notePositions.connectors["glyph-0"], second = controller.notePositions.connectors["glyph-1"]
            checks["differentGlyphsHaveDifferentConnectorOrigins"] = first != nil && second != nil && abs(first!.start.x - second!.start.x) > 10
            checks["connectorsLeaveTowardsMargin"] = [first,second].allSatisfy { $0 != nil && $0!.pageExit.x > $0!.start.x && abs($0!.pageExit.y - $0!.start.y) < 1 }
            samples.append(snapshot("separate-glyphs"))
            // The page and its margin form one centered sheet, not a page
            // centered independently from a window-pinned note column.
            controller.command(.setPaperBook(true)); controller.command(.jump(1)); controller.command(.fitWidth); await settle()
            func sheetSample(_ name: String) -> (page: CGRect, margin: CGRect, scale: CGFloat, width: CGFloat) {
                let container = descendants(window.contentView!, PDFReaderContainerView.self).first!
                let pdf = descendants(container, PDFView.self).first!, page = pdf.currentPage!
                let frame = container.convert(pdf.convert(page.bounds(for: .cropBox), from: page), from: pdf)
                let host = descendants(window.contentView!, PositionNoteNativeHost.self).first!
                let margin = container.convert(host.bounds, from: host)
                samples.append(["name":name,"page":NSStringFromRect(frame),"margin":NSStringFromRect(margin),"scale":Double(pdf.scaleFactor),"width":Double(container.bounds.width)])
                return (frame,margin,pdf.scaleFactor,container.bounds.width)
            }
            let wide = sheetSample("book-width")
            controller.command(.fitPage); await settle()
            let fitted = sheetSample("book-page")
            checks["bookNoteColumnFollowsPageEdge"] = abs(fitted.margin.minX - fitted.page.maxX) < 2
            checks["bookWholeSheetCentered"] = abs(fitted.page.minX - (fitted.width - fitted.margin.maxX)) < 20
            checks["bookMarginScalesWithPage"] = abs(fitted.margin.width / wide.margin.width - fitted.scale / wide.scale) < 0.02
            let container = descendants(window.contentView!, PDFReaderContainerView.self).first!
            let veil = descendants(container, ReadingPaperNativeVeil.self).first!
            let sheet = CGRect(x:fitted.page.minX,y:fitted.page.minY,width:fitted.page.width+fitted.margin.width,height:fitted.page.height)
            checks["bookMaterialDoesNotPaintOutsideSheet"] = veil.paperRects?.allSatisfy { sheet.insetBy(dx:-1,dy:-1).contains($0) } == true
            controller.command(.zoomIn); await settle()
            let enlarged = sheetSample("book-enlarged")
            checks["bookZoomMovesNotesProportionally"] = abs(enlarged.margin.width / fitted.margin.width - enlarged.scale / fitted.scale) < 0.02
            checks["bookZoomKeepsNotesBesidePage"] = abs(enlarged.margin.minX - enlarged.page.maxX) < 2
            controller.command(.fitWidth); await settle()
            let refitted = sheetSample("book-width-restored")
            checks["bookWidthRestoresNoteProportion"] = abs(refitted.margin.width-wide.margin.width)<2
            controller.command(.setPaperBook(false)); await settle()
            checks["leavingBookRetainsOriginalPage"] = controller.page == 1
            // With no placements, the same production surface must remove the
            // reserved area and return to its earlier fit/zoom, without touching
            // the saved Markdown. Exercise all four reader modes.
            let placements = store.activeNotePlacements
            for mode in ["width", "page", "actual", "custom"] {
                switch mode { case "width": controller.command(.fitWidth); case "page": controller.command(.fitPage); case "actual": controller.command(.actualSize); default: controller.command(.zoomIn) }
                await settle(); let prior = snapshot("margin-on-"+mode)
                for id in placements.keys { project = try await store.repository.organizeReaderCollections(bookID: project.id, sourceHash: project.sourceHash, command: .setNotePlacement(id, nil)) }
                store.publish(project); await settle(); let hidden = snapshot("margin-off-"+mode)
                checks[mode+"ModeSurvivesMarginRemoval"] = hidden["fitMode"] as? String == prior["fitMode"] as? String
                if mode == "width" {
                    // Native coordinate conversion can return 1120 plus a few
                    // floating-point ULPs. Still reject visible clipping: the
                    // tolerance is only one physical display pixel.
                    let tolerance = 1 / Double(window.backingScaleFactor)
                    checks["fitWidthRestoredAfterMarginRemoval"] = (hidden["pageMaxX"] as? Double ?? .infinity)
                        <= (hidden["windowWidth"] as? Double ?? 0) + tolerance
                        && (hidden["scale"] as? Double ?? 0) > (prior["scale"] as? Double ?? 0) + 0.1
                }
                if mode == "custom" || mode == "actual" { checks[mode+"ScaleSurvivesMarginRemoval"] = abs((hidden["scale"] as? Double ?? 0) - (prior["scale"] as? Double ?? 0)) < 0.001 }
                for (id, placement) in placements { project = try await store.repository.organizeReaderCollections(bookID: project.id, sourceHash: project.sourceHash, command: .setNotePlacement(id, placement)) }
                store.publish(project); await settle()
                checks[mode+"ModeSurvivesMarginRestore"] = controller.fitMode == prior["fitMode"] as? String
                samples += [prior, hidden, snapshot("margin-restored-"+mode)]
            }
            controller.command(.fitWidth); await settle()
            let record: [String: Any] = ["status": checks.values.allSatisfy{$0} ? "passed":"failed", "checks": checks, "samples":samples, "realModelRequests":0]
            try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("result.json"))
            print(String(decoding:try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]),as:UTF8.self))
            if ProcessInfo.processInfo.environment["NOTE_LAYOUT_STAY_OPEN"] != "1" { exit(checks.values.allSatisfy{$0} ? 0:1) }
        } catch { try? Data(String(describing:error).utf8).write(to:directory.appendingPathComponent("error.txt")); exit(2) }
    }
}

@main struct NoteLayoutMain {
    @MainActor static func main() {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard root.path.hasPrefix(FileManager.default.currentDirectoryPath+"/logs/") else { fatalError("Workspace-local output required") }
        try! FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let runner=NoteLayoutRunner(directory:root);app.delegate=runner
        withExtendedLifetime(runner){app.run()}
    }
}
