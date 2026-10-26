import Foundation

extension LibraryRepository {
    /// Host-only metadata publication. Re-read canonical state so another
    /// window's notes, chat and analysis are never replaced by the PDF worker.
    public func saveOriginalBookOutline(bookID: String, outline: BookChapterOutline) throws -> BookProject {
        let directory = try bookDirectory(bookID, mustExist: true)
        let current = try readProject(in: directory)
        try BookChapterRuntime.validateStored(outline)
        guard current.originalName.lowercased().hasSuffix(".pdf"),
              outline.sourceHash == current.sourceHash,
              outline.sourceFingerprint == (try BookOutlineRuntime.fingerprint(in: current)),
              outline.totalUnitCount == current.units.count else {
            throw ReadingError.invalid("原文已更新，目录范围未覆盖已有内容；请重新读取目录。")
        }
        // A native bookmark may navigate to an image/OCR page whose exact text
        // is unavailable. Keep navigation metadata, but never invent a range.
        let units = Dictionary(grouping: current.units, by: \.id)
        for entry in outline.entries {
            try Task.checkCancellation()
            guard let anchor = entry.anchor else { continue }
            guard let matches = units[anchor.unitID], matches.count == 1, let unit = matches.first else { throw ReadingError.invalid("章节原文位置不存在。") }
            let local = BookProject(id: current.id, title: current.title, originalName: current.originalName, sourceHash: current.sourceHash, units: [unit])
            guard try ReadingExperienceRuntime.resolve(anchor, in: local).page == entry.page else { throw ReadingError.invalid("章节原文页码不一致。") }
        }
        return try saveCanonicalProject(current, originalBookOutline: outline)
    }
}
