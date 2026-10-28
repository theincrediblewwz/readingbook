#!/usr/bin/env python3
"""Analyze an explicitly marked scroll interval, never infer FPS from a display link."""
import argparse
import json
import math
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parents[2]


def local(value):
    path = Path(value)
    path = (path if path.is_absolute() else ROOT / path).resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError("all input/output paths must remain inside the workspace")
    return path


def percentile(values, fraction):
    if not values:
        return None
    values = sorted(values)
    position = (len(values) - 1) * fraction
    lower, upper = math.floor(position), math.ceil(position)
    return values[lower] + (values[upper] - values[lower]) * (position - lower)


def distribution(values):
    return {
        "count": len(values), "median": percentile(values, 0.5),
        "p95": percentile(values, 0.95), "p99": percentile(values, 0.99),
        "maximum": max(values) if values else None,
    }


def analyze(metadata, frames, interval, roi_confirmed, continuous_input):
    factor = metadata["timebaseNumer"] / metadata["timebaseDenom"] / 1e9
    started, ended = interval["startMachTicks"], interval["endMachTicks"]
    if not metadata["captureStartMachTicks"] <= started < ended <= metadata["captureEndMachTicks"]:
        raise ValueError("scroll interval must be positive and wholly inside the capture")
    seconds = (ended - started) * factor
    selected = [f for f in frames if isinstance(f.get("displayTimeMachTicks"), int) and started <= f["displayTimeMachTicks"] <= ended]
    complete = [f for f in selected if f["status"] == 0 and not f.get("error")]
    complete_times = sorted(set(f["displayTimeMachTicks"] for f in complete))
    changed_times = sorted(set(f["displayTimeMachTicks"] for f in complete if f.get("changed") is True))
    complete_gaps = [(b - a) * factor * 1000 for a, b in zip(complete_times, complete_times[1:])]
    content_gaps = [(b - a) * factor * 1000 for a, b in zip(changed_times, changed_times[1:])]
    boundaries = ([started] + changed_times + [ended])
    boundary_gaps = [(b - a) * factor * 1000 for a, b in zip(boundaries, boundaries[1:])]
    foreground = metadata.get("foregroundSamples", [])
    before = [f for f in foreground if f["machTicks"] <= started]
    after = [f for f in foreground if f["machTicks"] >= ended]
    surrounding = before[-1:] + [f for f in foreground if started < f["machTicks"] < ended] + after[:1]
    foreground_covered = bool(before and after)
    foreground_ok = foreground_covered and all(f["targetFrontmost"] for f in surrounding)
    texture = [f["darkPixelFraction"] for f in complete if f.get("darkPixelFraction") is not None]
    texture_median = statistics.median(texture) if texture else None
    no_clock = sum(f["status"] == 0 and not isinstance(f.get("displayTimeMachTicks"), int) for f in frames)
    errors = [f for f in selected if f.get("error")]
    status = "qualified-captured-content-update-measurement"
    if not roi_confirmed:
        status = "inconclusive-roi-not-visually-confirmed"
    elif not continuous_input:
        status = "descriptive-operator-window-not-confirmed-continuous-scroll"
    elif not foreground_ok:
        status = "ineligible-background-or-uncovered-foreground"
    elif no_clock or errors or metadata.get("streamError"):
        status = "inconclusive-capture-errors"
    elif texture_median is None or texture_median < 0.005:
        status = "inconclusive-low-pdf-texture"
    elif len(complete_times) < 2:
        status = "inconclusive-insufficient-complete-frames"
    statuses = {}
    for frame in selected:
        key = str(frame["status"])
        statuses[key] = statuses.get(key, 0) + 1
    return {
        "label": interval.get("label", "explicit-scroll-interval"), "status": status,
        "inputMethod": interval.get("inputMethod", "caller-defined; consult input evidence"),
        "startMachTicks": started, "endMachTicks": ended, "durationSeconds": seconds,
        "continuousScrollInputConfirmed": continuous_input, "roiVisuallyConfirmed": roi_confirmed,
        "metric": "captured PDF ROI content-update FPS; not GPU/panel presentation FPS",
        "capturedPDFContentUpdateFPS": len(changed_times) / seconds,
        "uniqueCompleteCaptureFPS": len(complete_times) / seconds,
        "completeFrameEvents": len(complete), "uniqueCompleteFrames": len(complete_times),
        "changedPDFFrames": len(changed_times),
        "duplicateOrBelowThresholdROIFrames": sum(f.get("changed") is False for f in complete),
        "initialROIFramesWithoutComparison": sum(f.get("changed") is None for f in complete),
        "duplicateCompleteDisplayTimes": len(complete) - len(complete_times),
        "captureFrameStatusCounts": statuses,
        "completeFrameIntervalsMs": distribution(complete_gaps),
        "changedPDFFrameIntervalsMs": distribution(content_gaps),
        "contentSilenceIncludingIntervalBoundariesMs": distribution(boundary_gaps),
        "contentGapsOver16_7ms": sum(v > 16.7 for v in content_gaps),
        "contentGapsOver33_3ms": sum(v > 33.3 for v in content_gaps),
        "contentGapsOver50ms": sum(v > 50 for v in content_gaps),
        "callbackPixelProcessingMs": distribution([f["processingMicroseconds"] / 1000 for f in complete]),
        "roiDarkPixelFractionMedian": texture_median,
        "surroundingForegroundSamples": surrounding, "foregroundCoveragePresent": foreground_covered,
        "foregroundQualified": foreground_ok, "completeFramesWithoutDisplayTimeInEntireCapture": no_clock,
        "erroredSelectedFrameCount": len(errors),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", required=True, help="workspace-local capture output directory")
    parser.add_argument("--output", required=True, help="new workspace-local JSON report path")
    parser.add_argument("--intervals-file", help="JSON list (or intervals key) with startMachTicks/endMachTicks/label/inputMethod")
    parser.add_argument("--start-ticks", type=int)
    parser.add_argument("--end-ticks", type=int)
    parser.add_argument("--start-seconds", type=float, help="seconds relative to captureStartMachTicks")
    parser.add_argument("--end-seconds", type=float)
    parser.add_argument("--label", default="explicit-scroll-interval")
    parser.add_argument("--roi-confirmed", action="store_true", help="operator inspected an own-window preview and excluded all non-PDF animations")
    parser.add_argument("--continuous-input", action="store_true", help="independent input evidence establishes continuous scroll intent over the whole interval")
    args = parser.parse_args()
    capture, output = local(args.capture), local(args.output)
    if output.exists():
        raise ValueError("report output already exists; preserve earlier evidence")
    metadata = json.loads((capture / "capture.json").read_text())
    frames = [json.loads(line) for line in (capture / "frames.jsonl").read_text().splitlines() if line]
    modes = sum([bool(args.intervals_file), args.start_ticks is not None or args.end_ticks is not None,
                 args.start_seconds is not None or args.end_seconds is not None])
    if modes != 1:
        raise ValueError("supply exactly one explicit interval source; never use whole-capture FPS as scrolling FPS")
    if args.intervals_file:
        value = json.loads(local(args.intervals_file).read_text())
        intervals = value["intervals"] if isinstance(value, dict) else value
    elif args.start_ticks is not None and args.end_ticks is not None:
        intervals = [dict(startMachTicks=args.start_ticks, endMachTicks=args.end_ticks, label=args.label)]
    elif args.start_seconds is not None and args.end_seconds is not None:
        ticks_per_second = 1e9 * metadata["timebaseDenom"] / metadata["timebaseNumer"]
        intervals = [dict(startMachTicks=metadata["captureStartMachTicks"] + round(args.start_seconds * ticks_per_second),
                          endMachTicks=metadata["captureStartMachTicks"] + round(args.end_seconds * ticks_per_second), label=args.label)]
    else:
        raise ValueError("both start and end boundaries are required")
    if not intervals:
        raise ValueError("at least one positive, independently marked scroll interval is required")
    report = {
        "capture": str(capture), "scope": metadata["scope"],
        "requestedCaptureCeilingFPS": metadata["requestedCaptureCeilingFPS"],
        "roiPixels": metadata["roiPixels"], "pixelStep": metadata["pixelStep"],
        "channelDeltaThreshold": metadata["channelDeltaThreshold"],
        "changedPixelFractionThreshold": metadata["changedPixelFractionThreshold"],
        "observerCPUSecondsWholeCapture": metadata["observerCPUSeconds"],
        "observerCPUPercentOneCoreWholeCapture": metadata["observerCPUPercentOneCore"],
        "intervals": [analyze(metadata, frames, interval, args.roi_confirmed, args.continuous_input) for interval in intervals],
        "limits": [
            "ScreenCaptureKit WindowServer displayTime is a capture timestamp, not proof of hardware scan-out/GPU presentation.",
            "Content updates are subject to capture ceiling, ROI texture and threshold; below-threshold/duplicate captures do not count as PDF frames.",
            "Denominator is the complete independently marked interval, including silent gaps; idle before/after is not silently removed.",
            "Continuous input and an unobstructed PDF-only ROI require independent confirmation. A breathing status dot outside the ROI cannot raise content FPS.",
            "Capture and pixel comparison add overhead; process CPU excludes additional WindowServer/GPU capture cost.",
        ],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"output": str(output), "intervals": [{k: i[k] for k in ["label", "status", "durationSeconds", "capturedPDFContentUpdateFPS", "changedPDFFrameIntervalsMs"]} for i in report["intervals"]]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
