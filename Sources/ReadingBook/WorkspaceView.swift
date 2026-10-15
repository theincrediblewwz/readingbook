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
    @AppStorage("reader-outline-v3") private var readerOutline = false
    @State private var activeSheet: WorkspaceSheet?
    @State private var lastSheet: WorkspaceSheet?
    @State private var sheetClosing = false
    @State private var hoveredRoute: String?
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 244, max: 280)
        } detail: {
            GeometryReader { geometry in
            VStack(spacing: 0) {
                if store.book != nil {
                    HSplitView {
                        content.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .top) {
                                if store.route == "reader", store.selectedUnit != nil { readerControls.padding(.horizontal, 12).padding(.top, 10).padding(.leading, readerOutline && geometry.size.width >= 760 ? 224 : 0) }
                            }
                        if store.route != "reader", !viewingGraph, !viewingSpatial, showsInspector, geometry.size.width >= 920, let id = store.selectedObjectID {
                            ObjectInspector(id: id, onClose: { showsInspector = false }).frame(minWidth: 250, idealWidth: 280, maxWidth: 340)
                        }
                    }
                } else { WelcomeView() }
                if store.isBusy && !viewingWorkflow && !viewingGraph && !viewingSpatial { footer }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear { detailWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, width in
                detailWidth = width
                if width < 920, showsInspector, !viewingGraph, !viewingSpatial { showsInspector = false; compactInspector = true }
            }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { workspaceToolbar }
        .environmentObject(pdfController)
        .serviceProfileChangeConfirmation(store: store)
        .tint(Palette.accent)
        .onOpenURL { url in Task { await store.openInternalURL(url) } }
        .sheet(item: sheetBinding, onDismiss: finishSheetDismissal) { sheet in
            switch sheet {
            case .settings: ProviderSettingsView().environmentObject(store).frame(width: 600, height: 560)
            case .ocr: PDFOCRPanel().environmentObject(store).frame(width: 560, height: 460)
            case .trash: LibraryTrashView().environmentObject(store).frame(width: 600, height: 500)
            case .plugins: PluginLibraryView().environmentObject(store).frame(width: 620, height: 520)
            case .password(let request): PDFPasswordSheet(request: request).environmentObject(store)
            }
        }
        .onChange(of: modalSignature) { _, _ in reconcileSheet() }
        .onAppear { reconcileSheet() }
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
        .onChange(of: store.bookID) { _, _ in readerShowsPDF = true; showsInspector = false; compactInspector = false }
        .onChange(of: store.route) { _, _ in if viewingGraph || viewingSpatial { showsInspector = false; compactInspector = false } }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandGlyph(name: "mark").frame(width: 32, height: 32).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 4) { Text("ReadingBook").font(.system(size: 15, weight: .semibold)); Text("阅读 · 线索 · 理解").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: ReadingLayout.groupSpacing) {
                    Text("书库").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 4)
                    ForEach(store.books) { book in
                        Button { Task { await store.selectBook(book.id) } } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 5).fill(Palette.accent.opacity(0.09)).frame(width: 28, height: 36).overlay(BrandGlyph(name: "reader").frame(width: 18, height: 18).foregroundStyle(Palette.accent))
                                VStack(alignment: .leading, spacing: 4) { Text(book.title).lineLimit(1).font(.subheadline.weight(.medium)); ProgressView(value: book.progress).tint(Palette.accent).frame(width: 95) }
                                Spacer(minLength: 0)
                            }.padding(12).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).background(store.bookID == book.id ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(store.isBusy).contextMenu {
                            Button("移入回收站", role: .destructive) { store.requestDeletion(.book, id: book.id, title: book.title) }
                        }
                    }
                    Button { store.chooseBook() } label: { Label("导入书籍", systemImage: "plus").font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(ReadingToolbarButtonStyle()).foregroundStyle(.secondary).disabled(store.isBusy)
                    if store.book != nil {
                        Divider().padding(.vertical, 11)
                        Text("阅读工作台").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.horizontal, 12)
                        routeButton("原文阅读", icon: "book.pages", route: "reader")
                        routeButton("阅读流程", icon: ComponentKind.workflow.icon, route: "workflow")
                        routeButton("与书对话", icon: ComponentKind.query.icon, route: "query")
                        routeButton("我的理解", icon: "square.and.pencil", route: "editor")
                        if !componentViews.isEmpty {
                            Text("这本书的组件").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 16)
                            ForEach(componentViews) { view in
                                routeButton(view.title, icon: view.kind.icon, route: view.id)
                                    .contextMenu {
                                        let count = WorkspaceComponentRegistry.shared.removalIDs(for: view, in: store.book?.views ?? []).count
                                        Button(count > 1 ? "移除此组件及 \(count - 1) 个旧重复入口" : "移除此组件入口") { Task { await store.removeView(view.id) } }
                                    }
                            }
                        }
                        if !addableComponents.isEmpty {
                            Menu {
                                ForEach(addableComponents) { component in
                                    Button { store.activate(component.kind) } label: { Label(component.title, systemImage: component.icon) }
                                }
                            } label: {
                                Label("添加组件", systemImage: "plus.square.on.square").font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                            }.menuStyle(.borderlessButton).padding(.horizontal, 14).disabled(store.isBusy)
                        }
                    }
                }.padding(.horizontal, 12)
            }
            Divider().opacity(0.5)
            AIServiceBar().environmentObject(store)
            HStack {
                Button { store.showingPlugins = true } label: { Image(systemName: "puzzlepiece.extension") }.help("插件与读书法")
                Spacer()
                Menu { Button("导入书项目…") { store.importProject() }; Button("导出完整书项目…") { store.exportProject() }; Button("回收站") { store.showingTrash = true } } label: { Image(systemName: "square.and.arrow.up") }.menuStyle(.borderlessButton).frame(width: 40, height: 40).contentShape(Rectangle()).accessibilityLabel("书库操作")
            }.buttonStyle(ReadingToolbarButtonStyle()).foregroundStyle(.secondary).padding(10)
        }.background(.ultraThinMaterial)
    }
    private var componentViews: [ViewDefinition] { WorkspaceComponentRegistry.shared.navigationViews(store.enabledViews) }
    private var addableComponents: [WorkspaceComponentDescriptor] {
        guard let book = store.book else { return [] }
        let registry = WorkspaceComponentRegistry.shared
        return registry.components.filter { component in
            !component.permanent && !book.views.contains(where: { registry.equivalent($0.kind, component.kind) })
        }
    }
    private func routeButton(_ title: String, icon: String, route: String) -> some View {
        Button { store.route = route } label: {
            HStack(spacing: 12) {
                BrandGlyph(name: BrandNavigation.glyph(route: store.book?.views.first { $0.id == route }?.kind.rawValue ?? route)).frame(width: 20, height: 20)
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
    private var viewingPDF: Bool { store.route == "reader" && readerShowsPDF && store.sourceFileURL?.pathExtension.lowercased() == "pdf" }
    private var viewingWorkflow: Bool { store.route == "workflow" || store.book?.views.first(where: { $0.id == store.route })?.kind == .workflow }
    private var viewingGraph: Bool {
        let kind = store.book?.views.first(where: { $0.id == store.route })?.kind ?? ComponentKind(rawValue: store.route)
        return kind == .mindmap || kind == .relations
    }
    private var viewingSpatial: Bool {
        let kind = store.book?.views.first(where: { $0.id == store.route })?.kind ?? ComponentKind(rawValue: store.route)
        return kind == .map || kind == .timeline
    }
    @ToolbarContentBuilder private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 10) {
                BrandGlyph(name: "mark").frame(width: 20, height: 20).foregroundStyle(Palette.accent)
                Text(store.book?.title ?? "ReadingBook").font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 156)
            }
        }
        if #available(macOS 26.0, *) { ToolbarSpacer(.flexible, placement: .automatic) }
        ToolbarItemGroup(placement: .automatic) {
            if store.selectedObjectID != nil, !viewingGraph, !viewingSpatial {
                Button {
                    if detailWidth >= 920, store.route != "reader" { showsInspector.toggle() }
                    else { compactInspector.toggle() }
                } label: { Image(systemName: showsInspector ? "sidebar.right" : "info.circle") }.help("展开或收起所选对象详情").accessibilityLabel("所选对象详情")
                    .popover(isPresented: $compactInspector) {
                        if let id = store.selectedObjectID { ObjectInspector(id: id, onClose: { compactInspector = false }).environmentObject(store).frame(width: 330, height: 500) }
                    }
            }
            Button { servicePopover.toggle() } label: { Label("AI 服务", systemImage: "sparkles") }.help("AI 服务：\(store.serviceName)")
                .controlSize(.large)
                .popover(isPresented: $servicePopover) { servicePicker }
            if let book = store.book, !viewingWorkflow {
                Button { store.isBusy ? store.pause() : store.startReading() } label: {
                    Label(store.isBusy ? "暂停任务" : (book.insights.isEmpty ? "开始精读" : "继续精读"), systemImage: store.isBusy ? "pause.fill" : "play.fill")
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .help(store.isBusy ? (store.isImportingBookCommit || store.isCommittingLocalWrite ? "正在保存" : store.isExportingProject ? "正在导出" : "暂停任务") : (book.insights.isEmpty ? "开始精读" : "继续精读")).disabled(store.isSavingDocument || store.isExportingProject || store.isImportingBookCommit || store.isCommittingLocalWrite)
            }
            Menu {
                Button("导入书籍…") { store.chooseBook() }
                Button("导入书项目…") { store.importProject() }
                Button("导出完整书项目…") { store.exportProject() }.disabled(store.book == nil)
                Divider()
                Button("插件与读书法") { store.showingPlugins = true }
                Button("回收站") { store.showingTrash = true }
                Divider()
                Text(store.activity)
                if store.requestsUsed > 0 { Text("本轮 \(store.requestsUsed) 次请求") }
            } label: { Image(systemName: "ellipsis") }.help("导入、导出与设置").accessibilityLabel("更多操作")
        }
    }
    private var compactReaderControls: Bool { detailWidth - (readerOutline && detailWidth >= 760 ? 224 : 0) < 650 }
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
                        Button("原始 PDF") { readerShowsPDF = true }
                        Button("文本 / OCR 识别稿") { readerShowsPDF = false }
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
            HStack { Button("管理 / 新建") { servicePopover = false; store.showingSettings = true }; Spacer(); Button("测试") { store.testConnection() }.disabled(store.isBusy || store.settings.model.isEmpty) }
            if !store.connectionStatus.isEmpty { Text(store.connectionStatus).font(.caption).foregroundStyle(.secondary) }
            ServiceProfileLocalError(draft: store.serviceProfileDraft)
        }.padding(20).frame(width: 310)
    }
    private func moveSource(_ offset: Int) {
        guard let units = store.book?.units, let id = store.selectedUnitID, let index = units.firstIndex(where: { $0.id == id }), units.indices.contains(index + offset) else { return }
        store.navigateToUnit(units[index + offset].id)
    }
    private var modalSignature: String {
        "\(store.showingSettings)|\(store.showingOCR)|\(store.showingTrash)|\(store.showingPlugins)|\(store.pdfPasswordRequest?.id.uuidString ?? "")|\(store.pdfPasswordRequest?.message ?? "")"
    }
    private var sheetBinding: Binding<WorkspaceSheet?> {
        Binding(get: { activeSheet }, set: { value in
            if value == nil { sheetClosing = true }
            activeSheet = value
        })
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
        if store.route == "reader" { ReaderWorkspaceView(showPDF: $readerShowsPDF, showOutline: $readerOutline).id(store.bookID) }
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
        }.padding(.horizontal, 22).padding(.vertical, 4).background(.bar)
    }
}

private enum WorkspaceSheet: Identifiable {
    case settings, ocr, trash, plugins, password(PDFPasswordRequest)
    var id: String {
        switch self {
        case .settings: return "settings"
        case .ocr: return "ocr"
        case .trash: return "trash"
        case .plugins: return "plugins"
        case .password(let request): return "password-\(request.id)"
        }
    }
    @MainActor func isRequested(in store: AppStore) -> Bool {
        switch self {
        case .settings: return store.showingSettings
        case .ocr: return store.showingOCR
        case .trash: return store.showingTrash
        case .plugins: return store.showingPlugins
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
    @EnvironmentObject var store: AppStore
    var evidence: [Evidence]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !evidence.isEmpty { Text("回到原文").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            ForEach(Array(evidence.enumerated()), id: \.offset) { _, reference in
                Button { store.follow(reference) } label: {
                    VStack(alignment: .leading, spacing: 5) { Text(store.book?.units.first { $0.id == reference.unitID }?.locator ?? reference.unitID).font(.caption2).foregroundStyle(Palette.accent); Text(reference.quote).font(.caption).foregroundStyle(.secondary).lineLimit(4) }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}
