#!/usr/bin/env python3
"""Large synthetic files: actual PTY movement, Unicode deletion, history and restart."""
import json
from pathlib import Path
import runpy
import tempfile

ROOT = Path(__file__).resolve().parent.parent
Session = runpy.run_path(str(ROOT / "scripts/test-terminal.py"))["Session"]


def main():
    with tempfile.TemporaryDirectory(prefix="vibechar-large-pty-") as temporary:
        root = Path(temporary)
        for mib in [1, 10]:
            prefix = "x" * (mib * 1024 * 1024)
            source = prefix + "e\u0301👩‍💻界\tZ"
            path = root / f"large-{mib}.txt"
            state = root / f"state-{mib}"
            path.write_text(source)
            with Session(path, state=state) as editor:
                def saved(text, dirty):
                    editor.wait_until(lambda: (data := editor.checkpoint()) is not None
                                      and data["buffers"][0]["text"] == text
                                      and data["buffers"][0]["dirty"] == dirty, timeout=15)

                editor.send(b"\x1b[1;5F" + b"\x7f" * 5)
                saved(prefix, True)
                editor.send(b"\x1a")
                saved(source, False)
                editor.send(b"\x19")
                saved(prefix, True)
                editor.send(b"\x1a\x1b[1;2D\x1b[200~!\x1b[201~")
                saved(source[:-1] + "!", True)
                editor.send(b"\x1a")
                saved(source, False)
                editor.send(b"\x11")
                editor.finish()
                assert path.read_text() == source
            with Session(state=state) as editor:
                editor.wait_until(lambda: "Z" in editor.screen_text())
                editor.send(b"\x7f")
                editor.wait_until(lambda: (data := editor.checkpoint()) is not None
                                  and data["buffers"][0]["text"] == source[:-1], timeout=15)
                editor.send(b"\x1a\x13")
                editor.wait_until(lambda: editor.file_matches(path, source.encode()), timeout=15)
                editor.send(b"\x11")
                editor.finish()
    print(json.dumps({"large_text_real_pty_scenarios": 2,
                      "one_ten_mib_unicode_tail_navigation_selection_history_save_restart": "passed"}))


if __name__ == "__main__":
    main()
