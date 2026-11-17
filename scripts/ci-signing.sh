#!/bin/bash
# Runs only on a trusted main build, with a disposable GitHub runner keychain.
set -euo pipefail
: "${MACOS_CERTIFICATE_P12:?Missing certificate}"
: "${MACOS_CERTIFICATE_PASSWORD:?Missing certificate password}"
: "${APPLE_ID:?Missing Apple ID}"
: "${APPLE_APP_PASSWORD:?Missing app-specific password}"
: "${APPLE_TEAM_ID:?Missing Team ID}"
directory="$(mktemp -d "$RUNNER_TEMP/vibechar-signing.XXXXXX")"
keychain="$directory/signing.keychain-db"
password="$(openssl rand -hex 24)"
trap 'security delete-keychain "$keychain" >/dev/null 2>&1 || true; rm -r "$directory"' EXIT
python3 - "$directory/certificate.p12" <<'PY'
import os,base64,pathlib,sys
p=pathlib.Path(sys.argv[1]); p.write_bytes(base64.b64decode(os.environ['MACOS_CERTIFICATE_P12'],validate=True)); p.chmod(0o600)
PY
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$directory/certificate.p12" -k "$keychain" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
identity="$(security find-identity -v -p codesigning "$keychain" | sed -n 's/.*\([A-F0-9]\{40\}\) "Developer ID Application:.*$/\1/p' | head -1)"
test -n "$identity"
xcrun notarytool store-credentials vibechar-ci --keychain "$keychain" --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" >/dev/null
export VIBECHAR_SIGN_IDENTITY="$identity" VIBECHAR_NOTARY_PROFILE=vibechar-ci VIBECHAR_NOTARY_KEYCHAIN="$keychain"
bash scripts/notarize.sh
