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
Ctrl+Q quits. With unsaved changes, a second Ctrl+Q explicitly discards them. Escape
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
Cmd+O open UTF-8 file, Cmd+S save, Cmd+Z undo, Shift+Cmd+Z redo, Cmd+Q quit.

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

The app is an architecture prototype. Highlighting, AI, recovery/autosave, buffer
switching, multicursors, grouped typing undo, global hotkeys, and search are later
milestones. TUI selection/clipboard and native IME composition qualification are
also pending. No settings UI or long-term storage format exists yet.

Both clients currently start with one buffer. Ordinary typed characters produce
individual undo entries. Mac history restoration copies the document to the view;
ordinary edits send only the changed text to Rust. TUI navigation currently scans
the current line for grapheme boundaries: pathological single-line files need the
M3 large-document work before a performance claim.

Saves are atomic at the file replacement level, but external-change checks,
filesystem race handling, durability/permission edge cases, and a unified file
service are M2 work. Do not use this prototype as the only copy of important text.
Both interfaces reject replacing a known symlink; the TUI also rejects a read-only
destination. Scratch text has no recovery. No network calls are made by the editor.

## Validation policy

Core tests cover edit history, saved-state identity, invalid ranges, UTF-16 surrogate
boundaries, graphemes/ZWJ, and CRLF. Bridge tests cover malformed inputs and copy
ownership. Terminal tests cover meaningful editing, layout, and quit behavior. The
native smoke test exercises the actual Swift-to-Rust link and Unicode round-trip.

Integration validation must exercise a real pseudo-terminal and the real macOS
application. Keep evidence in `docs/verification.md` and distinguish automated
behavior, observed UI behavior, untested scenarios, and performance hypotheses.
