import Foundation

/// A readable interpretation of an already scoped extent, never a persisted
/// date, calendar conversion or additional source permission.
public enum TemporalDatePresentation {
    public static func summary(_ extent: TemporalExtent) -> String {
        let source = extent.sourceText.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if extent.precision == .narrative {
            let label = extent.narrativeDomain == "source-order" ? "原文先后，非史事日期" : "叙事先后，非确定日期"
            return label + (source.isEmpty ? "" : " · " + String(source.prefix(100)))
        }
        guard extent.precision != .unknown, extent.start != nil || extent.end != nil else {
            return source.isEmpty || source == "时间待考" ? "日期尚未确定" : "日期尚未确定 · 原文时语：" + String(source.prefix(120))
        }
        let classification: String
        switch extent.assertion {
        case .inferred: classification = "推算时间"
        case .explicit: classification = "原文明示时间"
        case .unknown, nil: classification = "时间依据待核对"
        }
        let qualifier: String
        switch extent.uncertainty {
        case .exact: qualifier = ""
        case .approximate: qualifier = "（约略）"
        case .disputed: qualifier = "（有争议）"
        case .unknown: qualifier = "（不确定）"
        }
        func date(_ value: TemporalDate) -> String {
            String(value.year) + "年" + (value.month.map { String($0) + "月" } ?? "") + (value.day.map { String($0) + "日" } ?? "")
        }
        let calendar = extent.calendar.map { $0 == "gregorian" ? "公历" : String($0.prefix(80)) } ?? ""
        let lower = extent.start.map(date), upper = extent.end.map(date)
        let dates: String
        if let lower, let upper, lower != upper { dates = lower + "—" + upper }
        else if let lower { dates = lower + (extent.kind == .interval && upper == nil ? "起，终点未定" : "") }
        else { dates = "截至" + (upper ?? "") + "，起点未定" }
        return classification + qualifier + " · " + calendar + dates
    }
}
