import Foundation
import CoreFoundation

/// Model-facing dates stay dates. Internal ordinal coordinates are calculated
/// by the same axis used by the map/timeline, never guessed by the model.
public struct TemporalViewWindow: Equatable, Sendable {
    public let axis: String
    public let from: Double
    public let to: Double
    public let cursor: Double
    public init(arguments: Data, availableAxes: [String]) throws {
        guard let args = try JSONSerialization.jsonObject(with: arguments) as? [String: Any], let at = args["at"] as? [String: Any] else { throw ReadingError.invalid("请提供时间体系和当前时间at。") }
        func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        func integer(_ value: Any?) -> Int? {
            guard let value = number(value), value.rounded() == value, abs(value) <= 1_000_000_000_000 else { return nil }; return Int(value)
        }
        let selected: String
        if let order = integer(at["narrativeOrder"]), (0...1_000_000_000).contains(order) {
            guard Set(at.keys).isSubset(of: ["narrativeOrder", "narrativeDomain"]) else { throw ReadingError.invalid("叙事顺序不能混入日期。") }
            if let raw = at["narrativeDomain"] {
                guard let domain = raw as? String, !domain.isEmpty, domain.utf8.count <= 80, !domain.contains("\u{0}") else { throw ReadingError.invalid("叙事顺序需明确且有效的基准。") }
                selected = "narrative-domain:" + domain
            } else { selected = "narrative" }
        } else if let calendar = at["calendar"] as? String, !calendar.isEmpty,
                  integer(at["year"]) != nil, Set(at.keys).isSubset(of: ["calendar", "year", "month", "day"]) {
            selected = (at["month"] != nil || at["day"] != nil ? "calendar-day:" : "calendar:") + calendar
        } else { throw ReadingError.invalid("当前时间须是明确历法的日期，或同一基准的叙事位置。") }
        guard availableAxes.contains(selected) else { throw ReadingError.invalid("该时间体系在本次范围内尚无可用数据。") }
        let time = TemporalAxis(selected)
        func coordinate(_ value: [String: Any]) -> Double? {
            guard Set(value.keys).isSubset(of: ["year", "month", "day"]), let year = integer(value["year"]) else { return nil }
            if time.isDateOrder {
                guard let month = integer(value["month"]), let day = integer(value["day"]) else { return nil }
                return time.parse("\(year)/\(month)/\(day)")
            }
            return value["month"] == nil && value["day"] == nil ? Double(year) : nil
        }
        let current: Double?
        if time.isNarrative { current = number(at["narrativeOrder"]) }
        else { current = coordinate(at.filter { $0.key != "calendar" }) }
        let lower: Double?, upper: Double?
        if time.isDateOrder {
            guard args["from"] == nil, args["to"] == nil, let first = args["fromDate"] as? [String: Any], let last = args["toDate"] as? [String: Any] else { throw ReadingError.invalid("按月日筛选请直接提供fromDate/toDate年月日，不要计算内部坐标。") }
            lower = coordinate(first); upper = coordinate(last)
        } else {
            guard args["fromDate"] == nil, args["toDate"] == nil else { throw ReadingError.invalid("日期边界不能混入年份或叙事轴。") }
            lower = number(args["from"]); upper = number(args["to"])
        }
        guard let lower, let upper, let current, time.window(from: lower, to: upper) != nil,
              time.point(current) != nil, lower <= current, current <= upper else { throw ReadingError.invalid("时间窗、当前时间或先后顺序无效。") }
        axis = selected; from = lower; to = upper; cursor = current
    }
}
