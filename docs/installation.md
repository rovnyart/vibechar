# Installation

```sh
curl -fsSL https://raw.githubusercontent.com/rovnyart/vibechar/main/install.sh | sh
```

The installer selects the latest stable GitHub Release for macOS Apple Silicon (arm64) or
Linux x86_64, verifies SHA-256 and installs into your account. Mac also requires a
valid code signature and a successful Gatekeeper assessment. Preview/unsigned Mac
builds are available as CI artifacts but are not a normal installation path.

Mac installs both clients inside `~/Applications/Vibechar.app`. `vc` is a symlink
in `~/.local/bin`; the terminal executable stays next to it inside the app. On
Linux, binaries live under `~/.local/share/vibechar/releases/<build>`.

`vc notes.txt` opens the native Mac app, including an already-running instance.
`vc -t notes.txt` / `vc --terminal notes.txt` run in the current terminal. Linux
always opens the terminal. Use `--` before filenames beginning with `-`.
`vc --help`, `vc --version` and `vc run ...` are also available.

Choose **Vibechar → Install vc Command…** or run `vc --install` to set up the
command. The operation appends an idempotent PATH block to zsh, bash or fish
startup files and preserves existing content. An unrelated `~/.local/bin/vc` is
left untouched. Open a new terminal after initial installation.

## Updates

From **1.0.0**, the Mac app checks quietly about every six hours while running.
An available version adds a small **Update** button to the header. One click
downloads the archive, verifies its Ed25519 signature, installs and reopens the
app. The installed app is Developer ID signed and notarized by Apple.

Ordinary scratch tabs and cursor positions are checkpointed before restart. An
open private tab containing text pauses installation: save or close it yourself,
then click **Restart**. Private text is never added to recovery. If a checkpoint
cannot be saved, the update also waits rather than throwing away the session.

Use **Vibechar → Check for Updates…** for an immediate check. Toggle
**Automatically Check for Updates** in the same menu. Downloads begin only when
you click Update; there are no surprise restarts or update dialogs during editing.

The Mac app, bundled terminal editor and `vc` are replaced as one bundle. The
existing PATH symlink keeps working. An already-running terminal editor continues
normally; the next `vc -t` uses the new version. There is no second Mac terminal
update service.

**Older preview builds need one manual install of 1.0.0** to gain the updater.
On Linux, or to reinstall on Mac, rerun the curl command above. Restart an
already-running editor to load the replacement. The installer does not quit your
editor or remove recovery, keys, private tabs or recipes. For a specific release,
first export `VIBECHAR_VERSION=v1.0.0`, then run the same command. Set
`VIBECHAR_APP_DIR` to choose another Mac application directory before installation.

## Manual installation and removal

For manual Mac installation, download your architecture's ZIP and `SHA256SUMS`,
verify the checksum, unpack `Vibechar.app` and move it to Applications. Launch it
and choose **Install vc Command…**. Linux archives contain `vc` and `vibechar`;
keep them in the same directory, then run that copy of `vc --install`.

To remove the app, move `~/Applications/Vibechar.app` to Trash and remove the
`~/.local/bin/vc` symlink if it points to Vibechar. On Linux, remove Vibechar's
binary directories and its symlink. Recovery, recipes and Keychain items are
separate and deliberately retained. Remove the `# Vibechar command` block from
your shell startup files if you no longer want its PATH entry.
