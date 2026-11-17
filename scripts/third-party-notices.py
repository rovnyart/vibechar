#!/usr/bin/env python3
"""Collect the resolved Rust dependencies' original license/notice files."""
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
cargo = ["bash", str(root / "scripts/cargo.sh")]
host = next(line.split(": ", 1)[1] for line in subprocess.check_output([*cargo, "-vV"]).decode().splitlines() if line.startswith("host: "))
metadata = json.loads(subprocess.check_output([*cargo, "metadata", "--locked", "--format-version", "1", "--filter-platform", host]))
ours = set(metadata["workspace_members"])
active = {node["id"] for node in metadata["resolve"]["nodes"]}
text = ["Vibechar — Rust dependency notices\n\nOriginal dependency license and notice texts from the locked source distribution.\nSyntax definitions carry additional notices in Syntax Notices.md.\n\n"]
for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
    if package["id"] in ours or package["id"] not in active:
        continue
    directory = Path(package["manifest_path"]).parent
    text.append(f"\n{'=' * 72}\n{package['name']} {package['version']}\nLicense: {package.get('license') or 'See upstream notices'}\n")
    files = sorted({p for pattern in ("LICENSE*", "COPYING*", "NOTICE*") for p in directory.glob(pattern) if p.is_file()})
    if package.get("license_file"):
        path = directory / package["license_file"]
        if path.is_file() and path not in files:
            files.append(path)
    if not files:
        raise SystemExit("No license text found for " + package["name"])
    for path in files:
        text.extend(["\n--- " + path.name + " ---\n", path.read_text(errors="replace"), "\n"])
destination = Path(sys.argv[1])
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text("".join(text))
print("Collected Rust dependency notices: " + str(destination))
