import Foundation

/// Transient transport/tool telemetry only. No prompt, answer, reasoning text,
/// tool arguments, credentials, or document contents cross this boundary.
public enum AIProgressPhase: String, Equatable, Sendable {
    case preparing, waitingForResponse, receiving, reasoning, answering, receivingTools
    case requestCompleted, performingTool, toolCompleted, saving
}

public struct AIProgressEvent: Equatable, Sendable {
    public var phase: AIProgressPhase
    public var requestID: UUID?
    public var requestNumber: Int?
    public var reasoningCharacters: Int?
    public var answerCharacters: Int?
    public var receivedBytes: Int?
    public var toolName: String?
    public var toolIndex: Int?
    public var toolTotal: Int?
    public var toolSucceeded: Bool?
    public var toolStatus: String?
    public var toolSummary: String?

    public init(_ phase: AIProgressPhase, requestID: UUID? = nil, requestNumber: Int? = nil,
                reasoningCharacters: Int? = nil, answerCharacters: Int? = nil, receivedBytes: Int? = nil,
                toolName: String? = nil, toolIndex: Int? = nil, toolTotal: Int? = nil, toolSucceeded: Bool? = nil, toolStatus: String? = nil, toolSummary: String? = nil) {
        self.phase = phase; self.requestID = requestID; self.requestNumber = requestNumber
        self.reasoningCharacters = reasoningCharacters; self.answerCharacters = answerCharacters; self.receivedBytes = receivedBytes
        self.toolName = toolName.map { String($0.prefix(80)) }; self.toolIndex = toolIndex; self.toolTotal = toolTotal
        self.toolSucceeded = toolSucceeded
        self.toolSummary = toolSummary.map { String($0.prefix(1200)) }
        self.toolStatus = toolStatus.flatMap { ["success", "failed", "needs_confirmation", "busy", "unsupported"].contains($0) ? $0 : nil }
    }
}

public typealias AIProgressHandler = @Sendable (AIProgressEvent) -> Void

struct ProviderStreamSnapshot: Equatable, Sendable {
    var phase: AIProgressPhase = .receiving
    var reasoningCharacters = 0
    var answerCharacters = 0
    var receivedBytes = 0
}

/// A serial URLSession delegate invokes this at most ten times a second, plus
/// real phase boundaries and the final count. Counts are Unicode scalars, not
/// provider tokens; UTF-8 bytes split across network chunks are parsed first.
final class ProviderProgressReporter: @unchecked Sendable {
    private let handler: @Sendable (ProviderStreamSnapshot) -> Void
    private let lock = NSLock()
    private var last: ProviderStreamSnapshot?
    private var lastTime: TimeInterval = 0
    private var seenPhases = Set<String>()
    private var stopped = false
    init(_ handler: @escaping @Sendable (ProviderStreamSnapshot) -> Void) { self.handler = handler }
    func emit(_ value: ProviderStreamSnapshot, force: Bool = false) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        guard !stopped, force || !seenPhases.contains(value.phase.rawValue) || now - lastTime >= 0.1 else { lock.unlock(); return }
        guard force || last != value else { lock.unlock(); return }
        last = value; lastTime = now; seenPhases.insert(value.phase.rawValue)
        lock.unlock()
        handler(value)
    }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}
