import SwiftUI
import AppKit
import ReadingCore

/// The complete Markdown stays in one renderer. Only its visible viewport is
/// bounded; copying, links, formula source and saving never use a text excerpt.
struct CompanionRecordBody: View {
    @EnvironmentObject private var typography: ReadingTypographySettings
    let markdown: String
    @State private var naturalHeight: CGFloat = 0
    @State private var expanded = false
    private var previewHeight: CGFloat { max(144, CGFloat(typography.style(for: .companion).pointSize) * 1.75 * 6) }
    private var needsExpansion: Bool { naturalHeight > previewHeight + 2 }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownText(markdown: markdown)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: CompanionRecordHeightPreference.self, value: geometry.size.height)
                    }.allowsHitTesting(false)
                }
                .frame(maxHeight: expanded ? nil : previewHeight, alignment: .top)
                .clipped()
                .onPreferenceChange(CompanionRecordHeightPreference.self) { height in
                    guard height.isFinite, height > 0, abs(naturalHeight - height) > 1 else { return }
                    naturalHeight = height
                }
            if needsExpansion {
                Button { expanded.toggle() } label: {
                    Label(expanded ? "收起全文" : "展开全文", systemImage: expanded ? "arrow.up.to.line" : "arrow.down.to.line")
                        .font(.system(size: 12, weight: .medium)).frame(minHeight: 28).contentShape(Rectangle())
                }.buttonStyle(ReadingQuietButtonStyle()).foregroundStyle(Palette.accent)
                    .help("展开完整解释；复制与存为笔记始终包含全部 Markdown、公式和出处。")
                    .accessibilityValue(expanded ? "已显示全文" : "当前为有限高度预览")
                    .accessibilityHint("点击切换完整正文；复制与存为笔记始终包含全部内容。")
            }
        }.onChange(of: markdown) { _, _ in naturalHeight = 0; expanded = false }
    }
}

private struct CompanionRecordHeightPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

typealias CompanionRecordSource = ReadingCompanionSource

/// One compact action row replaces separate full-width source and draft rows.
/// Multiple sources share a single popover; each still targets its exact anchor.
struct CompanionRecordActions: View {
    let sources: [CompanionRecordSource]
    var externalSource: URL?
    let markdown: String
    let onSource: (String) -> Void
    let onSave: () -> Void
    @State private var showsSources = false
    private var sourceCount: Int { sources.count + (externalSource == nil ? 0 : 1) }
    var body: some View {
        HStack(spacing: 8) {
            sourceAction
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
            } label: { Image(systemName: "doc.on.doc").font(.system(size: 12)).frame(width: 28, height: 32) }
                .buttonStyle(ReadingQuietButtonStyle()).foregroundStyle(.secondary)
                .help("复制完整 Markdown，包含未展开的正文和公式源文。")
                .accessibilityLabel("复制完整 Markdown")
            Button(action: onSave) {
                Label("存为笔记", systemImage: "square.and.pencil").font(.system(size: 12)).frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(ReadingQuietButtonStyle()).foregroundStyle(Palette.accent).fixedSize(horizontal: true, vertical: false)
                .help("把完整内容与原文出处放入可编辑草稿；保存后才成为笔记。")
        }.frame(minHeight: 32)
    }
    @ViewBuilder private var sourceAction: some View {
        if sourceCount == 1, let source = sources.first {
            Button { onSource(source.id) } label: {
                Label(source.quote, systemImage: "arrow.uturn.backward").font(.system(size: 12)).lineLimit(1)
                    .frame(minHeight: 32, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(ReadingQuietButtonStyle()).foregroundStyle(Palette.accent)
                .help(source.locator + "\n" + source.quote + "\n返回原文并高亮，不会重新生成。")
                .accessibilityLabel("返回原文：" + source.quote).accessibilityHint(source.locator)
        } else if sourceCount == 1, let externalSource {
            Link(destination: externalSource) { Label("查看来源", systemImage: "arrow.up.right.square").font(.system(size: 12)).frame(minHeight: 32) }
                .help(externalSource.absoluteString)
        } else if sourceCount > 1 {
            Button { showsSources.toggle() } label: {
                Label("原文 · \(sourceCount) 处", systemImage: "arrow.uturn.backward").font(.system(size: 12)).frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(ReadingQuietButtonStyle()).foregroundStyle(Palette.accent).fixedSize(horizontal: true, vertical: false)
                .help("查看这条记录的全部出处，再选择要返回的位置。")
                .popover(isPresented: $showsSources) { sourcePicker }
        }
    }
    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("原文出处 · \(sourceCount) 处").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                Button { showsSources = false } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(ReadingQuietButtonStyle()).help("关闭出处列表").accessibilityLabel("关闭出处列表")
            }.padding(.horizontal, 14).padding(.vertical, 8)
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sources) { source in
                        Button { showsSources = false; onSource(source.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Label(source.locator, systemImage: "arrow.uturn.backward").font(.system(size: 11)).foregroundStyle(Palette.accent)
                                Text(source.quote).font(.system(size: 13)).multilineTextAlignment(.leading).foregroundStyle(.primary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).contentShape(Rectangle())
                        }.buttonStyle(ReadingQuietButtonStyle()).help("返回这处原文并高亮")
                    }
                    if let externalSource {
                        Link(destination: externalSource) {
                            Label("查看标注的外部来源", systemImage: "arrow.up.right.square").font(.system(size: 13)).frame(minHeight: 32)
                        }.help(externalSource.absoluteString).padding(.vertical, 6)
                    }
                }.padding(.horizontal, 14)
            }
        }.frame(width: 340, height: min(360, max(160, CGFloat(sourceCount) * 76 + 52)))
            .onExitCommand { showsSources = false }
    }
}
