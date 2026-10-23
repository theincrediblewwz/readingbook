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
    var restoreNearTop = false
    var elevated = false
    var onExpansionChange: (Bool) -> Void = { _ in }
    @ViewBuilder var content: () -> Content
    @State private var collapsed = false
    @State private var hasOpened = false
    @State private var savedOrigin: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var epoch = 0
    @State private var memoryScope: String?
    @State private var initialPresented: Bool?
    @State private var transientPresentation: PanelPresentation?
    private struct PanelPresentation: Equatable { var presented: Bool; var collapsed: Bool }
    private var memoryID: String { memoryIDOverride ?? (trailing ? "reader.companion" : "reader.outline") }

    private var panelWidth: CGFloat { min(width, max(240, viewport.width - 100)) }
    private var panelHeight: CGFloat { collapsed ? (elevated ? 66 : 58) : min(height, max(120, viewport.height - 100 - bottomReserve)) }
    private var origin: CGPoint { clamp(savedOrigin ?? CGPoint(x: trailing ? viewport.width - panelWidth - 24 : 24, y: 100)) }
    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(24, point.x), max(24, viewport.width - panelWidth - 24)),
                y: min(max(88, point.y), max(88, viewport.height - panelHeight - bottomReserve)))
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
                // Keep the panel's contents mounted while collapsed or closed.
                // Frozen input scopes and unsaved adjustment fields survive a
                // temporary hide; hidden surfaces never receive pointer input.
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        HStack(spacing: 10) { Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.tertiary); Label(title, systemImage: icon).font(.system(size: 17, weight: .semibold)); Spacer(minLength: 0) }
                            .overlay {
                                FloatingPanelPointerInput(epoch: epoch, begin: { transientPresentation = nil; dragStart = origin }, drag: { delta, finished in
                                    let start = dragStart ?? origin
                                    savedOrigin = clamp(CGPoint(x: start.x + delta.width, y: start.y + delta.height))
                                    if finished { dragStart = nil }
                                }, cancel: { if let dragStart { savedOrigin = dragStart }; dragStart = nil })
                            }
                        Button { transientPresentation = nil; collapsed.toggle() } label: { Image(systemName: collapsed ? "plus" : "minus") }.buttonStyle(ReadingToolbarButtonStyle()).help(collapsed ? "展开\(title)" : "收起\(title)")
                        Button { transientPresentation = nil; isPresented = false } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("关闭\(title)")
                    }.padding(.leading, elevated ? 24 : 16).padding(.trailing, 10).frame(height: elevated ? 66 : 58)
                    content().frame(maxWidth: .infinity, maxHeight: collapsed ? 0 : .infinity)
                        .opacity(collapsed ? 0 : 1).clipped().allowsHitTesting(!collapsed).accessibilityHidden(collapsed)
                }.frame(width: panelWidth, height: panelHeight).readingGlass(radius: 24)
                    .overlay {
                        RoundedRectangle(cornerRadius: 24).strokeBorder(Palette.accent.opacity(elevated ? 0.13 : 0), lineWidth: 0.7).allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24)).position(x: origin.x + panelWidth / 2, y: origin.y + panelHeight / 2)
                    .opacity(isPresented ? 1 : 0).scaleEffect(isPresented || reduceMotion ? 1 : 0.97, anchor: trailing ? .topTrailing : .topLeading)
                    .allowsHitTesting(isPresented).accessibilityHidden(!isPresented)
            if !isPresented && hasOpened {
                Button { transientPresentation = nil; collapsed = false; isPresented = true } label: { Label(title, systemImage: icon) }
                    .buttonStyle(ReadingToolbarButtonStyle()).readingGlass(radius: 18)
                    .position(x: trailing ? max(100, viewport.width - 90) : 90, y: trailing && !restoreNearTop ? max(100, viewport.height - bottomReserve - 26) : 128)
                    .transition(.opacity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // These keys animate opening only. Pointer-driven origins never acquire an animation.
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: isPresented)
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: collapsed)
            .onAppear { initialPresented = isPresented; restoreMemory(); if viewport.width < 1050 && trailing { isPresented = false }; receivePanelCommand(store.workspaceAICommand) }
            .onChange(of: store.workspaceAICommand) { _, command in receivePanelCommand(command) }
            .onChange(of: store.workspaceMemoryRevision) { _, _ in restoreMemory() }
            .onChange(of: collapsed) { _, value in onExpansionChange(!value && isPresented); saveMemory() }
            .onChange(of: isPresented) { _, value in if value { hasOpened = true }; onExpansionChange(value && !collapsed); saveMemory() }
            .onChange(of: savedOrigin) { _, _ in saveMemory() }
            .onDisappear { saveMemory() }
            .onChange(of: viewport) { old, value in
                epoch += 1; dragStart = nil; savedOrigin = clamp(savedOrigin ?? origin)
                if old.width >= 1050, value.width < 1050, trailing { isPresented = false }
            }
    }
    private func restoreMemory() {
        transientPresentation = nil
        memoryScope = store.workspaceMemoryKey
        let saved = store.workspaceMemory.panels[memoryID]
        collapsed = saved?.collapsed ?? false
        savedOrigin = saved?.origin.map { clamp(CGPoint(x: $0.x, y: $0.y)) }
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
