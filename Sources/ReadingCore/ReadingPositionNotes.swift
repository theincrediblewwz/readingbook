import Foundation

/// Optional host metadata on an ordinary Markdown note. Coordinates are in
/// the original PDF crop box (0...1), never screen pixels or extracted offsets.
public struct ReadingNotePlacement: Codable, Hashable, Sendable {
    public var sourceHash: String
    public var unitID: String
    public var page: Int?
    public var x: Double
    public var y: Double
    public var fontFamily: String
    public var fontSize: Double
    /// Nil on older notes: inherit the current reading paper until the reader
    /// explicitly chooses a note color. The Markdown body is unchanged.
    public var paperStyle: String?
    public var quote: ReadingNoteSourceQuote?
    public init(sourceHash: String, unitID: String, page: Int?, x: Double, y: Double,
                fontFamily: String = "serif", fontSize: Double = 15, paperStyle: String? = nil, quote: ReadingNoteSourceQuote? = nil) {
        self.sourceHash = sourceHash; self.unitID = unitID; self.page = page; self.x = x; self.y = y
        self.fontFamily = fontFamily; self.fontSize = fontSize
        self.paperStyle = paperStyle
        self.quote = quote
    }
    public func validate() throws {
        guard !sourceHash.isEmpty, sourceHash.utf8.count <= 160, !unitID.isEmpty, unitID.utf8.count <= 160,
              page == nil || (page! > 0 && page! <= 1_000_000), x.isFinite, y.isFinite,
              (0...1).contains(x), (0...1).contains(y), (10...28).contains(fontSize), fontSize.isFinite,
              !fontFamily.isEmpty, fontFamily.count <= 100, !fontFamily.utf8.contains(0),
              paperStyle == nil || ["plain", "warm-cotton", "mist-white", "sage-paper"].contains(paperStyle!) else {
            throw ReadingError.invalid("笔记位置或字体无效，原笔记保留。")
        }
        try quote?.validate()
    }
    public func matches(_ project: BookProject) -> Bool {
        sourceHash == project.sourceHash && project.units.contains { $0.id == unitID && $0.page == page }
    }
}

public struct ReadingNoteQuoteRange: Codable, Hashable, Sendable {
    public let page: Int
    public let location: Int
    public let length: Int
    public init(page: Int, location: Int, length: Int) { self.page = page; self.location = location; self.length = length }
}
public struct ReadingNoteSourceQuote: Codable, Hashable, Sendable {
    public let text: String
    public let ranges: [ReadingNoteQuoteRange]
    public init(text: String, ranges: [ReadingNoteQuoteRange]) { self.text = text; self.ranges = ranges }
    public func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 131_072,
              !ranges.isEmpty, ranges.count <= 512,
              ranges.allSatisfy({ $0.page > 0 && $0.page <= 1_000_000 && $0.location >= 0 && $0.length > 0 && $0.location <= 100_000_000 && $0.length <= 100_000_000 - $0.location }) else {
            throw ReadingError.invalid("便签绑定的原文范围无效，原笔记保留。")
        }
    }
}

/// A note editor also owns the placement version it opened. A concurrent
/// rebind, unbind or color edit must be reviewed instead of overwritten.
public enum ReadingNotePlacementExpectation: Sendable {
    case unchanged(ReadingNotePlacement?)
}

public struct ReadingNoteScreenPosition: Hashable, Sendable {
    public let id: String
    public let y: Double
    public init(id: String, y: Double) { self.id = id; self.y = y }
}
public struct ReadingNoteStack: Hashable, Sendable {
    public let ids: [String]
    public let top: Double
    public init(ids: [String], top: Double) { self.ids = ids; self.top = top }
}
public enum ReadingNoteLayout {
    /// Nearby paper slips stack rather than obscure each other. This affects
    /// presentation only: every note and exact source coordinate is preserved.
    public static func stacks(_ positions: [ReadingNoteScreenPosition], height: Double, cardHeight: Double = 170, topInset: Double = 16) -> [ReadingNoteStack] {
        guard height.isFinite, height > 0, cardHeight.isFinite, cardHeight > 0, topInset.isFinite else { return [] }
        let sorted = positions.filter { $0.y.isFinite && $0.y >= 0 && $0.y <= height }.sorted { $0.y == $1.y ? $0.id < $1.id : $0.y < $1.y }
        var result: [ReadingNoteStack] = []
        for point in sorted {
            let bottom = max(16, height - cardHeight - 32), minimum = min(max(16, topInset), bottom)
            let top = min(max(minimum, point.y - cardHeight / 2), bottom)
            if let last = result.last, top < last.top + cardHeight + 24 {
                result[result.count - 1] = .init(ids: last.ids + [point.id], top: last.top)
            } else { result.append(.init(ids: [point.id], top: top)) }
        }
        return result
    }
}
