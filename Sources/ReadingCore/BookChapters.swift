import Foundation
#if os(macOS)
import PDFKit
import CoreGraphics
#endif

/// Unit-local, half-open source coordinates. They never identify rendered text,
/// and never alter the original units or their stable IDs.
public struct ReadingSourceRange: Codable, Hashable, Sendable {
    public var unitID: String
    public var startUTF16: Int
    public var endUTF16: Int
    public init(unitID: String, startUTF16: Int, endUTF16: Int) {
        self.unitID = unitID; self.startUTF16 = startUTF16; self.endUTF16 = endUTF16
    }
    private func stringRange(in unit: SourceUnit) throws -> Range<String.Index> {
        let native = unit.text as NSString
        guard unit.id == unitID, startUTF16 >= 0, endUTF16 > startUTF16,
              endUTF16 <= native.length,
              let range = Range(NSRange(location: startUTF16, length: endUTF16 - startUTF16), in: unit.text),
              (startUTF16 == 0 || native.rangeOfComposedCharacterSequence(at: startUTF16).location == startUTF16),
              (endUTF16 == native.length || native.rangeOfComposedCharacterSequence(at: endUTF16).location == endUTF16) else {
            throw ReadingError.invalid("章节范围与原文位置不一致。")
        }
        return range
    }
    public func validate(in unit: SourceUnit) throws { _ = try stringRange(in: unit) }
    public func text(in unit: SourceUnit) throws -> String {
        let range = try stringRange(in: unit)
        return String(unit.text[range])
    }
    public func text(in project: BookProject) throws -> String {
        let matches = project.units.filter { $0.id == unitID }
        guard matches.count == 1, let unit = matches.first else { throw ReadingError.invalid("章节原文单元不存在或重复。") }
        return try text(in: unit)
    }
}

/// A source-versioned copy of native PDF bookmarks. Unresolved native targets
/// stay visible for navigation, but cannot authorize chapter source reads.
public struct BookChapterOutline: Codable, Hashable, Sendable {
    public var version = 1
    public var sourceHash: String
    public var sourceFingerprint: String
    public var scannedUnitCount: Int
    public var totalUnitCount: Int
    public var entries: [BookOutlineEntry]
    public var complete: Bool { scannedUnitCount == totalUnitCount }
    public init(sourceHash: String, sourceFingerprint: String, scannedUnitCount: Int, totalUnitCount: Int, entries: [BookOutlineEntry]) {
        self.sourceHash = sourceHash; self.sourceFingerprint = sourceFingerprint
        self.scannedUnitCount = scannedUnitCount; self.totalUnitCount = totalUnitCount; self.entries = entries
    }
}

public struct BookChapterRange: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var level: Int
    public var ranges: [ReadingSourceRange]
    public var isComplete: Bool
    public init(id: String, title: String, level: Int, ranges: [ReadingSourceRange], isComplete: Bool) {
        self.id = id; self.title = title; self.level = level; self.ranges = ranges; self.isComplete = isComplete
    }
}

public struct BookChapterIndex: Codable, Hashable, Sendable {
    public var sourceFingerprint: String
    /// Hierarchical ranges: a parent ends at its next sibling or ancestor.
    public var chapters: [BookChapterRange]
    /// Non-overlapping work partitions, using the most specific known heading.
    public var segments: [BookChapterRange]
    public init(sourceFingerprint: String, chapters: [BookChapterRange], segments: [BookChapterRange]) {
        self.sourceFingerprint = sourceFingerprint; self.chapters = chapters; self.segments = segments
    }
    public func chapter(unitID: String, offsetUTF16: Int? = nil) throws -> BookChapterRange {
        let matching = segments.filter { segment in segment.ranges.contains { range in
            range.unitID == unitID && (offsetUTF16.map { range.startUTF16 <= $0 && $0 < range.endUTF16 } ?? true)
        } }
        guard matching.count == 1, let segment = matching.first else {
            throw ReadingError.invalid("这一页包含多个章节，请先点选章节标题或章内一句原文。")
        }
        guard let chapter = chapters.first(where: { $0.id == segment.id }) ?? (segment.id.hasPrefix("chapter-preface-") ? segment : nil), chapter.isComplete else {
            throw ReadingError.invalid("本章末尾尚未确定，请先继续整理目录，或改用当前页。")
        }
        return chapter
    }
}

public enum BookChapterRuntime {
    /// Structural validation only. A stale source-versioned cache may be retained
    /// safely on ordinary saves; index(in:) proves raw source before using it.
    public static func validateStored(_ outline: BookChapterOutline?) throws {
        guard let outline else { return }
        guard outline.version == 1, !outline.sourceHash.isEmpty, outline.sourceHash.count <= 128,
              outline.sourceFingerprint.count == 64, outline.sourceFingerprint.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              (1...BookImporter.maximumUnits).contains(outline.totalUnitCount),
              (0...outline.totalUnitCount).contains(outline.scannedUnitCount), outline.entries.count <= 10_000,
              Set(outline.entries.map(\.id)).count == outline.entries.count else {
            throw ReadingError.invalid("原书章节目录的来源或数量无效。")
        }
        for entry in outline.entries {
            guard !entry.id.isEmpty, entry.id.count <= 128, !entry.title.isEmpty, entry.title.count <= 1000,
                  !entry.title.utf8.contains(0), (0...32).contains(entry.level),
                  entry.page.map({ (1...20_000).contains($0) }) ?? true,
                  entry.destinationX.map(\.isFinite) ?? true, entry.destinationY.map(\.isFinite) ?? true,
                  (entry.destinationX == nil) == (entry.destinationY == nil) else {
                throw ReadingError.invalid("原书章节目录含无效条目。")
            }
            if let anchor = entry.anchor {
                guard anchor.sourceHash == outline.sourceHash, !anchor.unitID.isEmpty, anchor.unitID.utf8.count <= 128,
                      !anchor.quote.isEmpty, anchor.quote.count <= 4096,
                      anchor.prefix.utf8.count <= 1024, anchor.suffix.utf8.count <= 1024,
                      anchor.unitTextHash.count == 64, (anchor.utf16Location ?? -1) >= 0, (anchor.utf16Length ?? 0) > 0 else {
                    throw ReadingError.invalid("原书章节目录缺少可靠原文位置。")
                }
            }
        }
    }

    public static func index(in project: BookProject) throws -> BookChapterIndex? {
        guard project.originalBookOutline != nil || project.generatedOutline != nil else { return nil }
        let fingerprint = try BookOutlineRuntime.fingerprint(in: project)
        if let native = project.originalBookOutline,
           native.sourceHash == project.sourceHash, native.sourceFingerprint == fingerprint,
           native.totalUnitCount == project.units.count {
            try validateStored(native)
            if let index = try build(entries: native.entries, scanned: native.scannedUnitCount, complete: native.complete,
                                     fingerprint: fingerprint, in: project) { return index }
        }
        if let generated = project.generatedOutline, generated.sourceHash == project.sourceHash,
           generated.sourceFingerprint == fingerprint, generated.totalUnitCount == project.units.count {
            try BookOutlineRuntime.validateStored(generated)
            return try build(entries: generated.entries, scanned: generated.scannedUnitCount, complete: generated.complete,
                             fingerprint: fingerprint, in: project, generated: true)
        }
        return nil
    }

    /// Old text/EPUB chapters remain contiguous ranges, including repeated names.
    /// Legacy PDFs that only carry the book title or synthetic page labels do not
    /// acquire whole-book chapter permission from that importer placeholder.
    public static func legacyChapters(in project: BookProject) throws -> [BookChapterRange] {
        let units = project.units.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        guard Set(units.map(\.id)).count == units.count else { throw ReadingError.invalid("原文单元身份重复。") }
        var groups: [[SourceUnit]] = []
        for unit in units {
            try Task.checkCancellation()
            if groups.last?.last?.chapter.utf8.elementsEqual(unit.chapter.utf8) == true { groups[groups.count - 1].append(unit) }
            else { groups.append([unit]) }
        }
        if project.originalName.lowercased().hasSuffix(".pdf") {
            let real = groups.compactMap(\.first).map(\.chapter)
            guard !real.isEmpty, real.allSatisfy({ title in
                !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title != project.title &&
                title.range(of: "^第\\s*[0-9０-９一二三四五六七八九十百千]+\\s*页$", options: .regularExpression) == nil
            }) else { return [] }
        }
        return try groups.compactMap { group in
            guard let first = group.first else { return nil }
            let ranges = group.filter { !$0.text.isEmpty }.map { ReadingSourceRange(unitID: $0.id, startUTF16: 0, endUTF16: $0.text.utf16.count) }
            guard !ranges.isEmpty else { return nil }
            let id = "legacy-chapter-" + String(try BookImporter.sha256(Data(first.id.utf8)).prefix(48))
            return BookChapterRange(id: id, title: String(first.chapter.prefix(1000)), level: 0, ranges: ranges, isComplete: true)
        }
    }
    public static func legacyChapter(in project: BookProject, unitID: String) throws -> BookChapterRange? {
        try legacyChapters(in: project).first { $0.ranges.contains { $0.unitID == unitID } }
    }

    /// Validate the frozen hierarchy itself, without rebuilding it from a newer
    /// live directory. A new bookmark publication cannot enlarge a running task.
    public static func validate(index: BookChapterIndex, in project: BookProject) throws {
        guard index.sourceFingerprint == (try BookOutlineRuntime.fingerprint(in: project)),
              (1...10_000).contains(index.chapters.count), (1...10_001).contains(index.segments.count),
              Set(index.chapters.map(\.id)).count == index.chapters.count,
              Set(index.segments.map(\.id)).count == index.segments.count else {
            throw ReadingError.invalid("冻结章节的来源或数量已变化，已保存分析保留。")
        }
        let units = project.units.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        guard Set(units.map(\.id)).count == units.count else { throw ReadingError.invalid("冻结章节原文身份重复。") }
        var origins: [String: Int] = [:], byID: [String: SourceUnit] = [:], total = 0
        for unit in units { origins[unit.id] = total; byID[unit.id] = unit; total += unit.text.utf16.count }
        func span(_ chapter: BookChapterRange) throws -> (start: Int, end: Int) {
            guard !chapter.id.isEmpty, chapter.id.count <= 128, !chapter.title.isEmpty, chapter.title.count <= 1000,
                  (0...32).contains(chapter.level), !chapter.ranges.isEmpty, chapter.ranges.count <= units.count,
                  Set(chapter.ranges.map(\.unitID)).count == chapter.ranges.count else {
                throw ReadingError.invalid("冻结章节范围无效。")
            }
            var start: Int?, end: Int?
            for range in chapter.ranges {
                try Task.checkCancellation()
                guard let origin = origins[range.unitID], let unit = byID[range.unitID] else { throw ReadingError.invalid("冻结章节原文不存在。") }
                try range.validate(in: unit)
                let left = origin + range.startUTF16, right = origin + range.endUTF16
                guard end == nil || end == left else { throw ReadingError.invalid("冻结章节原文不连续。") }
                if start == nil { start = left }; end = right
            }
            return (start!, end!)
        }
        let chapterSpans = try index.chapters.map(span), segmentSpans = try index.segments.map(span)
        let frontier = segmentSpans.last!.end
        guard frontier <= total else { throw ReadingError.invalid("冻结章节超出原文。") }
        var nextSibling = [Int?](repeating: nil, count: index.chapters.count), stack: [Int] = []
        for position in index.chapters.indices {
            try Task.checkCancellation()
            if position > 0 {
                guard chapterSpans[position].start >= chapterSpans[position - 1].start,
                      chapterSpans[position].start != chapterSpans[position - 1].start || index.chapters[position].level > index.chapters[position - 1].level else {
                    throw ReadingError.invalid("冻结章节次序或重叠起点无效。")
                }
            }
            while let previous = stack.last, index.chapters[previous].level >= index.chapters[position].level {
                nextSibling[previous] = position; stack.removeLast()
            }
            stack.append(position)
        }
        for position in index.chapters.indices {
            if let next = nextSibling[position] {
                guard chapterSpans[position].end == chapterSpans[next].start, index.chapters[position].isComplete else {
                    throw ReadingError.invalid("冻结章节未遵守原有层级边界。")
                }
            } else {
                let expected = index.chapters[position].isComplete ? total : frontier
                guard chapterSpans[position].end == expected else { throw ReadingError.invalid("冻结章节末尾与范围不一致。") }
            }
        }
        var expectedSegments: [(id: String, title: String, level: Int, start: Int, end: Int, complete: Bool)] = []
        if chapterSpans[0].start > 0 {
            expectedSegments.append(("chapter-preface-" + String(index.sourceFingerprint.prefix(32)), "章前内容", 0, 0, chapterSpans[0].start, true))
        }
        for position in index.chapters.indices {
            let end = position + 1 < index.chapters.count ? chapterSpans[position + 1].start : frontier
            if chapterSpans[position].start < end {
                let chapter = index.chapters[position]
                expectedSegments.append((chapter.id, chapter.title, chapter.level, chapterSpans[position].start, end,
                                         position + 1 < index.chapters.count || chapter.isComplete))
            }
        }
        guard expectedSegments.count == index.segments.count else { throw ReadingError.invalid("冻结章节分区有缺漏。") }
        for position in index.segments.indices {
            let expected = expectedSegments[position], segment = index.segments[position], actual = segmentSpans[position]
            guard segment.id == expected.id, segment.title.utf8.elementsEqual(expected.title.utf8), segment.level == expected.level,
                  actual.start == expected.start, actual.end == expected.end, segment.isComplete == expected.complete else {
                throw ReadingError.invalid("冻结章节分区交叠或超出原有章节。")
            }
        }
    }

    private struct Position {
        var entry: BookOutlineEntry
        var start: Int
    }
    private static func build(entries: [BookOutlineEntry], scanned: Int, complete: Bool, fingerprint: String,
                              in project: BookProject, generated: Bool = false) throws -> BookChapterIndex? {
        let units = project.units.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        guard Set(units.map(\.id)).count == units.count, units.map(\.id) == project.units.map(\.id),
              (0...units.count).contains(scanned) else { throw ReadingError.invalid("章节目录的原文顺序已变化。") }
        var offsets: [Int] = [0], unitIndices: [String: Int] = [:]
        for (index, unit) in units.enumerated() {
            try Task.checkCancellation(); offsets.append(offsets.last! + unit.text.utf16.count); unitIndices[unit.id] = index
        }
        let frontier = offsets[scanned]
        var positions: [Position] = [], resolvers: [String: (SourceAnchor) throws -> ResolvedSourceAnchor] = [:]
        for entry in entries {
            try Task.checkCancellation()
            if entry.page == nil { continue } // External/non-source nodes remain navigation only.
            guard let anchor = entry.anchor, let index = unitIndices[anchor.unitID], index < scanned else {
                throw ReadingError.invalid("目录章首尚未与原文精确对应，请改用当前页；原目录仍可跳转。")
            }
            let resolver: (SourceAnchor) throws -> ResolvedSourceAnchor
            if let cached = resolvers[anchor.unitID] { resolver = cached }
            else {
                let unit = units[index]
                let local = BookProject(id: project.id, title: project.title, originalName: project.originalName, sourceHash: project.sourceHash, units: [unit])
                resolver = try ReadingExperienceRuntime.anchorResolver(sourceHash: project.sourceHash, unitID: unit.id, in: local)
                resolvers[unit.id] = resolver
            }
            let resolved = try resolver(anchor)
            guard resolved.page == entry.page else { throw ReadingError.invalid("章节页码与原文不一致。") }
            if generated {
                guard entry.id == anchor.id,
                      entry.title.utf8.elementsEqual(anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines).utf8) else {
                    throw ReadingError.invalid("生成目录标题与原文不一致。")
                }
            }
            let start = offsets[index] + resolved.utf16Location
            if let previous = positions.last {
                guard start >= previous.start,
                      start != previous.start || entry.level > previous.entry.level else {
                    throw ReadingError.invalid("章节目录次序或重叠起点不明确，请先核对目录。")
                }
            }
            positions.append(Position(entry: entry, start: start))
        }
        guard !positions.isEmpty else { return nil }
        func ranges(_ start: Int, _ end: Int) -> [ReadingSourceRange] {
            guard start < end else { return [] }
            // Binary search avoids walking the book prefix for every chapter.
            var low = 0, high = units.count
            while low < high { let mid = (low + high) / 2; if offsets[mid + 1] <= start { low = mid + 1 } else { high = mid } }
            var result: [ReadingSourceRange] = [], index = low
            while index < units.count, offsets[index] < end {
                let left = max(start, offsets[index]) - offsets[index], right = min(end, offsets[index + 1]) - offsets[index]
                if left < right { result.append(ReadingSourceRange(unitID: units[index].id, startUTF16: left, endUTF16: right)) }
                index += 1
            }
            return result
        }
        var ends = [Int](repeating: frontier, count: positions.count), known = [Bool](repeating: complete, count: positions.count), stack: [Int] = []
        for index in positions.indices {
            while let previous = stack.last, positions[previous].entry.level >= positions[index].entry.level {
                ends[previous] = positions[index].start; known[previous] = true; stack.removeLast()
            }
            stack.append(index)
        }
        let chapters = positions.indices.map { index in
            BookChapterRange(id: positions[index].entry.id, title: positions[index].entry.title, level: positions[index].entry.level,
                             ranges: ranges(positions[index].start, ends[index]), isComplete: known[index])
        }
        var segments: [BookChapterRange] = []
        if positions[0].start > 0 {
            segments.append(BookChapterRange(id: "chapter-preface-" + String(fingerprint.prefix(32)), title: "章前内容", level: 0,
                                             ranges: ranges(0, positions[0].start), isComplete: true))
        }
        for index in positions.indices {
            let next = index + 1 < positions.count ? positions[index + 1].start : frontier
            guard positions[index].start < next else { continue }
            segments.append(BookChapterRange(id: chapters[index].id, title: chapters[index].title, level: chapters[index].level,
                                             ranges: ranges(positions[index].start, next), isComplete: index + 1 < positions.count || known[index]))
        }
        return BookChapterIndex(sourceFingerprint: fingerprint, chapters: chapters, segments: segments)
    }
}

#if os(macOS)
extension BookChapterRuntime {
    /// Uses one worker-owned PDFDocument. Native point geometry is consulted only
    /// after the entire extracted page has been proved byte-identical to the
    /// canonical units; OCR or a different extraction is never guessed into place.
    public static func originalPDFOutline(at url: URL, project: BookProject, password: String?) throws -> BookChapterOutline? {
        let document = try BookOutlineRuntime.originalPDFDocument(at: url, expectedSourceHash: project.sourceHash, password: password)
        var entries = try BookOutlineRuntime.originalPDFEntries(in: document)
        guard !entries.isEmpty else { return nil }
        let ordered = project.units.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        guard Set(ordered.map(\.id)).count == ordered.count else { throw ReadingError.invalid("章节原文单元身份重复。") }
        let byPage = Dictionary(grouping: ordered.filter { $0.page != nil }, by: { $0.page! })
        struct PageLine {
            var start: Int
            var bounds: CGRect
        }
        struct PageProof {
            var units: [SourceUnit]
            var text: String
            var nativeOffsets: [Int]?
            var unitOffsets: [Int]
            var lines: [PageLine] = []
            func nativeIndex(_ offset: Int) -> Int? {
                guard offset >= 0, offset < (text as NSString).length else { return nil }
                return nativeOffsets.map { $0[offset] } ?? offset
            }
        }
        // Directory entries normally advance through the book. Retain one page,
        // not one Int-per-UTF16 mapping for every chapter page in a large PDF.
        var cachedProof: (page: Int, value: PageProof)?, unavailable = Set<Int>()
        func pageProof(_ number: Int) throws -> PageProof? {
            if let cachedProof, cachedProof.page == number { return cachedProof.value }
            if unavailable.contains(number) { return nil }
            guard let page = document.page(at: number - 1), let native = page.string, let units = byPage[number], !units.isEmpty else {
                unavailable.insert(number); return nil
            }
            guard native.utf8.count <= 2 * 1_024 * 1_024 else { unavailable.insert(number); return nil }
            let ns = native as NSString
            var text = native, nativeOffsets: [Int]?
            if native.contains("\r") {
                var normalized = "", mapping: [Int] = [], cursor = 0
                while cursor < ns.length {
                    if cursor.isMultiple(of: 1024) { try Task.checkCancellation() }
                    let code = ns.character(at: cursor)
                    if code == 13 {
                        normalized.append("\n"); mapping.append(cursor)
                        cursor += cursor + 1 < ns.length && ns.character(at: cursor + 1) == 10 ? 2 : 1
                    } else {
                        let scalarRange = ns.rangeOfComposedCharacterSequence(at: cursor)
                        normalized.append(ns.substring(with: scalarRange))
                        mapping += Array(scalarRange.location..<NSMaxRange(scalarRange)); cursor = NSMaxRange(scalarRange)
                    }
                }
                text = normalized; nativeOffsets = mapping
            }
            guard units.map(\.text).joined().utf8.elementsEqual(text.utf8) else { unavailable.insert(number); return nil }
            var starts = [0]
            for unit in units { starts.append(starts.last! + unit.text.utf16.count) }
            var proof = PageProof(units: units, text: text, nativeOffsets: nativeOffsets, unitOffsets: starts)
            let rows = text.components(separatedBy: "\n")
            guard rows.count <= 20_000 else { unavailable.insert(number); return nil }
            var rowOffset = 0
            for row in rows {
                try Task.checkCancellation()
                let lead = row.prefix(while: \.isWhitespace), first = rowOffset + String(lead).utf16.count
                defer { rowOffset += row.utf16.count + 1 }
                guard let nativeOffset = proof.nativeIndex(first), !row.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let bounds = page.characterBounds(at: nativeOffset)
                if !bounds.isEmpty, bounds.minX.isFinite, bounds.minY.isFinite {
                    proof.lines.append(PageLine(start: rowOffset, bounds: bounds))
                }
            }
            cachedProof = (number, proof); return proof
        }
        func normalized(_ value: String) -> (String, [Int]) {
            var result = "", positions: [Int] = [], offset = 0
            for character in value {
                let width = String(character).utf16.count
                let omitted = character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.punctuationCharacters.contains($0) }
                if !omitted { result.append(character); positions += Array(repeating: offset, count: width) }
                offset += width
            }
            return (result, positions)
        }
        func rawStart(entry: BookOutlineEntry, proof: PageProof, page: PDFPage) throws -> Int? {
            let ns = proof.text as NSString
            var geometryStart: Int?
            if let x = entry.destinationX, let y = entry.destinationY {
                let crop = page.bounds(for: .cropBox), point = CGPoint(x: x, y: y)
                if crop.insetBy(dx: -4, dy: -4).contains(point) {
                    var best: (Int, CGFloat)?
                    for line in proof.lines {
                        try Task.checkCancellation()
                        let bounds = line.bounds
                        guard bounds.midY <= point.y + bounds.height / 2 else { continue }
                        let vertical = max(0, point.y - bounds.maxY)
                        let score = vertical * 10_000 + abs(bounds.minX - point.x)
                        if best == nil || score < best!.1 { best = (line.start, score) }
                    }
                    geometryStart = best?.0
                }
            }
            // Use the source line at the native GoTo viewport boundary. Labels
            // may be custom; an unrelated same-named word cannot redirect it.
            if let geometryStart { return geometryStart }
            let title = normalized(entry.title).0
            if !title.isEmpty {
                let (search, map) = normalized(proof.text)
                var matches: [Int] = [], cursor = search.startIndex
                while cursor < search.endIndex, let match = search.range(of: title, options: .literal, range: cursor..<search.endIndex) {
                    let offset = search[..<match.lowerBound].utf16.count
                    if offset < map.count { matches.append(map[offset]) }
                    if matches.count > 64 { break }; cursor = match.upperBound
                }
                if matches.count == 1 { return ns.lineRange(for: NSRange(location: matches[0], length: 0)).location }
            }
            return geometryStart
        }
        for index in entries.indices {
            try Task.checkCancellation()
            guard let number = entries[index].page, let page = document.page(at: number - 1),
                  let proof = try pageProof(number), let start = try rawStart(entry: entries[index], proof: proof, page: page) else { continue }
            guard let unitIndex = proof.units.indices.first(where: { proof.unitOffsets[$0] <= start && start < proof.unitOffsets[$0 + 1] }) else { continue }
            let unit = proof.units[unitIndex], localOffset = start - proof.unitOffsets[unitIndex], ns = unit.text as NSString
            guard localOffset < ns.length else { continue }
            let line = ns.lineRange(for: NSRange(location: localOffset, length: 0))
            let length = min(160, NSMaxRange(line) - localOffset)
            let wanted = ns.rangeOfComposedCharacterSequences(for: NSRange(location: localOffset, length: length))
            guard wanted.location == localOffset, let swiftRange = Range(wanted, in: unit.text) else { continue }
            let quote = String(unit.text[swiftRange]), before = String(unit.text[..<swiftRange.lowerBound].suffix(64)), after = String(unit.text[swiftRange.upperBound...].prefix(64))
            let local = BookProject(id: project.id, title: project.title, originalName: project.originalName, sourceHash: project.sourceHash, units: [unit])
            if let anchor = try? ReadingExperienceRuntime.createAnchor(sourceHash: project.sourceHash, unitID: unit.id,
                quote: quote, prefix: before, suffix: after, in: local), anchor.utf16Location == localOffset {
                entries[index].anchor = anchor
            }
        }
        let outline = BookChapterOutline(sourceHash: project.sourceHash, sourceFingerprint: try BookOutlineRuntime.fingerprint(in: project),
            scannedUnitCount: project.units.count, totalUnitCount: project.units.count, entries: entries)
        try validateStored(outline)
        return outline
    }
}
#endif
