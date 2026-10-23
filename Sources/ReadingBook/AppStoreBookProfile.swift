import SwiftUI
import ReadingCore

@MainActor extension AppStore {
    /// A reader preference, separate from facts extracted from the book and from
    /// the confirmed executable scheme. Preserve every existing temporal record.
    @discardableResult
    func saveReaderBookProfile(_ profile: BookProfile, inBook expectedBookID: String) async -> Bool {
        guard var current = book, current.id == expectedBookID, !isBusy else { return false }
        isBusy = true; isCommittingLocalWrite = true
        defer { isBusy = false; isCommittingLocalWrite = false }
        do {
            var temporal = current.temporalKnowledge ?? TemporalKnowledgeState()
            var merged = temporal.profile ?? BookProfile()
            merged.genres = profile.genres; merged.customGenres = profile.customGenres; merged.avoidsSpoilers = profile.avoidsSpoilers
            temporal.profile = merged; current.temporalKnowledge = temporal
            try await repository.save(current)
            publish(current); activity = "读书偏好已保存；下次预读会参考所选书型。"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}

extension BookGenre {
    var readerTitle: String {
        switch self {
        case .history: return "历史"
        case .warfare: return "战争"
        case .fiction: return "小说"
        case .argument: return "论述"
        case .textbook: return "教材"
        }
    }
    var readerIcon: String {
        switch self {
        case .history: return "clock"
        case .warfare: return "flag"
        case .fiction: return "book.closed"
        case .argument: return "text.alignleft"
        case .textbook: return "graduationcap"
        }
    }
}
