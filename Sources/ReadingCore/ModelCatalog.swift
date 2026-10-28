import Foundation
import CoreFoundation

/// Public metadata only. Credentials and saved connections are deliberately absent.
public struct ProviderCatalog: Codable, Hashable, Sendable {
    public var verifiedAt: String
    public var providers: [ProviderPreset]
    public init(verifiedAt: String, providers: [ProviderPreset]) { self.verifiedAt = verifiedAt; self.providers = providers }
    public func matchingProvider(baseURL: String) -> ProviderPreset? {
        guard let requested = try? ProviderClient.endpoint(baseURL) else { return nil }
        let matches = providers.filter { provider in
            ([provider.baseURL] + (provider.aliases ?? [])).contains { address in
                guard let candidate = try? ProviderClient.endpoint(address) else { return false }
                return candidate.scheme == requested.scheme && candidate.host?.lowercased() == requested.host?.lowercased()
                    && candidate.port == requested.port && candidate.path == requested.path
            }
        }.sorted { $0.baseURL.count > $1.baseURL.count }
        return matches.count == 1 ? matches[0] : nil
    }
}
public struct CatalogSource: Codable, Hashable, Sendable {
    public var url: String
    public var quote: String
    public init(url: String, quote: String) { self.url = url; self.quote = quote }
}
public struct ProviderPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var documentationURL: String
    public var models: [ModelPreset]
    public var note: String?
    public var sources: [CatalogSource]?
    public var aliases: [String]?
    public init(id: String, name: String, baseURL: String, documentationURL: String, models: [ModelPreset], note: String? = nil, sources: [CatalogSource]? = nil, aliases: [String]? = nil) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.documentationURL = documentationURL; self.models = models
        self.note = note; self.sources = sources; self.aliases = aliases
    }
}
public struct ModelPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var contextTokens: Int?
    public var maxOutputTokens: Int?
    public var vision: Bool
    public var tools: Bool
    public var tokenParameter: String
    public var documentationURL: String
    public var note: String?
    public var limitSourceURL: String?
    public init(id: String, name: String, contextTokens: Int?, maxOutputTokens: Int?, vision: Bool, tools: Bool, tokenParameter: String, documentationURL: String, note: String? = nil, limitSourceURL: String? = nil) {
        self.id = id; self.name = name; self.contextTokens = contextTokens; self.maxOutputTokens = maxOutputTokens
        self.vision = vision; self.tools = tools; self.tokenParameter = tokenParameter; self.documentationURL = documentationURL
        self.note = note; self.limitSourceURL = limitSourceURL
    }
}
public struct CatalogPublicEvidence: Codable, Hashable, Sendable {
    public var url: String
    public var text: String
    public init(url: String, text: String) { self.url = url; self.text = text }
}
public struct ModelCatalogProposal: Codable, Hashable, Sendable {
    public var schema: String
    public var summary: String
    public var providers: [ProviderPreset]
    public init(summary: String, providers: [ProviderPreset]) { schema = "readingbook.model-catalog-proposal/v1"; self.summary = summary; self.providers = providers }
}
public struct ModelCatalogDifference: Codable, Hashable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var before: String
    public var after: String
}
public struct ModelCatalogSnapshot: Codable, Hashable, Sendable {
    public var catalog: ProviderCatalog
    public var revision: Int
    public var canRollback: Bool
}
public struct ModelCatalogReview: Codable, Hashable, Sendable {
    public var id: String
    public var expectedRevision: Int
    public var proposal: ModelCatalogProposal
    public var differences: [ModelCatalogDifference]
    public var digest: String
}

public enum ModelCatalogValidation {
    static let providerKeys: Set<String> = ["id", "name", "baseURL", "documentationURL", "models", "note", "sources", "aliases"]
    static let modelKeys: Set<String> = ["id", "name", "contextTokens", "maxOutputTokens", "vision", "tools", "tokenParameter", "documentationURL", "note", "limitSourceURL"]
    public static func publicURL(_ value: String) throws -> URL {
        guard value.utf8.count <= 2048, let parts = URLComponents(string: value), parts.scheme == "https", parts.user == nil,
              parts.password == nil, parts.fragment == nil, parts.port == nil || parts.port == 443,
              (parts.queryItems ?? []).allSatisfy({ ["lang", "locale", "language"].contains($0.name.lowercased()) }),
              let host = parts.host?.lowercased(), host.contains("."), !host.hasPrefix("["), !host.contains(":"),
              host.split(separator: ".").contains(where: { Int($0) == nil }),
              !["localhost", "local", "internal", "test", "invalid"].contains(host.split(separator: ".").last.map(String.init) ?? ""),
              !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.hasSuffix(".internal"), let url = parts.url else {
            throw ReadingError.invalid("公共目录只接受不含凭据的公网 HTTPS 地址；查询参数仅允许文档语言。")
        }
        return url
    }
    public static func validate(_ proposal: ModelCatalogProposal, evidence: [CatalogPublicEvidence]) throws -> ModelCatalogProposal {
        try proposalFromData(JSONEncoder().encode(proposal), evidence: evidence)
    }
    public static func proposalFromData(_ data: Data, evidence: [CatalogPublicEvidence]) throws -> ModelCatalogProposal {
        guard data.count <= 200_000, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schema", "summary", "providers"], root["schema"] as? String == "readingbook.model-catalog-proposal/v1" else {
            throw ReadingError.invalid("模型目录提案格式无效或含不允许的字段。")
        }
        _ = try text(root["summary"], maximum: 1200)
        guard let rows = root["providers"] as? [[String: Any]], !rows.isEmpty, rows.count <= 24 else { throw ReadingError.invalid("目录提案的服务商数量无效。") }
        try validateProviderRows(rows, evidence: evidence, requireEvidence: true)
        return try JSONDecoder().decode(ModelCatalogProposal.self, from: data)
    }
    public static func validateCatalog(_ catalog: ProviderCatalog) throws {
        guard catalog.verifiedAt.utf8.count <= 80, !catalog.providers.isEmpty, catalog.providers.count <= 32 else { throw ReadingError.invalid("公共模型目录大小无效。") }
        let data = try JSONEncoder().encode(catalog.providers)
        let rows = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        try validateProviderRows(rows, evidence: [], requireEvidence: false)
    }
    static func compact(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    static func text(_ value: Any?, maximum: Int) throws -> String {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= maximum, value.unicodeScalars.allSatisfy({ $0.value >= 32 || $0 == "\n" || $0 == "\t" }) else { throw ReadingError.invalid("目录文字字段为空、过长或无效。") }
        return value
    }
    static func validateProviderRows(_ rows: [[String: Any]], evidence: [CatalogPublicEvidence], requireEvidence: Bool) throws {
        var providerIDs = Set<String>()
        for row in rows {
            guard Set(row.keys).isSubset(of: providerKeys) else { throw ReadingError.invalid("目录不能修改连接、密钥、请求头或可执行字段。") }
            let id = try text(row["id"], maximum: 60)
            guard id.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil, providerIDs.insert(id).inserted else { throw ReadingError.invalid("目录服务商 ID 重复或无效。") }
            _ = try text(row["name"], maximum: 160)
            let endpoint = try publicURL(try text(row["baseURL"], maximum: 2048))
            guard endpoint.query == nil, endpoint.path.hasSuffix("/chat/completions") else { throw ReadingError.invalid("当前目录只能启用已实现的 Chat Completions 端点。") }
            let docs = try publicURL(try text(row["documentationURL"], maximum: 2048))
            if let note = row["note"], !(note is NSNull) { _ = try text(note, maximum: 1600) }
            if let aliases = row["aliases"], !(aliases is NSNull) {
                guard !requireEvidence, let aliases = aliases as? [String], aliases.count <= 16 else { throw ReadingError.invalid("AI 不能指定旧连接地址别名。") }
                for address in aliases { _ = try publicURL(address) }
            }
            var sources: [[String: Any]] = []
            if let raw = row["sources"], !(raw is NSNull) {
                guard let parsed = raw as? [[String: Any]], parsed.count <= 12 else { throw ReadingError.invalid("目录依据格式无效。") }; sources = parsed
            }
            if requireEvidence && sources.isEmpty { throw ReadingError.invalid("每个服务商必须引用本次实际读取的公共资料。") }
            for source in sources {
                guard Set(source.keys) == ["url", "quote"] else { throw ReadingError.invalid("目录依据包含不允许的字段。") }
                let url = try publicURL(try text(source["url"], maximum: 2048))
                let quote = try text(source["quote"], maximum: 4800)
                if requireEvidence {
                    guard quote.count >= 15, evidence.contains(where: { $0.url == url.absoluteString && compact($0.text).contains(compact(quote)) }) else { throw ReadingError.invalid("目录引文未在本次资料中实际读取，不能应用。") }
                }
            }
            if requireEvidence {
                guard sources.contains(where: { (try? publicURL($0["url"] as? String ?? "").host) == docs.host }) else { throw ReadingError.invalid("服务商说明须引用对应官方文档。") }
            }
            guard let models = row["models"] as? [[String: Any]], !models.isEmpty, models.count <= 120 else { throw ReadingError.invalid("模型目录数量无效。") }
            var ids = Set<String>()
            for model in models {
                guard Set(model.keys).isSubset(of: modelKeys) else { throw ReadingError.invalid("模型目录包含未实现的协议或私有字段。") }
                let mid = try text(model["id"], maximum: 240)
                guard mid.range(of: "^[a-zA-Z0-9_./:+-]+$", options: .regularExpression) != nil, ids.insert(mid).inserted else { throw ReadingError.invalid("模型 ID 重复或无效。") }
                if requireEvidence {
                    guard sources.contains(where: { containsExactModelID($0["quote"] as? String ?? "", modelID: mid) }) else { throw ReadingError.invalid("新增或修改的精确模型ID必须出现在实际读取的依据中。") }
                }
                if endpoint.host?.lowercased() == "opencode.ai" {
                    let isGo = endpoint.path.contains("/go/")
                    let wrongFamily = ["gpt-", "grok-", "claude-", "gemini-", "muse-"].contains(where: { mid.hasPrefix($0) })
                        || (isGo && (mid.hasPrefix("qwen") || mid == "minimax-m3" || mid.hasPrefix("minimax-m2")))
                    guard !wrongFamily else { throw ReadingError.invalid("此OpenCode型号要求尚未实现的API协议，不能放入Chat目录。") }
                    if requireEvidence {
                        guard sources.contains(where: { source in
                            let quote = source["quote"] as? String ?? ""
                            return containsExactModelID(quote, modelID: mid) && quote.contains("/chat/completions")
                        }) else { throw ReadingError.invalid("OpenCode型号必须引用同条Chat端点依据，不能套用其他协议。") }
                    }
                }
                _ = try text(model["name"], maximum: 240)
                for field in ["vision", "tools"] {
                    guard let flag = model[field] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw ReadingError.invalid("模型能力必须是布尔值。") }
                }
                guard ["max_tokens", "max_completion_tokens"].contains(model["tokenParameter"] as? String ?? "") else { throw ReadingError.invalid("目录只接受当前已实现的输出参数。") }
                for (field, maximum) in [("contextTokens", 4_194_304), ("maxOutputTokens", 1_048_576)] {
                    if let value = model[field], !(value is NSNull) {
                        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue,
                              number.doubleValue >= (field == "contextTokens" ? 1024 : 64), number.doubleValue <= Double(maximum) else { throw ReadingError.invalid("目录 token 上限无效；未知值应留空。") }
                        if requireEvidence {
                            guard limitIsProven(providerID: id, modelID: mid, field: field, value: number.intValue,
                                                limitSourceURL: (model["limitSourceURL"] as? String) ?? (model["documentationURL"] as? String), sources: sources, evidence: evidence) else {
                                throw ReadingError.invalid("目录额度未与同一型号、相应字段和实读来源绑定；未知值应留空。")
                            }
                        }
                    }
                }
                if let context = model["contextTokens"] as? NSNumber, let output = model["maxOutputTokens"] as? NSNumber {
                    guard output.intValue <= context.intValue else { throw ReadingError.invalid("最大输出不能超过已知总上下文窗口。") }
                }
                let modelDocs = try publicURL(try text(model["documentationURL"], maximum: 2048))
                if requireEvidence, modelDocs.host != docs.host { throw ReadingError.invalid("型号官方文档须与所属服务商文档域名一致。") }
                if let value = model["limitSourceURL"], !(value is NSNull) {
                    let url = try publicURL(try text(value, maximum: 2048))
                    if requireEvidence, !sources.contains(where: { $0["url"] as? String == url.absoluteString }) { throw ReadingError.invalid("额度资料须列入实际读取的依据。") }
                    if requireEvidence, url.host != docs.host && url.absoluteString != "https://models.dev/api.json" { throw ReadingError.invalid("额度来源须为同一服务商资料或可核对命名空间的Models.dev。") }
                }
                if let note = model["note"], !(note is NSNull) { _ = try text(note, maximum: 1600) }
            }
        }
    }
}

/// Independent file, never a library or credential writer. Reviews are host-held.
public actor ModelCatalogRepository {
    private struct Stored: Codable { var revision: Int; var overrides: [ProviderPreset]; var previous: [ProviderPreset]?; var verifiedAt: String }
    private let rootURL: URL
    private var reviews: [String: ModelCatalogReview] = [:]
    public init(rootURL: URL) { self.rootURL = rootURL }
    public func load(baseline: ProviderCatalog) throws -> ModelCatalogSnapshot {
        try ModelCatalogValidation.validateCatalog(baseline)
        let stored = try read()
        return ModelCatalogSnapshot(catalog: merge(baseline, stored.overrides, at: stored.verifiedAt), revision: stored.revision, canRollback: stored.previous != nil)
    }
    public func prepare(proposal: ModelCatalogProposal, evidence: [CatalogPublicEvidence], expectedRevision: Int, baseline: ProviderCatalog) throws -> ModelCatalogReview {
        let proposal = try ModelCatalogValidation.validate(proposal, evidence: evidence)
        let snapshot = try load(baseline: baseline)
        guard expectedRevision == snapshot.revision else { throw ReadingError.invalid("公共目录已更新，请重新检查差异。") }
        for provider in proposal.providers {
            if snapshot.catalog.providers.contains(where: { $0.id != provider.id && $0.baseURL == provider.baseURL }) {
                throw ReadingError.invalid("已有目录使用该接口，请保留原服务商ID更新，不能另造重复身份。")
            }
            let old = snapshot.catalog.providers.first(where: { $0.id == provider.id })
            if old?.baseURL != provider.baseURL {
                guard (provider.sources ?? []).contains(where: { source in
                    (try? ModelCatalogValidation.publicURL(source.url).host) == (try? ModelCatalogValidation.publicURL(provider.documentationURL).host)
                        && source.quote.contains(provider.baseURL)
                }) else { throw ReadingError.invalid("新增或变更的接口地址须出现在实际读取的官方引文中；不会把任意公网地址当已核实端点。") }
            }
        }
        let differences = try difference(proposal, in: snapshot.catalog)
        guard !differences.isEmpty else { throw ReadingError.invalid("没有需要应用的目录差异。") }
        let digest = try BookImporter.sha256(encode(proposal))
        let review = ModelCatalogReview(id: UUID().uuidString, expectedRevision: expectedRevision, proposal: proposal, differences: differences, digest: digest)
        if reviews.count >= 8 { reviews.removeAll() }
        reviews[review.id] = review
        return review
    }
    public func apply(review: ModelCatalogReview, baseline: ProviderCatalog) throws -> ModelCatalogSnapshot {
        guard reviews[review.id] == review, review.digest == (try BookImporter.sha256(encode(review.proposal))) else { throw ReadingError.invalid("目录审阅已失效，请重新检查。") }
        let current = try read()
        guard current.revision == review.expectedRevision, current.revision < Int.max else { throw ReadingError.invalid("公共目录版本冲突，原目录已保留。") }
        var overrides = current.overrides
        let effective = merge(baseline, overrides, at: current.verifiedAt)
        for proposed in review.proposal.providers {
            var provider = proposed
            if let old = effective.providers.first(where: { $0.id == provider.id }) {
                provider.models = old.models.filter { previous in !provider.models.contains(where: { $0.id == previous.id }) } + provider.models
                provider.aliases = Array(Set((old.aliases ?? []) + (old.baseURL == provider.baseURL ? [] : [old.baseURL]))).sorted()
            }
            if let index = overrides.firstIndex(where: { $0.id == provider.id }) { overrides[index] = provider } else { overrides.append(provider) }
        }
        let next = Stored(revision: current.revision + 1, overrides: overrides, previous: current.overrides, verifiedAt: ISO8601DateFormatter().string(from: Date()))
        try write(next, baseline: baseline)
        reviews.removeAll()
        return try load(baseline: baseline)
    }
    public func rollback(expectedRevision: Int, baseline: ProviderCatalog) throws -> ModelCatalogSnapshot {
        let current = try read()
        guard current.revision == expectedRevision, current.revision < Int.max, let previous = current.previous else { throw ReadingError.invalid("目录版本已改变，或没有上一版可回退。") }
        try write(Stored(revision: current.revision + 1, overrides: previous, previous: current.overrides, verifiedAt: ISO8601DateFormatter().string(from: Date())), baseline: baseline)
        reviews.removeAll()
        return try load(baseline: baseline)
    }
    private func merge(_ baseline: ProviderCatalog, _ overrides: [ProviderPreset], at date: String) -> ProviderCatalog {
        ProviderCatalog(verifiedAt: date.isEmpty ? baseline.verifiedAt : date, providers: baseline.providers.filter { old in !overrides.contains(where: { $0.id == old.id }) } + overrides)
    }
    private func read() throws -> Stored {
        let file = rootURL.appendingPathComponent("model-catalog.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Stored(revision: 0, overrides: [], previous: nil, verifiedAt: "") }
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) <= 2_000_000 else { throw ReadingError.invalid("公共目录缓存无效或过大，原文件已保留。") }
        let data = try Data(contentsOf: file)
        guard data.count <= 2_000_000 else { throw ReadingError.invalid("公共目录缓存超过限制。") }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        guard stored.revision >= 0, stored.overrides.count <= 32, (stored.previous?.count ?? 0) <= 32 else { throw ReadingError.invalid("公共目录缓存版本或大小无效。") }
        if !stored.overrides.isEmpty { try ModelCatalogValidation.validateCatalog(ProviderCatalog(verifiedAt: stored.verifiedAt, providers: stored.overrides)) }
        if let previous = stored.previous, !previous.isEmpty { try ModelCatalogValidation.validateCatalog(ProviderCatalog(verifiedAt: stored.verifiedAt, providers: previous)) }
        return stored
    }
    private func write(_ stored: Stored, baseline: ProviderCatalog) throws {
        try ModelCatalogValidation.validateCatalog(merge(baseline, stored.overrides, at: stored.verifiedAt))
        let data = try encode(stored)
        guard data.count <= 2_000_000 else { throw ReadingError.invalid("公共目录缓存已达限制，原目录保留。") }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let directory = try rootURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard directory.isDirectory == true, directory.isSymbolicLink != true else { throw ReadingError.invalid("公共目录保存位置无效。") }
        try data.write(to: rootURL.appendingPathComponent("model-catalog.json"), options: [.atomic])
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    private func difference(_ proposal: ModelCatalogProposal, in catalog: ProviderCatalog) throws -> [ModelCatalogDifference] {
        var rows: [ModelCatalogDifference] = []
        for provider in proposal.providers {
            let old = catalog.providers.first(where: { $0.id == provider.id })
            for (field, before, after) in [("名称", old?.name, provider.name), ("接口地址", old?.baseURL, provider.baseURL), ("官方文档", old?.documentationURL, provider.documentationURL), ("说明", old?.note, provider.note)] where before != after {
                rows.append(ModelCatalogDifference(path: provider.id + " / " + field, before: before ?? "新增", after: after ?? "未设置"))
            }
            for model in provider.models {
                let previous = old?.models.first(where: { $0.id == model.id })
                let values: [(String, String?, String?)] = [
                    ("名称", previous?.name, model.name),
                    ("上下文Token", previous?.contextTokens.map { String($0) }, model.contextTokens.map { String($0) }),
                    ("最大输出Token", previous?.maxOutputTokens.map { String($0) }, model.maxOutputTokens.map { String($0) }),
                    ("图像输入", previous.map { $0.vision ? "支持" : "未确认" }, model.vision ? "支持" : "未确认"),
                    ("工具调用", previous.map { $0.tools ? "支持" : "未确认" }, model.tools ? "支持" : "未确认"),
                    ("输出参数", previous?.tokenParameter, model.tokenParameter),
                    ("官方文档", previous?.documentationURL, model.documentationURL),
                    ("额度来源", previous?.limitSourceURL, model.limitSourceURL),
                    ("说明", previous?.note, model.note)
                ]
                for (field, before, after) in values where before != after {
                    rows.append(ModelCatalogDifference(path: provider.id + " / " + model.id + " / " + field,
                                                       before: before ?? (previous == nil ? "新增" : "未知"), after: after ?? "未知"))
                }
            }
        }
        return rows
    }
}
