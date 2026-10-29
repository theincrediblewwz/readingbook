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
