import AppKit
import CoreText
import SwiftUI
import ReadingCore

/// Kept alive across preview/edit switches. The native text view owns selection,
/// marked text and undo; SwiftUI never replaces its source to abbreviate links.
// This owned TextKit 1 graph is used only on MainActor; background layout is
// disabled below. The legacy ObjC delegate protocol itself lacks that isolation.
@MainActor final class NoteMarkdownEditorSession: NSObject, ObservableObject, NSTextViewDelegate, @preconcurrency NSLayoutManagerDelegate {
    let scrollView: NSScrollView
    private let textView: NoteMarkdownTextView
    private let noteLayout: NSLayoutManager
    private var libraryKey: String?
    private var bookID: String?
    private var documentID: String?
    private var initialized = false
    private var reconciling = false
    private var expanded = false
    private var sourceLinks: [ReadingNoteLinkFolds.Link] = []
    private var folded: [ReadingNoteLinkFolds.Link] = []
    private var onChange: ((String) -> Void)?
    private var pendingParse: DispatchWorkItem?
    private var parseTask: Task<[ReadingNoteLinkFolds.Link], Never>?
    private var sourceRevision: UInt64 = 0
    private var latestMarkdown = ""
    private struct PendingEdit {
        let range: NSRange
        let replacement: String
        let canRemap: Bool
    }
    private var pendingEdit: PendingEdit?
    private var appliedFont: NSFont?

    override init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        noteLayout = layout
        textView = NoteMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300), textContainer: container)
        scrollView = NSScrollView(frame: textView.frame)
        super.init()
        layout.delegate = self
        layout.allowsNonContiguousLayout = true
        layout.backgroundLayoutEnabled = false
        textView.delegate = self
        textView.ownerSession = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 6, height: 2)
        textView.drawsBackground = false
        textView.textColor = .labelColor
        // Markdown punctuation is source, not prose autocorrection input.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.setAccessibilityLabel("笔记 Markdown 正文")
        textView.setAccessibilityHelp("原文链接的长定位仅在显示时收纳。点进定位或展开完整定位后可编辑；复制、保存和导出保留完整 Markdown。")
        textView.willCompose = { [weak self] in self?.revealForComposition() }
        textView.didCompose = { [weak self] in self?.scheduleParse() }
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
    }

    func update(markdown: String, libraryRoot: URL, bookID nextBookID: String?, documentID nextDocumentID: String?,
        font: NSFont, expanded: Bool, editable: Bool, visible: Bool, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        self.expanded = expanded
        let nextLibraryKey = ReadingNoteEditorContinuity.libraryKey(libraryRoot)
        let identityChanged = !initialized || libraryKey != nextLibraryKey || bookID != nextBookID || documentID != nextDocumentID
        let sameBytes = ReadingNoteEditorContinuity.identicalSource(latestMarkdown, markdown)
        if identityChanged || !sameBytes {
            let keepHistory = initialized && ReadingNoteEditorContinuity.preservesHistory(
                previousLibraryKey: libraryKey ?? "", previousBookID: bookID, previousDocumentID: documentID,
                nextLibraryKey: nextLibraryKey, nextBookID: nextBookID, nextDocumentID: nextDocumentID,
                currentMarkdown: latestMarkdown, incomingMarkdown: markdown)
            // A normal Binding echo has identical text. Do not disturb active
            // composition in response to its own SwiftUI update.
            if !textView.hasMarkedText() || identityChanged {
                reconciling = true
                cancelParse()
                if textView.hasMarkedText() { textView.unmarkText() }
                if !sameBytes {
                    textView.string = markdown
                }
                if !keepHistory {
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                    scrollView.contentView.scroll(to: .zero)
                    textView.undoManager?.removeAllActions()
                }
                latestMarkdown = markdown; sourceRevision &+= 1
                self.libraryKey = nextLibraryKey; self.bookID = nextBookID; self.documentID = nextDocumentID; initialized = true
                reconciling = false
                if !keepHistory { sourceLinks = []; setFolded([]) }
                scheduleParse()
            }
        }
        if !textView.hasMarkedText(), appliedFont != font {
            reconciling = true
            appliedFont = font
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6
            textView.font = font
            textView.defaultParagraphStyle = paragraph
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            if let storage = textView.textStorage, storage.length > 0 {
                // Appearance attributes only. These never enter the native
                // text undo stack or the document's Markdown Binding.
                storage.addAttributes([.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph],
                    range: NSRange(location: 0, length: storage.length))
            }
            reconciling = false
        }
        textView.isEditable = editable
        textView.isSelectable = true
        scrollView.isHidden = !visible
        refreshFolds()
    }

    /// End marked text through the ordinary native editor before showing the
    /// rendered body. The live editor/undo manager are retained behind preview.
    @discardableResult func finishEditing() -> Bool {
        // Also end the title field's field editor. Hiding a focused title with
        // opacity alone would let further typing edit an invisible control.
        if let window = scrollView.window, !window.makeFirstResponder(nil) {
            return false
        }
        if textView.hasMarkedText() { textView.unmarkText() }
        textView.breakUndoCoalescing()
        return !textView.hasMarkedText()
    }

    /// Shared save entrypoint: only the current key window may commit editing.
    /// A weak view-to-owner reference avoids a global registry retaining stale
    /// sessions or dispatching an old window's Binding into another library.
    static func finishActiveEditing(libraryRoot: URL, bookID: String?) -> Bool {
        guard let window = NSApp?.keyWindow else { return true }
        if let editor = window.firstResponder as? NoteMarkdownTextView {
            guard let owner = editor.ownerSession, owner.textView === editor,
                  owner.scrollView.window === window,
                  owner.libraryKey == ReadingNoteEditorContinuity.libraryKey(libraryRoot),
                  owner.bookID == bookID else { return false }
            return owner.finishEditing()
        }
        // In particular, this normally commits the title's Cocoa field editor.
        // Respect a field refusing validation rather than saving stale text.
        return window.makeFirstResponder(nil)
    }

    func textDidChange(_ notification: Notification) {
        guard !reconciling else { return }
        // This is always the complete source, including hidden destinations.
        latestMarkdown = textView.string; sourceRevision &+= 1
        cancelParse()
        if !textView.hasMarkedText(), let edit = pendingEdit, edit.canRemap {
            sourceLinks = ReadingNoteLinkFolds.remapped(sourceLinks, editedRange: edit.range,
                replacementLength: edit.replacement.utf16.count)
            refreshFolds()
        } else { sourceLinks = []; setFolded([]) }
        pendingEdit = nil
        onChange?(latestMarkdown)
        scheduleParse()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !reconciling else { return }
        refreshFolds()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if !ReadingNoteLinkFolds.editTouchesFold(affectedCharRange, folded: folded) {
            pendingEdit = nil
            if let replacementString {
                let source = latestMarkdown as NSString
                if affectedCharRange.location <= source.length, affectedCharRange.length <= source.length - affectedCharRange.location {
                    let removed = source.substring(with: affectedCharRange)
                    var start = 0, end = 0, contentEnd = 0
                    source.getLineStart(&start, end: &end, contentsEnd: &contentEnd, for: affectedCharRange)
                    let line = source.substring(with: NSRange(location: start, length: contentEnd - start))
                    pendingEdit = PendingEdit(range: affectedCharRange, replacement: replacementString,
                        canRemap: ReadingNoteLinkFolds.canRemap(replacedText: removed, replacement: replacementString, editLine: line))
                }
            }
            return true
        }
        // Usually selection already revealed this source. A native command
        // reaching it directly first reveals it, without an invisible edit.
        sourceLinks = []; setFolded([])
        return false
    }

    private func revealForComposition() {
        cancelParse()
        sourceLinks = []
        setFolded([])
    }

    private func cancelParse() {
        pendingParse?.cancel(); pendingParse = nil
        parseTask?.cancel(); parseTask = nil
    }

    private func scheduleParse() {
        cancelParse()
        guard !reconciling, !textView.hasMarkedText(),
              !sourceLinks.isEmpty || (latestMarkdown as NSString).range(of: "readingbook://book/", options: .literal).location != NSNotFound else { return }
        let work = DispatchWorkItem { [weak self] in self?.parseLinksInBackground() }
        pendingParse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func parseLinksInBackground() {
        guard !reconciling, !textView.hasMarkedText() else { return }
        let snapshot = latestMarkdown, revision = sourceRevision
        let task = Task.detached(priority: .utility) { ReadingNoteLinkFolds.links(in: snapshot) }
        parseTask = task
        Task { [weak self] in
            let links = await task.value
            guard let self, !task.isCancelled, self.sourceRevision == revision,
                  ReadingNoteEditorContinuity.identicalSource(self.latestMarkdown, snapshot), !self.textView.hasMarkedText() else { return }
            self.parseTask = nil
            self.sourceLinks = links
            self.refreshFolds()
        }
    }

    #if DEBUG
    /// Read-only state for the workspace-local native regression probe. This
    /// avoids forcing layout through a large note merely to count folded URLs.
    var diagnosticLinkState: (confirmed: Int, folded: Int) { (sourceLinks.count, folded.count) }
    #endif

    private func refreshFolds() {
        setFolded(ReadingNoteLinkFolds.foldedLinks(sourceLinks, selections: textView.selectedRanges.map(\.rangeValue),
            expanded: expanded, composing: textView.hasMarkedText()))
    }

    private func setFolded(_ next: [ReadingNoteLinkFolds.Link]) {
        guard folded != next else { return }
        let previous = folded
        folded = next
        // Invalidate the display mapping, never NSTextStorage.string. Apple
        // defines .null glyphs as ignored for BOTH layout and display.
        let bounds = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        for link in previous + next {
            let range = NSIntersectionRange(bounds, link.destinationRange)
            if range.length > 0 { noteLayout.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil) }
        }
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard !folded.isEmpty else { return 0 }
        var changed = false
        var displayGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        var displayProperties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var character: UniChar = 0x2026, ellipsis: CGGlyph = 0
        CTFontGetGlyphsForCharacters(aFont as CTFont, &character, &ellipsis, 1)
        guard ellipsis != 0 else { return 0 }
        for index in 0..<glyphRange.length {
            let sourceIndex = charIndexes[index]
            guard let link = folded.first(where: { NSLocationInRange(sourceIndex, $0.destinationRange) }) else { continue }
            changed = true
            if sourceIndex == link.destinationRange.location {
                displayGlyphs[index] = ellipsis
                displayProperties[index] = []
            } else {
                displayGlyphs[index] = 0
                displayProperties[index] = .null
            }
        }
        guard changed else { return 0 }
        displayGlyphs.withUnsafeBufferPointer { glyphBuffer in
            displayProperties.withUnsafeBufferPointer { propertyBuffer in
                layoutManager.setGlyphs(glyphBuffer.baseAddress!, properties: propertyBuffer.baseAddress!,
                    characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
            }
        }
        return glyphRange.length
    }
}

/// TextKit 1 is intentional: its documented glyph-generation hook provides a
/// view-only fold while Cocoa still edits, copies and undoes the real Markdown.
private final class NoteMarkdownTextView: NSTextView {
    private let noteUndoManager = UndoManager()
    override var undoManager: UndoManager? { noteUndoManager }
    weak var ownerSession: NoteMarkdownEditorSession?
    var willCompose: (() -> Void)?
    var didCompose: (() -> Void)?

    // The responder chain otherwise reaches NSWindow, whose undo manager is
    // different from this note's manager. Route and validate only these two
    // commands here; native text editing and all other actions stay unchanged.
    @objc func undo(_ sender: Any?) {
        guard isEditable, allowsUndo, noteUndoManager.canUndo else { return }
        noteUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard isEditable, allowsUndo, noteUndoManager.canRedo else { return }
        noteUndoManager.redo()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) { return isEditable && allowsUndo && noteUndoManager.canUndo }
        if menuItem.action == #selector(redo(_:)) { return isEditable && allowsUndo && noteUndoManager.canRedo }
        return super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return isEditable && allowsUndo && noteUndoManager.canUndo }
        if item.action == #selector(redo(_:)) { return isEditable && allowsUndo && noteUndoManager.canRedo }
        return super.validateUserInterfaceItem(item)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        willCompose?()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        super.unmarkText()
        didCompose?()
    }
}

struct NoteMarkdownEditor: NSViewRepresentable {
    let session: NoteMarkdownEditorSession
    @Binding var markdown: String
    var libraryRoot: URL
    var bookID: String?
    var documentID: String?
    var font: NSFont
    var expanded: Bool
    var editable: Bool
    var visible: Bool

    func makeNSView(context: Context) -> NSScrollView { session.scrollView }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        session.update(markdown: markdown, libraryRoot: libraryRoot, bookID: bookID, documentID: documentID,
            font: font, expanded: expanded, editable: editable, visible: visible) { markdown = $0 }
    }
}
