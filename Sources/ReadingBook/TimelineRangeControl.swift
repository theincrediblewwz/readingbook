import SwiftUI
import ReadingCore

/// One time axis, two independent endpoints. Event dots share that same axis.
struct TimelineRangeControl: View {
    @Binding var lower: Double
    @Binding var upper: Double
    let bounds: ClosedRange<Double>
    let events: [KnowledgeEvent]
    let selectedID: String?
    let select: (String) -> Void
    @State private var dragging: Endpoint?
    @State private var dragOrigin: Double?
    @FocusState private var focused: Endpoint?
    private enum Endpoint: Hashable { case lower, upper }
    private let inset: CGFloat = 12
    private let axisY: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - inset * 2)
            let startX = x(lower, width: width), endX = x(upper, width: width)
            ZStack(alignment: .topLeading) {
                Capsule().fill(Palette.line).frame(width: width, height: 3).offset(x: inset, y: axisY - 1.5)
                Capsule().fill(Palette.accent.opacity(0.7)).frame(width: max(2, endX - startX), height: 4).offset(x: startX, y: axisY - 2)
                // Draw all ticks cheaply; only the focused/selected event needs a label.
                Canvas { context, _ in
                    for event in events {
                        guard let year = event.startYear else { continue }
                        let point = CGPoint(x: x(Double(year), width: width), y: axisY)
                        let selected = event.id == selectedID
                        let dot = CGRect(x: point.x - (selected ? 4 : 2), y: point.y - (selected ? 4 : 2), width: selected ? 8 : 4, height: selected ? 8 : 4)
                        context.fill(Path(ellipseIn: dot), with: .color(selected ? Palette.copper : Palette.ink.opacity(0.45)))
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
                Color.clear.contentShape(Rectangle()).frame(width: geometry.size.width, height: 44)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if dragging == nil {
                            let left = abs(value.startLocation.x - startX), right = abs(value.startLocation.x - endX)
                            if abs(startX - endX) < 18 {
                                let middle = (startX + endX) / 2
                                if value.startLocation.x < middle - 13 { dragging = .lower }
                                else if value.startLocation.x > middle + 13 { dragging = .upper }
                                else { dragging = value.startLocation.y <= axisY ? .lower : .upper }
                            } else { dragging = left < right ? .lower : .upper }
                        }
                        if let dragging, abs(value.translation.width) > 3 {
                            set(dragging, to: self.value(at: value.location.x, width: width))
                        }
                    }.onEnded { value in
                        if abs(value.translation.width) <= 3,
                           let event = events.filter({ $0.startYear != nil }).min(by: { abs(x(Double($0.startYear!), width: width) - value.location.x) < abs(x(Double($1.startYear!), width: width) - value.location.x) }),
                           abs(x(Double(event.startYear!), width: width) - value.location.x) <= 8 {
                            select(event.id)
                        } else if let dragging { set(dragging, to: self.value(at: value.location.x, width: width)) }
                        dragging = nil; dragOrigin = nil
                    })
                thumb(.lower, at: startX, width: width, crowded: abs(startX - endX) < 18)
                thumb(.upper, at: endX, width: width, crowded: abs(startX - endX) < 18)
                HStack {
                    Text(Self.yearLabel(Int(bounds.lowerBound)))
                    Spacer()
                    Text(Self.yearLabel(Int(bounds.upperBound)))
                }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary).padding(.horizontal, inset).offset(y: 45)
            }.coordinateSpace(name: "time-range-axis")
        }.frame(height: 60)
    }

    private func thumb(_ endpoint: Endpoint, at position: CGFloat, width: CGFloat, crowded: Bool) -> some View {
        let isLower = endpoint == .lower
        let current = isLower ? lower : upper
        let y = crowded ? axisY + (isLower ? -8 : 8) : axisY
        return Circle().fill(Palette.surface)
            .overlay(Circle().stroke(focused == endpoint || dragging == endpoint ? Palette.copper : Palette.accent, lineWidth: 2))
            .frame(width: 14, height: 14).padding(6).contentShape(TimelineThumbHit(isLower: isLower, crowded: crowded))
            .focusable().focused($focused, equals: endpoint)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { set(endpoint, to: current - 1); return .handled }
            .onKeyPress(.rightArrow) { set(endpoint, to: current + 1); return .handled }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("time-range-axis")).onChanged { value in
                if dragging != endpoint || dragOrigin == nil { dragOrigin = current; dragging = endpoint }
                let delta = Double(value.translation.width / max(1, width)) * (bounds.upperBound - bounds.lowerBound)
                set(endpoint, to: (dragOrigin ?? current) + delta)
            }.onEnded { _ in dragging = nil; dragOrigin = nil })
            .help("\(isLower ? "起点" : "终点")：\(Self.yearLabel(Int(current)))；可拖动或使用方向键")
            .accessibilityRepresentation {
                Slider(value: Binding(get: { current }, set: { set(endpoint, to: $0) }), in: bounds, step: 1) {
                    Text(isLower ? "时间范围起点" : "时间范围终点")
                }.accessibilityValue(Self.yearLabel(Int(current)))
            }.position(x: position, y: y)
    }

    private func x(_ value: Double, width: CGFloat) -> CGFloat {
        let span = max(1, bounds.upperBound - bounds.lowerBound)
        return inset + CGFloat(min(1, max(0, (value - bounds.lowerBound) / span))) * width
    }
    private func value(at position: CGFloat, width: CGFloat) -> Double {
        let fraction = Double(min(1, max(0, (position - inset) / max(1, width))))
        return (bounds.lowerBound + fraction * (bounds.upperBound - bounds.lowerBound)).rounded()
    }
    private func set(_ endpoint: Endpoint, to value: Double) {
        let value = min(bounds.upperBound, max(bounds.lowerBound, value.rounded()))
        if endpoint == .lower { lower = min(value, upper) } else { upper = max(value, lower) }
    }
    static func yearLabel(_ year: Int) -> String { year < 0 ? "公元前\(-year)年" : "\(year)年" }
}

/// When endpoints share a year their hit areas meet at the axis without
/// overlapping; a press on the upper/lower visible knob keeps that endpoint.
private struct TimelineThumbHit: Shape {
    let isLower: Bool
    let crowded: Bool
    func path(in rect: CGRect) -> Path {
        guard crowded else { return Path(rect) }
        return Path(CGRect(x: rect.minX, y: rect.minY + (isLower ? 0 : 5), width: rect.width, height: max(0, rect.height - 5)))
    }
}
