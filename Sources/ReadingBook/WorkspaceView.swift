import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ReadingCore

struct WorkspaceView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var navigationSelection
    @State private var compactInspector = false
    @State private var showsInspector = false
    @State private var detailWidth: CGFloat = 0
    @State private var servicePopover = false
    @State private var bookPopover = false
    @State private var editingPDFPage = false
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @StateObject private var pdfController = PDFReaderController()
    @StateObject private var pluginDefinitionDrafts = PluginDefinitionDraftStore()
    @StateObject private var bookSchemeDrafts = BookSchemeViewDraftStore()
    @State private var workspaceHeight: CGFloat = 600
    @State private var progressSize = CGSize(width: 260, height: 52)
    @State private var readerShowsPDF = true
    @State private var readerOutline = false
    @State private var readerBookmarks = false
    @State private var readerPopover: ReaderToolPopover?
    @State private var activeSheet: WorkspaceSheet?
    @State private var lastSheet: WorkspaceSheet?
    @State private var sheetClosing = false
    @State private var navigationExpanded = false
    @State private var pendingRoute: String?
    @State private var pendingModelRoute: String?
    @State private var showsRouteConfirmation = false
    @State private var showsModelRouteConfirmation = false
    @State private var resolvingNavigation = false
    @State private var chromeBounds: [String: CGRect] = [:]
    @State private var managementRoute: String?
    private var workspaceContent: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Palette.canvas.ignoresSafeArea()
                content
                    .allowsHitTesting(managementRoute == nil)
                    .environment(\.workspaceCanvasBlocked, canvasInteractionBlocked)
                    .environment(\.workspaceCanvasExclusionRects, canvasExclusionRects)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(managementRoute != nil)
                    .overlay {
                        if store.route == "reader", store.selectedUnit != nil, managementRoute == nil {
                            FloatingReadingDock(id: "reader-tools", viewport: geometry.size, allowsDragging: !editingPDFPage) { readerControls }
                        }
                    }
                    .clipped()
                if store.isBusy && !store.isSmartReadingRunning && !viewingWorkflow && !viewingGraph && !viewingSpatial && store.route != "reader" {
                    footer.frame(maxWidth: 310).readingGlass(radius: 16)
                        .padding(.trailing, 24).padding(.bottom, 86).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                topIslands(width: geometry.size.width).padding(.top, 14).padding(.leading, 104).padding(.trailing, 24)
                    .allowsHitTesting(managementRoute == nil)
                    .opacity(managementRoute == nil ? 1 : 0).accessibilityHidden(managementRoute != nil)
                if store.book?.smartReading != nil && managementRoute == nil && !navigationExpanded && store.route != "library" {
                    floatingProgress(in: geometry).zIndex(6)
                }
                if let managementRoute {
                    managementOverlay(managementRoute)
                        .transition(.opacity.combined(with: .scale(scale: 0.985))).zIndex(8)
                }
                if navigationExpanded {
                    sidebar.frame(width: min(286, geometry.size.width - 96), height: max(100, min(690, geometry.size.height - 126)))
                        .readingGlass(radius: 24).padding(.leading, 16).padding(.top, 88)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading))).zIndex(10)
                }

            }
            .onPreferenceChange(WorkspaceChromeBoundsPreference.self) { if chromeBounds != $0 { chromeBounds = $0 } }
            .onAppear { detailWidth = geometry.size.width; workspaceHeight = geometry.size.height }
            .onChange(of: geometry.size.height) { _, height in workspaceHeight = height }
            .onChange(of: geometry.size.width) { _, width in
                detailWidth = width
                if width < 920 { showsInspector = false }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .environmentObject(pdfController)
        .environment(\.bookSchemeDraftStore, bookSchemeDrafts)
        .serviceProfileChangeConfirmation(store: store)
        .tint(Palette.accent)
        .focusedSceneValue(\.readerFindAction, readerFindAction)
    }
    private var deletionPresented: Binding<Bool> {
        Binding(get: { store.deletionRequest != nil }, set: { visible in if !visible { store.deletionRequest = nil } })
    }
    private var navigationConfirmedWorkspace: some View {
        workspaceContent
        .onOpenURL { url in Task { await store.openInternalURL(url) } }
        .confirmationDialog("保存当前 Markdown 后离开？", isPresented: $showsRouteConfirmation, presenting: pendingRoute) { destination in
            Button("保存并继续") { saveDocumentAndNavigate(to: destination) }.disabled(store.isBusy)
            Button("放弃修改并继续", role: .destructive) {
                pendingRoute = nil; showsRouteConfirmation = false
                store.discardDraftForWorkspaceNavigation(); store.route = destination
            }.disabled(store.isBusy)
            Button("继续编辑", role: .cancel) { pendingRoute = nil; showsRouteConfirmation = false }
        } message: { _ in Text("已保存正文保留；本次未保存修改可保存或放弃。") }
        .confirmationDialog("当前模型配置尚未保存", isPresented: $showsModelRouteConfirmation, presenting: pendingModelRoute) { destination in
            Button("保存并继续") { resolveModelNavigation(to: destination, save: true) }.disabled(store.isBusy)
            Button("放弃更改并继续", role: .destructive) { resolveModelNavigation(to: destination, save: false) }.disabled(store.isBusy)
            Button("继续编辑", role: .cancel) { pendingModelRoute = nil; showsModelRouteConfirmation = false }
        } message: { _ in Text("保存会写入本机配置与钥匙串；取消可继续编辑。") }
        .onChange(of: showsRouteConfirmation) { _, visible in
            if !visible && !resolvingNavigation { pendingRoute = nil }
        }
        .onChange(of: showsModelRouteConfirmation) { _, visible in
            if !visible && !resolvingNavigation { pendingModelRoute = nil }
        }
    }
    private var presentedWorkspace: some View {
        navigationConfirmedWorkspace
        .sheet(item: sheetBinding, onDismiss: finishSheetDismissal) { sheet in
            switch sheet {
            case .settings: ProviderSettingsView(onClose: { closeSheet(.settings) }).environmentObject(store).frame(width: min(860, max(300, detailWidth - 40)), height: min(660, max(300, workspaceHeight - 40)))
            case .ocr: PDFOCRPanel().environmentObject(store).frame(width: 560, height: 460)
            case .trash: LibraryTrashView().environmentObject(store).frame(width: 600, height: 500)
            case .plugins: PluginLibraryView(onClose: { closeSheet(.plugins) }, draftStore: pluginDefinitionDrafts).environmentObject(store).frame(width: min(900, max(300, detailWidth - 40)), height: min(680, max(300, workspaceHeight - 40)))
            case .librarySearch: LibrarySearchView().environmentObject(store).frame(minWidth: 620, idealWidth: 800, minHeight: 500, idealHeight: 640)
            case .password(let request): PDFPasswordSheet(request: request).environmentObject(store)
            }
        }
        .onChange(of: modalSignature) { _, _ in reconcileSheet() }
        .onChange(of: managementRoute) { _, route in
            if route != nil { readerPopover = nil; navigationExpanded = false; bookPopover = false; servicePopover = false; store.queryAllowsOrganizing = false }
        }
        .onChange(of: activeSheet?.id) { _, id in
            if id != nil { readerPopover = nil; navigationExpanded = false; bookPopover = false; servicePopover = false }
        }
        .onChange(of: viewingPDF) { _, visible in
            if !visible, readerPopover != .navigation { readerPopover = nil }
        }
        .onChange(of: bookPopover) { _, visible in if !visible { servicePopover = false } }
    }
    private var persistedWorkspace: some View {
        presentedWorkspace
        .onAppear { repairLegacyManagementRoute(); reconcileSheet(); restoreReaderMemory() }
        .onChange(of: store.workspaceMemoryRevision) { _, _ in restoreReaderMemory() }
        .onChange(of: readerShowsPDF) { _, value in store.updateWorkspaceMemory { $0.readerShowsPDF = value } }
        .onChange(of: readerOutline) { _, value in store.updateWorkspaceMemory { $0.readerOutline = value } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in captureAndFlushWorkspace() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in captureAndFlushWorkspace() }
        .onChange(of: store.requestedWorkspaceRoute) { _, route in
            guard let route else { return }; store.requestedWorkspaceRoute = nil; navigate(route)
        }
    }
    private var guardedWorkspace: some View {
        persistedWorkspace
        .confirmationDialog("移入回收站？", isPresented: deletionPresented, presenting: store.deletionRequest) { request in
            Button("移入回收站", role: .destructive) { store.confirmDeletion(request) }
            Button("取消", role: .cancel) { store.deletionRequest = nil }
        } message: { request in Text("“\(request.title)”\n" + request.detail) }
        .alert("需要处理", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard !store.isBusy, let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                if let data = value as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { Task { @MainActor in store.importBook(url) } }
            }
            return true
        }
    }
    var body: some View {
        guardedWorkspace
        .onChange(of: store.bookID) { _, _ in showsInspector = false; compactInspector = false; readerPopover = nil; readerBookmarks = false; progressSize = CGSize(width: 260, height: 52) }
        .onChange(of: store.route) { old, next in
            readerPopover = nil
            if ["models", "plugins", "book.scheme"].contains(next) {
                store.route = ["models", "plugins", "book.scheme"].contains(old) ? (store.book == nil ? "library" : "reader") : old
                presentManagement(next)
            } else if viewingGraph || viewingSpatial { showsInspector = false; compactInspector = false }
        }
    }
    private func floatingProgress(in geometry: GeometryProxy) -> some View {
        let global = geometry.frame(in: .global)
        let available = CGRect(x: 20, y: 88, width: max(0, geometry.size.width - 40), height: max(0, geometry.size.height - 112))
        let obstacles = chromeBounds.filter { $0.key != "smart-progress" && $0.key != "window-drag" }.map {
            $0.value.offsetBy(dx: -global.minX, dy: -global.minY)
        }
        let preferred = CGPoint(x: geometry.size.width < 700 ? 68 : 80, y: geometry.size.height - 104 - progressSize.height)
        let placement = FloatingChromeGeometry.place(size: progressSize, preferredOrigin: preferred, within: available, avoiding: obstacles)
        let compact = placement == nil ? FloatingChromeGeometry.place(size: CGSize(width: 52, height: 52), preferredOrigin: preferred, within: available, avoiding: obstacles) : nil
        let frame = placement ?? CGRect(origin: preferred, size: progressSize)
        return ZStack(alignment: .topLeading) {
          SmartReadingProgressPanel(maximumExpandedHeight: max(100, min(430, geometry.size.height - 220))).environmentObject(store)
            .background {
                GeometryReader { panel in Color.clear.preference(key: WorkspaceProgressSizePreference.self, value: panel.size) }
            }
            .onPreferenceChange(WorkspaceProgressSizePreference.self) { value in
                guard value.width.isFinite, value.height.isFinite, value.width > 0, value.height > 0,
                      abs(value.width - progressSize.width) > 0.5 || abs(value.height - progressSize.height) > 0.5 else { return }
                progressSize = value
            }
            .workspaceChromeBounds("smart-progress")
            .transformPreference(WorkspaceChromeBoundsPreference.self) { if placement == nil { $0.removeValue(forKey: "smart-progress") } }
            .opacity(placement == nil ? 0 : 1).allowsHitTesting(placement != nil).accessibilityHidden(placement == nil)
            .position(x: frame.midX, y: frame.midY)
          if let compact {
            Button { navigate("workflow") } label: {
                Image(systemName: store.isSmartReadingRunning ? "sparkles" : "book.pages")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.accent)
                    .frame(width: 52, height: 52).contentShape(Circle())
            }.buttonStyle(.plain).readingGlass(radius: 26, interactive: true)
                .help("空间有限；点击查看智能阅读进度与结果")
                .accessibilityLabel("查看智能阅读进度")
                .contextMenu { if store.isSmartReadingRunning { Button("暂停分析，保留检查点") { store.pause() } } }
                .workspaceChromeBounds("smart-progress")
                .position(x: compact.midX, y: compact.midY)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func restoreReaderMemory() {
        readerShowsPDF = store.workspaceMemory.readerShowsPDF
        readerOutline = store.workspaceMemory.readerOutline
    }
    private func captureAndFlushWorkspace() {
        NotificationCenter.default.post(name: Notification.Name("ReadingBookCaptureWorkspaceMemory"), object: nil)
        store.flushWorkspaceMemory(); store.flushDocumentDraft()
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandGlyph(name: "mark").frame(width: 25, height: 25).foregroundStyle(Palette.accent)
                Text("阅读工作台").font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 0)
                Button { withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { navigationExpanded = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(ReadingToolbarButtonStyle()).help("收起导航")
            }.padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    routeButton("书库", icon: "books.vertical", route: "library")
                    if store.book != nil {
                        Divider().padding(.vertical, 8)
                        routeButton("原文阅读", icon: "book.pages", route: "reader")
                        routeButton("智能阅读", icon: "sparkles", route: "workflow")
                        routeButton("与书对话", icon: "bubble.left.and.bubble.right", route: "query")
                        routeButton("我的笔记", icon: "square.and.pencil", route: "editor")
                        if !componentViews.isEmpty {
                            Text("本书组件").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 5)
                            ForEach(componentViews) { view in
                                routeButton(view.title, icon: WorkspaceComponentRegistry.shared.component(for: view)?.icon ?? "puzzlepiece.extension", route: view.id)
                                    .contextMenu {
                                        let count = WorkspaceComponentRegistry.shared.removalIDs(for: view, in: store.book?.views ?? []).count
                                        Button(count > 1 ? "将组件及 \(count - 1) 个重复入口移入回收站" : "将组件移入回收站", role: .destructive) {
                                            let sourceBookID = store.bookID
                                            Task { guard store.bookID == sourceBookID else { return }; await store.removeView(view.id) }
                                        }.disabled(store.isBusy || store.editorDirty)
                                    }
                            }
                        }
                        if !addableComponents.isEmpty {
                            Menu {
                                ForEach(addableComponents) { component in
                                    Button { store.activate(component) } label: { Label(component.title, systemImage: component.icon) }
                                }
                            } label: { Label("添加组件", systemImage: "plus.square.on.square").frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle()) }
                                .menuStyle(.borderlessButton).padding(.horizontal, 14).disabled(store.isBusy)
                        }
                    }
                    Divider().padding(.vertical, 8)
                    routeButton("插件与组件", icon: "puzzlepiece.extension", route: "plugins")
                    routeButton("模型设置", icon: "slider.horizontal.3", route: "models")
                    routeButton("搜索", icon: "magnifyingglass", route: "librarySearch").help("搜索本书与书库")
                    routeButton("回收站", icon: "trash", route: "trash")
                    Menu {
                        Button { store.chooseBook() } label: { Label("导入书籍…", systemImage: "book.badge.plus") }
                        Button { store.importProject() } label: { Label("导入书项目…", systemImage: "square.and.arrow.down") }
                        Button { store.exportProject() } label: { Label("导出完整书项目…", systemImage: "square.and.arrow.up") }.disabled(store.book == nil)
                    } label: { Label("导入与导出", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle()) }.menuStyle(.borderlessButton).padding(.horizontal, 14).disabled(store.isBusy)
                }.padding(.horizontal, 10).padding(.bottom, 14)
            }
        }
    }
    private var componentViews: [ViewDefinition] { WorkspaceComponentRegistry.shared.navigationViews(store.enabledViews) }
    private var addableComponents: [WorkspaceComponentDescriptor] {
        guard store.book != nil else { return [] }
        let registry = WorkspaceComponentRegistry.shared
        return registry.components.filter { component in
            !component.permanent && !component.requiresDefinition && store.savedComponent(for: component) == nil
        }
    }
    private func routeButton(_ title: String, icon: String, route: String) -> some View {
        Button { navigate(route) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium)).frame(width: 22, height: 22)
                Text(title).font(.system(size: 15, weight: store.route == route ? .semibold : .regular))
                Spacer(minLength: 0)
            }.padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: ReadingLayout.navigationRowHeight, alignment: .leading)
                .modifier(WorkspaceNavigationRowHover(reduceMotion: reduceMotion))
                .background {
                    if store.route == route {
                        RoundedRectangle(cornerRadius: 12).fill(Palette.accent.opacity(0.12))
                            .matchedGeometryEffect(id: "workspace-selection", in: navigationSelection)
                    }
                }
                .contentShape(Rectangle())
                .overlay(alignment: .leading) { if store.route == route { Capsule().fill(Palette.accent).frame(width: 2, height: 15).padding(.leading, 3) } }
        }.buttonStyle(.plain).foregroundStyle(store.route == route ? Palette.accent : .primary)
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: store.route)
    }
    private var viewingPDF: Bool { store.route == "reader" && store.readingSourceMode == "original" && readerShowsPDF && store.sourceFileURL?.pathExtension.lowercased() == "pdf" }
    private var viewingWorkflow: Bool { store.route == "workflow" || store.book?.views.first(where: { $0.id == store.route })?.kind == .workflow }
    private var viewingGraph: Bool {
        let kind = store.book?.views.first(where: { $0.id == store.route })?.kind ?? ComponentKind(rawValue: store.route)
        return kind == .mindmap || kind == .relations
    }
    private var viewingSpatial: Bool {
        let kind = store.book?.views.first(where: { $0.id == store.route })?.kind ?? ComponentKind(rawValue: store.route)
        return kind == .map || kind == .timeline
    }
    /// Exclusion rectangles stay in SwiftUI global coordinates. GraphSurface
    /// converts them once into its own canvas coordinates.
    private var canvasInteractionBlocked: Bool {
        navigationExpanded || bookPopover || readerPopover != nil || compactInspector || activeSheet != nil || sheetClosing || managementRoute != nil
            || showsRouteConfirmation || showsModelRouteConfirmation || resolvingNavigation || store.deletionRequest != nil
            || store.errorMessage != nil || store.serviceProfileDraft.pendingChange != nil
    }
    private var canvasExclusionRects: [CGRect] { chromeBounds.keys.sorted().compactMap { chromeBounds[$0] } }
    private var showsObjectInspector: Bool {
        guard let book = store.book, let id = store.selectedObjectID, !viewingGraph, !viewingSpatial else { return false }
        let kind = book.views.first { $0.id == store.route }?.kind ?? ComponentKind(rawValue: store.route)
        guard store.route == "reader" || kind == .cards || kind == .knowledge else { return false }
        let evidence = book.entities.first { $0.id == id }?.evidence
            ?? book.events.first { $0.id == id }?.evidence
            ?? book.activeDocuments.first { $0.id == id }?.evidence
        guard let evidence else { return false }
        if store.route == "reader" { return evidence.contains { $0.unitID == store.selectedUnitID } }
        return true
    }
    private func topIslands(width: CGFloat) -> some View {
        let limit: CGFloat = width < 900 ? 150 : 240
        let measured = (String(workspaceTitle.prefix(500)) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium)]).width.rounded(.up)
        return HStack(spacing: 10) {
            HStack(spacing: 2) {
                DockIconButton(title: navigationExpanded ? "收起导航" : "展开导航", icon: "sidebar.left", isSelected: navigationExpanded) {
                    withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { navigationExpanded.toggle(); bookPopover = false; servicePopover = false; readerPopover = nil }
                }
                if store.route == "reader", store.book != nil {
                    DockIconButton(title: "阅读导航：目录、缩略图与书签", icon: "book.pages", isSelected: readerPopover == .navigation || readerOutline || pdfController.thumbnailsVisible) {
                        if readerOutline || pdfController.thumbnailsVisible {
                            readerOutline = false; pdfController.command(.setThumbnails(false)); readerPopover = nil
                        } else { toggleReaderPopover(.navigation) }
                    }.popover(isPresented: readerPopoverBinding(.navigation), arrowEdge: .top) {
                        ReaderNavigationPanel(pdf: pdfController, showsPDF: $readerShowsPDF, viewingPDF: viewingPDF, openOutline: openReadingOutline, close: { readerPopover = nil }).environmentObject(store)
                    }
                }
                DockDivider()
                Button { bookPopover.toggle(); servicePopover = false; navigationExpanded = false; readerPopover = nil } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "book.closed").foregroundStyle(Palette.accent)
                        Text(workspaceTitle).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle).frame(width: min(limit, max(36, measured)), alignment: .leading)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 10).frame(height: 44).contentShape(Capsule())
                }.buttonStyle(.plain).help("图书与工作区").accessibilityLabel("图书与工作区菜单")
                    .popover(isPresented: $bookPopover) {
                        if servicePopover {
                            ServiceSwitcherPanel(back: { servicePopover = false }, manage: { navigate("models") }, dismissForConfirmation: { servicePopover = false; bookPopover = false }).environmentObject(store)
                        } else { bookMenu }
                    }
            }.padding(.horizontal, 4).readingGlass(radius: 24, interactive: true).fixedSize().workspaceChromeBounds("book")
            FrostWindowDragRegion().frame(minWidth: 12, maxWidth: .infinity).frame(height: 44).workspaceChromeBounds("window-drag")
            if showsObjectInspector {
                DockIconButton(title: "所选对象详情", icon: "info.circle") { compactInspector.toggle() }.readingGlass(radius: 22)
                    .workspaceChromeBounds("object-inspector").popover(isPresented: $compactInspector) {
                        if let id = store.selectedObjectID { ObjectInspector(id: id, onClose: { compactInspector = false }).environmentObject(store).frame(width: 370, height: 520) }
                    }
            }
            if store.book != nil && store.route != "library" {
                Button { navigate("workflow") } label: { Label(store.isSmartReadingRunning ? "查看分析" : "智能阅读", systemImage: "sparkles").font(.system(size: 14, weight: .medium)).padding(.horizontal, 6).frame(minHeight: 34) }
                    .buttonStyle(.borderedProminent).controlSize(.large).clipShape(Capsule()).fixedSize().workspaceChromeBounds("primary")
            } else {
                Button { store.chooseBook() } label: { Label("导入书籍", systemImage: "plus").frame(minHeight: 34) }.buttonStyle(.borderedProminent).controlSize(.large).clipShape(Capsule()).disabled(store.isBusy).fixedSize().workspaceChromeBounds("primary")
            }
        }.frame(maxWidth: .infinity).readingGlassGroup()
    }
    private var bookMenu: some View {
        VStack(spacing: 2) {
            if !store.books.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.books) { book in
                            DockMenuRow(title: book.title, icon: "book.closed", selected: store.bookID == book.id) {
                                bookPopover = false; Task { await store.selectBook(book.id) }
                            }.disabled(store.isBusy || store.editorDirty)
                        }
                    }
                }.frame(height: min(188, CGFloat(store.books.count) * 46))
                Divider().padding(.horizontal, 10).padding(.vertical, 4)
            }
            DockMenuRow(title: "书库", icon: "books.vertical") { bookPopover = false; navigate("library") }
            DockMenuRow(title: "导入图书", icon: "book.badge.plus") { bookPopover = false; store.chooseBook() }.disabled(store.isBusy)
            Divider().padding(.horizontal, 10).padding(.vertical, 4)
            DockMenuRow(title: "AI 服务", icon: "slider.horizontal.3", detail: store.serviceName.isEmpty ? "尚未配置" : store.serviceName) { servicePopover = true }
            if store.book != nil {
                DockMenuRow(title: "本书方案", icon: "slider.horizontal.2.square") { bookPopover = false; presentManagement("book.scheme") }.disabled(store.isBusy || store.editorDirty)
                DockMenuRow(title: "插件与组件", icon: "puzzlepiece.extension") { bookPopover = false; navigate("plugins") }
                DockMenuRow(title: "重置布局", icon: "arrow.counterclockwise") { bookPopover = false; store.resetWorkspaceLayout() }
            }
        }.padding(8).frame(width: 284)
    }
    private var workspaceTitle: String {
        switch store.route {
        case "library": return "书库"
        case "models": return "模型设置"
        case "plugins": return "插件与组件"
        case "trash": return "回收站"
        case "librarySearch": return "搜索本书与书库"
        default: return store.book?.title ?? "ReadingBook"
        }
    }
    private func navigate(_ route: String) {
        guard !store.isSavingDocument, !resolvingNavigation else { return }
        navigationExpanded = false; servicePopover = false; bookPopover = false; readerPopover = nil
        if store.serviceProfileDraft.isDirty(in: store) && managementRoute == "models" && route != "models" { pendingModelRoute = route; showsModelRouteConfirmation = true }
        else if store.editorDirty && store.route == "editor" && route != "editor" && !["models", "plugins", "book.scheme"].contains(route) { pendingRoute = route; showsRouteConfirmation = true }
        else { completeNavigation(to: route) }
    }
    private func completeNavigation(to route: String) {
        if ["models", "plugins", "book.scheme"].contains(route) { presentManagement(route) }
        else { closeManagement(); store.route = route }
    }
    private func presentManagement(_ route: String) {
        store.queryAllowsOrganizing = false
        navigationExpanded = false; servicePopover = false; bookPopover = false; readerPopover = nil
        store.showingSettings = route == "models"; store.showingPlugins = route == "plugins"
        withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { managementRoute = route }
    }
    private func closeManagement() {
        store.showingSettings = false; store.showingPlugins = false
        withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { managementRoute = nil }
    }
    private func repairLegacyManagementRoute() {
        guard ["models", "plugins", "book.scheme"].contains(store.route) else { return }
        let route = store.route; store.route = store.book == nil ? "library" : "reader"; presentManagement(route)
    }
    @ViewBuilder private func managementOverlay(_ route: String) -> some View {
        ZStack {
            Color.black.opacity(0.025).contentShape(Rectangle()).onTapGesture { }
            if route == "models" { ProviderSettingsView(embedded: true, onClose: closeManagement).environmentObject(store) }
            else if route == "plugins" { PluginLibraryView(embedded: true, onClose: closeManagement, draftStore: pluginDefinitionDrafts).environmentObject(store) }
            else { BookSchemeWorkspaceView(onClose: closeManagement).environmentObject(store) }
        }.accessibilityAddTraits(.isModal)
    }
    private func saveDocumentAndNavigate(to destination: String) {
        guard !resolvingNavigation else { return }
        pendingRoute = destination; resolvingNavigation = true; showsRouteConfirmation = false
        Task {
            await store.saveCurrentDocument()
            resolvingNavigation = false
            guard pendingRoute == destination else { return }
            if !store.editorDirty { pendingRoute = nil; completeNavigation(to: destination) }
            else { showsRouteConfirmation = true }
        }
    }
    private func resolveModelNavigation(to destination: String, save: Bool) {
        guard !resolvingNavigation else { return }
        pendingModelRoute = destination; resolvingNavigation = true; showsModelRouteConfirmation = false
        let succeeded: Bool
        if save { store.saveServiceProfileForUI(); succeeded = !store.serviceProfileDraft.isDirty(in: store) }
        else { succeeded = store.discardServiceDraftForNavigation() }
        if succeeded { pendingModelRoute = nil; completeNavigation(to: destination); resolvingNavigation = false }
        else {
            // Re-present on the next turn, after the native dialog has dismissed.
            // Keep its destination and every draft field available for retry.
            DispatchQueue.main.async {
                resolvingNavigation = false
                if pendingModelRoute == destination { showsModelRouteConfirmation = true }
            }
        }
    }
    private var readerFindAction: (() -> Void)? {
        guard viewingPDF, pdfController.isReady, !canvasInteractionBlocked else { return nil }
        return { pdfController.command(.showSearch) }
    }
    private func readerPopoverBinding(_ value: ReaderToolPopover) -> Binding<Bool> {
        Binding(get: { readerPopover == value }, set: { visible in
            if visible { readerPopover = value } else if readerPopover == value { readerPopover = nil }
        })
    }
    private func toggleReaderPopover(_ value: ReaderToolPopover) {
        navigationExpanded = false; bookPopover = false; servicePopover = false
        readerPopover = readerPopover == value ? nil : value
    }
    private func openReadingOutline(_ bookmarks: Bool) {
        readerBookmarks = bookmarks; readerOutline = true; readerPopover = nil
        pdfController.command(.setThumbnails(false))
    }
    private var readerControls: some View {
        HStack(spacing: 4) {
            if viewingPDF { PDFPageNavigation(onEditingChange: { editingPDFPage = $0 }).environmentObject(pdfController) }
            else {
                DockIconButton(title: "上一原文单元", icon: "chevron.left") { moveSource(-1) }.disabled(store.selectedUnit?.order == 0)
                Text(store.selectedUnit?.page.map { "第 \($0) 页" } ?? "原文").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 110)
                DockIconButton(title: "下一原文单元", icon: "chevron.right") { moveSource(1) }.disabled(store.selectedUnit?.order == (store.book?.units.count ?? 0) - 1)
            }
            DockDivider()
            DockIconButton(title: "伴读与对话", icon: "sparkles", isSelected: store.readingCompanionVisible) { store.readingCompanionVisible.toggle() }
            if viewingPDF {
                DockIconButton(title: "高亮与批注", icon: "highlighter", isSelected: readerPopover == .annotations) { toggleReaderPopover(.annotations) }
                    .disabled(!pdfController.isReady || store.isBusy)
                    .popover(isPresented: readerPopoverBinding(.annotations), arrowEdge: .bottom) { annotationTools }
                Button { toggleReaderPopover(.zoom) } label: {
                    HStack(spacing: 5) {
                        Text("\(pdfController.zoomPercent)%").font(.system(size: 13, weight: .medium).monospacedDigit())
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }.buttonStyle(ReadingToolbarButtonStyle(selected: readerPopover == .zoom)).help("缩放与适合页面").accessibilityLabel("缩放 \(pdfController.zoomPercent)%")
                    .popover(isPresented: readerPopoverBinding(.zoom), arrowEdge: .bottom) { ReaderZoomPanel(pdf: pdfController) }
            }
            DockDivider()
            DockIconButton(title: "更多阅读操作", icon: "ellipsis", isSelected: readerPopover == .more) { toggleReaderPopover(.more) }
                .popover(isPresented: readerPopoverBinding(.more), arrowEdge: .bottom) { readerMoreTools }
        }.font(.system(size: 14)).fixedSize()
    }
    private var annotationTools: some View {
        VStack(spacing: 2) {
            DockMenuRow(title: "高亮选中文字", icon: "highlighter") { readerPopover = nil; pdfController.command(.createHighlight) }.disabled(!pdfController.hasSelection)
            DockMenuRow(title: "框选页面区域", icon: "viewfinder") { readerPopover = nil; pdfController.command(.createRegion) }
            DockMenuRow(title: "批注与恢复", icon: "list.bullet.rectangle") { readerPopover = nil; pdfController.command(.showAnnotations) }
        }.padding(8).frame(width: 262).background(Palette.surface)
    }
    private var readerMoreTools: some View {
        VStack(spacing: 2) {
            if let unit = store.selectedUnit {
                let bookmarked = store.book?.bookmarks.contains(unit.id) == true
                DockMenuRow(title: bookmarked ? "移除书签" : "添加书签", icon: bookmarked ? "bookmark.slash" : "bookmark", selected: bookmarked) { readerPopover = nil; Task { await store.toggleBookmark(unit.id) } }.disabled(store.isBusy)
                DockMenuRow(title: "记一篇笔记", icon: "square.and.pencil") { readerPopover = nil; store.newNote(for: unit) }.disabled(store.isRecognizingPDF)
            }
            if store.sourceReadingSelection != nil || store.selectedSourceAnchor != nil {
                Divider().padding(.horizontal, 10)
                DockMenuRow(title: "问所选内容", icon: "bubble.left") { readerPopover = nil; store.askAboutReadingContext() }
                DockMenuRow(title: "把选段写成笔记", icon: "text.badge.plus") { readerPopover = nil; store.noteSelectedSource() }.disabled(store.isBusy)
            }
            if store.sourceFileURL?.pathExtension.lowercased() == "pdf" {
                DockMenuRow(title: "识别页面…", icon: "viewfinder") { readerPopover = nil; store.showingOCR = true }.disabled(store.isBusy)
            }
            Divider().padding(.horizontal, 10)
            DockMenuRow(title: "模型设置", icon: "slider.horizontal.3") { navigate("models") }
        }.padding(8).frame(width: 272).background(Palette.surface)
    }
    private func moveSource(_ offset: Int) {
        guard let units = store.book?.units, let id = store.selectedUnitID, let index = units.firstIndex(where: { $0.id == id }), units.indices.contains(index + offset) else { return }
        store.navigateToUnit(units[index + offset].id)
    }
    private var modalSignature: String {
        "\(store.showingSettings)|\(store.showingOCR)|\(store.showingTrash)|\(store.showingPlugins)|\(store.showingLibrarySearch)|\(store.pdfPasswordRequest?.id.uuidString ?? "")|\(store.pdfPasswordRequest?.message ?? "")"
    }
    private var sheetBinding: Binding<WorkspaceSheet?> {
        Binding(get: { activeSheet }, set: { value in
            if value == nil {
                sheetClosing = true
                if let activeSheet { clearSheetRequest(activeSheet) }
            }
            activeSheet = value
        })
    }
    private func closeSheet(_ sheet: WorkspaceSheet) {
        guard activeSheet?.id == sheet.id else { return }
        sheetClosing = true
        clearSheetRequest(sheet)
        activeSheet = nil
    }
    private func clearSheetRequest(_ sheet: WorkspaceSheet) {
        switch sheet {
        case .settings: store.showingSettings = false
        case .ocr: store.showingOCR = false
        case .trash: store.showingTrash = false
        case .plugins: store.showingPlugins = false
        case .librarySearch: store.showingLibrarySearch = false
        case .password(let request):
            if store.pdfPasswordRequest?.id == request.id { store.cancelPDFPasswordRequest(request.id) }
        }
    }
    private func reconcileSheet() {
        guard !sheetClosing else { return }
        if ["models", "plugins"].contains(managementRoute ?? "") && !store.showingSettings && !store.showingPlugins { managementRoute = nil }
        if let activeSheet {
            let supersededByPassword: Bool
            if case .password = activeSheet { supersededByPassword = false }
            else { supersededByPassword = store.pdfPasswordRequest != nil }
            if !activeSheet.isRequested(in: store) || supersededByPassword {
                sheetClosing = true; self.activeSheet = nil
            } else if case .password = activeSheet, let request = store.pdfPasswordRequest {
                self.activeSheet = .password(request)
            }
            return
        }
        let next: WorkspaceSheet?
        if let request = store.pdfPasswordRequest { next = .password(request) }
        else if store.showingSettings { managementRoute = "models"; return }
        else if store.showingOCR { next = .ocr }
        else if store.showingTrash { next = .trash }
        else if store.showingPlugins { managementRoute = "plugins"; return }
        else if store.showingLibrarySearch { next = .librarySearch }
        else { next = nil }
        lastSheet = next; activeSheet = next
    }
    private func finishSheetDismissal() {
        if let lastSheet {
            switch lastSheet {
            case .settings: store.showingSettings = false
            case .ocr: store.showingOCR = false
            case .trash: store.showingTrash = false
            case .plugins: store.showingPlugins = false
            case .librarySearch: store.showingLibrarySearch = false
            case .password(let request):
                if store.pdfPasswordRequest?.id == request.id { store.cancelPDFPasswordRequest(request.id) }
            }
        }
        lastSheet = nil; activeSheet = nil; sheetClosing = false
        // onDismiss runs after the old sheet has actually left its window.
        // Requests accumulated during dismissal are presented on the next turn.
        DispatchQueue.main.async { reconcileSheet() }
    }
    @ViewBuilder private var content: some View {
        if store.route == "library" { FrostLibraryView() }
        else if store.route == "trash" { LibraryTrashView(onClose: { navigate("library") }).padding(.top, 88) }
        else if store.route == "librarySearch" { LibrarySearchView(embedded: true, onClose: { navigate("library") }).padding(.top, 88) }
        else if store.book == nil { WelcomeView().padding(.top, 88) }
        else if store.route == "reader" { ReaderWorkspaceView(showPDF: $readerShowsPDF, showOutline: $readerOutline, bookmarksOnly: $readerBookmarks).id(store.bookID) }
        else if let component = WorkspaceComponentRegistry.shared.render(id: store.route) { component }
        else {
            let kind = store.book?.views.first { $0.id == store.route }?.kind ?? ComponentKind(rawValue: store.route) ?? .workflow
            if let component = WorkspaceComponentRegistry.shared.render(store.book?.views.first { $0.id == store.route }, kind: kind) { component }
            else { EmptyState(title: "组件暂不可用", detail: "原书、已保存对象和笔记仍保留，请从侧栏选择可用组件。", icon: "puzzlepiece.extension") }
        }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            if store.isBusy { ProgressView().controlSize(.mini) } else { Circle().fill(Palette.accent.opacity(0.55)).frame(width: 5, height: 5) }
            Text(store.activity).lineLimit(1).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if store.requestsUsed > 0 { Text("本轮 \(store.requestsUsed) 次请求").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
            Text("本地书库").font(.caption2).foregroundStyle(.tertiary)
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// Pointer feedback belongs to its row, not the full reading workspace.
private struct WorkspaceNavigationRowHover: ViewModifier {
    let reduceMotion: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(hovered ? Palette.accent.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .onHover { if hovered != $0 { hovered = $0 } }
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: hovered)
    }
}

/// Layout-only measurements. They are collected after compact chrome has been
/// sized, so invisible maximum-width frames never block the canvas underneath.
struct WorkspaceChromeBoundsPreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
private struct WorkspaceProgressSizePreference: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 && next.height > 0 { value = next }
    }
}
extension View {
    func workspaceChromeBounds(_ id: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: WorkspaceChromeBoundsPreference.self, value: [id: geometry.frame(in: .global)])
            }.allowsHitTesting(false)
        }
    }
}

private enum WorkspaceSheet: Identifiable {
    case settings, ocr, trash, plugins, librarySearch, password(PDFPasswordRequest)
    var id: String {
        switch self {
        case .settings: return "settings"
        case .ocr: return "ocr"
        case .trash: return "trash"
        case .plugins: return "plugins"
        case .librarySearch: return "librarySearch"
        case .password(let request): return "password-\(request.id)"
        }
    }
    @MainActor func isRequested(in store: AppStore) -> Bool {
        switch self {
        case .settings: return store.showingSettings
        case .ocr: return store.showingOCR
        case .trash: return store.showingTrash
        case .plugins: return store.showingPlugins
        case .librarySearch: return store.showingLibrarySearch
        case .password(let request): return store.pdfPasswordRequest?.id == request.id
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        ScrollView {
        VStack(spacing: 20) {
            BrandGlyph(name: "mark").frame(width: 52, height: 52).foregroundStyle(Palette.accent)
            VStack(spacing: 12) {
                Text("读一本书，\n留下自己的理解。").font(.system(size: 28, weight: .regular, design: .serif)).multilineTextAlignment(.center).lineSpacing(6)
                Text("原文、人物与概念、时间与空间，以及你写下的理解。\n让自己的 AI 把它们连接起来。").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(6)
            }
            Button { store.chooseBook() } label: { Label("导入一本书", systemImage: "plus").padding(.horizontal, 18).padding(.vertical, 5) }.buttonStyle(.borderedProminent).controlSize(.large)
            Text("PDF · EPUB · Markdown · TXT   /   也可以拖入窗口").font(.caption).foregroundStyle(.tertiary)
            HStack(spacing: 30) {
                feature("逐段阅读", "book", "看见进度与原文依据")
                feature("随书生长", "puzzlepiece.extension", "AI 选择组件和内容类型")
                feature("写下理解", "square.and.pencil", "Markdown 留在自己手中")
            }.padding(.top, 12)
            Button("连接自己的 AI") { store.showingSettings = true }.buttonStyle(.plain).foregroundStyle(Palette.accent).padding(.top, 8)
        }.frame(maxWidth: .infinity).padding(30)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func feature(_ title: String, _ icon: String, _ detail: String) -> some View {
        VStack(spacing: 8) { Image(systemName: icon).foregroundStyle(Palette.accent); Text(title).font(.subheadline.weight(.medium)); Text(detail).font(.caption).foregroundStyle(.secondary) }
    }
}

struct EmptyState: View {
    var title: String
    var detail: String
    var icon: String = "sparkles"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(Palette.accent.opacity(0.7))
            Text(title).font(.title3.weight(.medium)); Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440).lineSpacing(5)
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.borderedProminent).padding(.top, 8) }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EvidenceList: View {
    var evidence: [Evidence]
    var showsHeading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeading && !evidence.isEmpty { Text("原文依据").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            ForEach(Array(evidence.enumerated()), id: \.offset) { _, reference in
                EvidenceReferenceRow(reference: reference).id(reference.unitID + "\n" + reference.quote)
            }
        }
    }
}

/// Inspect a quote in place; leaving for the source is a separate action.
private struct EvidenceReferenceRow: View {
    @EnvironmentObject var store: AppStore
    let reference: Evidence
    @State private var expanded = false
    private var unit: SourceUnit? { store.book?.units.first { $0.id == reference.unitID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(unit?.locator ?? reference.unitID).font(.caption.weight(.medium))
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                    }.foregroundStyle(Palette.accent)
                    if !expanded { Text(reference.quote).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading) }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(expanded ? "收起原文依据" : "展开原文依据")
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    if let unit, !unit.chapter.isEmpty { Text(unit.chapter).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text(reference.quote).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button { store.follow(reference) } label: { Label("回到原文", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(ReadingToolbarButtonStyle()).disabled(unit == nil)
                    if unit == nil { Text("来源片段已不存在，引句仍保留。").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 12)
            }
        }.background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct EvidenceDisclosure: View {
    var evidence: [Evidence]
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) {
                    Label("原文依据 · \(evidence.count) 处", systemImage: "text.quote")
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }.font(.system(size: 14)).foregroundStyle(Palette.accent).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded { EvidenceList(evidence: evidence, showsHeading: false).padding(.top, 8) }
        }
    }
}
