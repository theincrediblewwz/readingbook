import SwiftUI
import ReadingCore

/// Switching a view is free. Only the explicit generate action sends a model
/// request; each result is an ordinary saved note, with older versions retained.
struct DocumentPerspectiveView: View {
    @EnvironmentObject private var store: AppStore
    let document: DocumentRecord
    @State private var style: ReadingAnswerStyle = .mentor
    @State private var markdown = ""
    @State private var originalHash = ""
    @State private var savedID: String?
    @State private var working = false
    @State private var work: Task<Void, Never>?
    @State private var message = ""
    @State private var confirming = false
    private var origin: String { "ai-perspective:" + style.rawValue + ":" + originalHash + ":" + (store.book?.sourceHash ?? "") }
    private var refreshKey: String { store.collectionOwnerKey + "|" + document.id + "|" + String(store.projectRevision) + "|" + style.rawValue }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(ReadingAnswerStyle.allCases, id: \.self) { value in
                    Button { style = value } label: { Text(value.title).font(.system(size: 13)) }
                        .buttonStyle(ReadingToolbarButtonStyle(selected: style == value)).disabled(working)
                        .help(value == .mentor ? "看懂意思与思路；必要背景单独说明，不冒充书中事实。" : "核对原话、出处和推断，保留未知，不用书外知识填补证据。")
                }
                Spacer(minLength: 0)
                ReaderInformationButton(title: "两种讲解", text: "两种方式各自保存结果，切换只查看，不会自动生成或覆盖这篇笔记。生成时会读取这篇笔记；有原文依据时，仅分享第一个来源的精确选段。没有原文依据就只讨论笔记，不能当作原书事实。")
            }
            if !markdown.isEmpty {
                ChatMarkdownBody(markdown: ChatMarkdownBody.prepare(markdown, bookID: store.bookID ?? "", project: store.book), context: .notes)
            }
            else { Text(style == .mentor ? "还没有这篇笔记的老师讲解。" : "还没有这篇笔记的原文考据。").font(.system(size: 14)).foregroundStyle(.secondary) }
            if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Button("停止生成") { work?.cancel() }.buttonStyle(ReadingToolbarButtonStyle())
                } else {
                    Button(savedID == nil ? "生成" + style.title : "生成新的讲解版本…") {
                        if savedID == nil { generate() } else { confirming = true }
                    }.buttonStyle(ReadingToolbarButtonStyle()).disabled(originalHash.isEmpty || store.storageState.working)
                        .help("用当前模型生成单独保存的新笔记；原笔记、原书与所有旧版本保留。")
                }
                Spacer()
                if let savedID, let note = store.book?.activeDocuments.first(where: { $0.id == savedID }) {
                    Button("打开完整讲解") { Task { await store.openDocument(note) } }.buttonStyle(ReadingQuietButtonStyle())
                }
            }
        }.padding(16).background(Palette.paper.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            .task(id: refreshKey) { await load() }
            .onDisappear { work?.cancel() }
            .confirmationDialog("已保存这类讲解，再生成一个版本？", isPresented: $confirming) {
                Button("生成新版本") { generate() }; Button("保留现有版本", role: .cancel) { }
            } message: { Text("会消耗模型请求。旧讲解和原笔记保留，不会覆盖。") }
    }
    private func load() async {
        guard !working, let book = store.book else { return }
        let owner = WorkspacePickerOwner(store: store), expectedStyle = style
        markdown = ""; savedID = nil; originalHash = ""; message = ""
        do {
            let original = try await store.repository.readDocumentSnapshot(bookID: book.id, document: document)
            guard !Task.isCancelled, owner.matches(store), style == expectedStyle else { return }
            originalHash = original.contentHash
            let identity = "ai-perspective:" + expectedStyle.rawValue + ":" + original.contentHash + ":" + book.sourceHash
            if let saved = book.activeDocuments.filter({ $0.linkedIDs.contains(document.id) && $0.origin == identity }).max(by: { $0.updatedAt < $1.updatedAt }) {
                let body = try await store.repository.readDocument(bookID: book.id, document: saved)
                guard !Task.isCancelled, owner.matches(store), style == expectedStyle else { return }
                savedID = saved.id; markdown = body
            }
        } catch { if owner.matches(store) { message = error.localizedDescription } }
    }
    private func generate() {
        guard !working, !originalHash.isEmpty, let book = store.book else { return }
        let owner = WorkspacePickerOwner(store: store), expectedHash = originalHash, expectedStyle = style, savedOrigin = origin
        let coordinator = store.sharedAIRequests, limit = store.aiConcurrencyLimit, repository = store.repository
        var settings = store.settings; settings.transportSessionID = "readingbook-" + book.id + "-perspective"
        let apiKey = store.apiKey
        working = true; message = "正在生成独立讲解，原笔记保持…"
        work = Task { @MainActor in
            var run: AIRequestRun?
            defer { working = false; if let run { run.finish(); Task { await coordinator.endRun(run) } } }
            do {
                let original = try await repository.readDocumentSnapshot(bookID: book.id, document: document)
                guard original.contentHash == expectedHash else { throw ReadingError.invalid("原笔记已经修改，请重新打开后生成。") }
                let preparation = Task.detached(priority: .userInitiated) {
                    var context = ReadingContext(sourceHash: book.sourceHash)
                    var scope: ReadingQueryScope = .notes
                    if let evidence = document.evidence.first {
                        let anchor = try ReadingExperienceRuntime.createAnchor(sourceHash: book.sourceHash, unitID: evidence.unitID, quote: evidence.quote, in: book)
                        context.unitID = anchor.unitID; context.page = book.units.first { $0.id == anchor.unitID }?.page; context.selectedSourceAnchor = anchor; context.selectedText = anchor.quote
                        scope = .selection
                    }
                    return try ReadingPreparedAnswer.freeze(project: book, scope: scope, context: context,
                        documentIDs: scope == .notes ? [document.id] : nil, appendedDocumentIDs: scope == .notes ? [] : [document.id],
                        preferences: .init(interaction: .reading, style: expectedStyle))
                }
                let prepared = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
                try Task.checkCancellation(); guard owner.matches(store) else { throw CancellationError() }
                run = try await coordinator.beginManagedRun(settings: settings, maximumConcurrency: limit, independentBudget: true)
                let reader = AIReader(coordinator: coordinator, lane: .background)
                await reader.setRequestRun(run)
                let question = expectedStyle == .mentor
                    ? "请围绕这篇附加笔记和允许的原文片段，用老师伴读的方式解释意思与思路。必要背景单独说明，不复述整篇笔记，不透露未读后文。"
                    : "请对这篇附加笔记作原文考据。逐项区别原文明载、笔记或旧AI的推断与未知，给出本次允许片段内可核对的短引文；范围外出处不推定存在。没有原文时明确说明只能核对笔记内部表述。"
                // Keep the explicitly selected, hash-checked note available to
                // document_read. The provider receives only requested slices.
                let answer = try await reader.answerDetailed(question: question, prepared: prepared, settings: settings, apiKey: apiKey,
                    documents: [document.id: original.markdown], memoryEnabled: false)
                try Task.checkCancellation()
                guard answer.diagnostics.documentReadIDs.contains(document.id) else {
                    throw ReadingError.invalid("模型这次没有实际读取所选笔记，未另存空讲解；原笔记和已有讲解保留。")
                }
                guard owner.matches(store), let latest = store.book, latest.activeDocuments.first(where: { $0.id == document.id }) == document else { throw CancellationError() }
                let latestBody = try await repository.readDocumentSnapshot(bookID: book.id, document: document)
                guard latestBody.contentHash == expectedHash else { throw ReadingError.invalid("生成期间原笔记已修改，未保存旧版本讲解。") }
                let note = DocumentRecord(title: expectedStyle.title + " · " + document.title, origin: savedOrigin, linkedIDs: [document.id], evidence: answer.message.evidence)
                let result = try await repository.saveLatestNote(bookID: latest.id, sourceHash: latest.sourceHash, document: note, markdown: answer.message.content,
                    readingSnapshot: prepared.snapshot)
                guard owner.matches(store) else { return }; store.publish(result)
                savedID = note.id; markdown = answer.message.content; message = "已另存讲解，原笔记和旧讲解保留。"
            } catch { if owner.matches(store) { message = error is CancellationError ? "生成已停止，已有内容保留。" : error.localizedDescription } }
        }
    }
}
