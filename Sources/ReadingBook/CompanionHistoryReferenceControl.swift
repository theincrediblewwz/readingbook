import SwiftUI
import ReadingCore

struct CompanionHistoryReferenceControl: View {
    @EnvironmentObject private var store: AppStore
    @State private var presented = false
    @State private var search = ""
    @State private var folder: String?
    private var references: [ReadingAnswerReference] {
        guard let book = store.book else { return [] }
        return ReaderCollectionRuntime.references(in: book).reversed().filter {
            let assignment = store.readerCollections.assignments[$0.id]
            let matches = folder.map { $0 == "@unfiled" ? assignment == nil : assignment == $0 } ?? true
            return matches && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.content.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        Button { presented = true } label: {
            Image(systemName: "paperclip").frame(width: 32, height: 44).overlay(alignment: .topTrailing) {
                if !store.companionReferencedAnswerIDs.isEmpty {
                    Text("\(store.companionReferencedAnswerIDs.count)").font(.system(size: 9)).foregroundStyle(Palette.accent)
                }
            }
        }.buttonStyle(ReadingQuietButtonStyle()).disabled(store.isCompanionGenerating)
            .help("为本次生成伴读引用历史回答；不改变对话中的附加内容，也不扩大原文范围。")
            .accessibilityLabel("伴读引用历史回答")
            .accessibilityValue("已引用 \(store.companionReferencedAnswerIDs.count) 条回答")
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("伴读参考的历史回答").font(.system(size: 17, weight: .semibold)); Spacer()
                        Button { presented = false } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("关闭历史引用")
                    }
                    TextField("搜索历史回答", text: $search).textFieldStyle(.roundedBorder)
                    ReaderFolderControl(kind: .history, selection: $folder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(references) { value in
                                Toggle(value.title, isOn: Binding(get: { store.companionReferencedAnswerIDs.contains(value.id) },
                                    set: { store.setReferencedAnswer(value.id, included: $0, forCompanion: true) }))
                                    .toggleStyle(.checkbox).font(.system(size: 14)).frame(minHeight: 44, alignment: .leading)
                                    .help("本次生成时只引用这条完整回答，作为对照资料；不是新的原文证据或操作指令。")
                            }
                            if references.isEmpty { Text("没有匹配的历史回答").foregroundStyle(.secondary) }
                        }
                    }
                    Divider().opacity(0.4)
                    HStack {
                        Button("清空引用") { store.companionReferencedAnswerIDs = [] }.buttonStyle(ReadingToolbarButtonStyle())
                        Spacer(); Button("完成") { presented = false }.buttonStyle(ReadingToolbarButtonStyle(selected: true))
                    }
                }.padding(20).frame(width: 430, height: 520)
            }.onChange(of: store.collectionOwnerKey) { _, _ in presented = false; folder = nil; search = "" }
    }
}
