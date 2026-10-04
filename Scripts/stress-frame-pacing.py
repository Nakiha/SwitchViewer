#!/usr/bin/env python3
"""Sequential Metal replay A/B test; saves all runs, including failed checks.

Run after `zsh Scripts/build-app.sh`, with the game stopped to avoid competing
GPU workloads. This replays input cadence through real Apple interpolation and
presentation, not a timing-only mock. It does not reproduce game rendering cost.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("analysis", ROOT / "Scripts/analyze-frame-trace.py")
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


def summarize(events, result):
    shown = sorted((e for e in events if e["kind"] == "presented"), key=lambda e: e["time"])
    gaps = [(b["time"] - a["time"]) * 1000 for a, b in zip(shown, shown[1:])]
    delays = [e.get("pacingDelay", 0) * 1000 for e in events if e["kind"] == "submitted" and e["sequence"] % 2 == 0]
    inputs = sorted(e["time"] for e in events if e["kind"] == "gameInput")
    source_fps = (len(inputs) - 1) / (inputs[-1] - inputs[0]) if len(inputs) > 1 else None
    age = result["timings"].get("originalAgeMs", {})
    deviation = [abs(g - 500 / source_fps) for g in gaps] if source_fps else []
    # Metal timestamps near exact refresh multiples vary by fractions of a us.
    # Do not classify 25.000083 ms as meaningfully longer than 25 ms.
    tolerance_ms = .001
    tight = sum(g < 3 - tolerance_ms for g in gaps)
    long = sum(g > 25 + tolerance_ms for g in gaps)
    input_sequences = sorted({e["sequence"] for e in events if e["kind"] == "input"})
    # Exclude both ends where input/ready/submitted/presented can cross recording.
    originals = set(input_sequences[2:-2])
    midpoints = {sequence + 1 for sequence in originals if sequence + 2 in originals}
    presented_sequences = {e["sequence"] for e in shown}
    ready_sequences = {e["sequence"] for e in events if e["kind"] == "midpointReady"}
    return {"sourceFPS": source_fps, "displayFPS": result["displayFPS"],
            "outputMultiplier": result["displayFPS"] / source_fps if source_fps and result["displayFPS"] else None,
            "originalDeliveryPercent": 100 * len(originals & presented_sequences) / len(originals) if originals else None,
            "midpointGenerationPercent": 100 * len(midpoints & ready_sequences) / len(midpoints) if midpoints else None,
            "midpointDeliveryPercent": 100 * len(midpoints & presented_sequences) / len(midpoints) if midpoints else None,
            "originalAgeP50Ms": age.get("p50"), "originalAgeP95Ms": age.get("p95"),
            "gapCount": len(gaps), "gapThresholdToleranceMs": tolerance_ms,
            "tightBelow3Ms": tight,
            "tightPercent": 100 * tight / len(gaps) if gaps else None,
            "longAbove25Ms": long,
            "longPercent": 100 * long / len(gaps) if gaps else None,
            "gapP95Ms": analysis.percentile(gaps, .95) if gaps else None,
            "gapDeviationP95Ms": analysis.percentile(deviation, .95) if deviation else None,
            "gapMaxMs": max(gaps) if gaps else None,
            "phaseApplied": sum(d > 0 for d in delays), "phaseMaxMs": max(delays, default=0),
            "drops": result["drops"], "orderErrors": result["presentationOrderErrors"]}


def run(name, candidate, stress, args):
    prefix = args.out / name
    log = prefix.with_suffix(".log")
    command = [str(ROOT / ".build/release/GameHookFixture"), "--smoke-test",
               "--direct-presentation", "--direct-in-flight", "--validate-copy",
               f"--cadence={args.cadence}", f"--surface-size={args.surface}"]
    if candidate and args.candidate_arg:
        command.extend(args.candidate_arg)
    elif candidate and args.baseline_hook is None and args.candidate_cadence is None:
        command.append("--adaptive-unsynced-spacing")
    elif not candidate:
        command.append("--legacy-unsynced-spacing")
    if stress:
        command.append("--drawable-stall-test")
    hook = args.baseline_hook if not candidate and args.baseline_hook else ROOT / ".build/release/libSwitchViewerGameHook.dylib"
    env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(hook),
               SWITCHVIEWER_GAME_HOOK="1", SWITCHVIEWER_FRAME_TRACE="1",
               SWITCHVIEWER_GAME_DISPLAY_SYNC="0", SWITCHVIEWER_GAME_PROFILE="clarity")
    env["SWITCHVIEWER_GAME_CADENCE"] = (args.candidate_cadence or "lowLatency") if candidate else args.baseline_cadence
    print(f"Starting {name}", flush=True)
    timed_out = False
    with log.open("w") as output:
        child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT)
        try:
            code = child.wait(timeout=40)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
            child.terminate()  # Only the fixture this run created.
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            timed_out = True
            code = child.returncode
            if isinstance(error, KeyboardInterrupt):
                raise
    lines = log.read_text(errors="replace").splitlines()
    events = [json.loads(line.split(" FRAME ", 1)[1]) for line in lines if " FRAME {" in line]
    checks = subprocess.run([sys.executable, str(ROOT / "Scripts/check-early-capture.py"), str(log),
                             "--expect-route", "directAfterGPU", "--validate-copy",
                             "--check-midpoint-gate", "--check-presentation-stages"],
                            cwd=ROOT, text=True, capture_output=True)
    prefix.with_suffix(".checks.txt").write_text(checks.stdout + checks.stderr)
    report = {"name": name, "candidate": candidate, "stallTest": stress,
              "command": command, "hook": str(hook), "exitCode": code, "timedOut": timed_out,
              "cadenceMode": env["SWITCHVIEWER_GAME_CADENCE"],
              "checksPassed": checks.returncode == 0}
    floor_frames = []
    if events:
        trace = max(e["traceID"] for e in events)
        events = [e for e in events if e["traceID"] == trace]
        result, cadence = analysis.analyze(events)
        prefix.with_suffix(".analysis.json").write_text(json.dumps(result, indent=2) + "\n")
        phase_valid = all(0 <= e.get("pacingDelay", 0) <= .004001 and
                          (e.get("pacingDelay", 0) == 0 or e["sequence"] % 2 == 0)
                          for e in events if e["kind"] == "submitted")
        # The first state may precede layer creation and has no sync setting.
        sync_states = [e for e in events if e["kind"] == "displayState" and "syncEnabled" in e]
        report["phaseBoundsPassed"] = phase_valid
        report["unsyncedConfirmed"] = bool(sync_states) and all(not e.get("syncEnabled", True) for e in sync_states)
        report["activeVisibleFraction"] = (sum(e.get("applicationActive", False) and
            e.get("windowVisible", False) and not e.get("windowOccluded", True)
            for e in sync_states) / len(sync_states)) if sync_states else 0
        width, height = map(int, args.surface.split("x"))
        report["surfaceConfirmed"] = bool(sync_states) and all(
            e.get("surfaceWidth") == width and e.get("surfaceHeight") == height for e in sync_states)
        report.update(summarize(events, result))
        submitted = sorted((e for e in events if e["kind"] == "submitted"), key=lambda e: e["time"])
        floor_frames = [e for e in submitted if e.get("minimumDuration", 0) > 0]
        calls = {e["sequence"]: e for e in events if e["kind"] == "drawablePresentCalled"}
        floor_valid = all(0 <= e.get("minimumDuration", 0) <= .003001 for e in submitted)
        floor_valid = floor_valid and all(
            e.get("minimumDuration", 0) == 0 or e["sequence"] == before["sequence"] + 1
            for before, e in zip(submitted, submitted[1:]))
        floor_valid = floor_valid and all(e["sequence"] in calls and
            calls[e["sequence"]].get("reason") == "minimumDuration" and
            abs(calls[e["sequence"]].get("requested", 0) - e["minimumDuration"]) < .000001
            for e in floor_frames)
        report["cadenceFloorChecksPassed"] = floor_valid
        report["cadenceFloorFrames"] = len(floor_frames)
        if stress:
            starts = {e["sequence"]: e["time"] for e in events if e["kind"] == "drawableAcquireStart"}
            stalls = [(starts[e["sequence"]], e["time"]) for e in events
                      if e["kind"] == "drawableAcquireEnd" and e["sequence"] in starts
                      and e["time"] - starts[e["sequence"]] >= .9]
            if stalls:
                start, end = max(stalls, key=lambda pair: pair[1] - pair[0])
                inputs = sum(start < e["time"] < end for e in events if e["kind"] == "gameInput")
                recovered = sum(end < e["time"] < end + 1 for e in events if e["kind"] == "presented")
                report["stallRecovery"] = {"waitMs": (end - start) * 1000,
                                           "sourceFramesDuringWait": inputs,
                                           "presentationsInNextSecond": recovered}
                report["stallRecoveryPassed"] = inputs >= 10 and recovered >= 10
            else:
                report["stallRecoveryPassed"] = False
    report["passed"] = (code == 0 and not timed_out and report["checksPassed"] and
                        report.get("phaseBoundsPassed", False) and report.get("unsyncedConfirmed", False) and
                        report.get("activeVisibleFraction", 0) >= .9 and report.get("surfaceConfirmed", False) and
                        report.get("cadenceFloorChecksPassed", False) and
                        (not candidate or args.candidate_cadence != "uniform" or len(floor_frames) >= 100) and
                        (not stress or report.get("stallRecoveryPassed", False)))
    prefix.with_suffix(".json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cadence", type=Path, required=True)
    parser.add_argument("--surface", default="3024x1898")
    parser.add_argument("--repeats", type=int, default=2)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--include-stall", action="store_true")
    parser.add_argument("--candidate-arg", action="append", default=[],
                        help="Additional fixture switches for candidate runs")
    parser.add_argument("--candidate-cadence", choices=["lowLatency", "uniform"],
                        help="Compare the user-visible cadence setting without unrelated experiments")
    parser.add_argument("--baseline-cadence", choices=["lowLatency", "uniform"], default="lowLatency",
                        help="Use the same selected mode when comparing saved and current libraries")
    parser.add_argument("--baseline-hook", type=Path,
                        help="Compare a saved baseline library against the current release, without cadence experiments")
    args = parser.parse_args()
    args.cadence = args.cadence.resolve()
    args.out = args.out.resolve()
    if args.baseline_hook:
        args.baseline_hook = args.baseline_hook.resolve()
        if not args.baseline_hook.is_file():
            parser.error("Baseline hook library does not exist")
    if args.repeats < 1 or not args.cadence.is_file():
        parser.error("Supply an existing cadence file and positive repeat count")
    try:
        width, height = map(int, args.surface.split("x"))
        assert 64 <= width <= 8192 and 64 <= height <= 8192
    except (ValueError, AssertionError):
        parser.error("Surface must be WIDTHxHEIGHT, with each side between 64 and 8192")
    if args.out.exists() and any(args.out.iterdir()):
        parser.error("Choose a new output directory to preserve earlier runs")
    for name in ("GameHookFixture", "libSwitchViewerGameHook.dylib"):
        if not (ROOT / ".build/release" / name).is_file():
            parser.error("Build release binaries with Scripts/build-app.sh first")
    args.out.mkdir(parents=True, exist_ok=True)
    reports = []
    for index in range(args.repeats):
        # Alternate order to expose warmup/thermal bias instead of hiding it.
        for candidate in ([False, True] if index % 2 == 0 else [True, False]):
            reports.append(run(f"round-{index + 1}-{'candidate' if candidate else 'baseline'}", candidate, False, args))
    if args.include_stall:
        reports.append(run("candidate-stall", True, True, args))
    fields = ["displayFPS", "outputMultiplier", "originalDeliveryPercent", "midpointGenerationPercent",
              "midpointDeliveryPercent", "originalAgeP50Ms", "originalAgeP95Ms", "tightPercent", "longPercent"]
    aggregate = {}
    for candidate, label in [(False, "baseline"), (True, "candidate")]:
        group = [r for r in reports if r["candidate"] == candidate and not r["stallTest"]
                 and r["passed"] and r.get("displayFPS")]
        aggregate[label] = {key: statistics.median(r[key] for r in group if r.get(key) is not None)
                            for key in fields} if group else {}
    summary = {"runs": reports, "medianAcrossRuns": aggregate, "allChecksPassed": all(r["passed"] for r in reports),
               "excludedFromMedians": [r["name"] for r in reports if r["stallTest"] or not r["passed"]],
               "note": "Sequential real Metal fixture; no game render workload. Stall and invalid runs excluded from performance medians. Inspect every run; medians do not prove a game improvement."}
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(aggregate, indent=2), flush=True)
    return 0 if summary["allChecksPassed"] else 1


if __name__ == "__main__":
    sys.exit(main())
