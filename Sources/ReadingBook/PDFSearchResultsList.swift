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
    let table = NSTableView()
    let scroll = NSScrollView()
    private(set) var entries: [PDFSearchResultEntry] = []
    private var snippets: [Int: NativePDFSearchSnippet] = [:]
    private var snippetOrder: [Int] = []
    private var updating = false
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
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func reset() {
        updating = true; entries = []; snippets = [:]; snippetOrder = []; table.reloadData(); updating = false
    }
    func append(_ additions: [PDFSearchResultEntry], selected: Int) {
        updating = true
        if !additions.isEmpty {
            let start = entries.count; entries.append(contentsOf: additions)
            table.insertRows(at: IndexSet(integersIn: start..<entries.count), withAnimation: [])
        }
        if entries.indices.contains(selected) { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        updating = false
    }
    func showSelection(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        updating = true; table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index); updating = false
    }
    func setSnippet(_ snippet: NativePDFSearchSnippet, at index: Int) {
        guard entries.indices.contains(index) else { return }
        snippets[index] = snippet; snippetOrder.removeAll { $0 == index }; snippetOrder.append(index)
        while snippetOrder.count > 256 { snippets.removeValue(forKey: snippetOrder.removeFirst()) }
        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? PDFSearchResultCell { cell.apply(entries[index], snippet: snippet) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("search-hit")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? PDFSearchResultCell) ?? PDFSearchResultCell()
        cell.identifier = id; cell.apply(entries[row], snippet: snippets[row] ?? .unlocated(entries[row].match))
        if snippets[row] == nil { DispatchQueue.main.async { [weak self] in self?.onRequest?(row) } }
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PDFSearchResultRow() }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !updating, NSApp.currentEvent?.type == .keyDown, entries.indices.contains(table.selectedRow) { onSelect?(table.selectedRow) }
    }
    @objc private func picked() { guard !updating, entries.indices.contains(table.clickedRow) else { return }; onSelect?(table.clickedRow) }
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

@MainActor private final class PDFSearchResultRow: NSTableRowView {
    private var area: NSTrackingArea?
    private var hovered = false
    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        let value = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited,.activeInActiveApp,.inVisibleRect], owner: self)
        area = value; addTrackingArea(value); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func drawBackground(in dirtyRect: NSRect) {
        if hovered && !isSelected { NSColor.controlAccentColor.withAlphaComponent(0.07).setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill() }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}
