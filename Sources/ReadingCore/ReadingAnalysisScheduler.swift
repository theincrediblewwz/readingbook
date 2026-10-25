import Foundation

/// Scheduling never changes source order, chunk identity, or completion. It
/// only chooses among jobs whose chapter/book dependencies are already met.
public enum ReadingAnalysisScheduler {
    public static func nextReadyChunk(in chunks: [ReadingAnalysisChunk], completed: Set<String>, running: Set<String>,
                                      steps: [ReadingExecutionStep], chapters: [String: String],
                                      currentUnitID: String?, dispatchCount: Int) -> ReadingAnalysisChunk? {
        let frequencies = Dictionary(steps.map { ($0.id, $0.frequency) }, uniquingKeysWith: { _, last in last })
        var firstIncomplete: Int?
        var firstIncompleteByChapter: [String: Int] = [:]
        for (index, chunk) in chunks.enumerated() where !completed.contains(chunk.id) {
            if firstIncomplete == nil { firstIncomplete = index }
            for unitID in chunk.unitIDs {
                let chapter = chapters[unitID] ?? ""
                if firstIncompleteByChapter[chapter] == nil { firstIncompleteByChapter[chapter] = index }
            }
        }
        let ready = chunks.enumerated().filter { index, chunk in
            guard !completed.contains(chunk.id), !running.contains(chunk.id) else { return false }
            let actions = chunk.stepIDs.compactMap { frequencies[$0] }
            if actions.contains(.book), let firstIncomplete, firstIncomplete < index { return false }
            if actions.contains(.chapter) {
                let own = Set(chunk.unitIDs.compactMap { chapters[$0] })
                if own.contains(where: { (firstIncompleteByChapter[$0] ?? index) < index }) { return false }
            }
            return true
        }
        guard let oldest = ready.first else { return nil }
        // Every fourth dispatch makes forward progress from the oldest job,
        // even if the reader keeps moving to new pages while analysis runs.
        if dispatchCount % 4 == 3 { return oldest.element }
        guard let currentUnitID, let target = chunks.firstIndex(where: { $0.unitIDs.contains(currentUnitID) }) else { return oldest.element }
        return ready.min { left, right in
            let leftDistance = abs(left.offset - target), rightDistance = abs(right.offset - target)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            // At equal distance prefer the next part of the reader's page.
            if (left.offset >= target) != (right.offset >= target) { return left.offset >= target }
            return left.offset < right.offset
        }?.element
    }
}
