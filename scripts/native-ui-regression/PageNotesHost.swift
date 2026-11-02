import AppKit
import SwiftUI
import PDFKit
@testable import ReadingCore
@testable import ReadingBook

/// Exercises the actual container and native controls using only an isolated
/// synthetic document. No real library, AI service or global input is used.
@MainActor final class PageNotesRunner: NSObject, NSApplicationDelegate {
    let output: URL
    let controller = PDFReaderController(), reader = PDFReaderContainerView()
    var window: NSWindow!
    var checks: [String: Bool] = [:], observations: [String: Any] = [:]
    init(_ output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
    func settle(_ ms: Int = 450) async { try? await Task.sleep(for: .milliseconds(ms)) }
    func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
    }
    func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
    func frame(_ page: PDFPage, in pdf: PDFView, source: Bool = false) -> CGRect {
        reader.convert(pdf.convert(source ? page.readingSourceBounds(for: .cropBox) : page.bounds(for: .cropBox), from: page), from: pdf)
    }
    func record(_ name: String) {
        let value: [String: Any] = ["surfaces": controller.notePositions.surfaces.map { ["page": $0.id, "frame": NSStringFromRect($0.frame), "scale": $0.scale, "notes": $0.noteIDs.sorted()] },
            "points": controller.notePositions.points.mapValues(NSStringFromPoint)]
        observations[name] = value
    }
    func run() async {
        do {
            let source = output.appendingPathComponent("synthetic.pdf")
            var box = CGRect(x: 0, y: 0, width: 600, height: 800)
            let graphics = CGContext(source as CFURL, mediaBox: &box, nil)!
            for page in 1...3 {
                graphics.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics, flipped: false)
                for line in 0..<12 { NSString(string: "Page \(page), line \(line). Same sentence. Keep the original text.").draw(at: CGPoint(x: 30, y: 730 - line * 48), withAttributes: [.font: NSFont.systemFont(ofSize: 17)]) }
                NSGraphicsContext.restoreGraphicsState(); graphics.endPDFPage()
            }
            graphics.closePDF()
            let original = try Data(contentsOf: source), hash = try BookImporter.sha256(original)
            window = NSWindow(contentRect: .init(x: 120, y: 100, width: 1100, height: 780), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
            window.title = "ReadingBook 分页便签与查找 · 隔离回归"; window.contentView = reader
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            var input = PDFReaderView(controller: controller, url: source, sourceHash: hash, notePlacementOwner: "isolated")
            reader.update(from: input); await settle()
            guard let pdf = descendants(reader, PDFView.self).first, let document = pdf.document,
                  let first = document.page(at: 0), let second = document.page(at: 1), let third = document.page(at: 2) else { throw ReadingError.invalid("Missing native document") }
            let identity = ObjectIdentifier(document), originalBox = first.bounds(for: .cropBox), originalText = first.string
            let glyph = first.characterBounds(at: 15)
            reader.setReducedMotion(true)
            input.notePlacements = ["one": .init(sourceHash: hash, unitID: "p1", page: 1, x: 0.65, y: 0.95),
                "two": .init(sourceHash: hash, unitID: "p2", page: 2, x: 0.3, y: 0.5)]
            input.noteMarginVisible = true; reader.update(from: input)
            controller.command(.setDirection(.horizontal)); controller.command(.setContinuous(true)); controller.command(.jump(1)); controller.command(.fitWidth); await settle()
            checks["OnlyNotedPagesExpand"] = first.bounds(for: .cropBox).width > 600 && second.bounds(for: .cropBox).width > 600 && third.bounds(for: .cropBox) == originalBox
            checks["SourceBoxAndGlyphsStayOriginal"] = first.readingSourceBounds(for: .cropBox) == originalBox && first.characterBounds(at: 15) == glyph && first.string == originalText
            let surface = controller.notePositions.surfaces.first { $0.id == 1 }
            let sourceFrame = frame(first, in: pdf, source: true), sheetFrame = frame(first, in: pdf), nextFrame = frame(second, in: pdf, source: true)
            checks["PageOwnsItsGutter"] = surface.map { abs($0.frame.minX-sourceFrame.maxX) < 0.5 && abs($0.frame.maxX-sheetFrame.maxX) < 0.5 } == true
            checks["GutterEndsBeforeNextPage"] = sheetFrame.maxX <= nextFrame.minX + 0.5
            checks["GutterSharesOnlyOwnPageHeight"] = surface.map { abs($0.frame.height-sourceFrame.height) < 0.5 } == true
            checks["NoGlobalRightInsetInContinuousMode"] = abs(pdf.documentView?.enclosingScrollView?.contentInsets.right ?? -99) < 0.1
            record("horizontal-before-scroll")
            if let clip = pdf.documentView?.enclosingScrollView?.contentView, let before = surface {
                let pageBefore = frame(first, in: pdf, source: true)
                let old = clip.bounds.origin; clip.scroll(to: CGPoint(x: old.x + 120, y: old.y)); clip.enclosingScrollView?.reflectScrolledClipView(clip); await settle()
                let after = controller.notePositions.surfaces.first { $0.id == 1 }
                let pageAfter = frame(first, in: pdf, source: true), shift = pageAfter.minX - pageBefore.minX
                // NSClipView's document units scale with PDF magnification;
                // compare the independently converted page's actual movement.
                checks["GutterMovesWithPageDuringHorizontalPan"] = after.map { abs(shift) > 20 && abs($0.frame.minX-before.frame.minX-shift) < 1 } == true
                record("horizontal-after-scroll")
            } else { checks["GutterMovesWithPageDuringHorizontalPan"] = false }
            controller.command(.setDirection(.vertical)); controller.command(.jump(1)); controller.command(.fitWidth); await settle()
            record("vertical-before-scroll")
            if let clip = pdf.documentView?.enclosingScrollView?.contentView {
                let old = clip.bounds.origin, direction: CGFloat = clip.documentView?.isFlipped == true ? 1 : -1
                clip.scroll(to: CGPoint(x: old.x, y: old.y + 130 * direction)); clip.enclosingScrollView?.reflectScrolledClipView(clip); await settle()
                let point = controller.notePositions.points["one"], surface = controller.notePositions.surfaces.first { $0.id == 1 }
                checks["OffscreenAnchorDoesNotDropPartlyVisibleCard"] = point.map { $0.y < 0 } == true && surface != nil
                checks["FullPageOriginMovesBeyondViewportForNaturalClipping"] = surface.map { $0.frame.minY < 0 && $0.frame.height > 780 } == true
                record("vertical-clipped")
            }
            for angle in [0,90,180,270] {
                first.rotation = angle; controller.command(.setDirection(.horizontal)); controller.command(.jump(1)); controller.command(.fitWidth)
                reader.needsLayout = true; reader.layoutSubtreeIfNeeded(); await settle()
                let a = frame(first, in: pdf, source: true), b = frame(first, in: pdf)
                checks["Rotation\(angle)ExtendsDisplayRight"] = b.maxX > a.maxX + 1 && abs(b.minX-a.minX) < 0.5 && abs(b.height-a.height) < 0.5
                checks["Rotation\(angle)KeepsSourceBox"] = first.readingSourceBounds(for: .cropBox) == originalBox
            }
            first.rotation = 0
            for width in [640,900,1200] {
                window.setContentSize(.init(width: width, height: 780)); controller.command(.fitWidth); await settle()
                let a = frame(first, in: pdf, source: true), b = frame(first, in: pdf)
                checks["Width\(width)KeepsPageAndGutterAdjacent"] = controller.notePositions.surfaces.first { $0.id == 1 }.map { abs($0.frame.minX-a.maxX) < 0.5 && abs($0.frame.maxX-b.maxX) < 0.5 } == true
            }
            input.noteBindingDocumentID = "one"; reader.update(from: input); controller.command(.jump(3)); await settle()
            controller.command(.placeNote)
            let previewPoint = pdf.convert(CGPoint(x: 300, y: 500), from: third), windowPoint = pdf.convert(previewPoint, to: nil)
            let moved = NSEvent.mouseEvent(with: .mouseMoved, location: windowPoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            pdf.mouseMoved(with: moved); await settle()
            checks["RebindingPreviewAddsTargetPageGutter"] = third.bounds(for: .cropBox).width > originalBox.width && controller.notePositions.surfaces.contains { $0.id == 3 && $0.noteIDs.contains("one") }
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
            pdf.keyDown(with: escape); await settle()
            checks["CancelRebindingRestoresGutterAndOriginalAnchor"] = third.bounds(for: .cropBox) == originalBox && input.notePlacements["one"]?.page == 1
            input.noteBindingDocumentID = nil
            input.noteMarginVisible = false; reader.update(from: input); await settle()
            checks["ClosingNotesRestoresEveryNativeBox"] = first.bounds(for: .cropBox) == originalBox && second.bounds(for: .cropBox) == originalBox
            checks["SameDocumentIsReused"] = pdf.document.map(ObjectIdentifier.init) == identity
            checks["NoOriginalPDFWrite"] = try Data(contentsOf: source) == original
            controller.command(.showSearch); await settle(100)
            guard let field = descendants(reader, NSSearchField.self).first, let list = descendants(reader, PDFSearchResultsList.self).first else { throw ReadingError.invalid("Missing find controls") }
            window.makeFirstResponder(field)
            func query(_ value: String) {
                field.stringValue = value
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            }
            query("Same"); await settle(850)
            checks["TypingFindsWithoutReturn"] = list.entries.count == 36 && list.entries.allSatisfy { $0.match == "Same" }
            query("Absent old query"); query("Page"); await settle(850)
            checks["LatestTypingCancelsOldQuery"] = list.entries.count == 36 && list.entries.allSatisfy { $0.match == "Page" }
            let buttons = descendants(reader, NSButton.self).filter { ["上一个搜索结果", "下一个搜索结果", "关闭查找（Esc）"].contains($0.toolTip ?? "") }
            checks["FindButtonsHaveHoverTargets"] = buttons.count == 3 && buttons.allSatisfy { $0 is ReadingNativeHoverButton && $0.bounds.width >= 42 && $0.bounds.height >= 42 }
            for row in 0..<min(8, list.entries.count) {
                let point = list.table.convert(CGPoint(x: 15, y: list.table.rect(ofRow: row).midY), to: nil)
                let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                list.table.mouseMoved(with: event)
            }
            checks["OnlyCurrentSearchRowIsHovered"] = list.table.hoveredRow == 7
            let last = list.table.hoveredRow; list.table.clearHover()
            checks["LeavingResultsClearsHover"] = last >= 0 && list.table.hoveredRow == -1
            query("Same"); controller.command(.hideSearch); await settle(800)
            checks["ClosingFindCancelsDelayedSearch"] = !controller.isSearchVisible && list.entries.isEmpty && list.isHidden
            let selection = first.selection(for: NSRange(location: 0, length: 15))!
            var mark = try ReaderAnnotationCapture.capture(selection: selection, document: document, sourceHash: hash)[0]
            mark.lineStyle = .wavy; mark.lineAppearance = .init(glow: true)
            input.annotations = [mark]; reader.update(from: input); controller.command(.jump(1)); await settle()
            reader.setReducedMotion(false)
            let quad = mark.quads[0], hit = pdf.convert(CGPoint(x: quad.x + quad.width / 2, y: quad.y + quad.height / 2), from: first)
            reader.refreshSavedUnderlineHover(at: hit)
            func breathingLayers() -> [CALayer] { allViews(reader).flatMap { $0.layer?.sublayers ?? [] }.filter { $0.animationKeys()?.contains("reading-breath") == true } }
            let breathing = allViews(reader).flatMap { $0.layer?.sublayers ?? [] }.first { $0.name == "reading-saved-underline-hover" }
            checks["SavedWaveHoverWorksWithoutSourceCardGeometry"] = (breathing as? CAShapeLayer)?.path?.isEmpty == false && input.sourceDecorations.isEmpty
            checks["SavedWaveHasRealNativePath"] = (breathing as? CAShapeLayer)?.path?.isEmpty == false
            let animation = breathing?.animation(forKey: "reading-breath") as? CABasicAnimation
            let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UserDefaults.standard.bool(forKey: "appearance.reduceMotion")
            checks["WaveRespectsCurrentMotionPolicy"] = reduced ? animation == nil : animation?.keyPath == "opacity" && animation?.autoreverses == true && (animation?.duration ?? 0) >= 1 && animation?.timingFunction != nil
            reader.setReducedMotion(true); reader.refreshSavedUnderlineHover(at: hit)
            checks["ReducedMotionKeepsFeedbackWithoutBreathing"] = breathingLayers().isEmpty && (breathing as? CAShapeLayer)?.path?.isEmpty == false
            reader.refreshSavedUnderlineHover(at: nil)
            checks["LeavingSentenceRemovesPathAndAnimation"] = breathingLayers().isEmpty && (breathing as? CAShapeLayer)?.path == nil
            reader.refreshSavedUnderlineHover(at: CGPoint(x: CGFloat.nan, y: CGFloat.infinity))
            checks["InvalidPointerCannotCreateHover"] = breathingLayers().isEmpty && (breathing as? CAShapeLayer)?.path == nil
            checks["HoverNeverChangesSavedMark"] = input.annotations == [mark]
            let finalBytes = try Data(contentsOf: source)
            checks["NoGenerationOrOriginalDataLoss"] = pdf.document.map(ObjectIdentifier.init) == identity && first.string == originalText && finalBytes == original
            observations["realNetworkRequests"] = 0
            reader.shutdown()
        } catch { observations["error"] = String(describing: error); checks["completed"] = false }
        let result: [String: Any] = ["status": checks.values.allSatisfy { $0 } ? "passed" : "failed", "checks": checks, "observations": observations]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        NSApp.terminate(nil)
    }
}
@main enum PageNotesMain {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ProcessInfo.processInfo.environment["PAGE_NOTES_OUTPUT"]!
        let runner = PageNotesRunner(URL(fileURLWithPath: path)); app.delegate = runner; app.run(); withExtendedLifetime(runner) {}
    }
}
