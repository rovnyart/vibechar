#!/usr/bin/env python3
"""Exercise shared history retention through actual terminal paste/history events."""
import json
import os
from pathlib import Path
import runpy
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
Session = runpy.run_path(str(ROOT / "scripts/test-terminal.py"))["Session"]


def main():
    with tempfile.TemporaryDirectory(prefix="vibechar-history-pty-") as temporary:
        root = Path(temporary)
        path = root / "unicode.txt"
        path.write_bytes(b"")
        with Session(path, state=root / "state") as editor:
            def send(data):
                # Pump both PTY directions: a bulk producer must not deadlock on
                # input while the editor waits for its output to be consumed.
                blocking = os.get_blocking(editor.master)
                os.set_blocking(editor.master, False)
                deadline = time.monotonic() + 10
                try:
                    while data:
                        try:
                            written = os.write(editor.master, data[:256])
                            data = data[written:]
                        except BlockingIOError:
                            editor.receive(0.01)
                        editor.receive(0)
                        assert editor.process.poll() is None
                        assert time.monotonic() < deadline, "PTY bulk input stalled"
                finally:
                    os.set_blocking(editor.master, blocking)

            def saved(text, dirty):
                editor.wait_until(lambda: (data := editor.checkpoint()) is not None
                                  and data["buffers"][0]["text"] == text
                                  and data["buffers"][0]["dirty"] == dirty, timeout=10)

            paste = b"\x1b[200~" + "я".encode() + b"\x1b[201~"
            send(paste * 1029)
            text = "я" * 1029
            saved(text, True)
            send(b"\x13")
            editor.wait_until(lambda: editor.file_matches(path, text.encode()))
            saved(text, False)
            send(b"\x1a" * 1024)
            saved("я" * 5, True)
            send(b"\x1a\x19")  # Exhausted Undo leaves the first five; Redo remains ordered.
            saved("я" * 6, True)
            send(b"\x19" * 1023)
            saved(text, False)
            send(b"\x1a\x1b[200~" + "🦀".encode() + b"\x1b[201~\x19")
            saved("я" * 1028 + "🦀", True)
            editor.send(b"\x11")
            editor.finish()
            assert path.read_bytes() == text.encode()
    print(json.dumps({"history_real_pty_scenarios": 1,
                      "isolated_paste_step_cap_unicode_exhausted_undo_saved_redo_divergence": "passed"}))


if __name__ == "__main__":
    main()
