/// Platform-independent ownership for one wheel or magnification stream.
/// Inertia must retain the decision made at the beginning of the gesture; a
/// gesture that started over a panel can never become a canvas pan mid-flight.
public enum CanvasGesturePhase: Equatable, Sendable {
    case none, mayBegin, began, changed, ended, cancelled
}

public struct CanvasGestureOwnership: Sendable {
    private var accepted: Bool? = nil
    public init() {}

    public mutating func accepts(phase: CanvasGesturePhase, momentum: CanvasGesturePhase = .none,
                                isEligible: Bool) -> Bool {
        if phase == .cancelled || momentum == .cancelled { reset(); return false }
        if phase == .none && momentum == .none {
            // A conventional mouse wheel has no gesture lifecycle.
            reset(); return isEligible
        }
        if phase == .began || phase == .mayBegin { accepted = isEligible }
        // Never adopt a gesture whose beginning was not observed by this view.
        if accepted == nil { accepted = false }
        // Showing a panel or leaving this canvas revokes the entire remaining
        // stream, even if the pointer returns before the momentum finishes.
        if !isEligible { accepted = false }
        let result = accepted == true
        if momentum == .ended { reset() }
        return result
    }
    public mutating func reset() { accepted = nil }
}
