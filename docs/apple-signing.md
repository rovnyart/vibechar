# Apple signing and releases

Vibechar uses a stable **Developer ID Application** identity, Hardened Runtime,
a secure timestamp, Apple notarization and a stapled ticket. This also gives
Keychain a stable app identity across ordinary updates; switching from an old
ad-hoc development build can require one more Keychain approval.

## On this Mac

A valid Developer ID certificate is already installed. `scripts/build-mac.sh`
automatically selects an available Developer ID Application identity, or uses
`VIBECHAR_SIGN_IDENTITY` when provided. If no identity is available, it uses an
ad-hoc development signature. Explicitly set `VIBECHAR_SIGN_IDENTITY=-` for CI
checks that must not access signing credentials.

For a notarized local build:

```sh
bash scripts/build-mac.sh
export VIBECHAR_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export VIBECHAR_NOTARY_PROFILE=vibechar-notary
bash scripts/notarize.sh
bash scripts/package.sh
```

Create a Keychain profile interactively if you do not already have one:

```sh
xcrun notarytool store-credentials vibechar-notary
```

The tool prompts for Apple ID, Team ID and an app-specific password. Existing
profiles can be reused by changing `VIBECHAR_NOTARY_PROFILE`. Credentials stay in
Keychain and are never printed by Vibechar's release scripts.

## One-time GitHub setup: click by click

This is for the repository owner. Do not paste certificate keys or passwords into
chat, README files, workflow YAML, shell arguments or git.

### 1. Export the existing signing identity

1. Open **Keychain Access** with Spotlight.
2. Choose the **login** keychain and **My Certificates**.
3. Find **Developer ID Application: YOUR NAME (TEAMID)**. Expand it and check that
   its private key is present. This is the Developer ID certificate, not Apple Development.
4. Right-click that certificate → **Export…**. Choose **Personal Information
   Exchange (.p12)** and save as `~/Desktop/Vibechar-Developer-ID.p12`.
5. Set a strong export password. You will store it separately in GitHub.

If the certificate is missing, open **Xcode → Settings → Accounts**, select your
Apple ID and team, then **Manage Certificates → + → Developer ID Application**.
A paid Apple Developer Program membership and the team's signing permissions are
required. You do not need a new certificate for every app or every build.

### 2. Create a notarization password

1. Open [account.apple.com](https://account.apple.com/) and sign in yourself.
2. Open **Sign-In and Security → App-Specific Passwords**.
3. Choose **Generate an app-specific password** and name it `Vibechar GitHub CI`.
4. Keep the generated password for the GitHub secret below. This is not your
   ordinary Apple ID password. An App Store Connect individual API key is not the
   replacement for this notarization credential.

### 3. Add repository secrets

Open [rovnyart/vibechar → Settings → Secrets and variables → Actions](https://github.com/rovnyart/vibechar/settings/secrets/actions).
Choose **New repository secret** for each of these:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64 of the exported encrypted .p12 |
| `MACOS_CERTIFICATE_PASSWORD` | Password chosen while exporting .p12 |
| `APPLE_ID` | Apple ID email for your developer account |
| `APPLE_APP_PASSWORD` | The app-specific password from step 2 |
| `SPARKLE_PRIVATE_KEY` | Sparkle Ed25519 private key for signing update archives; already provisioned for this repository |

The simplest way to upload the certificate without copying it into a text file:

```sh
base64 -i "$HOME/Desktop/Vibechar-Developer-ID.p12" | \
  gh secret set MACOS_CERTIFICATE_P12 --repo rovnyart/vibechar
```

For the other three secrets, `gh secret set NAME --repo rovnyart/vibechar` prompts
for the value without placing it in the command line. The web UI works too.

Open the **Variables** tab → **New repository variable**:

| Variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | The 10-character Team ID shown on the Developer ID certificate |

You can find the Team ID at [developer.apple.com/account](https://developer.apple.com/account/)
under **Membership details**. The value must belong to the certificate's team.

### 4. Run the first automated signed release

Open [Actions → Release](https://github.com/rovnyart/vibechar/actions/workflows/release.yml),
choose **Run workflow**, select `main` and run it. Future pushes to `main` run checks only. Each publication is explicitly started
through this manual workflow; changelog generation, builds, signing and publishing
then run automatically.

GitHub uses a disposable keychain on each Mac runner. The Sparkle framework and
its nested installer tools, then both client helpers, are signed before the app.
Apple must return `Accepted`; the ticket is stapled and checked
before the package is marked notarized. Certificate files and temporary keychains
are cleaned up. Pull requests never run the signing step with credentials.

Release configuration is checked before reserving a version. Missing credentials
stop publication. The separate **CI** workflow and pull requests can still test
and upload unsigned development artifacts without any signing secrets.

### 5. Update signing key

The initial update key is already configured: the public key is committed in
`apps/macos/UpdaterPublicKey.txt`; the private key is in the repository secret
`SPARKLE_PRIVATE_KEY` and the dedicated local Keychain account
`dev.vibechar.updates.v1`. You do not need to generate or upload another key.

CI passes this key to Sparkle's official `generate_appcast` over stdin; it is never
put into arguments, committed files or logs. Keep the private key stable across
releases. Replacing only the public key would prevent existing installations from
accepting updates; key rotation needs a separate migration release. Keep a secure
backup through your normal credential-backup process.

## Release contents

Each release gets an immutable `vMAJOR.MINOR.PATCH` tag, binaries for macOS Apple
Silicon (arm64) and Linux x86_64, platform metadata, SHA256SUMS and `appcast.xml`.
The Mac archive includes the native app, terminal editor, `vc` and update helpers.
Stable publication requires Apple notarization and an Ed25519 update signature.
See [release rules and manual version selection](releases.md).

## References

- [Apple: Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Apple: Customizing notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Apple: App-specific passwords](https://support.apple.com/en-us/102654)
- [Apple: App Store Connect API key restrictions](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
- [Apple: Code signing requirements and stable identity](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
