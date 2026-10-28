#!/usr/bin/env python3
"""Exercise the real native menu row layout without opening a user library."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    ROOT / "scripts/ui-layout-regression/main.swift",
    ROOT / "Sources/ReadingBook/ReadingAdaptiveRows.swift",
    ROOT / "Sources/ReadingBook/ReadingGlass.swift",
    ROOT / "Sources/ReadingBook/FrostWindowAppearance.swift",
    ROOT / "Sources/ReadingCore/ReadingControlRowsGeometry.swift",
]


def compile_probe(build: Path, logs: Path, env: dict[str, str]) -> Path:
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True, env=env
    ).strip()
    common = ["xcrun", "swiftc", "-parse-as-library", "-sdk", sdk,
              "-module-cache-path", env["SWIFT_MODULE_CACHE_PATH"],
              "-Xcc", "-fmodules-cache-path=" + env["CLANG_MODULE_CACHE_PATH"]]
    commands = [
        common + ["-emit-library", "-emit-module", "-module-name", "ReadingCore",
                  str(SOURCES[-1]), "-emit-module-path", str(build / "ReadingCore.swiftmodule"),
                  "-o", str(build / "libReadingCore.dylib")],
        common + ["-I", str(build), "-L", str(build), "-lReadingCore",
                  "-Xlinker", "-rpath", "-Xlinker", str(build),
                  *map(str, SOURCES[:-1]), "-o", str(build / "ui-layout-regression")],
    ]
    with (logs / "build.log").open("w") as output:
        for command in commands:
            subprocess.run(command, cwd=ROOT, env=env, stdout=output,
                           stderr=subprocess.STDOUT, check=True, timeout=180)
    return build / "ui-layout-regression"


def run_case(name: str, flags: list[str], binary: Path, logs: Path,
             env: dict[str, str], timeout: float, baseline: bool) -> dict:
    output_path = logs / f"{name}.log"
    started = time.monotonic()
    timed_out = False
    with output_path.open("w") as output, (logs / f"{name}-metrics.txt").open("w") as metrics:
        process = subprocess.Popen([str(binary), *flags], cwd=ROOT, env=env,
                                   stdout=output, stderr=subprocess.STDOUT)
        try:
            while process.poll() is None:
                if time.monotonic() - started >= timeout:
                    timed_out = True
                    try:
                        subprocess.run(
                            ["/usr/bin/sample", str(process.pid), "2", "10", "-file",
                             str(logs / f"{name}.sample.txt")],
                            stdout=output, stderr=subprocess.STDOUT, timeout=10,
                        )
                    except subprocess.TimeoutExpired:
                        output.write("Process sampler timed out; terminating only this test process.\n")
                    break
                metrics.write(time.strftime("%Y-%m-%d %H:%M:%S %z") + "\n")
                subprocess.run(["/bin/ps", "-p", str(process.pid), "-o", "pid,%cpu,rss,state"],
                               stdout=metrics, stderr=subprocess.DEVNULL)
                time.sleep(0.25)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
    system_log_ok = False
    with (logs / f"{name}-system.log").open("w") as output:
        try:
            collected = subprocess.run(
                ["/usr/bin/log", "show", "--last", "3m", "--style", "compact", "--predicate",
                 f"processIdentifier == {process.pid}"],
                stdout=output, stderr=subprocess.STDOUT, timeout=15,
            )
            system_log_ok = collected.returncode == 0
        except subprocess.TimeoutExpired:
            output.write("System log collection timed out.\n")
    text = output_path.read_text()
    system = (logs / f"{name}-system.log").read_text()
    counts = re.findall(r"make=(\d+) dismantle=(\d+)", text)
    made, removed = map(int, counts[-1]) if counts else (0, 0)
    completed = "DONE tick=100 " in text
    layout_warning = "300 iterations" in system
    publication_warning = "Publishing changes from within view updates" in system
    # The marker is a background NSView on each native-menu control. A legacy
    # chat ViewThatFits remains mounted; a bounded number of chat remounts is
    # expected. Thousands of mounts with a stalled timer reproduce the defect.
    if baseline:
        passed = timed_out and made >= 256 and not completed and system_log_ok and layout_warning
    else:
        passed = (not timed_out and process.returncode == 0 and completed
                  and 0 < made <= 256 and system_log_ok and not layout_warning and not publication_warning)
    return {
        "case": name, "pid": process.pid, "passed": passed,
        "baseline_expected_stall": baseline, "timed_out": timed_out,
        "returncode": process.returncode, "completed_100_ticks": completed,
        "elapsed_seconds": round(time.monotonic() - started, 3),
        "native_menu_markers_made": made, "native_menu_markers_dismantled": removed,
        "layout_warning_300_iterations": layout_warning,
        "publication_warning": publication_warning,
        "system_log_collection_succeeded": system_log_ok,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", action="store_true",
                        help="Explicitly reproduce the old ViewThatFits stall; never used by normal CI.")
    parser.add_argument("--visible", action="store_true", help="Show only the synthetic test window.")
    parser.add_argument("--timeout", type=float, default=20,
                        help="Per-process watchdog in seconds (minimum 12; default 20).")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This regression requires macOS with an AppKit/SwiftUI SDK.")
    if args.timeout < 12:
        parser.error("--timeout must be at least 12 seconds for 100 timer ticks.")
    build_parent = ROOT / ".build/ui-layout-regression"
    build_parent.mkdir(parents=True, exist_ok=True)
    build = Path(tempfile.mkdtemp(prefix="run-", dir=build_parent))
    logs = ROOT / "logs/ui-layout-regression" / build.name
    logs.mkdir(parents=True)
    for name in ["tmp"]:
        (build / name).mkdir()
    shared = ROOT / ".build/shared-module-cache"
    for cache in [shared / "swift", shared / "clang"]:
        cache.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, "TMPDIR": str(build / "tmp"),
           "SWIFT_MODULE_CACHE_PATH": str(shared / "swift"),
           "CLANG_MODULE_CACHE_PATH": str(shared / "clang")}
    report = {
        "baseline": args.baseline, "build_directory": str(build),
        "log_directory": str(logs),
        "source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in SOURCES},
        "cases": [],
    }
    try:
        binary = compile_probe(build, logs, env)
        visible = ["--visible"] if args.visible else []
        cases = ([('baseline', ['--baseline', *visible])] if args.baseline else
                 [('glass', visible), ('opaque', ['--no-glass', *visible])])
        for name, flags in cases:
            result = run_case(name, flags, binary, logs, env, args.timeout, args.baseline)
            report["cases"].append(result)
            print(json.dumps(result, ensure_ascii=False), flush=True)
    except (subprocess.SubprocessError, OSError) as error:
        report["error"] = str(error)
        print(f"Native layout regression failed: {error}; see {logs}", file=sys.stderr)
    passed = bool(report["cases"]) and all(case["passed"] for case in report["cases"]) and "error" not in report
    report["passed"] = passed
    (logs / "result.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(f"{'PASS' if passed else 'FAIL'}: {logs / 'result.json'}", flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
