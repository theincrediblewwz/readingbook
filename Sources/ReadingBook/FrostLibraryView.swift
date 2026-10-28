import SwiftUI
import AppKit
import ReadingCore

struct FrostLibraryView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    private var books: [BookProject] { store.books.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { libraryHeading; Spacer(minLength: 24); searchControl.frame(width: 280) }
                    VStack(alignment: .leading, spacing: 16) { libraryHeading; searchControl }
                }
                if store.books.isEmpty {
                    VStack(spacing: 14) {
                        BrandGlyph(name: "mark").frame(width: 36, height: 36).foregroundStyle(Palette.accent)
                        Text("从一本书开始").font(.system(size: 18, weight: .semibold))
                        Text("点击右上角导入，或把书拖进窗口。")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                        Text("PDF · EPUB · Markdown · TXT").font(.system(size: 13)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 250).padding(24).readingGlass(radius: 24)
                } else if books.isEmpty {
                    EmptyState(title: "没有匹配的书", detail: "换一个关键词，或清空搜索查看全部书籍。", icon: "magnifyingglass")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 20)], spacing: 20) {
                        ForEach(books) { book in
                            VStack(alignment: .leading, spacing: 0) {
                                Button { Task { await store.selectBook(book.id, preferredRoute: "reader") } } label: {
                                    VStack(alignment: .leading, spacing: 20) {
                                        HStack(alignment: .top, spacing: 14) {
                                            Image(systemName: "book.closed.fill").font(.system(size: 28, weight: .medium)).foregroundStyle(Palette.accent)
                                                .frame(width: 52, height: 68).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                                            VStack(alignment: .leading, spacing: 8) {
                                                Text(book.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 40)
                                                Text(URL(fileURLWithPath: book.originalName).pathExtension.uppercased())
                                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                                            }.frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        VStack(alignment: .leading, spacing: 8) {
                                            ProgressView(value: book.progress).tint(Palette.accent)
                                            HStack {
                                                Text("已处理 \(Int(book.progress * 100))%")
                                                Spacer(minLength: 0)
                                                Label("\(book.activeDocuments.count)", systemImage: "square.and.pencil")
                                            }.font(.system(size: 13)).foregroundStyle(.secondary)
                                                .help("按已保存的逐段阅读记录计算处理覆盖；右侧为已保存笔记数。")
                                        }
                                    }.padding(16).frame(maxWidth: .infinity, minHeight: 168, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(store.isBusy)
                                    .help("打开\(book.title)继续阅读")
                            }.readingGlass(radius: 20)
                                .overlay(alignment: .topTrailing) {
                                    Menu {
                                        Button { store.showBookFolder(book.id) } label: { Label("在 Finder 显示", systemImage: "folder") }
                                        Button { store.requestDeletion(.book, id: book.id, title: book.title) } label: { Label("移出书库，保留文件", systemImage: "books.vertical") }
                                        Divider()
                                        Button(role: .destructive) { store.requestDeletion(.bookLocal, id: book.id, title: book.title) } label: { Label("删除本机项目副本…", systemImage: "trash") }
                                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(6).disabled(store.isBusy).help("管理\(book.title)")
                                }
                        }
                    }
                }
                HStack(spacing: 16) {
                    Button { store.importProject() } label: { Label("导入书项目", systemImage: "square.and.arrow.down") }.buttonStyle(ReadingToolbarButtonStyle())
                    Button { store.route = "trash" } label: { Label("回收站", systemImage: "trash") }.buttonStyle(ReadingToolbarButtonStyle())
                    if let url = store.lastTrashedProjectURL {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("显示系统废纸篓", systemImage: "arrow.up.forward.square") }.buttonStyle(ReadingToolbarButtonStyle())
                    }
                }.controlSize(.large).disabled(store.isBusy)
            }.padding(.horizontal, 24).padding(.top, 104).padding(.bottom, 32)
        }.background(Palette.canvas)
    }
    private var libraryHeading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("书库").font(.system(size: 24, weight: .semibold))
            Text("\(store.books.count) 本").font(.system(size: 13)).foregroundStyle(.secondary)
        }.fixedSize()
    }
    private var searchControl: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "magnifyingglass").readingSearchIcon()
            TextField("搜索书名", text: $search).readingSearchInput().frame(minWidth: 80)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).frame(width: 44, height: 44).accessibilityLabel("清空书库搜索")
            }
        }.padding(.leading, 16).padding(.trailing, search.isEmpty ? 16 : 0).frame(height: 44).readingGlass(radius: 16)
    }
}
