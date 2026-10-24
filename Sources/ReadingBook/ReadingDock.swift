import SwiftUI
import AppKit
import ReadingCore

/// A single material layer for a group of tools, with full-size pointer targets.
struct ReadingDockSurface<Content: View>: View {
    var spacing: CGFloat = 4
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: spacing, content: content)
            .buttonStyle(ReadingToolbarButtonStyle()).menuStyle(.borderlessButton)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .readingGlass(radius: 26).fixedSize(horizontal: true, vertical: true)
            .accessibilityElement(children: .contain)
    }
}

struct DockDivider: View {
    var body: some View { Rectangle().fill(Palette.line.opacity(0.8)).frame(width: 1, height: 20).padding(.horizontal, 3) }
}

struct DockIconButton: View {
    let title: String
    let icon: String
    var isSelected = false
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 18, weight: .medium)) }
            .buttonStyle(ReadingToolbarButtonStyle(selected: isSelected))
            .help(title).accessibilityLabel(title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Only the group's horizontal position is adjustable. The saved state uses
/// the existing disposable workspace memory; books and documents are untouched.
struct FloatingReadingDock<Content: View>: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.readingReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let id: String
    let viewport: CGSize
    var bottom: CGFloat = 18
    var allowsDragging = true
    @ViewBuilder var content: () -> Content
    @State private var width: CGFloat = 360
    @State private var dock: FloatingPanelDock = .bottomCenter
    @GestureState private var dragTranslation: CGFloat = 0
    @GestureState private var dragActive = false
    @State private var dragCancelled = false
    @State private var memoryScope: String?
    private var settledX: CGFloat {
        switch dock {
        case .bottomLeading: return 18 + width / 2
        case .bottomTrailing: return viewport.width - 18 - width / 2
        default: return viewport.width / 2
        }
    }
    private func fittedX(_ x: CGFloat) -> CGFloat { min(max(width / 2 + 12, x), max(width / 2 + 12, viewport.width - width / 2 - 12)) }
    var body: some View {
        GeometryReader { geometry in
            let y = max(26, viewport.height - bottom - 26)
            ReadingDockSurface(content: content)
                .background { GeometryReader { measured in Color.clear.preference(key: ReadingDockWidthKey.self, value: measured.size.width) } }
                .onPreferenceChange(ReadingDockWidthKey.self) { if $0 > 0 && abs(width - $0) > 0.5 { width = $0 } }
                .highPriorityGesture(DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .updating($dragTranslation) { gesture, offset, _ in offset = gesture.translation.width }
                    .updating($dragActive) { _, active, _ in active = true }
                    .onEnded { gesture in
                        guard !dragCancelled, scenePhase == .active, allowsDragging else { return }
                        let x = fittedX(settledX + gesture.translation.width)
                        let choices: [(FloatingPanelDock, CGFloat)] = [(.bottomLeading, fittedX(18 + width / 2)), (.bottomCenter, viewport.width / 2), (.bottomTrailing, fittedX(viewport.width - 18 - width / 2))]
                        withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { dock = choices.min { abs($0.1 - x) < abs($1.1 - x) }?.0 ?? .bottomCenter }
                        save()
                    }, including: allowsDragging ? .all : .none)
                .contextMenu {
                    Button("停靠左侧") { settle(.bottomLeading) }
                    Button("停靠中央") { settle(.bottomCenter) }
                    Button("停靠右侧") { settle(.bottomTrailing) }
                }
                .position(x: fittedX(settledX + (dragCancelled ? 0 : dragTranslation)), y: y)
                .background {
                    // Avoidance uses the settled frame, never each pointer tick.
                    let origin = geometry.frame(in: .global).origin
                    Color.clear.preference(key: WorkspaceChromeBoundsPreference.self, value: [id: CGRect(x: origin.x + fittedX(settledX) - width / 2, y: origin.y + y - 26, width: width, height: 52)]).allowsHitTesting(false)
                }
        }.onAppear(perform: restore)
            .onChange(of: store.workspaceMemoryRevision) { _, _ in restore() }
            .onChange(of: store.bookID) { _, _ in restore() }
            .onChange(of: dragActive) { _, active in if active { dragCancelled = false } }
            .onChange(of: viewport) { _, _ in dragCancelled = true }
            .onChange(of: allowsDragging) { _, _ in dragCancelled = true }
            .onChange(of: scenePhase) { _, phase in if phase != .active { dragCancelled = true } }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in dragCancelled = true }
            .onExitCommand { if dragActive { dragCancelled = true } }
    }
    private func settle(_ value: FloatingPanelDock) { withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { dock = value; dragCancelled = true }; save() }
    private func restore() {
        memoryScope = store.workspaceMemoryKey
        dock = store.workspaceMemory.panels["dock." + id]?.dock.flatMap(FloatingPanelDock.init(rawValue:)) ?? .bottomCenter
        dragCancelled = true
    }
    private func save() { store.updateWorkspaceMemory({ $0.panels["dock." + id] = WorkspacePanelMemory(dock: dock.rawValue) }, expectedKey: memoryScope) }
}

private struct ReadingDockWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct DockMenuRow: View {
    let title: String
    let icon: String
    var detail: String? = nil
    var selected = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Palette.accent.opacity(0.8)).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14)).lineLimit(1)
                    if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark.circle").font(.system(size: 14)).foregroundStyle(Palette.accent) }
            }.padding(.horizontal, 12).padding(.vertical, 7).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
