import SwiftUI
import ReadingCore

/// The suspended query task owns its original transcript/evidence in memory.
/// This bridge only holds the matching host decision; nothing new is put in the
/// book format, and no approval or new authority comes from model text.
struct QueryReviewContinuation {
    let runID: UUID
    let proposalID: String
    let bookID: String
    let sourceHash: String
    let libraryRoot: URL
    let snapshot: ReadingQuerySnapshot
    let continuation: CheckedContinuation<Data, Error>
    var result: Data?
}

@MainActor extension AppStore {
    var canContinueReviewedQuery: Bool {
        guard canProcessAIReview, pendingCurrentBookChanges.isEmpty, queryInteractionMode == .functional else { return false }
        if let waiting = queryReviewContinuation {
            return queryAwaitingReview && queryRunID == waiting.runID && waiting.result != nil
                && bookID == waiting.bookID && book?.sourceHash == waiting.sourceHash && libraryRootURL == waiting.libraryRoot
        }
        return queryAwaitingReview && canStartQuery && queryRetryQuestion != nil
    }

    func waitForQueryReview(proposalID: String, grant: ControlledWriteGrant, snapshot: ReadingQuerySnapshot, runID: UUID) async throws -> Data {
        try Task.checkCancellation()
        guard queryRunID == runID, bookID == grant.bookID, book?.sourceHash == grant.sourceHash,
              queryReviewContinuation == nil,
              pendingAIChanges.contains(where: { $0.id == proposalID && $0.grant.id == grant.id }) else { throw CancellationError() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, queryRunID == runID else { continuation.resume(throwing: CancellationError()); return }
                queryReviewContinuation = QueryReviewContinuation(runID: runID, proposalID: proposalID, bookID: grant.bookID,
                    sourceHash: grant.sourceHash, libraryRoot: libraryRootURL, snapshot: snapshot, continuation: continuation)
                queryAwaitingReview = true
                queryDisclosure = "整理已暂停，等待审阅；已读原文、工具结果和原问题保留，点击继续后从这里接着做。"
                activity = "请先审阅修改，再继续这次整理。"
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelQueryReviewWait(runID: runID) }
        })
    }

    func recordQueryReviewResult(proposalID: String, data: Data) {
        guard var waiting = queryReviewContinuation, waiting.proposalID == proposalID,
              queryRunID == waiting.runID, bookID == waiting.bookID, data.count <= 3600 else { return }
        waiting.result = data; queryReviewContinuation = waiting
        queryDisclosure = "审阅已处理，点击“继续这次整理”后接着原任务；不会重发问题或自动重复读取。"
    }

    func resumeQueryReview() {
        guard canContinueReviewedQuery, let waiting = queryReviewContinuation, let result = waiting.result, let book else { return }
        do {
            // Recheck the actual frozen slices after the human wait; selection
            // drift or OCR/source replacement must not reuse stale evidence.
            _ = try waiting.snapshot.sourceRanges(in: book)
            queryReviewContinuation = nil; queryAwaitingReview = false; queryRetryQuestion = nil
            queryDisclosure = "正在从刚才暂停的位置继续整理…"
            waiting.continuation.resume(returning: result)
        } catch {
            queryReviewContinuation = nil; queryAwaitingReview = false
            waiting.continuation.resume(throwing: CancellationError())
            errorMessage = "原文或选段已改变，原任务已停止；已保存内容保留，请按当前内容重新提问。"
        }
    }

    func cancelQueryReviewWait(runID: UUID) {
        guard let waiting = queryReviewContinuation, waiting.runID == runID else { return }
        queryReviewContinuation = nil
        if queryRunID == runID { queryAwaitingReview = false }
        waiting.continuation.resume(throwing: CancellationError())
    }
}
