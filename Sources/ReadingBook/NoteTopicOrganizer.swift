import SwiftUI
import ReadingCore

struct NoteTopicOrganizer: View {
    @EnvironmentObject private var store: AppStore
    var close: () -> Void
    @State private var documents: [DocumentRecord] = []
    @State private var groups: [ReadingNoteTopicGroup] = []
    @State private var owner: WorkspacePickerOwner?
    @State private var work: Task<Void, Never>?
    @State private var working = false
    @State private var applying = false
    @State private var status = ""
    @State private var confirmingRegeneration = false
    @State private var batchSize = 50
    private var unfiled: [DocumentRecord] {
        (store.book?.activeDocuments ?? []).filter { store.readerCollections.assignments["note:" + $0.id] == nil }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Label("按内容整理", systemImage: "folder.badge.gearshape").font(.system(size: 18, weight: .semibold))
                Text(groups.isEmpty ? "未分类 \(unfiled.count)" : "\(documents.count)篇 · \(groups.count)组").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if working {
                    ProgressView().controlSize(.small).help(status)
                    Button("停止") { work?.cancel() }.buttonStyle(ReadingToolbarButtonStyle())
                } else {
                    Button(groups.isEmpty ? "生成建议" : "重新生成…") { if groups.isEmpty { generate() } else { confirmingRegeneration = true } }
                        .buttonStyle(ReadingToolbarButtonStyle(selected: true)).disabled(unfiled.isEmpty || applying)
                        .help("发送本批未分类笔记的标题和开头节选给当前模型；先预览，不直接改动笔记。")
                }
                ReaderInformationButton(title: "怎样整理？", text: (status.isEmpty ? "" : status + "\n\n") + "只为未分类的笔记建议主题文件夹，已有手工分类不动。点击生成时，会把本批笔记的标题与开头节选发送给当前模型；最多50篇一批。先看每个文件夹具体放哪些笔记，点应用后才改变收纳，不修改、删除或搬动正文。无法判断的笔记留在未分类。")
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("关闭整理预览")
            }
            if status.hasPrefix("未能") || status.contains("已停止") { Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if status.hasPrefix("未能生成"), batchSize > 1 {
                Button("减少本批笔记后重试") { batchSize = max(1, batchSize / 2); generate() }
                    .buttonStyle(ReadingToolbarButtonStyle()).disabled(working)
                    .help("减少这一批的节选数量后重新请求模型；原笔记和现有分类保留。")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 12) {
                            Label(group.title + " · \(group.noteIDs.count)", systemImage: "folder").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.accent)
                            ForEach(group.noteIDs, id: \.self) { id in
                                Text(documents.first { $0.id == id }?.title ?? "笔记").font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.paper, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if !groups.isEmpty {
                        let remaining = documents.count - Set(groups.flatMap(\.noteIDs)).count
                        if remaining > 0 { Text("\(remaining) 篇未作分类建议，继续留在未分类。").foregroundStyle(.secondary) }
                    } else if !working {
                        Text(unfiled.isEmpty ? "所有笔记都已收纳。" : "先生成建议，再查看每个文件夹会放入哪些笔记。").font(.system(size: 16)).foregroundStyle(.secondary).padding(.top, 30)
                    }
                }.padding(.vertical, 4)
            }
            Divider().opacity(0.4)
            HStack {
                Text("正文、原文位置和已有手工分类保留").font(.system(size: 12)).foregroundStyle(.secondary); Spacer()
                Button(applying ? "应用中…" : "应用这份分类") { apply() }.buttonStyle(ReadingToolbarButtonStyle(selected: true))
                    .disabled(groups.isEmpty || working || applying).help("只应用上方预览中的文件夹收纳。笔记已被修改或手工归类时，会停止并要求重新预览。")
            }
        }.padding(24).frame(width: 740, height: 620).background(Palette.canvas)
            .onExitCommand(perform: close).onDisappear { work?.cancel() }
            .onChange(of: store.collectionOwnerKey) { _, _ in work?.cancel(); close() }
            .confirmationDialog("重新生成一份分类建议？", isPresented: $confirmingRegeneration) {
                Button("重新生成") { generate() }; Button("保留当前建议", role: .cancel) { }
            } message: { Text("会再次使用模型。新建议返回后替换当前预览；笔记和已应用的分类保留。") }
    }
    private func generate() {
        guard let book = store.book, !working else { return }
        owner = WorkspacePickerOwner(store: store); let captured = owner!, notes = Array(unfiled.prefix(batchSize))
        let repository = store.repository, root = store.libraryRootURL, coordinator = store.sharedAIRequests, limit = store.aiConcurrencyLimit
        var settings = store.settings; settings.transportSessionID = "readingbook-" + book.id + "-note-topics"
        let apiKey = store.apiKey
        working = true; status = "正在读取本批笔记节选…"
        work = Task { @MainActor in
            var run: AIRequestRun?
            defer { working = false; if let run { run.finish(); Task { await coordinator.endRun(run) } } }
            do {
                var inputs: [ReadingNoteTopicInput] = []
                for document in notes {
                    try Task.checkCancellation()
                    let body = try await repository.readDocument(bookID: book.id, document: document)
                    inputs.append(.init(id: document.id, title: String(document.title.prefix(160)), excerpt: String(body.prefix(500))))
                }
                guard captured.matches(store), root == store.libraryRootURL else { throw CancellationError() }
                status = "模型正在为 \(notes.count) 篇笔记建议主题…"
                run = try await coordinator.beginManagedRun(settings: settings, maximumConcurrency: limit, independentBudget: true)
                let reader = AIReader(coordinator: coordinator, lane: .background)
                await reader.setRequestRun(run)
                let result = try await reader.organizeNotesByTopic(notes: inputs, settings: settings, apiKey: apiKey)
                try Task.checkCancellation(); guard captured.matches(store) else { return }
                groups = result; documents = notes; status = "请核对下方分类，确认后再应用。"
            } catch { if captured.matches(store) { status = error is CancellationError ? "已停止生成，没有改动笔记。" : "未能生成：" + error.localizedDescription } }
        }
    }
    private func apply() {
        guard let owner, owner.matches(store), let book = store.book, !applying, !store.storageState.working else { return }
        applying = true
        Task { @MainActor in
            defer { applying = false }
            do {
                let result = try await store.repository.organizeReaderCollections(bookID: book.id, sourceHash: book.sourceHash,
                    command: .organizeNotesByTopic(groups, expectedDocuments: documents))
                guard owner.matches(store) else { return }; store.publish(result)
                groups = []; documents = []; status = unfiled.isEmpty ? "分类已应用，所有笔记均已收纳。" : "分类已应用。\(unfiled.count) 篇仍未分类，可继续整理。"
            } catch { if owner.matches(store) { status = "未能应用：" + error.localizedDescription } }
        }
    }
}
