import Foundation

/// Coalesces transient hover work without dropping the final pointer update.
/// Tickets schedule a fresh hit-test; they do not retain or authorize a source,
/// mouse position, window or decoration. The native host rechecks those at use.
public struct ReadingHoverRefresh: Sendable {
    public struct Ticket: Equatable, Sendable {
        public let deadline: TimeInterval
        fileprivate let generation: UInt
    }
    public private(set) var pending: Ticket?
    private var lastEvaluation: TimeInterval?
    private var generation: UInt = 0
    private let interval: TimeInterval = 1.0 / 30
    public init() {}

    @discardableResult public mutating func request(at now: TimeInterval, quietUntil: TimeInterval = 0) -> Ticket? {
        guard now.isFinite, quietUntil.isFinite else { cancel(); return nil }
        let earliest = max(quietUntil, lastEvaluation.map { $0 + interval } ?? pending?.deadline ?? now)
        // Keep the queued tail while input arrives. Only a later quiet-window
        // deadline can postpone it; continuous mouse movement cannot starve it.
        if let pending, pending.deadline >= earliest { return pending }
        generation &+= 1
        let ticket = Ticket(deadline: max(now, earliest), generation: generation)
        pending = ticket
        return ticket
    }

    public mutating func consume(_ ticket: Ticket, at now: TimeInterval, quietUntil: TimeInterval = 0) -> Bool {
        guard pending == ticket, now.isFinite, quietUntil.isFinite,
              now >= ticket.deadline, now >= quietUntil else { return false }
        pending = nil; lastEvaluation = now
        return true
    }

    public mutating func cancel() {
        generation &+= 1; pending = nil; lastEvaluation = nil
    }
}
