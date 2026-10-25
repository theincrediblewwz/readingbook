import SwiftUI
import ReadingCore

/// Reading material and layout permission are independent, explicit choices.
/// Selecting a node does not silently share its mounted Markdown documents.
@MainActor extension AppStore {
    var currentQueryPreferences: ReadingAnswerPreferences {
        ReadingAnswerPreferences(interaction: queryInteractionMode, style: queryAnswerStyle,
            avoidsSpoilers: book?.temporalKnowledge?.profile?.avoidsSpoilers != false)
    }
    func queryHistory(in project: BookProject, preferences: ReadingAnswerPreferences) -> [ChatMessage] {
        project.chats.filter {
            // Earlier versions had only functional, evidence-bound questions.
            ($0.conversationMode ?? .functional) == preferences.interaction && ($0.answerStyle ?? .research) == preferences.style
        }
    }
    var currentQueryHistory: [ChatMessage] { book.map { queryHistory(in: $0, preferences: currentQueryPreferences) } ?? [] }
    func currentQueryTaskSnapshot() throws -> ReadingQuerySnapshot {
        guard let book else { throw ReadingError.invalid("请先打开一本书。") }
        return try ReadingQuerySnapshot.freeze(scope: queryScope, in: book, context: queryReadingContext,
            documentIDs: queryDocumentIDs.map { Array($0).sorted() },
            appendedDocumentIDs: queryScope == .notes ? [] : queryAttachedDocumentIDs.sorted(),
            authorizedNodeIDs: queryInteractionMode == .functional ? queryAuthorizedNodeIDs.sorted() : [])
            .withContextIdentity(currentQueryPreferences.contextIdentity)
    }

    var queryAttachedDocuments: [DocumentRecord] {
        (book?.activeDocuments ?? []).filter { queryAttachedDocumentIDs.contains($0.id) }
    }
    var querySelectableNodes: [CanvasNode] { book?.nodes ?? [] }
    var queryAuthorizedNodes: [CanvasNode] {
        querySelectableNodes.filter { queryAuthorizedNodeIDs.contains($0.id) }
    }
    func queryNodeTitle(_ node: CanvasNode) -> String {
        if let title = node.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        if let document = book?.documents.first(where: { $0.id == node.targetID }) { return document.title }
        if book?.entities.contains(where: { $0.id == node.targetID }) == true || book?.events.contains(where: { $0.id == node.targetID }) == true {
            return objectTitle(node.targetID)
        }
        return "独立节点"
    }
    func setQueryAttachedDocument(_ id: String, included: Bool) {
        guard !isQueryBusy, book?.activeDocuments.contains(where: { $0.id == id }) == true else { return }
        if included {
            guard queryAttachedDocumentIDs.count < 128 || queryAttachedDocumentIDs.contains(id) else { errorMessage = "一次最多附加 128 篇笔记。"; return }
            queryAttachedDocumentIDs.insert(id)
        } else { queryAttachedDocumentIDs.remove(id) }
    }
    func setQueryAuthorizedNode(_ id: String, included: Bool) {
        guard !isQueryBusy, queryInteractionMode == .functional, book?.nodes.contains(where: { $0.id == id }) == true else { return }
        if included {
            guard queryAuthorizedNodeIDs.count < 128 || queryAuthorizedNodeIDs.contains(id) else { errorMessage = "一次最多选择 128 个画布节点。"; return }
            queryAuthorizedNodeIDs.insert(id)
        } else { queryAuthorizedNodeIDs.remove(id) }
    }
    func addSelectedQueryNodes() {
        guard !isQueryBusy, queryInteractionMode == .functional else { return }
        // This method is called only by an explicit reader action. Visibility
        // and ordinary graph selection alone never create query permission.
        let real = Set(querySelectableNodes.map(\.id))
        let selected = Set(renderedSelectedNodeIDs).intersection(real)
        let combined = queryAuthorizedNodeIDs.union(selected)
        guard combined.count <= 128 else { errorMessage = "一次最多选择 128 个画布节点。"; return }
        queryAuthorizedNodeIDs = combined
    }
    func clearQueryTaskAttachments() {
        guard !isQueryBusy else { return }
        queryAttachedDocumentIDs = []; queryAuthorizedNodeIDs = []
    }

    var currentQueryMemory: ConversationMemory? {
        guard let book, let snapshot = try? currentQueryTaskSnapshot(), let memory = loadQueryMemory(for: snapshot),
              ConversationMemoryRuntime.isValid(memory, snapshot: snapshot, history: queryHistory(in: book, preferences: currentQueryPreferences)) else { return nil }
        return memory
    }
    var queryMemorySourceMessages: [ChatMessage] {
        guard let memory = currentQueryMemory else { return [] }
        let ids = Set((memory.requirements + memory.conclusions + memory.unresolved).flatMap(\.sources))
        return currentQueryHistory.filter { ids.contains($0.id) }
    }

    /// Host receipts are operation state, not quotations, adopted conclusions or
    /// new authority. No original chat message is modified or manufactured.
    var queryHostOperationContext: String? {
        guard queryInteractionMode == .functional, let book else { return nil }
        var state: [String: Any] = ["version": 1, "bookID": book.id,
            "meaning": "仅软件操作结果；不是原书事实、用户新授权或继续调用请求。是否再次整理由用户本次选择决定。"]
        let ownReceipts = (book.controlledChanges?.receipts ?? []).filter { $0.originBookID == book.id }
        let receipts = Array(ownReceipts.sorted { ($0.undoneAt ?? $0.createdAt) < ($1.undoneAt ?? $1.createdAt) }.suffix(4))
        let results: [[String: Any]] = receipts.map { receipt in
            ["operationID": receipt.operationID, "status": receipt.undoneAt == nil ? "applied" : "undone",
             "recordCount": receipt.patches.count, "documentCount": receipt.documents.count,
             "groups": receipt.groups.map(\.rawValue), "occurredAt": (receipt.undoneAt ?? receipt.createdAt).timeIntervalSince1970]
        }
        state["currentResults"] = results
        let allDecisions: [[String: Any]] = book.audit.reversed().filter { $0.name == QueryHostOperationRecord.auditName }
            .compactMap { item in
                guard let data = item.summary.data(using: .utf8), data.count <= 1200,
                      let record = try? JSONDecoder().decode(QueryHostOperationRecord.self, from: data),
                      record.bookID == book.id, record.isValid else { return nil }
                // Applied/undone state must still have the canonical durable
                // receipt; an old imported audit row cannot manufacture it.
                if record.status != "discarded" {
                    guard let operationID = record.operationID,
                          ownReceipts.contains(where: { $0.operationID == operationID }) else { return nil }
                }
                var row = record.dictionary; row["occurredAt"] = item.createdAt.timeIntervalSince1970
                return row
            }
        let decisions = Array(allDecisions.prefix(3))
        state["recentReviewDecisions"] = decisions
        state["pendingReview"] = pendingCurrentBookChanges.prefix(3).map {
            ["proposalID": $0.proposal.id, "status": "needs_confirmation", "groups": $0.proposal.groups.map(\.rawValue)] as [String: Any]
        }
        state["pendingReviewCount"] = pendingCurrentBookChanges.count
        state["receiptCount"] = ownReceipts.count
        guard !receipts.isEmpty || !decisions.isEmpty || !pendingCurrentBookChanges.isEmpty else { return nil }
        // Always keep a complete JSON envelope; do not truncate IDs or silently
        // claim an incomplete body is the full operation history.
        state["partial"] = ownReceipts.count > receipts.count || allDecisions.count > decisions.count || pendingCurrentBookChanges.count > 3
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), data.count <= 4000 {
            return String(decoding: data, as: UTF8.self)
        }
        state["recentReviewDecisions"] = []
        state["pendingReview"] = []
        state["partial"] = true
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), data.count <= 4000 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func recordQueryHostOperation(status: String, bookID expectedBookID: String,
                                  proposal: ControlledChangeProposal? = nil, receipt: ControlledChangeReceipt? = nil) async {
        guard ["applied", "discarded", "undone"].contains(status), let base = book, base.id == expectedBookID else { return }
        var current = base
        let groups: [ControlledChangeGroup] = proposal?.groups ?? receipt?.groups ?? []
        let recordCount = receipt?.patches.count ?? proposal?.summary.count ?? 0
        let documentCount = receipt?.documents.count ?? proposal?.documents.count ?? 0
        let record = QueryHostOperationRecord(bookID: expectedBookID, status: status, proposalID: proposal?.id, operationID: receipt?.operationID,
            groups: groups.map(\.rawValue), recordCount: recordCount, documentCount: documentCount)
        guard let data = try? JSONEncoder().encode(record), data.count <= 1200 else { return }
        current.audit.append(ToolAudit(name: QueryHostOperationRecord.auditName, summary: String(decoding: data, as: UTF8.self)))
        let retained = Set(current.audit.filter { $0.name == QueryHostOperationRecord.auditName }.suffix(32).map(\.id))
        current.audit.removeAll { $0.name == QueryHostOperationRecord.auditName && !retained.contains($0.id) }
        do {
            let identity = [expectedBookID, status, proposal?.id ?? "", receipt?.operationID ?? ""].joined(separator: "|")
            let operationID = "query-review-" + (try BookImporter.sha256(Data(identity.utf8)))
            let saved = try await repository.commitAIResult(base: base, result: current, operationID: operationID)
            guard bookID == expectedBookID else { return }
            publish(saved)
        } catch {
            // Commit/undo receipts remain durable even if this auxiliary review
            // history cannot be saved; never turn a successful write into a retry.
            if bookID == expectedBookID { queryDisclosure += "\n整理结果已处理，但这次审阅记录未能保存；实际提交与撤销仍以持久回执为准。" }
        }
    }
}

private struct QueryHostOperationRecord: Codable {
    static let auditName = "query_review_result"
    let bookID: String
    let status: String
    let proposalID: String?
    let operationID: String?
    let groups: [String]
    let recordCount: Int
    let documentCount: Int
    var isValid: Bool {
        guard ["applied", "discarded", "undone"].contains(status), (0...512).contains(recordCount),
              (0...32).contains(documentCount), groups.count <= 4,
              Set(groups).isSubset(of: Set(["knowledge", "graph", "documents", "bookScheme"])) else { return false }
        return [proposalID, operationID].compactMap { $0 }.allSatisfy {
            $0.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil
        }
    }
    var dictionary: [String: Any] {
        var row: [String: Any] = ["status": status, "groups": groups, "recordCount": recordCount, "documentCount": documentCount]
        if let proposalID { row["proposalID"] = proposalID }
        if let operationID { row["operationID"] = operationID }
        return row
    }
}
