#!/usr/bin/env python3
"""Validate GPU ordering, current-frame pixels and native pairing in a hook trace."""
import argparse
import collections
import importlib.util
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('log', type=Path)
parser.add_argument('--expect-route', choices=['directAfterGPU', 'directAfterPresented', 'commandBufferBeforePresent'])
parser.add_argument('--validate-copy', action='store_true')
parser.add_argument('--check-midpoint-gate', action='store_true')
parser.add_argument('--check-presentation-stages', action='store_true')
parser.add_argument('--offscreen-producer', action='store_true')
parser.add_argument('--minimum-advanced-originals', type=int, default=0)
args = parser.parse_args()
lines = args.log.read_text(errors='replace').splitlines()
events = [json.loads(line.split(' FRAME ', 1)[1]) for line in lines if ' FRAME {' in line]
assert events, 'No recorded events'
trace_id = max(e['traceID'] for e in events)
events = [e for e in events if e['traceID'] == trace_id]
spec = importlib.util.spec_from_file_location('trace_analysis', Path(__file__).with_name('analyze-frame-trace.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
result, _ = module.analyze(events)
captures = collections.defaultdict(dict)
for event in events:
    if event.get('captureID'):
        captures[event['captureID']][event['kind']] = event
checked = 0
for capture in captures.values():
    entry = capture.get('gameInput', {})
    gpu = capture.get('nativeGpuComplete')
    copy = capture.get('captureComplete')
    if entry.get('reason') == 'directAfterGPU' and gpu and copy:
        assert entry['time'] + .000001 >= gpu['time'], 'Capture entered before game GPU completed'
        assert copy['gpu'] + .000001 >= gpu['time'], 'GPU copy completed before its writer'
        checked += 1
if args.expect_route:
    assert result['captureRoutes'].get(args.expect_route, 0) > 100, 'Expected route did not run'
    if args.expect_route == 'directAfterGPU':
        assert checked > 100, 'Insufficient GPU-ordered samples'
    else:
        assert not result['captureRoutes'].get('directAfterGPU'), 'Unsafe/unsupported route used early capture'
validation = collections.Counter(e.get('reason') for e in events if e['kind'] == 'captureValidation')
assert not validation['fail'], 'Copied pixels do not match the current frame'
if args.validate_copy:
    assert validation['pass'] > 100, 'No meaningful pixel readback coverage'
assert result['presentationOrderErrors'] == 0, 'Presentation sequence reversed'
submissions = collections.Counter(e['sequence'] for e in events if e['kind'] == 'submitted')
assert all(count == 1 for count in submissions.values()), 'A frame was submitted more than once'
assert all(e['time'] < e['expires'] for e in events if e['kind'] == 'submitted'), 'Submission exceeded absolute expiry'
assert not any('FRAME_TRACE lost=' in line for line in lines), 'Trace overflow invalidates this check'
if args.offscreen_producer:
    assert result['nativePresentedCount'] == 0, 'Offscreen comparison unexpectedly presented native frames'
else:
    assert result['timings'].get('overlayMinusNativeDisplayMs', {}).get('count', 0) > 100, 'Native pairing incomplete'
print(json.dumps({'traceID': trace_id, 'routes': result['captureRoutes'],
                  'gpuOrderedCopies': checked, 'pixelChecks': dict(validation),
                  'presentationOrderErrors': result['presentationOrderErrors']}, indent=2))

if args.check_midpoint_gate:
    frames = collections.defaultdict(dict)
    held = []
    advanced = 0
    for event in events:
        if event['sequence']:
            frames[event['sequence']][event['kind']] = event
        if event['kind'] == 'originalSubmissionHeld':
            held.append(event)
        if event['kind'] == 'submitted' and event.get('original', event['sequence'] % 2 == 0):
            credit = event.get('submissionAdvance', 0)
            assert 0 <= credit <= .004001, 'Original advance exceeded its bound'
            advanced += credit > 0
    checked_gates = 0
    for hold in held:
        limit = hold.get('expires', hold['deadline'])
        assert limit <= hold['deadline'] + .001001, 'Pair ownership exceeded 1 ms'
        assert hold['time'] < limit, 'Wait recorded after ownership expired'
        submitted = frames[hold['sequence']].get('submitted')
        if not submitted or submitted['time'] >= limit - .000001:
            continue  # The original used the bounded fallback slot or was dropped.
        midpoint = frames.get(hold['sequence'] - 1, {})
        resolved = midpoint.get('submitted') or midpoint.get('dropped')
        assert resolved and resolved['time'] <= submitted['time'], 'Original overtook its unfinished midpoint'
        checked_gates += 1
    assert advanced >= args.minimum_advanced_originals, 'Insufficient original advance coverage'
    print(json.dumps({'advancedOriginals': advanced, 'heldAttempts': len(held),
                      'resolvedBeforeEarlyOriginal': checked_gates}, indent=2))

if args.check_presentation_stages:
    frames = collections.defaultdict(dict)
    for event in events:
        if event['sequence']:
            frames[event['sequence']][event['kind']] = event
    checked = 0
    for frame in frames.values():
        names = ['commandCommitBegin', 'commandCommitEnd', 'gpuStart', 'gpuComplete', 'drawablePresentCalled', 'presented']
        if not all(name in frame for name in names):
            continue
        begin, end, start, gpu, call, shown = (frame[name]['time'] for name in names)
        assert begin <= end, 'Commit timing reversed'
        assert start + .000001 >= begin, 'GPU started before this commit'
        assert gpu >= start, 'GPU end precedes its start'
        assert shown + .000001 >= gpu, 'Presentation precedes GPU completion'
        assert begin <= call <= shown + .000001, 'Present invocation falls outside commit/presentation window'
        checked += 1
    assert checked > 100, 'Insufficient presentation-stage coverage'
    print(json.dumps({'completePresentationStages': checked}, indent=2))
