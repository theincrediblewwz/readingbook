import SwiftUI
import ReadingCore

struct TeacherBackgroundCard: View {
    @EnvironmentObject private var store: AppStore
    let objectID: String
    var unitID: String? = nil
    var autoGenerate = true
    var body: some View { TeacherBackgroundCardBody(state: store.teacherBackground, objectID: objectID, unitID: unitID, autoGenerate: autoGenerate) }
}

private struct TeacherBackgroundCardBody: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var state: TeacherBackgroundState
    let objectID: String
    let unitID: String?
    let autoGenerate: Bool
    private var key: String { state.key(objectID: objectID, unitID: unitID, store: store) }
    var body: some View {
        let entry = state.entries[key]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label("背景补充", systemImage: "sparkles").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent)
                Spacer()
                Text(entry?.fromCache == true ? "本地已存 · AI讲解" : "AI讲解").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let record = entry?.record {
                MarkdownText(markdown: record.markdown).clipShape(RoundedRectangle(cornerRadius: 14))
            } else if let entry, entry.running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(entry.progress.phaseTitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    Button { state.cancel(objectID: objectID, unitID: unitID, store: store) } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.plain).help("停止这次介绍")
                }
                if entry.progress.reasoningCharacters > 0 || entry.progress.answerCharacters > 0 {
                    Text("思考 \(entry.progress.reasoningCharacters.formatted()) · 输出 \(entry.progress.answerCharacters.formatted()) 字符")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                if let message = entry?.message { Text(message).font(.system(size: 13)).foregroundStyle(.secondary) }
                Button {
                    guard store.providerReady else { return }; state.load(objectID: objectID, unitID: unitID, store: store)
                } label: { Label(entry?.message == nil ? "听老师讲讲" : "再试一次", systemImage: "sparkles") }
                    .buttonStyle(ReadingToolbarButtonStyle())
            }
        }.padding(14).background(Palette.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            .task(id: key) { if autoGenerate { state.load(objectID: objectID, unitID: unitID, store: store) } }
    }
}
