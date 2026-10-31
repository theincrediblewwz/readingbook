import SwiftUI
import ReadingCore

struct CompanionHistoryReferenceControl: View {
    @EnvironmentObject private var store: AppStore
    @State private var presented = false
    @State private var search = ""
    @State private var folder: String?
    @State private var owner: WorkspacePickerOwner?
    @StateObject private var browser = ReaderRecordBrowserState()
    private var references: [ReadingAnswerReference] {
        guard let book = store.book else { return [] }
        return ReaderCollectionRuntime.references(in: book).reversed().filter {
            let assignment = store.readerCollections.assignments[$0.id]
            let matches = folder.map { $0 == "@unfiled" ? assignment == nil : assignment == $0 } ?? true
            return matches && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.content.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        Button { owner = WorkspacePickerOwner(store: store); presented = true } label: {
            Image(systemName: "paperclip").frame(width: 44, height: 44).contentShape(Rectangle()).overlay(alignment: .topTrailing) {
                if !store.companionReferencedAnswerIDs.isEmpty {
                    Text("\(store.companionReferencedAnswerIDs.count)").font(.system(size: 9)).foregroundStyle(Palette.accent)
                }
            }
        }.buttonStyle(ReadingQuietButtonStyle()).disabled(store.isCompanionGenerating)
            .help("为本次生成伴读引用历史回答；不改变对话中的附加内容，也不扩大原文范围。")
            .accessibilityLabel("伴读引用历史回答")
            .accessibilityValue("已引用 \(store.companionReferencedAnswerIDs.count) 条回答")
            .popover(isPresented: $presented) {
                let values = references
                let byID = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("伴读参考的历史回答").font(.system(size: 17, weight: .semibold)); Spacer()
                        Button { presented = false } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("关闭历史引用")
                    }
                    TextField("搜索历史回答", text: $search).textFieldStyle(.roundedBorder)
                    ReaderFolderControl(kind: .history, selection: $folder)
                    ReaderRecordGroupingBar(state: browser)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ReaderRecordSections(state: browser, ids: values.map(\.id), searching: !search.isEmpty) { record, expanded in
                                if let value = byID[record.id] {
                                    ReaderRecordFoldCard(record: record, expanded: expanded,
                                        selection: Binding(get: { store.companionReferencedAnswerIDs.contains(value.id) }, set: { included in
                                            guard owner?.matches(store) == true else { return }; store.setReferencedAnswer(value.id, included: included, forCompanion: true)
                                        })) {
                                        ChatMarkdownBody(markdown: MarkdownReferenceLinks.render(value.content, bookID: store.bookID ?? "", project: store.book), presentationActiveOverride: true)
                                    }
                                }
                            }
                            if references.isEmpty { Text("没有匹配的历史回答").foregroundStyle(.secondary) }
                        }
                    }
                    Divider().opacity(0.4)
                    HStack {
                        Button("清空引用") { if owner?.matches(store) == true { store.companionReferencedAnswerIDs = [] } }.buttonStyle(ReadingToolbarButtonStyle())
                        Spacer(); Button("完成") { presented = false }.buttonStyle(ReadingToolbarButtonStyle(selected: true))
                    }
                }.padding(20).frame(width: 430, height: 520)
            }.onChange(of: store.collectionOwnerKey) { _, _ in presented = false; folder = nil; search = ""; owner = nil }
    }
}
