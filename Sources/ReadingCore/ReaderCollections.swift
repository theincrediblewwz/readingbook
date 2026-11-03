import Foundation

public enum ReaderCollectionKind: String, Codable, CaseIterable, Sendable {
    case notes, history, summaries
    public var title: String { switch self { case .notes: return "笔记"; case .history: return "历史对话"; case .summaries: return "对话摘要" } }
}

public struct ReaderCollectionFolder: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: ReaderCollectionKind
    public var title: String
    public var parentID: String?
    public init(id: String = UUID().uuidString, kind: ReaderCollectionKind, title: String, parentID: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.parentID = parentID
    }
}

/// Host-owned organization only. Original messages, Markdown and source records
/// stay in their canonical arrays/files. Collapse is presentation; archive is a
/// separate, explicit automatic-context boundary.
public struct ReaderCollectionState: Codable, Hashable, Sendable {
    public var folders: [ReaderCollectionFolder] = []
    public var assignments: [String: String] = [:]
    public var archivedChatIDs: [String] = []
    public var archivedCompanionIDs: [String] = []
    public var collapsedReferenceIDs: [String] = []
    public var notePlacements: [String: ReadingNotePlacement]?
    public init() { }
}

public struct ReadingAnswerReference: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let content: String
    public let evidence: [Evidence]
}

public enum ReaderCollectionCommand: Sendable {
    case createFolder(ReaderCollectionFolder)
    case renameFolder(String, String)
    case removeFolder(String)
    case move(ReaderCollectionKind, [String], String?)
    case collapse([String], Bool)
    case archive([String], String)
    case restore([String])
    case organizeNotesByMonth
    case organizeNotesByTopic([ReadingNoteTopicGroup], expectedDocuments: [DocumentRecord])
    case setNotePlacement(String, ReadingNotePlacement?)
}

public enum ReaderCollectionRuntime {
    public static func state(in project: BookProject) -> ReaderCollectionState { project.readerCollections ?? .init() }

    public static func validate(_ state: ReaderCollectionState?) throws {
        guard let state else { return }
        guard (state.notePlacements?.count ?? 0) <= 100_000 else { throw ReadingError.invalid("位置笔记数量过多。") }
        for (id, placement) in state.notePlacements ?? [:] {
            guard !id.isEmpty, id.utf8.count <= 160 else { throw ReadingError.invalid("位置笔记身份无效。") }
            try placement.validate()
        }
        guard state.folders.count <= 512, Set(state.folders.map(\.id)).count == state.folders.count,
              state.assignments.count <= 100_000, state.archivedChatIDs.count <= 100_000,
              state.archivedCompanionIDs.count <= 100_000, state.collapsedReferenceIDs.count <= 100_000 else {
            throw ReadingError.invalid("文件夹或收纳记录数量过多。")
        }
        let folders = Dictionary(uniqueKeysWithValues: state.folders.map { ($0.id, $0) })
        for folder in state.folders {
            guard !folder.id.isEmpty, folder.id.utf8.count <= 160, !folder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  folder.title.count <= 80 else { throw ReadingError.invalid("文件夹名称需为1–80字。") }
            var visited: Set<String> = [folder.id], parent = folder.parentID
            while let id = parent {
                guard let value = folders[id], value.kind == folder.kind, visited.insert(id).inserted else {
                    throw ReadingError.invalid("文件夹层级无效，不能放入自身或其他类型的文件夹。")
                }
                parent = value.parentID
            }
        }
        guard state.assignments.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 300 && folders[$0.value] != nil }),
              [state.archivedChatIDs, state.archivedCompanionIDs, state.collapsedReferenceIDs].allSatisfy({ ids in
                  Set(ids).count == ids.count && ids.allSatisfy { !$0.isEmpty && $0.utf8.count <= 300 }
              }) else { throw ReadingError.invalid("收纳记录无效。") }
    }

    public static func reference(_ id: String, in project: BookProject) -> ReadingAnswerReference? {
        if id.hasPrefix("chat:"), let index = project.chats.firstIndex(where: { "chat:" + $0.id == id && $0.role == "assistant" }) {
            let message = project.chats[index]
            let question = project.chats[..<index].last(where: { $0.role == "user" })?.content
            return ReadingAnswerReference(id: id, title: String((question ?? message.content).prefix(100)), content: message.content, evidence: message.evidence)
        }
        let experience = project.readingExperience
        if id.hasPrefix("layer:"), let value = experience?.layers.first(where: { "layer:" + $0.id == id }) {
            return ReadingAnswerReference(id: id, title: value.title, content: value.markdown,
                evidence: evidence(value.sourceAnchorIDs, in: project))
        }
        if id.hasPrefix("alignment:"), let value = experience?.alignments.first(where: { "alignment:" + $0.id == id }) {
            return ReadingAnswerReference(id: id, title: value.title, content: value.markdown,
                evidence: evidence(value.sourceAnchorIDs, in: project))
        }
        return nil
    }

    public static func references(in project: BookProject) -> [ReadingAnswerReference] {
        var result: [ReadingAnswerReference] = [], question = ""
        for message in project.chats {
            if message.role == "user" { question = message.content }
            if message.role == "assistant" {
                result.append(.init(id: "chat:" + message.id, title: String((question.isEmpty ? message.content : question).prefix(100)), content: message.content, evidence: message.evidence))
            }
        }
        // Stored companion records also remain explicit, independently
        // selectable references after being moved into history.
        for id in project.readerCollections?.archivedCompanionIDs ?? [] {
            if let value = reference(id, in: project) { result.append(value) }
        }
        return result
    }

    private static func evidence(_ ids: [String], in project: BookProject) -> [Evidence] {
        let wanted = Set(ids)
        return (project.readingExperience?.anchors ?? []).filter { wanted.contains($0.id) }.map { Evidence(unitID: $0.unitID, quote: $0.quote) }
    }

    public static func explicitReferences(_ ids: [String], in project: BookProject) throws -> [ReadingAnswerReference] {
        guard ids.count <= 16, Set(ids).count == ids.count else { throw ReadingError.invalid("一次最多引用16条不同的历史回答。") }
        let result = try ids.map { id -> ReadingAnswerReference in
            guard let value = reference(id, in: project) else { throw ReadingError.invalid("引用的回答已不存在，请重新选择。") }
            return value
        }
        guard try JSONEncoder().encode(result).count <= 65_536 else { throw ReadingError.invalid("所选历史回答超过64 KiB，请减少引用；不会截断原回答。") }
        return result
    }

    public static func contextIdentity(preferences: ReadingAnswerPreferences, references: [ReadingAnswerReference]) throws -> String {
        guard !references.isEmpty else { return preferences.contextIdentity }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return preferences.contextIdentity + ":refs:" + (try BookImporter.sha256(encoder.encode(references)))
    }

    /// Include the question and every answer in a selected turn. A shared
    /// question cannot remain automatically admitted after its answers archive.
    public static func turnMessageIDs(for answerIDs: Set<String>, in project: BookProject) -> Set<String> {
        var result = Set<String>(), turn: [ChatMessage] = []
        func flush() {
            if turn.contains(where: { $0.role == "assistant" && answerIDs.contains($0.id) }) { result.formUnion(turn.map(\.id)) }
        }
        for message in project.chats {
            if message.role == "user" { flush(); turn = [] }
            turn.append(message)
        }
        flush(); return result
    }

    public static func apply(_ command: ReaderCollectionCommand, in project: BookProject) throws -> ReaderCollectionState {
        var state = state(in: project)
        func requireFolder(_ id: String?, kind: ReaderCollectionKind) throws {
            guard let id else { return }
            guard state.folders.contains(where: { $0.id == id && $0.kind == kind }) else { throw ReadingError.invalid("目标文件夹已不存在。") }
        }
        func requireReferences(_ ids: [String]) throws {
            let known = Set(project.chats.filter { $0.role == "assistant" }.map { "chat:" + $0.id })
                .union((project.readingExperience?.layers ?? []).map { "layer:" + $0.id })
                .union((project.readingExperience?.alignments ?? []).map { "alignment:" + $0.id })
            guard ids.count <= 100_000, Set(ids).isSubset(of: known) else { throw ReadingError.invalid("回答已变化，请重新选择。") }
        }
        switch command {
        case let .organizeNotesByTopic(groups, expected):
            let encoded = try JSONSerialization.data(withJSONObject: ["groups": try JSONSerialization.jsonObject(with: JSONEncoder().encode(groups))])
            _ = try ReadingNoteTopicRuntime.parse(String(decoding: encoded, as: UTF8.self), offeredIDs: Set(expected.map(\.id)))
            let selectedIDs = Set(groups.flatMap(\.noteIDs))
            let original = Dictionary(expected.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for id in selectedIDs {
                guard let document = project.activeDocuments.first(where: { $0.id == id }), original[id] == document,
                      state.assignments["note:" + id] == nil else { throw ReadingError.invalid("部分笔记或手工分类已经变化，未应用建议；请重新生成预览。") }
            }
            for group in groups {
                let folder = state.folders.first { $0.kind == .notes && $0.parentID == nil && $0.title == group.title }
                    ?? ReaderCollectionFolder(kind: .notes, title: group.title)
                if !state.folders.contains(where: { $0.id == folder.id }) { state.folders.append(folder) }
                for id in group.noteIDs { state.assignments["note:" + id] = folder.id }
            }
        case let .setNotePlacement(id, placement):
            guard project.activeDocuments.contains(where: { $0.id == id }) else { throw ReadingError.invalid("笔记已变化或在回收站，请重新打开。") }
            if let placement {
                try placement.validate()
                guard placement.matches(project) else { throw ReadingError.invalid("原书位置或版本已变化，请重新绑定；正文保留。") }
                if state.notePlacements == nil { state.notePlacements = [:] }
                state.notePlacements?[id] = placement
            } else { state.notePlacements?.removeValue(forKey: id) }
        case .createFolder(var folder):
            folder.title = folder.title.trimmingCharacters(in: .whitespacesAndNewlines)
            try requireFolder(folder.parentID, kind: folder.kind)
            guard !state.folders.contains(where: { $0.id == folder.id }) else { throw ReadingError.invalid("文件夹身份重复。") }
            state.folders.append(folder)
        case let .renameFolder(id, title):
            guard let index = state.folders.firstIndex(where: { $0.id == id }) else { throw ReadingError.invalid("文件夹已不存在。") }
            state.folders[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        case .removeFolder(let id):
            guard let folder = state.folders.first(where: { $0.id == id }) else { throw ReadingError.invalid("文件夹已不存在。") }
            state.folders.removeAll { $0.id == id }
            for index in state.folders.indices where state.folders[index].parentID == id { state.folders[index].parentID = folder.parentID }
            state.assignments = state.assignments.filter { $0.value != id }
        case let .move(kind, ids, folderID):
            try requireFolder(folderID, kind: kind)
            let expandedIDs: [String]
            if kind == .history {
                let turns = turnMessageIDs(for: Set(ids.filter { $0.hasPrefix("chat:") }.map { String($0.dropFirst(5)) }), in: project)
                expandedIDs = Array(Set(ids).union(turns.map { "chat:" + $0 }))
            } else { expandedIDs = ids }
            for id in expandedIDs {
                let valid: Bool
                switch kind {
                case .notes: valid = project.documents.contains { "note:" + $0.id == id }
                case .history: valid = id.hasPrefix("chat:") ? project.chats.contains(where: { "chat:" + $0.id == id }) : reference(id, in: project) != nil
                case .summaries: valid = id.hasPrefix("memory:" + project.id + ":") && id.utf8.count <= 300
                }
                guard valid else { throw ReadingError.invalid("收纳内容不属于这本书。") }
                state.assignments[id] = folderID
            }
        case let .collapse(ids, collapsed):
            try requireReferences(ids)
            let turns = turnMessageIDs(for: Set(ids.filter { $0.hasPrefix("chat:") }.map { String($0.dropFirst(5)) }), in: project)
            let references = Set(ids).union(project.chats.filter { $0.role == "assistant" && turns.contains($0.id) }.map { "chat:" + $0.id })
            var selected = Set(state.collapsedReferenceIDs)
            if collapsed { selected.formUnion(references) } else { selected.subtract(references) }
            state.collapsedReferenceIDs = selected.sorted()
        case let .archive(ids, title):
            try requireReferences(ids)
            let folder = ReaderCollectionFolder(kind: .history, title: title)
            state.folders.append(folder)
            let chats = Set(ids.filter { $0.hasPrefix("chat:") }.map { String($0.dropFirst(5)) })
            let turns = turnMessageIDs(for: chats, in: project)
            state.archivedChatIDs = Set(state.archivedChatIDs).union(turns).sorted()
            let companion = ids.filter { !$0.hasPrefix("chat:") }
            state.archivedCompanionIDs = Set(state.archivedCompanionIDs).union(companion).sorted()
            for id in turns { state.assignments["chat:" + id] = folder.id }
            for id in companion { state.assignments[id] = folder.id }
            let archived = Set(ids).union(turns.map { "chat:" + $0 })
            state.collapsedReferenceIDs.removeAll { archived.contains($0) }
        case .restore(let ids):
            try requireReferences(ids)
            let chats = Set(ids.filter { $0.hasPrefix("chat:") }.map { String($0.dropFirst(5)) })
            let turns = turnMessageIDs(for: chats, in: project)
            state.archivedChatIDs.removeAll { turns.contains($0) }
            state.archivedCompanionIDs.removeAll { ids.contains($0) }
        case .organizeNotesByMonth:
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "yyyy年MM月"
            for note in project.activeDocuments where state.assignments["note:" + note.id] == nil {
                let title = formatter.string(from: note.updatedAt)
                let folder: ReaderCollectionFolder
                if let old = state.folders.first(where: { $0.kind == .notes && $0.parentID == nil && $0.title == title }) { folder = old }
                else { folder = ReaderCollectionFolder(kind: .notes, title: title); state.folders.append(folder) }
                state.assignments["note:" + note.id] = folder.id
            }
        }
        try validate(state); return state
    }
}

extension LibraryRepository {
    /// A small editor/perspective save starts from the latest actor-owned book,
    /// so unrelated analysis written during a model request is retained.
    public func saveLatestNote(bookID: String, sourceHash: String, document: DocumentRecord, markdown: String,
                               expectedDocument: DocumentRecord? = nil, expectedContentHash: String? = nil,
                               notePlacement: ReadingNotePlacement? = nil, readingSnapshot: ReadingQuerySnapshot? = nil,
                               expectedPlacement: ReadingNotePlacementExpectation? = nil) throws -> BookProject {
        try Task.checkCancellation()
        let directory = try bookDirectory(bookID, mustExist: true)
        try recoverDocument(in: directory)
        let project = try readProject(in: directory)
        guard project.sourceHash == sourceHash else { throw ReadingError.invalid("原书版本已经变化，未覆盖笔记。") }
        if case .unchanged(let expected) = expectedPlacement {
            guard project.readerCollections?.notePlacements?[document.id] == expected else {
                throw ReadingError.invalid("这张便签的位置或外观已在别处修改，未覆盖。请重新打开对照，或另存为新笔记。")
            }
        }
        if let expectedDocument {
            guard project.activeDocuments.first(where: { $0.id == expectedDocument.id }) == expectedDocument else {
                throw ReadingError.invalid("笔记记录已经修改或回收，未覆盖已有内容。")
            }
        }
        if let readingSnapshot { _ = try readingSnapshot.sourceRanges(in: project) }
        return try saveDocument(project: project, document: document, markdown: markdown, expectedContentHash: expectedContentHash, notePlacement: notePlacement)
    }
    /// Resolve from the actor's latest canonical project, so an AI result or
    /// another window cannot overwrite a concurrent manual archive/folder edit.
    public func organizeReaderCollections(bookID: String, sourceHash: String, command: ReaderCollectionCommand,
                                         expectedPlacement: ReadingNotePlacementExpectation? = nil) throws -> BookProject {
        let directory = try bookDirectory(bookID, mustExist: true)
        try recoverDocument(in: directory)
        let project = try readProject(in: directory)
        guard project.sourceHash == sourceHash else { throw ReadingError.invalid("原书版本已变化，请重新打开收纳界面。") }
        if case .unchanged(let expected) = expectedPlacement {
            guard case .setNotePlacement(let id, _) = command, project.readerCollections?.notePlacements?[id] == expected else {
                throw ReadingError.invalid("便签位置后来又被修改，未覆盖。请重新选择。")
            }
        }
        let state = try ReaderCollectionRuntime.apply(command, in: project)
        return try saveCanonicalProject(project, readerCollections: state)
    }
}
