#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source_image="$root/apps/macos/Artwork/AppIcon.icon/Assets/Graphite.png"
output="${1:-$root/dist/AppIcon.icns}"
temporary="$(mktemp -d "${TMPDIR:-/tmp/}vibechar-icon.XXXXXX")"
trap 'rm -r "$temporary"' EXIT
iconset="$temporary/AppIcon.iconset"
mkdir -p "$iconset" "$(dirname "$output")"

# Standard macOS representations, including Retina sizes up to 1024 pixels.
# The selected master already includes the transparent margin and rounded tile.
for points in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((points * scale))
    suffix=""
    if [[ "$scale" == 2 ]]; then suffix="@2x"; fi
    sips -s format png -z "$pixels" "$pixels" "$source_image" \
      --out "$iconset/icon_${points}x${points}${suffix}.png" >/dev/null
  done
done
iconutil --convert icns "$iconset" --output "$output"

# On macOS 26+ a bitmap-only legacy icon gets a system backplate. Compile the
# modern native icon as well, retaining our literal ICNS family for macOS 14/15.
mkdir -p "$temporary/compiled"
xcrun actool "$root/apps/macos/Artwork/AppIcon.icon" \
  --compile "$temporary/compiled" --output-format human-readable-text \
  --notices --warnings --output-partial-info-plist "$temporary/compiled/Info.plist" \
  --app-icon AppIcon --include-all-app-icons --enable-on-demand-resources NO \
  --development-region en --target-device mac --minimum-deployment-target 14.0 \
  --platform macosx
test -s "$temporary/compiled/Assets.car"
cp "$temporary/compiled/Assets.car" "$(dirname "$output")/Assets.car"
