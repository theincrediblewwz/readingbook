import Foundation

/// Local, file-backed library. Markdown files are the only document body source;
/// project.json contains references and structured book analysis, never a body mirror.
public actor LibraryRepository {
    private let rootURL: URL
    private let files = FileManager.default
    private static let metadataLimit = 64 * 1_024 * 1_024
    private static let documentLimit = 16 * 1_024 * 1_024
    private static let packageLimit = 512 * 1_024 * 1_024

    private struct DocumentJournal: Codable {
        var version: Int = 1
        var bookID: String
        var documentID: String
        var markdownHash: String
        var project: BookProject
    }

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func loadAll() throws -> [BookProject] {
        let books = try booksDirectory()
        let children = try files.contentsOfDirectory(at: books, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var projects: [BookProject] = []
        for directory in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if directory.lastPathComponent == ".DS_Store" { continue }
            // Incomplete imports have not entered the committed book namespace. Keep them
            // on disk and surface them rather than quietly discarding possible recovery data.
            guard UUID(uuidString: directory.lastPathComponent) != nil else {
                throw ReadingError.invalid("书库包含无法识别的项目目录：\(directory.lastPathComponent)。原文件已保留。")
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
                throw ReadingError.invalid("无法载入书籍 \(directory.lastPathComponent)：\(error.localizedDescription) 原文件已保留；未将损坏项目当作空书。")
            }
        }
        return projects.sorted { $0.importedAt > $1.importedAt }
    }

    public func create(_ project: BookProject, sourceURL: URL) throws {
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
    }

    public func save(_ project: BookProject) throws {
        let directory = try bookDirectory(project.id, mustExist: true)
        try recoverDocument(in: directory)
        try validate(project)
        let existing = try readProject(in: directory)
        guard existing.id == project.id, existing.originalName == project.originalName, existing.sourceHash == project.sourceHash else {
            throw ReadingError.invalid("保存不能替换项目身份或原书。")
        }
        // A stale window must not erase references to user-owned Markdown documents.
        guard Set(existing.documents.map(\.id)).isSubset(of: Set(project.documents.map(\.id))) else {
            throw ReadingError.invalid("项目中的 Markdown 引用比磁盘版本少，已阻止覆盖。请重新载入书籍。")
        }
        var updated = project
        updated.readerAnnotations = existing.readerAnnotations
        // Only the explicit trash/restore API changes this canonical status. A stale reader
        // or editor window cannot silently revive a document through a routine save.
        for saved in existing.documents {
            if let index = updated.documents.firstIndex(where: { $0.id == saved.id }) { updated.documents[index].trashedAt = saved.trashedAt }
        }
        try validatePackageFiles(updated, in: directory, strictContents: false, verifySourceHash: false)
        try atomicWrite(encode(updated), to: try child(directory, "project.json"))
    }

    public func readDocument(bookID: String, document: DocumentRecord) throws -> String {
        let directory = try bookDirectory(bookID, mustExist: true)
        try recoverDocument(in: directory)
        let stored = try readProject(in: directory)
        guard let record = stored.documents.first(where: { $0.id == document.id }), record.relativePath == document.relativePath else {
            throw ReadingError.invalid("此文档不属于当前书籍，或文档引用已改变。")
        }
        let data = try readLimited(try documentURL(document, in: directory), limit: Self.documentLimit)
        guard let markdown = String(data: data, encoding: .utf8) else { throw ReadingError.invalid("Markdown 不是有效 UTF-8，未用替换字符覆盖原文。") }
        return markdown
    }

    public func saveDocument(project: BookProject, document: DocumentRecord, markdown: String) throws -> BookProject {
        let directory = try bookDirectory(project.id, mustExist: true)
        try recoverDocument(in: directory)
        let existing = try readProject(in: directory)
        guard project.originalName == existing.originalName, project.sourceHash == existing.sourceHash else { throw ReadingError.invalid("文档保存时书籍身份发生变化。") }
        let data = Data(markdown.utf8)
        guard data.count <= Self.documentLimit else { throw ReadingError.invalid("单篇 Markdown 超过 16 MiB。") }
        try validateDocumentPath(document)
        var updated = project
        updated.readerAnnotations = existing.readerAnnotations
        // Retain references written by another window before this editor was opened.
        for saved in existing.documents where !updated.documents.contains(where: { $0.id == saved.id }) { updated.documents.append(saved) }
        for saved in existing.documents {
            if let index = updated.documents.firstIndex(where: { $0.id == saved.id }) { updated.documents[index].trashedAt = saved.trashedAt }
        }
        var record = document
        if let previous = existing.documents.first(where: { $0.id == document.id }) {
            guard previous.relativePath == document.relativePath else { throw ReadingError.invalid("不能通过保存正文改变文档路径。") }
            guard previous.trashedAt == nil else { throw ReadingError.invalid("文档已在回收站，请先恢复后再编辑；原 Markdown 已保留。") }
            record.createdAt = previous.createdAt
            record.trashedAt = previous.trashedAt
        }
        record.updatedAt = Date()
        if let index = updated.documents.firstIndex(where: { $0.id == record.id }) { updated.documents[index] = record }
        else { updated.documents.append(record) }
        try validate(updated)
        // Validate all pre-existing files; the one being saved is allowed not to exist yet.
        try validatePackageFiles(updated, in: directory, strictContents: false, verifySourceHash: false, pendingDocumentID: record.id)
        let journalDirectory = try ensureDirectory(try child(directory, ".journal"))
        let stagedBody = try child(journalDirectory, "document.md")
        let marker = try child(journalDirectory, "transaction.json")
        guard !files.fileExists(atPath: marker.path) else { throw ReadingError.invalid("上一份文档事务尚未恢复。") }
        // The commit marker is written last. Before it exists the original files have not
        // changed; after it exists loadAll can repeat both idempotent replacements.
        try atomicWrite(data, to: stagedBody)
        let journal = DocumentJournal(bookID: updated.id, documentID: record.id,
                                      markdownHash: try BookImporter.sha256(data), project: updated)
        try atomicWrite(encode(journal), to: marker)
        try recoverDocument(in: directory)
        return updated
    }

    public func setDocumentTrashed(project: BookProject, documentID: String, trashed: Bool) throws -> BookProject {
        guard Self.isSafeID(documentID) else { throw ReadingError.invalid("文档 ID 不合法。") }
        let directory = try bookDirectory(project.id, mustExist: true)
        try recoverDocument(in: directory)
        var updated = try readProject(in: directory)
        guard updated.id == project.id, updated.sourceHash == project.sourceHash,
              updated.originalName == project.originalName else { throw ReadingError.invalid("回收操作中的书籍身份与磁盘记录不符。") }
        guard let index = updated.documents.firstIndex(where: { $0.id == documentID }) else { throw ReadingError.invalid("文档不属于此书籍。") }
        guard (updated.documents[index].trashedAt != nil) != trashed else { return updated }
        updated.documents[index].trashedAt = trashed ? Date() : nil
        updated.documents[index].updatedAt = Date()
        updated.audit.append(ToolAudit(name: trashed ? "document_trash" : "document_restore", summary: "\(trashed ? "移入回收站" : "恢复")文档：\(updated.documents[index].title)；Markdown 与导图关联保留。"))
        try validate(updated)
        try validatePackageFiles(updated, in: directory, strictContents: false, verifySourceHash: false)
        try atomicWrite(encode(updated), to: try child(directory, "project.json"))
        return updated
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
        return updated
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
        return updated
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
    }

    public func archivedBooks() throws -> [BookProject] {
        let trash = try trashDirectory()
        let children = try files.contentsOfDirectory(at: trash, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var result: [BookProject] = []
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
            } catch { throw ReadingError.invalid("回收书籍 \(directory.lastPathComponent) 读取失败，文件已保留：\(error.localizedDescription)") }
        }
        return result.sorted { $0.importedAt > $1.importedAt }
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
        do { try files.moveItem(at: source, to: destination) }
        catch { throw ReadingError.invalid("书籍恢复未完成。回收目录及可能的目标文件均已保留，请检查 trash/\(id) 与 books/\(id)：\(error.localizedDescription)") }
        return project
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
        guard existing.sourceHash == project.sourceHash, existing.units == project.units else { throw ReadingError.invalid("识别期间原文层已变化，请重新载入后继续。") }
        try checkOCRPage(project: existing, page: result.page)
        let updated = try OCRIntegration.applying(result, to: existing)
        try validate(updated)
        try validatePackageFiles(updated, in: directory, strictContents: false, verifySourceHash: true)
        try atomicWrite(encode(updated), to: try child(directory, "project.json"))
        return updated
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
        return project
    }

    // MARK: Recoverable document commit

    private func recoverDocument(in directory: URL) throws {
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
        try validatePackageFiles(journal.project, in: directory, strictContents: false, verifySourceHash: false, pendingDocumentID: document.id)
        try atomicWrite(body, to: try documentURL(document, in: directory))
        try atomicWrite(encode(journal.project), to: try child(directory, "project.json"))
        // Remove only our two exact journal files, after both durable replacements succeed.
        try files.removeItem(at: marker)
        try files.removeItem(at: staged)
    }

    // MARK: Package validation

    private func validate(_ project: BookProject) throws {
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
        try ReadingLedger.validateStoredRecords(in: project)
        if let experience = project.readingExperience {
            try ReadingExperienceRuntime.validateStoredState(experience, in: project)
        }
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
            guard targets.contains(node.targetID), node.x.isFinite, node.y.isFinite,
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

    private func validatePackageFiles(_ project: BookProject, in directory: URL, strictContents: Bool,
                                      verifySourceHash: Bool, pendingDocumentID: String? = nil) throws {
        try requireDirectory(directory)
        let source = try child(try child(directory, "source"), project.originalName)
        try requireDirectory(try child(directory, "source"))
        try requireDirectory(try child(directory, "docs"))
        var total = try regularFileSize(source, limit: BookImporter.maximumSourceBytes)
        let storedMetadata = try child(directory, "project.json")
        var storedSize = 0
        if files.fileExists(atPath: storedMetadata.path) { storedSize = try regularFileSize(storedMetadata, limit: Self.metadataLimit) }
        total += max(storedSize, try encode(project).count)
        if verifySourceHash { try verifyOriginal(at: source, expectedHash: project.sourceHash) }
        for document in project.documents where document.id != pendingDocumentID {
            let url = try documentURL(document, in: directory)
            let data = try readLimited(url, limit: Self.documentLimit)
            guard String(data: data, encoding: .utf8) != nil else { throw ReadingError.invalid("Markdown 文件不是有效 UTF-8：\(document.relativePath)") }
            total += data.count
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

    // MARK: Restricted filesystem helpers

    private func booksDirectory() throws -> URL {
        guard rootURL.isFileURL else { throw ReadingError.invalid("书库必须使用本地文件夹。") }
        _ = try ensureDirectory(rootURL)
        return try ensureDirectory(try child(rootURL, "books"))
    }

    private func trashDirectory() throws -> URL {
        guard rootURL.isFileURL else { throw ReadingError.invalid("书库必须使用本地文件夹。") }
        _ = try ensureDirectory(rootURL)
        return try ensureDirectory(try child(rootURL, "trash"))
    }

    private func archivedBookDirectory(_ id: String, mustExist: Bool) throws -> URL {
        guard id.count == 36, UUID(uuidString: id) != nil else { throw ReadingError.invalid("回收书籍 ID 必须为 UUID。") }
        let url = try child(try trashDirectory(), id)
        if mustExist { try requireDirectory(url) }
        return url
    }

    private func requireVacant(_ url: URL) throws {
        let symbolic = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        guard !files.fileExists(atPath: url.path), !symbolic else { throw ReadingError.invalid("目标已存在；不会覆盖已有书籍或回收数据。") }
    }

    /// Verify the complete moved tree, including undeclared recovery files, without following links.
    private func validateArchiveTree(_ directory: URL) throws {
        try requireDirectory(directory)
        var pending = [directory], count = 0, total = 0
        while let parent = pending.popLast() {
            for entry in try files.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
                count += 1
                guard count <= 100_000 else { throw ReadingError.invalid("书籍目录条目过多，已保留原目录。") }
                let checked = try child(parent, entry.lastPathComponent)
                let values = try checked.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw ReadingError.invalid("回收目录不允许符号链接。") }
                if values.isDirectory == true { pending.append(checked) }
                else {
                    guard values.isRegularFile == true, let size = values.fileSize, size >= 0,
                          size <= Self.packageLimit, total <= Self.packageLimit - size else { throw ReadingError.invalid("书籍目录含特殊文件或总大小超过 512 MiB。") }
                    total += size
                }
            }
        }
    }

    private func bookDirectory(_ id: String, mustExist: Bool) throws -> URL {
        guard id.count == 36, UUID(uuidString: id) != nil else { throw ReadingError.invalid("书籍 ID 必须为 UUID。") }
        let url = try child(try booksDirectory(), id)
        if mustExist { try requireDirectory(url) }
        return url
    }

    private func child(_ parent: URL, _ name: String) throws -> URL {
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

    private func ensureDirectory(_ url: URL) throws -> URL {
        if files.fileExists(atPath: url.path) { try requireDirectory(url) }
        else { try files.createDirectory(at: url, withIntermediateDirectories: true); try requireDirectory(url) }
        return url
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ReadingError.invalid("预期为普通文件夹且不能是符号链接：\(url.lastPathComponent)") }
    }

    private func documentURL(_ document: DocumentRecord, in directory: URL) throws -> URL {
        try validateDocumentPath(document)
        return try child(try child(directory, "docs"), "\(document.id).md")
    }

    private func regularFileSize(_ url: URL, limit: Int) throws -> Int {
        let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard value.isRegularFile == true, value.isSymbolicLink != true, let size = value.fileSize, size >= 0, size <= limit else {
            throw ReadingError.invalid("文件缺失、不是普通文件，或超过大小上限：\(url.lastPathComponent)")
        }
        return size
    }

    private func readLimited(_ url: URL, limit: Int) throws -> Data {
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

    private func readProject(in directory: URL) throws -> BookProject {
        try decode(readLimited(try child(directory, "project.json"), limit: Self.metadataLimit))
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        // Foundation writes a sibling temporary file and atomically replaces the destination.
        _ = try child(url.deletingLastPathComponent(), url.lastPathComponent)
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func temporaryDirectory(near parent: URL, prefix: String) throws -> URL {
        try requireDirectory(parent)
        let url = try child(parent, prefix + UUID().uuidString)
        guard !files.fileExists(atPath: url.path) else { throw ReadingError.invalid("临时目录冲突，请重试。") }
        try files.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func removeOwnTemporary(_ url: URL) {
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
