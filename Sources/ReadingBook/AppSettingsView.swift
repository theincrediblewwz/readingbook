import SwiftUI
import AppKit
import ReadingCore

struct AppSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var onClose: (() -> Void)? = nil
    @State private var tab = "storage"
    @State private var models = false
    @State private var guide = false
    var body: some View {
        VStack(spacing: 0) {
            SettingsManagementHeader(title: "设置", icon: "gearshape", dirty: false, onClose: { if let onClose { onClose() } else { dismiss() } }) {
                DockIconButton(title: "模型服务", icon: "sparkles") { models = true }.disabled(store.isBusy)
                DockIconButton(title: "使用指南", icon: "questionmark.circle") { guide = true }
            }
            Picker("设置分类", selection: $tab) {
                Text("存储与备份").tag("storage")
                Text("阅读").tag("reading")
                Text("外观").tag("appearance")
                Text("本地诊断").tag("diagnostics")
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 16)
            Divider().opacity(0.4)
            ScrollView {
                Group {
                    switch tab {
                    case "reading": ReadingSettingsPane()
                    case "appearance": AppearanceSettingsPane()
                    case "diagnostics": DiagnosticsSettingsPane(onStart: onClose)
                    default: StorageSettingsPane(state: store.storageState)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: 900, maxHeight: 690).readingGlass(radius: 22, prominent: true).padding(20)
            .sheet(isPresented: $models) { ProviderSettingsView(onClose: { models = false }).environmentObject(store).frame(minWidth: 760, minHeight: 600) }
            .sheet(isPresented: $guide) { ReadingGuideView(onClose: { guide = false }) }
    }
}

private struct StorageSettingsPane: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var state: StorageSettingsState
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Label("书库位置", systemImage: "folder").font(.system(size: 16, weight: .semibold))
                Text(store.libraryRootURL.path).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("在 Finder 显示") { store.showLibraryFolder() }
                    Button("复制路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.libraryRootURL.path, forType: .string) }
                    Spacer(minLength: 8)
                    Button("更改位置…") { store.chooseLibraryLocation() }.disabled(store.isBusy || state.working)
                }.buttonStyle(ReadingToolbarButtonStyle())
                if let overview = state.overview {
                    Text("本地内容 " + ByteCountFormatter.string(fromByteCount: overview.totalBytes, countStyle: .file))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Divider().opacity(0.5)
            Button("打开已有书库…") { store.openExistingLibrary() }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.isBusy || state.working)
            VStack(alignment: .leading, spacing: 12) {
                Text("备份与导出").font(.system(size: 16, weight: .semibold))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { transferButtons }
                    VStack(alignment: .leading, spacing: 8) { transferButtons }
                }.buttonStyle(ReadingToolbarButtonStyle()).disabled(store.isBusy || state.working)
                Text("完整备份含原书、笔记、分析与回收内容。连接设置和密钥留在本机；恢复到新目录，原库保留。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if state.working {
                HStack(spacing: 12) {
                    if state.total > 0 { ProgressView(value: Double(state.completed), total: Double(state.total)).frame(width: 120) }
                    else { ProgressView().controlSize(.small) }
                    Text(state.phase).font(.system(size: 13))
                    if state.total > 0 { Text("\(state.completed)/\(state.total)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
            if !state.notice.isEmpty { Label(state.notice, systemImage: "checkmark.circle").font(.system(size: 13)).foregroundStyle(.secondary) }
            if let error = state.error { Text(error).font(.system(size: 13)).foregroundStyle(Palette.copper).textSelection(.enabled) }
            if let overview = state.overview, !overview.books.isEmpty {
                Divider().opacity(0.5)
                DisclosureGroup("书籍文件") {
                    ForEach(overview.books, id: \.id) { info in
                        HStack(spacing: 12) {
                            Image(systemName: "book.closed").foregroundStyle(Palette.accent)
                            Text(info.title).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(ByteCountFormatter.string(fromByteCount: info.bytes, countStyle: .file)).foregroundStyle(.secondary)
                            Button { NSWorkspace.shared.open(info.directoryURL) } label: { Image(systemName: "folder") }
                                .buttonStyle(ReadingToolbarButtonStyle()).accessibilityLabel("显示\(info.title)文件夹")
                        }.font(.system(size: 14)).padding(.top, 6)
                    }
                }.font(.system(size: 14, weight: .medium))
            }
        }.task { await store.refreshStorageOverview() }
    }
    @ViewBuilder private var transferButtons: some View {
        Button { store.exportLibraryBackup() } label: { Label("导出完整备份…", systemImage: "externaldrive") }
        Button { store.restoreLibraryBackup() } label: { Label("从备份恢复…", systemImage: "arrow.counterclockwise") }
        Button { store.exportReadableLibrary() } label: { Label("导出阅读导览…", systemImage: "doc.text") }
    }
}

private struct ReadingSettingsPane: View {
    @EnvironmentObject private var typography: ReadingTypographySettings
    @State private var textContext: ReadingTextContext = .source
    @AppStorage("reading.defaultDirection") private var direction = "vertical"
    @AppStorage("reading.defaultContinuous") private var continuous = true
    @AppStorage("reading.showProgress") private var progress = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            typographyControls
            Divider().opacity(0.5)
            Text("默认阅读方式").font(.system(size: 16, weight: .semibold))
            Picker("翻页方向", selection: $direction) { Text("上下").tag("vertical"); Text("左右").tag("horizontal") }.pickerStyle(.segmented)
            Picker("页面布局", selection: $continuous) { Text("连续").tag(true); Text("单页").tag(false) }.pickerStyle(.segmented)
            Text("新书使用默认值；已打开的书保留本书设置。") .font(.system(size: 13)).foregroundStyle(.secondary)
            Divider().opacity(0.5)
            Toggle("显示左下角阅读百分比", isOn: $progress)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("字体与字号").font(.system(size: 16, weight: .semibold))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    contextPicker.frame(minWidth: 150, maxWidth: 210)
                    familyPicker.frame(minWidth: 230, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 14) { contextPicker; familyPicker }
            }
            HStack(spacing: 16) {
                Slider(value: pointSize, in: ReadingTextStyle.pointSizeRange, step: 1) { Text("字号") }
                    .frame(minWidth: 100).accessibilityLabel("\(textContext.title)字号")
                Stepper(value: pointSize, in: ReadingTextStyle.pointSizeRange, step: 1) {
                    Text(style.pointSize.formatted(.number.precision(.fractionLength(0...1))) + " pt").monospacedDigit().frame(minWidth: 56, alignment: .trailing)
                }.fixedSize().accessibilityLabel("\(textContext.title)字号")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("预览").font(.system(size: 13)).foregroundStyle(.secondary)
                Text("读到这里，可以再想一想。\n把书中的线索，慢慢变成自己的理解。")
                    .font(typography.font(for: textContext)).lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }.padding(.vertical, 6)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { resetTypographyButtons }
                VStack(alignment: .leading, spacing: 8) { resetTypographyButtons }
            }.buttonStyle(ReadingToolbarButtonStyle())
            Text("适用于文本原文，PDF 使用缩放。").font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
    private var contextPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("阅读区域").foregroundStyle(.secondary)
            Picker("阅读区域", selection: $textContext) {
                ForEach(ReadingTextContext.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var familyPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("字体").foregroundStyle(.secondary)
            Picker("\(textContext.title)字体", selection: family) {
                ForEach(builtInFamilies, id: \.id) { Text($0.title).tag($0.id) }
                if let missingFamily { Text(missingFamily + "（未安装）").tag(missingFamily) }
                Divider()
                ForEach(typography.availableFontFamilies.filter { candidate in !builtInFamilies.contains(where: { $0.id == candidate }) }, id: \.self) {
                    Text($0).tag($0)
                }
            }.pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 20) {
            Picker("外观", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }.pickerStyle(.segmented)
            Toggle("减少动效", isOn: $motion)
            Toggle("减少透明度", isOn: $transparency)
            Text("同时遵循系统辅助功能设置。") .font(.system(size: 13)).foregroundStyle(.secondary)
        }.font(.system(size: 14))
    }
}
private struct DiagnosticsSettingsPane: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var diagnostics = LocalDiagnostics.shared
    var onStart: (() -> Void)?
    @State private var status = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("本地性能诊断").font(.system(size: 16, weight: .semibold))
            Text("采样后操作阅读或导图，再导出报告。报告不含书名、正文、问题、路径或密钥。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { diagnostics.begin(); onStart?() } label: { Label(diagnostics.sampling ? "正在采样…" : "采样 10 秒", systemImage: "waveform.path.ecg") }.disabled(diagnostics.sampling)
                Button("导出报告…") {
                    do { if let url = try diagnostics.export(bookCount: store.books.count, phase: store.isBusy ? "working" : "idle") { NSWorkspace.shared.activateFileViewerSelecting([url]); status = "诊断已保存到本机。" } }
                    catch { status = error.localizedDescription }
                }.disabled(diagnostics.sampling)
            }.buttonStyle(ReadingToolbarButtonStyle())
            if let sample = diagnostics.sample {
                Text("\(sample.ticks) 次采样 · 最大响应间隔 \(Int(sample.maximumGapMilliseconds)) ms · 超过 50 ms：\(sample.gapsOver50ms) 次")
                    .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                Text("主线程响应间隔，不代表实际帧率。") .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !status.isEmpty { Text(status).font(.system(size: 13)).foregroundStyle(.secondary) }
        }
    }
}
