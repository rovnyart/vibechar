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
Ctrl+N creates a scratch buffer; Ctrl+P creates a private scratch;
F6/Shift+F6 (or Ctrl+PageDown/PageUp) cycle buffers;
Ctrl+W closes the active buffer; Ctrl+Q quits. Closing an edited buffer requires a
second Ctrl+W to discard it. Ctrl+Q flushes ordinary tabs, including hidden ones,
before quitting. When any private tab has text, the first Ctrl+Q asks and the second
consecutive Ctrl+Q discards private tabs and quits; any other key or paste cancels
that confirmation. If the ordinary-tab flush fails, the editor stays open;
a second Ctrl+Q allows quitting without the latest changes. Escape
cancels the save prompt. Bracketed paste is one undo step. No mouse is required.

Mouse reporting is enabled while the TUI is running. Wheel/trackpad scroll moves
the document viewport by three lines per reported wheel event and keeps the caret
in place. An offscreen caret is hidden; typing or keyboard navigation reveals it
again. A left click inside the text area places the caret at the nearest grapheme
boundary, accounting for tabs, wide characters, emoji, and the scrolled viewport.
Clicks beyond a line/document clamp to its end; header/footer clicks and mouse
events while a Save As/language prompt is open do not move the editing caret.
Drag selection is still pending. Terminal-owned selection/copy depends on the
emulator's mouse-reporting override (often Shift).

Viewport scrolling does not write recovery or trigger syntax parsing. Cursor-only
navigation is checkpointed quietly, without a Saving locally flash or postponing
an already pending text write. Content/tab/language/file-state changes still show
the recovery save status. Mouse reporting and bracketed paste are disabled on
normal/error exit and by the panic cleanup hook before terminal restoration.
The emulator must support mouse reporting; physical trackpad acceptance across
terminal apps remains part of release qualification.

F4 opens Save As even for an existing file buffer. Type/paste a destination and
press Enter. An existing destination requires another Enter to confirm replacement;
Esc cancels. Editing or pasting a filename clears that replacement confirmation.
Save and Save As reject known symlinks and read-only files. Failed or cancelled
operations keep the current destination and edited text. Only a successful write
attaches the new path; subsequent Ctrl+S uses it, and restart restores it.

Build and open the native development app:

```sh
bash scripts/build-mac.sh
open dist/Vibechar.app
```

The script builds the Rust static library and CLI helper, links the Swift app,
wraps a .app bundle, ad-hoc signs the helper and app for local development, and runs
the native bridge/interface/Secret Drop smoke tests. This
is not a notarized distributable. It is not copied to `/Applications`.

`scripts/check.sh` includes a real PTY integration test; run it from a local
environment that permits creating a controlling terminal. The integration test
cleans up its processes and temporary files and uses no desktop terminal app.

Mac controls: native text editing/selection and clipboard; Cmd+N new scratch,
Shift+Cmd+N new private scratch, Cmd+O open UTF-8 file in a new buffer,
Cmd+S save (ends private mode after success), Cmd+Z undo, Shift+Cmd+Z redo.
Shift+Cmd+S / File → Save As chooses a new destination for the active tab. The native
panel starts with the current filename/folder and confirms replacement. Success
attaches the new path; later Cmd+S uses it. Cancellation/failure preserves the old
path and text. The original file is untouched when choosing a different destination.
Cmd+W closes a tab; closing the last tab by Cmd+W or its × closes the window and
exits the app after the existing discard checks. Explicitly closed tabs are removed
from recovery; closing the final tab restarts into an empty scratch. The terminal
keeps its empty-scratch fallback when its final buffer closes; Ctrl+Q exits it.
Click a tab or use Option+Cmd+Left/Right to switch.
Each buffer remembers its selection and has independent undo history. Cmd+Q or
the red window button preserves ordinary Mac tabs locally
and waits for the final save. Explicitly closing an edited tab asks before removing
it from the saved session. If persisting the last tab's removal fails, Keep Editing
leaves the original tab intact; Close Anyway can leave an older session on disk.

Mac cursor/selection changes checkpoint quietly, without changing the text-save
status or postponing a queued text write. Repeated selection notifications with
the same range schedule nothing; private selection changes schedule no recovery.
Actual write failures remain visible until a checkpoint succeeds. Shared Rust
owns text/history/checkpoint filtering; frontend event handlers own scheduling
and presentation of the local-save status.

The Mac interface follows Pocket: traffic lights, compact tabs, new-tab button,
and `V_` share a 54 pt header. When tabs overflow, the chevron opens all tabs; the
active tab stays visible. Long labels truncate with full names available in native
tooltips and the menu. Scratch names use a bounded preview of the first meaningful
line (also shared with the terminal); file tabs keep their filenames. The file
modification dot is independent from the footer's local session-save status.

View provides text zoom (Zoom In/Out and Cmd+0 reset), an appearance submenu
(Follow System/Light/Dark), and full screen. Appearance and the normal window frame
persist locally. The canvas uses native AppKit input and an opaque light/dark
surface. AI actions, line numbers, and native line/column indicators remain
later work; the design studies showed illustrative future interactions.

The build's native smoke test checks tab geometry at 420–1600 pt, active-tab
visibility with 14 tabs, per-tab close targets, and the actual window composition
in both appearances. It checks that the system titlebar does not clip its buttons
or intercept clicks on tab controls, and typography does not alter document text
or history. To render the actual content view offscreen with synthetic text:

```sh
VIBECHAR_INTERFACE_SNAPSHOTS="$PWD/dist/pocket-ui" \
  dist/Vibechar.app/Contents/MacOS/Vibechar --smoke-test
```

These images exclude the system titlebar/traffic-light layer. They supplement
on-screen application checks; they do not qualify native full-screen transitions,
VoiceOver, or IME composition.

## Smart syntax

Both clients default to Auto: a recognized filename extension wins, followed by a
shebang and conservative content signals. Common paste detectors cover JSON/JSON
Lines, environment pairs, TOML/YAML, SQL, shell commands, Rust, Swift, Python,
TypeScript/JavaScript, HTML/XML and Markdown. Ambiguous fragments/prose/tokens stay
Text; auto detection is heuristic, not a classifier for every bundled language.
An ordinary `.txt`/`.log` filename still permits content detection. Nothing is sent
to an AI provider or network, including for private tabs.

On Mac click the footer's **Auto · language** badge or use View → Choose Language /
Control+Cmd+L. Search names or extensions (`ts`, `py`, `json`); the popover shows at
most seven choices, with arrows/Return to choose and Escape to cancel. In the TUI
use **F2** with the same search/selection keys. Choose **Auto** to return to detection
or **Text** to disable colors for that tab. An override is per tab and never changes
the text/dirty state. Ordinary pins survive restart; private pins are not recovered.

The pinned Syntect/two-face catalog has **186 visible grammars**. Run
`./target/release/vibechar --syntax-count` to inspect the build. Grammar data loads
on demand, outside the editor input thread; empty/plain scratches do not load it.
After a 120 ms input debounce, one worker parses an immutable rope snapshot. It
keeps parser checkpoints every 32 lines and reuses unchanged prefixes. A new
request replaces pending work; stale document/revision/path/mode results cannot
override the current state. Soft 160 ms slices publish partial results and continue;
that is a cooperative budget between lines, not a per-regex wall-clock deadline.

The current color preview caps are **512 KiB per document, 8,192 bytes per line,
10,000 lines and 20,000 colored spans**. Crossing a size/line cap leaves the text
uncolored and fully editable; a span/parser limit can keep a colored prefix. The
Mac tooltip/TUI `preview` label indicates a limited result. Regex execution uses
fancy-regex's backtracking limit; a single regex/line can outlast the soft slice.
These are explicit preview limits, not full large-document-mode qualification.

AppKit uses temporary foreground attributes for the viewport plus a small margin;
TUI paints visible rows with the same palette. Colors do not enter the clipboard,
save files or Undo. Dark terminal colors are the default; set
`VIBECHAR_COLOR_SCHEME=light` for a light background. Truecolor/emulator acceptance
beyond the local PTY remains pending. A nonempty `NO_COLOR` disables terminal color
output. Dependency notices are in
[syntax-licenses.md](syntax-licenses.md), included in the Mac bundle's Resources,
and available through `vibechar --syntax-licenses`.

## Private scratches

Use File → New Private Scratch / Shift+Cmd+N on Mac, or Ctrl+P in the terminal.
Private tabs have generic numbered titles, a persistent "not recovered" state,
and a lock icon on Mac. The shared engine excludes their text, path, and selection
from checkpoint capture, including background saves, final flush, and error paths.
They do not return after normal quit or forced termination. Ordinary tabs keep
their own state; a private-only session restarts as one empty ordinary scratch.

Nonempty private tabs require confirmation on close and on quit, even when hidden.
Cmd+S / Ctrl+S saves to a chosen file and turns that tab into an ordinary file tab.
The save UI states that this ends private mode and enables local recovery. On
success the tab shows its filename, loses its private label/lock/actions, remembers
the destination for subsequent saves, and revokes its Secret Drop reference.
Text, selection, and undo history are preserved. Cancellation or a failed write
keeps it private and leaves any existing grant usable. Other private tabs and
their grants are unaffected. Ordinary recovery can now include the saved text.

Existing ordinary tabs cannot be converted to private: their earlier snapshots
may already exist. This is recovery exclusion, not encrypted or securely wiped
memory. It does not erase clipboard contents, explicit exports, or OS-managed
swap/crash data. No AI/action/diagnostic service exists yet; each future service
must enforce private-buffer exclusion before collecting content.

## Secret Drop

Fast path: copy a value, then use **Agent → Paste Secret for Agent** / Option+Cmd+V
on Mac, or **F8** in the terminal. It creates a private tab, opens local access,
and copies a ready instruction. Paste that instruction into your agent chat. The
Mac app includes the helper and uses its absolute path; no global install is needed.

Existing private tab: **Give to Agent** / Shift+Cmd+C on Mac, **Ctrl+G / F7** in
the terminal. The footer reports open access and successful request count. **Stop**
closes this tab on Mac; the Agent menu also closes all grants. **F9** closes all
in the terminal. Actual edits/undo/redo, successful file save, tab close, and quitting revoke access.
After 30 minutes without a successful use the reference expires. The Mac GUI also
listens for lock/sleep/session switching; the TUI does not yet have OS-event hooks.

The prepared instruction asks the agent to invoke:

```text
vibechar run <reference> --env API_TOKEN -- <program> [args...]
```

The command reads its required environment variable inside the child process.
The reference and copied instruction contain no secret text. Literal child output
matches are masked, but arbitrary code can encode or transmit a secret; share only
with a trusted task. Keep the originating editor open. This increment works on the
same host and OS user account, including Mac GUI → terminal commands. It is not a
network bridge to remote/cloud agents. See [Secret Drop](secret-drop.md) for the
access boundary, 64 KiB input limit, clipboard providers, and test overrides.

Run `python3 scripts/test-handoff.py` after a release workspace build to exercise
the real TUI plus helper. The harness uses a synthetic Unicode/multiline value,
isolated clipboard providers, and a temporary socket directory. Native smoke uses
a unique AppKit pasteboard; neither test changes the user's clipboard or session.

## Mac session recovery

Mac captures immutable rope snapshots after a 500 ms pause, then encodes/writes on
a serial background queue. Normal Cmd+Q and closing the window flush the latest
state before exit. The next launch restores ordinary tab order, text, active tab, selections,
file destinations, and modified-file flags. Undo histories start fresh after restart.

The default file is `~/Library/Application Support/dev.vibechar.app/session.json`.
It contains ordinary UTF-8 JSON text and has owner-only permissions (directory 0700,
file 0600). Ordinary recovery is local, unencrypted storage. Private tabs are
excluded before serialization. A process
lock prevents two app instances from overwriting the same session. Separate QA
bundle identifiers have separate recovery folders.

Atomic replacement preserves the previous checkpoint on a failed write. Corrupt or
unreadable snapshots are left untouched; the app reports an error and disables
automatic writes for that process. A failed quit flush offers Keep Editing rather
than silently dropping recent text. Background recovery never overwrites an opened
file's original destination; Cmd+S still performs that explicit save.

Force quitting may lose input since the last completed background save. Wait for
"Saved locally" to know the latest checkpoint completed. The 500 ms debounce plus
write time is not a power-loss durability guarantee. Retention and broader
durability qualification remain later work.

## Terminal session recovery

Terminal uses the same Rust checkpoint format and a dedicated worker thread.
After a 500 ms input pause it captures and queues a snapshot; Ctrl+Q waits for the
latest save. An idle session blocks on terminal input. While Secret Drop access
is open it checks status/expiry once per second. The next launch restores ordinary buffers, text, cursor positions,
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

The app is an early prototype. AI,
multicursors, global hotkeys, and search are later
milestones. TUI selection/clipboard and native IME composition qualification are
also pending. No dedicated settings window exists; recovery uses a versioned JSON checkpoint.

Adjacent typing and repeated backspace/forward delete undo as runs in both clients.
A pause of at least one second, cursor/selection movement, newline, paste/cut,
explicit save, undo/redo or changing tabs ends the run. Typing and deletion do not
merge with one another. Paste and selection replacement remain separate undo steps,
including a one-character paste. Undo across a file save restores the correct
modified/clean flag. Groups cap at 512 edits / 64 KiB; a large single paste remains
one step. These limits do not bound total history memory.

Both clients start with one buffer and allow more buffers in the same process.
Both clients restore their separate sessions after restart. Switching restores
the cursor/selection and scrolls it into
view; exact manual scroll positions are not retained. Ordinary adjacent input is
grouped by the shared engine. Mac history restoration copies the document to the view;
ordinary edits send only the changed text to Rust. TUI navigation currently scans
the current line for grapheme boundaries: pathological single-line files need the
M3 large-document work before a performance claim.

Saves are atomic at the file replacement level, but external-change checks,
filesystem race handling, durability/permission edge cases, and a unified file
service are M2 work. Do not use this prototype as the only copy of important text.
Both interfaces reject replacing known symlinks and read-only destinations.
External-change and filesystem-race protection remain unqualified. No network
calls are made by the editor.

## Validation policy

Core tests cover edit history, saved-state identity, invalid ranges, UTF-16 surrogate
boundaries, graphemes/ZWJ, and CRLF. Bridge tests cover malformed inputs and copy
ownership. Terminal tests cover meaningful editing, layout, and quit behavior. The
native smoke test exercises the actual Swift-to-Rust link and Unicode round-trip.

Integration validation must exercise a real pseudo-terminal and the real macOS
application. Keep evidence in `docs/verification.md` and distinguish automated
behavior, observed UI behavior, untested scenarios, and performance hypotheses.
