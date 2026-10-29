import SwiftUI
import AppKit
import ReadingCore

@MainActor final class StorageSettingsState: ObservableObject {
    var runID = UUID()
    @Published var overview: LibraryStorageOverview?
    @Published var working = false
    @Published var phase = ""
    @Published var completed = 0
    @Published var total = 0
    @Published var notice = ""
    @Published var error: String?
}

private final class StorageProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var phase = ""
    private var time = 0.0
    private let handler: @Sendable (LibraryTransferProgress) -> Void
    init(_ handler: @escaping @Sendable (LibraryTransferProgress) -> Void) { self.handler = handler }
    func accept(_ value: LibraryTransferProgress) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        guard phase != value.stage || value.completedFiles == value.totalFiles || now - time >= 0.1 else { lock.unlock(); return }
        phase = value.stage; time = now; lock.unlock(); handler(value)
    }
}

@MainActor extension AppStore {
    func refreshStorageOverview() async {
        let root = libraryRootURL, owner = repository
        guard AppDataLocations.configuredRootAvailable else { storageState.error = "书库位置暂不可用。"; return }
        do { let value = try await owner.storageOverview(); if libraryRootURL == root { storageState.overview = value } }
        catch { if libraryRootURL == root { storageState.error = error.localizedDescription } }
    }
    func showLibraryFolder() {
        guard AppDataLocations.configuredRootAvailable else { storageState.error = "书库位置暂不可用。"; return }
        let owner = repository, root = libraryRootURL
        Task { _ = try? await owner.refreshReadableLibraryIndex(); NSWorkspace.shared.open(root) }
    }
    func refreshMissingReadableFiles() {
        readableRefreshTask?.cancel()
        let owner = repository, root = libraryRootURL, ids = (books + removedBooks).map(\.id)
        readableRefreshTask = Task.detached(priority: .utility) {
            for id in ids {
                guard !Task.isCancelled else { return }
                let guide = root.appendingPathComponent("books").appendingPathComponent(id).appendingPathComponent("阅读导航.md")
                if !FileManager.default.fileExists(atPath: guide.path) { _ = try? await owner.refreshReadableViews(id: id, archived: false) }
            }
            if !Task.isCancelled { _ = try? await owner.refreshReadableLibraryIndex() }
        }
    }
    func openExistingLibrary() {
        guard canManageStorage else { storageState.error = "请先保存笔记并结束当前任务。"; return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "打开书库"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("books").path, isDirectory: &directory), directory.boolValue else {
            storageState.error = "请选择含 books 文件夹的 ReadingBook 书库。"; return
        }
        guard prepareStorageOperation() else { return }
        storageState.phase = "核对已有书库"
        Task {
            defer { isBusy = false; storageState.working = false }
            do { try await activateLibrary(at: url); storageState.notice = "已打开书库。" }
            catch { storageState.error = error.localizedDescription }
            await refreshStorageOverview()
        }
    }
    func showBookFolder(_ id: String) {
        let owner = repository
        Task {
            do {
                let info = try await owner.storageBook(id: id)
                _ = try? await owner.refreshReadableViews(id: id, archived: false)
                NSWorkspace.shared.open(info.directoryURL)
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private var canManageStorage: Bool {
        !isBusy && !isSavingDocument && !isExportingProject && !isImportingBookCommit && !isCommittingLocalWrite
            && !storageState.working && !isManagingQueryMemory && pendingAIHistoryWrites == 0
            && !teacherBackground.hasRunningTasks && !sentenceTranslation.hasRunningTasks
            && catalogOperations == 0 && !editorDirty && pendingAIChanges.isEmpty
            && deletionRequest == nil
    }
    private func prepareStorageOperation() -> Bool {
        guard canManageStorage else {
            storageState.error = editorDirty ? "请先保存笔记。" : "请先结束当前任务或处理待审阅修改。"
            return false
        }
        NotificationCenter.default.post(name: Notification.Name("ReadingBookCaptureWorkspaceMemory"), object: nil)
        flushWorkspaceMemory(); flushDocumentDraft()
        readableRefreshTask?.cancel(); readableRefreshTask = nil
        storageState.error = nil; storageState.notice = ""; storageState.completed = 0; storageState.total = 0
        storageState.runID = UUID()
        storageState.working = true; isBusy = true
        return true
    }
    private func transferProgress(_ value: LibraryTransferProgress) {
        storageState.phase = value.stage; storageState.completed = value.completedFiles; storageState.total = value.totalFiles
    }
    private func storageProgressHandler() -> @Sendable (LibraryTransferProgress) -> Void {
        let runID = storageState.runID
        let relay = StorageProgressRelay { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.storageState.runID == runID, self.storageState.working else { return }
                self.transferProgress(value)
            }
        }
        return { relay.accept($0) }
    }
    func chooseLibraryLocation() {
        guard canManageStorage else { storageState.error = "请先保存笔记并结束当前任务。"; return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "使用此文件夹"; panel.message = "选择空文件夹。校验后切换，原书库保留。"
        guard panel.runModal() == .OK, let destination = panel.url, prepareStorageOperation() else { return }
        storageState.phase = "准备迁移"
        let owner = repository
        let progress = storageProgressHandler()
        Task {
            defer { isBusy = false; storageState.working = false }
            do {
                let result = try await owner.copyLibrary(to: destination, progress: progress)
                try await activateLibrary(at: result.rootURL)
                storageState.notice = "已切换书库，原目录保留。"
            } catch { storageState.error = error.localizedDescription }
            await refreshStorageOverview()
        }
    }
    func exportLibraryBackup() {
        guard canManageStorage else { storageState.error = "请先保存笔记并结束当前任务。"; return }
        let panel = NSSavePanel(); panel.canCreateDirectories = true
        panel.nameFieldStringValue = "ReadingBook-" + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) + ".readingbookbackup"
        panel.message = "包含书籍、笔记、分析及回收内容，不含本机连接设置和密钥。"
        guard panel.runModal() == .OK, let url = panel.url, prepareStorageOperation() else { return }
        storageState.phase = "准备备份"
        let owner = repository
        let progress = storageProgressHandler()
        Task {
            defer { isBusy = false; storageState.working = false }
            do {
                _ = try await owner.exportLibraryBackup(to: url, progress: progress)
                storageState.notice = "备份已导出并校验。"; NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { storageState.error = error.localizedDescription }
        }
    }
    func restoreLibraryBackup() {
        guard canManageStorage else { storageState.error = "请先保存笔记并结束当前任务。"; return }
        let sourcePanel = NSOpenPanel(); sourcePanel.canChooseDirectories = true; sourcePanel.canChooseFiles = true
        sourcePanel.treatsFilePackagesAsDirectories = false; sourcePanel.prompt = "选择备份"
        guard sourcePanel.runModal() == .OK, let source = sourcePanel.url else { return }
        let destinationPanel = NSOpenPanel(); destinationPanel.canChooseDirectories = true; destinationPanel.canChooseFiles = false
        destinationPanel.canCreateDirectories = true; destinationPanel.message = "恢复到空文件夹，现有书库保留。"; destinationPanel.prompt = "恢复到这里"
        guard destinationPanel.runModal() == .OK, let destination = destinationPanel.url, prepareStorageOperation() else { return }
        storageState.phase = "核对备份"
        let owner = repository
        let progress = storageProgressHandler()
        Task {
            defer { isBusy = false; storageState.working = false }
            do {
                let result = try await owner.restoreLibraryBackup(from: source, to: destination, progress: progress)
                try await activateLibrary(at: result.rootURL)
                storageState.notice = "备份已恢复，原书库保留。"
            } catch { storageState.error = error.localizedDescription }
            await refreshStorageOverview()
        }
    }
    func exportReadableLibrary() {
        guard canManageStorage else { storageState.error = "请先保存笔记并结束当前任务。"; return }
        let panel = NSSavePanel(); panel.canCreateDirectories = true; panel.nameFieldStringValue = "ReadingBook-可读内容"
        guard panel.runModal() == .OK, let destination = panel.url, prepareStorageOperation() else { return }
        storageState.phase = "整理可读内容"
        let owner = repository
        Task {
            defer { isBusy = false; storageState.working = false }
            do {
                let url = try await owner.exportReadableLibrary(to: destination)
                storageState.notice = "可读内容已导出。"; NSWorkspace.shared.open(url)
            } catch { storageState.error = error.localizedDescription }
        }
    }
    private func activateLibrary(at url: URL) async throws {
        let next = LibraryRepository(rootURL: url)
        let report = try await next.loadReport()
        guard report.issues.isEmpty else { throw ReadingError.invalid("新书库核验未通过，仍使用原目录。") }
        let nextRemoved = try await next.removedBooksReport()
        let nextTrash = try await next.trashReport()
        guard nextRemoved.issues.isEmpty && nextTrash.issues.isEmpty else { throw ReadingError.invalid("恢复内容核验未通过，仍使用原目录。") }
        workspaceMemorySaveTask?.cancel(); workspaceMemorySaveTask = nil
        readingIndexTask?.cancel(); readingIndexGeneration &+= 1
        readingIndexCache = [:]; readingIndexCacheOrder = []; readingExperienceIndex = ReadingExperienceState(); readingContextCacheKey = nil
        navigationGeneration &+= 1
        bookID = nil; selectedUnitID = nil; selectedDocumentID = nil; selectedObjectID = nil; sourceFileURL = nil
        pdfSourceAdmissionLeases = [:]; pdfDisplayReloadID = UUID()
        pdfSessionPasswords = [:]; pdfUnlockedBookIDs = []
        workspaceMemory = BookWorkspaceMemory(); workspaceMemoryRevision &+= 1
        deletionRequest = nil; lastTrashedProjectURL = nil
        AppDataLocations.selectRoot(url); libraryRootURL = url; repository = next
        storageState.overview = nil
        modelCatalogRepository = ModelCatalogRepository(rootURL: url.appendingPathComponent("ModelCatalog", isDirectory: true))
        providerCatalog = .current
        books = report.projects; removedBooks = nextRemoved.projects; archivedBooks = nextTrash.projects
        route = "library"; await loadModelCatalog()
        refreshMissingReadableFiles()
    }
    func restoreRemovedBook(_ id: String) async {
        guard !isBusy, !editorDirty else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let project = try await repository.rejoinBook(id: id)
            publish(project); await reloadTrash(); activity = "已重新加入书库。"
        } catch { errorMessage = error.localizedDescription }
    }
}
