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
    public init(sourceHash: String, unitID: String, page: Int?, x: Double, y: Double,
                fontFamily: String = "serif", fontSize: Double = 15) {
        self.sourceHash = sourceHash; self.unitID = unitID; self.page = page; self.x = x; self.y = y
        self.fontFamily = fontFamily; self.fontSize = fontSize
    }
    public func validate() throws {
        guard !sourceHash.isEmpty, sourceHash.utf8.count <= 160, !unitID.isEmpty, unitID.utf8.count <= 160,
              page == nil || (page! > 0 && page! <= 1_000_000), x.isFinite, y.isFinite,
              (0...1).contains(x), (0...1).contains(y), (10...28).contains(fontSize), fontSize.isFinite,
              !fontFamily.isEmpty, fontFamily.count <= 100, !fontFamily.utf8.contains(0) else {
            throw ReadingError.invalid("笔记位置或字体无效，原笔记保留。")
        }
    }
    public func matches(_ project: BookProject) -> Bool {
        sourceHash == project.sourceHash && project.units.contains { $0.id == unitID && $0.page == page }
    }
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
