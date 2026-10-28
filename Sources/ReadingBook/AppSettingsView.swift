import SwiftUI
import AppKit
import ReadingCore

struct AppSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    var onClose: (() -> Void)? = nil
    @State private var tab = "storage"
    @State private var models = false
    @State private var guide = false
    private struct Category: Identifiable {
        let id: String
        let title: String
        let icon: String
        let detail: String
    }
    private let categories = [
        Category(id: "storage", title: "书库与备份", icon: "folder", detail: "管理本地书库，保留每一份阅读积累。"),
        Category(id: "reading", title: "阅读", icon: "textformat.size", detail: "调成适合自己的字体与阅读节奏。"),
        Category(id: "appearance", title: "外观", icon: "circle.lefthalf.filled", detail: "让界面更安静、更舒适。"),
        Category(id: "diagnostics", title: "本地诊断", icon: "waveform.path.ecg", detail: "遇到卡顿时，记录本机的响应情况。")
    ]
    var body: some View {
        GeometryReader { geometry in
          let cardWidth = embedded ? min(960, max(1, geometry.size.width - 40)) : geometry.size.width
          let cardHeight = embedded ? min(720, max(1, geometry.size.height - 40)) : geometry.size.height
          VStack(spacing: 0) {
            SettingsManagementHeader(title: "设置", icon: "gearshape", dirty: false, onClose: { if let onClose { onClose() } else { dismiss() } }) {
                DockIconButton(title: "模型服务", icon: "sparkles") { models = true }.disabled(!store.canEditAISettings)
                DockIconButton(title: "使用指南", icon: "questionmark.circle") { guide = true }
            }
            Divider().opacity(0.4)
            if cardWidth < 720 {
                ManagementSegmentedControl(selection: $tab, options: categories.map {
                    ManagementSegmentOption(id: $0.id, title: $0.title, detail: $0.detail)
                }).accessibilityIdentifier("settings.categories").padding(18)
            }
            HStack(alignment: .top, spacing: 0) {
                if cardWidth >= 720 {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(categories) { category in
                            Button { tab = category.id } label: {
                                Label(category.title, systemImage: category.icon)
                                    .font(.system(size: 14, weight: tab == category.id ? .semibold : .regular))
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 12)
                                    .foregroundStyle(tab == category.id ? Palette.accent : Palette.ink)
                                    .background(Palette.accent.opacity(tab == category.id ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 11))
                                    .contentShape(RoundedRectangle(cornerRadius: 11))
                            }.buttonStyle(.plain).help(category.detail).accessibilityAddTraits(tab == category.id ? .isSelected : [])
                        }
                        Spacer(minLength: 0)
                    }.padding(14).frame(width: 180).frame(maxHeight: .infinity)
                        .background(Palette.accent.opacity(0.025))
                    Divider().opacity(0.35)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if let category = categories.first(where: { $0.id == tab }) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(category.title).font(.system(size: 23, weight: .semibold))
                                Text(category.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                        Group {
                            switch tab {
                            case "reading": ReadingSettingsPane()
                            case "appearance": AppearanceSettingsPane()
                            case "diagnostics": DiagnosticsSettingsPane(onStart: onClose)
                            default: StorageSettingsPane(state: store.storageState)
                            }
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading).padding(cardWidth < 720 ? 22 : 30)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
          }.frame(width: cardWidth, height: cardHeight).modifier(AppSettingsSurface(embedded: embedded))
              .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
            .sheet(isPresented: $models) { ProviderSettingsView(onClose: { models = false }).environmentObject(store).frame(minWidth: 760, minHeight: 600) }
            .sheet(isPresented: $guide) { ReadingGuideView(onClose: { guide = false }) }
    }
}

private struct AppSettingsSurface: ViewModifier {
    let embedded: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if embedded { content.readingGlass(radius: 22, prominent: true) }
        else { content.background(Palette.surface) }
    }
}

private struct StorageSettingsPane: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var state: StorageSettingsState
    @State private var pathExpanded = false
    @State private var pathCopied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroupSection(title: "本地书库") {
                libraryLocation
                SettingsGroupDivider()
                SettingsActionRow(title: "打开已有书库", detail: "切换到另一份本地书库，当前内容保留。") {
                    Button("选择书库…") { store.openExistingLibrary() }
                        .buttonStyle(SettingsActionButtonStyle()).disabled(store.isBusy || state.working)
                        .help("选择已有 ReadingBook 书库；不会移动或覆盖当前书库。")
                }
            }
            SettingsGroupSection(title: "备份与导出") {
                SettingsActionRow(title: "完整备份", detail: "原书、笔记、分析与回收内容一同保存。", icon: "externaldrive") {
                    Button("导出完整备份…") { store.exportLibraryBackup() }
                        .buttonStyle(SettingsActionButtonStyle(prominent: true)).disabled(store.isBusy || state.working)
                        .help("将整份书库导出为备份文件，连接设置与密钥留在本机。")
                }
                SettingsGroupDivider()
                SettingsActionRow(title: "从备份恢复", detail: "恢复到新目录，原书库保持原样。", icon: "arrow.counterclockwise") {
                    Button("选择备份…") { store.restoreLibraryBackup() }
                        .buttonStyle(SettingsActionButtonStyle()).disabled(store.isBusy || state.working)
                        .help("选择完整备份，再选择新的恢复位置；不会覆盖当前书库。")
                }
                SettingsGroupDivider()
                SettingsActionRow(title: "阅读导览", detail: "导出便于浏览的书籍目录与阅读记录。", icon: "doc.text") {
                    Button("导出阅读导览…") { store.exportReadableLibrary() }
                        .buttonStyle(SettingsActionButtonStyle()).disabled(store.isBusy || state.working)
                        .help("导出可在书库外浏览的阅读导览，不替代完整备份。")
                }
            }
            Label("连接设置与密钥留在本机，不随完整备份导出。", systemImage: "lock.shield")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            transferStatus
            if let overview = state.overview, !overview.books.isEmpty {
                SettingsContentGroup {
                    DisclosureGroup("书籍文件") {
                        ForEach(overview.books, id: \.id) { info in
                            HStack(spacing: 12) {
                                Image(systemName: "book.closed").foregroundStyle(Palette.accent)
                                Text(info.title).lineLimit(1).help(info.title)
                                Spacer(minLength: 8)
                                Text(ByteCountFormatter.string(fromByteCount: info.bytes, countStyle: .file)).foregroundStyle(.secondary)
                                Button { NSWorkspace.shared.open(info.directoryURL) } label: { Image(systemName: "folder") }
                                    .buttonStyle(SettingsActionButtonStyle()).accessibilityLabel("显示\(info.title)文件夹")
                                    .help("在 Finder 显示\(info.title)的文件夹")
                            }.font(.system(size: 14)).padding(.top, 8)
                        }
                    }.font(.system(size: 14, weight: .medium)).padding(16)
                }
            }
        }.task { await store.refreshStorageOverview() }
            .onChange(of: store.libraryRootURL) { _, _ in pathExpanded = false; pathCopied = false }
    }
    private var libraryLocation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("书库位置", systemImage: "folder").font(.system(size: 14, weight: .medium))
                Spacer(minLength: 8)
                Text("当前书库").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text(store.libraryRootURL.path).font(.system(size: 13, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(store.libraryRootURL.path).accessibilityLabel("书库路径").accessibilityValue(store.libraryRootURL.path)
                Button { pathExpanded.toggle() } label: {
                    Image(systemName: pathExpanded ? "chevron.up" : "chevron.down").font(.system(size: 11))
                }.buttonStyle(SettingsActionButtonStyle())
                    .help(pathExpanded ? "收起完整路径" : "展开完整路径以查看或选择复制")
                    .accessibilityLabel(pathExpanded ? "收起完整书库路径" : "展开完整书库路径")
                    .accessibilityValue(pathExpanded ? "已展开" : "已收起")
            }.padding(10).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line, lineWidth: 1).allowsHitTesting(false) }
            if pathExpanded {
                Text(store.libraryRootURL.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .padding(10).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
            }
            SettingsResponsiveActionLayout(minimumLeadingWidth: 230, spacing: 12) {
                HStack(spacing: 8) {
                    Button { store.showLibraryFolder() } label: { Label("在 Finder 显示", systemImage: "folder") }
                        .help("在 Finder 中打开当前书库位置")
                    Button {
                        NSPasteboard.general.clearContents()
                        pathCopied = NSPasteboard.general.setString(store.libraryRootURL.path, forType: .string)
                    } label: { Label("复制路径", systemImage: "doc.on.doc") }
                        .help("将当前书库的完整路径复制到剪贴板")
                }.buttonStyle(SettingsActionButtonStyle()).fixedSize(horizontal: true, vertical: false)
                Button("更改位置…") { store.chooseLibraryLocation() }
                    .buttonStyle(SettingsActionButtonStyle()).disabled(store.isBusy || state.working)
                    .help("选择新的位置并迁移书库，原书、笔记和分析一同保留。")
            }
            HStack(spacing: 12) {
                if let overview = state.overview {
                    Text("本地内容 " + ByteCountFormatter.string(fromByteCount: overview.totalBytes, countStyle: .file))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if pathCopied { Label("路径已复制", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Palette.accent) }
            }
        }.padding(16)
    }
    @ViewBuilder private var transferStatus: some View {
        if state.working || !state.notice.isEmpty || state.error != nil {
            SettingsContentGroup {
                VStack(alignment: .leading, spacing: 12) {
                    if state.working {
                        HStack(spacing: 12) {
                            if state.total > 0 { ProgressView(value: Double(state.completed), total: Double(state.total)).frame(width: 120) }
                            else { ProgressView().controlSize(.small) }
                            Text(state.phase).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                            if state.total > 0 { Text("\(state.completed)/\(state.total)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary) }
                        }
                    }
                    if !state.notice.isEmpty { Label(state.notice, systemImage: "checkmark.circle").font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if let error = state.error { Text(error).font(.system(size: 13)).foregroundStyle(Palette.copper).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                }.padding(16)
            }
        }
    }
}

private struct ReadingSettingsPane: View {
    @EnvironmentObject private var typography: ReadingTypographySettings
    @State private var textContext: ReadingTextContext = .source
    @AppStorage("reading.defaultDirection") private var direction = "vertical"
    @AppStorage("reading.defaultContinuous") private var continuous = true
    @AppStorage("reading.showProgress") private var progress = true
    @AppStorage("reading.hoverTranslation") private var hoverTranslation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            typographyControls
            SettingsGroupSection(title: "默认阅读方式") {
                SettingsPaneControlRow(title: "翻页方向", detail: "选择上下滚动或左右翻阅。") {
                    ManagementSegmentedControl(selection: $direction, options: [
                        ManagementSegmentOption(id: "vertical", title: "上下", detail: "按垂直方向滚动阅读页面"),
                        ManagementSegmentOption(id: "horizontal", title: "左右", detail: "按水平方向翻阅页面")
                    ]).accessibilityIdentifier("settings.direction")
                        .help("设置新书的默认翻页方向；已打开书籍保留本书设置。")
                }
                SettingsGroupDivider()
                SettingsPaneControlRow(title: "页面布局", detail: "连续浏览相邻页面，或逐页阅读。") {
                    ManagementSegmentedControl(selection: Binding(get: { continuous ? "continuous" : "single" }, set: { continuous = $0 == "continuous" }), options: [
                        ManagementSegmentOption(id: "continuous", title: "连续", detail: "连续浏览相邻页面"),
                        ManagementSegmentOption(id: "single", title: "单页", detail: "每次显示一个页面")
                    ]).accessibilityIdentifier("settings.layout")
                        .help("设置新书的默认页面布局；已打开书籍保留本书设置。")
                }
                SettingsGroupDivider()
                Text("新书使用默认值；已打开的书保留本书设置。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
            SettingsGroupSection(title: "阅读辅助") {
                SettingsPaneToggleRow(title: "显示阅读百分比", detail: "在阅读窗口左下角显示当前位置。", isOn: $progress)
                SettingsGroupDivider()
                SettingsPaneToggleRow(title: "悬停自动翻译", detail: "句旁卡片停留一秒后翻译；已有译文直接读取，缺少时按需调用模型。", isOn: $hoverTranslation)
            }
        }.font(.system(size: 14))
    }

    private struct FontChoice: Identifiable { let id: String; let title: String }
    private let builtInFamilies = [FontChoice(id: "system", title: "系统默认"), FontChoice(id: "serif", title: "宋体"),
                                   FontChoice(id: "sans", title: "无衬线"), FontChoice(id: "monospaced", title: "等宽")]
    private var style: ReadingTextStyle { typography.style(for: textContext) }
    private var family: Binding<String> {
        Binding(get: { typography.style(for: textContext).family }, set: { typography.setFamily($0, for: textContext) })
    }
    private var pointSize: Binding<Double> {
        Binding(get: { typography.style(for: textContext).pointSize }, set: { typography.setPointSize($0, for: textContext) })
    }
    private var missingFamily: String? {
        let selected = style.family
        return builtInFamilies.contains(where: { $0.id == selected }) || typography.availableFontFamilies.contains(selected) ? nil : selected
    }

    private var typographyControls: some View {
        SettingsGroupSection(title: "字体与字号") {
            SettingsPaneFieldGrid {
                contextPicker
                familyPicker
            }.padding(16)
            SettingsGroupDivider()
            VStack(alignment: .leading, spacing: 10) {
                Text("字号").font(.system(size: 14, weight: .medium))
                SettingsResponsiveActionLayout(minimumLeadingWidth: 100, spacing: 12) {
                    Slider(value: pointSize, in: ReadingTextStyle.pointSizeRange, step: 1) { Text("字号") }
                        .labelsHidden().frame(minWidth: 100).accessibilityLabel("\(textContext.title)字号")
                        .help("拖动调整\(textContext.title)字号；右侧也可逐级微调。")
                    Stepper(value: pointSize, in: ReadingTextStyle.pointSizeRange, step: 1) {
                        Text(style.pointSize.formatted(.number.precision(.fractionLength(0...1))) + " pt").monospacedDigit().frame(minWidth: 56, alignment: .trailing)
                    }.fixedSize().accessibilityLabel("\(textContext.title)字号")
                        .help("以 1 pt 为单位调整\(textContext.title)字号。")
                }
            }.padding(16)
            SettingsGroupDivider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("预览").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 8)
                    Text(textContext.title).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text("读到这里，可以再想一想。\n把书中的线索，慢慢变成自己的理解。")
                    .font(typography.font(for: textContext)).lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .padding(12).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 9))
            }.padding(16)
            SettingsGroupDivider()
            VStack(alignment: .leading, spacing: 12) {
                SettingsResponsiveActionLayout(minimumLeadingWidth: 150, spacing: 12) { resetTypographyButtons }
                    .buttonStyle(SettingsActionButtonStyle())
                Text("字体与字号分别应用于所选区域；原始 PDF 页面使用缩放。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16)
        }
    }
    private var contextPicker: some View {
        SettingsPaneField(title: "阅读区域", detail: "分别调整不同区域的文字。") {
            Picker("阅读区域", selection: $textContext) {
                ForEach(ReadingTextContext.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).labelsHidden().controlSize(.large).frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 36, alignment: .leading).help("选择要调整字体与字号的阅读区域")
        }
    }
    private var familyPicker: some View {
        SettingsPaneField(title: "字体", detail: missingFamily == nil ? "可用字体来自本机。" : "所选字体未安装，显示时使用替代字体。") {
            Picker("\(textContext.title)字体", selection: family) {
                ForEach(builtInFamilies, id: \.id) { Text($0.title).tag($0.id) }
                if let missingFamily { Text(missingFamily + "（未安装）").tag(missingFamily) }
                Divider()
                ForEach(typography.availableFontFamilies.filter { candidate in !builtInFamilies.contains(where: { $0.id == candidate }) }, id: \.self) {
                    Text($0).tag($0)
                }
            }.pickerStyle(.menu).labelsHidden().controlSize(.large).frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 36, alignment: .leading).help("\(textContext.title)字体：\(style.family)")
        }
    }
    @ViewBuilder private var resetTypographyButtons: some View {
        Button("恢复此区域") { typography.reset(textContext) }.help("恢复\(textContext.title)的默认字体与字号")
        Button("全部恢复默认") { typography.resetAll() }.help("恢复所有阅读区域的默认字体与字号")
    }
}
private struct AppearanceSettingsPane: View {
    @AppStorage("appearance.colorScheme") private var appearance = "system"
    @AppStorage("appearance.reduceMotion") private var motion = false
    @AppStorage("appearance.reduceTransparency") private var transparency = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroupSection(title: "显示模式") {
                SettingsPaneControlRow(title: "界面外观", detail: "跟随 macOS，或固定使用浅色、深色。", controlWidth: 260) {
                    ManagementSegmentedControl(selection: $appearance, options: [
                        ManagementSegmentOption(id: "system", title: "跟随系统", detail: "随 macOS 外观自动切换"),
                        ManagementSegmentOption(id: "light", title: "浅色", detail: "固定使用浅色界面"),
                        ManagementSegmentOption(id: "dark", title: "深色", detail: "固定使用深色界面")
                    ]).accessibilityIdentifier("settings.appearance")
                        .help("跟随系统时，界面随 macOS 的浅色或深色外观切换。")
                }
            }
            SettingsGroupSection(title: "动态与材质") {
                SettingsPaneToggleRow(title: "减少动效", detail: "减少面板切换、展开与呼吸动画。", isOn: $motion)
                SettingsGroupDivider()
                SettingsPaneToggleRow(title: "减少透明度", detail: "减弱毛玻璃与背景透色，让浮窗和控件更清晰。", isOn: $transparency)
            }
            Label("同时遵循 macOS 辅助功能中的减少动态效果与降低透明度设置。", systemImage: "accessibility")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 14))
    }
}
private struct DiagnosticsSettingsPane: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var diagnostics = LocalDiagnostics.shared
    var onStart: (() -> Void)?
    @State private var status = ""
    @State private var exportFailed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroupSection(title: "采集") {
                SettingsActionRow(title: "主线程响应采样", detail: "开始后操作阅读或导图，约 10 秒后自动结束。", icon: "waveform.path.ecg") {
                    Button { diagnostics.begin(); onStart?() } label: {
                        Label(diagnostics.sampling ? "正在采样…" : "采样 10 秒", systemImage: "waveform.path.ecg")
                    }.buttonStyle(SettingsActionButtonStyle(prominent: true)).disabled(diagnostics.sampling)
                        .help("在本机记录约 10 秒的主线程响应间隔；不读取正文，也不调用模型。")
                }
                SettingsGroupDivider()
                HStack(alignment: .top, spacing: 10) {
                    if diagnostics.sampling { ProgressView().controlSize(.small) }
                    else { Image(systemName: diagnostics.sample == nil ? "circle.dotted" : "checkmark.circle").foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(diagnostics.sampling ? "正在记录响应间隔" : diagnostics.sample == nil ? "尚未采样" : "已有完成的采样")
                            .font(.system(size: 14, weight: .medium))
                        Text(diagnostics.sampling ? "请操作需要检查的界面，完成后再回来导出报告。" : diagnostics.sample == nil
                            ? "可先采样，也可直接导出不含采样结果的本机环境信息。"
                            : "可导出最近一次结果；再次采样会在完成后更新这些数据。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }.padding(16).accessibilityElement(children: .combine)
            }
            if let sample = diagnostics.sample {
                SettingsGroupSection(title: "最近一次完成的采样") {
                    resultRow("实际采样时长", value: sample.durationSeconds.formatted(.number.precision(.fractionLength(1))) + " 秒")
                    SettingsGroupDivider()
                    resultRow("计时器回调", value: "\(sample.ticks) 次")
                    SettingsGroupDivider()
                    resultRow("最大响应间隔", value: "\(Int(sample.maximumGapMilliseconds)) ms")
                    SettingsGroupDivider()
                    resultRow("超过 50 ms 的间隔", value: "\(sample.gapsOver50ms) 次")
                    SettingsGroupDivider()
                    Text("记录主线程计时器回调之间的间隔，不代表实际渲染帧率（FPS）。主线程忙碌时，实际采样时长可能超过 10 秒。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(16)
                }
            }
            SettingsGroupSection(title: "导出与隐私") {
                SettingsActionRow(title: "本地诊断报告", detail: "保存为 JSON 文件；取消保存对话框不会导出文件。", icon: "doc.text") {
                    Button("导出报告…") {
                        do {
                            if let url = try diagnostics.export(bookCount: store.books.count, phase: store.isBusy ? "working" : "idle") {
                                NSWorkspace.shared.activateFileViewerSelecting([url]); status = "诊断已保存到本机。"; exportFailed = false
                            }
                        } catch { status = error.localizedDescription; exportFailed = true }
                    }.buttonStyle(SettingsActionButtonStyle()).disabled(diagnostics.sampling)
                        .help("选择报告保存位置；导出后在 Finder 显示文件，报告不会自动上传。")
                }
                SettingsGroupDivider()
                VStack(alignment: .leading, spacing: 9) {
                    Label("不含书名、正文、问题、路径或密钥。", systemImage: "lock.shield")
                        .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    Text("包含软件与构建版本、系统版本、处理器数量、系统内存、书籍数量、忙碌状态，以及最近一次采样结果（如有）。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(16)
            }
            if !status.isEmpty {
                SettingsContentGroup {
                    Label(status, systemImage: exportFailed ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.system(size: 13)).foregroundStyle(exportFailed ? Palette.copper : Color.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(16)
                }
            }
        }
    }
    private func resultRow(_ title: String, value: String) -> some View {
        HStack(spacing: 16) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit().textSelection(.enabled)
        }.padding(16).accessibilityElement(children: .combine)
    }
}
