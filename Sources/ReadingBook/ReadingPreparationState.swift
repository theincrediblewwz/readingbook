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

/// Stable reading-edge status. Brief page preparations change a small color,
/// not the size or presence of a text panel while the reader is scrolling.
struct ReadingPreparationStatusDot: View {
    @ObservedObject var state: ReadingPreparationState
    @Environment(\.readingReduceMotion) private var reduceMotion
    @State private var active = false
    @State private var lastProgress: ReadingPreparationProgress?
    @State private var showingDetails = false

    private var detail: String {
        guard active, let progress = state.current ?? lastProgress else { return "空闲中" }
        let phase: String
        switch progress.phase {
        case .sourceIndex: phase = "正在准备原文"
        case .pageText: phase = "正在读取页面"
        case .nativeLines: phase = "正在定位原文"
        case .matching: phase = "正在对齐原句"
        case .geometry: phase = "正在准备划线"
        case .companion: phase = "正在整理伴读"
        case .outline: phase = "正在读取目录"
        }
        return progress.page.map { "\(phase) · 第 \($0) 页" } ?? phase
    }

    var body: some View {
        Button { showingDetails.toggle() } label: {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduceMotion)) { context in
                let breath = active && !reduceMotion ? (sin(context.date.timeIntervalSinceReferenceDate * .pi / 1.4) + 1) / 2 : 0.5
                Circle()
                    .fill(active ? Color(red: 0.27, green: 0.59, blue: 0.43) : Color(red: 0.30, green: 0.49, blue: 0.72))
                    .opacity(active ? 0.62 + breath * 0.18 : 0.65)
                    .frame(width: 6, height: 6)
                    .scaleEffect(active && !reduceMotion ? 0.96 + breath * 0.12 : 1)
                    .frame(width: 22, height: 24).contentShape(Rectangle())
            }
        }
        .buttonStyle(ReadingQuietButtonStyle())
        .help(detail)
        .accessibilityLabel("页面读取状态")
        .accessibilityValue(Text(detail))
        .popover(isPresented: $showingDetails, arrowEdge: .top) {
            Text(detail).font(.system(size: 12)).padding(12)
                .frame(minWidth: 100, maxWidth: 240, alignment: .leading)
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.25 : 0.7), value: active)
        .onChange(of: state.current) { _, progress in if let progress { lastProgress = progress } }
        .task(id: state.current != nil) {
            if let progress = state.current {
                lastProgress = progress; active = true
            } else {
                // Coalesce the short gaps between preparation lanes, so one
                // scroll does not repeatedly toggle green/blue at full speed.
                do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
                guard !Task.isCancelled, state.current == nil else { return }
                active = false; lastProgress = nil
            }
        }
    }
}
