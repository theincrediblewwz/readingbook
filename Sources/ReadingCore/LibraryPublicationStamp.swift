import Foundation

/// Repository snapshots can reach the UI in a different order from disk commits.
/// This stamp is deliberately excluded from BookProject.CodingKeys.
public struct LibraryPublicationStamp: Equatable, Sendable {
    public let owner: UUID
    public let ordinal: UInt64

    public static func accepts(_ incoming: BookProject, replacing current: BookProject?, owner: UUID) -> Bool {
        guard let stamp = incoming.publicationStamp else { return current?.publicationStamp == nil }
        guard stamp.owner == owner else { return false }
        guard let current, current.id == incoming.id, let previous = current.publicationStamp,
              previous.owner == owner else { return true }
        return stamp.ordinal >= previous.ordinal
    }
}
