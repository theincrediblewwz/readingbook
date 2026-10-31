import SwiftUI
import ReadingCore

private struct PositionNoteStackPresentation: Identifiable {
    let id = UUID()
    let ids: [String]
}

/// Paper is confined to a separate part of the book surface. It cannot cover
/// a PDF glyph, even at a large scale, after rotation or in a narrow window.
struct PositionNoteMargin: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var nativePositions: PDFNotePositionState
    let height: CGFloat
    let isPDF: Bool
    var collapse: () -> Void
    @State private var snippets: [String: String] = [:]
    @State private var noteDates: [String: Date] = [:]
    @State private var expanded: PositionNoteStackPresentation?
    @StateObject private var actionRelay = PositionNoteActionRelay()
    private var positions: [ReadingNoteScreenPosition] {
        if isPDF { return nativePositions.owner == store.collectionOwnerKey ? nativePositions.points.map { .init(id: $0.key, y: $0.value.y) } : [] }
        return store.activeNotePlacements.filter { $0.value.unitID == store.selectedUnitID }.map { .init(id: $0.key, y: $0.value.y * height) }
    }
    private var stacks: [ReadingNoteStack] {
        ReadingNoteLayout.stacks(positions, height: height).map { stack in
            ReadingNoteStack(ids: stack.ids.sorted {
                let lhs = noteDates[$0] ?? .distantPast, rhs = noteDates[$1] ?? .distantPast
                return lhs == rhs ? $0 < $1 : lhs > rhs
            }, top: stack.top)
        }
    }
    private var preparationKey: String {
        store.collectionOwnerKey + "|" + String(store.projectRevision) + "|" + positions.map(\.id).sorted().joined(separator: ",")
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.paper
            ForEach(stacks, id: \.ids) { stack in
                if let id = stack.ids.first, let point = positions.first(where: { $0.id == id }) {
                    Path { path in
                        path.move(to: CGPoint(x: 3, y: point.y)); path.addCurve(to: CGPoint(x: 23, y: stack.top + 85), control1: CGPoint(x: 12, y: point.y), control2: CGPoint(x: 13, y: stack.top + 85))
                    }.stroke(Color.primary.opacity(0.17), lineWidth: 0.7).allowsHitTesting(false)
                    Circle().fill(Palette.accent.opacity(0.55)).frame(width: 4, height: 4).position(x: 3, y: point.y).allowsHitTesting(false)
                }
                stackView(stack).padding(.leading, 20).offset(y: stack.top)
            }
            Button(action: collapse) { Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium)).frame(width: 30, height: 30) }
                .buttonStyle(ReadingQuietButtonStyle()).background(Palette.paper.opacity(0.95), in: Circle())
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.06)) }.shadow(color: .black.opacity(0.04), radius: 5, y: 2)
                .padding(14).frame(maxWidth: .infinity, alignment: .trailing)
                .help("收起便签与右侧留白，恢复原来的阅读宽度").accessibilityLabel("收起页边便签")
        }.frame(width: 292, height: height).clipped()
            .task(id: preparationKey) {
                guard let book = store.book else { return }
                let owner = WorkspacePickerOwner(store: store), wanted = Set(positions.map(\.id))
                var values: [String: String] = [:], dates: [String: Date] = [:]
                for document in book.activeDocuments where wanted.contains(document.id) {
                    if Task.isCancelled { return }
                    if let body = try? await store.repository.readDocument(bookID: book.id, document: document) { values[document.id] = String(body.prefix(2400)); dates[document.id] = document.updatedAt }
                }
                guard !Task.isCancelled, owner.matches(store) else { return }; snippets = values; noteDates = dates
            }
            .sheet(item: $expanded, onDismiss: {
                actionRelay.finish(store: store)
            }) { presentation in
                PositionNoteStackBrowser(ids: presentation.ids, snippets: snippets, close: { expanded = nil }, onCommand: { id, command in actionRelay.pending = (id, WorkspacePickerOwner(store: store), command); expanded = nil }).environmentObject(store)
            }
            .onChange(of: store.collectionOwnerKey) { _, _ in snippets = [:]; actionRelay.pending = nil; expanded = nil }
    }
    private func stackView(_ stack: ReadingNoteStack) -> some View {
        HStack(alignment: .center, spacing: 5) {
            ZStack(alignment: .topLeading) {
                if stack.ids.count > 2 { paper.offset(x: 7, y: 13) }
                if stack.ids.count > 1 { paper.offset(x: 4, y: 7) }
                if let id = stack.ids.first {
                    PositionNotePaper(id: id, text: snippets[id] ?? "", height: 170)
                }
            }.frame(width: 230, height: 184, alignment: .topLeading)
            if stack.ids.count > 1 || (stack.ids.first.flatMap { snippets[$0]?.count } ?? 0) > 80 {
                Button { expanded = PositionNoteStackPresentation(ids: stack.ids) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11)).frame(width: 26, height: 32) }
                    .buttonStyle(ReadingQuietButtonStyle()).help("展开这叠 \(stack.ids.count) 张便签").accessibilityLabel("展开 \(stack.ids.count) 张便签")
            }
        }
    }
    private var paper: some View { RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)).overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.07)) }.frame(width: 230, height: 170) }
}

struct PositionNotePaper: View {
    @EnvironmentObject private var store: AppStore
    let id: String
    let text: String
    var height: CGFloat? = 170
    var width: CGFloat = 230
    var clickCount = 2
    var onCommand: ((String, PositionNoteCommand) -> Void)?
    @State private var hovered = false
    @Environment(\.readingReduceMotion) private var reduceMotion
    private var placement: ReadingNotePlacement? { store.readerCollections.notePlacements?[id] }
    private var font: Font {
        let size = placement?.fontSize ?? 15, family = placement?.fontFamily ?? "serif"
        if family == "system" { return .system(size: size) }
        if family == "monospaced" { return .system(size: size, design: .monospaced) }
        return .custom(family == "serif" ? "Songti SC" : family, size: size)
    }
    private var resolvedHeight: CGFloat {
        if let height { return height }
        let family = placement?.fontFamily ?? "serif", size = placement?.fontSize ?? 15
        let native = NSFontManager.shared.font(withFamily: family == "serif" ? "Songti SC" : family, traits: [], weight: 5, size: size) ?? NSFont.systemFont(ofSize: size)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        let bounds = (text as NSString).boundingRect(with: CGSize(width: width - 36, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: native, .paragraphStyle: paragraph])
        return min(300, max(100, ceil(bounds.height) + 36))
    }
    var body: some View {
        Text(text).font(font).foregroundStyle(Color.primary.opacity(0.67)).lineSpacing(5)
            .lineLimit(max(1, Int((resolvedHeight - 36) / ((placement?.fontSize ?? 15) + 5))))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(18)
            .frame(width: width, height: resolvedHeight, alignment: .topLeading).clipped()
            .background(Color(nsColor: .textBackgroundColor).opacity(0.96), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(hovered ? 0.14 : 0.065)) }
            .shadow(color: .black.opacity(hovered ? 0.055 : 0.035), radius: 8, y: 5)
            .contentShape(Rectangle()).onTapGesture(count: clickCount, perform: edit)
            .onHover { hovered = $0 }.animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: hovered)
            .contextMenu {
                Button("编辑便签…", systemImage: "pencil", action: edit)
                Button("字体与字号…", systemImage: "textformat", action: edit)
                Button("在我的笔记中打开", systemImage: "note.text") {
                    perform(.openNotebook)
                }
                Divider()
                Button("重新选择原文位置…", systemImage: "mappin.and.ellipse") { perform(.relocate) }
                Button("取消位置绑定", systemImage: "mappin.slash") { Task { await store.organizeReaderCollections(.setNotePlacement(id, nil)) } }
                Button("移入回收站…", systemImage: "trash") {
                    perform(.trash)
                }
            }.help("右键可编辑、调整字体或取消绑定；双击打开完整正文。")
            .accessibilityLabel("位置笔记").accessibilityValue(text).accessibilityHint("右键或双击编辑；纸条正文保存在普通笔记中。")
    }
    private func edit() { perform(.edit) }
    private func perform(_ command: PositionNoteCommand) {
        if let onCommand { onCommand(id, command) }
        else { store.performPositionNoteCommand(command, id: id, owner: WorkspacePickerOwner(store: store)) }
    }
}

struct PositionNoteStackBrowser: View {
    @EnvironmentObject private var store: AppStore
    let ids: [String]
    let snippets: [String: String]
    var close: () -> Void
    var onCommand: ((String, PositionNoteCommand) -> Void)?
    @State private var contents: [String: String] = [:]
    private var activeIDs: [String] { let current = store.activeNotePlacements; return ids.filter { current[$0] != nil } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Label("这一处的便签 · \(activeIDs.count)", systemImage: "square.stack").font(.system(size: 19, weight: .semibold)); Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("收起这叠便签")
            }.padding(20)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .top)], alignment: .leading, spacing: 22) {
                    ForEach(activeIDs, id: \.self) { id in
                        VStack(spacing: 10) {
                            PositionNotePaper(id: id, text: contents[id] ?? snippets[id] ?? "", height: nil, width: 244, clickCount: 1, onCommand: onCommand)
                                .accessibilityAddTraits(.isButton).help("点击查看与编辑完整便签；右键调整字体或取消位置绑定。")
                        }
                    }
                }.padding(24)
            }
        }.frame(minWidth: 860, idealWidth: 960).frame(height: min(720, max(360, 160 + CGFloat((ids.count + 2) / 3) * 240))).background(Palette.canvas).onExitCommand(perform: close)
            .task {
                guard let book = store.book else { return }; let owner = WorkspacePickerOwner(store: store)
                var loaded: [String: String] = [:]
                for document in book.activeDocuments where ids.contains(document.id) {
                    if Task.isCancelled { return }
                    if let text = try? await store.repository.readDocument(bookID: book.id, document: document) { loaded[document.id] = String(text.prefix(2400)) }
                }
                guard owner.matches(store), !Task.isCancelled else { return }; contents = loaded
            }.onChange(of: store.collectionOwnerKey) { _, _ in close() }
            .onChange(of: activeIDs.isEmpty) { _, empty in if empty { close() } }
    }
}
