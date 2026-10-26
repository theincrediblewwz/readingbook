import Foundation

/// Expands the reader's shorthand citations without changing literal code,
/// mathematics or an existing Markdown link. This is presentation-only.
public enum MarkdownReferenceLinks {
    public static func render(_ source: String, bookID: String, labelForReference: ((String, String) -> String?)? = nil) -> String {
        guard !bookID.isEmpty else { return source }
        let bytes = Array(source.utf8)
        let mathClosers = MathCloserIndex(bytes)
        var output: [UInt8] = []; output.reserveCapacity(bytes.count)
        var bracketEnds: [Int: Int] = [:], brackets: [Int] = []
        var parenthesisEnds: [Int: Int] = [:], parentheses: [Int] = []
        var referenceLabels = Set<String>()
        var scanningFence: (marker: UInt8, count: Int)?
        var offset = 0
        while offset < bytes.count {
            if offset == 0 || bytes[offset - 1] == 10 {
                let lineEnd = bytes[offset...].firstIndex(of: 10).map { $0 + 1 } ?? bytes.count
                let line = Array(bytes[offset..<lineEnd]), prefix = blockPrefix(line)
                if let active = scanningFence {
                    if let found = fenceMarker(line, start: prefix), found.marker == active.marker, found.count >= active.count,
                       line.dropFirst(found.end).allSatisfy({ [9, 10, 13, 32].contains($0) }) { scanningFence = nil }
                    offset = lineEnd; continue
                }
                if let found = fenceMarker(line, start: prefix), found.marker != 96 || !line.dropFirst(found.end).contains(96) {
                    scanningFence = (found.marker, found.count); offset = lineEnd; continue
                }
                if let label = definitionLabel(line, prefix: prefix) { referenceLabels.insert(label); offset = lineEnd; continue }
                if isIndented(line) { offset = lineEnd; continue }
            }
            if bytes[offset] == 96 {
                let length = run(bytes, from: offset, marker: 96)
                if let end = closingRun(bytes, from: offset + length, marker: 96, count: length) { offset = end; continue }
                offset += length; continue
            }
            if bytes[offset] == 36 {
                let length = run(bytes, from: offset, marker: 36)
                if length <= 2, let end = closingRun(bytes, from: offset + length, marker: 36, count: length) { offset = end; continue }
                offset += length; continue
            }
            if bytes[offset] == 92, offset + 1 < bytes.count, bytes[offset + 1] == 40 || bytes[offset + 1] == 91,
               let end = mathClosers.end(from: offset + 2, opener: bytes[offset + 1]) { offset = end; continue }
            if bytes[offset] == 92 { offset += 2; continue }
            if bytes[offset] == 91 { brackets.append(offset) }
            else if bytes[offset] == 93, let start = brackets.popLast() { bracketEnds[start] = offset }
            if bytes[offset] == 40 { parentheses.append(offset) }
            else if bytes[offset] == 41, let start = parentheses.popLast() { parenthesisEnds[start] = offset }
            offset += 1
        }
        var fence: (marker: UInt8, count: Int)?
        var noAngleCloser = false
        offset = 0
        while offset < bytes.count {
            if offset == 0 || bytes[offset - 1] == 10 {
                let lineEnd = bytes[offset...].firstIndex(of: 10).map { $0 + 1 } ?? bytes.count
                let line = Array(bytes[offset..<lineEnd])
                let prefix = blockPrefix(line)
                if let active = fence {
                    output.append(contentsOf: line)
                    if let found = fenceMarker(line, start: prefix), found.marker == active.marker, found.count >= active.count,
                       line.dropFirst(found.end).allSatisfy({ [9, 10, 13, 32].contains($0) }) { fence = nil }
                    offset = lineEnd; continue
                }
                if let found = fenceMarker(line, start: prefix), found.marker != 96 || !line.dropFirst(found.end).contains(96) {
                    fence = (found.marker, found.count); output.append(contentsOf: line); offset = lineEnd; continue
                }
                if isIndented(line) || definitionLabel(line, prefix: prefix) != nil { output.append(contentsOf: line); offset = lineEnd; continue }
            }
            let value = bytes[offset]
            if value == 92 {
                if offset + 1 < bytes.count, bytes[offset + 1] == 40 || bytes[offset + 1] == 91,
                   let end = mathClosers.end(from: offset + 2, opener: bytes[offset + 1]) {
                    output.append(contentsOf: bytes[offset..<end]); offset = end; continue
                }
                let end = min(bytes.count, offset + 2); output.append(contentsOf: bytes[offset..<end]); offset = end; continue
            }
            if value == 96 {
                let length = run(bytes, from: offset, marker: 96)
                if let end = closingRun(bytes, from: offset + length, marker: 96, count: length) {
                    output.append(contentsOf: bytes[offset..<end]); offset = end; continue
                }
                output.append(contentsOf: bytes[offset..<(offset + length)]); offset += length; continue
            }
            if value == 36 {
                let length = run(bytes, from: offset, marker: 36)
                if length <= 2, let end = closingRun(bytes, from: offset + length, marker: 36, count: length) {
                    output.append(contentsOf: bytes[offset..<end]); offset = end; continue
                }
                output.append(contentsOf: bytes[offset..<(offset + length)]); offset += length; continue
            }
            if value == 60, !noAngleCloser {
                if let end = bytes[(offset + 1)...].firstIndex(of: 62) {
                    output.append(contentsOf: bytes[offset...end]); offset = end + 1; continue
                }
                noAngleCloser = true
            }
            if value == 91, let close = bracketEnds[offset] {
                let after = close + 1
                if after < bytes.count, bytes[after] == 40, let end = parenthesisEnds[after] {
                    output.append(contentsOf: bytes[offset...end]); offset = end + 1; continue
                }
                if after < bytes.count, bytes[after] == 91, let end = bracketEnds[after] {
                    output.append(contentsOf: bytes[offset...end]); offset = end + 1; continue
                }
                let inside = bytes[(offset + 1)..<close]
                if referenceLabels.contains(normalizeLabel(String(decoding: inside, as: UTF8.self))) {
                    output.append(contentsOf: bytes[offset...close]); offset = close + 1; continue
                }
                let kind: String, idStart: Int
                if inside.starts(with: Array("unit:".utf8)) { kind = "unit"; idStart = 5 }
                else if inside.starts(with: Array("doc:".utf8)) { kind = "document"; idStart = 4 }
                else if inside.starts(with: Array("message:".utf8)) { kind = "message"; idStart = 8 }
                else { output.append(value); offset += 1; continue }
                let idBytes = inside.dropFirst(idStart)
                if !idBytes.isEmpty, idBytes.allSatisfy(isIdentifier) {
                    let id = String(decoding: idBytes, as: UTF8.self)
                    var url = URLComponents(); url.scheme = "readingbook"; url.host = "book"; url.path = "/\(bookID)/\(kind)/\(id)"
                    if let destination = url.string {
                        let fallback = kind == "unit" ? "原文" : kind == "message" ? "历史对话" : "笔记"
                        let label = labelForReference?(kind, id)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        output.append(contentsOf: "[\(escapedLabel(label?.isEmpty == false ? label! : fallback))](\(destination))".utf8)
                        offset = close + 1; continue
                    }
                }
            }
            output.append(value); offset += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    public static func render(_ source: String, bookID: String, project: BookProject?) -> String {
        // Build only an index that this answer actually needs. Repeated source
        // citations no longer linearly search the whole book for every label.
        var unitLabels: [String: String]?, messageLabels: [String: String]?, documentLabels: [String: String]?
        return render(source, bookID: bookID, labelForReference: { kind, id in
            if kind == "unit" {
                if unitLabels == nil {
                    unitLabels = Dictionary((project?.units ?? []).map { unit in
                        (unit.id, unit.page.map { "第 \($0) 页" } ?? (unit.chapter.isEmpty ? "原文" : unit.chapter))
                    }, uniquingKeysWith: { first, _ in first })
                }
                return unitLabels?[id]
            }
            if kind == "message" {
                if messageLabels == nil {
                    messageLabels = Dictionary((project?.chats ?? []).map { ($0.id, $0.role == "user" ? "先前的问题" : "先前的回答") }, uniquingKeysWith: { first, _ in first })
                }
                return messageLabels?[id]
            }
            if kind == "document" {
                if documentLabels == nil {
                    documentLabels = Dictionary((project?.documents ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
                }
                return documentLabels?[id]
            }
            return nil
        })
    }

    private static func escapedLabel(_ value: String) -> String {
        let punctuation = Set("\\`*_{}[]()#+-.!<>|")
        return value.prefix(120).map { character in
            if character.isWhitespace { return " " }
            return punctuation.contains(character) ? "\\" + String(character) : String(character)
        }.joined()
    }

    private static func isIdentifier(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || [45, 46, 95].contains(byte) }
    private static func run(_ bytes: [UInt8], from start: Int, marker: UInt8) -> Int {
        var end = start; while end < bytes.count, bytes[end] == marker { end += 1 }; return end - start
    }
    private static func closingRun(_ bytes: [UInt8], from start: Int, marker: UInt8, count: Int) -> Int? {
        var index = start
        while index < bytes.count {
            // Backslashes are literal inside a Markdown code span; they do not
            // escape its closing backtick. Dollar math still honors escapes.
            if marker != 96, bytes[index] == 92 { index += 2; continue }
            if bytes[index] == marker {
                let length = run(bytes, from: index, marker: marker)
                if length == count { return index + length }; index += length
            } else { index += 1 }
        }
        return nil
    }
    private struct MathCloserIndex {
        private let round: [Int]
        private let square: [Int]
        init(_ bytes: [UInt8]) {
            var round: [Int] = [], square: [Int] = [], index = 0
            while index + 1 < bytes.count {
                if bytes[index] == 92 {
                    if bytes[index + 1] == 41 { round.append(index) }
                    else if bytes[index + 1] == 93 { square.append(index) }
                    index += 2
                } else { index += 1 }
            }
            self.round = round; self.square = square
        }
        func end(from start: Int, opener: UInt8) -> Int? {
            // Each search starts after '(' or '[', never inside a backslash
            // run, so escape-pair alignment matches the old suffix scan.
            // Index once in O(N); malformed repeated openers now query in
            // O(log N) rather than scanning the same missing suffix O(N²).
            let positions = opener == 40 ? round : square
            var lower = 0, upper = positions.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if positions[middle] < start { lower = middle + 1 } else { upper = middle }
            }
            return lower < positions.count ? positions[lower] + 2 : nil
        }
    }
    private static func blockPrefix(_ line: [UInt8]) -> Int {
        var index = 0, spaces = 0
        while index < line.count {
            if line[index] == 32, spaces < 3 { index += 1; spaces += 1 }
            else if line[index] == 62 { index += 1; spaces = 0; if index < line.count, line[index] == 32 { index += 1 } }
            else if [42, 43, 45].contains(line[index]), index + 1 < line.count, [9, 32].contains(line[index + 1]) {
                index += 2; spaces = 0
            }
            else if (48...57).contains(line[index]) {
                var end = index
                while end < line.count, end - index < 9, (48...57).contains(line[end]) { end += 1 }
                guard end + 1 < line.count, [41, 46].contains(line[end]), [9, 32].contains(line[end + 1]) else { break }
                index = end + 2; spaces = 0
            }
            else { break }
        }
        return index
    }
    private static func isIndented(_ line: [UInt8]) -> Bool {
        line.count >= 4 && line.prefix(4).allSatisfy { $0 == 32 } || line.first == 9
    }
    private static func definitionLabel(_ line: [UInt8], prefix: Int) -> String? {
        guard prefix < line.count, line[prefix] == 91, let end = line[(prefix + 1)...].firstIndex(of: 93),
              end + 1 < line.count, line[end + 1] == 58 else { return nil }
        return normalizeLabel(String(decoding: line[(prefix + 1)..<end], as: UTF8.self))
    }
    private static func normalizeLabel(_ value: String) -> String {
        let bytes = Array(value.utf8); var result: [UInt8] = []; var index = 0
        while index < bytes.count {
            if bytes[index] == 92, index + 1 < bytes.count,
               (33...47).contains(bytes[index + 1]) || (58...64).contains(bytes[index + 1]) || (91...96).contains(bytes[index + 1]) || (123...126).contains(bytes[index + 1]) { index += 1 }
            result.append(bytes[index]); index += 1
        }
        return String(decoding: result, as: UTF8.self).split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
    private static func fenceMarker(_ line: [UInt8], start: Int) -> (marker: UInt8, count: Int, end: Int)? {
        guard start < line.count, line[start] == 96 || line[start] == 126 else { return nil }
        let count = run(line, from: start, marker: line[start]); guard count >= 3 else { return nil }
        return (line[start], count, start + count)
    }
}
