#!/usr/bin/env python3
"""Metadata/condition contracts only; no app, GUI, compiler or benchmark runs."""
import copy
import importlib.util
from pathlib import Path
import unittest

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


class DiagnosticMetadataContracts(unittest.TestCase):
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
