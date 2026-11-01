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
        let paperWidth: Double, paperHeight: Double, spread: Double, arcRise: Double
        if visible >= 6 {
            // A large stack keeps its compact fan and bounded page size.
            paperWidth = min(260, max(120, width - 64))
            paperHeight = min(330, max(140, height - 170))
            spread = min(max(0, width - paperWidth - 180), Double(visible - 1) * 90)
            arcRise = 32
        } else {
            let density = visible == 4 ? 0.5 : visible == 5 ? 0.75 : 0.0
            let desiredWidth = 340 - density * 80, desiredHeight = 430 - density * 100
            let angle = visible == 1 ? 0 : 16.0 * .pi / 180
            let rotatedWidth = cos(angle) * desiredWidth + sin(angle) * desiredHeight
            let rotatedHeight = cos(angle) * desiredHeight + sin(angle) * desiredWidth
            // Reserve room for rotated corners, exposed card edges and hover lift.
            let scale = min(1, min(max(1, width - 64) / (rotatedWidth + Double(visible - 1) * 44),
                                   max(1, height - 180) / (rotatedHeight + 64)))
            paperWidth = desiredWidth * scale
            paperHeight = desiredHeight * scale
            let spacing = visible <= 3 ? 0.82 : visible == 4 ? 0.62 : 0.48
            spread = min(max(0, width - 64 - rotatedWidth * scale),
                         Double(visible - 1) * paperWidth * spacing)
            arcRise = 24 * scale
        }
        return (0..<visible).map { index in
            let t = visible == 1 ? 0 : Double(index) / Double(visible - 1) * 2 - 1
            return .init(index: index, x: width / 2 + t * spread / 2,
                         y: height / 2 + abs(t) * abs(t) * arcRise,
                         width: paperWidth, height: paperHeight, degrees: t * 16)
        }
    }
}
