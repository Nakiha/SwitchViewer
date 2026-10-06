#!/usr/bin/env python3
"""Join per-frame timing events; export a cadence profile for Metal replay.

Usage: python3 Scripts/analyze-frame-trace.py game.log --out Artifacts/wuwa-trace
This measures recorded frames only, never models WindowServer latency.
"""
import argparse
import bisect
import collections
import json
import math
from pathlib import Path


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)] if ordered else None


def analyze(events):
    frames = collections.defaultdict(dict)
    captures = collections.defaultdict(dict)
    drops = collections.Counter()
    samples = collections.defaultdict(list)
    deadlines = []
    gaps = {}
    for kind in sorted({event['kind'] for event in events}):
        ordered = sorted((event for event in events if event['kind'] == kind), key=lambda e: e['time'])
        if len(ordered) > 1:
            before, after = max(zip(ordered, ordered[1:]), key=lambda pair: pair[1]['time'] - pair[0]['time'])
            gaps[kind] = {'maxMs': (after['time'] - before['time']) * 1000,
                          'start': before['time'], 'end': after['time'],
                          'beforeSequence': before['sequence'], 'afterSequence': after['sequence']}
    for event in events:
        if event.get('captureID'):
            captures[event['captureID']][event['kind']] = event
        sequence = event['sequence']
        if sequence:
            frames[sequence][event['kind']] = event
        if event['kind'] == 'dropped':
            drops[event.get('reason', 'unknown')] += 1
            if 'expires' in event:
                deadlines.append({'sequence': sequence, 'reason': event.get('reason'),
                                  'remainingMs': (event['expires'] - event['time']) * 1000})
    # Reconstruct only frames with confirmed presentation; this is a lower bound,
    # not the main-thread callback counter and not WindowServer queue depth.
    confirmed = [(stages['drawablePresentCalled']['time'], stages['presented']['time'])
                 for stages in frames.values()
                 if 'drawablePresentCalled' in stages and 'presented' in stages
                 and stages['presented']['time'] >= stages['drawablePresentCalled']['time']]
    call_times = sorted(start for start, _ in confirmed)
    shown_times = sorted(end for _, end in confirmed)
    states = sorted((e for e in events if e['kind'] == 'displayState'), key=lambda e: e['time'])
    state_times = [e['time'] for e in states]
    ticks = collections.defaultdict(list)
    for e in events:
        if e['kind'] == 'displayTick' and 'requested' in e and 'displayID' in e:
            ticks[e['displayID']].append(e['requested'])
            if e.get('refreshPeriod', 0) > 0:
                samples['observedNominalRefreshPeriodMs'].append(e['refreshPeriod'] * 1000)
    ticks = {display: sorted(set(values)) for display, values in ticks.items()}
    presentation_waits = []
    queue_waits = collections.defaultdict(list)
    expiry_checks = collections.defaultdict(list)
    shown = []
    for sequence, stages in frames.items():
        presented = stages.get('presented')
        if not presented:
            continue
        shown.append(presented)
        submitted = stages.get('submitted')
        gpu = stages.get('gpuComplete')
        is_original = presented.get('original', sequence % 2 == 0)
        multiplier = presented.get('multiplier', 2)
        role = 'original' if is_original else 'midpointReference'
        if is_original:
            capture = stages.get('input', {}).get('captureID')
            native = captures.get(capture, {}).get('nativePresented')
            if native:
                samples['overlayMinusNativeDisplayMs'].append((presented['time'] - native['time']) * 1000)
                samples['nativeRequestToOverlayDisplayMs'].append((presented['time'] - native['source']) * 1000)
        samples[role + 'AgeMs'].append((presented['time'] - presented['source']) * 1000)
        if submitted:
            if 'expires' in submitted:
                expiry_checks[role].append((presented['time'] - submitted['expires']) * 1000)
            samples[role + 'SubmitAgeMs'].append((submitted['time'] - presented['source']) * 1000)
            samples[role + 'SubmitToDisplayMs'].append((presented['time'] - submitted['time']) * 1000)
            converted = stages.get('originalReady')
            if is_original and converted:
                samples['originalConvertedToSubmitMs'].append((submitted['time'] - converted['time']) * 1000)
            following = frames.get(sequence + multiplier, {}).get('input')
            if is_original and following:
                samples['originalNextInputToDisplayMs'].append((presented['time'] - following['time']) * 1000)
                samples['originalSubmittedBeforeNextInputMs'].append((following['time'] - submitted['time']) * 1000)
        commit = stages.get('commandCommitBegin')
        committed = stages.get('commandCommitEnd')
        gpu_start = stages.get('gpuStart')
        present_call = stages.get('drawablePresentCalled')
        scheduled_callback = stages.get('gpuScheduledCallback')
        def stage_sample(name, start, end):
            if start and end:
                value = (end['time'] - start['time']) * 1000
                samples[name].append(value)
                samples[role + name[0].upper() + name[1:]].append(value)
        stage_sample('commandCommitDurationMs', commit, committed)
        stage_sample('commitToGpuStartMs', commit, gpu_start)
        stage_sample('gpuExecutionMs', gpu_start, gpu)
        stage_sample('presentCallToDisplayMs', present_call, presented)
        stage_sample('presentCallToGpuEndMs', present_call, gpu)
        stage_sample('scheduledCallbackToPresentCallMs', scheduled_callback, present_call)
        gpu_time = gpu['time'] if gpu else presented.get('gpu')
        if present_call and gpu_time is not None:
            call = present_call['time']
            ahead = max(0, bisect.bisect_left(call_times, call) - bisect.bisect_right(shown_times, call))
            wait_ms = (presented['time'] - gpu_time) * 1000
            queue_waits[ahead].append(wait_ms)
            row = {'sequence': sequence, 'role': role,
                   'confirmedFramesAheadAtPresentCall': ahead,
                   'gpuToDisplayMs': wait_ms,
                   'presentCallToDisplayMs': (presented['time'] - call) * 1000,
                   'presentMode': present_call.get('reason', 'unknown')}
            if present_call.get('reason') == 'atTime' and present_call.get('requested', 0) > 0:
                row['requestedAfterGpuMs'] = (present_call['requested'] - gpu_time) * 1000
            if submitted and 'drawableID' in submitted:
                row['drawableID'] = submitted['drawableID']
            state_index = bisect.bisect_right(state_times, gpu_time) - 1
            state = states[state_index] if state_index >= 0 else {}
            grid = ticks.get(state.get('displayID'), [])
            i = bisect.bisect_left(grid, gpu_time)
            # Require an observed grid bracketing the whole interval. Missing data
            # or screen transitions must not become a fictitious refresh count.
            end_index = bisect.bisect_right(state_times, presented['time']) - 1
            end_state = states[end_index] if end_index >= 0 else {}
            if (grid and grid[0] <= gpu_time and grid[-1] >= presented['time']
                    and i < len(grid) and state.get('displayID') == end_state.get('displayID')):
                row['displayID'] = state['displayID']
                row['nextPredictedTickAfterGpuMs'] = (grid[i] - gpu_time) * 1000
                row['displayMinusNextPredictedTickMs'] = (presented['time'] - grid[i]) * 1000
                row['predictedTicksBetweenGpuAndDisplay'] = bisect.bisect_right(grid, presented['time']) - i
            presentation_waits.append(row)
        if 'callbackTime' in presented:
            samples['overlayPresentCallbackDelayMs'].append((presented['callbackTime'] - presented['time']) * 1000)
        if gpu_time is not None:
            samples['gpuToDisplayMs'].append((presented['time'] - gpu_time) * 1000)
            samples[role + 'GpuToDisplayMs'].append((presented['time'] - gpu_time) * 1000)
            if submitted:
                samples['submitToGpuMs'].append((gpu_time - submitted['time']) * 1000)
                samples[role + 'SubmitToGpuMs'].append((gpu_time - submitted['time']) * 1000)
    for stages in frames.values():
        gpu = stages.get('gpuComplete')
        if gpu and 'callbackTime' in gpu:
            samples['overlayGpuCallbackDelayMs'].append((gpu['callbackTime'] - gpu['time']) * 1000)
        acquisition = stages.get('drawableAcquireEnd')
        returned = stages.get('drawableReturnedToMain')
        if returned and 'ready' in returned:
            samples['drawableReturnToMainMs'].append((returned['time'] - returned['ready']) * 1000)
        queued = stages.get('drawableAcquireQueued')
        if acquisition and 'ready' in acquisition:
            samples['drawableAcquireMs'].append((acquisition['time'] - acquisition['ready']) * 1000)
            if queued:
                samples['drawableQueueMs'].append((acquisition['ready'] - queued['time']) * 1000)
        ready = stages.get('phaseReady') or stages.get('midpointReady')
        if ready:
            samples['pipelineProcessingMs'].append(ready['processing'] * 1000)
            if 'algorithm' in ready:
                samples['appleProcessingMs'].append(ready['algorithm'] * 1000)
        original = stages.get('originalReady')
        if original:
            samples['captureToConvertedMs'].append((original['time'] - original['source']) * 1000)
        scheduled = stages.get('scheduled')
        if scheduled and 'ready' in scheduled:
            samples['readyToSchedulingMs'].append((scheduled['time'] - scheduled['ready']) * 1000)
    for stages in captures.values():
        native = stages.get('nativePresented')
        gpu = stages.get('nativeGpuComplete')
        capture = stages.get('gameInput')
        if gpu and capture:
            samples['nativeGpuToCaptureMs'].append((capture['time'] - gpu['time']) * 1000)
        if gpu and 'callbackTime' in gpu:
            samples['nativeGpuCallbackDelayMs'].append((gpu['callbackTime'] - gpu['time']) * 1000)
        if native:
            samples['nativeSubmitToDisplayMs'].append((native['time'] - native['source']) * 1000)
            if gpu:
                samples['nativeGpuToDisplayMs'].append((native['time'] - gpu['time']) * 1000)
    shown.sort(key=lambda e: e['time'])
    order_errors = sum(a['sequence'] >= b['sequence'] for a, b in zip(shown, shown[1:]))
    inputs = sorted({e['source'] for e in events if e['kind'] == 'input'})
    game_inputs = sorted({e['time'] for e in events if e['kind'] == 'gameInput'})
    cadence_inputs = game_inputs or inputs
    intervals = [b - a for a, b in zip(cadence_inputs, cadence_inputs[1:])]
    presentation_stalls = []
    for before, after in zip(shown, shown[1:]):
        gap = after['time'] - before['time']
        if gap < .060:
            continue
        counts = collections.Counter(event['kind'] for event in events
                                     if before['time'] < event['time'] < after['time'])
        presentation_stalls.append({'gapMs': gap * 1000, 'start': before['time'], 'end': after['time'],
                                    'beforeSequence': before['sequence'], 'afterSequence': after['sequence'],
                                    'eventsDuringGap': dict(counts)})
    span = shown[-1]['time'] - shown[0]['time'] if len(shown) > 1 else 0
    return {
        'inputCount': len(inputs), 'gameInputCount': len(game_inputs), 'presentedCount': len(shown),
        'displayFPS': (len(shown) - 1) / span if span else None,
        'presentationOrderErrors': order_errors, 'drops': dict(drops),
        'dropDeadlines': deadlines,
        'maxEventGaps': gaps, 'presentationStalls': presentation_stalls,
        'nativePresentedCount': sum(e['kind'] == 'nativePresented' for e in events),
        'nativeUnconfirmedCount': sum(e['kind'] == 'nativeUnconfirmed' for e in events),
        'captureRoutes': dict(collections.Counter(e.get('reason', 'unknown') for e in events if e['kind'] == 'gameInput')),
        'captureFallbacks': dict(collections.Counter(e.get('reason', 'unknown') for e in events if e['kind'] == 'captureFallback')),
        'overlayTransitions': [e for e in events if e['kind'] == 'overlayVisibility'],
        'displayStateSamples': [e for e in events if e['kind'] == 'displayState'],
        'presentationExpiryChecks': {role: {'count': len(errors), 'afterExpiryCount': sum(e > 0 for e in errors),
                                            'maxAfterExpiryMs': max(0, max(errors))}
                                     for role, errors in expiry_checks.items()},
        'presentationWaitDiagnostics': {
            'note': 'Confirmed frames ahead is a lower bound. Core Video ticks are predicted clock targets, not scanout or missed-refresh proof.',
            'tickCount': sum(len(values) for values in ticks.values()),
            'perFrame': presentation_waits,
            'gpuWaitByConfirmedFramesAhead': {
                str(depth): {'count': len(values), 'p50': percentile(values, .5), 'p95': percentile(values, .95)}
                for depth, values in sorted(queue_waits.items())},
            'gpuWaitByRoleAndFramesAhead': {
                role: {str(depth): {
                    'count': len(values), 'p50': percentile(values, .5), 'p95': percentile(values, .95)}
                    for depth in sorted(queue_waits)
                    if (values := [row['gpuToDisplayMs'] for row in presentation_waits
                                   if row['role'] == role and row['confirmedFramesAheadAtPresentCall'] == depth])}
                for role in ('original', 'midpointReference')},
        },
        'timings': {key: {'count': len(values), 'p50': percentile(values, .5),
                          'p95': percentile(values, .95), 'max': max(values)} for key, values in samples.items()},
    }, {'intervalsSeconds': intervals, 'origin': 'continuous trace; game submissions' if game_inputs else 'continuous trace; processed game inputs only'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--trace-id', type=int)
    args = parser.parse_args()
    events = []
    for line in args.log.read_text(errors='replace').splitlines():
        if ' FRAME {' in line:
            events.append(json.loads(line.split(' FRAME ', 1)[1]))
    if not events:
        parser.error('No FRAME events. Record 30 seconds with Option-Shift-T in the new game hook.')
    trace_id = args.trace_id or max(e['traceID'] for e in events)
    selected = [e for e in events if e['traceID'] == trace_id]
    if not selected:
        parser.error('The requested trace ID is absent from this log.')
    result, cadence = analyze(selected)
    result['traceID'] = trace_id
    result['note'] = 'Same-frame joined timings, not a sum of independent percentiles. Window visibility and game workload affect results.'
    result['lostEventsReportedInLog'] = sum(int(line.split('lost=', 1)[1].split()[0])
                                      for line in args.log.read_text(errors='replace').splitlines()
                                      if 'FRAME_TRACE lost=' in line)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    for suffix, value in [('.json', result), ('-cadence.json', cadence)]:
        Path(str(args.out) + suffix).write_text(json.dumps(value, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'dropDeadlines'}, indent=2))


if __name__ == '__main__':
    main()
