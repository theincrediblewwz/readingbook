import SwiftUI
import AppKit
import PDFKit

/// Displays the original PDF with PDFKit. Page numbers and callbacks are 1-based.
/// OCR text is deliberately not substituted for the PDF's rendered page.
struct PDFReaderView: NSViewRepresentable {
    var url: URL
    var page: Int?
    var onPageChange: ((Int) -> Void)?

    init(url: URL, page: Int? = nil, onPageChange: ((Int) -> Void)? = nil) {
        self.url = url; self.page = page; self.onPageChange = onPageChange
    }

    func makeNSView(context: Context) -> PDFReaderContainerView {
        let view = PDFReaderContainerView()
        view.update(url: url, requestedPage: page, onPageChange: onPageChange)
        return view
    }

    func updateNSView(_ nsView: PDFReaderContainerView, context: Context) {
        nsView.update(url: url, requestedPage: page, onPageChange: onPageChange)
    }

    static func dismantleNSView(_ nsView: PDFReaderContainerView, coordinator: ()) { nsView.shutdown() }
}

/// Native controls keep the toolbar usable when the surrounding reader narrows.
/// There is no fixed minimum toolbar width and no custom PDF rasterization.
@MainActor final class PDFReaderContainerView: NSView, NSTextFieldDelegate {
    private enum FitMode: Int { case page, width, actual, custom }
    private let pdfView = PDFView()
    private let thumbnails = PDFThumbnailView()
    private let thumbnailScroll = NSScrollView()
    private let contentStack = NSStackView()
    private let header = NSVisualEffectView()
    private let pageField = NSTextField(string: "1")
    private let countLabel = NSTextField(labelWithString: "/ —")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let searchField = NSSearchField()
    private let resultLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let fitPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var previousButton = NSButton()
    private var nextButton = NSButton()
    private var previousMatchButton = NSButton()
    private var nextMatchButton = NSButton()
    private var thumbnailButton = NSButton()
    private var contentButtons: [NSControl] = []
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
    private var lastEmittedPage: Int?
    private var callback: ((Int) -> Void)?
    private var documentGeneration = 0
    private var fitMode = FitMode.width
    private var lastViewportSize = NSSize.zero
    private var searchGeneration = 0
    private var searchDelegate: PDFReaderSearchDelegate?
    private var matches: [PDFSelection] = []
    private var matchIndex = -1
    private var searching = false
    private var searchLimited = false
    private var highlightUpdateScheduled = false
    private let matchLimit = 5000

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("PDFReaderContainerView is created in code") }

    private func configure() {
        pdfView.autoScales = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displayBox = .cropBox
        pdfView.displaysPageBreaks = true
        pdfView.minScaleFactor = 0.05
        pdfView.maxScaleFactor = 12
        pdfView.backgroundColor = .windowBackgroundColor
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged(_:)), name: .PDFViewScaleChanged, object: pdfView)

        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: 86, height: 112)
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.allowsDragging = false
        thumbnails.allowsMultipleSelection = false
        thumbnails.labelFont = .systemFont(ofSize: 10)
        thumbnails.backgroundColor = .controlBackgroundColor
        thumbnailScroll.documentView = thumbnails
        thumbnailScroll.hasVerticalScroller = true
        thumbnailScroll.hasHorizontalScroller = false
        thumbnailScroll.autohidesScrollers = true
        thumbnailScroll.drawsBackground = true
        thumbnailScroll.backgroundColor = .controlBackgroundColor
        thumbnailScroll.isHidden = true
        thumbnailScroll.widthAnchor.constraint(equalToConstant: 118).isActive = true

        contentStack.orientation = .horizontal
        contentStack.alignment = .top
        contentStack.distribution = .fill
        contentStack.spacing = 0
        contentStack.detachesHiddenViews = true
        contentStack.addArrangedSubview(thumbnailScroll)
        contentStack.addArrangedSubview(pdfView)
        pdfView.heightAnchor.constraint(equalTo: contentStack.heightAnchor).isActive = true
        thumbnailScroll.heightAnchor.constraint(equalTo: contentStack.heightAnchor).isActive = true
        pdfView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        previousButton = symbolButton("chevron.left", "上一页", #selector(previousPage))
        nextButton = symbolButton("chevron.right", "下一页", #selector(nextPage))
        thumbnailButton = symbolButton("sidebar.left", "显示或收起缩略图", #selector(toggleThumbnails))
        thumbnailButton.setButtonType(.toggle)
        pageField.controlSize = .small
        pageField.alignment = .right
        pageField.target = self; pageField.action = #selector(jumpToPage)
        pageField.setAccessibilityLabel("PDF 页码，按回车跳转")
        pageField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        let navigation = row([previousButton, nextButton, pageField, countLabel, flexibleSpace(), thumbnailButton])

        let zoomOut = symbolButton("minus.magnifyingglass", "缩小", #selector(zoomOut))
        let zoomIn = symbolButton("plus.magnifyingglass", "放大", #selector(zoomIn))
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        zoomLabel.alignment = .center
        zoomLabel.textColor = .secondaryLabelColor
        fitPicker.addItems(withTitles: ["适合页面", "适合宽度", "实际大小", "自定比例"])
        fitPicker.selectItem(at: FitMode.width.rawValue)
        fitPicker.target = self; fitPicker.action = #selector(changeFit)
        fitPicker.controlSize = .small
        modePicker.addItems(withTitles: ["连续", "单页"])
        modePicker.target = self; modePicker.action = #selector(changeMode)
        modePicker.controlSize = .small
        let sizing = row([zoomOut, zoomIn, zoomLabel, flexibleSpace(), fitPicker, modePicker])

        searchField.placeholderString = "搜索 PDF 文字 · 回车查找"
        searchField.controlSize = .small
        searchField.sendsWholeSearchString = true
        searchField.sendsSearchStringImmediately = false
        searchField.target = self; searchField.action = #selector(findText)
        searchField.delegate = self
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previousMatchButton = symbolButton("chevron.up", "上一个搜索结果", #selector(previousMatch))
        nextMatchButton = symbolButton("chevron.down", "下一个搜索结果", #selector(nextMatch))
        let clear = symbolButton("xmark", "停止搜索并清除高亮", #selector(clearSearch))
        resultLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        resultLabel.textColor = .secondaryLabelColor
        let finding = row([searchField, resultLabel, previousMatchButton, nextMatchButton, clear])
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = true
        let toolbar = NSStackView(views: [navigation, sizing, finding, statusLabel])
        toolbar.orientation = .vertical
        toolbar.alignment = .leading
        toolbar.spacing = 7
        toolbar.detachesHiddenViews = true
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .active
        header.addSubview(toolbar)
        for line in [navigation, sizing, finding] { line.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            toolbar.topAnchor.constraint(equalTo: header.topAnchor, constant: 9),
            toolbar.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -9)
        ])
        let stack = NSStackView(views: [header, contentStack])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), contentStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        header.setContentHuggingPriority(.required, for: .vertical)
        contentStack.setContentHuggingPriority(.defaultLow, for: .vertical)
        configureOverlay()
        contentButtons = [previousButton, nextButton, pageField, zoomOut, zoomIn, fitPicker, modePicker, searchField, thumbnailButton]
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

    func update(url: URL, requestedPage: Int?, onPageChange: ((Int) -> Void)?) {
        callback = onPageChange
        let canonical = url.standardizedFileURL
        if canonical != loadedURL {
            sourcePage = requestedPage; lastParentPage = requestedPage
            load(canonical)
        } else if requestedPage != lastParentPage {
            lastParentPage = requestedPage; sourcePage = requestedPage
            if let requestedPage { navigate(to: requestedPage, fromParent: true) }
        }
    }

    private func load(_ url: URL) {
        clearSearchState()
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
        if pdf.isLocked { showLocked(); return }
        showDocument()
    }

    private func showDocument() {
        guard let document, !document.isLocked, document.pageCount > 0 else {
            showError("PDF 没有可显示页面", "此文件没有有效页面，或尚未成功解锁。原文件没有被修改。")
            return
        }
        overlay.isHidden = true; passwordField.stringValue = ""
        pdfView.document = document
        thumbnails.pdfView = pdfView
        layoutThumbnails()
        let desired = sourcePage ?? 1
        navigate(to: (1...document.pageCount).contains(desired) ? desired : 1, fromParent: true)
        refreshControls()
        let generation = documentGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.documentGeneration == generation else { return }
            self.applyFit(); self.refreshControls()
        }
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
        passwordField.stringValue = ""; showDocument()
    }

    private var currentPageNumber: Int? {
        guard let document, let page = pdfView.currentPage else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index + 1
    }

    private func navigate(to number: Int, fromParent: Bool = false) {
        guard let document, !document.isLocked, document.pageCount > 0, (1...document.pageCount).contains(number), let target = document.page(at: number - 1) else {
            if document?.isLocked != true { setStatus("页码超出 PDF 的有效范围。") }
            return
        }
        if fromParent { lastEmittedPage = number }
        if pdfView.currentPage !== target { pdfView.go(to: target) }
        applyFit(); refreshControls()
    }

    @objc private func jumpToPage() {
        guard let number = Int(pageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let document, document.pageCount > 0, (1...document.pageCount).contains(number) else {
            setStatus("请输入 1–\(document?.pageCount ?? 0) 之间的原 PDF 页码。"); refreshControls(); return
        }
        setStatus(""); navigate(to: number)
    }

    @objc private func previousPage() { if let page = currentPageNumber, page > 1 { navigate(to: page - 1) } }
    @objc private func nextPage() { if let page = currentPageNumber, let document, page < document.pageCount { navigate(to: page + 1) } }
    @objc private func toggleThumbnails() {
        thumbnailScroll.isHidden = thumbnailButton.state != .on
        needsLayout = true; layoutSubtreeIfNeeded(); layoutThumbnails(); applyFit()
    }

    @objc private func zoomOut() { changeZoom(by: 1 / 1.2) }
    @objc private func zoomIn() { changeZoom(by: 1.2) }
    private func changeZoom(by factor: CGFloat) {
        fitMode = .custom; fitPicker.selectItem(at: fitMode.rawValue)
        pdfView.autoScales = false
        pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, pdfView.scaleFactor * factor))
        refreshControls()
    }

    @objc private func changeFit() { fitMode = FitMode(rawValue: fitPicker.indexOfSelectedItem) ?? .width; applyFit() }
    @objc private func changeMode() {
        let page = currentPageNumber
        pdfView.displayMode = modePicker.indexOfSelectedItem == 0 ? .singlePageContinuous : .singlePage
        if let page { navigate(to: page, fromParent: true) }
        applyFit()
    }

    override func layout() {
        super.layout()
        let size = pdfView.bounds.size
        if abs(size.width - lastViewportSize.width) > 0.5 || abs(size.height - lastViewportSize.height) > 0.5 {
            lastViewportSize = size; layoutThumbnails(); applyFit()
        }
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
        if abs(pdfView.scaleFactor - clamped) > 0.001 { pdfView.scaleFactor = clamped }
        refreshControls()
    }

    private func layoutThumbnails() {
        let height = max(thumbnailScroll.contentSize.height, CGFloat(document?.pageCount ?? 0) * 146 + 20)
        thumbnails.frame = NSRect(x: 0, y: 0, width: max(100, thumbnailScroll.contentSize.width), height: height)
    }

    @objc private func pageChanged(_ notification: Notification) {
        refreshControls()
        if fitMode == .page { applyFit() }
        guard let page = currentPageNumber, page != lastEmittedPage else { return }
        lastEmittedPage = page
        let generation = documentGeneration
        // Updating the enclosing SwiftUI source selection from updateNSView
        // would cause a render loop. Deliver only the latest page asynchronously.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.documentGeneration == generation, self.currentPageNumber == page else { return }
            self.callback?(page)
        }
    }

    @objc private func scaleChanged(_ notification: Notification) { refreshControls() }

    private func refreshControls() {
        let ready = document != nil && document?.isLocked == false && (document?.pageCount ?? 0) > 0
        for control in contentButtons { control.isEnabled = ready }
        let number = currentPageNumber ?? 1, count = ready ? document?.pageCount ?? 0 : 0
        if pageField.currentEditor() == nil || window?.firstResponder !== pageField.currentEditor() { pageField.stringValue = String(number) }
        countLabel.stringValue = count > 0 ? "/ \(count)" : "/ —"
        zoomLabel.stringValue = "\(Int((pdfView.scaleFactor * 100).rounded()))%"
        previousButton.isEnabled = ready && number > 1
        nextButton.isEnabled = ready && number < count
        previousMatchButton.isEnabled = !matches.isEmpty; nextMatchButton.isEnabled = !matches.isEmpty
    }

    @objc private func findText() {
        guard let document, !document.isLocked else { return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { clearSearchState(); return }
        guard query.count <= 500 else { setStatus("搜索词最多为 500 字。"); return }
        clearSearchState()
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

    @objc private func clearSearch() { searchField.stringValue = ""; clearSearchState(); setStatus("") }
    private func clearSearchState() {
        searchGeneration += 1
        document?.delegate = nil; document?.cancelFindString(); searchDelegate = nil
        matches = []; matchIndex = -1; searching = false; searchLimited = false
        highlightUpdateScheduled = false
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
        if matchIndex < 0 { matchIndex = 0; showMatch() }
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
        matchIndex = (matchIndex + direction + matches.count) % matches.count; showMatch()
    }
    private func showMatch() {
        guard matches.indices.contains(matchIndex) else { return }
        let selection = matches[matchIndex]
        pdfView.go(to: selection); pdfView.setCurrentSelection(selection, animate: true)
        pdfView.scrollSelectionToVisible(nil); updateSearchDisplay()
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSSearchField, field === searchField, field.stringValue.isEmpty { clearSearchState(); setStatus("") }
    }

    private func setStatus(_ text: String) { statusLabel.stringValue = text; statusLabel.toolTip = text; statusLabel.isHidden = text.isEmpty }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 6
        for view in views { view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        return stack
    }
    private func flexibleSpace() -> NSView { let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view }
    private func symbolButton(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .rounded; button.controlSize = .small; button.toolTip = title; button.setAccessibilityLabel(title)
        return button
    }

    func shutdown() {
        searchGeneration += 1; document?.delegate = nil; document?.cancelFindString(); searchDelegate = nil
        NotificationCenter.default.removeObserver(self)
        thumbnails.pdfView = nil; pdfView.document = nil; document = nil; callback = nil
        if securityScoped { loadedURL?.stopAccessingSecurityScopedResource() }; securityScoped = false
    }
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
