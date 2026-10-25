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
    var focusedDecorationID: String?
    var onSourceDecorationTap: ((String) -> Void)?
    var onSourceSelection: ((SourceReadingSelection?) -> Void)?
    var onSourceDecorationHover: ((SourceReadingHover?) -> Void)?
    var onVisiblePagesChange: (([Int]) -> Void)?
    var workspaceMemory: WorkspacePDFMemory?
    var memoryRevision = 0
    var onWorkspaceMemory: ((WorkspacePDFMemory) -> Void)?

    init(controller: PDFReaderController, url: URL, sourceHash: String = "", page: Int? = nil, navigationToken: Int = 0, password: String? = nil, annotations: [ReaderAnnotation] = [], canEditAnnotations: Bool = true, onPageChange: ((Int) -> Void)? = nil, onUnlock: ((String) -> Void)? = nil, onSaveAnnotations: (([ReaderAnnotation]) async -> Bool)? = nil, onTrashAnnotation: ((String, Bool) async -> Bool)? = nil, sourceDecorations: [SourceReadingDecoration] = [], sourceDecorationRevision: Int? = nil, focusedDecorationID: String? = nil, onSourceDecorationTap: ((String) -> Void)? = nil, onSourceSelection: ((SourceReadingSelection?) -> Void)? = nil, onSourceDecorationHover: ((SourceReadingHover?) -> Void)? = nil, onVisiblePagesChange: (([Int]) -> Void)? = nil, workspaceMemory: WorkspacePDFMemory? = nil, memoryRevision: Int = 0, onWorkspaceMemory: ((WorkspacePDFMemory) -> Void)? = nil) {
        self.controller = controller; self.url = url; self.sourceHash = sourceHash; self.password = password; self.annotations = annotations
        self.page = page; self.navigationToken = navigationToken; self.onPageChange = onPageChange
        self.onUnlock = onUnlock; self.onSaveAnnotations = onSaveAnnotations; self.onTrashAnnotation = onTrashAnnotation
        self.canEditAnnotations = canEditAnnotations
        self.sourceDecorations = sourceDecorations; self.sourceDecorationRevision = sourceDecorationRevision; self.focusedDecorationID = focusedDecorationID
        self.onSourceDecorationTap = onSourceDecorationTap; self.onSourceSelection = onSourceSelection
        self.onSourceDecorationHover = onSourceDecorationHover; self.onVisiblePagesChange = onVisiblePagesChange
        self.workspaceMemory = workspaceMemory; self.memoryRevision = memoryRevision; self.onWorkspaceMemory = onWorkspaceMemory
    }

    func makeNSView(context: Context) -> PDFReaderContainerView {
        let view = PDFReaderContainerView()
        view.setInteractionBlocked(interactionBlocked)
        view.setReducedTransparency(reduceTransparency)
        view.update(from: self)
        return view
    }

    func updateNSView(_ nsView: PDFReaderContainerView, context: Context) {
        nsView.setInteractionBlocked(interactionBlocked)
        nsView.setReducedTransparency(reduceTransparency)
        nsView.update(from: self)
    }

    static func dismantleNSView(_ nsView: PDFReaderContainerView, coordinator: ()) { nsView.shutdown() }
}

/// The PDF fills the reader; navigation is controlled by the window toolbar.
/// Search and annotation editing appear only when requested.
@MainActor final class PDFReaderContainerView: NSView, NSSearchFieldDelegate {
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
    private var sourceDecorationPage: Int?
    private var sourceDecorationFocusID: String?
    private struct SourceLineKey: Hashable, Sendable { let id: String; let line: Int }
    private struct SourceGeometry {
        let value: SourceReadingDecoration
        let page: Int
        let lines: [CGRect]
        let cost: Int
    }
    @MainActor private final class SourceGeometryPage {
        let text: String
        let byteCount: Int
        var ranges: [QuoteCacheKey: CachedQuoteRange] = [:]
        var rangeBytes = 0
        var geometry: [String: SourceGeometry] = [:]
        var geometryBytes = 0
        var hitBands = ReadingGeometryBands<SourceLineKey>()
        var paintBands = ReadingGeometryBands<SourceLineKey>()
        var cost: Int { byteCount + rangeBytes + geometryBytes }
        init(text: String, byteCount: Int) { self.text = text; self.byteCount = byteCount }
        func remember(_ value: SourceGeometry) {
            geometryBytes += value.cost - (geometry[value.value.id]?.cost ?? 0)
            geometry[value.value.id] = value
            for (line, rectangle) in value.lines.enumerated() {
                let key = SourceLineKey(id: value.value.id, line: line)
                hitBands.insert(key, rectangle: rectangle)
                if !value.value.passive { paintBands.insert(key, rectangle: rectangle) }
            }
        }
    }
    private var sourceGeometries: [String: SourceGeometry] = [:]
    private var sourceGeometryIDsByPage: [Int: [String]] = [:]
    private var sourceGeometryPages: [Int: SourceGeometryPage] = [:]
    private var sourceGeometryPageOrder: [Int] = []
    private var sourceDecorationTask: Task<Void, Never>?
    private var sourceDecorationGeneration = 0
    private var sourceDecorationRevision: Int?
    private var hoveredSourceID: String?
    private var sourceInputGeneration = 0
    private var renderedSourceInputGeneration = -1
    private var groupedSourceDecorations: [Int: [SourceReadingDecoration]] = [:]
    private var sourceAvailablePages: Set<Int> = []
    private var renderedSourceWindow: [Int] = []
    private let sourceCanvas = PDFSourceDecorationCanvas()
    private var sourcePointerMonitor: Any?
    private var sourcePress: (hit: PDFSourceDecorationHit, point: CGPoint)?
    private var lastSourcePointerTime = 0.0
    private var onVisiblePagesChange: (([Int]) -> Void)?
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
    private weak var quoteCachePage: PDFPage?
    private var quoteCacheText: NSString?
    private var quoteRangeCache: [QuoteCacheKey: CachedQuoteRange] = [:]
    private var quoteCacheBytes = 0
    private var onSourceDecorationTap: ((String) -> Void)?
    private var onSourceSelection: ((SourceReadingSelection?) -> Void)?
    private var onSourceDecorationHover: ((SourceReadingHover?) -> Void)?
    private var pendingQuote: (page: Int, quote: String, prefix: String?, suffix: String?)?
    private var isFocusingQuote = false
    private var pendingWorkspaceMemory: WorkspacePDFMemory?
    private var appliedMemoryRevision: Int?
    private var memoryCallback: ((WorkspacePDFMemory) -> Void)?
    private var memoryCaptureTask: DispatchWorkItem?
    private weak var observedClip: NSClipView?
    private var sourceSelectionObservation = 0
    private var annotationPanel: NSPanel?
    private var editingAnnotationSheet = false
    private var showingAnnotationList = false
    private enum FitMode: Int { case page, width, actual, custom }
    private let pdfView = AnnotationPDFView()
    private let thumbnails = PDFThumbnailView()
    private let thumbnailScroll = NSScrollView()
    private let thumbnailPanel = PDFReaderFloatingPanel()
    private var thumbnailTop: NSLayoutConstraint?
    private let contentStack = NSStackView()
    private let header = PDFReaderFloatingPanel()
    private let searchField = NSSearchField()
    private let resultLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var searchRow = NSStackView()
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
        if blocked { resetPageGesture() }
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
        return belongsToPDF || responder === searchField || (searchEditor != nil && responder === searchEditor)
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
        pdfView.onSourcePointerLeft = { [weak self] in self?.reportSourceHover(nil) }
        sourceCanvas.wantsLayer = true
        sourceCanvas.layer?.backgroundColor = NSColor.clear.cgColor
        sourceCanvas.paint = { [weak self] dirty in self?.drawSourceDecorations(in: dirty) }
        pdfView.onAnnotationTap = { [weak self] annotation in self?.openAnnotation(annotation) }
        pdfView.autoScales = false
        readingDirection = defaultReadingDirection
        pdfView.displayMode = defaultContinuous ? .singlePageContinuous : .singlePage
        pdfView.displayDirection = readingDirection == .vertical ? .vertical : .horizontal
        pdfView.readingDirection = readingDirection
        pdfView.displayBox = .cropBox
        pdfView.displaysPageBreaks = true
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

        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: 86, height: 112)
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.allowsDragging = false
        thumbnails.allowsMultipleSelection = false
        thumbnails.labelFont = .systemFont(ofSize: 10)
        thumbnails.backgroundColor = .clear
        thumbnailScroll.documentView = thumbnails
        thumbnailScroll.hasVerticalScroller = true
        thumbnailScroll.hasHorizontalScroller = false
        thumbnailScroll.autohidesScrollers = true
        thumbnailScroll.drawsBackground = false
        thumbnailScroll.translatesAutoresizingMaskIntoConstraints = false
        thumbnailPanel.isHidden = true
        let thumbnailTitle = NSTextField(labelWithString: "缩略图")
        thumbnailTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        let thumbnailHeader = row([thumbnailTitle, symbolButton("xmark", "关闭缩略图", #selector(hideThumbnails))])
        let thumbnailBody = NSStackView(views: [thumbnailHeader, thumbnailScroll])
        thumbnailBody.orientation = .vertical; thumbnailBody.alignment = .leading; thumbnailBody.spacing = 4
        thumbnailHeader.setContentHuggingPriority(.required, for: .vertical)
        thumbnailScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        thumbnailBody.translatesAutoresizingMaskIntoConstraints = false
        thumbnailPanel.panelContent.addSubview(thumbnailBody)
        NSLayoutConstraint.activate([
            thumbnailBody.leadingAnchor.constraint(equalTo: thumbnailPanel.panelContent.leadingAnchor, constant: 10),
            thumbnailBody.trailingAnchor.constraint(equalTo: thumbnailPanel.panelContent.trailingAnchor, constant: -10),
            thumbnailBody.topAnchor.constraint(equalTo: thumbnailPanel.panelContent.topAnchor, constant: 8),
            thumbnailBody.bottomAnchor.constraint(equalTo: thumbnailPanel.panelContent.bottomAnchor, constant: -10),
            thumbnailHeader.widthAnchor.constraint(equalTo: thumbnailBody.widthAnchor),
            thumbnailScroll.widthAnchor.constraint(equalTo: thumbnailBody.widthAnchor)
        ])

        contentStack.orientation = .horizontal
        contentStack.alignment = .top
        contentStack.distribution = .fill
        contentStack.spacing = 0
        contentStack.detachesHiddenViews = true
        contentStack.addArrangedSubview(pdfView)
        pdfView.heightAnchor.constraint(equalTo: contentStack.heightAnchor).isActive = true
        pdfView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        searchField.placeholderString = "搜索 PDF 文字 · 回车查找"
        searchField.controlSize = .regular
        searchField.font = .systemFont(ofSize: 15)
        searchField.setAccessibilityLabel("搜索 PDF 文字")
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
        searchRow = row([searchField, resultLabel, previousMatchButton, nextMatchButton, close])
        searchRow.isHidden = true
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = true
        // Navigation/zoom controls live in the window toolbar. Only explicitly opened search/status uses this row.
        let toolbar = NSStackView(views: [searchRow, statusLabel])
        toolbar.orientation = .vertical
        toolbar.alignment = .leading
        toolbar.spacing = 6
        toolbar.detachesHiddenViews = true
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        header.panelContent.addSubview(toolbar)
        searchRow.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: header.panelContent.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: header.panelContent.trailingAnchor, constant: -12),
            toolbar.topAnchor.constraint(equalTo: header.panelContent.topAnchor, constant: 10),
            toolbar.bottomAnchor.constraint(equalTo: header.panelContent.bottomAnchor, constant: -10)
        ])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false; header.isHidden = true
        thumbnailPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack); addSubview(sourceCanvas); addSubview(thumbnailPanel); addSubview(header)
        let thumbnailTop = thumbnailPanel.topAnchor.constraint(equalTo: topAnchor, constant: 76)
        self.thumbnailTop = thumbnailTop
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor), contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor), contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            header.centerXAnchor.constraint(equalTo: centerXAnchor),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 76),
            header.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
            thumbnailPanel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            thumbnailTop,
            thumbnailPanel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -88),
            thumbnailPanel.widthAnchor.constraint(equalToConstant: 156)
        ])
        let preferredSearchWidth = header.widthAnchor.constraint(equalToConstant: 500)
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
        let url = input.url, requestedPage = input.page, navigationToken = input.navigationToken
        let sourceChanged = sourceHash != input.sourceHash
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
        let sourceDecorationsChanged = sourceChanged || input.url.standardizedFileURL != loadedURL || sourceDecorationPage != requestedPage || (input.sourceDecorationRevision.map { $0 != sourceDecorationRevision }
            ?? (sourceDecorations != input.sourceDecorations))
        if sourceDecorationsChanged {
            sourceDecorations = Array(input.sourceDecorations.prefix(12_000)); sourceInputGeneration &+= 1
            groupedSourceDecorations = Dictionary(grouping: sourceDecorations, by: { $0.page ?? requestedPage ?? 1 })
            sourceAvailablePages = Set(groupedSourceDecorations.keys)
        }
        sourceDecorationRevision = input.sourceDecorationRevision; sourceDecorationPage = requestedPage
        sourceHash = input.sourceHash; sessionPassword = input.password
        canEditAnnotations = input.canEditAnnotations
        let annotationsChanged = input.annotations != savedAnnotations
        savedAnnotations = input.annotations
        let canonical = url.standardizedFileURL
        if canonical != loadedURL || sourceChanged || appliedMemoryRevision != input.memoryRevision {
            // Capture against the old callback before rebinding to another book.
            if canonical != loadedURL || sourceChanged { captureWorkspaceMemory() }
            memoryCaptureTask?.cancel(); memoryCaptureTask = nil
            appliedMemoryRevision = input.memoryRevision
            pendingWorkspaceMemory = input.workspaceMemory?.isValid == true ? input.workspaceMemory : nil
            applyWorkspaceDisplayPreferences()
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
        if sourceDecorationsChanged { renderSourceDecorations() }
        if sourceDecorationFocusID != input.focusedDecorationID {
            sourceDecorationFocusID = input.focusedDecorationID
            if let id = input.focusedDecorationID, let decoration = sourceDecorations.first(where: { $0.id == id }), let page = decoration.page ?? requestedPage {
                focusQuote(on: page, quote: decoration.quote, prefix: decoration.prefix, suffix: decoration.suffix)
            }
        }
        refreshControls()
        if pendingNavigation == nil, pendingWorkspaceMemory != nil, document?.isLocked == false { restoreWorkspaceDestination() }
    }

    private func load(_ url: URL) {
        resetPageGesture(); observedClip = nil
        if !editingAnnotationSheet { closeAnnotationPanel() }
        pdfView.cancelRegionSelection()
        clearSourceDecorations(); resetQuoteCache(); sourceDecorationFocusID = nil; pendingQuote = nil
        invalidateNavigation(); installingDocument = true
        defer { installingDocument = false }
        allowsSearchAutoNavigation = false; lastCallback = nil
        dismissSearch(restoreFocus: false)
        document?.delegate = nil
        pdfView.document = nil; document = nil
        if securityScoped { loadedURL?.stopAccessingSecurityScopedResource() }
        securityScoped = false; loadedURL = url
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
        thumbnails.pdfView = pdfView
        layoutThumbnails()
        let desired = sourcePage ?? 1
        navigate(to: (1...document.pageCount).contains(desired) ? desired : 1, notifyParent: false)
        if let id = sourceDecorationFocusID, let decoration = sourceDecorations.first(where: { $0.id == id }) {
            focusQuote(on: desired, quote: decoration.quote, prefix: decoration.prefix, suffix: decoration.suffix)
        }
        installingDocument = false
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
        invalidateNavigation()
        setStatus("")
        let request = navigationRequestID, generation = documentGeneration
        pendingNavigation = (request, number, notifyParent, landing)
        position(at: target, landing: landing)
        DispatchQueue.main.async { [weak self] in self?.settleNavigation(request, generation: generation, attempt: 0) }
    }

    private func invalidateNavigation() {
        navigationRequestID &+= 1; pageObservationID &+= 1; pendingNavigation = nil; pendingQuote = nil
    }

    private func position(at page: PDFPage, landing: PageLanding = .start) {
        pdfView.go(to: page)
        // A display-mode change rebuilds PDFKit's document view. Resolve that
        // layout before fitting or a destination may use the previous page's
        // geometry and retain its old scroll offset in single-page mode.
        pdfView.layoutDocumentView()
        applyFit()
        pdfView.layoutDocumentView()
        let box = page.bounds(for: pdfView.displayBox)
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
        // PDFKit may finish document/scale layout on the next run-loop turn.
        // An older attempt cannot move or notify after a newer request arrives.
        if attempt == 0 || currentPageNumber != pending.page {
            guard attempt < 3, let target = document?.page(at: pending.page - 1) else {
                pendingNavigation = nil
                setStatus("PDF 定位未完成，请重新选择页码。")
                return
            }
            position(at: target, landing: pending.landing)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.settleNavigation(request, generation: generation, attempt: attempt + 1) }
            return
        }
        pendingNavigation = nil; refreshControls()
        restoreWorkspaceDestination()
        if let quote = pendingQuote, quote.page == pending.page {
            pendingQuote = nil; applyQuoteFocus(on: quote.page, quote: quote.quote, prefix: quote.prefix, suffix: quote.suffix)
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
        guard let content = owner.contentView else { return false }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = content.hitTest(point), hit === pdfView || hit.isDescendant(of: pdfView) else { return false }
        // A scrollbar is a native control rather than a page-turn surface.
        return !(hit is NSScroller)
    }
    private func consumePageScroll(_ event: NSEvent) -> Bool {
        guard pdfView.displayMode == .singlePage, !interactionBlocked,
              !isHiddenOrHasHiddenAncestor, !installingDocument,
              let owner = window, event.window === owner, owner.isKeyWindow,
              owner.attachedSheet == nil, NSApp.modalWindow == nil,
              !editingAnnotationSheet, document?.isLocked == false else {
            resetPageGesture(); return false
        }
        let phase = Self.gesturePhase(event.phase), momentum = Self.gesturePhase(event.momentumPhase)
        let eligible = ownsPDFHit(event, in: owner)
        guard pageGestureOwnership.accepts(phase: phase, momentum: momentum, isEligible: eligible) else { return false }
        // A field editor elsewhere in this window keeps its input. PDF-owned
        // text selection is not an editable field and remains scrollable.
        if let editor = owner.firstResponder as? NSTextView, editor.isEditable, !editor.isDescendant(of: pdfView) {
            pageTurnPolicy.reset(); return true
        }
        // A gesture-owned turn may still be completing PDFKit layout. Preserve
        // its one-turn latch and swallow the tail until that navigation settles.
        if pendingNavigation != nil { return true }
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
        let rect = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page), tolerance: CGFloat = 3
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

    override func layout() {
        super.layout()
        sourceCanvas.frame = bounds; sourceCanvas.needsDisplay = true
        scheduleVisiblePages()
        let chrome = visibleChromeFrame(header)
        let nextTop: CGFloat = chrome.isEmpty ? 76 : max(76, chrome.maxY + 12)
        if let thumbnailTop, abs(thumbnailTop.constant - nextTop) > 0.5 { thumbnailTop.constant = nextTop }
        let size = pdfView.bounds.size
        if abs(size.width - lastViewportSize.width) > 0.5 || abs(size.height - lastViewportSize.height) > 0.5 {
            lastViewportSize = size; layoutThumbnails(); applyFit()
            if let pending = pendingNavigation, size.width > 40, size.height > 40 {
                let request = pending.id, generation = documentGeneration
                DispatchQueue.main.async { [weak self] in self?.settleNavigation(request, generation: generation, attempt: 0) }
            }
        }
        refreshControls()
    }

    private func applyFit() {
        guard fitMode != .custom, let page = pdfView.currentPage, pdfView.bounds.width > 40, pdfView.bounds.height > 40 else { return }
        var size = page.bounds(for: pdfView.displayBox).size
        if abs(page.rotation) % 180 == 90 { size = NSSize(width: size.height, height: size.width) }
        guard size.width > 0, size.height > 0 else { return }
        let width = max(1, pdfView.bounds.width - 32) / size.width
        let height = max(1, pdfView.bounds.height - 32) / size.height
        let scale: CGFloat = fitMode == .actual ? 1 : (fitMode == .width ? width : min(width, height))
        pdfView.autoScales = false
        let clamped = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, scale))
        isApplyingFit = true
        if abs(pdfView.scaleFactor - clamped) > 0.001 { pdfView.scaleFactor = clamped }
        isApplyingFit = false
        refreshControls()
    }

    private func layoutThumbnails() {
        let height = max(thumbnailScroll.contentSize.height, CGFloat(document?.pageCount ?? 0) * 146 + 20)
        thumbnails.frame = NSRect(x: 0, y: 0, width: max(100, thumbnailScroll.contentSize.width), height: height)
    }

    @objc private func pageChanged(_ notification: Notification) {
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
        if !isApplyingFit, !installingDocument, pendingNavigation == nil, pendingWorkspaceMemory == nil { fitMode = .custom }
        refreshControls(); sourceCanvas.needsDisplay = true; scheduleWorkspaceCapture()
    }

    @objc private func pdfViewportScrolled(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView, clip === observedClip else { return }
        sourceCanvas.needsDisplay = true; scheduleVisiblePages(); scheduleWorkspaceCapture()
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
        resetPageGesture()
        readingDirection = saved.map { $0.direction ?? .vertical } ?? defaultReadingDirection
        pdfView.readingDirection = readingDirection
        pdfView.displayDirection = readingDirection == .vertical ? .vertical : .horizontal
        switch saved?.fitMode { case "page": fitMode = .page; case "actual": fitMode = .actual; case "custom": fitMode = .custom; default: fitMode = .width }
        let continuous = saved?.continuous ?? defaultContinuous
        pdfView.displayMode = continuous ? .singlePageContinuous : .singlePage
        if saved == nil, !continuous { fitMode = .page }
        thumbnailPanel.isHidden = !(saved?.thumbnails ?? false)
        if fitMode == .custom, let scale = saved?.scale { pdfView.scaleFactor = CGFloat(scale) }
    }
    private func restoreWorkspaceDestination() {
        observePDFViewport()
        guard let saved = pendingWorkspaceMemory else { scheduleWorkspaceCapture(); return }
        pendingWorkspaceMemory = nil
        guard let page = document?.page(at: saved.page - 1), currentPageNumber == saved.page else { return }
        if fitMode == .custom { pdfView.scaleFactor = CGFloat(saved.scale) } else { applyFit() }
        if let location = saved.location {
            let box = page.bounds(for: pdfView.displayBox)
            let point = CGPoint(x: box.minX + min(1, max(0, location.x)) * box.width, y: box.minY + min(1, max(0, location.y)) * box.height)
            pdfView.go(to: PDFDestination(page: page, at: point))
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
    private func captureWorkspaceMemory() {
        guard !installingDocument, pendingNavigation == nil, pendingWorkspaceMemory == nil,
              let document, !document.isLocked, let destination = pdfView.currentDestination, let page = destination.page else { return }
        let index = document.index(for: page), box = page.bounds(for: pdfView.displayBox)
        guard index != NSNotFound, box.width > 0, box.height > 0 else { return }
        let location = WorkspacePoint(x: Double((destination.point.x - box.minX) / box.width), y: Double((destination.point.y - box.minY) / box.height))
        let mode: String
        switch fitMode { case .page: mode = "page"; case .width: mode = "width"; case .actual: mode = "actual"; case .custom: mode = "custom" }
        let memory = WorkspacePDFMemory(page: index + 1, location: location, scale: Double(pdfView.scaleFactor), fitMode: mode, continuous: pdfView.displayMode == .singlePageContinuous, thumbnails: !thumbnailPanel.isHidden, direction: readingDirection)
        if memory.isValid { memoryCallback?(memory) }
    }

    private func refreshControls() {
        let ready = document != nil && document?.isLocked == false && (document?.pageCount ?? 0) > 0
        let number = currentPageNumber ?? 1, count = ready ? document?.pageCount ?? 0 : 0
        previousMatchButton.isEnabled = !matches.isEmpty; nextMatchButton.isEnabled = !matches.isEmpty
        let zoom = Int((pdfView.scaleFactor * 100).rounded()), selected = !(pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let searchVisible = !searchRow.isHidden
        let continuous = pdfView.displayMode == .singlePageContinuous, thumbnailsVisible = !thumbnailPanel.isHidden
        let mode: String
        switch fitMode { case .page: mode = "page"; case .width: mode = "width"; case .actual: mode = "actual"; case .custom: mode = "custom" }
        let searchFrame = visibleChromeFrame(header), thumbnailFrame = visibleChromeFrame(thumbnailPanel)
        let snapshot = ControlSnapshot(controllerID: controller.map { ObjectIdentifier($0) }, generation: documentGeneration,
            page: number, pageCount: count, zoom: zoom, ready: ready, selected: ready && selected, canEdit: canEditAnnotations,
            searchVisible: searchVisible, continuous: continuous, direction: readingDirection, thumbnailsVisible: thumbnailsVisible, fitMode: mode,
            searchFrame: searchFrame, thumbnailFrame: thumbnailFrame)
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
            chromeFrame: snapshot.searchFrame, thumbnailFrame: snapshot.thumbnailFrame)
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
        startSearch(query, generation: searchGeneration, attempts: 0)
    }

    private func startSearch(_ query: String, generation: Int, attempts: Int) {
        guard generation == searchGeneration, let document, !document.isLocked else { return }
        if document.isFinding {
            guard attempts < 40 else { searching = false; setStatus("上一次搜索仍在结束，请稍后重新查找。"); updateSearchDisplay(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.startSearch(query, generation: generation, attempts: attempts + 1) }
            return
        }
        let delegate = PDFReaderSearchDelegate(owner: self, generation: generation)
        searchDelegate = delegate; document.delegate = delegate
        document.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    private func clearSearchState() {
        searchGeneration += 1
        document?.delegate = nil; document?.cancelFindString(); searchDelegate = nil
        matches = []; matchIndex = -1; searching = false; searchLimited = false
        highlightUpdateScheduled = false; allowsSearchAutoNavigation = false
        pdfView.highlightedSelections = nil; pdfView.clearSelection()
        resultLabel.stringValue = ""; refreshControls()
    }

    func acceptMatch(_ selection: PDFSelection, generation: Int) {
        guard generation == searchGeneration, searching,
              selection.pages.contains(where: { $0.document === document }) else { return }
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

    private func updateHighlights() { pdfView.highlightedSelections = matches; updateSearchDisplay(); refreshControls() }
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
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === searchField else { return }
        // Editing a query invalidates results immediately, even though the next
        // search intentionally waits for Return. Old matches must not keep moving
        // the reader while the user is typing a different query.
        clearSearchState(); setStatus("")
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !interactionBlocked, control === searchField, commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        closeSearch(); return true
    }

    private func setStatus(_ text: String) { statusLabel.stringValue = text; statusLabel.toolTip = text; statusLabel.isHidden = text.isEmpty; header.isHidden = searchRow.isHidden && statusLabel.isHidden }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 8
        return stack
    }
    private func flexibleSpace() -> NSView { let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view }
    private func symbolButton(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .circular; button.controlSize = .regular; button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = title; button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func shutdown() {
        pendingControlSnapshot = nil; lastControlSnapshot = nil
        memoryCaptureTask?.cancel(); captureWorkspaceMemory(); memoryCallback = nil; observedClip = nil
        invalidateNavigation(); installingDocument = true
        removeSearchEscapeMonitor()
        removePageScrollMonitor(); removeSourcePointerMonitor(); resetPageGesture()
        searchGeneration += 1; document?.delegate = nil; document?.cancelFindString(); searchDelegate = nil
        NotificationCenter.default.removeObserver(self)
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
        switch command {
        case .prev: previousPage()
        case .next: nextPage()
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
        case .toggleContinuous: changePDFDisplayMode(pdfView.displayMode == .singlePageContinuous ? .singlePage : .singlePageContinuous)
        case .setContinuous(let continuous): changePDFDisplayMode(continuous ? .singlePageContinuous : .singlePage)
        case .setDirection(let direction): changePDFDirection(direction)
        case .createHighlight: createHighlight()
        case .createRegion:
            guard canEditAnnotations else { setStatus("当前任务运行中，请稍后添加区域批注。"); return }
            guard document != nil, document?.isLocked == false else { return }
            pdfView.armRegionSelection(); window?.makeFirstResponder(pdfView)
            setStatus("拖动框选同一页内的区域，松开后填写批注；按Esc取消。")
        case .showAnnotations: showAnnotations()
        case .focusQuote(let page, let quote): focusQuote(on: page, quote: quote)
        }
        scheduleWorkspaceCapture()
    }

    @objc private func selectionChanged(_ notification: Notification) {
        refreshControls()
        guard !isFocusingQuote else { return }
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
        quoteCachePage = nil; quoteCacheText = nil
        quoteRangeCache.removeAll(keepingCapacity: true); quoteCacheBytes = 0
    }

    private func nativeQuoteRange(_ quote: String, prefix: String? = nil, suffix: String? = nil,
                                  on page: PDFPage, pageText: NSString? = nil) -> NSRange? {
        guard !quote.isEmpty, quote.utf16.count <= 32_768,
              (prefix?.utf8.count ?? 0) <= 4_096, (suffix?.utf8.count ?? 0) <= 4_096 else { return nil }
        if quoteCachePage !== page { resetQuoteCache(); quoteCachePage = page }
        let key = QuoteCacheKey(quote: Data(quote.utf8), prefix: prefix.map { Data($0.utf8) }, suffix: suffix.map { Data($0.utf8) })
        if let cached = quoteRangeCache[key] { return cached.range }
        guard let text = pageText ?? quoteCacheText ?? page.string.map({ $0 as NSString }) else { return nil }
        // Retain at most one ordinary page, 256 results and 1 MiB of query
        // keys. An unusually large page still matches without retaining it.
        if text.length <= 2_000_000 { quoteCacheText = text }
        let range = Self.findNativeQuoteRange(quote, prefix: prefix, suffix: suffix, text: text)
        if key.byteCount <= 1_048_576 {
            if quoteRangeCache.count >= 256 || quoteCacheBytes + key.byteCount > 1_048_576 {
                quoteRangeCache.removeAll(keepingCapacity: true); quoteCacheBytes = 0
            }
            quoteRangeCache[key] = CachedQuoteRange(range: range); quoteCacheBytes += key.byteCount
        }
        return range
    }

    nonisolated private static func findNativeQuoteRange(_ quote: String, prefix: String?, suffix: String?, text: NSString) -> NSRange? {
        var start = 0
        var candidate: NSRange?
        while start < text.length {
            let range = text.range(of: quote, options: [.literal], range: NSRange(location: start, length: text.length - start))
            guard range.location != NSNotFound else { break }
            // Advance one UTF-16 unit to include overlapping matches. Imported
            // unit offsets never enter this native page search.
            start = range.location + 1
            guard text.substring(with: range).utf8.elementsEqual(quote.utf8) else { continue }
            if let prefix, !prefix.isEmpty {
                let length = prefix.utf16.count
                guard range.location >= length,
                      text.substring(with: NSRange(location: range.location - length, length: length)).utf8.elementsEqual(prefix.utf8) else { continue }
            }
            if let suffix, !suffix.isEmpty {
                let length = suffix.utf16.count
                guard NSMaxRange(range) <= text.length - length,
                      text.substring(with: NSRange(location: NSMaxRange(range), length: length)).utf8.elementsEqual(suffix.utf8) else { continue }
            }
            guard candidate == nil else { return nil }
            candidate = range
        }
        return candidate
    }

    private func focusQuote(on number: Int, quote: String, prefix: String? = nil, suffix: String? = nil) {
        guard let document, !document.isLocked, (1...document.pageCount).contains(number) else { return }
        navigate(to: number)
        // Set after navigate(), which invalidates every older navigation target.
        pendingQuote = (number, quote, prefix, suffix)
    }

    private func applyQuoteFocus(on number: Int, quote: String, prefix: String? = nil, suffix: String? = nil) {
        guard let page = document?.page(at: number - 1), let range = nativeQuoteRange(quote, prefix: prefix, suffix: suffix, on: page),
              let selection = page.selection(for: range) else {
            setStatus("已定位到原页；原生文字无法唯一匹配此引文，未推测词位。扫描页请对照原页与识别稿。"); return
        }
        isFocusingQuote = true
        selection.color = NSColor.systemTeal.withAlphaComponent(0.3)
        pdfView.setCurrentSelection(selection, animate: !reduceReadingMotion)
        pdfView.go(to: selection)
        isFocusingQuote = false; refreshControls()
    }

    private func clearSourceDecorations() {
        sourceDecorationGeneration &+= 1; sourceDecorationTask?.cancel(); sourceDecorationTask = nil
        sourceGeometries = [:]; sourceGeometryIDsByPage = [:]; sourceGeometryPages = [:]; sourceGeometryPageOrder = []
        renderedSourceInputGeneration = -1; renderedSourceWindow = []; lastVisiblePages = []
        hoveredSourceID = nil; sourcePress = nil; onSourceDecorationHover?(nil); sourceCanvas.needsDisplay = true
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
            if pages != self.lastVisiblePages {
                self.lastVisiblePages = pages; self.onVisiblePagesChange?(pages); self.renderSourceDecorations()
            }
        }
    }
    private func renderSourceDecorations() {
        guard let document, !document.isLocked else { clearSourceDecorations(); return }
        let current = currentPageNumber ?? sourceDecorationPage ?? 1
        let window = ReadingSentenceAnchors.pageWindow(current: current, visible: lastVisiblePages, available: sourceAvailablePages)
        guard renderedSourceInputGeneration != sourceInputGeneration || renderedSourceWindow != window else { return }
        sourceDecorationGeneration &+= 1; sourceDecorationTask?.cancel(); sourceDecorationTask = nil
        renderedSourceInputGeneration = sourceInputGeneration; renderedSourceWindow = window
        let generation = sourceDecorationGeneration, documentID = documentGeneration
        let desired = window.flatMap { groupedSourceDecorations[$0] ?? [] }
        let desiredIDs = Set(desired.map(\.id))
        sourceGeometries = sourceGeometries.filter { desiredIDs.contains($0.key) }
        let grouped = groupedSourceDecorations
        sourceGeometryIDsByPage = grouped.mapValues { $0.map(\.id) }
        sourceDecorationTask = Task { [weak self] in
            guard let self else { return }
            for number in window {
                guard !Task.isCancelled, self.documentGeneration == documentID, self.sourceDecorationGeneration == generation,
                      let page = document.page(at: number - 1) else { return }
                let cache: SourceGeometryPage
                if let saved = self.sourceGeometryPages[number] { cache = saved }
                else {
                    guard let text = page.string, text.utf8.count <= 8_000_000 else { continue }
                    cache = SourceGeometryPage(text: text, byteCount: text.utf8.count)
                }
                self.sourceGeometryPageOrder.removeAll { $0 == number }; self.sourceGeometryPageOrder.append(number)
                let values = grouped[number] ?? []
                var additions: [SourceReadingDecoration] = []
                for value in values {
                    if let geometry = cache.geometry[value.id], geometry.value == value { self.sourceGeometries[value.id] = geometry }
                    else { additions.append(value); self.sourceGeometries.removeValue(forKey: value.id) }
                }
                self.sourceCanvas.needsDisplay = true
                let text = cache.text, saved = cache.ranges, matchingAdditions = additions
                let calculation = Task.detached(priority: .userInitiated) { () -> [String: CachedQuoteRange] in
                    let interval = pdfDecorationSignposter.beginInterval("MatchPageQuotes")
                    defer { pdfDecorationSignposter.endInterval("MatchPageQuotes", interval) }
                    let source = text as NSString
                    var ranges: [String: CachedQuoteRange] = [:]
                    for value in matchingAdditions {
                        guard !Task.isCancelled else { break }
                        guard !value.quote.isEmpty, value.quote.utf16.count <= 32_768,
                              (value.prefix?.utf8.count ?? 0) <= 4_096, (value.suffix?.utf8.count ?? 0) <= 4_096 else { continue }
                        let key = QuoteCacheKey(quote: Data(value.quote.utf8), prefix: value.prefix.map { Data($0.utf8) }, suffix: value.suffix.map { Data($0.utf8) })
                        ranges[value.id] = saved[key] ?? CachedQuoteRange(range: Self.findNativeQuoteRange(value.quote, prefix: value.prefix, suffix: value.suffix, text: source))
                    }
                    return ranges
                }
                let ranges = await withTaskCancellationHandler(operation: { await calculation.value }, onCancel: { calculation.cancel() })
                guard !Task.isCancelled, self.documentGeneration == documentID, self.sourceDecorationGeneration == generation else { return }
                var began = ProcessInfo.processInfo.systemUptime, count = 0
                var interval = pdfDecorationSignposter.beginInterval("PrepareGeometryBatch")
                for value in additions {
                    guard !Task.isCancelled, self.documentGeneration == documentID, self.sourceDecorationGeneration == generation else {
                        pdfDecorationSignposter.endInterval("PrepareGeometryBatch", interval); return
                    }
                    let key = QuoteCacheKey(quote: Data(value.quote.utf8), prefix: value.prefix.map { Data($0.utf8) }, suffix: value.suffix.map { Data($0.utf8) })
                    let matched = ranges[value.id]
                    if let matched, key.byteCount <= 1_048_576,
                       cache.ranges[key] != nil || (cache.ranges.count < 2000 && cache.rangeBytes + key.byteCount <= 1_048_576) {
                        if cache.ranges[key] == nil { cache.rangeBytes += key.byteCount }; cache.ranges[key] = matched
                    }
                    var lines: [CGRect] = []
                    if let range = matched?.range, let selection = page.selection(for: range) {
                        for line in selection.selectionsByLine() {
                            let rect = line.bounds(for: page).intersection(page.bounds(for: .cropBox))
                            if !rect.isNull && !rect.isEmpty && [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite) { lines.append(rect) }
                            count += 1
                            if count >= 24 || ProcessInfo.processInfo.systemUptime - began >= 0.003 {
                                pdfDecorationSignposter.endInterval("PrepareGeometryBatch", interval)
                                do { try await Task.sleep(nanoseconds: 1_000_000) } catch { return }
                                guard !Task.isCancelled, self.documentGeneration == documentID, self.sourceDecorationGeneration == generation else { return }
                                began = ProcessInfo.processInfo.systemUptime; count = 0
                                interval = pdfDecorationSignposter.beginInterval("PrepareGeometryBatch")
                            }
                        }
                    }
                    let cost = value.quote.utf8.count + (value.prefix?.utf8.count ?? 0) + (value.suffix?.utf8.count ?? 0) + lines.count * 64 + 256
                    let geometry = SourceGeometry(value: value, page: number, lines: lines, cost: cost)
                    cache.remember(geometry); self.sourceGeometries[value.id] = geometry
                    self.sourceCanvas.needsDisplay = true; count += 1
                    if count >= 12 || ProcessInfo.processInfo.systemUptime - began >= 0.003 {
                        self.sourceGeometryPages[number] = cache
                        pdfDecorationSignposter.endInterval("PrepareGeometryBatch", interval)
                        do { try await Task.sleep(nanoseconds: 1_000_000) } catch { return }
                        guard !Task.isCancelled, self.documentGeneration == documentID, self.sourceDecorationGeneration == generation else { return }
                        began = ProcessInfo.processInfo.systemUptime; count = 0
                        interval = pdfDecorationSignposter.beginInterval("PrepareGeometryBatch")
                    }
                }
                pdfDecorationSignposter.endInterval("PrepareGeometryBatch", interval)
                self.sourceGeometryPages[number] = cache
                while self.sourceGeometryPageOrder.count > 16 || self.sourceGeometryPages.values.reduce(0, { $0 + $1.cost }) > 12_582_912 {
                    // In-use visible geometry must not disappear merely because
                    // a dense page exceeds the idle-cache target. Only evict
                    // pages outside this small, already bounded active window.
                    guard let unused = self.sourceGeometryPageOrder.firstIndex(where: { !window.contains($0) }) else { break }
                    self.sourceGeometryPages.removeValue(forKey: self.sourceGeometryPageOrder.remove(at: unused))
                }
            }
            if self.sourceDecorationGeneration == generation { self.sourceDecorationTask = nil }
        }
    }
    private func drawSourceDecorations(in dirty: CGRect) {
        guard let document, !document.isLocked else { return }
        for number in lastVisiblePages {
            guard let page = document.page(at: number - 1), let cache = sourceGeometryPages[number] else { continue }
            let dirtyInPDF = sourceCanvas.convert(dirty, to: pdfView)
            let visible = pdfView.convert(dirtyInPDF.intersection(pdfView.bounds), to: page).intersection(page.bounds(for: .cropBox))
            guard !visible.isEmpty, !visible.isNull else { continue }
            var candidates: Set<SourceLineKey>
            if cache.paintBands.requiresFallback {
                candidates = Set((sourceGeometryIDsByPage[number] ?? []).flatMap { id in
                    guard let geometry = sourceGeometries[id], !geometry.value.passive else { return [SourceLineKey]() }
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
                guard active || !geometry.value.passive else { continue }
                let rect = geometry.lines[key.line]
                guard rect.intersects(visible) else { continue }
                NSColor.systemTeal.withAlphaComponent(active ? 0.95 : 0.38).setStroke()
                let from = sourceCanvas.convert(pdfView.convert(CGPoint(x: rect.minX, y: rect.minY + 1), from: page), from: pdfView)
                let to = sourceCanvas.convert(pdfView.convert(CGPoint(x: rect.maxX, y: rect.minY + 1), from: page), from: pdfView)
                let path = NSBezierPath(); path.lineWidth = active ? 1.6 : 1
                path.move(to: from); path.line(to: to); path.stroke()
            }
        }
    }
    private func sourceHit(at point: CGPoint, preferTerm: Bool) -> PDFSourceDecorationHit? {
        guard let document, let page = pdfView.page(for: point, nearest: false) else { return nil }
        let index = document.index(for: page), local = pdfView.convert(point, to: page)
        guard index != NSNotFound, let cache = sourceGeometryPages[index + 1] else { return nil }
        // Native links and real annotations keep their existing actions.
        if page.annotations.contains(where: { $0.bounds.contains(local) }) { return nil }
        let candidates: Set<SourceLineKey>
        if cache.hitBands.requiresFallback {
            candidates = Set((sourceGeometryIDsByPage[index + 1] ?? []).flatMap { id -> [SourceLineKey] in
                guard let geometry = sourceGeometries[id] else { return [] }
                return geometry.lines.indices.map { SourceLineKey(id: id, line: $0) }
            })
        } else { candidates = cache.hitBands.candidates(atY: local.y) }
        var best: (id: String, rect: CGRect, term: Bool, length: Int)?
        for key in candidates {
            guard let geometry = sourceGeometries[key.id], geometry.page == index + 1, geometry.lines.indices.contains(key.line) else { continue }
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
        sourcePointerMonitor = nil; sourcePress = nil
    }
    private func observeSourcePointer(_ event: NSEvent) {
        guard let owner = window, event.window === owner, !interactionBlocked, !isHiddenOrHasHiddenAncestor,
              !installingDocument, owner.attachedSheet == nil, NSApp.modalWindow == nil,
              !pdfView.isRegionSelectionArmed, ownsPDFHit(event, in: owner),
              event.modifierFlags.intersection([.option, .command, .control]).isEmpty else {
            sourcePress = nil; if event.type == .mouseMoved { reportSourceHover(nil) }; return
        }
        let point = pdfView.convert(event.locationInWindow, from: nil)
        switch event.type {
        case .mouseMoved:
            guard event.timestamp - lastSourcePointerTime >= 1.0 / 30, NSEvent.pressedMouseButtons == 0 else { return }
            lastSourcePointerTime = event.timestamp
            // Do not extract a potentially whole-book selected string on each
            // mouse move merely to learn whether selection owns the gesture.
            if pdfView.currentSelection?.pages.isEmpty == false { reportSourceHover(nil); return }
            reportSourceHover(sourceHit(at: point, preferTerm: false))
        case .leftMouseDown:
            reportSourceHover(nil)
            sourcePress = event.clickCount == 1 ? sourceHit(at: point, preferTerm: true).map { ($0, point) } : nil
        case .leftMouseDragged, .scrollWheel:
            sourcePress = nil; reportSourceHover(nil)
        case .leftMouseUp:
            defer { sourcePress = nil }
            guard event.clickCount == 1, let press = sourcePress, hypot(point.x - press.point.x, point.y - press.point.y) <= 3,
                  sourceGeometries[press.hit.id] != nil else { return }
            let generation = documentGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.documentGeneration == generation,
                      self.sourceGeometries[press.hit.id] != nil,
                      self.pdfView.currentSelection?.string?.isEmpty != false else { return }
                self.reportSourceHover(press.hit, activated: true)
            }
        default: break
        }
    }
    private func renderSavedAnnotations() {
        for (page, annotation) in renderedAnnotations { page.removeAnnotation(annotation) }
        renderedAnnotations = []; annotationIDs = [:]
        guard let document, !document.isLocked else { return }
        for record in savedAnnotations where record.trashedAt == nil && record.sourceHash == sourceHash {
            guard record.page >= 1, record.page <= document.pageCount, let page = document.page(at: record.page - 1) else { continue }
            for quad in record.quads {
                guard [quad.x, quad.y, quad.width, quad.height].allSatisfy({ $0.isFinite }), quad.width > 0, quad.height > 0 else { continue }
                let rect = NSRect(x: quad.x, y: quad.y, width: quad.width, height: quad.height).intersection(page.bounds(for: .cropBox))
                guard !rect.isNull, !rect.isEmpty else { continue }
                let annotation = PDFAnnotation(bounds: rect, forType: record.effectiveKind == .region ? .square : .highlight, withProperties: nil)
                annotation.color = record.color.nativeColor.withAlphaComponent(record.effectiveKind == .region ? 0.9 : 0.42)
                if record.effectiveKind == .region { let border = PDFBorder(); border.lineWidth = 1.5; annotation.border = border; annotation.interiorColor = record.color.nativeColor.withAlphaComponent(0.1) }
                annotation.contents = record.comment.isEmpty ? record.text : record.comment
                page.addAnnotation(annotation); renderedAnnotations.append((page, annotation))
                annotationIDs[ObjectIdentifier(annotation)] = record.id
            }
        }
        pdfView.needsDisplay = true
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
        if hoveredSourceID != hit?.id { hoveredSourceID = hit?.id; sourceCanvas.needsDisplay = true }
        guard let hit else { onSourceDecorationHover?(nil); return }
        let rect = convert(hit.rect, from: pdfView)
        let topRect = isFlipped ? rect : CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        onSourceDecorationHover?(SourceReadingHover(id: hit.id, rect: topRect, point: CGPoint(x: topRect.midX, y: topRect.maxY), activated: activated))
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
    func cancelRegionSelection() { regionArmed = false; handlingManagedClick = false; regionStart = nil; regionPreview?.removeFromSuperview(); regionPreview = nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if regionArmed { return bounds.contains(local) ? self : nil }
        if NSApp.currentEvent?.modifierFlags.contains(.option) != true, managedAnnotation(at: local) != nil { return self }
        return super.hitTest(point)
    }
    private func managedAnnotation(at point: CGPoint) -> PDFAnnotation? {
        guard let page = page(for: point, nearest: false) else { return nil }
        let local = convert(point, to: page)
        return page.annotations.reversed().first { isManagedAnnotation?($0) == true && $0.bounds.contains(local) }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
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
        let rect = CGRect(x: min(end.x, start.pagePoint.x), y: min(end.y, start.pagePoint.y), width: abs(end.x - start.pagePoint.x), height: abs(end.y - start.pagePoint.y)).intersection(start.page.bounds(for: .cropBox))
        guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { onRegionError?("框选区域太小或在页面外，未保存。"); return }
        onRegion?(start.page, rect)
    }
    override func keyDown(with event: NSEvent) {
        guard !interactionBlocked else { return }
        if regionArmed && event.keyCode == 53 { cancelRegionSelection(); onRegionError?(""); return }
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
        guard !interactionBlocked else { return }
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
