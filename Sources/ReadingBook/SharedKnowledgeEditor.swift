import SwiftUI
import ReadingCore

struct KnowledgeEditBasisPicker: View {
    @Binding var basis: KnowledgeEditBasis
    var body: some View {
        HStack(spacing: 10) {
            Text("这次修正").font(.callout).foregroundStyle(.secondary)
            Picker("这次修正的依据", selection: $basis) {
                ForEach(KnowledgeEditBasis.allCases, id: \.self) { value in Text(value.title).tag(value) }
            }.labelsHidden().pickerStyle(.menu)
            Image(systemName: "info.circle").foregroundStyle(.secondary)
                .help("这是你对修正内容的判断。原文出处单独保留；个人推断和理解不会标成书中事实。只保护改过的字段，AI 仍可补充其他资料和新出处。")
        }
    }
}

struct KnowledgeOwnershipBadge: View {
    @EnvironmentObject private var store: AppStore
    let id: String
    let kind: KnowledgeRecordKind
    var compact = false
    private var edit: KnowledgeUserEdit? { store.componentDataBook.flatMap { KnowledgeUserEditsRuntime.record(id, kind: kind, in: $0) } }
    var body: some View {
        Label(edit.map { compact ? "已修正" : "你的修正 · " + $0.basis.title } ?? (compact ? "资料" : "整理资料 · 待核对"), systemImage: edit == nil ? "text.book.closed" : "person.crop.circle.badge.checkmark")
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .help(edit == nil ? "这份资料尚未标注修正依据，可能来自 AI 或早先保存的内容。可打开原文核对；新的修正会单独标明你的判断。" : "只保护你改过的字段。所有组件使用同一份资料，后续 AI 仍可补充其他字段和原文出处。")
    }
}

struct SharedKnowledgeEditRequest: Identifiable {
    let id = UUID()
    let value: KnowledgeRecordValue
    let root: URL
    let bookID: String
    let sourceHash: String
    @MainActor init(value: KnowledgeRecordValue, store: AppStore) {
        self.value = value; root = store.libraryRootURL; bookID = store.bookID ?? ""; sourceHash = store.book?.sourceHash ?? ""
    }
    @MainActor func matches(_ store: AppStore) -> Bool { root == store.libraryRootURL && bookID == store.bookID && sourceHash == store.book?.sourceHash }
}

/// Reuses the reader's quiet rounded surface. Drafts remain until a successful
/// actor commit; a failed/stale save never dismisses or erases the input.
struct SharedKnowledgeEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let request: SharedKnowledgeEditRequest
    @State private var name = ""
    @State private var summary = ""
    @State private var basis = KnowledgeEditBasis.interpretation
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(request.value.kind == .event ? "修正事件介绍" : "修正关系名称").font(.title3.weight(.semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 40, height: 40) }.buttonStyle(ReadingQuietButtonStyle()).help("取消本次修正").disabled(saving)
            }
            KnowledgeEditBasisPicker(basis: $basis)
            TextField(request.value.kind == .relation ? "关系名称" : "事件名称", text: $name, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
            if request.value.kind == .event {
                TextEditor(text: $summary).scrollContentBackground(.hidden).padding(12).frame(minHeight: 180)
                    .background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
            }
            Text("共享资料会同步更新；原文出处、事件时间与其他字段保留。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("取消") { dismiss() }.buttonStyle(ReadingQuietButtonStyle()); Button(saving ? "保存中…" : "保存修正") { save() }.buttonStyle(ReadingToolbarButtonStyle(selected: true)) }
                .disabled(saving || !request.matches(store) || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(24).frame(width: 560).background(Palette.paper).interactiveDismissDisabled(saving)
            .onAppear {
                switch request.value { case .entity(let v): name = v.name; summary = v.summary; case .event(let v): name = v.name; summary = v.summary; case .relation(let v): name = v.label }
                basis = store.book.flatMap { KnowledgeUserEditsRuntime.record(request.value.id, kind: request.value.kind, in: $0)?.basis } ?? .interpretation
            }
    }
    private func save() {
        guard request.matches(store), !saving else { return }
        var replacement = request.value
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 1600, summary.utf8.count <= 131_072 else { error = "名称或概述过长，请缩短后保存。"; return }
        switch replacement {
        case .entity(var v): v.name = title; v.summary = summary; replacement = .entity(v)
        case .event(var v): v.name = title; v.summary = summary; replacement = .event(v)
        case .relation(var v): v.label = title; replacement = .relation(v)
        }
        saving = true; error = nil
        let repository = store.repository
        Task {
            guard request.matches(store) else { saving = false; error = "书库或书籍已切换，输入保留，未保存到其他书。"; return }
            do {
                let saved = try await repository.saveKnowledgeEdit(bookID: request.bookID, sourceHash: request.sourceHash, expected: request.value, replacement: replacement, basis: basis)
                guard request.matches(store) else { saving = false; error = "书籍已切换，修正已保存到原书。"; return }
                store.publish(saved); saving = false; dismiss()
            } catch { saving = false; self.error = error.localizedDescription }
        }
    }
}
