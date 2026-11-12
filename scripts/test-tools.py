#!/usr/bin/env python3
"""Local text tools through the real release PTY, with synthetic text and isolated state."""
from pathlib import Path
import json
import runpy
import tempfile
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent.parent
Session = runpy.run_path(str(ROOT / "scripts/test-terminal.py"))["Session"]

def main():
    with tempfile.TemporaryDirectory(prefix="vibechar-tools-pty-") as temporary:
        root = Path(temporary)
        def saved(editor, text, dirty=None):
            try:
                editor.wait_until(lambda: (data := editor.checkpoint()) is not None
                                  and data["buffers"][data["active"]]["text"] == text
                                  and (dirty is None or data["buffers"][data["active"]]["dirty"] == dirty))
            except AssertionError:
                raise AssertionError(f"Synthetic tool mismatch: {editor.checkpoint()!r}\n{editor.screen_text()}") from None
        def tool(editor, query):
            editor.send(b"\x0b")
            editor.wait_until(lambda: "V_ Text tools" in editor.screen_text())
            editor.send(query.encode() + b"\r")
            editor.wait_until(lambda: "V_ Text tools" not in editor.screen_text())
        def dismiss(editor):
            editor.send(b"\x1b")
            editor.wait_until(lambda: "V_ Text tools" not in editor.screen_text())

        source = '{"z":1e400,"a":[{},"👩‍💻"],"z":9007199254740993123456789}\r\n'
        pretty = '{\r\n  "z": 1e400,\r\n  "a": [\r\n    {},\r\n    "👩‍💻"\r\n  ],\r\n  "z": 9007199254740993123456789\r\n}\r\n'
        path = root / "fixture.json"; path.write_bytes(source.encode())
        with Session(path, state=root/"json") as editor:
            saved(editor, source, False)
            editor.wait_until(lambda: "Saved locally" in editor.screen_text())
            editor.send(b"\x0b")
            editor.wait_until(lambda: "Whole tab" in editor.screen_text())
            assert "Saving locally" not in editor.screen_text()
            marker = "UNPERSISTED_TOOL_QUERY_xyz"
            editor.send(b"\x1b[200~" + marker.encode() + b"\x1b[201~")
            editor.wait_until(lambda: "No tools found" in editor.screen_text())
            dismiss(editor); saved(editor, source, False)
            tool(editor, "format"); saved(editor, pretty, True)
            tool(editor, "format")
            editor.wait_until(lambda: "Already in shape" in editor.screen_text())
            editor.send(b"\x1a"); saved(editor, source, False)  # No-op must not consume Undo.
            editor.send(b"\x19"); saved(editor, pretty, True)
            tool(editor, "minify"); saved(editor, source, True)
            editor.send(b"\x1a"); saved(editor, pretty, True)
            editor.send(b"\x11"); editor.finish()
            assert path.read_bytes() == source.encode()
            assert marker not in (root/"json/session.json").read_text()

        source = "👩‍💻\r\nb\r\na\r\ntail"
        path = root/"lines.txt"; path.write_bytes(source.encode())
        with Session(path, state=root/"selection") as editor:
            saved(editor, source, False)
            editor.send(b"\x1b[1;5H\x1b[B\x1b[1;2B\x1b[1;2B\x0b")
            editor.wait_until(lambda: "Selection" in editor.screen_text())
            editor.send(b"sort\r"); saved(editor, "👩‍💻\r\na\r\nb\r\ntail", True)
            editor.send(b"\x1a"); saved(editor, source, False)
            editor.send(b"\x11"); editor.finish()

        with Session(piped=b"b\na\nb\n  x \t\n", state=root/"lines") as editor:
            tool(editor, "dedupe"); saved(editor, "b\na\n  x \t\n")
            tool(editor, "trim"); saved(editor, "b\na\n  x\n")
            editor.send(b"\x1a"); saved(editor, "b\na\n  x \t\n")
            editor.send(b"\x1a"); saved(editor, "b\na\nb\n  x \t\n")
            editor.send(b"\x0bjson\r")
            editor.wait_until(lambda: "Invalid JSON" in editor.screen_text())
            saved(editor, "b\na\nb\n  x \t\n")
            editor.send(b"\x01dedupe\r")  # Retry after error, field is still focused.
            saved(editor, "b\na\n  x \t\n")
            editor.send(b"\x11"); editor.finish()

        source = "👩‍💻\r\nstraße\r\nTAIL"
        path = root/"case.txt"; path.write_bytes(source.encode())
        with Session(path, state=root/"case") as editor:
            saved(editor, source, False)
            editor.send(b"\x1b[1;5H\x1b[B\x1b[1;2B")
            tool(editor, "upper"); saved(editor, "👩‍💻\r\nSTRASSE\r\nTAIL", True)
            tool(editor, "lower"); saved(editor, "👩‍💻\r\nstrasse\r\nTAIL", True)
            editor.send(b"\x1a"); saved(editor, "👩‍💻\r\nSTRASSE\r\nTAIL", True)
            editor.send(b"\x1a"); saved(editor, source, False)
            editor.send(b"\x11"); editor.finish()
            assert path.read_bytes() == source.encode()

        decoded = "Привет +/é\r\n"
        encoded = quote(decoded, safe="-._~")
        path = root/"url.txt"; path.write_bytes(encoded.encode())
        with Session(path, state=root/"url") as editor:
            saved(editor, encoded, False)
            editor.send(b"\x0b\x1b[A")  # Up wraps from the first to the ninth command.
            editor.wait_until(lambda: "Tools 5–9 of 9" in editor.screen_text())
            assert "URL decode" in editor.screen_text()
            assert "Format JSON" not in editor.screen_text()
            editor.send(b"\r"); saved(editor, decoded, True)
            editor.send(b"\x1a"); saved(editor, encoded, False)
            editor.send(b"\x19"); saved(editor, decoded, True)
            tool(editor, "url encode"); saved(editor, encoded, True)
            tool(editor, "url decode"); saved(editor, decoded, True)
            editor.send(b"\x01\x1b[200~%GG\x1b[201~\x0burl decode\r")
            editor.wait_until(lambda: "Invalid URL escape" in editor.screen_text())
            saved(editor, "%GG")
            dismiss(editor)
            editor.send(b"\x1a"); saved(editor, decoded)
            editor.send(b"\x11"); editor.finish()
            assert path.read_bytes() == encoded.encode()

        with Session(state=root/"private") as editor:
            editor.send(b"public\x10\x1b[200~PRIVATE_TOOL_FIXTURE b\na\na\x1b[201~")
            tool(editor, "dedupe")
            editor.wait_until(lambda: "Text tool applied" in editor.screen_text())
            tool(editor, "upper")
            tool(editor, "url encode")
            tool(editor, "url decode")
            editor.send(b"\x11\x11"); editor.finish()
            encoded=(root/"private/session.json").read_text()
            assert "PRIVATE_TOOL_FIXTURE" not in encoded
            assert editor.checkpoint()["buffers"][0]["text"] == "public"
    print(json.dumps({"local_tools_real_pty_scenarios":6,"json_fidelity_selection_crlf_unicode_case_url_scroll_undo_noop_error_retry_private_cancel_no_history":"passed"}))

if __name__ == "__main__": main()
