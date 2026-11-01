import AppKit
import PDFKit
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
        controller.command(command)
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
        if interrupt && !reducedReader { controller.command(.next); controller.command(.next) }
        await settle(800)
        let samples = captured?.progressSamples ?? []
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
                      "startPage": startPage, "nativeStartPage": nativeStart, "frames": captured?.renderedFrames ?? 0, "progress": samples,
                      "page": controller.page, "drawable": captured.map { NSStringFromSize($0.drawableSize) } ?? "missing"])
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
            window.title = "ReadingBook 纸张与真实翻页 · 隔离回归"; window.contentView = reader
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
                let veils = descendants(pdf, ReadingPaperNativeVeil.self)
                checks[style.rawValue + "HasCorrectVisibleTexture"] = !veils.isEmpty && veils.allSatisfy {
                    style == .plain ? $0.isHidden : (!$0.isHidden && $0.layer?.contents != nil)
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
