#!/usr/bin/env python3
"""Exercise release publication against a disposable filesystem and fake GitHub."""
import base64
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
        self.root = Path(self.temp.name).resolve()
        (self.root / "scripts").mkdir()
        shutil.copy2(Path(__file__).with_name("publish-release.py"), self.root / "scripts/publish-release.py")
        shutil.copy2(Path(__file__).with_name("versioning.py"), self.root / "scripts/versioning.py")
        (self.root / "Cargo.toml").write_text('[workspace.package]\nversion = "1.0.0"\n')
        (self.root / "CHANGELOG.md").write_text('# Changelog\n\n## [1.0.0] — 2026-11-17\n\n### Added\n\n- A real editor.\n')
        self.folder = self.root / "dist/release"
        self.folder.mkdir(parents=True)
        self.calls = self.root / "calls.jsonl"
        gh = self.root / "gh"
        gh.write_text(f"#!{sys.executable}\n" +
            "import json,os,pathlib,sys\n"
            f"calls=pathlib.Path({str(self.calls)!r})\n"
            "with calls.open('a') as output: output.write(json.dumps(sys.argv[1:])+'\\n')\n"
            "if sys.argv[1:3]==['release','view']:\n"
            " if not os.environ.get('PREVIEW_EXISTS') and not os.environ.get('STABLE_EXISTS'): sys.exit(1)\n"
            " print(json.dumps({'isPrerelease':not bool(os.environ.get('STABLE_EXISTS')),'isDraft':False}))\n"
            "if sys.argv[1]=='api': print(os.environ.get('PUBLISHED_REVISION','fixture-revision'))\n")
        gh.chmod(0o755)
        self.environment = {**os.environ, "PATH": str(self.root) + os.pathsep + os.defpath, "GITHUB_SHA": "fixture-revision"}
        self.environment.pop("PREVIEW_EXISTS", None)
        self.environment.pop("STABLE_EXISTS", None)
        self.environment.pop("RELEASE_REVISION", None)
        self.asset("macos", "arm64")
        self.asset("linux", "x86_64")
        signature = base64.b64encode(b'x' * 64).decode()
        (self.folder / 'appcast.xml').write_text(f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>1.0.0</sparkle:version><enclosure url="https://github.com/rovnyart/vibechar/releases/download/v1.0.0/vibechar-macos-arm64.zip" length="10" sparkle:edSignature="{signature}" /></item></channel></rss>')

    def asset(self, platform, arch):
        name = f"vibechar-{platform}-{arch}." + ("zip" if platform == "macos" else "tar.gz")
        content = (platform + arch).encode()
        (self.folder / name).write_bytes(content)
        info = dict(asset=name, platform=platform, arch=arch, revision="fixture-revision",
                    notarized=platform == "macos", version="1.0.0", ed_signature=base64.b64encode(b"x" * 64).decode(), sha256=hashlib.sha256(content).hexdigest())
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
        self.assertIn("Vibechar 1.0.0", create)
        self.assertIn("v1.0.0", create)
        self.assertIn(str(self.folder / 'appcast.xml'), create)
        self.assertIn("A real editor.", (self.folder / "release-notes.md").read_text())

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

    def test_published_same_revision_preserves_assets(self):
        self.environment['STABLE_EXISTS'] = '1'
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(args[1] in ('create','edit','upload') for args in self.commands() if args[0] == 'release'))

    def test_published_different_revision_is_immutable(self):
        self.environment.update(STABLE_EXISTS='1', PUBLISHED_REVISION='another-revision')
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertFalse(any(args[1] in ('create','edit','upload') for args in self.commands() if args[0] == 'release'))

    def test_version_mismatch_is_rejected_before_github(self):
        path = self.folder / 'vibechar-macos-arm64.zip.json'
        info = json.loads(path.read_text()); info['version'] = '1.1.0'; path.write_text(json.dumps(info))
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_unpublished_tag_can_only_move_forward(self):
        self.environment.update(PREVIEW_EXISTS='1', PUBLISHED_REVISION='old-draft-revision')
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        update = next(args for args in self.commands() if args[:3] == ['api','--method','PATCH'])
        self.assertIn('sha=fixture-revision', update)
        self.assertIn('force=false', update)

    def test_bad_update_feed_is_rejected_before_github(self):
        path = self.folder / 'appcast.xml'
        for old,new in [('>1.0.0<','>0.9.0<'),('/v1.0.0/','/v9.0.0/'),('length="10"','length="99"')]:
            original = path.read_text(); path.write_text(original.replace(old,new))
            self.assertNotEqual(self.run_release().returncode, 0)
            self.assertFalse(self.calls.exists())
            path.write_text(original)

    def test_unsigned_update_is_rejected_before_github(self):
        path = self.folder / 'vibechar-macos-arm64.zip.json'
        info = json.loads(path.read_text()); info.pop('ed_signature'); path.write_text(json.dumps(info))
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
