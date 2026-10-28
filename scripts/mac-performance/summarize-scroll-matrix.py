#!/usr/bin/env python3
"""Aggregate explicit qualified scroll cases; never promote failed/setup data."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import statistics

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "logs/mac-refinement-20261028/scroll-fps"
SPEC = importlib.util.spec_from_file_location("scroll_analysis", Path(__file__).with_name("analyze-scroll-capture.py"))
ANALYSIS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ANALYSIS)


def load(path):
    return json.loads(path.read_text())


def validate_formal_eligibility(result, source_manifest, operator_exclusion=None):
    if result.get("manualSetupRequired"):
        raise ValueError("manual setup has variable pre-scroll dwell; establish a matched waiting protocol before formal matrices")
    if (result.get("formalFPSBaselineExcluded") or result.get("diagnosticOnly")
            or source_manifest.get("formalFPSBaselineExcluded") or source_manifest.get("diagnosticOnly")
            or (operator_exclusion and (operator_exclusion.get("formalFPSBaselineExcluded")
                                       or operator_exclusion.get("diagnosticComparisonExcluded")))):
        raise ValueError("diagnostic or operator-excluded run cannot enter a formal FPS matrix")


def group(tags, expected_window, expected_roi):
    runs, pooled_gaps, boundaries = [], [], []
    for tag in tags:
        folder = BASE / tag
        result = load(folder / "result.json")
        capture = load(folder / "capture/capture.json")
        interval = result["interval"]
        trace = load(Path(result["heldRecord"]).parent / "scroll-control/scroll-trace.json")
        config = load(Path(result["heldRecord"]).parent / "config.json")
        source_manifest = load(Path(result["manifest"]))
        exclusion_path = folder / "operator-exclusion.json"
        validate_formal_eligibility(result, source_manifest,
                                    load(exclusion_path) if exclusion_path.exists() else None)
        app_info = plistlib.loads((Path(source_manifest["app"]) / "Contents/Info.plist").read_bytes())
        fixture_manifest = load(ROOT / "logs" / Path(source_manifest["buildRoot"]).name / tag / "fixture-before.json")
        fixture_digest = hashlib.sha256(json.dumps(fixture_manifest, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        assert result["status"] == interval["status"] == "qualified-captured-content-update-measurement", tag
        assert all(result[k] for k in ["targetBinaryUnchanged", "driverUnchanged", "collectorUnchanged", "fixtureUnchanged", "ownedHeldStopped", "allInputForeground", "geometricPageCrossing"]), tag
        assert result["systemLogReturnCode"] == result["layoutWarningLines"] == result["publishingWarnings"] == 0, tag
        assert [capture["captureWidth"], capture["captureHeight"]] == expected_window, tag
        assert capture["roiPixels"] == expected_roi and capture["pixelStep"] == 6, tag
        assert capture["channelDeltaThreshold"] == 3 and capture["changedPixelFractionThreshold"] == .001, tag
        assert capture["requestedCaptureCeilingFPS"] == 120 and config["scale"] == 3.43, tag
        assert trace["inputHz"] == 60 and trace["pointsPerSecond"] == 200 and trace["requestedDurationSeconds"] == 12, tag
        rows = [json.loads(line) for line in (folder / "capture/frames.jsonl").read_text().splitlines() if line]
        factor = capture["timebaseNumer"] / capture["timebaseDenom"] / 1e9
        changed = sorted(set(r["displayTimeMachTicks"] for r in rows if r["status"] == 0 and r.get("changed") is True
                             and interval["startMachTicks"] <= r.get("displayTimeMachTicks", -1) <= interval["endMachTicks"]))
        gaps = [(b - a) * factor * 1000 for a, b in zip(changed, changed[1:])]
        pooled_gaps.extend(gaps)
        bounded = [interval["startMachTicks"]] + changed + [interval["endMachTicks"]]
        boundaries.extend((b - a) * factor * 1000 for a, b in zip(bounded, bounded[1:]))
        ticks = trace["ticks"]
        delivered_hz = (len(ticks) - 1) / ((ticks[-1]["machTicks"] - ticks[0]["machTicks"]) * factor)
        runs.append({
            "tag": tag, "result": str(folder / "result.json"), "durationSeconds": interval["durationSeconds"],
            "capturedPDFContentUpdateFPS": interval["capturedPDFContentUpdateFPS"],
            "uniqueCompleteCaptureFPS": interval["uniqueCompleteCaptureFPS"], "changedPDFFrames": interval["changedPDFFrames"],
            "duplicateOrBelowThresholdROIFrames": interval["duplicateOrBelowThresholdROIFrames"],
            "changedPDFFrameIntervalsMs": interval["changedPDFFrameIntervalsMs"],
            "callbackPixelProcessingMs": interval["callbackPixelProcessingMs"],
            "collectorCPUPercentOneCoreWholeCapture": capture["observerCPUPercentOneCore"],
            "actualInputDeliveryHz": delivered_hz, "inputTicks": len(ticks),
            "documentDisplacementPoints": result["documentDisplacementPoints"],
            "initialCenterPDFPage": result["initialCenterPDFPage"], "finalCenterPDFPage": result["finalCenterPDFPage"],
            "targetBinarySHA256": result["targetBinarySHA256"], "driverSHA256": result["driverSHA256"],
            "collectorSHA256": result["collectorSHA256"], "sourceCommit": source_manifest["sourceCommit"],
            "fixtureManifestSHA256": fixture_digest,
            "appVersion": app_info["CFBundleShortVersionString"], "appBuild": app_info["CFBundleVersion"],
        })
    return {
        "qualifiedRunCount": len(runs), "actualWindowPixelsAtScale1": expected_window, "roiPixels": expected_roi,
        "medianCapturedPDFContentUpdateFPS": statistics.median(r["capturedPDFContentUpdateFPS"] for r in runs),
        "minimumRunCapturedPDFContentUpdateFPS": min(r["capturedPDFContentUpdateFPS"] for r in runs),
        "medianUniqueCompleteCaptureFPS": statistics.median(r["uniqueCompleteCaptureFPS"] for r in runs),
        "pooledChangedFrameIntervalsMs": ANALYSIS.distribution(pooled_gaps),
        "pooledContentSilenceIncludingBoundariesMs": ANALYSIS.distribution(boundaries),
        "medianRunP95ChangedFrameGapMs": statistics.median(r["changedPDFFrameIntervalsMs"]["p95"] for r in runs),
        "medianCollectorCPUPercentOneCoreWholeCapture": statistics.median(r["collectorCPUPercentOneCoreWholeCapture"] for r in runs),
        "maximumCollectorCPUPercentOneCoreWholeCapture": max(r["collectorCPUPercentOneCoreWholeCapture"] for r in runs),
        "medianActualInputDeliveryHz": statistics.median(r["actualInputDeliveryHz"] for r in runs),
        "allForegroundGeometryHashAndLogGatesPassed": True, "runs": runs,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wide", default="baseline-wide-qualified-pilot3,baseline-wide-qualified-run2,baseline-wide-qualified-run3")
    parser.add_argument("--narrow", default="baseline-narrow-qualified-run1,baseline-narrow-qualified-run2,baseline-narrow-qualified-run3")
    parser.add_argument("--output-prefix", default="logs/mac-refinement-20261028/scroll-fps/baseline-scroll-matrix")
    args = parser.parse_args()
    output = ANALYSIS.local(args.output_prefix)
    if output.with_suffix(".json").exists() or output.with_suffix(".md").exists():
        raise ValueError("matrix outputs already exist; preserve earlier evidence")
    wide_tags, narrow_tags = args.wide.split(","), args.narrow.split(",")
    if len(wide_tags) != 3 or len(narrow_tags) != 3 or len(set(wide_tags + narrow_tags)) != 6:
        raise ValueError("matrix requires exactly3 distinct wide and3 distinct narrow runs")
    for tag in wide_tags + narrow_tags:
        if not tag.replace("-", "").replace("_", "").isalnum():
            raise ValueError("invalid case tag")
    groups = {"wide": group(wide_tags, [1470, 843], [500, 160, 750, 450]),
              "narrow": group(narrow_tags, [800, 632], [120, 130, 580, 350])}
    all_runs = [r for g in groups.values() for r in g["runs"]]
    for key in ["targetBinarySHA256", "driverSHA256", "collectorSHA256", "sourceCommit", "fixtureManifestSHA256", "appVersion", "appBuild"]:
        assert len(set(r[key] for r in all_runs)) == 1, "mixed builds/tools: " + key
    accepted = set(wide_tags + narrow_tags)
    excluded = [{"folder": str(p), "reason": "setup/failed/nonselected evidence; not in accepted matrix"}
                for p in sorted(BASE.glob("baseline-*")) if p.is_dir() and p.name not in accepted]
    report = {
        "status": "qualified-captured-content-scroll-matrix", "qualifiedSamples": len(all_runs),
        "productVersion": all_runs[0]["appVersion"], "productBuild": all_runs[0]["appBuild"],
        "sourceCommit": all_runs[0]["sourceCommit"], "targetBinarySHA256": all_runs[0]["targetBinarySHA256"],
        "driverSHA256": all_runs[0]["driverSHA256"], "collectorSHA256": all_runs[0]["collectorSHA256"],
        "fixtureManifestSHA256": all_runs[0]["fixtureManifestSHA256"],
        "method": "independent ScreenCaptureKit complete-frame displayTime plus actual PDF-only ROI pixel changes",
        "input": {"method": "programmatic own-process NSClipView scrollToPoint; no OS events or Cua/AX during timing",
                  "requestedHz": 60, "durationSeconds": 12, "speedDocumentPointsPerSecond": 200, "zoom": 3.43,
                  "approximateSpeedScreenPointsPerSecond": 686, "pageCrossing": "center geometry182to186; cached currentPage is not crossing proof"},
        "capture": {"requestedCeilingFPS": 120, "outputScale": 1, "pixelStep": 6,
                    "channelDeltaThreshold": 3, "minimumChangedPixelFraction": .001, "audioOrCursor": False},
        "groups": groups, "excluded": excluded,
        "limits": ["Captured PDF content-update FPS is not GPU/panel presentation FPS or hardware-gesture latency.",
                   "Requested60Hz programmatic input limits demanded cadence; actual timer delivery is logged separately, never used as FPS.",
                   "ScreenCaptureKit ceiling/ROI texture/change threshold and WindowServer scheduling can limit observed updates.",
                   "Capture/driver and the frozen app's50ms heartbeat/1Hz resource sampler add overhead. Collector CPU excludes WindowServer/GPU capture work.",
                   "Gap percentiles pool positive consecutive changed-frame intervals within each run; no gaps across runs. Boundaries/idle gaps remain separately reported.",
                   "Only one1484-page PDF,343% zoom, companion/panels closed; no paid AI/OCR requests. Not a broad book/hardware benchmark."],
    }
    output.with_suffix(".json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    lines = [f"# ReadingBook {report['productVersion']}：滚动内容更新矩阵\n\n",
             "宽窗和窄窗各3个合格新进程，原书库副本、同一1,484页PDF、343%缩放、伴读/浮动面板关闭。每轮12秒、60Hz时间驱动的程序化连续滚动，200文档点/秒（约686屏幕点/秒）；实际位移约2400文档点，原生几何页中心182→186。没有在计时中读AX、操作Cua或编译，没有调用付费AI/OCR。\n\n",
             "指标是独立ScreenCaptureKit捕获的**PDF区域像素内容更新FPS**。它不等于GPU/面板真实展示FPS、触控板手势帧率或输入延迟。60Hz输入、采集上限和观察开销均限制解释范围。\n\n",
             "| 窗口（实测） | 内容更新FPS（三轮中位） | 最低单轮FPS | 更新间隔中位 | p95 | p99 | 最大 | 采集器CPU中位（单核） |\n",
             "|---|---:|---:|---:|---:|---:|---:|---:|\n"]
    for name, g in groups.items():
        d = g["pooledChangedFrameIntervalsMs"]
        dims = "×".join(str(v) for v in g["actualWindowPixelsAtScale1"])
        lines.append(f"| {dims} | {g['medianCapturedPDFContentUpdateFPS']:.2f} | {g['minimumRunCapturedPDFContentUpdateFPS']:.2f} | {d['median']:.2f}ms | {d['p95']:.2f}ms | {d['p99']:.2f}ms | {d['maximum']:.2f}ms | {g['medianCollectorCPUPercentOneCoreWholeCapture']:.2f}% |\n")
    lines += ["\n间隔分位数是组内三轮的正向相邻像素更新间隔池化，未跨轮连接。完整滚动意图区间作为FPS分母，不剔除中间空白/停顿；包含区间边界的静默间隔也保留在JSON。较长间隔可能来自采集节奏、ROI空白或阈值，不直接称为掉帧率。\n\n",
              "## 单轮\n\n| 场景 | 内容FPS | p95/p99/最大间隔(ms) | 实际输入投递Hz | 状态 |\n|---|---:|---|---:|---|\n"]
    for g in groups.values():
        for r in g["runs"]:
            d = r["changedPDFFrameIntervalsMs"]
            lines.append(f"| [{r['tag']}]({r['result']}) | {r['capturedPDFContentUpdateFPS']:.3f} | {d['p95']:.2f}/{d['p99']:.2f}/{d['maximum']:.2f} | {r['actualInputDeliveryHz']:.2f} | 全前台、页跨越、哈希/日志门通过，进程已停 |\n")
    lines += ["\n## 边界与保护\n\n",
              f"冻结产品提交`{report['sourceCommit']}`，二进制SHA`{report['targetBinarySHA256']}`；六轮使用相同驱动和采集器SHA。目标二进制、驱动、采集器和原始测试输入库的保全门全部通过。原始失败、静止或设置预览没有提升为FPS样本，见JSON的excluded。\n\n",
              "宽窗ROI为500,160,750,450；窄窗请求800×600，实测800×632，独立预览检查后使用120,130,580,350。ROI避开工具栏、悬浮窗、光标和动画状态；采集不录音，不保存视频。实际帧使用complete状态、WindowServer Mach时间和区域RGB变化判定，重复区域不算PDF更新。\n\n",
              "采集器采用120FPS请求上限，输出缩放1、采样步长6、RGB差阈值3、变化比例阈值0.1%。自身CPU是完整约24秒采集段值，包含前后空闲，不包含额外WindowServer/GPU工作；像素锁定/处理耗时也在单轮JSON中，不能视为纯CPU。\n\n",
              "驱动是同进程文档clip滚动，不强制绘制/布局；几何页查询只在输入区间前后进行。PDFView.currentPage可能在此输入方式下缓存182，故保留该事实，用visiblePages/中心pageForPoint而非缓存字段证明跨页。硬件手势路径仍需单独验收。\n\n",
              "该矩阵只覆盖上面列出的冻结提交，可以与相同驱动/窗口/ROI/输入设置的另一冻结Release比较。它不代表其他工作区状态；是否发布应以正式交付记录为准。\n"]
    output.with_suffix(".md").write_text("".join(lines))
    print(json.dumps({name: {k: g[k] for k in ["qualifiedRunCount", "medianCapturedPDFContentUpdateFPS", "pooledChangedFrameIntervalsMs", "medianCollectorCPUPercentOneCoreWholeCapture"]} for name, g in groups.items()}, ensure_ascii=False))


if __name__ == "__main__":
    main()
