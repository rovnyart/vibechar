#!/bin/sh
# Install both Mac clients, or the terminal client on Linux. No sudo required.
set -eu
repository=rovnyart/vibechar
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64|Darwin/aarch64) platform=macos; arch=arm64 ;;
  Linux/x86_64|Linux/amd64) platform=linux; arch=x86_64 ;;
  Darwin/*) echo 'Vibechar for macOS requires Apple Silicon (arm64).' >&2; exit 1 ;;
  Linux/*) echo 'The Linux terminal build requires x86_64.' >&2; exit 1 ;;
  *) echo 'Vibechar supports macOS and Linux.' >&2; exit 1 ;;
esac
tag=${VIBECHAR_VERSION:-}
if [ -z "$tag" ]; then
  final=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$repository/releases/latest")
  tag=${final##*/}
fi
case "$tag" in ''|*[!A-Za-z0-9._+-]*) echo 'Invalid release tag.' >&2; exit 1 ;; esac
temporary=$(mktemp -d "${TMPDIR:-/tmp/}vibechar-download.XXXXXX")
staged=''
cleanup() {
  if [ -n "$staged" ] && [ -d "$staged" ]; then
    if [ -d "$staged/previous.app" ] && [ ! -e "$apps/Vibechar.app" ]; then mv "$staged/previous.app" "$apps/Vibechar.app"; fi
    rm -r "$staged"
  fi
  if [ -d "$temporary" ]; then rm -r "$temporary"; fi
}
trap cleanup 0
trap 'exit 1' 1 2 15
extension=tar.gz
if [ "$platform" = macos ]; then extension=zip; fi
asset="vibechar-$platform-$arch.$extension"
base="https://github.com/$repository/releases/download/$tag"
printf 'Downloading Vibechar %s (%s/%s)…\n' "$tag" "$platform" "$arch"
curl -fSL "$base/$asset" -o "$temporary/$asset"
curl -fsSL "$base/SHA256SUMS" -o "$temporary/SHA256SUMS"
expected=$(awk -v file="$asset" '$2 == file { print $1 }' "$temporary/SHA256SUMS")
if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$temporary/$asset" | cut -d ' ' -f1)
else actual=$(shasum -a 256 "$temporary/$asset" | cut -d ' ' -f1); fi
if [ ${#expected} -ne 64 ] || [ "$actual" != "$expected" ]; then echo 'Download checksum failed. Nothing was installed.' >&2; exit 1; fi
mkdir -p "$temporary/unpacked"
if [ "$platform" = macos ]; then
  ditto -x -k "$temporary/$asset" "$temporary/unpacked"
  source_app="$temporary/unpacked/Vibechar.app"
  codesign --verify --deep --strict "$source_app"
  spctl --assess --type execute "$source_app"
  apps=${VIBECHAR_APP_DIR:-$HOME/Applications}
  mkdir -p "$apps"
  staged=$(mktemp -d "$apps/.vibechar-install.XXXXXX")
  ditto "$source_app" "$staged/Vibechar.app"
  if [ -e "$apps/Vibechar.app" ]; then mv "$apps/Vibechar.app" "$staged/previous.app"; fi
  if ! mv "$staged/Vibechar.app" "$apps/Vibechar.app"; then
    if [ -d "$staged/previous.app" ]; then mv "$staged/previous.app" "$apps/Vibechar.app"; fi
    echo 'App installation failed; previous version restored.' >&2; exit 1
  fi
  rm -r "$staged"
  staged=''
  "$apps/Vibechar.app/Contents/Helpers/vc" --install
  echo "Installed both clients in $apps/Vibechar.app. Restart Vibechar if it is running."
else
  tar -xzf "$temporary/$asset" -C "$temporary/unpacked"
  destination="$HOME/.local/share/vibechar/releases/$tag"
  mkdir -p "$destination"
  staged=$(mktemp -d "$destination/.next.XXXXXX")
  cp "$temporary/unpacked/vc" "$temporary/unpacked/vibechar" "$temporary/unpacked/LICENSE" \
    "$temporary/unpacked/Syntax-Notices.md" "$temporary/unpacked/Third-Party-Notices.txt" "$staged/"
  chmod 755 "$staged/vc" "$staged/vibechar"
  for file in vc vibechar LICENSE Syntax-Notices.md Third-Party-Notices.txt; do mv -f "$staged/$file" "$destination/$file"; done
  rmdir "$staged"
  staged=''
  "$destination/vc" --install
fi
