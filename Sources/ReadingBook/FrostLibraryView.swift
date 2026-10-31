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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 20, alignment: .top)], spacing: 20) {
                        ForEach(books) { book in
                            VStack(alignment: .leading, spacing: 0) {
                                Button { Task { await store.selectBook(book.id, preferredRoute: "reader") } } label: {
                                    VStack(alignment: .leading, spacing: 20) {
                                        HStack(spacing: 12) {
                                            Image(systemName: "book.closed.fill").font(.system(size: 25, weight: .medium)).foregroundStyle(Palette.accent)
                                                .frame(width: 46, height: 56).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                                            Text(URL(fileURLWithPath: book.originalName).pathExtension.uppercased())
                                                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                                            Spacer(minLength: 44)
                                        }
                                        Text(book.title).font(.system(size: 18, weight: .semibold))
                                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 8) {
                                            ProgressView(value: book.progress).tint(Palette.accent)
                                            HStack {
                                                Text("已处理 \(Int(book.progress * 100))%")
                                                Spacer(minLength: 0)
                                                Label("\(book.activeDocuments.count)", systemImage: "square.and.pencil")
                                            }.font(.system(size: 13)).foregroundStyle(.secondary)
                                                .help("按已保存的逐段阅读记录计算处理覆盖；右侧为已保存笔记数。")
                                        }
                                    }.padding(20).frame(maxWidth: .infinity, minHeight: 210, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(ReadingQuietButtonStyle(radius: 20)).disabled(store.isBusy)
                                    .help("打开\(book.title)继续阅读")
                            }.readingGlass(radius: 20)
                                .overlay(alignment: .topTrailing) {
                                    LibraryBookActions(book: book).padding(14)

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
                    .buttonStyle(ReadingQuietButtonStyle()).foregroundStyle(.secondary).frame(width: 44, height: 44).accessibilityLabel("清空书库搜索")
            }
        }.padding(.leading, 16).padding(.trailing, search.isEmpty ? 16 : 0).frame(height: 44).readingGlass(radius: 16)
    }
}

private struct LibraryBookActions: View {
    @EnvironmentObject private var store: AppStore
    let book: BookProject
    @State private var owner: WorkspacePickerOwner?
    @State private var presented = false
    var body: some View {
        Button { owner = WorkspacePickerOwner(store: store); presented = true } label: {
            Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40)
        }.buttonStyle(ReadingQuietButtonStyle()).disabled(store.isBusy).help("管理《" + book.title + "》").accessibilityLabel("管理书籍")
            .popover(isPresented: $presented) {
                ManagementActionPopover(title: "管理书籍", options: [
                    .init(id: "finder", title: "在 Finder 显示", detail: "打开本书文件所在的位置。", icon: "folder"),
                    .init(id: "remove", title: "移出书库，保留文件", detail: "从书库列表移除，原书和项目文件保留。", icon: "books.vertical"),
                    .init(id: "delete", title: "删除本机项目副本…", detail: "确认后移到系统废纸篓；不会直接永久删除。", icon: "trash", destructive: true)
                ], width: 370, close: { presented = false }, select: { id in
                    guard owner?.matches(store) == true, store.books.contains(where: { $0.id == book.id && $0.sourceHash == book.sourceHash }), !store.isBusy else { return }
                    presented = false
                    switch id {
                    case "finder": store.showBookFolder(book.id)
                    case "remove": store.requestDeletion(.book, id: book.id, title: book.title)
                    case "delete": store.requestDeletion(.bookLocal, id: book.id, title: book.title)
                    default: break
                    }
                })
            }
            .onChange(of: store.collectionOwnerKey) { _, _ in presented = false; owner = nil }
    }
}
