import Foundation

/// Transient intent only: a cancelled dwell never authorizes a later sentence.
/// The caller waits one second, then consumes the exact ticket before requesting.
public struct ReadingHoverTranslationDwell: Sendable {
    public struct Ticket: Hashable, Sendable {
        public let key: String
        fileprivate let generation: UInt
    }
    public private(set) var pending: Ticket?
    private var key: String?
    private var generation: UInt = 0
    private var consumed = false
    public init() {}

    @discardableResult public mutating func update(key: String, enabled: Bool, active: Bool) -> Ticket? {
        if self.key != key {
            generation &+= 1; self.key = key; pending = nil; consumed = false
        }
        guard enabled, active else {
            if pending != nil { generation &+= 1; pending = nil }
            return nil
        }
        guard !consumed else { return nil }
        if pending == nil {
            generation &+= 1; pending = Ticket(key: key, generation: generation)
        }
        return pending
    }
    public mutating func consume(_ ticket: Ticket) -> Bool {
        guard pending == ticket else { return false }
        pending = nil; consumed = true
        return true
    }
    /// An explicit translate/stop/tab choice takes precedence over the timer.
    public mutating func suppress(key: String) {
        self.key = key; generation &+= 1; pending = nil; consumed = true
    }
}
