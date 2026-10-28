// Inserted only into a git-archived, instrumented Release build.
import Foundation
import Darwin

@_silgen_name("proc_pid_rusage")
private func perf_pid_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

public enum PerfTrace {
    private final class Sink: @unchecked Sendable {
        let lock = NSLock()
        let queue = DispatchQueue(label: "org.readingbook.perf-harness.events", qos: .utility)
        var handle: FileHandle?
        var timer: DispatchSourceTimer?
        var webPIDs: [Int32: UInt64] = [:]
    }
    private static let sink = Sink()
    public static func ticks() -> UInt64 { mach_absolute_time() }
    public static func configure(_ output: URL, mainEntry: UInt64) throws {
        let file = output.appendingPathComponent("events.jsonl")
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        sink.handle = try FileHandle(forWritingTo: file)
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        event("main.entry", ["pid": getpid(), "timebaseNumer": timebase.numer, "timebaseDenom": timebase.denom], at: mainEntry)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { sampleResources("periodic") }
        timer.resume(); sink.timer = timer
    }
    public static func event(_ name: String, _ values: [String: Any] = [:], at: UInt64? = nil) {
        var row = values; row["event"] = name; row["ticks"] = at ?? ticks()
        let payload = row
        sink.queue.async {
            guard let handle = sink.handle,
                  var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
            data.append(10); try? handle.write(contentsOf: data)
        }
    }
    public static func registerWebPID(_ pid: Int32) {
        guard pid > 0 else { return }
        var info = rusage_info_v4()
        guard withUnsafeMutablePointer(to: &info, { perf_pid_rusage(pid, Int32(RUSAGE_INFO_V4), UnsafeMutableRawPointer($0)) }) == 0 else { return }
        sink.lock.lock(); let inserted = sink.webPIDs[pid] != info.ri_proc_start_abstime; sink.webPIDs[pid] = info.ri_proc_start_abstime; sink.lock.unlock()
        if inserted { event("webcontent.owned-pid", ["pid": pid, "processStartTicks": info.ri_proc_start_abstime, "attribution": "own-WKWebView-runtime-getter"]) }
    }
    public static func sampleResources(_ label: String) {
        sink.lock.lock(); let pids = sink.webPIDs; sink.lock.unlock()
        for pid in [getpid()] + pids.keys.sorted() {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { perf_pid_rusage(pid, Int32(RUSAGE_INFO_V4), UnsafeMutableRawPointer($0)) }
            guard result == 0 else { event("resource.unavailable", ["pid": pid, "label": label]); continue }
            if pid != getpid(), pids[pid] != info.ri_proc_start_abstime {
                sink.lock.lock(); sink.webPIDs.removeValue(forKey: pid); sink.lock.unlock()
                event("resource.unavailable", ["pid": pid, "label": label, "reason": "process-identity-changed"]); continue
            }
            event("resource.sample", ["pid": pid, "role": pid == getpid() ? "app" : "owned-webcontent", "label": label,
                "rssBytes": info.ri_resident_size, "physicalFootprintBytes": info.ri_phys_footprint,
                "peakPhysicalFootprintBytes": info.ri_lifetime_max_phys_footprint,
                "userCPUTimeMachTicks": info.ri_user_time, "systemCPUTimeMachTicks": info.ri_system_time])
        }
    }
    public static func flush() { sink.queue.sync { try? sink.handle?.synchronize() } }
}
