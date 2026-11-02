import AppKit
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import ReadingCore

@MainActor extension AppStore {
    func coverOperationKey(_ id: String) -> String { libraryRootURL.path + "|" + id }
    func chooseBookCover(_ id: String) {
        guard let project = books.first(where: { $0.id == id }), !storageState.working,
              bookCoverOperations[coverOperationKey(id)] == nil else { return }
        let owner = WorkspacePickerOwner(store: self)
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]; panel.title = "选择书籍封面"; panel.prompt = "使用封面"
        panel.message = "支持常见图片格式，文件须小于 2 MB。原书、笔记和分析会保留。"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url, owner.matches(self) else { return }
            Task { await self.prepareBookCoverCrop(project, url: url, owner: owner) }
        }
    }
    func restoreOriginalBookCover(_ id: String) {
        guard let project = books.first(where: { $0.id == id }), project.coverImage != nil else { return }
        let owner = WorkspacePickerOwner(store: self)
        Task { _ = await changeBookCover(project, bytes: nil, owner: owner) }
    }
    private func prepareBookCoverCrop(_ project: BookProject, url: URL, owner: WorkspacePickerOwner) async {
        let key = coverOperationKey(project.id), token = UUID()
        guard owner.matches(self), !storageState.working, bookCoverOperations[key] == nil else { return }
        bookCoverOperations[key] = token
        defer { if bookCoverOperations[key] == token { bookCoverOperations.removeValue(forKey: key) } }
        do {
            let image = try await Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
                          size > 0, size < BookCoverImage.maximumBytes else { throw ReadingError.invalid("请选择小于 2 MB 的封面图片。") }
                    let data = try Data(contentsOf: url)
                    guard data.count == size else { throw ReadingError.invalid("图片读取时发生变化，请重新选择。") }
                    return try BookCoverCropImage(data: data)
            }.value
            guard owner.matches(self), books.contains(where: { $0.id == project.id && $0.sourceHash == project.sourceHash }), !storageState.working else { return }
            bookCoverCropRequest = BookCoverCropRequest(project: project, owner: owner, image: image)
        } catch { if owner.matches(self) { errorMessage = error.localizedDescription } }
    }
    func applyBookCoverCrop(_ request: BookCoverCropRequest, bytes: Data) async -> Bool {
        guard bookCoverCropRequest?.id == request.id else { return false }
        return await changeBookCover(request.project, bytes: bytes, owner: request.owner)
    }
    private func changeBookCover(_ project: BookProject, bytes: Data?, owner: WorkspacePickerOwner) async -> Bool {
        let key = coverOperationKey(project.id), token = UUID()
        guard owner.matches(self), !storageState.working, bookCoverOperations[key] == nil,
              books.contains(where: { $0.id == project.id && $0.sourceHash == project.sourceHash }) else { return false }
        bookCoverOperations[key] = token
        defer { if bookCoverOperations[key] == token { bookCoverOperations.removeValue(forKey: key) } }
        let repository = repository
        do {
            let saved = try await repository.setBookCover(bookID: project.id, expectedSourceHash: project.sourceHash, data: bytes,
                expectedCoverRevision: project.coverImage?.sha256 ?? "original")
            guard owner.matches(self) else { return false }
            publish(saved); activity = bytes == nil ? "已恢复原书封面。" : "封面已更新；原书、笔记和分析保留。"
            return true
        } catch { if owner.matches(self) { errorMessage = error.localizedDescription }; return false }
    }
    func renameLibraryBook(_ project: BookProject, title: String, owner: WorkspacePickerOwner) async {
        guard owner.matches(self), !storageState.working, !isBusy,
              books.contains(where: { $0.id == project.id && $0.sourceHash == project.sourceHash }) else { return }
        let repository = repository
        do {
            let updated = try await repository.renameBook(bookID: project.id, expectedSourceHash: project.sourceHash, expectedTitle: project.title, title: title)
            guard owner.matches(self) else { return }
            publish(updated); activity = "书名已更新，原文件名、笔记和分析保留。"
        } catch { if owner.matches(self) { errorMessage = error.localizedDescription } }
    }
}

private actor LibraryCoverPreviews {
    static let shared = LibraryCoverPreviews()
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private var totalBytes = 0
    func preview(project: BookProject, repository: LibraryRepository, root: URL) async throws -> Data? {
        let key = root.path + "|" + project.id + "|" + project.sourceHash + "|" + (project.coverImage?.sha256 ?? "original")
        if let data = cache[key] { order.removeAll { $0 == key }; order.append(key); return data }
        let data: Data?
        if let raw = try await repository.bookCoverData(for: project) { data = try BookCoverImage.preview(raw) }
        else {
            let source = await repository.sourceURL(for: project)
            data = source.pathExtension.lowercased() == "pdf" ? try originalFirstPage(source) : nil
        }
        try Task.checkCancellation()
        if let data {
            totalBytes -= cache[key]?.count ?? 0; order.removeAll { $0 == key }
            cache[key] = data; order.append(key); totalBytes += data.count
            while order.count > 64 || totalBytes > 24 * 1024 * 1024 {
                let old = order.removeFirst(); totalBytes -= cache.removeValue(forKey: old)?.count ?? 0
            }
        }
        return data
    }
    private func originalFirstPage(_ url: URL) throws -> Data? {
        try autoreleasepool {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= BookImporter.maximumSourceBytes else { return nil }
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let provider = CGDataProvider(data: bytes as CFData), let document = CGPDFDocument(provider),
                  !document.isEncrypted, let page = document.page(at: 1) else { return nil }
            let crop = page.getBoxRect(.cropBox); guard crop.width > 0, crop.height > 0 else { return nil }
            let rotated = abs(page.rotationAngle) % 180 == 90
            let ratio = rotated ? crop.height / crop.width : crop.width / crop.height
            let width = min(640, max(1, Int(640 * ratio))), height = min(900, max(1, Int(CGFloat(width) / ratio)))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true)); context.drawPDFPage(page)
            guard let image = context.makeImage() else { return nil }
            let result = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(output, image, nil)
            return CGImageDestinationFinalize(output) ? result as Data : nil
        }
    }
}

struct FrostBookCoverCard: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.readingReduceMotion) private var reduceMotion
    let book: BookProject
    @State private var image: NSImage?
    @State private var progress: Double = 0
    private let green = Color(red: 0.39, green: 0.99, blue: 0.48)
    private var identity: String { store.libraryRootURL.path + "|" + book.id + "|" + book.sourceHash + "|" + (book.coverImage?.sha256 ?? "original") }
    var body: some View {
        Button { Task { await store.selectBook(book.id, preferredRoute: "reader") } } label: {
            VStack(alignment: .leading, spacing: 12) {
                GeometryReader { geometry in
                    ZStack(alignment: .bottom) {
                        if let image { Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                        else {
                            VStack(spacing: 18) {
                                Image(systemName: "book.closed").font(.system(size: 48, weight: .light)).foregroundStyle(Palette.accent.opacity(0.7))
                                Text(URL(fileURLWithPath: book.originalName).pathExtension.uppercased()).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.paper)
                        }
                        HStack { Spacer(); Text("\(Int(progress * 100))%").font(.system(size: 18, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(.white).modifier(CoverGlyphLegibility())
                        }.padding(.horizontal, 14).padding(.bottom, 15)
                        ZStack(alignment: .leading) {
                            green.opacity(0.18)
                            green.frame(width: geometry.size.width * progress).shadow(color: green.opacity(0.9), radius: 5)
                        }.frame(height: 4).animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: progress)
                    }.clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7) }
                        .shadow(color: .black.opacity(0.08), radius: 12, y: 7)
                }.aspectRatio(0.78, contentMode: .fit)
                Text(book.title).font(.system(size: 16, weight: .medium)).foregroundStyle(.primary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .center)
            }.padding(5).contentShape(Rectangle())
        }.buttonStyle(ReadingQuietButtonStyle(radius: 18)).disabled(store.isBusy)
            .help("打开《" + book.title + "》继续阅读；绿色进度条表示阅读位置。")
            .accessibilityElement(children: .ignore).accessibilityLabel(book.title).accessibilityAddTraits(.isButton)
            .accessibilityValue("阅读 \(Int(progress * 100))%，\(book.activeDocuments.count) 篇笔记")
            .overlay(alignment: .topTrailing) { LibraryBookActions(book: book).padding(12) }
            .task(id: identity) {
                let ownerRoot = store.libraryRootURL, repository = store.repository
                let unitID = book.id == store.bookID ? store.selectedUnitID : UserDefaults.standard.string(forKey: "position-" + book.id) ?? book.lastUnitID
                let page = book.id == store.bookID ? store.workspaceMemory.activePDFPage : nil
                progress = BookReadingProgress.fraction(in: book, unitID: unitID, page: page)
                do {
                    let data = try await LibraryCoverPreviews.shared.preview(project: book, repository: repository, root: ownerRoot)
                    guard !Task.isCancelled, store.libraryRootURL == ownerRoot else { return }
                    image = data.flatMap(NSImage.init(data:))
                } catch { if !Task.isCancelled { image = nil } }
            }
    }
}
