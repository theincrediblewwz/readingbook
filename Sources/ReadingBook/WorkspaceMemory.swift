import SwiftUI
import CryptoKit
import ReadingCore

@MainActor extension AppStore {
    var workspaceMemoryKey: String? {
        guard let book else { return nil }
        return book.id + "|" + book.sourceHash
    }
    private var workspaceMemoryURL: URL? {
        guard let key = workspaceMemoryKey else { return nil }
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ReadingBook/Workspace", isDirectory: true).appendingPathComponent(name + ".json")
    }
    func loadWorkspaceMemory() {
        guard let book else { workspaceMemory = BookWorkspaceMemory(); return }
        let saved = workspaceMemoryURL.flatMap { url -> BookWorkspaceMemory? in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(BookWorkspaceMemory.self, from: data)
        }
        workspaceMemory = (saved ?? BookWorkspaceMemory(bookID: book.id, sourceHash: book.sourceHash)).sanitized(bookID: book.id, sourceHash: book.sourceHash)
        UserDefaults.standard.set(book.id, forKey: "workspace-last-book-v1")
    }
    func updateWorkspaceMemory(_ mutate: (inout BookWorkspaceMemory) -> Void, expectedKey: String? = nil) {
        guard !restoringWorkspaceMemory, let book, expectedKey == nil || expectedKey == workspaceMemoryKey,
              workspaceMemory.bookID == book.id, workspaceMemory.sourceHash == book.sourceHash else { return }
        var next = workspaceMemory; mutate(&next)
        next = next.sanitized(bookID: book.id, sourceHash: book.sourceHash)
        guard next != workspaceMemory else { return }
        workspaceMemory = next
        workspaceMemorySaveTask?.cancel()
        workspaceMemorySaveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard !Task.isCancelled else { return }; self?.flushWorkspaceMemory()
        }
    }
    func flushWorkspaceMemory() {
        workspaceMemorySaveTask?.cancel(); workspaceMemorySaveTask = nil
        guard !restoringWorkspaceMemory, let book, workspaceMemory.bookID == book.id,
              workspaceMemory.sourceHash == book.sourceHash, let url = workspaceMemoryURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(workspaceMemory).write(to: url, options: .atomic)
        } catch { activity = "工作区位置未能保存；原书与笔记不受影响。" }
    }
    func rememberWorkspaceNavigation() {
        updateWorkspaceMemory { memory in memory.route = route; memory.documentID = selectedDocumentID }
    }
    func restoreWorkspaceNavigation(expectedBookID: String, generation: Int) async {
        guard let book, book.id == expectedBookID, generation == navigationGeneration else { return }
        let memory = workspaceMemory
        if let from = memory.timeFrom, let to = memory.timeTo { timeFrom = from; timeTo = to }
        temporalAxis = memory.temporalAxis ?? "legacy"; timeCursor = memory.timeCursor ?? timeFrom
        selectedTemporalEntityID = memory.temporalEntityID.flatMap { id in book.entities.contains { $0.id == id } ? id : nil }
        showUndated = memory.showUndated
        readingSourceMode = memory.readingSourceMode
        // An unsaved draft always wins. Restoration never discards or overwrites its Markdown.
        guard !editorDirty else { return }
        if let id = memory.documentID, let document = book.activeDocuments.first(where: { $0.id == id }) {
            await openDocument(document)
            guard bookID == expectedBookID, generation == navigationGeneration else { return }
        }
        let permanent: Set<String> = ["reader", "editor", "workflow", "query", "library", "models", "plugins", "trash", "librarySearch", "book.scheme"]
        let retiredView = book.views.contains { $0.id == memory.route && PluginEngine.isRetiredRenderer($0.rendererID ?? $0.id) }
        let routeExists = !PluginEngine.isRetiredRenderer(memory.route) && !retiredView && (permanent.contains(memory.route) || book.views.contains { $0.id == memory.route } || ComponentKind(rawValue: memory.route) != nil)
        route = routeExists ? memory.route : "reader"
        if route == "editor", selectedDocumentID == nil { route = "reader" }
        if route != "editor" { readingContextDocumentID = nil; selectedObjectID = nil }
    }
    /// Reset disposable layout only; keep reading page, document selection and all content.
    func resetWorkspaceLayout() {
        updateWorkspaceMemory { $0.resetLayout() }
        workspaceMemoryRevision &+= 1; flushWorkspaceMemory()
        activity = "已重置本书窗口布局；原书、笔记、节点与阅读进度保留。"
    }
}
