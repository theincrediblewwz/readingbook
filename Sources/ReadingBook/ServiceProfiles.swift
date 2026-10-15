import SwiftUI
import ReadingCore

struct SavedAIService: Codable, Identifiable {
    var id: String
    var name: String
    var settings: ProviderSettings
}
struct ProviderCatalog: Decodable {
    var verifiedAt: String
    var providers: [ProviderPreset]
    static let current: ProviderCatalog = {
        guard let url = ReadingBookResources.bundle?.url(forResource: "provider-catalog", withExtension: "json"), let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(ProviderCatalog.self, from: data) else { return ProviderCatalog(verifiedAt: "", providers: []) }
        return catalog
    }()
}
struct ProviderPreset: Decodable, Identifiable {
    var id: String
    var name: String
    var baseURL: String
    var documentationURL: String
    var models: [ModelPreset]
}
struct ModelPreset: Decodable, Identifiable {
    var id: String
    var name: String
    var contextTokens: Int?
    var maxOutputTokens: Int?
    var vision: Bool
    var tools: Bool
    var tokenParameter: String
    var documentationURL: String
}

extension AppStore {
    var matchingPreset: ProviderPreset? {
        ProviderCatalog.current.providers.first { URL(string: $0.baseURL)?.host == URL(string: settings.baseURL)?.host }
    }
    var matchingModel: ModelPreset? { matchingPreset?.models.first { $0.id == settings.model } }

    func loadServiceProfiles() {
        var loadError: String?
        do {
            if let data = UserDefaults.standard.data(forKey: "service-profiles"), let profiles = try? JSONDecoder().decode([SavedAIService].self, from: data) {
                savedServices = profiles
                let remembered = UserDefaults.standard.string(forKey: "selected-service")
                if let first = profiles.first(where: { $0.id == remembered }) ?? profiles.first {
                    selectedServiceID = first.id; serviceName = first.name; settings = first.settings
                    apiKey = try keyForService(first.id)
                } else { selectedServiceID = nil; serviceName = "新服务"; settings = ProviderSettings(); apiKey = "" }
            } else {
                apiKey = try Keychain.read()
                // The legacy key remains in its old account until the user saves.
                selectedServiceID = "legacy"; serviceName = "我的 AI"
                savedServices = [SavedAIService(id: "legacy", name: serviceName, settings: settings)]
            }
            ocrServiceID = UserDefaults.standard.string(forKey: "ocr-service")
            if !savedServices.contains(where: { $0.id == ocrServiceID }) { ocrServiceID = nil }
        } catch { loadError = error.localizedDescription }
        serviceProfileDraft.capture(from: self)
        if let loadError { serviceProfileDraft.errorMessage = loadError }
    }

    func selectService(_ id: String) {
        guard !isBusy, id != selectedServiceID, savedServices.contains(where: { $0.id == id }) else { return }
        requestServiceChange(.select(id))
    }

    func newService(_ preset: ProviderPreset? = nil) {
        guard !isBusy else { return }
        requestServiceChange(.create(preset))
    }

    private func requestServiceChange(_ change: ServiceProfileDraftState.Change) {
        serviceProfileDraft.errorMessage = ""
        if serviceProfileDraft.isDirty(in: self) {
            objectWillChange.send()
            serviceProfileDraft.pendingChange = change
        }
        else { performServiceChange(change) }
    }

    func resolveServiceChange(save: Bool) {
        guard !isBusy, let change = serviceProfileDraft.pendingChange else { return }
        serviceProfileDraft.pendingChange = nil
        do {
            if save { try persistServiceProfile() }
            performServiceChange(change)
        } catch {
            serviceProfileDraft.errorMessage = error.localizedDescription
            if serviceProfileDraft.settingsPresentationCount == 0 { showingSettings = true }
        }
    }

    private func performServiceChange(_ change: ServiceProfileDraftState.Change) {
        do {
            switch change {
            case .select(let id):
                guard let profile = savedServices.first(where: { $0.id == id }) else { throw ReadingError.invalid("所选配置已不存在。当前输入已保留。") }
                // Read first, so a Keychain failure leaves every draft field intact.
                let key = try keyForService(id)
                settings = profile.settings; serviceName = profile.name; selectedServiceID = profile.id; apiKey = key
                connectionStatus = ""; UserDefaults.standard.set(id, forKey: "selected-service")
                serviceProfileDraft.capture(from: self)
            case .create(let preset):
                selectedServiceID = nil; apiKey = ""; connectionStatus = ""
                serviceName = preset?.name ?? "新服务"
                settings = ProviderSettings(baseURL: preset?.baseURL ?? "https://api.openai.com/v1/chat/completions")
                if let model = preset?.models.first { chooseModel(model) }
                serviceProfileDraft.capture(from: self, isNew: true)
            }
        } catch { serviceProfileDraft.errorMessage = error.localizedDescription }
    }

    func saveServiceProfileForUI() {
        do { try persistServiceProfile(); connectionStatus = "配置已保存。" }
        catch { serviceProfileDraft.errorMessage = error.localizedDescription }
    }

    func chooseModel(_ model: ModelPreset) {
        guard !isBusy else { return }
        settings.model = model.id; settings.contextWindowTokens = model.contextTokens
        settings.tokenLimitParameter = model.tokenParameter
        settings.maxOutputTokens = min(model.maxOutputTokens ?? 6000, 8192)
        connectionStatus = model.vision ? "此预设支持图像输入，可选择作为 PDF OCR 服务。" : "此预设用于文本；PDF OCR 请另选支持图像输入的模型。"
    }

    func useMaximumOutput() {
        guard !isBusy, let model = matchingModel, let maximum = model.maxOutputTokens else { return }
        settings.maxOutputTokens = maximum; settings.contextWindowTokens = model.contextTokens
        settings.tokenLimitParameter = model.tokenParameter
    }

    func persistServiceProfile() throws {
        guard !isBusy, !serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...2000).contains(settings.maxRequestsPerRun), (64...1_048_576).contains(settings.maxOutputTokens),
              settings.contextWindowTokens.map({ (1024...4_194_304).contains($0) }) ?? true else { throw ReadingError.invalid("请填写配置名称、模型与有效的请求/token 上限。") }
        guard let url = URL(string: settings.baseURL), url.host != nil else { throw ReadingError.invalid("请填写完整的服务 URL。") }
        try ProviderProbe.validate(settings: settings, apiKey: apiKey)
        let id = selectedServiceID ?? UUID().uuidString
        let profile = SavedAIService(id: id, name: String(serviceName.prefix(80)), settings: settings)
        var profiles = savedServices
        if let index = profiles.firstIndex(where: { $0.id == id }) { profiles[index] = profile } else { profiles.append(profile) }
        let metadata = try JSONEncoder().encode(profiles)
        try Keychain.write(apiKey, account: "profile-\(id)")
        savedServices = profiles; selectedServiceID = id; serviceName = profile.name
        UserDefaults.standard.set(metadata, forKey: "service-profiles")
        UserDefaults.standard.set(id, forKey: "selected-service")
        UserDefaults.standard.set(ocrServiceID, forKey: "ocr-service")
        serviceProfileDraft.capture(from: self)
        if id == "legacy" {
            UserDefaults.standard.set(true, forKey: "legacy-profile-migrated")
            try Keychain.remove(account: "api-key")
        }
    }

    func removeService(_ id: String) {
        guard !isBusy else { return }
        do {
            try Keychain.remove(account: "profile-\(id)")
            if id == "legacy" { try Keychain.remove(account: "api-key"); UserDefaults.standard.set(true, forKey: "legacy-profile-migrated") }
            savedServices.removeAll { $0.id == id }
            UserDefaults.standard.set(try JSONEncoder().encode(savedServices), forKey: "service-profiles")
            if ocrServiceID == id { ocrServiceID = nil; UserDefaults.standard.removeObject(forKey: "ocr-service") }
            if selectedServiceID == id {
                if let first = savedServices.first { performServiceChange(.select(first.id)) }
                else { UserDefaults.standard.removeObject(forKey: "selected-service"); performServiceChange(.create(nil)) }
            }
        } catch { serviceProfileDraft.errorMessage = error.localizedDescription }
    }

    func testConnection() {
        guard !isBusy else { return }
        let configuration = settings, key = apiKey
        isBusy = true; connectionStatus = "正在发送一条短文本测试请求…"
        task = Task {
            defer { isBusy = false }
            do { connectionStatus = try await ProviderProbe.test(settings: configuration, apiKey: key) }
            catch { connectionStatus = error.localizedDescription }
        }
    }

    func startOCR(pages: [Int]) {
        guard let current = book, !isBusy else { return }
        serviceProfileDraft.ocrError = ""
        guard !editorDirty else { serviceProfileDraft.ocrError = "请先保存 Markdown 草稿，再启动页面识别。"; return }
        var configuration = settings, key = apiKey
        do {
            if let id = ocrServiceID, id != selectedServiceID, let profile = savedServices.first(where: { $0.id == id }) {
                configuration = profile.settings; key = try keyForService(id)
            }
        } catch { serviceProfileDraft.ocrError = error.localizedDescription; return }
        guard !configuration.model.isEmpty else { serviceProfileDraft.ocrError = "请先设置支持图像输入的 OCR 模型，再开始识别。"; return }
        guard (1...2000).contains(configuration.maxRequestsPerRun) else { serviceProfileDraft.ocrError = "每轮请求预算须在 1 到 2000 次之间。"; return }
        do { try ProviderProbe.validate(settings: configuration, apiKey: key) }
        catch { serviceProfileDraft.ocrError = error.localizedDescription; return }
        let candidates = Array(Set(pages)).sorted().filter { OCRIntegration.unavailableReason(project: current, page: $0) == nil }
        guard !candidates.isEmpty else { serviceProfileDraft.ocrError = "所选范围没有可识别页。已有分析或引用的页需要导入原书为新项目后识别。"; return }
        let runPages = Array(candidates.prefix(configuration.maxRequestsPerRun))
        let runSettings = configuration, runKey = key
        isBusy = true; isRecognizingPDF = true; showingOCR = false
        task = Task {
            defer { isBusy = false; isRecognizingPDF = false }
            await pdfOCRReader.resetBudget()
            do {
                let source = await repository.sourceURL(for: current)
                guard try await ensurePDFSession(bookID: current.id, sourceURL: source, resumeOCRPages: candidates) else { return }
                let sourcePassword = pdfPassword(for: current.id)
                for (index, page) in runPages.enumerated() {
                    try Task.checkCancellation()
                    guard let latest = book, latest.id == current.id else { throw CancellationError() }
                    try await repository.checkOCRPage(project: latest, page: page)
                    activity = "正在识别 PDF 第 \(page) 页（\(index + 1)/\(runPages.count)）…"
                    let result = try await pdfOCRReader.recognizePage(sourceURL: source, page: page, settings: runSettings, apiKey: runKey, password: sourcePassword)
                    try Task.checkCancellation()
                    let oldPage = selectedUnit?.page
                    let updated = try await repository.saveOCRPage(project: latest, result: result)
                    publish(updated)
                    if oldPage == page { selectedUnitID = updated.units.first { $0.page == page }?.id }
                    requestsUsed = await pdfOCRReader.requestCount
                }
                activity = runPages.count < candidates.count
                    ? "本轮 \(runPages.count) 页已识别并保存，另有 \(candidates.count - runPages.count) 页可续跑；请在识别面板选择剩余页。"
                    : "所选页面已逐页识别并保存；请对照 PDF 核对，再预读与精读。"
            } catch { handle(error) }
            requestsUsed = await pdfOCRReader.requestCount
        }
    }
    private func keyForService(_ id: String) throws -> String {
        let key = try Keychain.read(account: "profile-\(id)")
        if id == "legacy", key.isEmpty, !UserDefaults.standard.bool(forKey: "legacy-profile-migrated") { return try Keychain.read() }
        return key
    }
}

struct AIServiceBar: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("ai-service-expanded") private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 7) {
                Picker("使用", selection: Binding(get: { store.selectedServiceID ?? "" }, set: { store.selectService($0) })) {
                    if store.selectedServiceID == nil { Text("未保存配置").tag("") }
                    ForEach(store.savedServices) { service in Text(service.name).tag(service.id) }
                }.labelsHidden().disabled(store.isBusy)
                Text(store.settings.model.isEmpty ? "尚未配置模型" : store.settings.model).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                HStack { Button("管理 / 新建") { store.showingSettings = true }; Spacer(); Button("测试") { store.testConnection() }.disabled(store.isBusy || store.settings.model.isEmpty) }.font(.caption)
                if !store.connectionStatus.isEmpty { Text(store.connectionStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(3).help(store.connectionStatus) }
                ServiceProfileLocalError(draft: store.serviceProfileDraft)
            }.padding(.top, 7).controlSize(.regular)
        } label: { Label("AI · \(store.serviceName)", systemImage: "sparkles").font(.system(size: 12, weight: .medium)).lineLimit(1) }
        .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 12).padding(.bottom, 8)
    }
}
