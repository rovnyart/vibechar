#!/usr/bin/env python3
"""Install an actual release archive into disposable accounts; stub downloads only."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
asset = Path(sys.argv[1]).resolve()
assert asset.is_file()
with tempfile.TemporaryDirectory(prefix="vibechar-install-qa-") as temp:
    work = Path(temp)
    fixture = work / "downloads"
    fixture.mkdir()
    shutil.copy2(asset, fixture / asset.name)
    digest = hashlib.sha256(asset.read_bytes()).hexdigest()
    sums = fixture / "SHA256SUMS"
    sums.write_text(f"{digest}  {asset.name}\n")
    tools = work / "tools"
    tools.mkdir()
    curl = tools / "curl"
    curl.write_text(f"#!{sys.executable}\n" +
        "import pathlib,shutil,sys\n"
        f"fixture=pathlib.Path({str(fixture)!r})\n"
        "args=sys.argv[1:]\n"
        "url=next(x for x in args if x.startswith('https://'))\n"
        "output=args[args.index('-o')+1]\n"
        "shutil.copyfile(fixture/url.rsplit('/',1)[-1],output)\n")
    curl.chmod(0o755)
    home = work / "home"
    home.mkdir()
    environment = {**os.environ,"HOME":str(home),"VIBECHAR_APP_DIR":str(home/"Applications"),"SHELL":"/bin/zsh" if sys.platform == "darwin" else "/bin/bash",
                   "PATH":str(tools)+os.pathsep+os.defpath+":/usr/sbin:/sbin", "VIBECHAR_VERSION":"fixture-build"}
    for _ in range(2):
        result = subprocess.run(["sh",str(root/"install.sh")],env=environment,capture_output=True,timeout=120)
        assert result.returncode == 0, result.stdout.decode()+result.stderr.decode()
    vc = home / ".local/bin/vc"
    assert vc.is_symlink()
    assert subprocess.check_output([vc,"--version"],env=environment).startswith(b"vc ")
    assert subprocess.run([vc,"-t","--help"],env=environment,capture_output=True).returncode == 0
    if sys.platform == "darwin":
        app = home / "Applications/Vibechar.app"
        subprocess.run(["codesign","--verify","--deep","--strict",str(app)],check=True,capture_output=True)
        smoke = subprocess.run([str(app/"Contents/MacOS/Vibechar"),"--smoke-launcher"],capture_output=True)
        assert smoke.returncode == 0, smoke.stderr.decode(errors="replace")[:4000]
    # Tampering must fail before any app/PATH directory is created.
    bad_home = work / "tampered-home"
    bad_home.mkdir()
    sums.write_text(f"{'0'*64}  {asset.name}\n")
    bad = subprocess.run(["sh",str(root/"install.sh")],env={**environment,"HOME":str(bad_home),"VIBECHAR_APP_DIR":str(bad_home/"Applications")},capture_output=True,timeout=60)
    assert bad.returncode != 0 and not (bad_home/".local").exists() and not (bad_home/"Applications").exists()
    # An unsupported Mac must fail before downloading or touching its home.
    uname = tools / "uname"
    uname.write_text("#!/bin/sh\ncase \"$1\" in -s) echo Darwin ;; -m) echo x86_64 ;; *) exit 1 ;; esac\n")
    uname.chmod(0o755)
    unsupported_home = work / "unsupported-home"
    unsupported_home.mkdir()
    unsupported = subprocess.run(["sh",str(root/"install.sh")],env={**environment,"HOME":str(unsupported_home),"VIBECHAR_APP_DIR":str(unsupported_home/"Applications")},capture_output=True,timeout=15)
    assert unsupported.returncode != 0 and b"requires Apple Silicon" in unsupported.stderr
    assert not list(unsupported_home.iterdir())
print(json.dumps({"installer":"passed","real_archive_fresh_install_reinstall_cli_native_smoke_and_checksum_rejection":True,"unsupported_mac_rejected_before_install":True}))
