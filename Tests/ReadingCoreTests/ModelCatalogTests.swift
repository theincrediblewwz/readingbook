import Foundation
import XCTest
@testable import ReadingCore

final class ModelCatalogTests: XCTestCase {
    private let docs = "https://api-docs.deepseek.com/api/list-models/"
    private let quote = "Model public-next has a context window of 32768 tokens and a maximum output of 4096 tokens."
    private func model(_ id: String = "public-next") -> ModelPreset {
        ModelPreset(id: id, name: id, contextTokens: 32768, maxOutputTokens: 4096, vision: false, tools: true,
                    tokenParameter: "max_tokens", documentationURL: docs, limitSourceURL: docs)
    }
    private func baseline() -> ProviderCatalog {
        ProviderCatalog(verifiedAt: "2026-10-14", providers: [ProviderPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1/chat/completions", documentationURL: docs, models: [model("existing")])])
    }
    private func proposal() -> ModelCatalogProposal {
        ModelCatalogProposal(summary: "按公开依据补充一个型号", providers: [ProviderPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1/chat/completions", documentationURL: docs, models: [model()], sources: [CatalogSource(url: docs, quote: quote)])])
    }
    private var evidence: [CatalogPublicEvidence] { [CatalogPublicEvidence(url: docs, text: quote)] }

    func testPublicCatalogueRejectsSecretsInventedEvidenceAndWrongTransport() throws {
        XCTAssertEqual(try ModelCatalogValidation.validate(proposal(), evidence: evidence), proposal())
        XCTAssertThrowsError(try ModelCatalogValidation.validate(proposal(), evidence: []))
        let original = try JSONEncoder().encode(proposal())
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        var providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        providers[0]["apiKey"] = "synthetic-secret"
        object["providers"] = providers
        XCTAssertThrowsError(try ModelCatalogValidation.proposalFromData(JSONSerialization.data(withJSONObject: object), evidence: evidence))
        var wrong = proposal(); wrong.providers[0].baseURL = "https://opencode.ai/inference/go/openai/v1/responses"
        XCTAssertThrowsError(try ModelCatalogValidation.validate(wrong, evidence: evidence))
        wrong = proposal(); wrong.providers[0].models[0].contextTokens = nil; wrong.providers[0].models[0].maxOutputTokens = nil
        XCTAssertNoThrow(try ModelCatalogValidation.validate(wrong, evidence: evidence), "未知限额留空而不猜测")
        wrong = proposal(); wrong.providers[0].models[0].limitSourceURL = "https://models.dev/api.json"
        XCTAssertThrowsError(try ModelCatalogValidation.validate(wrong, evidence: evidence))
        wrong = proposal(); wrong.providers[0].models[0].contextTokens = 65536
        XCTAssertThrowsError(try ModelCatalogValidation.validate(wrong, evidence: evidence), "实读引文不含的数值不能猜Max")
    }
    func testGoAndConsoleAreDistinctDespiteSharedHostAndAliases() throws {
        let go = ProviderPreset(id: "opencode-go", name: "Go", baseURL: "https://opencode.ai/inference/go/openai/v1/chat/completions", documentationURL: "https://opencode.ai/v2/docs/console/go/", models: [model()], aliases: ["https://opencode.ai/zen/go/v1/chat/completions"])
        let console = ProviderPreset(id: "opencode", name: "Console", baseURL: "https://opencode.ai/inference/openai/v1/chat/completions", documentationURL: "https://opencode.ai/v2/docs/console/models/", models: [model()])
        let catalog = ProviderCatalog(verifiedAt: "today", providers: [console, go])
        XCTAssertEqual(catalog.matchingProvider(baseURL: "https://opencode.ai/inference/go/openai/v1")?.id, "opencode-go")
        XCTAssertEqual(catalog.matchingProvider(baseURL: console.baseURL)?.id, "opencode")
        XCTAssertEqual(catalog.matchingProvider(baseURL: "https://opencode.ai/zen/go/v1")?.id, "opencode-go")
        XCTAssertNil(catalog.matchingProvider(baseURL: "https://opencode.ai/private/v1"))
        var ambiguous = catalog; var duplicate = go; duplicate.id = "duplicate-go"; ambiguous.providers.append(duplicate)
        XCTAssertNil(ambiguous.matchingProvider(baseURL: go.baseURL), "重复身份不能猜测哪个型号额度")
    }
    func testLimitsBindExactModelFieldAndProviderNamespace() throws {
        let other = "Model public-other has a context window of 65536 tokens and a maximum output of 8192 tokens."
        var crossModel = proposal()
        crossModel.providers[0].models[0].contextTokens = 65536
        crossModel.providers[0].sources?.append(CatalogSource(url: docs, quote: other))
        XCTAssertThrowsError(try ModelCatalogValidation.validate(crossModel, evidence: [CatalogPublicEvidence(url: docs, text: quote + "\n" + other)]))
        var swapped = proposal(); swapped.providers[0].models[0].contextTokens = 4096; swapped.providers[0].models[0].maxOutputTokens = 32768
        XCTAssertThrowsError(try ModelCatalogValidation.validate(swapped, evidence: evidence))
        let inconsistent = "Model public-next has a context window of 32768 tokens and a maximum output of 65536 tokens."
        var impossible = proposal(); impossible.providers[0].models[0].maxOutputTokens = 65536
        impossible.providers[0].sources = [CatalogSource(url: docs, quote: inconsistent)]
        XCTAssertThrowsError(try ModelCatalogValidation.validate(impossible, evidence: [CatalogPublicEvidence(url: docs, text: inconsistent)]))

        let exact: [String: Any] = ["id": "public-next", "limit": ["context": 32768, "output": 4096]]
        let gateway: [String: Any] = ["id": "public-next", "limit": ["context": 65536, "output": 8192]]
        let metadata: [String: Any] = ["deepseek": ["models": [exact]], "opencode-go": ["models": [gateway]]]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), as: UTF8.self)
        let exactQuote = String(decoding: try JSONSerialization.data(withJSONObject: exact, options: [.sortedKeys]), as: UTF8.self)
        let gatewayQuote = String(decoding: try JSONSerialization.data(withJSONObject: gateway, options: [.sortedKeys]), as: UTF8.self)
        var structured = proposal(); structured.providers[0].models[0].limitSourceURL = "https://models.dev/api.json"
        structured.providers[0].sources?.append(CatalogSource(url: "https://models.dev/api.json", quote: exactQuote))
        let reads = evidence + [CatalogPublicEvidence(url: "https://models.dev/api.json", text: raw)]
        XCTAssertNoThrow(try ModelCatalogValidation.validate(structured, evidence: reads))
        let otherFirst = String(decoding: try JSONSerialization.data(withJSONObject: ["opencode-go": ["models": [exact]]], options: [.sortedKeys]), as: UTF8.self)
        let correctLater = String(decoding: try JSONSerialization.data(withJSONObject: ["deepseek": ["models": [exact]]], options: [.sortedKeys]), as: UTF8.self)
        XCTAssertNoThrow(try ModelCatalogValidation.validate(structured, evidence: evidence + [CatalogPublicEvidence(url: "https://models.dev/api.json", text: otherFirst), CatalogPublicEvidence(url: "https://models.dev/api.json", text: correctLater)]), "分批读取同一URL，需查找匹配命名空间而非只取首片")
        structured.providers[0].models[0].contextTokens = 65536; structured.providers[0].models[0].maxOutputTokens = 8192
        structured.providers[0].sources = [CatalogSource(url: docs, quote: quote), CatalogSource(url: "https://models.dev/api.json", quote: gatewayQuote)]
        XCTAssertThrowsError(try ModelCatalogValidation.validate(structured, evidence: reads), "同名型号的网关额度不能套到厂商直连")
    }
    func testApplyUpsertsAndRollbackCannotTouchProfilesKeysOrOtherFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingBook-Catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("private-profile-and-key.fixture")
        let privateBytes = Data("unrelated connection and synthetic key stay untouched".utf8)
        try privateBytes.write(to: marker)
        let repository = ModelCatalogRepository(rootURL: root)
        let first = try await repository.load(baseline: baseline())
        XCTAssertEqual(first.revision, 0); XCTAssertFalse(first.canRollback)
        let review = try await repository.prepare(proposal: proposal(), evidence: evidence, expectedRevision: 0, baseline: baseline())
        XCTAssertTrue(review.differences.contains(where: { $0.path.contains("public-next") }))
        let next = try await repository.apply(review: review, baseline: baseline())
        XCTAssertEqual(next.revision, 1); XCTAssertTrue(next.canRollback)
        XCTAssertEqual(next.catalog.providers[0].models.map(\.id), ["existing", "public-next"])
        XCTAssertEqual(try Data(contentsOf: marker), privateBytes)
        var arbitraryEndpoint = proposal(); arbitraryEndpoint.providers[0].baseURL = "https://api.example.com/v1/chat/completions"
        do { _ = try await repository.prepare(proposal: arbitraryEndpoint, evidence: evidence, expectedRevision: 1, baseline: baseline()); XCTFail("未在官方依据出现的新地址不能预览成已核实端点") } catch {}
        do { _ = try await repository.apply(review: review, baseline: baseline()); XCTFail("审阅不能重放") } catch {}
        do { _ = try await repository.rollback(expectedRevision: 0, baseline: baseline()); XCTFail("过期版本不能回退") } catch {}
        let loaded = try await ModelCatalogRepository(rootURL: root).load(baseline: baseline())
        XCTAssertEqual(loaded, next)
        let restored = try await repository.rollback(expectedRevision: 1, baseline: baseline())
        XCTAssertEqual(restored.catalog.providers[0].models.map(\.id), ["existing"])
        XCTAssertEqual(try Data(contentsOf: marker), privateBytes)
    }
    func testPublicReaderAllowlistAndNetworkAddressGuards() throws {
        let reader = try ModelCatalogPublicReader(additionalOfficialURLs: ["https://official.example.com/models"])
        XCTAssertTrue(reader.allows(docs)); XCTAssertTrue(reader.allows("https://official.example.com/models"))
        XCTAssertFalse(reader.allows("https://official.example.com/other"))
        for address in ["https://127.0.0.1/", "https://[::1]/", "http://example.com", "https://u:p@example.com/", "https://service.local/", "file:///secret", "https://evil.example.com/models"] {
            XCTAssertFalse(reader.allows(address))
        }
        for address in ["127.0.0.1", "10.2.3.4", "172.16.4.5", "192.168.0.1", "169.254.169.254", "100.64.0.1", "::1", "::ffff:127.0.0.1", "fd00::1", "2001:db8::1"] {
            XCTAssertFalse(ModelCatalogPublicReader.isPublicIP(address), address)
        }
        XCTAssertTrue(ModelCatalogPublicReader.isPublicIP("1.1.1.1"))
        XCTAssertTrue(ModelCatalogPublicReader.isPublicIP("2606:4700:4700::1111"))
        XCTAssertFalse(ModelCatalogPublicReader.pageText("<script>stealKey()</script><p>context 32768</p>").contains("stealKey"))
    }
    func testCatalogueAssistantOnlyReceivesPublicMetadataAndCannotApply() async throws {
        let output = String(decoding: try JSONEncoder().encode(proposal()), as: UTF8.self)
        let recorder = CatalogAssistantRecorder(finalOutput: output, docs: docs)
        let quote = quote
        let assistant = ModelCatalogAssistant(read: { address in
            XCTAssertEqual(address, "https://api-docs.deepseek.com/api/list-models/")
            return CatalogPublicEvidence(url: address, text: quote)
        }, complete: { try await recorder.complete($0) })
        var settings = ProviderSettings(baseURL: "https://personal-gateway.example.com/v1", model: "synthetic-model", maxRequestsPerRun: 2, maxOutputTokens: 4096, contextWindowTokens: 128_000)
        settings.transportSessionID = "reader-session-not-public"
        let result = try await assistant.inspect(request: "检查公开型号", catalog: baseline(), settings: settings, apiKey: "synthetic-private-key")
        XCTAssertEqual(result.proposal, proposal()); XCTAssertEqual(result.requestsUsed, 2); XCTAssertEqual(result.readsUsed, 1)
        let bodies = await recorder.bodies()
        XCTAssertFalse(bodies.joined().contains("synthetic-private-key"))
        XCTAssertFalse(bodies.joined().contains("personal-gateway.example.com"))
        XCTAssertFalse(bodies.joined().contains("reader-session-not-public"))
        let firstBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(bodies[0].utf8)) as? [String: Any])
        let definitions = try XCTUnwrap(firstBody["tools"] as? [[String: Any]])
        let names = definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(Set(names), ["catalog_read", "catalog_public_feed"])
        let lastBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(bodies.last).utf8)) as? [String: Any])
        XCTAssertNil(lastBody["tools"], "最后一轮只形成提案，不再调用工具")
    }
    func testGoUsesHonestClientAndHostSessionWithoutPersistingSessionIdentifier() throws {
        var settings = ProviderSettings(baseURL: "https://opencode.ai/inference/go/openai/v1", model: "glm-5.3", maxOutputTokens: 4096, contextWindowTokens: 128_000)
        settings.transportSessionID = "readingbook-synthetic-conversation"
        let prepared = try ProviderClient.prepare(messages: [["role": "user", "content": "test"]], tools: [], settings: settings, apiKey: "synthetic", remainingTokens: 128_000)
        XCTAssertEqual(prepared.request.value(forHTTPHeaderField: "User-Agent"), "ReadingBook/0.15")
        XCTAssertEqual(prepared.request.value(forHTTPHeaderField: "x-opencode-session"), settings.transportSessionID)
        let saved = try JSONEncoder().encode(settings)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("readingbook-synthetic-conversation"))
        XCTAssertNil(try JSONDecoder().decode(ProviderSettings.self, from: saved).transportSessionID)
        settings.baseURL = "https://api.deepseek.com/v1"
        let other = try ProviderClient.prepare(messages: [["role": "user", "content": "test"]], tools: [], settings: settings, apiKey: "synthetic", remainingTokens: 128_000)
        XCTAssertNil(other.request.value(forHTTPHeaderField: "x-opencode-session"))
    }
    func testLongPublicReadsRebuildBoundedFinalProposalBeforeBudgetIsSpent() async throws {
        let output = String(decoding: try JSONEncoder().encode(proposal()), as: UTF8.self)
        let recorder = CatalogAssistantRecorder(finalOutput: output, docs: docs, flood: true)
        let quote = quote
        let assistant = ModelCatalogAssistant(read: { address in
            CatalogPublicEvidence(url: address, text: quote + "\n" + String(repeating: "长网页细节", count: 24_000))
        }, complete: { try await recorder.complete($0) })
        let settings = ProviderSettings(baseURL: "https://api.example.com/v1", model: "synthetic", maxRequestsPerRun: 8, maxOutputTokens: 4096, contextWindowTokens: 65_536)
        let result = try await assistant.inspect(request: "核对目录", catalog: baseline(), settings: settings, apiKey: "synthetic")
        XCTAssertEqual(result.proposal, proposal()); XCTAssertEqual(result.requestsUsed, 2)
        XCTAssertGreaterThan(result.readsUsed, 0); XCTAssertLessThanOrEqual(result.readsUsed, 8)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(result.evidence).count, 24_000)
        let bodies = await recorder.bodies()
        let final = try XCTUnwrap(bodies.last)
        let data = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(final.utf8)) as? [String: Any])
        XCTAssertNil(data["tools"]); XCTAssertFalse(final.contains("OLD_TOOL_PREAMBLE"))
        XCTAssertTrue(final.contains("public-next")); XCTAssertLessThan(final.utf8.count, 65_536)
        let charged = await recorder.chargedTokens()
        XCTAssertLessThanOrEqual(charged, 65_536)
    }
}

private actor CatalogAssistantRecorder {
    let finalOutput: String
    let docs: String
    let flood: Bool
    private var captured: [String] = []
    private var charged = 0
    init(finalOutput: String, docs: String, flood: Bool = false) { self.finalOutput = finalOutput; self.docs = docs; self.flood = flood }
    func bodies() -> [String] { captured }
    func chargedTokens() -> Int { charged }
    func complete(_ prepared: ProviderClient.Prepared) throws -> ProviderClient.Result {
        captured.append(String(decoding: prepared.request.httpBody ?? Data(), as: UTF8.self))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: prepared.request.httpBody ?? Data()) as? [String: Any])
        let outputLimit = body["max_tokens"] as? Int ?? body["max_completion_tokens"] as? Int ?? 0
        let cost = flood ? prepared.estimatedInputTokens + outputLimit : 100
        charged += cost
        if captured.count == 1 {
            let args = try JSONSerialization.data(withJSONObject: ["url": docs, "length": 12000])
            let calls = (0..<(flood ? 8 : 1)).map { ProviderClient.ToolCall(id: "catalog-call-\($0)", type: "function", function: .init(name: "catalog_read", arguments: String(decoding: args, as: UTF8.self))) }
            return ProviderClient.Result(message: .init(role: "assistant", content: flood ? String(repeating: "OLD_TOOL_PREAMBLE", count: 8000) : nil, refusal: nil, tool_calls: calls, reasoning_content: nil), finishReason: "tool_calls", tokenCost: cost)
        }
        return ProviderClient.Result(message: .init(role: "assistant", content: finalOutput, refusal: nil, tool_calls: nil, reasoning_content: nil), finishReason: "stop", tokenCost: cost)
    }
}
