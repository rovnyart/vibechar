#!/usr/bin/env python3
"""Real release PTY find/replace acceptance, isolated recovery and synthetic text."""
from pathlib import Path
import json
import runpy
import tempfile

ROOT=Path(__file__).resolve().parent.parent
Session=runpy.run_path(str(ROOT/"scripts/test-terminal.py"))["Session"]

def main():
    with tempfile.TemporaryDirectory(prefix="vibechar-find-pty-") as temporary:
        root=Path(temporary)
        def saved(editor,text,clean=None):
            try:
                editor.wait_until(lambda:(data:=editor.checkpoint()) is not None and data["buffers"][data["active"]]["text"]==text
                                  and (clean is None or data["buffers"][data["active"]]["dirty"] != clean))
            except AssertionError:
                raise AssertionError(f"Synthetic find mismatch: {editor.checkpoint()!r}\n{editor.screen_text()}") from None
        def close_find(editor):
            editor.send(b"\x1b")
            editor.wait_until(lambda:not any(line.startswith(" Find:") for line in editor.screen_text().splitlines()))
        source="one One 👩‍💻\r\none\r\n"
        file=root/"source.txt";file.write_bytes(source.encode())
        with Session(file,state=root/"literal",extra_env={"NO_COLOR":""}) as editor:
            editor.wait_until(lambda:"Saved locally" in editor.screen_text())
            editor.send(b"\x06one")
            editor.wait_until(lambda:"1 / 3" in editor.screen_text())
            assert "Saving locally" not in editor.screen_text()
            editor.send(b"\x12\ttwo\x1b[15~")  # Ctrl+R, Tab replacement, F5 preview.
            editor.wait_until(lambda:"Replace 3 matches?" in editor.screen_text())
            assert file.read_bytes()==source.encode()
            saved(editor,source,True)
            editor.send(b"\x1b")
            editor.wait_until(lambda:"Replace 3 matches?" not in editor.screen_text())
            editor.send(b"\x1b[15~\r")
            replaced="two two 👩‍💻\r\ntwo\r\n"
            saved(editor,replaced,False)
            editor.send(b"\x1a");saved(editor,source,True)
            close_find(editor)
            editor.send(b"\x1b[1;5H\x12one\tX\r")  # Fast Enter may arrive before the worker result.
            saved(editor,"X One 👩‍💻\r\none\r\n",False)
            editor.send(b"\x1a");saved(editor,source,True)
            close_find(editor)
            editor.send(b"\x1b[1;5H\x06one\x1bc")  # Alt+C case sensitive.
            editor.wait_until(lambda:"1 / 2" in editor.screen_text())
            editor.send(b"\x11");editor.finish()
            assert file.read_bytes()==source.encode()

        regex_source="name=1\r\nother=22\r\n"
        with Session(piped=regex_source.encode(),state=root/"regex") as editor:
            editor.send(b"\x12(\\w+)=(\\d+)\x1br\t$1: $2\x1b[15~")
            editor.wait_until(lambda:"Replace 2 matches?" in editor.screen_text())
            editor.send(b"\r");saved(editor,"name: 1\r\nother: 22\r\n")
            editor.send(b"\x1a");saved(editor,regex_source)
            close_find(editor)
            editor.send(b"\x1b[1;5H\x12^\x1br\t>\x1b[15~")
            editor.wait_until(lambda:"Replace 3 matches?" in editor.screen_text())
            editor.send(b"\r");saved(editor,">name=1\r\n>other=22\r\n>")
            editor.send(b"\x1a");saved(editor,regex_source)
            close_find(editor)
            editor.send(b"\x06[\x1br")
            editor.wait_until(lambda:"Invalid or too complex regex" in editor.screen_text())
            saved(editor,regex_source)
            marker=b"UNPERSISTED_SEARCH_QUERY_xyz"
            editor.send(b"\x01"+marker)
            editor.wait_until(lambda:"No matches" in editor.screen_text())
            editor.send(b"\x11");editor.finish()
            assert marker not in (root/"regex/session.json").read_bytes()

        private="PRIVATE_SEARCH_FIXTURE one one"
        with Session(state=root/"private") as editor:
            editor.send(b"public\x10\x1b[200~"+private.encode()+b"\x1b[201~\x12one\ttwo\x1b[15~")
            editor.wait_until(lambda:"Replace 2 matches?" in editor.screen_text())
            editor.send(b"\r")
            editor.wait_until(lambda:"PRIVATE_SEARCH_FIXTURE two two" in editor.screen_text())
            editor.send(b"\x1a")
            editor.wait_until(lambda:private in editor.screen_text())
            editor.send(b"\x11\x11");editor.finish()
            encoded=(root/"private/session.json").read_text()
            assert "PRIVATE_SEARCH_FIXTURE" not in encoded
            assert editor.checkpoint()["buffers"][0]["text"]=="public"
    print(json.dumps({"find_replace_real_pty_scenarios":3,"literal_regex_case_preview_cancel_fast_enter_undo_crlf_zero_width_private_no_query_history":"passed"}))

if __name__=="__main__":main()
