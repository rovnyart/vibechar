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
    def __init__(self, *arguments, piped=None):
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
            env={**os.environ, "TERM": "xterm-256color"},
        )
        if piped is not None:
            self.process.stdin.write(piped)
            self.process.stdin.close()
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
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        os.close(self.master)
        os.close(self.slave)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def main():
    expected = "Привет 👩‍💻\r\nline\r\n".encode()
    with tempfile.TemporaryDirectory(prefix="vibechar-test-") as directory:
        path = Path(directory) / "sample.txt"
        with Session(path) as session:
            startup = session.first_frame_ms
            session.send(b"\x1b[200~" + expected + b"\x1b[201~")
            session.wait_for("Привет".encode())
            session.send(b"\x1a\x19\x13")  # undo, redo, save
            session.wait_for(b"Saved")
            rss = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(session.process.pid)]))
            session.send(b"\x11")
            session.finish()
        assert path.read_bytes() == expected, "paste/undo/redo/save changed UTF-8 or CRLF"

        with Session(path) as session:
            session.send(b"!\x11")
            session.wait_for(b"Unsaved")
            assert session.process.poll() is None, "unsaved text was discarded"
            session.send(b"\x1a\x11")  # undo to saved state, quit
            session.finish()
        assert path.read_bytes() == expected

        with Session(piped=expected) as session:
            session.send(b"\x11")
            session.wait_for(b"Unsaved")
            session.send(b"\x11")
            session.finish()

        with Session() as session:
            session.send(b"scratch\x13")
            session.wait_for(b"Save as:")
            destination = Path(directory) / "scratch.txt"
            session.send(str(destination).encode() + b"\r")
            session.wait_for(b"Saved")
            session.send(b"\x11")
            session.finish()
        assert destination.read_text() == "scratch"

        with Session() as session:
            session.send(b"first\x0esecond\x1b[17~")  # Ctrl+N, then F6 back to first
            session.wait_for(b"1/2")
            first = Path(directory) / "first.txt"
            session.send(b"!\x13")
            session.wait_for(b"Save as:")
            session.send(str(first).encode() + b"\r")
            session.wait_for(b"Saved")
            assert first.read_text() == "first!", "switching lost the first buffer's cursor or text"
            session.send(b"\x11")
            session.wait_for(b"Unsaved")
            assert session.process.poll() is None, "quit ignored the hidden unsaved buffer"
            session.send(b"\x1b[17~\x13")
            second = Path(directory) / "second.txt"
            session.wait_for(b"Save as:")
            session.send(str(second).encode() + b"\r")
            session.wait_for(str(second.name).encode())
            session.send(b"\x11")
            session.finish()
        assert second.read_text() == "second", "saved a different buffer's text"

        path.chmod(0o444)
        try:
            with Session(path) as session:
                session.send(b"!\x13")
                session.wait_for(b"Save failed")
                assert path.read_bytes() == expected, "failed save changed destination"
                session.send(b"\x11\x11")
                session.finish()
        finally:
            path.chmod(0o644)

    print(json.dumps({
        "real_pty_scenarios": 6,
        "utf8_crlf_bytes": "preserved",
        "terminal_restoration": "passed",
        "first_frame_single_sample_ms": round(startup, 2),
        "tui_single_sample_rss_kib": rss,
    }, indent=2))


if __name__ == "__main__":
    main()
