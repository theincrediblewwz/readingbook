import Foundation

public enum ReadingTextContext: String, Codable, CaseIterable, Sendable {
    case source, companion, conversation, notes, knowledge

    public var title: String {
        switch self {
        case .source: return "原文"
        case .companion: return "伴读"
        case .conversation: return "对话"
        case .notes: return "笔记"
        case .knowledge: return "卡片与组件"
        }
    }
}

public struct ReadingTextStyle: Codable, Hashable, Sendable {
    public static let pointSizeRange = 12.0...36.0
    public var family: String
    public var pointSize: Double

    public init(family: String, pointSize: Double) {
        self.family = family
        self.pointSize = pointSize
    }

    public func normalized(fallback: ReadingTextStyle) -> ReadingTextStyle {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        let validFamily = !trimmed.isEmpty && trimmed.utf8.count <= 256
            && !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        return ReadingTextStyle(family: validFamily ? trimmed : fallback.family,
                                pointSize: pointSize.isFinite
                                    ? min(Self.pointSizeRange.upperBound, max(Self.pointSizeRange.lowerBound, pointSize))
                                    : fallback.pointSize)
    }
}

/// Presentation preferences are independent of book projects and Markdown documents.
public struct ReadingTypographyPreferences: Codable, Equatable, Sendable {
    public private(set) var version: Int = 1
    private var styles: [String: ReadingTextStyle] = [:]

    public init(legacyCompanionScale: Double? = nil) {
        if let scale = legacyCompanionScale, scale.isFinite, scale > 0 {
            for context in [ReadingTextContext.companion, .conversation] {
                var style = Self.defaultStyle(for: context)
                style.pointSize *= scale
                set(style, for: context)
            }
        }
    }

    public static func defaultStyle(for context: ReadingTextContext) -> ReadingTextStyle {
        switch context {
        case .source: return ReadingTextStyle(family: "serif", pointSize: 17)
        case .companion, .conversation: return ReadingTextStyle(family: "serif", pointSize: 18)
        case .notes, .knowledge: return ReadingTextStyle(family: "system", pointSize: 16)
        }
    }

    public func style(for context: ReadingTextContext) -> ReadingTextStyle {
        let fallback = Self.defaultStyle(for: context)
        return (styles[context.rawValue] ?? fallback).normalized(fallback: fallback)
    }

    public mutating func set(_ style: ReadingTextStyle, for context: ReadingTextContext) {
        styles[context.rawValue] = style.normalized(fallback: Self.defaultStyle(for: context))
    }

    public mutating func reset(_ context: ReadingTextContext) { styles.removeValue(forKey: context.rawValue) }
    public mutating func resetAll() { styles.removeAll() }

    public static func restored(from data: Data?, legacyCompanionScale: Double? = nil) -> Self {
        guard let data else { return Self(legacyCompanionScale: legacyCompanionScale) }
        // A damaged/newer preference must not continually reapply a retired scale.
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data), decoded.version == 1 else { return Self() }
        var result = Self()
        for context in ReadingTextContext.allCases { result.set(decoded.style(for: context), for: context) }
        return result
    }
}
