import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    'frame_pacing_stress', Path(__file__).resolve().parents[1] / 'Scripts/stress-frame-pacing.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FramePacingStressTests(unittest.TestCase):
    def test_generation_and_delivery_are_separate_and_recording_edges_are_excluded(self):
        result = dict(timings={}, displayFPS=100, drops={}, presentationOrderErrors=0)
        events = [dict(kind='input', sequence=q, time=q * .01) for q in range(2, 22, 2)]
        events += [dict(kind='gameInput', sequence=0, time=q * .01) for q in range(2, 22, 2)]
        events += [dict(kind='midpointReady', sequence=q, time=q * .01) for q in [7, 9, 11, 15]]
        events += [dict(kind='presented', sequence=q, time=q * .01) for q in [2, 6, 7, 8, 10, 11, 12, 14, 15, 16, 20]]
        summary = module.summarize(events, result)
        self.assertAlmostEqual(summary['outputMultiplier'], 2)
        self.assertEqual(summary['originalDeliveryPercent'], 100)
        self.assertEqual(summary['midpointGenerationPercent'], 80)
        self.assertEqual(summary['midpointDeliveryPercent'], 60)

    def test_thresholds_tolerate_sub_microsecond_refresh_timestamp_noise(self):
        result = dict(timings={}, displayFPS=60, drops={}, presentationOrderErrors=0)
        # Each group starts with an exact tick and a slightly perturbed boundary.
        long_events = [dict(kind='presented', sequence=i + 1, time=t) for i, t in enumerate([0, .025000083, .050020083])]
        short_events = [dict(kind='presented', sequence=i + 1, time=t) for i, t in enumerate([0, .002999958, .005979958])]
        long = module.summarize(long_events, result)
        short = module.summarize(short_events, result)
        self.assertEqual(long['longAbove25Ms'], 1)
        self.assertEqual(short['tightBelow3Ms'], 1)
        self.assertEqual(long['gapThresholdToleranceMs'], .001)
