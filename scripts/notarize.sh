#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$root/dist/Vibechar.app}"
: "${VIBECHAR_SIGN_IDENTITY:?Set the Developer ID Application identity}"
: "${VIBECHAR_NOTARY_PROFILE:?Set the notarytool Keychain profile name}"
temporary="$(mktemp -d "${TMPDIR:-/tmp/}vibechar-notary.XXXXXX")"
trap 'rm -r "$temporary"' EXIT
for helper in vibechar vc; do
  codesign --force --options runtime --timestamp --sign "$VIBECHAR_SIGN_IDENTITY" "$app/Contents/Helpers/$helper"
done
codesign --force --options runtime --timestamp --sign "$VIBECHAR_SIGN_IDENTITY" "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --keepParent "$app" "$temporary/submit.zip"
notary_args=(--keychain-profile "$VIBECHAR_NOTARY_PROFILE")
if [[ -n "${VIBECHAR_NOTARY_KEYCHAIN:-}" ]]; then notary_args+=(--keychain "$VIBECHAR_NOTARY_KEYCHAIN"); fi
xcrun notarytool submit "$temporary/submit.zip" "${notary_args[@]}" \
  --wait --timeout 20m --output-format json > "$temporary/result.json"
python3 - "$temporary/result.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
if result.get('status')!='Accepted':
    raise SystemExit('Apple did not accept notarization. Submission ID: '+str(result.get('id')))
print('Apple notarization accepted: '+result['id'])
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
