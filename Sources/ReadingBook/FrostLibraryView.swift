import SwiftUI
import ReadingCore

struct FrostLibraryView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    private var books: [BookProject] { store.books.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("每一本书，都留下理解。").font(.system(size: 30, weight: .semibold, design: .serif))
                        Text("原文、AI 分析与你写下的 Markdown，分别保存在本机。").font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 20)
                    TextField("搜索书名", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260).controlSize(.large)
                }
                if store.books.isEmpty {
                    WelcomeView().frame(minHeight: 390)
                } else if books.isEmpty {
                    EmptyState(title: "没有匹配的书", detail: "换一个关键词，或清空搜索查看全部书籍。", icon: "magnifyingglass")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 24)], spacing: 24) {
                        ForEach(books) { book in
                            VStack(alignment: .leading, spacing: 18) {
                                Button { Task { await store.selectBook(book.id) } } label: {
                                    VStack(alignment: .leading, spacing: 22) {
                                        Image(systemName: "book.closed.fill").font(.system(size: 36, weight: .light)).foregroundStyle(Palette.accent).frame(height: 90)
                                        Text(book.title).font(.system(size: 21, weight: .semibold, design: .serif)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 8) {
                                            ProgressView(value: book.progress).tint(Palette.accent)
                                            Text("处理覆盖 \(Int(book.progress * 100))% · \(book.activeDocuments.count) 篇理解").font(.system(size: 13)).foregroundStyle(.secondary)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(store.isBusy)
                                HStack {
                                    Button("继续阅读") { Task { await store.selectBook(book.id) } }.buttonStyle(.borderless).foregroundStyle(Palette.accent).frame(minHeight: 44)
                                    Spacer()
                                    Menu {
                                        Button("移入回收站", role: .destructive) { store.requestDeletion(.book, id: book.id, title: book.title) }
                                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.menuStyle(.borderlessButton).disabled(store.isBusy)
                                }
                            }.padding(24).background(Palette.paper, in: RoundedRectangle(cornerRadius: 22))
                                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.line, lineWidth: 0.75))
                        }
                    }
                }
                HStack(spacing: 16) {
                    Button { store.chooseBook() } label: { Label("导入一本书", systemImage: "plus") }.buttonStyle(.borderedProminent)
                    Button { store.importProject() } label: { Label("导入书项目", systemImage: "square.and.arrow.down") }
                    Button { store.route = "trash" } label: { Label("回收站", systemImage: "trash") }
                }.controlSize(.large).disabled(store.isBusy)
            }.padding(.horizontal, 24).padding(.top, 112).padding(.bottom, 40)
        }.background(Palette.canvas)
    }
}
