#!/bin/bash
set -euo pipefail
case "$(uname -m)" in
  arm64|aarch64) ;;
  *) echo 'Vibechar for macOS requires Apple Silicon (arm64).' >&2; exit 1 ;;
esac
root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$root/scripts/cargo.sh" build --release -p vibechar-bridge -p vibechar -p vc
swift build --package-path "$root/apps/macos" -c release \
  -Xlinker -L -Xlinker "$root/target/release"
app="$root/dist/Vibechar.app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Helpers"
mkdir -p "$app/Contents/Resources"
bash "$root/scripts/build-icon.sh" "$app/Contents/Resources/AppIcon.icns"
cp "$root/docs/syntax-licenses.md" "$app/Contents/Resources/Syntax Notices.md"
cp "$root/LICENSE" "$app/Contents/Resources/LICENSE.txt"
python3 "$root/scripts/third-party-notices.py" "$app/Contents/Resources/Third Party Notices.txt"
python3 "$root/scripts/embed-sparkle.py" "$app"
cp "$root/target/release/vibechar" "$app/Contents/Helpers/.vibechar-next-$$"
mv -f "$app/Contents/Helpers/.vibechar-next-$$" "$app/Contents/Helpers/vibechar"
cp "$root/target/release/vc" "$app/Contents/Helpers/.vc-next-$$"
mv -f "$app/Contents/Helpers/.vc-next-$$" "$app/Contents/Helpers/vc"
identity="${VIBECHAR_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | sed -n 's/.*\([A-F0-9]\{40\}\) "Developer ID Application:.*$/\1/p' | head -1)"
fi
next_binary="$app/Contents/MacOS/.Vibechar-next-$$"
trap 'rm -f "$next_binary"' EXIT
cp "$root/apps/macos/.build/release/Vibechar" "$next_binary"
mv -f "$next_binary" "$app/Contents/MacOS/Vibechar"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Vibechar</string>
<key>CFBundleIdentifier</key><string>dev.vibechar.app</string>
<key>CFBundleName</key><string>vibechar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>dev.vibechar.open</string>
<key>CFBundleURLSchemes</key><array><string>vibechar</string></array>
</dict></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
python3 - "$root" "$app/Contents/Info.plist" <<'PYPLIST'
import base64,pathlib,plistlib,sys
root=pathlib.Path(sys.argv[1]);sys.path.insert(0,str(root/'scripts'))
from versioning import version
path=pathlib.Path(sys.argv[2]);info=plistlib.loads(path.read_bytes())
key=(root/'apps/macos/UpdaterPublicKey.txt').read_text().strip()
assert len(base64.b64decode(key,validate=True))==32
info.update(CFBundleShortVersionString=str(version(root)),CFBundleVersion=str(version(root)),
    SUFeedURL='https://github.com/rovnyart/vibechar/releases/latest/download/appcast.xml',
    SUPublicEDKey=key,SUEnableAutomaticChecks=True,SUAutomaticallyUpdate=False,
    SUScheduledCheckInterval=21600,SUEnableSystemProfiling=False,SUVerifyUpdateBeforeExtraction=True)
path.write_bytes(plistlib.dumps(info))
PYPLIST
bash "$root/scripts/sign-mac.sh" "$app" "${identity:--}"
touch "$app"
# Each AI UI suite owns its own AppKit lifecycle and outstanding callbacks.
# Bound every process so a stuck native dialog cannot hide inside a 45-min job.
python3 - "$app/Contents/MacOS/Vibechar" <<'PYTEST'
import subprocess, sys
for arguments in [
    ["--smoke-test"], ["--smoke-ai-settings"], ["--smoke-rewrite"],
    ["--smoke-examples"], ["--smoke-recipes"], ["--smoke-updates"],
    ["--smoke-first-presentation", "-AppleShowScrollBars", "Always"],
    ["--smoke-editing", "-AppleShowScrollBars", "Always"],
]:
    print("Native suite: " + " ".join(arguments), flush=True)
    subprocess.run([sys.argv[1], *arguments], check=True, timeout=180)
PYTEST
printf 'Development app: %s\n' "$app"
