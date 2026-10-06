import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('frame_trace', Path(__file__).resolve().parents[1] / 'Scripts/analyze-frame-trace.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FrameTraceAnalysisTests(unittest.TestCase):
    def test_multiframe_roles_use_metadata_instead_of_even_sequence(self):
        result, _ = module.analyze([
            dict(kind='input', sequence=8, time=.95, source=.95),
            dict(kind='submitted', sequence=8, time=1., original=True, multiplier=8),
            dict(kind='presented', sequence=8, time=1.01, source=.95, original=True, multiplier=8),
            dict(kind='submitted', sequence=10, time=1.02, original=False, multiplier=8),
            dict(kind='presented', sequence=10, time=1.03, source=.95, original=False, multiplier=8, phase=.25),
            dict(kind='input', sequence=16, time=.99, source=.99),
        ])
        self.assertAlmostEqual(result['timings']['originalAgeMs']['p50'], 60)
        self.assertAlmostEqual(result['timings']['midpointReferenceAgeMs']['p50'], 80)
        self.assertAlmostEqual(result['timings']['originalNextInputToDisplayMs']['p50'], 20)

    def test_predicted_ticks_and_confirmed_queue_are_observations(self):
        events = [
            dict(kind='displayState', sequence=0, time=.9, displayID=7),
            *[dict(kind='displayTick', sequence=0, time=t-.003, requested=t,
                   displayID=7, refreshPeriod=.008) for t in [1., 1.008, 1.016, 1.024, 1.032]],
            dict(kind='drawablePresentCalled', sequence=2, time=1.001, reason='immediate', requested=0),
            dict(kind='gpuComplete', sequence=2, time=1.002),
            dict(kind='presented', sequence=2, time=1.016, source=.98),
            dict(kind='drawablePresentCalled', sequence=3, time=1.005),
            dict(kind='gpuComplete', sequence=3, time=1.006),
            dict(kind='presented', sequence=3, time=1.024, source=.98),
        ]
        result, _ = module.analyze(events)
        rows = result['presentationWaitDiagnostics']['perFrame']
        self.assertNotIn('requestedAfterGpuMs', rows[0])
        self.assertEqual(rows[0]['confirmedFramesAheadAtPresentCall'], 0)
        self.assertEqual(rows[1]['confirmedFramesAheadAtPresentCall'], 1)
        self.assertAlmostEqual(rows[0]['nextPredictedTickAfterGpuMs'], 6)
        self.assertAlmostEqual(rows[0]['displayMinusNextPredictedTickMs'], 8)
        self.assertEqual(rows[0]['predictedTicksBetweenGpuAndDisplay'], 2)
        # A screen change invalidates the clock grid across that interval.
        events.append(dict(kind='displayState', sequence=0, time=1.010, displayID=8))
        changed, _ = module.analyze(events)
        self.assertNotIn('nextPredictedTickAfterGpuMs', changed['presentationWaitDiagnostics']['perFrame'][0])

    def test_actual_presentation_expiry_is_checked_separately_from_submission(self):
        result, _ = module.analyze([
            dict(kind='submitted', sequence=3, time=1.0, expires=1.010),
            dict(kind='presented', sequence=3, time=1.014, source=.98),
            dict(kind='submitted', sequence=5, time=1.020, expires=1.040),
            dict(kind='presented', sequence=5, time=1.038, source=1.0),
        ])
        checks = result['presentationExpiryChecks']['midpointReference']
        self.assertEqual(checks['count'], 2)
        self.assertEqual(checks['afterExpiryCount'], 1)
        self.assertAlmostEqual(checks['maxAfterExpiryMs'], 4)

    def test_presentation_stages_separate_execution_from_post_gpu_wait(self):
        result, _ = module.analyze([
            dict(kind='commandCommitBegin', sequence=2, time=1.0),
            dict(kind='commandCommitEnd', sequence=2, time=1.0001),
            dict(kind='gpuScheduledCallback', sequence=2, time=1.0002),
            dict(kind='drawablePresentCalled', sequence=2, time=1.0003),
            dict(kind='gpuStart', sequence=2, time=1.0004),
            dict(kind='gpuComplete', sequence=2, time=1.0006),
            dict(kind='presented', sequence=2, time=1.024, source=.98),
        ])
        t = result['timings']
        self.assertAlmostEqual(t['originalCommandCommitDurationMs']['p50'], .1)
        self.assertAlmostEqual(t['originalCommitToGpuStartMs']['p50'], .4)
        self.assertAlmostEqual(t['originalGpuExecutionMs']['p50'], .2)
        self.assertAlmostEqual(t['originalPresentCallToDisplayMs']['p50'], 23.7)
        self.assertAlmostEqual(t['originalGpuToDisplayMs']['p50'], 23.4)

    def test_joins_out_of_order_callbacks_by_frame_not_percentiles(self):
        events = [
            dict(kind='input', sequence=2, time=1, source=1),
            dict(kind='originalReady', sequence=2, time=1.002, source=1),
            dict(kind='submitted', sequence=2, time=1.014),
            dict(kind='presented', sequence=2, time=1.040, source=1),
            dict(kind='gpuComplete', sequence=2, time=1.015),
            dict(kind='input', sequence=4, time=1.025, source=1.025),
            dict(kind='unconfirmed', sequence=4, time=1.05),
        ]
        result, cadence = module.analyze(events)
        self.assertEqual(result['presentedCount'], 1)
        self.assertAlmostEqual(result['timings']['originalAgeMs']['p50'], 40)
        self.assertAlmostEqual(result['timings']['originalSubmitAgeMs']['p50'], 14)
        self.assertAlmostEqual(result['timings']['gpuToDisplayMs']['p50'], 25)
        self.assertAlmostEqual(result['timings']['originalSubmitToDisplayMs']['p50'], 26)
        self.assertAlmostEqual(result['timings']['originalConvertedToSubmitMs']['p50'], 12)
        self.assertAlmostEqual(result['timings']['originalSubmittedBeforeNextInputMs']['p50'], 11)
        self.assertAlmostEqual(result['timings']['originalNextInputToDisplayMs']['p50'], 15)
        self.assertAlmostEqual(result['timings']['originalSubmitToGpuMs']['p50'], 1)
        self.assertAlmostEqual(cadence['intervalsSeconds'][0], .025)

    def test_drop_reports_remaining_slot_and_order_errors(self):
        result, _ = module.analyze([
            dict(kind='dropped', sequence=3, time=1.030, expires=1.038, reason='dropPastExpiry'),
            dict(kind='presented', sequence=4, time=1.04, source=1.025),
            dict(kind='presented', sequence=3, time=1.05, source=1),
        ])
        self.assertEqual(result['presentationOrderErrors'], 1)
        self.assertAlmostEqual(result['dropDeadlines'][0]['remainingMs'], 8)
        self.assertEqual(result['drops']['dropPastExpiry'], 1)

    def test_replay_uses_game_submissions_even_when_capture_skips_an_input(self):
        result, cadence = module.analyze([
            dict(kind='gameInput', sequence=0, time=1),
            dict(kind='gameInput', sequence=0, time=1.025),
            dict(kind='gameInput', sequence=0, time=1.05),
            dict(kind='input', sequence=2, time=1, source=1),
            dict(kind='input', sequence=4, time=1.05, source=1.05),
        ])
        self.assertEqual(result['gameInputCount'], 3)
        self.assertEqual(len(cadence['intervalsSeconds']), 2)
        self.assertAlmostEqual(cadence['intervalsSeconds'][0], .025)

    def test_display_stall_is_visible_when_completed_frame_latency_stays_low(self):
        result, _ = module.analyze([
            dict(kind='presented', sequence=2, time=1.04, source=1),
            dict(kind='input', sequence=4, time=1.10, source=1.10),
            dict(kind='midpointReady', sequence=3, time=1.12, processing=.012),
            dict(kind='presented', sequence=6, time=2.04, source=2),
        ])
        self.assertAlmostEqual(result['timings']['originalAgeMs']['p50'], 40)
        self.assertAlmostEqual(result['maxEventGaps']['presented']['maxMs'], 1000)
        self.assertEqual(result['presentationStalls'][0]['eventsDuringGap']['input'], 1)
        self.assertEqual(result['presentationStalls'][0]['eventsDuringGap']['midpointReady'], 1)

    def test_acquisition_stall_is_counted_even_when_frame_expires(self):
        result, _ = module.analyze([
            dict(kind='drawableAcquireQueued', sequence=2, time=1),
            dict(kind='drawableAcquireEnd', sequence=2, time=2.01, ready=1.01),
            dict(kind='dropped', sequence=2, time=2.012, expires=1.04, reason='dropExpired'),
        ])
        self.assertAlmostEqual(result['timings']['drawableAcquireMs']['max'], 1000)
        self.assertAlmostEqual(result['timings']['drawableQueueMs']['max'], 10)
        self.assertEqual(result['presentedCount'], 0)

    def test_native_display_pairs_by_capture_id_with_missing_and_skipped_frames(self):
        result, _ = module.analyze([
            dict(kind='nativePresented', sequence=0, captureID=11, time=1.020, source=1),
            dict(kind='nativeGpuComplete', sequence=0, captureID=11, time=1.003),
            dict(kind='nativePresented', sequence=0, captureID=12, time=1.044, source=1.025),
            dict(kind='input', sequence=2, captureID=11, time=1, source=1),
            dict(kind='presented', sequence=2, time=1.040, source=1),
            dict(kind='input', sequence=4, captureID=13, time=1.05, source=1.05),
            dict(kind='presented', sequence=4, time=1.09, source=1.05),
            dict(kind='drawableReturnedToMain', sequence=2, time=1.013, ready=1.012),
        ])
        self.assertEqual(result['nativePresentedCount'], 2)
        self.assertEqual(result['timings']['overlayMinusNativeDisplayMs']['count'], 1)
        self.assertAlmostEqual(result['timings']['overlayMinusNativeDisplayMs']['p50'], 20)
        self.assertEqual(result['timings']['nativeRequestToOverlayDisplayMs']['count'], 1)
        self.assertAlmostEqual(result['timings']['nativeRequestToOverlayDisplayMs']['p50'], 40)
        self.assertAlmostEqual(result['timings']['nativeGpuToDisplayMs']['p50'], 17)
        self.assertAlmostEqual(result['timings']['drawableReturnToMainMs']['p50'], 1)

    def test_gpu_callback_delay_is_kept_without_confirmed_presentation(self):
        result, _ = module.analyze([
            dict(kind='gpuComplete', sequence=2, time=1.01, callbackTime=1.21),
            dict(kind='unconfirmed', sequence=2, time=1.22),
            dict(kind='nativeGpuComplete', sequence=0, captureID=11, time=1.01, callbackTime=1.11),
            dict(kind='nativeUnconfirmed', sequence=0, captureID=11, time=1.12),
        ])
        self.assertAlmostEqual(result['timings']['overlayGpuCallbackDelayMs']['max'], 200)
        self.assertAlmostEqual(result['timings']['nativeGpuCallbackDelayMs']['max'], 100)


if __name__ == '__main__':
    unittest.main()
