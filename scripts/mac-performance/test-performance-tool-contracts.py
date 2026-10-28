#!/usr/bin/env python3
"""Metadata/condition contracts only; no app, GUI, compiler or benchmark runs."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parents[1]


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, TOOLS / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


RUN = module("performance_run", "run.py")
COMPARE = module("scroll_compare", "compare-scroll-matrices.py")
HOOKS = module("performance_hooks", "verify-performance-hooks.py")
CAPTURE = module("scroll_capture_run", "capture-scroll-run.py")
MATRIX = module("scroll_matrix", "summarize-scroll-matrix.py")


class ScrollSetupContracts(unittest.TestCase):
    def test_pre_scroll_dwell_uses_actual_mach_timebase_and_both_boundaries(self):
        with tempfile.TemporaryDirectory(prefix="scroll-dwell-contract-", dir=ROOT / ".build") as temporary:
            path = Path(temporary) / "events.jsonl"
            rows = [dict(event="main.entry", ticks=100, timebaseNumer=125, timebaseDenom=3),
                    dict(event="run.completed", ticks=24_000_100)]
            path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
            result = CAPTURE.pre_scroll_dwell(path, 48_000_100)
            self.assertAlmostEqual(result["mainEntryToInputSeconds"], 2)
            self.assertAlmostEqual(result["runCompletedToInputSeconds"], 1)
            self.assertTrue(result["measuredAfterInput"])

    def test_pre_scroll_dwell_rejects_invalid_order_and_timebase(self):
        with tempfile.TemporaryDirectory(prefix="scroll-dwell-contract-", dir=ROOT / ".build") as temporary:
            path = Path(temporary) / "events.jsonl"
            for main, completed, start, denominator in [(100, 200, 199, 3), (100, 99, 200, 3), (100, 200, 300, 0)]:
                rows = [dict(event="main.entry", ticks=main, timebaseNumer=125, timebaseDenom=denominator),
                        dict(event="run.completed", ticks=completed)]
                path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
                with self.subTest(rows=rows), self.assertRaises(ValueError):
                    CAPTURE.pre_scroll_dwell(path, start)

    def test_new_options_default_to_existing_immediate_capture_behavior(self):
        args = CAPTURE.argument_parser().parse_args(["--tag", "synthetic-contract"])
        self.assertFalse(args.manual_setup)
        self.assertEqual(args.diagnostic_env, [])

    def test_diagnostic_environment_is_allowlisted_unique_and_binary(self):
        self.assertEqual(CAPTURE.DIAGNOSTIC_ENV_KEYS, RUN.DIAGNOSTIC_ENV_KEYS)
        good = ["READINGBOOK_DIAG_PAUSE_DOT=1", "READINGBOOK_DIAG_SKIP_HIDDEN_WIDTH=0"]
        expected = {"READINGBOOK_DIAG_PAUSE_DOT": "1", "READINGBOOK_DIAG_SKIP_HIDDEN_WIDTH": "0"}
        self.assertEqual(CAPTURE.diagnostic_environment(good), expected)
        self.assertEqual(RUN.diagnostic_environment(good), expected)
        self.assertEqual(CAPTURE.diagnostic_environment([]), {})
        for bad in (["UNTRUSTED_ENV=1"], ["READINGBOOK_DIAG_PAUSE_DOT=true"],
                    ["READINGBOOK_DIAG_PAUSE_DOT"], [good[0], good[0]]):
            with self.subTest(bad=bad):
                for tool in (CAPTURE, RUN):
                    with self.assertRaises(ValueError):
                        tool.diagnostic_environment(bad)

    def test_confirmation_requires_matching_nonce_and_actual_json_booleans(self):
        good = dict(nonce="synthetic-fresh", roiConfirmed=True, noOverlayConfirmed=True, manualInteractionFinished=True)
        self.assertEqual(CAPTURE.validate_manual_setup_confirmation(good, good["nonce"]), good)
        for key in ("nonce", "roiConfirmed", "noOverlayConfirmed", "manualInteractionFinished"):
            missing = dict(good); del missing[key]
            with self.subTest(missing=key), self.assertRaises(CAPTURE.ManualSetupError):
                CAPTURE.validate_manual_setup_confirmation(missing, good["nonce"])
        for key in ("roiConfirmed", "noOverlayConfirmed", "manualInteractionFinished"):
            for value in (False, 1, "true", None):
                invalid = dict(good); invalid[key] = value
                with self.subTest(key=key, value=value), self.assertRaises(CAPTURE.ManualSetupError):
                    CAPTURE.validate_manual_setup_confirmation(invalid, good["nonce"])
        with self.assertRaises(CAPTURE.ManualSetupError):
            CAPTURE.validate_manual_setup_confirmation(good, "different-run")

    def test_ready_is_rechecked_for_failure_consumption_and_110_second_age(self):
        with tempfile.TemporaryDirectory(prefix="scroll-setup-contract-", dir=ROOT / ".build") as temporary:
            control = Path(temporary)
            ready = control / "driver-ready.json"
            CAPTURE.write(ready, dict(pid=123, nonce="synthetic", workspacePDFVerified=True))
            self.assertEqual(CAPTURE.validate_fresh_control(control, dict(pid=123), "synthetic")["pid"], 123)
            for name in ("start.json", "driver-failure.json"):
                path = control / name; CAPTURE.write(path, {})
                with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, "stale or failed"):
                    CAPTURE.validate_fresh_control(control, dict(pid=123), "synthetic")
                path.unlink()
            os.utime(ready, (100, 100))
            with mock.patch.object(CAPTURE.time, "time", return_value=211), self.assertRaisesRegex(RuntimeError, "too old"):
                CAPTURE.validate_fresh_control(control, dict(pid=123), "synthetic")

    def test_confirmation_wait_never_consumes_control_and_is_bounded(self):
        with tempfile.TemporaryDirectory(prefix="scroll-setup-contract-", dir=ROOT / ".build") as temporary:
            control = Path(temporary); path = control / "setup-confirmed.json"
            with self.assertRaisesRegex(CAPTURE.ManualSetupError, "not confirmed within 90"):
                CAPTURE.wait_manual_setup(path, "synthetic", control, timeout=0)
            self.assertFalse((control / "start.json").exists())
            with self.assertRaises(ValueError):
                CAPTURE.wait_manual_setup(path, "synthetic", control, timeout=91)
            with mock.patch.object(CAPTURE.time, "monotonic", side_effect=[0, 0, 89.99, 90]), \
                    mock.patch.object(CAPTURE.time, "sleep") as sleep, \
                    self.assertRaises(CAPTURE.ManualSetupError):
                CAPTURE.wait_manual_setup(path, "synthetic", control)
            self.assertLessEqual(sleep.call_args.args[0], 0.011)
            confirmation = dict(nonce="synthetic", roiConfirmed=True, noOverlayConfirmed=True, manualInteractionFinished=True)
            CAPTURE.write(path, confirmation)
            self.assertEqual(CAPTURE.wait_manual_setup(path, "synthetic", control), confirmation)
            CAPTURE.write(control / "driver-failure.json", {})
            with self.assertRaisesRegex(CAPTURE.ManualSetupError, "failed or was consumed"):
                CAPTURE.wait_manual_setup(path, "synthetic", control)
            self.assertFalse((control / "start.json").exists())

    def test_identity_recheck_rejects_reused_pid_without_signalling_any_process(self):
        held = dict(pid=123, executable="/synthetic/owned/ReadingBook")
        with mock.patch.object(CAPTURE.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=held["executable"] + "\n")) as command:
            CAPTURE.validate_held_identity(held)
            self.assertEqual(command.call_args.args[0], ["/bin/ps", "-p", "123", "-o", "comm="])
        with mock.patch.object(CAPTURE.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="/different/process\n")):
            with self.assertRaises(CAPTURE.ManualSetupError):
                CAPTURE.validate_held_identity(held)

    def test_formal_fps_exclusion_follows_binary_and_enabled_switches(self):
        ordinary = CAPTURE.fps_diagnostic_metadata({}, {})
        self.assertFalse(ordinary["diagnosticOnly"])
        self.assertFalse(ordinary["formalFPSBaselineExcluded"])
        self.assertEqual(ordinary["formalFPSBaselineExclusionReasons"], [])
        self.assertFalse(CAPTURE.fps_diagnostic_metadata({}, {"READINGBOOK_DIAG_PAUSE_DOT": "0"})["formalFPSBaselineExcluded"])
        instrumented = CAPTURE.fps_diagnostic_metadata(dict(diagnosticOnly=True, formalFPSBaselineExcluded=True), {})
        self.assertTrue(instrumented["diagnosticOnly"])
        self.assertEqual(instrumented["formalFPSBaselineExclusionReasons"], ["diagnostic-build-manifest"])
        switched = CAPTURE.fps_diagnostic_metadata({}, {"READINGBOOK_DIAG_PAUSE_DOT": "1"})
        self.assertTrue(switched["formalFPSBaselineExcluded"])
        self.assertEqual(switched["formalFPSBaselineExclusionReasons"], ["experimental-component-switch"])

    def test_timeout_keeps_held_and_control_without_launching_collector(self):
        # Tiny synthetic files and a mocked launcher; no app/PID/UI exists.
        with tempfile.TemporaryDirectory(prefix="scroll-setup-contract-", dir=ROOT / ".build") as temporary:
            root = Path(temporary); app = root / "Owned.app"; binary = app / "Contents/MacOS/ReadingBook"
            binary.parent.mkdir(parents=True); binary.write_bytes(b"synthetic-product")
            fixture = root / "fixture"; fixture.mkdir(); (fixture / "untouched.txt").write_text("synthetic-book")
            driver = root / "driver"; driver.write_bytes(b"synthetic-driver")
            collector = root / "collector"; collector.write_bytes(b"synthetic-collector")
            tag = "synthetic-manual-timeout"; base = root / "build"; run = base / "runs" / tag / "run-1"
            control = run / "scroll-control"; control.mkdir(parents=True)
            CAPTURE.write(run / "held-process.json", dict(pid=123, executable=str(binary)))
            CAPTURE.write(run / "launch.json", dict(scrollDiagnostic=dict(nonce="synthetic-fresh")))
            CAPTURE.write(control / "driver-ready.json", dict(pid=123, nonce="synthetic-fresh", workspacePDFVerified=True, windowID=42))
            CAPTURE.write(root / "manifest.json", dict(app=str(app), buildRoot=str(base), binarySHA256=CAPTURE.sha(binary)))
            argv = ["capture-scroll-run.py", "--manifest", str(root / "manifest.json"), "--fixture", str(fixture),
                    "--driver", str(driver), "--collector", str(collector), "--tag", tag, "--roi-confirmed", "--manual-setup",
                    "--diagnostic-env", "READINGBOOK_DIAG_PAUSE_DOT=1"]
            with mock.patch.object(CAPTURE, "ROOT", root), mock.patch.object(CAPTURE.sys, "argv", argv), \
                    mock.patch.object(CAPTURE.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as launched, \
                    mock.patch.object(CAPTURE.subprocess, "Popen") as process, mock.patch.object(CAPTURE, "announce"), \
                    mock.patch.object(CAPTURE, "wait_manual_setup", side_effect=CAPTURE.ManualSetupError("synthetic timeout")):
                self.assertEqual(CAPTURE.main(), 3)
            process.assert_not_called()
            self.assertEqual(launched.call_count, 1)
            self.assertEqual(launched.call_args.args[0][-2:], ["--diagnostic-env", "READINGBOOK_DIAG_PAUSE_DOT=1"])
            output = root / "logs/mac-refinement-20261028/scroll-fps" / tag
            result = CAPTURE.read(output / "result.json")
            self.assertEqual(result["status"], "ineligible-manual-setup")
            self.assertTrue(result["heldPreservedForManualSetup"])
            self.assertFalse(result["ownedHeldStopped"])
            self.assertFalse(result["commandWritten"])
            self.assertTrue(result["fixtureUnchanged"])
            self.assertEqual(result["diagnosticEnvironment"], {"READINGBOOK_DIAG_PAUSE_DOT": "1"})
            self.assertEqual(CAPTURE.read(output / "setup.json")["diagnosticEnvironment"], result["diagnosticEnvironment"])
            request = CAPTURE.read(output / "setup-required.json")
            self.assertEqual(request["nonce"], "synthetic-fresh")
            self.assertEqual(request["setupConfirmationPath"], str(control / "setup-confirmed.json"))
            self.assertTrue((run / "held-process.json").exists())
            self.assertFalse((control / "start.json").exists())

    def test_failed_preflight_without_held_keeps_launcher_error_and_never_waits(self):
        with tempfile.TemporaryDirectory(prefix="scroll-setup-contract-", dir=ROOT / ".build") as temporary:
            root = Path(temporary); app = root / "Owned.app"; binary = app / "Contents/MacOS/ReadingBook"
            binary.parent.mkdir(parents=True); binary.write_bytes(b"synthetic-product")
            fixture = root / "fixture"; fixture.mkdir()
            driver = root / "driver"; driver.write_bytes(b"synthetic-driver")
            collector = root / "collector"; collector.write_bytes(b"synthetic-collector")
            CAPTURE.write(root / "manifest.json", dict(app=str(app), buildRoot=str(root / "build"), binarySHA256=CAPTURE.sha(binary)))
            argv = ["capture-scroll-run.py", "--manifest", str(root / "manifest.json"), "--fixture", str(fixture),
                    "--driver", str(driver), "--collector", str(collector), "--tag", "synthetic-preflight-failure", "--roi-confirmed", "--manual-setup"]
            with mock.patch.object(CAPTURE, "ROOT", root), mock.patch.object(CAPTURE.sys, "argv", argv), \
                    mock.patch.object(CAPTURE.subprocess, "run", return_value=SimpleNamespace(returncode=1)) as launched, \
                    mock.patch.object(CAPTURE.subprocess, "Popen") as process, mock.patch.object(CAPTURE, "announce"), \
                    mock.patch.object(CAPTURE, "wait_json") as wait:
                self.assertEqual(CAPTURE.main(), 1)
            self.assertEqual(launched.call_count, 1)
            process.assert_not_called(); wait.assert_not_called()
            result = CAPTURE.read(root / "logs/mac-refinement-20261028/scroll-fps/synthetic-preflight-failure/result.json")
            self.assertEqual(result["reason"], "held performance setup failed; see run-driver.log")
            self.assertFalse(result["ownedHeldStopped"])
            self.assertFalse(result["heldPreservedForManualSetup"])
            self.assertNotIn("heldPID", result)


class FormalFPSMatrixContracts(unittest.TestCase):
    def test_manual_pilots_cannot_silently_replace_early_scroll_matrices(self):
        with self.assertRaisesRegex(ValueError, "variable pre-scroll dwell"):
            MATRIX.validate_formal_eligibility(dict(manualSetupRequired=True), {})
    def test_historical_and_explicit_ordinary_runs_remain_eligible(self):
        MATRIX.validate_formal_eligibility({}, {})
        MATRIX.validate_formal_eligibility(dict(diagnosticOnly=False, formalFPSBaselineExcluded=False),
                                         dict(diagnosticOnly=False, formalFPSBaselineExcluded=False),
                                         dict(formalFPSBaselineExcluded=False, diagnosticComparisonExcluded=False))

    def test_either_result_or_manifest_diagnostic_flag_blocks_formal_matrix(self):
        for key in ("diagnosticOnly", "formalFPSBaselineExcluded"):
            with self.subTest(result=key), self.assertRaisesRegex(ValueError, "cannot enter a formal FPS matrix"):
                MATRIX.validate_formal_eligibility({key: True}, {})
            with self.subTest(manifest=key), self.assertRaises(ValueError):
                MATRIX.validate_formal_eligibility({}, {key: True})

    def test_operator_overlay_exclusion_cannot_be_promoted_by_automatic_gates(self):
        otherwise_passed = dict(status="qualified-captured-content-update-measurement", formalFPSBaselineExcluded=False)
        for key in ("formalFPSBaselineExcluded", "diagnosticComparisonExcluded"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                MATRIX.validate_formal_eligibility(otherwise_passed, {}, {key: True})


class DiagnosticMetadataContracts(unittest.TestCase):
    def test_manual_controls_and_manifest_only_diagnostics_stay_excluded(self):
        self.assertTrue(CAPTURE.fps_diagnostic_metadata({}, {}, True)["formalFPSBaselineExcluded"])
        self.assertTrue(CAPTURE.fps_diagnostic_metadata(dict(diagnosticOnly=True), {})["formalFPSBaselineExcluded"])
    def test_plain_unprofiled_run_is_not_excluded(self):
        result = RUN.diagnostic_metadata()
        self.assertFalse(result["latencyBaselineExcluded"])
        self.assertEqual(result["latencyBaselineExclusionReasons"], [])
        self.assertIsNone(result["scrollDiagnostic"])

    def test_scroll_run_keeps_identity_and_excludes_latency_only(self):
        metadata = dict(library="workspace-driver", sha256="hash", nonce="fresh", latencyBaselineExcluded=True)
        result = RUN.diagnostic_metadata(False, metadata)
        self.assertEqual(result["scrollDiagnostic"], metadata)
        self.assertFalse(result["profiled"])
        self.assertTrue(result["latencyBaselineExcluded"])
        self.assertEqual(result["latencyBaselineExclusionReasons"], ["in-process-scroll-driver"])

    def test_sampler_and_combined_diagnostics_are_labelled(self):
        result = RUN.diagnostic_metadata(True)
        self.assertTrue(result["profiled"])
        self.assertTrue(result["latencyBaselineExcluded"])
        self.assertEqual(result["latencyBaselineExclusionReasons"], ["startup-sample"])
        both = RUN.diagnostic_metadata(True, {})
        self.assertTrue(both["latencyBaselineExcluded"])
        self.assertEqual(both["latencyBaselineExclusionReasons"], ["startup-sample", "in-process-scroll-driver"])

    def test_explicit_empty_scroll_metadata_cannot_become_plain_baseline(self):
        self.assertTrue(RUN.diagnostic_metadata(False, {})["latencyBaselineExcluded"])


class ScrollComparisonContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Synthetic contract values, never a measured/performance artifact. The
        # public tool tests must not depend on the owner's ignored book/traces.
        cls.baseline = dict(status="qualified-captured-content-scroll-matrix", qualifiedSamples=6,
            sourceCommit="1" * 40, targetBinarySHA256="2" * 64, driverSHA256="3" * 64,
            collectorSHA256="4" * 64, fixtureManifestSHA256="5" * 64,
            input=dict(requestedHz=60), capture=dict(requestedCeilingFPS=120), groups={})
        for name, dims, roi in [("wide", [1470, 843], [500, 160, 750, 450]), ("narrow", [800, 632], [120, 130, 580, 350])]:
            cls.baseline["groups"][name] = dict(qualifiedRunCount=3, allForegroundGeometryHashAndLogGatesPassed=True,
                actualWindowPixelsAtScale1=dims, roiPixels=roi, medianCapturedPDFContentUpdateFPS=55.0,
                minimumRunCapturedPDFContentUpdateFPS=54.0, pooledChangedFrameIntervalsMs=dict(median=16.7, p95=33.0, p99=50.0, maximum=66.0),
                medianCollectorCPUPercentOneCoreWholeCapture=3.0, medianActualInputDeliveryHz=59.9,
                runs=[dict(capturedPDFContentUpdateFPS=value) for value in [54.0, 55.0, 56.0]])

    def test_same_data_control_has_zero_difference_without_claiming_new_binary(self):
        result = COMPARE.compare(self.baseline, copy.deepcopy(self.baseline))
        self.assertEqual(result["status"], "comparable-descriptive-scroll-matrices")
        self.assertFalse(result["differentProductBinaries"])
        self.assertEqual(result["groups"]["wide"]["medianCapturedPDFContentUpdateFPS"]["afterMinusBefore"], 0)

    def test_historical_baseline_schema_is_accepted_without_rewriting_it(self):
        old = copy.deepcopy(self.baseline)
        old["status"] = "qualified-captured-content-baseline-matrix"
        result = COMPARE.compare(old, self.baseline)
        self.assertEqual(result["status"], "comparable-descriptive-scroll-matrices")

    def test_arithmetic_uses_after_minus_before_without_automatic_win_claim(self):
        after = copy.deepcopy(self.baseline)
        after["targetBinarySHA256"] = "0" * 64
        before_fps = self.baseline["groups"]["wide"]["medianCapturedPDFContentUpdateFPS"]
        after["groups"]["wide"]["medianCapturedPDFContentUpdateFPS"] = before_fps * 1.1
        result = COMPARE.compare(self.baseline, after)
        self.assertTrue(result["differentProductBinaries"])
        self.assertAlmostEqual(result["groups"]["wide"]["medianCapturedPDFContentUpdateFPS"]["percentChange"], 10)

    def test_changed_observer_roi_or_fixture_blocks_comparison(self):
        for key in ["driverSHA256", "collectorSHA256", "fixtureManifestSHA256"]:
            after = copy.deepcopy(self.baseline); after[key] = "different"
            result = COMPARE.compare(self.baseline, after)
            self.assertEqual(result["status"], "not-comparable-condition-mismatch")
            self.assertIn(key, result["mismatches"])
            self.assertEqual(result["groups"], {})
        after = copy.deepcopy(self.baseline); after["groups"]["narrow"]["roiPixels"][0] += 1
        self.assertIn("narrow.roiPixels", COMPARE.compare(self.baseline, after)["mismatches"])

    def test_incomplete_or_unqualified_case_set_blocks_comparison(self):
        after = copy.deepcopy(self.baseline); after["qualifiedSamples"] = 5
        self.assertIn("after.qualified-six-sample-status", COMPARE.compare(self.baseline, after)["mismatches"])
        after = copy.deepcopy(self.baseline); after["groups"]["wide"]["allForegroundGeometryHashAndLogGatesPassed"] = False
        self.assertIn("after.wide.qualification", COMPARE.compare(self.baseline, after)["mismatches"])


class InstrumentationContracts(unittest.TestCase):
    def test_current_working_source_has_unique_init_and_projection_hook_preimages(self):
        result, patch = HOOKS.replay(ROOT, TOOLS / "prepare.py")
        self.assertEqual(result["hookCount"], 21)
        self.assertTrue(all(check["preimageCount"] == 1 for check in result["checks"]))
        self.assertTrue(result["freshProjectionHookPresent"])
        self.assertTrue(result["cachedProjectionHookPresent"])
        self.assertFalse(result["productSourceWrites"])
        self.assertFalse(result["compiled"])
        self.assertIn('PerfTrace.event("appstore.init.begin")', patch)


if __name__ == "__main__":
    unittest.main()
