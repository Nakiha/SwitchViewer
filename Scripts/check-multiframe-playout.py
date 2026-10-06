#!/usr/bin/env python3
"""Real Metal fixture checks. Run sequentially with other GPU workloads stopped.

Raw logs and JSON stay in ignored .build. A baseline release directory can be
supplied to compare the unchanged 2x policy against a previous revision.
"""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)] if ordered else None


def run(name, binaries, factor, budget, width, out):
    log = out / (name + ".log")
    env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(binaries / "libSwitchViewerGameHook.dylib"),
               SWITCHVIEWER_GAME_HOOK="1", SWITCHVIEWER_FRAME_TRACE="1",
               SWITCHVIEWER_GAME_DISPLAY_SYNC="0", SWITCHVIEWER_GAME_PROFILE="lowLatency",
               SWITCHVIEWER_GAME_CADENCE="uniform", SWITCHVIEWER_GAME_MULTIPLIER=str(factor))
    env.pop("SWITCHVIEWER_GAME_DELAY_MS", None)
    if budget is not None:
        env["SWITCHVIEWER_GAME_DELAY_MS"] = str(budget)
    command = [str(binaries / "GameHookFixture"), "--smoke-test", "--direct-presentation",
               "--direct-in-flight", "--validate-copy", "--fps=30", f"--proxy-width={width}"]
    print(f"Starting {name}", flush=True)
    with log.open("w") as output:
        child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT)
        try:
            code = child.wait(timeout=35)
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
            raise RuntimeError(f"{name}: fixture timed out")
    text = log.read_text(errors="replace")
    events = [json.loads(line.split(" FRAME ", 1)[1]) for line in text.splitlines() if " FRAME {" in line]
    inputs = [e for e in events if e["kind"] == "input"]
    assert code == 0 and len(inputs) > 150, f"{name}: no sustained capture"
    # Skip session warmup and the undrained final trace batch.
    floor, ceiling = inputs[0]["time"] + 3, inputs[-1]["time"] - .3
    shown = sorted([e for e in events if e["kind"] == "presented" and floor <= e["time"] <= ceiling], key=lambda e: e["time"])
    originals = [e for e in shown if e.get("original", e["sequence"] % factor == 0)]
    generated = [e for e in shown if not e.get("original", e["sequence"] % factor == 0)]
    gaps = [(b["time"] - a["time"]) * 1000 for a, b in zip(shown, shown[1:])]
    processing = [e["processing"] * 1000 for e in events if e["kind"] in ("midpointReady", "phaseReady") and floor <= e["time"] <= ceiling and "processing" in e]
    order_errors = sum(a["sequence"] >= b["sequence"] for a, b in zip(shown, shown[1:]))
    expiry_errors = sum(e["time"] >= e["expires"] for e in events if e["kind"] == "submitted" and "expires" in e)
    selected_inputs = [e for e in inputs if floor <= e["time"] <= ceiling]
    original_ids = {e["sequence"] for e in selected_inputs}
    shown_ids = {e["sequence"] for e in originals}
    submitted_originals = [e for e in events if e["kind"] == "scheduled" and e.get("original", e["sequence"] % factor == 0) and floor <= e["time"] <= ceiling]
    intentional_delays = [(e["deadline"] - e["source"]) * 1000 for e in submitted_originals]
    stats = dict(name=name, factor=factor, budgetMS=budget, proxyWidth=width,
                 outputFPS=len(shown) / (ceiling - floor), originalFPS=len(originals) / (ceiling - floor),
                 generatedFPS=len(generated) / (ceiling - floor),
                 originalDeliveryPercent=100 * len(original_ids & shown_ids) / max(1, len(original_ids)),
                 originalAgeP95MS=percentile([(e["time"] - e["source"]) * 1000 for e in originals], .95),
                 processingP95MS=percentile(processing, .95), gapP95MS=percentile(gaps, .95),
                 scheduledOriginalDelayP95MS=percentile(intentional_delays, .95),
                 orderErrors=order_errors, expiredSubmissions=expiry_errors,
                 shownPhases=sorted({e["phase"] for e in generated if "phase" in e}))
    assert shown and originals and order_errors == 0 and expiry_errors == 0, stats
    assert stats["originalDeliveryPercent"] >= 90, stats
    if factor > 2 and budget and width == 1280:
        ready_phases = sorted({e["phase"] for e in events if e["kind"] == "phaseReady" and floor <= e["time"] <= ceiling})
        assert ready_phases == [i / factor for i in range(1, factor)], stats
        if factor == 4:
            assert stats["shownPhases"] == ready_phases, stats
        # 8x 30fps requests 240fps on a 120Hz display. All outputs must be
        # generated; physical presentation can only show a subset of them.
        assert generated, stats
    if budget == 0:
        assert len(generated) == 0 and stats["scheduledOriginalDelayP95MS"] < 5, stats
    print(json.dumps(stats, ensure_ascii=False), flush=True)
    return stats


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, help="Previous release binaries directory")
    parser.add_argument("--out", type=Path, default=ROOT / ".build/multiframe-playout")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    current = ROOT / ".build/release"
    stats = []
    if args.baseline:
        for repeat in range(2):
            stats.append(run(f"baseline-2x-{repeat}", args.baseline.resolve(), 2, None, 1280, args.out))
            stats.append(run(f"current-2x-{repeat}", current, 2, None, 1280, args.out))
    else:
        stats.append(run("current-2x", current, 2, None, 1280, args.out))
    for name, factor, budget, width in [("4x-60ms", 4, 60, 1280), ("8x-80ms", 8, 80, 1280),
                                       ("4x-zero-budget", 4, 0, 1280), ("8x-overloaded", 8, 60, 1920)]:
        stats.append(run(name, current, factor, budget, width, args.out))
    report = {"runs": stats, "limits": "30fps synthetic game, 120Hz desktop; excludes actual game GPU load and input-to-photon latency"}
    (args.out / "summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    if args.baseline:
        old = [s for s in stats if s["name"].startswith("baseline")]
        new = [s for s in stats if s["name"].startswith("current")]
        # Two alternating repetitions, tolerance for display scheduling noise.
        for metric in ("originalAgeP95MS", "gapP95MS", "processingP95MS"):
            before = sum(s[metric] for s in old) / len(old)
            after = sum(s[metric] for s in new) / len(new)
            assert after <= before + 2, f"2x regression: {metric}: {before:.2f} -> {after:.2f}"
        assert sum(s["originalDeliveryPercent"] for s in new) / len(new) >= sum(s["originalDeliveryPercent"] for s in old) / len(old) - 1
    print("PASS: phase ordering, expiry, budget, overload and 2x checks", flush=True)


if __name__ == "__main__":
    main()
