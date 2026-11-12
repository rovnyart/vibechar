#!/usr/bin/env python3
"""Real release PTY multiple selections, isolated recovery and synthetic clipboards."""
import json
from pathlib import Path
import runpy
import sys
import tempfile

ROOT=Path(__file__).resolve().parent.parent
Session=runpy.run_path(str(ROOT/"scripts/test-terminal.py"))["Session"]

def main():
    with tempfile.TemporaryDirectory(prefix="vibechar-multi-pty-") as temporary:
        root=Path(temporary)
        clipboard,copy,paste=root/"clipboard",root/"copy",root/"paste"
        copy_source=f"#!{sys.executable}\nimport sys\nfrom pathlib import Path\nPath({str(clipboard)!r}).write_bytes(sys.stdin.buffer.read())\n"
        copy.write_text(copy_source);copy.chmod(0o700)
        paste.write_text(f"#!{sys.executable}\nimport sys\nfrom pathlib import Path\nsys.stdout.buffer.write(Path({str(clipboard)!r}).read_bytes())\n");paste.chmod(0o700)
        env={"VIBECHAR_COPY_COMMAND":str(copy),"VIBECHAR_PASTE_COMMAND":str(paste),"NO_COLOR":""}
        def saved(editor,text,dirty=None):
            try:
                editor.wait_until(lambda:(data:=editor.checkpoint()) is not None and data["buffers"][data["active"]]["text"]==text
                                  and (dirty is None or data["buffers"][data["active"]]["dirty"]==dirty))
            except AssertionError:
                raise AssertionError(f"Synthetic multi mismatch: {editor.checkpoint()!r}\n{editor.screen_text()}") from None
        def count(editor,number,noun="selections"):
            if number==1:noun=noun.removesuffix("s")
            try:editor.wait_until(lambda:f"{number} {noun}" in editor.screen_text())
            except AssertionError:raise AssertionError(editor.screen_text()) from None
        def all_matches(editor):
            editor.send(b"\x1b[1;5H\x0c")

        source="cat cat CAT cat\r\n";path=root/"words.txt";path.write_bytes(source.encode())
        with Session(path,state=root/"words",extra_env=env) as editor:
            saved(editor,source,False);editor.wait_until(lambda:"Saved locally" in editor.screen_text())
            editor.send(b"\x04");count(editor,1)
            editor.send(b"\x04");count(editor,2)
            editor.send(b"\x0c");count(editor,3)
            assert "Saving locally" not in editor.screen_text()
            editor.send(b"dog");saved(editor,"dog dog CAT dog\r\n",True);count(editor,3,"carets")
            editor.send(b"\x1a");saved(editor,source,False)
            editor.send(b"\x19");saved(editor,"dog dog CAT dog\r\n",True)
            editor.send(b"\x1b[1;5H\x04\x04");count(editor,2)
            editor.send(b"X");saved(editor,"X X CAT dog\r\n",True)
            editor.send(b"\x1a");saved(editor,"dog dog CAT dog\r\n",True)
            editor.send(b"\x11");editor.finish();assert path.read_bytes()==source.encode()

        with Session(piped=b"cat category cat\ncat",state=root/"rapid",extra_env=env) as editor:
            editor.send(b"\x0c\x1b[C\x7f\x7f")  # Navigation/deletion must wait for all matches.
            saved(editor,"c category c\nc");count(editor,3,"carets")
            editor.send(b"\x1a");saved(editor,"cat category cat\ncat")
            editor.send(b"\x11");editor.finish()

        source="x x x"
        with Session(piped=source.encode(),state=root/"clipboard-state",extra_env=env) as editor:
            all_matches(editor);count(editor,3)
            editor.send(b"\x03");editor.wait_until(lambda:clipboard.exists() and clipboard.read_text()=="x\nx\nx")
            copy.write_text(f"#!{sys.executable}\nraise SystemExit(1)\n")
            editor.send(b"\x18");editor.wait_until(lambda:"Clipboard unavailable" in editor.screen_text());saved(editor,source);count(editor,3)
            copy.write_text(copy_source)
            editor.send(b"\x18");saved(editor,"  ")
            editor.send(b"\x1a");saved(editor,source)
            all_matches(editor);count(editor,3);clipboard.write_bytes("я\r\n🦀".encode())
            editor.send(b"\x16");saved(editor,"я\r\n🦀 я\r\n🦀 я\r\n🦀")
            editor.send(b"\x1a");saved(editor,source)
            all_matches(editor);count(editor,3);clipboard.write_bytes(b"bad\xff")
            editor.send(b"\x16");editor.wait_until(lambda:"Clipboard unavailable or text" in editor.screen_text());saved(editor,source);count(editor,3)
            editor.send(b"\x11");editor.finish()

        source="👩‍💻\r\n👩‍💻\r\n"
        with Session(piped=source.encode(),state=root/"graphemes",extra_env=env) as editor:
            all_matches(editor);count(editor,2)
            editor.send(b"\x1b[C\x7f");saved(editor,"\r\n\r\n")
            editor.send(b"\x1a");saved(editor,source)
            all_matches(editor);count(editor,2)
            editor.send(b"\x1b[C\x1b[1;2D")
            editor.send(b"A");saved(editor,"A\r\nA\r\n")
            editor.send(b"\x1a");saved(editor,source)
            all_matches(editor);count(editor,2)
            editor.send(b"\x1b")
            editor.wait_until(lambda:"2 selections" not in editor.screen_text())
            editor.send(b"Q");saved(editor,"Q\r\n👩‍💻\r\n")
            editor.send(b"\x11");editor.finish()

        source="name=1\r\nother=22\r\n"
        with Session(piped=source.encode(),state=root/"regex",extra_env=env) as editor:
            editor.send(b"\x06\\w+=\\d+\x1br\x0c")  # Find, regex, Ctrl+L may precede worker completion.
            count(editor,2)
            assert " Find:" not in editor.screen_text()
            editor.send(b"X");saved(editor,"X\r\nX\r\n")
            editor.send(b"\x1a");saved(editor,source)
            editor.send(b"\x1b[1;5H\x06^\x1br\x0c");count(editor,3,"carets")
            editor.send(b"> ");saved(editor,"> name=1\r\n> other=22\r\n> ")
            editor.send(b"\x1a");saved(editor,source)
            editor.send(b"\x1b[1;5H\x06=\x0c");count(editor,2)
            editor.send(b"\x0e")  # New tab drops the transient set.
            editor.wait_until(lambda:"2/2" in editor.screen_text())
            editor.send(b"\x1b[17~")  # F6 back.
            editor.wait_until(lambda:"1/2" in editor.screen_text())
            assert "2 selections" not in editor.screen_text()
            editor.send(b"\x11");editor.finish()

        private="PRIVATE_MULTI_FIXTURE x x"
        with Session(state=root/"private",extra_env=env) as editor:
            editor.send(b"public\x10\x1b[200~"+private.encode()+b"\x1b[201~\x1b[1;5F\x04\x0c")
            count(editor,2)
            editor.send(b"Y")
            editor.wait_until(lambda:"PRIVATE_MULTI_FIXTURE Y Y" in editor.screen_text())
            editor.send(b"\x11\x11");editor.finish()
            assert "PRIVATE_MULTI_FIXTURE" not in (root/"private/session.json").read_text()
            assert editor.checkpoint()["buffers"][0]["text"]=="public"
    print(json.dumps({"multi_real_pty_scenarios":6,"next_all_regex_queued_typing_undo_clipboard_failures_graphemes_crlf_navigation_escape_tabs_private":"passed"}))

if __name__=="__main__":main()
