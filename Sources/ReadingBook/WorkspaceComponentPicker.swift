import SwiftUI
import ReadingCore

/// A popover command belongs to the book and library that opened it, including
/// the no-book state used by import. An old callback cannot target a new owner.
struct WorkspacePickerOwner: Identifiable {
    let id = UUID()
    let libraryRoot: URL
    let bookID: String?
    let sourceHash: String?
    @MainActor init(store: AppStore) {
        libraryRoot = store.libraryRootURL; bookID = store.bookID; sourceHash = store.book?.sourceHash
    }
    @MainActor func matches(_ store: AppStore) -> Bool {
        libraryRoot == store.libraryRootURL && bookID == store.bookID && sourceHash == store.book?.sourceHash
    }
}

struct WorkspacePickerEntryLabel: View {
    let title: String
    let icon: String
    let expanded: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 20)).frame(width: 22, height: 22)
            Text(title).font(.system(size: 15)).lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(expanded ? Palette.accent.opacity(0.45) : Palette.line.opacity(0.8), lineWidth: 0.7).allowsHitTesting(false) }
            .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

struct WorkspaceComponentPicker: View {
    let components: [WorkspaceComponentDescriptor]
    let width: CGFloat
    let maximumHeight: CGFloat
    let enabled: Bool
    let close: () -> Void
    let select: (WorkspaceComponentDescriptor) -> Void
    var body: some View {
        WorkspaceNavigationPicker(title: "添加到本书", options: components.map {
            WorkspacePickerOption(id: $0.id, title: $0.title, detail: description($0), icon: $0.icon, enabled: enabled)
        }, width: width, maximumHeight: maximumHeight, close: close) { id in
            if let component = components.first(where: { $0.id == id }) { select(component) }
        }
    }
    private func description(_ descriptor: WorkspaceComponentDescriptor) -> String {
        switch descriptor.id {
        case "reading.layers": return "对照原文、译文和解释"
        case "reading.atlas": return "查看本书内容与阅读进展概览"
        default:
            switch descriptor.kind {
            case .cards: return "人物、地点、概念与事件"
            case .map, .timeline: return "按时间与地点追踪书中线索"
            case .mindmap: return "用分支梳理观点和阅读结构"
            case .relations: return "查看人物、事件和概念间的联系"
            case .knowledge: return "集中查看本书已整理的资料"
            default: return "添加到本书的阅读工作台"
            }
        }
    }
}

enum WorkspaceTransferAction: String, CaseIterable, Identifiable {
    case importBook, importProject, exportProject
    var id: String { rawValue }
    var title: String {
        switch self { case .importBook: return "导入书籍…"; case .importProject: return "导入书项目…"; case .exportProject: return "导出完整书项目…" }
    }
    var icon: String {
        switch self { case .importBook: return "book.badge.plus"; case .importProject: return "square.and.arrow.down"; case .exportProject: return "square.and.arrow.up" }
    }
    var detail: String {
        switch self {
        case .importBook: return "读取 PDF、EPUB、Markdown 或文本"
        case .importProject: return "恢复原书、笔记与已保存的分析"
        case .exportProject: return "打包原书、Markdown 笔记和分析"
        }
    }
}

struct WorkspaceTransferPicker: View {
    let width: CGFloat
    let maximumHeight: CGFloat
    let enabled: Bool
    let hasBook: Bool
    let close: () -> Void
    let select: (WorkspaceTransferAction) -> Void
    var body: some View {
        WorkspaceNavigationPicker(title: "导入与导出", options: WorkspaceTransferAction.allCases.map {
            WorkspacePickerOption(id: $0.id, title: $0.title, detail: $0.detail, icon: $0.icon, enabled: enabled && ($0 != .exportProject || hasBook))
        }, width: width, maximumHeight: maximumHeight, close: close) { id in
            if let action = WorkspaceTransferAction(rawValue: id) { select(action) }
        }
    }
}

private struct WorkspacePickerOption: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let enabled: Bool
}

/// One real hierarchy, shared only as a view type. No native Menu or adaptive
/// alternative tree is constructed while measuring the navigation layout.
private struct WorkspaceNavigationPicker: View {
    let title: String
    let options: [WorkspacePickerOption]
    let width: CGFloat
    let maximumHeight: CGFloat
    let close: () -> Void
    let select: (String) -> Void
    @FocusState private var focusedID: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 13)).frame(width: 32, height: 32) }
                    .buttonStyle(ReadingQuietButtonStyle()).help("关闭选择").accessibilityLabel("关闭" + title)
            }.padding(.leading, 16).padding(.trailing, 8).frame(height: 50)
            Divider().opacity(0.4)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(options) { option in
                        Button { select(option.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: option.icon).font(.system(size: 20)).foregroundStyle(Palette.accent).frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.title).font(.system(size: 15)).foregroundStyle(.primary).lineLimit(1)
                                    Text(option.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(ReadingQuietButtonStyle()).modifier(WorkspacePickerRowHighlight()).disabled(!option.enabled).focused($focusedID, equals: option.id)
                            .help(option.title + "\n" + option.detail).accessibilityElement(children: .combine)
                            .padding(.horizontal, 5)
                    }
                }.padding(.vertical, 5)
            }.frame(height: max(52, min(CGFloat(options.count) * 52 + 10, maximumHeight - 51)))
        }.frame(width: width).background(Palette.surface)
            .onExitCommand(perform: close)
            .onMoveCommand { direction in moveFocus(direction) }
            .onAppear { focusedID = options.first(where: \.enabled)?.id }
            .onChange(of: options.map(\.id)) { _, ids in if !ids.contains(focusedID ?? "") { focusedID = options.first(where: \.enabled)?.id } }
    }
    private func moveFocus(_ direction: MoveCommandDirection) {
        let enabled = options.filter(\.enabled).map(\.id)
        guard !enabled.isEmpty else { return }
        let delta: Int
        switch direction { case .up: delta = -1; case .down: delta = 1; default: return }
        let current = focusedID.flatMap { enabled.firstIndex(of: $0) } ?? (delta > 0 ? -1 : enabled.count)
        focusedID = enabled[min(enabled.count - 1, max(0, current + delta))]
    }
}

private struct WorkspacePickerRowHighlight: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.background(Palette.accent.opacity(hovered ? 0.065 : 0), in: RoundedRectangle(cornerRadius: 9))
            .onHover { hovered = $0 }
    }
}
