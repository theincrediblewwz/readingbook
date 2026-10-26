import Foundation

/// A manual, exact chapter excerpt can be enriched without claiming that the
/// rest of its original unit has been read. This grant is transient and internal;
/// it cannot be supplied by a model argument or decoded from library metadata.
enum ReadingEnrichmentAuthority {
    struct Grant: Sendable {
        var bookID: String
        var sourceHash: String
        var unitID: String
        var unitHash: String
        var ranges: [ReadingSourceRange]
    }
    @TaskLocal static var current: Grant?

    static func validate(in project: BookProject, unitIDs: Set<String>) throws -> Bool {
        guard let grant = current else { return false }
        guard grant.bookID == project.id, grant.sourceHash == project.sourceHash, unitIDs == [grant.unitID],
              let unit = project.units.first(where: { $0.id == grant.unitID }),
              grant.unitHash == (try BookImporter.sha256(Data(unit.text.utf8))),
              !grant.ranges.isEmpty, grant.ranges.count <= 64 else { throw ReadingError.invalid("本次章节译注的原文已变化。") }
        var end = -1
        for range in grant.ranges {
            guard range.unitID == grant.unitID, range.startUTF16 >= end else { throw ReadingError.invalid("章节译注范围重叠或越界。") }
            _ = try range.text(in: unit); end = range.endUTF16
        }
        return true
    }
}
