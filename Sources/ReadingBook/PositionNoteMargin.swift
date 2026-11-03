import SwiftUI
import ReadingCore

enum PositionNotePreview {
    /// This is a display-only, bounded preview. The ordinary Markdown document
    /// remains byte-for-byte intact for editing, saving, export and backup.
    static func make(_ source: String, project: BookProject) -> String {
        let rendered = MarkdownReferenceLinks.render(source, bookID: project.id, project: project)
        guard let value = try? AttributedString(markdown: rendered, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return source }
        var result = "", previousReference: URL?
        for run in value.runs {
            let reference = run.link.flatMap { $0.scheme == "readingbook" ? $0 : nil }
            if let reference, let previousReference, reference != previousReference { result += " · " }
            result += String(value[run.range].characters); previousReference = reference
        }
        return result
    }
}

/// The note host owns only the reserved margin. Wheel events bubble through
/// its native responder to the same PDF scroll view, including single-page mode.
@MainActor final class PositionNoteNativeHost: NSHostingView<AnyView> {
    var onScroll: ((NSEvent) -> Void)?
    var onDetach: (() -> Void)?
    override var intrinsicContentSize: NSSize { .init(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // SwiftUI can ask a representable to hit-test outside its clipped frame.
        // A scaled, empty margin must not intercept the PDF's floating controls.
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
    override func scrollWheel(with event: NSEvent) { if let onScroll { onScroll(event) } else { super.scrollWheel(with: event) } }
}
struct PositionNoteMarginHost: NSViewRepresentable {
    @EnvironmentObject private var store: AppStore
    let content: PositionNoteMargin
    let controller: PDFReaderController
    var scale: CGFloat = 1
    func makeNSView(context: Context) -> PositionNoteNativeHost {
        let host = PositionNoteNativeHost(rootView: root)
        controller.attachNoteMargin(host, owner: store.collectionOwnerKey)
        host.onDetach = { [weak controller, weak host] in if let host { controller?.detachNoteMargin(host) } }
        host.onScroll = { controller.command(.scrollNoteArea($0)) }; return host
    }
    func updateNSView(_ view: PositionNoteNativeHost, context: Context) {
        view.rootView = root; view.onScroll = { controller.command(.scrollNoteArea($0)) }
        controller.attachNoteMargin(view, owner: store.collectionOwnerKey)
    }
    static func dismantleNSView(_ view: PositionNoteNativeHost, coordinator: ()) { view.onScroll = nil; view.onDetach?(); view.onDetach = nil }
    private var root: AnyView { AnyView(content.scaleEffect(scale, anchor: .topLeading)
        .frame(width: PositionNoteSurface.marginWidth * scale, height: content.height * scale, alignment: .topLeading)
        .environmentObject(store).modifier(ReadingPreferencesEnvironment())) }
}

struct PositionNoteTurnVisibility: ViewModifier {
    @ObservedObject var positions: PDFNotePositionState
    let visible: Bool
    let interactive: Bool
    func body(content: Content) -> some View {
        content.opacity(visible && !positions.paperTurnActive ? 1 : 0)
            .allowsHitTesting(visible && interactive && !positions.paperTurnActive)
    }
}

struct PositionNoteMargin: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var nativePositions: PDFNotePositionState
    let height: CGFloat
    let isPDF: Bool
    var scale: CGFloat = 1
    var originY: CGFloat = 0
    var topInset: CGFloat = PositionNoteSurface.topInset
    var noteIDs: Set<String>? = nil
    var onExpand: ([String], [String: String], CGPoint) -> Void
    @State private var snippets: [String: String] = [:]
    @State private var noteDates: [String: Date] = [:]
    private var positions: [ReadingNoteScreenPosition] {
        if isPDF { return nativePositions.owner == store.collectionOwnerKey ? nativePositions.points.filter { noteIDs?.contains($0.key) ?? true }.map { .init(id: $0.key, y: ($0.value.y - originY) / scale) } : [] }
        return store.activeNotePlacements.filter { $0.value.unitID == store.selectedUnitID }.map { .init(id: $0.key, y: $0.value.y * height) }
    }
    private var stacks: [ReadingNoteStack] {
        ReadingNoteLayout.stacks(positions, height: height, topInset: topInset).map { stack in
            ReadingNoteStack(ids: stack.ids.sorted {
                let lhs = noteDates[$0] ?? .distantPast, rhs = noteDates[$1] ?? .distantPast
                return lhs == rhs ? $0 < $1 : lhs > rhs
            }, top: stack.top)
        }
    }
    private var preparationKey: String {
        store.collectionOwnerKey + "|" + String(store.projectRevision) + "|" + positions.map(\.id).sorted().joined(separator: ",")
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if !isPDF { ReadingPaperBackground() }
            ForEach(stacks, id: \.ids) { stack in stackView(stack).padding(.leading, 20).offset(y: stack.top) }
        }.frame(width: PositionNoteSurface.marginWidth, height: height).clipped()
            .task(id: preparationKey) {
                guard let book = store.book else { return }
                let owner = WorkspacePickerOwner(store: store), wanted = Set(positions.map(\.id))
                var values: [String: String] = [:], dates: [String: Date] = [:]
                for document in book.activeDocuments where wanted.contains(document.id) {
                    if Task.isCancelled { return }
                    if let body = try? await store.repository.readDocument(bookID: book.id, document: document) {
                        let source = String(body.prefix(2400))
                        values[document.id] = await Task.detached(priority: .utility) { PositionNotePreview.make(source, project: book) }.value
                        dates[document.id] = document.updatedAt
                    }
                }
                guard !Task.isCancelled, owner.matches(store) else { return }; snippets = values; noteDates = dates
            }
            .onChange(of: store.collectionOwnerKey) { _, _ in snippets = [:] }
    }
    private func stackView(_ stack: ReadingNoteStack) -> some View {
        HStack(alignment: .center, spacing: 5) {
            ZStack(alignment: .topLeading) {
                if stack.ids.count > 2 { paper.offset(x: 7, y: 13) }
                if stack.ids.count > 1 { paper.offset(x: 4, y: 7) }
                if let id = stack.ids.first { PositionNotePaper(id: id, text: snippets[id] ?? "", height: 170) }
            }.frame(width: 230, height: 184, alignment: .topLeading)
            Button { onExpand(stack.ids, snippets, CGPoint(x: 135, y: stack.top + 85)) } label: {
                Image(systemName: "rectangle.stack").font(.system(size: 12)).foregroundStyle(.black.opacity(0.6)).frame(width: 32, height: 44)
            }.buttonStyle(ReadingQuietButtonStyle()).help("在书页中央摊开这叠 \(stack.ids.count) 张便签")
                .accessibilityLabel("展开 \(stack.ids.count) 张便签")
        }
    }
    private var paper: some View { ReadingPaperBackground().clipShape(RoundedRectangle(cornerRadius: 6)).overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.07)) }.frame(width: 230, height: 170) }
}

/// Only this leaf observes native position updates. Its frame, contents and
/// connector ends use one page-relative transform, including during zoom.
struct PositionNoteMarginLayer: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var positions: PDFNotePositionState
    let controller: PDFReaderController
    let viewport: CGSize
    let isPDF: Bool
    let showsMargin: Bool
    let visible: Bool
    let interactive: Bool
    var onExpand: ([String], [String: String], CGPoint) -> Void
    var onCollapse: () -> Void
    private var surfaces: [PDFNotePageSurface] {
        if isPDF, !positions.surfaces.isEmpty { return positions.surfaces }
        let frame = isPDF ? positions.marginFrame : CGRect(x: viewport.width - 17 - PositionNoteSurface.marginWidth, y: 0, width: PositionNoteSurface.marginWidth, height: viewport.height)
        return [.init(id: 0, frame: frame, scale: isPDF ? max(0.001, positions.marginScale) : 1, noteIDs: Set(positions.points.keys))]
    }
    var body: some View {
        let frame = (surfaces.first(where: { $0.id == controller.page }) ?? surfaces.first)?.frame ?? .zero
        let collapseX = frame.width > 0 && frame.maxX > 32 && frame.minX < viewport.width
            ? max(8, min(viewport.width - 52, frame.maxX + 8)) : viewport.width - 52
        // Navigation floats above the original page. Keep the paper reserve
        // stable, while hiding slips/lines that would cover search or thumbnails.
        let notesVisible = visible && (!isPDF || !positions.navigationObscured)
        ZStack(alignment: .topLeading) {
            Color.clear
            if showsMargin || (isPDF && positions.marginWidth > 0.1) {
                ForEach(surfaces) { surface in
                let frame = surface.frame, scale = surface.scale
                let margin = PositionNoteMargin(nativePositions: positions, height: max(1, frame.height / scale), isPDF: isPDF,
                    scale: scale, originY: frame.minY, topInset: isPDF ? 16 : PositionNoteSurface.topInset, noteIDs: isPDF ? surface.noteIDs : nil, onExpand: { ids, snippets, origin in
                        onExpand(ids, snippets, CGPoint(x: frame.minX + origin.x * scale, y: frame.minY + origin.y * scale))
                    })
                Group {
                    if isPDF { PositionNoteMarginHost(content: margin, controller: controller, scale: scale) }
                    else { margin }
                }.frame(width: max(0, frame.width), height: max(0, frame.height)).clipped()
                    .offset(x: frame.minX, y: frame.minY)
                    .modifier(PositionNoteTurnVisibility(positions: positions, visible: notesVisible, interactive: interactive))
                }
                if isPDF { PositionNoteConnections(positions: positions, size: viewport).opacity(notesVisible ? 1 : 0) }
                Button(action: onCollapse) { Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium)).frame(width: 32, height: 32) }
                    .buttonStyle(ReadingQuietButtonStyle()).background(Palette.paper.opacity(0.96), in: Circle())
                    .overlay { Circle().strokeBorder(Color.primary.opacity(0.07)) }.shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                    .offset(x: collapseX, y: 86)
                    .opacity(notesVisible ? 1 : 0).allowsHitTesting(notesVisible && interactive)
                    .help("收起便签与右侧留白，恢复原来的阅读模式").accessibilityLabel("收起页边便签")
            }
        // A full-page host is deliberately taller than the viewport at fit
        // width. Pin that oversized stack to the viewport origin; the default
        // centered frame otherwise shifts both cards and connections upward
        // by half of the overflow, despite correct PDF anchor coordinates.
        }.frame(width: viewport.width, height: viewport.height, alignment: .topLeading).clipped()
    }
}

struct PositionNoteConnection {
    let line: Path
    let start: CGPoint
}
@MainActor enum PositionNoteConnectionGeometry {
    static func make(positions: PDFNotePositionState, size: CGSize, owner: String) -> [PositionNoteConnection] {
            guard positions.owner == owner else { return [] }
            var result: [PositionNoteConnection] = []
            let surfaces = positions.surfaces.isEmpty ? [PDFNotePageSurface(id: 0,
                frame: positions.marginFrame.width > 0 ? positions.marginFrame : CGRect(x: size.width - positions.scrollerWidth - positions.marginWidth, y: 0, width: positions.marginWidth, height: size.height),
                scale: max(0.001, positions.marginScale), noteIDs: Set(positions.points.keys))] : positions.surfaces
            for surface in surfaces {
            let scale = surface.scale, frame = surface.frame
            let points = positions.points.filter { surface.noteIDs.contains($0.key) }.map { ReadingNoteScreenPosition(id: $0.key, y: ($0.value.y - frame.minY) / scale) }
            let stacks = ReadingNoteLayout.stacks(points, height: frame.height / scale, topInset: positions.surfaces.isEmpty ? max(12, PositionNoteSurface.topInset - frame.minY) / scale : 16)
            for stack in stacks {
                for id in stack.ids {
                    guard let connector = positions.connectors[id] else { continue }
                    let end = CGPoint(x: frame.minX + 20 * scale, y: frame.minY + (stack.top + 85) * scale)
                    var line = Path(); line.move(to: connector.start)
                    let exit = CGPoint(x: max(connector.start.x + 5 * scale, connector.pageExit.x), y: connector.pageExit.y)
                    line.addLine(to: exit)
                    line.addCurve(to: end, control1: CGPoint(x: exit.x + 14 * scale, y: exit.y), control2: CGPoint(x: end.x - 18 * scale, y: end.y))
                    result.append(.init(line: line, start: connector.start))
                }
            }
            }
            return result
    }
}

struct PositionNoteConnections: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var positions: PDFNotePositionState
    let size: CGSize
    var body: some View {
        Canvas { context, _ in
            for connection in PositionNoteConnectionGeometry.make(positions: positions, size: size, owner: store.collectionOwnerKey) {
                context.stroke(connection.line, with: .color(.black.opacity(0.18)), style: StrokeStyle(lineWidth: 0.7, lineCap: .round, lineJoin: .round))
                context.fill(Path(ellipseIn: CGRect(x: connection.start.x - 1.7, y: connection.start.y - 1.7, width: 3.4, height: 3.4)), with: .color(Palette.accent.opacity(0.5)))
            }
        }.opacity(positions.paperTurnActive ? 0 : 1).allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct PositionNotePaper: View {
    @EnvironmentObject private var store: AppStore
    let id: String
    let text: String
    var height: CGFloat? = 170
    var width: CGFloat = 230
    var clickCount = 2
    var onCommand: ((String, PositionNoteCommand) -> Void)?
    @State private var hovered = false
    @Environment(\.readingReduceMotion) private var reduceMotion
    private var placement: ReadingNotePlacement? { store.readerCollections.notePlacements?[id] }
    private var font: Font {
        Font(PositionNoteTypography.native(placement))
    }
    private var resolvedHeight: CGFloat {
        if let height { return height }
        let native = PositionNoteTypography.native(placement)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        let bounds = (text as NSString).boundingRect(with: CGSize(width: width - 36, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: native, .paragraphStyle: paragraph])
        return min(300, max(100, ceil(bounds.height) + 36))
    }
    var body: some View {
        Text(text).font(font).foregroundStyle(Color.black.opacity(0.67)).lineSpacing(5)
            .lineLimit(max(1, Int((resolvedHeight - 36) / ((placement?.fontSize ?? 15) + 5))))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(18)
            .frame(width: width, height: resolvedHeight, alignment: .topLeading).clipped()
            .background { ReadingPaperBackground().clipShape(RoundedRectangle(cornerRadius: 6)) }
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(hovered ? 0.14 : 0.065)) }
            .shadow(color: .black.opacity(hovered ? 0.055 : 0.035), radius: 8, y: 5)
            .contentShape(Rectangle()).onTapGesture(count: clickCount, perform: edit)
            .onHover { hovered = $0 }.animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: hovered)
            .overlay {
                ReadingPaperContextAnchor(actions: [
                    .init(title: "编辑便签", icon: "pencil", action: edit),
                    .init(title: "在我的笔记中打开", icon: "note.text", action: { perform(.openNotebook) }),
                    .init(title: "重新选择原文位置", icon: "mappin.and.ellipse", action: { perform(.relocate) }),
                    .init(title: "取消位置绑定", icon: "mappin.slash", action: { perform(.unbind) }),
                    .init(title: "移入回收站", icon: "trash", destructive: true, action: { perform(.trash) })
                ], primary: edit, clickCount: clickCount)
            }.accessibilityAction { edit() }.help("右键管理便签；双击编辑正文，字体在编辑纸张右下角的 AA 中调整。")
            .accessibilityLabel("位置笔记").accessibilityValue(text).accessibilityHint("右键或双击编辑；纸条正文保存在普通笔记中。")
    }
    private func edit() { perform(.edit) }
    private func perform(_ command: PositionNoteCommand) {
        if let onCommand { onCommand(id, command) }
        else { store.performPositionNoteCommand(command, id: id, owner: WorkspacePickerOwner(store: store)) }
    }
}
