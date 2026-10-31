import SwiftUI
import ReadingCore

struct ReaderInformationButton: View {
    let title: String
    let text: String
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: { Image(systemName: "info.circle").frame(width: 32, height: 32) }
            .buttonStyle(ReadingQuietButtonStyle()).help(text).accessibilityLabel(title)
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(text).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                }.padding(22).frame(width: 350)
            }
    }
}

struct ReaderFolderControl: View {
    @EnvironmentObject private var store: AppStore
    let kind: ReaderCollectionKind
    @Binding var selection: String?
    var organizeNotes = false
    @State private var owner: WorkspacePickerOwner?
    @State private var presented = false
    @State private var naming = false
    @State private var renaming = false
    @State private var removing = false
    @State private var name = ""
    private var folders: [ReaderCollectionFolder] { store.readerCollections.folders.filter { $0.kind == kind } }
    private var selected: ReaderCollectionFolder? { folders.first { $0.id == selection } }
    var body: some View {
        Button { owner = WorkspacePickerOwner(store: store); presented = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(selection == "@unfiled" ? "未分类" : selected?.title ?? "全部" + kind.title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10))
            }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 10).frame(minHeight: 36)
        }.buttonStyle(ReadingQuietButtonStyle()).foregroundStyle(Palette.accent)
            .help("按文件夹查看、新建或管理\(kind.title)；收纳不会移动或改写原始文件。")
            .popover(isPresented: $presented) { folderPicker }
            .alert(renaming ? "重命名文件夹" : "新建文件夹", isPresented: $naming) {
                TextField("文件夹名称", text: $name)
                Button("取消", role: .cancel) { }
                Button("保存") {
                    guard let owner, owner.matches(store) else { return }
                    let command: ReaderCollectionCommand
                    if renaming, let folder = selected { command = .renameFolder(folder.id, name) }
                    else { command = .createFolder(.init(kind: kind, title: name, parentID: selected?.id)) }
                    Task { await store.organizeReaderCollections(command, owner: owner) }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
            }
            .confirmationDialog("移除这个文件夹？", isPresented: $removing, titleVisibility: .visible) {
                Button("移除文件夹", role: .destructive) {
                    guard let id = selected?.id, let owner else { return }; selection = nil
                    Task { await store.organizeReaderCollections(.removeFolder(id), owner: owner) }
                }
                Button("取消", role: .cancel) { }
            } message: { Text("内容保留并回到未分类；子文件夹移到上一层。") }
            .onChange(of: store.collectionOwnerKey) { _, _ in presented = false; naming = false; removing = false; owner = nil; selection = nil }
    }
    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(kind.title + "文件夹").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { presented = false } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("关闭文件夹")
            }
            ScrollView {
                VStack(spacing: 3) {
                    folderRow("全部" + kind.title, icon: "square.grid.2x2", id: nil)
                    folderRow("未分类", icon: "tray", id: "@unfiled")
                    ForEach(orderedFolders) { folder in
                        folderRow(folder.title, icon: "folder", id: folder.id, depth: depth(folder))
                    }
                }
            }.frame(maxHeight: 280)
            Divider().opacity(0.4)
            Button { renaming = false; name = ""; presented = false; naming = true } label: { Label(selected == nil ? "新建文件夹…" : "新建子文件夹…", systemImage: "folder.badge.plus").frame(maxWidth: .infinity, minHeight: 40, alignment: .leading) }
                .buttonStyle(ReadingQuietButtonStyle()).help("新建文件夹；原始内容保留在原位置。")
            if selected != nil {
                Button { renaming = true; name = selected?.title ?? ""; presented = false; naming = true } label: { Label("重命名…", systemImage: "pencil").frame(maxWidth: .infinity, minHeight: 40, alignment: .leading) }.buttonStyle(ReadingQuietButtonStyle())
                Button { presented = false; removing = true } label: { Label("移除文件夹…", systemImage: "folder.badge.minus").frame(maxWidth: .infinity, minHeight: 40, alignment: .leading) }.buttonStyle(ReadingQuietButtonStyle()).help("只移除文件夹，里面的内容保留。")
            }
            if organizeNotes {
                Button {
                    guard let owner else { return }; presented = false
                    Task { await store.organizeReaderCollections(.organizeNotesByMonth, owner: owner) }
                } label: { Label("一键按月份整理", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity, minHeight: 42, alignment: .leading) }
                    .buttonStyle(ReadingQuietButtonStyle()).help("把未分类的笔记按保存月份放入文件夹；已有分类、正文和原文链接保持。")
            }
        }.padding(18).frame(width: 320).disabled(store.isOrganizingCollections)
    }
    private func folderRow(_ title: String, icon: String, id: String?, depth: Int = 0) -> some View {
        Button {
            guard owner?.matches(store) == true else { return }; selection = id; presented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(Palette.accent).frame(width: 20)
                Text(title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if selection == id { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
            }.font(.system(size: 14)).padding(.leading, CGFloat(depth) * 14 + 10).padding(.trailing, 10).frame(minHeight: 44)
        }.buttonStyle(ReadingQuietButtonStyle()).help(title)
    }
    private func depth(_ folder: ReaderCollectionFolder) -> Int {
        var value = folder.parentID, count = 0, visited = Set<String>()
        while let id = value, visited.insert(id).inserted, count < 12 { count += 1; value = folders.first { $0.id == id }?.parentID }
        return count
    }
    private var orderedFolders: [ReaderCollectionFolder] {
        let children = Dictionary(grouping: folders, by: { $0.parentID ?? "" })
        var rows: [ReaderCollectionFolder] = []
        func append(_ parent: String) {
            for folder in (children[parent] ?? []).sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) {
                guard !rows.contains(where: { $0.id == folder.id }) else { continue }
                rows.append(folder); append(folder.id)
            }
        }
        append(""); return rows
    }
}

struct ReaderMoveToFolderButton: View {
    @EnvironmentObject private var store: AppStore
    let kind: ReaderCollectionKind
    let recordIDs: [String]
    @State private var owner: WorkspacePickerOwner?
    @State private var presented = false
    @State private var name = ""
    var body: some View {
        Button { owner = WorkspacePickerOwner(store: store); presented = true } label: {
            Image(systemName: "folder.badge.plus").frame(width: 36, height: 36)
        }.buttonStyle(ReadingQuietButtonStyle()).help("移到文件夹；不改写内容。").accessibilityLabel("移到文件夹")
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("移到文件夹").font(.system(size: 16, weight: .semibold))
                    ScrollView {
                        VStack(spacing: 4) {
                            moveRow("未分类", id: nil)
                            ForEach(store.readerCollections.folders.filter { $0.kind == kind }) { folder in moveRow(folder.title, id: folder.id) }
                        }
                    }.frame(maxHeight: 260)
                    Divider().opacity(0.4)
                    HStack {
                        TextField("新文件夹名称", text: $name).textFieldStyle(.roundedBorder)
                        Button("新建并移入") {
                            guard let owner, owner.matches(store) else { return }
                            let folder = ReaderCollectionFolder(kind: kind, title: name); presented = false
                            Task {
                                await store.organizeReaderCollections(.createFolder(folder), owner: owner)
                                await store.organizeReaderCollections(.move(kind, recordIDs, folder.id), owner: owner)
                            }
                        }.buttonStyle(ReadingToolbarButtonStyle()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
                    }
                }.padding(20).frame(width: 370).disabled(store.isOrganizingCollections)
            }
            .onChange(of: store.collectionOwnerKey) { _, _ in presented = false; owner = nil; name = "" }
    }
    private func moveRow(_ title: String, id: String?) -> some View {
        Button {
            guard let owner, owner.matches(store) else { return }; presented = false
            Task { await store.organizeReaderCollections(.move(kind, recordIDs, id), owner: owner) }
        } label: { Label(title, systemImage: id == nil ? "tray" : "folder").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 10) }
            .buttonStyle(ReadingQuietButtonStyle()).help(title)
    }
}
