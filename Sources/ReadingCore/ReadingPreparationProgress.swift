import Foundation

/// Disposable preparation work, separate from AI generation and reading coverage.
/// Counts describe the current phase only; an unknown total is never a percentage.
public struct ReadingPreparationProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case sourceIndex, pageText, nativeLines, matching, geometry, companion, outline
    }

    public let phase: Phase
    public let page: Int?
    public let completed: Int?
    public let total: Int?

    public init(phase: Phase, page: Int? = nil, completed: Int? = nil, total: Int? = nil) {
        self.phase = phase
        self.page = page.flatMap { $0 > 0 ? $0 : nil }
        let safeTotal = total.map { max(0, $0) }
        self.total = safeTotal
        self.completed = completed.map { value in
            let safeCompleted = max(0, value)
            return safeTotal.map { min(safeCompleted, $0) } ?? safeCompleted
        }
    }

    public var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return Double(completed) / Double(total)
    }
}

/// Each producer owns a run ID. A consumer can discard late updates from an old run.
public enum ReadingPreparationEvent: Sendable, Equatable {
    case started(UUID, ReadingPreparationProgress)
    case advanced(UUID, ReadingPreparationProgress)
    case finished(UUID)
}
