import Foundation

/// Stable date-order coordinates in the named source calendar. Day positions
/// are ordinal keys, not Gregorian conversions or a claim of elapsed days.
public struct TemporalAxis: Hashable, Sendable {
    public let id: String
    public init(_ id: String) { self.id = id }
    public var calendar: String? {
        if id.hasPrefix("calendar-day:") { return String(id.dropFirst(13)) }
        if id.hasPrefix("calendar:") { return String(id.dropFirst(9)) }
        return nil
    }
    public var isDateOrder: Bool { id.hasPrefix("calendar-day:") }
    public var narrativeDomain: String? {
        guard id.hasPrefix("narrative-domain:") else { return nil }
        let value = String(id.dropFirst(17))
        return !value.isEmpty && value.count <= 80 && !value.contains("\0") ? value : nil
    }
    public var isNarrative: Bool { id == "narrative" || narrativeDomain != nil }
    public var title: String {
        if let domain = narrativeDomain { return domain == "source-order" ? "原文顺序" : domain + " · 叙事顺序" }
        return id == "narrative" ? "叙事顺序" : (calendar ?? id) + (isDateOrder ? " · 月日" : " · 年份")
    }
    public static func available(_ extents: [TemporalExtent]) -> [String] {
        var ids = Set<String>()
        for extent in extents {
            if extent.narrativeStart != nil { ids.insert(extent.narrativeDomain.map { "narrative-domain:" + $0 } ?? "narrative") }
            if let calendar = extent.calendar, extent.start != nil || extent.end != nil {
                ids.insert("calendar:" + calendar)
                if extent.start?.month != nil || extent.end?.month != nil { ids.insert("calendar-day:" + calendar) }
            }
        }
        return ids.sorted()
    }
    /// Prefer the scale covering the most records; retain calendar preference
    /// on ties. A record's alternative source position counts only once.
    public static func preferred(for records: [[TemporalExtent]]) -> String? {
        let axes = available(records.flatMap { $0 })
        let ranked = axes.enumerated().map { entry in
            (id: entry.element, index: entry.offset, count: records.filter { row in row.contains { TemporalAxis(entry.element).value($0) != nil } }.count)
        }
        return ranked.max { lhs, rhs in lhs.count == rhs.count ? lhs.index > rhs.index : lhs.count < rhs.count }?.id
    }
    public func value(_ extent: TemporalExtent?, end: Bool = false) -> Double? {
        guard let extent else { return nil }
        if isNarrative {
            guard extent.narrativeDomain == narrativeDomain else { return nil }
            return (end ? extent.narrativeEnd ?? extent.narrativeStart : extent.narrativeStart).map(Double.init)
        }
        guard calendar == extent.calendar, calendar?.isEmpty == false, let date = end ? extent.end ?? extent.start : extent.start ?? extent.end else { return nil }
        if !isDateOrder { return Double(date.year) }
        return Double(date.year) * 8192 + Double((date.month ?? (end ? 64 : 1)) - 1) * 128 + Double((date.day ?? (end ? 128 : 1)) - 1)
    }
    public func date(_ value: Double) -> TemporalDate? {
        guard calendar?.isEmpty == false, value.isFinite else { return nil }
        if !isDateOrder {
            guard abs(value) <= 1_000_000_000_000 else { return nil }
            return .init(year: Int(value))
        }
        guard value >= -8_192_000_000_000_000, value <= 8_192_000_000_008_191 else { return nil }
        let year = floor(value / 8192), remainder = Int(value - year * 8192)
        let date = TemporalDate(year: Int(year), month: remainder / 128 + 1, day: remainder % 128 + 1)
        let extent = TemporalExtent(sourceText: "时间轴", calendar: calendar, start: date, precision: .day, uncertainty: .exact)
        guard (try? TemporalKnowledgeRuntime.validateExtent(extent)) != nil else { return nil }; return date
    }
    public func point(_ value: Double) -> TemporalQueryPoint? {
        if let domain = narrativeDomain { return value.isFinite && (0...1_000_000_000).contains(value) ? .ordered(Int(value), domain: domain) : nil }
        if id == "narrative" { return value.isFinite && (0...1_000_000_000).contains(value) ? .narrative(Int(value)) : nil }
        guard let calendar, let date = date(value) else { return nil }; return .date(date, calendar: calendar)
    }
    public func window(from: Double, to: Double) -> TemporalQueryWindow? {
        guard from.isFinite, to.isFinite, from <= to else { return nil }
        if let domain = narrativeDomain, from >= 0, to <= 1_000_000_000 { return .ordered(from: Int(from), to: Int(to), domain: domain) }
        if id == "narrative", from >= 0, to <= 1_000_000_000 { return .narrative(from: Int(from), to: Int(to)) }
        guard let calendar, let start = date(from), let end = date(to) else { return nil }
        return .date(from: start, to: end, calendar: calendar)
    }
    /// UI drags choose existing source milestones, avoiding invented dates in
    /// gaps between months or in an unfamiliar calendar. Typed dates stay exact.
    public func snapped(_ proposed: Double, among extents: [TemporalExtent]) -> Double {
        guard isDateOrder else { return proposed }
        let values = extents.flatMap { [value($0), value($0, end: true)].compactMap { $0 } }.filter { date($0) != nil }
        return values.min { abs($0-proposed) < abs($1-proposed) } ?? proposed
    }
    public func input(_ value: Double) -> String {
        guard isDateOrder, let date = date(value) else { return value.isFinite && abs(value) <= 1_000_000_000_000 ? String(Int(value)) : "" }
        return "\(date.year)/\(date.month ?? 1)/\(date.day ?? 1)"
    }
    public func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        if !isDateOrder { guard parts.count == 1, let value = Double(parts[0]), point(value) != nil else { return nil }; return value }
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        let extent = TemporalExtent(sourceText: "时间轴", calendar: calendar, start: .init(year: year, month: month, day: day), precision: .day, uncertainty: .exact)
        guard (try? TemporalKnowledgeRuntime.validateExtent(extent)) != nil else { return nil }
        return value(extent)
    }
    public func label(_ value: Double) -> String {
        if isNarrative { return value.isFinite && (0...1_000_000_000).contains(value) ? (narrativeDomain == "source-order" ? "原文位置 " : "叙事 ") + String(Int(value)) : "时间待定" }
        guard let date = date(value) else { return "时间待定" }
        return "\(date.year)年" + (date.month.map { "\($0)月" } ?? "") + (date.day.map { "\($0)日" } ?? "")
    }
}
