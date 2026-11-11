# Development

## Requirements

- Rust 1.99.1 with rustfmt and clippy (pinned in rust-toolchain.toml).
- For macOS: Xcode command line tools / Swift 5.9 or newer, macOS 14+.
- No Docker, Node, background server, account, or API key is needed for M1.

The first local setup has a project-contained Rust installation under `.tooling/`.
`scripts/cargo.sh` uses it when present and falls back to the installed Cargo otherwise.
It does not change the global shell configuration. `.tooling/` is ignored and can be
removed if you already have the pinned Rust toolchain installed globally.

## Commands

Run from the repository root:

```sh
bash scripts/check.sh
# Or run individual checks:
bash scripts/cargo.sh test --workspace
bash scripts/cargo.sh fmt --all -- --check
bash scripts/cargo.sh clippy --workspace --all-targets -- -D warnings
bash scripts/cargo.sh build --release --workspace
```

Start the terminal editor:

```sh
bash scripts/cargo.sh run -p vibechar -- notes.txt
# After a release build:
./target/release/vibechar
printf 'hello\n' | ./target/release/vibechar
```

TUI controls: type normally; arrows/Home/End move; Ctrl+Home/End jump through the
document; Ctrl+S saves (asks a filename for a scratch buffer); Ctrl+Z/Ctrl+Y undo/redo;
Ctrl+N creates a scratch buffer; F6/Shift+F6 (or Ctrl+PageDown/PageUp) cycle buffers;
Ctrl+W closes the active buffer; Ctrl+Q quits. Closing an edited buffer requires a
second Ctrl+W to discard it. Ctrl+Q flushes the entire local session, including
hidden buffers, before quitting. If that flush fails, the editor stays open;
a second Ctrl+Q allows quitting without the latest changes. Escape
cancels the save prompt. Bracketed paste is one undo step. No mouse is required.

Build and open the native development app:

```sh
bash scripts/build-mac.sh
open dist/Vibechar.app
```

The script builds the Rust static library, links the Swift app, wraps a .app bundle,
ad-hoc signs it for local development, and runs the native bridge smoke test. This
is not a notarized distributable. It is not copied to `/Applications`.

`scripts/check.sh` includes a real PTY integration test; run it from a local
environment that permits creating a controlling terminal. The integration test
cleans up its processes and temporary files and uses no desktop terminal app.

Mac controls: native text editing/selection and clipboard; Cmd+N new scratch,
Cmd+O open UTF-8 file in a new buffer, Cmd+S save, Cmd+Z undo, Shift+Cmd+Z redo,
Cmd+W close buffer, Cmd+Q quit. Click a tab or use Option+Cmd+Left/Right to switch.
Each buffer remembers its selection and has independent undo history. Closing the
last buffer starts a fresh empty scratch. Quitting preserves the Mac session locally
and waits for the final save. Explicitly closing an edited tab asks before removing
it from the saved session.

## Mac session recovery

Mac captures immutable rope snapshots after a 500 ms pause, then encodes/writes on
a serial background queue. Normal Cmd+Q and closing the window flush the latest
state before exit. The next launch restores tab order, text, active tab, selections,
file destinations, and modified-file flags. Undo histories start fresh after restart.

The default file is `~/Library/Application Support/dev.vibechar.app/session.json`.
It contains ordinary UTF-8 JSON text and has owner-only permissions (directory 0700,
file 0600). It is local, unencrypted storage, not a private-buffer feature. A process
lock prevents two app instances from overwriting the same session. Separate QA
bundle identifiers have separate recovery folders.

Atomic replacement preserves the previous checkpoint on a failed write. Corrupt or
unreadable snapshots are left untouched; the app reports an error and disables
automatic writes for that process. A failed quit flush offers Keep Editing rather
than silently dropping recent text. Background recovery never overwrites an opened
file's original destination; Cmd+S still performs that explicit save.

Force quitting may lose input since the last completed background save. Wait for
"Saved locally" to know the latest checkpoint completed. The 500 ms debounce plus
write time is not a power-loss durability guarantee. Retention and private buffers
remain later work.

## Terminal session recovery

Terminal uses the same Rust checkpoint format and a dedicated worker thread.
After a 500 ms input pause it captures and queues a snapshot; Ctrl+Q waits for the
latest save. An idle session blocks on terminal input, rather than polling or
redrawing continuously. The next launch restores all buffers, text, cursor positions,
active buffer, file destinations, and modified flags. Undo starts fresh after restart.

Default storage is `~/Library/Application Support/dev.vibechar.terminal/` on macOS
and `$XDG_STATE_HOME/vibechar/terminal/` on Linux (fallback:
`~/.local/state/vibechar/terminal/`). The Mac GUI and terminal use separate sessions.
Folders/files are owner-only. A second terminal instance using the same session
exits with a clear error before changing terminal mode. A corrupt checkpoint is
left untouched and startup fails rather than replacing it with an empty session.

`vibechar FILE` selects that file's existing recovered buffer, preserving pending
edits, or opens a new buffer beside recovered ones. Piped text opens a new scratch.
File destinations are absolute so resuming from another working directory does not
redirect saves. Background recovery never writes changes to the original files.

Tests set `VIBECHAR_STATE_DIR` to a private temporary directory. This override can
also isolate a separate terminal session; it does not alter the GUI's storage.
Linux path selection is implemented; Linux runtime acceptance remains the M6 gate.

## Layout

```text
crates/core/        shared document, positions, history
crates/bridge/      small C ABI consumed by Swift
crates/terminal/    full-screen terminal client
apps/macos/        AppKit client and Swift package
scripts/           local build and verification entry points
docs/              roadmap, architecture, development, verification evidence
```

## M1 limitations

The app is an early prototype. Highlighting, AI,
multicursors, grouped typing undo, global hotkeys, and search are later
milestones. TUI selection/clipboard and native IME composition qualification are
also pending. No settings UI exists; recovery uses a versioned JSON checkpoint.

Both clients start with one buffer and allow more buffers in the same process.
Both clients restore their separate sessions after restart. Switching restores
the cursor/selection and scrolls it into
view; exact manual scroll positions are not retained. Ordinary typed characters produce
individual undo entries. Mac history restoration copies the document to the view;
ordinary edits send only the changed text to Rust. TUI navigation currently scans
the current line for grapheme boundaries: pathological single-line files need the
M3 large-document work before a performance claim.

Saves are atomic at the file replacement level, but external-change checks,
filesystem race handling, durability/permission edge cases, and a unified file
service are M2 work. Do not use this prototype as the only copy of important text.
Both interfaces reject replacing a known symlink; the TUI also rejects a read-only
destination. No network calls are made by the editor.

## Validation policy

Core tests cover edit history, saved-state identity, invalid ranges, UTF-16 surrogate
boundaries, graphemes/ZWJ, and CRLF. Bridge tests cover malformed inputs and copy
ownership. Terminal tests cover meaningful editing, layout, and quit behavior. The
native smoke test exercises the actual Swift-to-Rust link and Unicode round-trip.

Integration validation must exercise a real pseudo-terminal and the real macOS
application. Keep evidence in `docs/verification.md` and distinguish automated
behavior, observed UI behavior, untested scenarios, and performance hypotheses.
