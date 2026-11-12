#!/usr/bin/env python3
"""Release PTY samples on synthetic text. No clipboard or user recovery state."""
import argparse
import json
from pathlib import Path
import runpy
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
Session = runpy.run_path(str(ROOT / "scripts/test-terminal.py"))["Session"]


def summary(values):
    ordered = sorted(values)
    return {"p50_ms": statistics.median(ordered), "p95_ms": ordered[28]}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary",type=Path,default=ROOT/"target/release/vibechar")
    options=parser.parse_args()
    results = []
    with tempfile.TemporaryDirectory(prefix="vibechar-text-profile-") as temporary:
        root = Path(temporary)
        for mib in [1, 10]:
            text = '{"data":"' + 'x' * (mib * 1024 * 1024 - 11) + '"}'
            path = root / f"synthetic-{mib}.json"
            path.write_text(text)
            with Session(path, state=root / f"state-{mib}",binary=options.binary) as editor:
                def timed(key, column):
                    start = time.perf_counter()
                    editor.send(key)
                    while f"1:{column} " not in editor.screen_text():
                        editor.receive(0.005)
                        assert editor.process.poll() is None
                        assert time.perf_counter() - start < 15, "Synthetic key timed out"
                    return (time.perf_counter() - start) * 1000

                end_ms = timed(b"\x1b[1;5F", len(text) + 1)
                navigation, typing, deletion = [], [], []
                for _ in range(30):
                    navigation.append(timed(b"\x1b[D", len(text)))
                    timed(b"\x1b[C", len(text) + 1)
                    typing.append(timed(b"!", len(text) + 2))
                    deletion.append(timed(b"\x7f", len(text) + 1))
                # Sample both versions after the final debounced checkpoint,
                # independently of how quickly their 120 key events completed.
                editor.wait_until(lambda: "Saved locally" in editor.screen_text(),timeout=15)
                rss = int(subprocess.check_output(
                    ["ps", "-o", "rss=", "-p", str(editor.process.pid)], text=True).strip())
                results.append({"bytes": len(text), "first_frame_ms": editor.first_frame_ms,
                                "first_end_ms": end_ms, "navigation": summary(navigation),
                                "typing": summary(typing), "backspace": summary(deletion),
                                "rss_kib": rss, "samples_per_action": 30})
                editor.send(b"\x11")
                editor.finish()
                assert path.read_text() == text
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
