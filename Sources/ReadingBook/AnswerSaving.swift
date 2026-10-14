import Foundation
import ReadingCore

extension AppStore {
    /// Rebuild against the current conversation before saving. Repeating a save
    /// opens the existing document; it never replaces the user's later Markdown.
    @discardableResult
    func saveAnswerComposition(_ composition: SavedAnswerComposition, title: String, onError: ((String) -> Void)? = nil) async -> Bool {
        func fail(_ message: String) -> Bool { if let onError { onError(message) } else { errorMessage = message }; return false }
        guard var current = book, current.id == composition.bookID else { return fail("书籍已切换，请从当前会话重新选择回答。") }
        guard !isBusy else { return fail("请等待当前任务完成后再保存回答。") }
        do {
            let validated = try SavedAnswerComposition.build(project: current, parts: composition.parts, title: title)
            guard validated.documentID == composition.documentID else { throw ReadingError.invalid("回答内容已变化，请重新预览。") }
            if let existing = current.documents.first(where: { $0.id == validated.documentID }) {
                if existing.trashedAt != nil {
                    return fail("这份回答摘记已在回收站，请先恢复原文档；不会另建副本或覆盖正文。")
                }
                activity = "这份回答已保存；原文档及你的后续修改保留。"
                return true
            }
            isBusy = true; isSavingDocument = true
            defer { isBusy = false; isSavingDocument = false }
            let document = DocumentRecord(id: validated.documentID, title: validated.suggestedTitle, origin: "saved-answer",
                                          linkedIDs: validated.linkedIDs, evidence: validated.evidence)
            let index = current.nodes.count
            let node = CanvasNode(targetID: document.id, x: Double(index % 3) * 270 + 60, y: Double(index / 3) * 150 + 60)
            current.nodes.append(node)
            current = try await repository.saveDocument(project: current, document: document, markdown: validated.markdown)
            publish(current)
            activity = "已保存 \(validated.messageIDs.count) 条回答的摘记为 Markdown 与导图节点。"
            return true
        } catch { return fail(error.localizedDescription) }
    }
}
