import Foundation
import ReadingCore

/// Value-only admission proof; PDFKit documents stay on their owning thread.
/// It is established before the URL is admitted, rather than taking a new stat
/// at reuse time and assuming it describes the document already on screen.
struct PDFDisplaySourceLease: Equatable {
    let root: URL
    let owner: UUID
    let bookID: String
    let originalName: String
    let projectSourceHash: String
    let version: PDFDisplaySourceVersion

    init(root: URL, owner: UUID, project: BookProject, version: PDFDisplaySourceVersion) {
        self.root = root.standardizedFileURL
        self.owner = owner
        bookID = project.id
        originalName = project.originalName
        projectSourceHash = project.sourceHash
        self.version = version
    }
}

/// A deferred native viewport receipt may outlive its view or library. Equal
/// book IDs/hashes alone do not authorize a write into a newly selected owner.
struct PDFWorkspaceMemoryOwner: Equatable {
    let root: URL
    let repositoryOwner: UUID
    let bookID: String
    let sourceHash: String
    let sourceURL: URL
    let displayID: UUID
    let navigationToken: Int
}

/// Number the frozen snapshot, not its delivery. A lifecycle receipt can wait
/// on the main queue while a newer explicit capture has already been saved.
/// The clock spans native views so a remount cannot restart the ordering.
struct PDFWorkspaceMemoryReceipt: Equatable, Sendable {
    let memory: WorkspacePDFMemory
    let captureSequence: UInt64
    @MainActor private static var nextCaptureSequence: UInt64 = 0

    @MainActor init(memory: WorkspacePDFMemory) {
        Self.nextCaptureSequence += 1
        self.memory = memory
        captureSequence = Self.nextCaptureSequence
    }
}

@MainActor extension AppStore {
    var pdfWorkspaceMemoryOwner: PDFWorkspaceMemoryOwner? {
        guard let book, let sourceFileURL else { return nil }
        return PDFWorkspaceMemoryOwner(root: libraryRootURL.standardizedFileURL,
            repositoryOwner: repository.publicationOwner, bookID: book.id,
            sourceHash: book.sourceHash, sourceURL: sourceFileURL.standardizedFileURL,
            displayID: pdfDisplayReloadID, navigationToken: pdfNavigationToken)
    }

    func updatePDFWorkspaceMemory(_ receipt: PDFWorkspaceMemoryReceipt, owner: PDFWorkspaceMemoryOwner) {
        guard receipt.memory.isValid, pdfWorkspaceMemoryOwner == owner,
              receipt.captureSequence > pdfWorkspaceMemoryLatestCaptureSequence else { return }
        // Preserve the ordering barrier even if workspace restoration/storage
        // temporarily suppresses a write. An older queued receipt must not
        // become current merely because its delivery was delayed longer.
        pdfWorkspaceMemoryLatestCaptureSequence = receipt.captureSequence
        updateWorkspaceMemory({ $0.pdf = receipt.memory }, expectedKey: owner.bookID + "|" + owner.sourceHash)
    }

    /// Immediate callers can still submit a value; deferred callers must freeze
    /// a receipt before enqueuing it so delivery cannot assign a newer sequence.
    func updatePDFWorkspaceMemory(_ memory: WorkspacePDFMemory, owner: PDFWorkspaceMemoryOwner) {
        updatePDFWorkspaceMemory(PDFWorkspaceMemoryReceipt(memory: memory), owner: owner)
    }
}
