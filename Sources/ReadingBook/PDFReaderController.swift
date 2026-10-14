import SwiftUI

enum PDFReaderCommand {
    case prev, next, jump(Int), zoomIn, zoomOut, fitPage, fitWidth, actualSize
    case toggleSearch, toggleThumbnails, toggleContinuous, createHighlight, createRegion, showAnnotations
}

/// One instance belongs to one window. A mounted PDF view owns its command binding.
@MainActor final class PDFReaderController: ObservableObject {
    @Published var page = 1
    @Published var pageCount = 0
    @Published var zoomPercent = 100
    @Published var isReady = false
    @Published var hasSelection = false
    @Published var canEditAnnotations = true
    private var bindingID: UUID?
    private var handler: ((PDFReaderCommand) -> Void)?

    func command(_ command: PDFReaderCommand) { handler?(command) }
    func bind(id: UUID, handler: @escaping (PDFReaderCommand) -> Void) { bindingID = id; self.handler = handler }
    func update(id: UUID, page: Int, pageCount: Int, zoomPercent: Int, isReady: Bool, hasSelection: Bool, canEditAnnotations: Bool) {
        guard bindingID == id else { return }
        if self.page != page { self.page = page }
        if self.pageCount != pageCount { self.pageCount = pageCount }
        if self.zoomPercent != zoomPercent { self.zoomPercent = zoomPercent }
        if self.isReady != isReady { self.isReady = isReady }
        if self.hasSelection != hasSelection { self.hasSelection = hasSelection }
        if self.canEditAnnotations != canEditAnnotations { self.canEditAnnotations = canEditAnnotations }
    }
    func unbind(id: UUID) {
        guard bindingID == id else { return }; bindingID = nil; handler = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.bindingID == nil else { return }
            self.isReady = false; self.hasSelection = false; self.pageCount = 0
        }
    }
}
