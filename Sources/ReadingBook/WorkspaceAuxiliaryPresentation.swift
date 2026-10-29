import SwiftUI
import AppKit

/// Auxiliary panels do not participate in the persisted canvas route. Keeping
/// the route truthful also keeps the mounted reader and graph memory identities.
enum WorkspaceAuxiliaryKind: String {
    case search = "librarySearch", trash, notes = "editor"
    var idealSize: CGSize {
        switch self {
        case .search: return CGSize(width: 900, height: 680)
        case .trash: return CGSize(width: 820, height: 650)
        case .notes: return CGSize(width: 1100, height: 760)
        }
    }
}

struct WorkspaceAuxiliaryPresentation: Identifiable, Equatable {
    let id = UUID()
    let kind: WorkspaceAuxiliaryKind
    let libraryRoot: URL
    let bookID: String?
    let sourceHash: String?

    @MainActor init(_ kind: WorkspaceAuxiliaryKind, store: AppStore) {
        self.kind = kind; libraryRoot = store.libraryRootURL.standardizedFileURL
        bookID = store.bookID; sourceHash = store.book?.sourceHash
    }
    @MainActor func matches(_ store: AppStore) -> Bool {
        guard libraryRoot == store.libraryRootURL.standardizedFileURL else { return false }
        // Library-wide search and recovery may deliberately adopt another book.
        // Notes, including their native editor/undo session, belong to one source.
        return kind != .notes || (bookID == store.bookID && sourceHash == store.book?.sourceHash)
    }
}

enum WorkspaceNavigationIntent: Equatable {
    case route(String)
    case dismissAuxiliary(UUID)
    case searchResult(UUID)
    case internalURL(URL)
}

enum WorkspaceAuxiliaryNavigationAdmission: Equatable {
    case allowed
    case requiresNotesDecision(WorkspaceAuxiliaryPresentation)
    case ignored
}

/// Production entrypoints are shared with the fixture-only native regression.
/// Admission never modifies source position or document contents; a dirty note
/// is resolved by the Workspace confirmation before commit is retried.
@MainActor enum WorkspaceAuxiliaryNavigation {
    static func admission(for intent: WorkspaceNavigationIntent, store: AppStore) -> WorkspaceAuxiliaryNavigationAdmission {
        guard !store.isSavingDocument else { return .ignored }
        let leavesNotes: Bool
        switch intent {
        case .route(let route): leavesNotes = !["editor", "librarySearch", "trash", "models", "plugins", "book.scheme", "preferences"].contains(route)
        case .dismissAuxiliary(let id):
            guard let owner = store.activeAuxiliaryPresentation, owner.id == id, owner.matches(store) else { return .ignored }
            leavesNotes = owner.kind == .notes
        case .searchResult(let id):
            guard let owner = store.auxiliaryPresentation, owner.id == id, owner.kind == .search, owner.matches(store) else { return .ignored }
            leavesNotes = true
        case .internalURL: leavesNotes = true
        }
        guard store.finishWorkspaceNotesEditing() else { return .ignored }
        if leavesNotes, store.editorDirty, let owner = store.notesPresentation, owner.matches(store) {
            return .requiresNotesDecision(owner)
        }
        return .allowed
    }
    @discardableResult static func commit(_ intent: WorkspaceNavigationIntent, store: AppStore) -> Bool {
        guard admission(for: intent, store: store) == .allowed else { return false }
        switch intent {
        case .route(let route):
            guard !["models", "plugins", "book.scheme", "preferences"].contains(route) else { return false }
            if let kind = WorkspaceAuxiliaryKind(rawValue: route) { store.presentWorkspaceAuxiliary(kind) }
            else { store.commitWorkspaceRoute(route) }
        case .dismissAuxiliary(let id): store.dismissWorkspaceAuxiliary(id)
        case .searchResult: store.commitWorkspaceRoute("reader")
        case .internalURL(let url):
            let root = store.libraryRootURL
            Task { @MainActor in
                guard store.libraryRootURL == root else { return }
                await store.openInternalURL(url)
            }
        }
        return true
    }
}

/// Weak native references cannot retain an obsolete window/editor after a book
/// or library change. Restoration happens only after the owned panel has left.
@MainActor final class WorkspaceAuxiliaryFocus {
    private weak var window: NSWindow?
    private weak var responder: NSResponder?
    private var owner: WorkspaceAuxiliaryPresentation?
    private var notesID: UUID?
    func capture(store: AppStore) {
        if responder != nil, notesID == store.notesPresentation?.id { return }
        guard let currentWindow = NSApp?.keyWindow, let currentResponder = currentWindow.firstResponder else { return }
        window = currentWindow; responder = currentResponder
        owner = WorkspaceAuxiliaryPresentation(.notes, store: store); notesID = store.notesPresentation?.id
    }
    func restore(store: AppStore) {
        let window = window, responder = responder, owner = owner, notesID = notesID
        self.window = nil; self.responder = nil; self.owner = nil; self.notesID = nil
        DispatchQueue.main.async { [weak store, weak window, weak responder] in
            guard let store, let window, window === NSApp?.keyWindow,
                  owner?.matches(store) == true else { return }
            if let notesID {
                guard store.isNotesForeground, store.notesPresentation?.id == notesID else { return }
            } else { guard !store.hasWorkspaceAuxiliary else { return } }
            if let view = responder as? NSView, view.window === window, !view.isHiddenOrHasHiddenAncestor {
                _ = window.makeFirstResponder(view)
            } else { _ = window.makeFirstResponder(nil) }
        }
    }
}

@MainActor extension AppStore {
    var isNotesPresented: Bool { notesPresentation?.matches(self) == true }
    var isNotesForeground: Bool { isNotesPresented && auxiliaryPresentation == nil }
    var hasWorkspaceAuxiliary: Bool { auxiliaryPresentation != nil || isNotesPresented }
    var activeAuxiliaryPresentation: WorkspaceAuxiliaryPresentation? { auxiliaryPresentation ?? notesPresentation }

    @discardableResult func finishWorkspaceNotesEditing() -> Bool {
        guard isNotesPresented else { return true }
        if isNotesForeground { workspaceCoveredNotesFocus.capture(store: self) }
        guard NoteMarkdownEditorSession.finishActiveEditing(libraryRoot: libraryRootURL, bookID: bookID) else {
            documentError = "请先完成当前文字输入；笔记和草稿已保留。"; return false
        }
        return true
    }
    func presentWorkspaceAuxiliary(_ kind: WorkspaceAuxiliaryKind) {
        guard !isSavingDocument, kind == .notes || finishWorkspaceNotesEditing() else { return }
        if kind == .notes {
            guard book != nil else { return }
            if !hasWorkspaceAuxiliary { workspaceAuxiliaryFocus.capture(store: self) }
            if !isNotesPresented { notesPresentation = WorkspaceAuxiliaryPresentation(.notes, store: self) }
            auxiliaryPresentation = nil
        } else {
            if !hasWorkspaceAuxiliary { workspaceAuxiliaryFocus.capture(store: self) }
            if auxiliaryPresentation?.kind != kind || auxiliaryPresentation?.matches(self) != true {
                auxiliaryPresentation = WorkspaceAuxiliaryPresentation(kind, store: self)
            }
        }
        queryAllowsOrganizing = false
        if kind == .notes { rememberWorkspaceNavigation() }
    }
    func dismissWorkspaceAuxiliary(_ id: UUID) {
        if let owner = auxiliaryPresentation, owner.id == id, owner.matches(self) { auxiliaryPresentation = nil }
        else if let owner = notesPresentation, owner.id == id, owner.matches(self), !editorDirty { notesPresentation = nil }
        else { return }
        if isNotesForeground { workspaceCoveredNotesFocus.restore(store: self) }
        else if !hasWorkspaceAuxiliary { workspaceAuxiliaryFocus.restore(store: self) }
    }
    /// Only a validated navigation transaction may replace the base canvas.
    /// The regular route setter redirects dirty-note departures to Workspace's
    /// existing save/discard/cancel coordinator.
    func commitWorkspaceRoute(_ value: String, preservingAuxiliary: Bool = false) {
        if let kind = WorkspaceAuxiliaryKind(rawValue: value) { presentWorkspaceAuxiliary(kind); return }
        guard !["models", "plugins", "book.scheme", "preferences"].contains(value) else { requestedWorkspaceRoute = value; return }
        if !preservingAuxiliary { auxiliaryPresentation = nil; notesPresentation = nil }
        baseWorkspaceRoute = value
        if value != "query" { queryAllowsOrganizing = false }
        rememberWorkspaceNavigation()
        if !preservingAuxiliary { workspaceAuxiliaryFocus.restore(store: self) }
    }
    func clearWorkspaceAuxiliaryForNewSource() {
        // A search may be in the middle of its validated cross-book admission.
        notesPresentation = nil
    }
}

/// One outer material owns the shadow. Child panels supply their content only;
/// the full-size background remains the original mounted canvas underneath.
struct WorkspaceAuxiliaryShell<Content: View>: View {
    let kind: WorkspaceAuxiliaryKind
    let viewport: CGSize
    let dismiss: () -> Void
    let content: Content
    @Environment(\.readingReduceTransparency) private var reduceTransparency
    init(kind: WorkspaceAuxiliaryKind, viewport: CGSize, dismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.kind = kind; self.viewport = viewport; self.dismiss = dismiss; self.content = content()
    }
    var body: some View {
        ZStack {
            Group {
                if reduceTransparency { Color.black.opacity(0.10) }
                else { Rectangle().fill(.ultraThinMaterial).opacity(0.60).overlay(Color.black.opacity(0.035)) }
            }.contentShape(Rectangle()).onTapGesture(perform: dismiss)
            content
                .frame(width: min(kind.idealSize.width, max(1, viewport.width - 48)),
                       height: min(kind.idealSize.height, max(1, viewport.height - 48)))
                .readingGlass(radius: 24, prominent: true)
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous)).onTapGesture { }
                .accessibilityAddTraits(.isModal)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
