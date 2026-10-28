import Foundation
import CryptoKit

public struct LibraryStorageBook: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let directoryURL: URL
    public let sourceURL: URL
    public let documentsURL: URL
    public let metadataURL: URL
    public let bytes: Int64
    public let isRemoved: Bool
    public let isArchived: Bool
}

public struct LibraryStorageOverview: Sendable {
    public let rootURL: URL
    public let booksURL: URL
    public let trashURL: URL
    public let totalBytes: Int64
    public let books: [LibraryStorageBook]
}

public struct LibraryTransferProgress: Sendable {
    public let stage: String
    public let completedFiles: Int
    public let totalFiles: Int
    public init(stage: String, completedFiles: Int, totalFiles: Int) {
        self.stage = stage; self.completedFiles = completedFiles; self.totalFiles = totalFiles
    }
}

public struct LibraryTransferResult: Sendable {
    public let rootURL: URL
    public let bytes: Int64
    public let files: Int
}

struct LibraryMembership: Codable {
    var version = 1
    var removed: [String: Date] = [:]
}

private struct LibraryTransferEntry: Codable, Equatable {
    var path: String
    var bytes: Int64
    var sha256: String
}
private struct LibraryTransferManifest: Codable {
    var version = 1
    var createdAt: Date
    var directories: [String]
    var files: [LibraryTransferEntry]
}

extension LibraryRepository {
    private static var membershipName: String { ".readingbook-membership.json" }
    private static var transferFileLimit: Int64 { 512 * 1_024 * 1_024 }
    private static var transferTotalLimit: Int64 { 64 * 1_024 * 1_024 * 1_024 }
    private static var persistentRootNames: Set<String> {
        ["books", "trash", "ConversationMemory", "Workspace", "ModelCatalog", membershipName, ".readingbook-readable.json"]
    }

    func libraryMembership() throws -> LibraryMembership {
        let url = try child(rootURL, Self.membershipName)
        guard files.fileExists(atPath: url.path) else { return LibraryMembership() }
        let value = try JSONDecoder().decode(LibraryMembership.self, from: readLimited(url, limit: 8 * 1_024 * 1_024))
        guard value.version == 1, value.removed.count <= 100_000,
              value.removed.keys.allSatisfy({ $0.count == 36 && UUID(uuidString: $0) != nil }) else {
            throw ReadingError.invalid("书库显示状态无效，已保留原文件。")
        }
        return value
    }

    public func removeBookFromLibrary(project: BookProject) throws {
        let directory = try bookDirectory(project.id, mustExist: true)
        let canonical = try storageProject(in: directory, expectedID: project.id)
        guard canonical.sourceHash == project.sourceHash, canonical.originalName == project.originalName else {
            throw ReadingError.invalid("此书已变化，未从书库移除。")
        }
        var membership = try libraryMembership()
        if membership.removed[project.id] == nil {
            membership.removed[project.id] = Date()
            try saveMembership(membership)
        }
        _ = try? refreshReadableLibraryIndex()
    }

    public func removedBooksReport() throws -> LibraryLoadReport {
        let membership = try libraryMembership()
        var projects: [BookProject] = [], issues: [LibraryLoadIssue] = []
        for id in membership.removed.keys.sorted() {
            do {
                let archived = try archivedBookDirectory(id, mustExist: false)
                if files.fileExists(atPath: archived.path) { continue }
                let directory = try bookDirectory(id, mustExist: true)
                projects.append(try storageProject(in: directory, expectedID: id))
            } catch {
                issues.append(LibraryLoadIssue(folder: rootURL.appendingPathComponent("books/" + id).path,
                                              message: "已移除书籍的文件未能载入，原登记保留：\(error.localizedDescription)"))
            }
        }
        return LibraryLoadReport(projects: projects.sorted { $0.importedAt > $1.importedAt }, issues: issues)
    }

    public func rejoinBook(id: String) throws -> BookProject {
        let project = try storageProject(in: bookDirectory(id, mustExist: true), expectedID: id)
        try forgetRemovedBook(id: id)
        _ = try? refreshReadableViews(id: id)
        _ = try? refreshReadableLibraryIndex()
        return project
    }

    /// Removes only a library-list registration, never a book or a file. The UI
    /// calls this after a successful, separately confirmed system-Trash action.
    public func forgetRemovedBook(id: String) throws {
        guard id.count == 36, UUID(uuidString: id) != nil else { throw ReadingError.invalid("书籍 ID 无效。") }
        var membership = try libraryMembership()
        if membership.removed.removeValue(forKey: id) != nil { try saveMembership(membership) }
    }

    private func saveMembership(_ membership: LibraryMembership) throws {
        _ = try booksDirectory()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try atomicWrite(encoder.encode(membership), to: child(rootURL, Self.membershipName))
    }

    public func storageRootURL() throws -> URL {
        _ = try booksDirectory(); _ = try trashDirectory()
        try requireDirectory(rootURL)
        return rootURL
    }

    public func storageOverview() throws -> LibraryStorageOverview {
        let books = try booksDirectory(), trash = try trashDirectory()
        var result: [LibraryStorageBook] = []
        for (directory, archived) in [(books, false), (trash, true)] {
            for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if url.lastPathComponent == ".DS_Store" { continue }
                result.append(try storageBook(id: url.lastPathComponent, archived: archived))
            }
        }
        return LibraryStorageOverview(rootURL: rootURL, booksURL: books, trashURL: trash,
                                      totalBytes: try storageBytes(in: rootURL),
                                      books: result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }

    public func storageBook(id: String, archived: Bool = false) throws -> LibraryStorageBook {
        let directory: URL
        if archived { directory = try archivedBookDirectory(id, mustExist: true) }
        else { directory = try bookDirectory(id, mustExist: true) }
        let project = try readProject(in: directory)
        guard project.id == id else { throw ReadingError.invalid("书籍身份与目录不符。") }
        try validate(project)
        var removed = false
        if !archived { removed = try libraryMembership().removed[id] != nil }
        return LibraryStorageBook(id: project.id, title: project.title, directoryURL: directory,
                                  sourceURL: try child(child(directory, "source"), project.originalName),
                                  documentsURL: try child(directory, "docs"), metadataURL: try child(directory, "project.json"),
                                  bytes: try storageBytes(in: directory),
                                  isRemoved: removed, isArchived: archived)
    }

    /// Validates identity, canonical data and the complete bounded tree. This
    /// does not delete, move, resolve an external import path, or invoke AppKit.
    public func prepareLocalBookRemoval(id: String, archived: Bool = false) throws -> LibraryStorageBook {
        let directory: URL
        if archived { directory = try archivedBookDirectory(id, mustExist: true) }
        else { directory = try bookDirectory(id, mustExist: true) }
        _ = try storageProject(in: directory, expectedID: id)
        return try storageBook(id: id, archived: archived)
    }

    /// Validation and the caller's synchronous move share one actor turn. A
    /// queued derived refresh cannot recreate the directory during the move.
    /// The caller chooses its recoverable destination; Core only supplies the
    /// validated App-managed project, never the original import location.
    public func moveLocalBook(id: String, archived: Bool = false, using move: @Sendable (URL) throws -> URL?) throws -> URL? {
        let prepared = try prepareLocalBookRemoval(id: id, archived: archived)
        let destination = try move(prepared.directoryURL)
        guard !files.fileExists(atPath: prepared.directoryURL.path) else {
            throw ReadingError.invalid("项目仍在原目录，未完成本机副本移除；原登记保留。")
        }
        try? forgetRemovedBook(id: id)
        _ = try? refreshReadableLibraryIndex()
        return destination
    }

    func storageProject(in directory: URL, expectedID: String, recoverTransactions: Bool = true) throws -> BookProject {
        if recoverTransactions { try recoverDocument(in: directory) }
        else { try requireSettledStorageTransactions(in: directory) }
        let project = try readProject(in: directory)
        guard project.id == expectedID else { throw ReadingError.invalid("书籍身份与目录不符。") }
        try validate(project)
        try validatePackageFiles(project, in: directory, strictContents: false, verifySourceHash: true)
        try validateArchiveTree(directory)
        return project
    }

    public func copyLibrary(to destination: URL, progress: (@Sendable (LibraryTransferProgress) -> Void)? = nil) throws -> LibraryTransferResult {
        progress?(LibraryTransferProgress(stage: "预检", completedFiles: 0, totalFiles: 0))
        flushPendingReadableRefreshes()
        try validateWholeLibrary(at: rootURL)
        let snapshot = try transferTree(at: rootURL, roots: persistentRoots(in: rootURL))
        let target = try transferDestination(destination, disjointFrom: rootURL)
        let staging = try temporaryDirectory(near: target.deletingLastPathComponent(), prefix: ".readingbook-copy-")
        defer { removeOwnTemporary(staging) }
        try copyTransferTree(snapshot, from: rootURL, to: staging, progress: progress)
        progress?(LibraryTransferProgress(stage: "校验", completedFiles: 0, totalFiles: snapshot.files.count))
        try validateWholeLibrary(at: staging)
        try requireMatchingTree(snapshot, at: staging)
        try requireMatchingTree(snapshot, at: rootURL, roots: persistentRoots(in: rootURL))
        try commitTransfer(staging, to: target)
        progress?(LibraryTransferProgress(stage: "完成", completedFiles: snapshot.files.count, totalFiles: snapshot.files.count))
        return LibraryTransferResult(rootURL: target, bytes: snapshot.files.reduce(0) { $0 + $1.bytes }, files: snapshot.files.count)
    }

    public func exportLibraryBackup(to destination: URL, progress: (@Sendable (LibraryTransferProgress) -> Void)? = nil) throws -> LibraryTransferResult {
        guard destination.pathExtension.lowercased() == "readingbookbackup" else { throw ReadingError.invalid("请选择 .readingbookbackup 备份文件夹。") }
        progress?(LibraryTransferProgress(stage: "预检", completedFiles: 0, totalFiles: 0))
        flushPendingReadableRefreshes()
        try validateWholeLibrary(at: rootURL)
        let snapshot = try transferTree(at: rootURL, roots: persistentRoots(in: rootURL))
        let target = try transferDestination(destination, disjointFrom: rootURL)
        let staging = try temporaryDirectory(near: target.deletingLastPathComponent(), prefix: ".readingbook-backup-")
        defer { removeOwnTemporary(staging) }
        let library = try ensureDirectory(child(staging, "library"))
        try copyTransferTree(snapshot, from: rootURL, to: library, progress: progress)
        let manifest = LibraryTransferManifest(createdAt: Date(), directories: snapshot.directories, files: snapshot.files)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try atomicWrite(encoder.encode(manifest), to: child(staging, "manifest.json"))
        progress?(LibraryTransferProgress(stage: "校验", completedFiles: 0, totalFiles: snapshot.files.count))
        _ = try checkedBackup(staging)
        try requireMatchingTree(snapshot, at: rootURL, roots: persistentRoots(in: rootURL))
        try commitTransfer(staging, to: target)
        progress?(LibraryTransferProgress(stage: "完成", completedFiles: snapshot.files.count, totalFiles: snapshot.files.count))
        return LibraryTransferResult(rootURL: target, bytes: snapshot.files.reduce(0) { $0 + $1.bytes }, files: snapshot.files.count)
    }

    public func restoreLibraryBackup(from backup: URL, to destination: URL,
                                     progress: (@Sendable (LibraryTransferProgress) -> Void)? = nil) throws -> LibraryTransferResult {
        progress?(LibraryTransferProgress(stage: "预检", completedFiles: 0, totalFiles: 0))
        let manifest = try checkedBackup(backup)
        let library = try child(backup, "library")
        let target = try transferDestination(destination, disjointFrom: backup)
        guard !pathsOverlap(target, rootURL) else { throw ReadingError.invalid("恢复目标不能覆盖或包含当前书库。请选择新的空文件夹。") }
        let staging = try temporaryDirectory(near: target.deletingLastPathComponent(), prefix: ".readingbook-restore-")
        defer { removeOwnTemporary(staging) }
        try copyTransferTree(manifest, from: library, to: staging, progress: progress)
        progress?(LibraryTransferProgress(stage: "校验", completedFiles: 0, totalFiles: manifest.files.count))
        try validateWholeLibrary(at: staging)
        try requireMatchingTree(manifest, at: staging)
        _ = try checkedBackup(backup)
        try commitTransfer(staging, to: target)
        progress?(LibraryTransferProgress(stage: "完成", completedFiles: manifest.files.count, totalFiles: manifest.files.count))
        return LibraryTransferResult(rootURL: target, bytes: manifest.files.reduce(0) { $0 + $1.bytes }, files: manifest.files.count)
    }

    private func persistentRoots(in root: URL) throws -> Set<String> {
        try requireDirectory(root)
        let names = Set(try files.contentsOfDirectory(atPath: root.path).filter { $0 != ".DS_Store" })
        guard names.allSatisfy({ Self.persistentRootNames.contains($0) || ($0.hasPrefix("书库目录") && $0.hasSuffix(".md")) }) else {
            throw ReadingError.invalid("书库根目录有未登记的文件，未静默遗漏或复制。请先在 Finder 核对，再重试。")
        }
        return names
    }

    private func validateWholeLibrary(at root: URL) throws {
        try requireDirectory(root)
        let allowed = try persistentRoots(in: root)
        var seenBookIDs: Set<String> = []
        for namespace in ["books", "trash"] {
            guard allowed.contains(namespace) else { continue }
            let directory = try child(root, namespace); try requireDirectory(directory)
            for entry in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if entry.lastPathComponent == ".DS_Store" { continue }
                guard entry.lastPathComponent.count == 36, UUID(uuidString: entry.lastPathComponent) != nil else {
                    throw ReadingError.invalid("\(namespace) 中有待恢复的目录“\(entry.lastPathComponent)”，保留原库并停止复制。")
                }
                guard seenBookIDs.insert(entry.lastPathComponent).inserted else { throw ReadingError.invalid("书籍同时存在于书库和回收站，保留两份并停止复制，请先核对。") }
                _ = try storageProject(in: child(directory, entry.lastPathComponent), expectedID: entry.lastPathComponent, recoverTransactions: false)
            }
        }
        if allowed.contains(Self.membershipName) {
            let data = try readLimited(child(root, Self.membershipName), limit: 8 * 1_024 * 1_024)
            let membership = try JSONDecoder().decode(LibraryMembership.self, from: data)
            guard membership.version == 1, membership.removed.count <= 100_000 else { throw ReadingError.invalid("书库显示状态无效。") }
            for id in membership.removed.keys {
                guard id.count == 36, UUID(uuidString: id) != nil else { throw ReadingError.invalid("隐藏书籍身份无效。") }
                let active = try child(child(root, "books"), id)
                if files.fileExists(atPath: active.path) { try requireDirectory(active) }
                else { try requireDirectory(child(child(root, "trash"), id)) }
            }
        }
        for namespace in ["ConversationMemory", "Workspace", "ModelCatalog"] where allowed.contains(namespace) {
            try requireDirectory(child(root, namespace))
        }
    }

    private func checkedBackup(_ backup: URL) throws -> LibraryTransferManifest {
        try requireDirectory(backup)
        guard Set(try files.contentsOfDirectory(atPath: backup.path).filter { $0 != ".DS_Store" }) == ["library", "manifest.json"] else {
            throw ReadingError.invalid("备份包含未声明内容。")
        }
        let data = try readLimited(child(backup, "manifest.json"), limit: 32 * 1_024 * 1_024)
        let manifest = try JSONDecoder().decode(LibraryTransferManifest.self, from: data)
        guard manifest.version == 1, manifest.files.count <= 200_000, manifest.directories.count <= 200_000,
              Set(manifest.files.map(\.path)).count == manifest.files.count,
              Set(manifest.directories).count == manifest.directories.count,
              manifest.files.allSatisfy({ $0.bytes >= 0 && $0.bytes <= Self.transferFileLimit && $0.sha256.count == 64 && $0.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }) }) else {
            throw ReadingError.invalid("备份清单无效。")
        }
        let library = try child(backup, "library")
        let roots = try persistentRoots(in: library)
        guard roots == Set(try files.contentsOfDirectory(atPath: library.path).filter { $0 != ".DS_Store" }) else {
            throw ReadingError.invalid("备份含未知根目录，未恢复。")
        }
        try validateWholeLibrary(at: library)
        try requireMatchingTree(manifest, at: library)
        return manifest
    }

    private func transferDestination(_ destination: URL, disjointFrom source: URL) throws -> URL {
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty else { throw ReadingError.invalid("目标必须为本地目录。") }
        let target = destination.standardizedFileURL
        try requireDirectory(target.deletingLastPathComponent())
        guard !pathsOverlap(target, source) else { throw ReadingError.invalid("目标不能位于源目录内，也不能包含源目录。") }
        _ = try child(target.deletingLastPathComponent(), target.lastPathComponent)
        if files.fileExists(atPath: target.path) {
            try requireDirectory(target)
            guard try files.contentsOfDirectory(atPath: target.path).isEmpty else { throw ReadingError.invalid("目标文件夹不是空的，保留现有文件。") }
        }
        return target
    }

    private func pathsOverlap(_ a: URL, _ b: URL) -> Bool {
        let left = a.standardizedFileURL.resolvingSymlinksInPath().path
        let right = b.standardizedFileURL.resolvingSymlinksInPath().path
        return left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    private func commitTransfer(_ staging: URL, to target: URL) throws {
        // Never replace a nonempty target. Preserve the user's empty directory
        // alongside staging until the new tree is committed, then remove only
        // that verified empty directory; no previous library is removed.
        var previousEmpty: URL?
        if files.fileExists(atPath: target.path) {
            try requireDirectory(target)
            guard try files.contentsOfDirectory(atPath: target.path).isEmpty else { throw ReadingError.invalid("复制期间目标已出现文件，停止提交。") }
            let placeholder = try child(staging.deletingLastPathComponent(), ".readingbook-empty-" + UUID().uuidString)
            try requireVacant(placeholder)
            try files.moveItem(at: target, to: placeholder); previousEmpty = placeholder
        }
        do {
            try requireVacant(target)
            try files.moveItem(at: staging, to: target)
        } catch {
            if let previousEmpty, !files.fileExists(atPath: target.path) { try? files.moveItem(at: previousEmpty, to: target) }
            throw error
        }
        if let previousEmpty, (try? files.contentsOfDirectory(atPath: previousEmpty.path).isEmpty) == true {
            try? files.removeItem(at: previousEmpty)
        }
    }

    private func transferTree(at root: URL, roots: Set<String>?) throws -> LibraryTransferManifest {
        try requireDirectory(root)
        var directories: [String] = [], entries: [LibraryTransferEntry] = [], pending = [(root, "")], total: Int64 = 0
        while let (parent, relative) = pending.popLast() {
            for entry in try files.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]) {
                let name = entry.lastPathComponent
                if name == ".DS_Store" { continue }
                if relative.isEmpty, let roots, !roots.contains(name) { continue }
                guard entries.count + directories.count < 200_000 else { throw ReadingError.invalid("目录条目过多，未复制。") }
                let checked = try child(parent, name), path = relative.isEmpty ? name : relative + "/" + name
                let values = try checked.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw ReadingError.invalid("不复制符号链接：\(path)") }
                if values.isDirectory == true { directories.append(path); pending.append((checked, path)) }
                else {
                    guard values.isRegularFile == true, let size = values.fileSize, size >= 0,
                          Int64(size) <= Self.transferFileLimit, total <= Self.transferTotalLimit - Int64(size) else { throw ReadingError.invalid("目录包含特殊文件或超过安全大小上限：\(path)") }
                    total += Int64(size)
                    entries.append(LibraryTransferEntry(path: path, bytes: Int64(size), sha256: try storageHash(checked)))
                }
            }
        }
        return LibraryTransferManifest(createdAt: Date(), directories: directories.sorted(), files: entries.sorted { $0.path < $1.path })
    }

    private func transferPath(_ path: String, under root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("//") else { throw ReadingError.invalid("备份中的相对路径无效。") }
        return try path.split(separator: "/", omittingEmptySubsequences: false).reduce(root) { try child($0, String($1)) }
    }

    private func copyTransferTree(_ snapshot: LibraryTransferManifest, from source: URL, to destination: URL,
                                  progress: (@Sendable (LibraryTransferProgress) -> Void)?) throws {
        for directory in snapshot.directories.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
            _ = try ensureDirectory(transferPath(directory, under: destination))
        }
        for (index, entry) in snapshot.files.enumerated() {
            let original = try transferPath(entry.path, under: source), target = try transferPath(entry.path, under: destination)
            try requireVacant(target)
            try files.copyItem(at: original, to: target)
            guard Int64(try regularFileSize(target, limit: Int(Self.transferFileLimit))) == entry.bytes,
                  try storageHash(target) == entry.sha256 else { throw ReadingError.invalid("复制校验失败：\(entry.path)，原库保留。") }
            progress?(LibraryTransferProgress(stage: "复制", completedFiles: index + 1, totalFiles: snapshot.files.count))
        }
    }

    private func requireMatchingTree(_ expected: LibraryTransferManifest, at root: URL, roots: Set<String>? = nil) throws {
        let actual = try transferTree(at: root, roots: roots)
        guard expected.directories == actual.directories, expected.files == actual.files else {
            throw ReadingError.invalid("校验时文件集合或内容已变化，保留源文件并停止提交。")
        }
    }

    private func storageHash(_ url: URL) throws -> String {
        _ = try regularFileSize(url, limit: Int(Self.transferFileLimit))
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func requireSettledStorageTransactions(in directory: URL) throws {
        let documentMarker = try child(child(directory, ".journal"), "transaction.json")
        guard !files.fileExists(atPath: documentMarker.path) else { throw ReadingError.invalid("此书有待恢复的保存事务；源文件保留，请先重新打开书籍完成恢复。") }
        let changes = try child(directory, ".changes-journal")
        guard files.fileExists(atPath: changes.path) else { return }
        try requireDirectory(changes)
        for entry in try files.contentsOfDirectory(at: changes, includingPropertiesForKeys: nil) where entry.lastPathComponent != ".DS_Store" {
            let marker = try child(child(changes, entry.lastPathComponent), "transaction.json")
            guard !files.fileExists(atPath: marker.path) else { throw ReadingError.invalid("此书有待恢复的 AI 修改事务；未改写源库，请先完成恢复。") }
        }
    }

    private func storageBytes(in root: URL) throws -> Int64 {
        try requireDirectory(root)
        var pending = [root], total: Int64 = 0, count = 0
        while let directory = pending.popLast() {
            for entry in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
                count += 1
                guard count <= 200_000 else { throw ReadingError.invalid("目录条目过多。") }
                let checked = try child(directory, entry.lastPathComponent)
                let values = try checked.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw ReadingError.invalid("不统计符号链接目录。") }
                if values.isDirectory == true { pending.append(checked) }
                else {
                    guard values.isRegularFile == true, let size = values.fileSize, size >= 0,
                          Int64(size) <= Self.transferTotalLimit, total <= Self.transferTotalLimit - Int64(size) else { throw ReadingError.invalid("文件占用大小无效。") }
                    total += Int64(size)
                }
            }
        }
        return total
    }
}
