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
  if spctl --assess --type execute "$root/dist/Vibechar.app" >/dev/null 2>&1 && xcrun stapler validate "$root/dist/Vibechar.app" >/dev/null 2>&1; then notarized=true; fi
  asset="vibechar-$platform-$arch.zip"
  ditto -c -k --keepParent "$root/dist/Vibechar.app" "$out/$asset"
else
  platform=linux
  stage="$(mktemp -d)"
  trap 'rm -r "$stage"' EXIT
  cp "$root/target/release/vc" "$root/target/release/vibechar" "$root/LICENSE" "$stage/"
  cp "$root/docs/syntax-licenses.md" "$stage/Syntax-Notices.md"
  asset="vibechar-$platform-$arch.tar.gz"
  tar -czf "$out/$asset" -C "$stage" vc vibechar LICENSE Syntax-Notices.md
fi
revision="$(git -C "$root" rev-parse HEAD)"
python3 - "$out/$asset" "$platform" "$arch" "$revision" "$notarized" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
info=dict(asset=p.name,platform=sys.argv[2],arch=sys.argv[3],revision=sys.argv[4],notarized=sys.argv[5]=='true',sha256=hashlib.sha256(p.read_bytes()).hexdigest())
p.with_suffix(p.suffix+'.json').write_text(json.dumps(info,indent=2)+'\n')
PY
printf 'Packaged %s (notarized=%s)\n' "$asset" "$notarized"
