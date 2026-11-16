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
        def ready(editor, source, dirty=False):
            editor.wait_until(lambda: (data := editor.checkpoint()) is not None
                              and data["buffers"][data["active"]]["text"] == source
                              and data["buffers"][data["active"]]["dirty"] == dirty, timeout=15)
        def shown(editor, text):
            try: editor.wait_until(lambda: text in editor.screen_text(), timeout=15)
            except AssertionError: raise AssertionError(editor.screen_text()) from None
        env={"VIBECHAR_LINE_NUMBERS":"1"}
        source="a"*(512*1024-1)
        path=root/"threshold.txt";path.write_text(source)
        with Session(path,extra_env=env) as editor:
            ready(editor,source)
            assert "Large text" not in editor.screen_text()
            editor.send(b"X");ready(editor,"X"+source,True);shown(editor,"Large text")
            editor.send(b"\x1a");ready(editor,source)
            editor.wait_until(lambda:"Large text" not in editor.screen_text())
            editor.send(b"\x11");editor.finish()
            assert path.read_text()==source

        tail='{ "b": 2, "a": 1 }'
        source="x"*(10*1024*1024)+"\n"+tail
        path=root/"budgets.txt";path.write_text(source)
        with Session(path,extra_env=env) as editor:
            ready(editor,source);shown(editor,"Large text")
            editor.send(b"\x1b[<0;7;2M\x1b[<0;7;2m\x1b[<0;7;2M\x1b[<0;7;2m")
            shown(editor,"Long line · drag to select a fragment")
            editor.send(b"\x04");shown(editor,"limited to 4 MiB")
            editor.send(b"\x06");shown(editor,"Search is limited to 4 MiB")
            editor.send(b"\x1b\x0b");shown(editor,"V_ Text tools")
            editor.send(b"format\r");shown(editor,"Select up to 1 MiB")
            ready(editor,source)
            editor.send(b"\x1b")
            editor.wait_until(lambda:"V_ Text tools" not in editor.screen_text())
            editor.send(b"\x1b[1;5F\x1b[1;2H")
            editor.wait_until(lambda:(data:=editor.checkpoint()) is not None and data["buffers"][data["active"]]["selection"]=={"start":len(source)-len(tail),"end":len(source)})
            editor.send(b"\x0b");shown(editor,"V_ Text tools")
            editor.send(b"minify\r");ready(editor,source[:-len(tail)]+'{"b":2,"a":1}',True)
            editor.send(b"\x1a");ready(editor,source)
            editor.send(b"\x13");editor.wait_until(lambda:editor.file_matches(path,source.encode()))
            editor.send(b"\x11");editor.finish()
            assert path.read_bytes()==source.encode()

        source="PRIVATE_LARGE_TUI_FIXTURE\n"+"я"*(300*1024)
        with Session(extra_env=env) as editor:
            ready(editor,"")
            editor.send(b"\x10\x1b[200~"+source.encode()+b"\x1b[201~")
            shown(editor,"Large text")
            editor.send(b"\x1b[23~");shown(editor,"tools: selection ≤1 MiB")
            assert all("PRIVATE_LARGE_TUI_FIXTURE" not in b["text"] for b in editor.checkpoint()["buffers"])
            editor.send(b"\x1b\x11\x11");editor.finish()
    print(json.dumps({"large_text_real_pty_scenarios": 5,
                      "one_ten_mib_unicode_history_save_restart_mode_threshold_bounded_word_search_tools_selected_json_private": "passed"}))


if __name__ == "__main__":
    main()
