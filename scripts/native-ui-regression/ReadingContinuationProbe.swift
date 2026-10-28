import AppKit
import Foundation
import Darwin
@testable import ReadingBook
@testable import ReadingCore

/// There is no socket implementation here. Every production reader uses this
/// transport; only an explicitly enabled, fixed planning response may succeed.
private actor ContinuationOfflineTransport {
    private(set) var calls = 0
    private(set) var planningCalls = 0
    private(set) var rejectedCalls = 0
    var allowsPlanning = false
    func enablePlanning() { allowsPlanning = true }
    func perform(_ prepared: ProviderClient.Prepared) throws -> ProviderClient.Result {
        calls += 1
        guard prepared.request.url?.host == "127.0.0.1", prepared.request.url?.port == 1,
              let body = prepared.request.httpBody,
              let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            rejectedCalls += 1; throw ReadingError.invalid("离线探针拒绝非本地fixture请求。")
        }
        let tools = payload["tools"] as? [[String: Any]] ?? []
        if allowsPlanning, tools.contains(where: { ($0["function"] as? [String: Any])?["name"] as? String == "reading_plan" }) {
            planningCalls += 1
            let arguments = try JSONSerialization.data(withJSONObject: ["methodIDs": ["genre.history"],
                "rationale": "离线固定响应：更新阅读方案，不生成正文。", "focus": ["原文中的因果"]])
            return ProviderClient.Result(message: .init(role: "assistant", content: nil, refusal: nil,
                tool_calls: [.init(id: "offline-plan-\(planningCalls)", type: "function",
                    function: .init(name: "reading_plan", arguments: String(decoding: arguments, as: UTF8.self)))], reasoning_content: nil),
                finishReason: "tool_calls", tokenCost: 10)
        }
        rejectedCalls += 1
        throw ReadingError.invalid("离线探针拒绝意外正文或隐式综合请求。")
    }
}

@main struct ReadingContinuationProbe {
    @MainActor private static var stage = "fixture-setup"
    private struct Fixture {
        var root: URL
        var source: URL
        var owner: LibraryRepository
        var project: BookProject
        var note: DocumentRecord
        var noteBody: String
    }
    @MainActor static func main() async {
        var output: URL?
        var result: [String: Any] = ["status": "failed", "realNetworkRequests": 0, "guiLaunched": false]
        do {
            let args = CommandLine.arguments
            guard args.count == 5, args[1] == "--workspace", args[3] == "--output" else {
                throw ReadingError.invalid("用法：reading-continuation-probe --workspace WORKSPACE --output NEW_DIRECTORY")
            }
            let workspace = URL(fileURLWithPath: args[2]).standardizedFileURL.resolvingSymlinksInPath()
            let expected = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            let destination = URL(fileURLWithPath: args[4]).standardizedFileURL.resolvingSymlinksInPath()
            guard workspace == expected, FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Package.swift").path),
                  destination != workspace, destination.pathComponents.starts(with: workspace.pathComponents),
                  !FileManager.default.fileExists(atPath: destination.path), Bundle.main.bundleIdentifier != "org.readingbook.app" else {
                throw ReadingError.invalid("探针只允许本工作区中全新的独立输出目录。")
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            output = destination
            UserDefaults.standard.setVolatileDomain([
                "library.root.path.v1": destination.appendingPathComponent("unused-default-library").path,
                "service-profiles": Data("[]".utf8), "query-memory-enabled": false,
                "reading.hoverTranslation": false], forName: UserDefaults.argumentDomain)
            defer {
                let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
                if domain != "org.readingbook.app" { UserDefaults.standard.removePersistentDomain(forName: domain) }
            }
            result.merge(try await run(in: destination)) { _, value in value }; result["status"] = "passed"
        } catch { result["error"] = error.localizedDescription; result["stage"] = stage }
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        if let output { try? data.write(to: output.appendingPathComponent("result.json"), options: .atomic) }
        print(String(decoding: data, as: UTF8.self)); exit(result["status"] as? String == "passed" ? 0 : 1)
    }
    private static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw ReadingError.invalid(message) }
    }
    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    @MainActor private static func waitUntil(_ title: String, _ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return }; try await Task.sleep(for: .milliseconds(5))
        }
        throw ReadingError.invalid("离线续读探针超时：" + title)
    }
    @MainActor private static func settled(_ store: AppStore) async throws {
        try await waitUntil("任务和历史写入收尾") { !store.isSmartReadingRunning && store.readingTask == nil && store.pendingAIHistoryWrites == 0 }
    }
    private static var configuration: ReadingExecutionConfiguration {
        .init(granularity: .page, steps: [ReadingExecutionStep(id: "understand", title: "解释本页内容")])
    }
    private static func selection(_ first: Int, _ last: Int) -> SmartReadingSelection {
        .init(scope: .pageRange, pageStart: first, pageEnd: last, execution: configuration)
    }
    private static func seedCompletion(_ work: ReadingAnalysisChunk, in project: inout BookProject) throws {
        guard let session = project.smartReading else { throw ReadingError.invalid("fixture缺少session") }
        let allowed = Set(work.unitIDs)
        let grant = ReadingAnalysisAuthority.Grant(bookID: project.id, sessionID: session.id, sourceHash: project.sourceHash,
            chunk: work, unitHashes: session.unitHashes.filter { allowed.contains($0.key) })
        let arguments = try JSONSerialization.data(withJSONObject: ["unitIDs": work.unitIDs, "completedStepIDs": work.stepIDs,
            "markdown": "离线保留分析：" + work.title, "evidence": work.unitIDs.map { id in
                ["unitID": id, "quote": project.units.first { $0.id == id }!.text]
            }])
        try ReadingAnalysisAuthority.$current.withValue(grant) {
            _ = try SmartReadingRuntime.completeAnalysis(arguments: arguments, in: &project, allowedUnitIDs: allowed)
        }
    }
    @MainActor private static func fixture(in directory: URL, pages: Int = 200, completed: Int = 100,
                                            textPadding: Int = 0, title: String = "离线续读书") async throws -> Fixture {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let units = (1...pages).map { page in SourceUnit(id: "u\(page)", order: page - 1, chapter: "合成章节", page: page,
            text: "第\(page)页，甲在此读书。" + String(repeating: "文", count: textPadding)) }
        let bytes = Data(units.map(\.text).joined(separator: "\n\n").utf8)
        let source = directory.appendingPathComponent("fixture.txt"); try bytes.write(to: source)
        var project = BookProject(id: "70000000-0000-4000-8000-000000000001", title: title, originalName: "fixture.txt",
            sourceHash: try BookImporter.sha256(bytes), units: units)
        PluginEngine.seed(&project); project.plan = ReadingPlan(methodIDs: ["genre.history"])
        project.smartReading = try SmartReadingRuntime.freeze(selection(1, max(1, completed)), in: project, currentUnitID: "u1")
        project.smartReading?.isPlanConfirmed = true
        if completed > 0 {
            for work in try SmartReadingRuntime.analysisChunks(in: project) { try seedCompletion(work, in: &project) }
        }
        let root = directory.appendingPathComponent("library"), owner = LibraryRepository(rootURL: root)
        project = try await owner.create(project, sourceURL: source)
        let note = DocumentRecord(id: "user-note", title: "必须保留的用户笔记")
        let noteBody = "# 原笔记\n\n保留 e\u{301}、🙂 和 $x^2$，不属于可重生成内容。\n"
        project = try await owner.saveDocument(project: project, document: note, markdown: noteBody)
        return Fixture(root: root, source: source, owner: owner, project: project, note: note, noteBody: noteBody)
    }
    @MainActor private static func store(_ fixture: Fixture, transport: ContinuationOfflineTransport) -> AppStore {
        let coordinator = AIRequestCoordinator(transport: { try await transport.perform($0) })
        let store = AppStore(sharedAIRequests: coordinator, connectionProbe: { _, _ in throw ReadingError.invalid("离线探针禁用连接测试") })
        store.libraryRootURL = fixture.root; store.repository = fixture.owner; store.books = [fixture.project]
        store.bookID = fixture.project.id; store.selectedUnitID = "u1"; store.sourceFileURL = fixture.source
        store.settings = ProviderSettings(baseURL: "http://127.0.0.1:1/disabled", model: "offline-continuation-fixture",
            maxRequestsPerRun: 20, maxOutputTokens: 1_000, contextWindowTokens: 128_000)
        store.apiKey = ""; store.queryMemoryEnabled = false
        return store
    }
    private static func canonical(_ fixture: Fixture) async throws -> BookProject {
        guard let project = try await fixture.owner.loadReport().projects.first(where: { $0.id == fixture.project.id }) else {
            throw ReadingError.invalid("fixture书库无法读取")
        }
        return project
    }
    @MainActor private static func run(in directory: URL) async throws -> [String: Any] {
        var checks: [[String: Any]] = []
        let fixture = try await fixture(in: directory.appendingPathComponent("core-flow"))
        let transport = ContinuationOfflineTransport(), store = store(fixture, transport: transport)
        let before = try encoded(await canonical(fixture))
        stage = "readonly-deterministic-overlap"
        let a = try await store.previewReadingContinuation(selection(50, 200), intent: .continueMissing)
        let b = try await store.previewReadingContinuation(selection(50, 200), intent: .continueMissing)
        try require(a == b && a.selectedUnitCount == 151 && a.selectedPageCount == 151 && a.reusedUnitCount == 51 && a.newUnitCount == 100,
            "AppStore重叠预览必须确定性显示151单元、沿用51及新增100。")
        let previewCalls = await transport.calls, afterPreview = try encoded(await canonical(fixture))
        try require(previewCalls == 0 && afterPreview == before, "只读预览不能提交或调用模型。")
        checks.append(["name": "readonly-deterministic-overlap", "status": "passed", "selected": 151, "reused": 51, "new": 100])
        stage = "complete-range-noop"
        let noop = try await store.previewReadingContinuation(selection(1, 100), intent: .continueMissing)
        try require(!noop.hasWork, "重复完整范围不能虚构待处理工作。")
        store.startReadingContinuation(selection(1, 100), intent: .continueMissing, expectedPreview: noop)
        try await settled(store)
        let afterNoop = try encoded(await canonical(fixture)), noopCalls = await transport.calls
        try require(afterNoop == before && noopCalls == 0, "no-op不能建立新session、提交操作或调用模型。")
        checks.append(["name": "complete-range-noop-no-commit", "status": "passed"])
        stage = "redo-confirmation-guard"
        store.errorMessage = nil; store.startReadingContinuation(selection(1, 100), intent: .reanalyze)
        try require(store.readingTask == nil && !store.isSmartReadingRunning && store.errorMessage?.contains("确认") == true,
            "重做没有确认预览时必须同步拒绝。")
        let afterRejectedRedo = try encoded(await canonical(fixture)), redoCalls = await transport.calls
        try require(afterRejectedRedo == before && redoCalls == 0, "被拒绝重做不能改库或调用模型。")
        checks.append(["name": "redo-requires-confirmed-preview", "status": "passed"])
        stage = "stale-fingerprint"
        let stale = try await store.previewReadingContinuation(selection(50, 200), intent: .continueMissing)
        var changed = try await canonical(fixture); changed.plan?.focus = ["在预览之后改变阅读目标"]
        changed = try await fixture.owner.save(changed); _ = store.publish(changed)
        let changedBefore = try encoded(await canonical(fixture)); store.errorMessage = nil
        store.startReadingContinuation(selection(50, 200), intent: .continueMissing, expectedPreview: stale)
        try await settled(store)
        let afterStale = try encoded(await canonical(fixture)), staleCalls = await transport.calls
        try require(store.errorMessage != nil && afterStale == changedBefore && staleCalls == 0,
            "旧fingerprint必须在提交/正文请求前被拒绝。")
        checks.append(["name": "stale-semantic-fingerprint-rejected", "status": "passed"])
        stage = "run-token"
        let oldRun = UUID(), newRun = UUID()
        let dummy: Task<Void, Never> = Task { try? await Task.sleep(for: .seconds(1)) }
        store.readingRunID = newRun; store.readingTask = dummy; store.isSmartReadingRunning = true; store.activeReadingUnitID = "u1"
        store.finishReadingRun(oldRun)
        try require(store.readingRunID == newRun && store.readingTask != nil && store.isSmartReadingRunning && store.activeReadingUnitID == "u1",
            "旧run token收尾不能清理新的阅读任务。")
        store.finishReadingRun(newRun); dummy.cancel(); await dummy.value
        try require(store.readingRunID == nil && store.readingTask == nil && !store.isSmartReadingRunning, "所属run必须正常收尾。")
        checks.append(["name": "old-run-cannot-clear-new-run", "status": "passed"])
        stage = "confirmation-and-plan-history"
        checks += try await checkConfirmationAndHistory(in: directory.appendingPathComponent("plan-history"))
        stage = "cross-library-owner-fences"
        checks += try await checkOwnerFences(in: directory.appendingPathComponent("owner-fences"))
        stage = "legacy-no-implicit-synthesis"
        checks += try await checkLegacyNoSynthesis(in: directory.appendingPathComponent("legacy"))
        try require(try await fixture.owner.readDocument(bookID: fixture.project.id, document: fixture.note) == fixture.noteBody,
            "任何预览/拒绝路径都不能改写原笔记。")
        return ["checks": checks, "checkCount": checks.count, "fixtureBookID": fixture.project.id,
                "previewRequests": previewCalls, "unplannedRequests": await transport.rejectedCalls]
    }
    @MainActor private static func checkConfirmationAndHistory(in directory: URL) async throws -> [[String: Any]] {
        var fixture = try await fixture(in: directory)
        var proposed = fixture.project; proposed.plan?.rationale = "本地待确认方案"
        var pending = try BookSchemeRuntime.stageAIProposal(from: fixture.project, proposed: proposed)
        pending.smartReading?.status = .awaitingConfirmation; pending.smartReading?.isPlanConfirmed = false
        fixture.project = try await fixture.owner.save(pending)
        let transport = ContinuationOfflineTransport(), confirmedStore = store(fixture, transport: transport)
        guard let selected = pending.bookSchemes?.pending?.selection else { throw ReadingError.invalid("fixture缺少待确认方案") }
        confirmedStore.confirmSmartReading(selected); try await settled(confirmedStore)
        let ready = try await canonical(fixture), confirmCalls = await transport.calls
        try require(ready.smartReading?.status == .ready && ready.smartReading?.isPlanConfirmed == true &&
            ready.bookSchemes?.pending == nil && confirmCalls == 0 && confirmedStore.requestedWorkspaceRoute == "workflow",
            "确认方案只能保存ready并返回预览，不能发起正文分析。")
        let first = try ReadingContinuationRuntime.prepare(selection: selection(50, 200), intent: .continueMissing, in: ready).candidate
        let second = try ReadingContinuationRuntime.prepare(selection: selection(1, 200), intent: .continueMissing, in: first).candidate
        let priorIDs = Set(try ReadingContinuationRuntime.history(in: second).map(\.id))
        try require(priorIDs.count >= 2, "fixture须包含至少两次真实归档任务")
        let priorMarkdown = (second.smartReading?.analysisCheckpoints ?? []).map(\.markdown)
        fixture.project = try await fixture.owner.save(second)
        let replanner = store(fixture, transport: transport)
        await transport.enablePlanning()
        replanner.prepareSmartReading(selection(1, 200)); replanner.confirmPlanRegeneration()
        try await settled(replanner)
        let after = try await canonical(fixture), callsAfterPlan = await transport.calls
        let retainedIDs = Set(try ReadingContinuationRuntime.history(in: after).map(\.id))
        try require(replanner.errorMessage == nil && after.bookSchemes?.pending != nil && callsAfterPlan == 1,
            "固定规划响应必须真实生成待确认方案；尚不生成正文。")
        try require(priorIDs.isSubset(of: retainedIDs) && after.smartReading?.analysisCheckpoints?.map(\.markdown) == priorMarkdown,
            "成功重新预读不能丢失既有历史引用或改写旧分析正文。")
        for id in priorIDs {
            let detail = try ReadingContinuationRuntime.historyDetails(sessionID: id, in: after)
            try require(detail.missingCheckpointIDs.isEmpty, "重新预读后旧历史必须仍可解析全部真实引用。")
        }
        try require(try await fixture.owner.readDocument(bookID: fixture.project.id, document: fixture.note) == fixture.noteBody,
            "确认/重新预读不能改动用户笔记。")
        return [["name": "confirm-plan-ready-without-reading", "status": "passed", "modelCalls": confirmCalls],
            ["name": "successful-replanning-retains-history", "status": "passed", "priorHistoryCount": priorIDs.count,
             "retainedHistoryCount": retainedIDs.count, "planningFixtureCalls": callsAfterPlan]]
    }
    @MainActor private static func checkOwnerFences(in directory: URL) async throws -> [[String: Any]] {
        let original = try await fixture(in: directory.appendingPathComponent("original"), pages: 600, completed: 0, textPadding: 2_048)
        let replacement = try await fixture(in: directory.appendingPathComponent("replacement"), pages: 600, completed: 0,
            textPadding: 2_048, title: "同ID异库不得写入")
        let transport = ContinuationOfflineTransport(), target = store(original, transport: transport)
        let beforeOld = try encoded(await canonical(original)), beforeNew = try encoded(await canonical(replacement))
        var entered = false
        let pending = Task { @MainActor in
            entered = true
            return try await target.previewReadingContinuation(selection(1, 600), intent: .continueMissing)
        }
        try await waitUntil("preview已开始") { entered }
        target.libraryRootURL = replacement.root; target.repository = replacement.owner
        target.books = [replacement.project]; target.sourceFileURL = replacement.source
        var rejected = false
        do { _ = try await pending.value } catch is CancellationError { rejected = true }
        try require(rejected, "同ID异库的迟到preview必须被owner守卫拒绝，不能展示为当前库结果。")
        let afterPreviewOld = try encoded(await canonical(original)), afterPreviewNew = try encoded(await canonical(replacement))
        try require(afterPreviewOld == beforeOld && afterPreviewNew == beforeNew, "跨库预览必须保持两个库都不变。")
        target.libraryRootURL = original.root; target.repository = original.owner
        target.books = [original.project]; target.sourceFileURL = original.source
        let template = BookSchemeTemplate(name: "只应在原库预览", configuration: BookSchemeConfiguration(project: original.project))
        target.stageBookSchemeTemplate(template)
        try require(target.bookSchemeWriteID != nil, "必须实际进入方案异步保存路径")
        // No suspension: the queued write cannot start until after this owner switch.
        target.libraryRootURL = replacement.root; target.repository = replacement.owner
        target.books = [replacement.project]; target.sourceFileURL = replacement.source
        try await waitUntil("旧方案写入退出") { target.bookSchemeWriteID == nil }
        let afterSchemeOld = try encoded(await canonical(original)), afterSchemeNew = try encoded(await canonical(replacement))
        let calls = await transport.calls
        try require(afterSchemeOld == beforeOld && afterSchemeNew == beforeNew && calls == 0,
            "旧方案写入不能改动新库，也不能在owner失效后回写原库。")
        return [["name": "late-preview-same-id-other-library-rejected", "status": "passed"],
            ["name": "scheme-write-owner-fence", "status": "passed", "bothLibrariesUnchanged": true]]
    }
    @MainActor private static func checkLegacyNoSynthesis(in directory: URL) async throws -> [[String: Any]] {
        var fixture = try await fixture(in: directory, pages: 1, completed: 0)
        var project = fixture.project
        project.methods.append(ReadingMethod(id: "legacy-method", name: "旧逐段方法", goal: "只保留逐段账本", steps: ["说明这一段"],
            executions: [ReadingStepExecution(stepIndex: 0, actionID: "ai.analyze")]))
        project.plan = ReadingPlan(methodIDs: ["legacy-method"])
        project.smartReading = try SmartReadingRuntime.freeze(.init(scope: .wholeBook), in: project, currentUnitID: "u1")
        project.smartReading?.isPlanConfirmed = true
        let unit = project.units[0], paragraphs = try ReadingLedger.paragraphs(for: unit, in: project)
        project.receiptBatch = try ReadingLedger.makeBatch(unit: unit, paragraphs: paragraphs)
        let receipt: [String: Any] = ["batchID": project.receiptBatch!.id, "receipts": paragraphs.map {
            ["paragraphID": $0.id, "textHash": $0.textHash, "summary": "甲在此阅读。", "startQuote": $0.startQuote,
             "endQuote": $0.endQuote, "issues": []] as [String: Any]
        }]
        _ = try PluginEngine.apply(name: "read_receipt", arguments: JSONSerialization.data(withJSONObject: receipt),
            to: &project, allowedUnitIDs: [unit.id]); project.receiptBatch = nil
        guard let task = try ReadingWorkflowRuntime.nextTask(for: unit, in: project) else { throw ReadingError.invalid("legacy fixture缺少真实步骤") }
        project = try await ReadingWorkflowRuntime.perform(task, in: project, services: ReadingWorkflowServices { task, original in
            var result = original
            try ReadingWorkflowRuntime.complete(stepID: task.requirement.stepID,
                output: ReadingWorkflowOutput(result: "甲在这里阅读。", paragraphIDs: task.input.paragraphIDs,
                    evidence: [Evidence(unitID: "u1", quote: unit.text)]), to: &result, allowedUnitIDs: ["u1"])
            return result
        })
        project.insights.append(.init(id: "analysis-u1", unitIDs: ["u1"], markdown: "保留的旧逐段解读。"))
        var entry = CoverageEntry(); entry.status = .completed; project.coverage["u1"] = entry
        let prepared = try ReadingContinuationRuntime.prepare(selection: .init(scope: .wholeBook), intent: .continueMissing, in: project)
        try require(prepared.candidate.smartReading?.selection.execution == nil && prepared.preview.pendingScopeJobCount == 0,
            "旧逐段续读必须保留nil配置且不增加范围总结。")
        fixture.project = try await fixture.owner.save(prepared.candidate)
        let transport = ContinuationOfflineTransport(), target = store(fixture, transport: transport)
        // Exercise the actual prepared-session execution/finish path, rather
        // than letting the no-op admission path mask an implicit synthesis.
        target.startReading(); try await settled(target)
        let after = try await canonical(fixture), calls = await transport.calls
        try require(target.errorMessage == nil && after.smartReading?.status == .completed && calls == 0 && after.syntheses.isEmpty,
            "已准备的旧逐段任务不能在结束时发送隐式综合请求。")
        try require(after.insights.map(\.markdown) == project.insights.map(\.markdown), "旧逐段结束不能覆盖已存正文。")
        return [["name": "legacy-prepared-session-no-implicit-synthesis", "status": "passed", "modelCalls": calls]]
    }
}
