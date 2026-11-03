import Foundation
import ReadingCore

extension AppStore {
    func saveReaderAnnotations(_ annotations: [ReaderAnnotation]) async -> Bool {
        guard let current = book, !annotations.isEmpty else { return false }
        guard !isBusy else { errorMessage = "当前任务尚未结束，请稍后保存批注；已填写内容保留在批注窗口。"; return false }
        isBusy = true; isCommittingLocalWrite = true
        let owner = WorkspacePickerOwner(store: self), repository = repository
        defer { isBusy = false; isCommittingLocalWrite = false }
        do {
            let ids = Set(annotations.map(\.id))
            let saved = try await repository.saveAnnotations(project: current, annotations: annotations,
                expectedAnnotations: (current.readerAnnotations ?? []).filter { ids.contains($0.id) })
            guard owner.matches(self) else { return false }
            readerEditUndo.recordAnnotations(before: current, after: saved, ids: ids, owner: owner)
            publish(saved); activity = "标记已保存，可用⌘Z撤销；原PDF保持不变。"
            return true
        } catch { if owner.matches(self) { errorMessage = error.localizedDescription }; return false }
    }

    func setReaderAnnotationTrashed(_ id: String, trashed: Bool) async -> Bool {
        guard let current = book else { return false }
        guard !isBusy else { errorMessage = "当前任务尚未结束，请稍后删除或恢复批注。"; return false }
        isBusy = true; isCommittingLocalWrite = true
        let owner = WorkspacePickerOwner(store: self), repository = repository
        defer { isBusy = false; isCommittingLocalWrite = false }
        do {
            let saved = try await repository.setAnnotationTrashed(project: current, annotationID: id, trashed: trashed)
            guard owner.matches(self) else { return false }
            readerEditUndo.recordAnnotations(before: current, after: saved, ids: [id], owner: owner)
            publish(saved); activity = trashed ? "批注已移入回收列表，可恢复。" : "批注已恢复。"
            return true
        } catch { if owner.matches(self) { errorMessage = error.localizedDescription }; return false }
    }
}
