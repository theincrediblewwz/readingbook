import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if os(macOS)
import PDFKit
#if canImport(FoundationXML)
import FoundationXML
#endif
#endif

/// Imports original text into bounded, located units. Coverage records describe processing,
/// not a promise that a model understood every detail of the original book.
public enum BookImporter {
    static let maximumSourceBytes = 256 * 1_024 * 1_024
    static let maximumTextBytes = 64 * 1_024 * 1_024
    static let maximumUnits = 100_000

    public static func importFile(at url: URL) async throws -> BookProject {
        try await Task.detached(priority: .userInitiated) {
            #if os(macOS)
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            #endif
            return try importSynchronously(at: url)
        }.value
    }

    static func sha256(_ data: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        throw ReadingError.invalid("当前平台未提供 CryptoKit，不能核验原书 SHA-256。请使用 macOS 构建。")
        #endif
    }

    private static func importSynchronously(at url: URL) throws -> BookProject {
        guard url.isFileURL else { throw ReadingError.invalid("请选择本地原书文件。") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumSourceBytes else {
            throw ReadingError.invalid("原书必须是非空普通文件，且不超过 256 MiB；不接受符号链接。")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == size, data.count <= maximumSourceBytes else {
            throw ReadingError.invalid("读取时原书发生变化，或超过大小上限，请重新导入。")
        }
        let hash = try sha256(data)
        let title = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        let units: [SourceUnit]
        switch ext {
        case "txt", "md", "markdown":
            guard data.count <= maximumTextBytes else { throw ReadingError.invalid("文本原书超过 64 MiB，请先拆分为卷。") }
            units = try splitText(decodeText(data), chapter: title, markdownHeadings: ext != "txt")
        #if os(macOS)
        case "pdf": units = try importPDF(data, title: title)
        case "epub": units = try importEPUB(data)
        #endif
        default:
            throw ReadingError.invalid("当前构建支持 TXT、Markdown，以及 macOS 上的 PDF / EPUB；此格式尚不支持。")
        }
        guard !units.isEmpty, units.count <= maximumUnits else { throw ReadingError.invalid("无法生成阅读单元，或原书超过 100,000 个单元。") }
        var project = BookProject(title: title, originalName: url.lastPathComponent, sourceHash: hash, units: units)
        for unit in units {
            var entry = CoverageEntry()
            if let warning = unit.warning { entry.message = warning }
            project.coverage[unit.id] = entry
        }
        if ext == "epub" {
            project.audit.append(ToolAudit(name: "source_import", summary: "EPUB 按 spine 顺序提取，并收录未列入 spine 的 XHTML 附加材料；行号对应提取文本，原书样式不作为处理覆盖证据。"))
        }
        return project
    }

    private static func decodeText(_ data: Data) throws -> String {
        let bytes = [UInt8](data.prefix(4))
        let encoding: String.Encoding
        if bytes.starts(with: [0xff, 0xfe, 0, 0]) || bytes.starts(with: [0, 0, 0xfe, 0xff]) { encoding = .utf32 }
        else if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) { encoding = .utf16 }
        else { encoding = .utf8 }
        guard var result = String(data: data, encoding: encoding), !result.contains("\0") else {
            throw ReadingError.invalid("文本编码无法无损识别。请转换为 UTF-8 或带 BOM 的 UTF-16/32 后重试。")
        }
        if result.first == "\u{feff}" { result.removeFirst() }
        return result
    }

    /// Joining unit texts reproduces the newline-normalized text. Blank source lines and
    /// fragments of an exceptionally long line keep their original line coordinates.
    static func splitText(_ source: String, chapter: String, page: Int? = nil, warning: String? = nil,
                          startingOrder: Int = 0, markdownHeadings: Bool = false) throws -> [SourceUnit] {
        let text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")
        var result: [SourceUnit] = []
        var buffer = "", count = 0, firstLine: Int?, lastLine = 1, currentChapter = chapter
        func flush() throws {
            guard let start = firstLine else { return }
            let blank = buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let notices = [warning, blank ? "此单元只有空白；已登记原文位置，请核对是否为排版空白。" : nil].compactMap { $0 }
            let order = startingOrder + result.count
            result.append(SourceUnit(id: String(format: "unit-%06d", order + 1), order: order,
                                     chapter: currentChapter, page: page, lineStart: start, lineEnd: lastLine,
                                     text: buffer, warning: notices.isEmpty ? nil : notices.joined(separator: "\n")))
            guard result.count + startingOrder <= maximumUnits else { throw ReadingError.invalid("原书单元过多，请按卷导入。") }
            buffer = ""; count = 0; firstLine = nil
        }
        for (offset, line) in lines.enumerated() {
            try Task.checkCancellation()
            let number = offset + 1
            if markdownHeadings, line.range(of: "^#{1,6}\\s+", options: .regularExpression) != nil {
                try flush()
                currentChapter = line.drop(while: { $0 == "#" || $0.isWhitespace }).description
                if currentChapter.isEmpty { currentChapter = chapter }
            }
            let row = line + (offset + 1 < lines.count ? "\n" : "")
            if row.isEmpty { if firstLine == nil { firstLine = number }; lastLine = number }
            for character in row {
                if firstLine == nil { firstLine = number }
                lastLine = number
                buffer.append(character); count += 1
                if count == 5_000 { try flush() }
            }
        }
        try flush()
        return result
    }

    #if os(macOS)
    private static func importPDF(_ data: Data, title: String) throws -> [SourceUnit] {
        guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0, pdf.pageCount <= 20_000 else {
            throw ReadingError.invalid("PDF 损坏、被加密，或超过 20,000 页。请先解锁或分卷。")
        }
        var units: [SourceUnit] = [], extractedBytes = 0
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index) else { throw ReadingError.invalid("PDF 第 \(index + 1) 页不可读取，导入未完成。") }
            let text = page.string ?? ""
            extractedBytes += text.utf8.count
            guard extractedBytes <= maximumTextBytes else { throw ReadingError.invalid("PDF 提取文本超过 64 MiB，请按卷导入。") }
            let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let notice = blank
                ? "此 PDF 页没有可提取文本，可能是扫描页或空白页。首版尚未执行 OCR；此页必须人工核对，不能视为已完整读取。"
                : "PDF 提取保留页号；行号来自提取文本。图片、图表、公式、双栏顺序与脚注可能未正确提取，请对照原页核对。"
            units += try splitText(text, chapter: title, page: index + 1, warning: notice, startingOrder: units.count)
        }
        return units
    }

    private struct ArchiveEntry {
        let name: String
        let uncompressedSize: Int
        let directory: Bool
    }

    /// Read the ZIP central directory before allowing the system extractor to touch disk.
    /// ZIP64, encryption, duplicate paths, links, traversal and oversized archives fail closed.
    private static func archiveEntries(_ data: Data) throws -> [ArchiveEntry] {
        func u16(_ i: Int) throws -> Int {
            guard i >= 0, i + 2 <= data.count else { throw ReadingError.invalid("EPUB ZIP 目录被截断。") }
            return Int(data[i]) | Int(data[i + 1]) << 8
        }
        func u32(_ i: Int) throws -> Int { try u16(i) | u16(i + 2) << 16 }
        guard data.count >= 22 else { throw ReadingError.invalid("EPUB 不是有效 ZIP 文件。") }
        let lower = max(0, data.count - 65_557)
        var end: Int?
        for i in stride(from: data.count - 22, through: lower, by: -1) {
            if try u32(i) == 0x06054b50, try i + 22 + u16(i + 20) == data.count { end = i; break }
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0 else { throw ReadingError.invalid("不支持分卷 EPUB 或损坏的 ZIP 目录。") }
        let total = try u16(end + 10), diskTotal = try u16(end + 8)
        let centralSize = try u32(end + 12), centralOffset = try u32(end + 16)
        guard total > 0, total <= 10_000, total == diskTotal, total != 65_535,
              centralOffset != 0xffff_ffff, centralSize != 0xffff_ffff,
              centralOffset >= 0, centralOffset + centralSize == end else { throw ReadingError.invalid("EPUB ZIP64、文件数量或目录范围不受支持。") }
        var cursor = centralOffset, entries: [ArchiveEntry] = [], names = Set<String>(), expanded = 0
        for _ in 0..<total {
            guard try u32(cursor) == 0x02014b50 else { throw ReadingError.invalid("EPUB ZIP 中心目录损坏。") }
            let flags = try u16(cursor + 8), method = try u16(cursor + 10)
            let compressed = try u32(cursor + 20), size = try u32(cursor + 24)
            let nameLength = try u16(cursor + 28), extra = try u16(cursor + 30), comment = try u16(cursor + 32)
            let external = try u32(cursor + 38), local = try u32(cursor + 42)
            let next = cursor + 46 + nameLength + extra + comment
            guard next <= end, nameLength > 0, flags & ~0x080e == 0, [0, 8].contains(method),
                  size <= 32 * 1_024 * 1_024, compressed <= data.count,
                  size <= max(1, compressed) * 1_000, local < centralOffset else { throw ReadingError.invalid("EPUB 含加密、不支持的压缩或过大的文件。") }
            guard try u16(cursor + 34) == 0 else { throw ReadingError.invalid("不支持跨磁盘的 EPUB 文件项。") }
            let rawName = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard let name = String(data: rawName, encoding: .utf8) else { throw ReadingError.invalid("EPUB 文件名不是 UTF-8，无法安全提取。") }
            let directory = name.hasSuffix("/")
            let trimmed = directory ? String(name.dropLast()) : name
            try validateArchivePath(trimmed)
            guard names.insert(trimmed.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw ReadingError.invalid("EPUB 含重复或大小写冲突的文件路径。") }
            let mode = (external >> 16) & 0xf000
            guard mode == 0 || mode == 0x8000 || mode == 0x4000,
                  !(directory && mode == 0x8000), !(!directory && mode == 0x4000) else { throw ReadingError.invalid("EPUB 含符号链接或特殊文件。") }
            guard try u32(local) == 0x04034b50, try u16(local + 6) == flags, try u16(local + 8) == method else { throw ReadingError.invalid("EPUB 本地文件头与目录不一致。") }
            let localNameLength = try u16(local + 26), localExtra = try u16(local + 28)
            let payload = local + 30 + localNameLength + localExtra
            guard localNameLength == nameLength, payload + compressed <= centralOffset,
                  data.subdata(in: (local + 30)..<(local + 30 + localNameLength)) == rawName else { throw ReadingError.invalid("EPUB 文件路径或内容范围不一致。") }
            // Do not allow an extra field to override the inspected filename or file type
            // (Unicode-path, ASi Unix symlink and ZIP64 extras have such semantics).
            func checkExtras(_ start: Int, length: Int) throws {
                var position = start
                while position < start + length {
                    guard position + 4 <= start + length else { throw ReadingError.invalid("EPUB ZIP 扩展字段被截断。") }
                    let type = try u16(position), count = try u16(position + 2)
                    guard [0x5455, 0x7875, 0x000a, 0x5855, 0x7855].contains(type), position + 4 + count <= start + length else {
                        throw ReadingError.invalid("EPUB 含首版尚未安全支持的 ZIP 扩展字段。请使用普通 EPUB 重新导出。")
                    }
                    position += 4 + count
                }
            }
            try checkExtras(cursor + 46 + nameLength, length: extra)
            try checkExtras(local + 30 + localNameLength, length: localExtra)
            expanded += size
            guard expanded <= 256 * 1_024 * 1_024 else { throw ReadingError.invalid("EPUB 解压后超过 256 MiB。") }
            entries.append(ArchiveEntry(name: name, uncompressedSize: size, directory: directory))
            cursor = next
        }
        guard cursor == end else { throw ReadingError.invalid("EPUB 目录存在未识别数据。") }
        // A file may not also act as a parent directory.
        let fileNames = Set(entries.filter { !$0.directory }.map { $0.name.precomposedStringWithCanonicalMapping.lowercased() })
        for entry in entries {
            let parts = entry.name.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/")
            if parts.count > 1 {
                for count in 1..<parts.count where fileNames.contains(parts.prefix(count).joined(separator: "/")) {
                    throw ReadingError.invalid("EPUB 文件与目录路径冲突。")
                }
            }
        }
        return entries
    }

    private static func validateArchivePath(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 1_024, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ReadingError.invalid("EPUB 包含不安全的文件路径。")
        }
    }

    private static func importEPUB(_ data: Data) throws -> [SourceUnit] {
        let entries = try archiveEntries(data)
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("ReadingBook-EPUB-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temporary) } // Only this invocation's freshly allocated directory.
        // Extract the exact bytes inspected above, even if the user's original file changes.
        let archive = temporary.appendingPathComponent("input.epub")
        let extracted = temporary.appendingPathComponent("contents", isDirectory: true)
        try data.write(to: archive, options: .atomic)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: false)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", "-n", archive.path, "-d", extracted.path]
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ReadingError.invalid("系统解压 EPUB 失败（\(process.terminationStatus)）：\(String(decoding: output.prefix(2_000), as: UTF8.self))")
        }
        for entry in entries {
            let url = extracted.appendingPathComponent(entry.name)
            let resource = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard resource.isSymbolicLink != true,
                  (entry.directory ? resource.isDirectory == true : (resource.isRegularFile == true && resource.fileSize == entry.uncompressedSize)),
                  url.resolvingSymlinksInPath().path.hasPrefix(extracted.path + "/") else { throw ReadingError.invalid("EPUB 解压结果未通过路径与体积核验。") }
        }
        let expectedFiles = Set(entries.filter { !$0.directory }.map(\.name))
        func read(_ relative: String) throws -> Data {
            try validateArchivePath(relative)
            guard expectedFiles.contains(relative) else { throw ReadingError.invalid("EPUB 引用了不存在的文件：\(relative)") }
            return try Data(contentsOf: extracted.appendingPathComponent(relative))
        }
        guard try decodeText(read("mimetype")).trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip" else {
            throw ReadingError.invalid("此 ZIP 包没有有效的 EPUB mimetype 声明。")
        }
        let container = EPUBXML(kind: .container)
        try parseXML(read("META-INF/container.xml"), delegate: container)
        guard let opf = container.packagePath else { throw ReadingError.invalid("EPUB 缺少 OPF 包文件。") }
        try validateArchivePath(opf)
        let package = EPUBXML(kind: .package)
        try parseXML(read(opf), delegate: package)
        guard !package.spine.isEmpty else { throw ReadingError.invalid("EPUB 缺少可读 spine；不创建假完成的空书。") }
        let folder = opf.split(separator: "/").dropLast().map(String.init)
        func resolve(_ href: String) throws -> String {
            let raw = String(href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
            guard let decoded = raw.removingPercentEncoding, !decoded.hasPrefix("/"), !decoded.contains(":"), !decoded.contains("\\") else { throw ReadingError.invalid("EPUB 内容地址不安全。") }
            var parts = folder
            for part in decoded.split(separator: "/", omittingEmptySubsequences: false) {
                if part == ".." { guard !parts.isEmpty else { throw ReadingError.invalid("EPUB 内容地址越界。") }; parts.removeLast() }
                else if part != "." && !part.isEmpty { parts.append(String(part)) }
            }
            let path = parts.joined(separator: "/"); try validateArchivePath(path); return path
        }
        var readingOrder: [(String, Bool)] = [], seen = Set<String>()
        for id in package.spine {
            guard let item = package.items[id], item.mediaType == "application/xhtml+xml" || item.mediaType == "text/html" else { throw ReadingError.invalid("EPUB spine 包含缺失或非 XHTML 内容，无法完整导入。") }
            let path = try resolve(item.href)
            if seen.insert(path).inserted { readingOrder.append((path, false)) }
        }
        // Include footnotes/appendices omitted from spine instead of silently dropping them.
        for id in package.itemOrder {
            guard let item = package.items[id], ["application/xhtml+xml", "text/html"].contains(item.mediaType) else { continue }
            let path = try resolve(item.href)
            if seen.insert(path).inserted { readingOrder.append((path, true)) }
        }
        var units: [SourceUnit] = [], textBytes = 0
        for (index, chapter) in readingOrder.enumerated() {
            try Task.checkCancellation()
            let content = EPUBXML(kind: .content)
            try parseXML(read(chapter.0), delegate: content)
            guard content.hasBody else { throw ReadingError.invalid("EPUB 内容缺少 body：\(chapter.0)") }
            let text = content.text
            textBytes += text.utf8.count
            guard textBytes <= maximumTextBytes else { throw ReadingError.invalid("EPUB 提取文本超过 64 MiB。") }
            var warnings: [String] = []
            if chapter.1 { warnings.append("此内容不在 spine，作为附加材料收录，请核对其顺序与用途。") }
            warnings += content.warnings.sorted()
            units += try splitText(text, chapter: content.contentTitle.isEmpty ? "第 \(index + 1) 节 · \(chapter.0)" : content.contentTitle,
                                   warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"), startingOrder: units.count)
        }
        return units
    }

    private static func parseXML(_ data: Data, delegate: EPUBXML) throws {
        guard data.count <= 32 * 1_024 * 1_024 else { throw ReadingError.invalid("EPUB XML 内容过大。") }
        var string = try decodeText(data)
        guard string.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw ReadingError.invalid("EPUB XML 含实体声明，已拒绝解析。") }
        // Common XHTML named entities are converted to numeric references without loading a DTD.
        for (name, value) in ["nbsp": "&#160;", "mdash": "&#8212;", "ndash": "&#8211;", "hellip": "&#8230;", "ldquo": "&#8220;", "rdquo": "&#8221;", "lsquo": "&#8216;", "rsquo": "&#8217;"] {
            string = string.replacingOccurrences(of: "&\(name);", with: value)
        }
        let parser = XMLParser(data: Data(string.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil else { throw ReadingError.invalid("EPUB XML 解析失败：\(delegate.failure ?? parser.parserError?.localizedDescription ?? "格式无效")") }
    }

    private final class EPUBXML: NSObject, XMLParserDelegate {
        enum Kind { case container, package, content }
        struct Item { let href: String; let mediaType: String }
        let kind: Kind
        var packagePath: String?, items: [String: Item] = [:], itemOrder: [String] = [], spine: [String] = []
        var text = "", contentTitle = "", warnings = Set<String>(), failure: String?
        var hasBody = false
        private var inSpine = false, bodyDepth = 0, ignoredDepth = 0, titleDepth = 0, depth = 0
        init(kind: Kind) { self.kind = kind }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
            depth += 1
            guard depth <= 128 else { failure = "XML 嵌套超过 128 层。"; parser.abortParsing(); return }
            let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
            if kind == .container, name == "rootfile", packagePath == nil { packagePath = attributes["full-path"] }
            if kind == .package {
                if name == "item", let id = attributes["id"], let href = attributes["href"], let type = attributes["media-type"] {
                    if items[id] != nil { failure = "OPF manifest ID 重复。"; parser.abortParsing(); return }
                    items[id] = Item(href: href, mediaType: type); itemOrder.append(id)
                }
                if name == "spine" { inSpine = true }
                if name == "itemref", inSpine, let id = attributes["idref"] { spine.append(id) }
            }
            guard kind == .content else { return }
            if name == "title", bodyDepth == 0 { titleDepth = depth }
            if name == "body" { bodyDepth = depth; hasBody = true }
            guard bodyDepth > 0 else { return }
            if ignoredDepth > 0 { return }
            if name == "script" || name == "style" { ignoredDepth = depth; return }
            if ["p", "div", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "section", "blockquote", "pre"].contains(name) { text += "\n" }
            if name == "td" || name == "th" { text += "\t" }
            if name == "img" || name == "image" {
                text += "[图片：\(attributes["alt"] ?? attributes["title"] ?? "无替代文字")]"
                warnings.insert("本节含图片；替代文字不能代替图像内容，需对照原书核对。")
            }
            if name == "math" || name == "svg" { warnings.insert("本节含 MathML / SVG 图形或公式；文本提取不能保证保留含义，需对照原书核对。") }
            if name == "audio" || name == "video" { warnings.insert("本节含音视频内容，首版未转录，需另行核对。") }
            if name == "object" || name == "embed" || name == "iframe" { warnings.insert("本节含嵌入资源，首版只保留可提取的替代文本，需对照原书核对。") }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if titleDepth > 0, bodyDepth == 0 { contentTitle += string }
            if bodyDepth > 0, ignoredDepth == 0 { text += string }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
            if kind == .package, name == "spine" { inSpine = false }
            if kind == .content {
                if bodyDepth > 0, ignoredDepth == 0, ["p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "section", "blockquote", "pre"].contains(name) { text += "\n" }
                if ignoredDepth == depth { ignoredDepth = 0 }
                if titleDepth == depth { titleDepth = 0; contentTitle = contentTitle.trimmingCharacters(in: .whitespacesAndNewlines) }
                if bodyDepth == depth { bodyDepth = 0 }
            }
            depth -= 1
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if bodyDepth > 0, ignoredDepth == 0, let string = String(data: CDATABlock, encoding: .utf8) { text += string }
        }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
    }
    #endif
}
