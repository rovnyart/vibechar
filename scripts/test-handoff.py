#!/usr/bin/env python3
"""Real PTY + agent CLI checks. Only synthetic data and isolated clipboards."""
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
model = runpy.run_path(str(ROOT / "scripts/test-terminal.py"))
Session, BINARY = model["Session"], model["BINARY"]
FIXTURE = "DROP_PTY_FIXTURE_日本語_👩‍💻\nsecond line"

def main():
    with tempfile.TemporaryDirectory(prefix="vc-drop-", dir="/tmp") as folder:
        folder = Path(folder)
        clipboard = folder / "clipboard"
        copy, paste = folder / "copy", folder / "paste"
        copy_program = f"#!{sys.executable}\nimport sys\nfrom pathlib import Path\nPath({str(clipboard)!r}).write_text(sys.stdin.read())\n"
        copy.write_text(copy_program)
        paste.write_text(f"#!{sys.executable}\nimport sys\nfrom pathlib import Path\nsys.stdout.write(Path({str(clipboard)!r}).read_text())\n")
        copy.chmod(0o700); paste.chmod(0o700)
        bridge = folder / "bridge"
        environment = {"VIBECHAR_COPY_COMMAND": str(copy), "VIBECHAR_PASTE_COMMAND": str(paste), "VIBECHAR_HANDOFF_DIR": str(bridge)}
        def reference():
            if not clipboard.exists(): return None
            text = clipboard.read_text()
            if not text.startswith("Use this local Vibechar Secret Drop"): return None
            assert FIXTURE not in text, "copied instruction exposed the value"
            match = re.search(r"vibechar://grant/[0-9a-f]{16}/[0-9a-f]{64}", text)
            return match.group() if match else None
        def use(ref, code, expected=0, name="TEST_TOKEN"):
            result = subprocess.run([str(BINARY), "run", ref, "--env", name, "--", sys.executable, "-c", code],
                                    env={"PATH": os.defpath, "VIBECHAR_HANDOFF_DIR": str(bridge), "EXPECTED": FIXTURE},
                                    capture_output=True, timeout=10)
            assert result.returncode == expected, "unexpected helper exit status"
            assert FIXTURE.encode() not in result.stdout + result.stderr, "helper disclosed the fixture"
            return result
        marker = folder / "must-not-start"
        no_child = f"from pathlib import Path; Path({str(marker)!r}).write_text('started')"
        state = folder / "state"
        with Session(state=state, extra_env=environment) as editor:
            editor.send(b"ordinary survives\x10\x1b[200~" + FIXTURE.encode() + b"\x1b[201~\x07")
            editor.wait_until(lambda: clipboard.exists())
            ref = reference(); assert ref
            exact = use(ref, "import os; print(os.environ['TEST_TOKEN']==os.environ['EXPECTED'])")
            assert exact.stdout == b"True\n" and not exact.stderr
            masked = use(ref, "import os,sys; print(os.environ['TEST_TOKEN']); print(os.environ['TEST_TOKEN'],file=sys.stderr); sys.exit(7)", expected=7)
            assert masked.stdout == b"[REDACTED]\n" and masked.stderr == b"[REDACTED]\n"
            wrong = ref[:-1] + ("1" if ref[-1] == "0" else "0")
            use(wrong, no_child, expected=1)
            use(ref, no_child, expected=1, name="9INVALID")
            assert not marker.exists()
            copy.write_text(f"#!{sys.executable}\nraise SystemExit(1)\n")
            editor.send(b"\x07")
            editor.wait_for(b"Could not prepare Secret Drop")
            use(ref, no_child, expected=1); assert not marker.exists()
            copy.write_text(copy_program)
            editor.send(b"\x07")
            editor.wait_until(lambda: reference() != ref)
            ref = reference()
            editor.wait_until(lambda: (data := editor.checkpoint()) is not None and data["buffers"][0]["text"] == "ordinary survives")
            snapshot = (state / "session.json").read_bytes()
            assert len(editor.checkpoint()["buffers"]) == 1
            assert FIXTURE.encode() not in snapshot and ref.encode() not in snapshot
            editor.send(b"\x1b[20~")  # F9 Stop.
            editor.wait_for(b"All agent access closed")
            use(ref, no_child, expected=1); assert not marker.exists()
            editor.send(b"\x07")
            editor.wait_until(lambda: reference() != ref)
            ref = reference()
            editor.send(b"!")
            # Wait for edit acknowledgement before checking the old reference.
            editor.wait_until(lambda: "second line!" in editor.screen_text())
            use(ref, no_child, expected=1); assert not marker.exists()
            editor.send(b"\x1a\x07")  # Undo preserves private text, but opens a fresh grant.
            editor.wait_until(lambda: reference() != ref)
            last = reference()
            use(last, "import os; print(os.environ['TEST_TOKEN']==os.environ['EXPECTED'])")
            editor.send(b"\x11\x11"); editor.finish()
        use(last, no_child, expected=1); assert not marker.exists()
        assert not list(bridge.glob("*.sock")), "editor quit left a live socket"
        with Session(state=state, extra_env=environment) as editor:
            editor.wait_for(b"ordinary survives")
            assert len(editor.checkpoint()["buffers"]) == 1
            editor.send(b"\x11"); editor.finish()

        clipboard.write_text(FIXTURE)
        with Session(state=folder / "fast-state", extra_env=environment) as editor:
            editor.send(b"\x1b[19~")  # F8 Paste Secret for Agent.
            editor.wait_until(lambda: reference() is not None)
            fast = reference()
            assert use(fast, "import os; print(os.environ['TEST_TOKEN']==os.environ['EXPECTED'])").stdout == b"True\n"
            editor.send(b"\x1b[19~")
            editor.wait_for(b"Clipboard already contains instructions")
            editor.send(b"\x13")
            editor.wait_for(b"Save as (ends private mode):")
            editor.send(b"\x1b")
            editor.wait_until(lambda: "Save as" not in editor.screen_text())
            assert use(fast, "import os; print(bool(os.environ['TEST_TOKEN']))").stdout == b"True\n"
            editor.send(b"\x13" + str(folder / "missing" / "file.txt").encode() + b"\r")
            editor.wait_for(b"Save failed:")
            assert use(fast, "import os; print(bool(os.environ['TEST_TOKEN']))").stdout == b"True\n"
            saved = folder / "saved.txt"
            editor.send(b"\x13" + str(saved).encode() + b"\r")
            editor.wait_until(lambda: saved.exists() and saved.read_text() == FIXTURE)
            editor.wait_until(lambda: "saved.txt" in editor.screen_text().splitlines()[0] and "PRIVATE" not in editor.screen_text().splitlines()[-2])
            use(fast, no_child, expected=1); assert not marker.exists()
            editor.send(b"\x11"); editor.finish()
        use(fast, no_child, expected=1); assert not marker.exists()
        assert not list(bridge.glob("*.sock"))
    print(json.dumps({"secret_drop_pty_and_cli": "passed", "exact_injection_reuse_masking_exit_status": "passed", "wrong_revoked_edited_quit_no_child": "passed", "clipboard_fast_path_copy_failure_and_recovery_exclusion": "passed", "save_conversion_revokes_only_after_success": "passed"}))

if __name__ == "__main__": main()
