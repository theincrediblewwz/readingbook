#!/usr/bin/env python3
"""Synthetic measurement-invariant tests; no UI, capture or network."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("scroll_analysis", Path(__file__).with_name("analyze-scroll-capture.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MeasurementInvariants(unittest.TestCase):
    def fixture(self):
        metadata = dict(timebaseNumer=1, timebaseDenom=1, captureStartMachTicks=0,
                        captureEndMachTicks=3_000_000_000, foregroundSamples=[
                            dict(machTicks=t, targetFrontmost=True) for t in [0, 1_000_000_000, 1_500_000_000, 2_000_000_000, 3_000_000_000]], streamError=None)
        frames = [dict(status=0, displayTimeMachTicks=1_000_000_000 + round(i / 120 * 1e9), changed=i % 2 == 0,
                       darkPixelFraction=0.15, processingMicroseconds=200) for i in range(1, 121)]
        interval = dict(startMachTicks=1_000_000_000, endMachTicks=2_000_000_000, label="continuous-input")
        return metadata, frames, interval

    def test_capture120_with_content60_is60_not120(self):
        values = MODULE.analyze(*self.fixture(), True, True)
        self.assertEqual(values["capturedPDFContentUpdateFPS"], 60)
        self.assertEqual(values["uniqueCompleteCaptureFPS"], 120)
        self.assertAlmostEqual(values["changedPDFFrameIntervalsMs"]["median"], 1000 / 60, places=5)
        self.assertEqual(values["status"], "qualified-captured-content-update-measurement")

    def test_complete_duplicates_do_not_count_as_pdf_updates(self):
        metadata, frames, interval = self.fixture()
        for frame in frames:
            frame["changed"] = False
        values = MODULE.analyze(metadata, frames, interval, True, True)
        self.assertEqual(values["capturedPDFContentUpdateFPS"], 0)
        self.assertEqual(values["duplicateOrBelowThresholdROIFrames"], 120)
        self.assertEqual(values["contentSilenceIncludingIntervalBoundariesMs"]["maximum"], 1000)

    def test_silent_gaps_are_not_trimmed_from_denominator(self):
        metadata, frames, interval = self.fixture()
        for index, frame in enumerate(frames):
            frame["changed"] = index in [11, 71]
        values = MODULE.analyze(metadata, frames, interval, True, True)
        self.assertEqual(values["capturedPDFContentUpdateFPS"], 2)
        self.assertEqual(values["durationSeconds"], 1)
        self.assertAlmostEqual(values["changedPDFFrameIntervalsMs"]["maximum"], 500)

    def test_duplicate_display_times_do_not_inflate_update_count(self):
        metadata, frames, interval = self.fixture()
        frames.extend([frames[1], frames[3]])
        values = MODULE.analyze(metadata, frames, interval, True, True)
        self.assertEqual(values["capturedPDFContentUpdateFPS"], 60)
        self.assertEqual(values["duplicateCompleteDisplayTimes"], 2)

    def test_foreground_roi_and_continuous_input_are_required(self):
        metadata, frames, interval = self.fixture()
        self.assertIn("roi-not-visually-confirmed", MODULE.analyze(metadata, frames, interval, False, True)["status"])
        self.assertIn("not-confirmed-continuous-scroll", MODULE.analyze(metadata, frames, interval, True, False)["status"])
        metadata["foregroundSamples"][2]["targetFrontmost"] = False
        self.assertIn("ineligible-background", MODULE.analyze(metadata, frames, interval, True, True)["status"])

    def test_missing_frame_clock_and_low_texture_cannot_qualify(self):
        metadata, frames, interval = self.fixture()
        frames.append(dict(status=0, displayTimeMachTicks=None))
        self.assertEqual(MODULE.analyze(metadata, frames, interval, True, True)["status"], "inconclusive-capture-errors")
        frames.pop()
        for frame in frames:
            frame["darkPixelFraction"] = 0
        self.assertEqual(MODULE.analyze(metadata, frames, interval, True, True)["status"], "inconclusive-low-pdf-texture")

    def test_interval_must_be_inside_capture(self):
        metadata, frames, interval = self.fixture()
        interval["endMachTicks"] = 4_000_000_000
        with self.assertRaises(ValueError):
            MODULE.analyze(metadata, frames, interval, True, True)


if __name__ == "__main__":
    unittest.main()
