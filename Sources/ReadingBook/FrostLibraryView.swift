import SwiftUI
import AppKit
import ReadingCore

struct FrostLibraryView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    private var books: [BookProject] { store.books.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
            ScrollView {
            VStack(alignment: .leading, spacing: 24) {
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 270), spacing: 28, alignment: .top)], alignment: .leading, spacing: 30) {
                        ForEach(books) { book in FrostBookCoverCard(book: book) }
                    }
                }
            }.padding(.horizontal, 24).padding(.top, 180).padding(.bottom, 104)
            }.accessibilityIdentifier("library-cover-scroll")
            HStack(spacing: 20) {
                libraryHeading
                Spacer(minLength: 12)
                searchControl.frame(width: max(130, min(280, geometry.size.width - 190)))
            }.padding(.horizontal, 24).padding(.top, 104)
                .accessibilityIdentifier("library-fixed-search")
            HStack(spacing: 8) {
                    Button { store.importProject() } label: { Label("导入书项目", systemImage: "square.and.arrow.down") }.buttonStyle(ReadingToolbarButtonStyle())
                    Button { store.route = "trash" } label: { Label("回收站", systemImage: "trash") }.buttonStyle(ReadingToolbarButtonStyle())
                    if let url = store.lastTrashedProjectURL {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("显示系统废纸篓", systemImage: "arrow.up.forward.square") }.buttonStyle(ReadingToolbarButtonStyle())
                    }
                }.controlSize(.large).disabled(store.isBusy)
                    .padding(6).readingGlass(radius: 24)
                    .padding(.leading, 24).padding(.bottom, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .accessibilityIdentifier("library-fixed-actions")
            }
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

struct LibraryBookActions: View {
    @EnvironmentObject private var store: AppStore
    let book: BookProject
    @State private var owner: WorkspacePickerOwner?
    @State private var presented = false
    @State private var renaming = false
    @State private var renameTitle = ""
    @State private var renameTarget: BookProject?
    private var coverOptions: [ManagementActionOption] {
        var options: [ManagementActionOption] = [
            .init(id: "rename", title: "重命名…", detail: "只改书库显示名称，原文件名与内容保留。", icon: "pencil"),
            .init(id: "cover", title: book.coverImage == nil ? "导入封面…" : "更换封面…", detail: "选择小于 2 MB 的图片，可移动、缩放取景。", icon: "photo")]
        if book.coverImage != nil { options.append(.init(id: "cover-reset", title: "使用原书封面", detail: "只移除本书的自选封面，原始图片不改动。", icon: "book.closed")) }
        return options
    }
    var body: some View {
        Button { owner = WorkspacePickerOwner(store: store); presented = true } label: {
            Image(systemName: "ellipsis").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                .modifier(CoverGlyphLegibility()).frame(width: 44, height: 44).contentShape(Circle())
        }.buttonStyle(CoverGlyphButtonStyle()).disabled(store.isBusy || store.bookCoverOperations[store.coverOperationKey(book.id)] != nil).help("管理《" + book.title + "》").accessibilityLabel("管理书籍")
            .popover(isPresented: $presented) {
                ManagementActionPopover(title: "管理书籍", options: coverOptions + [
                    .init(id: "finder", title: "在 Finder 显示", detail: "打开本书文件所在的位置。", icon: "folder"),
                    .init(id: "remove", title: "移出书库，保留文件", detail: "从书库列表移除，原书和项目文件保留。", icon: "books.vertical"),
                    .init(id: "delete", title: "删除本机项目副本…", detail: "确认后移到系统废纸篓；不会直接永久删除。", icon: "trash", destructive: true)
                ], width: 370, close: { presented = false }, select: { id in
                    guard owner?.matches(store) == true, store.books.contains(where: { $0.id == book.id && $0.sourceHash == book.sourceHash }), !store.isBusy else { return }
                    presented = false
                    switch id {
                    case "rename": renameTarget = book; renameTitle = book.title; renaming = true
                    case "cover": DispatchQueue.main.async { store.chooseBookCover(book.id) }
                    case "cover-reset": store.restoreOriginalBookCover(book.id)
                    case "finder": store.showBookFolder(book.id)
                    case "remove": store.requestDeletion(.book, id: book.id, title: book.title)
                    case "delete": store.requestDeletion(.bookLocal, id: book.id, title: book.title)
                    default: break
                    }
                })
            }
            .alert("重命名书籍", isPresented: $renaming) {
                TextField("书名", text: $renameTitle)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("保存") {
                    if let target = renameTarget, let owner, owner.matches(store) {
                        let title = renameTitle
                        Task { await store.renameLibraryBook(target, title: title, owner: owner) }
                    }
                    renameTarget = nil
                }.disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renameTitle.count > 256)
            } message: { Text("只改显示书名，原文件和阅读内容保留。") }
            .onChange(of: store.collectionOwnerKey) { _, _ in presented = false; renaming = false; renameTarget = nil; owner = nil }
    }
}
