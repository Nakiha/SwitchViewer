#!/usr/bin/env python3
"""Print measured timings; never promote modeled admission into display latency."""
import argparse,json,math,statistics
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('probes',nargs='+',type=Path);args=p.parse_args()
def q(xs,f):return sorted(xs)[max(0,min(len(xs)-1,math.ceil(len(xs)*f)-1))]
for path in args.probes:
 data=json.loads(path.read_text());print(f"\n{path.name}: {data['device']}, {data['os']}")
 print('| Resolution | Factor | Delivery | Batch P50 / P95 ms | First phase P50 / P95 ms |')
 print('|---|---|---|---|---|')
 for run in data['runs']:
  if run.get('error'):print('ERROR',run['width'],run['level'],run['error']);continue
  if len(run['phases'])==1 and run['level']!=1:continue
  samples=run['samples'];total=[s['totalMS'] for s in samples];first=[s['outputs'][0]['readyMS'] for s in samples]
  print(f"| {run['width']}×{run['height']} | {len(run['phases'])+1}× | {run['delivery']} | {statistics.median(total):.2f} / {q(total,.95):.2f} | {statistics.median(first):.2f} / {q(first,.95):.2f} |")
