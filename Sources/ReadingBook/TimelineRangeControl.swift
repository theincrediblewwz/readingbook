import SwiftUI
import AppKit
import ReadingCore

/// One time axis, two independent endpoints. Event dots share that same axis.
struct TimelineRangeControl: View {
    @Binding var lower: Double
    @Binding var upper: Double
    let bounds: ClosedRange<Double>
    let events: [KnowledgeEvent]
    let selectedID: String?
    let select: (String) -> Void
    var cursor: Binding<Double>? = nil
    var label: (Double) -> String = { TimelineRangeControl.yearLabel(Int($0)) }
    @State private var cursorOrigin: Double?
    @State private var cursorMapping: AxisMapping?
    @State private var interaction: DragSnapshot?
    @State private var pointerEpoch = 0
    @FocusState private var focused: Endpoint?
    private enum Endpoint: Hashable { case lower, upper }
    private let inset: CGFloat = 22
    private let axisY: CGFloat = 22

    private struct AxisMapping: Equatable {
        let bounds: ClosedRange<Double>
        let width: CGFloat
        var span: Double { bounds.upperBound - bounds.lowerBound }
        func x(_ value: Double) -> CGFloat {
            22 + CGFloat(min(1, max(0, (value - bounds.lowerBound) / max(1, span)))) * width
        }
        func year(at position: CGFloat) -> Double {
            let fraction = Double(min(1, max(0, (position - 22) / max(1, width))))
            return (bounds.lowerBound + fraction * span).rounded()
        }
    }
    private struct DragSnapshot {
        let endpoint: Endpoint
        let originYear: Double
        let startX: CGFloat
        let mapping: AxisMapping
        let onThumb: Bool
        let eventID: String?
        var didAdjust = false
    }

    var body: some View {
        GeometryReader { geometry in
            let mapping = AxisMapping(bounds: bounds, width: max(1, geometry.size.width - inset * 2))
            let startX = mapping.x(lower), endX = mapping.x(upper)
            ZStack(alignment: .topLeading) {
                Capsule().fill(Palette.line).frame(width: mapping.width, height: 3).offset(x: inset, y: axisY - 1.5)
                Capsule().fill(Palette.accent.opacity(0.7)).frame(width: max(2, endX - startX), height: 4).offset(x: startX, y: axisY - 2)
                // Draw all ticks cheaply; only the focused/selected event needs a label.
                Canvas { context, _ in
                    for index in 0...4 {
                        let x = inset + mapping.width * CGFloat(index) / 4
                        var tick = Path(); tick.move(to: CGPoint(x: x, y: axisY - 5)); tick.addLine(to: CGPoint(x: x, y: axisY + 7))
                        context.stroke(tick, with: .color(Palette.ink.opacity(0.27)), lineWidth: 1)
                    }
                    for event in events {
                        guard let year = event.startYear else { continue }
                        let point = CGPoint(x: mapping.x(Double(year)), y: axisY)
                        let selected = event.id == selectedID
                        let dot = CGRect(x: point.x - (selected ? 4 : 2), y: point.y - (selected ? 4 : 2), width: selected ? 8 : 4, height: selected ? 8 : 4)
                        context.fill(Path(ellipseIn: dot), with: .color(selected ? Palette.copper : Palette.ink.opacity(0.45)))
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
                thumb(.lower, at: startX, crowded: abs(startX - endX) < 24)
                thumb(.upper, at: endX, crowded: abs(startX - endX) < 24)
                ForEach(0...4, id: \.self) { index in
                    let year = bounds.lowerBound + mapping.span * Double(index) / 4
                    Text(label(year.rounded()))
                        .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize().frame(width: 0, alignment: index == 0 ? .leading : index == 4 ? .trailing : .center)
                        .position(x: inset + mapping.width * CGFloat(index) / 4, y: 51)
                }
                if let cursor {
                    let x = mapping.x(cursor.wrappedValue)
                    let text = label(cursor.wrappedValue)
                    let labelWidth = min(max(44, ceil((text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)]).width) + 18), max(0, geometry.size.width))
                    let labelX = min(max(labelWidth / 2, x), max(labelWidth / 2, geometry.size.width - labelWidth / 2))
                    Rectangle().fill(Palette.copper).frame(width: 2, height: 37).offset(x: x - 1, y: axisY)
                        .allowsHitTesting(false)
                    Text(text).font(.system(size: 15, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
                        .padding(.horizontal, 9).padding(.vertical, 6).frame(width: labelWidth).background(Palette.surface, in: Capsule())
                        .overlay(Capsule().stroke(Palette.copper.opacity(0.6)))
                        .frame(height: 44).contentShape(Rectangle())
                        .overlay {
                            // Window-space movement remains stable while this
                            // capsule follows the cursor along the same axis.
                            GraphPointerBridge(enabled: true, movable: true, resetID: pointerEpoch,
                                click: { _ in }, drag: { delta, ended in
                                    moveCursor(cursor, by: delta.width, ended: ended, mapping: mapping)
                                }, cancel: { cursorOrigin = nil; cursorMapping = nil })
                        }
                        .accessibilityRepresentation {
                            Slider(value: cursor, in: lower...max(lower, upper), step: 1) { Text("当前时间") }
                                .accessibilityValue(label(cursor.wrappedValue))
                        }.help("拖动当前时间；人物卡、地图与关系同步更新")
                        .position(x: labelX, y: 79)
                }
            }
            .overlay(alignment: .topLeading) {
                TimelinePointerInput(epoch: pointerEpoch,
                                     begin: { begin(at: $0, mapping: mapping) },
                                     drag: { change(by: $0, ended: $1, mapping: mapping) },
                                     click: { finishClick(mapping: mapping) },
                                     cancel: { cancelInteraction() })
                    .frame(height: 44).accessibilityHidden(true)
                    .help("拖动两个端点调整时间范围，点击事件点定位；端点也可用方向键调整，Esc 结束拖动。")
            }
            .transaction { $0.animation = nil }
            .onChange(of: geometry.size.width) { _, _ in cancelInteraction(); cursorOrigin = nil }
        }.frame(height: cursor == nil ? 68 : 105)
            .onChange(of: bounds) { _, _ in cancelInteraction() }
            .onChange(of: focused) { _, next in
                if let interaction, next != interaction.endpoint { cancelInteraction() }
            }
            .onExitCommand { cancelInteraction() }
            .onDisappear { cancelInteraction(); focused = nil }
    }

    private func thumb(_ endpoint: Endpoint, at position: CGFloat, crowded: Bool) -> some View {
        let isLower = endpoint == .lower
        let current = isLower ? lower : upper
        return Circle().fill(Palette.accent)
            .overlay(Circle().stroke(Palette.surface, lineWidth: 3))
            .overlay(Circle().stroke(focused == endpoint || interaction?.endpoint == endpoint ? Palette.copper : Palette.accent.opacity(0.55), lineWidth: 1))
            .shadow(color: Palette.accent.opacity(0.14), radius: 4, y: 1)
            .frame(width: 20, height: 20).padding(12).contentShape(TimelineThumbHit(isLower: isLower, crowded: crowded))
            .focusable().focused($focused, equals: endpoint)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { adjust(endpoint, by: -1); return .handled }
            .onKeyPress(.rightArrow) { adjust(endpoint, by: 1); return .handled }
            .help("\(isLower ? "起点" : "终点")：\(label(current))；可拖动或使用方向键")
            .accessibilityRepresentation {
                Slider(value: Binding(get: { endpoint == .lower ? lower : upper }, set: {
                    cancelInteraction(); set(endpoint, to: $0)
                }), in: bounds, step: 1) {
                    Text(isLower ? "时间范围起点" : "时间范围终点")
                }.accessibilityValue(label(current))
            }.position(x: position, y: thumbY(endpoint, crowded: crowded))
    }

    private func thumbY(_ endpoint: Endpoint, crowded: Bool) -> CGFloat {
        crowded ? axisY + (endpoint == .lower ? -8 : 8) : axisY
    }
    private func thumbRect(_ endpoint: Endpoint, at position: CGFloat, crowded: Bool) -> CGRect {
        let rect = CGRect(x: position - 22, y: thumbY(endpoint, crowded: crowded) - 22, width: 44, height: 44)
        return TimelineThumbHit.hitRect(in: rect, isLower: endpoint == .lower, crowded: crowded)
    }
    private func begin(at point: CGPoint, mapping: AxisMapping) {
        let startX = mapping.x(lower), endX = mapping.x(upper), crowded = abs(startX - endX) < 24
        let hitsLower = thumbRect(.lower, at: startX, crowded: crowded).contains(point)
        let hitsUpper = thumbRect(.upper, at: endX, crowded: crowded).contains(point)
        let endpoint: Endpoint
        if hitsLower && hitsUpper { endpoint = point.y <= axisY ? .lower : .upper }
        else if hitsLower { endpoint = .lower }
        else if hitsUpper { endpoint = .upper }
        else if crowded {
            let middle = (startX + endX) / 2
            if point.x < middle - 16 { endpoint = .lower }
            else if point.x > middle + 16 { endpoint = .upper }
            else { endpoint = point.y <= axisY ? .lower : .upper }
        } else { endpoint = abs(point.x - startX) < abs(point.x - endX) ? .lower : .upper }
        let nearest = events.compactMap { event -> (String, CGFloat)? in
            guard let year = event.startYear else { return nil }
            return (event.id, abs(mapping.x(Double(year)) - point.x))
        }.min { $0.1 < $1.1 }
        interaction = DragSnapshot(endpoint: endpoint, originYear: endpoint == .lower ? lower : upper,
                                   startX: point.x, mapping: mapping, onThumb: hitsLower || hitsUpper,
                                   eventID: nearest.flatMap { $0.1 <= 8 ? $0.0 : nil })
        focused = endpoint
    }
    private func change(by delta: CGSize, ended: Bool, mapping: AxisMapping) {
        guard var snapshot = interaction else { return }
        guard snapshot.mapping == mapping else { cancelInteraction(); return }
        // Width, date span and year origin belong to the mouse-down snapshot.
        // A moving thumb or a model update never becomes the next drag origin.
        if snapshot.didAdjust || abs(delta.width) > 3 {
            if !snapshot.didAdjust { snapshot.didAdjust = true; interaction = snapshot }
            let year = snapshot.onThumb
                ? snapshot.originYear + Double(delta.width / max(1, snapshot.mapping.width)) * snapshot.mapping.span
                : snapshot.mapping.year(at: snapshot.startX + delta.width)
            set(snapshot.endpoint, to: year)
        }
        if ended { interaction = nil }
    }
    private func finishClick(mapping: AxisMapping) {
        guard let snapshot = interaction else { return }
        guard snapshot.mapping == mapping else { cancelInteraction(); return }
        interaction = nil
        if snapshot.onThumb { return }
        if let eventID = snapshot.eventID {
            if events.contains(where: { $0.id == eventID }) { select(eventID) }
        } else { set(snapshot.endpoint, to: snapshot.mapping.year(at: snapshot.startX)) }
    }
    private func cancelInteraction() {
        // Keep the last displayed filter; only end ownership of this gesture.
        // Changing the epoch also drops AppKit's origin, so later events from
        // the same held mouse button cannot start another interaction.
        interaction = nil; cursorOrigin = nil; cursorMapping = nil; pointerEpoch &+= 1
    }
    private func adjust(_ endpoint: Endpoint, by delta: Double) {
        cancelInteraction(); set(endpoint, to: (endpoint == .lower ? lower : upper) + delta)
    }
    private func set(_ endpoint: Endpoint, to value: Double) {
        let value = min(bounds.upperBound, max(bounds.lowerBound, value.rounded()))
        // Rounded years/narrative positions often stay unchanged across many
        // pointer events. Avoid publishing an identical shared time snapshot.
        if endpoint == .lower {
            let next = min(value, upper); if lower != next { lower = next }
        } else {
            let next = max(value, lower); if upper != next { upper = next }
        }
    }
    private func moveCursor(_ cursor: Binding<Double>, by delta: CGFloat, ended: Bool, mapping: AxisMapping) {
        if cursorOrigin == nil { cursorOrigin = cursor.wrappedValue; cursorMapping = mapping }
        guard cursorMapping == mapping, let cursorOrigin else { cancelInteraction(); return }
        let year = cursorOrigin + Double(delta / max(1, mapping.width)) * mapping.span
        let next = min(upper, max(lower, year.rounded()))
        if cursor.wrappedValue != next { cursor.wrappedValue = next }
        if ended { self.cursorOrigin = nil; cursorMapping = nil }
    }
    static func yearLabel(_ year: Int) -> String { year < 0 ? "公元前\(-year)年" : "\(year)年" }
}

/// A single receiver owns a press across both moving thumbs and the track.
/// Geometry changes invalidate its epoch; Escape and loss of window focus drop
/// the native origin immediately, before another drag/up event can arrive.
private struct TimelinePointerInput: NSViewRepresentable {
    let epoch: Int
    let begin: (CGPoint) -> Void
    let drag: (CGSize, Bool) -> Void
    let click: () -> Void
    let cancel: () -> Void
    func makeNSView(context: Context) -> PointerView { PointerView() }
    func updateNSView(_ view: PointerView, context: Context) {
        view.begin = begin; view.drag = drag; view.click = click; view.cancel = cancel
        view.configure(epoch: epoch)
    }
    static func dismantleNSView(_ view: PointerView, coordinator: ()) { view.invalidate() }

    final class PointerView: NSView {
        var begin: ((CGPoint) -> Void)?
        var drag: ((CGSize, Bool) -> Void)?
        var click: (() -> Void)?
        var cancel: (() -> Void)?
        private var epoch: Int?
        private var origin: CGPoint?
        private var didDrag = false
        private var escapeMonitor: Any?
        private var windowObserver: NSObjectProtocol?
        private var appObserver: NSObjectProtocol?
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        func configure(epoch: Int) {
            if self.epoch != epoch { stopTracking(); self.epoch = epoch }
        }
        override func mouseDown(with event: NSEvent) {
            stopTracking(); origin = event.locationInWindow; didDrag = false
            begin?(convert(event.locationInWindow, from: nil))
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, self.origin != nil,
                      event.window == nil || event.window === self.window else { return event }
                self.cancelTracking(); return nil
            }
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            let delta = CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y)
            guard didDrag || hypot(delta.width, delta.height) >= 4 else { return }
            didDrag = true; drag?(delta, false)
        }
        override func mouseUp(with event: NSEvent) {
            guard let origin else { return }
            let delta = CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y)
            let endedDrag = didDrag || hypot(delta.width, delta.height) >= 4; stopTracking()
            if endedDrag { drag?(delta, true) } else { click?() }
        }
        private func stopTracking() {
            origin = nil; didDrag = false
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        }
        private func cancelTracking() {
            guard origin != nil else { return }
            stopTracking(); cancel?()
        }
        override func cancelOperation(_ sender: Any?) {
            if origin != nil { cancelTracking() } else { super.cancelOperation(sender) }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stopTracking(); removeObservers()
            guard let window else { return }
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.cancelTracking() } }
            appObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.cancelTracking() } }
        }
        private func removeObservers() {
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
            if let appObserver { NotificationCenter.default.removeObserver(appObserver); self.appObserver = nil }
        }
        func invalidate() { stopTracking(); removeObservers(); begin = nil; drag = nil; click = nil; cancel = nil }
        deinit {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
            if let appObserver { NotificationCenter.default.removeObserver(appObserver) }
        }
    }
}

/// Keep the native pointer classification and SwiftUI accessibility hit areas
/// identical when the endpoints share a year.
private struct TimelineThumbHit: Shape {
    let isLower: Bool
    let crowded: Bool
    static func hitRect(in rect: CGRect, isLower: Bool, crowded: Bool) -> CGRect {
        guard crowded else { return rect }
        return CGRect(x: rect.minX, y: rect.minY + (isLower ? 0 : 5), width: rect.width, height: max(0, rect.height - 5))
    }
    func path(in rect: CGRect) -> Path { Path(Self.hitRect(in: rect, isLower: isLower, crowded: crowded)) }
}
