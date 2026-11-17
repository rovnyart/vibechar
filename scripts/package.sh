#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
system="$(uname -s)"
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64) arch=x86_64 ;; *) exit 1 ;; esac
out="$root/dist/release"
mkdir -p "$out"
notarized=false
if [[ "$system" == Darwin ]]; then
  platform=macos
  app="${1:-$root/dist/Vibechar.app}"
  arch="$(lipo -archs "$app/Contents/MacOS/Vibechar")"
  case "$arch" in arm64|x86_64) ;; *) echo 'Expected a single-architecture Mac bundle.' >&2; exit 1 ;; esac
  for helper in vc vibechar; do lipo -verify_arch "$arch" "$app/Contents/Helpers/$helper"; done
  if spctl --assess --type execute "$app" >/dev/null 2>&1 && xcrun stapler validate "$app" >/dev/null 2>&1; then notarized=true; fi
  asset="vibechar-$platform-$arch.zip"
  ditto -c -k --keepParent "$app" "$out/$asset"
else
  platform=linux
  stage="$(mktemp -d)"
  trap 'rm -r "$stage"' EXIT
  binaries="${VIBECHAR_BIN_DIR:-$root/target/release}"
  cp "$binaries/vc" "$binaries/vibechar" "$root/LICENSE" "$stage/"
  cp "$root/docs/syntax-licenses.md" "$stage/Syntax-Notices.md"
  asset="vibechar-$platform-$arch.tar.gz"
  python3 "$root/scripts/third-party-notices.py" "$stage/Third-Party-Notices.txt"
  tar -czf "$out/$asset" -C "$stage" vc vibechar LICENSE Syntax-Notices.md Third-Party-Notices.txt
fi
revision="$(git -C "$root" rev-parse HEAD)"
python3 - "$out/$asset" "$platform" "$arch" "$revision" "$notarized" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
info=dict(asset=p.name,platform=sys.argv[2],arch=sys.argv[3],revision=sys.argv[4],notarized=sys.argv[5]=='true',sha256=hashlib.sha256(p.read_bytes()).hexdigest())
p.with_suffix(p.suffix+'.json').write_text(json.dumps(info,indent=2)+'\n')
PY
printf 'Packaged %s (notarized=%s)\n' "$asset" "$notarized"
