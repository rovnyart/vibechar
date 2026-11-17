#!/usr/bin/env python3
"""Exercise release publication against a disposable filesystem and fake GitHub."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vibechar-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copy2(Path(__file__).with_name("publish-release.py"), self.root / "scripts/publish-release.py")
        self.folder = self.root / "dist/release"
        self.folder.mkdir(parents=True)
        self.calls = self.root / "calls.jsonl"
        gh = self.root / "gh"
        gh.write_text(f"#!{sys.executable}\n" +
            "import json,os,pathlib,sys\n"
            f"calls=pathlib.Path({str(self.calls)!r})\n"
            "with calls.open('a') as output: output.write(json.dumps(sys.argv[1:])+'\\n')\n"
            "if sys.argv[1:3]==['release','view']:\n"
            " if not os.environ.get('PREVIEW_EXISTS'): sys.exit(1)\n"
            " print(json.dumps({'isPrerelease':True,'isDraft':False}))\n")
        gh.chmod(0o755)
        self.environment = {**os.environ, "PATH": str(self.root) + os.pathsep + os.defpath, "GITHUB_SHA": "fixture-revision"}
        self.environment.pop("PREVIEW_EXISTS", None)
        self.asset("macos", "arm64")
        self.asset("linux", "x86_64")

    def asset(self, platform, arch):
        name = f"vibechar-{platform}-{arch}." + ("zip" if platform == "macos" else "tar.gz")
        content = (platform + arch).encode()
        (self.folder / name).write_bytes(content)
        info = dict(asset=name, platform=platform, arch=arch, revision="fixture-revision",
                    notarized=platform == "macos", sha256=hashlib.sha256(content).hexdigest())
        (self.folder / (name + ".json")).write_text(json.dumps(info))

    def run_release(self):
        return subprocess.run([sys.executable, str(self.root / "scripts/publish-release.py")],
                              env=self.environment, capture_output=True, timeout=15)

    def commands(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_signed_mac_and_linux_publish_with_only_declared_assets(self):
        stray = self.folder / "obsolete-mac-build.zip"
        stray.write_text("not a declared release asset")
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(args for args in self.commands() if args[:2] == ["release", "create"])
        self.assertNotIn(str(stray), create)
        self.assertNotIn("--prerelease", create)
        self.assertEqual(len((self.folder / "SHA256SUMS").read_text().splitlines()), 2)
        self.assertIn("Apple Silicon / arm64", (self.folder / "release-notes.md").read_text())

    def test_extra_mac_architecture_is_rejected_before_github(self):
        self.asset("macos", "unsupported")
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_missing_mac_is_rejected_before_github(self):
        (self.folder / "vibechar-macos-arm64.zip.json").unlink()
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_tampered_archive_is_rejected_before_github(self):
        (self.folder / "vibechar-macos-arm64.zip").write_text("tampered")
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_preview_promotion_updates_the_release_description(self):
        self.environment["PREVIEW_EXISTS"] = "1"
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        edit = next(args for args in self.commands() if args[:2] == ["release", "edit"])
        self.assertIn("--notes-file", edit)
        self.assertIn("--prerelease=false", edit)
        self.assertIn("--latest", edit)


if __name__ == "__main__":
    unittest.main()
