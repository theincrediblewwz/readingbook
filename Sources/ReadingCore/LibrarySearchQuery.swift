import Foundation
import NaturalLanguage

/// Model output is a bounded keyword plan, never a source result or authority to
/// read another book. The host still searches its immutable, scoped snapshots.
public struct LibrarySearchExpansionPlan: Hashable, Sendable {
    public let keywords: [String]

    public init(keywords: [String]) throws {
        guard (1...8).contains(keywords.count) else { throw Self.invalidPlan }
        var seen = Set<String>(), accepted: [String] = []
        for value in keywords {
            let word = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.count <= 80, !word.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw Self.invalidPlan
            }
            let identity = word.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if seen.insert(identity).inserted { accepted.append(word) }
        }
        guard !accepted.isEmpty else { throw Self.invalidPlan }
        self.keywords = accepted
    }

    public static func parse(_ json: String) throws -> Self {
        guard json.utf8.count <= 8_192, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any], Set(dictionary.keys) == ["keywords"],
              let keywords = dictionary["keywords"] as? [String] else { throw invalidPlan }
        return try Self(keywords: keywords)
    }

    private static var invalidPlan: ReadingError { .invalid("检索扩展只接受1–8个关键词，每词最多80字；没有使用不完整或无效的模型结果。") }
}

/// Ephemeral language hints, not a persisted declaration of a book's language.
/// Search equivalence does not depend on this classifier. No assets download.
public struct LibrarySearchLanguageProfile: Hashable, Sendable {
    public let languageCodes: [String]
    public let sampledCharacterCount: Int
    public var isMixed: Bool { languageCodes.count > 1 }
    public var summary: String {
        guard !languageCodes.isEmpty else { return "语言未确定" }
        return languageCodes.map { code in
            switch code {
            case "zh-Hans": return "简体中文"
            case "zh-Hant": return "繁体中文"
            case "en": return "英语"
            default: return Locale(identifier: "zh_CN").localizedString(forLanguageCode: code) ?? code
            }
        }.joined(separator: "、")
    }

    public static func identify(in snapshots: [LibrarySourceSnapshot], bookID: String? = nil) throws -> Self {
        try Task.checkCancellation()
        var weights: [String: Double] = [:], characterCount = 0
        // At most 16 books, five distributed units each and 16K characters total.
        for book in snapshots.lazy.filter({ bookID == nil || $0.bookID == bookID }).prefix(16) {
            try Task.checkCancellation()
            let units = book.units
            guard !units.isEmpty else { continue }
            let positions = Set([0, units.count / 4, units.count / 2, units.count * 3 / 4, units.count - 1]).sorted()
            for position in positions {
                try Task.checkCancellation()
                let remaining = 16_384 - characterCount
                guard remaining > 0 else { break }
                let sample = String(units[position].text.prefix(min(512, remaining)))
                guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                characterCount += sample.count
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(sample)
                if let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.35 {
                    weights[best.key.rawValue, default: 0] += Double(sample.count) * best.value
                }
            }
            if characterCount == 16_384 { break }
        }
        let total = weights.values.reduce(0, +)
        let languages = weights.filter { $0.value >= max(1, total * 0.1) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(4).map(\.key)
        return Self(languageCodes: languages, sampledCharacterCount: characterCount)
    }
}

/// Search-local cache; canonical text is only a discovery view. Its boundaries
/// carry original UTF-16 locations, including length-changing character folds.
struct LibrarySearchCanonicalizer {
    private var characters: [Character: String] = [:]
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2EBEF, 0x30000...0x323AF: return true
            default: return false
            }
        }
    }

    mutating func fold(_ character: Character) -> String {
        if let stored = characters[character] { return stored }
        let raw = String(character)
        var folded = raw.folding(options: [.caseInsensitive, .widthInsensitive], locale: Self.locale)
        if Self.containsHan(raw) {
            folded = folded.applyingTransform(StringTransform(rawValue: "Traditional-Simplified"), reverse: false) ?? folded
        }
        if folded.isEmpty { folded = raw }
        if characters.count < 4_096 { characters[character] = folded }
        return folded
    }

    mutating func fold(_ text: String) throws -> String {
        var result = ""
        for (index, character) in text.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            result += fold(character)
        }
        return result
    }
}

struct LibrarySearchMappedText {
    struct Boundary { let canonical: Int; let original: Int }
    let text: String
    let boundaries: [Boundary]

    init(_ original: String, canonicalizer: inout LibrarySearchCanonicalizer) throws {
        var folded = "", boundaries = [Boundary(canonical: 0, original: 0)]
        var foldedLength = 0, originalLength = 0
        for (index, character) in original.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            let piece = canonicalizer.fold(character)
            folded += piece
            foldedLength += piece.utf16.count
            originalLength += String(character).utf16.count
            boundaries.append(Boundary(canonical: foldedLength, original: originalLength))
        }
        self.text = folded; self.boundaries = boundaries
    }

    func originalRange(_ range: NSRange) -> NSRange? {
        guard let start = boundary(for: range.location), let end = boundary(for: range.location + range.length) else { return nil }
        return NSRange(location: start.original, length: end.original - start.original)
    }

    func canonicalStart(atOrAfter offset: Int) -> Int {
        var lower = 0, upper = boundaries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if boundaries[middle].original < offset { lower = middle + 1 } else { upper = middle }
        }
        return boundaries[min(lower, boundaries.count - 1)].canonical
    }

    private func boundary(for offset: Int) -> Boundary? {
        var lower = 0, upper = boundaries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if boundaries[middle].canonical < offset { lower = middle + 1 } else { upper = middle }
        }
        guard lower < boundaries.count, boundaries[lower].canonical == offset else { return nil }
        return boundaries[lower]
    }
}
