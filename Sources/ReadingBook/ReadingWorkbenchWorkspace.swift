import SwiftUI
import ReadingCore

@MainActor extension AppStore {
    func prepareWorkbenchContinuation(_ view: ViewDefinition) {
        guard ReadingWorkbench.isWorkbench(view), book?.views.contains(where: { $0.id == view.id }) == true,
              !isQueryBusy, !editorDirty, positionNoteRequest == nil, positionNoteBinding == nil else { return }
        guard queryComposerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            readingCompanionVisible = true; readingCompanionTab = "chat"
            activity = "输入框已有未发送内容，先保留；发送或清空后可继续整理工作台。"
            return
        }
        // The button prepares, never sends. The reader sees the source range,
        // permission switch and exact question before submitting a new request.
        queryInteractionMode = .functional
        queryScope = .readSoFar
        queryAllowsOrganizing = true
        queryComposerDraft.text = ReadingWorkbench.continuationQuestion(view: view)
        readingCompanionVisible = true; readingCompanionTab = "chat"
    }
}
