import SwiftUI
import Foundation
import AppKit
import ReadingCore

struct GraphItem: Identifiable, Equatable {
    var id: String
    var targetID: String
    var title: String
    var subtitle: String
    var x: Double
    var y: Double
    var documentIDs: [String] = []
}
struct GraphLine: Identifiable, Equatable { var id: String; var from: String; var to: String; var label: String }

/// Camera movement reuses data indices and edge lanes. These caches are only
/// presentation data and never publish a model change during a render.
private final class GraphRenderCache {
    private var items: [GraphItem] = []
    private var lines: [GraphLine] = []
    var byID: [String: GraphItem] = [:]
    var identities = GraphIdentityIndex(nodes: [])
    var lanes: [String: CGFloat] = [:]
    var incident: [String: [GraphLine]] = [:]
    private var memorySave: Task<Void, Never>?
    func cancelMemorySave() { memorySave?.cancel(); memorySave = nil }
    func queueCameraMemory(store: AppStore, scope: String, id: String, camera: GraphCamera) {
        cancelMemorySave()
        let value = WorkspaceGraphCamera(center: WorkspacePoint(x: camera.center.x, y: camera.center.y), scale: camera.scale)
        memorySave = Task { @MainActor [weak store] in
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            store?.updateWorkspaceMemory({ $0.graphs[id] = value }, expectedKey: scope)
        }
    }
    deinit { memorySave?.cancel() }
    func update(items: [GraphItem], lines: [GraphLine]) {
        if self.items != items {
            self.items = items
            byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            identities = GraphIdentityIndex(nodes: items.map { (nodeID: $0.id, targetID: $0.targetID) })
        }
        if self.lines != lines {
            self.lines = lines; lanes = [:]; incident = [:]
            for line in lines { incident[line.from, default: []].append(line); if line.to != line.from { incident[line.to, default: []].append(line) } }
            for group in Dictionary(grouping: lines, by: { [$0.from, $0.to].sorted().joined(separator: "|") }).values {
                for (offset, line) in group.sorted(by: { $0.id < $1.id }).enumerated() {
                    let lane = (CGFloat(offset) - CGFloat(group.count - 1) / 2) * 32
                    lanes[line.id] = line.from < line.to ? lane : -lane
                }
            }
        }
    }
}

/// Canvas identity is the node ID; opening content uses the separate target ID.
/// Body dragging moves a card. Its edge ports own a separate connection gesture.
struct GraphSurface: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("frost-navigation-dock-v1") private var navigationDock = NavigationOrbDock.topLeading.rawValue
    var items: [GraphItem]
    var lines: [GraphLine]
    var selectedID: String?
    var select: (String) -> Void
    var open: ((String) -> Void)? = nil
    var move: ((String, Double, Double) async -> Bool)? = nil
    var remove: ((String) -> Void)? = nil
    var connect: ((String, String) async -> Bool)? = nil
    var renameLine: ((String, String) async -> Bool)? = nil
    var removeLine: ((String) async -> Bool)? = nil
    var deselect: (() -> Void)? = nil
    var inspect: ((String) -> Void)? = nil
    var createDocument: (() -> Void)? = nil
    var title: String? = nil
    var isEnabled = true
    var errorText: (() -> String?)? = nil
    /// Focus requests use the physical node ID, which may differ from its document.
    var focusNodeID: String? = nil
    var focusRequestToken: UUID? = nil
    var selectedNodeIDChanged: ((String?) -> Void)? = nil
    var interactionExclusion: CGRect? = nil
    var obscuredLeadingWidth: CGFloat = 0
    var obscuredTrailingWidth: CGFloat = 0
    var scopeTitle: String? = nil
    var toggleScope: (() -> Void)? = nil
    var ambientMotion = false
    var openPhysicalNode: ((String) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var canvasHovered = false
    @Environment(\.workspaceCanvasBlocked) private var workspaceCanvasBlocked
    @Environment(\.workspaceCanvasExclusionRects) private var workspaceCanvasExclusionRects

    private struct NodeDrag {
        var id: String
        var origin: CGPoint
        var position: CGPoint
        var scale: CGFloat
    }
    @State private var nodeDragState: NodeDrag?
    @State private var camera = GraphCamera()
    @State private var viewportSize = CGSize.zero
    @State private var controlsRect = CGRect.zero
    @State private var cameraInitialized = false
    @State private var memoryScope: String?
    @State private var renderCache = GraphRenderCache()
    @State private var panOrigin: GraphCamera?
    @State private var connectionDragScale: CGFloat?
    @State private var gestureEpoch = 0
    @State private var selectedNodeID: String?
    @State private var connectionFromID: String?
    @State private var connectionSide: PortSide = .trailing
    @State private var connectionPoint: CGPoint?
    @State private var connectionTargetID: String?
    @State private var draggingConnection = false
    @State private var savingConnection = false
    @State private var savingPosition = false
    @State private var editingLineID: String?
    @State private var lineDraft = ""
    @State private var savingLine = false
    @State private var message = ""
    @State private var canvasInputID = UUID()
    @FocusState private var focus: FocusTarget?
    private enum FocusTarget: Hashable { case node(String), port(String, PortSide), line(String) }
    private enum PortSide: Hashable { case leading, trailing }
    private let nodeSize = CGSize(width: 232, height: 100)
    private var acceptsCanvasInput: Bool { isEnabled && !workspaceCanvasBlocked }
    private var canNavigate: Bool {
        acceptsCanvasInput && nodeDragState == nil && !draggingConnection && !savingPosition && !savingConnection && !savingLine && editingLineID == nil
    }
    private func point(_ item: GraphItem, phase: Double? = nil) -> CGPoint {
        let location = nodeDragState?.id == item.id ? nodeDragState!.position : CGPoint(x: item.x, y: item.y)
        let seed = Double(item.id.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 997 }) / 73
        let drift = phase.map { CGPoint(x: sin($0 + seed) * 4, y: cos($0 * 0.73 + seed * 1.7) * 3) } ?? .zero
        return CGPoint(x: location.x + nodeSize.width / 2 + drift.x, y: location.y + nodeSize.height / 2 + drift.y)
    }
    private func rect(_ item: GraphItem, phase: Double? = nil) -> CGRect {
        let center = point(item, phase: phase)
        return CGRect(x: center.x - nodeSize.width / 2, y: center.y - nodeSize.height / 2, width: nodeSize.width, height: nodeSize.height)
    }
    private var selectedPhysicalID: String? {
        renderCache.identities.selectedNode(targetID: selectedID, preferredNodeID: selectedNodeID)
    }
    private func renderedLines(phase: Double? = nil) -> [RenderedGraphLine] {
        return lines.compactMap { line in
            guard let from = renderCache.byID[line.from], let to = renderCache.byID[line.to] else { return nil }
            let a = anchor(rect(from, phase: phase), towards: point(to, phase: phase)), b = anchor(rect(to, phase: phase), towards: point(from, phase: phase))
            return RenderedGraphLine(line: line, curve: GraphCurve(start: a.point, end: b.point, startNormal: a.normal, endNormal: b.normal, lane: renderCache.lanes[line.id] ?? 0))
        }
    }
    var body: some View {
        let _ = renderCache.update(items: items, lines: lines)
        GeometryReader { geometry in
            let globalFrame = geometry.frame(in: .global)
            let workspaceExclusions = workspaceCanvasExclusionRects.filter { !$0.isNull && !$0.isInfinite && !$0.isEmpty }
                .map { $0.offsetBy(dx: -globalFrame.minX, dy: -globalFrame.minY) }
            let visibility = visibilitySnapshot(in: geometry.size, exclusions: workspaceExclusions + [interactionExclusion].compactMap { $0 })
            ZStack(alignment: .topLeading) {
                Palette.canvas
                grid(in: geometry.size)
                GraphPointerBridge(enabled: canNavigate, movable: true, resetID: gestureEpoch, exclusion: interactionExclusion,
                                   additionalExclusions: workspaceExclusions, canvasID: canvasInputID,
                                   click: { _ in backgroundTapped() }, drag: { updatePan(delta: $0, ended: $1) },
                                   cancel: { cancelPan() })
                    .contextMenu { if let createDocument { Button("新建笔记") { createDocument() } } }
                GraphViewportInput(enabled: canNavigate, canvasID: canvasInputID,
                                   exclusions: workspaceExclusions + [interactionExclusion, controlsRect.isEmpty ? nil : controlsRect].compactMap { $0 },
                                   scroll: { panViewport(by: $0) }, zoom: { zoomViewport(by: $0, at: $1) })
                GraphAmbientLayer(active: ambientMotion && !reduceMotion && scenePhase == .active && canNavigate
                                  && !canvasHovered && selectedID == nil && focus == nil && items.count <= 80) { phase in
                let motion = ambientMotion && !reduceMotion && items.count <= 80 ? phase : nil
                let rendered = renderedLines(phase: motion)
                ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.translateBy(x: geometry.size.width / 2 - camera.center.x * camera.scale,
                                        y: geometry.size.height / 2 - camera.center.y * camera.scale)
                    context.scaleBy(x: camera.scale, y: camera.scale)
                    for edge in rendered {
                        context.stroke(edge.curve.path, with: .color(Palette.accent.opacity(0.55)), lineWidth: 1.5)
                        context.fill(edge.curve.arrow, with: .color(Palette.accent.opacity(0.65)))
                    }
                    if let curve = previewCurve {
                        context.stroke(curve.path, with: .color(Palette.copper), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        context.fill(curve.arrow, with: .color(Palette.copper))
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
                ForEach(rendered.filter { labelVisible($0, in: geometry.size) }) { edge in
                    edgeLabel(edge).scaleEffect(camera.scale)
                        .position(camera.screen(CGPoint(x: edge.curve.middle.x, y: edge.curve.middle.y - 11), in: geometry.size))
                }
                ForEach(visibleItems(in: geometry.size)) { item in
                    nodeShell(item).scaleEffect(camera.scale)
                        .position(camera.screen(point(item, phase: motion), in: geometry.size)).zIndex(item.id == selectedPhysicalID ? 2 : 1)
                }
                }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            .transaction { $0.animation = nil }
            .overlay(alignment: .bottomLeading) {
                statusOverlay.lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: min(300, statusWidth(in: geometry.size)), alignment: .leading)
                    .padding(.leading, geometry.size.width >= 1050 && navigationDock == NavigationOrbDock.bottomLeading.rawValue ? 80 : 24)
                    .padding(.bottom, geometry.size.width < 1050 ? 96 : 24).allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                cameraControls.background {
                    GeometryReader { controls in
                        Color.clear.preference(key: GraphControlsFrameKey.self, value: controls.frame(in: .named("graph-viewport")))
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            .coordinateSpace(name: "graph-viewport")
            .onPreferenceChange(GraphControlsFrameKey.self) { controlsRect = $0 }
            .task(id: visibility) {
                guard !Task.isCancelled else { return }
                store.renderedWorkspaceVisibility = visibility
            }
            .onContinuousHover { phase in
                if case .active = phase { canvasHovered = true } else { canvasHovered = false }
                guard acceptsCanvasInput, connectionFromID != nil, !draggingConnection, !savingConnection else { return }
                switch phase {
                case .active(let location):
                    if interactionExclusion?.contains(location) == true || controlsRect.contains(location) || workspaceExclusions.contains(where: { $0.contains(location) }) { connectionPoint = nil; connectionTargetID = nil }
                    else { updateConnection(at: camera.world(location, in: geometry.size)) }
                case .ended: connectionPoint = nil; connectionTargetID = nil
                }
            }
            .onAppear {
                viewportSize = geometry.size
                if !cameraInitialized {
                    restoreCameraMemory()
                    // Widely separated saved nodes remain untouched. Show a
                    // readable starting area; “show all” remains explicit.
                    if store.workspaceMemory.graphs[title ?? store.route] == nil, camera.scale < 0.72, let first = items.first(where: { $0.targetID == selectedID }) ?? items.first {
                        camera.scale = 0.9
                        camera.focus(point(first), in: viewportSize, obscuredLeadingWidth: obscuredLeadingWidth, obscuredTrailingWidth: obscuredTrailingWidth)
                    }
                    cameraInitialized = true; focusRequestedNode()
                }
            }
            .onChange(of: geometry.size) { _, size in
                cancelTransientInteractions(); viewportSize = size
                // Center remains a world point when the window resizes. Never
                // refit automatically and move a user's carefully arranged view.
            }
        }
        .onExitCommand {
            guard !savingLine, !savingConnection else { return }
            if editingLineID != nil { editingLineID = nil; focus = nil; message = "" }
            else { cancelTransientInteractions() }
        }
        .onChange(of: isEnabled) { _, enabled in if !enabled { cancelTransientInteractions() } }
        .onChange(of: camera) { _, _ in
            guard cameraInitialized, let memoryScope else { return }
            // Keep high-frequency camera changes local to this surface; the
            // whole AppStore need not republish on every wheel/pinch frame.
            renderCache.queueCameraMemory(store: store, scope: memoryScope, id: title ?? store.route, camera: camera)
        }
        .onChange(of: store.workspaceMemoryRevision) { _, _ in cancelTransientInteractions(); restoreCameraMemory() }
        .onChange(of: workspaceCanvasBlocked) { _, blocked in if blocked { cancelTransientInteractions() } }
        .onChange(of: obscuredLeadingWidth) { old, _ in reframeCamera(previousLeadingWidth: old, previousTrailingWidth: obscuredTrailingWidth) }
        .onChange(of: obscuredTrailingWidth) { old, _ in reframeCamera(previousLeadingWidth: obscuredLeadingWidth, previousTrailingWidth: old) }
        .onChange(of: focusNodeID) { _, _ in focusRequestedNode() }
        .onChange(of: focusRequestToken) { _, _ in focusRequestedNode() }
        .onChange(of: store.workspaceAICommand) { _, command in
            guard let command, command.name == "graph_focus", let data = try? JSONSerialization.jsonObject(with: command.arguments) as? [String: Any] else { return }
            guard !workspaceCanvasBlocked, nodeDragState == nil, panOrigin == nil, !savingPosition, !savingConnection, !savingLine else {
                store.acknowledgeViewCommand(command, status: "busy", message: "画布正在操作，未改变相机。"); return
            }
            let ids = (data["nodeIDs"] as? [String]) ?? (data["nodeID"] as? String).map { [$0] } ?? []
            let targets = items.filter { ids.contains($0.id) }
            guard !targets.isEmpty, Set(targets.map(\.id)) == Set(ids) else { store.acknowledgeViewCommand(command, status: "unsupported", message: "物理节点不存在于当前画布。"); return }
            let bounds = targets.map { rect($0) }.reduce(CGRect.null) { $0.union($1) }
            camera.fit(bounds, in: viewportSize, obscuredLeadingWidth: obscuredLeadingWidth, obscuredTrailingWidth: obscuredTrailingWidth)
            if let first = targets.first { setPhysicalSelection(first.id); select(first.targetID) }
            store.acknowledgeViewCommand(command, message: "已聚焦真实节点；保存坐标未改变。")
        }
        .onChange(of: items.map(\.id)) { _, ids in
            if let id = connectionFromID, !ids.contains(id) { cancelConnection() }
            if let id = selectedNodeID, !ids.contains(id) { setPhysicalSelection(nil) }
            if let drag = nodeDragState, !ids.contains(drag.id) { nodeDragState = nil; gestureEpoch += 1 }
        }
        .onChange(of: lines.map(\.id)) { _, ids in if let id = editingLineID, !ids.contains(id) { editingLineID = nil } }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ReadingBookCaptureWorkspaceMemory"))) { _ in saveCameraMemory() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in cancelTransientInteractions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in cancelTransientInteractions() }
        .onDisappear {
            saveCameraMemory(); cancelTransientInteractions(); editingLineID = nil
            if store.renderedWorkspaceVisibility?.rendererID == store.route { store.renderedWorkspaceVisibility = nil; store.renderedSelectedNodeIDs = [] }
        }
    }
    private func restoreCameraMemory() {
        renderCache.cancelMemorySave()
        memoryScope = store.workspaceMemoryKey
        if let saved = store.workspaceMemory.graphs[title ?? store.route], saved.isValid {
            camera = GraphCamera(center: CGPoint(x: saved.center.x, y: saved.center.y), scale: saved.scale)
        } else {
            let bounds = items.map { rect($0) }.reduce(CGRect.null) { $0.union($1) }
            camera.fit(bounds.isNull ? CGRect(origin: .zero, size: nodeSize) : bounds, in: viewportSize, obscuredLeadingWidth: obscuredLeadingWidth, obscuredTrailingWidth: obscuredTrailingWidth)
        }
    }
    private func saveCameraMemory() {
        renderCache.cancelMemorySave()
        guard cameraInitialized, let memoryScope else { return }
        let saved = WorkspaceGraphCamera(center: WorkspacePoint(x: camera.center.x, y: camera.center.y), scale: camera.scale)
        store.updateWorkspaceMemory({ $0.graphs[title ?? store.route] = saved }, expectedKey: memoryScope)
    }
    private func visibleItems(in size: CGSize) -> [GraphItem] {
        let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -max(240, nodeSize.width / 2 * camera.scale + 24), dy: -max(100, nodeSize.height / 2 * camera.scale + 24))
        return items.filter { item in
            if nodeDragState?.id == item.id { return true } // Keep the native drag receiver alive offscreen.
            let position = camera.screen(point(item), in: size)
            return viewport.contains(position)
        }
    }
    private func visibilitySnapshot(in size: CGSize, exclusions: [CGRect]) -> ReadingVisibleObjectsSnapshot {
        let viewport = CGRect(origin: .zero, size: size)
        var partial = false
        let visible = items.filter { item in
            let origin = camera.screen(CGPoint(x: item.x, y: item.y), in: size)
            let bounds = CGRect(origin: origin, size: CGSize(width: nodeSize.width * camera.scale, height: nodeSize.height * camera.scale))
            let clipped = bounds.intersection(viewport)
            guard !clipped.isNull, !clipped.isEmpty, !exclusions.contains(where: { $0.contains(clipped) }) else { return false }
            if !viewport.contains(bounds) || exclusions.contains(where: { $0.intersects(clipped) }) { partial = true }
            return true
        }
        return ReadingVisibleObjectsSnapshot(rendererID: store.route, objectIDs: Array(Set(visible.map(\.targetID))).sorted(),
            partial: partial || ambientMotion, description: "渲染节点矩形与视口相交，排除浮窗完全遮挡；部分遮挡单独标明。可见不代表正文已读。", nodeIDs: visible.map(\.id))
    }
    private func labelVisible(_ edge: RenderedGraphLine, in size: CGSize) -> Bool {
        if editingLineID == edge.id { return true }
        let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -max(180, 90 * camera.scale), dy: -max(60, 25 * camera.scale))
        return viewport.contains(camera.screen(edge.curve.middle, in: size))
    }
    private func grid(in size: CGSize) -> some View {
        // One small cached image repeats only across the viewport. Its phase
        // follows the camera, with adaptive spacing at distant zoom levels.
        let scaled = 24 * camera.scale
        let period = scaled * pow(2, ceil(log2(18 / max(0.000001, scaled))))
        let origin = camera.screen(.zero, in: size)
        let x = origin.x.truncatingRemainder(dividingBy: period), y = origin.y.truncatingRemainder(dividingBy: period)
        return Rectangle().fill(ImagePaint(image: Image(nsImage: GraphGridTile.image), scale: period / 24))
            .frame(width: size.width + period * 4, height: size.height + period * 4)
            .offset(x: x - period * 2, y: y - period * 2).opacity(0.18)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
    private var cameraControls: some View {
        HStack(spacing: ReadingLayout.groupSpacing) {
            Button { zoomViewport(by: 1 / 1.25, at: usableCenter) } label: { Image(systemName: "minus") }
                .help("缩小画布").accessibilityLabel("缩小画布")
            Button { zoomViewport(by: 1 / camera.scale, at: usableCenter) } label: {
                Text(Double(camera.scale).formatted(.percent.precision(.fractionLength(camera.scale < 0.01 ? 2 : 0))))
                    .monospacedDigit().font(.system(size: 13, weight: .medium)).frame(minWidth: 50)
            }.help("恢复 100% 缩放")
            Button { zoomViewport(by: 1.25, at: usableCenter) } label: { Image(systemName: "plus") }
                .help("放大画布").accessibilityLabel("放大画布")
            Divider().frame(height: 18).padding(.horizontal, 2)
            Button { fitAll() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("显示全部节点").accessibilityLabel("显示全部节点")
            Button { centerSelection() } label: { Image(systemName: "scope") }
                .disabled(selectedPhysicalID == nil).help("定位选中节点").accessibilityLabel("定位选中节点")
            if let scopeTitle, let toggleScope {
                Divider().frame(height: 18).padding(.horizontal, 2)
                Button(action: toggleScope) { Label(scopeTitle, systemImage: "line.3.horizontal.decrease") }.help("切换全书关系与当前原文关系")
            }
            if let createDocument {
                Divider().frame(height: 18).padding(.horizontal, 2)
                Button(action: createDocument) { Label("新建节点", systemImage: "plus") }.help("新建 Markdown 笔记与节点")
            }
        }
        .buttonStyle(ReadingToolbarButtonStyle()).padding(7).readingGlass(radius: 30)
        .disabled(!canNavigate).help("拖动空白或双指平移 · 捏合或 ⌘ 滚轮缩放")
    }
    private var usableCenter: CGPoint {
        let usable = GraphCamera.usableRect(in: viewportSize, obscuredLeadingWidth: obscuredLeadingWidth, obscuredTrailingWidth: obscuredTrailingWidth)
        return CGPoint(x: usable.midX, y: usable.midY)
    }
    private func statusWidth(in size: CGSize) -> CGFloat {
        // The collapsed browser still owns its top-right button. Long status
        // messages must wrap before that button even when it no longer narrows
        // the camera's usable area.
        let trailing = max(obscuredTrailingWidth, interactionExclusion.map { size.width - $0.minX } ?? 0)
        return max(80, GraphCamera.usableRect(in: size, obscuredLeadingWidth: obscuredLeadingWidth, obscuredTrailingWidth: trailing).width - 24)
    }
    private func reframeCamera(previousLeadingWidth: CGFloat, previousTrailingWidth: CGFloat) {
        guard cameraInitialized, viewportSize.width > 0 else { return }
        cancelTransientInteractions()
        let previous = GraphCamera.usableRect(in: viewportSize, obscuredLeadingWidth: previousLeadingWidth, obscuredTrailingWidth: previousTrailingWidth)
        let visibleCenter = camera.world(CGPoint(x: previous.midX, y: previous.midY), in: viewportSize)
        // Opening or closing the browser keeps the same world point in the
        // usable center and retains the user's zoom, rather than refitting.
        camera.focus(visibleCenter, in: viewportSize, obscuredLeadingWidth: obscuredLeadingWidth, obscuredTrailingWidth: obscuredTrailingWidth)
    }
    private func fitAll() {
        guard canNavigate, viewportSize.width > 0 else { return }
        let bounds = items.map { rect($0) }.reduce(CGRect.null) { $0.union($1) }
        camera.fit(bounds.isNull ? CGRect(origin: .zero, size: nodeSize) : bounds, in: viewportSize, obscuredLeadingWidth: obscuredLeadingWidth, obscuredTrailingWidth: obscuredTrailingWidth)
        connectionPoint = nil; connectionTargetID = nil
    }
    private func centerSelection() {
        guard canNavigate, let selectedPhysicalID, let item = renderCache.byID[selectedPhysicalID] else { return }
        camera.focus(point(item), in: viewportSize, obscuredLeadingWidth: obscuredLeadingWidth, obscuredTrailingWidth: obscuredTrailingWidth)
    }
    private func focusRequestedNode() {
        guard let id = focusNodeID, let item = renderCache.byID[id], !savingPosition, !savingConnection, !savingLine else { return }
        cancelTransientInteractions(); setPhysicalSelection(id)
        camera.focus(point(item), in: viewportSize, obscuredLeadingWidth: obscuredLeadingWidth, obscuredTrailingWidth: obscuredTrailingWidth)
    }
    private func updatePan(delta: CGSize, ended: Bool) {
        guard canNavigate else { return }
        if panOrigin == nil { panOrigin = camera; cancelConnection() }
        guard var next = panOrigin else { return }
        next.pan(by: delta); camera = next
        if ended { panOrigin = nil }
    }
    private func cancelPan() { if let panOrigin { camera = panOrigin }; panOrigin = nil }
    private func panViewport(by delta: CGSize) {
        guard canNavigate, panOrigin == nil else { return }
        camera.pan(by: delta); connectionPoint = nil; connectionTargetID = nil
    }
    private func zoomViewport(by factor: CGFloat, at point: CGPoint) {
        guard canNavigate, panOrigin == nil else { return }
        camera.zoom(by: factor, at: point, in: viewportSize); connectionPoint = nil; connectionTargetID = nil
    }
    private func cancelTransientInteractions() {
        gestureEpoch += 1; cancelPan()
        if !savingPosition { nodeDragState = nil }
        if !savingConnection { cancelConnection() }
    }
    private func setPhysicalSelection(_ id: String?) {
        selectedNodeID = id; selectedNodeIDChanged?(id)
        store.renderedSelectedNodeIDs = id.map { [$0] } ?? []
    }
    @ViewBuilder private var statusOverlay: some View {
        if savingConnection || savingLine { Text("正在保存连线…").font(.caption).padding(9).readingGlass() }
        else if let id = connectionFromID, let source = renderCache.byID[id] {
            Text(message.isEmpty ? "从「\(source.title)」连线 · 点击目标节点，Esc 或点空白取消" : message)
                .font(.caption).padding(9).readingGlass()
        } else if editingLineID != nil {
            Text(message.isEmpty ? "关系名称：回车保存，Esc 取消" : message).font(.caption).padding(9).readingGlass()
        } else if !message.isEmpty { Text(message).font(.caption).padding(9).readingGlass() }
        else if title != nil {
            Text("\(items.count) 个节点 · \(lines.count) 条连线").font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 11).readingGlass(radius: 14)
        }
    }
    private func nodeShell(_ item: GraphItem) -> some View {
        ZStack {
            nodeBody(item).overlay {
                GraphPointerBridge(enabled: acceptsCanvasInput && !savingPosition && !savingConnection && !savingLine,
                                   movable: move != nil && connectionFromID == nil && editingLineID == nil,
                                   reservePorts: connect != nil, resetID: gestureEpoch, canvasID: canvasInputID,
                                   click: { activate(item, opening: $0) },
                                   drag: { updateNodeDrag(item, delta: $0, ended: $1) },
                                   cancel: { if !savingPosition { nodeDragState = nil } })
            }
            .focusable().focusEffectDisabled().focused($focus, equals: .node(item.id))
            .onKeyPress(.return) { activate(item, opening: true); return .handled }
            .onKeyPress(.space) { activate(item); return .handled }
            .contextMenu { nodeMenu(item) }
            .accessibilityLabel("\(item.title)，\(item.subtitle)，节点 \(nodeNumber(item))")
            .accessibilityHint(connect == nil ? "单击选中，双击打开内容。" : "双击打开；拖动卡片移动，从边缘圆点拖到另一节点连线。")
            .accessibilityAction { activate(item, opening: true) }
            if connect != nil {
                port(item, side: .leading).offset(x: -nodeSize.width / 2)
                port(item, side: .trailing).offset(x: nodeSize.width / 2)
            }
        }.frame(width: nodeSize.width, height: nodeSize.height)
    }
    private func nodeBody(_ item: GraphItem) -> some View {
        let selected = selectedPhysicalID == item.id
        let target = connectionTargetID == item.id && connectionFromID != item.id
        return HStack(spacing: 12) {
            Image(systemName: item.subtitle == "Markdown" ? "doc.text" : "circle.hexagongrid")
                .font(.system(size: 26, weight: .regular)).foregroundStyle(Palette.accent.opacity(0.8)).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.system(size: 18, weight: selected ? .semibold : .medium)).foregroundStyle(Palette.ink).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(item.subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(16).frame(width: nodeSize.width, height: nodeSize.height)
            .background(Palette.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(target || connectionFromID == item.id ? Palette.copper : selected ? Palette.accent : Palette.line, lineWidth: target || selected || connectionFromID == item.id ? 2 : 1))
            .shadow(color: Palette.accent.opacity(selected ? 0.10 : 0.035), radius: 14, y: 5)
            .contentShape(RoundedRectangle(cornerRadius: 15)).help(item.title)
    }
    private func port(_ item: GraphItem, side: PortSide) -> some View {
        Circle().fill(Palette.accent.opacity(selectedPhysicalID == item.id || connectionFromID == item.id ? 1 : 0.55)).overlay(Circle().stroke(Palette.surface, lineWidth: 2))
            .frame(width: 12, height: 12).padding(6).contentShape(Circle())
            .overlay {
                GraphPointerBridge(enabled: acceptsCanvasInput && !savingPosition && !savingConnection && !savingLine && editingLineID == nil,
                                   movable: true, resetID: gestureEpoch, canvasID: canvasInputID, requiresUnobscuredDragEnd: true,
                                   click: { _ in portActivated(item, side: side) },
                                   drag: { updatePortDrag(item, side: side, delta: $0, ended: $1) }, cancel: { cancelConnection() })
            }
            .focusable().focusEffectDisabled().focused($focus, equals: .port(item.id, side))
            .onKeyPress(.return) { portActivated(item, side: side); return .handled }
            .onKeyPress(.space) { portActivated(item, side: side); return .handled }
            .accessibilityLabel("\(item.title)，节点 \(nodeNumber(item))，\(side == .leading ? "左" : "右")连接点")
            .accessibilityHint("点击开始或完成连接，也可以按住拖向另一节点。")
            .accessibilityAction { portActivated(item, side: side) }
            .help("从这里拖到另一节点连线；也可点击后选择目标")
    }
    @ViewBuilder private func nodeMenu(_ item: GraphItem) -> some View {
        if open != nil { Button(item.subtitle == "Markdown" ? "打开文档" : "打开内容") { activate(item, opening: true) } }
        if let inspect { Button("查看来源与关联") { inspect(item.targetID) } }
        if connect != nil {
            if let source = connectionFromID, source != item.id {
                Button("连接到这里") { commitConnection(from: source, to: item.id) }
            }
            Button("从这里连线") { beginConnection(item, side: .trailing) }
            if connectionFromID != nil { Button("取消连线") { cancelConnection() } }
        }
        let incident = renderCache.incident[item.id] ?? []
        if !incident.isEmpty, renameLine != nil || removeLine != nil {
            Menu("已有连线") {
                ForEach(incident) { line in
                    let other = renderCache.byID[line.from == item.id ? line.to : line.from]
                    Menu("\(line.from == item.id ? "→" : "←") \(line.label) · \(other?.title ?? "节点") · \(other.map(nodeNumber) ?? 0)") {
                        if renameLine != nil { Button("修改关系名称") { beginRename(line) } }
                        if removeLine != nil { Button("移除这条连线", role: .destructive) { deleteLine(line.id) } }
                    }
                }
            }
        }
        if let remove { Divider(); Button("移除节点，保留文档", role: .destructive) { remove(item.id) } }
    }
    private func updateNodeDrag(_ item: GraphItem, delta: CGSize, ended: Bool) {
        guard acceptsCanvasInput, !savingPosition, editingLineID == nil, connectionFromID == nil, let move else { return }
        if nodeDragState == nil {
            let origin = CGPoint(x: item.x, y: item.y)
            nodeDragState = NodeDrag(id: item.id, origin: origin, position: origin, scale: camera.scale)
            setPhysicalSelection(item.id); select(item.targetID); message = ""
        }
        guard var drag = nodeDragState, drag.id == item.id else { return }
        drag.position = CGPoint(x: min(10_000_000, max(-10_000_000, drag.origin.x + delta.width / drag.scale)),
                                y: min(10_000_000, max(-10_000_000, drag.origin.y + delta.height / drag.scale)))
        nodeDragState = drag
        guard ended else { return }
        savingPosition = true
        let destination = drag.position
        Task {
            let saved = await move(item.id, destination.x, destination.y)
            // Absolute display coordinates survive the model's save callback;
            // adding a translation to the newly saved position would jump twice.
            nodeDragState = nil; savingPosition = false
            if !saved { message = (errorText?() ?? "位置未保存。") + "节点保留原位置。" }
        }
    }
    private func updatePortDrag(_ item: GraphItem, side: PortSide, delta: CGSize, ended: Bool) {
        guard acceptsCanvasInput, !savingPosition, !savingConnection, !savingLine, editingLineID == nil else { return }
        if !draggingConnection {
            beginConnection(item, side: side)
            guard connectionFromID == item.id else { return }
            draggingConnection = true; connectionDragScale = camera.scale
        }
        let origin = rect(item), scale = connectionDragScale ?? camera.scale
        let cursor = CGPoint(x: (side == .leading ? origin.minX : origin.maxX) + delta.width / scale, y: origin.midY + delta.height / scale)
        updateConnection(at: cursor)
        guard ended else { return }
        draggingConnection = false
        if let source = connectionFromID, let target = hitItem(at: cursor, excluding: source) { commitConnection(from: source, to: target.id) }
        else { cancelConnection() }
    }
    private func activate(_ item: GraphItem, opening: Bool = false) {
        guard acceptsCanvasInput, nodeDragState == nil, !savingPosition, !savingConnection, !savingLine else { return }
        guard editingLineID == nil else { if let id = editingLineID { focus = .line(id) }; return }
        if let source = connectionFromID {
            if source != item.id { commitConnection(from: source, to: item.id) }
            return
        }
        setPhysicalSelection(item.id); select(item.targetID); focus = .node(item.id); message = ""
        if opening { if let openPhysicalNode { openPhysicalNode(item.id) } else { open?(item.targetID) } }
    }
    private func portActivated(_ item: GraphItem, side: PortSide) {
        guard acceptsCanvasInput, !savingPosition, !savingConnection, !savingLine else { return }
        if let source = connectionFromID {
            if source == item.id { cancelConnection() } else { commitConnection(from: source, to: item.id) }
        } else { beginConnection(item, side: side) }
    }
    private func beginConnection(_ item: GraphItem, side: PortSide) {
        guard acceptsCanvasInput, nodeDragState == nil, connect != nil, !savingPosition, !savingConnection, !savingLine else { return }
        guard editingLineID == nil else { if let id = editingLineID { focus = .line(id) }; return }
        setPhysicalSelection(item.id); select(item.targetID); connectionFromID = item.id; connectionSide = side
        connectionPoint = nil; connectionTargetID = nil; message = ""; focus = .node(item.id)
    }
    private func updateConnection(at point: CGPoint) {
        connectionPoint = point
        connectionTargetID = hitItem(at: point, excluding: connectionFromID)?.id
    }
    private func hitItem(at point: CGPoint, excluding source: String?) -> GraphItem? {
        let eligible = items.reversed().filter { $0.id != source && rect($0).insetBy(dx: -5, dy: -5).contains(point) }
        return eligible.first(where: { $0.id == selectedPhysicalID }) ?? eligible.first
    }
    private func commitConnection(from: String, to: String) {
        guard acceptsCanvasInput, !savingPosition, !savingConnection, !savingLine, from != to, renderCache.byID[from] != nil, renderCache.byID[to] != nil, let connect else { cancelConnection(); return }
        guard editingLineID == nil else { return }
        connectionFromID = from; connectionTargetID = to; connectionPoint = renderCache.byID[to].map { point($0) }
        savingConnection = true; message = ""
        Task {
            let saved = await connect(from, to)
            savingConnection = false; draggingConnection = false
            if saved { cancelConnection() }
            else { message = (errorText?() ?? "连线未保存。") + "起点已保留，点击目标重试，Esc 或点空白取消。" }
        }
    }
    private func cancelConnection() {
        connectionFromID = nil; connectionPoint = nil; connectionTargetID = nil; draggingConnection = false; connectionDragScale = nil
    }
    private func backgroundTapped() {
        guard acceptsCanvasInput, !savingConnection, !savingLine else { return }
        cancelConnection(); message = ""
        if editingLineID == nil { setPhysicalSelection(nil); focus = nil; deselect?() }
    }
    @ViewBuilder private func edgeLabel(_ edge: RenderedGraphLine) -> some View {
        if editingLineID == edge.id {
            TextField("关系名称", text: $lineDraft).textFieldStyle(.roundedBorder).font(.system(size: 12))
                .frame(width: 150).focused($focus, equals: .line(edge.id)).onSubmit { saveRename(edge.line) }.disabled(savingLine)
                .accessibilityLabel("关系名称，回车保存，Esc取消")
        } else {
            Text(edge.line.label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 4).background(Palette.canvas.opacity(0.96), in: Capsule())
                .contentShape(Capsule()).overlay {
                    GraphPointerBridge(enabled: acceptsCanvasInput && !savingPosition && !savingConnection && !savingLine,
                                       movable: false, resetID: gestureEpoch, canvasID: canvasInputID,
                                       click: { twice in if twice { beginRename(edge.line) } }, drag: { _, _ in }, cancel: {})
                }
                .help(renameLine == nil ? edge.line.label : "双击修改关系名称；右键移除这条连线")
                .contextMenu {
                    if renameLine != nil { Button("修改关系名称") { beginRename(edge.line) } }
                    if removeLine != nil { Button("移除这条连线", role: .destructive) { deleteLine(edge.id) } }
                }
        }
    }
    private func beginRename(_ line: GraphLine) {
        guard acceptsCanvasInput, nodeDragState == nil, renameLine != nil, !savingPosition, !savingLine, !savingConnection else { return }
        if let id = editingLineID { focus = .line(id); return }
        cancelConnection(); lineDraft = line.label; editingLineID = line.id; focus = .line(line.id); message = ""
    }
    private func saveRename(_ line: GraphLine) {
        guard acceptsCanvasInput, !savingLine, let renameLine else { return }
        let submittedLabel = lineDraft
        savingLine = true
        Task {
            let saved = await renameLine(line.id, submittedLabel)
            savingLine = false
            if saved { editingLineID = nil; focus = nil; message = "" }
            else { focus = .line(line.id); message = (errorText?() ?? "改名未保存。") + "已填写名称保留，回车重试或Esc取消。" }
        }
    }
    private func deleteLine(_ id: String) {
        guard acceptsCanvasInput, !savingLine, !savingConnection, let removeLine else { return }
        cancelConnection(); savingLine = true
        Task { let saved = await removeLine(id); savingLine = false; if saved && editingLineID == id { editingLineID = nil }; if !saved { message = errorText?() ?? "连线未移除，请重试。" } }
    }
    private func nodeNumber(_ item: GraphItem) -> Int { renderCache.identities.ordinalByNodeID[item.id] ?? 0 }
    private var previewCurve: GraphCurve? {
        guard let sourceID = connectionFromID, let source = renderCache.byID[sourceID], let cursor = connectionPoint else { return nil }
        let sourceRect = rect(source)
        let a = CGPoint(x: connectionSide == .leading ? sourceRect.minX : sourceRect.maxX, y: sourceRect.midY)
        let target = connectionTargetID.flatMap { renderCache.byID[$0] }
        let end = target.map { anchor(rect($0), towards: a) } ?? GraphAnchor(point: cursor, normal: CGVector(dx: -1, dy: 0))
        return GraphCurve(start: a, end: end.point, startNormal: CGVector(dx: connectionSide == .leading ? -1 : 1, dy: 0), endNormal: end.normal)
    }
    private func anchor(_ rect: CGRect, towards point: CGPoint) -> GraphAnchor {
        let dx = point.x - rect.midX, dy = point.y - rect.midY
        if abs(dx) / rect.width >= abs(dy) / rect.height {
            return GraphAnchor(point: CGPoint(x: dx >= 0 ? rect.maxX : rect.minX, y: rect.midY), normal: CGVector(dx: dx >= 0 ? 1 : -1, dy: 0))
        }
        return GraphAnchor(point: CGPoint(x: rect.midX, y: dy >= 0 ? rect.maxY : rect.minY), normal: CGVector(dx: 0, dy: dy >= 0 ? 1 : -1))
    }
}

/// Render-only drift: the cached layout, saved coordinates and hit identities
/// stay unchanged. Pointer presence or selection pauses at the current phase.
private struct GraphAmbientLayer<Content: View>: View {
    let active: Bool
    @ViewBuilder var content: (Double) -> Content
    @State private var phase = 0.0
    var body: some View {
        content(phase)
            .task(id: active) {
                guard active else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 66_666_667) } catch { return }
                    guard !Task.isCancelled else { return }
                    phase += 0.018
                }
            }
    }
}

private struct GraphControlsFrameKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private enum GraphGridTile {
    static let image = NSImage(size: NSSize(width: 24, height: 24), flipped: true) { _ in
        NSColor.gray.setFill(); NSBezierPath(ovalIn: CGRect(x: 11.25, y: 11.25, width: 1.5, height: 1.5)).fill(); return true
    }
}

private struct GraphAnchor { let point: CGPoint; let normal: CGVector }
private struct RenderedGraphLine: Identifiable { let line: GraphLine; let curve: GraphCurve; var id: String { line.id } }
private struct GraphCurve {
    let start: CGPoint
    let end: CGPoint
    let first: CGPoint
    let second: CGPoint
    init(start: CGPoint, end: CGPoint, startNormal: CGVector, endNormal: CGVector, lane: CGFloat = 0) {
        self.start = start; self.end = end
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(1, hypot(dx, dy)), distance = min(180, max(40, length * 0.4))
        let offset = CGSize(width: -dy / length * lane, height: dx / length * lane)
        first = CGPoint(x: start.x + startNormal.dx * distance + offset.width, y: start.y + startNormal.dy * distance + offset.height)
        second = CGPoint(x: end.x + endNormal.dx * distance + offset.width, y: end.y + endNormal.dy * distance + offset.height)
    }
    var path: Path { var path = Path(); path.move(to: start); path.addCurve(to: end, control1: first, control2: second); return path }
    var middle: CGPoint { CGPoint(x: (start.x + first.x * 3 + second.x * 3 + end.x) / 8, y: (start.y + first.y * 3 + second.y * 3 + end.y) / 8) }
    var arrow: Path {
        let dx = end.x - second.x, dy = end.y - second.y, length = max(1, hypot(end.x - second.x, end.y - second.y))
        let ux = dx / length, uy = dy / length
        var path = Path(); path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - ux * 8 - uy * 3.5, y: end.y - uy * 8 + ux * 3.5))
        path.addLine(to: CGPoint(x: end.x - ux * 8 + uy * 3.5, y: end.y - uy * 8 - ux * 3.5)); path.closeSubpath(); return path
    }
}
