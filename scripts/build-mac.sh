#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$root/scripts/cargo.sh" build --release -p vibechar-bridge -p vibechar
swift build --package-path "$root/apps/macos" -c release \
  -Xlinker -L -Xlinker "$root/target/release"
app="$root/dist/Vibechar.app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Helpers"
mkdir -p "$app/Contents/Resources"
cp "$root/docs/syntax-licenses.md" "$app/Contents/Resources/Syntax Notices.md"
cp "$root/target/release/vibechar" "$app/Contents/Helpers/.vibechar-next-$$"
mv -f "$app/Contents/Helpers/.vibechar-next-$$" "$app/Contents/Helpers/vibechar"
codesign --force --sign - "$app/Contents/Helpers/vibechar"
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
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
"$app/Contents/MacOS/Vibechar" --smoke-test
printf 'Development app: %s\n' "$app"
