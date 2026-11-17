#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
system="$(uname -s)"
out="$root/dist/release"
mkdir -p "$out"
notarized=false
if [[ "$system" == Darwin ]]; then
  platform=macos
  app="${1:-$root/dist/Vibechar.app}"
  arch="$(lipo -archs "$app/Contents/MacOS/Vibechar")"
  if [[ "$arch" != arm64 ]]; then echo 'The Mac release must be an Apple Silicon (arm64) bundle.' >&2; exit 1; fi
  for helper in vc vibechar; do
    if [[ "$(lipo -archs "$app/Contents/Helpers/$helper")" != arm64 ]]; then
      echo "The Mac helper $helper must contain only arm64." >&2; exit 1
    fi
  done
  if spctl --assess --type execute "$app" >/dev/null 2>&1 && xcrun stapler validate "$app" >/dev/null 2>&1; then notarized=true; fi
  asset="vibechar-$platform-$arch.zip"
  ditto -c -k --keepParent "$app" "$out/$asset"
elif [[ "$system" == Linux ]]; then
  platform=linux
  case "$(uname -m)" in x86_64|amd64) arch=x86_64 ;; *) echo 'The Linux terminal build requires x86_64.' >&2; exit 1 ;; esac
  stage="$(mktemp -d)"
  trap 'rm -r "$stage"' EXIT
  binaries="${VIBECHAR_BIN_DIR:-$root/target/release}"
  cp "$binaries/vc" "$binaries/vibechar" "$root/LICENSE" "$stage/"
  cp "$root/docs/syntax-licenses.md" "$stage/Syntax-Notices.md"
  asset="vibechar-$platform-$arch.tar.gz"
  python3 "$root/scripts/third-party-notices.py" "$stage/Third-Party-Notices.txt"
  tar -czf "$out/$asset" -C "$stage" vc vibechar LICENSE Syntax-Notices.md Third-Party-Notices.txt
else
  echo 'Vibechar supports macOS and Linux.' >&2; exit 1
fi
revision="$(git -C "$root" rev-parse HEAD)"
python3 - "$out/$asset" "$platform" "$arch" "$revision" "$notarized" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
info=dict(asset=p.name,platform=sys.argv[2],arch=sys.argv[3],revision=sys.argv[4],notarized=sys.argv[5]=='true',sha256=hashlib.sha256(p.read_bytes()).hexdigest())
p.with_suffix(p.suffix+'.json').write_text(json.dumps(info,indent=2)+'\n')
PY
printf 'Packaged %s (notarized=%s)\n' "$asset" "$notarized"
