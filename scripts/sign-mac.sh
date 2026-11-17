#!/bin/bash
# Sign nested update tools before their framework and the enclosing application.
set -euo pipefail
app="$1"
identity="$2"
args=(--force --sign "$identity")
if [[ "$identity" != - ]]; then args+=(--options runtime --timestamp); fi
framework="$app/Contents/Frameworks/Sparkle.framework"
if [[ -d "$framework" ]]; then
  codesign "${args[@]}" --preserve-metadata=identifier,entitlements "$framework/Versions/B/Autoupdate"
  codesign "${args[@]}" --preserve-metadata=identifier,entitlements "$framework/Versions/B/Updater.app"
  codesign "${args[@]}" --preserve-metadata=identifier,entitlements "$framework"
fi
for helper in vibechar vc; do codesign "${args[@]}" "$app/Contents/Helpers/$helper"; done
codesign "${args[@]}" "$app"
codesign --verify --deep --strict "$app"
