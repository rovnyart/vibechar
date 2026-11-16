#!/usr/bin/env python3
"""Numbered release PTY: hit testing, numerical statistics and view-only changes."""
import fcntl
import json
import os
from pathlib import Path
import runpy
import signal
import struct
import sys
import tempfile
import termios

ROOT = Path(__file__).resolve().parent.parent
Session = runpy.run_path(str(ROOT / "scripts/test-terminal.py"))["Session"]
F10, F11, F12 = b"\x1b[21~", b"\x1b[23~", b"\x1b[24~"


def main():
    with tempfile.TemporaryDirectory(prefix="vibechar-counters-pty-") as temporary:
        root = Path(temporary)
        clipboard, copy = root / "clipboard", root / "copy"
        copy.write_text(f"#!{sys.executable}\nimport sys\nfrom pathlib import Path\nPath({str(clipboard)!r}).write_bytes(sys.stdin.buffer.read())\n")
        copy.chmod(0o700)
        env = {"VIBECHAR_COPY_COMMAND": str(copy), "VIBECHAR_LINE_NUMBERS": "1"}

        def saved(editor, text, selection=None):
            def ready():
                data = editor.checkpoint()
                if data is None:
                    return False
                buffer = data["buffers"][data["active"]]
                return buffer["text"] == text and (selection is None or buffer["selection"] == {"start": selection[0], "end": selection[1]})
            editor.wait_until(ready)

        def screen(editor, fragment):
            try:
                editor.wait_until(lambda: fragment in editor.screen_text())
            except AssertionError:
                raise AssertionError(editor.screen_text()) from None

        source = "first\r\nsecond\r\nlast"
        path = root / "lines.txt"
        path.write_bytes(source.encode())
        with Session(path, extra_env=env) as editor:
            saved(editor, source)
            screen(editor, "Saved locally")
            assert editor.screen_text().splitlines()[1].startswith("  1 first")
            editor.send(b"\x1b[<0;2;3M\x1b[<0;2;3m\x03")
            editor.wait_until(lambda: clipboard.exists() and clipboard.read_bytes() == b"second\r\n")
            screen(editor, "7 chars selected")
            saved(editor, source, (7, 15))
            editor.send(b"\x1b[<0;7;4M\x1b[<0;7;4m")
            saved(editor, source, (17, 17))
            editor.send(F12)
            editor.wait_until(lambda: editor.screen_text().splitlines()[1].startswith("first"))
            editor.send(F12)
            editor.wait_until(lambda: editor.screen_text().splitlines()[1].startswith("  1 first"))
            editor.send(F11)
            screen(editor, "Text statistics")
            screen(editor, "UTF-8 bytes")
            editor.send(b"\x1b")
            screen(editor, "Saved locally")
            assert "Saving locally" not in editor.screen_text()
            assert not editor.checkpoint()["buffers"][0]["dirty"]
            editor.send(b"\x11")
            editor.finish()
            assert path.read_bytes() == source.encode()

        source = "A" * 96 + "B" * 96 + "\nlast"
        with Session(piped=source.encode(), extra_env=env) as editor:
            saved(editor, source)
            editor.send(F10)
            screen(editor, "Line wrap on")
            lines = editor.screen_text().splitlines()
            assert lines[1].startswith("  1 " + "A" * 30)
            assert lines[2].startswith("  · " + "B" * 30)
            assert lines[3].startswith("  2 last")
            editor.send(b"\x1b[<0;1;3M\x1b[<0;1;3m\x03")
            editor.wait_until(lambda: clipboard.read_bytes() == source[:193].encode())
            screen(editor, "193 chars selected · 1 line")
            editor.send(b"\x1b[1;5H" + F11 + b"\x1b[200~!\x1b[201~")
            saved(editor, "!" + source)
            editor.wait_until(lambda: "Text statistics" not in editor.screen_text())
            editor.send(b"\x1a")
            saved(editor, source)
            editor.send(b"\x11")
            editor.finish()

        source = "👩‍💻e\u0301\r\nfoo foo"
        with Session(piped=source.encode(), extra_env=env) as editor:
            saved(editor, source)
            editor.send(b"\x1b[1;2C")
            screen(editor, "1 char selected · 1 line")
            editor.send(F11)
            screen(editor, "Text statistics")
            # Exact Unicode/CRLF numeric rows are additionally asserted by core/native tests.
            assert "11" in editor.screen_text() and "UTF-8 bytes" in editor.screen_text()
            editor.send(F11 + b"\x1b[1;5F\x1b[H\x04\x04")
            screen(editor, "2 selections · 6 chars selected")
            editor.send(b"\x10\x1b[200~PRIVATE_COUNTER_FIXTURE\x1b[201~")
            screen(editor, "PRIVATE")
            fcntl.ioctl(editor.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 18, 40, 0, 0))
            os.kill(editor.process.pid, signal.SIGWINCH)
            screen(editor, "23 ch · 1 ln")
            editor.send(F11)
            screen(editor, "Text statistics")
            screen(editor, "UTF-8 bytes")
            assert all("PRIVATE_COUNTER_FIXTURE" not in b["text"] for b in editor.checkpoint()["buffers"])
            editor.send(b"\x1b\x11\x11")
            editor.finish()

        source = "x" * (10 * 1024 * 1024) + "\nlast"
        path = root / "ten-mib.txt"
        path.write_bytes(source.encode())
        with Session(path, extra_env=env) as editor:
            saved(editor, source)
            screen(editor, "10,485,765 chars")
            editor.send(b"\x1b[1;5F!\x1a")
            saved(editor, source)
            editor.send(b"\x1b[1;5H\x1b[1;2C")
            screen(editor, "1 char selected")
            editor.send(F12 + F11)
            screen(editor, "10,485,765")
            assert not editor.checkpoint()["buffers"][0]["dirty"]
            assert path.read_bytes() == source.encode()
            editor.send(b"\x1b\x11")
            editor.finish()
    print(json.dumps({"counters_real_pty_scenarios": 4, "numbered_hit_testing_wrapped_rows_graphemes_multiselection_private_resize_background_ten_mib_view_only": "passed"}))


if __name__ == "__main__":
    main()
