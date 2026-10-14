import SwiftUI
import ReadingCore

/// Popovers may be dismissed by their host. Keep only card drafts, in memory,
/// scoped to the owning store and book, until explicit save or cancel.
@MainActor private enum ObjectInspectorDraftCache {
    struct Key: Hashable {
        let owner: ObjectIdentifier
        let bookID: String
        let entityID: String
    }
    static var drafts: [Key: EntityEditDraft] = [:]
}

@MainActor struct ObjectInspector: View {
    @EnvironmentObject var store: AppStore
    let id: String
    var onClose: (() -> Void)? = nil
    @State private var displayedID: String?
    @State private var loadedBookID: String?
    @State private var draft: EntityEditDraft?
    @State private var localError: String?
    @State private var restoredDraft = false
    @State private var saving = false
    @State private var pendingAction: PendingAction?
    @State private var showsDraftConfirmation = false

    private enum PendingAction { case show(String), close }
    private var objectID: String { displayedID ?? id }
    private var hasChanges: Bool { draft?.isDirty == true }
    private var draftBinding: Binding<EntityEditDraft> {
        Binding(get: { draft ?? EntityEditDraft(entity: KnowledgeEntity(id: objectID, typeID: "", name: "")) }, set: { next in
            if draft != nil { draft = next }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(draft == nil ? "关联与依据" : "编辑卡片").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { request(.close) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("收起详情").accessibilityLabel("收起详情").disabled(saving)
            }.padding(.horizontal, 14).padding(.vertical, 11)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if draft != nil {
                        if restoredDraft {
                            Text("已保留上次未保存的修改；可继续编辑、保存或取消。").font(.caption).foregroundStyle(Palette.copper)
                        }
                        EntityEditView(draft: draftBinding, types: store.book?.types ?? []).disabled(saving || store.isBusy)
                        if let evidence = draft?.entity.evidence, !evidence.isEmpty {
                            DisclosureGroup("原文依据 · 保留不变") { EvidenceList(evidence: evidence).padding(.top, 6) }
                                .font(.caption).tint(Palette.accent).disabled(saving)
                        }
                    } else { objectContents }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let localError {
                ScrollView {
                    Text(localError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 66).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.bottom, 8)
            }
            if draft != nil {
                Divider().opacity(0.5)
                HStack(spacing: 10) {
                    Button("取消") {
                        cancelEditing()
                    }.disabled(saving)
                    Spacer(minLength: 0)
                    Button(saving ? "保存中…" : "保存") { saveDraft() }
                        .buttonStyle(.borderedProminent).disabled(saving || store.isBusy)
                }.controlSize(.small).padding(.horizontal, 14).padding(.vertical, 10)
            }
        }.background(.background)
            .interactiveDismissDisabled(hasChanges || saving)
            .onAppear { loadedBookID = store.bookID; displayedID = id; restoreDraft(checkOtherDrafts: true) }
            .onChange(of: id) { _, next in
                guard loadedBookID == store.bookID else { return }
                if next != objectID { request(.show(next)) }
            }
            .onChange(of: draft) { _, _ in cacheDraft() }
            .onChange(of: store.bookID) { _, next in
                cacheDraft(); draft = nil; loadedBookID = next; displayedID = id
                localError = nil; restoredDraft = false; pendingAction = nil; showsDraftConfirmation = false
                restoreDraft(checkOtherDrafts: true)
            }
            .onDisappear { cacheDraft() }
            .confirmationDialog("保存卡片的修改？", isPresented: $showsDraftConfirmation, titleVisibility: .visible) {
                Button("保存后继续") { let action = pendingAction; pendingAction = nil; saveDraft(then: action) }.disabled(saving || store.isBusy)
                Button("放弃修改", role: .destructive) {
                    let action = pendingAction; pendingAction = nil; cancelEditing()
                    if let action { perform(action) }
                }
                Button("继续编辑", role: .cancel) { pendingAction = nil }
            } message: {
                Text("“\(draft?.entity.name ?? "卡片")”尚未保存。失败时保留标题、字段和坐标输入。")
            }
    }

    @ViewBuilder private var objectContents: some View {
        if let entity = store.book?.entities.first(where: { $0.id == objectID }) {
            Text(store.book?.types.first { $0.id == entity.typeID }?.name ?? entity.typeID).font(.caption).foregroundStyle(Palette.copper)
            Text(entity.name).font(.system(size: 21, design: .serif)).textSelection(.enabled)
            if !entity.summary.isEmpty { MarkdownText(markdown: entity.summary) }
            HStack(spacing: 12) {
                Button("编辑") { draft = EntityEditDraft(entity: entity); localError = nil; restoredDraft = false }
                Button("删除", role: .destructive) { store.requestDeletion(.entity, id: entity.id, title: entity.name) }
            }.font(.caption).disabled(store.isBusy)
            ForEach(entity.properties.keys.sorted().filter { entity.properties[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }, id: \.self) { key in
                VStack(alignment: .leading, spacing: 5) {
                    Text(fieldLabel(key, type: entity.typeID)).font(.caption).foregroundStyle(.secondary)
                    MarkdownText(markdown: entity.properties[key] ?? "")
                }
            }
            if let lat = entity.latitude, let lon = entity.longitude {
                Label("\(lat), \(lon)", systemImage: "location").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let note = entity.locationNote, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            ForEach((store.book?.events ?? []).filter { $0.participantIDs.contains(objectID) || $0.placeIDs.contains(objectID) }) { event in
                Button(event.name) { showObject(event.id) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
            }
            EvidenceList(evidence: entity.evidence)
        } else if let event = store.book?.events.first(where: { $0.id == objectID }) {
            Text("事件").font(.caption).foregroundStyle(Palette.copper)
            Text(event.name).font(.system(size: 21, design: .serif))
            Label(event.dateText, systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
            MarkdownText(markdown: event.summary)
            linkGroup("地点", ids: event.placeIDs); linkGroup("参与者", ids: event.participantIDs)
            EvidenceList(evidence: event.evidence)
            Button("删除事件", role: .destructive) { store.requestDeletion(.event, id: event.id, title: event.name) }.font(.caption).disabled(store.isBusy)
        } else if let document = store.book?.activeDocuments.first(where: { $0.id == objectID }) {
            Text("Markdown 文档").font(.caption).foregroundStyle(Palette.copper)
            Text(document.title).font(.title2)
            Button("打开文档") { store.openObject(document.id) }
            Button("添加一个画布节点") { Task { await store.addDocumentToGraph(document) } }.disabled(store.isBusy)
            Button("移入回收站", role: .destructive) { store.requestDeletion(.document, id: document.id, title: document.title) }.disabled(store.isBusy)
            EvidenceList(evidence: document.evidence)
        } else if let unit = store.book?.units.first(where: { $0.id == objectID }) {
            Text(unit.chapter).font(.title3); Text(unit.locator).font(.caption).foregroundStyle(.secondary)
            Text(String(unit.text.prefix(500))).font(.caption).lineSpacing(5).textSelection(.enabled)
        } else {
            Text("对象已不存在，或已移入回收站。").font(.callout).foregroundStyle(.secondary)
        }
        ForEach((store.book?.relations ?? []).filter { $0.fromID == objectID || $0.toID == objectID }) { relation in
            HStack {
                Button { showObject(relation.fromID == objectID ? relation.toID : relation.fromID) } label: {
                    Label("\(relation.label) · \(store.objectTitle(relation.fromID == objectID ? relation.toID : relation.fromID))", systemImage: "arrow.up.right").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                Spacer(minLength: 0)
                Button { Task { await store.removeConnection(relation.id, relation: true) } } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).help("移除这条关系").disabled(store.isBusy)
            }
        }
        ForEach((store.book?.activeDocuments ?? []).filter { $0.linkedIDs.contains(objectID) }) { document in
            Button { Task { await store.openDocument(document) } } label: { Label(document.title, systemImage: "doc.text").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(Palette.accent)
        }
    }

    private func key(bookID: String, entityID: String) -> ObjectInspectorDraftCache.Key {
        .init(owner: ObjectIdentifier(store), bookID: bookID, entityID: entityID)
    }
    private func cacheDraft() {
        guard let bookID = loadedBookID, let draft else { return }
        let cacheKey = key(bookID: bookID, entityID: draft.entity.id)
        if draft.isDirty { ObjectInspectorDraftCache.drafts[cacheKey] = draft }
        else { ObjectInspectorDraftCache.drafts.removeValue(forKey: cacheKey) }
    }
    private func restoreDraft(checkOtherDrafts: Bool = false) {
        guard let bookID = loadedBookID else { return }
        if store.book?.entities.contains(where: { $0.id == objectID }) == true,
           let retained = ObjectInspectorDraftCache.drafts[key(bookID: bookID, entityID: objectID)] {
            draft = retained; restoredDraft = true; return
        }
        // An item-driven popover can replace this View instead of changing `id`.
        // Bring the previous card back before asking how to leave its draft.
        guard checkOtherDrafts, let entry = ObjectInspectorDraftCache.drafts.first(where: { entry in
            entry.key.owner == ObjectIdentifier(store) && entry.key.bookID == bookID && entry.value.isDirty
                && store.book?.entities.contains(where: { $0.id == entry.key.entityID }) == true
        }) else { return }
        let requestedID = objectID
        displayedID = entry.key.entityID; draft = entry.value; restoredDraft = true
        pendingAction = .show(requestedID); showsDraftConfirmation = true
    }
    private func cancelEditing() {
        if let bookID = loadedBookID, let draft { ObjectInspectorDraftCache.drafts.removeValue(forKey: key(bookID: bookID, entityID: draft.entity.id)) }
        draft = nil; localError = nil; restoredDraft = false
    }
    private func request(_ action: PendingAction) {
        guard !saving else { return }
        if hasChanges { pendingAction = action; showsDraftConfirmation = true }
        else { cancelEditing(); perform(action) }
    }
    private func perform(_ action: PendingAction) {
        switch action {
        case .show(let next): displayedID = next; localError = nil; restoredDraft = false; restoreDraft()
        case .close: if let onClose { onClose() } else { store.selectedObjectID = nil }
        }
    }
    private func saveDraft(then action: PendingAction? = nil) {
        guard let draft, let expectedBookID = loadedBookID, !saving, !store.isBusy else { return }
        guard store.bookID == expectedBookID else { localError = "书籍已切换，草稿已保留，请返回原书后保存。"; return }
        do {
            guard let current = store.book?.entities.first(where: { $0.id == draft.entity.id }) else {
                throw ReadingError.invalid("卡片已不存在或已回收。草稿已保留，请先恢复原卡片。")
            }
            guard current == draft.original else {
                throw ReadingError.invalid("原卡片已在其他操作中更新。草稿已保留，请核对后取消并重新编辑，避免覆盖新内容。")
            }
            let entity = try draft.validated(types: store.book?.types ?? [])
            saving = true; localError = nil
            Task {
                let saved = await store.saveEntity(entity, inBook: expectedBookID, onError: { message in
                    if loadedBookID == expectedBookID { localError = message }
                })
                saving = false
                if saved {
                    ObjectInspectorDraftCache.drafts.removeValue(forKey: key(bookID: expectedBookID, entityID: entity.id))
                    guard loadedBookID == expectedBookID else { return }
                    self.draft = nil; restoredDraft = false
                    if let action { perform(action) }
                } else if loadedBookID == expectedBookID, localError == nil { localError = "未能保存，所有输入已保留，请重试。" }
            }
        } catch { localError = error.localizedDescription; cacheDraft() }
    }
    private func fieldLabel(_ key: String, type: String) -> String {
        store.book?.types.first { $0.id == type }?.fields.first { $0.key == key }?.label ?? key
    }
    private func showObject(_ next: String) { request(.show(next)); store.focus(next) }
    private func linkGroup(_ title: String, ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !ids.isEmpty { Text(title).font(.caption).foregroundStyle(.secondary) }
            ForEach(ids, id: \.self) { target in
                Button(store.objectTitle(target)) { showObject(target) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
            }
        }
    }
}
