import SwiftUI
import AppKit
import PDFKit
import ReadingCore
import os

private let pdfDecorationSignposter = OSSignposter(subsystem: "org.readingbook.app", category: "PDFDecorations")

/// Displays the original PDF with PDFKit. Page numbers and callbacks are 1-based.
/// OCR text is deliberately not substituted for the PDF's rendered page.
struct PDFReaderView: NSViewRepresentable {
    @Environment(\.workspaceCanvasBlocked) private var interactionBlocked
    @Environment(\.readingReduceTransparency) private var reduceTransparency
    @Environment(\.readingReduceMotion) private var reduceMotion
    @AppStorage("reading.paperStyle") private var paperStyleName = ReadingPaperStyle.plain.rawValue
    var controller: PDFReaderController
    var url: URL
    var sourceHash: String
    var password: String?
    var annotations: [ReaderAnnotation]
    var canEditAnnotations: Bool
    var onUnlock: ((String) -> Void)?
    var onSaveAnnotations: (([ReaderAnnotation]) async -> Bool)?
    var onTrashAnnotation: ((String, Bool) async -> Bool)?
    var page: Int?
    /// Increment for an explicit source navigation, even when selecting the same
    /// page again. PDF scroll callbacks should not increment this token.
    var navigationToken: Int
    var onPageChange: ((Int) -> Void)?
    var sourceDecorations: [SourceReadingDecoration]
    var sourceDecorationRevision: Int?
    var sourcePageTexts: [Int: PDFPageSourceText]
    var focusedDecorationID: String?
    var onSourceDecorationTap: ((String) -> Void)?
    var onSourceSelection: ((SourceReadingSelection?) -> Void)?
    var onSourceDecorationHover: ((SourceReadingHover?) -> Void)?
    var onVisiblePagesChange: (([Int]) -> Void)?
    var onPreparationChanged: ((ReadingPreparationEvent) -> Void)?
    var workspaceMemory: WorkspacePDFMemory?
    var memoryRevision = 0
    var onWorkspaceMemory: ((PDFWorkspaceMemoryReceipt) -> Void)?
    var interactionResetID: UUID?
    var notePlacements: [String: ReadingNotePlacement]
    var onCreatePositionNote: ((Int, Double, Double) -> Void)?
    var noteMarginVisible: Bool
    var notePlacementOwner: String
    var onCancelPositionNote: (() -> Void)?
    var onAISearch: ((String) -> Void)?
    var onSearchKeywords: ((String) async throws -> [String])?
    var searchAIIdentity: Int
    var onAddBookmark: ((Int) -> Void)?
    var noteBindingDocumentID: String?

    init(controller: PDFReaderController, url: URL, sourceHash: String = "", page: Int? = nil, navigationToken: Int = 0, password: String? = nil, annotations: [ReaderAnnotation] = [], canEditAnnotations: Bool = true, onPageChange: ((Int) -> Void)? = nil, onUnlock: ((String) -> Void)? = nil, onSaveAnnotations: (([ReaderAnnotation]) async -> Bool)? = nil, onTrashAnnotation: ((String, Bool) async -> Bool)? = nil, sourceDecorations: [SourceReadingDecoration] = [], sourceDecorationRevision: Int? = nil, sourcePageTexts: [Int: PDFPageSourceText] = [:], focusedDecorationID: String? = nil, onSourceDecorationTap: ((String) -> Void)? = nil, onSourceSelection: ((SourceReadingSelection?) -> Void)? = nil, onSourceDecorationHover: ((SourceReadingHover?) -> Void)? = nil, onVisiblePagesChange: (([Int]) -> Void)? = nil, onPreparationChanged: ((ReadingPreparationEvent) -> Void)? = nil, workspaceMemory: WorkspacePDFMemory? = nil, memoryRevision: Int = 0, onWorkspaceMemory: ((PDFWorkspaceMemoryReceipt) -> Void)? = nil, interactionResetID: UUID? = nil, notePlacements: [String: ReadingNotePlacement] = [:], onCreatePositionNote: ((Int, Double, Double) -> Void)? = nil, noteMarginVisible: Bool = false, notePlacementOwner: String = "", onCancelPositionNote: (() -> Void)? = nil, onAddBookmark: ((Int) -> Void)? = nil, noteBindingDocumentID: String? = nil, onAISearch: ((String) -> Void)? = nil, onSearchKeywords: ((String) async throws -> [String])? = nil, searchAIIdentity: Int = 0) {
        self.controller = controller; self.url = url; self.sourceHash = sourceHash; self.password = password; self.annotations = annotations
        self.page = page; self.navigationToken = navigationToken; self.onPageChange = onPageChange
        self.onUnlock = onUnlock; self.onSaveAnnotations = onSaveAnnotations; self.onTrashAnnotation = onTrashAnnotation
        self.canEditAnnotations = canEditAnnotations
        self.sourceDecorations = sourceDecorations; self.sourceDecorationRevision = sourceDecorationRevision; self.focusedDecorationID = focusedDecorationID
        self.sourcePageTexts = sourcePageTexts
        self.onSourceDecorationTap = onSourceDecorationTap; self.onSourceSelection = onSourceSelection
        self.onSourceDecorationHover = onSourceDecorationHover; self.onVisiblePagesChange = onVisiblePagesChange
        self.onPreparationChanged = onPreparationChanged
        self.workspaceMemory = workspaceMemory; self.memoryRevision = memoryRevision; self.onWorkspaceMemory = onWorkspaceMemory
        self.interactionResetID = interactionResetID
        self.onSearchKeywords = onSearchKeywords; self.searchAIIdentity = searchAIIdentity
        self.onAISearch = onAISearch
        self.onAddBookmark = onAddBookmark; self.noteBindingDocumentID = noteBindingDocumentID
        self.onCancelPositionNote = onCancelPositionNote
        self.notePlacementOwner = notePlacementOwner
        self.noteMarginVisible = noteMarginVisible
        self.notePlacements = notePlacements; self.onCreatePositionNote = onCreatePositionNote
    }

    func makeNSView(context: Context) -> PDFReaderContainerView {
        let view = PDFReaderContainerView()
        view.setInteractionBlocked(interactionBlocked)
        view.setPaperStyle(ReadingPaperStyle(rawValue: paperStyleName) ?? .plain)
        view.setReducedMotion(reduceMotion)
        view.setReducedTransparency(reduceTransparency)
        view.update(from: self)
        return view
    }

    func updateNSView(_ nsView: PDFReaderContainerView, context: Context) {
        nsView.setInteractionBlocked(interactionBlocked)
        nsView.setPaperStyle(ReadingPaperStyle(rawValue: paperStyleName) ?? .plain)
        nsView.setReducedMotion(reduceMotion)
        nsView.setReducedTransparency(reduceTransparency)
        nsView.update(from: self)
    }

    static func dismantleNSView(_ nsView: PDFReaderContainerView, coordinator: ()) { nsView.shutdown() }
}

/// The PDF fills the reader; navigation is controlled by the window toolbar.
/// Search and annotation editing appear only when requested.
@MainActor final class PDFReaderContainerView: NSView, NSSearchFieldDelegate {
    private let paperSurface = ReadingPaperNativeVeil(frame: .zero)
    private let bookEdges = PDFBookEdges(frame: .zero)
    private var paperBookMode = false
    private var flatBookMode: (PDFReadingDirection, PDFDisplayMode, FitMode, CGFloat)?
    private var pageCurl: PDFPaperCurl? {
        didSet {
            pdfView.paperTurnInProgress = pageCurl != nil
            controller?.reportPaperTurn(id: bindingID, active: pageCurl != nil)
        }
    }
    private var paperGeometryScheduled = false
    func setPaperStyle(_ style: ReadingPaperStyle) {
        if paperSurface.style != style { pageCurl?.cancel(); pageCurl = nil; sourceCanvas.isHidden = false }
        paperSurface.apply(style); bookEdges.paper = style
        updatePaperBackground(); layoutPaperSurface()
    }
    private var notePlacementOwner = ""
    private var noteBindingDocumentID: String?
    private var noteBindingPreview: (PDFPage, CGPoint)?
    private var noteMarginWidth: CGFloat = 0
    private var noteMarginTargetWidth: CGFloat = 0
    private var noteMarginAnimation: Timer?
    private var noteMarginDestination: PDFDestination?
    private var reducedMotion = false
    func setReducedMotion(_ value: Bool) {
        reducedMotion = value
        if value { underlineHoverLayer.removeAllAnimations() }
    }
    private var noteInsetsNeedLayout = false
    private weak var noteInsetScrollView: NSScrollView?
    private var originalContentInsets = NSEdgeInsetsZero
    private var originalScrollerInsets = NSEdgeInsetsZero
    private var originalAutomaticInsets = true
    private var appliedNoteReservedWidth: CGFloat = 0
    private var notePlacements: [String: ReadingNotePlacement] = [:]
    private var notePlacementsByPage: [Int: [(String, ReadingNotePlacement)]] = [:]
    private var onCreatePositionNote: ((Int, Double, Double) -> Void)?
    private let bindingID = UUID()
    private weak var controller: PDFReaderController?
    private var interactionBlocked = false
    private var sourceHash = ""
    private var sessionPassword: String?
    private var onUnlock: ((String) -> Void)?
    private var onSaveAnnotations: (([ReaderAnnotation]) async -> Bool)?
    private var onTrashAnnotation: ((String, Bool) async -> Bool)?
    private var canEditAnnotations = true
    private var savedAnnotations: [ReaderAnnotation] = []
    private var renderedAnnotations: [(PDFPage, PDFAnnotation)] = []
    private var annotationIDs: [ObjectIdentifier: String] = [:]
    private var sourceDecorations: [SourceReadingDecoration] = []
    private var sourceDecorationsHaveUnpagedValues = false
    private var sourceDecorationValuesByID: [String: SourceReadingDecoration] = [:]
    private var sourcePageTexts: [Int: PDFPageSourceText] = [:]
    private var sourceDecorationPage: Int?
    private var sourceDecorationFocusID: String?
    private var appliedSourceDecorationFocusID: String?
    private var appliedSourceDecorationProofIdentity: String?
    private var awaitingSourceFocusProof = false
    private struct SourceLineKey: Hashable, Sendable { let id: String; let line: Int }
    private struct SourceGeometry {
        let value: SourceReadingDecoration
        let page: Int
        let range: NSRange?
        let lines: [CGRect]
        let cost: Int
    }
    @MainActor private final class SourceGeometryPage {
        let text: String
        let byteCount: Int
        struct LineLayout: Equatable {
            let crop: CGRect; let rotation: Int; let characterCount: Int
        }
        var nativeLines = NativePDFTextLine.Directory()
        var nativeLineLayout: LineLayout?
        var ranges: [QuoteCacheKey: CachedQuoteRange] = [:]
        var rangeBytes = 0
        // Identity is the canonical page's raw-byte hash. A nil proof with a
        // non-nil identity remembers a completed mismatch, not cancellation.
        var sourceTextProofIdentity: String?
        var sourceTextProof: NativePageTextProof?
        var unresolvedIDs: Set<String> = []
        var unresolvedProofAttempts: [String: String] = [:]
        var geometry: [String: SourceGeometry] = [:]
        var geometryBytes = 0
        private(set) var passageValues: [String: SourceReadingDecoration] = [:]
        private(set) var passageRanges: [String: NSRange] = [:]
        var passageIndex = ReadingRangeIndex<String>()
        var passageBytes = 0
        private var passageIndexDirty = false
        var hitBands = ReadingGeometryBands<SourceLineKey>()
        var paintBands = ReadingGeometryBands<SourceLineKey>()
        var cost: Int { byteCount + nativeLines.byteCount + rangeBytes + geometryBytes + passageBytes + (sourceTextProof?.byteCount ?? 0) + unresolvedIDs.count * 192 }
        init(prepared: NativePDFPreparationWorker.PreparedPage) {
            self.text = prepared.text; self.byteCount = prepared.byteCount
            nativeLines = prepared.directory
            nativeLineLayout = LineLayout(crop: prepared.crop, rotation: prepared.rotation, characterCount: prepared.nativeCharacterCount)
        }
        func remember(_ value: SourceGeometry) {
            geometryBytes += value.cost - (geometry[value.value.id]?.cost ?? 0)
            geometry[value.value.id] = value
            for (line, rectangle) in value.lines.enumerated() {
                let key = SourceLineKey(id: value.value.id, line: line)
                hitBands.insert(key, rectangle: rectangle)
                if value.value.interaction == .term && !value.value.passive { paintBands.insert(key, rectangle: rectangle) }
            }
        }
        func retain(validIDs: Set<String>) {
            unresolvedIDs.formIntersection(validIDs)
            unresolvedProofAttempts = unresolvedProofAttempts.filter { validIDs.contains($0.key) }
            let removedPassages = passageValues.keys.contains { !validIDs.contains($0) }
            if removedPassages {
                passageValues = passageValues.filter { validIDs.contains($0.key) }
                passageRanges = passageRanges.filter { validIDs.contains($0.key) }
                passageIndexDirty = true
                rebuildPassageIndexIfNeeded()
            }
            guard geometry.keys.contains(where: { !validIDs.contains($0) }) else { return }
            geometry = geometry.filter { validIDs.contains($0.key) }
            geometryBytes = geometry.values.reduce(0) { $0 + $1.cost }
            hitBands = ReadingGeometryBands<SourceLineKey>()
            paintBands = ReadingGeometryBands<SourceLineKey>()
            for value in geometry.values {
                for (line, rectangle) in value.lines.enumerated() {
                    let key = SourceLineKey(id: value.value.id, line: line)
                    hitBands.insert(key, rectangle: rectangle)
                    if value.value.interaction == .term && !value.value.passive { paintBands.insert(key, rectangle: rectangle) }
                }
            }
        }
        func rememberPassage(_ value: SourceReadingDecoration, range: NSRange?) {
            guard passageValues[value.id] != value || passageRanges[value.id] != range else { return }
            passageValues[value.id] = value; passageRanges[value.id] = range
            passageIndexDirty = true
        }
        func removePassage(_ id: String) {
            let value = passageValues.removeValue(forKey: id), range = passageRanges.removeValue(forKey: id)
            if value != nil || range != nil { passageIndexDirty = true }
        }
        func rebuildPassageIndexIfNeeded() {
            guard passageIndexDirty else { return }
            passageIndex = ReadingRangeIndex(passageRanges.map { .init(id: $0.key, range: $0.value) })
            passageBytes = passageValues.values.reduce(0) { $0 + $1.quote.utf8.count + ($1.prefix?.utf8.count ?? 0) + ($1.suffix?.utf8.count ?? 0) + 256 }
            passageIndexDirty = false
        }
        func needsProofRetry(_ id: String, identity: String, currentValues: [String: SourceReadingDecoration]) -> Bool {
            guard unresolvedIDs.contains(id), unresolvedProofAttempts[id] != identity, let value = currentValues[id] else { return false }
            return passageValues[id] == value || geometry[id]?.value == value
        }
        func rememberMatch(_ id: String, range: NSRange?, proofIdentity: String?) {
            if range != nil { unresolvedIDs.remove(id); unresolvedProofAttempts.removeValue(forKey: id) }
            else {
                unresolvedIDs.insert(id)
                unresolvedProofAttempts[id] = proofIdentity
            }
        }
    }
    private var sourceGeometries: [String: SourceGeometry] = [:]
    private var sourceGeometryIDsByPage: [Int: [String]] = [:]
    private var sourceGeometryPages: [Int: SourceGeometryPage] = [:]
    private var sourceGeometryPageOrder: [Int] = []
    private var sourceDecorationTask: Task<Void, Never>?
    private let nativePreparation = NativePDFPreparationWorker()
    private var sourcePreparationRun: UUID?
    private var sourceGeometryTask: Task<Void, Never>?
    private var sourceGeometryRun: UUID?
    private var sourceQuoteTask: Task<Void, Never>?
    private var sourceQuoteRun: UUID?
    private var sourceQuoteTarget: SourceReadingDecoration?
    private struct PendingSourceGeometry {
        let page: Int; let value: SourceReadingDecoration; let range: NSRange
    }
    private var pendingSourceGeometry: [String: PendingSourceGeometry] = [:]
    private var inFlightSourceGeometryIDs = Set<String>()
    private var sourceDecorationGeneration = 0
    private var sourceDecorationRevision: Int?
    private var hoveredSourceID: String?
    private var sourceInputGeneration = 0
    private var renderedSourceInputGeneration = -1
    private var groupedSourceDecorations: [Int: [SourceReadingDecoration]] = [:]
    private var validSourceDecorationIDsByPage: [Int: Set<String>] = [:]
    private var sourceAvailablePages: Set<Int> = []
    private var renderedSourceWindow: [Int] = []
    private var sourcePreparationNeedsRetry = false
    private let sourceCanvas = PDFSourceDecorationCanvas()
    private let underlineHoverLayer = CAShapeLayer()
    private var hoveredUnderlineID: String?
    private var underlineRecordsByPage: [Int: [ReaderAnnotation]] = [:]
    private var underlineRecordsByID: [String: ReaderAnnotation] = [:]
    private var underlineHitBands: [Int: ReadingGeometryBands<String>] = [:]
    private var renderedUnderlinesByID: [String: [PDFAnnotation]] = [:]
    private var sourcePointerMonitor: Any?
    private var sourcePress: (hit: PDFSourceDecorationHit, point: CGPoint, generation: Int)?
    private var sourceInteractionGeneration = 0
    private var sourceHoverRefresh = ReadingHoverRefresh()
    private var sourceHoverRefreshWork: DispatchWorkItem?
    private var sourceScrollQuietUntil = 0.0
    private var onVisiblePagesChange: (([Int]) -> Void)?
    private var onPreparationChanged: ((ReadingPreparationEvent) -> Void)?
    private var lastVisiblePages: [Int] = []
    private var visiblePagePublishScheduled = false
    private struct QuoteCacheKey: Hashable, Sendable {
        // String equality normalizes Unicode; matching below deliberately does
        // not. Keep cache identities byte-exact as well.
        let quote: Data
        let prefix: Data?
        let suffix: Data?
        var byteCount: Int { quote.count + (prefix?.count ?? 0) + (suffix?.count ?? 0) }
    }
    private struct CachedQuoteRange: Sendable { let range: NSRange? }
    private struct PageQuoteMatches: Sendable {
        let ranges: [String: CachedQuoteRange]
        let uniqueMatchedIDs: Set<String>
        let sourceTextIdentity: String?
        let proof: NativePageTextProof?
    }
    private weak var quoteCachePage: PDFPage?
    private var quoteRangeCache: [QuoteCacheKey: CachedQuoteRange] = [:]
    private var quoteCacheBytes = 0
    private var onSourceDecorationTap: ((String) -> Void)?
    private var onSourceSelection: ((SourceReadingSelection?) -> Void)?
    private var onSourceDecorationHover: ((SourceReadingHover?) -> Void)?
    private var pendingQuote: (page: Int, quote: String, prefix: String?, suffix: String?, decoration: SourceReadingDecoration?)?
    /// Navigation emphasis is not a user text selection. In particular, a
    /// remounted reader may restore a focused anchor while hover stays usable.
    private var quoteFocusHighlight: PDFSelection?
    private var pendingWorkspaceMemory: WorkspacePDFMemory?
    private var appliedMemoryRevision: Int?
    private var appliedInteractionResetID: UUID?
    private var memoryCallback: ((PDFWorkspaceMemoryReceipt) -> Void)?
    private var memoryCaptureTask: DispatchWorkItem?
    private weak var observedClip: NSClipView?
    private var sourceSelectionObservation = 0
    private var annotationPanel: NSPanel?
    private var editingAnnotationSheet = false
    private var showingAnnotationList = false
    private enum FitMode: Int { case page, width, actual, custom }
    private let pdfView = AnnotationPDFView()
    private let notePageGutters = PDFNotePageGutters()
    private var usesPageGutters: Bool { pdfView.displayMode == .singlePageContinuous && !paperBookMode }
    private let thumbnails = PDFThumbnailView()
    private let thumbnailScroll = NSScrollView()
    private let thumbnailPanel = PDFReaderFloatingPanel()
    private var thumbnailTop: NSLayoutConstraint?
    private var thumbnailWidth: NSLayoutConstraint?
    private let thumbnailResize = PDFThumbnailResizeHandle()
    private var thumbnailDensity = PDFThumbnailDensity(rawValue: UserDefaults.standard.string(forKey: "reader.thumbnailDensity") ?? "") ?? .medium
    private var thumbnailPreferredWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "reader.thumbnailPanelWidth")
        return saved.isFinite && saved >= 244 ? min(900, saved) : 420
    }()
    private var thumbnailSizeButtons: [PDFThumbnailDensityButton] = []
    private let contentStack = NSStackView()
    private let header = PDFReaderFloatingPanel()
    private var searchPanelHeight: NSLayoutConstraint?
    private let searchField = NSSearchField()
    private let resultLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var searchRow = NSStackView()
    private let searchResults = PDFSearchResultsList()
    private var searchResultsHeight: NSLayoutConstraint?
    private var searchSnippetTasks: [Int: Task<Void, Never>] = [:]
    private var searchTextTasks: [Int: (id: UUID, task: Task<NativePDFSearchTextIndex, Error>)] = [:]
    private var searchTextIndexes: [Int: NativePDFSearchTextIndex] = [:]
    private var searchTextOrder: [Int] = []
    private var searchTextBytes = 0
    private var searchMatchKeys = Set<[Int]>()
    private var previousMatchButton = NSButton()
    private var nextMatchButton = NSButton()
    private let overlay = NSVisualEffectView()
    private let overlayTitle = NSTextField(labelWithString: "")
    private let overlayDetail = NSTextField(wrappingLabelWithString: "")
    private let passwordField = NSSecureTextField()
    private let overlayButton = NSButton(title: "解锁", target: nil, action: nil)
    private var loadedURL: URL?
    private var document: PDFDocument?
    private var securityScoped = false
    private var sourcePage: Int?
    private var lastParentPage: Int?
    private var lastParentNavigationToken: Int?
    private var lastEmittedPage: Int?
    private var lastCallback: (page: Int, token: Int)?
    private var callback: ((Int) -> Void)?
    private var documentGeneration = 0
    private var navigationRequestID = 0
    private var pageObservationID = 0
    private var installingDocument = false
    private enum PageLanding: Equatable { case start, end }
    private var pendingNavigation: (id: Int, page: Int, notifyParent: Bool, landing: PageLanding)?
    private var readingDirection = PDFReadingDirection.vertical
    private var pageScrollMonitor: Any?
    private var pageGestureOwnership = CanvasGestureOwnership()
    private var pageTurnPolicy = PDFPageTurnPolicy()
    private var fitMode = FitMode.width
    private var isApplyingFit = false
    private var lastViewportSize = NSSize.zero
    private var searchGeneration = 0
    private var automaticSearchTask: Task<Void, Never>?
    private var onAISearch: ((String) -> Void)?
    private var aiSearchButton: NSButton?
    private var onSearchKeywords: ((String) async throws -> [String])?
    private var searchAIIdentity = 0
    private var keywordTask: Task<Void, Never>?
    private var keywordQuery = ""
    private var keywordEpoch = UUID()
    private var keywordCache: [String: [String]] = [:]
    private let keywordSpinner = NSProgressIndicator()
    private var searchDelegate: PDFReaderSearchDelegate?
    private var matches: [PDFSelection] = []
    private var matchIndex = -1
    private var searching = false
    private var searchLimited = false
    private var highlightUpdateScheduled = false
    private var allowsSearchAutoNavigation = false
    private var searchEscapeMonitor: Any?
    private let matchLimit = 5000
    private struct ControlSnapshot: Equatable {
        let controllerID: ObjectIdentifier?
        let generation: Int
        let page: Int
        let pageCount: Int
        let zoom: Int
        let ready: Bool
        let selected: Bool
        let canEdit: Bool
        let searchVisible: Bool
        let continuous: Bool
        let direction: PDFReadingDirection
        let thumbnailsVisible: Bool
        let fitMode: String
        let searchFrame: CGRect
        let thumbnailFrame: CGRect
        let paperBook: Bool
    }
    private var pendingControlSnapshot: ControlSnapshot?
    private var lastControlSnapshot: ControlSnapshot?
    private var controlPublishScheduled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("PDFReaderContainerView is created in code") }

    func setInteractionBlocked(_ blocked: Bool) {
        guard interactionBlocked != blocked else { return }
        interactionBlocked = blocked; pdfView.interactionBlocked = blocked
        if blocked { awaitingSourceFocusProof = false; resetPageGesture(); invalidateSourcePress(); cancelSourceQuotePreparation() }
        else { scheduleSourceHoverRefresh() }
        guard blocked, let owner = window, let responder = owner.firstResponder else { return }
        // Only resign a PDF-owned responder. A management card may already
        // own this window's shared field editor by the time this update runs.
        if ownsResponder(responder) { owner.makeFirstResponder(nil) }
    }
    func setReducedTransparency(_ reduced: Bool) {
        let enabled = reduced || UserDefaults.standard.bool(forKey: "appearance.reduceTransparency")
            || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        header.setReducedTransparency(enabled); thumbnailPanel.setReducedTransparency(enabled)
    }
    private func ownsResponder(_ responder: NSResponder) -> Bool {
        let searchEditor = searchField.currentEditor()
        let belongsToPDF = (responder as? NSView).map { $0 === pdfView || $0.isDescendant(of: pdfView) } ?? false
        let belongsToSearch = (responder as? NSView).map { $0 === header || $0.isDescendant(of: header) } ?? false
        return belongsToPDF || belongsToSearch || responder === searchField || (searchEditor != nil && responder === searchEditor)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        interactionBlocked ? nil : super.hitTest(point)
    }

    private func configure() {
        pdfView.onRegion = { [weak self] page, rect in self?.createRegion(page: page, rect: rect) }
        pdfView.onReadingNavigation = { [weak self] offset, direction, pageStep, repeatKey in
            self?.handlePageNavigationKey(offset: offset, direction: direction, pageStep: pageStep, repeatKey: repeatKey) ?? false
        }
        pdfView.onRegionError = { [weak self] message in self?.setStatus(message) }
        pdfView.isManagedAnnotation = { [weak self] annotation in self?.annotationIDs[ObjectIdentifier(annotation)] != nil }
        pdfView.onSourcePointerLeft = { [weak self] in self?.cancelSourceHoverRefresh(); self?.reportSourceHover(nil) }
        sourceCanvas.wantsLayer = true
        sourceCanvas.layer?.backgroundColor = NSColor.clear.cgColor
        underlineHoverLayer.fillColor = nil; underlineHoverLayer.lineCap = .round
        underlineHoverLayer.name = "reading-saved-underline-hover"
        sourceCanvas.layer?.addSublayer(underlineHoverLayer)
        sourceCanvas.paint = { [weak self] dirty in self?.drawSourceDecorations(in: dirty) }
        pdfView.onAnnotationTap = { [weak self] annotation in self?.openAnnotation(annotation) }
        pdfView.autoScales = false
        readingDirection = defaultReadingDirection
        pdfView.displayMode = defaultContinuous ? .singlePageContinuous : .singlePage
        pdfView.displayDirection = readingDirection == .vertical ? .vertical : .horizontal
        pdfView.readingDirection = readingDirection
        pdfView.displayBox = .cropBox
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        pdfView.minScaleFactor = 0.05
        pdfView.maxScaleFactor = 12
        pdfView.backgroundColor = .windowBackgroundColor
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(visiblePagesChanged(_:)), name: .PDFViewVisiblePagesChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged(_:)), name: .PDFViewScaleChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)), name: .PDFViewSelectionChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(annotationHit(_:)), name: .PDFViewAnnotationHit, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(pdfViewportScrolled(_:)), name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(captureWorkspaceMemoryNow(_:)), name: Notification.Name("ReadingBookCaptureWorkspaceMemory"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(readingWindowResigned(_:)), name: NSWindow.didResignKeyNotification, object: nil)

        thumbnails.allowsDragging = false
        thumbnails.allowsMultipleSelection = false
        thumbnails.labelFont = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        thumbnails.backgroundColor = .clear
        thumbnailScroll.documentView = thumbnails
        thumbnailScroll.hasVerticalScroller = false
        thumbnailScroll.hasHorizontalScroller = false
        thumbnailScroll.autohidesScrollers = true
        thumbnailScroll.drawsBackground = false
        thumbnailScroll.translatesAutoresizingMaskIntoConstraints = false
        thumbnailPanel.isHidden = true
        let thumbnailTitle = NSTextField(labelWithString: "缩略图")
        thumbnailTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        thumbnailSizeButtons = PDFThumbnailDensity.allCases.map { PDFThumbnailDensityButton($0, target: self, action: #selector(changeThumbnailDensity(_:))) }
        for button in thumbnailSizeButtons { button.selectedDensity = button.density == thumbnailDensity }
        let sizes = NSStackView(views: thumbnailSizeButtons); sizes.orientation = .horizontal; sizes.spacing = 2
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let thumbnailHeader = row([thumbnailTitle, spacer, sizes, symbolButton("xmark", "关闭缩略图", #selector(hideThumbnails))])
        let thumbnailBody = NSStackView(views: [thumbnailHeader, thumbnailScroll])
        thumbnailBody.orientation = .vertical; thumbnailBody.alignment = .leading; thumbnailBody.spacing = 4
        thumbnailHeader.setContentHuggingPriority(.required, for: .vertical)
        thumbnailScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        thumbnailBody.translatesAutoresizingMaskIntoConstraints = false
        thumbnailPanel.panelContent.addSubview(thumbnailBody)
        thumbnailResize.translatesAutoresizingMaskIntoConstraints = false
        thumbnailResize.toolTip = "左右拖动调整缩略图面板宽度"
        thumbnailResize.onBegin = { [weak self] in self?.thumbnailPanel.bounds.width ?? 420 }
        thumbnailResize.onResize = { [weak self] width in
            guard let self else { return }
            self.thumbnailPreferredWidth = min(900, max(244, width))
            self.thumbnailWidth?.constant = min(self.thumbnailPreferredWidth, max(244, self.bounds.width - 36))
            self.layoutSubtreeIfNeeded(); self.layoutThumbnails()
        }
        thumbnailResize.onFinish = { [weak self] in if let self { UserDefaults.standard.set(Double(self.thumbnailPreferredWidth), forKey: "reader.thumbnailPanelWidth") } }
        thumbnailPanel.addSubview(thumbnailResize)
        NSLayoutConstraint.activate([
            thumbnailBody.leadingAnchor.constraint(equalTo: thumbnailPanel.panelContent.leadingAnchor, constant: 10),
            thumbnailBody.trailingAnchor.constraint(equalTo: thumbnailPanel.panelContent.trailingAnchor, constant: -10),
            thumbnailBody.topAnchor.constraint(equalTo: thumbnailPanel.panelContent.topAnchor, constant: 8),
            thumbnailBody.bottomAnchor.constraint(equalTo: thumbnailPanel.panelContent.bottomAnchor, constant: -10),
            thumbnailBody.heightAnchor.constraint(equalTo: thumbnailPanel.heightAnchor, constant: -18),
            thumbnailBody.widthAnchor.constraint(equalTo: thumbnailPanel.widthAnchor, constant: -20),
            thumbnailHeader.widthAnchor.constraint(equalTo: thumbnailBody.widthAnchor),
            thumbnailScroll.widthAnchor.constraint(equalTo: thumbnailBody.widthAnchor)
        ])
        NSLayoutConstraint.activate([thumbnailResize.trailingAnchor.constraint(equalTo: thumbnailPanel.trailingAnchor),
            thumbnailResize.widthAnchor.constraint(equalToConstant: 10), thumbnailResize.topAnchor.constraint(equalTo: thumbnailPanel.topAnchor, constant: 56),
            thumbnailResize.bottomAnchor.constraint(equalTo: thumbnailPanel.bottomAnchor, constant: -12)])

        contentStack.orientation = .horizontal
        contentStack.alignment = .top
        contentStack.distribution = .fill
        contentStack.spacing = 0
        contentStack.detachesHiddenViews = true
        contentStack.addArrangedSubview(pdfView)
        pdfView.heightAnchor.constraint(equalTo: contentStack.heightAnchor).isActive = true
        pdfView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        searchField.placeholderString = "搜索 PDF 文字"
        searchField.controlSize = .regular
        searchField.font = .systemFont(ofSize: 15)
        searchField.setAccessibilityLabel("搜索 PDF 文字")
        searchField.toolTip = "先本地简繁互找；已连接模型时，自动理解错字、翻译和相关词。右侧AI图标用于主动阅读全文。"
        searchField.heightAnchor.constraint(equalToConstant: 44).isActive = true
        // One visible close affordance closes the entire find panel. Keeping the
        // search field's native clear cross beside it gave two identical crosses
        // different meanings, while the original outer cross only cleared text.
        (searchField.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        searchField.sendsWholeSearchString = true
        searchField.sendsSearchStringImmediately = false
        searchField.target = self; searchField.action = #selector(findText)
        searchField.delegate = self
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previousMatchButton = symbolButton("chevron.up", "上一个搜索结果", #selector(previousMatch))
        nextMatchButton = symbolButton("chevron.down", "下一个搜索结果", #selector(nextMatch))
        let close = symbolButton("xmark", "关闭查找（Esc）", #selector(closeSearch))
        resultLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.lineBreakMode = .byTruncatingTail
        resultLabel.setContentHuggingPriority(.required, for: .horizontal)
        let aiSearch = symbolButton("sparkle.magnifyingglass", "AI阅读全文查找：先理解意图，再阅读全文", #selector(openAISearch))
        aiSearchButton = aiSearch
        keywordSpinner.style = .spinning; keywordSpinner.controlSize = .small; keywordSpinner.isDisplayedWhenStopped = false
        keywordSpinner.setAccessibilityLabel("AI正在理解检索词")
        keywordSpinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        searchRow = row([searchField, keywordSpinner, aiSearch, resultLabel, previousMatchButton, nextMatchButton, close])
        searchRow.isHidden = true
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = true
        // Navigation/zoom controls live in the window toolbar. Only explicitly opened search/status uses this row.
        searchResults.isHidden = true
        searchResults.onRequest = { [weak self] index in self?.prepareSearchSnippet(index) }
        searchResults.onSelect = { [weak self] index in
            guard let self, !self.interactionBlocked, !self.searchRow.isHidden, self.matches.indices.contains(index) else { return }
            self.allowsSearchAutoNavigation = true; self.matchIndex = index; self.showMatch()
        }
        let toolbar = NSStackView(views: [searchRow, searchResults, statusLabel])
        toolbar.orientation = .vertical
        toolbar.alignment = .leading
        toolbar.spacing = 6
        toolbar.detachesHiddenViews = true
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        header.panelContent.addSubview(toolbar)
        searchRow.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true
        searchResults.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true
        let resultsHeight = searchResults.heightAnchor.constraint(equalToConstant: 0)
        resultsHeight.isActive = true; searchResultsHeight = resultsHeight
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: header.panelContent.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: header.panelContent.trailingAnchor, constant: -12),
            toolbar.topAnchor.constraint(equalTo: header.panelContent.topAnchor, constant: 10),
            toolbar.bottomAnchor.constraint(equalTo: header.panelContent.bottomAnchor, constant: -10)
        ])
        // Keep the outer navigation frame equal to its live content. Otherwise
        // NSGlassEffectView can retain the previous intrinsic height after rows
        // shrink, leaving an invisible gap and pushing thumbnails offscreen.
        let searchPanelHeight = header.heightAnchor.constraint(equalToConstant: 64)
        searchPanelHeight.isActive = true; self.searchPanelHeight = searchPanelHeight
        toolbar.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -24).isActive = true
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false; header.isHidden = true
        thumbnailPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack); addSubview(paperSurface); addSubview(bookEdges); bookEdges.isHidden = true; addSubview(sourceCanvas); addSubview(thumbnailPanel); addSubview(header)
        let thumbnailTop = thumbnailPanel.topAnchor.constraint(equalTo: topAnchor, constant: 76)
        self.thumbnailTop = thumbnailTop
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor), contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor), contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            header.centerXAnchor.constraint(equalTo: centerXAnchor),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 76),
            header.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
            thumbnailPanel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            thumbnailTop,
            thumbnailPanel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -88),
            thumbnailPanel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -36)
        ])
        let thumbnailWidth = thumbnailPanel.widthAnchor.constraint(equalToConstant: thumbnailPreferredWidth)
        thumbnailWidth.priority = .defaultHigh; thumbnailWidth.isActive = true; self.thumbnailWidth = thumbnailWidth
        let preferredSearchWidth = header.widthAnchor.constraint(equalToConstant: 680)
        preferredSearchWidth.priority = .defaultHigh; preferredSearchWidth.isActive = true
        header.setContentHuggingPriority(.required, for: .vertical)
        contentStack.setContentHuggingPriority(.defaultLow, for: .vertical)
        configureOverlay()
        refreshControls()
    }

    private func configureOverlay() {
        overlay.material = .windowBackground; overlay.blendingMode = .withinWindow; overlay.state = .active
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: contentStack.topAnchor), overlay.bottomAnchor.constraint(equalTo: contentStack.bottomAnchor)
        ])
        overlayTitle.font = .systemFont(ofSize: 18, weight: .medium)
        overlayDetail.font = .systemFont(ofSize: 12)
        overlayDetail.textColor = .secondaryLabelColor
        overlayDetail.maximumNumberOfLines = 5
        passwordField.placeholderString = "PDF 密码（仅在内存中使用）"
        passwordField.target = self; passwordField.action = #selector(overlayAction)
        overlayButton.target = self; overlayButton.action = #selector(overlayAction)
        overlayButton.bezelStyle = .rounded
        let box = NSStackView(views: [overlayTitle, overlayDetail, passwordField, overlayButton])
        box.orientation = .vertical; box.alignment = .centerX; box.spacing = 14
        box.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(box)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: overlay.centerXAnchor), box.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            box.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 20),
            box.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -20),
            box.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            overlayDetail.widthAnchor.constraint(equalTo: box.widthAnchor), passwordField.widthAnchor.constraint(equalTo: box.widthAnchor)
        ])
        box.detachesHiddenViews = true
        overlay.isHidden = true
    }

    func update(from input: PDFReaderView) {
        if searchAIIdentity != input.searchAIIdentity { resetKeywordAssistance(clearCache: true) }
        searchAIIdentity = input.searchAIIdentity; onSearchKeywords = input.onSearchKeywords
        onAISearch = input.onAISearch; aiSearchButton?.isHidden = input.onAISearch == nil
        let url = input.url, requestedPage = input.page, navigationToken = input.navigationToken
        let margin = input.noteMarginVisible ? PositionNoteSurface.marginWidth : 0
        changeNoteMargin(to: margin)
        pdfView.pageShadowsEnabled = false
        updatePaperBackground()
        let sourceChanged = sourceHash != input.sourceHash
        if sourceChanged { resetKeywordAssistance(clearCache: true) }
        if notePlacements != input.notePlacements {
            notePlacements = input.notePlacements
            notePlacementsByPage = Dictionary(grouping: notePlacements.compactMap { id, value in value.page.map { ($0, id, value) } }, by: { $0.0 })
                .mapValues { $0.map { ($0.1, $0.2) } }
            noteInsetsNeedLayout = true; needsLayout = true
        }
        notePlacementOwner = input.notePlacementOwner
        onCreatePositionNote = input.onCreatePositionNote
        if noteBindingDocumentID != input.noteBindingDocumentID { noteBindingPreview = nil; noteInsetsNeedLayout = true; needsLayout = true }
        noteBindingDocumentID = input.noteBindingDocumentID
        pdfView.onNotePlacementCancelled = { [weak self] in
            self?.noteBindingPreview = nil; self?.noteInsetsNeedLayout = true; self?.needsLayout = true
            self?.scheduleVisiblePages(); input.onCancelPositionNote?()
        }
        pdfView.onNotePreview = { [weak self] page, point in
            guard let self, self.noteBindingDocumentID != nil, !self.interactionBlocked else { return }
            if self.noteBindingPreview?.0 !== page { self.noteInsetsNeedLayout = true; self.needsLayout = true }
            self.noteBindingPreview = (page, point); self.scheduleVisiblePages()
        }
        pdfView.onBookmarkPoint = { [weak self] page in
            guard let self, !self.interactionBlocked, let document = self.document else { return }
            let index = document.index(for: page)
            if index != NSNotFound { input.onAddBookmark?(index + 1) }
        }
        pdfView.onNotePoint = { [weak self] page, point in self?.createPositionNote(page: page, point: point) }
        pdfView.onSentenceActions = { [weak self] page, point in self?.sentenceMarkActions(page: page, point: point) ?? [] }
        scheduleVisiblePages()
        if controller !== input.controller {
            controller?.unbind(id: bindingID)
            controller = input.controller
            input.controller.bind(id: bindingID) { [weak self] command in self?.perform(command) }
        }
        callback = input.onPageChange; onUnlock = input.onUnlock
        onSaveAnnotations = input.onSaveAnnotations; onTrashAnnotation = input.onTrashAnnotation
        onSourceDecorationTap = input.onSourceDecorationTap; onSourceSelection = input.onSourceSelection
        onSourceDecorationHover = input.onSourceDecorationHover
        onVisiblePagesChange = input.onVisiblePagesChange
        onPreparationChanged = input.onPreparationChanged
        let interactionResetChanged = appliedInteractionResetID != input.interactionResetID
        if interactionResetChanged {
            appliedInteractionResetID = input.interactionResetID
            // Same-book selection resets transient interaction state just as
            // a reload did, while keeping the verified document and its caches.
            resetPageGesture(); pdfView.cancelRegionSelection()
            clearSearchState()
            let resetID = appliedInteractionResetID, generation = searchGeneration
            // Hiding an active NSSearchField asks AppKit to find its next key
            // view, which re-enters SwiftUI's focus graph. In updateNSView that
            // causes AttributeGraph cycles. Invalidate results immediately,
            // then hide the field after the current graph transaction ends.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.controller != nil,
                      self.appliedInteractionResetID == resetID,
                      self.searchGeneration == generation else { return }
                self.dismissSearch(restoreFocus: false)
            }
            cancelSourceQuotePreparation(); clearQuoteFocusHighlight()
            pdfView.clearSelection()
        }
        // This optional acceleration metadata has its own lifetime. A normal
        // publication may briefly withhold it; keep existing marks/geometry
        // and fall back to unique matching rather than flashing the page.
        let newProofMetadata = input.sourcePageTexts.contains { sourcePageTexts[$0.key]?.identity != $0.value.identity }
        sourcePageTexts = input.sourcePageTexts
        for (number, cache) in sourceGeometryPages {
            // Missing window metadata is not evidence that an idle page's
            // source changed. Reuse still requires present, matching metadata
            // at the use site; a new document/source clears all page caches.
            guard let identity = sourcePageTexts[number]?.identity,
                  cache.sourceTextProofIdentity != identity else { continue }
            cache.sourceTextProofIdentity = nil; cache.sourceTextProof = nil
        }
        let requestedPageChanged = sourceDecorationPage != requestedPage
        let sourceDecorationsChanged = sourceChanged || input.url.standardizedFileURL != loadedURL || (requestedPageChanged && sourceDecorationsHaveUnpagedValues) || (sourceDecorationFocusID != input.focusedDecorationID && sourceDecorations != input.sourceDecorations) || (input.sourceDecorationRevision.map { $0 != sourceDecorationRevision }
            ?? (sourceDecorations != input.sourceDecorations))
        if sourceDecorationsChanged {
            invalidateSourcePress()
            sourceDecorations = input.sourceDecorations; sourceInputGeneration &+= 1
            groupedSourceDecorations = Dictionary(grouping: sourceDecorations, by: { $0.page ?? requestedPage ?? 1 })
            // Keep every supplied mark eligible. Matching is consumed in
            // bounded worker batches below; a work limit must not delete the
            // tail of a dense page from the presentation catalog.
            validSourceDecorationIDsByPage = [:]
            sourceDecorationsHaveUnpagedValues = false
            for value in input.sourceDecorations {
                if value.page == nil { sourceDecorationsHaveUnpagedValues = true }
                validSourceDecorationIDsByPage[value.page ?? requestedPage ?? 1, default: []].insert(value.id)
            }
            sourceAvailablePages = Set(groupedSourceDecorations.keys)
            sourceDecorationValuesByID = Dictionary(sourceDecorations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // New unrelated presentation data does not cancel a reader's
            // outstanding jump. If its actual target changed, retry only while
            // that same explicit intent is still active, never after a scroll.
            if let target = sourceQuoteTarget, sourceDecorationValuesByID[target.id] != target {
                let retry = sourceQuoteRun != nil && input.focusedDecorationID == target.id && sourceDecorationValuesByID[target.id] != nil
                cancelSourceQuotePreparation()
                if retry { appliedSourceDecorationFocusID = nil; appliedSourceDecorationProofIdentity = nil }
            }
        }
        sourceDecorationRevision = input.sourceDecorationRevision; sourceDecorationPage = requestedPage
        sourceHash = input.sourceHash; sessionPassword = input.password
        canEditAnnotations = input.canEditAnnotations
        let annotationsChanged = input.annotations != savedAnnotations
        savedAnnotations = input.annotations
        let canonical = url.standardizedFileURL
        if canonical != loadedURL || sourceChanged || appliedMemoryRevision != input.memoryRevision || interactionResetChanged {
            // Capture against the old callback before rebinding to another book.
            if canonical != loadedURL || sourceChanged { captureWorkspaceMemory(deferDelivery: true) }
            memoryCaptureTask?.cancel(); memoryCaptureTask = nil
            appliedMemoryRevision = input.memoryRevision
            pendingWorkspaceMemory = input.workspaceMemory?.isValid == true ? input.workspaceMemory : nil
            applyWorkspaceDisplayPreferences()
            if canonical == loadedURL && !sourceChanged { synchronizeThumbnails() }
        }
        memoryCallback = input.onWorkspaceMemory
        if canonical != loadedURL || sourceChanged {
            sourcePage = requestedPage; lastParentPage = requestedPage; lastParentNavigationToken = navigationToken
            load(canonical)
        } else if requestedPage != lastParentPage || navigationToken != lastParentNavigationToken {
            // A page echoed by our own scroll callback acknowledges a native
            // scroll. Do not snap it back to the page top on the SwiftUI update.
            // The PDF may already have scrolled farther before that echo arrives.
            let isAcknowledgement = navigationToken == lastParentNavigationToken
                && lastCallback?.token == navigationToken && lastCallback?.page == requestedPage
            lastParentPage = requestedPage; lastParentNavigationToken = navigationToken; sourcePage = requestedPage
            lastCallback = nil
            if !isAcknowledgement {
                allowsSearchAutoNavigation = false
                invalidateNavigation()
                if let requestedPage { navigate(to: requestedPage, notifyParent: false) }
            }
        }
        if document?.isLocked == true, let password = input.password, !password.isEmpty,
           document?.unlock(withPassword: password) == true { showDocument() }
        if annotationsChanged { renderSavedAnnotations(); if showingAnnotationList { showAnnotations() } }
        if sourceDecorationsChanged || newProofMetadata || requestedPageChanged { renderSourceDecorations() }
        if sourceDecorationFocusID != input.focusedDecorationID {
            cancelSourceQuotePreparation()
            sourceDecorationFocusID = input.focusedDecorationID
            clearQuoteFocusHighlight()
            appliedSourceDecorationFocusID = nil; appliedSourceDecorationProofIdentity = nil; pendingQuote = nil
        }
        focusSourceDecorationIfReady()
        refreshControls()
        if pendingNavigation == nil, pendingWorkspaceMemory != nil, document?.isLocked == false { restoreWorkspaceDestination() }
    }

    private func load(_ url: URL) {
        resetPageGesture(); observedClip = nil
        if !editingAnnotationSheet { closeAnnotationPanel() }
        pdfView.cancelRegionSelection()
        clearSourceDecorations(); resetQuoteCache(); sourceDecorationFocusID = nil; appliedSourceDecorationFocusID = nil; appliedSourceDecorationProofIdentity = nil; pendingQuote = nil
        invalidateNavigation(); installingDocument = true
        defer { installingDocument = false }
        allowsSearchAutoNavigation = false; lastCallback = nil
        dismissSearch(restoreFocus: false)
        document?.delegate = nil
        thumbnails.pdfView = nil
        notePageGutters.restore()
        pdfView.document = nil; document = nil
        if securityScoped { loadedURL?.stopAccessingSecurityScopedResource() }
        securityScoped = false; loadedURL = url
        pageCurl?.cancel(); pageCurl = nil; sourceCanvas.isHidden = false
        documentGeneration += 1; lastEmittedPage = nil
        passwordField.stringValue = ""
        guard url.isFileURL else { showError("无法打开 PDF", "请选择本地 PDF 文件；查看器不会从远程地址载入文件。"); return }
        securityScoped = url.startAccessingSecurityScopedResource()
        guard let pdf = PDFDocument(url: url) else {
            showError("PDF 无法读取", "文件可能不可访问、已经移动或格式损坏。原文件没有被修改。")
            return
        }
        document = pdf
        if pdf.isLocked, let sessionPassword, !sessionPassword.isEmpty { _ = pdf.unlock(withPassword: sessionPassword) }
        if pdf.isLocked { showLocked(); return }
        showDocument()
    }

    private func showDocument() {
        guard let document, !document.isLocked, document.pageCount > 0 else {
            showError("PDF 没有可显示页面", "此文件没有有效页面，或尚未成功解锁。原文件没有被修改。")
            return
        }
        overlay.isHidden = true; passwordField.stringValue = ""
        installingDocument = true
        pdfView.document = document
        renderSavedAnnotations()
        renderSourceDecorations()
        synchronizeThumbnails()
        let desired = sourcePage ?? 1
        navigate(to: (1...document.pageCount).contains(desired) ? desired : 1, notifyParent: false)
        installingDocument = false
        focusSourceDecorationIfReady()
        refreshControls()
    }

    private func showLocked() {
        overlayTitle.stringValue = "PDF 需要密码"
        overlayDetail.stringValue = "输入此文件的打开密码。密码不会保存；原 PDF 不会被改写或重新加密。"
        passwordField.isHidden = false; overlayButton.title = "解锁"
        overlay.isHidden = false; refreshControls()
    }

    private func showError(_ title: String, _ detail: String) {
        overlayTitle.stringValue = title; overlayDetail.stringValue = detail
        passwordField.isHidden = true; overlayButton.title = "重新载入"
        overlay.isHidden = false; refreshControls()
    }

    @objc private func overlayAction() {
        guard let document, document.isLocked else { if let loadedURL { load(loadedURL) }; return }
        let password = passwordField.stringValue
        guard !password.isEmpty, password.count <= 1024, document.unlock(withPassword: password) else {
            passwordField.stringValue = ""; overlayDetail.stringValue = "密码不正确或文件无法解锁，请核对后重试。"; return
        }
        passwordField.stringValue = ""; sessionPassword = password; onUnlock?(password); showDocument()
    }

    private var currentPageNumber: Int? {
        guard let document, let page = pdfView.currentPage else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index + 1
    }

    /// Explicit navigation always addresses a destination, including a repeated
    /// request for the current page. Notifications resume after its layout turn.
    private func navigate(to number: Int, notifyParent: Bool = true, landing: PageLanding = .start) {
        guard let document, !document.isLocked, document.pageCount > 0, (1...document.pageCount).contains(number), let target = document.page(at: number - 1) else {
            if document?.isLocked != true { setStatus("页码超出 PDF 的有效范围。") }
            return
        }
        let oldPage = pdfView.currentPage
        let oldNumber = currentPageNumber
        let oldFrame = oldPage.map { convert(pdfView.convert($0.readingSourceBounds(for: .cropBox), from: $0), from: pdfView) }
        pageCurl?.cancel(); pageCurl = nil; sourceCanvas.isHidden = false
        invalidateNavigation()
        setStatus("")
        let request = navigationRequestID, generation = documentGeneration
        pendingNavigation = (request, number, notifyParent, landing)
        if paperBookMode, notifyParent, !reduceReadingMotion, !reducedMotion,
           let oldPage, let oldFrame, let oldNumber, abs(oldNumber - number) == 1 {
            preparePageCurl(from: oldPage, fromFrame: oldFrame, backwards: number < oldNumber)
        }
        position(at: target, landing: landing)
        DispatchQueue.main.async { [weak self] in self?.settleNavigation(request, generation: generation, attempt: 0) }
    }

    private func preparePageCurl(from old: PDFPage, fromFrame: CGRect, backwards: Bool) {
        pageCurl?.cancel(); pageCurl = nil
        let frame = CGRect(x: bounds.minX, y: bounds.minY, width: max(1, viewportPaperEdge - bounds.minX), height: bounds.height)
        let margin = noteMarginWidth > 0 ? controller?.noteMarginSnapshot(in: self) : nil
        let connections = controller.map {
            PositionNoteConnectionGeometry.make(positions: $0.notePositions, size: bounds.size, owner: notePlacementOwner)
        } ?? []
        guard let curl = PDFPaperCurl(frame: frame, from: old, fromFrame: fromFrame, backwards: backwards,
            paper: paperSurface.style, background: pdfView.backgroundColor, scale: window?.backingScaleFactor ?? 2,
            materialFrame: bounds, noteMarginWidth: scaledNoteMarginWidth, oldNoteMargin: margin, connections: connections,
            fitsVisibleSheets: true) else { sourceCanvas.isHidden = false; return }
        pageCurl = curl; sourceCanvas.isHidden = true
        addSubview(curl, positioned: .above, relativeTo: bookEdges)
        curl.completion = { [weak self, weak curl] in
            guard let self, let curl, self.pageCurl === curl else { return }
            self.layoutPaperSurface(); self.pdfView.displayIfNeeded(); self.pdfView.documentView?.displayIfNeeded()
            self.publishNoteAnchorPoints(allowDuringTurn: true)
            self.controller?.reportPaperTurn(id: self.bindingID, active: false)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08; curl.animator().alphaValue = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self, weak curl] in
                guard let self, let curl, self.pageCurl === curl else { return }
                curl.removeFromSuperview(); self.pageCurl = nil; self.sourceCanvas.isHidden = false
                self.sourceCanvas.needsDisplay = true; self.scheduleVisiblePages(); self.layoutPaperSurface()
            }
        }
    }
    private func updatePaperBackground() {
        pdfView.backgroundColor = noteMarginTargetWidth > 0 || paperSurface.style != .plain ? .white : .windowBackgroundColor
    }
    private var viewportPaperEdge: CGFloat {
        let scroll = observedClip?.enclosingScrollView ?? pdfScrollView(in: pdfView)
        return bounds.maxX - (noteMarginWidth > 0 ? max(12, scroll?.verticalScroller?.bounds.width ?? 17) : 0)
    }
    private var widthFitScale: CGFloat {
        guard let page = pdfView.currentPage else { return 1 }
        var size = page.readingSourceBounds(for: pdfView.displayBox).size
        if abs(page.rotation) % 180 == 90 { size = CGSize(width: size.height, height: size.width) }
        let scroll = observedClip?.enclosingScrollView ?? pdfScrollView(in: pdfView)
        let rail = noteMarginWidth > 0 && scroll?.scrollerStyle == .overlay ? max(12, scroll?.verticalScroller?.bounds.width ?? 17) : 0
        // A fit-page view can hide its legacy scroller, which must not change
        // the reference ratio while zoom crosses the scrolling threshold.
        let referenceWidth = noteMarginWidth > 0 && scroll?.scrollerStyle == .legacy
            ? pdfView.bounds.width - max(12, scroll?.verticalScroller?.bounds.width ?? 17)
            : (scroll?.contentSize.width ?? pdfView.bounds.width)
        return max(1, referenceWidth - noteMarginWidth - rail - (paperBookMode ? 16 : 0)) / max(1, size.width)
    }
    private var scaledNoteMarginWidth: CGFloat {
        noteMarginWidth * pdfView.scaleFactor / max(0.001, widthFitScale)
    }
    private var noteMarginFrame: CGRect {
        guard noteMarginWidth > 0, let page = pdfView.currentPage else { return .zero }
        return noteMarginFrame(for: page)
    }
    private func noteMarginFrame(for page: PDFPage) -> CGRect {
        let rect = convert(pdfView.convert(page.readingSourceBounds(for: .cropBox), from: page), from: pdfView)
        if usesPageGutters {
            guard notePageGutters.contains(page) else { return .zero }
            let sheet = convert(pdfView.convert(page.bounds(for: .cropBox), from: page), from: pdfView)
            return CGRect(x: rect.maxX, y: rect.minY, width: max(0, sheet.maxX - rect.maxX), height: rect.height)
        }
        // The whole page moves underneath a viewport clip. Anchors and cards
        // do not clamp to the window edge or disappear at an anchor threshold.
        return CGRect(x: rect.maxX, y: rect.minY, width: scaledNoteMarginWidth, height: rect.height)
    }
    private func sheetFrame(_ pageFrame: CGRect) -> CGRect {
        guard noteMarginWidth > 0 else { return pageFrame }
        return CGRect(x: pageFrame.minX, y: pageFrame.minY, width: pageFrame.width + scaledNoteMarginWidth, height: pageFrame.height)
    }
    private func layoutPaperSurface() {
        paperSurface.frame = bounds
        var regions = pdfView.visiblePages.map { page in
            convert(pdfView.convert(page.readingSourceBounds(for: .cropBox), from: page), from: pdfView).intersection(bounds)
        }.filter { !$0.isEmpty && !$0.isNull }
        if noteMarginWidth > 0 {
            // Reserve belongs to this page only. A full-height viewport strip
            // joined the top/right corners and filled neighbouring page gaps.
            regions += pdfView.visiblePages.map { page in
                noteMarginFrame(for: page).intersection(bounds)
            }.filter { !$0.isEmpty && !$0.isNull }
        }
        paperSurface.cover(regions)
        bookEdges.frame = bounds; bookEdges.isHidden = !paperBookMode
        if let page = pdfView.currentPage {
            bookEdges.pageFrame = sheetFrame(convert(pdfView.convert(page.readingSourceBounds(for: .cropBox), from: page), from: pdfView))
        }
    }
    private func requestPaperGeometry() {
        guard !paperGeometryScheduled else { return }; paperGeometryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.paperGeometryScheduled = false; self.layoutPaperSurface()
        }
    }
    private func setPaperBookMode(_ enabled: Bool) {
        guard paperBookMode != enabled else { return }
        if enabled, !PDFPaperCurl.supported { setStatus("这台 Mac 暂不支持纸书翻页，仍可使用上下或左右阅读。"); return }
        pageCurl?.cancel(); pageCurl = nil; sourceCanvas.isHidden = false
        let page = currentPageNumber ?? sourcePage ?? 1
        if enabled {
            flatBookMode = (readingDirection, pdfView.displayMode, fitMode, pdfView.scaleFactor)
            readingDirection = .horizontal; pdfView.displayDirection = .horizontal
            pdfView.readingDirection = .horizontal; pdfView.displayMode = .singlePage; fitMode = .page
        } else if let previous = flatBookMode {
            readingDirection = previous.0; pdfView.readingDirection = previous.0
            pdfView.displayDirection = previous.0 == .vertical ? .vertical : .horizontal
            pdfView.displayMode = previous.1; fitMode = previous.2
            isApplyingFit = true; pdfView.scaleFactor = previous.3; isApplyingFit = false
        }
        notePageGutters.restore(); noteInsetsNeedLayout = true
        paperBookMode = enabled; flatBookMode = enabled ? flatBookMode : nil
        resetPageGesture(); pdfView.layoutDocumentView(); navigate(to: page, notifyParent: false)
        layoutPaperSurface(); refreshControls(); scheduleWorkspaceCapture()
    }

    private func invalidateNavigation() {
        invalidateSourcePress()
        cancelSourceQuotePreparation()
        clearQuoteFocusHighlight()
        awaitingSourceFocusProof = false
        navigationRequestID &+= 1; pageObservationID &+= 1; pendingNavigation = nil; pendingQuote = nil
    }

    private func position(at page: PDFPage, landing: PageLanding = .start) {
        pdfView.go(to: page)
        // A display-mode change rebuilds PDFKit's document view. Resolve that
        // layout before fitting or a destination may use the previous page's
        // geometry and retain its old scroll offset in single-page mode.
        pdfView.layoutDocumentView()
        applyFit()
        // A different crop/rotation changes the proportional margin too.
        // Tile that width before capturing the target, not on a later pass
        // after the paper animation has already started.
        _ = layoutNoteInsets()
        pdfView.layoutDocumentView()
        let box = page.readingSourceBounds(for: pdfView.displayBox)
        let point: CGPoint
        if landing == .end {
            let visiblePage = pdfView.convert(box, from: page)
            let top = pdfView.isFlipped ? visiblePage.minY : visiblePage.maxY
            let bottom = pdfView.isFlipped ? visiblePage.maxY : visiblePage.minY
            let edge = readingDirection == .vertical
                ? CGPoint(x: visiblePage.minX, y: bottom)
                : CGPoint(x: visiblePage.maxX, y: top)
            point = pdfView.convert(edge, to: page)
        } else { point = CGPoint(x: box.minX, y: box.maxY) }
        pdfView.go(to: PDFDestination(page: page, at: point))
        refreshControls()
    }

    private func settleNavigation(_ request: Int, generation: Int, attempt: Int) {
        guard generation == documentGeneration, let pending = pendingNavigation,
              request == navigationRequestID, pending.id == request else { return }
        // makeNSView can load a document before SwiftUI gives the PDF a viewport.
        // Keep the request pending; layout() will resume it once it has a size.
        guard pdfView.bounds.width > 40, pdfView.bounds.height > 40 else { return }
        if pageCurl != nil, noteMarginAnimation != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.settleNavigation(request, generation: generation, attempt: attempt)
            }
            return
        }
        // PDFKit may finish document/scale layout on the next run-loop turn.
        // An older attempt cannot move or notify after a newer request arrives.
        if attempt == 0 || currentPageNumber != pending.page {
            guard attempt < 3, let target = document?.page(at: pending.page - 1) else {
                pendingNavigation = nil
                pageCurl?.cancel(); pageCurl = nil; sourceCanvas.isHidden = false
                setStatus("PDF 定位未完成，请重新选择页码。")
                return
            }
            position(at: target, landing: pending.landing)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.settleNavigation(request, generation: generation, attempt: attempt + 1) }
            return
        }
        pendingNavigation = nil; refreshControls()
        restoreWorkspaceDestination()
        if layoutNoteInsets() { pdfView.layoutDocumentView() }
        layoutPaperSurface()
        if let curl = pageCurl, !curl.targetPrepared, let page = pdfView.currentPage {
            let frame = convert(pdfView.convert(page.readingSourceBounds(for: .cropBox), from: page), from: pdfView)
            if !curl.prepareTarget(page, in: frame, noteMarginWidth: scaledNoteMarginWidth) { curl.cancel(); pageCurl = nil; sourceCanvas.isHidden = false }
        }
        if let quote = pendingQuote, quote.page == pending.page {
            pendingQuote = nil; applyQuoteFocus(on: quote.page, quote: quote.quote, prefix: quote.prefix, suffix: quote.suffix, decoration: quote.decoration)
        }
        if pending.notifyParent { schedulePageCallback(pending.page) }
        else { lastEmittedPage = pending.page }
    }

    @objc private func previousPage() {
        if let page = currentPageNumber, page > 1 { navigate(to: page - 1); window?.makeFirstResponder(pdfView) }
    }
    @objc private func nextPage() {
        if let page = currentPageNumber, let document, page < document.pageCount { navigate(to: page + 1); window?.makeFirstResponder(pdfView) }
    }
    @objc private func toggleThumbnails() {
        setThumbnailsVisible(thumbnailPanel.isHidden)
    }
    @objc private func hideThumbnails() { setThumbnailsVisible(false) }
    private func setThumbnailsVisible(_ visible: Bool) {
        guard !visible || (document != nil && document?.isLocked == false) else { return }
        thumbnailPanel.isHidden = !visible
        synchronizeThumbnails()
        needsLayout = true; layoutSubtreeIfNeeded(); layoutThumbnails(); refreshControls()
    }

    @objc private func zoomOut() { changeZoom(by: 1 / 1.2) }
    @objc private func zoomIn() { changeZoom(by: 1.2) }
    private func changeZoom(by factor: CGFloat) {
        fitMode = .custom
        pdfView.autoScales = false
        pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, pdfView.scaleFactor * factor))
        refreshControls()
    }

    private func changePDFDisplayMode(_ mode: PDFDisplayMode) {
        guard pdfView.displayMode != mode else { refreshControls(); return }
        let page = currentPageNumber ?? sourcePage ?? 1
        memoryCaptureTask?.cancel(); memoryCaptureTask = nil; pendingWorkspaceMemory = nil
        // Suppress synchronous PDFKit observations until the explicit current
        // page navigation has been installed. A mode choice must not echo a
        // transient first page into the book's reading position.
        installingDocument = true
        resetPageGesture()
        if mode == .singlePage { fitMode = .page }
        notePageGutters.restore(); noteInsetsNeedLayout = true
        pdfView.displayMode = mode
        pdfView.layoutDocumentView()
        installingDocument = false
        navigate(to: page, notifyParent: false)
        refreshControls()
    }

    private func changePDFDirection(_ direction: PDFReadingDirection) {
        guard readingDirection != direction else { refreshControls(); return }
        let page = currentPageNumber ?? sourcePage ?? 1
        memoryCaptureTask?.cancel(); memoryCaptureTask = nil; pendingWorkspaceMemory = nil
        installingDocument = true; resetPageGesture()
        readingDirection = direction; pdfView.readingDirection = direction
        pdfView.displayDirection = direction == .vertical ? .vertical : .horizontal
        pdfView.layoutDocumentView(); installingDocument = false
        navigate(to: page, notifyParent: false)
        refreshControls()
    }

    @objc private func toggleSearch() {
        if searchRow.isHidden { showSearch() } else { closeSearch() }
    }

    private func showSearch() {
        guard document != nil, document?.isLocked == false else { return }
        let wasHidden = searchRow.isHidden
        searchRow.isHidden = false; header.isHidden = false
        installSearchEscapeMonitor()
        needsLayout = true; layoutSubtreeIfNeeded()
        if wasHidden, !reduceReadingMotion {
            header.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18; header.animator().alphaValue = 1
            }
        } else { header.alphaValue = 1 }
        window?.makeFirstResponder(searchField)
        refreshControls()
    }

    @objc private func openAISearch() {
        guard !interactionBlocked else { return }
        let query = searchField.stringValue
        closeSearch(); onAISearch?(query)
    }
    @objc private func closeSearch() { dismissSearch(restoreFocus: true) }

    private func dismissSearch(restoreFocus: Bool) {
        let wasVisible = !searchRow.isHidden
        searchRow.isHidden = true; searchField.stringValue = ""
        removeSearchEscapeMonitor()
        // Invalidating the search generation also prevents queued PDFKit results
        // from navigating, restoring highlights or showing a late status message.
        clearSearchState(); setStatus("")
        header.isHidden = true; needsLayout = true
        if wasVisible, restoreFocus, !interactionBlocked { window?.makeFirstResponder(pdfView) }
    }

    private func installSearchEscapeMonitor() {
        guard searchEscapeMonitor == nil else { return }
        searchEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, !self.interactionBlocked, event.keyCode == 53, !self.searchRow.isHidden,
                      let owner = self.window, event.window === owner, owner.attachedSheet == nil,
                      !self.editingAnnotationSheet, let responder = owner.firstResponder,
                      self.ownsResponder(responder) || responder === owner else { return false }
                self.closeSearch(); return true
            }
            return handled ? nil : event
        }
    }

    private func removeSearchEscapeMonitor() {
        if let searchEscapeMonitor { NSEvent.removeMonitor(searchEscapeMonitor) }
        searchEscapeMonitor = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { dismissSearch(restoreFocus: false) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removePageScrollMonitor(); removeSourcePointerMonitor(); resetPageGesture()
        guard window != nil else { return }
        sourcePointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.observeSourcePointer(event) }
            // Observation only: native PDF text selection, links and scrolling
            // always receive the original event, including source clicks.
            return event
        }
        pageScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumePageScroll(event) ?? false }
            return consumed ? nil : event
        }
    }
    private func removePageScrollMonitor() {
        if let pageScrollMonitor { NSEvent.removeMonitor(pageScrollMonitor) }
        pageScrollMonitor = nil
    }
    private func resetPageGesture() { pageGestureOwnership.reset(); pageTurnPolicy.reset() }
    private static func gesturePhase(_ phase: NSEvent.Phase) -> CanvasGesturePhase {
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.began) { return .began }
        if phase.contains(.mayBegin) { return .mayBegin }
        if phase.contains(.ended) { return .ended }
        return phase.isEmpty ? .none : .changed
    }
    private func ownsPDFHit(_ event: NSEvent, in owner: NSWindow) -> Bool {
        ownsPDFHit(at: event.locationInWindow, in: owner)
    }
    private func ownsPDFHit(at windowPoint: CGPoint, in owner: NSWindow) -> Bool {
        guard let content = owner.contentView else { return false }
        let point = content.superview?.convert(windowPoint, from: nil) ?? windowPoint
        guard let hit = content.hitTest(point), hit === pdfView || hit.isDescendant(of: pdfView) else { return false }
        // A scrollbar is a native control rather than a page-turn surface.
        return !(hit is NSScroller)
    }
    private func consumePageScroll(_ event: NSEvent, fromNoteMargin: Bool = false) -> Bool {
        if pageCurl != nil, let owner = window, event.window === owner,
           fromNoteMargin || ownsPDFHit(event, in: owner) { return true }
        guard pdfView.displayMode == .singlePage, !interactionBlocked,
              !isHiddenOrHasHiddenAncestor, !installingDocument,
              let owner = window, event.window === owner, owner.isKeyWindow,
              owner.attachedSheet == nil, NSApp.modalWindow == nil,
              !editingAnnotationSheet, document?.isLocked == false else {
            resetPageGesture(); return false
        }
        let phase = Self.gesturePhase(event.phase), momentum = Self.gesturePhase(event.momentumPhase)
        let eligible = fromNoteMargin || ownsPDFHit(event, in: owner)
        guard pageGestureOwnership.accepts(phase: phase, momentum: momentum, isEligible: eligible) else { return false }
        // A field editor elsewhere in this window keeps its input. PDF-owned
        // text selection is not an editable field and remains scrollable.
        if let editor = owner.firstResponder as? NSTextView, editor.isEditable, !editor.isDescendant(of: pdfView) {
            pageTurnPolicy.reset(); return true
        }
        // A gesture-owned turn may still be completing PDFKit layout. Preserve
        // its one-turn latch and swallow the tail until that navigation settles.
        if pendingNavigation != nil || pageCurl != nil { return true }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !pdfView.isRegionSelectionArmed, let edges = pageBoundaries() else { return false }
        let wheelAlongReadingAxis = readingDirection == .horizontal && event.scrollingDeltaX == 0
            && (!event.hasPreciseScrollingDeltas || event.modifierFlags.contains(.shift))
        let primary = readingDirection == .vertical || wheelAlongReadingAxis ? event.scrollingDeltaY : event.scrollingDeltaX
        let cross = wheelAlongReadingAxis ? 0 : (readingDirection == .vertical ? event.scrollingDeltaX : event.scrollingDeltaY)
        // scrollingDelta already respects macOS natural scrolling. Negating
        // converts movement of the content into previous/next-page semantics.
        switch pageTurnPolicy.action(delta: -Double(primary), crossDelta: Double(cross),
                                     precise: event.hasPreciseScrollingDeltas, phase: phase,
                                     momentum: momentum, timestamp: event.timestamp,
                                     atStart: edges.start, atEnd: edges.end) {
        case .scroll: return false
        case .consume: return true
        case .turn(let offset):
            turnPage(offset: offset); return true
        }
    }
    private func pageBoundaries() -> (start: Bool, end: Bool)? {
        guard let page = pdfView.currentPage else { return nil }
        if observedClip == nil { observePDFViewport() }
        let viewport = observedClip.map { pdfView.convert($0.bounds, from: $0) } ?? pdfView.bounds
        let rect = pdfView.convert(page.readingSourceBounds(for: pdfView.displayBox), from: page), tolerance: CGFloat = 3
        guard rect.width > 0, rect.height > 0, viewport.width > 0, viewport.height > 0 else { return nil }
        if readingDirection == .horizontal {
            return (rect.minX >= viewport.minX - tolerance, rect.maxX <= viewport.maxX + tolerance)
        }
        if pdfView.isFlipped {
            return (rect.minY >= viewport.minY - tolerance, rect.maxY <= viewport.maxY + tolerance)
        }
        return (rect.maxY <= viewport.maxY + tolerance, rect.minY >= viewport.minY - tolerance)
    }
    private func turnPage(offset: Int) {
        guard let page = currentPageNumber, let document else { return }
        let destination = page + offset
        guard (1...document.pageCount).contains(destination) else { return }
        navigate(to: destination, landing: offset < 0 ? .end : .start)
    }
    private func handlePageNavigationKey(offset: Int, direction: PDFReadingDirection, pageStep: Bool, repeatKey: Bool) -> Bool {
        guard !interactionBlocked, !installingDocument,
              let owner = window, owner.attachedSheet == nil, !editingAnnotationSheet,
              let responder = owner.firstResponder, ownsResponder(responder) else { return false }
        awaitingSourceFocusProof = false
        cancelSourceQuotePreparation()
        if pendingNavigation != nil { return true }
        guard let edges = pageBoundaries() else { return false }
        let boundary = offset < 0 ? edges.start : edges.end
        if pdfView.displayMode == .singlePage, direction == readingDirection, boundary {
            // Holding a key does not run through several pages after the first
            // turn; another physical key press starts the next turn.
            if !repeatKey { turnPage(offset: offset) }
            return true
        }
        guard let clip = observedClip else { return false }
        var proposed = clip.bounds
        let distance = pageStep ? (direction == .vertical ? proposed.height : proposed.width) * 0.85 : 40
        if direction == .vertical {
            proposed.origin.y += CGFloat(offset) * distance * (clip.documentView?.isFlipped == true ? 1 : -1)
        } else { proposed.origin.x += CGFloat(offset) * distance }
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        scheduleWorkspaceCapture()
        return true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // SwiftUI can make a final representable size assignment after AppKit's
        // current layout pass. Reconcile row constraints at that final size.
        updateSearchResultsHeight()
        updateThumbnailTop()
    }
    private func updateThumbnailTop() {
        let nextTop: CGFloat = header.isHidden ? 76 : 76 + (searchPanelHeight?.constant ?? 64) + 12
        if let thumbnailTop, abs(thumbnailTop.constant - nextTop) > 0.5 { thumbnailTop.constant = nextTop; needsLayout = true }
    }
    override func layout() {
        super.layout()
        updateSearchResultsHeight()
        if let curl = pageCurl, curl.viewportSize != bounds.size {
            curl.cancel(); pageCurl = nil; sourceCanvas.isHidden = false
        }
        // SwiftUI can resize the representable before the nested stack/PDFView
        // has laid out. Always measure the settled child, including a first note.
        contentStack.layoutSubtreeIfNeeded()
        let changedInsets = layoutNoteInsets()
        sourceCanvas.frame = bounds; sourceCanvas.needsDisplay = true
        scheduleVisiblePages()
        updateThumbnailTop()
        let size = pdfView.bounds.size
        if changedInsets || abs(size.width - lastViewportSize.width) > 0.5 || abs(size.height - lastViewportSize.height) > 0.5 {
            invalidateSourcePress()
            lastViewportSize = size; layoutThumbnails(); applyFit()
            if layoutNoteInsets() { pdfView.layoutDocumentView() }
            if noteMarginAnimation == nil { restoreNoteMarginViewport() }
            if let pending = pendingNavigation, size.width > 40, size.height > 40 {
                let request = pending.id, generation = documentGeneration
                DispatchQueue.main.async { [weak self] in self?.settleNavigation(request, generation: generation, attempt: 0) }
            }
            scheduleSourceHoverRefresh()
        }
        layoutPaperSurface()
        refreshControls()
    }

    private func changeNoteMargin(to target: CGFloat) {
        guard noteMarginTargetWidth != target else { return }
        pageCurl?.cancel(); pageCurl = nil; sourceCanvas.isHidden = false
        noteMarginTargetWidth = target; noteMarginAnimation?.invalidate(); noteMarginAnimation = nil
        // At a continuous-page boundary PDFKit's destination may name the
        // preceding page, even though currentPage and the visible text belong
        // to the next one. Keep that exact viewport point in the displayed
        // page's coordinates; replaying the raw destination changes its page.
        if let destination = pdfView.currentDestination, let destinationPage = destination.page,
           let page = pdfView.currentPage {
            let point = destinationPage === page ? destination.point
                : pdfView.convert(pdfView.convert(destination.point, from: destinationPage), to: page)
            noteMarginDestination = PDFDestination(page: page, at: point)
        } else { noteMarginDestination = nil }
        guard !reduceReadingMotion, !reducedMotion, document != nil, bounds.width > 40 else {
            noteMarginWidth = target; noteInsetsNeedLayout = true; needsLayout = true; return
        }
        let start = noteMarginWidth, began = ProcessInfo.processInfo.systemUptime
        let generation = documentGeneration
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
            guard let self, self.documentGeneration == generation else { timer.invalidate(); return }
            let t = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.38)
            let eased = t * t * (3 - 2 * t)
            self.noteMarginWidth = start + (target - start) * eased
            self.noteInsetsNeedLayout = true; self.needsLayout = true; self.layoutSubtreeIfNeeded()
            self.scheduleVisiblePages()
            if t >= 1 {
                timer.invalidate(); self.noteMarginAnimation = nil
                self.restoreNoteMarginViewport()
                self.scheduleVisiblePages(); self.scheduleWorkspaceCapture()
            }
            }
        }
        noteMarginAnimation = timer; RunLoop.main.add(timer, forMode: .common)
    }

    private func restoreNoteMarginViewport() {
        guard let destination = noteMarginDestination else { return }
        noteMarginDestination = nil
        guard let page = destination.page, let document, document.index(for: page) != NSNotFound else { return }
        pdfView.go(to: destination)
        pdfView.layoutDocumentView()
        // go(to:) can clamp an anchor just outside its page. Keep the original
        // visible boundary through the native clip, including reduced motion.
        if let clip = observedClip, let actual = pdfView.currentDestination, let actualPage = actual.page {
            let desired = clip.convert(pdfView.convert(destination.point, from: page), from: pdfView)
            let current = clip.convert(pdfView.convert(actual.point, from: actualPage), from: pdfView)
            let origin = CGPoint(x: clip.bounds.origin.x + desired.x - current.x,
                                 y: clip.bounds.origin.y + desired.y - current.y)
            if origin.x.isFinite, origin.y.isFinite {
                clip.scroll(to: origin); clip.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            if fitMode == .width, readingDirection == .vertical {
                // A former paper-book inset can leave a negative horizontal
                // destination. Preserve the reading height, while an exact
                // fit-width page returns to the viewport's left edge.
                let printed = pdfView.convert(page.readingSourceBounds(for: .cropBox), from: page)
                let left = clip.convert(CGPoint(x: printed.minX, y: printed.minY), from: pdfView)
                let edge = clip.convert(CGPoint(x: pdfView.bounds.minX, y: printed.minY), from: pdfView)
                let x = clip.bounds.minX + left.x - edge.x
                if x.isFinite, abs(left.x - edge.x) > 0.01 {
                    clip.scroll(to: CGPoint(x: x, y: clip.bounds.minY)); clip.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            }
        }
    }

    @discardableResult private func layoutNoteInsets() -> Bool {
        guard let scroll = observedClip?.enclosingScrollView ?? pdfScrollView(in: pdfView) else { return false }
        if noteInsetScrollView !== scroll {
            noteInsetScrollView = scroll
            originalContentInsets = scroll.contentInsets; originalScrollerInsets = scroll.scrollerInsets
            originalAutomaticInsets = scroll.automaticallyAdjustsContentInsets; noteInsetsNeedLayout = true
        }
        let overlayRail = scroll.scrollerStyle == .overlay ? max(12, scroll.verticalScroller?.bounds.width ?? 17) : 0
        let reserved = noteMarginWidth == 0 || usesPageGutters ? 0 : scaledNoteMarginWidth + overlayRail
        var gutterPages: [PDFPage] = []
        if usesPageGutters, noteMarginWidth > 0, let document {
            for index in notePlacementsByPage.keys.sorted() where (notePlacementsByPage[index] ?? []).contains(where: { $0.1.sourceHash == sourceHash }) {
                if let page = document.page(at: index - 1) { gutterPages.append(page) }
            }
            if let page = noteBindingPreview?.0, !gutterPages.contains(where: { $0 === page }) { gutterPages.append(page) }
            if gutterPages.isEmpty, let page = pdfView.currentPage { gutterPages.append(page) }
        }
        let reference = pdfView.currentPage.map { page -> CGFloat in
            let crop = page.readingSourceBounds(for: .cropBox)
            return abs(page.rotation) % 180 == 90 ? crop.height : crop.width
        } ?? 1
        let ratio = noteMarginWidth / max(1, widthFitScale * reference)
        let changedGutters = notePageGutters.apply(pages: gutterPages, widthRatio: usesPageGutters ? ratio : 0)
        guard noteInsetsNeedLayout || changedGutters || abs(appliedNoteReservedWidth - reserved) > 0.1 else { return false }
        noteInsetsNeedLayout = false; appliedNoteReservedWidth = reserved
        scroll.automaticallyAdjustsContentInsets = reserved == 0 ? originalAutomaticInsets : false
        var content = originalContentInsets; content.right += reserved
        var scroller = originalScrollerInsets; scroller.right -= reserved
        // Public AppKit insets reserve page space while the original native
        // scroller remains at the outer edge of the combined book surface.
        scroll.contentInsets = content; scroll.scrollerInsets = scroller; scroll.tile()
        if changedGutters { pdfView.layoutDocumentView() }
        return true
    }
    private func pdfScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.pdfScrollView(in: $0) }.first
    }

    private func applyFit() {
        guard fitMode != .custom, let page = pdfView.currentPage, pdfView.bounds.width > 40, pdfView.bounds.height > 40 else { return }
        var size = page.readingSourceBounds(for: pdfView.displayBox).size
        if abs(page.rotation) % 180 == 90 { size = NSSize(width: size.height, height: size.width) }
        guard size.width > 0, size.height > 0 else { return }
        let scroll = observedClip?.enclosingScrollView ?? pdfScrollView(in: pdfView)
        let viewport = scroll?.contentSize ?? pdfView.bounds.size
        let width = widthFitScale
        let height = max(1, viewport.height - 32) / size.height
        let scale: CGFloat = fitMode == .actual ? 1 : (fitMode == .width ? width : min(width, height))
        pdfView.autoScales = false
        let clamped = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, scale))
        isApplyingFit = true
        if abs(pdfView.scaleFactor - clamped) > 0.001 { pdfView.scaleFactor = clamped }
        isApplyingFit = false
        refreshControls()
    }

    private func synchronizeThumbnails() {
        // PDFThumbnailView eagerly creates native collection cells even while
        // an ancestor panel is hidden. Keep it detached until the user opens
        // thumbnails (including a saved visible workspace).
        guard !thumbnailPanel.isHidden, let document, !document.isLocked else {
            if thumbnails.pdfView != nil { thumbnails.pdfView = nil }
            return
        }
        if thumbnails.pdfView !== pdfView { thumbnails.pdfView = pdfView }
        layoutThumbnails()
    }

    private func layoutThumbnails() {
        guard !thumbnailPanel.isHidden, thumbnails.pdfView != nil else { return }
        // PDFThumbnailView already owns a scrolling collection. Giving it the
        // entire book's height creates a second scroll range whose bottom can
        // show empty collection space instead of the visible thumbnails.
        thumbnailScroll.hasVerticalScroller = false
        thumbnails.frame = NSRect(origin: .zero, size: NSSize(
            width: max(100, thumbnailScroll.contentSize.width),
            height: max(1, thumbnailScroll.contentSize.height)))
        let page = pdfView.currentPage ?? document?.page(at: 0)
        var pageSize = page?.readingSourceBounds(for: .cropBox).size ?? .init(width: 600, height: 800)
        if let page, abs(page.rotation) % 180 == 90 { pageSize = .init(width: pageSize.height, height: pageSize.width) }
        let grid = PDFThumbnailGridGeometry(width: thumbnails.bounds.width, pageAspectRatio: pageSize.width / max(1, pageSize.height), density: thumbnailDensity)
        if thumbnails.maximumNumberOfColumns != grid.columns { thumbnails.maximumNumberOfColumns = grid.columns }
        if thumbnails.thumbnailSize != grid.thumbnailSize { thumbnails.thumbnailSize = grid.thumbnailSize }
    }
    @objc private func changeThumbnailDensity(_ sender: PDFThumbnailDensityButton) {
        thumbnailDensity = sender.density
        UserDefaults.standard.set(thumbnailDensity.rawValue, forKey: "reader.thumbnailDensity")
        for button in thumbnailSizeButtons { button.selectedDensity = button.density == thumbnailDensity }
        layoutThumbnails()
    }

    @objc private func pageChanged(_ notification: Notification) {
        requestPaperGeometry()
        scheduleVisiblePages(); sourceCanvas.needsDisplay = true
        refreshControls()
        guard !installingDocument, pendingNavigation == nil else { return }
        if fitMode == .page { applyFit() }
        if let page = currentPageNumber { schedulePageCallback(page) }
    }

    private func schedulePageCallback(_ page: Int) {
        pageObservationID &+= 1
        guard page != lastEmittedPage, !installingDocument, pendingNavigation == nil else { return }
        let generation = documentGeneration, navigation = navigationRequestID
        let observation = pageObservationID, token = lastParentNavigationToken ?? 0
        // A document switch, source navigation or later native page observation
        // invalidates this queued callback before it can update SwiftUI selection.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.documentGeneration == generation,
                  self.navigationRequestID == navigation, self.pageObservationID == observation,
                  self.lastParentNavigationToken == token, self.pendingNavigation == nil,
                  !self.installingDocument, self.currentPageNumber == page else { return }
            self.lastEmittedPage = page; self.lastCallback = (page, token)
            self.callback?(page)
        }
    }

    @objc private func scaleChanged(_ notification: Notification) {
        requestPaperGeometry()
        noteInsetsNeedLayout = true; needsLayout = true
        invalidateSourcePress()
        if !isApplyingFit, !installingDocument, pendingNavigation == nil, pendingWorkspaceMemory == nil { fitMode = .custom }
        refreshControls(); sourceCanvas.needsDisplay = true; scheduleWorkspaceCapture(); scheduleVisiblePages()
        scheduleSourceHoverRefresh()
    }

    @objc private func pdfViewportScrolled(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView, clip === observedClip else { return }
        sourceScrollQuietUntil = ProcessInfo.processInfo.systemUptime + 0.15
        invalidateSourcePress(); reportSourceHover(nil)
        layoutPaperSurface()
        sourceCanvas.needsDisplay = true; scheduleVisiblePages(); scheduleWorkspaceCapture()
        scheduleSourceHoverRefresh()
    }
    private func observePDFViewport() {
        func findClip(_ view: NSView) -> NSClipView? {
            if let scroll = view as? NSScrollView { return scroll.contentView }
            for child in view.subviews { if let clip = findClip(child) { return clip } }
            return nil
        }
        observedClip = findClip(pdfView); observedClip?.postsBoundsChangedNotifications = true
    }
    private var defaultReadingDirection: PDFReadingDirection {
        PDFReadingDirection(rawValue: UserDefaults.standard.string(forKey: "reading.defaultDirection") ?? "") ?? .vertical
    }
    private var defaultContinuous: Bool {
        UserDefaults.standard.object(forKey: "reading.defaultContinuous") as? Bool ?? true
    }
    private var reduceReadingMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UserDefaults.standard.bool(forKey: "appearance.reduceMotion")
    }
    private func applyWorkspaceDisplayPreferences() {
        let saved = pendingWorkspaceMemory
        paperBookMode = saved?.paperBook == true
        flatBookMode = nil
        bookEdges.isHidden = !paperBookMode
        resetPageGesture()
        readingDirection = paperBookMode ? .horizontal : (saved.map { $0.direction ?? .vertical } ?? defaultReadingDirection)
        pdfView.readingDirection = readingDirection
        pdfView.displayDirection = readingDirection == .vertical ? .vertical : .horizontal
        switch saved?.fitMode { case "page": fitMode = .page; case "actual": fitMode = .actual; case "custom": fitMode = .custom; default: fitMode = .width }
        let continuous = paperBookMode ? false : (saved?.continuous ?? defaultContinuous)
        pdfView.displayMode = continuous ? .singlePageContinuous : .singlePage
        if saved == nil, !continuous { fitMode = .page }
        thumbnailPanel.isHidden = !(saved?.thumbnails ?? false)
        if fitMode == .custom, let scale = saved?.scale { pdfView.scaleFactor = CGFloat(scale) }
    }
    private func restoreWorkspaceDestination() {
        observePDFViewport()
        guard let saved = pendingWorkspaceMemory else { scheduleWorkspaceCapture(); return }
        pendingWorkspaceMemory = nil
        guard let document, let page = document.page(at: saved.page - 1), currentPageNumber == saved.page else { return }
        if fitMode == .custom { pdfView.scaleFactor = CGFloat(saved.scale) } else { applyFit() }
        if let location = saved.location {
            let box = page.readingSourceBounds(for: pdfView.displayBox)
            let point = CGPoint(x: box.minX + location.x * box.width, y: box.minY + location.y * box.height)
            let viewport = pdfView.convert(pdfView.bounds, to: page)
            // The viewport's origin can lie just outside the current page at
            // a continuous-page boundary, or beside a centered narrow page.
            // Preserve those coordinates; clamping to the crop box moves the
            // visible text. Reject implausible saved geometry before PDFKit.
            let allowed = box.insetBy(dx: -max(box.width, viewport.width), dy: -max(box.height, viewport.height))
            let finiteGeometry = [box, viewport, allowed].allSatisfy {
                $0.minX.isFinite && $0.minY.isFinite && $0.maxX.isFinite && $0.maxY.isFinite
                    && $0.width > 0 && $0.height > 0
            }
            if finiteGeometry, point.x.isFinite, point.y.isFinite, allowed.contains(point) {
                var destinationPage = page, destinationPoint = point
                // Old continuous-view records may name a neighbouring page
                // while their out-of-page anchor displays another page.
                // Resolve the expected viewport center geometrically, keeping
                // the exact original anchor instead of guessing a page number.
                if pdfView.displayMode == .singlePageContinuous,
                   !box.insetBy(dx: -0.000_001, dy: -0.000_001).contains(point) {
                    pdfView.layoutDocumentView()
                    observePDFViewport()
                    if let clip = observedClip {
                        let bounds = clip.bounds
                        let desired = clip.convert(pdfView.convert(point, from: page), from: pdfView)
                        let center = CGPoint(x: desired.x + bounds.width / 2,
                            y: desired.y + (clip.isFlipped ? bounds.height / 2 : -bounds.height / 2))
                        let viewCenter = pdfView.convert(center, from: clip)
                        if bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
                           center.x.isFinite, center.y.isFinite, viewCenter.x.isFinite, viewCenter.y.isFinite,
                           let resolved = pdfView.page(for: viewCenter, nearest: false),
                           document.index(for: resolved) != NSNotFound, resolved !== page {
                            let converted = pdfView.convert(pdfView.convert(point, from: page), to: resolved)
                            if converted.x.isFinite, converted.y.isFinite {
                                destinationPage = resolved; destinationPoint = converted
                            }
                        }
                    }
                }
                pdfView.go(to: PDFDestination(page: destinationPage, at: destinationPoint))
                pdfView.layoutDocumentView()
                // PDFKit may clamp go(to:) to the page even for a legitimate
                // viewport origin outside it. Finish the exact restoration in
                // clip coordinates, which also account for flipped/scaled views.
                observePDFViewport()
                if let clip = observedClip, let actual = pdfView.currentDestination,
                   let actualPage = actual.page, document.index(for: actualPage) != NSNotFound {
                    let desiredPoint = clip.convert(pdfView.convert(point, from: page), from: pdfView)
                    let actualPoint = clip.convert(pdfView.convert(actual.point, from: actualPage), from: pdfView)
                    let origin = CGPoint(x: clip.bounds.origin.x + desiredPoint.x - actualPoint.x,
                                         y: clip.bounds.origin.y + desiredPoint.y - actualPoint.y)
                    if origin.x.isFinite, origin.y.isFinite {
                        clip.scroll(to: origin); clip.enclosingScrollView?.reflectScrolledClipView(clip)
                    }
                }
            }
        }
        scheduleWorkspaceCapture()
    }
    private func scheduleWorkspaceCapture() {
        guard !installingDocument, pendingNavigation == nil, pendingWorkspaceMemory == nil else { return }
        memoryCaptureTask?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.captureWorkspaceMemory() }
        memoryCaptureTask = item; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
    @objc private func captureWorkspaceMemoryNow(_ notification: Notification) {
        // The caller flushes immediately after posting, before a book switch or
        // app shutdown can invalidate this reader's scoped memory callback.
        memoryCaptureTask?.cancel(); memoryCaptureTask = nil
        captureWorkspaceMemory()
    }
    private func captureWorkspaceMemory(deferDelivery: Bool = false) {
        guard !installingDocument, pendingNavigation == nil, pendingWorkspaceMemory == nil,
              let document, !document.isLocked, let page = pdfView.currentPage,
              let destination = pdfView.currentDestination, let destinationPage = destination.page,
              document.index(for: destinationPage) != NSNotFound else { return }
        let index = document.index(for: page), box = page.readingSourceBounds(for: pdfView.displayBox)
        guard index != NSNotFound, box.width > 0, box.height > 0 else { return }
        // PDFKit chooses currentPage at the viewport center; currentDestination
        // can belong to the preceding page at the same visible boundary. Store
        // the displayed page identity and express that same viewport anchor in
        // its coordinates, letting PDFKit handle rotation and crop origins.
        let point = destinationPage === page ? destination.point
            : pdfView.convert(pdfView.convert(destination.point, from: destinationPage), to: page)
        let location = WorkspacePoint(x: Double((point.x - box.minX) / box.width), y: Double((point.y - box.minY) / box.height))
        let mode: String
        switch fitMode { case .page: mode = "page"; case .width: mode = "width"; case .actual: mode = "actual"; case .custom: mode = "custom" }
        let memory = WorkspacePDFMemory(page: index + 1, location: location, scale: Double(pdfView.scaleFactor), fitMode: mode, continuous: pdfView.displayMode == .singlePageContinuous, thumbnails: !thumbnailPanel.isHidden, direction: readingDirection, paperBook: paperBookMode ? true : nil)
        guard memory.isValid else { return }
        let receipt = PDFWorkspaceMemoryReceipt(memory: memory)
        let callback = memoryCallback
        if deferDelivery {
            // Representable update/dismantle can run inside a SwiftUI graph
            // transaction. Freeze the scoped receipt before releasing the view;
            // its owner is checked again by the store after this transaction.
            DispatchQueue.main.async { callback?(receipt) }
        } else {
            // Explicit capture notifications must finish before select/quit
            // flushes the latest reading position to disk.
            callback?(receipt)
        }
    }

    private func refreshControls() {
        let ready = document != nil && document?.isLocked == false && (document?.pageCount ?? 0) > 0
        let number = currentPageNumber ?? 1, count = ready ? document?.pageCount ?? 0 : 0
        previousMatchButton.isEnabled = !matches.isEmpty; nextMatchButton.isEnabled = !matches.isEmpty
        let zoom = Int((pdfView.scaleFactor * 100).rounded()), selected = pdfView.currentSelection?.pages.isEmpty == false
        let searchVisible = !searchRow.isHidden
        let continuous = pdfView.displayMode == .singlePageContinuous, thumbnailsVisible = !thumbnailPanel.isHidden
        let mode: String
        switch fitMode { case .page: mode = "page"; case .width: mode = "width"; case .actual: mode = "actual"; case .custom: mode = "custom" }
        let searchFrame = visibleChromeFrame(header), thumbnailFrame = visibleChromeFrame(thumbnailPanel)
        let snapshot = ControlSnapshot(controllerID: controller.map { ObjectIdentifier($0) }, generation: documentGeneration,
            page: number, pageCount: count, zoom: zoom, ready: ready, selected: ready && selected, canEdit: canEditAnnotations,
            searchVisible: searchVisible, continuous: continuous, direction: readingDirection, thumbnailsVisible: thumbnailsVisible, fitMode: mode,
            searchFrame: searchFrame, thumbnailFrame: thumbnailFrame, paperBook: paperBookMode)
        if let previous = pendingControlSnapshot ?? lastControlSnapshot, previous == snapshot { return }
        pendingControlSnapshot = snapshot
        guard !controlPublishScheduled else { return }
        controlPublishScheduled = true
        DispatchQueue.main.async { [weak self] in self?.publishControls() }
    }
    private func publishControls() {
        controlPublishScheduled = false
        guard let snapshot = pendingControlSnapshot else { return }
        pendingControlSnapshot = nil
        guard snapshot.generation == documentGeneration,
              snapshot.controllerID == controller.map({ ObjectIdentifier($0) }) else { refreshControls(); return }
        guard snapshot != lastControlSnapshot else { return }
        lastControlSnapshot = snapshot
        controller?.update(id: bindingID, page: snapshot.page, pageCount: snapshot.pageCount, zoomPercent: snapshot.zoom,
            isReady: snapshot.ready, hasSelection: snapshot.selected, canEditAnnotations: snapshot.canEdit,
            isSearchVisible: snapshot.searchVisible, isContinuous: snapshot.continuous, direction: snapshot.direction,
            thumbnailsVisible: snapshot.thumbnailsVisible, fitMode: snapshot.fitMode,
            chromeFrame: snapshot.searchFrame, thumbnailFrame: snapshot.thumbnailFrame, paperBookMode: snapshot.paperBook)
    }
    private func visibleChromeFrame(_ view: NSView) -> CGRect {
        guard overlay.isHidden, !view.isHidden, view.bounds.width > 0, view.bounds.height > 0 else { return .zero }
        let frame = view.convert(view.bounds, to: self)
        return CGRect(x: frame.minX, y: isFlipped ? frame.minY : bounds.height - frame.maxY,
                      width: frame.width, height: frame.height)
    }

    @objc private func findText() {
        guard !interactionBlocked, !searchRow.isHidden, let document, !document.isLocked else { return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { clearSearchState(); return }
        guard query.count <= 500 else { setStatus("搜索词最多为 500 字。"); return }
        clearSearchState()
        allowsSearchAutoNavigation = true
        searching = true; resultLabel.stringValue = "查找中…"; setStatus("")
        startSearch(query, generation: searchGeneration, attempts: 0, additionalTerms: keywordCache[query] ?? [])
        prepareKeywordAssistance(query)
    }

    private func startSearch(_ query: String, generation: Int, attempts: Int, additionalTerms: [String]) {
        guard generation == searchGeneration, let document, !document.isLocked else { return }
        if document.isFinding {
            guard attempts < 40 else { searching = false; setStatus("上一次搜索仍在结束，请稍后重新查找。"); updateSearchDisplay(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.startSearch(query, generation: generation, attempts: attempts + 1, additionalTerms: additionalTerms) }
            return
        }
        let delegate = PDFReaderSearchDelegate(owner: self, generation: generation)
        searchDelegate = delegate; document.delegate = delegate
        var identities = Set<String>()
        let terms = ([query] + additionalTerms).flatMap { NativePDFSearchQuery.terms(for: $0) }.filter { identities.insert($0.lowercased()).inserted }
        guard !terms.isEmpty else { searching = false; updateSearchDisplay(); return }
        if terms.count == 1 { document.beginFindString(terms[0], withOptions: [.caseInsensitive, .diacriticInsensitive]) }
        else { document.beginFindStrings(terms, withOptions: [.caseInsensitive, .diacriticInsensitive]) }
    }

    private func resetKeywordAssistance(clearCache: Bool = false) {
        keywordEpoch = UUID(); keywordTask?.cancel(); keywordTask = nil; keywordQuery = ""; keywordSpinner.stopAnimation(nil)
        if clearCache { keywordCache = [:] }
    }
    private func prepareKeywordAssistance(_ query: String) {
        guard let operation = onSearchKeywords, (2...400).contains(query.count), keywordCache[query] == nil, keywordTask == nil else { return }
        keywordQuery = query; keywordEpoch = UUID()
        let epoch = keywordEpoch, documentOwner = documentGeneration, configuration = searchAIIdentity
        keywordTask = Task { @MainActor [weak self] in
            defer { if let self, self.keywordEpoch == epoch { self.keywordTask = nil; self.keywordSpinner.stopAnimation(nil) } }
            do {
                try await Task.sleep(for: .milliseconds(650))
                guard let self, !Task.isCancelled, self.keywordEpoch == epoch, self.documentGeneration == documentOwner,
                      !self.searchRow.isHidden, self.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query,
                      (self.searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
                self.keywordSpinner.startAnimation(nil)
                let words = try await operation(query)
                try Task.checkCancellation()
                guard self.keywordEpoch == epoch, self.documentGeneration == documentOwner, self.searchAIIdentity == configuration,
                      !self.searchRow.isHidden, self.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                let plan = try LibrarySearchExpansionPlan(keywords: words)
                if self.keywordCache.count >= 16 { self.keywordCache.removeAll(keepingCapacity: true) }
                self.keywordCache[query] = plan.keywords; self.keywordTask = nil; self.keywordSpinner.stopAnimation(nil)
                let original = Set(NativePDFSearchQuery.terms(for: query).map { $0.lowercased() })
                let expanded = Set(plan.keywords.flatMap { NativePDFSearchQuery.terms(for: $0) }.map { $0.lowercased() })
                if !expanded.isSubset(of: original) { self.findText(); self.allowsSearchAutoNavigation = false }
            } catch {
                guard let self, self.keywordEpoch == epoch else { return }
                self.keywordTask = nil; self.keywordSpinner.stopAnimation(nil)
                if !Task.isCancelled { self.searchField.toolTip = "本地结果仍可查看。AI扩词暂未完成：" + error.localizedDescription }
            }
        }
    }
    private func clearSearchState() {
        if searchRow.isHidden || searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != keywordQuery { resetKeywordAssistance() }
        automaticSearchTask?.cancel(); automaticSearchTask = nil
        searchGeneration += 1
        for task in searchSnippetTasks.values { task.cancel() }; searchSnippetTasks = [:]
        for task in searchTextTasks.values { task.task.cancel() }; searchTextTasks = [:]
        searchTextIndexes = [:]; searchTextOrder = []; searchTextBytes = 0
        searchMatchKeys = []
        searchResults.reset(); searchResults.isHidden = true; searchResultsHeight?.constant = 0
        document?.delegate = nil; document?.cancelFindString(); searchDelegate = nil
        matches = []; matchIndex = -1; searching = false; searchLimited = false
        highlightUpdateScheduled = false; allowsSearchAutoNavigation = false
        updateSelectionHighlights(); pdfView.clearSelection()
        resultLabel.stringValue = ""; refreshControls()
    }

    func acceptMatch(_ selection: PDFSelection, generation: Int) {
        guard generation == searchGeneration, searching,
              selection.pages.contains(where: { $0.document === document }) else { return }
        // Equivalent query spellings can report the same native range. Keep
        // every distinct original location, including repeated words on a page.
        var identity: [Int] = []
        for page in selection.pages {
            guard page.document === document, let document else { return }
            let count = selection.numberOfTextRanges(on: page)
            guard count > 0 else { identity = []; break }
            identity.append(document.index(for: page)); identity.append(count)
            for index in 0..<count {
                let range = selection.range(at: index, on: page)
                identity.append(range.location); identity.append(range.length)
            }
        }
        if !identity.isEmpty, !searchMatchKeys.insert(identity).inserted { return }
        guard matches.count < matchLimit else {
            searchLimited = true; searching = false; document?.cancelFindString()
            setStatus("结果超过 5000 处，已停止搜索；请缩小关键词。")
            updateHighlights(); return
        }
        selection.color = NSColor.systemYellow.withAlphaComponent(0.45)
        matches.append(selection)
        if matchIndex < 0 { matchIndex = 0; if allowsSearchAutoNavigation { showMatch() } }
        guard !highlightUpdateScheduled else { return }
        highlightUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.searchGeneration == generation else { return }
            self.highlightUpdateScheduled = false; self.updateHighlights()
        }
    }

    func finishSearch(generation: Int) {
        guard generation == searchGeneration else { return }
        searching = false; updateHighlights()
        if matches.isEmpty { setStatus("没有找到匹配文字。扫描页没有文字层时，原生搜索无法查到图中的字。") }
    }

    private func updateSelectionHighlights() {
        if let quoteFocusHighlight { pdfView.highlightedSelections = matches + [quoteFocusHighlight] }
        else { pdfView.highlightedSelections = matches.isEmpty ? nil : matches }
    }
    private func clearQuoteFocusHighlight() {
        guard quoteFocusHighlight != nil else { return }
        quoteFocusHighlight = nil; updateSelectionHighlights()
    }
    private func updateHighlights() { updateSelectionHighlights(); updateSearchDisplay(); synchronizeSearchResults(); refreshControls() }
    private func synchronizeSearchResults() {
        guard !searchRow.isHidden, let document else { return }
        let start = searchResults.entries.count
        if matches.count > start {
            let additions = (start..<matches.count).map { index -> PDFSearchResultEntry in
                let selection = matches[index], page = selection.pages.first(where: { $0.document === document })
                let number = page.map { document.index(for: $0) + 1 } ?? 1
                let range = page.flatMap { selection.numberOfTextRanges(on: $0) > 0 ? selection.range(at: 0, on: $0) : nil } ?? NSRange(location: NSNotFound, length: 0)
                return PDFSearchResultEntry(index: index, page: number, range: range, match: selection.string ?? searchField.stringValue)
            }
            searchResults.append(additions, selected: matchIndex)
        }
        searchResults.isHidden = searchResults.entries.isEmpty
        updateSearchResultsHeight()
        needsLayout = true
    }
    private func updateSearchResultsHeight() {
        guard let height = searchResultsHeight else { return }
        // On shorter windows, leave a usable thumbnail viewport if both
        // navigation surfaces are open; show whole result rows only.
        let available = max(34, bounds.height - (thumbnailPanel.isHidden ? 174 : 440))
        let rows = searchRow.isHidden ? 0 : min(searchResults.entries.count, min(10, max(1, Int(available / PDFSearchResultsList.rowHeight))))
        let value = CGFloat(rows) * PDFSearchResultsList.rowHeight
        if abs(height.constant - value) > 0.5 { height.constant = value; needsLayout = true }
        let searchHeight: CGFloat = searchRow.isHidden ? 0 : 44
        let rowsHeight: CGFloat = rows > 0 ? value + 6 : 0
        let statusHeight: CGFloat = statusLabel.isHidden ? 0 : ceil(statusLabel.intrinsicContentSize.height) + (searchHeight + rowsHeight > 0 ? 6 : 0)
        let panelHeight = 20 + searchHeight + rowsHeight + statusHeight
        if let panel = searchPanelHeight, abs(panel.constant - panelHeight) > 0.5 { panel.constant = panelHeight; needsLayout = true }
    }
    private func prepareSearchSnippet(_ index: Int) {
        guard !searchRow.isHidden, searchResults.entries.indices.contains(index), searchSnippetTasks[index] == nil,
              let session = nativePreparationSession() else { return }
        let entry = searchResults.entries[index], generation = searchGeneration, documentID = documentGeneration
        if let cached = searchTextIndexes[entry.page] {
            searchResults.setSnippet(cached.snippet(range: entry.range, expectedMatch: entry.match), at: index); return
        }
        let worker = nativePreparation
        let loading: (id: UUID, task: Task<NativePDFSearchTextIndex, Error>)
        if let existing = searchTextTasks[entry.page] { loading = existing }
        else {
            loading = (UUID(), Task { try await worker.prepareSearchText(session: session, page: entry.page) })
            searchTextTasks[entry.page] = loading
        }
        searchSnippetTasks[index] = Task { [weak self] in
            guard let self else { return }
            defer { if self.searchGeneration == generation { self.searchSnippetTasks.removeValue(forKey: index) } }
            do {
                let text = try await loading.task.value
                guard !Task.isCancelled, self.searchGeneration == generation, self.documentGeneration == documentID,
                      !self.searchRow.isHidden, self.searchResults.entries.indices.contains(index) else { return }
                if self.searchTextTasks[entry.page]?.id == loading.id { self.searchTextTasks.removeValue(forKey: entry.page) }
                if self.searchTextIndexes[entry.page] == nil, text.byteCount <= 8_000_000 {
                    self.searchTextIndexes[entry.page] = text; self.searchTextOrder.append(entry.page); self.searchTextBytes += text.byteCount
                    while self.searchTextOrder.count > 8 || self.searchTextBytes > 8_000_000 {
                        let old = self.searchTextOrder.removeFirst(); self.searchTextBytes -= self.searchTextIndexes.removeValue(forKey: old)?.byteCount ?? 0
                    }
                }
                self.searchResults.setSnippet(text.snippet(range: entry.range, expectedMatch: entry.match), at: index)
            } catch {
                if self.searchGeneration == generation, !Task.isCancelled {
                    if self.searchTextTasks[entry.page]?.id == loading.id { self.searchTextTasks.removeValue(forKey: entry.page) }
                    self.searchResults.setSnippet(.unlocated(entry.match), at: index)
                }
            }
        }
    }
    private func updateSearchDisplay() {
        if matches.isEmpty { resultLabel.stringValue = searching ? "查找中…" : "无结果" }
        else { resultLabel.stringValue = "\(matchIndex + 1)/\(matches.count)\(searchLimited ? "+" : searching ? "…" : "")" }
    }
    @objc private func previousMatch() { moveMatch(-1) }
    @objc private func nextMatch() { moveMatch(1) }
    private func moveMatch(_ direction: Int) {
        guard !matches.isEmpty else { return }
        allowsSearchAutoNavigation = true
        matchIndex = (matchIndex + direction + matches.count) % matches.count; showMatch()
    }
    private func showMatch() {
        guard matches.indices.contains(matchIndex) else { return }
        invalidateNavigation()
        let selection = matches[matchIndex]
        pdfView.go(to: selection); pdfView.setCurrentSelection(selection, animate: true)
        pdfView.scrollSelectionToVisible(nil); updateSearchDisplay()
        searchResults.showSelection(matchIndex)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === searchField else { return }
        clearSearchState(); setStatus("")
        // Wait for committed input: a Chinese IME's unfinished syllables must
        // neither search nor move the page. Return still starts immediately.
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true,
              !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let query = field.stringValue, generation = searchGeneration
        automaticSearchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, let self, self.searchGeneration == generation,
                  !self.searchRow.isHidden, self.searchField.stringValue == query,
                  (self.searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            self.findText()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !interactionBlocked, control === searchField, commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        closeSearch(); return true
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text; statusLabel.toolTip = text; statusLabel.isHidden = text.isEmpty
        header.isHidden = searchRow.isHidden && statusLabel.isHidden; updateSearchResultsHeight()
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 8
        return stack
    }
    private func flexibleSpace() -> NSView { let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view }
    private func symbolButton(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage()
        let button = ReadingNativeHoverButton(image: image, target: self, action: action)
        button.bezelStyle = .circular; button.controlSize = .regular; button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = title; button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func shutdown() {
        resetKeywordAssistance(clearCache: true)
        noteMarginAnimation?.invalidate(); noteMarginAnimation = nil
        pageCurl?.cancel(); pageCurl = nil
        pendingControlSnapshot = nil; lastControlSnapshot = nil
        memoryCaptureTask?.cancel(); captureWorkspaceMemory(deferDelivery: true); memoryCallback = nil; observedClip = nil
        invalidateNavigation(); installingDocument = true
        removeSearchEscapeMonitor()
        removePageScrollMonitor(); removeSourcePointerMonitor(); resetPageGesture()
        clearSearchState()
        NotificationCenter.default.removeObserver(self)
        notePageGutters.restore()
        thumbnails.pdfView = nil; pdfView.document = nil; document = nil; callback = nil
        controller?.unbind(id: bindingID); controller = nil
        // An external scene/state change can dismantle this reader even while its
        // window is modal. Keep the draft sheet alive until explicit save/cancel.
        if !editingAnnotationSheet { closeAnnotationPanel() }
        sessionPassword = nil; onUnlock = nil; onSaveAnnotations = nil; onTrashAnnotation = nil
        clearSourceDecorations(); resetQuoteCache(); onSourceDecorationTap = nil; onSourceSelection = nil; onSourceDecorationHover = nil; onVisiblePagesChange = nil; pendingQuote = nil
        if securityScoped { loadedURL?.stopAccessingSecurityScopedResource() }; securityScoped = false
    }

    private func perform(_ command: PDFReaderCommand) {
        awaitingSourceFocusProof = false
        switch command {
        case .prev: if pageCurl == nil { previousPage() }
        case .next: if pageCurl == nil { nextPage() }
        case .jump(let page):
            guard let document, (1...document.pageCount).contains(page) else { setStatus("页码超出原PDF范围。"); return }
            navigate(to: page); window?.makeFirstResponder(pdfView)
        case .zoomIn: zoomIn()
        case .zoomOut: zoomOut()
        case .fitPage: fitMode = .page; applyFit()
        case .fitWidth: fitMode = .width; applyFit()
        case .actualSize: fitMode = .actual; applyFit()
        case .showSearch: showSearch()
        case .hideSearch: closeSearch()
        case .toggleSearch: toggleSearch()
        case .toggleThumbnails: toggleThumbnails()
        case .setThumbnails(let visible): setThumbnailsVisible(visible)
        case .toggleContinuous: setPaperBookMode(false); changePDFDisplayMode(pdfView.displayMode == .singlePageContinuous ? .singlePage : .singlePageContinuous)
        case .setContinuous(let continuous): setPaperBookMode(false); changePDFDisplayMode(continuous ? .singlePageContinuous : .singlePage)
        case .setDirection(let direction): setPaperBookMode(false); changePDFDirection(direction)
        case .setPaperBook(let enabled): setPaperBookMode(enabled)
        case .createHighlight: createHighlight()
        case .createRegion:
            guard canEditAnnotations else { setStatus("当前任务运行中，请稍后添加区域批注。"); return }
            guard document != nil, document?.isLocked == false else { return }
            pdfView.armRegionSelection(); window?.makeFirstResponder(pdfView)
            setStatus("拖动框选同一页内的区域，松开后填写批注；按Esc取消。")
        case .placeNote:
            guard canEditAnnotations, document != nil, document?.isLocked == false else { return }
            pdfView.armNotePlacement(); window?.makeFirstResponder(pdfView)
            setStatus("点击原书中要贴便签的位置；按Esc取消。")
        case .scrollNoteArea(let event):
            guard noteMarginWidth > 0, !interactionBlocked, window?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            if !consumePageScroll(event, fromNoteMargin: true) {
                (observedClip?.enclosingScrollView ?? pdfScrollView(in: pdfView))?.scrollWheel(with: event)
            }
        case .showAnnotations: showAnnotations()
        case .focusQuote(let page, let quote): focusQuote(on: page, quote: quote)
        }
        scheduleWorkspaceCapture()
    }

    @objc private func selectionChanged(_ notification: Notification) {
        refreshControls()
        if pdfView.currentSelection?.pages.isEmpty == false { awaitingSourceFocusProof = false; cancelSourceQuotePreparation(); clearQuoteFocusHighlight() }
        else { scheduleSourceHoverRefresh() }
        sourceSelectionObservation &+= 1
        let observation = sourceSelectionObservation, generation = documentGeneration
        let deliver: (SourceReadingSelection?) -> Void = { [weak self] selection in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sourceSelectionObservation == observation, self.documentGeneration == generation else { return }
                self.onSourceSelection?(selection)
            }
        }
        guard let document, let selected = pdfView.currentSelection, let text = selected.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 131_072 else {
            deliver(nil); return
        }
        // A PDF native range is page-local, whereas SourceAnchor offsets are
        // unit-local. Return the quote and page; the store validates its own unit.
        let pages = selected.pages
        let index = pages.first.map { document.index(for: $0) }
        let pageNumber = index.flatMap { $0 == NSNotFound ? nil : $0 + 1 }
        let lastIndex = pages.last.map { document.index(for: $0) }
        let endPage = lastIndex.flatMap { $0 == NSNotFound ? nil : $0 + 1 }
        deliver(SourceReadingSelection(text: text, isExact: false, page: pageNumber, endPage: endPage))
    }

    private func resetQuoteCache() {
        quoteCachePage = nil
        quoteRangeCache.removeAll(keepingCapacity: true); quoteCacheBytes = 0
    }

    nonisolated private static func findNativeQuoteRange(_ quote: String, prefix: String?, suffix: String?, text: NSString) -> NSRange? {
        NativeQuoteRangeMatcher.range(of: quote, prefix: prefix, suffix: suffix, in: text)
    }

    private func focusQuote(on number: Int, quote: String, prefix: String? = nil, suffix: String? = nil,
                            decoration: SourceReadingDecoration? = nil) {
        guard let document, !document.isLocked, (1...document.pageCount).contains(number) else { return }
        navigate(to: number)
        // Set after navigate(), which invalidates every older navigation target.
        pendingQuote = (number, quote, prefix, suffix, decoration)
    }

    private func focusSourceDecorationIfReady() {
        guard let id = sourceDecorationFocusID,
              document?.isLocked == false,
              let decoration = sourceDecorations.first(where: { $0.id == id }),
              let page = decoration.page ?? sourceDecorationPage else { return }
        let identity = sourcePageTexts[page]?.identity
        // A repeated quote may fail unique matching before the page snapshot
        // arrives. Retry once for that new proof, without restarting navigation
        // on every publication or repeatedly retrying a proven mismatch.
        guard appliedSourceDecorationFocusID != id ||
                (awaitingSourceFocusProof && identity != nil && appliedSourceDecorationProofIdentity != identity) else { return }
        // The target page snapshot may arrive after the navigation request.
        // Keep that one request pending instead of consuming its ID too soon.
        focusQuote(on: page, quote: decoration.quote, prefix: decoration.prefix, suffix: decoration.suffix, decoration: decoration)
        appliedSourceDecorationFocusID = id; appliedSourceDecorationProofIdentity = identity
        awaitingSourceFocusProof = identity == nil
    }

    private func applyQuoteFocus(on number: Int, quote: String, prefix: String? = nil, suffix: String? = nil,
                                 decoration: SourceReadingDecoration? = nil) {
        if let decoration, sourceDecorationValuesByID[decoration.id] != decoration { return }
        guard !quote.isEmpty, quote.utf16.count <= 32_768,
              (prefix?.utf8.count ?? 0) <= 4_096, (suffix?.utf8.count ?? 0) <= 4_096,
              let page = document?.page(at: number - 1), let session = nativePreparationSession() else { return }
        cancelSourceQuotePreparation()
        if quoteCachePage !== page { resetQuoteCache(); quoteCachePage = page }
        let key = QuoteCacheKey(quote: Data(quote.utf8), prefix: prefix.map { Data($0.utf8) }, suffix: suffix.map { Data($0.utf8) })
        let savedUnique = quoteRangeCache[key], source = sourcePageTexts[number]
        let cached = sourceGeometryPages[number]
        let savedIdentity = cached?.sourceTextProofIdentity, savedProof = cached?.sourceTextProof
        let documentID = documentGeneration, navigation = navigationRequestID
        let generation = sourceDecorationGeneration, run = UUID()
        sourceQuoteRun = run
        sourceQuoteTarget = decoration
        onPreparationChanged?(.started(run, .init(phase: .pageText, page: number)))
        let progress = preparationProgress(run: run, generation: generation, documentID: documentID)
        sourceQuoteTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.sourceQuoteRun == run {
                    self.onPreparationChanged?(.finished(run)); self.sourceQuoteRun = nil; self.sourceQuoteTask = nil; self.sourceQuoteTarget = nil
                }
            }
            do {
                let cache: SourceGeometryPage
                if let cached { cache = cached }
                else {
                    let prepared = try await self.nativePreparation.preparePage(session: session, page: number, onProgress: progress)
                    guard !Task.isCancelled, self.documentGeneration == documentID, self.navigationRequestID == navigation,
                          self.sourceQuoteRun == run, page.readingSourceBounds(for: .cropBox) == prepared.crop,
                          page.rotation == prepared.rotation,
                          decoration.map({ self.sourceDecorationValuesByID[$0.id] == $0 }) ?? true else { return }
                    let layout = SourceGeometryPage.LineLayout(crop: prepared.crop, rotation: prepared.rotation, characterCount: prepared.nativeCharacterCount)
                    cache = self.sourceGeometryPages[number].flatMap { $0.nativeLineLayout == layout ? $0 : nil } ?? SourceGeometryPage(prepared: prepared)
                    self.sourceGeometryPages[number] = cache
                    self.sourceGeometryPageOrder.removeAll { $0 == number }; self.sourceGeometryPageOrder.append(number)
                    self.trimSourceGeometryCache(keeping: Array(Set(self.renderedSourceWindow + [number])))
                }
                let text = cache.text
                progress(.init(phase: .matching, page: number, completed: 0, total: 1))
                let calculation = Task.detached(priority: .userInitiated) { () -> (NSRange?, NativePageTextProof?, Bool) in
                    let proof = source.flatMap { value in
                        savedIdentity == value.identity ? savedProof : NativePageTextProof.prove(page: number, nativeText: text, source: value)
                    }
                    if let decoration, (decoration.page ?? number) == number,
                       let exact = proof?.range(of: decoration.quote, location: decoration.rangeLocation, length: decoration.rangeLength) {
                        return (exact, proof, true)
                    }
                    let range: NSRange?
                    if let savedUnique { range = savedUnique.range }
                    else { range = Self.findNativeQuoteRange(quote, prefix: prefix, suffix: suffix, text: text as NSString) }
                    return (range, proof, false)
                }
                let (range, proof, exact) = await withTaskCancellationHandler(operation: { await calculation.value }, onCancel: { calculation.cancel() })
                guard !Task.isCancelled, self.documentGeneration == documentID, self.navigationRequestID == navigation,
                      self.sourceQuoteRun == run,
                      decoration.map({ self.sourceDecorationValuesByID[$0.id] == $0 }) ?? true else { return }
                guard !exact || source?.identity == self.sourcePageTexts[number]?.identity else {
                    // Publication can briefly withhold the current page proof.
                    // Keep rejecting the stale result, but let the next actual
                    // metadata publication retry this still-current intent.
                    if let decoration, self.sourceDecorationFocusID == decoration.id {
                        self.awaitingSourceFocusProof = true
                        self.appliedSourceDecorationProofIdentity = nil
                    }
                    return
                }
                if let source, self.sourcePageTexts[number]?.identity == source.identity, (proof?.byteCount ?? 0) <= 2_097_152 {
                    cache.sourceTextProofIdentity = source.identity; cache.sourceTextProof = proof
                }
                // Only a generic unique match enters the quote/context cache.
                // Exact offsets may intentionally disambiguate repeated quotes.
                if !exact, savedUnique == nil, key.byteCount <= 1_048_576 {
                    if self.quoteRangeCache.count >= 256 || self.quoteCacheBytes + key.byteCount > 1_048_576 {
                        self.quoteRangeCache.removeAll(keepingCapacity: true); self.quoteCacheBytes = 0
                    }
                    self.quoteRangeCache[key] = CachedQuoteRange(range: range); self.quoteCacheBytes += key.byteCount
                }
                guard let range, range.location >= 0, range.location != NSNotFound, range.length > 0,
                      let count = cache.nativeLineLayout?.characterCount,
                      range.location <= count, range.length <= count - range.location,
                      let selection = page.selection(for: range) else {
                    self.setStatus("已定位到原页；原生文字无法唯一匹配此引文，未推测词位。扫描页请对照原页与识别稿。"); return
                }
                selection.color = NSColor.systemTeal.withAlphaComponent(0.3)
                self.pdfView.clearSelection()
                self.quoteFocusHighlight = selection; self.updateSelectionHighlights()
                self.pdfView.go(to: selection); self.refreshControls()
            } catch is CancellationError { return }
            catch {
                guard self.documentGeneration == documentID, self.navigationRequestID == navigation,
                      self.sourceQuoteRun == run else { return }
                self.setStatus("已定位到原页，阅读提示暂未准备好。")
            }
        }
    }
    private func cancelSourceQuotePreparation() {
        sourceQuoteTask?.cancel(); sourceQuoteTask = nil
        if let run = sourceQuoteRun { onPreparationChanged?(.finished(run)) }; sourceQuoteRun = nil
        sourceQuoteTarget = nil
    }

    private func clearSourceDecorations() {
        invalidateSourcePress()
        cancelSourceQuotePreparation()
        sourceDecorationGeneration &+= 1; cancelSourcePreparation()
        sourceGeometries = [:]; sourceGeometryIDsByPage = [:]; sourceGeometryPages = [:]; sourceGeometryPageOrder = []
        renderedSourceInputGeneration = -1; renderedSourceWindow = []; lastVisiblePages = []
        sourcePreparationNeedsRetry = false
        hoveredSourceID = nil; sourcePress = nil; publishSourceHover(nil); sourceCanvas.needsDisplay = true
    }
    @objc private func visiblePagesChanged(_ notification: Notification) { scheduleVisiblePages() }
    private func scheduleVisiblePages() {
        guard !visiblePagePublishScheduled else { return }
        visiblePagePublishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.visiblePagePublishScheduled = false
            guard let document = self.document, !document.isLocked else { return }
            let pages = Array(Set(self.pdfView.visiblePages.compactMap { page -> Int? in
                let index = document.index(for: page); return index == NSNotFound ? nil : index + 1
            })).sorted()
            self.sourceCanvas.needsDisplay = true
            self.publishNoteAnchorPoints()
            if pages != self.lastVisiblePages {
                self.invalidateSourcePress()
                self.lastVisiblePages = pages; self.onVisiblePagesChange?(pages); self.renderSourceDecorations()
                // Visibility can change while the prepared page window stays
                // identical. renderSourceDecorations then has no worker to
                // rearm the tail that invalidateSourcePress just cancelled.
                self.scheduleSourceHoverRefresh()
            }
        }
    }
    private func createPositionNote(page: PDFPage, point: CGPoint) {
        guard !interactionBlocked, canEditAnnotations, let document else { return }
        let index = document.index(for: page), crop = page.readingSourceBounds(for: .cropBox)
        guard index != NSNotFound, crop.width > 0, crop.height > 0, crop.contains(point) else { return }
        setStatus("")
        if noteBindingDocumentID != nil { noteBindingPreview = (page, point); scheduleVisiblePages() }
        onCreatePositionNote?(index + 1, Double((point.x - crop.minX) / crop.width), Double((point.y - crop.minY) / crop.height))
    }
    private func publishNoteAnchorPoints(allowDuringTurn: Bool = false) {
        if pageCurl != nil && !allowDuringTurn { return }
        guard let document else { controller?.reportNotePositions(id: bindingID, points: [:], owner: notePlacementOwner, marginWidth: noteMarginWidth); return }
        var points: [String: CGPoint] = [:], connectors: [String: PDFNoteConnector] = [:]
        var surfaces: [PDFNotePageSurface] = []
        func topLeft(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y) }
        func append(_ id: String, page: PDFPage, original: CGPoint) {
            let crop = page.readingSourceBounds(for: .cropBox)
            guard crop.contains(original) else { return }
            let local = convert(pdfView.convert(original, from: page), from: pdfView)
            points[id] = topLeft(local)
            let glyphIndex = page.characterIndex(at: original)
            var start = points[id]!
            if glyphIndex >= 0, glyphIndex < page.numberOfCharacters {
                let glyph = page.characterBounds(at: glyphIndex)
                if !glyph.isEmpty, !glyph.isNull, glyph.insetBy(dx: -4, dy: -4).contains(original) {
                    let line = page.selectionForLine(at: original)?.bounds(for: page) ?? glyph
                    let screenGlyph = convert(pdfView.convert(glyph, from: page), from: pdfView)
                    let screenLine = convert(pdfView.convert(line, from: page), from: pdfView)
                    let top = topLeft(CGPoint(x: screenGlyph.midX, y: screenLine.maxY))
                    let bottom = topLeft(CGPoint(x: screenGlyph.midX, y: screenLine.minY))
                    start = CGPoint(x: screenGlyph.midX, y: max(top.y, bottom.y) + 2)
                }
            }
            let screenPage = convert(pdfView.convert(crop, from: page), from: pdfView)
            let scale = max(0.001, noteMarginFrame(for: page).width / PositionNoteSurface.marginWidth)
            connectors[id] = .init(start: start, pageExit: CGPoint(x: screenPage.maxX + 8 * scale, y: start.y))
        }
        for page in pdfView.visiblePages {
            let index = document.index(for: page)
            guard index != NSNotFound else { continue }
            let margin = noteMarginFrame(for: page)
            if margin.width > 0, margin.height > 0 {
                var ids = Set((notePlacementsByPage[index + 1] ?? []).filter { $0.1.sourceHash == sourceHash }.map { $0.0 })
                if let id = noteBindingDocumentID, noteBindingPreview?.0 === page { ids.insert(id) }
                surfaces.append(.init(id: index + 1,
                    frame: CGRect(x: margin.minX, y: bounds.maxY - margin.maxY, width: margin.width, height: margin.height),
                    scale: max(0.001, margin.width / PositionNoteSurface.marginWidth), noteIDs: ids))
            }
            for (id, placement) in notePlacementsByPage[index + 1] ?? [] where placement.sourceHash == sourceHash {
                if id == noteBindingDocumentID, noteBindingPreview != nil { continue }
                let crop = page.readingSourceBounds(for: .cropBox)
                append(id, page: page, original: CGPoint(x: crop.minX + crop.width * placement.x, y: crop.minY + crop.height * placement.y))
            }
        }
        if let id = noteBindingDocumentID, let (page, point) = noteBindingPreview, document.index(for: page) != NSNotFound {
            append(id, page: page, original: point)
        }
        let width = (observedClip?.enclosingScrollView ?? pdfScrollView(in: pdfView))?.verticalScroller?.bounds.width ?? 17
        let margin = noteMarginFrame
        let topLeftFrame = CGRect(x: margin.minX, y: bounds.maxY - margin.maxY, width: margin.width, height: margin.height)
        controller?.reportNotePositions(id: bindingID, points: points, owner: notePlacementOwner, connectors: connectors, scrollerWidth: max(12, width), marginWidth: scaledNoteMarginWidth, marginFrame: topLeftFrame, marginScale: max(0.001, scaledNoteMarginWidth / PositionNoteSurface.marginWidth), surfaces: surfaces)
    }
    private func nativePreparationSession() -> NativePDFPreparationWorker.Session? {
        guard let loadedURL, !sourceHash.isEmpty else { return nil }
        return .init(url: loadedURL, sourceHash: sourceHash, generation: documentGeneration, password: sessionPassword)
    }
    private func preparationProgress(run: UUID, generation: Int, documentID: Int) -> @Sendable (ReadingPreparationProgress) -> Void {
        { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.documentGeneration == documentID else { return }
                let sourceRun = self.sourceDecorationGeneration == generation && (self.sourcePreparationRun == run || self.sourceGeometryRun == run)
                guard sourceRun || self.sourceQuoteRun == run else { return }
                self.onPreparationChanged?(.advanced(run, value))
            }
        }
    }
    private func cancelSourcePreparation() {
        sourceDecorationTask?.cancel(); sourceDecorationTask = nil
        sourceGeometryTask?.cancel(); sourceGeometryTask = nil; pendingSourceGeometry = [:]
        inFlightSourceGeometryIDs = []
        if let run = sourcePreparationRun { onPreparationChanged?(.finished(run)) }; sourcePreparationRun = nil
        if let run = sourceGeometryRun { onPreparationChanged?(.finished(run)) }; sourceGeometryRun = nil
    }
    private func renderSourceDecorations() {
        guard let document, !document.isLocked else { clearSourceDecorations(); return }
        let current = currentPageNumber ?? sourceDecorationPage ?? 1
        let window = ReadingSentenceAnchors.pageWindow(current: current, visible: lastVisiblePages, available: sourceAvailablePages)
        let inputChanged = renderedSourceInputGeneration != sourceInputGeneration
        let windowChanged = renderedSourceWindow != window
        if !inputChanged, !windowChanged, sourceDecorationTask != nil { return }
        let needsProofRetry = !inputChanged && !windowChanged && window.contains { number in
            guard number > 0, number <= document.pageCount, let cache = sourceGeometryPages[number], let identity = sourcePageTexts[number]?.identity else { return false }
            return cache.unresolvedIDs.contains { cache.needsProofRetry($0, identity: identity, currentValues: sourceDecorationValuesByID) }
        }
        guard inputChanged || windowChanged || needsProofRetry || sourcePreparationNeedsRetry else { return }
        sourcePreparationNeedsRetry = false
        sourceDecorationGeneration &+= 1; cancelSourcePreparation()
        if inputChanged {
            for (number, validIDs) in validSourceDecorationIDsByPage { sourceGeometryPages[number]?.retain(validIDs: validIDs) }
        }
        renderedSourceInputGeneration = sourceInputGeneration; renderedSourceWindow = window
        let generation = sourceDecorationGeneration, documentID = documentGeneration
        let desiredIDs = Set(window.flatMap { (groupedSourceDecorations[$0] ?? []).map(\.id) })
        sourceGeometries = sourceGeometries.filter { desiredIDs.contains($0.key) && $0.value.value == sourceDecorationValuesByID[$0.key] }
        if let hoveredSourceID, !desiredIDs.contains(hoveredSourceID) {
            self.hoveredSourceID = nil; sourcePress = nil; publishSourceHover(nil)
        }
        let grouped = groupedSourceDecorations
        sourceGeometryIDsByPage = grouped.mapValues { $0.map(\.id) }
        guard !window.isEmpty, let session = nativePreparationSession() else { return }
        let visible = Set(lastVisiblePages).union([current])
        let priorityWindows = [window.filter { visible.contains($0) }, window.filter { !visible.contains($0) }]
        let run = UUID(); sourcePreparationRun = run
        onPreparationChanged?(.started(run, .init(phase: .pageText, page: priorityWindows.first?.first)))
        let progress = preparationProgress(run: run, generation: generation, documentID: documentID)
        sourceDecorationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.sourcePreparationRun == run { self.onPreparationChanged?(.finished(run)); self.sourcePreparationRun = nil }
                if self.sourceDecorationGeneration == generation { self.sourceDecorationTask = nil }
            }
            do {
                // All actual visible pages become interactive before idle-only
                // neighboring pages consume native parsing or term geometry.
                for (priority, pages) in priorityWindows.enumerated() where !pages.isEmpty {
                    if priority > 0 { try await Task.sleep(nanoseconds: 100_000_000) }
                    for passages in [true, false] {
                        for number in pages {
                            try await self.waitForSourceScrollIdle(extraDelay: priority > 0 ? 0.35 : 0)
                            guard !Task.isCancelled, self.documentGeneration == documentID, self.sourceDecorationGeneration == generation,
                                  let page = document.page(at: number - 1) else { return }
                            let cache: SourceGeometryPage
                            if let saved = self.sourceGeometryPages[number], let layout = saved.nativeLineLayout,
                               layout.crop == page.readingSourceBounds(for: .cropBox), layout.rotation == page.rotation { cache = saved }
                            else {
                                let prepared: NativePDFPreparationWorker.PreparedPage
                                do { prepared = try await self.nativePreparation.preparePage(session: session, page: number, onProgress: progress) }
                                catch NativePDFPreparationWorker.Failure.pageTextTooLarge { continue }
                                guard !Task.isCancelled, self.documentGeneration == documentID, self.sourceDecorationGeneration == generation,
                                      page.readingSourceBounds(for: .cropBox) == prepared.crop, page.rotation == prepared.rotation else { return }
                                let layout = SourceGeometryPage.LineLayout(crop: prepared.crop, rotation: prepared.rotation, characterCount: prepared.nativeCharacterCount)
                                cache = self.sourceGeometryPages[number].flatMap { $0.nativeLineLayout == layout ? $0 : nil } ?? SourceGeometryPage(prepared: prepared)
                                self.sourceGeometryPages[number] = cache
                                self.scheduleSourceHoverRefresh()
                            }
                            self.sourceGeometryPageOrder.removeAll { $0 == number }; self.sourceGeometryPageOrder.append(number)
                            let pageText = self.sourcePageTexts[number]
                            var additions: [SourceReadingDecoration] = [], inspected = 0
                            for value in grouped[number] ?? [] {
                                guard !Task.isCancelled, self.documentGeneration == documentID, self.sourceDecorationGeneration == generation else { return }
                                guard (value.interaction == .passage) == passages else { continue }
                                if !passages { cache.removePassage(value.id) }
                                if let identity = pageText?.identity, cache.needsProofRetry(value.id, identity: identity, currentValues: self.sourceDecorationValuesByID) {
                                    additions.append(value)
                                } else if passages, cache.passageValues[value.id] == value {
                                    if let geometry = cache.geometry[value.id], geometry.value == value { self.sourceGeometries[value.id] = geometry }
                                } else if let geometry = cache.geometry[value.id], geometry.value == value { self.sourceGeometries[value.id] = geometry }
                                else { additions.append(value); self.sourceGeometries.removeValue(forKey: value.id) }
                                inspected += 1
                                if inspected.isMultiple(of: 512) {
                                    try await Task.sleep(nanoseconds: 1_000_000)
                                    try await self.waitForSourceScrollIdle(extraDelay: priority > 0 ? 0.35 : 0)
                                }
                            }
                            if additions.isEmpty {
                                if passages { cache.rebuildPassageIndexIfNeeded() }
                                self.trimSourceGeometryCache(keeping: window); self.scheduleSourceHoverRefresh(); continue
                            }
                            let text = cache.text
                            var phaseProofChecked = pageText != nil && cache.sourceTextProofIdentity == pageText?.identity
                            var phaseProof = phaseProofChecked ? cache.sourceTextProof : nil
                            progress(.init(phase: .matching, page: number, completed: 0, total: additions.count))
                            for batchStart in stride(from: 0, to: additions.count, by: 12_000) {
                                try await self.waitForSourceScrollIdle(extraDelay: priority > 0 ? 0.35 : 0)
                                let batchEnd = batchStart + min(12_000, additions.count - batchStart)
                                let matchingAdditions = Array(additions[batchStart..<batchEnd]), saved = cache.ranges
                                let checkedProof = phaseProofChecked, savedProof = phaseProof, total = additions.count
                                let calculation = Task.detached(priority: priority == 0 ? .userInitiated : .utility) { () -> PageQuoteMatches in
                                    let interval = pdfDecorationSignposter.beginInterval("MatchPageQuotes")
                                    defer { pdfDecorationSignposter.endInterval("MatchPageQuotes", interval) }
                                    var nativeSource: NSString?
                                    let proof = checkedProof ? savedProof : pageText.flatMap { NativePageTextProof.prove(page: number, nativeText: text, source: $0) }
                                    var ranges: [String: CachedQuoteRange] = [:], uniqueMatchedIDs = Set<String>()
                                    var lastProgress = ProcessInfo.processInfo.systemUptime
                                    for (offset, value) in matchingAdditions.enumerated() {
                                        guard !Task.isCancelled else { break }
                                        guard !value.quote.isEmpty, value.quote.utf16.count <= 32_768,
                                              (value.prefix?.utf8.count ?? 0) <= 4_096, (value.suffix?.utf8.count ?? 0) <= 4_096 else { continue }
                                        if let range = proof?.range(of: value.quote, location: value.rangeLocation, length: value.rangeLength) {
                                            ranges[value.id] = CachedQuoteRange(range: range)
                                        } else {
                                            let key = QuoteCacheKey(quote: Data(value.quote.utf8), prefix: value.prefix.map { Data($0.utf8) }, suffix: value.suffix.map { Data($0.utf8) })
                                            if let cached = saved[key] { ranges[value.id] = cached }
                                            else {
                                                let source = nativeSource ?? (text as NSString); nativeSource = source
                                                ranges[value.id] = CachedQuoteRange(range: Self.findNativeQuoteRange(value.quote, prefix: value.prefix, suffix: value.suffix, text: source))
                                            }
                                            uniqueMatchedIDs.insert(value.id)
                                        }
                                        if ProcessInfo.processInfo.systemUptime - lastProgress >= 0.1 {
                                            progress(.init(phase: .matching, page: number, completed: batchStart + offset + 1, total: total))
                                            lastProgress = ProcessInfo.processInfo.systemUptime
                                        }
                                    }
                                    return PageQuoteMatches(ranges: ranges, uniqueMatchedIDs: uniqueMatchedIDs, sourceTextIdentity: pageText?.identity, proof: proof)
                                }
                                let matches = await withTaskCancellationHandler(operation: { await calculation.value }, onCancel: { calculation.cancel() })
                                guard !Task.isCancelled, self.documentGeneration == documentID, self.sourceDecorationGeneration == generation else { return }
                                phaseProofChecked = true; phaseProof = matches.proof
                                if let identity = matches.sourceTextIdentity, self.sourcePageTexts[number]?.identity == identity {
                                    if (matches.proof?.byteCount ?? 0) <= 2_097_152 { cache.sourceTextProofIdentity = identity; cache.sourceTextProof = matches.proof }
                                    else { cache.sourceTextProofIdentity = nil; cache.sourceTextProof = nil }
                                }
                                progress(.init(phase: .matching, page: number, completed: batchEnd, total: additions.count))
                                // Native geometry is prepared only by the actor's
                                // own document, in small requests. The displayed
                                // PDF never parses a cold page for source hints.
                                if !passages {
                                    let requests = matchingAdditions.compactMap { value -> NativePDFPreparationWorker.GeometryRequest? in
                                        matches.ranges[value.id]?.range.map { .init(id: value.id, range: $0) }
                                    }
                                    for start in stride(from: 0, to: requests.count, by: 24) {
                                        try await self.waitForSourceScrollIdle(extraDelay: priority > 0 ? 0.35 : 0)
                                        let end = min(start + 24, requests.count)
                                        let geometry = try await self.nativePreparation.prepareGeometry(session: session, page: number, requests: Array(requests[start..<end]))
                                        guard !Task.isCancelled, self.documentGeneration == documentID, self.sourceDecorationGeneration == generation else { return }
                                        for request in requests[start..<end] {
                                            guard let value = self.sourceDecorationValuesByID[request.id] else { continue }
                                            let lines = geometry[request.id] ?? []
                                            let cost = value.quote.utf8.count + (value.prefix?.utf8.count ?? 0) + (value.suffix?.utf8.count ?? 0) + lines.count * 64 + 256
                                            let ready = SourceGeometry(value: value, page: number, range: request.range, lines: lines, cost: cost)
                                            cache.remember(ready); self.sourceGeometries[request.id] = ready
                                        }
                                        self.sourceCanvas.needsDisplay = true; self.scheduleSourceHoverRefresh()
                                        progress(.init(phase: .geometry, page: number, completed: end, total: requests.count))
                                    }
                                }
                                var applied = 0
                                for value in matchingAdditions {
                                    guard !Task.isCancelled, self.documentGeneration == documentID, self.sourceDecorationGeneration == generation else { return }
                                    let key = QuoteCacheKey(quote: Data(value.quote.utf8), prefix: value.prefix.map { Data($0.utf8) }, suffix: value.suffix.map { Data($0.utf8) })
                                    let matched = matches.ranges[value.id]
                                    if matches.uniqueMatchedIDs.contains(value.id), let matched, key.byteCount <= 1_048_576,
                                       cache.ranges[key] != nil || (cache.ranges.count < 2000 && cache.rangeBytes + key.byteCount <= 1_048_576) {
                                        if cache.ranges[key] == nil { cache.rangeBytes += key.byteCount }; cache.ranges[key] = matched
                                    }
                                    if passages { cache.rememberPassage(value, range: matched?.range) }
                                    else if cache.geometry[value.id]?.value != value {
                                        let cost = value.quote.utf8.count + (value.prefix?.utf8.count ?? 0) + (value.suffix?.utf8.count ?? 0) + 256
                                        let geometry = SourceGeometry(value: value, page: number, range: matched?.range, lines: [], cost: cost)
                                        cache.remember(geometry); self.sourceGeometries[value.id] = geometry
                                    }
                                    cache.rememberMatch(value.id, range: matched?.range, proofIdentity: matches.sourceTextIdentity)
                                    applied += 1
                                    if applied.isMultiple(of: 128) { try await Task.sleep(nanoseconds: 1_000_000) }
                                }
                            }
                            if passages { cache.rebuildPassageIndexIfNeeded() }
                            self.sourceCanvas.needsDisplay = true; self.trimSourceGeometryCache(keeping: window); self.scheduleSourceHoverRefresh()
                        }
                    }
                }
            } catch is CancellationError { return }
            catch {
                guard self.documentGeneration == documentID, self.sourceDecorationGeneration == generation else { return }
                // Only another explicit render trigger may retry this failure.
                // Do not recurse or schedule timers after a native/file error.
                self.sourcePreparationNeedsRetry = true
                self.setStatus("阅读提示暂未准备好，原文仍可阅读。")
                return
            }
            if self.sourceDecorationGeneration == generation { self.sourceDecorationTask = nil; self.renderSourceDecorations() }
        }
    }
    private func trimSourceGeometryCache(keeping window: [Int]) {
        while sourceGeometryPageOrder.count > 16 || sourceGeometryPages.values.reduce(0, { $0 + $1.cost }) > 12_582_912 {
            // In-use visible geometry must not disappear merely because a
            // dense page exceeds the idle-cache target. Evict only idle pages.
            guard let unused = sourceGeometryPageOrder.firstIndex(where: { !window.contains($0) }) else { break }
            sourceGeometryPages.removeValue(forKey: sourceGeometryPageOrder.remove(at: unused))
        }
    }
    private func waitForSourceScrollIdle(extraDelay: TimeInterval = 0) async throws {
        while true {
            try Task.checkCancellation()
            let remaining = sourceScrollQuietUntil + extraDelay - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(min(0.2, remaining) * 1_000_000_000))
        }
    }
    private func drawSourceDecorations(in dirty: CGRect) {
        guard let document, !document.isLocked else { return }
        for number in lastVisiblePages {
            guard let page = document.page(at: number - 1), let cache = sourceGeometryPages[number] else { continue }
            let dirtyInPDF = sourceCanvas.convert(dirty.insetBy(dx: -4, dy: -4), to: pdfView)
            let visible = pdfView.convert(dirtyInPDF.intersection(pdfView.bounds), to: page).intersection(page.readingSourceBounds(for: .cropBox))
            guard !visible.isEmpty, !visible.isNull else { continue }
            var candidates: Set<SourceLineKey>
            if cache.paintBands.requiresFallback {
                candidates = Set((sourceGeometryIDsByPage[number] ?? []).flatMap { id in
                    guard let geometry = sourceGeometries[id], geometry.value.interaction == .term, !geometry.value.passive else { return [SourceLineKey]() }
                    return geometry.lines.indices.map { SourceLineKey(id: id, line: $0) }
                })
            } else { candidates = cache.paintBands.candidates(intersecting: visible) }
            if let hoveredSourceID, sourceGeometries[hoveredSourceID]?.page == number {
                if cache.hitBands.requiresFallback, let hovered = sourceGeometries[hoveredSourceID] {
                    candidates.formUnion(hovered.lines.indices.map { SourceLineKey(id: hoveredSourceID, line: $0) })
                } else {
                    candidates.formUnion(cache.hitBands.candidates(intersecting: visible).filter { $0.id == hoveredSourceID })
                }
            }
            for key in candidates {
                guard let geometry = sourceGeometries[key.id], geometry.page == number, geometry.lines.indices.contains(key.line) else { continue }
                let active = key.id == hoveredSourceID
                if active, hoveredUnderlineID != nil { continue }
                guard active || (geometry.value.interaction == .term && !geometry.value.passive) else { continue }
                let rect = geometry.lines[key.line]
                guard rect.intersects(visible) else { continue }
                NSColor.systemTeal.withAlphaComponent(active ? 0.95 : 0.38).setStroke()
                let from = sourceCanvas.convert(pdfView.convert(CGPoint(x: rect.minX, y: rect.minY), from: page), from: pdfView)
                let to = sourceCanvas.convert(pdfView.convert(CGPoint(x: rect.maxX, y: rect.minY), from: page), from: pdfView)
                let center = sourceCanvas.convert(pdfView.convert(CGPoint(x: rect.midX, y: rect.midY), from: page), from: pdfView)
                let width = active ? 1.6 : 1.0
                guard let segment = ReadingUnderlineGeometry.outside(edgeStart: from, edgeEnd: to, contentCenter: center, lineWidth: width) else { continue }
                let path = NSBezierPath(); path.lineWidth = width
                path.move(to: segment.start); path.line(to: segment.end); path.stroke()
            }
        }
    }
    private func sourceHit(at point: CGPoint, preferTerm: Bool) -> PDFSourceDecorationHit? {
        guard let document, let page = pdfView.page(for: point, nearest: false) else { return nil }
        let index = document.index(for: page), local = pdfView.convert(point, to: page)
        guard index != NSNotFound, let cache = sourceGeometryPages[index + 1] else { return nil }
        // Native links and real annotations keep their existing actions.
        if let annotation = page.annotation(at: local) {
            guard let id = annotationIDs[ObjectIdentifier(annotation)],
                  (underlineRecordsByPage[index + 1] ?? []).contains(where: { $0.id == id }) else { return nil }
        }
        // Clicks prefer an already prepared term. Asking PDFKit for the whole
        // sentence's character/line geometry first adds work that cannot alter
        // that winner, especially with many overlapping passive passages.
        if preferTerm, let term = cachedSourceHit(at: local, on: page, number: index + 1, cache: cache, preferTerm: true, onlyTerms: true) { return term }
        // Physical native line ranges are authoritative here. PDFKit's
        // characterIndex can omit synthesized line breaks or count emoji
        // differently, and a glyph gap may return no index at all.
        let prepared = cachedSourceHit(at: local, on: page, number: index + 1, cache: cache, preferTerm: preferTerm)
        guard ProcessInfo.processInfo.systemUptime >= sourceScrollQuietUntil, !cache.passageIndex.isEmpty else { return prepared }
        let lines = cache.nativeLines.lines(at: local)
        guard !lines.isEmpty else { return prepared }
        let maximumRequests = 8
        var candidates: [NativePDFTextLine.Candidate<String>] = []
        var cached: (id: String, rectangle: CGRect, length: Int)?
        var visited = Set<String>()
        for line in lines {
            for range in line.ranges {
                cache.passageIndex.forEachEntry(intersecting: range) { entry in
                    guard visited.insert(entry.id).inserted, validSourceDecorationIDsByPage[index + 1]?.contains(entry.id) == true,
                          let value = cache.passageValues[entry.id], value.interaction == .passage,
                          value == sourceDecorationValuesByID[entry.id] else { return }
                    if let geometry = cache.geometry[entry.id], geometry.value == value {
                        sourceGeometries[entry.id] = geometry
                        if let rectangle = geometry.lines.first(where: { $0.contains(local) }) {
                            let moreSpecific = cached.map {
                                entry.range.length < $0.length || (entry.range.length == $0.length && entry.id < $0.id)
                            } ?? true
                            if moreSpecific { cached = (entry.id, rectangle, entry.range.length) }
                        }
                        return
                    }
                    let candidate = NativePDFTextLine.Candidate(id: entry.id, range: entry.range)
                    let position = candidates.firstIndex {
                        candidate.range.length < $0.range.length || (candidate.range.length == $0.range.length && candidate.id < $0.id)
                    } ?? candidates.count
                    if position < maximumRequests {
                        candidates.insert(candidate, at: position)
                        if candidates.count > maximumRequests { candidates.removeLast() }
                    }
                }
            }
        }
        // Cold native geometry never runs in the pointer handler. A single
        // background queue coalesces at most eight current candidates; completed
        // results request a fresh current-pointer check, not a stored position.
        let moreSpecific = candidates.prefix { candidate in
            cached.map { candidate.range.length < $0.length || (candidate.range.length == $0.length && candidate.id < $0.id) } ?? true
        }
        queueSourceGeometry(Array(moreSpecific), page: index + 1, cache: cache)
        if let cached { return PDFSourceDecorationHit(id: cached.id, rect: pdfView.convert(cached.rectangle, from: page)) }
        return prepared
    }
    private func queueSourceGeometry(_ candidates: [NativePDFTextLine.Candidate<String>], page: Int, cache: SourceGeometryPage) {
        guard let session = nativePreparationSession() else { return }
        var next: [String: PendingSourceGeometry] = [:]
        for candidate in candidates.prefix(8) {
            guard !inFlightSourceGeometryIDs.contains(candidate.id),
                  let value = cache.passageValues[candidate.id], value == sourceDecorationValuesByID[candidate.id],
                  cache.passageRanges[candidate.id] == candidate.range else { continue }
            next[candidate.id] = PendingSourceGeometry(page: page, value: value, range: candidate.range)
        }
        pendingSourceGeometry = next
        guard sourceGeometryTask == nil, !pendingSourceGeometry.isEmpty else { return }
        let generation = sourceDecorationGeneration, documentID = documentGeneration, run = UUID()
        sourceGeometryRun = run
        onPreparationChanged?(.started(run, .init(phase: .geometry, page: page, completed: 0, total: next.count)))
        let progress = preparationProgress(run: run, generation: generation, documentID: documentID)
        sourceGeometryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.sourceGeometryRun == run {
                    self.onPreparationChanged?(.finished(run)); self.sourceGeometryRun = nil
                    self.sourceGeometryTask = nil; self.inFlightSourceGeometryIDs = []; self.pendingSourceGeometry = [:]
                }
            }
            do {
                while !self.pendingSourceGeometry.isEmpty {
                    try await self.waitForSourceScrollIdle()
                    guard !Task.isCancelled, self.documentGeneration == documentID,
                          self.sourceDecorationGeneration == generation, self.sourceGeometryRun == run,
                          let number = self.pendingSourceGeometry.values.first?.page,
                          let cache = self.sourceGeometryPages[number] else { return }
                    let batch = Array(self.pendingSourceGeometry.values.filter { $0.page == number }.prefix(8))
                    self.inFlightSourceGeometryIDs = Set(batch.map { $0.value.id })
                    for item in batch { self.pendingSourceGeometry.removeValue(forKey: item.value.id) }
                    let requests = batch.map { NativePDFPreparationWorker.GeometryRequest(id: $0.value.id, range: $0.range) }
                    let values = try await self.nativePreparation.prepareGeometry(session: session, page: number, requests: requests, onProgress: progress)
                    guard !Task.isCancelled, self.documentGeneration == documentID,
                          self.sourceDecorationGeneration == generation, self.sourceGeometryRun == run,
                          self.sourceGeometryPages[number] === cache,
                          let page = self.document?.page(at: number - 1), let layout = cache.nativeLineLayout,
                          page.readingSourceBounds(for: .cropBox) == layout.crop, page.rotation == layout.rotation else { return }
                    for item in batch {
                        guard self.sourceDecorationValuesByID[item.value.id] == item.value,
                              cache.passageValues[item.value.id] == item.value,
                              cache.passageRanges[item.value.id] == item.range else { continue }
                        let lines = values[item.value.id] ?? []
                        let geometry = SourceGeometry(value: item.value, page: number, range: item.range, lines: lines, cost: lines.count * 64 + 128)
                        cache.remember(geometry); self.sourceGeometries[item.value.id] = geometry
                    }
                    self.inFlightSourceGeometryIDs = []
                    self.sourceCanvas.needsDisplay = true; self.scheduleSourceHoverRefresh()
                }
            } catch is CancellationError { return }
            catch {
                if self.sourceGeometryRun == run { self.pendingSourceGeometry = [:] }
            }
        }
    }
    private func cachedSourceHit(at local: CGPoint, on page: PDFPage, number: Int, cache: SourceGeometryPage,
                                 preferTerm: Bool, onlyTerms: Bool = false) -> PDFSourceDecorationHit? {
        let candidates: Set<SourceLineKey>
        if cache.hitBands.requiresFallback {
            candidates = Set((sourceGeometryIDsByPage[number] ?? []).flatMap { id -> [SourceLineKey] in
                guard let geometry = sourceGeometries[id] else { return [] }
                return geometry.lines.indices.map { SourceLineKey(id: id, line: $0) }
            })
        } else { candidates = cache.hitBands.candidates(atY: local.y) }
        var best: (id: String, rect: CGRect, term: Bool, length: Int)?
        for key in candidates {
            guard let geometry = sourceGeometries[key.id], geometry.page == number, geometry.lines.indices.contains(key.line),
                  !onlyTerms || geometry.value.interaction == .term else { continue }
            let rect = geometry.lines[key.line]
            guard rect.contains(local) else { continue }
            let term = geometry.value.interaction == .term, length = geometry.value.rangeLength ?? Int.max
            if let chosen = best {
                if term != chosen.term { if term != preferTerm { continue } }
                else if length > chosen.length || (length == chosen.length && key.id >= chosen.id) { continue }
            }
            best = (key.id, rect, term, length)
        }
        guard let best else { return nil }
        return PDFSourceDecorationHit(id: best.id, rect: pdfView.convert(best.rect, from: page))
    }
    private func removeSourcePointerMonitor() {
        if let sourcePointerMonitor { NSEvent.removeMonitor(sourcePointerMonitor) }
        sourcePointerMonitor = nil; invalidateSourcePress()
    }
    private func invalidateSourcePress() {
        cancelSourceHoverRefresh()
        sourceInteractionGeneration &+= 1; sourcePress = nil
    }
    private func cancelSourceHoverRefresh() {
        sourceHoverRefreshWork?.cancel(); sourceHoverRefreshWork = nil
        sourceHoverRefresh.cancel()
    }
    private func scheduleSourceHoverRefresh() {
        // PDFKit may clear selection or change scale synchronously while a
        // document is being replaced. That transition has no eligible hover;
        // its page worker will request one after installation completes.
        guard !installingDocument else { return }
        let previous = sourceHoverRefresh.pending
        guard let ticket = sourceHoverRefresh.request(at: ProcessInfo.processInfo.systemUptime, quietUntil: sourceScrollQuietUntil) else { return }
        if previous == ticket, sourceHoverRefreshWork != nil { return }
        sourceHoverRefreshWork?.cancel()
        let documentID = documentGeneration, interaction = sourceInteractionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.documentGeneration == documentID, self.sourceInteractionGeneration == interaction,
                  self.sourceHoverRefresh.pending == ticket else { return }
            self.sourceHoverRefreshWork = nil
            guard self.sourceHoverRefresh.consume(ticket, at: ProcessInfo.processInfo.systemUptime, quietUntil: self.sourceScrollQuietUntil) else {
                self.scheduleSourceHoverRefresh(); return
            }
            // Scheduling never makes a former mouse position authoritative.
            // Geometry may finish after leaving the page or opening a panel;
            // only the pointer's current frontmost window and hit are eligible.
            guard let owner = self.window, NSApp.isActive, owner.isKeyWindow,
                  NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == owner.windowNumber,
                  !self.interactionBlocked, !self.isHiddenOrHasHiddenAncestor, !self.installingDocument,
                  owner.attachedSheet == nil, NSApp.modalWindow == nil, !self.pdfView.isRegionSelectionArmed,
                  NSEvent.pressedMouseButtons == 0,
                  NSEvent.modifierFlags.intersection([.option, .command, .control]).isEmpty,
                  self.pdfView.currentSelection?.pages.isEmpty != false else {
                self.reportSourceHover(nil); return
            }
            let point = owner.mouseLocationOutsideOfEventStream
            guard self.ownsPDFHit(at: point, in: owner) else { self.reportSourceHover(nil); return }
            let pdfPoint = self.pdfView.convert(point, from: nil)
            self.reportSourceHover(self.sourceHit(at: pdfPoint, preferTerm: false))
            // Saved marks have their own authoritative quads. Their feedback
            // must not wait for model/source-card geometry to be prepared.
            self.refreshSavedUnderlineHover(at: pdfPoint)
        }
        sourceHoverRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, ticket.deadline - ProcessInfo.processInfo.systemUptime), execute: work)
    }
    private func observeSourcePointer(_ event: NSEvent) {
        // A later click, drag or wheel expresses a newer reader intention.
        // Late acceleration metadata must not pull the viewport back to an
        // earlier sentence after that action (including scrollbar dragging).
        if event.type != .mouseMoved, event.window === window {
            awaitingSourceFocusProof = false
            cancelSourceQuotePreparation()
        }
        if event.type == .mouseMoved {
            guard event.window === window, NSEvent.pressedMouseButtons == 0 else {
                cancelSourceHoverRefresh(); reportSourceHover(nil); return
            }
            scheduleSourceHoverRefresh(); return
        }
        // Wheel events keep their original recipient. Clearing an existing
        // hover needs neither a window hit-test nor a full-book read boundary.
        if event.type == .scrollWheel {
            guard event.window === window else { return }
            sourceScrollQuietUntil = ProcessInfo.processInfo.systemUptime + 0.15
            invalidateSourcePress(); reportSourceHover(nil); scheduleSourceHoverRefresh(); return
        }
        guard let owner = window, event.window === owner, !interactionBlocked, !isHiddenOrHasHiddenAncestor,
              !installingDocument, owner.attachedSheet == nil, NSApp.modalWindow == nil,
              !pdfView.isRegionSelectionArmed, ownsPDFHit(event, in: owner),
              event.modifierFlags.intersection([.option, .command, .control]).isEmpty else {
            invalidateSourcePress(); if event.type == .mouseMoved { reportSourceHover(nil) }; return
        }
        let point = pdfView.convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            invalidateSourcePress()
            clearQuoteFocusHighlight()
            reportSourceHover(nil)
            sourcePress = event.clickCount == 1 ? sourceHit(at: point, preferTerm: true).map { ($0, point, sourceInteractionGeneration) } : nil
        case .leftMouseDragged, .scrollWheel:
            invalidateSourcePress(); reportSourceHover(nil)
        case .leftMouseUp:
            defer { sourcePress = nil }
            guard event.clickCount == 1, let press = sourcePress, hypot(point.x - press.point.x, point.y - press.point.y) <= 3,
                  press.generation == sourceInteractionGeneration, let geometry = sourceGeometries[press.hit.id] else { return }
            let generation = documentGeneration, navigation = navigationRequestID, input = sourceInputGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.documentGeneration == generation, self.navigationRequestID == navigation,
                      self.sourceInputGeneration == input, self.sourceInteractionGeneration == press.generation,
                      self.window === owner, !self.interactionBlocked, !self.isHiddenOrHasHiddenAncestor,
                      !self.installingDocument, owner.attachedSheet == nil, NSApp.modalWindow == nil,
                      !self.pdfView.isRegionSelectionArmed,
                      self.sourceGeometries[press.hit.id]?.value == geometry.value,
                      self.sourceGeometries[press.hit.id]?.page == geometry.page,
                      self.pdfView.currentSelection?.string?.isEmpty != false else { return }
                self.reportSourceHover(press.hit, activated: true)
            }
        default: break
        }
    }
    private func renderSavedAnnotations() {
        invalidateSourcePress()
        refreshSavedUnderlineHover(at: nil)
        for (page, annotation) in renderedAnnotations { page.removeAnnotation(annotation) }
        renderedAnnotations = []; annotationIDs = [:]
        renderedUnderlinesByID = [:]
        underlineRecordsByPage = Dictionary(grouping: savedAnnotations.filter { $0.trashedAt == nil && $0.sourceHash == sourceHash && $0.lineStyle != nil }, by: \.page)
        underlineRecordsByID = Dictionary(underlineRecordsByPage.values.flatMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        underlineHitBands = underlineRecordsByPage.mapValues { records in
            var bands = ReadingGeometryBands<String>()
            for record in records { for quad in record.quads {
                bands.insert(record.id, rectangle: CGRect(x: quad.x, y: quad.y, width: quad.width, height: quad.height).insetBy(dx: -1, dy: -4))
            } }
            return bands
        }
        guard let document, !document.isLocked else { return }
        for record in savedAnnotations where record.trashedAt == nil && record.sourceHash == sourceHash {
            guard record.page >= 1, record.page <= document.pageCount, let page = document.page(at: record.page - 1) else { continue }
            for quad in record.quads {
                guard let annotation = ReaderAnnotationAppearance.make(record, quad: quad, crop: page.readingSourceBounds(for: .cropBox)) else { continue }
                page.addAnnotation(annotation); renderedAnnotations.append((page, annotation))
                annotationIDs[ObjectIdentifier(annotation)] = record.id
                if record.lineStyle != nil { renderedUnderlinesByID[record.id, default: []].append(annotation) }
            }
        }
        pdfView.needsDisplay = true
    }

    private func sentenceMarkActions(page: PDFPage, point: CGPoint) -> [ReadingContextAction] {
        guard canEditAnnotations, !interactionBlocked, let document, !document.isLocked, document.allowsCopying,
              page.document === document else { return [] }
        let number = document.index(for: page) + 1
        // Already prepared hover geometry is the fast path. The explicit menu
        // command may prepare up to eight native ranges on this one hit line;
        // ordinary mouse movement still does no synchronous native geometry.
        let hit = (sourceGeometryIDsByPage[number] ?? []).compactMap { sourceGeometries[$0] }
            .filter { $0.value.interaction == .passage && $0.value == sourceDecorationValuesByID[$0.value.id] && $0.lines.contains(where: { $0.contains(point) }) }
            .min { ($0.range?.length ?? Int.max, $0.value.id) < ($1.range?.length ?? Int.max, $1.value.id) }
        var candidates: [(id: String, range: NSRange)] = []
        if let hit, let range = hit.range { candidates.append((hit.value.id, range)) }
        if let cache = sourceGeometryPages[number], candidates.isEmpty {
            var seen = Set<String>()
            for line in cache.nativeLines.lines(at: point) { for nativeRange in line.ranges {
                cache.passageIndex.forEachEntry(intersecting: nativeRange) { entry in
                    guard seen.insert(entry.id).inserted, let value = cache.passageValues[entry.id],
                          value == sourceDecorationValuesByID[entry.id] else { return }
                    candidates.append((entry.id, entry.range))
                    candidates.sort { ($0.range.length, $0.id) < ($1.range.length, $1.id) }
                    if candidates.count > 8 { candidates.removeLast() }
                }
            } }
        }
        let hash = sourceHash
        guard let target = candidates.lazy.compactMap({ try? ReaderAnnotationCapture.sentence(range: $0.range, page: page, document: document, sourceHash: hash, point: point) }).first
            ?? savedAnnotations.first(where: { record in record.trashedAt == nil && record.sourceHash == hash && record.page == number && record.lineStyle != nil && record.quads.contains(where: { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(point) }) }) else { return [] }
        let range = NSRange(location: target.rangeLocation, length: target.rangeLength)
        let generation = documentGeneration, navigation = navigationRequestID, source = sourceHash
        let existing = savedAnnotations.first { $0.trashedAt == nil && $0.sourceHash == source && $0.page == number && $0.lineStyle != nil && $0.rangeLocation == range.location && $0.rangeLength == range.length }
        var actions = ReaderAnnotationLineStyle.allCases.map { style in
            let removing = existing?.lineStyle == style
            let name = style == .straight ? "直线下划线" : "波浪下划线"
            return ReadingContextAction(title: (removing ? "移除" : "添加") + name, icon: style == .straight ? "underline" : "water.waves") { [weak self, weak page] in
                guard let self, let page, self.canEditAnnotations, !self.interactionBlocked,
                      self.documentGeneration == generation, self.navigationRequestID == navigation,
                      self.sourceHash == source, page.document === self.document else { return }
                Task { @MainActor in
                    if removing, let existing { _ = await self.onTrashAnnotation?(existing.id, true) }
                    else {
                        var record = existing ?? target; record.lineStyle = style
                        if existing == nil { record.color = .blue; record.lineAppearance = ReaderUnderlineDefaults.value }
                        _ = await self.onSaveAnnotations?([record])
                    }
                }
            }
        }
        actions.append(.init(title: "下划线样式…", icon: "slider.horizontal.3") { [weak self] in
            self?.showUnderlineStyle(existing: existing, generation: generation, navigation: navigation, source: source)
        })
        return actions
    }

    private func showUnderlineStyle(existing: ReaderAnnotation?, generation: Int, navigation: Int, source: String) {
        guard canEditAnnotations, !interactionBlocked, documentGeneration == generation, navigationRequestID == navigation,
              sourceHash == source, window?.attachedSheet == nil else { return }
        let initial = existing.map { record -> ReaderUnderlineAppearance in
            if let appearance = record.lineAppearance { return appearance }
            var appearance = ReaderUnderlineAppearance()
            if let color = record.color.nativeColor.usingColorSpace(.sRGB) {
                appearance.red = color.redComponent; appearance.green = color.greenComponent; appearance.blue = color.blueComponent
            }
            return appearance
        } ?? ReaderUnderlineDefaults.value
        let view = ReaderUnderlineStyleView(value: initial, editsExisting: existing != nil,
            onApply: { [weak self] appearance in
                guard let self, appearance.isValid, self.documentGeneration == generation,
                      self.navigationRequestID == navigation, self.sourceHash == source, self.canEditAnnotations else { return false }
                if let existing {
                    guard self.savedAnnotations.contains(existing) else { self.setStatus("这条划线已在别处变化，请关闭后重新打开样式。"); return false }
                    var updated = existing; updated.lineAppearance = appearance
                    guard await self.onSaveAnnotations?([updated]) == true else { return false }
                }
                ReaderUnderlineDefaults.save(appearance); self.closeAnnotationPanel(); return true
            }, onCancel: { [weak self] in self?.closeAnnotationPanel() })
        presentAnnotationPanel(view, title: "下划线样式", asSheet: true)
    }

    @objc private func annotationHit(_ notification: Notification) {
        guard let annotation = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation else { return }
        // Source mentions are admitted by the click/drag distinction below.
        openAnnotation(annotation)
    }
    private func openAnnotation(_ annotation: PDFAnnotation) {
        guard let id = annotationIDs[ObjectIdentifier(annotation)], let record = savedAnnotations.first(where: { $0.id == id && $0.trashedAt == nil }) else { return }
        editAnnotations([record])
    }

    private func reportSourceHover(_ hit: PDFSourceDecorationHit?, activated: Bool = false) {
        if hit == nil { refreshSavedUnderlineHover(at: nil) }
        guard hit != nil || hoveredSourceID != nil else { return }
        if hoveredSourceID != hit?.id {
            let old = hoveredSourceID; hoveredSourceID = hit?.id
            invalidateSourceHover(old); invalidateSourceHover(hit?.id)
        }
        guard let hit else { publishSourceHover(nil); return }
        let rect = convert(hit.rect, from: pdfView)
        let topRect = isFlipped ? rect : CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        publishSourceHover(SourceReadingHover(id: hit.id, rect: topRect, point: CGPoint(x: topRect.midX, y: topRect.maxY), activated: activated))
    }
    @objc private func readingWindowResigned(_ notification: Notification) {
        if notification.object as? NSWindow === window { reportSourceHover(nil) }
    }
    func refreshSavedUnderlineHover(at point: CGPoint?) {
        let page = point.flatMap { point -> PDFPage? in
            guard point.x.isFinite, point.y.isFinite else { return nil }
            return pdfView.page(for: point, nearest: false)
        }
        let number = page.flatMap { page -> Int? in
            guard let index = document?.index(for: page), index != NSNotFound else { return nil }; return index + 1
        }
        let local = point.flatMap { point in page.map { pdfView.convert(point, to: $0) } }
        let bands = number.flatMap { underlineHitBands[$0] }
        let ids = local.map { bands?.requiresFallback == true ? Set(number.flatMap { underlineRecordsByPage[$0] }?.map(\.id) ?? []) : bands?.candidates(atY: $0.y) ?? [] } ?? []
        let record = ids.compactMap { underlineRecordsByID[$0] }.filter { value in
            local.map { point in value.quads.contains { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).insetBy(dx: -1, dy: -4).contains(point) } } == true
        }.min { ($0.rangeLength, $0.id) < ($1.rangeLength, $1.id) }
        guard let record, let page, !interactionBlocked, window?.isKeyWindow == true,
              pageCurl == nil, header.isHidden, thumbnailPanel.isHidden else {
            hoveredUnderlineID = nil; underlineHoverLayer.removeAllAnimations(); underlineHoverLayer.path = nil; return
        }
        let changed = hoveredUnderlineID != record.id; hoveredUnderlineID = record.id
        let path = CGMutablePath()
        for annotation in renderedUnderlinesByID[record.id] ?? [] {
            let origin = sourceCanvas.convert(pdfView.convert(annotation.bounds.origin, from: page), from: pdfView)
            let x = sourceCanvas.convert(pdfView.convert(CGPoint(x: annotation.bounds.minX + 1, y: annotation.bounds.minY), from: page), from: pdfView)
            let y = sourceCanvas.convert(pdfView.convert(CGPoint(x: annotation.bounds.minX, y: annotation.bounds.minY + 1), from: page), from: pdfView)
            let transform = CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y, c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y)
            for ink in annotation.paths ?? [] { path.addPath(ink.cgPath, transform: transform) }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        underlineHoverLayer.frame = sourceCanvas.bounds; underlineHoverLayer.path = path
        let appearance = record.lineAppearance ?? ReaderUnderlineAppearance()
        underlineHoverLayer.strokeColor = (record.lineAppearance == nil ? record.color.nativeColor : NSColor(srgbRed: appearance.red, green: appearance.green, blue: appearance.blue, alpha: 1)).cgColor
        underlineHoverLayer.lineWidth = appearance.thickness * pdfView.scaleFactor; underlineHoverLayer.opacity = 0.65
        CATransaction.commit()
        if record.lineStyle == .wavy, !reducedMotion, !reduceReadingMotion {
            if changed || underlineHoverLayer.animation(forKey: "reading-breath") == nil {
                let animation = CABasicAnimation(keyPath: "opacity"); animation.fromValue = 0.12; animation.toValue = 0.85
                animation.duration = 1.15; animation.autoreverses = true; animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                underlineHoverLayer.add(animation, forKey: "reading-breath")
            }
        } else { underlineHoverLayer.removeAllAnimations() }
    }
    private func publishSourceHover(_ value: SourceReadingHover?) {
        // Resets also run inside make/updateNSView. The SwiftUI recipient
        // publishes observable card state, so every delivery must leave that
        // update transaction. Preserve FIFO, including explicit activation.
        let generation = documentGeneration, navigation = navigationRequestID, interaction = sourceInteractionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A reset carries no old source and still clears a card on reload.
            // A positive hit must never arrive after a document/navigation change.
            if let value {
                guard self.documentGeneration == generation, self.navigationRequestID == navigation,
                      self.sourceInteractionGeneration == interaction, self.hoveredSourceID == value.id,
                      !self.interactionBlocked, !self.installingDocument else { return }
            }
            self.onSourceDecorationHover?(value)
        }
    }
    private func invalidateSourceHover(_ id: String?) {
        guard let id, let geometry = sourceGeometries[id], let page = document?.page(at: geometry.page - 1) else { return }
        for rect in geometry.lines {
            let display = sourceCanvas.convert(pdfView.convert(rect, from: page), from: pdfView).insetBy(dx: -4, dy: -4)
            sourceCanvas.setNeedsDisplay(display)
        }
    }

    private func createHighlight() {
        guard canEditAnnotations else { setStatus("当前任务运行中，请稍后添加高亮。"); return }
        guard let document, let selection = pdfView.currentSelection, onSaveAnnotations != nil else { setStatus("请先选择PDF文字；扫描页或无文字选择时，可用阅读菜单的“框选区域批注”。"); return }
        do { editAnnotations(try ReaderAnnotationCapture.capture(selection: selection, document: document, sourceHash: sourceHash)) }
        catch { setStatus(error.localizedDescription) }
    }

    private func createRegion(page: PDFPage, rect: CGRect) {
        guard let document, page.document === document, !sourceHash.isEmpty, onSaveAnnotations != nil else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        setStatus("")
        let annotation = ReaderAnnotation(sourceHash: sourceHash, page: index + 1, text: "", rangeLocation: 0, rangeLength: 0, quads: [ReaderQuadRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)], kind: .region)
        editAnnotations([annotation])
    }

    private func presentAnnotationPanel<V: View>(_ view: V, title: String, asSheet: Bool = false) {
        guard let owner = window else { setStatus("阅读窗口尚未就绪，请稍后打开批注。"); return }
        if asSheet {
            guard owner.attachedSheet == nil else { setStatus("请先完成或关闭当前窗口的弹出表单，再编辑批注。"); return }
            closeAnnotationPanel()
        } else if editingAnnotationSheet { annotationPanel?.makeKeyAndOrderFront(nil); return }
        if annotationPanel == nil {
            // Editor sheets have no native close button: only successful save or
            // the explicit cancel action can dismiss a draft, including during I/O.
            let style: NSWindow.StyleMask = asSheet ? [.titled, .resizable] : [.titled, .closable, .resizable]
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480), styleMask: style, backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.minSize = NSSize(width: 330, height: 300)
            annotationPanel = panel
        }
        guard let panel = annotationPanel else { return }
        panel.title = title; panel.contentView = NSHostingView(rootView: view)
        if asSheet { editingAnnotationSheet = true; owner.beginSheet(panel) }
        else { if !panel.isVisible { panel.center(); owner.addChildWindow(panel, ordered: .above) }; panel.makeKeyAndOrderFront(nil) }
    }

    private func closeAnnotationPanel() {
        if let panel = annotationPanel {
            if let owner = panel.sheetParent { owner.endSheet(panel) }
            else { panel.parent?.removeChildWindow(panel) }
            panel.orderOut(nil); panel.close(); panel.contentView = nil
        }
        annotationPanel = nil; showingAnnotationList = false; editingAnnotationSheet = false
    }

    private func editAnnotations(_ records: [ReaderAnnotation]) {
        guard let controller else { return }
        guard window?.attachedSheet == nil else { setStatus("请先完成或关闭当前窗口的弹出表单，再编辑批注。"); return }
        showingAnnotationList = false
        let existing = records.count == 1 && savedAnnotations.contains(where: { $0.id == records[0].id })
        let saveCallback = onSaveAnnotations, trashCallback = onTrashAnnotation
        // The sheet owns its draft and retains this controller until it is explicitly
        // dismissed; a cross-window navigation cannot silently destroy the text.
        let editor = PDFAnnotationEditor(controller: controller, records: records, canDelete: existing, onSave: { [self] updated in
            let saved = await saveCallback?(updated) ?? false
            if saved { self.closeAnnotationPanel() }; return saved
        }, onDelete: { [self] in
            guard let record = records.first else { return false }
            let saved = await trashCallback?(record.id, true) ?? false
            if saved { self.closeAnnotationPanel() }; return saved
        }, onCancel: { [self] in closeAnnotationPanel() })
        presentAnnotationPanel(editor, title: existing ? "编辑高亮与批注" : "保存高亮与批注", asSheet: true)
    }

    private func showAnnotations() {
        guard let controller else { return }
        showingAnnotationList = true
        let list = PDFAnnotationList(controller: controller, records: savedAnnotations, onLocate: { [weak self] record in
            self?.closeAnnotationPanel(); self?.navigate(to: record.page)
        }, onEdit: { [weak self] record in self?.editAnnotations([record]) }, onTrash: { [weak self] record, trashed in await self?.onTrashAnnotation?(record.id, trashed) ?? false })
        presentAnnotationPanel(list, title: "本书PDF批注")
    }
}

private extension ReaderAnnotationColor {
    var nativeColor: NSColor { switch self { case .yellow: return .systemYellow; case .green: return .systemGreen; case .blue: return .systemBlue; case .pink: return .systemPink } }
}

/// Region mode intercepts PDFKit's text selection only while explicitly armed.
/// Both endpoints must belong to the same page; coordinates are converted by PDFView, including rotation/crop.
@MainActor private final class AnnotationPDFView: PDFView {
    var paperTurnInProgress = false
    var onSourcePointerLeft: (() -> Void)?
    private var sourceTrackingArea: NSTrackingArea?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true }
    override func updateTrackingAreas() {
        if let sourceTrackingArea { removeTrackingArea(sourceTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        sourceTrackingArea = area; addTrackingArea(area); super.updateTrackingAreas()
    }
    override func mouseExited(with event: NSEvent) { onSourcePointerLeft?(); super.mouseExited(with: event) }
    var interactionBlocked = false
    var readingDirection = PDFReadingDirection.vertical
    var onReadingNavigation: ((Int, PDFReadingDirection, Bool, Bool) -> Bool)?
    var onNotePlacementCancelled: (() -> Void)?
    var onNotePoint: ((PDFPage, CGPoint) -> Void)?
    private var noteArmed = false
    private let readingContext = ReadingContextPopover()
    var onBookmarkPoint: ((PDFPage) -> Void)?
    var onSentenceActions: ((PDFPage, CGPoint) -> [ReadingContextAction])?
    var onNotePreview: ((PDFPage, CGPoint) -> Void)?
    func armNotePlacement() { cancelRegionSelection(); noteArmed = true }
    override func menu(for event: NSEvent) -> NSMenu? {
        showReadingContext(for: event)
        return nil
    }
    override func rightMouseDown(with event: NSEvent) { showReadingContext(for: event) }
    private func showReadingContext(for event: NSEvent) {
        guard !interactionBlocked, !paperTurnInProgress else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), let page = page(for: point, nearest: false), let anchor = window?.contentView else { return }
        let original = convert(point, to: page)
        guard page.readingSourceBounds(for: .cropBox).contains(original) else { return }
        readingContext.show([
            .init(title: "在此写便签", icon: "square.and.pencil", action: { [weak self, weak page] in
                guard let self, let page, !self.interactionBlocked else { return }; self.onNotePoint?(page, original)
            }),
            .init(title: "添加书签", icon: "bookmark", action: { [weak self, weak page] in
                guard let self, let page, !self.interactionBlocked else { return }; self.onBookmarkPoint?(page)
            })
        ] + (onSentenceActions?(page, original) ?? []), at: anchor.convert(point, from: self), in: anchor)
    }
    override func mouseMoved(with event: NSEvent) {
        if noteArmed, !interactionBlocked {
            let point = convert(event.locationInWindow, from: nil)
            if let page = page(for: point, nearest: false) { onNotePreview?(page, convert(point, to: page)) }
            return
        }
        super.mouseMoved(with: event)
    }
    var onRegion: ((PDFPage, CGRect) -> Void)?
    var onRegionError: ((String) -> Void)?
    var isManagedAnnotation: ((PDFAnnotation) -> Bool)?
    var onAnnotationTap: ((PDFAnnotation) -> Void)?
    private var regionArmed = false
    var isRegionSelectionArmed: Bool { regionArmed }
    private var handlingManagedClick = false
    private var regionStart: (page: PDFPage, pagePoint: CGPoint, viewPoint: CGPoint)?
    private var regionPreview: NSView?

    func armRegionSelection() { cancelRegionSelection(); regionArmed = true }
    func cancelRegionSelection() { noteArmed = false; regionArmed = false; handlingManagedClick = false; regionStart = nil; regionPreview?.removeFromSuperview(); regionPreview = nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if paperTurnInProgress { return bounds.contains(local) ? self : nil }
        if regionArmed || noteArmed { return bounds.contains(local) ? self : nil }
        // Own the original window event rather than PDFKit page subviews'
        // forwarded context events, whose coordinates can follow page layout.
        if NSApp.currentEvent?.type == .rightMouseDown { return bounds.contains(local) ? self : nil }
        if NSApp.currentEvent?.modifierFlags.contains(.option) != true, managedAnnotation(at: local) != nil { return self }
        return super.hitTest(point)
    }
    private func managedAnnotation(at point: CGPoint) -> PDFAnnotation? {
        guard let page = page(for: point, nearest: false) else { return nil }
        let local = convert(point, to: page)
        return page.annotations.reversed().first { isManagedAnnotation?($0) == true && $0.bounds.contains(local) }
    }
    override func mouseDown(with event: NSEvent) {
        guard !paperTurnInProgress else { return }
        let point = convert(event.locationInWindow, from: nil)
        if noteArmed {
            defer { cancelRegionSelection() }
            if let page = page(for: point, nearest: false) { onNotePoint?(page, convert(point, to: page)) }; return
        }
        if !regionArmed {
            if !event.modifierFlags.contains(.option), let annotation = managedAnnotation(at: point) {
                handlingManagedClick = true; onAnnotationTap?(annotation); return
            }
            super.mouseDown(with: event); return
        }
        guard let page = page(for: point, nearest: false) else { cancelRegionSelection(); onRegionError?("请从PDF页面内开始框选。"); return }
        regionStart = (page, convert(point, to: page), point)
        let preview = NSView(frame: NSRect(origin: point, size: .zero)); preview.wantsLayer = true
        preview.layer?.borderColor = NSColor.systemYellow.cgColor; preview.layer?.borderWidth = 1.5
        preview.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.15).cgColor
        addSubview(preview); regionPreview = preview
    }
    override func mouseDragged(with event: NSEvent) {
        guard !handlingManagedClick else { return }
        guard let start = regionStart else { if !regionArmed { super.mouseDragged(with: event) }; return }
        let point = convert(event.locationInWindow, from: nil)
        regionPreview?.frame = NSRect(x: min(point.x, start.viewPoint.x), y: min(point.y, start.viewPoint.y), width: abs(point.x - start.viewPoint.x), height: abs(point.y - start.viewPoint.y))
    }
    override func mouseUp(with event: NSEvent) {
        if handlingManagedClick { handlingManagedClick = false; return }
        guard let start = regionStart else { if !regionArmed { super.mouseUp(with: event) }; return }
        let point = convert(event.locationInWindow, from: nil)
        defer { cancelRegionSelection() }
        guard let endPage = page(for: point, nearest: false), endPage === start.page else { onRegionError?("区域批注一次只能框选同一页，跨页拖框未保存，请分别框选。"); return }
        let end = convert(point, to: start.page)
        let rect = CGRect(x: min(end.x, start.pagePoint.x), y: min(end.y, start.pagePoint.y), width: abs(end.x - start.pagePoint.x), height: abs(end.y - start.pagePoint.y)).intersection(start.page.readingSourceBounds(for: .cropBox))
        guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { onRegionError?("框选区域太小或在页面外，未保存。"); return }
        onRegion?(start.page, rect)
    }
    override func keyDown(with event: NSEvent) {
        guard !interactionBlocked, !paperTurnInProgress else { return }
        if (regionArmed || noteArmed) && event.keyCode == 53 { let note = noteArmed; cancelRegionSelection(); if note { onNotePlacementCancelled?() }; onRegionError?(""); return }
        // Every plain arrow pans along its own axis. Only the selected reading
        // axis turns pages, and only after the current magnified page boundary.
        if !regionArmed, (displayMode == .singlePage || displayMode == .singlePageContinuous),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           let onReadingNavigation {
            let input: (Int, PDFReadingDirection, Bool)?
            switch event.keyCode {
            case 123: input = (-1, .horizontal, false)
            case 124: input = (1, .horizontal, false)
            case 126: input = (-1, .vertical, false)
            case 125: input = (1, .vertical, false)
            case 116: input = (-1, readingDirection, true)
            case 121: input = (1, readingDirection, true)
            default: input = nil
            }
            if let input, onReadingNavigation(input.0, input.1, input.2, event.isARepeat) { return }
        }
        super.keyDown(with: event)
    }
    override func swipe(with event: NSEvent) {
        guard !interactionBlocked, !paperTurnInProgress else { return }
        guard !regionArmed, (displayMode == .singlePage || displayMode == .singlePageContinuous), let onReadingNavigation else {
            super.swipe(with: event); return
        }
        let delta = readingDirection == .vertical ? event.deltaY : event.deltaX
        let cross = readingDirection == .vertical ? event.deltaX : event.deltaY
        // Discrete accessibility/system swipes obey the same axis as two-finger
        // scrolling. Perpendicular swipes must not invoke PDFKit's own pager.
        guard abs(delta) > 0.001, abs(delta) >= abs(cross) else { return }
        _ = onReadingNavigation(delta > 0 ? -1 : 1, readingDirection, true, false)
    }
}

private struct PDFAnnotationEditor: View {
    @ObservedObject var controller: PDFReaderController
    let records: [ReaderAnnotation]
    let canDelete: Bool
    let onSave: ([ReaderAnnotation]) async -> Bool
    let onDelete: () async -> Bool
    let onCancel: () -> Void
    @State private var color: ReaderAnnotationColor
    @State private var comment: String
    @State private var isSaving = false
    @State private var failure = ""
    @State private var confirmingCancel = false
    init(controller: PDFReaderController, records: [ReaderAnnotation], canDelete: Bool, onSave: @escaping ([ReaderAnnotation]) async -> Bool, onDelete: @escaping () async -> Bool, onCancel: @escaping () -> Void) {
        self.controller = controller
        self.records = records; self.canDelete = canDelete; self.onSave = onSave; self.onDelete = onDelete; self.onCancel = onCancel
        _color = State(initialValue: records.first?.color ?? .yellow); _comment = State(initialValue: records.first?.comment ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(records.count > 1 ? "跨页/多段选择 · \(records.count) 处，一次保存" : "第 \(records.first?.page ?? 1) 页").font(.headline)
            ScrollView { VStack(alignment: .leading, spacing: 10) { ForEach(records) { record in Text(record.effectiveKind == .region ? "已框选原页区域，未自动识别其中的文字。" : record.text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } } }.frame(maxHeight: 160)
            Picker("高亮颜色", selection: $color) { ForEach(ReaderAnnotationColor.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().accessibilityLabel("高亮颜色").frame(maxWidth: .infinity)
            Text("批注").font(.subheadline)
            TextEditor(text: $comment).font(.body).frame(minHeight: 100).border(Color.secondary.opacity(0.2))
            if comment.count > 16_000 { Text("批注最多16000字。").font(.caption).foregroundStyle(.red) }
            HStack {
                if canDelete { Button("移入回收列表", role: .destructive) { Task { isSaving = true; let saved = await onDelete(); isSaving = false; if !saved { failure = "删除未完成，原批注保留。" } } }.disabled(isSaving || !controller.canEditAnnotations) }
                Spacer(); Button("取消") {
                    if comment != (records.first?.comment ?? "") || color != (records.first?.color ?? .yellow) { confirmingCancel = true }
                    else { onCancel() }
                }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button(isSaving ? "保存中…" : "保存") { Task { isSaving = true; let saved = await onSave(records.map { record in var copy = record; copy.color = color; copy.comment = comment; return copy }); isSaving = false; if !saved { failure = "保存未完成，已填写内容保留，请重试。" } } }.keyboardShortcut(.defaultAction).disabled(comment.count > 16_000 || isSaving || !controller.canEditAnnotations)
            }
            if !failure.isEmpty { Text(failure).font(.caption).foregroundStyle(.red) }
            Text("独立保存到书项目，原PDF不改写。").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 320, minHeight: 360)
        .alert("放弃尚未保存的批注？", isPresented: $confirmingCancel) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃并关闭", role: .destructive, action: onCancel)
        } message: { Text("关闭后会丢弃本次修改，原来已保存的批注保留。") }
    }
}

private struct PDFAnnotationList: View {
    @ObservedObject var controller: PDFReaderController
    let records: [ReaderAnnotation]
    let onLocate: (ReaderAnnotation) -> Void
    let onEdit: (ReaderAnnotation) -> Void
    let onTrash: (ReaderAnnotation, Bool) async -> Bool
    @State private var showTrashed = false
    @State private var savingID: String?
    @State private var failure = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("显示已删除批注", isOn: $showTrashed)
            if !failure.isEmpty { Text(failure).font(.caption).foregroundStyle(.red) }
            let visible = records.filter { showTrashed || $0.trashedAt == nil }.sorted { $0.page == $1.page ? $0.rangeLocation < $1.rangeLocation : $0.page < $1.page }
            if visible.isEmpty { ContentUnavailableView("暂无批注", systemImage: "highlighter", description: Text("选中原PDF文字后，使用工具栏高亮按钮保存。")) }
            ScrollView { LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(visible) { record in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text("第 \(record.page) 页").font(.caption.weight(.semibold)); Spacer(); if record.trashedAt != nil { Text("已删除").font(.caption).foregroundStyle(.secondary) } }
                        Text(record.effectiveKind == .region ? "区域批注" : String(record.text.prefix(180))).font(.callout).textSelection(.enabled)
                        if !record.comment.isEmpty { Text(String(record.comment.prefix(240))).font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button("定位原页") { onLocate(record) }
                            if record.trashedAt == nil { Button("编辑") { onEdit(record) }.disabled(!controller.canEditAnnotations); Button("删除", role: .destructive) { updateTrash(record, trashed: true) }.disabled(savingID != nil || !controller.canEditAnnotations) }
                            else { Button("恢复") { updateTrash(record, trashed: false) }.disabled(savingID != nil || !controller.canEditAnnotations) }
                        }.font(.caption)
                        Divider()
                    }
                }
            } }
        }.padding(18).frame(minWidth: 320, minHeight: 300)
    }
    private func updateTrash(_ record: ReaderAnnotation, trashed: Bool) {
        Task { savingID = record.id; let saved = await onTrash(record, trashed); savingID = nil; if !saved { failure = "操作未完成，原批注保留，请重试。" } }
    }
}

/// The find controls float above the PDF. AppKit owns the real Liquid Glass
/// content hierarchy on macOS 26; older systems keep the same panel geometry.
@MainActor private final class PDFReaderFloatingPanel: NSView {
    let panelContent = NSView()
    private var surface: NSView?
    private var reducedTransparency = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        panelContent.translatesAutoresizingMaskIntoConstraints = false
        installSurface()
        wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 18; shadow.shadowOffset = NSSize(width: 0, height: -5)
        self.shadow = shadow
    }
    func setReducedTransparency(_ reduced: Bool) {
        guard reducedTransparency != reduced else { return }
        reducedTransparency = reduced; installSurface()
    }
    private func installSurface() {
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView { glass.contentView = nil }
        panelContent.removeFromSuperview(); surface?.removeFromSuperview()
        let surface: NSView
        if reducedTransparency {
            let opaque = NSView(); opaque.wantsLayer = true
            opaque.layer?.cornerRadius = 22; opaque.layer?.masksToBounds = true
            opaque.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            opaque.layer?.borderWidth = 0.75
            opaque.layer?.borderColor = NSColor.separatorColor.cgColor
            opaque.addSubview(panelContent)
            NSLayoutConstraint.activate([
                panelContent.leadingAnchor.constraint(equalTo: opaque.leadingAnchor),
                panelContent.trailingAnchor.constraint(equalTo: opaque.trailingAnchor),
                panelContent.topAnchor.constraint(equalTo: opaque.topAnchor),
                panelContent.bottomAnchor.constraint(equalTo: opaque.bottomAnchor)
            ])
            surface = opaque
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular; glass.cornerRadius = 22
            glass.contentView = panelContent
            surface = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover; material.blendingMode = .withinWindow; material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 22; material.layer?.masksToBounds = true
            material.layer?.borderWidth = 0.75
            material.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
            material.addSubview(panelContent)
            NSLayoutConstraint.activate([
                panelContent.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                panelContent.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                panelContent.topAnchor.constraint(equalTo: material.topAnchor),
                panelContent.bottomAnchor.constraint(equalTo: material.bottomAnchor)
            ])
            surface = material
        }
        self.surface = surface
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if reducedTransparency {
            surface?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            surface?.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("PDFReaderFloatingPanel is created in code") }
}

/// PDFDocument search is asynchronous. Each search owns an immutable generation,
/// so callbacks from a canceled or replaced document cannot pollute new results.
private final class PDFReaderSearchDelegate: NSObject, PDFDocumentDelegate {
    private weak var owner: PDFReaderContainerView?
    private let generation: Int
    init(owner: PDFReaderContainerView, generation: Int) { self.owner = owner; self.generation = generation }
    func didMatchString(_ instance: PDFSelection) {
        let generation = generation
        DispatchQueue.main.async { [weak owner] in owner?.acceptMatch(instance, generation: generation) }
    }
    func documentDidEndDocumentFind(_ notification: Notification) {
        let generation = generation
        DispatchQueue.main.async { [weak owner] in owner?.finishSearch(generation: generation) }
    }
}

private struct PDFSourceDecorationHit: Sendable { let id: String; let rect: CGRect }
@MainActor private final class PDFSourceDecorationCanvas: NSView {
    var paint: ((CGRect) -> Void)?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        paint?(dirtyRect)
    }
}
