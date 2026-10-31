import SwiftUI
import ReadingCore

struct PositionNoteFanPresentation: Identifiable {
    let id = UUID()
    let ids: [String]
    let snippets: [String: String]
    let origin: CGPoint
    let owner: WorkspacePickerOwner
}

/// Individual papers float over the original page. The gaps remain transparent;
/// this is a reading-surface overlay, not a sheet or a framed board.
struct PositionNoteFan: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.readingReduceMotion) private var reduceMotion
    let presentation: PositionNoteFanPresentation
    let size: CGSize
    var close: () -> Void
    @State private var opened = false
    @State private var closing = false
    @FocusState private var keyboardFocus: Bool
    @State private var page = 0
    @State private var hoveredID: String?
    @State private var contents: [String: String] = [:]
    private var ids: [String] { presentation.ids.filter { store.activeNotePlacements[$0] != nil } }
    private var pageSize: Int { ReadingNoteFanLayout.pageSize(width: size.width) }
    private var pageCount: Int { max(1, (ids.count + pageSize - 1) / pageSize) }
    private var visibleIDs: [String] { Array(ids.dropFirst(min(page, pageCount - 1) * pageSize).prefix(pageSize)) }
    private var cards: [ReadingNoteFanCard] { ReadingNoteFanLayout.cards(count: visibleIDs.count, width: size.width, height: size.height) }
    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle()).onTapGesture { dismiss() }
            ForEach(Array(visibleIDs.enumerated()), id: \.element) { index, id in
                if index < cards.count {
                    let card = cards[index], raised = hoveredID == id
                    PositionNotePaper(id: id, text: contents[id] ?? presentation.snippets[id] ?? "",
                        height: opened ? card.height : 170, width: opened ? card.width : 230, clickCount: 1,
                        onCommand: { note, command in dismiss(note: note, command: command) })
                        .rotationEffect(.degrees(opened ? (raised ? 0 : card.degrees) : Double(min(index, 2))))
                        .scaleEffect(opened && raised ? 1.035 : 1)
                        .onHover { inside in
                            guard !closing else { return }
                            withAnimation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.08)) {
                                if inside { hoveredID = id } else if hoveredID == id { hoveredID = nil }
                            }
                        }
                        .position(opened ? CGPoint(x: card.x, y: card.y - (raised ? 22 : 0)) :
                                      CGPoint(x: presentation.origin.x + CGFloat(min(index, 2) * 4), y: presentation.origin.y + CGFloat(min(index, 2) * 7)))
                        .zIndex(raised ? 100 : Double(index))
                        .accessibilityAddTraits(.isButton).accessibilityHint("点击编辑；悬停会将这张便签抬到最前面。")
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 36, height: 36) }
                        .buttonStyle(ReadingQuietButtonStyle()).background(Palette.paper.opacity(0.94), in: Circle())
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 3).help("将便签收回页边").accessibilityLabel("收回展开便签")
                }.padding(.top, 88).padding(.trailing, 28)
                Spacer()
                if pageCount > 1 {
                    HStack(spacing: 18) {
                        Button { changePage(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                            .buttonStyle(ReadingQuietButtonStyle()).disabled(page == 0).help("上一叠便签")
                        Text("\(min(page, pageCount - 1) * pageSize + 1)–\(min(ids.count, (min(page, pageCount - 1) + 1) * pageSize)) / \(ids.count)")
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        Button { changePage(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                            .buttonStyle(ReadingQuietButtonStyle()).disabled(page >= pageCount - 1).help("下一叠便签")
                    }.padding(.horizontal, 10).padding(.vertical, 4).background(Palette.paper.opacity(0.94), in: Capsule()).padding(.bottom, 94)
                }
            }.opacity(opened ? 1 : 0).zIndex(200)
        }.frame(width: size.width, height: size.height).accessibilityIdentifier("position-note-fan")
            .focusable().focused($keyboardFocus).focusEffectDisabled()
            .onAppear { keyboardFocus = true; withAnimation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.12)) { opened = true } }
            .onExitCommand { dismiss() }
            .task(id: visibleIDs) {
                guard let book = store.book else { return }
                var loaded: [String: String] = [:]
                for document in book.activeDocuments where visibleIDs.contains(document.id) {
                    if Task.isCancelled { return }
                    if let body = try? await store.repository.readDocument(bookID: book.id, document: document) {
                        let source = String(body.prefix(5000))
                        loaded[document.id] = await Task.detached(priority: .utility) { PositionNotePreview.make(source, project: book) }.value
                    }
                }
                guard !Task.isCancelled, presentation.owner.matches(store) else { return }; contents.merge(loaded) { _, fresh in fresh }
            }
            .onChange(of: ids.isEmpty) { _, empty in if empty { close() } }
            .onChange(of: pageSize) { _, _ in page = 0; hoveredID = nil }
    }
    private func changePage(_ offset: Int) {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.05)) {
            hoveredID = nil; page = min(max(0, page + offset), pageCount - 1)
        }
    }
    private func dismiss(note: String? = nil, command: PositionNoteCommand? = nil) {
        guard !closing else { return }; closing = true
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.34), completionCriteria: .logicallyComplete) {
            opened = false; hoveredID = nil
        } completion: {
            close()
            if let note, let command {
                DispatchQueue.main.async { store.performPositionNoteCommand(command, id: note, owner: presentation.owner) }
            }
        }
    }
}
