import Foundation

public struct LibraryLoadIssue: Sendable {
    public var folder: String
    public var message: String
    public init(folder: String, message: String) { self.folder = folder; self.message = message }
}

public struct LibraryLoadReport: Sendable {
    public var projects: [BookProject]
    public var issues: [LibraryLoadIssue]
    public init(projects: [BookProject], issues: [LibraryLoadIssue]) { self.projects = projects; self.issues = issues }
}

public struct DocumentContentSnapshot: Sendable {
    public var markdown: String
    public var contentHash: String
    public init(markdown: String, contentHash: String) { self.markdown = markdown; self.contentHash = contentHash }
}

/// Local, file-backed library. Markdown files are the only document body source;
/// project.json contains references and structured book analysis, never a body mirror.
public actor LibraryRepository {
    public nonisolated let publicationOwner = UUID()
    private var publicationOrdinal: UInt64 = 0
    let rootURL: URL
    let files = FileManager.default
    private static let metadataLimit = 64 * 1_024 * 1_024
    private static let documentLimit = 16 * 1_024 * 1_024
    private static let packageLimit = 512 * 1_024 * 1_024
    private static let changePreviewLimit = 8 * 1_024 * 1_024
    private struct DocumentValidationStamp: Equatable {
        var size: Int
        var modified: Date
        var created: Date?
        var fileNumber: UInt64?
        var deviceNumber: UInt64?
    }
    private var documentValidationCache: [String: DocumentValidationStamp] = [:]
    private var mathValidationCache = MathVerificationValidationCache()
    private struct SourceManifest {
        var sourceHash: String
        var units: [SourceUnit]
        var hashes: [String: String]
    }
    private var sourceManifests: [String: SourceManifest] = [:]
    var readableAutomaticRefresh: [String: Date] = [:]
    var pendingReadableRefresh: [String: Task<Void, Never>] = [:]
    private struct ChangeGrantSession { var grant: ControlledWriteGrant; var latestRevision: String }
    private var changeGrants: [String: ChangeGrantSession] = [:]
    private var changeProposals: [String: PreparedControlledChange] = [:]
    private var changeProposalGrants: [String: String] = [:]
    private var changeApprovals: [String: String] = [:]
    private var changeCommitRevisions: [String: String] = [:]

    private struct DocumentJournal: Codable {
        var version: Int = 1
        var bookID: String
        var documentID: String
        var markdownHash: String
        var previousMarkdownHash: String? = nil
        var project: BookProject
    }

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func loadAll() throws -> [BookProject] {
        try loadReport().projects
    }

    /// Recover readable books independently. Damaged and interrupted imports stay
    /// exactly where they are and produce diagnostics instead of hiding healthy books.
    public func loadReport() throws -> LibraryLoadReport {
        let books = try booksDirectory()
        let children = try files.contentsOfDirectory(at: books, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var projects: [BookProject] = []
        var issues: [LibraryLoadIssue] = []
        let removed: Set<String>
        do { removed = Set(try libraryMembership().removed.keys) }
        catch { removed = []; issues.append(LibraryLoadIssue(folder: rootURL.path, message: "书库显示状态未能读取，文件保留：\(error.localizedDescription)")) }
        for directory in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if directory.lastPathComponent == ".DS_Store" || removed.contains(directory.lastPathComponent) { continue }
            // Incomplete imports have not entered the committed book namespace. Keep them
            // on disk and surface them rather than quietly discarding possible recovery data.
            guard UUID(uuidString: directory.lastPathComponent) != nil else {
                let unfinished = directory.lastPathComponent.hasPrefix(".creating-") || directory.lastPathComponent.hasPrefix(".importing-")
                issues.append(LibraryLoadIssue(folder: directory.path, message: unfinished ? "发现未完成的导入暂存目录，已保留恢复现场，不影响其他书籍。" : "无法识别的书库条目，已保留原文件。"))
                continue
            }
            do {
                let checked = try bookDirectory(directory.lastPathComponent, mustExist: true)
                try recoverDocument(in: checked)
                let project = try readProject(in: checked)
                guard project.id == directory.lastPathComponent else { throw ReadingError.invalid("项目 ID 与文件夹不一致。") }
                try validate(project)
                try validatePackageFiles(project, in: checked, strictContents: false, verifySourceHash: true)
                projects.append(project)
            } catch {
                issues.append(LibraryLoadIssue(folder: directory.path, message: "无法载入此书：\(error.localizedDescription) 原文件已保留，其他书籍仍可使用。"))
            }
        }
        return LibraryLoadReport(projects: projects.sorted { $0.importedAt > $1.importedAt }, issues: issues)
    }

    @discardableResult
    public func create(_ project: BookProject, sourceURL: URL) throws -> BookProject {
        try validate(project)
        guard project.documents.isEmpty else { throw ReadingError.invalid("创建书籍时不能引用尚未写入的 Markdown。请随后使用 saveDocument 保存。") }
        let destination = try bookDirectory(project.id, mustExist: false)
        guard !files.fileExists(atPath: destination.path) else { throw ReadingError.invalid("书籍 ID 已存在；没有覆盖原项目。") }
        try verifyOriginal(at: sourceURL, expectedHash: project.sourceHash)
        let staging = try temporaryDirectory(near: try booksDirectory(), prefix: ".creating-")
        defer { removeOwnTemporary(staging) }
        try writePackage(project, source: sourceURL, documentsFrom: nil, to: staging)
        try validatePackageFiles(project, in: staging, strictContents: true, verifySourceHash: true)
        try files.moveItem(at: staging, to: destination)
        _ = try? refreshReadableViews(id: project.id)
        _ = try? refreshReadableLibraryIndex()
        // The committed import must enter the UI with this repository's
        // publication identity, just like load/save. The caller's draft has no
        // stamp and cannot authorize reuse of disposable page preparation.
        return stampForPublication(project)
    }

    @discardableResult
    public func save(_ project: BookProject) throws -> BookProject {
        try saveCanonicalProject(project)
    }

    /// Canonical metadata after host-only caches have been merged. Callers
    /// publishing a saved result must use this returned value, not their draft.
    func saveCanonicalProject(_ project: BookProject, generatedOutline: GeneratedBookOutline? = nil, originalBookOutline: BookChapterOutline? = nil, readerCollections: ReaderCollectionState? = nil) throws -> BookProject {
        let directory = try bookDirectory(project.id, mustExist: true)
        try recoverDocument(in: directory)
        let existing = try readProject(in: directory)
        try requireCurrentChangeHistory(project, existing: existing)
        guard existing.id == project.id, existing.originalName == project.originalName, existing.sourceHash == project.sourceHash else {
            throw ReadingError.invalid("保存不能替换项目身份或原书。")
        }
        // A stale window must not erase references to user-owned Markdown documents.
        guard Set(existing.documents.map(\.id)).isSubset(of: Set(project.documents.map(\.id))) else {
            throw ReadingError.invalid("项目中的 Markdown 引用比磁盘版本少，已阻止覆盖。请重新载入书籍。")
        }
        var updated = project
        updated.aiRequestHistory = try AIRequestHistoryMerge.merge(proposed: project.aiRequestHistory, canonical: existing.aiRequestHistory)
        updated.readerAnnotations = existing.readerAnnotations
        updated.generatedOutline = generatedOutline ?? existing.generatedOutline
        updated.originalBookOutline = originalBookOutline ?? existing.originalBookOutline
        updated.readerCollections = readerCollections ?? existing.readerCollections
        // Only the explicit trash/restore API changes this canonical status. A stale reader
        // or editor window cannot silently revive a document through a routine save.
        let documentIndices = Dictionary(updated.documents.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for saved in existing.documents {
            if let index = documentIndices[saved.id] { updated.documents[index].trashedAt = saved.trashedAt }
        }
        try ReadingKnowledgeRuntime.captureVersions(before: existing, in: &updated)
        try validate(updated)
        let metadata = try encode(updated)
        try validatePackageFiles(updated, in: directory, strictContents: false, verifySourceHash: false, encodedMetadataSize: metadata.count, reuseDocumentValidation: true)
        try atomicWrite(metadata, to: try child(directory, "project.json"))
        refreshReadableAfterCommit(id: updated.id)
        return stampForPublication(updated)
    }

    public func readDocument(bookID: String, document: DocumentRecord) throws -> String {
        try readDocumentSnapshot(bookID: bookID, document: document).markdown
    }

    public func readDocumentSnapshot(bookID: String, document: DocumentRecord) throws -> DocumentContentSnapshot {
        let directory = try bookDirectory(bookID, mustExist: true)
        try recoverDocument(in: directory)
        let stored = try readProject(in: directory)
        guard let record = stored.documents.first(where: { $0.id == document.id }), record.relativePath == document.relativePath else {
            throw ReadingError.invalid("此文档不属于当前书籍，或文档引用已改变。")
        }
        let data = try readLimited(try documentURL(document, in: directory), limit: Self.documentLimit)
        guard let markdown = String(data: data, encoding: .utf8) else { throw ReadingError.invalid("Markdown 不是有效 UTF-8，未用替换字符覆盖原文。") }
        return DocumentContentSnapshot(markdown: markdown, contentHash: try BookImporter.sha256(data))
    }

    public func saveDocument(project: BookProject, document: DocumentRecord, markdown: String, expectedContentHash: String? = nil) throws -> BookProject {
        let directory = try bookDirectory(project.id, mustExist: true)
        try recoverDocument(in: directory)
        let existing = try readProject(in: directory)
        try requireCurrentChangeHistory(project, existing: existing)
        guard project.originalName == existing.originalName, project.sourceHash == existing.sourceHash else { throw ReadingError.invalid("文档保存时书籍身份发生变化。") }
        let data = Data(markdown.utf8)
        guard data.count <= Self.documentLimit else { throw ReadingError.invalid("单篇 Markdown 超过 16 MiB。") }
        try validateDocumentPath(document)
        var updated = project
        updated.aiRequestHistory = try AIRequestHistoryMerge.merge(proposed: project.aiRequestHistory, canonical: existing.aiRequestHistory)
        updated.readerAnnotations = existing.readerAnnotations
        updated.generatedOutline = existing.generatedOutline
        updated.originalBookOutline = existing.originalBookOutline
        updated.readerCollections = existing.readerCollections
        // Retain references written by another window before this editor was opened.
        // Index positions only: leave the original array intact so validation
        // still rejects duplicate proposed IDs instead of silently deduplicating.
        var documentIndices = Dictionary(updated.documents.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for saved in existing.documents {
            if let index = documentIndices[saved.id] { updated.documents[index].trashedAt = saved.trashedAt }
            else { documentIndices[saved.id] = updated.documents.count; updated.documents.append(saved) }
        }
        var record = document
        var previousMarkdownHash: String?
        if let previous = existing.documents.first(where: { $0.id == document.id }) {
            guard previous.relativePath == document.relativePath else { throw ReadingError.invalid("不能通过保存正文改变文档路径。") }
            guard previous.trashedAt == nil else { throw ReadingError.invalid("文档已在回收站，请先恢复后再编辑；原 Markdown 已保留。") }
            record.createdAt = previous.createdAt
            record.trashedAt = previous.trashedAt
            let storedBody = try readLimited(try documentURL(previous, in: directory), limit: Self.documentLimit)
            guard let expectedContentHash, expectedContentHash.count == 64,
                  expectedContentHash.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  try BookImporter.sha256(storedBody) == expectedContentHash.lowercased() else {
                throw ReadingError.invalid("磁盘 Markdown 已改变，或缺少打开时版本；未覆盖正文。请重新打开对照，或把当前草稿另存为新笔记。")
            }
            previousMarkdownHash = expectedContentHash.lowercased()
        } else {
            guard !files.fileExists(atPath: try documentURL(document, in: directory).path) else {
                throw ReadingError.invalid("同名 Markdown 已存在但未登记；已保留文件，不会用新文档覆盖恢复资料。")
            }
        }
        record.updatedAt = Date()
        if let index = documentIndices[record.id] { updated.documents[index] = record }
        else { updated.documents.append(record) }
        try ReadingKnowledgeRuntime.captureVersions(before: existing, in: &updated)
        try validate(updated)
        // Validate all pre-existing files; the one being saved is allowed not to exist yet.
        try validatePackageFiles(updated, in: directory, strictContents: false, verifySourceHash: false, pendingDocumentID: record.id, pendingDocumentBytes: data.count)
        let journalDirectory = try ensureDirectory(try child(directory, ".journal"))
        let stagedBody = try child(journalDirectory, "document.md")
        let marker = try child(journalDirectory, "transaction.json")
        guard !files.fileExists(atPath: marker.path) else { throw ReadingError.invalid("上一份文档事务尚未恢复。") }
        // The commit marker is written last. Before it exists the original files have not
        // changed; after it exists loadAll can repeat both idempotent replacements.
        try atomicWrite(data, to: stagedBody)
        let journal = DocumentJournal(bookID: updated.id, documentID: record.id,
                                      markdownHash: try BookImporter.sha256(data), previousMarkdownHash: previousMarkdownHash, project: updated)
        try atomicWrite(encode(journal), to: marker)
        try recoverDocument(in: directory)
        refreshReadableAfterCommit(id: updated.id)
        return stampForPublication(updated)
    }

    public func setDocumentTrashed(project: BookProject, documentID: String, trashed: Bool) throws -> BookProject {
        guard Self.isSafeID(documentID) else { throw ReadingError.invalid("文档 ID 不合法。") }
        let directory = try bookDirectory(project.id, mustExist: true)
        try recoverDocument(in: directory)
        var updated = try readProject(in: directory)
        guard updated.id == project.id, updated.sourceHash == project.sourceHash,
              updated.originalName == project.originalName else { throw ReadingError.invalid("回收操作中的书籍身份与磁盘记录不符。") }
        guard let index = updated.documents.firstIndex(where: { $0.id == documentID }) else { throw ReadingError.invalid("文档不属于此书籍。") }
        guard (updated.documents[index].trashedAt != nil) != trashed else { return stampForPublication(updated) }
        updated.documents[index].trashedAt = trashed ? Date() : nil
        updated.documents[index].updatedAt = Date()
        updated.audit.append(ToolAudit(name: trashed ? "document_trash" : "document_restore", summary: "\(trashed ? "移入回收站" : "恢复")文档：\(updated.documents[index].title)；Markdown 与导图关联保留。"))
        try validate(updated)
        try validatePackageFiles(updated, in: directory, strictContents: false, verifySourceHash: false)
        try atomicWrite(encode(updated), to: try child(directory, "project.json"))
        return stampForPublication(updated)
    }

    /// Manual deletion and its complete recovery record share one atomic metadata
    /// replacement. An old window cannot turn a later edit into a trash snapshot.
    public func trashManualItem(project: BookProject, kind: ManualTrashKind, id: String, viewIDs: [String] = []) throws -> BookProject {
        let directory = try bookDirectory(project.id, mustExist: true)
        try recoverDocument(in: directory)
        let canonical = try readProject(in: directory)
        try requireManualTrashRevision(project, canonical: canonical)
        let updated = try ManualTrashRuntime.trashing(kind: kind, id: id, viewIDs: viewIDs, in: canonical)
        try validate(updated)
        let metadata = try encode(updated)
        try validatePackageFiles(updated, in: directory, strictContents: false, verifySourceHash: false,
                                 encodedMetadataSize: metadata.count, reuseDocumentValidation: true)
        try atomicWrite(metadata, to: try child(directory, "project.json"))
        return stampForPublication(updated)
    }

    /// The confirmed dependency set is checked by the runtime against canonical
    /// state. Nothing is written if any record has changed or a dependency is gone.
    public func restoreManualItems(project: BookProject, itemID: String, expectedItemIDs: [String]) throws -> BookProject {
        let directory = try bookDirectory(project.id, mustExist: true)
        try recoverDocument(in: directory)
        let canonical = try readProject(in: directory)
        try requireManualTrashRevision(project, canonical: canonical)
        let updated = try ManualTrashRuntime.restoring(itemID: itemID, expectedItemIDs: expectedItemIDs, in: canonical)
        try validate(updated)
        let metadata = try encode(updated)
        try validatePackageFiles(updated, in: directory, strictContents: false, verifySourceHash: false,
                                 encodedMetadataSize: metadata.count, reuseDocumentValidation: true)
        try atomicWrite(metadata, to: try child(directory, "project.json"))
        return stampForPublication(updated)
    }

    private func requireManualTrashRevision(_ project: BookProject, canonical: BookProject) throws {
        try validate(canonical)
        guard project.id == canonical.id, project.sourceHash == canonical.sourceHash, project.originalName == canonical.originalName,
              try ControlledChangeRecords.revision(project) == ControlledChangeRecords.revision(canonical) else {
            throw ControlledChangeError.conflict("等待回收或恢复期间内容已变化；请重新载入并确认，当前资料没有被覆盖。")
        }
    }

    /// Annotation edits use the canonical disk project so a reader window cannot overwrite newer knowledge or notes.
    public func saveAnnotations(project: BookProject, annotations: [ReaderAnnotation]) throws -> BookProject {
        let directory = try bookDirectory(project.id, mustExist: true)
        try recoverDocument(in: directory)
        var updated = try readProject(in: directory)
        guard updated.sourceHash == project.sourceHash, updated.originalName == project.originalName,
              !annotations.isEmpty, annotations.count <= 512, Set(annotations.map(\.id)).count == annotations.count else { throw ReadingError.invalid("批注保存来源已变化或批次无效。") }
        var records = updated.readerAnnotations ?? []
        for var annotation in annotations {
            try ReaderAnnotationValidator.validate(annotation, in: updated)
            if let index = records.firstIndex(where: { $0.id == annotation.id }) {
                let old = records[index]
                guard old.trashedAt == nil, old.sourceHash == annotation.sourceHash, old.page == annotation.page,
                      old.text == annotation.text, old.rangeLocation == annotation.rangeLocation, old.rangeLength == annotation.rangeLength,
                      old.quads == annotation.quads, old.effectiveKind == annotation.effectiveKind else { throw ReadingError.invalid("批注来源位置不能改写，已删除批注须先恢复。") }
                annotation.createdAt = old.createdAt; annotation.trashedAt = nil
                annotation.updatedAt = Date(); records[index] = annotation
            } else {
                guard annotation.trashedAt == nil else { throw ReadingError.invalid("新增批注不能直接置入回收站。") }
                annotation.updatedAt = Date(); records.append(annotation)
            }
        }
        updated.readerAnnotations = records
        try validate(updated)
        try atomicWrite(encode(updated), to: try child(directory, "project.json"))
        return stampForPublication(updated)
    }

    public func setAnnotationTrashed(project: BookProject, annotationID: String, trashed: Bool) throws -> BookProject {
        let directory = try bookDirectory(project.id, mustExist: true)
        try recoverDocument(in: directory)
        var updated = try readProject(in: directory)
        guard updated.sourceHash == project.sourceHash, updated.originalName == project.originalName,
              let index = updated.readerAnnotations?.firstIndex(where: { $0.id == annotationID }) else { throw ReadingError.invalid("批注不存在或来源已变化。") }
        if (updated.readerAnnotations?[index].trashedAt != nil) != trashed {
            updated.readerAnnotations?[index].trashedAt = trashed ? Date() : nil
            updated.readerAnnotations?[index].updatedAt = Date()
        }
        try validate(updated)
        try atomicWrite(encode(updated), to: try child(directory, "project.json"))
        return stampForPublication(updated)
    }

    public func archiveBook(project: BookProject) throws {
        let source = try bookDirectory(project.id, mustExist: true)
        try recoverDocument(in: source)
        let canonical = try readProject(in: source)
        guard canonical.id == project.id, canonical.sourceHash == project.sourceHash,
              canonical.originalName == project.originalName else { throw ReadingError.invalid("回收操作中的书籍身份与磁盘记录不符。") }
        try validate(canonical)
        try validatePackageFiles(canonical, in: source, strictContents: false, verifySourceHash: true)
        try validateArchiveTree(source)
        let destination = try archivedBookDirectory(project.id, mustExist: false)
        try requireVacant(destination)
        do { try files.moveItem(at: source, to: destination) }
        catch { throw ReadingError.invalid("书籍未能完整移入回收站。原书及可能的目标文件均已保留，请检查 books/\(project.id) 与 trash/\(project.id)：\(error.localizedDescription)") }
        _ = try? refreshReadableLibraryIndex()
    }

    public func archivedBooks() throws -> [BookProject] {
        try trashReport().projects
    }

    public func trashReport() throws -> LibraryLoadReport {
        let trash = try trashDirectory()
        let children = try files.contentsOfDirectory(at: trash, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var result: [BookProject] = []
        var issues: [LibraryLoadIssue] = []
        for directory in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if directory.lastPathComponent == ".DS_Store" { continue }
            do {
                let checked = try archivedBookDirectory(directory.lastPathComponent, mustExist: true)
                try recoverDocument(in: checked)
                let project = try readProject(in: checked)
                guard project.id == directory.lastPathComponent else { throw ReadingError.invalid("回收书籍 ID 与目录不一致。") }
                try validate(project)
                try validatePackageFiles(project, in: checked, strictContents: false, verifySourceHash: true)
                try validateArchiveTree(checked)
                result.append(project)
            } catch { issues.append(LibraryLoadIssue(folder: directory.path, message: "此回收条目无法载入，原文件已保留：\(error.localizedDescription)")) }
        }
        return LibraryLoadReport(projects: result.sorted { $0.importedAt > $1.importedAt }, issues: issues)
    }

    public func restoreBook(id: String) throws -> BookProject {
        let source = try archivedBookDirectory(id, mustExist: true)
        try recoverDocument(in: source)
        let project = try readProject(in: source)
        guard project.id == id else { throw ReadingError.invalid("回收书籍 ID 与目录不一致。") }
        try validate(project)
        try validatePackageFiles(project, in: source, strictContents: false, verifySourceHash: true)
        try validateArchiveTree(source)
        let destination = try bookDirectory(id, mustExist: false)
        try requireVacant(destination)
        try forgetRemovedBook(id: id)
        do { try files.moveItem(at: source, to: destination) }
        catch { throw ReadingError.invalid("书籍恢复未完成。回收目录及可能的目标文件均已保留，请检查 trash/\(id) 与 books/\(id)：\(error.localizedDescription)") }
        _ = try? refreshReadableViews(id: id)
        _ = try? refreshReadableLibraryIndex()
        return stampForPublication(project)
    }

    public func sourceURL(for project: BookProject) -> URL {
        // This nonthrowing lookup never produces an escaping path for a forged model.
        guard let directory = try? bookDirectory(project.id, mustExist: false),
              Self.isSafeFilename(project.originalName),
              let source = try? child(directory, "source"),
              let url = try? child(source, project.originalName) else {
            return rootURL.appendingPathComponent("__invalid_source__")
        }
        return url
    }

    public func checkOCRPage(project: BookProject, page: Int) throws {
        if let reason = OCRIntegration.unavailableReason(project: project, page: page) { throw ReadingError.invalid(reason) }
        let ids = project.units.filter { $0.page == page }.map(\.id)
        // Typed Markdown links may exist without structured evidence metadata.
        for document in project.documents {
            let text = try readDocument(bookID: project.id, document: document)
            if ids.contains(where: { text.contains("[unit:\($0)]") || text.contains("/unit/\($0)") }) { throw ReadingError.invalid("Markdown 正文含有此页引用，已保留原引用；请在新导入的项目中识别。") }
        }
    }

    public func saveOCRPage(project: BookProject, result: OCRPageResult) throws -> BookProject {
        let directory = try bookDirectory(project.id, mustExist: true)
        try recoverDocument(in: directory)
        let existing = try readProject(in: directory)
        guard existing.sourceHash == project.sourceHash, existing.units == project.units,
              zip(existing.units, project.units).allSatisfy({ $0.text.utf8.elementsEqual($1.text.utf8) }) else { throw ReadingError.invalid("识别期间原文层已变化，请重新载入后继续。") }
        try checkOCRPage(project: existing, page: result.page)
        let updated = try OCRIntegration.applying(result, to: existing)
        try validate(updated)
        try validatePackageFiles(updated, in: directory, strictContents: false, verifySourceHash: true)
        try atomicWrite(encode(updated), to: try child(directory, "project.json"))
        return stampForPublication(updated)
    }

    public func exportProject(_ project: BookProject, to url: URL) throws {
        try validateExportURL(url)
        guard !files.fileExists(atPath: url.path) else { throw ReadingError.invalid("导出位置已经存在，请选择新的 .readingbook 文件夹名。") }
        let directory = try bookDirectory(project.id, mustExist: true)
        try recoverDocument(in: directory)
        let canonical = try readProject(in: directory)
        guard canonical.id == project.id, canonical.sourceHash == project.sourceHash, canonical.originalName == project.originalName else { throw ReadingError.invalid("导出时项目身份与磁盘记录不符。") }
        try validate(canonical)
        try validatePackageFiles(canonical, in: directory, strictContents: false, verifySourceHash: true)
        let staging = try temporaryDirectory(near: url.deletingLastPathComponent(), prefix: ".readingbook-export-")
        defer { removeOwnTemporary(staging) }
        try writePackage(canonical, source: sourceURL(for: canonical), documentsFrom: directory, to: staging)
        try validatePackageFiles(canonical, in: staging, strictContents: true, verifySourceHash: true)
        try files.moveItem(at: staging, to: url)
    }

    public func importProject(from url: URL) throws -> BookProject {
        try validateExportURL(url)
        try requireDirectory(url)
        let original = try readProject(in: url)
        try validate(original)
        try validatePackageFiles(original, in: url, strictContents: true, verifySourceHash: true)
        var project = original
        project.id = UUID().uuidString
        project.importedAt = Date()
        let destination = try bookDirectory(project.id, mustExist: false)
        guard !files.fileExists(atPath: destination.path) else { throw ReadingError.invalid("新项目 ID 冲突，请重试导入。") }
        let source = try child(try child(url, "source"), original.originalName)
        let staging = try temporaryDirectory(near: try booksDirectory(), prefix: ".importing-")
        defer { removeOwnTemporary(staging) }
        try writePackage(project, source: source, documentsFrom: url, to: staging)
        // The imported copy has a new book identity. Keep its Markdown source
        // links inside that copy; the external package itself is untouched.
        for document in project.documents {
            let destination = try documentURL(document, in: staging)
            let data = try readLimited(destination, limit: Self.documentLimit)
            guard let body = String(data: data, encoding: .utf8) else { throw ReadingError.invalid("导入的 Markdown 不是 UTF-8。") }
            let rewritten = body.replacingOccurrences(of: "readingbook://book/\(original.id)/", with: "readingbook://book/\(project.id)/")
            if rewritten != body { try atomicWrite(Data(rewritten.utf8), to: destination) }
        }
        // Recheck copied content, not just the external package before copying it.
        try validatePackageFiles(project, in: staging, strictContents: true, verifySourceHash: true)
        try files.moveItem(at: staging, to: destination)
        _ = try? refreshReadableViews(id: project.id)
        _ = try? refreshReadableLibraryIndex()
        return stampForPublication(project)
    }

    // MARK: Recoverable document commit

    func recoverDocument(in directory: URL) throws {
        try recoverControlledChanges(in: directory)
        let journalDirectory = try child(directory, ".journal")
        guard files.fileExists(atPath: journalDirectory.path) else { return }
        try requireDirectory(journalDirectory)
        let marker = try child(journalDirectory, "transaction.json")
        guard files.fileExists(atPath: marker.path) else { return } // Uncommitted preparation; no visible data was touched.
        let journal: DocumentJournal = try decode(readLimited(marker, limit: Self.metadataLimit))
        guard journal.version == 1, journal.bookID == directory.lastPathComponent,
              journal.project.id == journal.bookID,
              let document = journal.project.documents.first(where: { $0.id == journal.documentID }) else {
            throw ReadingError.invalid("文档恢复日志的版本或引用不正确，已保留现场。")
        }
        try validate(journal.project)
        let staged = try child(journalDirectory, "document.md")
        let body = try readLimited(staged, limit: Self.documentLimit)
        guard String(data: body, encoding: .utf8) != nil, try BookImporter.sha256(body) == journal.markdownHash else {
            throw ReadingError.invalid("文档恢复日志的 Markdown 校验失败，已保留现场。")
        }
        let existing = try readProject(in: directory)
        guard existing.id == journal.bookID, existing.sourceHash == journal.project.sourceHash,
              existing.originalName == journal.project.originalName,
              Set(existing.documents.map(\.id)).isSubset(of: Set(journal.project.documents.map(\.id))) else {
            throw ReadingError.invalid("恢复日志与现有书籍冲突，未覆盖现有资料。")
        }
        try requireCurrentChangeHistory(journal.project, existing: existing)
        try validatePackageFiles(journal.project, in: directory, strictContents: false, verifySourceHash: false, pendingDocumentID: document.id, pendingDocumentBytes: body.count)
        let destination = try documentURL(document, in: directory)
        if files.fileExists(atPath: destination.path) {
            let currentHash = try BookImporter.sha256(readLimited(destination, limit: Self.documentLimit))
            guard currentHash == journal.markdownHash || currentHash == journal.previousMarkdownHash else {
                throw ReadingError.invalid("恢复期间 Markdown 已被其他编辑器修改；磁盘正文和待恢复事务均保留，未自动覆盖。")
            }
        } else if journal.previousMarkdownHash != nil {
            throw ReadingError.invalid("待恢复的原 Markdown 已移除，事务已保留；不会自动重建覆盖用户文件操作。")
        }
        try atomicWrite(body, to: destination)
        try atomicWrite(encode(journal.project), to: try child(directory, "project.json"))
        // Remove only our two exact journal files, after both durable replacements succeed.
        try files.removeItem(at: marker)
        try files.removeItem(at: staged)
    }

    // MARK: Package validation

    func validate(_ project: BookProject) throws {
        try ReaderCollectionRuntime.validate(project.readerCollections)
        let requests = project.aiRequestHistory ?? []
        guard requests.count <= 1000, Set(requests.map(\.id)).count == requests.count,
              requests.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.title.count <= 160 && $0.number > 0 &&
                  ["returned", "paused", "failed"].contains($0.status) && $0.reasoningCharacters >= 0 && $0.answerCharacters >= 0 &&
                  $0.startedAt.timeIntervalSince1970.isFinite && $0.finishedAt.timeIntervalSince1970.isFinite && $0.finishedAt >= $0.startedAt }) else {
            throw ReadingError.invalid("请求历史记录无效，原数据保留。")
        }
        try ReaderAnnotationValidator.validateAll(in: project)
        guard project.schemaVersion == 1 else { throw ReadingError.invalid("不支持此项目 schemaVersion：\(project.schemaVersion)。") }
        guard UUID(uuidString: project.id) != nil, project.id.count == 36,
              Self.isSafeFilename(project.originalName), !project.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["txt", "md", "markdown", "pdf", "epub"].contains(URL(fileURLWithPath: project.originalName).pathExtension.lowercased()),
              project.sourceHash.count == 64, project.sourceHash.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              !project.units.isEmpty, project.units.count <= BookImporter.maximumUnits else { throw ReadingError.invalid("书籍身份、原文件名、摘要或单元数量无效。") }
        let unitIDs = try uniqueIDs(project.units.map(\.id), label: "原文单元")
        let sourceUnits = Dictionary(uniqueKeysWithValues: project.units.map { ($0.id, $0) })
        let typeIDs = try uniqueIDs(project.types.map(\.id), label: "卡片类型")
        let entityIDs = try uniqueIDs(project.entities.map(\.id), label: "要素")
        let eventIDs = try uniqueIDs(project.events.map(\.id), label: "事件")
        _ = try uniqueIDs(project.relations.map(\.id), label: "关系")
        _ = try uniqueIDs(project.views.map(\.id), label: "视图")
        let methodIDs = try uniqueIDs(project.methods.map(\.id), label: "读书法")
        let insightIDs = try uniqueIDs(project.insights.map(\.id), label: "阅读分析")
        _ = try uniqueIDs(project.syntheses.map(\.id), label: "综合记录")
        let documentIDs = try uniqueIDs(project.documents.map(\.id), label: "文档")
        let nodeIDs = try uniqueIDs(project.nodes.map(\.id), label: "导图节点")
        _ = try uniqueIDs(project.edges.map(\.id), label: "导图连线")
        _ = try uniqueIDs(project.chats.map(\.id), label: "对话消息")
        _ = try uniqueIDs(project.audit.map(\.id), label: "操作记录")
        let pluginIDs = try uniqueIDs(project.plugins.map(\.id), label: "插件")
        let knowledgeIDs = entityIDs.union(eventIDs).union(documentIDs)
        guard entityIDs.isDisjoint(with: eventIDs), entityIDs.isDisjoint(with: documentIDs), eventIDs.isDisjoint(with: documentIDs) else { throw ReadingError.invalid("实体、事件与文档必须使用互不冲突的稳定 ID。") }
        let targets = knowledgeIDs.union(documentIDs).union(unitIDs).union(insightIDs)
        guard project.documents.count <= 10_000, project.entities.count <= 100_000,
              project.events.count <= 100_000, project.nodes.count <= 100_000,
              project.relations.count <= 200_000, project.edges.count <= 200_000,
              project.types.count <= 1_000, project.methods.count <= 1_000, project.views.count <= 1_000,
              project.plugins.count <= 1_000 else { throw ReadingError.invalid("项目记录数量超过首版安全上限。") }
        for (index, unit) in project.units.enumerated() {
            guard unit.order == index, unit.text.count <= 5_000, unit.lineStart > 0, unit.lineEnd >= unit.lineStart,
                  unit.page.map({ $0 > 0 && $0 <= 20_000 }) ?? true else { throw ReadingError.invalid("原文单元顺序、页行定位或长度无效：\(unit.id)") }
        }
        // Older projects may have no ledger. When present, its source hashes,
        // anchors, historical method versions and batch must survive every load/save/import.
        try MathVerificationTools.validateStoredRecords(in: project, cache: &mathValidationCache)
        try ReadingLedger.validateStoredRecords(in: project, mathCache: &mathValidationCache)
        try BookSchemeRuntime.validateStoredState(in: project)
        let sourceManifest: SourceManifest
        if let cached = sourceManifests[project.id], cached.sourceHash == project.sourceHash, cached.units == project.units,
           zip(cached.units, project.units).allSatisfy({ $0.text.utf8.elementsEqual($1.text.utf8) }) {
            sourceManifest = cached
        } else {
            sourceManifest = SourceManifest(sourceHash: project.sourceHash, units: project.units,
                hashes: try Dictionary(uniqueKeysWithValues: project.units.map { ($0.id, try BookImporter.sha256(Data($0.text.utf8))) }))
            sourceManifests[project.id] = sourceManifest
            if sourceManifests.count > 4, let key = sourceManifests.keys.first(where: { $0 != project.id }) { sourceManifests.removeValue(forKey: key) }
        }
        try SmartReadingRuntime.validateStoredState(in: project, prevalidatedUnitHashes: sourceManifest.hashes)
        guard project.plan?.recommendedParallelism.map({ (1...5).contains($0) }) ?? true else { throw ReadingError.invalid("AI 并行建议应在 1–5 之间。") }
        if let experience = project.readingExperience {
            try ReadingExperienceRuntime.validateStoredState(experience, in: project)
        }
        try TemporalKnowledgeRuntime.validateStoredState(in: project)
        try ReadingKnowledgeRuntime.validateStoredState(in: project)
        try BookOutlineRuntime.validateStored(project.generatedOutline)
        try BookChapterRuntime.validateStored(project.originalBookOutline)
        try ControlledGraphRuntime.validate(in: project)
        try ControlledChangeRecords.validate(in: project)
        try ManualTrashRuntime.validateStoredState(in: project)
        let recognizedPages = project.ocrPages ?? []
        guard recognizedPages.count <= 20_000, Set(recognizedPages.map(\.page)).count == recognizedPages.count else { throw ReadingError.invalid("OCR 页记录重复或超过上限。") }
        for page in recognizedPages {
            guard (1...20_000).contains(page.page), !page.model.isEmpty, page.model.count <= 240,
                  page.issues.count <= 200, page.issues.allSatisfy({ $0.count <= 4000 }),
                  !page.unitIDs.isEmpty, Set(page.unitIDs).isSubset(of: unitIDs),
                  page.unitIDs.allSatisfy({ sourceUnits[$0]?.page == page.page }) else { throw ReadingError.invalid("OCR 来源记录与页面单元不一致。") }
        }
        guard Set(project.coverage.keys).isSubset(of: unitIDs),
              project.coverage.values.allSatisfy({ $0.attempts >= 0 && $0.attempts <= 1_000_000 }),
              project.lastUnitID.map({ unitIDs.contains($0) }) ?? true else { throw ReadingError.invalid("阅读覆盖记录引用了不存在的单元。") }
        guard Set(project.bookmarks).count == project.bookmarks.count,
              Set(project.bookmarks).isSubset(of: unitIDs),
              Set(project.disabledPluginIDs).count == project.disabledPluginIDs.count,
              Set(project.disabledPluginIDs).isSubset(of: pluginIDs) else { throw ReadingError.invalid("书签或禁用插件记录含重复或悬空引用。") }
        for type in project.types {
            _ = try uniqueIDs(type.fields.map(\.key), label: "类型字段")
            guard !type.name.isEmpty, type.fields.count <= 100 else { throw ReadingError.invalid("卡片类型名称或字段数量无效。") }
        }
        for entity in project.entities {
            guard typeIDs.contains(entity.typeID), !entity.name.isEmpty, entity.properties.count <= 256,
                  entity.latitude.map({ $0.isFinite && (-90...90).contains($0) }) ?? true,
                  entity.longitude.map({ $0.isFinite && (-180...180).contains($0) }) ?? true else { throw ReadingError.invalid("要素类型或坐标无效：\(entity.id)") }
            try validateEvidence(entity.evidence, units: sourceUnits)
        }
        for event in project.events {
            guard Set(event.placeIDs + event.participantIDs).isSubset(of: entityIDs) else { throw ReadingError.invalid("事件引用了不存在的地点或参与者。") }
            guard event.startYear.map({ (-1_000_000_000_000...1_000_000_000_000).contains($0) }) ?? true,
                  event.endYear.map({ (-1_000_000_000_000...1_000_000_000_000).contains($0) }) ?? true else { throw ReadingError.invalid("事件年份超出安全范围。") }
            if let start = event.startYear, let end = event.endYear, end < start { throw ReadingError.invalid("事件的结束年份早于开始年份。") }
            try validateEvidence(event.evidence, units: sourceUnits)
        }
        for relation in project.relations {
            guard knowledgeIDs.contains(relation.fromID), knowledgeIDs.contains(relation.toID) else { throw ReadingError.invalid("关系引用了不存在的要素、事件或文档。") }
            try validateEvidence(relation.evidence, units: sourceUnits)
        }
        for view in project.views {
            guard Set(view.typeIDs).isSubset(of: typeIDs) else { throw ReadingError.invalid("视图引用了不存在的类型：\(view.id)") }
            try validateViewMetadata(view)
        }
        if let plan = project.plan, !Set(plan.methodIDs).isSubset(of: methodIDs) { throw ReadingError.invalid("阅读计划引用了不存在的读书法。") }
        for insight in project.insights where !Set(insight.unitIDs).isSubset(of: unitIDs) { throw ReadingError.invalid("阅读分析引用了不存在的原文单元。") }
        for synthesis in project.syntheses {
            guard synthesis.level > 0, !synthesis.markdown.isEmpty, !synthesis.unitIDs.isEmpty,
                  Set(synthesis.unitIDs).isSubset(of: unitIDs) else { throw ReadingError.invalid("综合记录的层级、正文或原文引用无效。") }
        }
        for document in project.documents {
            try validateDocumentPath(document)
            guard Set(document.linkedIDs).isSubset(of: targets) else { throw ReadingError.invalid("文档关联了不存在的记录：\(document.id)") }
            try validateEvidence(document.evidence, units: sourceUnits)
        }
        for node in project.nodes {
            guard targets.contains(node.targetID) || (node.isStandalone == true && node.targetID == node.id), node.x.isFinite, node.y.isFinite,
                  abs(node.x) <= 10_000_000, abs(node.y) <= 10_000_000 else { throw ReadingError.invalid("导图节点目标或位置无效。") }
        }
        for edge in project.edges where !nodeIDs.contains(edge.fromID) || !nodeIDs.contains(edge.toID) { throw ReadingError.invalid("导图连线引用了不存在的画布节点。") }
        for message in project.chats { try validateEvidence(message.evidence, units: sourceUnits) }
        for plugin in project.plugins {
            guard plugin.version > 0 else { throw ReadingError.invalid("插件版本必须为正整数。") }
            _ = try uniqueIDs(plugin.types.map(\.id), label: "插件类型")
            _ = try uniqueIDs(plugin.methods.map(\.id), label: "插件读书法")
            _ = try uniqueIDs(plugin.views.map(\.id), label: "插件视图")
            guard plugin.views.count <= 1_000 else { throw ReadingError.invalid("插件视图数量超过安全上限。") }
            for view in plugin.views { try validateViewMetadata(view) }
        }
        guard Set(project.appliedOperationIDs).count == project.appliedOperationIDs.count,
              project.appliedOperationIDs.count <= 200_000,
              project.appliedOperationIDs.allSatisfy(Self.isSafeID) else { throw ReadingError.invalid("操作去重 ID 不正确。") }
    }

    /// A newer plugin's renderer ID is recoverable metadata, not permission to
    /// execute code. Validate its shape and bounds without requiring installation.
    private func validateViewMetadata(_ view: ViewDefinition) throws {
        if let rendererID = view.rendererID, !Self.isSafeID(rendererID) {
            throw ReadingError.invalid("视图渲染器标识无效：\(view.id)")
        }
        if let scope = view.scope, !["current", "book"].contains(scope) {
            throw ReadingError.invalid("视图上下文范围须为 current 或 book：\(view.id)")
        }
        if let configuration = view.configuration {
            guard configuration.count <= 16, configuration.allSatisfy({ key, value in
                !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && key.utf8.count <= 128 &&
                !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
                value.count <= 4_000 && value.utf8.count <= 16_000 && !value.contains("\0")
            }) else { throw ReadingError.invalid("视图声明配置的键、值或数量超出安全范围：\(view.id)") }
        }
    }

    private func validateEvidence(_ evidence: [Evidence], units: [String: SourceUnit]) throws {
        guard evidence.count <= 1_000, evidence.allSatisfy({ reference in
            guard let unit = units[reference.unitID], !reference.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  reference.quote.count <= 100_000 else { return false }
            return unit.text.contains(reference.quote)
        }) else { throw ReadingError.invalid("证据引用不存在的原文单元、摘录无法匹配，或数量/长度过大。") }
    }

    private func uniqueIDs(_ ids: [String], label: String) throws -> Set<String> {
        guard ids.allSatisfy(Self.isSafeID), Set(ids).count == ids.count else { throw ReadingError.invalid("\(label)含无效或重复 ID。") }
        return Set(ids)
    }

    private static func isSafeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0))
        } && value != "." && value != ".."
    }

    private static func isSafeFilename(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 240 && value != "." && value != ".." && !value.hasPrefix(".") &&
        !value.contains("/") && !value.contains("\\") && !value.contains(":") &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func validateDocumentPath(_ document: DocumentRecord) throws {
        guard Self.isSafeID(document.id), document.relativePath == "docs/\(document.id).md", !document.title.isEmpty else {
            throw ReadingError.invalid("Markdown 必须使用 docs/<文档ID>.md，且必须有标题。")
        }
    }

    func validatePackageFiles(_ project: BookProject, in directory: URL, strictContents: Bool,
                                      verifySourceHash: Bool, pendingDocumentID: String? = nil, pendingDocumentBytes: Int = 0,
                                      encodedMetadataSize: Int? = nil, reuseDocumentValidation: Bool = false, pendingDocumentSizes: [String: Int] = [:]) throws {
        try requireDirectory(directory)
        let source = try child(try child(directory, "source"), project.originalName)
        try requireDirectory(try child(directory, "source"))
        try requireDirectory(try child(directory, "docs"))
        var total = try regularFileSize(source, limit: BookImporter.maximumSourceBytes)
        let storedMetadata = try child(directory, "project.json")
        var storedSize = 0
        if files.fileExists(atPath: storedMetadata.path) { storedSize = try regularFileSize(storedMetadata, limit: Self.metadataLimit) }
        let metadataSize = try encodedMetadataSize ?? encode(project).count
        guard pendingDocumentSizes.values.allSatisfy({ (0...Self.documentLimit).contains($0) }) else { throw ReadingError.invalid("待写文档大小无效。") }
        total += max(storedSize, metadataSize) + pendingDocumentBytes + pendingDocumentSizes.values.reduce(0, +)
        guard total <= Self.packageLimit else { throw ReadingError.invalid("书籍与文档总大小超过 512 MiB。") }
        if verifySourceHash { try verifyOriginal(at: source, expectedHash: project.sourceHash) }
        for document in project.documents where document.id != pendingDocumentID && pendingDocumentSizes[document.id] == nil {
            let url = try documentURL(document, in: directory)
            total += try validateDocumentFile(url, reuseValidation: reuseDocumentValidation)
            guard total <= Self.packageLimit else { throw ReadingError.invalid("书籍与文档总大小超过 512 MiB。") }
        }
        if strictContents {
            let rootNames = try files.contentsOfDirectory(atPath: directory.path).filter { $0 != ".DS_Store" }
            guard Set(rootNames) == Set(["project.json", "source", "docs"]) else { throw ReadingError.invalid(".readingbook 包含未声明的文件或内部恢复目录。") }
            let sourceNames = try files.contentsOfDirectory(atPath: source.deletingLastPathComponent().path).filter { $0 != ".DS_Store" }
            guard sourceNames == [project.originalName] else { throw ReadingError.invalid(".readingbook 原书目录与元数据不一致。") }
            let docNames = try files.contentsOfDirectory(atPath: try child(directory, "docs").path).filter { $0 != ".DS_Store" }
            guard Set(docNames) == Set(project.documents.map { "\($0.id).md" }) else { throw ReadingError.invalid(".readingbook 文档目录有缺失或未声明文件。") }
        }
    }

    /// Every call checks the file type, link boundary and size. Only unchanged
    /// file identity and timestamps reuse the expensive UTF-8 content validation.
    /// Load, import and export deliberately perform a fresh complete validation.
    private func validateDocumentFile(_ url: URL, reuseValidation: Bool) throws -> Int {
        let size = try regularFileSize(url, limit: Self.documentLimit)
        let attributes = try files.attributesOfItem(atPath: url.path)
        let stamp: DocumentValidationStamp?
        if let modified = attributes[.modificationDate] as? Date,
           let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
           let deviceNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value {
            stamp = DocumentValidationStamp(size: size, modified: modified, created: attributes[.creationDate] as? Date,
                                            fileNumber: fileNumber, deviceNumber: deviceNumber)
        } else { stamp = nil } // An unknown identity never earns a cached admission.
        if reuseValidation, let stamp, documentValidationCache[url.path] == stamp { return size }
        let data = try readLimited(url, limit: Self.documentLimit)
        guard String(data: data, encoding: .utf8) != nil else { throw ReadingError.invalid("Markdown 文件不是有效 UTF-8：\(url.lastPathComponent)") }
        // Read after validation as well, so a concurrent atomic replacement cannot
        // inherit the old inode's admission stamp.
        let after = try files.attributesOfItem(atPath: url.path)
        if let stamp, (after[.size] as? NSNumber)?.intValue == stamp.size,
           after[.modificationDate] as? Date == stamp.modified,
           after[.creationDate] as? Date == stamp.created,
           (after[.systemFileNumber] as? NSNumber)?.uint64Value == stamp.fileNumber,
           (after[.systemNumber] as? NSNumber)?.uint64Value == stamp.deviceNumber {
            if documentValidationCache.count >= 20_000 { documentValidationCache.removeAll(keepingCapacity: true) }
            documentValidationCache[url.path] = stamp
        } else { documentValidationCache.removeValue(forKey: url.path) }
        return data.count
    }

    // MARK: Restricted filesystem helpers

    func booksDirectory() throws -> URL {
        guard rootURL.isFileURL else { throw ReadingError.invalid("书库必须使用本地文件夹。") }
        _ = try ensureDirectory(rootURL)
        return try ensureDirectory(try child(rootURL, "books"))
    }

    func trashDirectory() throws -> URL {
        guard rootURL.isFileURL else { throw ReadingError.invalid("书库必须使用本地文件夹。") }
        _ = try ensureDirectory(rootURL)
        return try ensureDirectory(try child(rootURL, "trash"))
    }

    func archivedBookDirectory(_ id: String, mustExist: Bool) throws -> URL {
        guard id.count == 36, UUID(uuidString: id) != nil else { throw ReadingError.invalid("回收书籍 ID 必须为 UUID。") }
        let url = try child(try trashDirectory(), id)
        if mustExist { try requireDirectory(url) }
        return url
    }

    func requireVacant(_ url: URL) throws {
        let symbolic = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        guard !files.fileExists(atPath: url.path), !symbolic else { throw ReadingError.invalid("目标已存在；不会覆盖已有书籍或回收数据。") }
    }

    /// Verify the complete moved tree, including undeclared recovery files, without following links.
    func validateArchiveTree(_ directory: URL) throws {
        try requireDirectory(directory)
        var pending = [directory], count = 0, total = 0, readableTotal = 0
        while let parent = pending.popLast() {
            for entry in try files.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
                count += 1
                guard count <= 100_000 else { throw ReadingError.invalid("书籍目录条目过多，已保留原目录。") }
                let checked = try child(parent, entry.lastPathComponent)
                let values = try checked.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw ReadingError.invalid("回收目录不允许符号链接。") }
                if values.isDirectory == true { pending.append(checked) }
                else {
                    guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else { throw ReadingError.invalid("书籍目录含特殊文件。") }
                    let relative = String(checked.path.dropFirst(directory.path.count + 1))
                    let readable = relative.hasPrefix("AI分析/") || relative == ".readingbook-readable.json" || (relative.hasPrefix("阅读导航") && relative.hasSuffix(".md") && !relative.contains("/"))
                    if readable {
                        let limit = 32 * 1_024 * 1_024
                        guard size <= 16 * 1_024 * 1_024, readableTotal <= limit - size else { throw ReadingError.invalid("可读导览总大小超过 32 MiB，原文件保留。") }
                        readableTotal += size
                    } else {
                        guard size <= Self.packageLimit, total <= Self.packageLimit - size else { throw ReadingError.invalid("书籍目录总大小超过 512 MiB。") }
                        total += size
                    }
                }
            }
        }
    }

    func bookDirectory(_ id: String, mustExist: Bool) throws -> URL {
        guard id.count == 36, UUID(uuidString: id) != nil else { throw ReadingError.invalid("书籍 ID 必须为 UUID。") }
        let url = try child(try booksDirectory(), id)
        if mustExist { try requireDirectory(url) }
        return url
    }

    func child(_ parent: URL, _ name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ReadingError.invalid("拒绝越界文件路径。") }
        let url = parent.appendingPathComponent(name).standardizedFileURL
        let base = parent.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.resolvingSymlinksInPath().path.hasPrefix(base + "/") else { throw ReadingError.invalid("文件路径越过了项目目录。") }
        if files.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ReadingError.invalid("项目内不允许符号链接：\(name)") }
        }
        return url
    }

    func ensureDirectory(_ url: URL) throws -> URL {
        if files.fileExists(atPath: url.path) { try requireDirectory(url) }
        else { try files.createDirectory(at: url, withIntermediateDirectories: true); try requireDirectory(url) }
        return url
    }

    func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ReadingError.invalid("预期为普通文件夹且不能是符号链接：\(url.lastPathComponent)") }
    }

    private func documentURL(_ document: DocumentRecord, in directory: URL) throws -> URL {
        try validateDocumentPath(document)
        return try child(try child(directory, "docs"), "\(document.id).md")
    }

    func regularFileSize(_ url: URL, limit: Int) throws -> Int {
        let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard value.isRegularFile == true, value.isSymbolicLink != true, let size = value.fileSize, size >= 0, size <= limit else {
            throw ReadingError.invalid("文件缺失、不是普通文件，或超过大小上限：\(url.lastPathComponent)")
        }
        return size
    }

    func readLimited(_ url: URL, limit: Int) throws -> Data {
        let size = try regularFileSize(url, limit: limit)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == size, data.count <= limit else { throw ReadingError.invalid("读取时文件发生变化：\(url.lastPathComponent)") }
        return data
    }

    private func verifyOriginal(at url: URL, expectedHash: String) throws {
        let data = try readLimited(url, limit: BookImporter.maximumSourceBytes)
        guard !data.isEmpty, try BookImporter.sha256(data) == expectedHash.lowercased() else { throw ReadingError.invalid("原书 SHA-256 与项目记录不符，请保留文件并重新导入。") }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.metadataLimit else { throw ReadingError.invalid("项目元数据超过 64 MiB，请分卷保存。") }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T { try JSONDecoder().decode(T.self, from: data) }

    func readProject(in directory: URL) throws -> BookProject {
        let project: BookProject = try decode(readLimited(try child(directory, "project.json"), limit: Self.metadataLimit))
        return stampForPublication(project)
    }

    func stampForPublication(_ project: BookProject) -> BookProject {
        publicationOrdinal &+= 1
        var result = project
        result.publicationStamp = LibraryPublicationStamp(owner: publicationOwner, ordinal: publicationOrdinal)
        return result
    }

    func atomicWrite(_ data: Data, to url: URL) throws {
        // Foundation writes a sibling temporary file and atomically replaces the destination.
        _ = try child(url.deletingLastPathComponent(), url.lastPathComponent)
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    func temporaryDirectory(near parent: URL, prefix: String) throws -> URL {
        try requireDirectory(parent)
        let url = try child(parent, prefix + UUID().uuidString)
        guard !files.fileExists(atPath: url.path) else { throw ReadingError.invalid("临时目录冲突，请重试。") }
        try files.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func removeOwnTemporary(_ url: URL) {
        // Callers pass only the fresh UUID directory returned by temporaryDirectory.
        if files.fileExists(atPath: url.path) { try? files.removeItem(at: url) }
    }

    private func writePackage(_ project: BookProject, source: URL, documentsFrom: URL?, to directory: URL) throws {
        let sourceDirectory = try ensureDirectory(try child(directory, "source"))
        _ = try ensureDirectory(try child(directory, "docs"))
        let destinationSource = try child(sourceDirectory, project.originalName)
        _ = try regularFileSize(source, limit: BookImporter.maximumSourceBytes)
        try files.copyItem(at: source, to: destinationSource)
        if let original = documentsFrom {
            for document in project.documents {
                let data = try readLimited(try documentURL(document, in: original), limit: Self.documentLimit)
                try atomicWrite(data, to: try documentURL(document, in: directory))
            }
        }
        try atomicWrite(encode(project), to: try child(directory, "project.json"))
    }

    private func validateExportURL(_ url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "readingbook", Self.isSafeFilename(url.lastPathComponent) else {
            throw ReadingError.invalid("请选择以 .readingbook 结尾的本地文件夹包。")
        }
    }
}

// The actor owns authorization, prepared bytes and confirmation tokens. None of
// these entry points accepts paths, model-supplied operation IDs or body mirrors.
extension LibraryRepository {
    public func issueChangeGrant(bookID: String, permissions: Set<ControlledChangeGroup>, allowedUnitIDs: Set<String>, editableDocumentIDs: Set<String> = [], requiresReceipts: Bool = true, reason: String) throws -> ControlledWriteGrant {
        let directory = try bookDirectory(bookID, mustExist: true)
        try recoverDocument(in: directory)
        let project = try readProject(in: directory)
        try validate(project)
        guard project.id == bookID, !permissions.isEmpty,
              allowedUnitIDs.isSubset(of: Set(project.units.map(\.id))),
              editableDocumentIDs.isSubset(of: Set(project.activeDocuments.map(\.id))) else { throw ControlledChangeError.denied("整理授权的书籍、原文范围或可编辑文档无效。") }
        try ControlledChangeCoding.text(reason, maximum: 4000)
        if requiresReceipts, !allowedUnitIDs.isEmpty { try ReadingLedger.requireComplete(unitIDs: allowedUnitIDs, in: project) }
        let revision = try ControlledChangeRecords.revision(project)
        let grant = ControlledWriteGrant(id: UUID().uuidString, bookID: project.id, sourceHash: project.sourceHash, baseRevision: revision, grantRevision: 1,
            permissions: permissions, allowedUnitIDs: allowedUnitIDs, editableDocumentIDs: editableDocumentIDs, requiresReceipts: requiresReceipts, reason: reason, expiresAt: Date().addingTimeInterval(7200))
        for expired in changeGrants.values.filter({ $0.grant.expiresAt < Date() }).map({ $0.grant.id }) { revokeChangeGrant(expired) }
        guard changeGrants.count < 32 else { throw ControlledChangeError.denied("待审阅的整理任务过多，请先应用或放弃。") }
        changeGrants[grant.id] = ChangeGrantSession(grant: grant, latestRevision: revision)
        return grant
    }

    public func prepareChanges(_ batch: ControlledChangeBatch, grant: ControlledWriteGrant) throws -> ControlledChangeProposal {
        let session = try requireChangeGrant(grant)
        let directory = try bookDirectory(grant.bookID, mustExist: true)
        try recoverDocument(in: directory)
        let project = try readProject(in: directory)
        let digest = try ControlledChangeCoding.hash(batch)
        if let prepared = changeProposals.values.first(where: { changeProposalGrants[$0.proposal.id] == grant.id && $0.proposal.digest == digest }) {
            if let receipt = project.controlledChanges?.receipts.first(where: { $0.operationID == prepared.proposal.operationID }) {
                try requireActiveChange(receipt, proposal: prepared.proposal, grant: grant, project: project, directory: directory)
                let revision = try ControlledChangeRecords.revision(project)
                if changeCommitRevisions[prepared.proposal.id] == revision { changeGrants[grant.id]?.latestRevision = revision }
                return prepared.proposal
            }
            try requireChangeRevision(project, session: session)
            return prepared.proposal // Stable operation ID and exact reviewed bytes.
        }
        try requireChangeRevision(project, session: session)
        guard changeProposals.count < 128 else { throw ControlledChangeError.denied("待处理提案过多，请先应用或放弃。") }
        let sessionProposals = changeProposals.values.filter { changeProposalGrants[$0.proposal.id] == grant.id }
        guard sessionProposals.count < 16 else { throw ControlledChangeError.denied("本次整理最多16批提案，请结束本次任务后再继续。") }
        let edits = batch.documents?.edits ?? [], creates = batch.documents?.create ?? []
        guard edits.count <= 16, creates.count <= 16, Set(edits.map(\.documentID)).count == edits.count else { throw ControlledChangeError.invalid("文档批次过大或重复编辑同一文档。") }
        let retainedBytes = sessionProposals.reduce(0) { total, proposal in
            total + proposal.bodies.values.reduce(0, { $0 + $1.count }) + proposal.beforeBodies.values.reduce(0, { $0 + $1.count })
        }
        var projectedBytes = retainedBytes + creates.reduce(0) { $0 + $1.markdown.utf8.count }
        var documentFiles: [String: (url: URL, size: Int)] = [:]
        // Inspect every size before reading any old body. Long notes replaced by
        // tiny output still occupy complete before/diff previews in this grant.
        for edit in edits {
            guard grant.editableDocumentIDs.contains(edit.documentID), let document = project.activeDocuments.first(where: { $0.id == edit.documentID }) else { throw ControlledChangeError.denied("本次未获准编辑此笔记。") }
            let url = try documentURL(document, in: directory), size = try regularFileSize(url, limit: Self.documentLimit)
            documentFiles[edit.documentID] = (url, size)
            projectedBytes += size + edit.markdown.utf8.count + (edit.mode == .append ? size : 0)
        }
        guard projectedBytes <= Self.changePreviewLimit else { throw ControlledChangeError.denied("本次整理的完整原文与修改后预览累计超过8 MiB。请缩小到更少或更短的笔记后重新整理；未读取超额正文，也未截断差异内容。") }
        var documentBodies: [String: Data] = [:]
        for (id, file) in documentFiles {
            // A concurrent growth cannot turn the admitted size into a larger
            // allocation. A shrink remains safe and is still checked by hash.
            documentBodies[id] = try readLimited(file.url, limit: file.size)
        }
        let prepared = try ControlledChangeBuilder.prepare(batch, grant: grant, project: project, documents: documentBodies,
            proposalID: UUID().uuidString, operationID: UUID().uuidString, baseRevision: session.latestRevision)
        guard sessionProposals.reduce(prepared.patches.count, { $0 + $1.patches.count }) <= 512,
              sessionProposals.reduce(prepared.bodies.count, { $0 + $1.bodies.count }) <= 32,
              sessionProposals.reduce(prepared.bodies.values.reduce(0, { $0 + $1.count }), { total, value in total + value.bodies.values.reduce(0, { $0 + $1.count }) }) <= 2_097_152 else { throw ControlledChangeError.denied("本次整理累计超过512项记录、32篇文档或2 MiB正文，未追加提案。") }
        guard retainedBytes + prepared.bodies.values.reduce(0, { $0 + $1.count }) + prepared.beforeBodies.values.reduce(0, { $0 + $1.count }) <= Self.changePreviewLimit else { throw ControlledChangeError.denied("本次整理的完整原文与修改后预览累计超过8 MiB，请缩小任务；差异内容未截断。") }
        try validate(prepared.project)
        try validatePackageFiles(prepared.project, in: directory, strictContents: false, verifySourceHash: false, pendingDocumentSizes: prepared.bodies.mapValues(\.count))
        changeProposals[prepared.proposal.id] = prepared; changeProposalGrants[prepared.proposal.id] = grant.id
        return prepared.proposal
    }

    public func approveChanges(proposalID: String, digest: String) throws -> ControlledChangeApproval {
        guard let prepared = changeProposals[proposalID], prepared.proposal.digest == digest,
              let grantID = changeProposalGrants[proposalID], let session = changeGrants[grantID] else { throw ControlledChangeError.denied("此提案不存在、已失效或摘要不同，请重新审阅。") }
        _ = try requireChangeGrant(session.grant)
        let token = UUID().uuidString; changeApprovals[proposalID] = token
        return ControlledChangeApproval(proposalID: proposalID, digest: digest, token: token)
    }

    public func commitChanges(proposalID: String, grant: ControlledWriteGrant, approval: ControlledChangeApproval? = nil) throws -> ControlledChangeCommitResult {
        let session = try requireChangeGrant(grant)
        guard let prepared = changeProposals[proposalID], changeProposalGrants[proposalID] == grant.id else { throw ControlledChangeError.denied("提案不属于此整理授权，或已撤销。") }
        let directory = try bookDirectory(grant.bookID, mustExist: true)
        try recoverDocument(in: directory)
        let canonical = try readProject(in: directory), proposal = prepared.proposal
        if let prior = canonical.controlledChanges?.receipts.first(where: { $0.operationID == proposal.operationID }) {
            try requireActiveChange(prior, proposal: proposal, grant: grant, project: canonical, directory: directory)
            // A recovery may have completed this exact operation before returning
            // from an interrupted call. Do not replay its writes.
            let revision = try ControlledChangeRecords.revision(canonical)
            if changeCommitRevisions[proposal.id] == revision { changeGrants[grant.id]?.latestRevision = revision }
            return ControlledChangeCommitResult(project: canonical, receipt: prior, replayed: true)
        }
        try requireChangeRevision(canonical, session: session)
        if proposal.requiresConfirmation {
            guard let approval, approval.proposalID == proposal.id, approval.digest == proposal.digest,
                  changeApprovals[proposal.id] == approval.token else { throw ControlledChangeError.denied("此提案必须先审阅具体差异再确认。") }
        }
        var candidate = try ControlledChangeRecords.applying(prepared.patches, to: canonical, undo: false)
        var bodies = prepared.bodies, expected: [String: String] = [:], receipts: [ControlledDocumentReceipt] = []
        for (id, body) in prepared.bodies.sorted(by: { $0.key < $1.key }) {
            guard let document = candidate.documents.first(where: { $0.id == id }) else { throw ControlledChangeError.invalid("待写正文没有登记文档。") }
            let path = try documentURL(document, in: directory), afterHash = try BookImporter.sha256(body)
            if let before = prepared.beforeBodies[id] {
                let beforeHash = try BookImporter.sha256(before)
                guard files.fileExists(atPath: path.path), try BookImporter.sha256(readLimited(path, limit: Self.documentLimit)) == beforeHash else { throw ControlledChangeError.conflict("审阅后磁盘 Markdown 已改变；原稿和提案均保留。") }
                let backupID = "backup-" + UUID().uuidString
                var backup = DocumentRecord(id: backupID, title: document.title + " · 整理前版本", origin: "change-recovery", linkedIDs: [], evidence: [])
                backup.trashedAt = Date(); candidate.documents.append(backup); bodies[backupID] = before
                expected[id] = beforeHash
                receipts.append(ControlledDocumentReceipt(documentID: id, afterHash: afterHash, beforeHash: beforeHash, backupDocumentID: backupID))
            } else {
                guard !files.fileExists(atPath: path.path) else { throw ControlledChangeError.conflict("新笔记路径已有文件，已保留该文件。") }
                receipts.append(ControlledDocumentReceipt(documentID: id, afterHash: afterHash, beforeHash: nil, backupDocumentID: nil))
            }
        }
        let receipt = ControlledChangeReceipt(operationID: proposal.operationID, originBookID: canonical.id, digest: proposal.digest, grantID: grant.id, createdAt: Date(), undoneAt: nil,
            idMap: proposal.idMap, groups: proposal.groups, patches: prepared.patches, documents: receipts)
        var state = candidate.controlledChanges ?? ControlledChangeState()
        guard state.receipts.count < 1_000 else { throw ControlledChangeError.denied("此书整理历史已达安全上限；未丢弃任何旧回执。") }
        state.receipts.append(receipt); candidate.controlledChanges = state
        candidate.audit.append(ToolAudit(name: "controlled_changes", summary: "已应用获准整理 \(receipt.operationID)，\(prepared.patches.count) 项记录变更。"))
        try ReadingKnowledgeRuntime.captureVersions(before: canonical, in: &candidate)
        changeCommitRevisions[proposal.id] = try ControlledChangeRecords.revision(candidate)
        try writeControlledTransaction(candidate, bodies: bodies, expectedHashes: expected, operationID: receipt.operationID, proofOperationID: receipt.operationID, in: directory)
        let committed = try readProject(in: directory)
        changeGrants[grant.id]?.latestRevision = try ControlledChangeRecords.revision(committed)
        refreshReadableAfterCommit(id: committed.id)
        return ControlledChangeCommitResult(project: committed, receipt: receipt, replayed: false)
    }

    public func undoChanges(bookID: String, operationID: String) throws -> ControlledChangeCommitResult {
        let directory = try bookDirectory(bookID, mustExist: true)
        try recoverDocument(in: directory)
        let canonical = try readProject(in: directory)
        guard let index = canonical.controlledChanges?.receipts.firstIndex(where: { $0.operationID == operationID }),
              let receipt = canonical.controlledChanges?.receipts[index], receipt.originBookID == bookID else { throw ControlledChangeError.denied("此回执不属于当前书籍；导入副本中的历史回执只供查看。") }
        if receipt.undoneAt != nil { return ControlledChangeCommitResult(project: canonical, receipt: receipt, replayed: true) }
        var bodies: [String: Data] = [:], expected: [String: String] = [:]
        // Check every body before making any metadata or file change.
        for item in receipt.documents {
            guard let document = canonical.documents.first(where: { $0.id == item.documentID }) else { throw ControlledChangeError.conflict("整理后的笔记引用已改变，未自动撤销。") }
            let body = try readLimited(try documentURL(document, in: directory), limit: Self.documentLimit)
            guard try BookImporter.sha256(body) == item.afterHash else { throw ControlledChangeError.conflict("笔记在整理后已有新编辑，撤销停止并保留当前内容。") }
            if let backupID = item.backupDocumentID, let beforeHash = item.beforeHash {
                guard let backup = canonical.documents.first(where: { $0.id == backupID }), backup.origin == "change-recovery" else { throw ControlledChangeError.conflict("整理前版本缺失；未覆盖当前笔记。") }
                let previous = try readLimited(try documentURL(backup, in: directory), limit: Self.documentLimit)
                guard try BookImporter.sha256(previous) == beforeHash else { throw ControlledChangeError.conflict("整理前备份已变化；未覆盖当前笔记。") }
                bodies[item.documentID] = previous; expected[item.documentID] = item.afterHash
            }
        }
        var candidate = try ControlledChangeRecords.applying(receipt.patches, to: canonical, undo: true)
        candidate.controlledChanges?.receipts[index].undoneAt = Date()
        candidate.audit.append(ToolAudit(name: "controlled_changes_undo", summary: "已撤销整理 \(operationID)，新增笔记保留在回收站。"))
        try ReadingKnowledgeRuntime.captureVersions(before: canonical, in: &candidate)
        try writeControlledTransaction(candidate, bodies: bodies, expectedHashes: expected, operationID: "undo-" + UUID().uuidString, proofOperationID: receipt.operationID, in: directory)
        let committed = try readProject(in: directory)
        refreshReadableAfterCommit(id: committed.id)
        return ControlledChangeCommitResult(project: committed, receipt: committed.controlledChanges!.receipts[index], replayed: false)
    }

    public func revokeChangeGrant(_ grantID: String) {
        changeGrants.removeValue(forKey: grantID)
        let proposals = changeProposalGrants.filter { $0.value == grantID }.map(\.key)
        for id in proposals { changeProposals.removeValue(forKey: id); changeProposalGrants.removeValue(forKey: id); changeApprovals.removeValue(forKey: id); changeCommitRevisions.removeValue(forKey: id) }
    }

    private func requireActiveChange(_ receipt: ControlledChangeReceipt, proposal: ControlledChangeProposal, grant: ControlledWriteGrant, project: BookProject, directory: URL) throws {
        guard receipt.digest == proposal.digest, receipt.grantID == grant.id, receipt.originBookID == project.id,
              receipt.undoneAt == nil else { throw ControlledChangeError.conflict("同一操作内容不同、已撤销或来自另一书籍，不能再报告为已应用。") }
        _ = try ControlledChangeRecords.applying(receipt.patches, to: project, undo: true)
        for item in receipt.documents {
            guard let document = project.documents.first(where: { $0.id == item.documentID }), document.trashedAt == nil,
                  try BookImporter.sha256(readLimited(try documentURL(document, in: directory), limit: Self.documentLimit)) == item.afterHash else { throw ControlledChangeError.conflict("这次整理的笔记后来已改变或回收，历史回执保留，但不能重放为当前成功。") }
        }
    }

    private func requireChangeGrant(_ grant: ControlledWriteGrant) throws -> ChangeGrantSession {
        guard let session = changeGrants[grant.id], session.grant == grant, grant.expiresAt >= Date() else { throw ControlledChangeError.denied("本次整理授权已失效或已撤销，请重新发起。") }
        return session
    }
    private func requireChangeRevision(_ project: BookProject, session: ChangeGrantSession) throws {
        guard project.id == session.grant.bookID, project.sourceHash == session.grant.sourceHash,
              try ControlledChangeRecords.revision(project) == session.latestRevision else { throw ControlledChangeError.conflict("等待整理期间书籍、笔记、布局或配置已变化；没有覆盖后来的修改，请重新发起整理。") }
    }
    private func requireCurrentChangeHistory(_ project: BookProject, existing: BookProject) throws {
        guard try project.controlledChanges.map(ControlledChangeCoding.data) == existing.controlledChanges.map(ControlledChangeCoding.data) else { throw ControlledChangeError.conflict("磁盘上已有更新的整理回执；当前窗口未覆盖该结果，请重新载入后保存。") }
        try requireCurrentManualTrashHistory(project, existing: existing)
    }
    private func requireCurrentManualTrashHistory(_ project: BookProject, existing: BookProject) throws {
        guard try project.manualTrash.map(ControlledChangeCoding.data) == existing.manualTrash.map(ControlledChangeCoding.data) else {
            throw ControlledChangeError.conflict("磁盘回收或恢复状态已变化；当前窗口不能复活已删除对象或覆盖恢复记录，请重新载入后保存。")
        }
    }

    private struct ControlledBodyJournal: Codable {
        var documentID: String; var beforeHash: String?; var afterHash: String
    }
    private struct ControlledJournal: Codable {
        var version: Int = 1; var operationID: String; var bookID: String
        var beforeMetadataHash: String; var afterMetadataHash: String
        var bodies: [ControlledBodyJournal]; var project: BookProject
        var proofOperationID: String? = nil; var proofReceiptHash: String? = nil
    }
    private func writeControlledTransaction(_ project: BookProject, bodies: [String: Data], expectedHashes: [String: String], operationID: String, proofOperationID: String, in directory: URL) throws {
        try ControlledChangeCoding.requireID(operationID)
        try validate(project)
        let metadata = try encode(project)
        try validatePackageFiles(project, in: directory, strictContents: false, verifySourceHash: false, encodedMetadataSize: metadata.count, pendingDocumentSizes: bodies.mapValues(\.count))
        let before = try readLimited(try child(directory, "project.json"), limit: Self.metadataLimit)
        let canonical: BookProject = try decode(before)
        try requireCurrentManualTrashHistory(project, existing: canonical)
        let journals = try ensureDirectory(try child(directory, ".changes-journal")), staging = try child(journals, operationID)
        try requireVacant(staging); _ = try ensureDirectory(staging)
        var changes: [ControlledBodyJournal] = []
        for (id, data) in bodies.sorted(by: { $0.key < $1.key }) {
            guard let document = project.documents.first(where: { $0.id == id }), data.count <= Self.documentLimit, String(data: data, encoding: .utf8) != nil else { throw ControlledChangeError.invalid("待写文档引用、大小或 UTF-8 无效。") }
            let destination = try documentURL(document, in: directory)
            if let hash = expectedHashes[id] {
                guard try BookImporter.sha256(readLimited(destination, limit: Self.documentLimit)) == hash else { throw ControlledChangeError.conflict("写入前 Markdown 已改变，未覆盖。") }
            } else { try requireVacant(destination) }
            try atomicWrite(data, to: try child(staging, "\(id).md"))
            changes.append(ControlledBodyJournal(documentID: id, beforeHash: expectedHashes[id], afterHash: try BookImporter.sha256(data)))
        }
        guard let proof = project.controlledChanges?.receipts.first(where: { $0.operationID == proofOperationID }) else { throw ControlledChangeError.invalid("事务缺少持久提交回执。") }
        let journal = ControlledJournal(operationID: operationID, bookID: project.id, beforeMetadataHash: try BookImporter.sha256(before), afterMetadataHash: try BookImporter.sha256(metadata), bodies: changes, project: project,
            proofOperationID: proofOperationID, proofReceiptHash: try ControlledChangeCoding.hash(proof))
        // Only this final marker makes staged files recoverable committed intent.
        try atomicWrite(encode(journal), to: try child(staging, "transaction.json"))
        try recoverControlledChanges(in: directory)
    }
    private func recoverControlledChanges(in directory: URL) throws {
        let journals = try child(directory, ".changes-journal")
        guard files.fileExists(atPath: journals.path) else { return }
        try requireDirectory(journals)
        let entries = try files.contentsOfDirectory(atPath: journals.path).filter { $0 != ".DS_Store" }.sorted()
        guard entries.count <= 4_000 else { throw ControlledChangeError.invalid("整理恢复目录过多，已保留现场。") }
        for name in entries {
            try ControlledChangeCoding.requireID(name)
            let staging = try child(journals, name); try requireDirectory(staging)
            let marker = try child(staging, "transaction.json")
            guard files.fileExists(atPath: marker.path) else { continue }
            let journal: ControlledJournal = try decode(readLimited(marker, limit: Self.metadataLimit))
            guard journal.version == 1, journal.operationID == name, journal.bookID == directory.lastPathComponent, journal.project.id == journal.bookID,
                  journal.bodies.count <= 64, Set(journal.bodies.map(\.documentID)).count == journal.bodies.count,
                  ControlledChangeRecords.hash(journal.beforeMetadataHash), ControlledChangeRecords.hash(journal.afterMetadataHash) else { throw ControlledChangeError.invalid("整理恢复标记的版本或身份无效，已保留现场。") }
            try validate(journal.project)
            let metadata = try encode(journal.project), metadataURL = try child(directory, "project.json")
            let currentMetadata = try readLimited(metadataURL, limit: Self.metadataLimit)
            let current: BookProject = try decode(currentMetadata)
            guard current.id == journal.bookID, current.sourceHash == journal.project.sourceHash, current.originalName == journal.project.originalName,
                  try BookImporter.sha256(metadata) == journal.afterMetadataHash else { throw ControlledChangeError.conflict("整理恢复与当前书籍身份或文档登记冲突，保留现场。") }
            if try controlledJournalIsCommitted(journal, current: current) {
                // Metadata carrying this exact receipt can only follow all body
                // replacements. Cleanup failure must never replay old bytes over
                // a later answer, note edit or layout change.
                cleanupControlledJournal(journal, staging: staging, marker: marker)
                continue
            }
            try requireCurrentManualTrashHistory(journal.project, existing: current)
            guard Set(current.documents.map(\.id)).isSubset(of: Set(journal.project.documents.map(\.id))) else { throw ControlledChangeError.conflict("整理恢复缺少后来的文档登记，保留现场。") }
            let currentHash = try BookImporter.sha256(currentMetadata)
            guard currentHash == journal.beforeMetadataHash || currentHash == journal.afterMetadataHash else { throw ControlledChangeError.conflict("恢复期间项目元数据已有外部修改；磁盘及待恢复资料均保留。") }
            var staged: [(URL, URL, Data)] = [], sizes: [String: Int] = [:]
            for item in journal.bodies {
                guard let document = journal.project.documents.first(where: { $0.id == item.documentID }), ControlledChangeRecords.hash(item.afterHash), item.beforeHash.map(ControlledChangeRecords.hash) ?? true else { throw ControlledChangeError.invalid("整理恢复正文的引用或散列无效。") }
                let source = try child(staging, "\(item.documentID).md"), destination = try documentURL(document, in: directory)
                let body = try readLimited(source, limit: Self.documentLimit)
                guard String(data: body, encoding: .utf8) != nil, try BookImporter.sha256(body) == item.afterHash else { throw ControlledChangeError.invalid("整理恢复正文校验失败，已保留现场。") }
                if files.fileExists(atPath: destination.path) {
                    let actual = try BookImporter.sha256(readLimited(destination, limit: Self.documentLimit))
                    guard actual == item.beforeHash || actual == item.afterHash else { throw ControlledChangeError.conflict("恢复期间 Markdown 已被外部编辑，未自动覆盖任何冲突内容。") }
                } else if item.beforeHash != nil { throw ControlledChangeError.conflict("恢复所需的旧 Markdown 已移除，未自动重建。") }
                staged.append((source, destination, body)); sizes[item.documentID] = body.count
            }
            try validatePackageFiles(journal.project, in: directory, strictContents: false, verifySourceHash: false, encodedMetadataSize: metadata.count, pendingDocumentSizes: sizes)
            // All file and metadata preconditions have passed. Replacements are
            // idempotent and a crash can continue from either old or new bytes.
            for (_, destination, body) in staged { try atomicWrite(body, to: destination) }
            try atomicWrite(metadata, to: metadataURL)
            cleanupControlledJournal(journal, staging: staging, marker: marker)
        }
    }
    private func cleanupControlledJournal(_ journal: ControlledJournal, staging: URL, marker: URL) {
        // Visible data and receipt are already durable. Best-effort cleanup of
        // exact verified owned files must not turn success into an apparent fail.
        for item in journal.bodies {
            guard let source = try? child(staging, "\(item.documentID).md"),
                  let bytes = try? readLimited(source, limit: Self.documentLimit),
                  (try? BookImporter.sha256(bytes)) == item.afterHash else { continue }
            try? files.removeItem(at: source)
        }
        try? files.removeItem(at: marker)
        if (try? files.contentsOfDirectory(atPath: staging.path).isEmpty) == true { try? files.removeItem(at: staging) }
    }
    private func controlledJournalIsCommitted(_ journal: ControlledJournal, current: BookProject) throws -> Bool {
        guard let proofID = journal.proofOperationID, let proofHash = journal.proofReceiptHash,
              let expected = journal.project.controlledChanges?.receipts.first(where: { $0.operationID == proofID }),
              try ControlledChangeCoding.hash(expected) == proofHash,
              var actual = current.controlledChanges?.receipts.first(where: { $0.operationID == proofID }) else { return false }
        // An original commit remains known committed after its later explicit
        // undo. The stale cleanup marker must not block reopening that book.
        if expected.undoneAt == nil { actual.undoneAt = nil }
        return try ControlledChangeCoding.hash(actual) == proofHash
    }
}

extension LibraryRepository {
    /// Search-only text preparation. Never a content-hash receipt or a writer
    /// grant. Small callers may retain readDocument; a batch verifies current
    /// membership once before and after its synchronous, cancellable file pass.
    public func readDocumentsForSearch(bookID: String, sourceHash: String, documents: [DocumentRecord]) throws -> [String: String] {
        try Task.checkCancellation()
        guard !documents.isEmpty else { return [:] }
        guard Set(documents.map(\.id)).count == documents.count else {
            throw ReadingError.invalid("检索请求包含重复的笔记。")
        }
        let directory = try bookDirectory(bookID, mustExist: true)
        try recoverDocument(in: directory)
        func checkedRecords(_ project: BookProject) throws -> [String: DocumentRecord] {
            guard project.id == bookID, project.sourceHash == sourceHash else {
                throw ReadingError.invalid("书籍来源已变化，请重新载入后搜索。")
            }
            let current = Dictionary(project.activeDocuments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for document in documents {
                guard let record = current[document.id], record.relativePath == document.relativePath,
                      record.updatedAt == document.updatedAt else {
                    throw ReadingError.invalid("笔记引用或版本已变化，请重新载入后搜索。")
                }
            }
            return current
        }
        let records = try checkedRecords(readProject(in: directory))
        var texts: [String: String] = [:]
        var total = 0
        for document in documents {
            try Task.checkCancellation()
            guard let record = records[document.id] else { throw ReadingError.invalid("笔记不属于当前书籍。") }
            let data = try readLimited(documentURL(record, in: directory), limit: Self.documentLimit)
            total += data.count
            guard total <= Self.packageLimit, let text = String(data: data, encoding: .utf8) else {
                throw ReadingError.invalid("笔记不是有效UTF-8或检索内容超过书库大小限制。")
            }
            texts[record.id] = text
        }
        try Task.checkCancellation()
        try recoverDocument(in: directory)
        _ = try checkedRecords(readProject(in: directory))
        return texts
    }
}
