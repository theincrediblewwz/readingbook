import Foundation

/// A sentence popup is narrower than a page/chapter companion. A citation that
/// merely overlaps the hovered sentence does not make the entire saved analysis
/// an explanation of that sentence. This disposable projection never edits the
/// stored layer or its anchors.
public enum ReadingSentenceLayerProjection {
    public static func exactLayers(for anchor: SourceAnchor, in project: BookProject,
                                   state suppliedState: ReadingExperienceState? = nil,
                                   structuralBreaks: [Int] = [], maximumCount: Int = 3) -> [ReadingLayer] {
        guard maximumCount > 0, !Task.isCancelled,
              let resolved = try? ReadingExperienceRuntime.resolve(anchor, in: project) else { return [] }
        let boundaries = ReadingSentenceAnchors.boundaryIndex(in: resolved.unit.text, chapterTitle: resolved.unit.chapter,
            syntax: ReadingSentenceAnchors.syntax(for: resolved.unit, in: project), structuralBreaks: structuralBreaks)
        guard !boundaries.crossesStructuralBoundary(resolved.range) else { return [] }
        let state = suppliedState ?? project.readingExperience ?? ReadingExperienceState()
        let anchors = Dictionary(grouping: state.anchors.filter { $0.unitID == anchor.unitID }, by: \.id)
        var localProject = project; localProject.units = [resolved.unit]
        guard let resolve = try? ReadingExperienceRuntime.anchorResolver(sourceHash: project.sourceHash,
            unitID: resolved.unit.id, in: localProject) else { return [] }
        var ranges: [String: NSRange] = [:], invalid = Set<String>()
        var result: [ReadingLayer] = []
        // Saved layers are append ordered, unlike their arbitrary UUIDs. Keep
        // the most recently saved exact explanations nearest the sentence.
        for layer in state.layers.reversed() {
            guard !Task.isCancelled else { return [] }
            guard layer.kind != "translation", layer.sourceAnchorIDs.count == 1,
                  !layer.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let id = layer.sourceAnchorIDs.first, !invalid.contains(id),
                  let candidates = anchors[id], candidates.count == 1, let stored = candidates.first else { continue }
            let range: NSRange
            if let cached = ranges[id] { range = cached }
            else {
                guard let verified = try? resolve(stored), !boundaries.crossesStructuralBoundary(verified.range) else {
                    invalid.insert(id); continue
                }
                range = verified.range; ranges[id] = range
            }
            // Equal verified range, not containment/intersection or quotation
            // text alone: repeated sentences have distinct source identities.
            guard range == resolved.range else { continue }
            result.append(layer)
            if result.count == maximumCount { break }
        }
        return result
    }
}
