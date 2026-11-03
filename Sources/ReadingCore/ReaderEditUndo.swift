import Foundation

/// Window-local undo describes only the affected records, never a snapshot of
/// the whole book. Applying it compares the latest canonical target first.
public struct ReadingNoteUndoSnapshot: Sendable {
    public var document: DocumentRecord
    public var markdown: String
    public var placement: ReadingNotePlacement?
    public init(document: DocumentRecord, markdown: String, placement: ReadingNotePlacement?) {
        self.document = document; self.markdown = markdown; self.placement = placement
    }
}
public enum ReadingEditUndoChange: Sendable {
    case annotations(expected: [ReaderAnnotation], desired: [ReaderAnnotation])
    case note(expected: ReadingNoteUndoSnapshot, desired: ReadingNoteUndoSnapshot)
    case placement(documentID: String, expected: ReadingNotePlacement?, desired: ReadingNotePlacement?)
    case bookmark(unitID: String, expected: Bool, desired: Bool)
}
public enum ReadingNotePlacementWrite { case set(ReadingNotePlacement?) }
