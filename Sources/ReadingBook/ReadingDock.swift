import SwiftUI
import AppKit
import ReadingCore

/// A single material layer for a group of tools, with full-size pointer targets.
struct ReadingDockSurface<Content: View>: View {
    var spacing: CGFloat = 4
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: spacing, content: content)
            .buttonStyle(ReadingToolbarButtonStyle()).menuStyle(.borderlessButton).modifier(ReadingHoverSurface())
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
    var explanation: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 18, weight: .medium)) }
            .buttonStyle(ReadingToolbarButtonStyle(selected: isSelected))
            .help(explanation ?? title).accessibilityLabel(title)
            .accessibilityHint(explanation ?? title)
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
    var autoHides = false
    var keepsExpanded = false
    @ViewBuilder var content: () -> Content
    @State private var width: CGFloat = 360
    @State private var dock: FloatingPanelDock = .bottomCenter
    @GestureState private var dragTranslation: CGFloat = 0
    @GestureState private var dragActive = false
    @State private var dragCancelled = false
    @State private var memoryScope: String?
    @State private var revealed = false
    @State private var manuallyExpanded = false
    @State private var handleHovered = false
    @State private var toolsHovered = false
    @State private var collapseTask: Task<Void, Never>?
    private var expanded: Bool { !autoHides || revealed || manuallyExpanded || keepsExpanded || dragActive }
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
            ZStack(alignment: .bottom) {
                if autoHides && manuallyExpanded {
                    Button { manuallyExpanded = false; scheduleCollapse() } label: { Color.clear }
                        .keyboardShortcut(.escape, modifiers: [])
                        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                }
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
                .padding(.bottom, autoHides ? bottom : 0)
                .padding(.top, autoHides ? 12 : 0)
                .contentShape(Rectangle())
                .onHover { toolsHovered = $0; updateReveal(inside: $0) }
                .opacity(expanded ? 1 : 0)
                .offset(y: expanded ? 0 : 72)
                .allowsHitTesting(expanded)
                .accessibilityHidden(!expanded)
                if autoHides {
                    Button { manuallyExpanded = true; reveal() } label: {
                        Capsule().fill(.white.opacity(0.72)).frame(width: width, height: 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay { Capsule().strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5) }
                            .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
                            .shadow(color: .black.opacity(0.08), radius: 7, y: 3)
                            .frame(width: width, height: 22, alignment: .bottom).padding(.bottom, 3)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .opacity(expanded ? 0 : 1)
                        .onHover { handleHovered = $0; updateReveal(inside: $0) }
                        .accessibilityHidden(expanded)
                        .accessibilityLabel("展开阅读工具栏")
                        .accessibilityIdentifier("reader-tools-reveal")
                        .help("悬停展开阅读工具栏；点击保持展开，按 Esc 恢复自动收起。")
                }
            }
                .frame(width: width, height: autoHides ? 90 : 52, alignment: .bottom)
                .position(x: fittedX(settledX + (dragCancelled ? 0 : dragTranslation)), y: autoHides ? viewport.height - 45 : y)
                .animation(ReadingMotion.animation(reduce: reduceMotion), value: expanded)
                .background {
                    // Avoidance uses the settled frame, never each pointer tick.
                    let origin = geometry.frame(in: .global).origin
                    let rect = autoHides && !expanded
                        ? CGRect(x: origin.x + fittedX(settledX) - width / 2, y: origin.y + viewport.height - 25, width: width, height: 25)
                        : CGRect(x: origin.x + fittedX(settledX) - width / 2, y: origin.y + y - 26, width: width, height: 52)
                    Color.clear.preference(key: WorkspaceChromeBoundsPreference.self, value: [id: rect]).allowsHitTesting(false)
                }
        }.onAppear(perform: restore)
            .onChange(of: store.workspaceMemoryRevision) { _, _ in restore() }
            .onChange(of: store.bookID) { _, _ in restore() }
            .onChange(of: dragActive) { _, active in if active { dragCancelled = false } }
            .onChange(of: viewport) { _, _ in dragCancelled = true }
            .onChange(of: allowsDragging) { _, _ in dragCancelled = true }
            .onChange(of: keepsExpanded) { _, value in if value { collapseTask?.cancel() } else { scheduleCollapse() } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { dragCancelled = true } }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in dragCancelled = true }
            .onExitCommand { if dragActive { dragCancelled = true }; manuallyExpanded = false; scheduleCollapse() }
            .onDisappear { collapseTask?.cancel() }
    }
    private func reveal() {
        collapseTask?.cancel()
        withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { revealed = true }
    }
    private func updateReveal(inside: Bool) { if inside { reveal() } else { scheduleCollapse() } }
    private func scheduleCollapse() {
        collapseTask?.cancel()
        guard autoHides, !handleHovered, !toolsHovered, !manuallyExpanded, !keepsExpanded, !dragActive else { return }
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, !handleHovered, !toolsHovered, !manuallyExpanded, !keepsExpanded, !dragActive else { return }
            withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { revealed = false }
        }
    }
    private func settle(_ value: FloatingPanelDock) { withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { dock = value; dragCancelled = true }; save() }
    private func restore() {
        if memoryScope != store.workspaceMemoryKey { collapseTask?.cancel(); revealed = false; manuallyExpanded = false }
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
        }.buttonStyle(ReadingQuietButtonStyle())
    }
}
