import SwiftUI
import ReadingCore

struct PendingAIChange: Identifiable {
    var id: String { proposal.id }
    let proposal: ControlledChangeProposal
    let grant: ControlledWriteGrant
}

@MainActor extension AppStore {
    var pendingCurrentBookChanges: [PendingAIChange] { pendingAIChanges.filter { $0.proposal.bookID == bookID } }
    var latestAIChange: ControlledChangeReceipt? {
        book?.controlledChanges?.receipts.last { $0.undoneAt == nil && $0.originBookID == bookID }
    }
    func readingProposalAccess(grant: ControlledWriteGrant, snapshot: ReadingQuerySnapshot) -> ReadingProposalToolAccess {
        ReadingProposalToolAccess(proposalTools: ["knowledge_changes_propose", "graph_changes_propose", "document_changes_propose", "book_scheme_propose"], prepare: { [weak self] name, data in
            guard let self else { throw CancellationError() }
            return try await self.prepareReadingProposal(name, data: data, grant: grant, snapshot: snapshot)
        }, currentProject: { [weak self] in await self?.book })
    }
    func prepareReadingProposal(_ name: String, data: Data, grant: ControlledWriteGrant, snapshot: ReadingQuerySnapshot) async throws -> Data {
        try Task.checkCancellation()
        guard bookID == grant.bookID, book?.sourceHash == grant.sourceHash else { throw ControlledChangeError.conflict("书籍已改变，本次整理未写入其他书。") }
        let batch = try ReadingProposalTools.decode(name: name, arguments: data)
        let knowledgeEvidence = (batch.knowledge?.entities ?? []).flatMap(\.evidence)
            + (batch.knowledge?.events ?? []).flatMap(\.evidence) + (batch.knowledge?.relations ?? []).flatMap(\.evidence)
        let documentEvidence = (batch.documents?.create ?? []).flatMap { $0.evidence ?? [] }
        let proposedAnchors = (batch.knowledge?.anchors ?? []).map { Evidence(unitID: $0.unitID, quote: $0.quote) }
        guard (knowledgeEvidence + documentEvidence + proposedAnchors).allSatisfy(snapshot.admits) else {
            throw ControlledChangeError.denied("提案证据超出本次选段、页或章节；没有写入。")
        }
        let proposal = try await repository.prepareChanges(batch, grant: grant)
        try Task.checkCancellation()
        if proposal.requiresConfirmation {
            if !pendingAIChanges.contains(where: { $0.id == proposal.id }) { pendingAIChanges.append(PendingAIChange(proposal: proposal, grant: grant)) }
            return try changeToolReceipt(status: "needs_confirmation", applied: false, proposal: proposal)
        }
        let committed = try await repository.commitChanges(proposalID: proposal.id, grant: grant)
        guard bookID == grant.bookID else { throw CancellationError() }
        publish(committed.project)
        activity = "本次授权的新增整理已保存，可以撤销。"
        return try changeToolReceipt(status: "success", applied: true, proposal: proposal, receipt: committed.receipt, replayed: committed.replayed)
    }
    private func changeToolReceipt(status: String, applied: Bool, proposal: ControlledChangeProposal,
                                   receipt: ControlledChangeReceipt? = nil, replayed: Bool = false) throws -> Data {
        // Never put large before/after bodies into the model's tool window.
        // Full reviewed bytes stay in the proposal, and IDs can be paged from
        // book_schema_get/operations after an actual successful commit.
        var result: [String: Any] = ["ok": applied, "status": status, "applied": applied, "proposalID": proposal.id,
            "message": applied ? "本次授权整理已实际保存，可撤销。" : "具体变更已准备，等待读者审阅；尚未应用。",
            "groups": proposal.groups.map(\.rawValue), "summaryCount": proposal.summary.count, "fullPreview": "in_app_review",
            "replayed": replayed]
        if let receipt { result["operationID"] = receipt.operationID }
        let mappings = receipt?.idMap ?? [:]
        var included: [String: String] = [:]
        result["idMapCount"] = mappings.count; result["idMapPartial"] = !mappings.isEmpty
        for key in mappings.keys.sorted() {
            var candidate = included; candidate[key] = mappings[key]
            result["idMap"] = candidate
            let size = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).count
            if size > 3300 { break }
            included = candidate
        }
        result["idMap"] = included; result["idMapPartial"] = included.count < mappings.count
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        guard data.count <= 3600 else { throw ReadingError.invalid("整理已保存，但简短回执编码超过限制；请在应用中查看记录。") }
        return data
    }
    func applyAIChange(_ pending: PendingAIChange) async -> Bool {
        guard !isBusy, bookID == pending.proposal.bookID else { return false }
        guard !editorDirty else { errorMessage = "请先保存或放弃当前笔记草稿，再应用 AI 修改。"; return false }
        isBusy = true; isCommittingLocalWrite = true
        defer { isBusy = false; isCommittingLocalWrite = false }
        do {
            let approval = try await repository.approveChanges(proposalID: pending.proposal.id, digest: pending.proposal.digest)
            let committed = try await repository.commitChanges(proposalID: pending.proposal.id, grant: pending.grant, approval: approval)
            publish(committed.project); pendingAIChanges.removeAll { $0.id == pending.id }
            if !pendingAIChanges.contains(where: { $0.grant.id == pending.grant.id }) { await repository.revokeChangeGrant(pending.grant.id) }
            if let document = book?.activeDocuments.first(where: { $0.id == selectedDocumentID }), pending.proposal.documents.contains(where: { $0.documentID == document.id }) { await openDocument(document) }
            activity = "审阅的修改已应用；原版本可通过本次撤销恢复。"; return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func discardAIChange(_ pending: PendingAIChange) async {
        guard !isBusy else { return }
        pendingAIChanges.removeAll { $0.id == pending.id }
        if !pendingAIChanges.contains(where: { $0.grant.id == pending.grant.id }) { await repository.revokeChangeGrant(pending.grant.id) }
    }
    func undoLatestAIChange() async {
        guard !isBusy, let bookID, let change = latestAIChange else { return }
        guard !editorDirty else { errorMessage = "请先保存当前草稿，再撤销整理。"; return }
        isBusy = true; isCommittingLocalWrite = true
        defer { isBusy = false; isCommittingLocalWrite = false }
        do {
            let result = try await repository.undoChanges(bookID: bookID, operationID: change.operationID)
            publish(result.project)
            if let id = selectedDocumentID, book?.activeDocuments.contains(where: { $0.id == id }) != true {
                selectedDocumentID = nil; editorMarkdown = ""; editorTitle = ""; documentBaseHash = nil
            } else if let document = book?.activeDocuments.first(where: { $0.id == selectedDocumentID }) { await openDocument(document) }
            activity = "已撤销这次整理；新增笔记进入回收站，后续修改发生冲突时会保留。"
        } catch { errorMessage = error.localizedDescription }
    }
}

struct AIChangeReview: View {
    @EnvironmentObject private var store: AppStore
    var close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("审阅 AI 整理", systemImage: "doc.text.magnifyingglass").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).keyboardShortcut(.cancelAction).help("关闭审阅，不丢弃提案")
            }.padding(18)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if store.pendingCurrentBookChanges.isEmpty { Text("没有待确认的修改。").foregroundStyle(.secondary).padding(24) }
                    ForEach(store.pendingCurrentBookChanges) { pending in
                        VStack(alignment: .leading, spacing: 14) {
                            Text("这次将改变什么").font(.title3.weight(.semibold))
                            ForEach(Array(pending.proposal.summary.enumerated()), id: \.offset) { _, text in Text(text).font(.callout) }
                            ForEach(pending.proposal.documents, id: \.documentID) { document in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(document.title).font(.headline)
                                    if let before = document.before {
                                        Text("原内容").font(.caption).foregroundStyle(.secondary)
                                        Text(before).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.red.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                                    }
                                    Text(document.before == nil ? "新笔记" : "应用后").font(.caption).foregroundStyle(.secondary)
                                    Text(document.after).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Palette.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                                }
                            }
                            HStack {
                                Button("放弃这次提案", role: .destructive) { Task { await store.discardAIChange(pending) } }.buttonStyle(ReadingToolbarButtonStyle())
                                Spacer()
                                Button("应用这次修改") { Task { if await store.applyAIChange(pending), store.pendingCurrentBookChanges.isEmpty { close() } } }.buttonStyle(.borderedProminent).controlSize(.large)
                            }.disabled(store.isBusy)
                        }.padding(20).readingGlass(radius: 20)
                    }
                }.padding(20)
            }
            Text("应用前重新检查原书、项目版本和笔记 hash。冲突会停止，不覆盖后来的编辑。")
                .font(.caption).foregroundStyle(.secondary).padding(16)
        }.background(Palette.canvas).frame(minWidth: 620, idealWidth: 800, minHeight: 500, idealHeight: 680)
    }
}
