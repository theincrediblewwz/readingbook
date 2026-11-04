import SwiftUI
import ReadingCore

struct PDFNoteConnector: Equatable {
    let start: CGPoint
    let pageExit: CGPoint
}

struct PDFNotePageSurface: Equatable, Identifiable {
    let id: Int
    let frame: CGRect
    let scale: CGFloat
    let noteIDs: Set<String>
}

enum PositionNoteSurface {
    static let marginWidth: CGFloat = 292
    static let topInset: CGFloat = 94
}

@MainActor final class PDFNotePositionState: ObservableObject {
    @Published private(set) var points: [String: CGPoint] = [:]
    @Published private(set) var owner = ""
    @Published private(set) var connectors: [String: PDFNoteConnector] = [:]
    @Published private(set) var scrollerWidth: CGFloat = 17
    @Published private(set) var marginWidth: CGFloat = 0
    @Published private(set) var marginFrame = CGRect.zero
    @Published private(set) var marginScale: CGFloat = 1
    @Published private(set) var surfaces: [PDFNotePageSurface] = []
    @Published private(set) var paperTurnActive = false
    @Published private(set) var navigationObscured = false
    func setPaperTurn(_ active: Bool) { if paperTurnActive != active { paperTurnActive = active } }
    func setNavigationObscured(_ value: Bool) { if navigationObscured != value { navigationObscured = value } }
    func update(_ next: [String: CGPoint], owner: String = "", connectors: [String: PDFNoteConnector] = [:], scrollerWidth: CGFloat = 17, marginWidth: CGFloat = 0, marginFrame: CGRect = .zero, marginScale: CGFloat = 1, surfaces: [PDFNotePageSurface] = []) {
        if self.owner != owner { self.owner = owner }
        if points != next { points = next }
        if self.connectors != connectors { self.connectors = connectors }
        if abs(self.scrollerWidth - scrollerWidth) > 0.1 { self.scrollerWidth = scrollerWidth }
        if abs(self.marginWidth - marginWidth) > 0.1 { self.marginWidth = marginWidth }
        if self.marginFrame != marginFrame { self.marginFrame = marginFrame }
        if abs(self.marginScale - marginScale) > 0.0001 { self.marginScale = marginScale }
        if self.surfaces != surfaces { self.surfaces = surfaces }
    }
}

enum PDFReaderCommand {
    case prev, next, jump(Int), zoomIn, zoomOut, fitPage, fitWidth, actualSize
    case showSearch, toggleSearch, toggleThumbnails, toggleContinuous, createHighlight, showAnnotations, placeNote
    case hideSearch, setThumbnails(Bool), setContinuous(Bool)
    case setDirection(PDFReadingDirection)
    case setPaperBook(Bool)
    /// Offsets from an extracted SourceUnit must never be reused as PDF offsets.
    case focusQuote(page: Int, quote: String)
    case scrollNoteArea(NSEvent)
}

/// One instance belongs to one window. A mounted PDF view owns its command binding.
@MainActor final class PDFReaderController: ObservableObject {
    @Published var page = 1
    @Published var pageCount = 0
    @Published var zoomPercent = 100
    @Published var isReady = false
    @Published var hasSelection = false
    @Published var isSearchVisible = false
    @Published var isContinuous = true
    @Published var direction = PDFReadingDirection.vertical
    @Published var thumbnailsVisible = false
    @Published var fitMode = "width"
    @Published var paperBookMode = false
    /// Visible native chrome in the PDF container's top-left coordinate space.
    @Published var chromeFrame = CGRect.zero
    @Published var thumbnailFrame = CGRect.zero
    @Published var canEditAnnotations = true
    let notePositions = PDFNotePositionState()
    var noteAnchorPoints: [String: CGPoint] { notePositions.points }
    private var bindingID: UUID?
    private var handler: ((PDFReaderCommand) -> Void)?
    private weak var noteMarginHost: NSView?
    private var noteMarginOwner = ""
    private var paperTurnIsActive = false

    func attachNoteMargin(_ host: NSView, owner: String) {
        noteMarginHost = host; noteMarginOwner = owner; host.isHidden = paperTurnIsActive || notePositions.navigationObscured
    }
    func detachNoteMargin(_ host: NSView) { if noteMarginHost === host { noteMarginHost = nil; noteMarginOwner = "" } }
    func noteMarginSnapshot(in reader: NSView) -> (image: CGImage, frame: CGRect)? {
        guard let host = noteMarginHost, !host.isHidden, host.window === reader.window,
              noteMarginOwner == notePositions.owner, host.bounds.width > 0, host.bounds.height > 0 else { return nil }
        let visible = host.bounds.intersection(host.convert(reader.bounds, from: reader))
        guard !visible.isNull, !visible.isEmpty else { return nil }
        let size = visible.size
        let scale = host.window?.backingScaleFactor ?? 1
        guard size.width * size.height * scale * scale <= 4_000_000,
              max(size.width, size.height) * scale <= 4096 else { return nil }
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: visible) else { return nil }
        host.cacheDisplay(in: visible, to: bitmap)
        guard let image = bitmap.cgImage else { return nil }
        return (image, reader.convert(visible, from: host))
    }
    func reportPaperTurn(id: UUID, active: Bool) {
        guard bindingID == id else { return }
        paperTurnIsActive = active; noteMarginHost?.isHidden = active || notePositions.navigationObscured
        DispatchQueue.main.async { [weak self] in
            guard let self, self.bindingID == id else { return }; self.notePositions.setPaperTurn(self.paperTurnIsActive)
        }
    }

    func command(_ command: PDFReaderCommand) { handler?(command) }
    func reportNotePositions(id: UUID, points: [String: CGPoint], owner: String, connectors: [String: PDFNoteConnector] = [:], scrollerWidth: CGFloat = 17, marginWidth: CGFloat = 0, marginFrame: CGRect = .zero, marginScale: CGFloat = 1, surfaces: [PDFNotePageSurface] = []) {
        guard bindingID == id else { return }; notePositions.update(points, owner: owner, connectors: connectors, scrollerWidth: scrollerWidth, marginWidth: marginWidth, marginFrame: marginFrame, marginScale: marginScale, surfaces: surfaces)
    }
    func bind(id: UUID, handler: @escaping (PDFReaderCommand) -> Void) {
        let changed = bindingID != id
        if changed { paperTurnIsActive = false; noteMarginHost?.isHidden = false }
        bindingID = id; self.handler = handler
        if changed { reportPaperTurn(id: id, active: false) }
    }
    func update(id: UUID, page: Int, pageCount: Int, zoomPercent: Int, isReady: Bool, hasSelection: Bool, canEditAnnotations: Bool, isSearchVisible: Bool, isContinuous: Bool, direction: PDFReadingDirection, thumbnailsVisible: Bool, fitMode: String, chromeFrame: CGRect, thumbnailFrame: CGRect, paperBookMode: Bool = false) {
        guard bindingID == id else { return }
        if self.page != page { self.page = page }
        if self.pageCount != pageCount { self.pageCount = pageCount }
        if self.zoomPercent != zoomPercent { self.zoomPercent = zoomPercent }
        if self.isReady != isReady { self.isReady = isReady }
        if self.hasSelection != hasSelection { self.hasSelection = hasSelection }
        if self.isSearchVisible != isSearchVisible { self.isSearchVisible = isSearchVisible }
        if self.isContinuous != isContinuous { self.isContinuous = isContinuous }
        if self.direction != direction { self.direction = direction }
        if self.thumbnailsVisible != thumbnailsVisible { self.thumbnailsVisible = thumbnailsVisible }
        if self.fitMode != fitMode { self.fitMode = fitMode }
        if self.paperBookMode != paperBookMode { self.paperBookMode = paperBookMode }
        if self.chromeFrame != chromeFrame { self.chromeFrame = chromeFrame }
        if self.thumbnailFrame != thumbnailFrame { self.thumbnailFrame = thumbnailFrame }
        if self.canEditAnnotations != canEditAnnotations { self.canEditAnnotations = canEditAnnotations }
        let obscured = isSearchVisible || thumbnailsVisible
        noteMarginHost?.isHidden = paperTurnIsActive || obscured
        notePositions.setNavigationObscured(obscured)
    }
    func unbind(id: UUID) {
        guard bindingID == id else { return }; bindingID = nil; handler = nil
        paperTurnIsActive = false; noteMarginHost?.isHidden = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.bindingID == nil else { return }
            self.isReady = false; self.hasSelection = false; self.isSearchVisible = false; self.pageCount = 0
            self.notePositions.update([:])
            self.notePositions.setPaperTurn(false)
            self.notePositions.setNavigationObscured(false)
            self.chromeFrame = .zero; self.thumbnailFrame = .zero; self.thumbnailsVisible = false
        }
    }
}
