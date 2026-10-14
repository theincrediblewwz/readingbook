import SwiftUI
import PDFKit
import ReadingCore

/// A pending operation, never a password. The credential lives only in the
/// SecureField state and AppStore's in-memory session dictionary.
struct PDFPasswordRequest: Identifiable, Equatable {
    enum Purpose: Equatable {
        case importing(URL)
        case opening(bookID: String, sourceURL: URL, resumeOCRPages: [Int]?)
    }
    var id = UUID()
    var purpose: Purpose
    var message: String?
    var title: String {
        switch purpose {
        case .importing: return "输入密码以导入 PDF"
        case .opening: return "解锁本次 PDF 会话"
        }
    }
    var actionTitle: String {
        switch purpose {
        case .importing: return "解锁并导入"
        case .opening(_, _, let pages): return pages == nil ? "解锁" : "解锁并继续识别"
        }
    }
}

extension AppStore {
    /// The normal importBook entry point delegates here, so drag/drop and the
    /// file picker share password retry, cancellation and original-file handling.
    func startBookImport(_ url: URL, password: String? = nil) {
        guard !isBusy else { return }
        guard !editorDirty else { errorMessage = "请先保存当前文档，再导入书籍。"; return }
        isBusy = true; activity = "正在建立原文与内容清单…"
        task = Task {
            do {
                var project = try await BookImporter.importFile(at: url, password: password)
                PluginEngine.seed(&project)
                try Task.checkCancellation()
                // Cancellation is honored up to this point. Once the repository
                // commits, always publish that committed book before yielding.
                isImportingBookCommit = true
                // Repository copies the original encrypted bytes. No unlocked
                // PDFDocument or decrypted replacement is written to the book.
                try await repository.create(project, sourceURL: url)
                publish(project)
                if url.pathExtension.lowercased() == "pdf" {
                    if let password { pdfSessionPasswords[project.id] = password }
                    pdfUnlockedBookIDs.insert(project.id)
                }
                pdfPasswordRequest = nil
                activity = "已导入 \(project.units.count) 个内容单元；原文保留，可开始预读。"
                isImportingBookCommit = false; isBusy = false
                await selectBook(project.id)
                return // Do not reset flags belonging to a newer task after selectBook yields.
            } catch let error as PDFPasswordError {
                if Task.isCancelled { handle(CancellationError()) }
                else {
                    presentPDFPassword(.importing(url), error: error)
                    activity = "等待 PDF 打开密码；尚未创建书籍。"
                }
            } catch { handle(error) }
            isImportingBookCommit = false; isBusy = false
        }
    }

    func pdfPassword(for bookID: String?) -> String? {
        guard let bookID else { return nil }
        return pdfSessionPasswords[bookID]
    }

    /// Also receives successful unlocks from the native PDF viewer.
    func rememberPDFPassword(_ password: String, bookID: String) {
        guard password.count <= 1024, books.contains(where: { $0.id == bookID }) else { return }
        pdfSessionPasswords[bookID] = password
        pdfUnlockedBookIDs.insert(bookID)
    }

    /// Called after selectBook resolves the original URL. A fresh app process
    /// starts with an empty session and asks again for a locked source.
    func preparePDFSession(bookID: String, sourceURL: URL) async {
        let navigation = pdfNavigationToken
        do { _ = try await ensurePDFSession(bookID: bookID, sourceURL: sourceURL) }
        catch { if self.bookID == bookID, pdfNavigationToken == navigation { handle(error) } }
    }

    /// Returns false after presenting the password sheet. OCR must stop before
    /// rendering or contacting a provider until this operation returns true.
    func ensurePDFSession(bookID: String, sourceURL: URL, resumeOCRPages: [Int]? = nil) async throws -> Bool {
        guard sourceURL.pathExtension.lowercased() == "pdf" else { return true }
        guard self.bookID == bookID, books.contains(where: { $0.id == bookID }) else { throw CancellationError() }
        if pdfUnlockedBookIDs.contains(bookID) { return true }
        let navigation = pdfNavigationToken
        do {
            try await PDFSessionProbe.validate(sourceURL, password: pdfSessionPasswords[bookID])
            try Task.checkCancellation()
            guard self.bookID == bookID, pdfNavigationToken == navigation else { throw CancellationError() }
            pdfUnlockedBookIDs.insert(bookID)
            return true
        } catch let error as PDFPasswordError {
            try Task.checkCancellation()
            guard self.bookID == bookID, pdfNavigationToken == navigation else { throw CancellationError() }
            // A native viewer or another prompt may have unlocked the same book
            // while this older nil-password probe was still reading its bytes.
            if pdfUnlockedBookIDs.contains(bookID) { return true }
            if let pending = pdfPasswordRequest, case .opening(let pendingID, _, let pages) = pending.purpose,
               pendingID == bookID, pages != nil, resumeOCRPages == nil { return false }
            pdfSessionPasswords.removeValue(forKey: bookID)
            pdfUnlockedBookIDs.remove(bookID)
            presentPDFPassword(.opening(bookID: bookID, sourceURL: sourceURL, resumeOCRPages: resumeOCRPages), error: error)
            return false
        }
    }

    func submitPDFPassword(_ password: String, for request: PDFPasswordRequest) {
        guard !isBusy, pdfPasswordRequest?.id == request.id, !password.isEmpty, password.count <= 1024 else { return }
        switch request.purpose {
        case .importing(let url): startBookImport(url, password: password)
        case .opening(let id, let sourceURL, let pages):
            guard bookID == id else { pdfPasswordRequest = nil; return }
            let navigation = pdfNavigationToken
            isBusy = true; activity = "正在解锁原始 PDF…"
            task = Task {
                var resume: [Int]?
                do {
                    try await PDFSessionProbe.validate(sourceURL, password: password)
                    try Task.checkCancellation()
                    guard bookID == id, pdfNavigationToken == navigation, pdfPasswordRequest?.id == request.id else { throw CancellationError() }
                    rememberPDFPassword(password, bookID: id)
                    pdfPasswordRequest = nil; pdfNavigationToken += 1
                    activity = "PDF 已在本次会话解锁；原文件保持不变。"
                    resume = pages
                } catch let error as PDFPasswordError {
                    if !Task.isCancelled, bookID == id, pdfNavigationToken == navigation, pdfPasswordRequest?.id == request.id { presentPDFPassword(request.purpose, error: error) }
                    else { handle(CancellationError()) }
                }
                catch { handle(error) }
                isBusy = false
                if let resume { startOCR(pages: resume) }
            }
        }
    }

    func cancelPDFPasswordRequest(_ requestID: UUID) {
        guard !isImportingBookCommit, pdfPasswordRequest?.id == requestID else { return }
        if isBusy { task?.cancel() }
        pdfPasswordRequest = nil
        activity = "已取消 PDF 解锁；密码没有保存。"
    }

    private func presentPDFPassword(_ purpose: PDFPasswordRequest.Purpose, error: PDFPasswordError) {
        let id = pdfPasswordRequest?.purpose == purpose ? pdfPasswordRequest!.id : UUID()
        pdfPasswordRequest = PDFPasswordRequest(id: id, purpose: purpose, message: error.errorDescription)
    }
}

private enum PDFSessionProbe {
    static func validate(_ url: URL, password: String?) async throws {
        let child = Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                try Task.checkCancellation()
                guard url.isFileURL else { throw ReadingError.invalid("请选择本地 PDF。") }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size > 0, size <= 256 * 1024 * 1024 else { throw ReadingError.invalid("PDF 不可读取或超过 256 MiB。") }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count == size, let document = PDFDocument(data: data) else { throw ReadingError.invalid("PDF 损坏或读取时发生变化。") }
                if document.isLocked {
                    guard let password else { throw PDFPasswordError.needsPassword }
                    guard password.count <= 1024, document.unlock(withPassword: password), !document.isLocked else { throw PDFPasswordError.wrongPassword }
                }
                try Task.checkCancellation()
            }
        }
        try await withTaskCancellationHandler(operation: { try await child.value }, onCancel: { child.cancel() })
    }
}

struct PDFPasswordSheet: View {
    @EnvironmentObject var store: AppStore
    let request: PDFPasswordRequest
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(request.title, systemImage: "lock.doc").font(.title2)
            Text("只解锁内存中的原书视图与页面识别。密码仅用于本次 App 会话，不会写入书包、钥匙串或设置。")
                .font(.subheadline).foregroundStyle(.secondary)
            SecureField("PDF 打开密码", text: $password).textFieldStyle(.roundedBorder)
                .focused($passwordFocused).disabled(store.isBusy).onSubmit(submit)
            if let message = request.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("取消") { password = ""; store.cancelPDFPasswordRequest(request.id) }.keyboardShortcut(.cancelAction)
                    .disabled(store.isImportingBookCommit)
                Spacer()
                if store.isBusy { ProgressView().controlSize(.small) }
                Button(request.actionTitle, action: submit).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || password.count > 1024 || store.isBusy)
            }
        }.padding(28).frame(width: 430)
            .interactiveDismissDisabled(store.isBusy)
            .onAppear { passwordFocused = true }
            .onDisappear { password = "" }
    }

    private func submit() {
        let value = password; password = ""
        store.submitPDFPassword(value, for: request)
    }
}
