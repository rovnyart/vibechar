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

Synthetic history memory/latency sample (no files, clipboard or recovery data):

```sh
bash scripts/cargo.sh run --release -p vibechar-core --example profile_history --locked
```

It performs 96 alternating full replacements of a 512 KiB document, samples
process RSS with `ps`, then verifies all retained Undo/Redo steps and the save
point. Run the built example repeatedly for comparisons. These are core-only
samples, not native/TUI input latency or a process-memory ceiling.

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

Shift+arrows/Home/End extends a selection; Ctrl+Shift+Home/End extends to the
document boundary. Ctrl+A selects all; Escape clears selection. Plain Left/Right
collapses it to the corresponding edge. Ctrl+C copies, Ctrl+X cuts after a
successful copy, and Ctrl+V pastes over the selection. Ctrl+Insert / Shift+Delete /
Shift+Insert provide alternate copy/cut/paste keys. Terminal shortcuts such as
Cmd+C may be intercepted by the emulator; use the editor's Ctrl shortcuts for its
own selection. Pasting into Save As/language prompts is supported too.

Typing, bracketed paste, Backspace/Delete and cut replace/delete the selected
range through the shared Rust history. A selection replacement or deletion is an
isolated undo step; Undo restores the text and caret. Copy does not change text,
dirty state or Secret Drop access. Failed copy/cut/paste preserves the selection
and source. Ordinary clipboard reads accept UTF-8 up to 8 MiB, preserving line
endings; Secret Drop retains its independent 64 KiB limit. Providers are the same
pbcopy/pbpaste, wl-copy/wl-paste or xclip adapters. Clipboard access is explicit,
including when copying a private selection; there is no automatic copying.

Mouse reporting is enabled while the TUI is running. Wheel/trackpad scroll moves
the document viewport by three lines per reported wheel event and keeps the caret
in place. An offscreen caret is hidden; typing or keyboard navigation reveals it
again. A left click inside the text area places the caret at the nearest grapheme
boundary, accounting for tabs, wide characters, emoji, and the scrolled viewport.
Clicks beyond a line/document clamp to its end; header/footer clicks and mouse
events while a Save As/language prompt is open do not move the editing caret.
Drag selects text; holding a drag beyond the text area autoscrolls until release.
Double click selects a Unicode word/segment and subsequent drag extends by words.
Shift+click extends the current anchor when the emulator delivers that modifier.
The selection background uses the Pocket light/dark palette, including tabs,
wide glyphs and a marker for selected line breaks. Terminal-owned selection/copy
depends on the emulator's mouse-reporting override (often Shift).

Viewport scrolling does not write recovery or trigger syntax parsing. Selection/
cursor-only
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

## Find and replace

Both clients use the same background Rust find/replace engine. Search starts in
case-insensitive literal mode; enable Match Case (`Aa`) or Regex (`.*`) explicitly.
The current selection seeds a bounded query. Matches are nonoverlapping and
navigation wraps. Search and preview do not change source, dirty state or Secret
Drop access; actual replacements use the shared document/history and revoke a
private tab's grant. No-op replacements create no history and keep grants valid.

On Mac use Edit → Find / **Cmd+F**, or Find and Replace / **Option+Cmd+F**. The
compact Pocket bar shows the query, count, previous/next arrows and toggles. Use
**Cmd+G / Shift+Cmd+G**, or Enter/Shift+Enter in the Find field, to navigate. The
replacement row has **Replace** for the current hit and **All…** for a preview of
up to three changes and the affected count. Its Replace All button applies the
reviewed plan. Escape closes the popover/bar; clicking the canvas returns to editing.
Undo in a native query field edits the query; applying a replacement returns
focus to the document, where Cmd+Z undoes it.

In the TUI use **Ctrl+F / Ctrl+R**, **Tab** between Find/With, **Alt+C** for case,
**Alt+R** for regex, and **F3 / Shift+F3** to navigate. Enter in Find moves to the
next hit; Enter in With replaces the current hit. **F5** opens a batch preview;
Enter confirms and Escape returns to the fields. Another Escape closes the bar.
Fields support Unicode-safe cursor movement/deletion, Ctrl+A and clipboard paste;
query-only input never reaches the document. A canvas click lets you edit while
the panel remains open. Successful replacements return editing focus to the canvas.
File/language prompts retain their own input and footer. Some terminals consume
Alt/modified keys; multi-emulator qualification remains open.

Regex syntax follows the pinned [Rust regex library](https://docs.rs/regex/1.13.1/regex/).
Multiline `^`/`$` respect CRLF; use `(?s)` when dot should cross lines. Lookaround
and pattern backreferences are unsupported. Regex replacement accepts **$0**, **$1**,
**${name}** and **$$**; unknown groups show an error. In literal mode dollar signs
are ordinary replacement text. Empty Find produces no matches; a valid zero-width
regex is supported. Find/replace does not normalize source line endings.

Batch preview is bound to the document identity, revision and current query/options.
Editing, Undo or changing the query invalidates it; a stale plan cannot apply.
Replace All validates every edit before mutation and records one revision/history
transaction. **One Undo** restores the original bytes and saved-state flag. Regex
errors, limits, cancelled previews and no-op replacements leave text unchanged.

Search currently accepts documents up to **4 MiB**, queries up to **1 KiB**, and
replacement fields up to **64 KiB**. Results cap at **10,000 matches**; limited or
failed results cannot be replaced as a partial batch. Expanded output caps at
**8 MiB**, including group expansion. Compiled regex/DFA limits are 1 MiB each,
with nesting limited to 64. A cooperative one-second scan budget is checked
between matches; compilation or a single iterator search can outlast it. This is
not a hard wall-clock deadline or large-document qualification. Parsing, capture
expansion and preview construction run in a latest-wins worker, not on input threads.

Queries and previews are not automatically written to recovery, preferences,
clipboard, history files or diagnostics. Explicit field copy still copies the
selected query. Native recent-search persistence is disabled. Closing the
bar or changing tabs releases the query/plan. Private search/replace remains local
and its source/selection stays excluded from recovery. Ordinary match selection
checkpoints quietly, without flashing Saving locally. Dependency notices are
bundled alongside the existing syntax notices.

## Multiple selections

| Action | Mac | Terminal |
| --- | --- | --- |
| Select word / add next occurrence | Cmd+D | Ctrl+D |
| Select all occurrences / current Find hits | Cmd+Shift+L | Ctrl+L |
| Move all carets / extend all selections | Arrows, Shift+arrows | Arrows, Shift+arrows |
| Line/document boundaries | Cmd+Left/Right, Cmd+Up/Down; Shift extends | Home/End, Ctrl+Home/End; Shift extends |
| Keep only the primary selection | Escape or click the text | Escape or click the text |

With an empty selection, the first Next selects a Unicode word (or an emoji/
grapheme); later requests add following occurrences and wrap. Word-at-caret
matching is case-sensitive and whole-word, so `cat` does not select `category`.
An explicit selection uses literal, case-sensitive fragment matching instead.
All occurrences selects the same kind of matches. While Find is open, All adopts
its actual results, respecting regex/case options and supporting zero-width hits.
A request made before Find completes waits for its current frame. Matches that
split a composed character are rejected; normal occurrence matching filters them.

Typing, Backspace/Delete and newline/tab insertion apply to every range. Paste
distributes **N clipboard lines over N carets/selections**, one line per target in
document order. LF/CRLF separators and one final line ending are omitted during
distribution; intentional empty lines remain empty fragments. If the counts differ,
the complete clipboard text goes to every target. A single caret always receives
the original payload, including its line endings. Empty clipboard text is a no-op.
This also applies to terminal bracketed paste; Enter remains a newline at each caret.
Copy joins nonempty selections in document order with LF separators; cut edits
only after a successful copy. Clipboard failures leave source and selections.
Caret deletion consumes whole graphemes/CRLF. Overlapping selections and colliding
carets merge. Arrows move all carets, Shift extends them; vertical movement uses
logical document lines and Unicode cell columns (tabs every four cells).

Input runs are grouped across all targets. Pause, navigation, paste, newline, save
and changing tabs establish boundaries; groups retain the 512-step / 64 KiB caps.
Every batch changes the document revision once and is atomic. Undo/Redo returns
to one primary caret; it never leaves stale secondary ranges over restored text.
Selection/navigation/copy/no-op operations neither mark text dirty nor revoke
Secret Drop. A real edit revokes access, including in private tabs.

The set is transient: only the primary selection enters ordinary recovery.
Switching tabs, opening Find/tools/language search or ordinary single-selection
editing clears the set. Native IME composition deliberately returns to the primary
selection before composing; arbitrary native word/paragraph commands may do the
same. Private text remains excluded from recovery. No network or source persistence
is added by occurrence matching.

Input/navigation arriving while occurrence matching is pending is queued and
replayed on the full set, never silently applied to just the seed. The queue caps
at 512 actions / 8 MiB text. Copy waits for the set; save/close/tab/mode-changing
commands ask to retry if queued input has not finished, preventing its loss or a
save of stale text. Selection failures discard queued input without partial edits.
IME uses the existing single-cursor history behavior; composition Undo granularity
remains part of native IME qualification.

Initial limits: **4 MiB** source for matching/adoption, **1 KiB** literal seed,
**1,000** selections, **8 MiB** combined removed/inserted bytes per edit. Oversized
match sets fail without a partial Select All; use Replace All for larger batches.
Word-at-caret detection asks for an explicit fragment on lines over 64 KiB.
Navigation/deletion caches per-line grapheme/column maps with an 8 MiB source
budget. Rectangular selections, mouse-added independent carets, rich clipboard
metadata for arbitrary multiline fragments and persisted sets are not implemented.

## Local text tools

Open **Edit → Text Tools… / Cmd+K** on Mac or **Ctrl+K** in the terminal.
Search by title or aliases (`json`, `pretty`, `compact`, `sort`, `dedupe`, `trim`,
`case`, `upper`, `lower`, `url`). Nine tools fit into a five-row scrolling list.
Up/Down chooses and reveals the selected row, Enter applies, Escape cancels;
Mac also supports mouse/trackpad scrolling and clicking rows. The target is the exact selection, otherwise the whole tab,
and is stated above the commands. A partial-line selection is not expanded.
Input stays in the palette while it is open; terminal mouse events cannot edit
the document behind it. An error leaves the original untouched and allows retry.

| Tool | Behavior |
| --- | --- |
| Format JSON | Two-space indentation, document newline convention |
| Minify JSON | Remove JSON whitespace outside strings |
| Sort lines | Ascending, case-sensitive Unicode order |
| Remove duplicate lines | Exact matches, retain first occurrence order |
| Trim trailing whitespace | Remove spaces/tabs at line ends; preserve indentation |
| Uppercase / Lowercase | Unicode case conversion; preserve whitespace and line endings |
| URL encode | Percent-encode a UTF-8 URL component; spaces become `%20` |
| URL decode | Decode `%HH` once; literal `+` remains `+`; reject malformed escapes/UTF-8 |

Case conversion uses Rust's locale-independent [Unicode casing](https://doc.rust-lang.org/std/primitive.str.html#method.to_lowercase).
Characters may expand (`straße` → `STRASSE`, `İ` → `i` + combining dot), so upper/
lower are not guaranteed inverses; Undo restores the original exactly. The resulting
selection accounts for changed character/UTF-16 length in both clients.

URL encode follows the [RFC 3986 unreserved set](https://www.rfc-editor.org/rfc/rfc3986#section-2.3):
ASCII letters/digits and `-._~` stay literal; other UTF-8 bytes become uppercase
`%HH`. It encodes a component, including `/`, `?`, `&`, `+` and existing `%`, rather
than preserving URL delimiters. Decode accepts upper/lower hex, performs exactly
one pass (`%252F` → `%2F`) and preserves raw `+`; this is not HTML form decoding.
It can restore encoded whitespace/newlines/NUL. Malformed escape errors contain
only a target-relative byte offset, and invalid decoded UTF-8 is rejected without
lossy replacement. Commands never open or request URLs.

JSON is validated without serializing through a numeric/value representation:
original number lexemes (including large integers/exponents), key order, duplicate
keys and string escapes survive. Invalid JSON shows only line/column metadata,
never an excerpt. Existing final newlines are retained. Line tools retain the
original line-ending sequence for retained positions and the final-newline state;
sorting compares line bodies. They recognize LF and CRLF, not bare CR separators.

Each explicit command snapshots its target and prepares on a Rust worker. The
target may contain up to **1 MiB UTF-8**; output is bounded at **2 MiB**. URL encoding
preflights its expanded length before allocating the output.
Select a smaller range in a large document. A ready plan applies only to the same
document/revision, through one shared Undo transaction. A no-op creates no history,
dirty state, recovery-write flash or Secret Drop revocation. A real edit revokes
access like typing. Closing the palette cancels application without blocking the
UI; a bounded worker may finish its discarded computation in the background.

Tools are entirely local in ordinary and private tabs. Queries, worker plans and
palette state are not stored in recovery or recent searches. No network/key is
needed. These named reversible tools apply on Enter; AI/recipe proposals remain
separate future features with previews.

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

Ordinary TUI selections retain their anchor and active end across tab switches
and restart, including backward selections. Recovery uses the existing normalized
range plus an optional selection_head endpoint, compatible with version 1
checkpoints. Older ranges default to their end as the active caret. Private
selection metadata is filtered with the rest of the private buffer.

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

The app is an early prototype. AI and global hotkeys are later milestones.
Shared multicursors and TUI selection/clipboard are implemented; acceptance across terminal
emulators/Linux and native IME composition qualification remain pending. No
dedicated settings window exists; recovery uses a versioned JSON checkpoint.

Adjacent typing and repeated backspace/forward delete undo as runs in both clients.
A pause of at least one second, cursor/selection movement, newline, paste/cut,
explicit save, undo/redo or changing tabs ends the run. Typing and deletion do not
merge with one another. Paste and selection replacement remain separate undo steps,
including a one-character paste. Undo across a file save restores the correct
modified/clean flag. Groups cap at 512 edits / 64 KiB; a large single paste remains
one step. Undo and Redo together retain up to **1,024 steps / 32 MiB of charged
history allocations per document**. The engine removes oldest whole steps when
either budget is reached. String and change-vector capacities count toward the
budget. The newest operation always remains undoable, including one operation
larger than 32 MiB; the next edit may expire that oversized step. Eviction never
changes current text, file contents or saved/modified state. History is still
memory-only and is not restored after restart. This is not a total process or
peak-memory limit; full large-document rendering qualification remains open.

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
