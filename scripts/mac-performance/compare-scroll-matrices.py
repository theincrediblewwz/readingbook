#!/usr/bin/env python3
"""Compare scroll matrices descriptively, only with identical measurement controls."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
QUALIFIED = {"qualified-captured-content-baseline-matrix", "qualified-captured-content-scroll-matrix"}


def local(value):
    path = Path(value)
    path = (path if path.is_absolute() else ROOT / path).resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError("all inputs and outputs must remain in the workspace")
    return path


def delta(before, after):
    return {"before": before, "after": after, "afterMinusBefore": after - before,
            "percentChange": (after / before - 1) * 100 if before else None}


def compare(before, after, before_label=None, after_label=None):
    mismatches = []
    for label, matrix in [("before", before), ("after", after)]:
        if matrix.get("status") not in QUALIFIED or matrix.get("qualifiedSamples") != 6:
            mismatches.append(label + ".qualified-six-sample-status")
        for name in ["wide", "narrow"]:
            group = matrix.get("groups", {}).get(name, {})
            if group.get("qualifiedRunCount") != 3 or group.get("allForegroundGeometryHashAndLogGatesPassed") is not True:
                mismatches.append(label + "." + name + ".qualification")
    for key in ["driverSHA256", "collectorSHA256", "fixtureManifestSHA256", "input", "capture"]:
        if before.get(key) is None or before.get(key) != after.get(key):
            mismatches.append(key)
    # Missing historical protocols stay comparable only to each other, never to
    # a newly controlled early/settled or parked-pointer matrix.
    for key in ["timingProtocol", "pointerProtocol"]:
        if before.get(key) != after.get(key):
            mismatches.append(key)
    for name in ["wide", "narrow"]:
        for key in ["actualWindowPixelsAtScale1", "roiPixels"]:
            if before.get("groups", {}).get(name, {}).get(key) != after.get("groups", {}).get(name, {}).get(key):
                mismatches.append(name + "." + key)
    report = {
        "status": "comparable-descriptive-scroll-matrices" if not mismatches else "not-comparable-condition-mismatch",
        "beforeLabel": before_label or before.get("productVersion") or before["sourceCommit"][:7],
        "afterLabel": after_label or after.get("productVersion") or after["sourceCommit"][:7],
        "beforeSourceCommit": before["sourceCommit"], "afterSourceCommit": after["sourceCommit"],
        "beforeBinarySHA256": before["targetBinarySHA256"], "afterBinarySHA256": after["targetBinarySHA256"],
        "beforeTimingProtocol": before.get("timingProtocol"), "afterTimingProtocol": after.get("timingProtocol"),
        "beforePointerProtocol": before.get("pointerProtocol"), "afterPointerProtocol": after.get("pointerProtocol"),
        "differentProductBinaries": before["targetBinarySHA256"] != after["targetBinarySHA256"],
        "mismatches": mismatches, "groups": {},
        "limits": ["Three runs per window, sequential before/after matrices rather than randomized/interleaved trials; small differences are not automatically a performance gain.",
                   "Metric is captured PDF ROI content-update cadence, not GPU/panel presentation FPS or a hardware gesture.",
                   "Same requested60Hz programmatic input and120FPS capture ceiling; collector CPU is over the whole capture and excludes WindowServer/GPU cost.",
                   "Only scroll metrics are compared here; injected-driver startup/action timings are excluded from latency baselines."],
    }
    if mismatches:
        return report
    for name in ["wide", "narrow"]:
        left, right = before["groups"][name], after["groups"][name]
        report["groups"][name] = {
            "actualWindowPixelsAtScale1": left["actualWindowPixelsAtScale1"], "roiPixels": left["roiPixels"],
            "medianCapturedPDFContentUpdateFPS": delta(left["medianCapturedPDFContentUpdateFPS"], right["medianCapturedPDFContentUpdateFPS"]),
            "minimumRunCapturedPDFContentUpdateFPS": delta(left["minimumRunCapturedPDFContentUpdateFPS"], right["minimumRunCapturedPDFContentUpdateFPS"]),
            "pooledChangedFrameIntervalsMs": {key: delta(left["pooledChangedFrameIntervalsMs"][key], right["pooledChangedFrameIntervalsMs"][key]) for key in ["median", "p95", "p99", "maximum"]},
            "medianCollectorCPUPercentOneCoreWholeCapture": delta(left["medianCollectorCPUPercentOneCoreWholeCapture"], right["medianCollectorCPUPercentOneCoreWholeCapture"]),
            "medianActualInputDeliveryHz": delta(left["medianActualInputDeliveryHz"], right["medianActualInputDeliveryHz"]),
            "beforeRunFPS": [r["capturedPDFContentUpdateFPS"] for r in left["runs"]],
            "afterRunFPS": [r["capturedPDFContentUpdateFPS"] for r in right["runs"]],
        }
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", required=True)
    parser.add_argument("--after", required=True)
    parser.add_argument("--before-label")
    parser.add_argument("--after-label")
    parser.add_argument("--output-prefix", required=True)
    args = parser.parse_args()
    before_path, after_path, output = local(args.before), local(args.after), local(args.output_prefix)
    if output.with_suffix(".json").exists() or output.with_suffix(".md").exists():
        raise ValueError("comparison output exists; preserve earlier evidence")
    report = compare(json.loads(before_path.read_text()), json.loads(after_path.read_text()), args.before_label, args.after_label)
    report.update(beforeMatrix=str(before_path), afterMatrix=str(after_path))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.with_suffix(".json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    lines = [f"# ReadingBook 滚动内容更新：{report['beforeLabel']} → {report['afterLabel']}\n\n"]
    if report["mismatches"]:
        lines.append("条件不匹配，未生成前后性能结论：" + "、".join(report["mismatches"]) + "。\n")
    else:
        lines += ["同条件宽窄窗各三轮的描述性比较；FPS是PDF区域捕获内容更新，并非GPU/面板展示帧率。\n\n",
                  "| 窗口 | 原内容FPS中位 | 新内容FPS中位 | 差值 | 变化 |\n|---|---:|---:|---:|---:|\n"]
        for group in report["groups"].values():
            fps = group["medianCapturedPDFContentUpdateFPS"]
            dims = "×".join(str(v) for v in group["actualWindowPixelsAtScale1"])
            lines.append(f"| {dims} | {fps['before']:.2f} | {fps['after']:.2f} | {fps['afterMinusBefore']:+.2f} | {fps['percentChange']:+.2f}% |\n")
        lines += ["\n| 窗口 | p95间隔 原→新 | p99间隔 原→新 | 最大间隔 原→新 | 采集器CPU 原→新（单核） |\n|---|---|---|---|---|\n"]
        for group in report["groups"].values():
            gaps = group["pooledChangedFrameIntervalsMs"]; cpu = group["medianCollectorCPUPercentOneCoreWholeCapture"]
            dims = "×".join(str(v) for v in group["actualWindowPixelsAtScale1"])
            row = " | ".join(f"{gaps[key]['before']:.2f}→{gaps[key]['after']:.2f}ms" for key in ["p95", "p99", "maximum"])
            lines.append(f"| {dims} | {row} | {cpu['before']:.2f}→{cpu['after']:.2f}% |\n")
        lines += ["\n两组是先后采集而非随机交错，样本有限；小差异不自动证明提升。ROI、输入、原书副本和驱动/采集器哈希严格一致才输出对照。注入滚动驱动的启动/动作耗时不进入普通延迟基线。\n"]
    lines += [f"\n[原矩阵]({before_path}) · [新矩阵]({after_path})\n"]
    output.with_suffix(".md").write_text("".join(lines))
    print(json.dumps({"status": report["status"], "mismatches": report["mismatches"], "output": str(output)}, ensure_ascii=False))
    return 0 if not report["mismatches"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
