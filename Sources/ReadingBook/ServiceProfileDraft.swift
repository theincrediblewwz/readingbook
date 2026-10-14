import SwiftUI
import ReadingCore

/// Configuration drafts and keys live only for this AppStore's lifetime.
@MainActor
final class ServiceProfileDraftState: ObservableObject {
    enum Change {
        case select(String)
        case create(ProviderPreset?)
    }
    private struct Snapshot {
        var id: String?
        var name: String
        var settings: ProviderSettings
        var key: String
    }
    private var baseline: Snapshot?
    private var newProfile = false
    @Published var pendingChange: Change?
    @Published var errorMessage = ""
    @Published var ocrError = ""
    @Published var settingsPresentationCount = 0

    func capture(from store: AppStore, isNew: Bool = false) {
        baseline = Snapshot(id: store.selectedServiceID, name: store.serviceName, settings: store.settings, key: store.apiKey)
        newProfile = isNew
        errorMessage = ""
    }

    func isDirty(in store: AppStore) -> Bool {
        guard let baseline else { return false }
        let current = store.settings, saved = baseline.settings
        return newProfile || baseline.id != store.selectedServiceID || baseline.name != store.serviceName || baseline.key != store.apiKey
            || saved.baseURL != current.baseURL || saved.model != current.model
            || saved.maxRequestsPerRun != current.maxRequestsPerRun || saved.maxOutputTokens != current.maxOutputTokens
            || saved.contextWindowTokens != current.contextWindowTokens || saved.tokenLimitParameter != current.tokenLimitParameter
    }
}

@MainActor
private struct ServiceProfileChangeConfirmation: ViewModifier {
    let store: AppStore
    let isSettingsContext: Bool
    @ObservedObject var draft: ServiceProfileDraftState

    func body(content: Content) -> some View {
        content.alert("当前配置尚未保存", isPresented: Binding(get: {
            draft.pendingChange != nil && (isSettingsContext || draft.settingsPresentationCount == 0)
        }, set: { _ in })) {
            Button("保存并继续") { store.resolveServiceChange(save: true) }
            Button("放弃更改并继续", role: .destructive) { store.resolveServiceChange(save: false) }
            Button("取消", role: .cancel) { draft.pendingChange = nil }
        } message: {
            Text("保存会保留当前配置与 API Key；放弃后切换到所选配置。取消可继续编辑，输入不会丢失。")
        }
    }
}

@MainActor
extension View {
    func serviceProfileChangeConfirmation(store: AppStore, isSettingsContext: Bool = false) -> some View {
        modifier(ServiceProfileChangeConfirmation(store: store, isSettingsContext: isSettingsContext, draft: store.serviceProfileDraft))
    }
}

struct ServiceProfileLocalError: View {
    @ObservedObject var draft: ServiceProfileDraftState
    var body: some View {
        if !draft.errorMessage.isEmpty {
            Label(draft.errorMessage, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("配置错误：\(draft.errorMessage)")
        }
    }
}
