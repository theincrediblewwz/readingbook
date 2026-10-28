import SwiftUI

enum ReaderToolPopover: Equatable { case navigation, zoom, annotations, more }

/// Clickable groups replace the long menu and its fragile hover submenus.
struct ReaderNavigationPanel: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var pdf: PDFReaderController
    @Binding var showsPDF: Bool
    let viewingPDF: Bool
    var maximumHeight: CGFloat = 600
    var openOutline: (Bool) -> Void
    var close: () -> Void
    @State private var showsParallelModes = false
    private var isPDF: Bool { store.sourceFileURL?.pathExtension.lowercased() == "pdf" }
    var body: some View {
        ViewThatFits(in: .vertical) {
            panelContent
            ScrollView { panelContent }.scrollBounceBehavior(.basedOnSize)
        }.frame(width: 354).frame(maxHeight: max(180, maximumHeight)).background(Palette.surface)
            .onAppear { showsParallelModes = store.readingSourceMode != "original" }
    }
    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("阅读导航").font(.system(size: 16, weight: .semibold))
            HStack(spacing: 4) {
                navigationTile("目录", icon: "list.bullet", selected: false) { openOutline(false) }
                navigationTile("缩略图", icon: "square.grid.2x2", selected: pdf.thumbnailsVisible) {
                    pdf.command(.setThumbnails(!pdf.thumbnailsVisible)); close()
                }.disabled(!viewingPDF || !pdf.isReady)
                navigationTile("书签", icon: "bookmark", selected: false) { openOutline(true) }
                navigationTile("查找", icon: "magnifyingglass", selected: pdf.isSearchVisible) {
                    pdf.command(.setThumbnails(false)); pdf.command(.showSearch); close()
                }.disabled(!viewingPDF || !pdf.isReady)
            }
            if isPDF {
                Divider().opacity(0.55)
                sectionLabel("阅读内容")
                HStack(spacing: 8) {
                    choice("原始 PDF", icon: "doc.richtext", selected: store.readingSourceMode == "original" && showsPDF) { store.readingSourceMode = "original"; showsPDF = true }
                    choice("文本 / OCR", icon: "doc.text", selected: store.readingSourceMode == "original" && !showsPDF) { store.readingSourceMode = "original"; showsPDF = false }
                }
                if viewingPDF {
                    sectionLabel("翻页方式")
                    HStack(spacing: 8) {
                        choice("单页", icon: "doc", selected: !pdf.isContinuous) { pdf.command(.setContinuous(false)) }
                        choice("连续", icon: "rectangle.portrait.on.rectangle.portrait", selected: pdf.isContinuous) { pdf.command(.setContinuous(true)) }
                    }.disabled(!pdf.isReady)
                    sectionLabel("翻页方向")
                    HStack(spacing: 8) {
                        choice("上下", icon: "arrow.up.arrow.down", selected: pdf.direction == .vertical) { pdf.command(.setDirection(.vertical)) }
                        choice("左右", icon: "arrow.left.arrow.right", selected: pdf.direction == .horizontal) { pdf.command(.setDirection(.horizontal)) }
                    }.disabled(!pdf.isReady)
                }
            }
            Divider().opacity(0.55)
            DisclosureGroup("原文与译注", isExpanded: $showsParallelModes) {
              VStack(spacing: 6) {
                HStack(spacing: 8) {
                    choice("原书阅读", icon: "book.closed", selected: store.readingSourceMode == "original") { store.readingSourceMode = "original" }
                    choice("逐段对照", icon: "rectangle.split.1x2", selected: store.readingSourceMode == "stacked") { store.readingSourceMode = "stacked" }
                }
                HStack(spacing: 8) {
                    choice("左右并排", icon: "rectangle.split.2x1", selected: store.readingSourceMode == "parallel") { store.readingSourceMode = "parallel" }
                    choice("只读译注", icon: "text.book.closed", selected: store.readingSourceMode == "layers") { store.readingSourceMode = "layers" }
                }
              }.padding(.top, 10)
            }.font(.system(size: 14, weight: .medium))
        }.padding(18)
    }
    private func sectionLabel(_ value: String) -> some View { Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
    private func navigationTile(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) { Image(systemName: icon).font(.system(size: 19)); Text(title).font(.system(size: 13, weight: .medium)) }
                .frame(maxWidth: .infinity, minHeight: 68).contentShape(RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(selected ? Palette.accent : Palette.ink)
                .background(Palette.accent.opacity(selected ? 0.11 : 0.035), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func choice(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 18)
                Text(title).font(.system(size: 14, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
            }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44).contentShape(RoundedRectangle(cornerRadius: 11))
                .foregroundStyle(selected ? Palette.accent : Palette.ink)
                .background(Palette.accent.opacity(selected ? 0.1 : 0.035), in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ReaderZoomPanel: View {
    @ObservedObject var pdf: PDFReaderController
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                DockIconButton(title: "缩小", icon: "minus") { pdf.command(.zoomOut) }
                Text("\(pdf.zoomPercent)%").font(.system(size: 18, weight: .medium).monospacedDigit()).frame(maxWidth: .infinity)
                DockIconButton(title: "放大", icon: "plus") { pdf.command(.zoomIn) }
            }
            HStack(spacing: 6) {
                zoomChoice("适宽", active: pdf.fitMode == "width", command: .fitWidth)
                zoomChoice("整页", active: pdf.fitMode == "page", command: .fitPage)
                zoomChoice("100%", active: pdf.fitMode == "actual", command: .actualSize)
            }
        }.padding(14).frame(width: 292).background(Palette.surface).disabled(!pdf.isReady)
    }
    private func zoomChoice(_ title: String, active: Bool, command: PDFReaderCommand) -> some View {
        Button { pdf.command(command) } label: { Text(title).font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity, minHeight: 44).contentShape(RoundedRectangle(cornerRadius: 11)) }
            .buttonStyle(.plain).foregroundStyle(active ? Palette.accent : Palette.ink)
            .background(Palette.accent.opacity(active ? 0.1 : 0.035), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct ServiceSwitcherPanel: View {
    @EnvironmentObject private var store: AppStore
    var back: () -> Void
    var manage: () -> Void
    var dismissForConfirmation: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DockIconButton(title: "返回图书与工作区", icon: "chevron.left", action: back)
                Text("AI 服务").font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 0)
            }.padding(.trailing, 14).frame(height: 56)
            Divider().opacity(0.5)
            if store.selectedServiceID == nil {
                HStack(spacing: 10) {
                    Image(systemName: "circle.dashed").foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前未保存配置").font(.system(size: 14, weight: .medium))
                        Text(store.settings.model.isEmpty ? "尚未配置模型" : store.settings.model).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.padding(14)
            }
            if !store.savedServices.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.savedServices) { service in
                            DockMenuRow(title: service.name, icon: "link", detail: service.settings.model, selected: service.id == store.selectedServiceID) {
                                store.selectService(service.id)
                                if store.serviceProfileDraft.pendingChange != nil { dismissForConfirmation() }
                            }.background(Palette.accent.opacity(service.id == store.selectedServiceID ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding(8)
                }.frame(height: min(264, CGFloat(store.savedServices.count) * 62 + 16))
            }
            ServiceProfileLocalError(draft: store.serviceProfileDraft).padding(.horizontal, 14)
            if !store.connectionStatus.isEmpty { Text(store.connectionStatus).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14) }
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                Button(action: manage) { Label("管理服务", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity) }
                Button { store.testConnection() } label: { Label("测试连接", systemImage: "bolt").frame(maxWidth: .infinity) }.disabled(!store.canTestAIConnection || store.settings.model.isEmpty)
            }.font(.system(size: 14)).buttonStyle(ReadingToolbarButtonStyle()).padding(8)
        }.frame(width: 320).background(Palette.surface)
    }
}
