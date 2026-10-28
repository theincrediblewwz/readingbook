import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Placement only: controls retain one identity while their rows change.
public enum ReadingControlRowsGeometry {
    public struct Plan: Equatable {
        public let size: CGSize
        public let rows: [[Int]]
        /// Frames are indexed by the original control order, including when
        /// a narrow presentation moves the send button to the first row.
        public let frames: [CGRect]
    }

    public static func plan(idealSizes: [CGSize], proposedWidth: CGFloat?,
                            fittedHeights: [CGFloat]? = nil,
                            horizontalSpacing: CGFloat = 8, rowSpacing: CGFloat = 4,
                            narrowRows: [[Int]]? = nil) -> Plan {
        guard !idealSizes.isEmpty else { return Plan(size: .zero, rows: [], frames: []) }
        func dimension(_ value: CGFloat) -> CGFloat { value.isFinite ? max(0, value) : 0 }
        func add(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
            let value = lhs + rhs
            return value.isFinite ? value : .greatestFiniteMagnitude
        }
        let sizes = idealSizes.map { CGSize(width: dimension($0.width), height: dimension($0.height)) }
        let gap = horizontalSpacing.isFinite ? max(0, horizontalSpacing) : 8
        let rowGap = rowSpacing.isFinite ? max(0, rowSpacing) : 4
        func naturalWidth(_ row: [Int]) -> CGFloat {
            row.enumerated().reduce(CGFloat.zero) { total, element in
                add(add(total, element.offset == 0 ? 0 : gap), sizes[element.element].width)
            }
        }
        let all = Array(sizes.indices), idealWidth = naturalWidth(all)
        let width = proposedWidth.flatMap { $0.isFinite ? max(0, $0) : nil } ?? idealWidth
        let rows: [[Int]]
        if idealWidth <= width { rows = [all] }
        else {
            // Never let an incomplete or stale row configuration lose or
            // duplicate an actionable control.
            var used = Set<Int>(), configured: [[Int]] = []
            for proposedRow in narrowRows ?? all.map({ [$0] }) {
                let row = proposedRow.filter { sizes.indices.contains($0) && used.insert($0).inserted }
                if !row.isEmpty { configured.append(row) }
            }
            configured.append(contentsOf: all.filter { !used.contains($0) }.map { [$0] })
            rows = configured
        }
        var frames = Array(repeating: CGRect.zero, count: sizes.count)
        var y: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex > 0 { y = add(y, rowGap) }
            let heights = row.map { index in
                fittedHeights.flatMap { $0.indices.contains(index) ? dimension($0[index]) : nil } ?? sizes[index].height
            }
            let rowHeight = heights.max() ?? 0
            let spare = max(0, width - naturalWidth(row))
            var x: CGFloat = 0
            for (position, index) in row.enumerated() {
                let childWidth = row.count == 1 ? width : sizes[index].width
                frames[index] = CGRect(x: x, y: add(y, max(0, rowHeight - heights[position]) / 2),
                                       width: childWidth, height: heights[position])
                x = add(add(x, childWidth), gap)
                if position == 0 && row.count > 1 { x = add(x, spare) }
            }
            y = add(y, rowHeight)
        }
        return Plan(size: CGSize(width: width, height: y), rows: rows, frames: frames)
    }
}
