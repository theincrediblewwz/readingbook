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

    private struct NodeDrag {
        var id: String
        var origin: CGPoint
        var position: CGPoint
    }
    @State private var nodeDragState: NodeDrag?
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
    @FocusState private var focus: FocusTarget?
    @Namespace private var canvasSpace
    private enum FocusTarget: Hashable { case node(String), port(String, PortSide), line(String) }
    private enum PortSide: Hashable { case leading, trailing }
    private var canvasWidth: Double { max(1000, (items.map(\.x).max() ?? 600) + 340) }
    private var canvasHeight: Double { max(650, (items.map(\.y).max() ?? 400) + 260) }
    private func point(_ item: GraphItem) -> CGPoint {
        let location = nodeDragState?.id == item.id ? nodeDragState!.position : CGPoint(x: item.x, y: item.y)
        return CGPoint(x: location.x + 110, y: location.y + 45)
    }
    private func rect(_ item: GraphItem) -> CGRect {
        let center = point(item)
        return CGRect(x: center.x - 110, y: center.y - 45, width: 220, height: 90)
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
        let rendered = renderedLines
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Palette.canvas.contentShape(Rectangle()).onTapGesture { backgroundTapped() }
                    .contextMenu { if let createDocument { Button("新建笔记") { createDocument() } } }
                Rectangle().fill(ImagePaint(image: Image(nsImage: GraphGridTile.image), scale: 1)).opacity(0.18).allowsHitTesting(false).accessibilityHidden(true)
                Canvas { context, size in
                    for edge in rendered {
                        context.stroke(edge.curve.path, with: .color(Palette.accent.opacity(0.55)), lineWidth: 1.5)
                        context.fill(edge.curve.arrow, with: .color(Palette.accent.opacity(0.65)))
                    }
                    if let curve = previewCurve {
                        context.stroke(curve.path, with: .color(Palette.copper), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        context.fill(curve.arrow, with: .color(Palette.copper))
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
                ForEach(rendered) { edge in edgeLabel(edge).position(x: edge.curve.middle.x, y: edge.curve.middle.y - 11) }
                ForEach(items) { item in
                    nodeShell(item).position(point(item)).zIndex(item.id == selectedPhysicalID ? 2 : 1)
                }
            }.frame(width: canvasWidth, height: canvasHeight)
                .transaction { $0.animation = nil }
                .coordinateSpace(name: canvasSpace)
                .onContinuousHover { phase in
                    guard connectionFromID != nil, !draggingConnection, !savingConnection else { return }
                    switch phase {
                    case .active(let location): updateConnection(at: location)
                    case .ended: connectionPoint = nil; connectionTargetID = nil
                    }
                }
        }
        .overlay(alignment: .topLeading) { statusOverlay.padding(12).allowsHitTesting(false) }
        .allowsHitTesting(isEnabled)
        .onExitCommand {
            guard !savingLine, !savingConnection else { return }
            if editingLineID != nil { editingLineID = nil; focus = nil; message = "" }
            else { cancelConnection() }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled && !savingConnection { cancelConnection() }
            if !enabled && !savingPosition { nodeDragState = nil }
        }
        .onChange(of: items.map(\.id)) { _, ids in
            if let id = connectionFromID, !ids.contains(id) { cancelConnection() }
            if let id = selectedNodeID, !ids.contains(id) { selectedNodeID = nil }
            if let drag = nodeDragState, !ids.contains(drag.id) { nodeDragState = nil }
        }
        .onChange(of: lines.map(\.id)) { _, ids in if let id = editingLineID, !ids.contains(id) { editingLineID = nil } }
        .onDisappear { cancelConnection(); nodeDragState = nil; editingLineID = nil }
    }
    @ViewBuilder private var statusOverlay: some View {
        if savingConnection || savingLine { Text("正在保存连线…").font(.caption).padding(9).readingGlass() }
        else if let id = connectionFromID, let source = items.first(where: { $0.id == id }) {
            Text(message.isEmpty ? "从「\(source.title)」连线 · 点击目标节点，Esc 或点空白取消" : message)
                .font(.caption).padding(9).readingGlass()
        } else if editingLineID != nil {
            Text(message.isEmpty ? "关系名称：回车保存，Esc 取消" : message).font(.caption).padding(9).readingGlass()
        } else if !message.isEmpty { Text(message).font(.caption).padding(9).readingGlass() }
        else if let title {
            Text("\(title) · \(items.count) 个节点").font(.caption).foregroundStyle(.secondary).padding(8).readingGlass()
        }
    }
    private func nodeShell(_ item: GraphItem) -> some View {
        ZStack {
            nodeBody(item).overlay {
                GraphPointerBridge(enabled: isEnabled && !savingPosition && !savingConnection && !savingLine,
                                   movable: move != nil && connectionFromID == nil && editingLineID == nil,
                                   reservePorts: connect != nil,
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
                port(item, side: .leading).offset(x: -110)
                port(item, side: .trailing).offset(x: 110)
            }
        }.frame(width: 220, height: 90)
    }
    private func nodeBody(_ item: GraphItem) -> some View {
        let selected = selectedPhysicalID == item.id
        let target = connectionTargetID == item.id && connectionFromID != item.id
        return VStack(alignment: .leading, spacing: 6) {
            Text(item.subtitle).font(.caption2).foregroundStyle(Palette.accent)
            Text(item.title).font(.system(size: 16, weight: .medium, design: .serif)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).frame(width: 220, height: 90)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(target || connectionFromID == item.id ? Palette.copper : selected ? Palette.accent : Palette.line, lineWidth: target || selected || connectionFromID == item.id ? 2 : 1))
            .shadow(color: .black.opacity(0.025), radius: 8, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 13)).help(item.title)
    }
    private func port(_ item: GraphItem, side: PortSide) -> some View {
        Circle().fill(Palette.surface).overlay(Circle().stroke(selectedPhysicalID == item.id || connectionFromID == item.id ? Palette.accent : Palette.ink.opacity(0.45), lineWidth: 1.5))
            .frame(width: 8, height: 8).padding(8).contentShape(Circle())
            .overlay {
                GraphPointerBridge(enabled: isEnabled && !savingPosition && !savingConnection && !savingLine && editingLineID == nil,
                                   movable: true, click: { _ in portActivated(item, side: side) },
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
        guard isEnabled, !savingPosition, editingLineID == nil, connectionFromID == nil, let move else { return }
        if nodeDragState == nil {
            let origin = CGPoint(x: item.x, y: item.y)
            nodeDragState = NodeDrag(id: item.id, origin: origin, position: origin)
            selectedNodeID = item.id; select(item.targetID); message = ""
        }
        guard var drag = nodeDragState, drag.id == item.id else { return }
        drag.position = CGPoint(x: max(10, drag.origin.x + delta.width), y: max(10, drag.origin.y + delta.height))
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
        guard isEnabled, !savingPosition, !savingConnection, !savingLine, editingLineID == nil else { return }
        if !draggingConnection {
            beginConnection(item, side: side)
            guard connectionFromID == item.id else { return }
            draggingConnection = true
        }
        let origin = rect(item)
        let cursor = CGPoint(x: (side == .leading ? origin.minX : origin.maxX) + delta.width, y: origin.midY + delta.height)
        updateConnection(at: cursor)
        guard ended else { return }
        draggingConnection = false
        if let source = connectionFromID, let target = hitItem(at: cursor, excluding: source) { commitConnection(from: source, to: target.id) }
        else { cancelConnection() }
    }
    private func activate(_ item: GraphItem, opening: Bool = false) {
        guard isEnabled, nodeDragState == nil, !savingPosition, !savingConnection, !savingLine else { return }
        guard editingLineID == nil else { if let id = editingLineID { focus = .line(id) }; return }
        if let source = connectionFromID {
            if source != item.id { commitConnection(from: source, to: item.id) }
            return
        }
        selectedNodeID = item.id; select(item.targetID); focus = .node(item.id); message = ""
        if opening { open?(item.targetID) }
    }
    private func portActivated(_ item: GraphItem, side: PortSide) {
        guard isEnabled, !savingPosition, !savingConnection, !savingLine else { return }
        if let source = connectionFromID {
            if source == item.id { cancelConnection() } else { commitConnection(from: source, to: item.id) }
        } else { beginConnection(item, side: side) }
    }
    private func beginConnection(_ item: GraphItem, side: PortSide) {
        guard isEnabled, nodeDragState == nil, connect != nil, !savingPosition, !savingConnection, !savingLine else { return }
        guard editingLineID == nil else { if let id = editingLineID { focus = .line(id) }; return }
        selectedNodeID = item.id; select(item.targetID); connectionFromID = item.id; connectionSide = side
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
        guard isEnabled, !savingPosition, !savingConnection, !savingLine, from != to, items.contains(where: { $0.id == from }), items.contains(where: { $0.id == to }), let connect else { cancelConnection(); return }
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
        connectionFromID = nil; connectionPoint = nil; connectionTargetID = nil; draggingConnection = false
    }
    private func backgroundTapped() {
        guard isEnabled, !savingConnection, !savingLine else { return }
        cancelConnection(); message = ""
        if editingLineID == nil { selectedNodeID = nil; focus = nil; deselect?() }
    }
    @ViewBuilder private func edgeLabel(_ edge: RenderedGraphLine) -> some View {
        if editingLineID == edge.id {
            TextField("关系名称", text: $lineDraft).textFieldStyle(.roundedBorder).font(.system(size: 12))
                .frame(width: 150).focused($focus, equals: .line(edge.id)).onSubmit { saveRename(edge.line) }.disabled(savingLine)
                .accessibilityLabel("关系名称，回车保存，Esc取消")
        } else {
            Text(edge.line.label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 4).background(Palette.canvas.opacity(0.96), in: Capsule())
                .contentShape(Capsule()).onTapGesture(count: 2) { beginRename(edge.line) }
                .help(renameLine == nil ? edge.line.label : "双击修改关系名称；右键移除这条连线")
                .contextMenu {
                    if renameLine != nil { Button("修改关系名称") { beginRename(edge.line) } }
                    if removeLine != nil { Button("移除这条连线", role: .destructive) { deleteLine(edge.id) } }
                }
        }
    }
    private func beginRename(_ line: GraphLine) {
        guard isEnabled, nodeDragState == nil, renameLine != nil, !savingPosition, !savingLine, !savingConnection else { return }
        if let id = editingLineID { focus = .line(id); return }
        cancelConnection(); lineDraft = line.label; editingLineID = line.id; focus = .line(line.id); message = ""
    }
    private func saveRename(_ line: GraphLine) {
        guard isEnabled, !savingLine, let renameLine else { return }
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
        guard isEnabled, !savingLine, !savingConnection, let removeLine else { return }
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
