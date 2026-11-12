#!/usr/bin/env python3
"""Release PTY selection/clipboard checks with disposable, synthetic providers."""
import json
from pathlib import Path
import runpy
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
Session = runpy.run_path(str(ROOT / "scripts/test-terminal.py"))["Session"]


def main():
    with tempfile.TemporaryDirectory(prefix="vibechar-selection-pty-") as temporary:
        root = Path(temporary)
        clipboard, copy, paste = root / "clipboard", root / "copy", root / "paste"
        copy_source = f"#!{sys.executable}\nimport sys\nfrom pathlib import Path\nPath({str(clipboard)!r}).write_bytes(sys.stdin.buffer.read())\n"
        copy.write_text(copy_source)
        paste.write_text(f"#!{sys.executable}\nimport sys\nfrom pathlib import Path\nsys.stdout.buffer.write(Path({str(clipboard)!r}).read_bytes())\n")
        copy.chmod(0o700); paste.chmod(0o700)
        env = {"VIBECHAR_COPY_COMMAND": str(copy), "VIBECHAR_PASTE_COMMAND": str(paste), "NO_COLOR": ""}

        def saved(editor, text, selection=None, head=None):
            def matches():
                data = editor.checkpoint()
                if data is None: return False
                buffer = data["buffers"][data["active"]]
                return (buffer["text"] == text
                        and (selection is None or buffer["selection"] == {"start": selection[0], "end": selection[1]})
                        and (head is None or buffer.get("selection_head") == head))
            editor.wait_until(matches)

        state = root / "keyboard"
        source = "one 👩‍💻e\u0301\r\ntwo"
        with Session(piped=source.encode(), state=state, extra_env=env) as editor:
            editor.send(b"\x1b[1;5H\x1b[1;2F")  # Ctrl+Home, Shift+End: whole first line.
            saved(editor, source, (0, 9), 9)
            assert "selected" in editor.screen_text()
            assert b"48;2;89;64;46" in editor.output, "selection background was not rendered"
            editor.send(b"\x03")
            editor.wait_until(lambda: clipboard.exists() and clipboard.read_text() == "one 👩‍💻e\u0301")
            copy.write_text(f"#!{sys.executable}\nraise SystemExit(1)\n")
            editor.send(b"\x18")  # Failed cut must keep text and selection.
            editor.wait_for(b"Clipboard unavailable")
            saved(editor, source, (0,9), 9)
            copy.write_text(copy_source)
            editor.send(b"\x18")
            saved(editor, "\r\ntwo")
            editor.send(b"\x1a")
            saved(editor, source)
            editor.send(b"\x01")
            saved(editor, source, (0,len(source)), len(source))
            clipboard.write_bytes(b"bad\xff")
            editor.send(b"\x16")
            editor.wait_until(lambda: "Clipboard unavailable or text" in editor.screen_text())
            saved(editor, source, (0,len(source)), len(source))
            large = "x" * 70_000 + "\r\n"
            clipboard.write_bytes(large.encode())
            editor.send(b"\x16")
            saved(editor, large)
            editor.send(b"\x1a")
            saved(editor, source)
            clipboard.write_bytes(b"x" * (8 * 1024 * 1024 + 1))
            editor.send(b"\x01\x16")
            editor.wait_until(lambda: "Clipboard unavailable or text" in editor.screen_text())
            saved(editor, source, (0,len(source)), len(source))
            clipboard.write_bytes("я\r\n".encode())
            editor.send(b"\x16")
            saved(editor,"я\r\n")
            editor.send(b"\x1a\x1b[1;5F\x1b[1;6H")  # Ctrl+End, Ctrl+Shift+Home: backward all.
            saved(editor, source, (0,len(source)), 0)
            editor.send(b"\x11"); editor.finish()
        with Session(state=state, extra_env=env) as editor:
            editor.wait_until(lambda: "Saved locally" in editor.screen_text())
            editor.send(b"\x1b[1;2C")
            saved(editor, source, (1,len(source)), 1)
            assert "Saving locally" not in editor.screen_text(), "extending selection flashed saving"
            editor.send(b"!\x1a\x11"); editor.finish()
            assert editor.checkpoint()["buffers"][0]["text"] == source

        mouse_source = "hello world\nsecond line\nthird\n" + "more text\n" * 45
        with Session(piped=mouse_source.encode(), extra_env=env) as editor:
            editor.send(b"\x1b[1;5H\x1b[<0;1;2M\x1b[<32;6;3M\x1b[<0;6;3m\x03")
            editor.wait_until(lambda: clipboard.read_bytes() == b"hello world\nsecon")
            editor.send(b"\x1b[<0;7;2M\x1b[<0;7;2m\x1b[<0;7;2M\x1b[<0;7;2m\x03")
            editor.wait_until(lambda: clipboard.read_bytes() == b"world")
            editor.send(b"\x1b[<4;2;2M\x1b[<4;2;2m\x03")  # Shift+click extends the anchor.
            editor.wait_until(lambda: clipboard.read_bytes() == b"ello ")
            editor.send(b"\x1b[<0;1;2M\x1b[<32;4;24M")
            editor.wait_until(lambda: editor.screen_text().splitlines()[1].strip() != "hello world")
            editor.send(b"\x1b[<0;4;24m")
            saved(editor,mouse_source)
            editor.send(b"\x03")
            editor.wait_until(lambda: len(clipboard.read_bytes()) > len(b"hello world\nsecond line\nthird\n"))
            editor.send(b"\x18")
            editor.wait_until(lambda: editor.checkpoint()["buffers"][0]["text"] != mouse_source)
            editor.send(b"\x1a\x11"); editor.finish()
            assert editor.checkpoint()["buffers"][0]["text"] == mouse_source

        private_state = root / "private"
        private = "PRIVATE_SELECTION_FIXTURE_👩‍💻"
        with Session(state=private_state, extra_env=env) as editor:
            editor.send(b"public\x10\x1b[200~"+private.encode()+b"\x1b[201~\x01\x03")
            editor.wait_until(lambda: clipboard.read_bytes() == private.encode())
            copied_at = clipboard.stat().st_mtime_ns
            editor.send(b"\x1b[200~replace\x1b[201~\x1a\x01\x03")
            editor.wait_until(lambda: clipboard.stat().st_mtime_ns != copied_at and clipboard.read_bytes() == private.encode())
            editor.send(b"\x11\x11"); editor.finish()
            encoded=(private_state/"session.json").read_text()
            assert private not in encoded and "PRIVATE_SELECTION" not in encoded
            assert editor.checkpoint()["buffers"][0]["text"] == "public"

    print(json.dumps({"selection_real_pty_scenarios":4,
        "keyboard_mouse_double_click_drag_autoscroll_clipboard_failure_large_paste_restart_private": "passed"}))


if __name__ == "__main__":
    main()
