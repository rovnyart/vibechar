#!/usr/bin/env python3
"""Real PTY indentation/wrapping, isolated recovery and synthetic clipboard."""
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

ROOT=Path(__file__).resolve().parent.parent
Session=runpy.run_path(str(ROOT/"scripts/test-terminal.py"))["Session"]


def main():
    with tempfile.TemporaryDirectory(prefix="vibechar-editing-pty-") as temporary:
        root=Path(temporary)
        clipboard,copy=root/"clipboard",root/"copy"
        copy.write_text(f"#!{sys.executable}\nimport sys\nfrom pathlib import Path\nPath({str(clipboard)!r}).write_bytes(sys.stdin.buffer.read())\n")
        copy.chmod(0o700)
        env={"VIBECHAR_COPY_COMMAND":str(copy)}

        def saved(editor,text,selection=None):
            def ready():
                data=editor.checkpoint()
                if not data:return False
                buffer=data["buffers"][data["active"]]
                return buffer["text"]==text and (selection is None or (buffer["selection"]["start"],buffer["selection"]["end"])==selection)
            editor.wait_until(ready)

        source="  я👩‍💻\r\n\tb\r\nlast"
        path=root/"indent.txt";path.write_bytes(source.encode())
        with Session(path,extra_env=env) as editor:
            saved(editor,source)
            editor.send(b"\x01\t");saved(editor,"      я👩‍💻\r\n    \tb\r\n    last")
            editor.send(b"\x1b[Z");saved(editor,source)
            editor.send(b"\x1a\x1a");saved(editor,source)
            editor.send(b"\x1b[1;5H\x1b[F\r");saved(editor,"  я👩‍💻\r\n  \r\n\tb\r\nlast")
            editor.wait_until(lambda:"2:3" in editor.screen_text())
            editor.send(b"\x1a\x13");editor.wait_until(lambda:editor.file_matches(path,source.encode()))
            editor.send(b"\x11");editor.finish()

        source="A"*100+"B"*100+"C"*100+"\nlast"
        path=root/"wrap.txt";path.write_bytes(source.encode())
        with Session(path,extra_env=env) as editor:
            saved(editor,source)
            editor.send(b"\x1b[21~")
            editor.wait_until(lambda:"Line wrap on" in editor.screen_text() and editor.screen_text().splitlines()[4].startswith("last"))
            lines=editor.screen_text().splitlines()
            assert lines[1].startswith("A"*30) and lines[2].startswith("B"*30) and lines[3].startswith("C"*30)
            editor.send(b"\x1b[<0;6;3M\x1b[<0;6;3m")
            saved(editor,source,(105,105));editor.wait_until(lambda:"1:106" in editor.screen_text())
            editor.send(b"\x1b[200~!\x1b[201~");saved(editor,source[:105]+"!"+source[105:])
            editor.send(b"\x1a");saved(editor,source)
            editor.send(b"\x1b[<0;1;2M\x1b[<32;4;4M\x1b[<0;4;4m\x03")
            editor.wait_until(lambda:clipboard.exists() and clipboard.read_bytes()==source[:203].encode())
            saved(editor,source,(0,203))
            fcntl.ioctl(editor.slave,termios.TIOCSWINSZ,struct.pack("HHHH",12,40,0,0))
            os.kill(editor.process.pid,signal.SIGWINCH)
            editor.wait_until(lambda:editor.screen_text().splitlines()[2].startswith("A"*30))
            saved(editor,source,(0,203))
            editor.send(b"\x1b[21~");editor.wait_until(lambda:"Line wrap off" in editor.screen_text())
            editor.send(b"\x13");editor.wait_until(lambda:editor.file_matches(path,source.encode()))
            editor.send(b"\x11");editor.finish()

        source="x"*(10*1024*1024)+"界👩‍💻e\u0301"
        path=root/"large-wrap.txt";path.write_bytes(source.encode())
        with Session(path,extra_env=env) as editor:
            saved(editor,source)
            editor.send(b"\x1b[21~");editor.wait_until(lambda:"Line wrap on" in editor.screen_text())
            editor.send(b"\x1b[1;5F");saved(editor,source,(len(source),len(source)))
            editor.send(b"!\x7f\x1a\x1a");saved(editor,source)
            editor.wait_until(lambda:not editor.checkpoint()["buffers"][0]["dirty"])
            fcntl.ioctl(editor.slave,termios.TIOCSWINSZ,struct.pack("HHHH",12,40,0,0))
            os.kill(editor.process.pid,signal.SIGWINCH)
            editor.wait_until(lambda:"1:10485766" in editor.screen_text())
            assert path.read_bytes()==source.encode()
            editor.send(b"\x11");editor.finish()

        with Session(extra_env=env) as editor:
            saved(editor,"")
            editor.send(b"\x10\x1b[200~  PRIVATE_EDITING_FIXTURE\x1b[201~\r")
            editor.wait_until(lambda:"2:3" in editor.screen_text())
            editor.send(b"\x1b[21~");editor.wait_until(lambda:"Line wrap on" in editor.screen_text())
            assert all("PRIVATE_EDITING_FIXTURE" not in buffer["text"] for buffer in editor.checkpoint()["buffers"])
            editor.send(b"\x1b[Z")
            editor.wait_until(lambda:"2:1" in editor.screen_text())
            destination=root/"private-saved.txt"
            editor.send(b"\x13"+str(destination).encode()+b"\r")
            editor.wait_until(lambda:editor.file_matches(destination,b"  PRIVATE_EDITING_FIXTURE\n"))
            editor.send(b"\x11");editor.finish()
    print(json.dumps({"editing_real_pty_scenarios":4,"indent_outdent_enter_crlf_unicode_one_undo_wrap_mouse_selection_resize_ten_mib_tail_byte_exact_save_private_exclusion":"passed"}))


if __name__=="__main__":
    main()
