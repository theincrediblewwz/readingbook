#!/usr/bin/env python3
"""One isolated, time-marked native PDF scrolling/capture run. No OS input injection."""
import argparse
import ctypes
import datetime
import hashlib
import json
import os
import math
from pathlib import Path
import plistlib
import selectors
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
DIAGNOSTIC_ENV_KEYS = frozenset(("READINGBOOK_DIAG_PAUSE_DOT", "READINGBOOK_DIAG_SKIP_HIDDEN_WIDTH",
                               "READINGBOOK_DIAG_BIND_HIDDEN_THUMBNAILS"))
MANUAL_SETUP_TIMEOUT_SECONDS = 90


class ManualSetupError(RuntimeError):
    """Setup was not confirmed; the held run/control must remain unconsumed."""


class FixedDwellError(RuntimeError):
    """A requested completed-run clock boundary could not be met."""


def qualify_pointer_guard(trace):
    guard = trace.get("pointerGuard", {})
    return (guard.get("policy") == "stationary-and-native-hit-outside-PDF-subtree"
            and guard.get("hitsPDFAtStart") is False
            and guard.get("hitsPDFAtEnd") is False
            and guard.get("movedDuringInput") is False)


def mach_ticks():
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    system.mach_absolute_time.restype = ctypes.c_uint64
    return system.mach_absolute_time()


def timing_protocol(args):
    seconds, tolerance = args.completed_dwell_seconds, args.dwell_tolerance_seconds
    if seconds is None:
        if args.formal_fixed_dwell:
            raise ValueError("formal fixed dwell requires --completed-dwell-seconds")
        return None
    if not math.isfinite(seconds) or not 2 <= seconds <= 90:
        raise ValueError("completed dwell must be finite and between 2 and 90 seconds")
    if not math.isfinite(tolerance) or not 0.05 <= tolerance <= 2:
        raise ValueError("dwell tolerance must be finite and between 0.05 and 2 seconds")
    if args.manual_setup and args.formal_fixed_dwell:
        raise ValueError("formal fixed dwell cannot use variable manual setup")
    if args.formal_fixed_dwell and (not args.pointer_park_confirmed or not args.no_overlay_confirmed
            or not args.no_interaction_confirmed or not args.pointer_park_evidence.strip()
            or not args.expected_source_commit):
        raise ValueError("formal fixed dwell requires exact source and explicit pointer/overlay/interaction preflight evidence")
    return dict(version=1, anchor="run.completed", requestedSeconds=seconds,
                toleranceSeconds=tolerance, formalRequested=args.formal_fixed_dwell)


def validate_source_identity(build, expected):
    source = build.get("sourceCommit")
    if expected is not None and (len(expected) != 40 or any(c not in "0123456789abcdef" for c in expected)
                                 or source != expected):
        raise ValueError("expected source must be the exact 40-character frozen build commit")
    return source


def pointer_protocol(args):
    if not (args.pointer_park_confirmed and args.no_overlay_confirmed and args.no_interaction_confirmed):
        return None
    return dict(version=1, condition="pointer parked outside PDF; ROI clear before launch",
                interactionPolicy="no operator UI interaction from preflight through capture",
                verification="operator assertion only; no continuous pointer/overlay telemetry")


def fixed_dwell_plan(events_path, protocol):
    rows = [json.loads(line) for line in events_path.read_text().splitlines() if line]
    main = next(row for row in rows if row["event"] == "main.entry")
    completed = next(row for row in rows if row["event"] == "run.completed")
    numer, denom = main["timebaseNumer"], main["timebaseDenom"]
    if numer <= 0 or denom <= 0 or completed["ticks"] < main["ticks"]:
        raise FixedDwellError("invalid completed-run Mach anchor/timebase")
    factor = numer / denom / 1e9
    return dict(anchorMachTicks=completed["ticks"], secondsPerMachTick=factor,
                targetMachTicks=completed["ticks"] + round(protocol["requestedSeconds"] / factor))


def wait_for_capture_boundary(plan, control):
    # Four seconds permit collector initialization and driver arming. A missed
    # target is rejected, never silently shifted from an early case to a warm one.
    while True:
        if (control / "driver-failure.json").exists() or (control / "start.json").exists():
            raise FixedDwellError("fixed dwell control failed or was consumed before capture")
        remaining = (plan["targetMachTicks"] - mach_ticks()) * plan["secondsPerMachTick"]
        if remaining <= 0:
            raise FixedDwellError("fixed dwell target passed before capture; no input was started")
        if remaining <= 4:
            return
        time.sleep(min(0.1, remaining - 4))


def command_delay(plan, now_ticks):
    remaining = (plan["targetMachTicks"] - now_ticks) * plan["secondsPerMachTick"]
    if remaining <= 0 or remaining > 30:
        raise FixedDwellError("fixed dwell target cannot be armed within the driver's 0–30s delay")
    return remaining


def qualify_fixed_dwell(dwell, protocol):
    actual = dwell["runCompletedToInputSeconds"]
    error = actual - protocol["requestedSeconds"]
    return dict(anchor="run.completed", requestedSeconds=protocol["requestedSeconds"],
                actualSeconds=actual, errorSeconds=error, toleranceSeconds=protocol["toleranceSeconds"],
                qualified=math.isfinite(actual) and abs(error) <= protocol["toleranceSeconds"])


def diagnostic_environment(values):
    result = {}
    for value in values:
        key, separator, setting = value.partition("=")
        if not separator or key not in DIAGNOSTIC_ENV_KEYS or setting not in ("0", "1") or key in result:
            raise ValueError("diagnostic environment requires unique allowlisted NAME=0/1 values")
        result[key] = setting
    return result


def fps_diagnostic_metadata(build, diagnostic_env, manual_setup=False):
    reasons = []
    if build.get("formalFPSBaselineExcluded", False) or build.get("diagnosticOnly", False):
        reasons.append("diagnostic-build-manifest")
    if any(value == "1" for value in diagnostic_env.values()):
        reasons.append("experimental-component-switch")
    if manual_setup:
        reasons.append("variable-manual-setup-dwell; single control only")
    return dict(diagnosticOnly=bool(build.get("diagnosticOnly", False)),
                formalFPSBaselineExcluded=bool(reasons), formalFPSBaselineExclusionReasons=reasons)


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


def validate_fresh_control(control, held, nonce):
    ready_path = control / "driver-ready.json"
    ready = read(ready_path)
    if ready["pid"] != held["pid"] or ready["nonce"] != nonce or not ready.get("workspacePDFVerified"):
        raise RuntimeError("driver identity/nonce/fixture mismatch")
    if (control / "start.json").exists() or (control / "driver-failure.json").exists():
        raise RuntimeError("control is stale or failed before capture")
    if time.time() - ready_path.stat().st_mtime > 110:
        raise RuntimeError("driver-ready is too old for a fresh capture")
    return ready


def validate_manual_setup_confirmation(value, nonce):
    if not isinstance(value, dict) or value.get("nonce") != nonce:
        raise ManualSetupError("manual setup confirmation nonce mismatch")
    for key in ("roiConfirmed", "noOverlayConfirmed", "manualInteractionFinished"):
        if value.get(key) is not True:
            raise ManualSetupError("manual setup confirmation requires " + key + "=true")
    return value


def wait_manual_setup(path, nonce, control, timeout=MANUAL_SETUP_TIMEOUT_SECONDS):
    if not 0 <= timeout <= MANUAL_SETUP_TIMEOUT_SECONDS:
        raise ValueError("manual setup timeout must be at most 90 seconds")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if (control / "driver-failure.json").exists() or (control / "start.json").exists():
            raise ManualSetupError("manual setup control failed or was consumed before confirmation")
        if path.exists():
            try:
                return validate_manual_setup_confirmation(read(path), nonce)
            except (OSError, json.JSONDecodeError) as error:
                raise ManualSetupError("manual setup confirmation is unreadable: " + str(error)) from error
        time.sleep(min(0.1, max(0, deadline - time.monotonic())))
    raise ManualSetupError("manual setup was not confirmed within 90 seconds; held run and control preserved")


def validate_held_identity(held):
    identity = subprocess.run(["/bin/ps", "-p", str(held["pid"]), "-o", "comm="],
                              capture_output=True, text=True, timeout=5)
    if identity.returncode or identity.stdout.strip() != held["executable"]:
        raise ManualSetupError("held PID no longer matches owned probe executable")


def pre_scroll_dwell(events_path, input_start_ticks):
    rows = [json.loads(line) for line in events_path.read_text().splitlines() if line]
    main = next(row for row in rows if row["event"] == "main.entry")
    completed = next(row for row in rows if row["event"] == "run.completed")
    if not main["timebaseNumer"] > 0 or not main["timebaseDenom"] > 0:
        raise ValueError("invalid pre-scroll event timebase")
    if input_start_ticks < completed["ticks"] or completed["ticks"] < main["ticks"]:
        raise ValueError("pre-scroll events are outside their required order")
    factor = main["timebaseNumer"] / main["timebaseDenom"] / 1e9
    return dict(mainEntryToInputSeconds=(input_start_ticks - main["ticks"]) * factor,
                runCompletedToInputSeconds=(input_start_ticks - completed["ticks"]) * factor,
                measuredAfterInput=True, clock="shared Mach absolute ticks; no warmup inferred from FPS")


def argument_parser():
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
    parser.add_argument("--manual-setup", action="store_true",
                        help="wait up to 90s for nonce-bound ROI/overlay/interaction confirmation before collector launch")
    parser.add_argument("--completed-dwell-seconds", type=float,
                        help="target actual input this many Mach seconds after run.completed (2–90)")
    parser.add_argument("--dwell-tolerance-seconds", type=float, default=0.5)
    parser.add_argument("--formal-fixed-dwell", action="store_true")
    parser.add_argument("--expected-source-commit", help="exact 40-character frozen source commit")
    parser.add_argument("--pointer-park-confirmed", action="store_true")
    parser.add_argument("--no-overlay-confirmed", action="store_true")
    parser.add_argument("--no-interaction-confirmed", action="store_true",
                        help="operator commitment to no UI interaction from preflight through capture; not telemetry")
    parser.add_argument("--pointer-park-evidence", default="",
                        help="operator description of preflight parking/ROI check; not automated full-duration proof")
    parser.add_argument("--diagnostic-env", action="append", default=[],
                        help="allowlisted scroll-diagnostic NAME=0/1; repeat for distinct keys")
    return parser


def main():
    args = argument_parser().parse_args()
    diagnostic_env = diagnostic_environment(args.diagnostic_env)
    protocol = timing_protocol(args)
    if not args.tag.replace("-", "").replace("_", "").isalnum():
        raise ValueError("tag must be alphanumeric with hyphens/underscores")
    if not args.roi_confirmed:
        raise ValueError("inspect an own-window preview first, then explicitly pass --roi-confirmed")
    output = ROOT / "logs/mac-refinement-20261028/scroll-fps" / args.tag
    output.mkdir(parents=True, exist_ok=False)
    source_manifest, fixture = local(args.manifest), local(args.fixture)
    build = read(source_manifest)
    validate_source_identity(build, args.expected_source_commit)
    binary = local(build["app"]) / "Contents/MacOS/ReadingBook"
    driver, collector = local(args.driver), local(args.collector)
    before = manifest_tree(fixture)
    binary_before, driver_before, collector_before = sha(binary), sha(driver), sha(collector)
    if binary_before != build["binarySHA256"]:
        raise RuntimeError("frozen target binary does not match its build manifest")
    info_path = binary.parent.parent / "Info.plist"
    info = plistlib.loads(info_path.read_bytes()) if info_path.exists() else {}
    if args.formal_fixed_dwell and (build.get("diagnosticOnly") or build.get("formalFPSBaselineExcluded")
                                    or any(v == "1" for v in diagnostic_env.values())):
        raise ValueError("formal fixed dwell cannot use component-disabled/diagnostic-only builds")
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
                  latencyBaselineExcluded=True, hardwareGesture=False,
                  diagnosticEnvironment=diagnostic_env, manualSetupRequired=args.manual_setup,
                  sourceCommit=build.get("sourceCommit"), buildManifestSHA256=sha(source_manifest),
                  appVersion=info.get("CFBundleShortVersionString"), appBuild=info.get("CFBundleVersion"),
                  timingProtocol=protocol, pointerProtocol=pointer_protocol(args),
                  pointerParkEvidence=args.pointer_park_evidence,
                  manualSetupStatus="pending" if args.manual_setup else "not-requested",
                  **fps_diagnostic_metadata(build, diagnostic_env, args.manual_setup))
    if protocol is not None and not args.formal_fixed_dwell:
        result["formalFPSBaselineExcluded"] = True
        result["formalFPSBaselineExclusionReasons"].append("fixed-dwell-without-formal-preflight")
    write(output / "setup.json", result)
    try:
        launch_args = [sys.executable, str(ROOT / "scripts/mac-performance/run.py"), "--manifest", str(source_manifest),
                       "--library-copy", str(fixture), "--rounds", "1", "--width", str(args.width), "--height", str(args.height),
                       "--hold-final", "--scroll-driver", str(driver), "--tag", args.tag]
        for key, value in diagnostic_env.items():
            launch_args.extend(["--diagnostic-env", key + "=" + value])
        announce(status="launching-isolated-held-test", tag=args.tag)
        with (output / "run-driver.log").open("w") as log:
            launched = subprocess.run(launch_args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=150)
        held = (read(held_path) if held_path.exists() else None) if launched.returncode else wait_json(held_path, timeout=2)
        if held:
            preserve_held = args.manual_setup
            result["heldPID"] = held["pid"]; result["heldRecord"] = str(held_path)
        if launched.returncode:
            raise RuntimeError("held performance setup failed; see run-driver.log")
        launch = read(run / "launch.json")
        nonce = launch["scrollDiagnostic"]["nonce"]
        wait_json(control / "driver-ready.json", failure=control / "driver-failure.json")
        ready = validate_fresh_control(control, held, nonce)
        if args.manual_setup:
            confirmation_path = control / "setup-confirmed.json"
            setup_request = dict(status="setup-required", pid=held["pid"], app=str(local(build["app"])),
                                 executable=held["executable"], heldRecord=str(held_path), control=str(control), nonce=nonce,
                                 setupConfirmationPath=str(confirmation_path), maximumWaitSeconds=MANUAL_SETUP_TIMEOUT_SECONDS,
                                 windowID=ready["windowID"], roi=args.roi,
                                 requirements=dict(roiConfirmed=True, noOverlayConfirmed=True, manualInteractionFinished=True))
            result["manualSetupConfirmationPath"] = str(confirmation_path)
            write(output / "setup-required.json", setup_request)
            announce(**setup_request)
            confirmation = wait_manual_setup(confirmation_path, nonce, control)
            # No collector or input exists yet. Recheck after the operator's UI
            # work, rather than trusting the readiness/identity from before it.
            renewed_ready = validate_fresh_control(control, held, nonce)
            if (held["executable"] != str(binary) or renewed_ready.get("executable") != held["executable"]
                    or renewed_ready["windowID"] != ready["windowID"]):
                raise ManualSetupError("manual setup target executable/window identity changed")
            validate_held_identity(held)
            ready = renewed_ready
            result.update(manualSetupStatus="confirmed", manualSetupConfirmation=confirmation)
            announce(status="setup-confirmed", pid=held["pid"], control=str(control), nonce=nonce)
        plan = None
        if protocol is not None:
            plan = fixed_dwell_plan(run / "events.jsonl", protocol)
            result["fixedDwellPlan"] = plan
            announce(status="waiting-for-fixed-completed-dwell", pid=held["pid"], protocol=protocol, plan=plan)
            wait_for_capture_boundary(plan, control)
            ready = validate_fresh_control(control, held, nonce)
            validate_held_identity(held)
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
                            if args.formal_fixed_dwell:
                                raise FixedDwellError("target is not foreground; formal fixed dwell forbids Cua activation during capture setup")
                            preserve_held = True
                            announce(status="needs-cua-activation", pid=held["pid"], heldRecord=str(held_path),
                                     controlFresh=True, commandWritten=False, collectorWaitSeconds=60)
                        if event.get("status") == "capture-started":
                            if (control / "driver-failure.json").exists():
                                raise RuntimeError("driver expired before capture")
                            command = dict(nonce=nonce, durationSeconds=args.scroll_seconds, pointsPerSecond=args.points_per_second,
                                           inputHz=args.input_hz, direction="down",
                                           startAfterSeconds=command_delay(plan, mach_ticks()) if plan else 2)
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
        result["pointerGuard"] = trace.get("pointerGuard")
        result["pointerTelemetryQualified"] = qualify_pointer_guard(trace)
        if args.formal_fixed_dwell and not result["pointerTelemetryQualified"]:
            raise RuntimeError("formal scrolling requires a stationary pointer outside the native PDF subtree")
        result["preScrollDwell"] = pre_scroll_dwell(run / "events.jsonl", trace["startMachTicks"])
        if protocol is not None:
            result["fixedDwellQualification"] = qualify_fixed_dwell(result["preScrollDwell"], protocol)
            if not result["fixedDwellQualification"]["qualified"]:
                raise FixedDwellError("actual input missed the requested completed-run dwell tolerance")
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
        if isinstance(error, FixedDwellError):
            preserve_held = False
            result["status"] = "ineligible-fixed-dwell"
        elif args.manual_setup and held and result["manualSetupStatus"] != "confirmed":
            preserve_held = True
            result.update(status="ineligible-manual-setup", manualSetupStatus="ineligible")
        elif result["status"] == "incomplete":
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
            result["heldPreservedForCuaActivation"] = bool(held and preserve_held
                                                         and result["manualSetupStatus"] != "ineligible")
            if args.manual_setup:
                result["heldPreservedForManualSetup"] = bool(held and preserve_held)
        result["commandWritten"] = command_written
        write(output / "result.json", result)
        announce(**result)
    return 0 if result["status"] == "qualified-captured-content-update-measurement" else 3 if preserve_held else 1


if __name__ == "__main__":
    sys.exit(main())
