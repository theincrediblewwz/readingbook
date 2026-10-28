import SwiftUI
import ReadingCore

/// Unlike alternative ViewThatFits trees, one set of native menus stays
/// mounted while this layout chooses their rows. Measurement does not publish
/// state or construct another set of controls.
struct ReadingAdaptiveRows: Layout {
    var horizontalSpacing: CGFloat = 8
    var rowSpacing: CGFloat = 4
    var narrowRows: [[Int]]? = nil

    struct Cache {
        var idealSizes: [CGSize]
        var plan: ReadingControlRowsGeometry.Plan?
        var key: PlanKey?
    }
    struct PlanKey: Equatable {
        var width: CGFloat?
        var horizontalSpacing: CGFloat
        var rowSpacing: CGFloat
        var narrowRows: [[Int]]?
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(idealSizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        measuredPlan(width: proposal.width, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let plan = measuredPlan(width: bounds.width, subviews: subviews, cache: &cache)
        for index in subviews.indices {
            let frame = plan.frames[index]
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func measuredPlan(width: CGFloat?, subviews: Subviews, cache: inout Cache) -> ReadingControlRowsGeometry.Plan {
        if cache.idealSizes.count != subviews.count { cache = makeCache(subviews: subviews) }
        let finiteWidth = width.flatMap { $0.isFinite ? max(0, $0) : nil }
        let key = PlanKey(width: finiteWidth,
            horizontalSpacing: horizontalSpacing.isFinite ? max(0, horizontalSpacing) : 8,
            rowSpacing: rowSpacing.isFinite ? max(0, rowSpacing) : 4, narrowRows: narrowRows)
        if cache.key == key, let plan = cache.plan { return plan }
        let initial = ReadingControlRowsGeometry.plan(idealSizes: cache.idealSizes, proposedWidth: finiteWidth,
            horizontalSpacing: horizontalSpacing, rowSpacing: rowSpacing, narrowRows: narrowRows)
        // A group placed alone receives the available width. Measure its
        // resulting height so nested rows and wrapping text remain visible.
        let heights = subviews.indices.map { index in
            subviews[index].sizeThatFits(ProposedViewSize(width: initial.frames[index].width, height: nil)).height
        }
        let plan = ReadingControlRowsGeometry.plan(idealSizes: cache.idealSizes, proposedWidth: finiteWidth,
            fittedHeights: heights, horizontalSpacing: horizontalSpacing, rowSpacing: rowSpacing, narrowRows: narrowRows)
        cache.key = key; cache.plan = plan
        return plan
    }
}
