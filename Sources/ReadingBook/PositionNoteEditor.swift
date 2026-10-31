import SwiftUI
import ReadingCore
import CryptoKit

@MainActor enum PositionNoteTypography {
    static func native(_ placement: ReadingNotePlacement?) -> NSFont {
        let family = placement?.fontFamily ?? "serif", size = placement?.fontSize ?? 15
        if family == "system" { return .systemFont(ofSize: size) }
        if family == "monospaced" { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        if family == "serif" { return NSFont(name: "Songti SC", size: size) ?? NSFont(name: "STSong", size: size) ?? .systemFont(ofSize: size) }
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? .systemFont(ofSize: size)
    }
}

private struct PositionNoteDraft: Codable {
    var bookID: String
    var sourceHash: String
    var document: DocumentRecord?
    var contentHash: String?
    var placement: ReadingNotePlacement?
    var text: String
}

struct PositionNoteRequest: Identifiable {
    let id = UUID()
    let owner: WorkspacePickerOwner
    var document: DocumentRecord?
    var contentHash: String?
    var placement: ReadingNotePlacement?
    var text = ""
    var recovered = false
}
struct PositionNoteBindingRequest: Identifiable {
    let id = UUID()
    let owner: WorkspacePickerOwner
    let documentID: String
}
enum PositionNoteCommand { case edit, openNotebook, relocate, trash }
@MainActor final class PositionNoteActionRelay: ObservableObject {
    var pending: (id: String, owner: WorkspacePickerOwner, command: PositionNoteCommand)?
    func finish(store: AppStore) {
        guard let value = pending else { return }; pending = nil
        store.performPositionNoteCommand(value.command, id: value.id, owner: value.owner)
    }
}

@MainActor extension AppStore {
    func performPositionNoteCommand(_ command: PositionNoteCommand, id: String, owner: WorkspacePickerOwner) {
        guard owner.matches(self), let document = book?.activeDocuments.first(where: { $0.id == id }) else { return }
        switch command {
        case .edit: Task { await editPositionNote(id) }
        case .openNotebook: Task { await openDocument(document) }
        case .relocate: requestPositionNoteBinding(id)
        case .trash: requestDeletion(.document, id: id, title: document.title)
        }
    }
    var activeNotePlacements: [String: ReadingNotePlacement] {
        guard let book, let placements = readerCollections.notePlacements, !placements.isEmpty else { return [:] }
        let active = Set(book.activeDocuments.map(\.id))
        let units = Dictionary(book.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return placements.filter { id, placement in
            active.contains(id) && placement.sourceHash == book.sourceHash && units[placement.unitID].map { $0.page == placement.page } == true
        }
    }
    func beginPositionNote(page: Int? = nil, x: Double = 0.5, y: Double = 0.5) {
        guard positionNoteRequest == nil else { return }
        guard let book, let unit = page.flatMap({ p in book.units.first { $0.page == p } }) ?? selectedUnit else { return }
        if let binding = positionNoteBinding {
            positionNoteBinding = nil
            guard binding.owner.matches(self) else { return }
            var placement = readerCollections.notePlacements?[binding.documentID]
                ?? ReadingNotePlacement(sourceHash: book.sourceHash, unitID: unit.id, page: unit.page, x: x, y: y)
            placement.sourceHash = book.sourceHash; placement.unitID = unit.id; placement.page = unit.page; placement.x = x; placement.y = y
            Task { await organizeReaderCollections(.setNotePlacement(binding.documentID, placement), owner: binding.owner) }
            return
        }
        if let data = UserDefaults.standard.data(forKey: positionNoteDraftKey()), data.count <= 20_000_000,
           let draft = try? JSONDecoder().decode(PositionNoteDraft.self, from: data), draft.bookID == book.id, draft.sourceHash == book.sourceHash {
            positionNoteRequest = PositionNoteRequest(owner: WorkspacePickerOwner(store: self), document: draft.document,
                contentHash: draft.contentHash, placement: draft.placement, text: draft.text, recovered: true)
            return
        }
        let placement = ReadingNotePlacement(sourceHash: book.sourceHash, unitID: unit.id, page: unit.page, x: x, y: y)
        positionNoteRequest = PositionNoteRequest(owner: WorkspacePickerOwner(store: self), placement: placement)
    }
    func requestPositionNoteBinding(_ id: String) {
        guard !editorDirty, book?.activeDocuments.contains(where: { $0.id == id }) == true else { errorMessage = "请先保存当前笔记，再选择位置。"; return }
        if let notes = notesPresentation { dismissWorkspaceAuxiliary(notes.id) }
        readingCompanionVisible = false; readingSourceMode = "original"
        positionNoteBinding = .init(owner: WorkspacePickerOwner(store: self), documentID: id)
        requestedWorkspaceRoute = "reader"
    }
    private func positionNoteDraftKey(documentID: String? = nil) -> String {
        "position-note-draft-" + SHA256.hash(data: Data((collectionOwnerKey + "|" + (documentID ?? "@new")).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func persistPositionNoteDraft(_ request: PositionNoteRequest, text: String, placement: ReadingNotePlacement?) {
        guard request.owner.matches(self), positionNoteRequest?.id == request.id, let book else { return }
        let draft = PositionNoteDraft(bookID: book.id, sourceHash: book.sourceHash, document: request.document,
            contentHash: request.contentHash, placement: placement, text: text)
        if let data = try? JSONEncoder().encode(draft), data.count <= 20_000_000 { UserDefaults.standard.set(data, forKey: positionNoteDraftKey(documentID: request.document?.id)) }
    }
    func discardPositionNoteDraft(_ request: PositionNoteRequest) {
        guard request.owner.matches(self) else { return }; UserDefaults.standard.removeObject(forKey: positionNoteDraftKey(documentID: request.document?.id))
    }
    func editPositionNote(_ id: String) async {
        guard let book, let document = book.activeDocuments.first(where: { $0.id == id }) else { return }
        let owner = WorkspacePickerOwner(store: self)
        do {
            let value = try await repository.readDocumentSnapshot(bookID: book.id, document: document)
            guard owner.matches(self), self.book?.activeDocuments.first(where: { $0.id == id }) == document else { return }
            if let data = UserDefaults.standard.data(forKey: positionNoteDraftKey(documentID: id)), data.count <= 20_000_000,
               let draft = try? JSONDecoder().decode(PositionNoteDraft.self, from: data), draft.bookID == book.id,
               draft.sourceHash == book.sourceHash, draft.document?.id == id {
                positionNoteRequest = PositionNoteRequest(owner: owner, document: draft.document, contentHash: draft.contentHash,
                    placement: draft.placement, text: draft.text, recovered: true); return
            }
            positionNoteRequest = PositionNoteRequest(owner: owner, document: document, contentHash: value.contentHash,
                placement: readerCollections.notePlacements?[id], text: value.markdown)
        } catch { if owner.matches(self) { errorMessage = error.localizedDescription } }
    }
    func savePositionNote(_ request: PositionNoteRequest, text: String, placement: ReadingNotePlacement?, asNew: Bool = false) async throws {
        guard request.owner.matches(self), let book, !storageState.working, !isSavingDocument else { throw ReadingError.invalid("书籍或书库已变化，请先保留当前文字。") }
        if !asNew && request.document?.id == selectedDocumentID && editorDirty { throw ReadingError.invalid("这篇笔记在编辑器中还有未保存修改，请先保存或保留草稿。") }
        let root = libraryRootURL
        let title = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "笔记"
        var document = (asNew ? nil : request.document) ?? DocumentRecord(title: String(title.prefix(30)))
        document.updatedAt = .now
        isSavingDocument = true; defer { isSavingDocument = false }
        let saved = try await repository.saveLatestNote(bookID: book.id, sourceHash: book.sourceHash, document: document, markdown: text,
            expectedDocument: asNew ? nil : request.document, expectedContentHash: asNew ? nil : request.contentHash, notePlacement: placement)
        guard request.owner.matches(self), libraryRootURL == root else { return }
        publish(saved)
        discardPositionNoteDraft(request)
        if selectedDocumentID == document.id { await openDocument(saved.activeDocuments.first { $0.id == document.id } ?? document, present: false) }
        positionNoteRequest = nil
    }
}

struct PositionNoteEditor: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var typography: ReadingTypographySettings
    let request: PositionNoteRequest
    @State private var text: String
    @State private var placement: ReadingNotePlacement?
    @State private var error: String?
    @State private var saving = false
    @State private var confirmDiscard = false
    @StateObject private var editorSession = NoteMarkdownEditorSession()
    @State private var draftSaveTask: Task<Void, Never>?
    init(request: PositionNoteRequest) { self.request = request; _text = State(initialValue: request.text); _placement = State(initialValue: request.placement) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(request.document == nil ? "写一张便签" : "编辑笔记").font(.system(size: 20, weight: .semibold)); Spacer()
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("关闭编辑")
            }
            if request.recovered { Text("已恢复上次未保存的便签").font(.system(size: 12)).foregroundStyle(.secondary) }
            NoteMarkdownEditor(session: editorSession, markdown: $text, libraryRoot: request.owner.libraryRoot,
                bookID: request.owner.bookID, documentID: request.document?.id, font: noteNSFont,
                expanded: false, editable: !saving, visible: true)
                .padding(16).background(Palette.paper, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.accent.opacity(0.12)) }.accessibilityLabel("便签正文")
            if placement != nil {
                HStack(spacing: 16) {
                    Picker("字体", selection: Binding(get: { placement?.fontFamily ?? "serif" }, set: { placement?.fontFamily = $0 })) {
                        Text("宋体").tag("serif"); Text("系统字体").tag("system"); Text("等宽字体").tag("monospaced")
                        ForEach(typography.availableFontFamilies, id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: 300).help("只调整这张便签的字体，不改变原书或其他笔记。")
                    Stepper("字号 \(Int(placement?.fontSize ?? 15))", value: Binding(get: { placement?.fontSize ?? 15 }, set: { placement?.fontSize = $0 }), in: 10...28, step: 1)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(Palette.copper).textSelection(.enabled) }
            if error != nil && request.document != nil {
                Button("保留原笔记，另存为新笔记") {
                    guard editorSession.finishEditing() else { return }; saving = true
                    Task { do { try await store.savePositionNote(request, text: text, placement: placement, asNew: true) }
                        catch { self.error = error.localizedDescription }; saving = false }
                }.buttonStyle(ReadingToolbarButtonStyle()).disabled(saving)
            }
            HStack {
                Label(placement?.page.map { "绑定第 \($0) 页的位置" } ?? (placement == nil ? "未绑定位置" : "绑定当前章节"), systemImage: placement == nil ? "note.text" : "mappin")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { close() }.buttonStyle(ReadingToolbarButtonStyle()).disabled(saving)
                Button(saving ? "保存中…" : "保存") {
                    guard editorSession.finishEditing() else { error = "请先完成当前文字输入，再保存。"; return }
                    saving = true; error = nil
                    Task { do { try await store.savePositionNote(request, text: text, placement: placement) }
                        catch { self.error = error.localizedDescription }; saving = false }
                }.buttonStyle(ReadingToolbarButtonStyle(selected: true)).keyboardShortcut("s", modifiers: .command)
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(minWidth: 640, idealWidth: 720, minHeight: 450, idealHeight: 560)
            .background(Palette.canvas).interactiveDismissDisabled(hasChanges || saving)
            .confirmationDialog("放弃这次未保存的修改？", isPresented: $confirmDiscard) {
                Button("继续编辑", role: .cancel) { }
                Button("保留草稿并关闭") { store.persistPositionNoteDraft(request, text: text, placement: placement); store.positionNoteRequest = nil }
                Button("放弃修改", role: .destructive) { store.discardPositionNoteDraft(request); store.positionNoteRequest = nil }
            } message: { Text("已经保存的笔记与原书保留。") }
            .onExitCommand { close() }
            .onChange(of: text) { _, _ in scheduleDraft() }
            .onChange(of: placement) { _, _ in scheduleDraft() }
            .onDisappear { draftSaveTask?.cancel() }
    }
    private var hasChanges: Bool { text != request.text || placement != request.placement || request.recovered || (request.document == nil && !text.isEmpty) }
    private var noteNSFont: NSFont {
        PositionNoteTypography.native(placement)
    }
    private func scheduleDraft() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            store.persistPositionNoteDraft(request, text: text, placement: placement)
        }
    }
    private func close() { if saving { return }; guard editorSession.finishEditing() else { return }; if hasChanges { confirmDiscard = true } else { store.positionNoteRequest = nil } }
}
