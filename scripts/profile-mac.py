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
    options=parser.parse_args()
    results=[]
    for kind in ["minified","logs"]:
        for mib in [1,10]:
            print(f"AppKit fixture: {kind}, {mib} MiB",file=sys.stderr,flush=True)
            result=subprocess.run([str(options.binary),"--profile-appkit","--kind",kind,
                                   "--mib",str(mib),"--samples",str(options.samples)],
                                  stdout=subprocess.PIPE,text=True,check=True,timeout=options.timeout)
            results.append(json.loads(result.stdout))
    print(json.dumps(results,indent=2))


if __name__ == "__main__":
    main()
