import Foundation

/// Capability exposure and the way a reader is addressed are independent.
public enum ReadingConversationMode: String, Codable, CaseIterable, Hashable, Sendable {
    case reading, functional
    public var title: String { self == .reading ? "纯阅读" : "功能协作" }
    public var icon: String { self == .reading ? "book" : "square.stack.3d.up" }
}

public enum ReadingAnswerStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case mentor, research
    public var title: String { self == .mentor ? "老师伴读" : "原文考据" }
    public var icon: String { self == .mentor ? "sparkles" : "text.magnifyingglass" }
}

public struct ReadingAnswerPreferences: Codable, Hashable, Sendable {
    public var interaction: ReadingConversationMode
    public var style: ReadingAnswerStyle
    public var avoidsSpoilers: Bool
    public init(interaction: ReadingConversationMode = .reading, style: ReadingAnswerStyle = .mentor, avoidsSpoilers: Bool = true) {
        self.interaction = interaction; self.style = style; self.avoidsSpoilers = avoidsSpoilers
    }
    /// Derived memories from another mode must never become this mode's context.
    public var contextIdentity: String { interaction.rawValue + ":" + style.rawValue + ":" + (avoidsSpoilers ? "current" : "open") }

    static let readingToolNames: Set<String> = ["source_outline", "source_search", "source_read", "objects_search", "object_get", "documents_list", "documents_search", "document_read", "conversation_search", "conversation_read"]

    var voiceInstructions: String {
        let voice = style == .mentor
            ? "像一位熟悉这本书、愿意陪人慢慢读的老师，用自然、温和的中文直接回应问题。先讲清读者关心的意思，有必要时才展开；不要把普通回答写成工作报告、核查流水线或满篇编号。可以用恰当的背景知识解释人物、时代和概念；书外知识请放在简短的‘背景补充’段，与原书实际写到的内容分开，记不准就直说。背景常识不冒充已核实来源，也不能写入有原文证据的事实字段。"
            : "采用原文考据方式。内容结论只依据本次实际读取的原文、授权笔记或可重读的原始消息；区分文字明载、推断与未知。必要时引用短句并指出分歧，不加入未经说明的书外背景。仍使用清楚自然的中文，不输出开发记录。"
        let spoiler = avoidsSpoilers
            ? "围绕读者当前选择的阅读范围讲解，不主动透露后文命运、结局或未来事件；人物全貌、后续发展须等读者明确要求。背景讲解也应注意剧透。"
            : "读者已允许讨论后续发展；仍须区别已读取原文与背景知识，不能声称读过未返回的正文。"
        return voice + "\n" + spoiler
    }
}
