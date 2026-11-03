import SwiftUI
import AppKit

struct PositionNoteColorPicker: View {
    @Binding var selection: String?
    @AppStorage("reading.paperStyle") private var inherited = ReadingPaperStyle.plain.rawValue
    var body: some View {
        HStack(spacing: 12) {
            ForEach(ReadingPaperStyle.allCases) { style in
                Button { selection = style.rawValue } label: {
                    ZStack {
                        Circle().fill(Color(nsColor: style.color))
                        Circle().strokeBorder(Palette.ink.opacity(0.15), lineWidth: 1)
                        if PositionNoteBackground.style(selection, inherited: inherited) == style {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                        }
                    }.frame(width: 38, height: 38).padding(3).contentShape(Circle())
                }.buttonStyle(ReadingQuietButtonStyle(radius: 22))
                    .help("便签颜色：" + style.title).accessibilityLabel("便签颜色：" + style.title)
                    .accessibilityValue(PositionNoteBackground.style(selection, inherited: inherited) == style ? "已选中" : "未选中")
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("便签纸张颜色")
    }
}

/// Native layer geometry spans the separate PDF note hosting tree and the
/// SwiftUI fan. A shared SwiftUI namespace cannot match across those roots.
/// The editor is laid out once at its final size; only its composited layer
/// moves/scales, so TextKit does not reflow at every animation frame.
struct PositionNoteEditorStage: NSViewRepresentable {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var typography: ReadingTypographySettings
    @Environment(\.readingReduceMotion) private var reduceMotion
    let request: PositionNoteRequest
    func makeNSView(context: Context) -> PositionNoteEditorStageView { PositionNoteEditorStageView() }
    func updateNSView(_ view: PositionNoteEditorStageView, context: Context) {
        view.update(id: request.id, origin: request.origin, reduceMotion: reduceMotion,
            root: AnyView(PositionNoteEditor(request: request).environmentObject(store).environmentObject(typography).modifier(ReadingPreferencesEnvironment())))
    }
}

@MainActor final class PositionNoteEditorStageView: NSView {
    override var isFlipped: Bool { true }
    private(set) var paper: NSHostingView<AnyView>?
    private var requestID: UUID?
    private var origin: PositionNoteEditorOrigin?
    private var reduceMotion = false
    private var needsEntrance = false
    private(set) var transitionStart = CGRect.zero
    private(set) var transitionTarget = CGRect.zero
    static let duration: CFTimeInterval = 0.38

    func update(id: UUID, origin: PositionNoteEditorOrigin?, reduceMotion: Bool, root: AnyView) {
        if requestID != id {
            paper?.removeFromSuperview()
            let host = NSHostingView(rootView: root); host.sizingOptions = []
            host.wantsLayer = true; addSubview(host); paper = host
            requestID = id; self.origin = origin; needsEntrance = true
        } else { paper?.rootView = root }
        self.reduceMotion = reduceMotion
        needsLayout = true
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0, let paper else { return }
        let width = max(240, min(720, bounds.width - 56)), height = max(200, min(600, bounds.height - 100))
        let target = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        if paper.frame != target { paper.frame = target }
        transitionTarget = target
        guard needsEntrance, let window else { return }; needsEntrance = false
        let source = origin.map { convert(window.convertFromScreen($0.screenFrame), from: nil) } ?? target
        transitionStart = Self.valid(source) ? source : target
        guard !reduceMotion, let layer = paper.layer, transitionStart != target else { return }
        // A cold SwiftUI/TextKit layout can outlast the entire transition.
        // Prepare its fixed-size contents before starting the layer clock.
        paper.layoutSubtreeIfNeeded()
        paper.displayIfNeeded()
        // Keep the model layer at the final position. The presentation layer
        // alone interpolates; unrelated AppStore publications cannot restart it.
        var transform = CATransform3DMakeRotation(CGFloat((origin?.degrees ?? 0) * .pi / 180), 0, 0, 1)
        transform = CATransform3DScale(transform, transitionStart.width / target.width, transitionStart.height / target.height, 1)
        let scale = CABasicAnimation(keyPath: "transform"); scale.fromValue = NSValue(caTransform3D: transform); scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        let anchor = layer.anchorPoint, finalPosition = layer.position
        let startPosition = CGPoint(x: finalPosition.x + transitionStart.minX - target.minX + anchor.x * (transitionStart.width - target.width),
                                    y: finalPosition.y + transitionStart.minY - target.minY + anchor.y * (transitionStart.height - target.height))
        let move = CABasicAnimation(keyPath: "position"); move.fromValue = NSValue(point: startPosition); move.toValue = NSValue(point: finalPosition)
        let group = CAAnimationGroup(); group.animations = [scale, move]; group.duration = Self.duration
        group.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(group, forKey: "position-note-expand")
    }
    static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 1 && rect.height > 1
    }
}

private struct WorkspaceCompanionBoundsKey: EnvironmentKey { static let defaultValue = CGRect.zero }
extension EnvironmentValues {
    var workspaceCompanionBounds: CGRect {
        get { self[WorkspaceCompanionBoundsKey.self] }
        set { self[WorkspaceCompanionBoundsKey.self] = newValue }
    }
}
