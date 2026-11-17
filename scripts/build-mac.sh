#!/bin/bash
set -euo pipefail
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
cp "$root/target/release/vibechar" "$app/Contents/Helpers/.vibechar-next-$$"
mv -f "$app/Contents/Helpers/.vibechar-next-$$" "$app/Contents/Helpers/vibechar"
cp "$root/target/release/vc" "$app/Contents/Helpers/.vc-next-$$"
mv -f "$app/Contents/Helpers/.vc-next-$$" "$app/Contents/Helpers/vc"
identity="${VIBECHAR_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | sed -n 's/.*\([A-F0-9]\{40\}\) "Developer ID Application:.*$/\1/p' | head -1)"
fi
sign_args=(--force --sign "${identity:--}")
if [[ -n "$identity" && "$identity" != - ]]; then sign_args+=(--options runtime --timestamp); fi
codesign "${sign_args[@]}" "$app/Contents/Helpers/vibechar"
codesign "${sign_args[@]}" "$app/Contents/Helpers/vc"
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
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>dev.vibechar.open</string>
<key>CFBundleURLSchemes</key><array><string>vibechar</string></array>
</dict></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign "${sign_args[@]}" "$app"
touch "$app"
"$app/Contents/MacOS/Vibechar" --smoke-test
"$app/Contents/MacOS/Vibechar" --smoke-first-presentation -AppleShowScrollBars Always
"$app/Contents/MacOS/Vibechar" --smoke-editing -AppleShowScrollBars Always
printf 'Development app: %s\n' "$app"
