import SwiftUI
import ReadingCore

/// Small presentation state: progress never invalidates every AppStore consumer.
@MainActor final class ReadingPreparationState: ObservableObject {
    @Published private(set) var current: ReadingPreparationProgress?

    private struct Entry {
        let owner: String
        let run: UUID
        var progress: ReadingPreparationProgress
        var order: UInt64
    }
    private var entries: [String: Entry] = [:]
    private var order: UInt64 = 0
    private var flushGeneration: UInt64 = 0
    private var flushTask: Task<Void, Never>?

    func apply(_ event: ReadingPreparationEvent, lane: String, owner: String) {
        switch event {
        case .started(let run, let progress):
            order &+= 1
            entries[lane] = Entry(owner: owner, run: run, progress: progress, order: order)
            cancelFlush()
            publishCurrent()
        case .advanced(let run, let progress):
            guard var entry = entries[lane], entry.owner == owner, entry.run == run,
                  entry.progress != progress else { return }
            order &+= 1
            entry.progress = progress; entry.order = order
            entries[lane] = entry
            scheduleFlush()
        case .finished(let run):
            guard let entry = entries[lane], entry.owner == owner, entry.run == run else { return }
            entries.removeValue(forKey: lane)
            // Do not leave a completed phase visible until the next timer tick.
            cancelFlush()
            publishCurrent()
        }
    }

    func reset() {
        cancelFlush()
        entries.removeAll()
        order = 0
        if current != nil { current = nil }
    }

    private func publishCurrent() {
        let next = entries.values.max { $0.order < $1.order }?.progress
        if current != next { current = next }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let generation = flushGeneration
        flushTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            guard !Task.isCancelled, let self, self.flushGeneration == generation else { return }
            self.flushTask = nil
            self.publishCurrent()
        }
    }

    private func cancelFlush() {
        flushGeneration &+= 1
        flushTask?.cancel(); flushTask = nil
    }
}

/// Can be placed at a reading edge or inside the companion without blocking input.
struct ReadingPreparationIndicator: View {
    @ObservedObject var state: ReadingPreparationState

    var body: some View {
        if let progress = state.current {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if progress.fraction == nil { ProgressView().controlSize(.small) }
                    Text(title(for: progress.phase)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let page = progress.page {
                        Text("第 \(page) 页").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if let fraction = progress.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                }
                if let completed = progress.completed {
                    Text(countLabel(completed: completed, total: progress.total))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(width: 220, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }

    private func countLabel(completed: Int, total: Int?) -> String {
        if let total { return "\(completed) / \(total)" }
        return "已处理 \(completed)"
    }

    private func title(for phase: ReadingPreparationProgress.Phase) -> String {
        switch phase {
        case .sourceIndex: return "准备原文"
        case .pageText: return "读取页面"
        case .nativeLines: return "定位原文"
        case .matching: return "对齐原句"
        case .geometry: return "准备划线"
        case .companion: return "整理伴读"
        case .outline: return "读取目录"
        }
    }
}
