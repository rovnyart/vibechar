#!/usr/bin/env python3
"""Install a real Ed25519-signed archive and relaunch on a disposable CI Mac.

The bootstrap is the candidate app with an older version and a loopback feed.
The downloaded replacement is the unmodified, signed and notarized release ZIP.
Never run this against a developer's session.
"""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def app_pids(executable):
    result = []
    for line in run('ps', '-axo', 'pid=,command=').splitlines():
        pid, _, command = line.strip().partition(' ')
        if command.strip() == str(executable) or command.strip().startswith(str(executable) + ' '):
            result.append(int(pid))
    return result


def main():
    assert sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true', 'Disposable GitHub Mac runner required'
    recovery = Path.home() / 'Library/Application Support/dev.vibechar.app'
    assert not recovery.exists(), 'Refusing to use an existing editor profile'
    release = ROOT / 'dist/release'
    info = json.loads((release / 'vibechar-macos-arm64.zip.json').read_text())
    expected = info['version']
    assert info['notarized']
    process = server = None
    with tempfile.TemporaryDirectory(prefix='vibechar-update-install-') as temporary:
        stage = Path(temporary)
        installed = stage / 'Installed/Vibechar.app'
        executable = installed / 'Contents/MacOS/Vibechar'
        # A normal app location, outside Downloads/translocation and the source bundle.
        installed.parent.mkdir()
        run('ditto', str(ROOT / 'dist/Vibechar.app'), str(installed))
        class Handler(SimpleHTTPRequestHandler):
            def log_message(self, *args): pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=str(release)))
        base = f'http://127.0.0.1:{server.server_port}'
        feed = ET.parse(release / 'appcast.xml')
        feed.find('./channel/item/enclosure').set('url', base + '/' + info['asset'])
        feed_path = release / 'test-appcast.xml'
        feed.write(feed_path, encoding='utf-8', xml_declaration=True)
        plist_path = installed / 'Contents/Info.plist'
        plist = plistlib.loads(plist_path.read_bytes())
        plist.update(CFBundleVersion='0.0.1', CFBundleShortVersionString='0.0.1', SUFeedURL=base + '/test-appcast.xml',
                     NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
        plist_path.write_bytes(plistlib.dumps(plist))
        # The modified bootstrap is ad hoc; the downloaded archive stays untouched.
        run('codesign', '--force', '--sign', '-', '--options', '0x0', str(installed))
        log_path = stage / 'update.log'
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with log_path.open('w') as log:
                process = subprocess.Popen([str(executable), '--smoke-update-install'], stdout=log, stderr=log,
                    env={**os.environ, 'VIBECHAR_TEST_UPDATE_FEED': base + '/test-appcast.xml'})
                deadline = time.monotonic() + 180
                while time.monotonic() < deadline:
                    current = plistlib.loads(plist_path.read_bytes()) if plist_path.exists() else {}
                    relaunched = [pid for pid in app_pids(executable) if pid != process.pid]
                    if current.get('CFBundleVersion') == expected and relaunched:
                        # New process must survive startup and restore the checkpoint.
                        time.sleep(2)
                        assert set(relaunched) & set(app_pids(executable)), 'Relaunched app exited'
                        checkpoint = (recovery / 'session.json').read_text()
                        assert 'UPDATE_RECOVERY_FIXTURE' in checkpoint, 'Scratch checkpoint lost'
                        for helper in ('vc', 'vibechar'):
                            assert run(str(installed / 'Contents/Helpers' / helper), '--version') == f'{helper} {expected}'
                        run('codesign', '--verify', '--deep', '--strict', str(installed))
                        run('xcrun', 'stapler', 'validate', str(installed))
                        run('spctl', '--assess', '--type', 'execute', str(installed))
                        actual = plistlib.loads(plist_path.read_bytes())
                        assert actual['SUPublicEDKey'] == (ROOT / 'apps/macos/UpdaterPublicKey.txt').read_text().strip()
                        assert actual['SUFeedURL'].startswith('https://github.com/'), 'Test feed leaked into release'
                        print(f'Real Sparkle update passed: 0.0.1 → {expected}, relaunch, scratch recovery, both helpers and notarized replacement')
                        return
                    if process.poll() is not None and process.returncode != 0:
                        raise AssertionError(f'Bootstrap exited: {process.returncode}')
                    time.sleep(1)
                raise AssertionError('Timed out waiting for signed replacement and relaunch')
        except Exception:
            print(log_path.read_text(), file=sys.stderr)
            raise
        finally:
            # Kill only processes inside our own temporary app, never an arbitrary Vibechar.
            for pid in app_pids(executable):
                try: os.kill(pid, signal.SIGTERM)
                except ProcessLookupError: pass
            if process:
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            server.shutdown(); server.server_close()
            feed_path.unlink(missing_ok=True)


if __name__ == '__main__': main()
