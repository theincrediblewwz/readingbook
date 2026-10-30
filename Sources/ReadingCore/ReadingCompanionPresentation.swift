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

/// Ephemeral presentation values; lookup never rewrites or retains library data.
public struct ReadingCompanionSource: Identifiable, Equatable, Sendable {
    public let id: String
    public let quote: String
    public let locator: String
    public init(id: String, quote: String, locator: String) {
        self.id = id; self.quote = quote; self.locator = locator
    }
}

extension ReadingCompanionPresentation {
    public static func sources(_ ids: [String], indexedAnchors: [SourceAnchor],
                               storedAnchors: [SourceAnchor], units: [SourceUnit]) -> [ReadingCompanionSource] {
        var seen: Set<String> = []
        let requested = ids.filter { seen.insert($0).inserted }
        // Most sentence cards have one source. Keep their existing short path;
        // build bounded temporary lookups only for multi-source records.
        if requested.count <= 64 {
            return requested.compactMap { id in
                guard let anchor = indexedAnchors.first(where: { $0.id == id })
                    ?? storedAnchors.first(where: { $0.id == id }) else { return nil }
                return ReadingCompanionSource(id: anchor.id, quote: anchor.quote,
                    locator: units.first(where: { $0.id == anchor.unitID })?.locator ?? "原文片段")
            }
        }
        var anchors: [String: SourceAnchor] = [:]
        for anchor in indexedAnchors where seen.contains(anchor.id) {
            if anchors[anchor.id] == nil { anchors[anchor.id] = anchor }
            if anchors.count == seen.count { break }
        }
        for anchor in storedAnchors where seen.contains(anchor.id) {
            if anchors[anchor.id] == nil { anchors[anchor.id] = anchor }
            if anchors.count == seen.count { break }
        }
        let neededUnits = Set(anchors.values.map(\.unitID))
        var locators: [String: String] = [:]
        for unit in units where neededUnits.contains(unit.id) {
            if locators[unit.id] == nil { locators[unit.id] = unit.locator }
            if locators.count == neededUnits.count { break }
        }
        return requested.compactMap { id in
            guard let anchor = anchors[id] else { return nil }
            return ReadingCompanionSource(id: anchor.id, quote: anchor.quote, locator: locators[anchor.unitID] ?? "原文片段")
        }
    }
}
