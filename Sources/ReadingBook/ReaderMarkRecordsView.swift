import SwiftUI
import ReadingCore

@MainActor final class ReaderMarkRecordsState: ObservableObject {
    @Published private(set) var records: [ReaderAnnotation] = []
    func update(_ records: [ReaderAnnotation]) { if self.records != records { self.records = records } }
}

/// Marks remain source decorations. New writing lives in notes; historical
/// comments stay readable in full without reviving a second note editor.
struct ReaderMarkRecordsView: View {
    @ObservedObject var controller: PDFReaderController
    @ObservedObject var model: ReaderMarkRecordsState
    let onLocate: (ReaderAnnotation) -> Void
    let onStyle: (ReaderAnnotation) -> Void
    let onTrash: (ReaderAnnotation, Bool) async -> Bool
    let onClose: () -> Void
    @State private var showTrashed = false
    @State private var expanded: Set<String> = []
    @State private var savingID: String?
    @State private var failure = ""

    private var visible: [ReaderAnnotation] {
        model.records.filter { ($0.trashedAt != nil) == showTrashed }
            .sorted { ($0.page, $0.rangeLocation, $0.id) < ($1.page, $1.rangeLocation, $1.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("本书标记", systemImage: "highlighter").font(.system(size: 18, weight: .semibold))
                Text("\(visible.count)").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ReaderInformationButton(title: "标记与笔记", text: "划线和荧光用于标记原文，写想法请用便签或笔记。过去保存的批注文字仍完整保留在对应记录中。移入回收后可以恢复，原 PDF 不会改写。")
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 32, height: 32) }
                    .buttonStyle(ReadingQuietButtonStyle()).help("关闭标记记录").accessibilityLabel("关闭标记记录")
                    .keyboardShortcut(.cancelAction)
            }
            ManagementSegmentedControl(selection: Binding(get: { showTrashed ? "trashed" : "active" }, set: { showTrashed = $0 == "trashed" }), options: [
                .init(id: "active", title: "原文标记", detail: "查看本书已保存的划线和荧光标记"),
                .init(id: "trashed", title: "已移入回收", detail: "查看和恢复已移走的标记")
            ])
            if !failure.isEmpty { Text(failure).font(.callout).foregroundStyle(.red) }
            if visible.isEmpty {
                ContentUnavailableView(showTrashed ? "没有已移走的标记" : "还没有标记", systemImage: "highlighter",
                    description: Text(showTrashed ? "移走的标记会出现在这里，可以随时恢复。" : "选中原文或在句子上点右键，添加划线或荧光标记。"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visible) { record in card(record) }
                    }.padding(.vertical, 2)
                }
            }
        }.padding(20).frame(minWidth: 390, minHeight: 340)
            .foregroundStyle(Palette.ink).background(Palette.surface)
    }
    private func card(_ record: ReaderAnnotation) -> some View {
        let open = expanded.contains(record.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("第 \(record.page) 页").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent)
                Text(kind(record)).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { if open { expanded.remove(record.id) } else { expanded.insert(record.id) } } label: {
                    Image(systemName: open ? "minus" : "arrow.up.left.and.arrow.down.right").frame(width: 30, height: 30)
                }.buttonStyle(ReadingQuietButtonStyle()).help(open ? "收起这条记录" : "展开完整原文和旧批注")
                    .accessibilityLabel(open ? "收起标记详情" : "展开标记详情")
            }
            Text(record.text.isEmpty ? "原页中的区域标记" : record.text)
                .font(.system(size: 15)).lineSpacing(4).lineLimit(open ? nil : 2).textSelection(.enabled)
            if !record.comment.isEmpty {
                Text(record.comment).font(.system(size: 14)).lineSpacing(4).foregroundStyle(.secondary)
                    .lineLimit(open ? nil : 2).textSelection(.enabled)
            }
            HStack(spacing: 4) {
                Button { onLocate(record) } label: { Label("回到原文", systemImage: "arrow.uturn.backward").padding(.horizontal, 9).frame(height: 34) }
                    .buttonStyle(ReadingQuietButtonStyle()).help("返回这条标记所在页，并定位保存的原文")
                Spacer(minLength: 4)
                if record.trashedAt == nil {
                    if record.effectiveKind == .text {
                        Button { onStyle(record) } label: { Image(systemName: "slider.horizontal.3").frame(width: 34, height: 34) }
                            .buttonStyle(ReadingQuietButtonStyle()).help("调整这条标记的样式").accessibilityLabel("调整标记样式")
                            .disabled(savingID != nil || !controller.canEditAnnotations)
                    }
                    Button { updateTrash(record, trashed: true) } label: { Image(systemName: "trash").frame(width: 34, height: 34) }
                        .buttonStyle(ReadingQuietButtonStyle()).help("移入回收，可在此恢复").accessibilityLabel("移走标记")
                        .disabled(savingID != nil || !controller.canEditAnnotations)
                } else {
                    Button { updateTrash(record, trashed: false) } label: { Label("恢复", systemImage: "arrow.counterclockwise").padding(.horizontal, 9).frame(height: 34) }
                        .buttonStyle(ReadingQuietButtonStyle()).help("恢复这条原文标记").disabled(savingID != nil || !controller.canEditAnnotations)
                }
            }.font(.system(size: 13)).foregroundStyle(Palette.accent)
        }.padding(14).background(Palette.paper, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line.opacity(0.8), lineWidth: 0.75).allowsHitTesting(false) }
    }
    private func kind(_ record: ReaderAnnotation) -> String {
        if record.effectiveKind == .region { return "旧区域标记" }
        switch record.lineStyle { case .straight: return "直线"; case .wavy: return "波浪线"; case nil: return "荧光" }
    }
    private func updateTrash(_ record: ReaderAnnotation, trashed: Bool) {
        guard savingID == nil else { return }
        savingID = record.id; failure = ""
        Task { let saved = await onTrash(record, trashed); savingID = nil; if !saved { failure = "操作未完成，原标记保留，请重试。" } }
    }
}
