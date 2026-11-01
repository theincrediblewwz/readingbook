import AppKit
import PDFKit
import SwiftUI
@testable import ReadingBook
@testable import ReadingCore

/// Drives the shipped native reader, without synthesized input or a real library.
@MainActor final class PaperReadingRunner: NSObject, NSApplicationDelegate {
    let output: URL
    let controller = PDFReaderController()
    let reader = PDFReaderContainerView()
    var window: NSWindow!
    var checks: [String: Bool] = [:]
    var turns: [[String: Any]] = []
    var observations: [String: Any] = [:]
    var noteHost: PositionNoteNativeHost?
    var reducedReader = false
    init(_ output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
    func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
    }
    func settle(_ milliseconds: Int = 450) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
    func turn(_ command: PDFReaderCommand, target: Int, name: String, interrupt: Bool = false) async {
        let startPage = controller.page
        let pdf = descendants(reader, PDFView.self).first
        let nativeStart = pdf?.currentPage.flatMap { page in pdf?.document.map { $0.index(for: page) + 1 } } ?? 0
        let commandStarted = ProcessInfo.processInfo.systemUptime
        controller.command(command)
        let commandMilliseconds = (ProcessInfo.processInfo.systemUptime - commandStarted) * 1000
        var captured: PDFPaperCurl?
        if reducedReader {
            // The application must honor its motion policy. Test that navigation
            // separately, then exercise the same shipped GPU renderer directly
            // in this synthetic host; never change the Mac's system preference.
            await settle(200)
            checks[name + "RespectsReaderMotionPolicy"] = descendants(reader, PDFPaperCurl.self).isEmpty
            if let pdf, let document = pdf.document,
               let from = document.page(at: nativeStart - 1), let to = document.page(at: target - 1), let page = pdf.currentPage {
                let frame = reader.convert(pdf.convert(page.bounds(for: .cropBox), from: page), from: pdf)
                let curl = PDFPaperCurl(frame: frame, from: from, fromFrame: frame, to: to, toFrame: frame,
                    backwards: target < nativeStart, paper: .warmCotton, background: .white, scale: window.backingScaleFactor)
                if let curl {
                    captured = curl; reader.addSubview(curl)
                    curl.completion = { [weak curl] in curl?.removeFromSuperview() }
                }
            }
        } else {
            for _ in 0..<120 {
                if let curl = descendants(reader, PDFPaperCurl.self).first { captured = curl; break }
                await settle(8)
            }
            checks[name + "RespectsReaderMotionPolicy"] = captured != nil
        }
        checks[name + "UsesActualMetalPage"] = captured != nil
        if !reducedReader {
            checks[name + "FreezesNativeNotesDuringTurn"] = noteHost?.isHidden == true
            checks[name + "OldNotesAreInMovingSheet"] = captured.flatMap { descendants($0, NSImageView.self).first?.image }.map(containsMagenta) == true
            checks[name + "StartsWithOldPageCover"] = captured.map { !descendants($0, NSImageView.self).filter { !$0.isHidden && $0.image != nil }.isEmpty } == true
            checks[name + "IncludesNoteOuterEdge"] = captured.map { abs($0.frame.maxX - (reader.bounds.maxX - controller.notePositions.scrollerWidth)) < 2 } == true
        }
        if interrupt && !reducedReader { controller.command(.next); controller.command(.next) }
        // Wait for the actual GPU handoff, rather than sampling once in the
        // middle of the added native-cover fade. Keep a finite wall-clock gate.
        let completionStarted = ProcessInfo.processInfo.systemUptime
        for _ in 0..<160 {
            if captured?.superview == nil { break }
            await settle(8)
        }
        observations[name + "CompletionWaitMilliseconds"] = (ProcessInfo.processInfo.systemUptime - completionStarted) * 1000
        checks[name + "CompletesWithinBoundedDeadline"] = captured?.superview == nil && ProcessInfo.processInfo.systemUptime - completionStarted < 1.3
        let samples = captured?.progressSamples ?? []
        observations[name + "CompletionState"] = ["paused": captured?.isPaused ?? false, "alpha": captured?.alphaValue ?? -1, "overlayRemoved": captured?.superview == nil]
        checks[name + "RestoresLiveNotesAfterTurn"] = noteHost?.isHidden == false
        checks[name + "RendersIntermediateFrames"] = (captured?.renderedFrames ?? 0) > 2 && samples.contains { $0 > 0 && $0 < 1 }
        checks[name + "CompletesAndRemovesOverlay"] = samples.last == 1 && captured?.superview == nil
        checks[name + "LandsOnExactPage"] = controller.page == target && nativeStart == (target == 2 ? 1 : 2)
        checks[name + "ProgressIsMonotonic"] = zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }
        checks[name + "BoundsRasterAllocation"] = captured.map { $0.drawableSize.width * $0.drawableSize.height <= 4_000_000 && max($0.drawableSize.width, $0.drawableSize.height) <= 4096 } == true
        if captured == nil, let pdf, let document = pdf.document, let from = document.page(at: 0), let to = document.page(at: 1) {
            let frame = reader.convert(pdf.convert(from.bounds(for: .cropBox), from: from), from: pdf)
            let test = PDFPaperCurl(frame: frame, from: from, fromFrame: frame, to: to, toFrame: frame,
                                   backwards: false, paper: .warmCotton, background: .white, scale: 1)
            observations[name + "RendererCanInitializeIndependently"] = test != nil; test?.cancel()
        }
        turns.append(["name": name, "mode": reducedReader ? "reduced-reader-navigation-and-isolated-renderer" : "animated-reader-integration",
                      "commandMilliseconds": commandMilliseconds, "startPage": startPage, "nativeStartPage": nativeStart, "frames": captured?.renderedFrames ?? 0, "progress": samples,
                      "page": controller.page, "drawable": captured.map { NSStringFromSize($0.drawableSize) } ?? "missing"])
    }
    func containsMagenta(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        return containsMagentaPixels(cg)
    }
    // Color-managed captures may encode NSColor.magenta with a nonzero green
    // channel. Require a strong red/blue hue, not one assumed ICC encoding.
    func containsMagentaPixels(_ cg: CGImage) -> Bool {
        let bitmap = NSBitmapImageRep(cgImage: cg)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 12) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 12) {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.redComponent > 0.7, c.blueComponent > 0.7, min(c.redComponent, c.blueComponent) - c.greenComponent > 0.4 { return true }
            }
        }
        return false
    }
    func markerCentroid(_ image: NSImage, red: Bool) -> CGPoint? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        var xSum = 0.0, ySum = 0.0, count = 0.0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let dominant = red ? c.redComponent : c.blueComponent
                let other = red ? max(c.greenComponent,c.blueComponent) : max(c.greenComponent,c.redComponent)
                if dominant > 0.7 && dominant - other > 0.4 {
                    xSum += (Double(x) + 0.5) / Double(bitmap.pixelsWide)
                    ySum += (Double(y) + 0.5) / Double(bitmap.pixelsHigh); count += 1
                }
            }
        }
        return count > 0 ? CGPoint(x: xSum/count, y: ySum/count) : nil
    }
    func blackGlyphBox(_ image: NSImage) -> CGRect? {
        glyphInkBox(image, threshold: 64, step: 2)
    }
    func viewportGlyphBox(_ image: NSImage) -> CGRect? {
        // At 60%, a visible thin stroke may consist entirely of antialiased
        // grey pixels. Sample every pixel and include that visible ink, while
        // still excluding the quiet paper spine (which is above 0.85).
        glyphInkBox(image, threshold: 192, step: 1)
    }
    func glyphInkBox(_ image: NSImage, threshold: UInt8, step: Int) -> CGRect? {
        guard let cg = image.cgImage(forProposedRect:nil, context:nil, hints:nil) else { return nil }
        guard let bitmap = CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = bitmap.data?.assumingMemoryBound(to:UInt8.self) else { return nil }
        bitmap.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
        // Decode color once. Creating and color-converting millions of NSColor
        // objects made this test oracle exceed the CI host's finite deadline.
        var minX=cg.width, minY=cg.height, maxX=0, maxY=0
        for y in stride(from:0,to:cg.height,by:step) {
            for x in stride(from:0,to:cg.width,by:step) {
                let pixel = data.advanced(by:y * bitmap.bytesPerRow + x * 4)
                if pixel[3]>204 && max(pixel[0],pixel[1],pixel[2])<threshold {
                    minX=min(minX,x); minY=min(minY,y); maxX=max(maxX,x); maxY=max(maxY,y)
                }
            }
        }
        guard minX<maxX, minY<maxY else { return nil }
        return CGRect(x:Double(minX)/Double(cg.width),y:Double(minY)/Double(cg.height),width:Double(maxX-minX)/Double(cg.width),height:Double(maxY-minY)/Double(cg.height))
    }
    func grainEnergy(_ image: NSImage) -> Double {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return -1 }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        var sum = 0.0
        for y in stride(from: 32, to: bitmap.pixelsHigh - 32, by: 19) {
            for x in stride(from: 32, to: bitmap.pixelsWide - 32, by: 19) {
                guard let a = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), let b = bitmap.colorAt(x: x + 1, y: y)?.usingColorSpace(.deviceRGB) else { return -1 }
                for delta in [a.redComponent-b.redComponent, a.greenComponent-b.greenComponent, a.blueComponent-b.blueComponent] { sum += Double(delta * delta) }
            }
        }
        return sum
    }
    func run() async {
        do {
            UserDefaults.standard.setVolatileDomain(["service-profiles": Data("[]".utf8), "appearance.reduceMotion": false,
                "reader.hoverAutoTranslation": false], forName: UserDefaults.argumentDomain)
            let source = output.appendingPathComponent("fixture.pdf")
            var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
            let graphics = CGContext(source as CFURL, mediaBox: &bounds, nil)!
            for page in 1...3 {
                graphics.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics, flipped: false)
                for row in 0..<10 { NSString(string: "第\(page)页 · 原文字随纸页一起翻动 · 第\(row)行").draw(at: .init(x: 30, y: 730 - row * 60), withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black]) }
                NSGraphicsContext.restoreGraphicsState(); graphics.endPDFPage()
            }
            graphics.closePDF()
            let original = try Data(contentsOf: source), hash = try BookImporter.sha256(original)
            window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1100, height: 780), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "ReadingBook 纸张与真实翻页 · 隔离回归"
            let root = NSView(frame: CGRect(origin: .zero, size: window.contentLayoutRect.size))
            reader.frame = root.bounds; reader.autoresizingMask = [.width, .height]
            root.addSubview(reader); window.contentView = root
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            var input = PDFReaderView(controller: controller, url: source, sourceHash: hash, notePlacementOwner: "isolated")
            reader.update(from: input)
            for _ in 0..<200 { if controller.isReady { break }; await settle(20) }
            guard controller.isReady, let pdf = descendants(reader, PDFView.self).first else { throw ReadingError.invalid("Reader did not become ready") }
            observations["systemReduceMotion"] = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            observations["appReduceMotion"] = UserDefaults.standard.bool(forKey: "appearance.reduceMotion")
            observations["explicitReducedReaderProbe"] = ProcessInfo.processInfo.environment["PAPER_PROBE_REDUCED_READER"] == "1"
            reducedReader = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.environment["PAPER_PROBE_REDUCED_READER"] == "1"
            reader.setReducedMotion(reducedReader)
            observations["metalSupported"] = PDFPaperCurl.supported
            controller.command(.setDirection(.vertical)); controller.command(.setContinuous(true)); controller.command(.fitWidth); await settle()
            let scale = pdf.scaleFactor
            input.noteMarginVisible = true; reader.update(from: input)
            var widths: [Double] = []
            for _ in 0..<35 { widths.append(Double(controller.notePositions.marginWidth)); await settle(16) }
            checks["MarginFollowsMotionPreference"] = widths.last == 292 && (reducedReader
                ? widths.allSatisfy { $0 == 0 || $0 == 292 } : Set(widths.map { Int($0) }).count > 5)
            checks["FitWidthShrinksWithoutChangingMode"] = controller.fitMode == "width" && pdf.scaleFactor < scale
            input.noteMarginVisible = false; reader.update(from: input); await settle()
            checks["MarginCollapseRestoresFitWidth"] = controller.notePositions.marginWidth == 0 && abs(pdf.scaleFactor - scale) < 0.001
            // Reproduce the real continuous-page boundary: the viewport starts
            // on page 1's tail while page 2 is the displayed/current page.
            // Replaying that raw destination used to change the page to 1.
            for forceReduced in [false, true] {
                reader.setReducedMotion(reducedReader || forceReduced)
                let name = forceReduced ? "ReducedBoundary" : "ConfiguredBoundary"
                input.noteMarginVisible = true; reader.update(from: input); await settle()
                controller.command(.jump(2)); await settle()
                if let clip = descendants(pdf, NSScrollView.self).first?.contentView {
                    var origin = clip.bounds.origin
                    origin.y += clip.documentView?.isFlipped == true ? -40 : 40
                    clip.scroll(to: origin); clip.enclosingScrollView?.reflectScrolledClipView(clip)
                }
                await settle(200)
                let page = pdf.document!.page(at: 1)!
                func viewportPoint() -> CGPoint? {
                    guard let destination = pdf.currentDestination, let owner = destination.page else { return nil }
                    return pdf.convert(pdf.convert(destination.point, from: owner), to: page)
                }
                let before = viewportPoint()
                checks[name + "Precondition"] = pdf.currentPage === page && controller.page == 2
                    && pdf.currentDestination?.page === pdf.document?.page(at: 0)
                input.noteMarginVisible = false; reader.update(from: input); await settle()
                let closed = viewportPoint()
                checks[name + "CollapseKeepsPage"] = pdf.currentPage === page && controller.page == 2
                input.noteMarginVisible = true; reader.update(from: input); await settle()
                let opened = viewportPoint()
                checks[name + "ExpansionKeepsPage"] = pdf.currentPage === page && controller.page == 2
                checks[name + "KeepsViewportAnchor"] = before.map { point in
                    [closed, opened].allSatisfy { other in
                        other.map { hypot($0.x - point.x, $0.y - point.y) * pdf.scaleFactor < 1 } == true
                    }
                } == true
                observations[name] = ["before": before.map(NSStringFromPoint) ?? "missing",
                    "closed": closed.map(NSStringFromPoint) ?? "missing", "opened": opened.map(NSStringFromPoint) ?? "missing"]
            }
            input.noteMarginVisible = false; reader.update(from: input); await settle()
            reader.setReducedMotion(reducedReader)
            for style in ReadingPaperStyle.allCases {
                reader.setPaperStyle(style); await settle(80)
                let veils = descendants(reader, ReadingPaperNativeVeil.self)
                checks[style.rawValue + "HasCorrectVisibleTexture"] = !veils.isEmpty && veils.allSatisfy {
                    style == .plain ? $0.isHidden : (!$0.isHidden && $0.layer?.contents != nil)
                }
                if style != .plain,
                   let url = ReadingBookResources.bundle?.url(forResource: style.rawValue, withExtension: "png", subdirectory: "Paper"),
                   let raw = NSImage(contentsOf: url), let soft = ReadingPaperAssets.image(style) {
                    let before = grainEnergy(raw), after = grainEnergy(soft)
                    observations[style.rawValue + "GrainEnergy"] = ["original": before, "rendered": after]
                    checks[style.rawValue + "HasSubtlerGrain"] = before > 0 && after > 0 && after < before * 0.25
                }
                checks[style.rawValue + "KeepsFlatReadingUnshaded"] = descendants(reader, PDFBookEdges.self).allSatisfy(\.isHidden) && !pdf.pageShadowsEnabled
            }
            reader.setPaperStyle(.warmCotton)
            controller.command(.setPaperBook(true)); await settle()
            // Continuous PDF layout may make another page dominant while the
            // earlier margin checks restore its visible rectangle. Establish an
            // explicit, settled page before testing an adjacent turn.
            controller.command(.jump(1)); await settle(800)
            observations["pageBeforeForward"] = controller.page
            checks["PaperBookIsHorizontalSinglePage"] = controller.paperBookMode && controller.direction == .horizontal && pdf.displayMode == .singlePage
            checks["SpineAndLeavesOnlyInBookMode"] = descendants(reader, PDFBookEdges.self).contains { !$0.isHidden && !$0.pageFrame.isEmpty }
            controller.command(.fitWidth); await settle()
            let actual = reader.convert(pdf.convert(pdf.currentPage!.bounds(for: .cropBox), from: pdf.currentPage!), from: pdf)
            let edge = descendants(reader, PDFBookEdges.self).first!
            checks["FitWidthSpineTracksSettledPage"] = abs(edge.pageFrame.minX - actual.minX) < 1 / window.backingScaleFactor
            observations["fitWidthSpine"] = ["edge": NSStringFromRect(edge.pageFrame), "actual": NSStringFromRect(actual)]
            controller.command(.zoomIn); await settle(100)
            func spineMatches() -> Bool {
                guard let page = pdf.currentPage else { return false }
                let actual = reader.convert(pdf.convert(page.bounds(for: .cropBox), from: page), from: pdf)
                return abs(edge.pageFrame.minX - actual.minX) < 1 / window.backingScaleFactor
            }
            checks["ZoomSpineTracksNativePage"] = spineMatches()
            if let clip = descendants(pdf, NSScrollView.self).first?.contentView {
                var origin = clip.bounds.origin; origin.x += 20; clip.scroll(to: origin); clip.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            await settle(100); checks["ScrolledSpineTracksNativePage"] = spineMatches()
            controller.command(.fitWidth); await settle()
            input.noteMarginVisible = true; reader.update(from: input); await settle()
            let host = PositionNoteNativeHost(rootView: AnyView(ZStack(alignment: .topLeading) {
                Color.clear
                VStack(alignment: .leading) { Color(nsColor: .magenta).frame(width: 40, height: 40); Text("随纸页一起翻动的便签") }
                    .padding(18).frame(width: 230, height: 170, alignment: .topLeading).background(Color.white).padding(.leading, 20).padding(.top, 110)
            }))
            host.frame = CGRect(x: reader.bounds.maxX - controller.notePositions.scrollerWidth - 292, y: 0, width: 292, height: reader.bounds.height)
            root.addSubview(host); noteHost = host; controller.attachNoteMargin(host, owner: "isolated")
            host.layoutSubtreeIfNeeded(); await settle(150)
            let snapshot = controller.noteMarginSnapshot(in: reader)
            if let snapshot, let png = NSBitmapImageRep(cgImage: snapshot.image).representation(using: .png, properties: [:]) { try png.write(to: output.appendingPathComponent("actual-note-snapshot.png")) }
            checks["ActualHostingNoteSnapshotHasVisibleContent"] = snapshot.map { containsMagentaPixels($0.image) } == true
            observations["NoteSnapshot"] = snapshot.map { ["frame": NSStringFromRect($0.frame), "pixels": "\($0.image.width)x\($0.image.height)"] } ?? [:]
            checks["NoteSnapshotAllocationIsBounded"] = snapshot.map { $0.image.width * $0.image.height <= 4_000_000 && max($0.image.width, $0.image.height) <= 4096 } == true
            controller.attachNoteMargin(host, owner: "foreign")
            checks["ForeignOwnerNoteSnapshotRejected"] = controller.noteMarginSnapshot(in: reader) == nil
            controller.attachNoteMargin(host, owner: "isolated")
            let material = descendants(reader, ReadingPaperNativeVeil.self).first
            checks["OneMaterialSpansPageAndNoteReserve"] = material?.frame == reader.bounds && material?.paperRects?.contains(where: { $0.contains(CGPoint(x: host.frame.midX, y: host.frame.midY)) }) == true
            await turn(.next, target: 2, name: "Forward", interrupt: true)
            await turn(.prev, target: 1, name: "Backward")
            reader.setReducedMotion(true); controller.command(.next); await settle()
            checks["ReducedMotionNavigatesWithoutCurl"] = controller.page == 2 && descendants(reader, PDFPaperCurl.self).isEmpty
            reader.setReducedMotion(reducedReader)
            controller.command(.setDirection(.vertical)); await settle()
            checks["ChoosingVerticalExitsPaperBook"] = !controller.paperBookMode && controller.direction == .vertical && descendants(reader, PDFBookEdges.self).allSatisfy(\.isHidden)
            controller.command(.setContinuous(true)); controller.command(.zoomIn); await settle()
            let customScale = pdf.scaleFactor
            controller.command(.setPaperBook(true)); await settle(); controller.command(.setPaperBook(false)); await settle()
            checks["ExitingBookRestoresFlatDirectionModeAndScale"] = controller.direction == .vertical && pdf.displayMode == .singlePageContinuous && controller.fitMode == "custom" && abs(pdf.scaleFactor - customScale) < 0.001
            // An independent native PDFView is the geometry oracle. All
            // additional documents here contain only this tiny synthetic input.
            for angle in [0, 90, 180, 270] {
                let variant = PDFDocument(data: original)!, edited = variant.page(at: 0)!
                edited.setBounds(CGRect(x: 20, y: 30, width: 550, height: 730), for: .cropBox); edited.rotation = angle
                for (rect,color) in [(CGRect(x: 80,y: 100,width: 40,height: 30),NSColor.red),(CGRect(x: 430,y: 610,width: 30,height: 50),NSColor.blue)] {
                    let mark = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
                    mark.color = .clear; mark.interiorColor = color
                    let border = PDFBorder(); border.lineWidth = 0; mark.border = border; edited.addAnnotation(mark)
                }
                let document = PDFDocument(data: variant.dataRepresentation()!)!, page = document.page(at: 0)!
                let size = angle % 180 == 0 ? CGSize(width: 550,height: 730) : CGSize(width: 730,height: 550)
                let rect = CGRect(origin: .zero, size: size)
                let oracle = PDFView(frame: rect); oracle.displayBox = .cropBox; oracle.displayMode = .singlePage
                oracle.document = document; oracle.autoScales = false; oracle.scaleFactor = 1; oracle.go(to: page); oracle.layoutDocumentView()
                let nativeRect = oracle.convert(page.bounds(for: .cropBox), from: page)
                let nativePoints = [CGPoint(x:100,y:115),CGPoint(x:445,y:635)].map { p -> CGPoint in
                    let q = oracle.convert(p, from: page)
                    return CGPoint(x:(q.x-nativeRect.minX)/nativeRect.width, y:oracle.isFlipped ? (q.y-nativeRect.minY)/nativeRect.height : (nativeRect.maxY-q.y)/nativeRect.height)
                }
                let probe = PDFPaperCurl(frame: rect, from: page, fromFrame: rect, to: page, toFrame: rect, backwards: false, paper: .plain, background: .white, scale: 1)
                let image = probe.flatMap { descendants($0, NSImageView.self).first?.image }
                let centers = image.map { [markerCentroid($0,red:true),markerCentroid($0,red:false)] } ?? []
                let reference = page.thumbnail(of:size,for:.cropBox)
                let expectedBox=blackGlyphBox(reference), actualBox=image.flatMap(blackGlyphBox)
                checks["OriginalGlyphCropAndRotation-"+String(angle)] = expectedBox.flatMap { a in actualBox.map { b in
                    zip([a.minX,a.minY,a.maxX,a.maxY],[b.minX,b.minY,b.maxX,b.maxY]).allSatisfy { abs($0-$1)<0.015 }
                }} == true
                observations["GlyphBox-"+String(angle)] = ["native":expectedBox.map(NSStringFromRect) ?? "missing","raster":actualBox.map(NSStringFromRect) ?? "missing"]
                checks["RasterPreservesCropRotationAndAnnotations-" + String(angle)] = centers.count == 2 && zip(centers,nativePoints).allSatisfy { pair in pair.0.map { hypot($0.x-pair.1.x,$0.y-pair.1.y)<0.02 } == true }
                observations["RasterGeometry-"+String(angle)] = ["native":nativePoints.map(NSStringFromPoint),"raster":centers.map { $0.map(NSStringFromPoint) ?? "missing" }]
                // The one-to-one oracle above cannot detect a missing viewport
                // scale. Exercise both sides of 100%, with a nonzero origin,
                // against independent PDFKit glyph bounds and native points.
                for factor in [0.6, 2.0] {
                    let location = CGRect(x: 23, y: 17, width: size.width * factor, height: size.height * factor)
                    let surface = CGRect(x: 0, y: 0, width: location.maxX + 19, height: location.maxY + 23)
                    let scaled = PDFPaperCurl(frame: surface, from: page, fromFrame: location, to: page, toFrame: location,
                        backwards: false, paper: .plain, background: .white, scale: 1)
                    let sourceImage = scaled.flatMap { descendants($0, NSImageView.self).first?.image }
                    let targetImage = scaled?.targetRaster.map { NSImage(cgImage: $0, size: surface.size) }
                    // Ask PDFKit for the oracle at the tested resolution.
                    // Scaling a 100% ink bounding box is not equivalent to
                    // rasterizing 60% text: hinting can drop a thin edge stroke.
                    let scaledReference = page.thumbnail(of: location.size, for: .cropBox)
                    let expected = viewportGlyphBox(scaledReference).map { CGRect(x: (location.minX + $0.minX * location.width) / surface.width,
                        y: (surface.height - location.maxY + $0.minY * location.height) / surface.height,
                        width: $0.width * location.width / surface.width, height: $0.height * location.height / surface.height) }
                    func glyphMatches(_ image: NSImage?) -> Bool {
                        expected.flatMap { a in image.flatMap(viewportGlyphBox).map { b in
                            zip([a.minX,a.minY,a.maxX,a.maxY],[b.minX,b.minY,b.maxX,b.maxY]).allSatisfy { abs($0-$1)<0.015 }
                        }} == true
                    }
                    let name = String(angle) + "-" + String(factor)
                    checks["ViewportSourceGlyphScale-" + name] = glyphMatches(sourceImage)
                    checks["ViewportTargetGlyphScale-" + name] = glyphMatches(targetImage)
                    let expectedPoints = nativePoints.map { CGPoint(x: (location.minX + $0.x * location.width) / surface.width,
                        y: (surface.height - location.maxY + $0.y * location.height) / surface.height) }
                    let actualPoints = sourceImage.map { [markerCentroid($0,red:true),markerCentroid($0,red:false)] } ?? []
                    checks["ViewportAnnotationsMatchNative-" + name] = actualPoints.count == 2 && zip(actualPoints,expectedPoints).allSatisfy { pair in
                        pair.0.map { point in hypot(point.x-pair.1.x,point.y-pair.1.y)<0.02 } == true
                    }
                    observations["ViewportGlyphScale-" + name] = ["expected":expected.map(NSStringFromRect) ?? "missing",
                        "source":sourceImage.flatMap(viewportGlyphBox).map(NSStringFromRect) ?? "missing",
                        "target":targetImage.flatMap(viewportGlyphBox).map(NSStringFromRect) ?? "missing"]
                    if angle == 0, factor == 2 {
                        let wrongFrame = CGRect(x:location.midX-size.width/2,y:location.midY-size.height/2,width:size.width,height:size.height)
                        let unscaled = PDFPaperCurl(frame:surface,from:page,fromFrame:wrongFrame,to:page,toFrame:wrongFrame,
                            backwards:false,paper:.plain,background:.white,scale:1)
                        let wrongImage = unscaled.flatMap { descendants($0,NSImageView.self).first?.image }
                        checks["ViewportGlyphOracleRejectsMissingZoom"] = wrongImage != nil && !glyphMatches(wrongImage)
                        unscaled?.cancel()
                    }
                    scaled?.cancel()
                }
                if angle == 90, let image, let tiff=image.tiffRepresentation, let png=NSBitmapImageRep(data:tiff)?.representation(using:.png,properties:[:]) { try png.write(to:output.appendingPathComponent("rotated-raster.png")) }
                probe?.cancel(); oracle.document = nil
            }
            let hugeFrame = CGRect(x:-2000,y:-1000,width:7200,height:9600), smallViewport = CGRect(x:0,y:0,width:1000,height:700)
            let large = PDFPaperCurl(frame:smallViewport, from:pdf.document!.page(at:0)!, fromFrame:hugeFrame, to:pdf.document!.page(at:1)!, toFrame:hugeFrame, backwards:false, paper:.warmCotton, background:.white, scale:2)
            let bitmap = large.flatMap { descendants($0,NSImageView.self).first?.image?.cgImage(forProposedRect:nil,context:nil,hints:nil) }
            checks["LargeZoomRasterStaysWithinVisiblePixelBudget"] = bitmap.map { $0.width * $0.height <= 4_000_000 && max($0.width,$0.height)<=4096 } == true
            observations["LargeZoom"] = ["pageFrame":NSStringFromRect(hugeFrame),"viewport":NSStringFromRect(smallViewport),"rasterPixels":bitmap.map { "\($0.width)x\($0.height)" } ?? "missing"]
            large?.cancel()
            let lifecycle = PDFReaderController(), firstID = UUID(), nextID = UUID(), detached = NSView()
            lifecycle.attachNoteMargin(detached, owner:"old"); lifecycle.bind(id:firstID,handler:{_ in})
            lifecycle.reportPaperTurn(id:firstID,active:true); lifecycle.bind(id:nextID,handler:{_ in})
            lifecycle.reportPaperTurn(id:firstID,active:true); await settle(20)
            checks["LateOldSessionCannotHideNewNoteMargin"] = !detached.isHidden && !lifecycle.notePositions.paperTurnActive
            lifecycle.unbind(id:nextID)
            checks["OriginalPDFBytesUnchanged"] = try Data(contentsOf: source) == original
            let passed = checks.values.allSatisfy { $0 }
            let result: [String: Any] = ["probe": "paper-reading", "status": passed ? "passed" : "failed", "checks": checks,
                "checkCount": checks.count, "turns": turns, "observations": observations, "marginWidths": widths, "realNetworkRequests": 0]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
            reader.shutdown(); exit(passed ? 0 : 1)
        } catch { try? Data(String(describing: error).utf8).write(to: output.appendingPathComponent("error.txt")); exit(2) }
    }
}
@main struct PaperReadingMain {
    @MainActor static func main() {
        let output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard output.path.hasPrefix(FileManager.default.currentDirectoryPath + "/logs/") else { fatalError("Workspace-local output required") }
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let runner = PaperReadingRunner(output); app.delegate = runner
        withExtendedLifetime(runner) { app.run() }
    }
}
