import SwiftUI
import ReadingCore

/// The overlay never changes PDF layout. Collapsing keeps its editor mounted.
struct ReaderQuestionComposer: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.readingReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool
    @State private var question = ""
    @Binding var isExpanded: Bool
    var viewport: CGSize
    var availableRect: CGRect
    var compact = false
    /// Report only settled frames; other panels must not chase the pointer.
    var onFrameChange: (CGRect) -> Void = { _ in }
    @State private var expandedSize = QuestionPanelGeometry.defaultSize
    @State private var dock: FloatingPanelDock = .bottomTrailing
    @State private var liveFrame: CGRect?
    @State private var dragStart: CGRect?
    @State private var resizeStart: CGRect?
    @State private var pointerEpoch = 0
    @State private var memoryScope: String?

    private let memoryID = "reader.question"
    private var bounds: CGRect { QuestionPanelGeometry.availableBounds(availableRect, viewport: viewport) }
    private var fittedSize: CGSize { QuestionPanelGeometry.fittedSize(requested: expandedSize, in: bounds) }
    private var expandedFrame: CGRect { liveFrame ?? QuestionPanelGeometry.frame(at: dock, in: bounds, panel: fittedSize) }
    private var orbFrame: CGRect { QuestionPanelGeometry.frame(at: dock, in: bounds, panel: QuestionPanelGeometry.orbSize) }
    private var visibleFrame: CGRect { isExpanded ? expandedFrame : orbFrame }
    private var resizeCorner: QuestionPanelResizeCorner { QuestionPanelGeometry.resizeCorner(for: dock) }
    private var resizeAlignment: Alignment {
        switch resizeCorner {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }
    private var expansionAnchor: UnitPoint {
        switch dock {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomTrailing: return .bottomTrailing
        }
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            composer
                .frame(width: expandedFrame.width, height: expandedFrame.height)
                .readingGlass(radius: 22)
                .overlay(alignment: resizeAlignment) { resizeHandle }
                .position(x: expandedFrame.midX, y: expandedFrame.midY)
                .opacity(isExpanded ? 1 : 0)
                .scaleEffect(isExpanded || reduceMotion ? 1 : 0.94, anchor: expansionAnchor)
                .allowsHitTesting(isExpanded && bounds.width > 0 && bounds.height > 0)
                .accessibilityHidden(!isExpanded)
            if !isExpanded {
                Button { expand() } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 22, weight: .medium)).foregroundStyle(Palette.accent)
                        .frame(width: orbFrame.width, height: orbFrame.height)
                        .overlay(alignment: .topTrailing) {
                            if !question.isEmpty { Circle().fill(Palette.accent).frame(width: 8, height: 8).padding(5) }
                        }
                }.buttonStyle(.plain).readingGlass(radius: 29, interactive: true)
                    .help(question.isEmpty ? "问 AI" : "继续未发送的问题").accessibilityLabel("展开 AI 提问")
                    .position(x: orbFrame.midX, y: orbFrame.midY)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }.frame(width: max(0, viewport.width), height: max(0, viewport.height), alignment: .topLeading)
            .transaction { transaction in
                if dragStart != nil || resizeStart != nil { transaction.animation = nil; transaction.disablesAnimations = true }
            }
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: isExpanded)
            .animation(nil, value: viewport).animation(nil, value: availableRect)
            .onAppear { restoreMemory(); onFrameChange(visibleFrame) }
            .onChange(of: isExpanded) { _, value in
                if !value { inputFocused = false; cancelInteraction() }
                saveMemory(); onFrameChange(visibleFrame)
            }
            .onChange(of: store.bookID) { _, _ in question = ""; inputFocused = false; cancelInteraction(); restoreMemory(); onFrameChange(visibleFrame) }
            .onChange(of: store.workspaceMemoryRevision) { _, _ in cancelInteraction(); restoreMemory(); onFrameChange(visibleFrame) }
            .onChange(of: viewport) { _, _ in geometryChanged() }
            .onChange(of: availableRect) { _, _ in geometryChanged() }
            .onDisappear { cancelInteraction(); saveMemory(); onFrameChange(.zero) }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                HStack(spacing: 9) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 18)).foregroundStyle(.tertiary)
                    Text("问 AI").font(.system(size: 16, weight: .semibold))
                    Spacer(minLength: 0)
                }.frame(height: 44).contentShape(Rectangle())
                    .overlay {
                        FloatingPanelPointerInput(epoch: pointerEpoch, begin: beginDragging,
                                                  drag: drag(by:ended:), cancel: cancelInteraction)
                    }.help("拖动提问框，松手吸附到附近位置")
                Button { store.requestedWorkspaceRoute = "query" } label: { Image(systemName: "bubble.left.and.bubble.right") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("打开与书对话")
                Button { collapse() } label: { Image(systemName: "minus") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("缩为悬浮按钮，保留草稿").accessibilityLabel("收起 AI 提问")
            }.padding(.leading, resizeCorner == .topLeading ? 30 : 16)
                .padding(.trailing, resizeCorner == .topTrailing ? 30 : 10).padding(.top, 6)
            HStack(spacing: 12) {
                QueryScopeControl(compact: true)
                QueryAttachmentsControl()
                Spacer(minLength: 0)
            }.padding(.horizontal, 16).padding(.bottom, 4)
            HStack(alignment: .bottom, spacing: 12) {
                TextField("围绕所选内容，问一个问题…", text: $question, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(1...12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .focused($inputFocused).onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).frame(width: 26, height: 28)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!store.canStartQuery || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canUseQueryScope(store.queryScope))
                    .help("按所选范围提问").accessibilityLabel("发送问题")
            }.frame(minHeight: 44, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, resizeCorner == .bottomLeading ? 30 : 16)
                .padding(.trailing, resizeCorner == .bottomTrailing ? 30 : 16).padding(.bottom, 14)
        }.clipped()
    }
    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary.opacity(0.65))
            .rotationEffect(.degrees(resizeCorner == .topTrailing || resizeCorner == .bottomLeading ? 90 : 0))
            .frame(width: 24, height: 24).contentShape(Rectangle())
            .overlay {
                FloatingPanelPointerInput(epoch: pointerEpoch, begin: beginResizing,
                                          drag: resize(by:ended:), cancel: cancelInteraction)
            }.help("拖动调整提问框的宽度和高度").accessibilityLabel("调整提问框大小")
    }
    private func expand() {
        cancelInteraction()
        withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { isExpanded = true }
        inputFocused = true
    }
    private func collapse() {
        inputFocused = false; cancelInteraction()
        withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { isExpanded = false }
    }
    private func beginDragging() {
        guard isExpanded else { return }
        resizeStart = nil; dragStart = expandedFrame
    }
    private func drag(by delta: CGSize, ended: Bool) {
        guard let start = dragStart else { return }
        let frame = QuestionPanelGeometry.clampedFrame(start.offsetBy(dx: delta.width, dy: delta.height), in: bounds)
        if ended { finishInteraction(frame: frame, resized: false) }
        else { withoutAnimation { liveFrame = frame } }
    }
    private func beginResizing() {
        guard isExpanded else { return }
        dragStart = nil; resizeStart = expandedFrame
    }
    private func resize(by delta: CGSize, ended: Bool) {
        guard let start = resizeStart else { return }
        let frame = QuestionPanelGeometry.resizedFrame(from: start, delta: delta, corner: resizeCorner, in: bounds)
        if ended { finishInteraction(frame: frame, resized: true) }
        else { withoutAnimation { liveFrame = frame } }
    }
    private func finishInteraction(frame: CGRect, resized: Bool) {
        let target = QuestionPanelGeometry.nearest(to: CGPoint(x: frame.midX, y: frame.midY), in: bounds, panel: frame.size, preferred: dock)
        dragStart = nil; resizeStart = nil
        if resized { expandedSize = frame.size }
        withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { dock = target; liveFrame = nil }
        saveMemory(); onFrameChange(visibleFrame)
    }
    private func cancelInteraction() {
        withoutAnimation { dragStart = nil; resizeStart = nil; liveFrame = nil }
    }
    private func geometryChanged() {
        pointerEpoch &+= 1; cancelInteraction()
        // Narrow-window fitting never overwrites the preferred expanded size.
        onFrameChange(visibleFrame)
    }
    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction(); transaction.animation = nil; transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
    private func restoreMemory() {
        memoryScope = store.workspaceMemoryKey
        let saved = store.workspaceMemory.panels[memoryID]
        expandedSize = saved?.size.map { CGSize(width: $0.width, height: $0.height) } ?? QuestionPanelGeometry.defaultSize
        dock = saved?.dock.flatMap(FloatingPanelDock.init(rawValue:)) ?? .bottomTrailing
        isExpanded = saved.map { $0.isPresented && !$0.collapsed } ?? false
    }
    private func saveMemory() {
        guard let memoryScope else { return }
        let memory = WorkspacePanelMemory(isPresented: true, collapsed: !isExpanded,
            size: WorkspaceSize(width: Double(expandedSize.width), height: Double(expandedSize.height)), dock: dock.rawValue)
        store.updateWorkspaceMemory({ $0.panels[memoryID] = memory }, expectedKey: memoryScope)
    }
    private func send() {
        guard store.canStartQuery, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // ask synchronously freezes the boundary before this view can navigate.
        store.ask(question)
        if store.isQueryBusy { question = ""; store.requestedWorkspaceRoute = "query" }
    }
}
