import Foundation
import ReadingCore

extension AppStore {
    func saveReaderAnnotations(_ annotations: [ReaderAnnotation]) async -> Bool {
        guard let current = book, !annotations.isEmpty else { return false }
        guard !isBusy else { errorMessage = "当前任务尚未结束，请稍后保存批注；已填写内容保留在批注窗口。"; return false }
        isBusy = true; isCommittingLocalWrite = true
        defer { isBusy = false; isCommittingLocalWrite = false }
        do {
            let saved = try await repository.saveAnnotations(project: current, annotations: annotations)
            publish(saved); activity = "PDF高亮与批注已保存，原PDF保持不变。"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func setReaderAnnotationTrashed(_ id: String, trashed: Bool) async -> Bool {
        guard let current = book else { return false }
        guard !isBusy else { errorMessage = "当前任务尚未结束，请稍后删除或恢复批注。"; return false }
        isBusy = true; isCommittingLocalWrite = true
        defer { isBusy = false; isCommittingLocalWrite = false }
        do {
            let saved = try await repository.setAnnotationTrashed(project: current, annotationID: id, trashed: trashed)
            publish(saved); activity = trashed ? "批注已移入回收列表，可恢复。" : "批注已恢复。"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}
