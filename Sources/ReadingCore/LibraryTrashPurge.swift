import Foundation

public enum LibraryTrashPurgeTarget: Hashable, Sendable {
    case book(String)
    case document(bookID: String, id: String)
    case manual(bookID: String, id: String)
}

public struct LibraryTrashPurgePlan: Identifiable, Sendable {
    public let id: UUID
    public let titles: [String]
    public let bytes: Int64
    let repositoryOwner: UUID
    let targets: [LibraryTrashPurgeTarget]
    let batches: [LibraryTrashPurgeBatch]
}

struct LibraryTrashPurgeBatch: Sendable {
    let bookID: String
    let archived: Bool
    let metadataHash: String
    let documentHashes: [String: String]
    let manualIDs: Set<String>
    let treeDigest: String?
}

enum LibraryTrashPurgeRuntime {
    /// Forget dependent recovery deltas only after listing them in the user's
    /// confirmation. Active objects and their unrelated changes are retained.
    static func expandedManualIDs(_ requested: Set<String>, documents: Set<String>, in project: BookProject) throws -> Set<String> {
        let items = project.manualTrash?.items ?? []
        guard requested.isSubset(of: Set(items.map(\.id))) else { throw ReadingError.invalid("回收项目已经变化，请重新确认。") }
        var selected = requested
        for item in items where item.patches.contains(where: { $0.collection == .documents && documents.contains($0.id) })
            || item.dependencies.contains(where: { $0.collection == .documents && documents.contains($0.id) }) {
            selected.insert(item.id)
        }
        var changed = true
        while changed {
            changed = false
            for item in items where !selected.contains(item.id) {
                let dependencies = Set(try ManualTrashRuntime.restorePlan(in: project, itemID: item.id).itemIDs)
                if !dependencies.isDisjoint(with: selected) { selected.insert(item.id); changed = true }
            }
        }
        return selected
    }

    static func removing(documents: Set<String>, manualIDs: Set<String>, in project: BookProject) throws -> BookProject {
        guard documents.isSubset(of: Set(project.trashedDocuments.map(\.id))) else {
            throw ReadingError.invalid("只能永久删除回收站中的笔记；原书和使用中的笔记保留。")
        }
        var result = project
        var state = result.manualTrash ?? .init()
        guard state.revision < Int.max else { throw ReadingError.invalid("回收版本已到上限，请先导出备份。") }
        state.items.removeAll { manualIDs.contains($0.id) }; state.revision += 1
        result.manualTrash = state
        for id in documents.sorted() { result = try KnowledgeDeletion.removingTrashedDocument(id: id, from: result) }
        result.audit.append(ToolAudit(name: "user_purge_trash", summary: "用户确认永久删除回收站中的 \(documents.count) 篇笔记、\(manualIDs.count) 项恢复快照；使用中的内容保留。"))
        return result
    }
}
