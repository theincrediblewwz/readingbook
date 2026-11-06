import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A small start-to-start gap, shared across all features/keys for one service.
/// This is an app policy, not a provider quota. No request is retried here.
actor ProviderRequestPacer {
    static let shared = ProviderRequestPacer()

    struct Clock: Sendable {
        let now: @Sendable () -> TimeInterval
        let sleep: @Sendable (TimeInterval) async throws -> Void
        static let continuous = Clock(now: { ProcessInfo.processInfo.systemUptime }, sleep: { seconds in
            try await Task.sleep(nanoseconds: UInt64(min(60, max(0, seconds)) * 1_000_000_000))
        })
    }

    /// Retains only validated timing hints, never URLs, credentials or bodies.
    struct ResponseHint: Sendable {
        let id = UUID()
        let receivedAt: TimeInterval
        let status: Int
        let retryDelay: TimeInterval?
        let exhaustedFor: TimeInterval?

        init(_ response: HTTPURLResponse, receivedAt: TimeInterval, date: Date = Date()) {
            self.receivedAt = receivedAt; status = response.statusCode
            retryDelay = Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), date: date)
            let windows = [("requests", "requests"), ("tokens", "tokens"), ("project-tokens", "project-tokens")]
            exhaustedFor = windows.compactMap { remaining, reset -> TimeInterval? in
                guard let value = response.value(forHTTPHeaderField: "x-ratelimit-remaining-" + remaining),
                      value.trimmingCharacters(in: .whitespaces) == "0" else { return nil }
                return Self.duration(response.value(forHTTPHeaderField: "x-ratelimit-reset-" + reset))
            }.max()
        }

        static func retryAfter(_ raw: String?, date: Date) -> TimeInterval? {
            guard let raw, raw.utf8.count <= 64 else { return nil }
            let value = raw.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let seconds = Int(value), seconds >= 0 {
                return TimeInterval(seconds)
            }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            formatter.isLenient = false
            return formatter.date(from: value).map { max(0, $0.timeIntervalSince(date)) }
        }

        /// OpenAI reset hints can be composite durations, e.g. 6m0s or 250ms.
        static func duration(_ raw: String?) -> TimeInterval? {
            guard let raw, !raw.isEmpty, raw.utf8.count <= 64,
                  let expression = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)(ms|s|m|h|d)"#) else { return nil }
            let matches = expression.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
            var end = 0, seconds: Double = 0
            for match in matches {
                guard match.range.location == end, let n = Range(match.range(at: 1), in: raw),
                      let u = Range(match.range(at: 2), in: raw), let value = Double(raw[n]) else { return nil }
                let factor = ["ms": 0.001, "s": 1.0, "m": 60.0, "h": 3600.0, "d": 86400.0][String(raw[u])]!
                seconds += value * factor; end = NSMaxRange(match.range)
            }
            guard end == raw.utf16.count, end > 0, seconds.isFinite else { return nil }
            return seconds
        }
    }

    struct State {
        var lastStart: TimeInterval?
        var blockedUntil: TimeInterval = 0
        var consecutiveFailures = 0
        var lastHealthReceipt: TimeInterval = -1
        var observed: [UUID] = []

        func delay(at now: TimeInterval, interval: TimeInterval) -> TimeInterval {
            max(0, max(blockedUntil, lastStart.map { $0 + interval } ?? now) - now)
        }
        mutating func observe(_ hint: ResponseHint, failure: ProviderHTTPFailure?, jitter: TimeInterval) {
            guard !observed.contains(hint.id) else { return }
            observed.append(hint.id); observed = Array(observed.suffix(32))
            if (200...299).contains(hint.status) {
                if hint.receivedAt >= lastHealthReceipt { consecutiveFailures = 0; lastHealthReceipt = hint.receivedAt }
                if let reset = hint.exhaustedFor { blockedUntil = max(blockedUntil, hint.receivedAt + reset) }
            } else if failure?.reason == .rateLimited || failure?.reason == .overloaded || hint.status == 503 {
                if hint.receivedAt >= lastHealthReceipt {
                    consecutiveFailures = min(6, consecutiveFailures + 1); lastHealthReceipt = hint.receivedAt
                }
                let fallback = min(60, pow(2, Double(max(1, consecutiveFailures))))
                let delay = max(hint.retryDelay ?? fallback, hint.exhaustedFor ?? 0) + min(0.5, max(0, jitter))
                blockedUntil = max(blockedUntil, hint.receivedAt + delay)
            }
        }
    }

    private var states: [String: State] = [:]
    private let interval: TimeInterval
    private nonisolated let clock: Clock
    private let jitter: @Sendable () -> TimeInterval

    init(minimumInterval: TimeInterval = 1, clock: Clock = .continuous,
         jitter: @escaping @Sendable () -> TimeInterval = { Double.random(in: 0.1...0.3) }) {
        interval = max(0, minimumInterval); self.clock = clock; self.jitter = jitter
    }

    // Host-level grouping is deliberately conservative: several profiles/keys
    // can belong to the same provider account. No credential is a dictionary key.
    nonisolated static func serviceKey(_ url: URL) -> String {
        (url.scheme?.lowercased() ?? "") + "://" + (url.host?.lowercased() ?? "") + ":" + String(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))
    }
    nonisolated func hint(for response: HTTPURLResponse) -> ResponseHint { .init(response, receivedAt: clock.now()) }

    func acquire(for url: URL) async throws {
        let key = Self.serviceKey(url)
        while true {
            try Task.checkCancellation()
            let now = clock.now()
            var state = states[key] ?? State()
            let delay = state.delay(at: now, interval: interval)
            if delay <= 0 {
                state.lastStart = now; states[key] = state
                return
            }
            // No future slot is reserved. Cancelling a queued request therefore
            // cannot leave phantom gaps; every wake rechecks newer server hints.
            try await clock.sleep(min(60, delay))
        }
    }

    func observe(_ hint: ResponseHint, for url: URL, failure: ProviderHTTPFailure? = nil) {
        let key = Self.serviceKey(url)
        var state = states[key] ?? State()
        state.observe(hint, failure: failure, jitter: jitter()); states[key] = state
    }
}

/// URLSession callbacks are synchronous. Copy only the sanitized timing value
/// across them so transport completion can apply the same hint exactly once.
final class ProviderTimingReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ProviderRequestPacer.ResponseHint?
    func set(_ hint: ProviderRequestPacer.ResponseHint) { lock.lock(); value = hint; lock.unlock() }
    func get() -> ProviderRequestPacer.ResponseHint? { lock.lock(); defer { lock.unlock() }; return value }
}
