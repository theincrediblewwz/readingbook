import SwiftUI
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
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @StateObject private var pdfController = PDFReaderController()
    @State private var readerShowsPDF = true
    @State private var readerOutline = false
    @State private var activeSheet: WorkspaceSheet?
    @State private var lastSheet: WorkspaceSheet?
    @State private var sheetClosing = false
    @State private var hoveredRoute: String?
    @State private var navigationExpanded = false
    @State private var pendingRoute: String?
    @State private var pendingModelRoute: String?
    @State private var showsRouteConfirmation = false
    @State private var showsModelRouteConfirmation = false
    @State private var resolvingNavigation = false
    @State private var chromeBounds: [String: CGRect] = [:]
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Palette.canvas.ignoresSafeArea()
                content
                    .environment(\.workspaceCanvasBlocked, canvasInteractionBlocked)
                    .environment(\.workspaceCanvasExclusionRects, canvasExclusionRects)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        if store.route == "reader", store.selectedUnit != nil {
                            readerControls.padding(.horizontal, 18).padding(.bottom, 22)
                        }
                    }
                    .clipped()
                if store.isBusy && !viewingWorkflow && !viewingGraph && !viewingSpatial && store.route != "reader" {
                    footer.frame(maxWidth: 310).readingGlass(radius: 16)
                        .padding(.trailing, 24).padding(.bottom, 86).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                topIslands(width: geometry.size.width).padding(.top, 14).padding(.leading, 104).padding(.trailing, 24)
                if navigationExpanded {
                    sidebar.frame(width: min(286, geometry.size.width - 96), height: max(100, min(690, geometry.size.height - 126)))
                        .readingGlass(radius: 24).padding(.leading, 16).padding(.top, 88)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading))).zIndex(10)
                }
                FloatingNavigationButton(viewport: geometry.size, isExpanded: navigationExpanded) {
                    withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { navigationExpanded.toggle(); servicePopover = false }
                }.opacity(navigationExpanded ? 0 : 1).allowsHitTesting(!navigationExpanded).accessibilityHidden(navigationExpanded).zIndex(11)
            }
            .onPreferenceChange(WorkspaceChromeBoundsPreference.self) { chromeBounds = $0 }
            .onAppear { detailWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, width in
                detailWidth = width
                if width < 920 { showsInspector = false }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .environmentObject(pdfController)
        .serviceProfileChangeConfirmation(store: store)
        .tint(Palette.accent)
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
        .sheet(item: sheetBinding, onDismiss: finishSheetDismissal) { sheet in
            switch sheet {
            case .settings: ProviderSettingsView(onClose: { closeSheet(.settings) }).environmentObject(store).frame(width: 860, height: 660)
            case .ocr: PDFOCRPanel().environmentObject(store).frame(width: 560, height: 460)
            case .trash: LibraryTrashView().environmentObject(store).frame(width: 600, height: 500)
            case .plugins: PluginLibraryView(onClose: { closeSheet(.plugins) }).environmentObject(store).frame(width: 900, height: 680)
            case .librarySearch: LibrarySearchView().environmentObject(store).frame(minWidth: 620, idealWidth: 800, minHeight: 500, idealHeight: 640)
            case .password(let request): PDFPasswordSheet(request: request).environmentObject(store)
            }
        }
        .onChange(of: modalSignature) { _, _ in reconcileSheet() }
        .onAppear { reconcileSheet(); restoreReaderMemory() }
        .onChange(of: store.workspaceMemoryRevision) { _, _ in restoreReaderMemory() }
        .onChange(of: readerShowsPDF) { _, value in store.updateWorkspaceMemory { $0.readerShowsPDF = value } }
        .onChange(of: readerOutline) { _, value in store.updateWorkspaceMemory { $0.readerOutline = value } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in captureAndFlushWorkspace() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in captureAndFlushWorkspace() }
        .onChange(of: store.requestedWorkspaceRoute) { _, route in
            guard let route else { return }; store.requestedWorkspaceRoute = nil; navigate(route)
        }
        .confirmationDialog("删除保存的内容？", isPresented: Binding(get: { store.deletionRequest != nil }, set: { if !$0 { store.deletionRequest = nil } }), presenting: store.deletionRequest) { request in
            Button(request.kind == .book || request.kind == .document ? "移入回收站" : "删除对象", role: .destructive) { store.confirmDeletion(request) }
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
        .onChange(of: store.bookID) { _, _ in showsInspector = false; compactInspector = false }
        .onChange(of: store.route) { _, _ in if viewingGraph || viewingSpatial { showsInspector = false; compactInspector = false } }
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
                        routeButton("读书方法", icon: "point.3.connected.trianglepath.dotted", route: "workflow")
                        routeButton("与书对话", icon: "bubble.left.and.bubble.right", route: "query")
                        routeButton("我的笔记", icon: "square.and.pencil", route: "editor")
                        if !componentViews.isEmpty {
                            Text("本书组件").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 5)
                            ForEach(componentViews) { view in
                                routeButton(view.title, icon: WorkspaceComponentRegistry.shared.component(for: view)?.icon ?? "puzzlepiece.extension", route: view.id)
                                    .contextMenu {
                                        let count = WorkspaceComponentRegistry.shared.removalIDs(for: view, in: store.book?.views ?? []).count
                                        Button(count > 1 ? "移除此组件及 \(count - 1) 个旧重复入口" : "移除此组件入口") { Task { await store.removeView(view.id) } }
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
                    routeButton("搜索本书与书库", icon: "magnifyingglass", route: "librarySearch")
                    routeButton("回收站", icon: "trash", route: "trash")
                    Menu {
                        Button("导入书籍…") { store.chooseBook() }
                        Button("导入书项目…") { store.importProject() }
                        Button("导出完整书项目…") { store.exportProject() }.disabled(store.book == nil)
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
            !component.permanent && store.savedComponent(for: component) == nil
        }
    }
    private func routeButton(_ title: String, icon: String, route: String) -> some View {
        Button { navigate(route) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium)).frame(width: 20, height: 20)
                Text(title).font(.system(size: 14, weight: store.route == route ? .semibold : .regular))
                Spacer(minLength: 0)
            }.padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: ReadingLayout.navigationRowHeight, alignment: .leading)
                .background(hoveredRoute == route ? Palette.accent.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .background {
                    if store.route == route {
                        RoundedRectangle(cornerRadius: 12).fill(Palette.accent.opacity(0.12))
                            .matchedGeometryEffect(id: "workspace-selection", in: navigationSelection)
                    }
                }
                .contentShape(Rectangle())
                .overlay(alignment: .leading) { if store.route == route { Capsule().fill(Palette.accent).frame(width: 2, height: 15).padding(.leading, 3) } }
        }.buttonStyle(.plain).foregroundStyle(store.route == route ? Palette.accent : .primary)
            .onHover { hoveredRoute = $0 ? route : nil }
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: store.route)
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: hoveredRoute)
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
        navigationExpanded || servicePopover || compactInspector || activeSheet != nil || sheetClosing
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
        let compact = width < 1050
        let hasPrimaryAction = store.route == "editor" || store.route == "reader" || store.route == "workflow" || store.route == "library" || store.book == nil
        let titleLimit: CGFloat = compact ? (hasPrimaryAction ? (showsObjectInspector ? 140 : 188) : 240) : 360
        let serviceLimit: CGFloat = compact ? 108 : 170
        return HStack(spacing: 10) {
            Menu {
                ForEach(store.books) { book in
                    Button { navigationExpanded = false; Task { await store.selectBook(book.id) } } label: {
                        Label(book.title, systemImage: store.bookID == book.id ? "checkmark.circle.fill" : "book.closed")
                    }.disabled(store.isBusy)
                }
                Divider()
                if store.book != nil {
                    Button("书本方案…") { store.openBookScheme() }.disabled(store.isBusy || store.editorDirty)
                    Button("恢复本书默认布局") { store.resetWorkspaceLayout() }
                    Divider()
                }
                Button("打开书库") { navigate("library") }
                Button("导入一本书…") { store.chooseBook() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "book.closed.fill").foregroundStyle(Palette.accent)
                    Text(workspaceTitle).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle).frame(maxWidth: titleLimit)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).frame(minHeight: 46).foregroundStyle(Palette.ink).contentShape(Capsule())
            }.menuStyle(.borderlessButton).buttonStyle(.plain).menuIndicator(.hidden)
                .fixedSize(horizontal: true, vertical: true).frame(minHeight: 46).readingGlass(radius: 24, interactive: true)
                .help(workspaceTitle).workspaceChromeBounds("book")
            FrostWindowDragRegion().frame(minWidth: 12, maxWidth: .infinity).frame(height: 46).workspaceChromeBounds("window-drag")
            if showsObjectInspector {
                Button { compactInspector.toggle() } label: { Image(systemName: "info.circle") }.buttonStyle(ReadingToolbarButtonStyle()).readingGlass(radius: 22)
                    .workspaceChromeBounds("object-inspector")
                    .help("所选对象详情").popover(isPresented: $compactInspector) {
                        if let id = store.selectedObjectID { ObjectInspector(id: id, onClose: { compactInspector = false }).environmentObject(store).frame(width: 370, height: 520) }
                    }
            }
            Button { servicePopover.toggle() } label: {
                HStack(spacing: 8) { Circle().fill(Palette.accent).frame(width: 7, height: 7); Text(store.serviceName.isEmpty ? "选择 AI" : store.serviceName).lineLimit(1).truncationMode(.middle).frame(maxWidth: serviceLimit); Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                    .font(.system(size: 14)).padding(.horizontal, 16).frame(minHeight: 46)
            }.buttonStyle(.plain).fixedSize(horizontal: true, vertical: true).readingGlass(radius: 24, interactive: true)
                .help(store.serviceName.isEmpty ? "选择 AI 服务" : "AI 服务：\(store.serviceName)").workspaceChromeBounds("service")
                .popover(isPresented: $servicePopover) { servicePicker }
            if store.route == "editor" {
                Button { Task { await store.saveCurrentDocument() } } label: { Label(store.isSavingDocument ? "保存中…" : "保存", systemImage: "square.and.arrow.down").padding(.horizontal, 8).frame(minHeight: 34) }
                    .buttonStyle(.borderedProminent).controlSize(.large).clipShape(Capsule()).disabled(!store.editorDirty || store.isBusy).fixedSize().workspaceChromeBounds("primary")
            } else if store.route == "reader", store.book != nil {
                Button { navigate("workflow") } label: { Label(store.isBusy ? "查看精读" : (store.book?.plan == nil ? "预读与精读" : "继续精读"), systemImage: "sparkles").padding(.horizontal, 5).frame(minHeight: 34) }.buttonStyle(.borderedProminent).controlSize(.large).clipShape(Capsule()).fixedSize().workspaceChromeBounds("primary")
            } else if store.route == "workflow", store.book != nil {
                Button { NotificationCenter.default.post(name: Notification.Name("ReadingBookAdjustReaderMethod"), object: nil) } label: {
                    Label("调整读法", systemImage: "slider.horizontal.3").padding(.horizontal, 5).frame(minHeight: 34)
                }.buttonStyle(.borderedProminent).controlSize(.large).clipShape(Capsule()).fixedSize().workspaceChromeBounds("primary")
            } else if store.route == "library" || store.book == nil {
                Button { store.chooseBook() } label: { Label("导入书籍", systemImage: "plus").frame(minHeight: 34) }.buttonStyle(.borderedProminent).controlSize(.large).clipShape(Capsule()).disabled(store.isBusy).fixedSize().workspaceChromeBounds("primary")
            }
        }.frame(maxWidth: .infinity).readingGlassGroup()
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
        navigationExpanded = false; servicePopover = false
        if store.serviceProfileDraft.isDirty(in: store) && store.route == "models" && route != "models" { pendingModelRoute = route; showsModelRouteConfirmation = true }
        else if store.editorDirty && store.route == "editor" && route != "editor" { pendingRoute = route; showsRouteConfirmation = true }
        else { store.route = route }
    }
    private func saveDocumentAndNavigate(to destination: String) {
        guard !resolvingNavigation else { return }
        pendingRoute = destination; resolvingNavigation = true; showsRouteConfirmation = false
        Task {
            await store.saveCurrentDocument()
            resolvingNavigation = false
            guard pendingRoute == destination else { return }
            if !store.editorDirty { pendingRoute = nil; store.route = destination }
            else { showsRouteConfirmation = true }
        }
    }
    private func resolveModelNavigation(to destination: String, save: Bool) {
        guard !resolvingNavigation else { return }
        pendingModelRoute = destination; resolvingNavigation = true; showsModelRouteConfirmation = false
        let succeeded: Bool
        if save { store.saveServiceProfileForUI(); succeeded = !store.serviceProfileDraft.isDirty(in: store) }
        else { succeeded = store.discardServiceDraftForNavigation() }
        if succeeded { pendingModelRoute = nil; store.route = destination; resolvingNavigation = false }
        else {
            // Re-present on the next turn, after the native dialog has dismissed.
            // Keep its destination and every draft field available for retry.
            DispatchQueue.main.async {
                resolvingNavigation = false
                if pendingModelRoute == destination { showsModelRouteConfirmation = true }
            }
        }
    }
    private var compactReaderControls: Bool { detailWidth < 950 }
    private var readerControls: some View {
        HStack(spacing: ReadingLayout.groupSpacing) {
            Button { withAnimation(ReadingMotion.animation(reduce: reduceMotion)) { readerOutline.toggle() } } label: { Image(systemName: "list.bullet") }
                .buttonStyle(ReadingToolbarButtonStyle(selected: readerOutline)).help("展开或收起原文目录").accessibilityLabel("原文目录")
            if viewingPDF { PDFPageNavigation().environmentObject(pdfController) }
            else {
                Button { moveSource(-1) } label: { Image(systemName: "chevron.left") }.help("上一原文单元").disabled(store.selectedUnit?.order == 0)
                Text(store.selectedUnit?.locator ?? "原文").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 155)
                Button { moveSource(1) } label: { Image(systemName: "chevron.right") }.help("下一原文单元").disabled(store.selectedUnit?.order == (store.book?.units.count ?? 0) - 1)
            }
            Divider().frame(height: 22).padding(.horizontal, 2)
            Menu {
                Button(store.readingCompanionVisible ? "收起伴读" : "展开伴读") { store.readingCompanionVisible.toggle() }
                Button("解释与译文") { store.readingCompanionSection = "layers"; store.readingCompanionVisible = true }
                Button("原文中的对象") { store.readingCompanionSection = "mentions"; store.readingCompanionVisible = true }
                Menu("原文与译注对照") {
                    Button("原书阅读") { store.readingSourceMode = "original" }
                    Button("逐段对照") { store.readingSourceMode = "stacked" }
                    Button("左右并排，随段滚动") { store.readingSourceMode = "parallel" }
                    Button("只读译注，缺失处保留原文") { store.readingSourceMode = "layers" }
                }
                Divider()
                Button("增强当前片段") { store.enhanceCurrentSource() }.disabled(store.isBusy)
                Button("把选段写成笔记") { store.noteSelectedSource() }.disabled(store.sourceReadingSelection == nil || store.isBusy)
                Button("问 AI 当前选段与对象") { store.askAboutReadingContext() }
            } label: { Image(systemName: "text.book.closed").frame(width: 40, height: 40) }.help("伴读、解释与当前选段")
            if store.route == "reader", let unit = store.selectedUnit {
                if viewingPDF, !compactReaderControls {
                    Menu {
                        Button("高亮选中文字…") { pdfController.command(.createHighlight) }.disabled(!pdfController.hasSelection)
                        Button("框选页面区域…") { pdfController.command(.createRegion) }
                        Divider()
                        Button("批注列表与恢复…") { pdfController.command(.showAnnotations) }
                    } label: { Label("批注", systemImage: "highlighter").frame(minHeight: ReadingLayout.controlHeight) }.help("高亮、区域批注与批注列表").accessibilityLabel("批注选项").disabled(!pdfController.isReady || store.isBusy)
                }
                Menu {
                    if viewingPDF, compactReaderControls {
                        Button("高亮选中文字…") { pdfController.command(.createHighlight) }.disabled(!pdfController.hasSelection || store.isBusy)
                        Button("框选页面区域…") { pdfController.command(.createRegion) }.disabled(store.isBusy)
                        Button("批注列表与恢复…") { pdfController.command(.showAnnotations) }
                        Divider()
                    }
                    if store.sourceFileURL?.pathExtension.lowercased() == "pdf" {
                        Button("原始 PDF") { store.readingSourceMode = "original"; readerShowsPDF = true }
                        Button("文本 / OCR 识别稿") { store.readingSourceMode = "original"; readerShowsPDF = false }
                        Button("用视觉模型识别页面…") { store.showingOCR = true }.disabled(store.isBusy)
                        if viewingPDF {
                            Divider()
                            Button("适合宽度") { pdfController.command(.fitWidth) }
                            Button("适合整页") { pdfController.command(.fitPage) }
                            Button("实际大小") { pdfController.command(.actualSize) }
                            Button("放大") { pdfController.command(.zoomIn) }
                            Button("缩小") { pdfController.command(.zoomOut) }
                            Button("显示 / 收起缩略图") { pdfController.command(.toggleThumbnails) }
                            Button("连续 / 单页") { pdfController.command(.toggleContinuous) }
                        }
                    }
                    Button(store.book?.bookmarks.contains(unit.id) == true ? "移除书签" : "添加书签") { Task { await store.toggleBookmark(unit.id) } }.disabled(store.isBusy)
                    Button("对这一段记一笔") { store.newNote(for: unit) }.disabled(store.isRecognizingPDF)
                    if let message = unit.warning { Text(String(message.prefix(70))) }
                } label: {
                    HStack(spacing: 6) { Image(systemName: "textformat.size"); if viewingPDF { Text("\(pdfController.zoomPercent)%").font(.system(size: 13).monospacedDigit()) } }.frame(minWidth: 40, minHeight: ReadingLayout.controlHeight)
                }.help("阅读模式、缩放、目录与书签").accessibilityLabel("阅读模式与缩放")
                if viewingPDF {
                    Button { pdfController.command(.showSearch) } label: { Image(systemName: "magnifyingglass") }
                        .keyboardShortcut("f", modifiers: [.command])
                        .help("查找 PDF 文字（⌘F）").accessibilityLabel("查找 PDF 文字").buttonStyle(ReadingToolbarButtonStyle(selected: pdfController.isSearchVisible)).disabled(!pdfController.isReady)
                }
            }

        }.buttonStyle(ReadingToolbarButtonStyle()).menuStyle(.borderlessButton).controlSize(.regular)
            .padding(8).readingGlass(radius: 22, interactive: true)
            .fixedSize(horizontal: true, vertical: true)
            .accessibilityElement(children: .contain).accessibilityLabel("阅读工具")
    }
    private var servicePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("自己的 AI", systemImage: "sparkles").font(.headline)
            Text("已保存的服务").font(.system(size: 13, weight: .medium))
            Picker("已保存的服务", selection: Binding(get: { store.selectedServiceID ?? "" }, set: { store.selectService($0); if store.serviceProfileDraft.pendingChange != nil { servicePopover = false } })) {
                if store.selectedServiceID == nil { Text("未保存配置").tag("") }
                ForEach(store.savedServices) { service in Text(service.name).tag(service.id) }
            }.labelsHidden().accessibilityLabel("已保存的服务").lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity).disabled(store.isBusy)
            Text(store.settings.model.isEmpty ? "尚未配置模型" : store.settings.model).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            HStack { Button("管理 / 新建") { servicePopover = false; navigate("models") }; Spacer(); Button("测试") { store.testConnection() }.disabled(store.isBusy || store.settings.model.isEmpty) }
            if !store.connectionStatus.isEmpty { Text(store.connectionStatus).font(.caption).foregroundStyle(.secondary) }
            ServiceProfileLocalError(draft: store.serviceProfileDraft)
        }.padding(20).frame(width: 310)
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
        else if store.showingSettings { next = .settings }
        else if store.showingOCR { next = .ocr }
        else if store.showingTrash { next = .trash }
        else if store.showingPlugins { next = .plugins }
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
        else if store.route == "models" { ProviderSettingsView(embedded: true, onClose: { navigate(store.book == nil ? "library" : "reader") }) }
        else if store.route == "plugins" { PluginLibraryView(embedded: true, onClose: { navigate(store.book == nil ? "library" : "reader") }) }
        else if store.route == "trash" { LibraryTrashView(onClose: { navigate("library") }).padding(.top, 88) }
        else if store.route == "librarySearch" { LibrarySearchView(embedded: true, onClose: { navigate("library") }).padding(.top, 88) }
        else if store.book == nil { WelcomeView().padding(.top, 88) }
        else if store.route == "reader" { ReaderWorkspaceView(showPDF: $readerShowsPDF, showOutline: $readerOutline).id(store.bookID) }
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

/// Layout-only measurements. They are collected after compact chrome has been
/// sized, so invisible maximum-width frames never block the canvas underneath.
struct WorkspaceChromeBoundsPreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
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
