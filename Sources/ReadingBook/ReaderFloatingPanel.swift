import SwiftUI
import ReadingCore

/// Only the title handle drags. The original PDF keeps its own scroll and selection.
struct ReaderFloatingPanel<Content: View>: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let icon: String
    var width: CGFloat = 410
    var height: CGFloat = 520
    var trailing = true
    @Binding var isPresented: Bool
    var viewport: CGSize
    var memoryIDOverride: String? = nil
    var bottomReserve: CGFloat = 88
    var avoidRects: [CGRect] = []
    var restoreNearTop = false
    var elevated = false
    var onExpansionChange: (Bool) -> Void = { _ in }
    var onFrameChange: (CGRect) -> Void = { _ in }
    @ViewBuilder var content: () -> Content
    @State private var collapsed = false
    @State private var hasOpened = false
    @State private var savedOrigin: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var dragOrigin: CGPoint?
    @State private var dragHeight: CGFloat?
    @State private var epoch = 0
    @State private var memoryScope: String?
    @State private var initialPresented: Bool?
    @State private var transientPresentation: PanelPresentation?
    @State private var lastReportedFrame: CGRect?
    private struct PanelPresentation: Equatable { var presented: Bool; var collapsed: Bool }
    private var memoryID: String { memoryIDOverride ?? (trailing ? "reader.companion" : "reader.outline") }

    private var panelWidth: CGFloat { min(width, max(240, viewport.width - 100)) }
    private var headerHeight: CGFloat { elevated ? 56 : 52 }
    private var wantedHeight: CGFloat { collapsed ? headerHeight : min(height, max(headerHeight, viewport.height - 88 - bottomReserve)) }
    private var panelHeight: CGFloat { presentationPlacement().height }
    private var origin: CGPoint { presentationPlacement().origin }
    private struct PanelPlacement { var origin: CGPoint; var height: CGFloat }
    private func clamp(_ point: CGPoint, height: CGFloat) -> CGPoint {
        CGPoint(x: min(max(24, point.x), max(24, viewport.width - panelWidth - 24)),
                y: min(max(88, point.y), max(88, viewport.height - height - bottomReserve)))
    }
    /// Avoidance is presentation only. Keep the reader's saved position intact
    /// so it returns when the other floating surface closes or moves away.
    private func presentationPlacement() -> PanelPlacement {
        if let dragOrigin { return PanelPlacement(origin: dragOrigin, height: dragHeight ?? wantedHeight) }
        let proposed = savedOrigin ?? CGPoint(x: trailing ? viewport.width - panelWidth - 24 : 24, y: 100)
        let start = clamp(proposed, height: wantedHeight)
        let obstacles = avoidRects.filter {
            !$0.isEmpty && !$0.isNull && $0.minX.isFinite && $0.maxX.isFinite && $0.minY.isFinite && $0.maxY.isFinite
        }.map { $0.insetBy(dx: -8, dy: -8) }
        func overlap(_ placement: PanelPlacement) -> CGFloat {
            let frame = CGRect(origin: placement.origin, size: CGSize(width: panelWidth, height: placement.height))
            return obstacles.reduce(0) { total, obstacle in
                let intersection = frame.intersection(obstacle)
                return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
            }
        }
        func distance(_ point: CGPoint) -> CGFloat { let dx = point.x - start.x, dy = point.y - start.y; return dx * dx + dy * dy }
        let initial = PanelPlacement(origin: start, height: wantedHeight)
        guard overlap(initial) > 0 else { return initial }
        var candidates = [start, CGPoint(x: 24, y: 88), CGPoint(x: viewport.width - panelWidth - 24, y: 88),
                          CGPoint(x: 24, y: viewport.height - wantedHeight - bottomReserve),
                          CGPoint(x: viewport.width - panelWidth - 24, y: viewport.height - wantedHeight - bottomReserve)]
        for obstacle in obstacles {
            candidates += [CGPoint(x: obstacle.minX - panelWidth, y: start.y), CGPoint(x: obstacle.maxX, y: start.y),
                           CGPoint(x: start.x, y: obstacle.minY - wantedHeight), CGPoint(x: start.x, y: obstacle.maxY)]
        }
        let full = candidates.map { PanelPlacement(origin: clamp($0, height: wantedHeight), height: wantedHeight) }
        if let clear = full.filter({ overlap($0) == 0 }).min(by: { distance($0.origin) < distance($1.origin) }) { return clear }

        // No full-height slot fits: examine free vertical bands at each useful
        // horizontal position, keeping at least the closeable title handle.
        var shorter: [PanelPlacement] = []
        let lowerBound: CGFloat = 88, upperBound = max(88 + headerHeight, viewport.height - bottomReserve)
        for candidate in candidates {
            let x = clamp(candidate, height: headerHeight).x
            let blockers = obstacles.filter { $0.maxX > x && $0.minX < x + panelWidth && $0.maxY > lowerBound && $0.minY < upperBound }
                .sorted { $0.minY < $1.minY }
            var cursor = lowerBound
            func appendBand(_ top: CGFloat, _ bottom: CGFloat) {
                guard bottom - top >= headerHeight else { return }
                let availableHeight = min(wantedHeight, bottom - top)
                let y = min(max(start.y, top), bottom - availableHeight)
                shorter.append(PanelPlacement(origin: CGPoint(x: x, y: y), height: availableHeight))
            }
            for blocker in blockers {
                let top = max(lowerBound, blocker.minY), bottom = min(upperBound, blocker.maxY)
                if top > cursor { appendBand(cursor, top) }
                cursor = max(cursor, bottom)
            }
            appendBand(cursor, upperBound)
        }
        if let clear = shorter.max(by: { lhs, rhs in
            lhs.height == rhs.height ? distance(lhs.origin) > distance(rhs.origin) : lhs.height < rhs.height
        }) { return clear }
        // Extremely small windows may have no entirely clear title slot. Keep
        // the header visible at the least obstructed candidate instead of hiding it.
        return candidates.map { PanelPlacement(origin: clamp($0, height: headerHeight), height: headerHeight) }.min { lhs, rhs in
            let a = overlap(lhs), b = overlap(rhs)
            return a == b ? distance(lhs.origin) < distance(rhs.origin) : a < b
        } ?? PanelPlacement(origin: start, height: headerHeight)
    }
    private var restoreButtonPosition: CGPoint {
        let preferred = CGPoint(x: trailing ? viewport.width - 90 : 90,
                                y: trailing && !restoreNearTop ? viewport.height - bottomReserve - 26 : 128)
        func fit(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(114, point.x), max(114, viewport.width - 114)),
                    y: min(max(110, point.y), max(110, viewport.height - bottomReserve - 22)))
        }
        let points = [preferred, CGPoint(x: 114, y: 110), CGPoint(x: viewport.width - 114, y: 110),
                      CGPoint(x: 114, y: viewport.height - bottomReserve - 22),
                      CGPoint(x: viewport.width - 114, y: viewport.height - bottomReserve - 22)].map(fit)
        func overlap(_ point: CGPoint) -> CGFloat {
            let frame = CGRect(x: point.x - 90, y: point.y - 22, width: 180, height: 44)
            return avoidRects.filter { !$0.isEmpty && !$0.isNull }.reduce(0) { total, obstacle in
                let intersection = frame.intersection(obstacle.insetBy(dx: -8, dy: -8))
                return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
            }
        }
        func distance(_ point: CGPoint) -> CGFloat { let dx = point.x - preferred.x, dy = point.y - preferred.y; return dx * dx + dy * dy }
        return points.min { lhs, rhs in
            let a = overlap(lhs), b = overlap(rhs)
            return a == b ? distance(lhs) < distance(rhs) : a < b
        } ?? fit(preferred)
    }
    /// The host can establish one-way avoidance priorities. Publish only the
    /// settled frame, never the pointer's intermediate positions.
    private func reportStableFrame() {
        guard dragOrigin == nil && dragStart == nil else { return }
        let frame: CGRect
        if isPresented {
            let placement = presentationPlacement()
            frame = CGRect(origin: placement.origin, size: CGSize(width: panelWidth, height: placement.height))
        } else if hasOpened {
            let center = restoreButtonPosition
            frame = CGRect(x: center.x - 90, y: center.y - 22, width: 180, height: 44)
        } else { frame = .zero }
        guard lastReportedFrame != frame else { return }
        lastReportedFrame = frame; onFrameChange(frame)
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
                // Keep the panel's contents mounted while collapsed or closed.
                // Frozen input scopes and unsaved adjustment fields survive a
                // temporary hide; hidden surfaces never receive pointer input.
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal").font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Rectangle())
                            .overlay {
                                FloatingPanelPointerInput(epoch: epoch, begin: {
                                    transientPresentation = nil
                                    let placement = presentationPlacement(); dragStart = placement.origin; dragOrigin = placement.origin; dragHeight = placement.height
                                }, drag: { delta, finished in
                                    let start = dragStart ?? origin
                                    dragOrigin = clamp(CGPoint(x: start.x + delta.width, y: start.y + delta.height), height: dragHeight ?? wantedHeight)
                                    if finished { savedOrigin = dragOrigin; dragStart = nil; dragOrigin = nil; dragHeight = nil; reportStableFrame() }
                                }, cancel: { dragStart = nil; dragOrigin = nil; dragHeight = nil; reportStableFrame() })
                            }
                            .help("拖动\(title)面板").accessibilityLabel("拖动\(title)面板")
                        Label(title, systemImage: icon).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        Button { transientPresentation = nil; collapsed.toggle() } label: { Image(systemName: collapsed ? "plus" : "minus") }.buttonStyle(ReadingToolbarButtonStyle()).help(collapsed ? "展开\(title)" : "收起\(title)")
                        Button { transientPresentation = nil; isPresented = false } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("关闭\(title)")
                    }.padding(.leading, 16).padding(.trailing, 8).frame(height: headerHeight).layoutPriority(1)
                    content().frame(maxWidth: .infinity).frame(minHeight: 0, maxHeight: collapsed ? 0 : .infinity)
                        .opacity(collapsed ? 0 : 1).clipped().allowsHitTesting(!collapsed).accessibilityHidden(collapsed || panelHeight <= headerHeight)
                }.frame(width: panelWidth, height: panelHeight).readingGlass(radius: 24)
                    .overlay {
                        RoundedRectangle(cornerRadius: 24).strokeBorder(Palette.accent.opacity(elevated ? 0.13 : 0), lineWidth: 0.7).allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24)).position(x: origin.x + panelWidth / 2, y: origin.y + panelHeight / 2)
                    .opacity(isPresented ? 1 : 0).scaleEffect(isPresented || reduceMotion ? 1 : 0.97, anchor: trailing ? .topTrailing : .topLeading)
                    .allowsHitTesting(isPresented).accessibilityHidden(!isPresented)
            if !isPresented && hasOpened {
                Button { transientPresentation = nil; collapsed = false; isPresented = true } label: { Label(title, systemImage: icon).lineLimit(1).frame(maxWidth: 140) }
                    .buttonStyle(ReadingToolbarButtonStyle()).readingGlass(radius: 18)
                    .position(restoreButtonPosition)
                    .transition(.opacity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // These keys animate opening only. Pointer-driven origins never acquire an animation.
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: isPresented)
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: collapsed)
            .onAppear { initialPresented = isPresented; restoreMemory(); if viewport.width < 1050 && trailing { isPresented = false }; receivePanelCommand(store.workspaceAICommand); reportStableFrame() }
            .onChange(of: store.workspaceAICommand) { _, command in receivePanelCommand(command) }
            .onChange(of: store.workspaceMemoryRevision) { _, _ in restoreMemory(); reportStableFrame() }
            .onChange(of: collapsed) { _, value in onExpansionChange(!value && isPresented); saveMemory(); reportStableFrame() }
            .onChange(of: isPresented) { _, value in if value { hasOpened = true }; onExpansionChange(value && !collapsed); saveMemory(); reportStableFrame() }
            .onChange(of: savedOrigin) { _, _ in saveMemory(); reportStableFrame() }
            .onChange(of: avoidRects) { _, _ in reportStableFrame() }
            .onDisappear { saveMemory(); lastReportedFrame = nil; onFrameChange(.zero) }
            .onChange(of: viewport) { old, value in
                epoch += 1; dragStart = nil; dragOrigin = nil; dragHeight = nil
                if old.width >= 1050, value.width < 1050, trailing { isPresented = false }
                reportStableFrame()
            }
    }
    private func restoreMemory() {
        transientPresentation = nil
        if memoryScope != store.workspaceMemoryKey { lastReportedFrame = nil }
        memoryScope = store.workspaceMemoryKey
        let saved = store.workspaceMemory.panels[memoryID]
        collapsed = saved?.collapsed ?? false
        savedOrigin = saved?.origin.map { CGPoint(x: $0.x, y: $0.y) }
        isPresented = saved?.isPresented ?? initialPresented ?? false
        if isPresented || saved != nil { hasOpened = true }
        onExpansionChange(isPresented && !collapsed)
    }
    private func saveMemory() {
        guard let memoryScope else { return }
        if transientPresentation == PanelPresentation(presented: isPresented, collapsed: collapsed) { return }
        transientPresentation = nil
        let memory = WorkspacePanelMemory(origin: savedOrigin.map { WorkspacePoint(x: $0.x, y: $0.y) }, isPresented: isPresented, collapsed: collapsed)
        store.updateWorkspaceMemory({ $0.panels[memoryID] = memory }, expectedKey: memoryScope)
    }
    private func receivePanelCommand(_ command: WorkspaceAICommand?) {
        guard let command, command.name == "panel_present",
              let args = try? JSONSerialization.jsonObject(with: command.arguments) as? [String: Any],
              args["panelID"] as? String == memoryID else { return }
        guard let state = args["state"] as? String, ["open", "collapse", "close"].contains(state) else {
            store.acknowledgeViewCommand(command, status: "unsupported", message: "面板状态必须为 open、collapse 或 close。")
            return
        }
        let requested = PanelPresentation(presented: state != "close", collapsed: state == "collapse")
        transientPresentation = requested
        isPresented = requested.presented
        guard isPresented == requested.presented else {
            transientPresentation = nil
            store.acknowledgeViewCommand(command, status: "needs_confirmation", message: "面板有尚未保存的调整，等待读者保存或放弃；没有关闭。")
            return
        }
        if state != "close" { collapsed = requested.collapsed }
        // Closing retains the previous collapse preference, so compare that
        // actual state when suppressing this temporary AI change's persistence.
        transientPresentation = PanelPresentation(presented: isPresented, collapsed: collapsed)
        store.acknowledgeViewCommand(command, message: state == "close" ? "面板已关闭，可从恢复入口重新打开。" : state == "collapse" ? "面板已收起。" : "面板已展开。")
    }
}
