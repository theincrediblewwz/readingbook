import SwiftUI
import AppKit

private struct WorkspaceCanvasBlockedKey: EnvironmentKey {
    static let defaultValue = false
}
private struct WorkspaceCanvasExclusionRectsKey: EnvironmentKey {
    static let defaultValue: [CGRect] = []
}
private struct WorkspaceProgressBoundsKey: EnvironmentKey {
    static let defaultValue = CGRect.zero
}

extension EnvironmentValues {
    /// A global overlay owns input until it is dismissed. This does not change
    /// book data or the camera; it only suspends background canvas interaction.
    var workspaceCanvasBlocked: Bool {
        get { self[WorkspaceCanvasBlockedKey.self] }
        set { self[WorkspaceCanvasBlockedKey.self] = newValue }
    }

    /// SwiftUI `.global` rectangles occupied by the workspace command islands.
    /// Each canvas converts these to its own local coordinates. Callers must
    /// not invent navigation padding; the button is only a 48pt exclusion.
    var workspaceCanvasExclusionRects: [CGRect] {
        get { self[WorkspaceCanvasExclusionRectsKey.self] }
        set { self[WorkspaceCanvasExclusionRectsKey.self] = newValue }
    }

    /// Global bounds of the settled progress control. Transient sentence cards
    /// yield to this frame; progress placement never depends on those cards.
    var workspaceProgressBounds: CGRect {
        get { self[WorkspaceProgressBoundsKey.self] }
        set { self[WorkspaceProgressBoundsKey.self] = newValue }
    }
}

/// Only native receivers explicitly belonging to one canvas may opt into its
/// window-level wheel/pinch monitor. A node-list receiver uses the same pointer
/// bridge but has no canvas ID, so it remains owned by its surrounding panel.
@MainActor protocol WorkspaceCanvasInputTarget: AnyObject {
    var canvasInputID: UUID? { get }
}

/// One native coordinate space for every background, node body and port in a
/// canvas. AppKit performs the actual conversion through SwiftUI's scaled and
/// positioned hosting views; callers never reapply zoom or invent a layout gap.
@MainActor enum WorkspaceCanvasInputRegions {
    private final class Region {
        weak var viewport: NSView?
        var exclusions: [CGRect]
        init(viewport: NSView, exclusions: [CGRect]) { self.viewport = viewport; self.exclusions = exclusions }
    }
    private static var regions: [UUID: Region] = [:]

    static func register(_ viewport: NSView, id: UUID, exclusions: [CGRect]) {
        regions = regions.filter { $0.value.viewport != nil }
        regions[id] = Region(viewport: viewport, exclusions: exclusions)
    }
    static func remove(_ viewport: NSView, id: UUID?) {
        guard let id, regions[id]?.viewport === viewport else { return }
        regions.removeValue(forKey: id)
    }
    static func permits(_ point: CGPoint, in receiver: NSView, canvasID: UUID) -> Bool {
        guard let region = regions[canvasID], let viewport = region.viewport,
              let window = viewport.window, receiver.window === window,
              !viewport.isHiddenOrHasHiddenAncestor else { return false }
        let canvasPoint = viewport.convert(point, from: receiver)
        return viewport.bounds.contains(canvasPoint) && !region.exclusions.contains(where: { $0.contains(canvasPoint) })
    }
}
