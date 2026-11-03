import AppKit
import SwiftUI
import ReadingCore

@MainActor final class ReaderEditUndoState: ObservableObject {
    struct Entry {
        let owner: WorkspacePickerOwner
        let title: String
        let change: ReadingEditUndoChange
        let bytes: Int
    }
    @Published private(set) var undoEntries: [Entry] = []
    @Published private(set) var redoEntries: [Entry] = []
    @Published private(set) var applying = false
    private var generation = 0
    func clear() { generation &+= 1; undoEntries = []; redoEntries = [] }
    func record(_ change: ReadingEditUndoChange, title: String, owner: WorkspacePickerOwner) {
        guard !applying else { return }
        let size: Int
        switch change {
        case .note(let expected, let desired): size = expected.markdown.utf8.count + desired.markdown.utf8.count
        case .annotations(let a, _): size = a.reduce(0) { $0 + $1.text.utf8.count + $1.quads.count * 32 + 512 }
        default: size = 1024
        }
        undoEntries.append(.init(owner: owner, title: title, change: change, bytes: size)); redoEntries = []
        while undoEntries.count > 30 || (undoEntries.count > 1 && undoEntries.reduce(0, { $0 + $1.bytes }) > 32 * 1024 * 1024) { undoEntries.removeFirst() }
    }
    func canApply(store: AppStore, redo: Bool) -> Bool {
        !applying && !store.isBusy && !store.isSavingDocument && !store.isOrganizingCollections && !store.storageState.working
            && !store.editorDirty && store.positionNoteRequest == nil && store.route == "reader"
            && (redo ? redoEntries.last : undoEntries.last)?.owner.matches(store) == true
    }
    func apply(store: AppStore, redo: Bool) async {
        guard canApply(store: store, redo: redo), let entry = redo ? redoEntries.last : undoEntries.last,
              let bookID = entry.owner.bookID, let sourceHash = entry.owner.sourceHash else { return }
        applying = true; defer { applying = false }
        store.isBusy = true; store.isCommittingLocalWrite = true
        defer { store.isBusy = false; store.isCommittingLocalWrite = false }
        let epoch = generation
        do {
            let saved = try await store.repository.applyReadingEditUndo(bookID: bookID, sourceHash: sourceHash, change: entry.change)
            guard epoch == generation, entry.owner.matches(store) else { return }
            let inverse: ReadingEditUndoChange
            switch entry.change {
            case .annotations(let expected, let desired): inverse = .annotations(expected: desired, desired: expected)
            case .placement(let id, let expected, let desired): inverse = .placement(documentID: id, expected: desired, desired: expected)
            case .bookmark(let id, let expected, let desired): inverse = .bookmark(unitID: id, expected: desired, desired: expected)
            case .note(let expected, let desired):
                guard let document = saved.documents.first(where: { $0.id == desired.document.id }) else { return }
                inverse = .note(expected: .init(document: document, markdown: desired.markdown, placement: saved.readerCollections?.notePlacements?[document.id]), desired: expected)
            }
            let reverse = Entry(owner: entry.owner, title: entry.title, change: inverse, bytes: entry.bytes)
            if redo { redoEntries.removeLast(); undoEntries.append(reverse) }
            else { undoEntries.removeLast(); redoEntries.append(reverse) }
            store.publish(saved)
            if let id = store.selectedDocumentID, let document = saved.activeDocuments.first(where: { $0.id == id }) { await store.openDocument(document, present: false) }
            else { store.reconcileSelectionAfterTrash(in: saved) }
            store.activity = (redo ? "已重做：" : "已撤销：") + entry.title
        } catch { if epoch == generation, entry.owner.matches(store) { store.errorMessage = error.localizedDescription } }
    }
    func recordAnnotations(before: BookProject, after: BookProject, ids: Set<String>, owner: WorkspacePickerOwner) {
        let expected = (after.readerAnnotations ?? []).filter { ids.contains($0.id) }
        let desired = expected.map { record -> ReaderAnnotation in
            if let previous = before.readerAnnotations?.first(where: { $0.id == record.id }) { return previous }
            var removed = record; removed.trashedAt = .now; return removed
        }
        guard !expected.isEmpty, expected != desired else { return }
        record(.annotations(expected: expected, desired: desired), title: "阅读标记", owner: owner)
    }
    func recordNote(before: ReadingNoteUndoSnapshot?, after: ReadingNoteUndoSnapshot, owner: WorkspacePickerOwner) {
        var desired = before ?? after
        if before == nil { desired.document.trashedAt = .now }
        record(.note(expected: after, desired: desired), title: before == nil ? "创建便签" : "修改便签", owner: owner)
    }
}

/// Native text views keep first refusal of undo. Only after their responder
/// chain reaches the reading workspace do Cmd-Z / Shift-Cmd-Z edit the book.
struct ReaderEditUndoBridge: NSViewRepresentable {
    @EnvironmentObject private var store: AppStore
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.router.store = store; view.install() }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.uninstall() }
    final class Anchor: NSView {
        let router = Router()
        weak var installedRoot: NSView?
        private var menuObserver: NSObjectProtocol?
        private var undoKeyMonitor: Any?
        private var menuBindingScheduled = false
        private var menuBindingGeneration = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        func install() {
            guard let root = window?.contentView else { return }
            router.window = window
            if root !== installedRoot {
                uninstall(); router.nextResponder = root.nextResponder; root.nextResponder = router; installedRoot = root
                menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { [weak self] note in
                    guard let self, let changed = note.object as? NSMenu, let main = NSApp.mainMenu,
                          changed === main || (main.items.contains { $0.submenu === changed }
                            && changed.items.contains { $0.action == NSSelectorFromString("undo:") || $0.action == NSSelectorFromString("redo:") }) else { return }
                    self.scheduleMenuBinding()
                }
                // PDFKit and SwiftUI can consume the stock key equivalent
                // before the bound menu target is called. Claim only an
                // applicable reading edit in this window; native text editing
                // and every other shortcut keep their normal dispatch.
                undoKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, event.window === self.window,
                          self.router.consumeReadingUndoKey(event) else { return event }
                    return nil
                }
            }
            router.bindMenus()
        }
        private func scheduleMenuBinding() {
            guard !menuBindingScheduled else { return }; menuBindingScheduled = true
            let generation = menuBindingGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.menuBindingGeneration == generation else { return }
                self.menuBindingScheduled = false
                guard self.installedRoot != nil else { return }; self.router.bindMenus()
            }
        }
        func uninstall() {
            menuBindingGeneration &+= 1; menuBindingScheduled = false
            if let root = installedRoot, root.nextResponder === router { root.nextResponder = router.nextResponder }
            if let menuObserver { NotificationCenter.default.removeObserver(menuObserver); self.menuObserver = nil }
            if let undoKeyMonitor { NSEvent.removeMonitor(undoKeyMonitor); self.undoKeyMonitor = nil }
            router.unbindMenus(); installedRoot = nil; router.nextResponder = nil
        }
    }
    final class Router: NSResponder, NSMenuItemValidation, NSUserInterfaceValidations {
        weak var store: AppStore?
        weak var window: NSWindow?
        private var textEditor: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }
        func consumeReadingUndoKey(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard event.charactersIgnoringModifiers?.lowercased() == "z",
                  flags == .command || flags == [.command, .shift],
                  window?.isKeyWindow == true, textEditor == nil, let store,
                  store.readerEditUndo.canApply(store: store, redo: flags.contains(.shift)) else { return false }
            if flags.contains(.shift) { redo(nil) } else { undo(nil) }
            return true
        }
        // A window can itself be the first responder after a context popover.
        // Its stock undo: stops the responder search even with no window undo
        // history. Bind just these native menu items explicitly, while keeping
        // the active text editor's own manager ahead of the reading journal.
        func bindMenus() {
            for item in undoMenuItems where item.target !== self { item.target = self }
        }
        func unbindMenus() { for item in undoMenuItems where item.target === self { item.target = nil } }
        private var undoMenuItems: [NSMenuItem] {
            (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }.filter { $0.action == #selector(undo(_:)) || $0.action == #selector(redo(_:)) }
        }
        @objc func undo(_ sender: Any?) {
            if let text = textEditor { if text.isEditable && text.allowsUndo && text.undoManager?.canUndo == true { text.undoManager?.undo() }; return }
            if window?.isKeyWindow == true, let store { Task { await store.readerEditUndo.apply(store: store, redo: false) } }
        }
        @objc func redo(_ sender: Any?) {
            if let text = textEditor { if text.isEditable && text.allowsUndo && text.undoManager?.canRedo == true { text.undoManager?.redo() }; return }
            if window?.isKeyWindow == true, let store { Task { await store.readerEditUndo.apply(store: store, redo: true) } }
        }
        func validateMenuItem(_ item: NSMenuItem) -> Bool { validate(action: item.action) }
        func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool { validate(action: item.action) }
        private func validate(action: Selector?) -> Bool {
            guard let store else { return false }
            if let text = textEditor {
                guard text.isEditable && text.allowsUndo else { return false }
                return action == #selector(redo(_:)) ? text.undoManager?.canRedo == true : text.undoManager?.canUndo == true
            }
            guard window?.isKeyWindow == true else { return false }
            if action == #selector(undo(_:)) { return store.readerEditUndo.canApply(store: store, redo: false) }
            if action == #selector(redo(_:)) { return store.readerEditUndo.canApply(store: store, redo: true) }
            return false
        }
    }
}
