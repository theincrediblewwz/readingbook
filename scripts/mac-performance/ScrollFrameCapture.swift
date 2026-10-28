// Diagnostic only. No input injection, audio, network, or desktop capture.
import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

@_silgen_name("proc_pidpath") private func pidPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32
@_silgen_name("proc_pid_rusage") private func pidUsage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

private struct Failure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
private func cpuSeconds() -> Double {
    var value = rusage(); getrusage(RUSAGE_SELF, &value)
    return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
}
private func processIdentity(_ pid: Int32) throws -> (String, UInt64) {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = buffer.withUnsafeMutableBytes { pidPath(pid, $0.baseAddress!, UInt32($0.count)) }
    try require(length > 0, "target-process-unavailable")
    var usage = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &usage) { pidUsage(pid, Int32(RUSAGE_INFO_V4), UnsafeMutableRawPointer($0)) }
    try require(rc == 0, "target-process-identity-unavailable")
    return (String(cString: buffer), usage.ri_proc_start_abstime)
}
private struct Options {
    var workspace: URL; var output: URL; var preflightOnly: Bool
    var pid: Int32; var executable: String; var bundle: String; var windowID: UInt32?
    var seconds: Double; var maximumFPS: Int; var scale: Double; var roi: [Int]
    var foregroundWaitSeconds: Double
    var step: Int; var channelDelta: Int; var changedFraction: Double; var preview: Bool
    static func parse() throws -> Self {
        var flags = Set<String>(), values: [String: String] = [:]
        let args = Array(CommandLine.arguments.dropFirst()); var index = 0
        let names = Set(["--workspace", "--output", "--pid", "--expected-executable", "--bundle", "--window-id",
                         "--seconds", "--max-fps", "--scale", "--roi", "--pixel-step", "--channel-delta", "--changed-fraction", "--wait-for-foreground-seconds"])
        while index < args.count {
            let name = args[index]; index += 1
            if ["--preflight-only", "--preview"].contains(name) { flags.insert(name); continue }
            try require(names.contains(name) && index < args.count && values[name] == nil, "invalid-or-duplicate-arguments")
            values[name] = args[index]; index += 1
        }
        guard let workspacePath = values["--workspace"], let outputPath = values["--output"] else {
            throw Failure(message: "--workspace-and--output-required")
        }
        let workspace = URL(fileURLWithPath: workspacePath).standardizedFileURL.resolvingSymlinksInPath()
        func local(_ path: String) throws -> URL {
            let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace.appendingPathComponent(path))
                .standardizedFileURL.resolvingSymlinksInPath()
            try require(url.path.hasPrefix(workspace.path + "/"), "output-and-target-must-be-inside-workspace")
            return url
        }
        let output = try local(outputPath), preflight = flags.contains("--preflight-only")
        let executable = try values["--expected-executable"].map { try local($0).path } ?? ""
        let roi = (values["--roi"] ?? "").split(separator: ",").compactMap { Int($0) }
        let result = Self(workspace: workspace, output: output, preflightOnly: preflight,
            pid: Int32(values["--pid"] ?? "") ?? 0, executable: executable,
            bundle: values["--bundle"] ?? "org.readingbook.perf-harness", windowID: values["--window-id"].flatMap(UInt32.init),
            seconds: Double(values["--seconds"] ?? "20") ?? 0, maximumFPS: Int(values["--max-fps"] ?? "120") ?? -1,
            scale: Double(values["--scale"] ?? "1") ?? 0, roi: roi,
            foregroundWaitSeconds: Double(values["--wait-for-foreground-seconds"] ?? "0") ?? -1,
            step: Int(values["--pixel-step"] ?? "3") ?? 0, channelDelta: Int(values["--channel-delta"] ?? "3") ?? -1,
            changedFraction: Double(values["--changed-fraction"] ?? "0.001") ?? -1, preview: flags.contains("--preview"))
        if !preflight {
            try require(result.pid > 0 && !result.executable.isEmpty, "--pid-and--expected-executable-required")
            try require(result.bundle.hasPrefix("org.readingbook."), "isolated-readingbook-bundle-required")
            try require((1...120).contains(result.seconds) && (0...240).contains(result.maximumFPS), "invalid-duration-or-capture-ceiling")
            try require((0.5...2).contains(result.scale) && (1...16).contains(result.step), "invalid-scale-or-pixel-step")
            try require((0...120).contains(result.foregroundWaitSeconds), "invalid-foreground-wait")
            try require((0...255).contains(result.channelDelta) && (0.00001...1).contains(result.changedFraction), "invalid-change-threshold")
            try require(roi.count == 4 && roi[0] >= 0 && roi[1] >= 0 && roi[2] > 16 && roi[3] > 16, "--roi-x,y,width,height-required-in-output-pixels")
        }
        return result
    }
}
private struct Frame: Codable {
    var status: Int; var displayTimeMachTicks: UInt64?; var callbackMachTicks: UInt64
    var processingMicroseconds: Double = 0
    var changed: Bool?; var changedPixelFraction: Double?; var darkPixelFraction: Double?
    var signature: String?; var error: String?
}
private final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let options: Options; let queue = DispatchQueue(label: "org.readingbook.scroll-capture", qos: .userInitiated)
    var frames: [Frame] = []; var previous: [UInt8]?; var previewWritten = false
    private let lock = NSLock(); private var errorMessage: String?
    init(_ options: Options) { self.options = options }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); errorMessage = error.localizedDescription; lock.unlock()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let started = mach_absolute_time()
        guard let attachments = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let status = attachments[.status] as? Int else { return }
        var frame = Frame(status: status, displayTimeMachTicks: (attachments[.displayTime] as? NSNumber)?.uint64Value, callbackMachTicks: started)
        if status == SCFrameStatus.complete.rawValue {
            if let pixels = CMSampleBufferGetImageBuffer(buffer) { inspect(pixels, frame: &frame) }
            else { frame.error = "complete-frame-without-pixels" }
        }
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        frame.processingMicroseconds = Double(mach_absolute_time() - started) * Double(timebase.numer) / Double(timebase.denom) / 1e3
        frames.append(frame)
    }
    private func inspect(_ pixels: CVPixelBuffer, frame: inout Frame) {
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let r = options.roi
        guard r[0] + r[2] <= width, r[1] + r[3] <= height else { frame.error = "roi-outside-buffer"; return }
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { frame.error = "unexpected-pixel-format"; return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { frame.error = "pixels-unavailable"; return }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        var current: [UInt8] = []; current.reserveCapacity(((r[2] + options.step - 1) / options.step) * ((r[3] + options.step - 1) / options.step) * 3)
        var changed = 0, dark = 0, samples = 0, signature: UInt64 = 14695981039346656037
        for y in stride(from: r[1], to: r[1] + r[3], by: options.step) {
            for x in stride(from: r[0], to: r[0] + r[2], by: options.step) {
                let offset = y * rowBytes + x * 4, at = current.count
                let blue = base[offset], green = base[offset + 1], red = base[offset + 2]
                current.append(blue); current.append(green); current.append(red)
                signature = (signature ^ UInt64(blue)) &* 1099511628211
                signature = (signature ^ UInt64(green)) &* 1099511628211
                signature = (signature ^ UInt64(red)) &* 1099511628211
                if Int(blue) + Int(green) + Int(red) < 735 { dark += 1 }
                if let previous, previous.count > at + 2,
                   max(abs(Int(blue) - Int(previous[at])), abs(Int(green) - Int(previous[at + 1])), abs(Int(red) - Int(previous[at + 2]))) > options.channelDelta { changed += 1 }
                samples += 1
            }
        }
        frame.signature = String(signature, radix: 16); frame.darkPixelFraction = Double(dark) / Double(max(1, samples))
        if previous?.count == current.count {
            frame.changedPixelFraction = Double(changed) / Double(max(1, samples))
            frame.changed = frame.changedPixelFraction! >= options.changedFraction
        }
        previous = current
        if options.preview && !previewWritten {
            let url = options.output.appendingPathComponent("own-window-preview.png")
            if let context = CGContext(data: UnsafeMutableRawPointer(mutating: base), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
               let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil); previewWritten = CGImageDestinationFinalize(destination)
            }
        }
    }
    func snapshot() -> ([Frame], String?) {
        let result = queue.sync { frames }
        lock.lock(); let error = errorMessage; lock.unlock()
        return (result, error)
    }
}
private func save(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
}
private func announce(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys), let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
}
@main private struct ScrollFrameCapture {
    static func main() async {
        var options: Options?
        var createdOutput = false
        do {
            let o = try Options.parse(); options = o
            try require(!FileManager.default.fileExists(atPath: o.output.path), "output-directory-already-exists")
            try FileManager.default.createDirectory(at: o.output, withIntermediateDirectories: true)
            createdOutput = true
            let access = CGPreflightScreenCaptureAccess()
            let preflight: [String: Any] = ["status": access ? "screen-capture-access-present" : "blocked-screen-capture-permission",
                "preflightOnly": o.preflightOnly, "permissionRequested": false, "captureAttempted": false,
                "requiresManualUserAuthorization": !access]
            try save(preflight, to: o.output.appendingPathComponent("preflight.json")); announce(preflight)
            guard access else { exit(77) }
            guard !o.preflightOnly else { return }
            // A bare async command-line process has not necessarily established
            // AppKit's WindowServer connection. ScreenCaptureKit's CoreGraphics
            // path otherwise asserts CGS_REQUIRE_INIT before window enumeration.
            // Initialize on the main actor without activating, opening a window,
            // or requesting any screen/audio permissions.
            await MainActor.run {
                let application = NSApplication.shared
                application.setActivationPolicy(.prohibited)
                _ = NSScreen.screens
            }
            let identity = try processIdentity(o.pid)
            try require(URL(fileURLWithPath: identity.0).resolvingSymlinksInPath().path == o.executable, "target-executable-mismatch")
            if o.foregroundWaitSeconds > 0 {
                let deadline = ProcessInfo.processInfo.systemUptime + o.foregroundWaitSeconds
                var announced = false
                while !(await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier == o.pid }) {
                    if !announced {
                        announce(["status": "waiting-for-target-foreground", "pid": o.pid,
                            "maximumWaitSeconds": o.foregroundWaitSeconds, "captureStarted": false, "activationAttempted": false])
                        announced = true
                    }
                    try require(ProcessInfo.processInfo.systemUptime < deadline, "target-not-foreground-before-capture")
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            let shareable = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let ownWindows = shareable.windows.filter { $0.owningApplication?.processID == o.pid && $0.owningApplication?.bundleIdentifier == o.bundle && $0.frame.width > 100 && $0.frame.height > 100 }
            let matches = ownWindows.filter { o.windowID == nil || $0.windowID == o.windowID }
            try require(matches.count == 1, "target-own-window-missing-or-ambiguous-use--window-id")
            let window = matches[0], filter = SCContentFilter(desktopIndependentWindow: matches[0])
            let checked = try processIdentity(o.pid)
            try require(checked.0 == identity.0 && checked.1 == identity.1, "target-process-identity-changed")
            let config = SCStreamConfiguration()
            config.width = Int((window.frame.width * o.scale).rounded()); config.height = Int((window.frame.height * o.scale).rounded())
            config.pixelFormat = kCVPixelFormatType_32BGRA; config.queueDepth = 3
            config.minimumFrameInterval = o.maximumFPS == 0 ? .zero : CMTime(value: 1, timescale: CMTimeScale(o.maximumFPS))
            config.showsCursor = false; config.showMouseClicks = false; config.capturesAudio = false; config.captureMicrophone = false
            config.ignoreShadowsSingleWindow = true; config.includeChildWindows = false
            config.scalesToFit = true; config.preservesAspectRatio = true
            try require(o.roi[0] + o.roi[2] <= config.width && o.roi[1] + o.roi[3] <= config.height, "roi-outside-configured-window")
            let recorder = Recorder(o), stream = SCStream(filter: filter, configuration: config, delegate: recorder)
            try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
            var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
            let started = mach_absolute_time(), cpuStart = cpuSeconds()
            try await stream.startCapture()
            announce(["status": "capture-started", "pid": o.pid, "windowID": window.windowID, "captureStartMachTicks": started,
                "width": config.width, "height": config.height, "roiPixels": o.roi, "output": o.output.path])
            var foreground: [[String: Any]] = []
            let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
            while Double(mach_absolute_time() - started) * secondsPerTick < o.seconds {
                let active = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier == o.pid }
                foreground.append(["machTicks": mach_absolute_time(), "targetFrontmost": active])
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            try await stream.stopCapture()
            let ended = mach_absolute_time(), cpuEnd = cpuSeconds(), (frames, stoppedError) = recorder.snapshot()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var raw = Data()
            for frame in frames { raw.append(try encoder.encode(frame)); raw.append(10) }
            try raw.write(to: o.output.appendingPathComponent("frames.jsonl"), options: .atomic)
            let elapsed = Double(ended - started) * secondsPerTick
            let metadata: [String: Any] = ["status": stoppedError == nil ? "captured-awaiting-scroll-interval-analysis" : "stream-error",
                "pid": o.pid, "windowID": window.windowID, "bundle": o.bundle, "targetExecutable": o.executable,
                "processStartMachTicks": identity.1, "captureStartMachTicks": started, "captureEndMachTicks": ended,
                "timebaseNumer": timebase.numer, "timebaseDenom": timebase.denom, "durationSeconds": elapsed,
                "requestedCaptureCeilingFPS": o.maximumFPS, "nativeCeilingWhenZero": true,
                "captureWidth": config.width, "captureHeight": config.height, "windowWidthPoints": window.frame.width, "windowHeightPoints": window.frame.height,
                "requestedOutputScale": o.scale, "windowBackingPointPixelScale": filter.pointPixelScale,
                "roiPixels": o.roi, "pixelStep": o.step, "channelDeltaThreshold": o.channelDelta, "changedPixelFractionThreshold": o.changedFraction,
                "frameEventCount": frames.count, "frameStatusCountsWholeCapture": Dictionary(grouping: frames, by: { String($0.status) }).mapValues(\.count), "foregroundSamples": foreground,
                "observerCPUSeconds": cpuEnd - cpuStart, "observerCPUPercentOneCore": (cpuEnd - cpuStart) / elapsed * 100,
                "previewWritten": recorder.previewWritten, "streamError": stoppedError ?? NSNull(),
                "pixelContentPersisted": recorder.previewWritten, "audioCaptured": false, "cursorCaptured": false,
                "permissionRequested": false, "scope": "only selected workspace-local ReadingBook window; no desktop/audio/network",
                "appKitInitializedOnMainActor": true, "collectorActivationPolicy": "prohibited",
                "metric": "captured PDF ROI content-update cadence, not actual GPU presentation FPS",
                "notes": ["An explicit independently marked continuous-scroll interval is required for FPS analysis.",
                    "ROI must contain PDF text and exclude status dots, hover cards, controls, cursor and other animations.",
                    "Window capture and pixel comparison add observer overhead, including WindowServer work not reflected in this process CPU.",
                    "A complete capture frame is not necessarily a changed PDF frame; idle and duplicate ROI samples remain in raw data."]]
            try save(metadata, to: o.output.appendingPathComponent("capture.json")); announce(["status": metadata["status"]!, "output": o.output.path, "frameEvents": frames.count])
            if stoppedError != nil { exit(1) }
        } catch {
            let message = (error as? Failure)?.message ?? error.localizedDescription
            let result: [String: Any] = ["status": "failed", "reason": message, "permissionRequested": false]
            if let options, createdOutput { try? save(result, to: options.output.appendingPathComponent("failure.json")) }
            announce(result); exit(1)
        }
    }
}
