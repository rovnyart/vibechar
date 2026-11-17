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

Long-line and snapshot samples:

```sh
bash scripts/cargo.sh run --release -p vibechar-core --example profile_navigation --locked
bash scripts/cargo.sh build --release --workspace --locked
python3 scripts/profile-text.py
# After building the Mac app:
dist/Vibechar.app/Contents/MacOS/Vibechar --profile-snapshots
python3 scripts/profile-mac.py
# Repeat first presentation in fresh processes for one fixture:
python3 scripts/profile-mac.py --kind minified --mib 10 --repeat 5
dist/Vibechar.app/Contents/MacOS/Vibechar --smoke-first-presentation
```

The PTY profiler uses temporary 1/10 MiB JSON files and isolated recovery, takes
30 samples per action, waits for the final checkpoint before sampling RSS, and
checks the original files remain unchanged. `--binary PATH` selects an older
local release binary for comparisons. Snapshot profiling uses only synthetic
in-memory documents, without launching the editor UI or opening recovery state.
The AppKit profiler runs four isolated 1/10 MiB log/minified fixtures through the
real native window, bitmap rendering and history path. It uses unique pasteboards
and no recovery store. `first_screen_ms` includes show, layout, bitmap allocation
and the first bitmap draw. `native_first_frame_ms` also includes window setup and
opening the synthetic document in Rust, but excludes fixture construction and
NSApplication initialization. First typing/Backspace at the start is measured
before jumping to EOF and collecting the repeated input samples. Each child has
a timeout; `--samples` controls the 30 EOF input samples, `--repeat` launches fresh
processes, and `--binary PATH` allows an instrumented pre-change build. Timings are
CPU/render-work observations, not physical screen latency or cold-launch percentiles.

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
wraps a .app bundle with the selected Graphite icon (native catalog plus a
16–512 pt legacy family at 1×/2×), signs both helpers and the app, and runs
the native bridge/interface/Secret Drop smoke tests. A local Developer ID
Application identity is selected when available; otherwise the build is ad-hoc
signed. `VIBECHAR_SIGN_IDENTITY=-` explicitly selects ad-hoc signing. The build
is not copied to `/Applications`. Notarization is a separate release step;
see [Apple signing](apple-signing.md) and [installation](installation.md).

Icon packaging requires Xcode 26+ (`actool`), `sips` and `iconutil`. The selected
source and exact imagegen prompts live in `apps/macos/Artwork/`. Builds compile
the existing artwork; they do not invoke image generation. `Assets.car` and
`CFBundleIconName` provide the modern macOS icon without an extra gray backplate;
`AppIcon.icns` / `CFBundleIconFile` retain the literal older-system family. Both
resources are sealed by the app signature. After replacing a running development
bundle, fully quit Vibechar and reopen that same `dist/Vibechar.app` to refresh its
live Dock icon. No global Dock reset is needed.

`scripts/check.sh` includes a real PTY integration test; run it from a local
environment that permits creating a controlling terminal. The integration test
cleans up its processes and temporary files and uses no desktop terminal app.

Mac controls: native text editing/selection and clipboard; Cmd+T (or Cmd+N) new scratch tab,
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
Cmd+1 through Cmd+8 select the first eight tabs; Cmd+9 selects the last tab,
including when more than nine are open. Unavailable numbered tabs are disabled.
Each buffer remembers its selection and has independent undo history. Cmd+Q or
the red window button preserves ordinary Mac tabs locally
and waits for the final save. Explicitly closing an edited tab asks before removing
it from the saved session. If persisting the last tab's removal fails, Keep Editing
leaves the original tab intact; Close Anyway can leave an older session on disk.

### Indentation, wrapping and position

Both clients use the same Rust editing commands. Tab at a caret inserts spaces
to the next four-column stop. With selected text it indents every touched logical
line by four spaces; a selection ending exactly at the next line's start excludes
that line. Shift+Tab removes one leading tab or up to four leading spaces. Selected
text stays selected, and multiple selections touching the same line indent it
once. Enter replaces the selection with a newline and copies the leading spaces/
tabs before its start. Existing LF/CRLF style is used, including in pasted scratches.
Pasting does not auto-indent or rewrite the clipboard. Each explicit command is
one shared Undo transaction. An outdent with nothing to remove is a no-op.

Mac: **View → Wrap Lines / Option+Cmd+W** toggles native line wrapping and horizontal
scrolling. TUI: **F10** toggles cell wrapping without splitting graphemes. Mac starts
wrapped and TUI starts unwrapped, preserving their existing defaults. The toggle
applies to the current editor session across tabs; it is not stored in recovery.
Wrapping changes presentation only: saved/copied text, line endings, selection,
history, dirty state and Secret Drop grants are preserved. TUI mouse hit testing,
drag scrolling, Up/Down and Home/End use the visual rows when wrapping is enabled;
Ctrl+Home/End still target the whole document.

The footer shows 1-based logical **line:column**, independent of visual wrapping.
Columns use four-cell tab stops and Unicode grapheme display widths. Mac shows
the selection start, or the primary multicursor head; the terminal follows its
active selection head. Mac keeps this indicator visible in narrow/private layouts;
the font-size/UTF-8 detail yields space first. The indicator tooltip/accessibility
value expands the compact numbers into a full line/column description.

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
surface. Line numbers and native line/column indicators are implemented. AI connection
settings, selection rewriting/previews, Do the Rest and saved offline recipes are
implemented below. Named AI rewrite instructions remain later work.

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
Navigation/deletion uses the same Rope-local grapheme walker and sparse geometry
as single-caret TUI editing. Geometry stores up to eight lines × 4,096 points
(1 MiB of point storage per document), coarsening its initial 4 KiB stride as needed.
Rectangular selections, mouse-added independent carets, rich clipboard
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
swap/crash data. Document AI actions enforce private-buffer exclusion before
collecting content. Future diagnostics must do the same. The global AI Settings
test reads no document content.

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

## Line numbers and counters

Line numbers start enabled in both clients. Mac **View → Line Numbers (⌥⌘N)**
and TUI **F12** toggle them for the current client session. The active logical
line is accented; a dot marks a visual continuation. Clicking a number selects
the whole source line, including its newline, without inserting a newline at wraps.

The footer shows text/selection counts and the logical cursor position. Click the
Mac counter or press TUI **F11** for document/selected characters, words, lines and
UTF-8 bytes plus selection/caret totals. Escape/F11 closes the terminal panel;
typing closes it and continues editing. Narrow windows use compact counts; the
detail panel retains exact numbers.

Characters are extended graphemes: `👩‍💻`, `é` and CRLF each count once. Words
are runs of letters/numbers/underscores, not linguistic tokenization. Selected
overlaps and touched lines count once; ending at the next line's start excludes
that line. An empty document has one line. A final newline adds an empty logical
line. Cursor columns still use logical cell geometry/four-column tab stops.

Counting above 4 KiB runs in the shared background engine; exact byte/line metadata
appears immediately. Up to 64 MiB / 500 ms per scan is allowed, with cooperative
cancellation between chunks/graphemes. A dash means a detailed count exceeded the
budget; an ellipsis means it is pending. Statistics do not write text or change
Undo, dirty/recovery state or private grants. Timers stop when counting finishes.

```sh
python3 scripts/test-counters.py
dist/Vibechar.app/Contents/MacOS/Vibechar --smoke-counters
# Optional snapshots of synthetic fixtures only:
VIBECHAR_INTERFACE_SNAPSHOTS="$PWD/dist/counters-ui" \
  dist/Vibechar.app/Contents/MacOS/Vibechar --smoke-counters
```

The optional snapshot mode writes offscreen images of synthetic fixtures only;
it uses no real clipboard or user recovery state and does not order a window.
Legacy PTY coordinate fixtures disable the gutter via `VIBECHAR_LINE_NUMBERS=0`;
the dedicated counters suite explicitly tests it enabled, including wrapping,
mouse selection, private/narrow layout and a 10 MiB file.

## Large text mode

The shared resource policy marks documents from **512 KiB of UTF-8** as large.
Mac **View → Large Text Mode → Automatic / On / Off** controls a client-session
presentation preference. Automatic follows the current document, including edits,
Undo and tab switches. A lightning icon beside the footer counter identifies the
mode; its tooltip explains the active layout path. TUI shows **Large text** in
the footer (or **Large** in narrow terminals); F11 includes a tool-size reminder.
Its viewport renderer already uses bounded Rope windows, so it needs no separate
rendering toggle. Wrap preferences remain independent in both clients.

Wrapped Mac presentation limits paragraph context to **256 Ki glyphs per chunk**,
rounded back to a native composed-character boundary. This can add an earlier
visual wrap at a chunk edge; it adds no character to text storage or the Rust
document. Native input, offsets, selections, clipboard, Undo and saved bytes retain
their full-document meaning. Noncontiguous layout is used for short lines and the
first bounded window of a large paragraph; later caret positions retain the faster
contiguous tail-edit path. In Automatic, a distant selection or paste prepares one
full native paragraph context, reused for subsequent navigation in that revision.
An edit near the beginning returns to bounded context; On forces chunking and Off
keeps standard layout. Transient native EOF selections during text installation
are ignored. No-wrap uses standard native layout. Unicode bidi text
retains full paragraph context, as does a single composed cluster exceeding the
budget. The bidi decision uses pinned `unicode-bidi` data and a revision cache.

The mode improves first-viewport and nearby edit work on giant paragraphs, at the
cost of potentially slower first distant navigation. A fresh EOF reveal can still
do substantial layout on the UI thread; this is **not** a hard wall-time guarantee
or a general large-file performance qualification. Standard mode remains available.

| Operation | Shared limit / behavior |
| --- | --- |
| Syntax | 512 KiB source, 8 KiB logical line, 10,000 lines; uncolored fallback |
| Pointer word selection | 64 KiB logical line; drag selection remains available |
| Find / multiple selections | 4 MiB document; explicit error above the limit |
| Local text tools | 1 MiB selected input, 2 MiB result; small selections work in large documents |
| Statistics | 64 MiB / cooperative 500 ms scan; line/byte metadata remains available |
| Undo + Redo | 32 MiB charged allocations / 1,024 steps; newest oversized step survives |

These are operation limits, not a file-size cap or a total-process memory ceiling.
Large text and mode changes do not weaken private recovery exclusion or grants.

```sh
python3 scripts/test-large.py
dist/Vibechar.app/Contents/MacOS/Vibechar --smoke-large-text
VIBECHAR_INTERFACE_SNAPSHOTS="$PWD/dist/large-ui" \
  dist/Vibechar.app/Contents/MacOS/Vibechar --smoke-large-text
python3 scripts/profile-mac.py --kind minified --mib 10 --repeat 3 --samples 3
python3 scripts/profile-mac.py --large-mode off --wrap on --kind minified --mib 10
python3 scripts/profile-mac.py --load paste --kind minified --mib 10 --samples 3
```

Profiling supports `--large-mode auto/on/off`, `--wrap auto/on/off` and `--load open/paste`.
Paste fixtures use a unique synthetic pasteboard. Their first screen includes
paste/read, model/native update and rendering; clipboard preparation is excluded.
First input is measured at the start, after a separately timed return from EOF.
The report also measures repeated start/end jumps after the context is prepared.
Use identical fixtures and record first screen/input and first distant navigation;
report all trade-offs. Synthetic bitmap timings do not measure physical latency,
cold launch or a Sublime comparison. Broad performance/memory acceptance is M6.

## Layout

```text
crates/core/        shared document, positions, history
crates/bridge/      small C ABI consumed by Swift
crates/terminal/    full-screen terminal client
apps/macos/        AppKit client and Swift package
scripts/           local build and verification entry points
docs/              roadmap, architecture, development, verification evidence
```

## OpenAI connection settings (Mac only)

Open **vibechar → Settings…** with **Cmd+,**. Paste an API key, pick a model, and
click **Test & Save** (Cmd+Return). The test sends only `Reply with the single word
OK.` to OpenAI Responses, with `store: false` and a bounded output budget. It uses
your API billing. No document, selection or clipboard text is read by the adapter.
Opening Settings, searching and selecting a model make no network requests.

The key is stored as a non-synchronizing generic password in this Mac's Keychain
(`dev.vibechar.openai`, account `api-key`, WhenUnlockedThisDeviceOnly). The model ID
alone is saved in UserDefaults (`OpenAIModel`). Reopening Settings shows a read-only
preview such as `sk-…Ab12`, revealing only the fixed `sk-` prefix and last four
characters. Short values are fully masked. **Replace** opens a blank secure input;
**Cancel** discards the replacement and restores the saved preview. The preview is
computed in memory and never becomes an editable key or a saved preference.
A successful test precedes
saving. A failed test or Keychain write keeps the working saved configuration.
**Remove** deletes the saved key; closing Settings clears its in-memory key entries.
Edits, Cancel or closing the window supersede pending requests. A short Keychain
commit already in progress finishes even if the window closes.

**Refresh** lists account model IDs and marks availability within the supported
text-model catalog. It doesn't run inference. A listing permission error still
allows a direct model test. An unlisted model can be tested; listing is advisory.
The initial catalog is Luna, Sol, Terra and Astra; Luna is the default. Model IDs,
Responses support and test reasoning settings were checked on 2026-11-17 against
the official [Luna](https://developers.openai.com/api/docs/models/gpt-6-luna),
[Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol),
[Terra](https://developers.openai.com/api/docs/models/gpt-6.1-terra) and
[Astra](https://developers.openai.com/api/docs/models/gpt-6-astra) documentation.
Luna/Terra tests use `none` with 128 output tokens; Sol/Astra use `low` with 1,024
tokens (including reasoning). Completed text output is required for success.

Provider bodies and raw network errors never appear in diagnostics. Requests use
an ephemeral URLSession with no disk cache, cookies or credential cache, reject
redirects, cap response bodies at 1 MiB, and have 30 s request / 45 s resource
timeouts. There is no retry loop or background account check. The TUI neither
reads this credential nor calls OpenAI. Selection rewriting/diffs are described below.

Run isolated fixtures and native UI/menu checks without real API requests:

```sh
dist/Vibechar.app/Contents/MacOS/Vibechar --smoke-ai-settings
VIBECHAR_INTERFACE_SNAPSHOTS="$PWD/dist/ai-settings-ui" \
  dist/Vibechar.app/Contents/MacOS/Vibechar --smoke-ai-settings
```

The standard Mac build includes this smoke. It uses a temporary UserDefaults suite,
synthetic HTTP responses and a UUID-scoped Keychain service, removed afterward.
For an opt-in live check, enter your key in the UI and click Test & Save; automated
tests never discover real credentials from Keychain, the environment or clipboard.

## Rewrite Selection (Mac only)

Select a single nonempty fragment and choose **Edit → Rewrite Selection…**
(**Shift+Cmd+K**). Enter an instruction, then **Preview changes** (Cmd+Return).
The configured OpenAI key/model is read on that explicit request. Opening the
window, typing instructions and inspecting the source make no provider calls.
The API-billed request contains only the captured selection and your instruction,
with `store: false`; filenames, adjacent text, other tabs and clipboard are excluded.

The window has **Source**, **Changes** and **Result** views. Changes marks removed
and inserted lines; Result shows the complete replacement. **Apply**
(Shift+Cmd+Return) replaces the original selection in one shared history transaction.
**Discard**, Escape or closing the window leave the document alone. Cmd+W closes
the rewrite window. Changing an instruction cancels an in-flight request and
invalidates its preview. Cancel request keeps the source/instruction for retry.

In Source, select a fragment and click **Keep exact**. Marked occurrences are
replaced with opaque placeholders before sending; Rust requires every placeholder
exactly once and in order, then restores the original bytes locally. Changed,
missing, duplicated or reordered placeholders reject the entire proposal. **Clear
kept** removes these transient protections. Protection applies only to the marked
occurrences: other occurrences and your instruction are sent as written. No
automatic secret detector is claimed. Private tabs cannot prepare a rewrite,
including through the C bridge, before source extraction or credential access.

Proposals bind a document ID, monotonic source revision and explicit scalar range.
Generation and Apply recheck the active document; any source edit (including an
Undo back to identical text) makes the proposal stale. Switching tabs or quitting
closes the window and cancels work. Keychain/provider failures and model refusals
leave the text/history untouched. A completed empty replacement can delete the
selection through the same reviewed transaction. Returned text is never executed.

Limits: selection **32 KiB UTF-8**, instruction **4 KiB**, **32 kept fragments**,
replacement **128 KiB**, model output budget **16,384 tokens** including reasoning.
Generated newlines follow the document's CRLF convention where applicable; kept
fragments retain their original bytes. The adapter retains its connection timeout,
body limit, redirect rejection and sanitized errors. It doesn't retry automatically.
Instructions, captures and results are memory-only and excluded from recovery and
preferences; closing clears their UI text/undo state.

Line diffs use an LCS matrix capped at 262,144 cells; larger comparisons show a
block replacement, labeled `block`. Painting starts near the first change and caps
at 4,096 diff lines, labeled `part` with a visible partial-preview notice. Source
and Result retain complete text. Native input stays usable during requests.

```sh
dist/Vibechar.app/Contents/MacOS/Vibechar --smoke-rewrite
VIBECHAR_INTERFACE_SNAPSHOTS="$PWD/dist/rewrite-ui" \
  dist/Vibechar.app/Contents/MacOS/Vibechar --smoke-rewrite
```

Fixtures cover the actual HTTP request, shared protection/apply, stale and delayed
responses, native editing/history and both themes. They use synthetic credentials
and no real API calls. For a live smoke, configure your own key in Settings and
explicitly preview a nonprivate selection; no live credentials are saved by tests.

## Do the Rest: example-based recipes (Mac, M5.1)

Select **two or more complete nonblank rows** and choose **Edit → Do the Rest…**
(**Option+Cmd+K**). The first nonblank selected row becomes **Before**; edit its
copy in **After**. Clicking **Do the rest** (Cmd+Return) sends only that pair to
the configured OpenAI model, using strict Structured Outputs. The remaining rows,
filename, other tabs and clipboard are excluded. The explicit learning request
uses API billing; there are no automatic calls while typing or opening the window.

The shared Rust executor first requires the inferred rule to reproduce After
exactly. It then processes the captured selection locally, including the example
row, and shows **Source / Changes / Result / Rule / Skipped**. Rule explains field
selection and literal formatting; Skipped lists up to eight sample reasons.
Counts distinguish matched, changed, unchanged, skipped and blank records (blank
counts are available in the native frame; blanks are always preserved).
**Apply** (Shift+Cmd+Return) commits one Undo step. At least one record beyond the
example must match before Apply is enabled. Editing the source makes the capture
stale; changing tabs, Cancel, closing or quitting discards pending work.

Recipe v1 supports whole rows (`$`), exact literal delimiters (zero-based fields or
`last`), top-level scalar JSON fields (`/name`, with JSON-pointer key escaping), and
key/value around the first `=`. Parts may trim, change Unicode case, add literal
prefix/suffix and encode text or typed JSON. JSON output uses typed encodings;
numeric lexemes, including huge integers and exponents, are retained. Text fields
remain strings. Missing fields, malformed/duplicate-key JSON, unsupported types
and oversized row results are skipped without changing their original bytes.
Each original LF/CRLF ending is preserved, including mixed endings and final newline.

This pass is **per row**, suitable for JSONL, simple delimited text, links, case/trim
and per-row env→JSON. Pretty multiline JSON records, nested field extraction,
quoted CSV parsing, arbitrary substitutions, aggregating many rows into one object,
semantic rewriting and guessed conversions are outside v1. Unsupported inference
produces an error with a Rewrite Selection suggestion. No fallback sends the target
rows to the provider. A single example is inherently ambiguous; inspect Result.

Budgets: target 256 KiB / 4,096 physical lines; example Before and After 4 KiB each;
inferred JSON rule 16 KiB / 12 parts; literal pieces 256 bytes; delimiter 16 bytes;
64 fields per row; input/result row 16 KiB; complete result 1 MiB. Provider output
budget is 4,096 tokens including reasoning. Apply uses privacy/identity/revision
checks and shared history. Private buffers are rejected before source extraction
or credential access. Example/source/result are memory-only. A validated rule can
be saved explicitly with **Save Recipe…**; separately saved AI prompts remain open.

```sh
dist/Vibechar.app/Contents/MacOS/Vibechar --smoke-examples
VIBECHAR_INTERFACE_SNAPSHOTS="$PWD/dist/examples-ui" \
  dist/Vibechar.app/Contents/MacOS/Vibechar --smoke-examples
```

The core fixture set has 11 supported demonstrations with unseen target inputs,
plus unsupported/ambiguous cases. Native fixtures check the actual provider request
shape, local planning, skips, cancellation/stale protection and editing/history.
They use synthetic credentials and no live requests. Test real inference explicitly
in the UI using your configured key.

## Saved recipes (Mac, M5.2)

1. Teach a rule using **Do the Rest…**, then inspect its Changes, Result and Rule.
2. Before Apply, choose **Save Recipe…** and give it a unique name (1–80 characters).
3. Select complete lines in another ordinary tab, then use **Edit → Saved Recipes…**
   (**Option+Cmd+R**). Search by name/structural summary; arrows choose, Return previews.
4. Inspect the local preview, then Apply. One Undo reverses the entire change.

The library supports rename and confirmed deletion. A recipe may process a single
row; no demonstration pair, API key or network is needed for replay. A mismatching
first row does not block later matches. Unmatched/blank rows and original LF/CRLF
endings stay intact; zero matches or zero changes disable Apply. Source changes,
tab switching, close and cancellation prevent late application. Private tabs refuse
saved recipes in this increment, as they do example capture.

Only UUID, name and validated recipe JSON are stored at
`~/Library/Application Support/dev.vibechar.app/recipes.json`. The library version
and each rule's schema version are checked; the file is atomically replaced with
0600 permissions. Source rows, teaching pairs and previews are excluded. Literal
text in the rule is saved. Up to 100 recipes / 2 MiB are supported; existing rules
are never silently overwritten by a duplicate name. Corrupt/unsupported libraries
stay untouched and block writes with an explicit error.

Replay retains the 256 KiB / 4,096-line target, 16 KiB rule/row and 1 MiB result
budgets. The teaching example's 4 KiB size limit does not apply to replay rows.
Recipe format and supported per-row operations are unchanged; multiline records,
aggregate conversion, interactive type choices and saved AI instructions remain open.

```sh
dist/Vibechar.app/Contents/MacOS/Vibechar --smoke-recipes
VIBECHAR_INTERFACE_SNAPSHOTS="$PWD/dist/recipes-ui" \
  dist/Vibechar.app/Contents/MacOS/Vibechar --smoke-recipes
```

The smoke uses a disposable library, a unique clipboard and synthetic data. Trap
credential/provider implementations fail immediately if offline replay accesses
them. It checks persistence through a fresh store, naming/rename/delete, corrupt
and future versions, write failures, skip/stale/cancel/private guards, actual native
menu/search/preview and both Rust/AppKit text through Undo/Redo. The example smoke
also exercises saving a learned rule through the native callback and reopening it.

## M1 limitations

The app is an early prototype. Global hotkeys remain a later milestone.
AI settings, rewriting, example learning and the recipe library are Mac GUI-only.
TUI remains a local editor with Secret Drop.
Shared multicursors and TUI selection/clipboard are implemented; acceptance across terminal
emulators/Linux and native IME composition qualification remain pending. No
general editing settings pane exists yet; recovery uses a versioned JSON checkpoint.

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
grouped by the shared engine. Mac Undo/Redo normally patches only changed ranges
in its native presentation. The engine still owns and applies the single history
operation. Frames cap at 1 MiB estimated encoded JSON / 4,096 edits; oversized
frames, marked text or a mismatched presentation length use a full snapshot.
Inserted ranges retain the current font/paragraph settings, including after an
Undo to empty and subsequent Redo. Ordinary edits send only the changed text to
Rust. Mac snapshots fill the Swift
String directly without an intermediate byte array. TUI Left/Right/deletion walks
Rope chunks, while column/mouse/vertical movement reuses sparse line checkpoints.
Only visible whole graphemes are copied for painting; selection, Find and syntax
keep their original scalar/UTF-16 offsets. Edits/history invalidate the affected
suffix, retaining the preceding checkpoints. A first distant column lookup scans
its prefix. Giant composed graphemes/context and word double-click can still do
large work. AppKit uses demand-driven layout and selects contiguous versus
noncontiguous layout from the caret line's length (32,768 UTF-16 units). A giant
wrapped paragraph still has expensive first layout. Peak memory and cross-platform qualification
remain open before a general large-document performance claim.

Saves are atomic at the file replacement level, but external-change checks,
filesystem race handling, durability/permission edge cases, and a unified file
service are M2 work. Do not use this prototype as the only copy of important text.
Both interfaces reject replacing known symlinks and read-only destinations.
External-change and filesystem-race protection remain unqualified. Network calls
are made only by explicit Mac AI Settings, Rewrite Selection and Do the Rest actions.

## Validation policy

Core tests cover edit history, saved-state identity, invalid ranges, UTF-16 surrogate
boundaries, graphemes/ZWJ, and CRLF. Bridge tests cover malformed inputs and copy
ownership. Terminal tests cover meaningful editing, layout, and quit behavior. The
native smoke test exercises the actual Swift-to-Rust link and Unicode round-trip.

Integration validation must exercise a real pseudo-terminal and the real macOS
application. Keep evidence in `docs/verification.md` and distinguish automated
behavior, observed UI behavior, untested scenarios, and performance hypotheses.
