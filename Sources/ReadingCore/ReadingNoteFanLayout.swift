import Foundation

public struct ReadingNoteFanCard: Equatable, Sendable {
    public let index: Int
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let degrees: Double
}

public enum ReadingNoteFanLayout {
    public static func pageSize(width: Double) -> Int { width < 440 ? 1 : width < 760 ? 3 : 7 }
    /// A bounded fan keeps every paper reachable even for hundreds of notes;
    /// paging changes presentation only and never drops the remaining IDs.
    public static func cards(count: Int, width: Double, height: Double) -> [ReadingNoteFanCard] {
        guard count > 0, width.isFinite, height.isFinite, width > 0, height > 0 else { return [] }
        let visible = min(count, pageSize(width: width))
        let paperWidth = min(260, max(120, width - 64)), paperHeight = min(330, max(140, height - 170))
        let spread = min(max(0, width - paperWidth - 180), Double(visible - 1) * 90)
        return (0..<visible).map { index in
            let t = visible == 1 ? 0 : Double(index) / Double(visible - 1) * 2 - 1
            return .init(index: index, x: width / 2 + t * spread / 2,
                         y: height / 2 + abs(t) * abs(t) * 32,
                         width: paperWidth, height: paperHeight, degrees: t * 16)
        }
    }
}
