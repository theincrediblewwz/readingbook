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
struct PositionNoteDraftBuffer {
    let requestID: UUID
    let text: String
    let placement: ReadingNotePlacement?
}

struct PositionNoteRequest: Identifiable {
    let id = UUID()
    let owner: WorkspacePickerOwner
    var document: DocumentRecord?
    var contentHash: String?
    var placement: ReadingNotePlacement?
    var text = ""
    var recovered = false
    var origin: PositionNoteEditorOrigin?
}
/// Transient presentation geometry only; never saved into the book or draft.
struct PositionNoteEditorOrigin {
    let screenFrame: CGRect
    var degrees: Double = 0
}
struct PositionNoteBindingRequest: Identifiable {
    let id = UUID()
    let owner: WorkspacePickerOwner
    let documentID: String
}
enum PositionNoteCommand { case edit, openNotebook, relocate, unbind, trash }


@MainActor extension AppStore {
    func performPositionNoteCommand(_ command: PositionNoteCommand, id: String, owner: WorkspacePickerOwner, origin: PositionNoteEditorOrigin? = nil) {
        guard owner.matches(self), let document = book?.activeDocuments.first(where: { $0.id == id }) else { return }
        switch command {
        case .edit: Task { await editPositionNote(id, origin: origin) }
        case .openNotebook: Task { await openDocument(document) }
        case .relocate: requestPositionNoteBinding(id)
        case .unbind: Task { await organizeReaderCollections(.setNotePlacement(id, nil), owner: owner) }
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
    func beginPositionNote(page: Int? = nil, x: Double = 0.5, y: Double = 0.5, quote: ReadingNoteSourceQuote? = nil) {
        guard positionNoteRequest == nil else { return }
        guard let book, let unit = page == nil ? selectedUnit : book.units.first(where: { $0.page == page }) else { return }
        guard (try? quote?.validate()) != nil || quote == nil else { return }
        positionNoteOpenID = nil
        if let binding = positionNoteBinding {
            guard binding.owner.matches(self), !isOrganizingCollections else { return }
            var placement = readerCollections.notePlacements?[binding.documentID]
                ?? ReadingNotePlacement(sourceHash: book.sourceHash, unitID: unit.id, page: unit.page, x: x, y: y)
            placement.sourceHash = book.sourceHash; placement.unitID = unit.id; placement.page = unit.page; placement.x = x; placement.y = y; placement.quote = quote
            Task {
                await organizeReaderCollections(.setNotePlacement(binding.documentID, placement), owner: binding.owner)
                if positionNoteBinding?.id == binding.id { positionNoteBinding = nil }
            }
            return
        }
        if let data = UserDefaults.standard.data(forKey: positionNoteDraftKey()), data.count <= 20_000_000,
           let draft = try? JSONDecoder().decode(PositionNoteDraft.self, from: data), draft.bookID == book.id, draft.sourceHash == book.sourceHash {
            positionNoteRequest = PositionNoteRequest(owner: WorkspacePickerOwner(store: self), document: draft.document,
                contentHash: draft.contentHash, placement: draft.placement, text: draft.text, recovered: true)
            return
        }
        let placement = ReadingNotePlacement(sourceHash: book.sourceHash, unitID: unit.id, page: unit.page, x: x, y: y,
            paperStyle: PositionNoteBackground.style(nil, inherited: UserDefaults.standard.string(forKey: "reading.paperStyle") ?? "plain").rawValue, quote: quote)
        positionNoteRequest = PositionNoteRequest(owner: WorkspacePickerOwner(store: self), placement: placement)
    }
    func requestPositionNoteBinding(_ id: String) {
        guard !isOrganizingCollections else { return }
        guard !editorDirty, book?.activeDocuments.contains(where: { $0.id == id }) == true else { errorMessage = "请先保存当前笔记，再选择位置。"; return }
        if let notes = notesPresentation { dismissWorkspaceAuxiliary(notes.id) }
        readingCompanionVisible = false; readingSourceMode = "original"
        positionNoteBinding = .init(owner: WorkspacePickerOwner(store: self), documentID: id)
        requestedWorkspaceRoute = "reader"
    }
    private func positionNoteDraftKey(documentID: String? = nil, owner: WorkspacePickerOwner? = nil) -> String {
        let key = owner.map { $0.libraryRoot.path + "|" + ($0.bookID ?? "") + "|" + ($0.sourceHash ?? "") } ?? collectionOwnerKey
        return "position-note-draft-" + SHA256.hash(data: Data((key + "|" + (documentID ?? "@new")).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func persistPositionNoteDraft(_ request: PositionNoteRequest, text: String, placement: ReadingNotePlacement?) {
        guard request.owner.matches(self), positionNoteRequest?.id == request.id, let book else { return }
        writePositionNoteDraft(request, bookID: book.id, sourceHash: book.sourceHash, text: text, placement: placement)
    }
    private func writePositionNoteDraft(_ request: PositionNoteRequest, bookID: String, sourceHash: String, text: String, placement: ReadingNotePlacement?) {
        let draft = PositionNoteDraft(bookID: bookID, sourceHash: sourceHash, document: request.document,
            contentHash: request.contentHash, placement: placement, text: text)
        if let data = try? JSONEncoder().encode(draft), data.count <= 20_000_000 { UserDefaults.standard.set(data, forKey: positionNoteDraftKey(documentID: request.document?.id, owner: request.owner)) }
    }
    func cancelPositionNoteForSourceChange() {
        if let request = positionNoteRequest, let buffer = positionNoteDraftBuffer, buffer.requestID == request.id,
           let bookID = request.owner.bookID, let hash = request.owner.sourceHash {
            writePositionNoteDraft(request, bookID: bookID, sourceHash: hash, text: buffer.text, placement: buffer.placement)
        }
        positionNoteRequest = nil; positionNoteOpenID = nil; positionNoteDraftBuffer = nil
    }
    func discardPositionNoteDraft(_ request: PositionNoteRequest) {
        guard request.owner.matches(self) else { return }; UserDefaults.standard.removeObject(forKey: positionNoteDraftKey(documentID: request.document?.id))
        if positionNoteDraftBuffer?.requestID == request.id { positionNoteDraftBuffer = nil }
    }
    func editPositionNote(_ id: String, origin: PositionNoteEditorOrigin? = nil) async {
        guard positionNoteRequest == nil, let book, let document = book.activeDocuments.first(where: { $0.id == id }) else { return }
        let owner = WorkspacePickerOwner(store: self)
        let opening = UUID(); positionNoteOpenID = opening
        defer { if positionNoteOpenID == opening { positionNoteOpenID = nil } }
        do {
            let value = try await repository.readDocumentSnapshot(bookID: book.id, document: document)
            guard owner.matches(self), positionNoteOpenID == opening, positionNoteRequest == nil,
                  self.book?.activeDocuments.first(where: { $0.id == id }) == document else { return }
            if let data = UserDefaults.standard.data(forKey: positionNoteDraftKey(documentID: id)), data.count <= 20_000_000,
               let draft = try? JSONDecoder().decode(PositionNoteDraft.self, from: data), draft.bookID == book.id,
               draft.sourceHash == book.sourceHash, draft.document?.id == id {
                positionNoteRequest = PositionNoteRequest(owner: owner, document: draft.document, contentHash: draft.contentHash,
                    placement: draft.placement, text: draft.text, recovered: true, origin: origin); return
            }
            positionNoteRequest = PositionNoteRequest(owner: owner, document: document, contentHash: value.contentHash,
                placement: readerCollections.notePlacements?[id], text: value.markdown, origin: origin)
        } catch { if owner.matches(self), positionNoteOpenID == opening { errorMessage = error.localizedDescription } }
    }
    func savePositionNote(_ request: PositionNoteRequest, text: String, placement: ReadingNotePlacement?, asNew: Bool = false) async throws {
        guard request.owner.matches(self), let book, !storageState.working, !isSavingDocument else { throw ReadingError.invalid("书籍或书库已变化，请先保留当前文字。") }
        if !asNew && request.document?.id == selectedDocumentID && editorDirty { throw ReadingError.invalid("这篇笔记在编辑器中还有未保存修改，请先保存或保留草稿。") }
        let root = libraryRootURL
        let previous: ReadingNoteUndoSnapshot?
        if !asNew, let document = request.document {
            let snapshot = try await repository.readDocumentSnapshot(bookID: book.id, document: document)
            previous = .init(document: document, markdown: snapshot.markdown, placement: request.placement)
        } else { previous = nil }
        let title = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "笔记"
        var document = (asNew ? nil : request.document) ?? DocumentRecord(title: String(title.prefix(30)))
        document.updatedAt = .now
        isSavingDocument = true; defer { isSavingDocument = false }
        let saved = try await repository.saveLatestNote(bookID: book.id, sourceHash: book.sourceHash, document: document, markdown: text,
            expectedDocument: asNew ? nil : request.document, expectedContentHash: asNew ? nil : request.contentHash, notePlacement: placement,
            expectedPlacement: asNew || request.document == nil ? nil : .unchanged(request.placement))
        guard request.owner.matches(self), libraryRootURL == root else { return }
        if let record = saved.documents.first(where: { $0.id == document.id }) {
            readerEditUndo.recordNote(before: previous,
                after: .init(document: record, markdown: text, placement: saved.readerCollections?.notePlacements?[document.id]), owner: request.owner)
        }
        publish(saved)
        discardPositionNoteDraft(request)
        if selectedDocumentID == document.id { await openDocument(saved.activeDocuments.first { $0.id == document.id } ?? document, present: false) }
        if positionNoteRequest?.id == request.id { positionNoteRequest = nil }
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
    @State private var showsTypography = false
    @State private var showsError = false
    @StateObject private var editorSession = NoteMarkdownEditorSession()
    @State private var draftSaveTask: Task<Void, Never>?
    init(request: PositionNoteRequest) { self.request = request; _text = State(initialValue: request.text); _placement = State(initialValue: request.placement) }
    var body: some View {
        NoteMarkdownEditor(session: editorSession, markdown: $text, libraryRoot: request.owner.libraryRoot,
            bookID: request.owner.bookID, documentID: request.document?.id, font: noteNSFont,
            expanded: false, editable: !saving, visible: true, foregroundColor: .black.withAlphaComponent(0.67))
            .padding(.horizontal, 28).padding(.top, 58).padding(.bottom, 58)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { PositionNoteBackground(paperStyle: placement?.paperStyle).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)) }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(ReadingToolbarButtonStyle()).disabled(saving)
                        .help("放弃这次编辑并关闭；已保存的笔记保留。")
                        .accessibilityLabel("取消便签编辑").keyboardShortcut(.cancelAction)
                    Button(action: save) { Image(systemName: "checkmark") }
                        .buttonStyle(ReadingToolbarButtonStyle(selected: true))
                        .help(saving ? "正在保存便签" : "保存这张便签")
                        .accessibilityLabel("保存便签").keyboardShortcut("s", modifiers: .command)
                        .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                if placement != nil {
                    Button { showsTypography.toggle() } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("A").font(.system(size: 12, weight: .medium))
                            Text("A").font(.system(size: 19, weight: .medium))
                        }.accessibilityHidden(true)
                    }
                        .buttonStyle(ReadingToolbarButtonStyle(selected: showsTypography)).padding(8)
                        .help("调整这张便签的字体、字号与纸张颜色").accessibilityLabel("便签文字外观")
                        .popover(isPresented: $showsTypography, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 18) {
                                Text("便签外观").font(.system(size: 15, weight: .semibold))
                                PositionNoteColorPicker(selection: Binding(get: { placement?.paperStyle }, set: { placement?.paperStyle = $0 }))
                                Picker("字体", selection: Binding(get: { placement?.fontFamily ?? "serif" }, set: { placement?.fontFamily = $0 })) {
                                    Text("宋体").tag("serif"); Text("系统字体").tag("system"); Text("等宽字体").tag("monospaced")
                                    ForEach(typography.availableFontFamilies, id: \.self) { Text($0).tag($0) }
                                }.controlSize(.large)
                                Stepper("字号 \(Int(placement?.fontSize ?? 15))", value: Binding(get: { placement?.fontSize ?? 15 }, set: { placement?.fontSize = $0 }), in: 10...28, step: 1)
                                    .frame(minHeight: 40)
                            }.padding(22).frame(width: 300)
                        }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let error {
                    Button { showsError.toggle() } label: { Label("尚未保存", systemImage: "exclamationmark.circle").font(.system(size: 12)) }
                        .buttonStyle(ReadingToolbarButtonStyle()).foregroundStyle(Palette.copper).padding(8)
                        .help(error).popover(isPresented: $showsError, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(error).font(.system(size: 13)).textSelection(.enabled)
                                if request.document != nil {
                                    Button("保留原笔记，另存为新笔记") { save(asNew: true) }
                                        .buttonStyle(ReadingToolbarButtonStyle()).disabled(saving)
                                }
                            }.padding(20).frame(width: 320)
                        }
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(Palette.line.opacity(0.6)).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.13), radius: 30, y: 12)
            .accessibilityElement(children: .contain).accessibilityLabel("便签编辑纸张")
            .onAppear { DispatchQueue.main.async { editorSession.focusEditing() } }
            .onExitCommand { close() }
            .onChange(of: text) { _, _ in scheduleDraft() }
            .onChange(of: placement) { _, _ in scheduleDraft() }
            .onDisappear { draftSaveTask?.cancel() }
    }
    private func save() { save(asNew: false) }
    private func save(asNew: Bool) {
        guard !saving, editorSession.finishEditing() else { error = "请先完成当前文字输入，再保存。"; return }
        saving = true; error = nil
        Task {
            do { try await store.savePositionNote(request, text: text, placement: placement, asNew: asNew) }
            catch { self.error = error.localizedDescription; showsError = true }
            saving = false
        }
    }
    private var noteNSFont: NSFont {
        PositionNoteTypography.native(placement)
    }
    private func scheduleDraft() {
        store.positionNoteDraftBuffer = .init(requestID: request.id, text: text, placement: placement)
        draftSaveTask?.cancel()
        draftSaveTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            store.persistPositionNoteDraft(request, text: text, placement: placement)
        }
    }
    private func close() {
        guard !saving, editorSession.finishEditing() else { return }
        draftSaveTask?.cancel()
        store.discardPositionNoteDraft(request)
        store.positionNoteRequest = nil
    }
}
