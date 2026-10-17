import SwiftUI
import ReadingCore

@MainActor extension AppStore {
    /// A local calculation stores the exact supplied values, independently from AI prose.
    func verifyMathematics(_ supplied: MathVerificationRequest, inBook expectedBookID: String) async -> String? {
        guard var current = book, current.id == expectedBookID, !isBusy, !isSavingDocument else { return nil }
        guard (current.mathVerifications?.count ?? 0) < MathVerificationTools.maximumRecords else {
            errorMessage = "本书已达到 256 条核查记录上限；删除的记录仍保留以便恢复。请导出书项目留存。"; return nil
        }
        let request: MathVerificationRequest = {
            var value = supplied; value.origin = .user; return value
        }()
        guard request.evidence.allSatisfy({ evidence in current.units.contains { $0.id == evidence.unitID && !evidence.quote.isEmpty && $0.text.range(of: evidence.quote, options: .literal) != nil } }) else {
            errorMessage = "原文出处已变化，请重新选择后核查。"; return nil
        }
        let expectedID = current.id, expectedHash = current.sourceHash
        isBusy = true; isCommittingLocalWrite = true
        defer { isBusy = false; isCommittingLocalWrite = false }
        do {
            let record = try await Task.detached(priority: .userInitiated) { try MathVerificationEngine.verify(request) }.value
            guard bookID == expectedID, book?.sourceHash == expectedHash else { throw ReadingError.invalid("书籍已切换，未保存到其他书。") }
            current.mathVerifications = (current.mathVerifications ?? []) + [record]
            try await repository.save(current); publish(current)
            activity = record.summary
            return record.id
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func setMathVerificationDeleted(_ id: String, deleted: Bool, inBook expectedBookID: String) async {
        guard var current = book, current.id == expectedBookID, !isBusy, !isSavingDocument,
              let index = current.mathVerifications?.firstIndex(where: { $0.id == id }) else { return }
        isBusy = true; isCommittingLocalWrite = true
        defer { isBusy = false; isCommittingLocalWrite = false }
        current.mathVerifications?[index].deletedAt = deleted ? Date() : nil
        do {
            try await repository.save(current); publish(current)
            activity = deleted ? "核查记录已收起到已删除，可在数学核查中恢复。" : "核查记录已恢复。"
        } catch { errorMessage = error.localizedDescription }
    }

    func makeNoteFromMathVerification(_ record: MathVerificationRecord) {
        guard let book, book.mathVerifications?.contains(where: { $0.id == record.id && $0.deletedAt == nil }) == true,
              !editorDirty, !isBusy else { errorMessage = "请先保存当前草稿或等待任务结束。"; return }
        newDocument(); editorTitle = record.title; draftEvidence = record.request.evidence
        let links = record.request.evidence.compactMap { evidence -> String? in
            var url = URLComponents(); url.scheme = "readingbook"; url.host = "book"; url.path = "/\(book.id)/unit/\(evidence.unitID)"
            url.queryItems = [URLQueryItem(name: "quote", value: evidence.quote)]
            return url.string.map { "[回到原文](\($0))" }
        }.joined(separator: "\n\n")
        editorMarkdown = record.markdown + (links.isEmpty ? "" : "\n\n" + links) + "\n\n## 我的理解\n\n"
        activity = "核查结果已放入新 Markdown 草稿；保存后才成为文档。"
    }
}
