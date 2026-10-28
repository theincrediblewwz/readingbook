import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// An explicit, short main-run-loop sample. It is not a rendered frame-rate measurement.
@MainActor final class LocalDiagnostics: ObservableObject {
    static let shared = LocalDiagnostics()
    @Published private(set) var sampling = false
    @Published private(set) var sample: Sample?
    struct Sample: Codable {
        var durationSeconds: Double
        var ticks: Int
        var gapsOver50ms: Int
        var maximumGapMilliseconds: Double
    }
    private var timer: Timer?
    private var start = 0.0
    private var previous = 0.0
    private var count = 0
    private var slow = 0
    private var maximum = 0.0
    func begin() {
        guard !sampling else { return }
        start = ProcessInfo.processInfo.systemUptime; previous = start
        count = 0; slow = 0; maximum = 0; sampling = true
        let value = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = value; RunLoop.main.add(value, forMode: .common)
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime, gap = now - previous
        previous = now; count += 1; maximum = max(maximum, gap)
        if gap > 0.05 { slow += 1 }
        if now - start >= 10 {
            timer?.invalidate(); timer = nil
            sample = Sample(durationSeconds: now - start, ticks: count, gapsOver50ms: slow, maximumGapMilliseconds: maximum * 1000)
            sampling = false
        }
    }
    func export(bookCount: Int, phase: String) throws -> URL? {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ReadingBook-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        struct Report: Encodable {
            let version: Int, appVersion: String, build: String, system: String
            let processorCount: Int, systemMemoryBytes: UInt64, bookCount: Int
            let phase: String, sampleMeaning: String
            let sample: Sample?
        }
        let report = Report(version: 1,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            system: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.processorCount,
            systemMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            bookCount: bookCount, phase: phase,
            sampleMeaning: "10-second main-run-loop responsiveness; not rendered FPS. No book text, names, paths, keys or prompts.", sample: sample)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }
}
