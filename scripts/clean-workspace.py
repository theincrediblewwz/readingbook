#!/usr/bin/env python3
"""Report explicitly allowlisted build waste; delete only with --apply.

This tool never deletes a whole test run or anything outside this repository's
.build. Historical 2026-10-28 artifacts additionally require --legacy-artifacts.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
CACHE_PATHS = (
    "ai-concurrency-probe/cache", "native-ui-harness/cache",
    "native-ui-harness/phase-metrics-probe/cache", "load-retry-probe/cache",
    "layout-root-probe/cache", "stable-rows-probe/cache",
    "native-note-probe/clang-cache", "native-note-probe/module-cache",
    "layout-probe/module-cache", "perf-tool-validation/modules",
    "hover-delivery-probe/module-cache", "scroll-frame-capture/module-cache",
    "ai-concurrency-ui/cache",
    # Retired SwiftPM defaults: current builders pass the shared cache explicitly.
    "mac-debug/arm64-apple-macosx/debug/ModuleCache",
    "perf-refinement-20261028-final/build/arm64-apple-macosx/release/ModuleCache",
)
# These are retired scratch builds, not a policy for future Release directories.
LEGACY_BUILDS = (
    "local-release", "perf-harness-20261028-thumbnails-off/build",
    "perf-harness-20261028-release/build",
)
LEGACY_NATIVE_RUNS = (
    "20261028-124647-initial-panel", "20261028-124742-initial-workspace",
    "20261028-125134-fixed-workspace", "20261028-125203-fixed-panel",
    "20261028-125225-fixed-pdf", "20261028-125318-fixed-pdf-stress",
    "20261028-125532-driver-final-check", "20261028-130647-final-driver",
    "20261028-131553-phase-attribution-local", "20261028-131855-phase-overlap-local",
    "20261028-195857-pdf-lazy-thumbnails", "20261028-195938-pdf-lazy-thumbnails-2",
    "20261028-200001-pdf-lazy-thumbnails-3", "20261028-200049-pdf-lazy-thumbnails-4",
    "20261028-200132-pdf-lazy-thumbnails-5", "20261028-200150-workspace-120-after-pdf",
    "20261028-232152-final-debug13-pdf8", "20261028-232226-final-debug13-workspace120",
    "20261028-232346-final-debug13-real1484",
    "20261029-002350-book-picker-hotfix-navigation1", "20261029-002635-book-picker-hotfix-navigation2",
    "20261029-002845-book-picker-hotfix-navigation3",
    "20261029-003443-book-picker-hotfix-shared-action", "20261029-003521-book-picker-hotfix-workspace24",
)
LEGACY_PERF_TAGS = (
    "formal-warm-wide", "baseline-narrow-roi-preview", "pilot-load-launchservices",
    "pilot-load-foreground", "formal-import-wide", "pilot-load-established",
    "baseline-narrow-qualified-run1", "baseline-wide-qualified-run3",
    "baseline-wide-qualified-run2", "pilot-load-launched", "formal-import-narrow",
    "baseline-wide-qualified-pilot2", "baseline-wide-qualified-pilot3",
    "startup-profile-wide", "formal-warm-narrow-v3", "formal-import-wide-v2",
    "formal-warm-narrow-v2", "formal-warm-narrow", "baseline-narrow-qualified-run2",
    "pilot-load", "baseline-narrow-qualified-run3", "pilot-load-visible",
    "formal-load-wide", "pilot-import-launchservices", "formal-load-narrow",
    "refinement-baseline-scroll-driver", "refinement-baseline-scroll-setup",
    "current-session-old-control",
)
REFINEMENT_PERF_TAGS = (
    "final-f0eabf7-diagnostic-scroll-sample", "final-f0eabf7-latency-import-narrow",
    "final-f0eabf7-latency-import-wide", "final-f0eabf7-latency-load-narrow",
    "final-f0eabf7-latency-load-wide", "final-f0eabf7-latency-warm-narrow",
    "final-f0eabf7-latency-warm-wide", "final-f0eabf7-narrow-roi-preview",
    "final-f0eabf7-narrow-run1", "final-f0eabf7-narrow-run2", "final-f0eabf7-narrow-run3",
    "final-f0eabf7-wide-roi-preview", "final-f0eabf7-wide-run1",
    "final-f0eabf7-wide-run2", "final-f0eabf7-wide-run3",
    "opt1029-f0-clean-pointer-narrow-control",
)
PERF_COPY_ALLOWLISTS = {
    "perf-harness-20261028-release": LEGACY_PERF_TAGS,
    "perf-refinement-20261028-final": REFINEMENT_PERF_TAGS,
    "perf-harness-20261028-thumbnails-off": (
        "opt1029-old-thumbnails-off-narrow-control",
        "opt1029-old-thumbnails-off-narrow-control2",
        "opt1029-old-thumbnails-off-narrow-control4",
    ),
}
PROTECTED = ("Sources", "Tests", "scripts", "Design", "logs", "private-books", "dist", ".git")


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def sha256(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def inside(path: Path, parent: Path) -> bool:
    return path == parent or parent in path.parents


def guarded_path(path: Path) -> Path:
    """Reject symlink ancestors, even if their current destination is local."""
    if not path.is_absolute() or not inside(path, ROOT) or ".." in path.parts:
        raise ValueError("Path must be absolute and inside the workspace: " + str(path))
    relative = path.relative_to(ROOT)
    current = ROOT
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("Symlink target/ancestor is not allowed: " + str(current))
    if not inside(path.resolve(), ROOT):
        raise ValueError("Resolved path escapes the workspace: " + str(path))
    return path


def validate_root() -> None:
    if ROOT != ROOT.resolve() or not (ROOT / "Package.swift").is_file() or not (ROOT / "Sources/ReadingBook").is_dir():
        raise ValueError("This script must live in the ReadingBook repository's scripts directory")
    if not (ROOT / ".git").exists():
        raise ValueError("Repository marker is missing")
    guarded_path(ROOT / ".build")
    guarded_path(ROOT / "logs")
    guarded_path(ROOT / "logs/workspace-cleanup")


def allowed(relative: str, legacy: bool) -> bool:
    if relative in {".build/" + value for value in CACHE_PATHS}:
        return True
    if re.fullmatch(r"\.build/ui-layout-regression/run-[A-Za-z0-9_]+/cache", relative):
        return True
    if not legacy:
        return False
    if relative in {".build/" + value for value in LEGACY_BUILDS}:
        return True
    if any(relative == f".build/native-ui-harness/runs/{run}/{leaf}"
           for run in LEGACY_NATIVE_RUNS for leaf in ("Native UI Regression.app", "library")):
        return True
    match = re.fullmatch(r"\.build/([^/]+)/runs/([^/]+)/run-([1-9][0-9]*)/(library|input)", relative)
    return bool(match and match.group(2) in PERF_COPY_ALLOWLISTS.get(match.group(1), ()))


def read_metadata(path: Path) -> dict:
    guarded_path(path)
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("Expected metadata object: " + str(path))
    return value


def candidate_paths(legacy: bool) -> tuple[list[dict], list[dict]]:
    targets: list[dict] = []
    skipped: list[dict] = []

    def add(relative: str, kind: str, reason: str, evidence: list[str] | None = None) -> None:
        path = ROOT / relative
        if path.exists() or path.is_symlink():
            if not allowed(relative, legacy):
                raise ValueError("Internal allowlist mismatch: " + relative)
            targets.append({"path": str(path), "relativePath": relative, "kind": kind,
                            "reason": reason, "rebuildable": True, "evidence": evidence or []})

    for value in CACHE_PATHS:
        add(".build/" + value, "cache", "重复系统模块缓存；保留 helper 二进制、manifest 和 dSYM，可按需重建。")
    cache_parent = guarded_path(ROOT / ".build/ui-layout-regression")
    if cache_parent.exists():
        for run in sorted(cache_parent.iterdir()):
            if re.fullmatch(r"run-[A-Za-z0-9_]+", run.name):
                add(str((run / "cache").relative_to(ROOT)), "cache", "原生布局回归每轮重复的编译缓存，可重新生成。")
    if not legacy:
        return targets, skipped
    for value in LEGACY_BUILDS:
        add(".build/" + value, "legacy-build", "2026-10-28 已弃用的 SwiftPM 编译中间产物；保留正式包、独立诊断 app、源码归档和原始证据。")
    for name in LEGACY_NATIVE_RUNS:
        run = ROOT / ".build/native-ui-harness/runs" / name
        if not run.exists():
            continue
        summary_path = ROOT / "logs" / ("native-ui-harness-" + name) / "summary.json"
        try:
            guarded_path(run)
            summary = read_metadata(summary_path)
            if summary.get("output") != str(summary_path.parent) or not isinstance(summary.get("returncode"), int):
                raise ValueError("Missing finished native run identity/exit status")
        except (OSError, ValueError) as error:
            skipped.append({"path": str(run), "reason": str(error)})
            continue
        for leaf in ("Native UI Regression.app", "library"):
            add(str((run / leaf).relative_to(ROOT)), "test-copy", "已结束的原生测试复制 app/隔离书库；报告、采样、截图及 OS 状态继续保留。", [str(summary_path)])
    for build_name, tag in ((name, tag) for name, tags in PERF_COPY_ALLOWLISTS.items() for tag in tags):
        base = ROOT / ".build" / build_name / "runs"
        group = guarded_path(base / tag)
        if not group.exists():
            continue
        for run in sorted(group.iterdir()):
            if not re.fullmatch(r"run-[1-9][0-9]*", run.name):
                continue
            try:
                guarded_path(run)
                config = read_metadata(run / "config.json")
                result = read_metadata(run / "result.json")
                if config.get("workspace") != str(ROOT) or config.get("output") != str(run) or config.get("library") != str(run / "library"):
                    raise ValueError("Performance run owner is not this isolated workspace run")
                if result.get("run") != str(run) or not isinstance(result.get("status"), str):
                    raise ValueError("Missing completed performance result")
            except (OSError, ValueError) as error:
                skipped.append({"path": str(run), "reason": str(error)})
                continue
            evidence = [str(run / name) for name in ("config.json", "result.json", "events.jsonl", "system.log")]
            add(str((run / "library").relative_to(ROOT)), "test-copy", "性能测试通过 copytree 或导入创建的隔离书库副本；所有原始事件和系统日志保留。", evidence)
            source = config.get("source")
            if config.get("mode") == "import" and isinstance(source, str) and inside(Path(source), run / "input"):
                add(str((run / "input").relative_to(ROOT)), "test-copy", "导入测试通过 copy2 创建的输入 PDF 副本；原 PDF 与源 SHA 报告保留。", evidence)
    return targets, skipped


def scan_target(path: Path, hash_files: bool) -> dict:
    guarded_path(path)
    if not path.is_dir():
        raise ValueError("Only allowlisted directories may be deleted: " + str(path))
    entries: list[dict] = []
    seen: set[tuple[int, int]] = set()
    allocated = logical = files = 0
    initial = path.stat()
    for parent, dirs, names in os.walk(path, followlinks=False):
        parent_path = Path(parent)
        for item in [parent_path] + [parent_path / name for name in dirs + names]:
            # Every directory is seen once as a child and once as its walk root.
            info = item.lstat()
            inode = (info.st_dev, info.st_ino)
            if inode not in seen:
                seen.add(inode)
                allocated += getattr(info, "st_blocks", 0) * 512
            rel = item.relative_to(path).as_posix()
            if stat.S_ISLNK(info.st_mode):
                resolved = item.resolve()
                if not inside(resolved, ROOT):
                    raise ValueError("Nested symlink escapes workspace: " + str(item))
                if not any(row["path"] == rel for row in entries):
                    entries.append({"path": rel, "type": "symlink", "linkTarget": os.readlink(item),
                                    "resolvedPath": str(resolved), "mode": stat.S_IMODE(info.st_mode)})
            elif stat.S_ISREG(info.st_mode):
                files += 1
                logical += info.st_size
                if hash_files:
                    digest = sha256(item)
                    after = item.lstat()
                    if (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                        raise ValueError("File changed during SHA inventory: " + str(item))
                    entries.append({"path": rel, "type": "file", "sizeBytes": info.st_size,
                                    "sha256": digest, "mtimeNanoseconds": info.st_mtime_ns,
                                    "mode": stat.S_IMODE(info.st_mode)})
            elif not stat.S_ISDIR(info.st_mode):
                raise ValueError("Unexpected special file in deletion target: " + str(item))
    return {"allocatedBytes": allocated, "logicalBytes": logical, "fileCount": files,
            "rootIdentity": [initial.st_dev, initial.st_ino, initial.st_mtime_ns],
            "sha256Inventory": hash_files, "entries": entries}


def active_blockers() -> list[dict]:
    # -ww avoids truncating long app paths. Separate columns retain spaces in
    # macOS application executable names without guessing where argv starts.
    command = subprocess.check_output(["/bin/ps", "-ww", "-axo", "pid=,comm="], text=True)
    exact = {"swift", "swiftc", "swift-frontend", "swift-build", "swift-driver", "swift-package",
             "clang", "clang++", "ld", "ld64", "ld64.lld", "lld", "xcodebuild",
             "native-ui-harness", "ai-concurrency-probe", "ai-concurrency-ui-host",
             "nativenoteeditorprobe", "scrollframecapture", "ui-layout-regression", "sample", "vmmap"}
    blockers = []
    for line in command.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        pid, executable = int(parts[0]), parts[1]
        if pid == os.getpid():
            continue
        name = Path(executable).name.lower()
        local_probe = inside(Path(executable), ROOT / ".build") and any(value in name for value in ("probe", "harness", "collector"))
        versioned_compiler = bool(re.fullmatch(r"(?:clang(?:\+\+)?|swiftc?)(?:-[0-9.]+)?", name))
        if name in exact or versioned_compiler or name.startswith("readingbook") or local_probe:
            blockers.append({"pid": pid, "executable": executable})
    return blockers


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Delete the allowlisted targets after writing complete reports; default is dry-run")
    parser.add_argument("--legacy-artifacts", action="store_true", help="Also include explicitly retired 2026-10-28 builds and finished test copies")
    args = parser.parse_args()
    validate_root()
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ") + "-" + uuid.uuid4().hex[:6]
    output = guarded_path(ROOT / "logs/workspace-cleanup" / stamp)
    output.mkdir(parents=True, exist_ok=False)
    report: dict = {"version": 1, "workspaceRoot": str(ROOT), "reportDirectory": str(output),
                    "scriptSHA256": sha256(Path(__file__).resolve()),
                    "mode": "apply" if args.apply else "dry-run", "legacyArtifacts": args.legacy_artifacts,
                    "protectedTopLevelPaths": [str(ROOT / value) for value in PROTECTED],
                    "status": "planning", "targets": [], "deleted": [], "skipped": [],
                    "diskFreeBytesBefore": shutil.disk_usage(ROOT).free}
    report_path = output / "report.json"
    write_json(report_path, report)
    try:
        candidates, report["skipped"] = candidate_paths(args.legacy_artifacts)
        for index, target in enumerate(candidates, 1):
            path = Path(target["path"])
            if not allowed(target["relativePath"], args.legacy_artifacts):
                raise ValueError("Target is not explicitly allowlisted: " + str(path))
            scan = scan_target(path, target["kind"] == "test-copy")
            inventory = output / f"inventory-{index:03d}.json"
            write_json(inventory, {"target": str(path), **scan})
            target.update({key: value for key, value in scan.items() if key != "entries"})
            target["inventory"] = str(inventory)
            report["targets"].append(target)
        report["totalAllocatedBytes"] = sum(item["allocatedBytes"] for item in report["targets"])
        report["activeBlockers"] = active_blockers()
        report["status"] = "blocked" if args.apply and report["activeBlockers"] else "ready" if args.apply else "dry-run"
        write_json(report_path, report)
        if args.apply and report["activeBlockers"]:
            raise RuntimeError("Refusing deletion while compiler, ReadingBook or native probe/collector processes are active")
        if args.apply:
            for target in report["targets"]:
                blockers = active_blockers()
                if blockers:
                    report["activeBlockers"] = blockers
                    raise RuntimeError("A compiler or probe started; remaining cleanup stopped")
                path = guarded_path(Path(target["path"]))
                if not allowed(target["relativePath"], args.legacy_artifacts):
                    raise ValueError("Target no longer allowlisted")
                current = scan_target(path, target["kind"] == "test-copy")
                previous = json.loads(Path(target["inventory"]).read_text(encoding="utf-8"))
                if any(current[key] != previous[key] for key in ("rootIdentity", "fileCount", "logicalBytes", "entries")):
                    raise RuntimeError("Target changed since inventory; refusing deletion: " + str(path))
                shutil.rmtree(path)
                report["deleted"].append(target["path"])
                write_json(report_path, report)
            report["status"] = "completed"
        report["diskFreeBytesAfter"] = shutil.disk_usage(ROOT).free
        write_json(report_path, report)
        print(json.dumps({"status": report["status"], "report": str(report_path),
                          "targetCount": len(report["targets"]), "allocatedBytes": report["totalAllocatedBytes"],
                          "activeBlockers": report["activeBlockers"], "deletedCount": len(report["deleted"])}, ensure_ascii=False, indent=2))
        return 0
    except Exception as error:
        report["status"] = "blocked" if report.get("activeBlockers") else "failed"
        report["error"] = str(error)
        write_json(report_path, report)
        print(json.dumps({"status": report["status"], "error": str(error), "report": str(report_path)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
