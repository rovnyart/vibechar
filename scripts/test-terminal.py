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
    def __init__(self, *arguments, piped=None, state=None, expect_ready=True):
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
            env={**os.environ, "TERM": "xterm-256color", "VIBECHAR_STATE_DIR": str(self.state)},
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
            session.wait_for(b"Save private copy as:")
            private_copy = directory / "explicit-private-copy.txt"
            session.send(str(private_copy).encode() + b"\r")
            session.wait_until(lambda: session.file_matches(private_copy, private_text))
            session.send(b"\x17")
            session.wait_for(b"Private text is not recovered")
            assert session.process.poll() is None
            session.send(b"\x1b[17~\x11")  # Hide private text, then request quit.
            session.wait_for(b"Private tabs will be lost")
            assert session.process.poll() is None, "hidden private tab was silently discarded"
            session.send(b"\x11")
            session.finish()
            assert len(session.checkpoint()["buffers"]) == 1
            assert private_text not in (private_state / "session.json").read_bytes()
            assert str(private_copy).encode() not in (private_state / "session.json").read_bytes()
        with Session(state=private_state) as session:
            session.wait_for(b"1/1")
            session.wait_for(b"public survives")
            session.send(b"\x11")
            session.finish()
        assert private_copy.read_bytes() == private_text, "explicitly saved file must remain"

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
        "real_pty_scenarios": 12,
        "utf8_crlf_bytes": "preserved",
        "terminal_restoration": "passed",
        "session_restart_and_force_stop_recovery": "passed",
        "private_background_copy_quit_and_crash_exclusion": "passed",
        "first_frame_single_sample_ms": round(startup, 2),
        "tui_single_sample_rss_kib": rss,
    }, indent=2))


if __name__ == "__main__":
    main()
