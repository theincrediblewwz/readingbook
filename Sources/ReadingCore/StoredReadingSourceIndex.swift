/// One render's stored-source lookup. It deliberately keeps the first stored
/// anchor and unit, matching the legacy page; it does not resolve live anchors,
/// deduplicate requested links, or turn display metadata into a source grant.
public struct StoredReadingSourceIndex: Sendable {
    private let anchors: [SourceAnchor]
    private let units: [SourceUnit]
    private let anchorPositions: [String: Int]?
    private let unitLocators: [String: String]?
    private let indexedAnchorIDs: Set<String>
    private let indexedUnitIDs: Set<String>

    public init(anchors: [SourceAnchor], units: [SourceUnit], referencedAnchorIDs: [String]) {
        self.anchors = anchors; self.units = units
        // A few links use the original scan, avoiding a book-sized index when
        // an empty or short companion page is opened.
        let requested = referencedAnchorIDs.count < 12 ? Set<String>() : Set(referencedAnchorIDs)
        if requested.count < 12 {
            anchorPositions = nil; unitLocators = nil
            indexedAnchorIDs = []; indexedUnitIDs = []
        } else {
            var positions: [String: Int] = [:], locators: [String: String] = [:]
            var missing = requested
            for (position, anchor) in anchors.enumerated() where missing.remove(anchor.id) != nil {
                positions[anchor.id] = position
                if missing.isEmpty { break }
            }
            let unitIDs = Set(positions.values.map { anchors[$0].unitID })
            var missingUnits = unitIDs
            for unit in units where missingUnits.remove(unit.id) != nil {
                locators[unit.id] = unit.locator
                if missingUnits.isEmpty { break }
            }
            anchorPositions = positions; unitLocators = locators
            indexedAnchorIDs = requested; indexedUnitIDs = unitIDs
        }
    }

    public func anchor(id: String) -> SourceAnchor? {
        if let anchorPositions, indexedAnchorIDs.contains(id) { return anchorPositions[id].map { anchors[$0] } }
        return anchors.first { $0.id == id }
    }

    public func locator(unitID: String) -> String? {
        if let unitLocators, indexedUnitIDs.contains(unitID) { return unitLocators[unitID] }
        return units.first { $0.id == unitID }?.locator
    }
}
