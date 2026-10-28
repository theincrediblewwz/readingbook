#!/usr/bin/env python3
"""One isolated, time-marked native PDF scrolling/capture run. No OS input injection."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]


def local(value):
    path = Path(value)
    path = (path if path.is_absolute() else ROOT / path).resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError("all paths must resolve inside the workspace")
    return path


def read(path):
    return json.loads(path.read_text())


def write(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest_tree(path):
    return {str(p.relative_to(path)): sha(p) for p in sorted(path.rglob("*")) if p.is_file()}


def announce(**value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def wait_json(path, timeout=15, failure=None):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if failure and failure.exists():
            raise RuntimeError("driver failure: " + json.dumps(read(failure)))
        if path.exists():
            return read(path)
        time.sleep(0.1)
    raise RuntimeError("timed out waiting for " + str(path.relative_to(ROOT)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default=".build/perf-harness-20261028-release/build-manifest.json")
    parser.add_argument("--fixture", default="private-books/mac-refinement-20261028/library-before")
    parser.add_argument("--driver", default=".build/scroll-frame-capture/libReadingBookScrollDrive.dylib")
    parser.add_argument("--collector", default=".build/scroll-frame-capture/ScrollFrameCapture")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--roi", default="500,160,750,450", help="confirmed wide ROI, output pixels")
    parser.add_argument("--width", type=int, default=1470)
    parser.add_argument("--height", type=int, default=843)
    parser.add_argument("--pixel-step", type=int, default=6)
    parser.add_argument("--points-per-second", type=float, default=200, help="PDF document/clip-coordinate points, not screen points")
    parser.add_argument("--scroll-seconds", type=float, default=12)
    parser.add_argument("--input-hz", type=float, default=60)
    parser.add_argument("--capture-seconds", type=float, default=24)
    parser.add_argument("--roi-confirmed", action="store_true")
    args = parser.parse_args()
    if not args.tag.replace("-", "").replace("_", "").isalnum():
        raise ValueError("tag must be alphanumeric with hyphens/underscores")
    if not args.roi_confirmed:
        raise ValueError("inspect an own-window preview first, then explicitly pass --roi-confirmed")
    output = ROOT / "logs/mac-refinement-20261028/scroll-fps" / args.tag
    output.mkdir(parents=True, exist_ok=False)
    source_manifest, fixture = local(args.manifest), local(args.fixture)
    build = read(source_manifest)
    binary = local(build["app"]) / "Contents/MacOS/ReadingBook"
    driver, collector = local(args.driver), local(args.collector)
    before = manifest_tree(fixture)
    binary_before, driver_before, collector_before = sha(binary), sha(driver), sha(collector)
    if binary_before != build["binarySHA256"]:
        raise RuntimeError("frozen target binary does not match its build manifest")
    run = local(build["buildRoot"]) / "runs" / args.tag / "run-1"
    held_path = run / "held-process.json"
    control = run / "scroll-control"
    capture_process = None
    held = None
    preserve_held = False
    command_written = False
    result = dict(status="incomplete", tag=args.tag, manifest=str(source_manifest),
                  targetBinarySHA256=binary_before, driverSHA256=driver_before,
                  collectorSHA256=collector_before, fixtureFiles=len(before), inputMethod="programmatic-own-process-continuous-PDF-scroll",
                  latencyBaselineExcluded=True, hardwareGesture=False)
    write(output / "setup.json", result)
    try:
        launch_args = [sys.executable, str(ROOT / "scripts/mac-performance/run.py"), "--manifest", str(source_manifest),
                       "--library-copy", str(fixture), "--rounds", "1", "--width", str(args.width), "--height", str(args.height),
                       "--hold-final", "--scroll-driver", str(driver), "--tag", args.tag]
        announce(status="launching-isolated-held-test", tag=args.tag)
        with (output / "run-driver.log").open("w") as log:
            launched = subprocess.run(launch_args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=150)
        held = wait_json(held_path, timeout=2)
        result["heldPID"] = held["pid"]; result["heldRecord"] = str(held_path)
        if launched.returncode:
            raise RuntimeError("held performance setup failed; see run-driver.log")
        launch = read(run / "launch.json")
        nonce = launch["scrollDiagnostic"]["nonce"]
        ready = wait_json(control / "driver-ready.json", failure=control / "driver-failure.json")
        if ready["pid"] != held["pid"] or ready["nonce"] != nonce or not ready.get("workspacePDFVerified"):
            raise RuntimeError("driver identity/nonce/fixture mismatch")
        if (control / "start.json").exists() or (control / "driver-failure.json").exists():
            raise RuntimeError("control is stale or failed before capture")
        if time.time() - (control / "driver-ready.json").stat().st_mtime > 110:
            raise RuntimeError("driver-ready is too old for a fresh capture")
        capture = output / "capture"
        capture_args = [str(collector), "--workspace", str(ROOT), "--output", str(capture), "--pid", str(held["pid"]),
                        "--expected-executable", held["executable"], "--bundle", "org.readingbook.perf-harness",
                        "--window-id", str(ready["windowID"]), "--roi", args.roi, "--scale", "1", "--max-fps", "120",
                        "--seconds", str(args.capture_seconds), "--pixel-step", str(args.pixel_step), "--wait-for-foreground-seconds", "60"]
        env = os.environ.copy(); env["TMPDIR"] = str(ROOT / ".build/scroll-frame-capture/tmp")
        started_at = datetime.datetime.now().astimezone()
        capture_process = subprocess.Popen(capture_args, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
        selector = selectors.DefaultSelector(); selector.register(capture_process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + args.capture_seconds + 80
        pending = b""
        with (output / "capture-driver.log").open("w") as log:
            while capture_process.poll() is None:
                if time.monotonic() > deadline:
                    raise RuntimeError("collector timeout")
                for key, _ in selector.select(timeout=1):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    log.write(chunk.decode(errors="replace")); log.flush(); pending += chunk
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        try:
                            event = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if event.get("status") == "waiting-for-target-foreground":
                            preserve_held = True
                            announce(status="needs-cua-activation", pid=held["pid"], heldRecord=str(held_path),
                                     controlFresh=True, commandWritten=False, collectorWaitSeconds=60)
                        if event.get("status") == "capture-started":
                            if (control / "driver-failure.json").exists():
                                raise RuntimeError("driver expired before capture")
                            command = dict(nonce=nonce, durationSeconds=args.scroll_seconds, pointsPerSecond=args.points_per_second,
                                           inputHz=args.input_hz, direction="down", startAfterSeconds=2)
                            write(control / "start.json", command)
                            command_written = True; preserve_held = False
                            result["captureStartMachTicks"] = event["captureStartMachTicks"]
                            announce(status="capture-running-command-written", pid=held["pid"], output=str(output),
                                     durationSeconds=args.scroll_seconds, documentPointsPerSecond=args.points_per_second)
            trailing = capture_process.stdout.read()
            if trailing:
                log.write(trailing.decode(errors="replace"))
        selector.close()
        if capture_process.returncode or not command_written:
            if not command_written:
                preserve_held = True
                result["status"] = "needs-cua-activation-control-unconsumed"
            raise RuntimeError("collector did not complete successfully with an accepted fresh command")
        trace = wait_json(control / "scroll-trace.json", timeout=2, failure=control / "driver-failure.json")
        if trace["status"] != "completed":
            raise RuntimeError("scroll input ineligible: " + trace["status"])
        ticks = trace["ticks"]
        all_foreground = ticks and all(all(t["foreground"].get(k) for k in ["appActive", "keyWindow", "windowVisible", "occlusionVisible"]) for t in ticks)
        displacement = abs(ticks[-1]["actualY"] - ticks[0]["actualY"]) if ticks else 0
        pages = sorted(set(t["currentPDFPage"] for t in ticks if t.get("currentPDFPage") is not None))
        initial_center, final_center = trace.get("initialCenterPDFPage"), trace.get("finalCenterPDFPage")
        initial_visible, final_visible = trace.get("initialVisiblePDFPages", []), trace.get("finalVisiblePDFPages", [])
        crossed = ((isinstance(initial_center, int) and isinstance(final_center, int) and initial_center != final_center)
                   or (bool(initial_visible and final_visible) and initial_visible != final_visible))
        result.update(inputTraceStatus=trace["status"], inputTicks=len(ticks), documentDisplacementPoints=displacement,
                      cachedCurrentPDFPages=pages, allInputForeground=bool(all_foreground), geometricPageCrossing=crossed,
                      initialCenterPDFPage=initial_center, finalCenterPDFPage=final_center,
                      initialVisiblePDFPages=initial_visible, finalVisiblePDFPages=final_visible)
        if not all_foreground or displacement < args.points_per_second * args.scroll_seconds * .95 or not crossed:
            raise RuntimeError("input did not establish foreground continuous displacement and page crossing")
        analysis_path = output / "analysis.json"
        analyzed = subprocess.run([sys.executable, str(ROOT / "scripts/mac-performance/analyze-scroll-capture.py"),
            "--capture", str(capture), "--intervals-file", str(control / "scroll-intervals.json"), "--roi-confirmed",
            "--continuous-input", "--output", str(analysis_path)], cwd=ROOT, capture_output=True, text=True)
        (output / "analysis-driver.log").write_text(analyzed.stdout + analyzed.stderr)
        if analyzed.returncode:
            raise RuntimeError("capture analysis failed")
        analysis = read(analysis_path)
        result.update(analysis=str(analysis_path),
                      interval=analysis["intervals"][0], status=analysis["intervals"][0]["status"])
        ended_at = datetime.datetime.now().astimezone()
        log_args = ["/usr/bin/log", "show", "--style", "compact", "--start", started_at.strftime("%Y-%m-%d %H:%M:%S"),
                    "--end", ended_at.strftime("%Y-%m-%d %H:%M:%S"), "--predicate", "processIdentifier == " + str(held["pid"])]
        system_log = subprocess.run(log_args, cwd=ROOT, capture_output=True, text=True, timeout=30)
        (output / "scroll-system.log").write_text(system_log.stdout + system_log.stderr)
        text = system_log.stdout + system_log.stderr
        result["systemLogReturnCode"] = system_log.returncode
        result["layoutWarningLines"] = sum("being marked as needing layout" in line or "300 iterations" in line for line in text.splitlines())
        result["publishingWarnings"] = text.count("Publishing changes from within view updates")
        if system_log.returncode or result["layoutWarningLines"] or result["publishingWarnings"]:
            result["status"] = "ineligible-log-gate"
    except Exception as error:
        if result["status"] == "incomplete":
            result["status"] = "failed-scroll-diagnostic"
        result["reason"] = str(error)
    finally:
        if capture_process is not None and capture_process.poll() is None:
            capture_process.terminate()
            try:
                capture_process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                capture_process.kill(); capture_process.wait(timeout=5)
        result["targetBinaryUnchanged"] = sha(binary) == binary_before
        result["driverUnchanged"] = sha(driver) == driver_before
        result["collectorUnchanged"] = sha(collector) == collector_before
        result["fixtureUnchanged"] = manifest_tree(fixture) == before
        if not all(result[k] for k in ["targetBinaryUnchanged", "driverUnchanged", "collectorUnchanged", "fixtureUnchanged"]):
            result["status"] = "failed-preservation"
        if held and not preserve_held:
            stopped = subprocess.run([sys.executable, str(ROOT / "scripts/mac-performance/run.py"), "--stop-held", str(held_path)],
                                     cwd=ROOT, capture_output=True, text=True, timeout=30)
            (output / "stop-held.log").write_text(stopped.stdout + stopped.stderr)
            result["ownedHeldStopped"] = stopped.returncode == 0
            if stopped.returncode:
                result["status"] = "failed-stop-owned-held"
        else:
            result["ownedHeldStopped"] = False
            result["heldPreservedForCuaActivation"] = bool(held and preserve_held)
        write(output / "result.json", result)
        announce(**result)
    return 0 if result["status"] == "qualified-captured-content-update-measurement" else 3 if preserve_held else 1


if __name__ == "__main__":
    sys.exit(main())
