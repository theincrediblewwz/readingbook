import AppKit
import ReadingCore

struct PDFSearchResultEntry {
    let index: Int
    let page: Int
    let range: NSRange
    let match: String
}

/// Native reusable rows keep a 5,000-hit search from creating 5,000 views.
@MainActor final class PDFSearchResultsList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 34
    let table = PDFSearchResultTable()
    let scroll = NSScrollView()
    private(set) var entries: [PDFSearchResultEntry] = []
    private var snippets: [Int: NativePDFSearchSnippet] = [:]
    private var snippetOrder: [Int] = []
    private var updating = false
    private struct Related: Equatable { let terms: [String]; let primaryCount: Int; let expanded: Bool; let loading: Bool }
    private var related: Related?
    var visibleRowCount: Int { entries.count + (related == nil ? 0 : 1) }
    var onToggleRelated: (() -> Void)?
    var onRequest: ((Int) -> Void)?
    var onSelect: ((Int) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("result")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = Self.rowHeight; table.intercellSpacing = .zero
        table.backgroundColor = .clear; table.style = .plain; table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(picked)
        table.setAccessibilityLabel("PDF 查找结果")
        NotificationCenter.default.addObserver(self, selector: #selector(windowResigned(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        table.observeScrolling(in: scroll.contentView)
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func windowResigned(_ notification: Notification) { if notification.object as? NSWindow === window { table.clearHover() } }
    func reset() {
        updating = true; entries = []; snippets = [:]; snippetOrder = []; related = nil; table.clearHover(); table.reloadData(); updating = false
    }
    func configureRelated(terms: [String], primaryCount: Int, expanded: Bool, loading: Bool) {
        let next = terms.isEmpty ? nil : Related(terms: terms, primaryCount: primaryCount, expanded: expanded, loading: loading)
        guard next != related else { return }
        related = next; updating = true; table.clearHover(); table.reloadData(); updating = false
    }
    func trim(to count: Int) {
        guard count < entries.count else { return }
        entries = Array(entries.prefix(count)); snippets = snippets.filter { $0.key < count }; snippetOrder.removeAll { $0 >= count }
        updating = true; table.reloadData(); updating = false
    }
    private func row(for index: Int) -> Int { index + (related.map { index >= $0.primaryCount ? 1 : 0 } ?? 0) }
    private func entry(at row: Int) -> Int? {
        let index: Int
        if let related { if row == related.primaryCount { return nil }; index = row > related.primaryCount ? row - 1 : row }
        else { index = row }
        return entries.indices.contains(index) ? index : nil
    }
    func append(_ additions: [PDFSearchResultEntry], selected: Int) {
        updating = true
        if !additions.isEmpty {
            let start = entries.count; entries.append(contentsOf: additions)
            if related == nil { table.insertRows(at: IndexSet(integersIn: start..<entries.count), withAnimation: []) }
            else { table.reloadData() }
        }
        if entries.indices.contains(selected) { table.selectRowIndexes(IndexSet(integer: row(for: selected)), byExtendingSelection: false) }
        updating = false
    }
    func showSelection(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        let row = row(for: index)
        updating = true; table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row); updating = false
    }
    func setSnippet(_ snippet: NativePDFSearchSnippet, at index: Int) {
        guard entries.indices.contains(index) else { return }
        snippets[index] = snippet; snippetOrder.removeAll { $0 == index }; snippetOrder.append(index)
        while snippetOrder.count > 256 { snippets.removeValue(forKey: snippetOrder.removeFirst()) }
        if let cell = table.view(atColumn: 0, row: row(for: index), makeIfNecessary: false) as? PDFSearchResultCell { cell.apply(entries[index], snippet: snippet) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visibleRowCount }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let related, row == related.primaryCount {
            let id = NSUserInterfaceItemIdentifier("related-toggle")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? NSTableCellView()
            cell.identifier = id
            if cell.subviews.isEmpty {
                let button = ReadingNativeHoverButton(title: "", target: self, action: #selector(toggleRelated))
                button.font = .systemFont(ofSize: 13, weight: .medium); button.isBordered = false; button.alignment = .left
                button.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(button)
                NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                    button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                    button.topAnchor.constraint(equalTo: cell.topAnchor), button.bottomAnchor.constraint(equalTo: cell.bottomAnchor)])
            }
            let button = cell.subviews.first as? NSButton
            button?.title = related.expanded ? "收起相关结果" + (related.loading ? " · 查找中…" : " · \(max(0, entries.count - related.primaryCount))处") : "更多相关结果 · 点击查找"
            cell.toolTip = "相关主题单独收在这里，不混进上方原词、纠错和语言变体的结果。\n" + related.terms.joined(separator: "、")
            button?.toolTip = cell.toolTip; return cell
        }
        guard let index = entry(at: row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("search-hit")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? PDFSearchResultCell) ?? PDFSearchResultCell()
        cell.identifier = id; cell.apply(entries[index], snippet: snippets[index] ?? .unlocated(entries[index].match))
        if snippets[index] == nil { DispatchQueue.main.async { [weak self] in self?.onRequest?(index) } }
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = PDFSearchResultRow(); view.readingHovered = row == table.hoveredRow; return view
    }
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? PDFSearchResultRow)?.readingHovered = row == table.hoveredRow
    }
    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        (rowView as? PDFSearchResultRow)?.readingHovered = false
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !updating, NSApp.currentEvent?.type == .keyDown, let index = entry(at: table.selectedRow) { onSelect?(index) }
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { entry(at: row) != nil }
    @objc private func picked() {
        guard !updating else { return }
        if let related, table.clickedRow == related.primaryCount { onToggleRelated?() }
        else if let index = entry(at: table.clickedRow) { onSelect?(index) }
    }
    @objc private func toggleRelated() { onToggleRelated?() }
}

@MainActor private final class PDFSearchResultCell: NSTableCellView {
    let excerpt = NSTextField(labelWithString: ""), location = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        excerpt.font = .systemFont(ofSize: 14); excerpt.lineBreakMode = .byTruncatingTail; excerpt.maximumNumberOfLines = 1
        location.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); location.textColor = .secondaryLabelColor
        location.setContentHuggingPriority(.required, for: .horizontal); location.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [excerpt, location]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)])
        excerpt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func apply(_ entry: PDFSearchResultEntry, snippet: NativePDFSearchSnippet) {
        let value = NSMutableAttributedString(string: snippet.before, attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        value.append(NSAttributedString(string: snippet.match, attributes: [.foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.36), .font: NSFont.systemFont(ofSize: 14, weight: .semibold)]))
        value.append(NSAttributedString(string: snippet.after, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        excerpt.attributedStringValue = value
        location.stringValue = "第 \(entry.page) 页" + (snippet.paragraph.map { " · 段 \($0)" } ?? "")
        toolTip = snippet.text + "\n" + location.stringValue + "；段落按 PDF 文字层划分，点击定位原页。"
        setAccessibilityLabel(snippet.text + "，" + location.stringValue)
    }
}

/// A single owner resolves pointer position after both mouse moves and native
/// scrolling. Per-row enter/exit flags become stale when rows are recycled.
@MainActor final class PDFSearchResultTable: NSTableView {
    private var area: NSTrackingArea?
    private var boundsObserver: NSObjectProtocol?
    private(set) var hoveredRow = -1
    func observeScrolling(in clip: NSClipView) {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHover() }
        }
    }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let value = NSTrackingArea(rect: .zero, options: [.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect], owner: self)
        area = value; addTrackingArea(value); refreshHover()
    }
    override func mouseMoved(with event: NSEvent) { refreshHover(windowPoint: event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { refreshHover(windowPoint: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { clearHover() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); clearHover() }
    func clearHover() { setHoveredRow(-1) }
    func refreshHover(windowPoint: CGPoint? = nil) {
        guard let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else { clearHover(); return }
        let point = convert(windowPoint ?? window.mouseLocationOutsideOfEventStream, from: nil)
        setHoveredRow(visibleRect.contains(point) ? row(at: point) : -1)
    }
    private func setHoveredRow(_ next: Int) {
        let old = hoveredRow; hoveredRow = next
        for index in Set([old, next]) where index >= 0 {
            (rowView(atRow: index, makeIfNecessary: false) as? PDFSearchResultRow)?.readingHovered = index == next
        }
    }
}

@MainActor private final class PDFSearchResultRow: NSTableRowView {
    private let surface = CALayer()
    var readingHovered = false { didSet { updateSurface() } }
    override var isSelected: Bool { didSet { updateSurface() } }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        surface.cornerRadius = 8; layer?.insertSublayer(surface, at: 0); updateSurface()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); surface.frame = bounds.insetBy(dx: 2, dy: 1) }
    private func updateSurface() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(isSelected ? 0.12 : readingHovered ? 0.07 : 0).cgColor
        CATransaction.commit()
    }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}
