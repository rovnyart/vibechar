#!/usr/bin/env python3
"""Exercise vc with an isolated HOME and real terminal; never touch the user's PATH."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
VC = ROOT / "target/release/vc"
Session = runpy.run_path(str(ROOT / "scripts/test-terminal.py"))["Session"]

with tempfile.TemporaryDirectory(prefix="vibechar-launcher-") as temp:
    home = Path(temp)
    environment = {**os.environ, "HOME": str(home), "SHELL": "/bin/zsh"}
    (home / ".zshrc").write_text("export KEEP_THIS=yes\n")
    for _ in range(2):
        result = subprocess.run([VC, "--install"], env=environment, capture_output=True, check=True)
        assert b"Installed" in result.stdout
    link = home / ".local/bin/vc"
    assert link.resolve() == VC.resolve()
    content = (home / ".zshrc").read_text()
    assert content.startswith("export KEEP_THIS=yes\n") and content.count("# Vibechar command") == 1
    assert subprocess.check_output([link, "--version"], env=environment).startswith(b"vc ")
    assert b"--terminal" in subprocess.check_output([link, "--help"], env=environment)
    link.unlink(); link.write_text("other program")
    result = subprocess.run([VC, "--install"], env=environment, capture_output=True)
    assert result.returncode != 0 and link.read_text() == "other program"
    file = home / "я spaces &.txt"
    file.write_text("from vc\n")
    with Session("--terminal", file, binary=VC) as editor:
        editor.wait_for(b"from vc")
        editor.send(b"\x13\x11")
        editor.finish()
        assert editor.process.returncode == 0 and file.read_text() == "from vc\n"
    with Session("-t", piped=b"piped via vc", binary=VC) as editor:
        editor.wait_for(b"piped via vc")
        editor.send(b"\x11")
        editor.finish()
        assert editor.process.returncode == 0
print(json.dumps({"vc_real_pty_scenarios": 2, "isolated_home_path_install_idempotence_collision_unicode_and_pipe": "passed"}))
