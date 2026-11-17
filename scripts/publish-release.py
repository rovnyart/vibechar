#!/usr/bin/env python3
"""Publish checked build artifacts; stable Mac downloads require notarization."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
folder = root / "dist/release"
revision = os.environ["GITHUB_SHA"]
manifests = [json.loads(p.read_text()) for p in sorted(folder.glob("*.json"))]
expected = {("macos", "arm64"), ("linux", "x86_64")}
assert {(m["platform"], m["arch"]) for m in manifests} == expected, "Missing or duplicate platform artifact"
assert len(manifests) == len(expected)
checksums = []
for info in manifests:
    assert info["revision"] == revision, "Artifact revision mismatch"
    path = folder / info["asset"]
    assert path.parent == folder and path.is_file()
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    assert digest == info["sha256"], "Artifact checksum mismatch"
    checksums.append(f"{digest}  {path.name}\n")
(folder / "SHA256SUMS").write_text("".join(sorted(checksums)))
stable = all(m["notarized"] for m in manifests if m["platform"] == "macos")
notes = folder / "release-notes.md"
notes.write_text(f"Built from `{revision}`.\n\n"
    + ("The Mac build is Developer ID signed and Apple notarized. The Mac app and terminal client are included.\n" if stable else
       "Preview build: Mac signing is not configured yet. Normal installation requires a signed, notarized release.\n")
    + "\nmacOS 14+ (Apple Silicon / arm64); Linux x86_64 terminal client.\n\n"
      "```sh\ncurl -fsSL https://raw.githubusercontent.com/rovnyart/vibechar/main/install.sh | sh\n```\n\n"
      "`vc file.txt` opens the Mac app; `vc -t file.txt` opens the terminal client.\n")
tag = "build-" + revision[:12]
command = ["gh", "release", "create", tag, "--repo", "rovnyart/vibechar", "--target", revision,
           "--title", "Vibechar · " + revision[:7], "--notes-file", str(notes), "--draft"]
if not stable:
    command.append("--prerelease")
assets = [folder / "SHA256SUMS"]
for info in manifests:
    assets.extend([folder / info["asset"], folder / (info["asset"] + ".json")])
assert all(path.is_file() for path in assets), "Missing release file"
exists = subprocess.run(["gh", "release", "view", tag, "--repo", "rovnyart/vibechar"],capture_output=True).returncode == 0
if exists:
    # A manually notarized first release must never be downgraded by a CI rerun.
    current = json.loads(subprocess.check_output(["gh","release","view",tag,"--repo","rovnyart/vibechar","--json","isPrerelease,isDraft"]))
    if current["isPrerelease"] or current["isDraft"]:
        subprocess.run(["gh","release","upload",tag,"--repo","rovnyart/vibechar","--clobber",*map(str,assets)],check=True)
        edit = ["gh","release","edit",tag,"--repo","rovnyart/vibechar","--draft=false","--prerelease="+str(not stable).lower(),"--notes-file",str(notes)]
        if stable: edit.append("--latest")
        subprocess.run(edit,check=True)
else:
    subprocess.run([*command,*map(str,assets)],check=True)
    edit = ["gh","release","edit",tag,"--repo","rovnyart/vibechar","--draft=false"]
    if stable: edit.append("--latest")
    subprocess.run(edit,check=True)
