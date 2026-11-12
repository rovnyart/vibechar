#!/usr/bin/env python3
"""Exercise the actual release editor through a controlling pseudo-terminal."""

import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import tempfile
import termios
import time
import unicodedata

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "target/release/vibechar"


class Session:
    def __init__(self, *arguments, piped=None, state=None, expect_ready=True, extra_env=None):
        self.temporary_state = tempfile.TemporaryDirectory(prefix="vibechar-state-") if state is None else None
        self.state = Path(self.temporary_state.name) if self.temporary_state else Path(state)
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        self.original = termios.tcgetattr(self.slave)
        self.output = bytearray()

        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)

        self.started = time.perf_counter()
        self.process = subprocess.Popen(
            [str(BINARY), *map(str, arguments)],
            stdin=self.slave if piped is None else subprocess.PIPE,
            stdout=self.slave,
            stderr=self.slave,
            pass_fds=(self.slave,),
            preexec_fn=controlling_terminal,
            env={**os.environ, "TERM": "xterm-256color", "VIBECHAR_STATE_DIR": str(self.state), **(extra_env or {})},
        )
        if piped is not None:
            self.process.stdin.write(piped)
            self.process.stdin.close()
        if expect_ready:
            try:
                self.wait_for(b"vibechar")
                self.wait_for(b"\x1b[?25h")
            except BaseException:
                self.close()
                raise
        self.first_frame_ms = (time.perf_counter() - self.started) * 1000

    def receive(self, timeout=0.1):
        if select.select([self.master], [], [], timeout)[0]:
            try:
                data = os.read(self.master, 65536)
            except OSError:
                return False
            if not data:
                return False
            self.output.extend(data)
            if b"\x1b[6n" in data:
                os.write(self.master, b"\x1b[1;1R")
            return True
        return False

    def wait_for(self, fragment, timeout=5):
        deadline = time.monotonic() + timeout
        while fragment not in self.output and fragment.decode() not in self.screen_text():
            self.receive()
            if self.process.poll() is not None:
                raise AssertionError(f"editor exited before {fragment!r}: {bytes(self.output)!r}")
            if time.monotonic() > deadline:
                raise AssertionError(f"timed out waiting for {fragment!r}: {bytes(self.output)!r}")

    def screen_text(self):
        # Ratatui emits cell diffs: unchanged letters may be omitted between cursor
        # moves. Reconstruct its screen instead of matching only the raw byte stream.
        screen = [[" "] * 100 for _ in range(24)]
        row = column = 0
        for part in re.split(r"(\x1b\[[0-?]*[ -/]*[@-~])", self.output.decode(errors="replace")):
            if part.startswith("\x1b["):
                command = part[-1]
                parameters = part[2:-1]
                if command in ("H", "f"):
                    values = [int(value or "1") for value in parameters.split(";")]
                    row = values[0] - 1
                    column = values[1] - 1 if len(values) > 1 else 0
                elif command == "J" and parameters in ("2", "3"):
                    screen = [[" "] * 100 for _ in range(24)]
                elif command == "K" and parameters in ("", "0") and 0 <= row < 24:
                    screen[row][column:] = [" "] * max(0, 100 - column)
                continue
            for character in part:
                if character == "\r":
                    column = 0
                elif character == "\n":
                    row += 1
                elif character == "\u200d" or unicodedata.combining(character):
                    continue
                elif character.isprintable():
                    if 0 <= row < 24 and 0 <= column < 100:
                        screen[row][column] = character
                    column += 2 if unicodedata.east_asian_width(character) in ("W", "F") else 1
        return "\n".join("".join(line) for line in screen)

    def send(self, data):
        os.write(self.master, data)

    def wait_until(self, condition, timeout=5):
        deadline = time.monotonic() + timeout
        while not condition():
            self.receive(0.05)
            assert self.process.poll() is None, bytes(self.output)
            assert time.monotonic() < deadline, "timed out waiting for persisted state"

    def checkpoint(self):
        try:
            return json.loads((self.state / "session.json").read_text())
        except FileNotFoundError:
            return None

    def file_matches(self, path, content):
        try:
            return path.read_bytes() == content
        except FileNotFoundError:
            return False

    def failed_start(self, message):
        deadline = time.monotonic() + 5
        while self.process.poll() is None:
            self.receive()
            assert time.monotonic() < deadline, bytes(self.output)
        assert self.process.returncode == 1
        while self.receive(0):
            pass
        assert message in self.output, bytes(self.output)
        assert termios.tcgetattr(self.master) == self.original
        assert b"\x1b[?1049h" not in self.output, "failed startup entered raw terminal"

    def finish(self):
        deadline = time.monotonic() + 5
        while self.process.poll() is None and time.monotonic() < deadline:
            self.receive()
        assert self.process.poll() == 0, bytes(self.output)
        assert termios.tcgetattr(self.master) == self.original, "terminal attributes not restored"
        while select.select([self.master], [], [], 0)[0]:
            if not self.receive(0):
                break
        assert b"\x1b[?2004l" in self.output, "bracketed paste was not disabled"
        for mode in (1000, 1006):
            assert f"\x1b[?{mode}h".encode() in self.output, "mouse capture was not enabled"
            assert f"\x1b[?{mode}l".encode() in self.output, "mouse capture was not disabled"
        assert b"\x1b[?1049l" in self.output, "alternate screen was not left"

    def close(self):
        try:
            if self.process.poll() is None:
                self.force_stop()
        finally:
            os.close(self.master)
            os.close(self.slave)
            if self.temporary_state:
                self.temporary_state.cleanup()

    def force_stop(self):
        self.process.kill()
        # Drain PTY output while waiting, just as for graceful exits. A wait()
        # without draining can stall process teardown on macOS.
        deadline = time.monotonic() + 5
        while self.process.poll() is None and time.monotonic() < deadline:
            self.receive(0.05)
        self.process.wait(timeout=0.5)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def main():
    expected = "Привет 👩‍💻\r\nline\r\n".encode()
    with tempfile.TemporaryDirectory(prefix="vibechar-test-") as directory:
        directory = Path(directory)
        mouse_file = directory / "mouse.txt"
        mouse_state = directory / "mouse-state"
        mouse_text = "".join(f"row {n:03}\n" for n in range(60))
        mouse_file.write_text(mouse_text)
        with Session(mouse_file, state=mouse_state) as session:
            session.wait_until(lambda: session.checkpoint() is not None and "Saved locally" in session.screen_text())
            checkpoint = mouse_state / "session.json"
            before = checkpoint.read_bytes(), checkpoint.stat().st_mtime_ns
            session.send(b"\x1b[<65;10;5M")  # SGR wheel down, inside the document.
            session.wait_until(lambda: session.screen_text().splitlines()[1].startswith("row 003"))
            assert "1:1" in session.screen_text().splitlines()[22], "wheel moved the caret"
            until = time.monotonic() + 0.8
            while time.monotonic() < until:
                session.receive(0.05)
                assert "Saving locally" not in session.screen_text(), "wheel flashed recovery status"
            assert (checkpoint.read_bytes(), checkpoint.stat().st_mtime_ns) == before, "wheel rewrote recovery"
            assert b"\x1b[?25l" in session.output, "an offscreen caret should be hidden"
            session.send(b"\x1b[<0;5;3M\x1b[<0;5;3m")  # Click row 004, before its number.
            session.wait_until(lambda: session.checkpoint()["buffers"][0]["selection"]["start"] == 36)
            assert "Saved locally" in session.screen_text() and "Saving locally" not in session.screen_text()
            session.send(b"!")
            edited = mouse_text[:36] + "!" + mouse_text[36:]
            session.wait_until(lambda: session.checkpoint()["buffers"][0]["text"] == edited)
            session.send(b"\x1a")
            session.wait_until(lambda: session.checkpoint()["buffers"][0]["text"] == mouse_text)
            session.send(b"\x11")
            session.finish()
        assert mouse_file.read_text() == mouse_text, "mouse edits overwrote the original file"
        with Session(state=mouse_state) as session:
            session.wait_until(lambda: "Saved locally" in session.screen_text())
            session.send(b"\x1b[C")  # Keyboard navigation persists quietly too.
            session.wait_until(lambda: session.checkpoint()["buffers"][0]["selection"]["start"] == 37)
            assert "Saved locally" in session.screen_text() and "Saving locally" not in session.screen_text()
            session.send(b"\x11")
            session.finish()

        unicode_mouse = "a界e\u0301👩‍💻\tZ\r\nshort\r\n".encode()
        with Session(piped=unicode_mouse) as session:
            session.wait_until(lambda: session.checkpoint() is not None and "Saved locally" in session.screen_text())
            session.send(b"\x1b[<0;6;2M\x1b[<0;6;2m!")  # Second cell of emoji snaps after its whole grapheme.
            expected_mouse = "a界e\u0301👩‍💻!\tZ\r\nshort\r\n"
            session.wait_until(lambda: session.checkpoint()["buffers"][0]["text"] == expected_mouse)
            session.send(b"\x1a\x11")
            session.finish()
            assert session.checkpoint()["buffers"][0]["text"].encode() == unicode_mouse
        syntax_state = directory / "syntax-state"
        syntax_text = '{"name":"Pocket 👩‍💻","count":42}'.encode()
        with Session(state=syntax_state, extra_env={"NO_COLOR": ""}) as session:
            started = time.perf_counter()
            session.send(b"\x1b[200~" + syntax_text + b"\x1b[201~")
            session.wait_until(lambda: "Auto · JSON" in session.screen_text())
            syntax_ms = (time.perf_counter() - started) * 1000
            syntax_rss = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(session.process.pid)]))
            assert b"38;2;" in session.output, "syntax must emit truecolor styles"
            session.send(b"\x1bOQpy\r")
            session.wait_for(b"Language pinned: Python")
            session.wait_until(lambda: (data := session.checkpoint()) is not None
                               and data["buffers"][0].get("language") == "Python")
            assert session.checkpoint()["buffers"][0]["text"].encode() == syntax_text
            session.send(b"\x1bOQjson\x1b")
            session.wait_until(lambda: "Language:" not in session.screen_text())
            session.send(b"\x11")
            session.finish()
        with Session(state=syntax_state) as session:
            session.wait_until(lambda: "Python" in session.screen_text())
            session.send(b"\x1bOQauto\r")
            session.wait_until(lambda: "Auto · JSON" in session.screen_text())
            session.send(b"\x10\x1b[200~PRIVATE_SYNTAX_PTY_FIXTURE\x1b[201~\x1bOQswift\r")
            session.wait_for(b"Language pinned: Swift")
            session.send(b"\x11\x11")
            session.finish()
            encoded = (syntax_state / "session.json").read_text()
            assert "PRIVATE_SYNTAX_PTY_FIXTURE" not in encoded and "Swift" not in encoded
            assert session.checkpoint()["buffers"][0]["text"].encode() == syntax_text
            assert "language" not in session.checkpoint()["buffers"][0]
        path = directory / "sample.txt"
        with Session(path) as session:
            startup = session.first_frame_ms
            session.send(b"\x1b[200~" + expected + b"\x1b[201~")
            session.wait_for("Привет".encode())
            session.send(b"\x1a\x19\x13")  # undo, redo, save file
            session.wait_until(lambda: session.file_matches(path, expected))
            rss = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(session.process.pid)]))
            session.send(b"\x11")
            session.finish()
        assert path.read_bytes() == expected

        with Session(path) as session:
            session.send(b"!\x11")
            session.finish()
            assert session.checkpoint()["buffers"][0]["text"] == "!" + expected.decode()
        assert path.read_bytes() == expected, "recovery overwrote the original file"

        with Session(piped=expected) as session:
            session.send(b"\x11")
            session.finish()
            assert session.checkpoint()["buffers"][0]["text"] == expected.decode()

        with Session() as session:
            session.send(b"scratch\x13")
            session.wait_for(b"Save as:")
            destination = directory / "scratch.txt"
            session.send(str(destination).encode() + b"\r")
            session.wait_until(lambda: session.file_matches(destination, b"scratch"))
            session.send(b"\x11")
            session.finish()
        assert destination.read_text() == "scratch"

        undo_state = directory / "grouped-undo-state"
        undo_file = directory / "grouped-undo.txt"
        with Session(state=undo_state) as session:
            def undo_text(value, dirty=None):
                session.wait_until(lambda: session.screen_text().splitlines()[1].rstrip() == value)
                session.wait_until(lambda: (data := session.checkpoint()) is not None
                                   and data["buffers"][0]["text"] == value
                                   and (dirty is None or data["buffers"][0]["dirty"] == dirty))
            baseline = "hello world"
            session.send(baseline.encode()); undo_text(baseline)
            session.send(b"\x1a"); undo_text("")
            session.send(b"\x19"); undo_text(baseline)
            session.send(b"\x13"); session.wait_for(b"Save as:")
            session.send(str(undo_file).encode() + b"\r")
            session.wait_until(lambda: session.file_matches(undo_file, baseline.encode()))
            session.send(b"ab"); undo_text(baseline + "ab")
            session.send(b"\x1a"); undo_text(baseline, dirty=False)
            session.send(b"\x1a"); undo_text("", dirty=True)
            session.send(b"\x19"); undo_text(baseline, dirty=False)
            session.send(b"FIRST"); undo_text(baseline + "FIRST")
            time.sleep(1.1)
            session.send(b"SECOND"); undo_text(baseline + "FIRSTSECOND")
            session.send(b"\x1a"); undo_text(baseline + "FIRST")
            session.send(b"\x1a"); undo_text(baseline)
            session.send(b"ab"); undo_text(baseline + "ab")
            session.send(b"\x1b[D\x1b[Ccd"); undo_text(baseline + "abcd")
            session.send(b"\x1a"); undo_text(baseline + "ab")
            session.send(b"\x1a"); undo_text(baseline)
            session.send(b"ab"); undo_text(baseline + "ab")
            session.send(b"\x1b[200~P\x1b[201~cd"); undo_text(baseline + "abPcd")
            session.send(b"\x1a"); undo_text(baseline + "abP")
            session.send(b"\x1a"); undo_text(baseline + "ab")
            session.send(b"\x1a"); undo_text(baseline)
            session.send(b"abc"); undo_text(baseline + "abc")
            session.send(b"\x7f\x7f"); undo_text(baseline + "a")
            session.send(b"\x1a"); undo_text(baseline + "abc")
            session.send(b"\x19"); undo_text(baseline + "a")
            session.send(b"\x1a"); undo_text(baseline + "abc")
            session.send(b"\x1b[D\x1b[D\x1b[D\x1b[3~\x1b[3~"); undo_text(baseline + "c")
            session.send(b"\x1a"); undo_text(baseline + "abc")
            session.send(b"\x13\x11"); session.finish()
            assert undo_file.read_bytes() == (baseline + "abc").encode()

        original = directory / "save-as-original.txt"
        original.write_bytes(expected)
        renamed = directory / "копия.txt"
        renamed.write_bytes(b"keep until confirmed")
        read_only = directory / "save-as-readonly.txt"
        read_only.write_bytes(b"preserve")
        read_only.chmod(0o444)
        alias = directory / "save-as-link.txt"
        alias.symlink_to(original)
        save_as_state = directory / "save-as-state"
        with Session(original, state=save_as_state) as session:
            session.send(b"!\x1bOS")  # F4 Save As, including an existing file buffer.
            session.wait_for(b"Save as:")
            session.send(b"\x1b")
            session.wait_until(lambda: "Save as:" not in session.screen_text())
            for target in [directory / "missing" / "file.txt", read_only, alias]:
                session.send(b"\x1bOS" + str(target).encode() + b"\r")
                session.wait_until(lambda: "Save as:" not in session.screen_text())
                if target.exists():
                    session.wait_until(lambda: "Replace file?" in session.screen_text())
                    session.send(b"\r")
                session.wait_until(lambda: "Save failed:" in session.screen_text().splitlines()[-1])
                session.wait_until(lambda: (data := session.checkpoint()) is not None
                                   and data["buffers"][0]["path"] == str(original)
                                   and data["buffers"][0]["dirty"])
            session.send(b"\x1bOS" + str(renamed).encode() + b"\r")
            session.wait_until(lambda: "Replace file?" in session.screen_text())
            assert renamed.read_bytes() == b"keep until confirmed"
            session.send(b"\x1b")
            session.wait_until(lambda: "Replace file?" not in session.screen_text())
            assert renamed.read_bytes() == b"keep until confirmed"
            session.send(b"\x1bOS" + str(renamed).encode() + b"\r")
            session.wait_until(lambda: "Replace file?" in session.screen_text())
            session.send(b"\x7ft")  # Edit the name back to the same value: approval must reset.
            session.wait_until(lambda: "Save as:" in session.screen_text().splitlines()[-1])
            session.send(b"\r")
            session.wait_until(lambda: "Replace file?" in session.screen_text())
            assert renamed.read_bytes() == b"keep until confirmed"
            session.send(b"\r")
            session.wait_until(lambda: session.file_matches(renamed, b"!" + expected))
            session.send(b"?\x13")
            session.wait_until(lambda: session.file_matches(renamed, b"!?" + expected))
            assert original.read_bytes() == expected
            assert read_only.read_bytes() == b"preserve" and alias.is_symlink()
            session.send(b"\x11")
            session.finish()
            saved = session.checkpoint()["buffers"][0]
            assert saved["path"] == str(renamed) and not saved["dirty"]
        read_only.chmod(0o644)
        with Session(state=save_as_state) as session:
            session.wait_for("копия.txt".encode())
            session.wait_for(b"!?")
            session.send(b"\x11"); session.finish()

        state = directory / "two-buffers"
        with Session(state=state) as session:
            session.send(b"first\x0esecond\x1b[17~")
            session.wait_for(b"1/2")
            first = directory / "first.txt"
            session.send(b"!\x13")
            session.wait_for(b"Save as:")
            session.send(str(first).encode() + b"\r")
            session.wait_until(lambda: session.file_matches(first, b"first!"))
            session.send(b"\x1b[17~\x13")
            second = directory / "second.txt"
            session.wait_for(b"Save as:")
            session.send(str(second).encode() + b"\r")
            session.wait_until(lambda: session.file_matches(second, b"second"))
            session.send(b"\x1b[D\x11")  # cursor before d, flush and quit
            session.finish()
        with Session(state=state) as session:
            session.wait_for(b"2/2")
            session.send(b"?")
            session.wait_for(b"secon?d")
            session.send(b"\x1b[17~")
            session.wait_for(b"first!")
            session.send(b"\x11")
            session.finish()
            assert session.checkpoint()["buffers"][1]["text"] == "secon?d"
        assert first.read_text() == "first!" and second.read_text() == "second"
        # Opening the same file again selects its recovered buffer, preserving edits.
        with Session(second, state=state) as session:
            session.wait_for(b"2/2")
            session.wait_for(b"secon?d")
            session.send(b"\x11")
            session.finish()

        path.chmod(0o444)
        try:
            with Session(path) as session:
                session.send(b"!\x13")
                session.wait_for(b"Save failed")
                assert path.read_bytes() == expected
                session.send(b"\x11")
                session.finish()
                assert session.checkpoint()["buffers"][0]["text"].startswith("!")
        finally:
            path.chmod(0o644)

        background = directory / "background"
        with Session(state=background) as session:
            session.send(b"\x1b[200~" + expected + b"\x1b[201~\x0erecover me")
            session.wait_until(lambda: (data := session.checkpoint()) is not None
                               and len(data["buffers"]) == 2
                               and data["buffers"][1]["text"] == "recover me")
            assert (background / "session.json").stat().st_mode & 0o777 == 0o600
            session.force_stop()
        with Session(state=background) as session:
            session.wait_for(b"2/2")
            session.wait_for(b"recover me")
            session.send(b"\x17")
            session.wait_for(b"Unsaved text")
            session.send(b"\x17\x11")  # discard the tab, save the remaining session
            session.finish()
        with Session(state=background) as session:
            session.wait_for(b"1/1")
            session.wait_for("Привет".encode())
            session.send(b"\x11")
            session.finish()

        private_state = directory / "private-mixed"
        private_text = "PRIVATE_PTY_FIXTURE_👩‍💻".encode()
        with Session(state=private_state) as session:
            session.send(b"public survives\x10\x1b[200~" + private_text + b"\x1b[201~")
            session.wait_for(b"PRIVATE")
            session.wait_until(lambda: (data := session.checkpoint()) is not None
                               and len(data["buffers"]) == 1
                               and data["buffers"][0]["text"] == "public survives")
            for file in private_state.rglob("*"):
                if file.is_file():
                    assert private_text not in file.read_bytes(), "private text entered recovery"
            session.send(b"\x13")
            session.wait_for(b"Save as (ends private mode):")
            session.send(b"\x1b")
            session.wait_until(lambda: "PRIVATE" in session.screen_text().splitlines()[-2] and "Save as" not in session.screen_text())
            session.send(b"\x13" + str(directory / "missing" / "save.txt").encode() + b"\r")
            session.wait_for(b"Save failed:")
            assert "PRIVATE" in session.screen_text().splitlines()[-2], "failed save ended private mode"
            assert len(session.checkpoint()["buffers"]) == 1
            private_file = directory / "saved-private.txt"
            session.send(b"\x13" + str(private_file).encode() + b"\r")
            session.wait_until(lambda: session.file_matches(private_file, private_text))
            session.wait_until(lambda: "saved-private.txt" in session.screen_text().splitlines()[0] and "PRIVATE" not in session.screen_text().splitlines()[-2])
            # Further Ctrl+S writes the same file without another filename prompt.
            session.send(b"!\x13")
            saved_text = private_text + b"!"
            session.wait_until(lambda: session.file_matches(private_file, saved_text))
            session.wait_until(lambda: (data := session.checkpoint()) is not None and len(data["buffers"]) == 2
                               and data["buffers"][1]["text"] == saved_text.decode())
            # A different unsaved private tab still requires confirmation when hidden.
            hidden_private = b"HIDDEN_PRIVATE_UNSAVED_FIXTURE"
            session.send(b"\x10" + hidden_private)
            session.send(b"\x17")
            session.wait_for(b"Private text is not recovered")
            assert session.process.poll() is None
            session.send(b"\x1b[17~\x11")  # Hide private text, then request quit.
            session.wait_for(b"Private tabs will be lost")
            assert session.process.poll() is None, "hidden private tab was silently discarded"
            session.send(b"\x11")
            session.finish()
            assert len(session.checkpoint()["buffers"]) == 2
            assert hidden_private not in (private_state / "session.json").read_bytes()
            assert str(private_file).encode() in (private_state / "session.json").read_bytes()
        with Session(state=private_state) as session:
            session.wait_for(b"1/2")
            session.wait_for(b"public survives")
            session.send(b"\x1b[17~")
            session.wait_for(b"saved-private.txt")
            session.wait_for(private_text)
            session.send(b"\x11")
            session.finish()
        assert private_file.read_bytes() == saved_text, "saved private text must remain an ordinary file"

        private_only = directory / "private-only"
        with Session(state=private_only) as session:
            session.send(b"\x10PRIVATE_CRASH_FIXTURE\x1b[17~\x17")
            session.wait_until(lambda: (data := session.checkpoint()) is not None
                               and len(data["buffers"]) == 1 and data["buffers"][0]["text"] == "")
            assert b"PRIVATE_CRASH_FIXTURE" not in (private_only / "session.json").read_bytes()
            session.force_stop()
        with Session(state=private_only) as session:
            session.wait_for(b"1/1")
            assert not session.checkpoint()["buffers"][0]["text"]
            session.send(b"\x11")
            session.finish()

        corrupt = directory / "corrupt"
        corrupt.mkdir(mode=0o700)
        (corrupt / "session.json").write_bytes(b"{broken")
        with Session(state=corrupt, expect_ready=False) as session:
            session.failed_start(b"invalid or unsupported recovery snapshot")
        assert (corrupt / "session.json").read_bytes() == b"{broken"

        locked = directory / "locked"
        with Session(state=locked) as first_session:
            with Session(state=locked, expect_ready=False) as second_session:
                second_session.failed_start(b"another terminal editor is already using this session")
            first_session.send(b"still here\x11")
            first_session.finish()

        blocked = directory / "failed-save"
        with Session(state=blocked) as session:
            checkpoint = blocked / "session.json"
            checkpoint.mkdir()
            (checkpoint / "sentinel").write_text("keep")
            session.send(b"keep me\x11")
            session.wait_for(b"Ctrl+Q again quits")
            assert session.process.poll() is None, "failed flush silently quit"
            destination = directory / "rescued.txt"
            session.send(b"\x13")
            session.wait_for(b"Save as:")
            session.send(str(destination).encode() + b"\r")
            session.wait_until(lambda: session.file_matches(destination, b"keep me"))
            session.send(b"\x11\x11")
            session.finish()
        assert (checkpoint / "sentinel").read_text() == "keep"

    print(json.dumps({
        "real_pty_scenarios": 19,
        "mouse_scroll_no_cursor_move_no_checkpoint_write_click_edit_unicode_and_quiet_navigation": "passed",
        "smart_syntax_auto_search_pin_cancel_restart_and_private_exclusion": "passed",
        "syntax_paste_to_label_single_sample_ms": round(syntax_ms, 2),
        "tui_highlighted_single_sample_rss_kib": syntax_rss,
        "grouped_typing_pause_paste_navigation_deletion_and_save_boundary": "passed",
        "save_as_cancel_failure_confirmed_replace_and_restart": "passed",
        "utf8_crlf_bytes": "preserved",
        "terminal_restoration": "passed",
        "session_restart_and_force_stop_recovery": "passed",
        "private_save_conversion_cancellation_failure_and_unsaved_exclusion": "passed",
        "first_frame_single_sample_ms": round(startup, 2),
        "tui_single_sample_rss_kib": rss,
    }, indent=2))


if __name__ == "__main__":
    main()
