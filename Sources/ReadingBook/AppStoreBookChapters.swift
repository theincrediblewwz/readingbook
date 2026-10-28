import Foundation
import CryptoKit
import ReadingCore

/// A bounded process cache also remembers that a verified PDF has no outline.
/// Its key includes extraction bytes and file metadata. A hit still verifies the
/// original file bytes; it avoids parsing an unchanged PDF a second time.
private actor OriginalChapterOutlineCache {
    static let shared = OriginalChapterOutlineCache()
    private struct Key: Hashable {
        let path: String
        let sourceHash: String
        let fingerprint: String
        let size: Int
        let modified: Date?
    }
    private struct Value { let key: Key; let outline: BookChapterOutline? }
    private var values: [Value] = []

    /// A local preview may reuse metadata-matched extraction. It is never a
    /// source admission proof: starting work still calls read and hashes bytes.
    func preview(url: URL, project: BookProject, password: String?) throws -> BookChapterOutline? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard resource.isRegularFile == true, resource.isSymbolicLink != true,
              let size = resource.fileSize, size > 0, size <= 256 * 1_024 * 1_024 else {
            throw ReadingError.invalid("原书文件无法安全读取。")
        }
        let candidate = Key(path: url.standardizedFileURL.path, sourceHash: project.sourceHash,
                            fingerprint: try BookOutlineRuntime.fingerprint(in: project), size: size,
                            modified: resource.contentModificationDate)
        if let value = values.first(where: { $0.key == candidate }) { return value.outline }
        return try read(url: url, project: project, password: password)
    }

    func read(url: URL, project: BookProject, password: String?) throws -> BookChapterOutline? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let fingerprint = try BookOutlineRuntime.fingerprint(in: project)
        func key() throws -> Key {
            let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard resource.isRegularFile == true, resource.isSymbolicLink != true, let size = resource.fileSize,
                  size > 0, size <= 256 * 1_024 * 1_024 else { throw ReadingError.invalid("原书文件无法安全读取。") }
            return Key(path: url.standardizedFileURL.path, sourceHash: project.sourceHash, fingerprint: fingerprint,
                       size: size, modified: resource.contentModificationDate)
        }
        let before = try key()
        if let position = values.firstIndex(where: { $0.key == before }) {
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            try Task.checkCancellation()
            let sourceHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard bytes.count == before.size, sourceHash == project.sourceHash,
                  try key() == before else { throw ReadingError.invalid("原书文件已变化，请重新打开书籍。") }
            let value = values.remove(at: position); values.append(value); return value.outline
        }
        let outline = try BookChapterRuntime.originalPDFOutline(at: url, project: project, password: password)
        try Task.checkCancellation()
        guard try key() == before else { throw ReadingError.invalid("原书正在更新，请稍后重新打开目录。") }
        values.removeAll { $0.key.path == before.path }
        values.append(Value(key: before, outline: outline))
        if values.count > 8 { values.removeFirst(values.count - 8) }
        return outline
    }
}

@MainActor extension AppStore {
    /// Resolve chapter meaning for an execution preview without saving an
    /// outline, changing the selected session, or starting a model request.
    func readingContinuationSourceSnapshot(project: BookProject) async throws -> BookProject {
        guard project.originalName.lowercased().hasSuffix(".pdf") else { return project }
        guard bookID == project.id, let source = sourceFileURL else {
            throw ReadingError.invalid("请先打开原书，再选择分析范围。")
        }
        let root = libraryRootURL, owner = repository.publicationOwner
        let password = pdfPassword(for: project.id)
        let worker = Task.detached(priority: .userInitiated) {
            var snapshot = project
            if let outline = try await OriginalChapterOutlineCache.shared.preview(url: source, project: project, password: password) {
                snapshot.originalBookOutline = outline
            }
            return snapshot
        }
        let snapshot = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        guard libraryRootURL == root, repository.publicationOwner == owner, bookID == project.id,
              book?.sourceHash == project.sourceHash, sourceFileURL == source else { throw CancellationError() }
        return snapshot
    }

    /// This runs before chapter queries/tasks as well as the directory panel.
    /// A reader does not have to open the directory to authorize a real chapter.
    func ensureBookChapterOutline(project: BookProject) async throws -> BookProject {
        try Task.checkCancellation()
        guard project.originalName.lowercased().hasSuffix(".pdf") else { return project }
        guard bookID == project.id, let source = sourceFileURL else { throw ReadingError.invalid("请先打开原书，再读取章节。") }
        let root = libraryRootURL, repository = repository
        guard try await ensurePDFSession(bookID: project.id, sourceURL: source) else { throw PDFPasswordError.needsPassword }
        try Task.checkCancellation()
        let password = pdfPassword(for: project.id)
        let worker = Task.detached(priority: .userInitiated) {
            let outline = try await OriginalChapterOutlineCache.shared.read(url: source, project: project, password: password)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let needsSave = try outline.map { try encoder.encode($0) != encoder.encode(project.originalBookOutline) } ?? false
            return (outline, needsSave)
        }
        let (outline, needsSave) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        guard bookID == project.id, libraryRootURL == root, sourceFileURL == source else { throw CancellationError() }
        guard let outline else { return project }
        if !needsSave { return project }
        let saved = try await repository.saveOriginalBookOutline(bookID: project.id, outline: outline)
        guard bookID == project.id, libraryRootURL == root, sourceFileURL == source else { throw CancellationError() }
        _ = publish(saved)
        return saved
    }

    /// This is only a cursor hint. Core resolves the proof against canonical
    /// source before it grants chapter authority. Mismatched units yield nil.
    func chapterReadingOffset(in project: BookProject, unitID: String? = nil) -> Int? {
        chapterReadingAnchor(in: project, unitID: unitID)?.utf16Location
    }
    func chapterReadingAnchor(in project: BookProject, unitID: String? = nil) -> SourceAnchor? {
        let id = unitID ?? selectedUnitID
        for anchor in [selectedSourceAnchor, focusedReadingSourceAnchor, readerChapterAnchor].compactMap({ $0 }) {
            if anchor.sourceHash == project.sourceHash, anchor.unitID == id { return anchor }
        }
        return nil
    }

    func navigateToChapter(_ entry: BookOutlineEntry) {
        guard let project = book else { return }
        if let anchor = entry.anchor {
            guard anchor.sourceHash == project.sourceHash,
                  (try? ReadingExperienceRuntime.resolve(anchor, in: project)) != nil else {
                readingExperienceError = "章节位置已变化，请重新打开目录。"; return
            }
            navigateToUnit(anchor.unitID)
            if !readingExperienceIndex.anchors.contains(where: { $0.id == anchor.id }) { readingExperienceIndex.anchors.append(anchor) }
            readerChapterAnchor = anchor
            focusedReadingAnchorID = anchor.id
            route = "reader"
        } else if let page = entry.page, let unit = project.units.first(where: { $0.page == page }) {
            navigateToUnit(unit.id)
        } else if !project.originalName.lowercased().hasSuffix(".pdf") { navigateToUnit(entry.id) }
    }
}
