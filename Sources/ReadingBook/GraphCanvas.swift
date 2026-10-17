import SwiftUI
import Foundation
import AppKit

struct GraphItem: Identifiable {
    var id: String
    var targetID: String
    var title: String
    var subtitle: String
    var x: Double
    var y: Double
}
struct GraphLine: Identifiable { var id: String; var from: String; var to: String; var label: String }

/// Canvas identity is the node ID; opening content uses the separate target ID.
/// Body dragging moves a card. Its edge ports own a separate connection gesture.
struct GraphSurface: View {
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
    private func point(_ item: GraphItem) -> CGPoint {
        let location = nodeDragState?.id == item.id ? nodeDragState!.position : CGPoint(x: item.x, y: item.y)
        return CGPoint(x: location.x + nodeSize.width / 2, y: location.y + nodeSize.height / 2)
    }
    private func rect(_ item: GraphItem) -> CGRect {
        let center = point(item)
        return CGRect(x: center.x - nodeSize.width / 2, y: center.y - nodeSize.height / 2, width: nodeSize.width, height: nodeSize.height)
    }
    private var selectedPhysicalID: String? {
        if let id = selectedNodeID, items.first(where: { $0.id == id })?.targetID == selectedID { return id }
        return items.first(where: { $0.targetID == selectedID })?.id
    }
    private var renderedLines: [RenderedGraphLine] {
        let index = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let groups = Dictionary(grouping: lines) { [$0.from, $0.to].sorted().joined(separator: "|") }
        var lanes: [String: CGFloat] = [:]
        for group in groups.values {
            for (offset, line) in group.sorted(by: { $0.id < $1.id }).enumerated() {
                let lane = (CGFloat(offset) - CGFloat(group.count - 1) / 2) * 32
                lanes[line.id] = line.from < line.to ? lane : -lane
            }
        }
        return lines.compactMap { line in
            guard let from = index[line.from], let to = index[line.to] else { return nil }
            let a = anchor(rect(from), towards: point(to)), b = anchor(rect(to), towards: point(from))
            return RenderedGraphLine(line: line, curve: GraphCurve(start: a.point, end: b.point, startNormal: a.normal, endNormal: b.normal, lane: lanes[line.id] ?? 0))
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let rendered = renderedLines
            let globalFrame = geometry.frame(in: .global)
            let workspaceExclusions = workspaceCanvasExclusionRects.filter { !$0.isNull && !$0.isInfinite && !$0.isEmpty }
                .map { $0.offsetBy(dx: -globalFrame.minX, dy: -globalFrame.minY) }
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
                        .position(camera.screen(point(item), in: geometry.size)).zIndex(item.id == selectedPhysicalID ? 2 : 1)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            .transaction { $0.animation = nil }
            .overlay(alignment: .bottomLeading) {
                statusOverlay.lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: min(300, statusWidth(in: geometry.size)), alignment: .leading)
                    .padding(.leading, 24).padding(.bottom, geometry.size.width < 1050 ? 96 : 24).allowsHitTesting(false)
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
            .onContinuousHover { phase in
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
                    fitAll()
                    // Widely separated saved nodes remain untouched. Show a
                    // readable starting area; “show all” remains explicit.
                    if camera.scale < 0.72, let first = items.first(where: { $0.targetID == selectedID }) ?? items.first {
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
        .onChange(of: workspaceCanvasBlocked) { _, blocked in if blocked { cancelTransientInteractions() } }
        .onChange(of: obscuredLeadingWidth) { old, _ in reframeCamera(previousLeadingWidth: old, previousTrailingWidth: obscuredTrailingWidth) }
        .onChange(of: obscuredTrailingWidth) { old, _ in reframeCamera(previousLeadingWidth: obscuredLeadingWidth, previousTrailingWidth: old) }
        .onChange(of: focusNodeID) { _, _ in focusRequestedNode() }
        .onChange(of: focusRequestToken) { _, _ in focusRequestedNode() }
        .onChange(of: items.map(\.id)) { _, ids in
            if let id = connectionFromID, !ids.contains(id) { cancelConnection() }
            if let id = selectedNodeID, !ids.contains(id) { setPhysicalSelection(nil) }
            if let drag = nodeDragState, !ids.contains(drag.id) { nodeDragState = nil; gestureEpoch += 1 }
        }
        .onChange(of: lines.map(\.id)) { _, ids in if let id = editingLineID, !ids.contains(id) { editingLineID = nil } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in cancelTransientInteractions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in cancelTransientInteractions() }
        .onDisappear { cancelTransientInteractions(); editingLineID = nil }
    }
    private func visibleItems(in size: CGSize) -> [GraphItem] {
        let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -max(240, nodeSize.width / 2 * camera.scale + 24), dy: -max(100, nodeSize.height / 2 * camera.scale + 24))
        return items.filter { item in
            if nodeDragState?.id == item.id { return true } // Keep the native drag receiver alive offscreen.
            let position = camera.screen(point(item), in: size)
            return viewport.contains(position)
        }
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
        let bounds = items.map(rect).reduce(CGRect.null) { $0.union($1) }
        camera.fit(bounds.isNull ? CGRect(origin: .zero, size: nodeSize) : bounds, in: viewportSize, obscuredLeadingWidth: obscuredLeadingWidth, obscuredTrailingWidth: obscuredTrailingWidth)
        connectionPoint = nil; connectionTargetID = nil
    }
    private func centerSelection() {
        guard canNavigate, let item = items.first(where: { $0.id == selectedPhysicalID }) else { return }
        camera.focus(point(item), in: viewportSize, obscuredLeadingWidth: obscuredLeadingWidth, obscuredTrailingWidth: obscuredTrailingWidth)
    }
    private func focusRequestedNode() {
        guard let id = focusNodeID, let item = items.first(where: { $0.id == id }), !savingPosition, !savingConnection, !savingLine else { return }
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
    }
    @ViewBuilder private var statusOverlay: some View {
        if savingConnection || savingLine { Text("正在保存连线…").font(.caption).padding(9).readingGlass() }
        else if let id = connectionFromID, let source = items.first(where: { $0.id == id }) {
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
            Menu("连接到…") {
                ForEach(items.filter { $0.id != item.id }) { target in
                    Button("\(target.title) · 节点 \(nodeNumber(target))") { commitConnection(from: item.id, to: target.id) }
                }
            }.disabled(items.count < 2)
            if connectionFromID != nil { Button("取消连线") { cancelConnection() } }
        }
        let incident = lines.filter { $0.from == item.id || $0.to == item.id }
        if !incident.isEmpty, renameLine != nil || removeLine != nil {
            Menu("已有连线") {
                ForEach(incident) { line in
                    let other = items.first { $0.id == (line.from == item.id ? line.to : line.from) }
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
        if opening { open?(item.targetID) }
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
        guard acceptsCanvasInput, !savingPosition, !savingConnection, !savingLine, from != to, items.contains(where: { $0.id == from }), items.contains(where: { $0.id == to }), let connect else { cancelConnection(); return }
        guard editingLineID == nil else { return }
        connectionFromID = from; connectionTargetID = to; connectionPoint = items.first { $0.id == to }.map(point)
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
    private func nodeNumber(_ item: GraphItem) -> Int { (items.firstIndex { $0.id == item.id } ?? 0) + 1 }
    private var previewCurve: GraphCurve? {
        guard let sourceID = connectionFromID, let source = items.first(where: { $0.id == sourceID }), let cursor = connectionPoint else { return nil }
        let sourceRect = rect(source)
        let a = CGPoint(x: connectionSide == .leading ? sourceRect.minX : sourceRect.maxX, y: sourceRect.midY)
        let target = items.first { $0.id == connectionTargetID }
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
