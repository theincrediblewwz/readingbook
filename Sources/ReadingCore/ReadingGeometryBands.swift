import Foundation

/// Small, transient page-space broad phase. It contains no PDFKit objects and
/// is built while geometry arrives, never while handling a pointer or drawing.
public struct ReadingGeometryBands<ID: Hashable & Sendable>: Sendable {
    private var bands: [Int: Set<ID>] = [:]
    private var overflow: Set<ID> = []
    private let height: Double
    private let maximumBands: Int
    private let maximumOverflow: Int
    public private(set) var requiresFallback = false

    public init(height: Double = 64, maximumBands: Int = 64, maximumOverflow: Int = 256) {
        self.height = height.isFinite && height >= 1 ? height : 64
        self.maximumBands = max(1, min(256, maximumBands))
        self.maximumOverflow = max(0, min(1024, maximumOverflow))
    }
    public mutating func insert(_ id: ID, rectangle: CGRect) {
        guard let lower = band(rectangle.minY), let upper = band(rectangle.maxY),
              rectangle.minX.isFinite, rectangle.maxX.isFinite, !rectangle.isEmpty else { return }
        if upper - lower > maximumBands {
            if overflow.count < maximumOverflow || overflow.contains(id) { overflow.insert(id) }
            else { requiresFallback = true }
            return
        }
        for value in lower...upper { bands[value, default: []].insert(id) }
    }
    public func candidates(atY value: Double) -> Set<ID> {
        guard let value = band(value) else { return [] }
        guard !overflow.isEmpty else { return bands[value] ?? [] }
        return (bands[value] ?? []).union(overflow)
    }
    public func candidates(intersecting rectangle: CGRect) -> Set<ID> {
        guard let lower = band(rectangle.minY), let upper = band(rectangle.maxY), !rectangle.isEmpty else { return [] }
        var result = overflow
        if upper - lower <= 256 {
            for value in lower...upper { if let ids = bands[value] { result.formUnion(ids) } }
        } else {
            // At an extreme zoom-out, visit only occupied bands rather than
            // allocating or iterating millions of empty page coordinates.
            for (value, ids) in bands where value >= lower && value <= upper { result.formUnion(ids) }
        }
        return result
    }
    private func band(_ value: Double) -> Int? {
        guard value.isFinite, abs(value) <= 1_000_000_000 else { return nil }
        return Int(floor(value / height))
    }
}
