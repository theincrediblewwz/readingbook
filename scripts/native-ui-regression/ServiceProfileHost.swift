import AppKit
import Combine
import Foundation
@testable import ReadingBook
@testable import ReadingCore

private actor ConnectionGate {
    private(set) var count = 0
    private var waiter: CheckedContinuation<Void, Never>?
    func test(_ settings: ProviderSettings, _ key: String) async -> String {
        count += 1
        await withCheckedContinuation { waiter = $0 }
        return "文本连接正常：离线替身。"
    }
    func release() { waiter?.resume(); waiter = nil }
}

@main private struct ServiceProfileHost {
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard output.path.hasPrefix(FileManager.default.currentDirectoryPath + "/logs/"), Bundle.main.bundleIdentifier != "org.readingbook.app" else { throw ReadingError.invalid("必须隔离测试。") }
        let defaults = UserDefaults.standard
        defer { if let id = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: id) } }
        let directory = output.appendingPathComponent("fixture-credentials", isDirectory: true)
        let credentials = LocalCredentialStore(directoryURL: directory)
        let a = SavedAIService(id: "profile-a", name: "服务甲", settings: ProviderSettings(baseURL: "https://provider.invalid/a", model: "fixture-A", maxOutputTokens: 384_000, contextWindowTokens: 1_000_000))
        let b = SavedAIService(id: "profile-b", name: "服务乙", settings: ProviderSettings(baseURL: "https://provider.invalid/b", model: "fixture-B", maxOutputTokens: 8192, contextWindowTokens: 128_000, tokenLimitParameter: "max_completion_tokens"))
        let keyA = "fixture-key-A", keyB = "fixture-key-B"
        var checks = [String: Bool]()
        func check(_ name: String, _ value: Bool) throws { checks[name] = value; if !value { throw ReadingError.invalid("配置检查失败：" + name) } }
        func metadata(_ profiles: [SavedAIService], selected: String) throws {
            defaults.set(try JSONEncoder().encode(profiles), forKey: "service-profiles"); defaults.set(selected, forKey: "selected-service")
        }
        func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
            for _ in 0..<1000 { if await condition() { return }; try await Task.sleep(nanoseconds: 1_000_000) }
            throw ReadingError.invalid("配置异步检查超时。")
        }
        do {
            let inline = ReaderInlineState()
            var publishes = 0
            let observation = inline.objectWillChange.sink { publishes += 1 }
            inline.clear(); inline.clear()
            try check("emptyInlineClearDoesNotPublish", publishes == 0)
            inline.pinned = true; publishes = 0; inline.clear()
            try check("inlineClearStillResetsActivePresentation", !inline.pinned && publishes == 1)
            withExtendedLifetime(observation) {}
            defaults.setVolatileDomain(["library.root.path.v1": output.appendingPathComponent("library").path], forName: UserDefaults.argumentDomain)
            try credentials.save(keyA, for: a.id); try credentials.save(keyB, for: b.id)
            try metadata([a, b], selected: b.id)
            let gate = ConnectionGate()
            let store = AppStore(localCredentials: credentials, connectionProbe: { await gate.test($0, $1) })
            try check("startupLoadsRememberedProfile", store.selectedServiceID == b.id && store.settings == b.settings)
            try check("startupLoadsMatchingKeyWithoutReselection", store.apiKey == keyB && !store.serviceProfileDraft.isDirty(in: store))
            store.selectService(a.id)
            try check("switchLoadsMatchingProfileAndKey", store.selectedServiceID == a.id && store.settings == a.settings && store.apiKey == keyA)
            store.settings.maxOutputTokens = 12_000; store.apiKey = "fixture-replacement-key"
            try store.persistServiceProfile()
            let reloaded = AppStore(localCredentials: credentials)
            try check("saveAndFreshStoreRestoreAllFields", reloaded.selectedServiceID == a.id && reloaded.settings == store.settings)
            try check("saveAndFreshStoreRestoreMatchingKey", reloaded.apiKey == store.apiKey && (try credentials.key(for: b.id)) == keyB)
            store.apiKey = "fixture-unsaved-key"; store.selectService(b.id)
            try check("unsavedKeyWaitsForChoice", store.selectedServiceID == a.id && store.serviceProfileDraft.pendingChange != nil)
            store.resolveServiceChange(save: false)
            try check("discardAndSwitchNeverReusePreviousKey", store.selectedServiceID == b.id && store.apiKey == keyB && store.settings == b.settings)
            store.apiKey = ""; try store.persistServiceProfile()
            let empty = AppStore(localCredentials: credentials)
            try check("explicitEmptyKeySurvivesRestart", empty.selectedServiceID == b.id && empty.apiKey.isEmpty && (try credentials.key(for: b.id)) == "")
            store.selectService(a.id)
            let oldID = store.selectedServiceID, oldSettings = store.settings, oldKey = store.apiKey, oldNames = store.savedServices.map(\.id)
            let secretFile = directory.appendingPathComponent("credentials.json")
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secretFile.path)
            defaults.set(b.id, forKey: "selected-service"); store.loadServiceProfiles()
            try check("keyReadFailureKeepsPreviousMatchingTuple", store.selectedServiceID == oldID && store.settings == oldSettings && store.apiKey == oldKey)
            try check("keyReadFailureIsVisibleAndMetadataUntouched", !store.serviceProfileDraft.errorMessage.isEmpty && defaults.string(forKey: "selected-service") == b.id && store.savedServices.map(\.id) == oldNames)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretFile.path)
            let bad = Data("{unreadable-profiles".utf8); defaults.set(bad, forKey: "service-profiles"); store.loadServiceProfiles()
            try check("malformedProfilesNeverBecomeLegacyProfile", store.selectedServiceID == oldID && store.savedServices.map(\.id) == oldNames && store.apiKey == oldKey)
            try check("malformedProfileBytesPreserved", defaults.data(forKey: "service-profiles") == bad && !store.serviceProfileDraft.errorMessage.isEmpty)
            try metadata([a, a], selected: a.id); store.loadServiceProfiles()
            try check("duplicateProfileIDsRejectedWithoutChangingSelection", store.selectedServiceID == oldID && store.savedServices.map(\.id) == oldNames && !store.serviceProfileDraft.errorMessage.isEmpty)
            try metadata([a, b], selected: a.id); store.loadServiceProfiles()
            try check("successfulReloadRecoversWithoutReselectingPreset", store.selectedServiceID == a.id && store.settings == a.settings && store.apiKey == "fixture-replacement-key" && store.serviceProfileDraft.errorMessage.isEmpty)
            for field in ["output", "context", "tokenParameter", "requests"] {
                store.settings = a.settings; store.connectionStatus = ""
                let expected = await gate.count + 1
                store.testConnection(); try await wait { await gate.count == expected }
                switch field {
                case "output": store.settings.maxOutputTokens += 64
                case "context": store.settings.contextWindowTokens = 500_000
                case "tokenParameter": store.settings.tokenLimitParameter = "max_completion_tokens"
                default: store.settings.maxRequestsPerRun += 1
                }
                await gate.release(); try await wait { !store.isTestingConnection }
                try check("staleConnectionResultRejected-" + field, store.connectionStatus == "配置已更改，请重新测试当前配置。")
            }
            let currentProfile = store.settings
            store.testConnection(); try await wait { await gate.count == 5 }; await gate.release(); try await wait { !store.isTestingConnection }
            try check("currentConfigurationStillTestsSuccessfully", store.settings == currentProfile && store.connectionStatus.contains("文本连接正常"))
            try check("otherProfileKeyStillIntact", (try credentials.key(for: b.id)) == "")
            store.errorMessage = "测试错误"
            store.dismissErrorAfterViewUpdate()
            try check("errorDismissalWaitsUntilAfterViewUpdate", store.errorMessage == "测试错误")
            try await Task.sleep(nanoseconds: 20_000_000)
            try check("errorDismissalCompletes", store.errorMessage == nil)
            store.errorMessage = "同样文字的新错误"; store.dismissErrorAfterViewUpdate(); store.errorMessage = "同样文字的新错误"
            try await Task.sleep(nanoseconds: 20_000_000)
            try check("oldDismissalCannotClearNewErrorWithSameText", store.errorMessage == "同样文字的新错误")
            let result: [String: Any] = ["status": "passed", "checks": checks, "originalLibraryUsed": false, "realCredentialUsed": false, "realNetworkRequests": 0, "fixtureKeyValuesPrinted": false]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        } catch {
            let result: [String: Any] = ["status": "failed", "checks": checks, "error": error.localizedDescription, "originalLibraryUsed": false, "realCredentialUsed": false, "realNetworkRequests": 0]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("result.json")); exit(1)
        }
    }
}
