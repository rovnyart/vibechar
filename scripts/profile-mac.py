#!/usr/bin/env python3
"""Bound each isolated AppKit fixture; capture only synthetic timing metadata."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary",type=Path,default=ROOT/"apps/macos/.build/release/Vibechar")
    parser.add_argument("--samples",type=int,default=30)
    parser.add_argument("--timeout",type=float,default=50)
    parser.add_argument("--kind",choices=["minified","logs"])
    parser.add_argument("--mib",type=int,choices=[1,10])
    parser.add_argument("--repeat",type=int,default=1,help="Fresh processes per fixture")
    options=parser.parse_args()
    if not 1 <= options.samples <= 30 or options.repeat < 1 or options.timeout <= 0:
        parser.error("samples must be 1–30; repeat and timeout must be positive")
    results=[]
    for run in range(options.repeat):
        for kind in [options.kind] if options.kind else ["minified","logs"]:
            for mib in [options.mib] if options.mib else [1,10]:
                print(f"AppKit fixture: {kind}, {mib} MiB, run {run+1}/{options.repeat}",file=sys.stderr,flush=True)
                result=subprocess.run([str(options.binary),"--profile-appkit","--kind",kind,
                                       "--mib",str(mib),"--samples",str(options.samples)],
                                      stdout=subprocess.PIPE,text=True,check=True,timeout=options.timeout)
                results.append(json.loads(result.stdout))
    print(json.dumps(results,indent=2))


if __name__ == "__main__":
    main()
