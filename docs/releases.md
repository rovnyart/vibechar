# Versions and releases

The first numbered release is **1.0.0**. Stable tags are `vMAJOR.MINOR.PATCH` and
release titles are `Vibechar MAJOR.MINOR.PATCH`. Historical `build-<commit>` tags
remain available but do not participate in version calculation.

`[workspace.package].version` in `Cargo.toml` is the source of truth. The release
workflow updates it, all four local packages in `Cargo.lock`, and `CHANGELOG.md`.
The Mac bundle, About window, `vc --version`, `vibechar --version` and artifact
metadata use that same version.

## Manual releases, automatic changelog

Ordinary pushes to `main` run **CI checks only**. They do not change the version
or publish anything. To release, explicitly run
[Release](https://github.com/rovnyart/vibechar/actions/workflows/release.yml) with a
patch/minor/major bump or an exact version. The default selection is minor.
Release jobs are serialized; version calculation uses the current main checkout.

The manual trigger automatically collects Conventional Commits since the last
stable version, groups them and commits `CHANGELOG.md` together with the new
version. The same notes appear in GitHub Releases. Initial 1.0.0 collects the
project's Conventional Commit history; the legacy non-conventional initial
commit and generated release commits are excluded.

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```text
feat(editor): add a text tool
fix(mac): preserve selection after paste
perf(core): reduce snapshot copies
feat(api)!: change the command format
```

Supported types: `feat`, `fix`, `perf`, `refactor`, `docs`, `style`, `test`,
`build`, `ci`, `chore`, `revert`. A `!` or `BREAKING CHANGE:` footer marks an
incompatible change. The workflow groups changes into the changelog and release
notes, with links to commits. Main pushes and pull requests check commit conventions as well as
building both clients without signing credentials.

GitHub first commits `chore(release): VERSION [skip ci]` to main, then tests and
builds that exact revision for Mac arm64 and Linux x86_64. This bot commit does
not start another release. **Pull main before your next local push** to include
the generated version/changelog commit.

## Choose a version manually

1. Open **Actions → Release → Run workflow** and select `main`.
2. Choose `patch`, `minor`, `major`, or `exact`.
3. For `exact` only, enter a stable version such as `1.4.2`.
4. Run the workflow. A manual release can ship without new code changes.

The first release is always 1.0.0. Versions cannot go backwards, and an incompatible
change requires a major release. The separate **CI** workflow is a check-only run;
use it when you want validation without publishing or incrementing a version.

## Failed builds and retries

A failed build leaves its reserved version on main but publishes no new stable
release. Rerun the failed workflow; it reuses the same version and source commit.
If a code fix is necessary, commit it normally and run Release again: it reuses the pending
version and refreshes its changelog. It does not skip another version number.

Already-published stable versions are immutable. A retry for the same source
preserves the existing assets; a different source cannot replace that version.
Only complete Mac + Linux releases become latest. Signing configuration must be
present before a version is reserved; missing credentials fail with a named
configuration error.

## Updates and signing

The Mac ZIP includes the app, `vc`, terminal editor and Sparkle's update helpers.
All shipped Mach-O binaries are arm64. Apple signing and notarization cover the
bundle; a separate Ed25519 key signs the update archive. The official Sparkle
appcast generator produces `appcast.xml`, bundled release notes and versioned
download URLs. The feed is served over HTTPS from the latest GitHub Release;
the app pins the archive-verification public key. No update service is hosted.

The publisher checks version, source revision, expected platforms, SHA-256,
notarization metadata and feed/archive consistency before publishing. Signed Mac
CI also performs an actual download, replacement and relaunch using the candidate
archive and a loopback feed on a disposable runner.

See [Apple signing setup](apple-signing.md), [update behavior](installation.md#updates)
and [CHANGELOG.md](../CHANGELOG.md).
