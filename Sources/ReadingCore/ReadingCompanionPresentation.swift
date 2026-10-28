import Foundation

/// Saved enhancement arrays are append ordered. Presentation order is derived
/// from that sequence, never from arbitrary UUIDs or invented legacy dates.
public struct ReadingCompanionRecordPlan: Equatable, Sendable {
    public var primaryID: String?
    public var orderedIDs: [String]
    public var historyIDs: [String]
    public init(primaryID: String? = nil, orderedIDs: [String] = [], historyIDs: [String] = []) {
        self.primaryID = primaryID; self.orderedIDs = orderedIDs; self.historyIDs = historyIDs
    }
}

public enum ReadingCompanionPresentation {
    public static func layers(_ layers: [ReadingLayer], focusedAnchorID: String? = nil) -> ReadingCompanionRecordPlan {
        let newest = layers.reversed()
        let primary: String?
        if let focusedAnchorID {
            // A sentence card owns its translation. Broader/multi-anchor
            // analyses stay in history instead of posing as its current answer.
            primary = newest.first {
                $0.kind != "translation" && $0.sourceAnchorIDs == [focusedAnchorID]
            }?.id
        } else { primary = newest.first?.id }
        let ordered = newest.map(\.id)
        return ReadingCompanionRecordPlan(primaryID: primary, orderedIDs: ordered,
            historyIDs: ordered.filter { $0 != primary })
    }

    public static func alignments(_ alignments: [ReferenceAlignment], focusedAnchorID: String? = nil) -> ReadingCompanionRecordPlan {
        let newest = alignments.reversed()
        let primary: String?
        if let focusedAnchorID { primary = newest.first { $0.sourceAnchorIDs.contains(focusedAnchorID) }?.id }
        else { primary = newest.first?.id }
        let ordered = newest.map(\.id)
        return ReadingCompanionRecordPlan(primaryID: primary, orderedIDs: ordered,
            historyIDs: ordered.filter { $0 != primary })
    }
}

/// A review is needed only when the requested source already has saved derived
/// content. Indexed source anchors alone do not turn a first generation into a
/// regeneration. The review never edits or removes those records.
public struct ReadingCompanionGenerationReview: Equatable, Sendable {
    public var layerCount: Int
    public var alignmentCount: Int
    public var objectCount: Int
    public var requiresConfirmation: Bool { layerCount + alignmentCount + objectCount > 0 }
    public init(items: ReadingContextItems) {
        layerCount = items.layers.count; alignmentCount = items.alignments.count
        objectCount = items.entities.count + items.events.count
    }
    public init(project: BookProject, unitIDs: Set<String>) {
        let state = project.readingExperience ?? ReadingExperienceState()
        let anchors = Set(state.anchors.filter { $0.sourceHash == project.sourceHash && unitIDs.contains($0.unitID) }.map(\.id))
        layerCount = state.layers.filter { !anchors.isDisjoint(with: $0.sourceAnchorIDs) }.count
        alignmentCount = state.alignments.filter { !anchors.isDisjoint(with: $0.sourceAnchorIDs) }.count
        objectCount = project.entities.filter { $0.evidence.contains { unitIDs.contains($0.unitID) } }.count
            + project.events.filter { $0.evidence.contains { unitIDs.contains($0.unitID) } }.count
    }
}
