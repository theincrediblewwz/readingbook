import Foundation

/// Immutable derived versions keep earlier introductions readable after later
/// evidence is added to the canonical object. They never replace that object.
public struct KnowledgeObjectVersion: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var objectID: String
    public var sourceHash: String
    public var contentFingerprint: String
    public var unitHashes: [String: String]
    public var entity: KnowledgeEntity?
    public var event: KnowledgeEvent?
    public var createdAt: Date
    public var evidence: [Evidence] { entity?.evidence ?? event?.evidence ?? [] }
}

/// Model background is not a source-backed fact or a user-owned document.
public struct TeacherBackgroundRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var objectID: String
    public var sourceHash: String
    public var contextFingerprint: String
    public var unitHashes: [String: String]
    public var evidence: [Evidence]
    public var avoidsSpoilers: Bool
    public var cursorOrder: Int
    public var title: String
    public var markdown: String
    public var model: String
    public var createdAt: Date
    public init(id: String, objectID: String, sourceHash: String, contextFingerprint: String,
                unitHashes: [String: String], evidence: [Evidence], avoidsSpoilers: Bool,
                cursorOrder: Int, title: String, markdown: String, model: String, createdAt: Date = Date()) {
        self.id = id; self.objectID = objectID; self.sourceHash = sourceHash
        self.contextFingerprint = contextFingerprint; self.unitHashes = unitHashes; self.evidence = evidence
        self.avoidsSpoilers = avoidsSpoilers; self.cursorOrder = cursorOrder; self.title = title
        self.markdown = markdown; self.model = model; self.createdAt = createdAt
    }
}

public struct ReadingKnowledgeState: Codable, Sendable {
    public var version = 1
    public var versions: [KnowledgeObjectVersion] = []
    public var backgrounds: [TeacherBackgroundRecord] = []
    public init() {}
}

public enum ReadingKnowledgeRuntime {
    /// Called only by a canonical host save. Evidence-only additions keep the
    /// first valid version instead of duplicating a growing aggregate summary.
    public static func captureVersions(before: BookProject, in project: inout BookProject) throws {
        guard before.id == project.id, before.sourceHash == project.sourceHash else { return }
        var state = before.readingKnowledge ?? ReadingKnowledgeState()
        if let proposed = project.readingKnowledge {
            var versions = Dictionary(state.versions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var backgrounds = Dictionary(state.backgrounds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for value in proposed.versions {
                if let current = versions[value.id] {
                    guard current == value else { throw invalid("已有知识版本已更新，未覆盖本地记录；请重新载入。") }
                } else { state.versions.append(value); versions[value.id] = value }
            }
            for value in proposed.backgrounds {
                if let current = backgrounds[value.id] {
                    guard current == value else { throw invalid("已有老师介绍已更新，未覆盖本地记录；请重新载入。") }
                } else { state.backgrounds.append(value); backgrounds[value.id] = value }
            }
        }
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var known = Set(state.versions.map { $0.objectID + "|" + $0.sourceHash + "|" + $0.contentFingerprint })
        var hashes: [String: String] = [:]
        func append(entity: KnowledgeEntity? = nil, event: KnowledgeEvent? = nil) throws {
            let evidence = entity?.evidence ?? event?.evidence ?? []
            guard let id = entity?.id ?? event?.id, !evidence.isEmpty,
                  evidence.allSatisfy({ item in units[item.unitID].map { exact(item.quote, in: $0.text) } == true }) else { return }
            let fingerprint = try contentFingerprint(entity: entity, event: event)
            let key = id + "|" + project.sourceHash + "|" + fingerprint
            guard known.insert(key).inserted else { return }
            // A cache must not make an otherwise valid legacy save fail merely
            // because an old hand-edited aggregate exceeds the cache bounds.
            guard state.versions.count < 100_000,
                  evidence.count <= 100_000, evidence.allSatisfy({ safeID($0.unitID) && validText($0.quote, maximum: 20_000) }) else { return }
            if let value = entity {
                guard validText(value.name, maximum: 1600), validText(value.summary, maximum: 1_000_000, empty: true),
                      value.aliases.count <= 256, value.aliases.allSatisfy({ validText($0, maximum: 1600) }),
                      value.properties.count <= 256,
                      value.properties.allSatisfy({ validText($0.key, maximum: 512) && validText($0.value, maximum: 1_000_000, empty: true) }) else { return }
            }
            if let value = event {
                guard validText(value.name, maximum: 1600), validText(value.summary, maximum: 1_000_000, empty: true),
                      validText(value.dateText, maximum: 16_000, empty: true) else { return }
            }
            var sourceHashes: [String: String] = [:]
            for item in evidence {
                if hashes[item.unitID] == nil { hashes[item.unitID] = try BookImporter.sha256(Data(units[item.unitID]!.text.utf8)) }
                sourceHashes[item.unitID] = hashes[item.unitID]
            }
            state.versions.append(KnowledgeObjectVersion(id: "knowledge-" + (try BookImporter.sha256(Data(key.utf8))), objectID: id,
                sourceHash: project.sourceHash, contentFingerprint: fingerprint, unitHashes: sourceHashes,
                entity: entity, event: event, createdAt: Date()))
        }
        let oldEntities = Dictionary(before.entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldEvents = Dictionary(before.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for value in project.entities where oldEntities[value.id] != value {
            if let previous = oldEntities[value.id] { try append(entity: previous) }
            try append(entity: value)
        }
        for value in project.events where oldEvents[value.id] != value {
            if let previous = oldEvents[value.id] { try append(event: previous) }
            try append(event: value)
        }
        if !state.versions.isEmpty || !state.backgrounds.isEmpty { project.readingKnowledge = state }
    }

    public static func entityVersion(id: String, in project: BookProject, allowedUnitIDs: Set<String>?,
                                     currentSlices: [String: String]? = nil) -> KnowledgeEntity? {
        let context = VersionContext(project: project, allowed: allowedUnitIDs, slices: currentSlices)
        return context.entity(id)
    }
    public static func eventVersion(id: String, in project: BookProject, allowedUnitIDs: Set<String>?,
                                    currentSlices: [String: String]? = nil) -> KnowledgeEvent? {
        let context = VersionContext(project: project, allowed: allowedUnitIDs, slices: currentSlices)
        return context.event(id)
    }

    /// Construct once per projection, not once for every row in a large list.
    public struct VersionContext: Sendable {
        private let units: [String: SourceUnit]
        private let sourceHash: String
        private let versions: [String: [KnowledgeObjectVersion]]
        private let allowed: Set<String>?
        private let slices: [String: String]?
        public init(project: BookProject, allowed: Set<String>?, slices: [String: String]? = nil) {
            sourceHash = project.sourceHash
            units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            versions = Dictionary(grouping: project.readingKnowledge?.versions ?? [], by: \.objectID)
            self.allowed = allowed; self.slices = slices
        }
        public func entity(_ id: String) -> KnowledgeEntity? { visible(id, entity: true)?.entity }
        public func event(_ id: String) -> KnowledgeEvent? { visible(id, entity: false)?.event }
        private func visible(_ id: String, entity: Bool) -> KnowledgeObjectVersion? {
            (versions[id] ?? []).reversed().first { value in
                (entity ? value.entity != nil : value.event != nil) && value.sourceHash == sourceHash && !value.evidence.isEmpty && value.evidence.allSatisfy { item in
                    guard allowed?.contains(item.unitID) != false, let unit = units[item.unitID],
                          ReadingKnowledgeRuntime.exact(item.quote, in: unit.text),
                          value.unitHashes[item.unitID] == (try? BookImporter.sha256(Data(unit.text.utf8))) else { return false }
                    if let slice = slices?[item.unitID] { return ReadingKnowledgeRuntime.exact(item.quote, in: slice) }
                    return true
                }
            }
        }
    }

    public static func background(for request: TeacherBackgroundRequest, in project: BookProject) -> TeacherBackgroundRecord? {
        guard request.bookID == project.id, request.sourceHash == project.sourceHash,
              active(request.objectID, in: project) else { return nil }
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return project.readingKnowledge?.backgrounds.reversed().first { value in
            value.objectID == request.objectID && value.sourceHash == request.sourceHash &&
                value.contextFingerprint == request.contextFingerprint && value.avoidsSpoilers == request.avoidsSpoilers &&
                (!request.avoidsSpoilers || value.cursorOrder <= request.cursorOrder) &&
                sourcesCurrent(value, units: units, allowed: request.allowedUnitIDs)
        }
    }

    /// Full-library human-readable export, still separate from source facts.
    /// Stale or removed-object entries remain in project.json for recovery.
    public static func readableBackgrounds(in project: BookProject) -> [TeacherBackgroundRecord] {
        let units = Dictionary(project.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (project.readingKnowledge?.backgrounds ?? []).filter {
            $0.sourceHash == project.sourceHash && active($0.objectID, in: project) && sourcesCurrent($0, units: units, allowed: nil)
        }
    }

    /// Stale cache entries remain recoverable after OCR or a manual removal.
    /// Exact source/active-object checks happen at read and save time instead.
    public static func validateStoredState(in project: BookProject) throws {
        guard let state = project.readingKnowledge else { return }
        guard state.version == 1, state.versions.count <= 100_000, state.backgrounds.count <= 20_000,
              Set(state.versions.map(\.id)).count == state.versions.count,
              Set(state.backgrounds.map(\.id)).count == state.backgrounds.count else { throw invalid("知识记忆版本或记录数量无效。") }
        for value in state.versions {
            guard safeID(value.id), safeID(value.objectID), hash(value.sourceHash), hash(value.contentFingerprint),
                  (value.entity == nil) != (value.event == nil), (value.entity?.id ?? value.event?.id) == value.objectID,
                  validDate(value.createdAt), !value.evidence.isEmpty, value.evidence.count <= 100_000,
                  validSources(value.evidence, hashes: value.unitHashes) else { throw invalid("知识版本记录无效。") }
            if let entity = value.entity {
                guard validText(entity.name, maximum: 1600), validText(entity.summary, maximum: 1_000_000, empty: true),
                      entity.aliases.count <= 256, entity.aliases.allSatisfy({ validText($0, maximum: 1600) }),
                      entity.properties.count <= 256,
                      entity.properties.allSatisfy({ validText($0.key, maximum: 512) && validText($0.value, maximum: 1_000_000, empty: true) }) else { throw invalid("知识实体版本文本无效。") }
            }
            if let event = value.event {
                guard validText(event.name, maximum: 1600), validText(event.summary, maximum: 1_000_000, empty: true),
                      validText(event.dateText, maximum: 16_000, empty: true) else { throw invalid("知识事件版本文本无效。") }
            }
        }
        for value in state.backgrounds { try validateBackground(value) }
    }

    static func validateBackground(_ value: TeacherBackgroundRecord) throws {
        guard safeID(value.id), safeID(value.objectID), hash(value.sourceHash), hash(value.contextFingerprint),
              validDate(value.createdAt), value.cursorOrder >= 0, validText(value.title, maximum: 1600),
              validText(value.markdown, maximum: 12_000), validText(value.model, maximum: 240),
              !value.evidence.isEmpty, value.evidence.count <= 16,
              validSources(value.evidence, hashes: value.unitHashes) else { throw invalid("老师背景记录无效。") }
    }
    static func sourcesCurrent(_ value: TeacherBackgroundRecord, units: [String: SourceUnit], allowed: Set<String>?) -> Bool {
        value.evidence.allSatisfy { item in
            guard allowed?.contains(item.unitID) != false, let unit = units[item.unitID], exact(item.quote, in: unit.text),
                  value.unitHashes[item.unitID] == (try? BookImporter.sha256(Data(unit.text.utf8))) else { return false }
            return !value.avoidsSpoilers || unit.order <= value.cursorOrder
        }
    }
    static func active(_ id: String, in project: BookProject) -> Bool {
        project.entities.contains { $0.id == id } || project.events.contains { $0.id == id }
    }
    static func contentFingerprint(entity: KnowledgeEntity?, event: KnowledgeEvent?) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data: Data
        if var value = entity { value.evidence = []; data = try encoder.encode(value) }
        else if var value = event { value.evidence = []; data = try encoder.encode(value) }
        else { throw invalid("缺少知识对象。") }
        return try BookImporter.sha256(data)
    }
    static func exact(_ quote: String, in text: String) -> Bool {
        guard !quote.isEmpty, let range = text.range(of: quote, options: .literal) else { return false }
        return text[range].utf8.elementsEqual(quote.utf8)
    }
    private static func validSources(_ evidence: [Evidence], hashes: [String: String]) -> Bool {
        Set(evidence.map(\.unitID)) == Set(hashes.keys) && hashes.allSatisfy { safeID($0.key) && hash($0.value) } &&
            evidence.allSatisfy { safeID($0.unitID) && validText($0.quote, maximum: 20_000) }
    }
    private static func validDate(_ value: Date) -> Bool { value.timeIntervalSince1970.isFinite }
    private static func hash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isASCII && $0.isHexDigit } }
    private static func safeID(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil }
    private static func validText(_ value: String, maximum: Int, empty: Bool = false) -> Bool { (empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && value.utf8.count <= maximum && !value.contains("\0") }
    private static func invalid(_ message: String) -> ReadingError { .invalid(message) }
}
