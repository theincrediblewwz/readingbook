/// Reading layout and direction are independent. This value also backs the
/// optional per-book direction in disposable workspace memory.
public enum PDFReadingDirection: String, Codable, CaseIterable, Sendable {
    case vertical, horizontal
}

/// Owns only page turns, not page rendering or ordinary scrolling. A precise
/// gesture must start at the page boundary before it may turn a page. Reaching
/// the boundary while scrolling a magnified page requires a fresh gesture.
public struct PDFPageTurnPolicy: Sendable {
    public enum Action: Equatable, Sendable { case scroll, consume, turn(Int) }
    private var active = false
    private var turned = false
    private var decided = false
    private var armedDirection = 0
    private var accumulated = 0.0
    private var lastWheelTime: Double?
    public init() {}

    public mutating func reset() {
        active = false; turned = false; decided = false
        armedDirection = 0; accumulated = 0; lastWheelTime = nil
    }

    /// Positive delta means next page, after the platform has resolved the
    /// user's natural scrolling preference. Momentum can never start a turn.
    public mutating func action(delta: Double, crossDelta: Double = 0,
                                precise: Bool, phase: CanvasGesturePhase,
                                momentum: CanvasGesturePhase = .none,
                                timestamp: Double,
                                atStart: Bool, atEnd: Bool) -> Action {
        guard delta.isFinite, crossDelta.isFinite, timestamp.isFinite else { reset(); return .scroll }
        if phase == .cancelled || momentum == .cancelled {
            let consume = turned; reset(); return consume ? .consume : .scroll
        }
        if momentum != .none {
            // Keep swallowing the tail after a turn, including its last event.
            let boundary = delta > 0 ? atEnd : atStart
            let consume = turned || (abs(delta) > 0.001 && abs(delta) >= abs(crossDelta) * 1.1 && boundary)
            if momentum == .ended { reset() }
            return consume ? .consume : .scroll
        }
        let wheel = phase == .none
        if wheel {
            if lastWheelTime == nil || timestamp - (lastWheelTime ?? timestamp) > 0.35 || timestamp < (lastWheelTime ?? timestamp) {
                active = true; turned = false; decided = false; armedDirection = 0; accumulated = 0
            }
            lastWheelTime = timestamp
        } else if phase == .began || phase == .mayBegin {
            active = true; turned = false; decided = false; armedDirection = 0; accumulated = 0; lastWheelTime = nil
        }
        if phase == .mayBegin { return .scroll }
        if turned { return .consume }
        if phase == .ended { active = false; return .scroll }
        // Never adopt a stream whose beginning belongs to another control.
        guard active else { return .scroll }
        let direction = delta > 0 ? 1 : -1
        let boundary = direction > 0 ? atEnd : atStart
        let primary = abs(delta) >= abs(crossDelta) * 1.1
        if !decided, abs(delta) > 0.001 || abs(crossDelta) > 0.001 {
            decided = true
            armedDirection = primary && boundary ? direction : 0
        }
        guard abs(delta) > 0.001 else { return .scroll }
        guard primary, decided, direction == armedDirection, boundary else {
            // PDFKit must not do its own page turn at a boundary, even if this
            // gesture started inside the page or reversed before reaching it.
            return primary && boundary ? .consume : .scroll
        }
        accumulated += abs(delta)
        guard accumulated >= (precise ? 24 : 2) else { return .consume }
        turned = true
        return .turn(direction)
    }
}
