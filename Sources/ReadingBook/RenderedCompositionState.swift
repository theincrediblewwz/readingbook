import ReadingCore

/// Renderer-owned, transient, and deliberately not @Published: observing the
/// UI must not recursively render it or write a new project revision.
struct RenderedCompositionState {
    let contextID: String
    let selectedIDs: [String]
    let maps: [ReadingMapViewport]
    let clocks: [ReadingViewTimeWindow]
    var observationStatus: ReadingWorkspaceObservationStatus = .ready
}
