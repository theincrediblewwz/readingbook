import SwiftUI
import ReadingCore

enum PDFReaderCommand {
    case prev, next, jump(Int), zoomIn, zoomOut, fitPage, fitWidth, actualSize
    case showSearch, toggleSearch, toggleThumbnails, toggleContinuous, createHighlight, createRegion, showAnnotations
    case hideSearch, setThumbnails(Bool), setContinuous(Bool)
    case setDirection(PDFReadingDirection)
    /// Offsets from an extracted SourceUnit must never be reused as PDF offsets.
    case focusQuote(page: Int, quote: String)
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
    /// Visible native chrome in the PDF container's top-left coordinate space.
    @Published var chromeFrame = CGRect.zero
    @Published var thumbnailFrame = CGRect.zero
    @Published var canEditAnnotations = true
    private var bindingID: UUID?
    private var handler: ((PDFReaderCommand) -> Void)?

    func command(_ command: PDFReaderCommand) { handler?(command) }
    func bind(id: UUID, handler: @escaping (PDFReaderCommand) -> Void) { bindingID = id; self.handler = handler }
    func update(id: UUID, page: Int, pageCount: Int, zoomPercent: Int, isReady: Bool, hasSelection: Bool, canEditAnnotations: Bool, isSearchVisible: Bool, isContinuous: Bool, direction: PDFReadingDirection, thumbnailsVisible: Bool, fitMode: String, chromeFrame: CGRect, thumbnailFrame: CGRect) {
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
        if self.chromeFrame != chromeFrame { self.chromeFrame = chromeFrame }
        if self.thumbnailFrame != thumbnailFrame { self.thumbnailFrame = thumbnailFrame }
        if self.canEditAnnotations != canEditAnnotations { self.canEditAnnotations = canEditAnnotations }
    }
    func unbind(id: UUID) {
        guard bindingID == id else { return }; bindingID = nil; handler = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.bindingID == nil else { return }
            self.isReady = false; self.hasSelection = false; self.isSearchVisible = false; self.pageCount = 0
            self.chromeFrame = .zero; self.thumbnailFrame = .zero; self.thumbnailsVisible = false
        }
    }
}
