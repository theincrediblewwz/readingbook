import Foundation

private struct ReadableFileRecord: Codable {
    var path: String
    var generatedHash: String
}
private struct ReadableManifest: Codable {
    var version = 1
    var files: [String: ReadableFileRecord] = [:]
}

extension LibraryRepository {
    func refreshReadableAfterCommit(id: String) {
        // Canonical data is already durable. Coalesce disposable Markdown
        // guides instead of delaying every tool-result publication with a
        // second full validation and regeneration of all readable files.
        guard pendingReadableRefresh[id] == nil else { return }
        pendingReadableRefresh[id] = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
            guard let self else { return }
            await self.finishReadableRefresh(id: id)
        }
    }

    private func finishReadableRefresh(id: String) {
        pendingReadableRefresh[id] = nil
        _ = try? refreshReadableViews(id: id)
    }

    func flushPendingReadableRefreshes() {
        let ids = Array(pendingReadableRefresh.keys)
        for task in pendingReadableRefresh.values { task.cancel() }
        pendingReadableRefresh.removeAll()
        for id in ids { _ = try? refreshReadableViews(id: id) }
    }

    /// Derived views have stable Chinese names. They never become the writer for
    /// source, Markdown, IDs or analysis. A hand edit earns a separate new draft.
    @discardableResult
    public func refreshReadableViews(id: String, archived: Bool = false) throws -> URL {
        let directory: URL
        if archived { directory = try archivedBookDirectory(id, mustExist: true) }
        else { directory = try bookDirectory(id, mustExist: true) }
        let project = try readProject(in: directory)
        guard project.id == id else { throw ReadingError.invalid("导览身份与项目目录不一致。") }
        try validate(project)
        let pieces = readablePieces(project, absoluteDirectory: nil)
        var manifest = try readableManifest(in: directory)
        for (name, content) in pieces where name != "阅读导航.md" {
            _ = try writeManagedReadable(content, name: name, directory: directory, manifest: &manifest)
        }
        var guideContent = pieces.first(where: { $0.0 == "阅读导航.md" })?.1 ?? ""
        for (name, record) in manifest.files where name.hasPrefix("AI分析/") && record.path != name {
            guideContent = guideContent.replacingOccurrences(of: "(" + readableLink(name) + ")", with: "(" + readableLink(record.path) + ")")
        }
        let guide = try writeManagedReadable(guideContent, name: "阅读导航.md", directory: directory, manifest: &manifest)
        try saveReadableManifest(manifest, in: directory)
        return guide
    }

    @discardableResult
    public func refreshReadableLibraryIndex() throws -> URL {
        _ = try booksDirectory(); _ = try trashDirectory()
        let membership = try libraryMembership()
        var content = "# 书库目录\n\n点击书名查看原书、笔记与 AI 分析导览。这里是自动生成的目录，原书与笔记仍以各自文件为准。\n\n"
        for (name, heading) in [("books", "书籍"), ("trash", "App 回收站")] {
            content += "## \(heading)\n\n"
            let parent = try child(rootURL, name)
            let entries = try files.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            if entries.isEmpty { content += "暂无内容。\n\n" }
            for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
                guard let project = try? readProject(in: child(parent, entry.lastPathComponent)), project.id == entry.lastPathComponent else { continue }
                let suffix = membership.removed[project.id] == nil || name == "trash" ? "" : " · 已从书库移除，文件保留"
                let guideRecord = try? readableManifest(in: entry).files["阅读导航.md"]
                let guide = guideRecord?.path ?? "阅读导航.md"
                content += "- [\(readableLabel(project.title))](\(readableLink(name + "/" + project.id + "/" + guide)))\(suffix)\n"
            }
            content += "\n"
        }
        var manifest = try readableManifest(in: rootURL)
        let url = try writeManagedReadable(content, name: "书库目录.md", directory: rootURL, manifest: &manifest)
        try saveReadableManifest(manifest, in: rootURL)
        return url
    }

    /// A readable export contains analysis and links to the current canonical
    /// files, not duplicated books or note bodies. Whole-library backup is the
    /// separate portable, verifiable operation.
    public func exportReadableLibrary(to destination: URL) throws -> URL {
        guard destination.isFileURL else { throw ReadingError.invalid("可读导出必须选择本地文件夹。") }
        let target = destination.standardizedFileURL
        let resolved = target.resolvingSymlinksInPath().path, source = rootURL.path
        guard resolved != source, !resolved.hasPrefix(source + "/"), !source.hasPrefix(resolved + "/") else {
            throw ReadingError.invalid("可读导出需位于当前书库之外。")
        }
        try requireVacant(target); try requireDirectory(target.deletingLastPathComponent())
        let staging = try temporaryDirectory(near: target.deletingLastPathComponent(), prefix: ".readingbook-readable-")
        defer { removeOwnTemporary(staging) }
        let membership = try libraryMembership()
        var index = "# 可读书库导出\n\n这是 AI 分析的可读副本，原书与笔记链接指向当前书库。迁移或恢复全部内容请使用整库备份。\n\n"
        for namespace in ["books", "trash"] {
            let parent: URL
            if namespace == "books" { parent = try booksDirectory() } else { parent = try trashDirectory() }
            for entry in try files.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if entry.lastPathComponent == ".DS_Store" { continue }
                let project = try storageProject(in: child(parent, entry.lastPathComponent), expectedID: entry.lastPathComponent)
                let name = readableFolder(project.title) + "-" + project.id
                let directory = try ensureDirectory(child(staging, name))
                for (path, content) in readablePieces(project, absoluteDirectory: entry) {
                    let url = try readablePath(path, under: directory)
                    _ = try ensureDirectory(url.deletingLastPathComponent())
                    try atomicWrite(Data(content.utf8), to: url)
                }
                let state = namespace == "trash" ? " · 回收站" : (membership.removed[project.id] != nil ? " · 已移除" : "")
                index += "- [\(readableLabel(project.title))](\(readableLink(name + "/阅读导航.md")))\(state)\n"
            }
        }
        try atomicWrite(Data(index.utf8), to: child(staging, "书库目录.md"))
        try requireVacant(target); try files.moveItem(at: staging, to: target)
        return target
    }

    private func readableManifest(in directory: URL) throws -> ReadableManifest {
        let url = try child(directory, ".readingbook-readable.json")
        guard files.fileExists(atPath: url.path) else { return ReadableManifest() }
        let manifest = try JSONDecoder().decode(ReadableManifest.self, from: readLimited(url, limit: 1_024 * 1_024))
        guard manifest.version == 1, manifest.files.count <= 32 else { throw ReadingError.invalid("导览生成记录无效，保留现有文件。") }
        for (name, record) in manifest.files {
            let allowed: Set<String> = ["阅读导航.md", "书库目录.md", "AI分析/阅读摘要.md", "AI分析/对象与事件.md", "AI分析/关系与组件.md", "AI分析/问答.md"]
            let base = (name as NSString).deletingPathExtension
            guard allowed.contains(name), record.path == name || record.path.hasPrefix(base + " · AI新稿"),
                  record.path.hasSuffix(".md"), record.generatedHash.count == 64,
                  record.generatedHash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw ReadingError.invalid("导览记录无效。") }
            _ = try readablePath(name, under: directory)
            _ = try readablePath(record.path, under: directory)
        }
        return manifest
    }

    private func saveReadableManifest(_ manifest: ReadableManifest, in directory: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(manifest), url = try child(directory, ".readingbook-readable.json")
        if files.fileExists(atPath: url.path), try readLimited(url, limit: 1_024 * 1_024) == bytes { return }
        try atomicWrite(bytes, to: url)
    }

    private func writeManagedReadable(_ content: String, name: String, directory: URL, manifest: inout ReadableManifest) throws -> URL {
        let bytes = Data(content.utf8), hash = try BookImporter.sha256(bytes)
        var path = manifest.files[name]?.path ?? name
        var target = try readablePath(path, under: directory)
        if files.fileExists(atPath: target.path) {
            let existing = try readLimited(target, limit: 16 * 1_024 * 1_024), existingHash = try BookImporter.sha256(existing)
            if existingHash == hash {
                manifest.files[name] = ReadableFileRecord(path: path, generatedHash: hash)
                return target
            }
            if manifest.files[name]?.generatedHash != existingHash {
                // Never replace an unregistered or hand-edited Markdown file.
                let base = (name as NSString).deletingPathExtension
                var candidates = [base + " · AI新稿.md", base + " · AI新稿-" + String(hash.prefix(12)) + ".md"]
                var chosen: (String, URL)?
                while !candidates.isEmpty {
                    let candidate = candidates.removeFirst(), url = try readablePath(candidate, under: directory)
                    if !files.fileExists(atPath: url.path) { chosen = (candidate, url); break }
                    if try BookImporter.sha256(readLimited(url, limit: 16 * 1_024 * 1_024)) == hash { chosen = (candidate, url); break }
                }
                guard let chosen else { throw ReadingError.invalid("导览文件已有手改版本，请保留并另行导出。") }
                path = chosen.0; target = chosen.1
            }
        }
        _ = try ensureDirectory(target.deletingLastPathComponent())
        try atomicWrite(bytes, to: target)
        manifest.files[name] = ReadableFileRecord(path: path, generatedHash: hash)
        return target
    }

    private func readablePath(_ path: String, under root: URL) throws -> URL {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(pieces.count), pieces.count == 1 || pieces.first == "AI分析" else { throw ReadingError.invalid("可读导览路径无效。") }
        return try pieces.reduce(root) { try child($0, String($1)) }
    }

    private func readablePieces(_ project: BookProject, absoluteDirectory: URL?) -> [(String, String)] {
        let note = "> App 自动生成的只读导览；原书、笔记和结构化记录仍是真源。手改文件会保留，后续生成稿另存。\n\n"
        func target(_ relative: String) -> String {
            if let absoluteDirectory { return absoluteDirectory.appendingPathComponent(relative).absoluteString }
            return readableLink(relative)
        }
        var guide = "# \(readableLabel(project.title))\n\n" + note
        guide += "[打开原书](\(target("source/" + project.originalName))) · [笔记文件夹](\(target("docs")))\n\n"
        guide += "## 笔记与保存的回答\n\n"
        if project.documents.isEmpty { guide += "暂无保存的 Markdown。\n\n" }
        for document in project.documents {
            guide += "- [\(readableLabel(document.title))](\(target(document.relativePath)))" + (document.trashedAt != nil ? " · 已回收" : "") + "\n"
        }
        guide += "\n## AI 分析与书本要素\n\n"
        for name in ["阅读摘要", "对象与事件", "人物背景", "句旁译注", "关系与组件", "问答"] { guide += "- [\(name)](\(readableLink("AI分析/" + name + ".md")))\n" }
        guide += "\n项目 ID：`\(project.id)`\n\n[完整结构化记录](\(target("project.json")))包含 OCR、分析检查点、证据及恢复记录；本导览不改写它们。\n"
        var summary = "# 阅读摘要\n\n" + note
        summary += "处理进度：\(project.coverage.values.filter { $0.status == .completed }.count)/\(project.units.count) 个内容单元完成处理；不表示理解无遗漏。\n\n"
        if let plan = project.plan { summary += "## 阅读计划\n\n\(plan.rationale)\n\n" + plan.focus.map { "- " + $0 }.joined(separator: "\n") + "\n\n" }
        for synthesis in project.syntheses { summary += "## \(readableLabel(synthesis.title))\n\n\(synthesis.markdown)\n\n" }
        for insight in project.insights { summary += "## 阅读记录\n\n\(insight.markdown)\n\n" }
        if project.syntheses.isEmpty && project.insights.isEmpty { summary += "暂无保存的 AI 摘要。\n" }
        let names = Dictionary(uniqueKeysWithValues: project.entities.map { ($0.id, $0.name) })
        let unitIndex = Dictionary(uniqueKeysWithValues: project.units.map { ($0.id, $0) })
        func label(_ id: String) -> String { (names[id] ?? id) + " (`" + id + "`)" }
        var objects = "# 对象与事件\n\n" + note
        for entity in project.entities {
            objects += "## \(readableLabel(entity.name))\n\nID：`\(entity.id)` · 类型：`\(entity.typeID)`\n\n\(entity.summary)\n\n"
            for (key, value) in entity.properties.sorted(by: { $0.key < $1.key }) { objects += "- \(readableLabel(key))：\(value)\n" }
            if !entity.aliases.isEmpty { objects += "- 别名：\(entity.aliases.joined(separator: "、"))\n" }
            if let latitude = entity.latitude, let longitude = entity.longitude { objects += "- 坐标：\(latitude), \(longitude)\n" }
            objects += readableEvidence(entity.evidence, units: unitIndex, originalName: project.originalName, absoluteDirectory: absoluteDirectory)
        }
        for event in project.events {
            objects += "## \(readableLabel(event.name))\n\nID：`\(event.id)` · \(event.dateText)\n\n\(event.summary)\n\n"
            objects += "- 参与者：\(event.participantIDs.map(label).joined(separator: "、"))\n- 地点：\(event.placeIDs.map(label).joined(separator: "、"))\n"
            objects += readableEvidence(event.evidence, units: unitIndex, originalName: project.originalName, absoluteDirectory: absoluteDirectory)
        }
        if project.entities.isEmpty && project.events.isEmpty { objects += "暂无保存的对象或事件。\n" }
        var relations = "# 关系与组件\n\n" + note
        for relation in project.relations { relations += "- \(label(relation.fromID)) → **\(readableLabel(relation.label))** → \(label(relation.toID))\n" + readableEvidence(relation.evidence, units: unitIndex, originalName: project.originalName, absoluteDirectory: absoluteDirectory) }
        relations += "\n## 组件\n\n"
        for view in project.views { relations += "- \(readableLabel(view.title)) · \(view.kind.title) · `\(view.id)`\n" }
        relations += "\n## 导图节点与挂载\n\n"
        for node in project.nodes { relations += "- \(readableLabel(node.title ?? names[node.targetID] ?? node.targetID)) · 节点 `\(node.id)` · 坐标 (\(node.x), \(node.y)) · 挂载：\((node.documentIDs ?? []).joined(separator: "、"))\n" }
        for edge in project.edges { relations += "- `\(edge.fromID)` → \(readableLabel(edge.label)) → `\(edge.toID)`\n" }
        var chats = "# 问答\n\n" + note
        if project.chats.isEmpty { chats += "暂无已保存的问答。\n" }
        for message in project.chats {
            let role = message.role == "user" ? "读者" : (message.role == "assistant" ? "AI" : message.role)
            chats += "## \(readableLabel(role))\n\n\(message.content)\n\n" + readableEvidence(message.evidence, units: unitIndex, originalName: project.originalName, absoluteDirectory: absoluteDirectory)
        }
        var backgrounds = "# 人物与事件背景\n\nAI 生成的讲解与背景补充，不等于原书所载，也不表示外部资料已经核验。书中对象、原文出处与用户笔记分别保留。\n\n"
        for record in ReadingKnowledgeRuntime.readableBackgrounds(in: project) {
            backgrounds += "## \(readableLabel(record.title))\n\n\(record.markdown)\n\n_模型：\(readableLabel(record.model))；对象 ID：`\(record.objectID)`_\n\n"
            backgrounds += readableEvidence(record.evidence, units: unitIndex, originalName: project.originalName, absoluteDirectory: absoluteDirectory)
        }
        var translations = "# 句旁译注\n\n" + note
        let anchors = Dictionary((project.readingExperience?.anchors ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for layer in (project.readingExperience?.layers ?? []) where layer.kind == "translation" {
            translations += "## \(readableLabel(layer.title))\n\n\(layer.markdown)\n\n_\(readableLabel(layer.sourceLabel))_\n"
            translations += readableEvidence(layer.sourceAnchorIDs.compactMap { anchors[$0] }.map { Evidence(unitID: $0.unitID, quote: $0.quote) }, units: unitIndex, originalName: project.originalName, absoluteDirectory: absoluteDirectory)
        }
        return [("阅读导航.md", guide), ("AI分析/阅读摘要.md", summary), ("AI分析/对象与事件.md", objects),
                ("AI分析/人物背景.md", backgrounds), ("AI分析/句旁译注.md", translations),
                ("AI分析/关系与组件.md", relations), ("AI分析/问答.md", chats)].map { ($0.0, boundedReadable($0.1)) }
    }

    private func readableEvidence(_ evidence: [Evidence], units: [String: SourceUnit], originalName: String, absoluteDirectory: URL?) -> String {
        var content = ""
        for item in evidence {
            let unit = units[item.unitID], relative = "source/" + originalName
            let source = absoluteDirectory?.appendingPathComponent(relative).absoluteString ?? readableLink("../" + relative)
            let anchor = unit?.page.map { "#page=\($0)" } ?? ""
            content += "\n> \(item.quote.replacingOccurrences(of: "\n", with: "\n> "))\n\n[\(readableLabel(unit?.locator ?? item.unitID))](\(source + anchor))\n\n"
        }
        return content
    }

    private func readableLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ")
    }
    private func readableLink(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))) ?? ""
    }
    private func readableFolder(_ title: String) -> String {
        let cleaned = title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"/\\:".unicodeScalars.contains($0) }.prefix(50).map { String($0) }.joined()
        return cleaned.isEmpty ? "书籍" : cleaned
    }
    private func boundedReadable(_ content: String) -> String {
        let bytes = Data(content.utf8), limit = 4 * 1_024 * 1_024
        guard bytes.count > limit else { return content }
        var end = limit
        while end > limit - 4 {
            if let prefix = String(data: bytes.prefix(end), encoding: .utf8) {
                return prefix + "\n\n---\n\n此可读导览已达 4 MiB。完整内容仍保存在项目的 project.json，未删除或修改；可在 App 分范围查看。\n"
            }
            end -= 1
        }
        return "可读导览过大，请在 App 分范围查看；完整结构化记录保留。\n"
    }
}
