# Prototype verification

Started: 2026-11-11. Latest increment: 2026-11-17.
This records local engineering evidence. Art accepted the functional MVP scope on
2026-11-17; distribution and broad performance qualification remain separately tracked.

## Environment

- Apple M5, 16 GiB RAM, macOS 27.0.1 (26A434), Apple Silicon.
- Rust 1.99.1, Swift 6.4.2, release builds for runnable clients.
- Local builds use Developer ID when available, with ad-hoc fallback. Distribution
  validation now includes Apple notarization and isolated installation; see the
  distribution entry below.

## Automated checks

- 160 Rust tests across document/history/Unicode, sessions/recovery, Secret Drop,
  syntax, find/replace, local tools, the C bridge and terminal model/layout.
- Rust formatting and Clippy with warnings as errors.
- Rust release workspace build and Swift release link.
- Mac AI Settings smoke: isolated Keychain, synthetic HTTP responses, safe failures,
  model preferences, cancellation/stale checks, native controls and menu routing.
- Native Swift ↔ Rust smoke test: embedded NUL, Russian text, UTF-16 rejection,
  emoji substitution, undo/redo, dirty tracking, and saved-state reset.
- Native input smoke exercises AppKit typing/deletion, isolated one-character
  clipboard insertion, selections/navigation, newline, save and tab boundaries
  against the shared document history.
- Native first-presentation smoke checks stable initial container width, a 256 KiB
  paragraph with Unicode/NUL/CRLF, first input and history, complete selection/copy,
  tab/caret restoration, private tabs, narrow/wide layout and light/dark appearance.
- Native last-tab close checks: Cmd+W action, the real tab close button, empty
  private tab, multiple-tab behavior, close notifications/termination decision,
  removed-tab recovery versus whole-window recovery.
- Fifty-five real PTY scenarios across the baseline, selection, find, tools,
  multicursor, history, large-text, editing/wrapping and counters suites,
  including bracketed paste + undo/redo + byte-exact UTF-8/CRLF save;
  unsaved-change protection; piped stdin with interactive keyboard; scratch save-as;
  failed read-only save preserving the previous destination; two independently
  saved buffers with restart/cursor restoration; background checkpoint + forced
  termination; closed tabs staying closed; corrupt recovery; concurrent writer
  rejection; and failed quit flush with manual text rescue before explicit quit.
- Save As PTY coverage includes existing file tabs, cancelled prompts, failed and
  read-only/symlink destinations, replacement confirmation/reset, Unicode paths,
  subsequent Save to the new path and restart with that destination.
- Grouped-input PTY coverage includes typing/redo, an actual input pause,
  cursor-away-and-back, one-character paste, backward/forward deletion and clean
  save-point restoration.
- Private PTY cases verify mixed/private-only recovery, background exclusion,
  conversion after successful file save, cancelled/failed saves, subsequent saves,
  hidden-private quit confirmation, and forced termination.
- An additional real PTY + helper scenario verifies Secret Drop clipboard actions,
  exact injection, reuse, literal stdout/stderr masking, exit status, failed-copy
  revocation, edited/revoked/wrong references, quit, recovery exclusion, and grant
  preservation on cancelled/failed saves versus revocation on successful save.
- PTY checks verify terminal attributes, alternate screen, and bracketed paste
  restoration on exit. All temporary processes/files are cleaned up by the harness.

The piped-input integration test exposed a real input-reader failure. Crossterm's
`use-dev-tty` feature fixes it by separating piped document data from keyboard input.

Reproduce with `bash scripts/check.sh`. This also rebuilds the local .app.

## Observed native UI

Opened the real AppKit app, pasted Russian text + a ZWJ emoji + JSON, used Cmd+Z
and Shift+Cmd+Z, saved through the native save panel, and independently compared
the saved UTF-8 bytes. The 60-byte file matched exactly. Text was visible and editable
with native scrolling, selection, clipboard, title, and menus available.

The user started interacting with this window during verification; it was left
running and subsequent user edits were preserved. Native IME, VoiceOver, failure
dialogs, light appearance, and large-file behavior have not been qualified.

### Feedback increment: scratch buffers

Baseline is preserved in local initial commit `5462194`. The next increment was
tested in a separately identified QA app, leaving the user's original window alone.
Observed: create two scratch tabs, switch by clicking, insert at the remembered
Unicode cursor, undo independently in both tabs, warn on quit when only a hidden
buffer is dirty, cancel the warning, close a clean buffer, warn on closing an edited
buffer, and create a fresh empty scratch after closing the final clean buffer.
The QA instance was then quit. No scratch recovery or autosave was added.

### Feedback increment: Mac restart recovery

Art's next test identified the missing restart behavior and rejected the visual
quality. This increment adds Mac recovery; the dedicated interface work is now
the next feedback step rather than a late cosmetic task.

Native disk/bridge smoke tests verify a checkpoint round-trip, Unicode selection,
owner-only file permissions, and a second writer being refused. Core tests also
cover immutable background snapshots, dirty/file metadata, corrupted/invalid
snapshots, closed tabs staying closed, and failed replacement preserving data.

In an isolated real QA app, entered two tabs with Russian, JSON, and emoji, used
Cmd+Q, relaunched, and observed both tabs and the selected tab restored. Inserting
at the remembered cursor produced the expected position before a surrogate-pair
emoji. Verified a completed background checkpoint, SIGKILLed only the QA process,
and relaunched: tabs and text survived without a graceful quit. Explicitly closed
one tab and restarted again; only the remaining tab returned. Quit the QA instance.
The user's original app/window and its storage were not used for these tests.

The 500 ms debounce leaves a small unsaved-input window on force quit; normal Cmd+Q
flushes it. No claim is made about power-loss durability, private buffers, or undo
history after restart. Terminal recovery is not enabled in this increment.

### Feedback increment: terminal recovery parity

Preserved the earlier buffer/Mac recovery work in local commit `8fab1af`, then
connected terminal recovery to the shared checkpoint format. Real PTY tests use
private temporary directories and do not touch either default client session.

Observed two independently saved buffers returning with the saved active buffer
and cursor. Reopening an existing file selected its recovered edits instead of
duplicating/reloading the buffer. Piped input was retained on quit; background
recovery left original files unchanged. A completed checkpoint survived SIGKILL,
and an explicitly closed tab stayed closed on the next launch.

Verified corrupt checkpoints and second writers are rejected before raw mode.
Blocked a recovery destination: Ctrl+Q kept the editor open, Ctrl+S rescued the
text to a separate file, and explicit repeated Ctrl+Q quit with terminal attributes
restored. Core worker tests also cover retrying after a failed save and final flush
ordering after queued writes. Linux end-to-end validation remains pending.

### Feedback increment: native Pocket interface (2026-11-12)

Replaced the stock segmented-control shell with the approved Pocket direction:
a 54 pt title/tab row, native traffic-light buttons, per-tab close/new controls,
active-tab-preserving overflow menu, warm orange `V_` mark, light/dark canvas,
selection/cursor styling, text zoom, empty hints, and a quiet session footer.
Scratch labels use at most 256 source scalars and 32 displayed graphemes; files
keep their names. A file modification marker is separate from recovery state.

Full `scripts/check.sh` passed with 29 Rust tests, formatting/Clippy, release builds,
10 real PTY scenarios, the bridge/recovery smoke tests, and native chrome geometry
tests across 420/560/880/1600 pt with up to 14 tabs. Native window tests exercise
the actual composition in light/dark at 420/880 pt, verify typography preserves
text/history, and distinguish scratch recovery from file modification state.
Mouse hit tests cover the three real system window buttons and every visible
header control. Native titlebar space is reserved through an AppKit accessory;
the system button group retains its own geometry and aligns to the tab row.
The offscreen tests allow the native window/appearance layout to settle before
checking coordinates and visible button bounds.

In the isolated on-screen `dev.vibechar.pocket-qa` app, observed the dark interface,
three restored synthetic buffers, switching by click/keyboard, Russian/ZWJ emoji
insertion and undo, immediate focus in an empty scratch, 14-tab overflow, selecting
a hidden buffer, closing an inactive clean tab without changing the active text,
and cancelling an inactive dirty tab's close confirmation. The graceful quit
checkpoint contained 13 tabs and the expected active Unicode text. A subsequent
launch showed recovered buffers; user interaction resumed during this QA session.
The user's normal app session was never used or replaced for these checks.

Rendered and visually inspected real AppKit content views in light at 880 pt and
dark at 420 pt. Captures are generated under ignored `dist/pocket-ui/`; these do
not include system window controls. The live dark-window screenshots also showed
the system's capture/sharing indicator over the traffic-light region.

An initial PTY run stalled while waiting for a deliberately SIGKILLed test process
to exit and was interrupted. An isolated signed-copy rerun and then the unchanged
standard full check passed. No test terminal processes remain. The latest full
check's single TUI startup sample was 759.28 ms / 2,960 KiB RSS; startup variance
remains unresolved and no speed improvement is claimed for this UI increment.

Native full-screen transitions, VoiceOver, IME composition, keyboard focus-ring
qualification, and interactive save-failure presentation still need acceptance.
App icon work, syntax highlighting, AI, line numbers, and position indicators are
not part of this increment. Art accepted the first working Pocket interface on
2026-11-12, before the private-scratch increment.

### Feedback increment: private scratches (2026-11-12)

Historical behavior below used Save a Copy and kept the tab private. Art's later
save feedback supersedes that behavior; see the private-save increment below.

The shared session owns private flags. Checkpoint capture filters those buffers
before cloning any text/path/selection; active indices are remapped and a
private-only session saves an empty ordinary fallback. Existing version-1
checkpoints remain compatible. No conversion of an ordinary buffer is offered.
The Mac window disables AppKit state and snapshot restoration at construction;
custom recovery and geometry-only window preferences remain enabled.

Full checks passed: 35 Rust tests, formatting/Clippy, release builds, 12 real PTY
scenarios, and Swift-to-Rust/native window smoke tests. New core tests inspect raw
encoded bytes and restored state, including a private buffer with a path and a
clean dirty flag. Private text still requires close/quit confirmation. TUI tests
cover cancellation by navigation/paste, close/quit confirmation isolation, and a
visible mode label after ordinary recovery completes. The native smoke checks
generic titles, persistent private
status, and a real filtered checkpoint round trip.

In the isolated `dev.vibechar.private-qa` Mac app, created private text with
Shift+Cmd+N and observed the lock, generic tab/window title, and "Private · not
recovered" status. Inspected actual background recovery files: only the ordinary
fixture remained. Saved an explicit file through the native panel, which explains
disk persistence, and compared its UTF-8 bytes exactly. The tab stayed private.
Cmd+W asked before discarding, Keep Editing preserved it, and Cmd+Q also asked
while the private tab was hidden. Cancelled quit and observed both tabs intact.
Confirmed quit, reopened, and observed only the original ordinary tab restored.
The explicit copy still existed; the private fixture was absent from recovery.

Only synthetic text was used. The QA process, bundle, recovery folder, preferences,
and explicit test copy were removed afterward. The user's normal app/session were
not used or modified. The PTY crash case verifies that a private-only session
returns empty after forced termination; a Mac force-quit was not separately
repeated for this increment.

An intermediate PTY run stalled in a blocking wait after SIGKILL and was
interrupted. The harness now drains output during bounded force-stop waits and
closes PTY descriptors in a finally block. The subsequent standard full check
passed, including both forced-stop cases. No QA or test-terminal processes remain.

Explicit exports persist by design. The feature does not erase earlier ordinary
snapshots or promise protection from OS swap/crash data, clipboard history, or
external screen capture. There are no AI/actions/diagnostic upload routes yet;
those future routes must enforce exclusion independently. Art's private-mode
hands-on feedback is the next checkpoint. One verification run's single TUI sample was
341.01 ms / 2,976 KiB RSS; existing startup variance remains unresolved.

### Feedback increment: Secret Drop (2026-11-12)

Added the shared memory-only local broker, explicit private-tab grants, and
`vibechar run` environment injection. The helper is bundled with the Mac app and
dispatches independently of TUI/recovery. Both clients provide Paste Secret for
Agent and Copy for Agent; Mac shows access/use count with Copy Again and Stop,
and the terminal exposes Ctrl+G/F7, F8 and F9. No model/provider integration or
MCP setup is needed for this local workflow.

Full `scripts/check.sh` passed: formatting, Clippy with warnings as errors, 39 Rust
tests, release builds, the 12 existing PTY scenarios plus the Secret Drop scenario,
and native bridge/window checks. The final native termination check also passes.

Core tests exercise exact Unicode injection, reusable grants, wrong/expired and
cross-instance references, safe socket permissions, oversized frames, no-op versus
real edits, undo/redo, Stop, close, session drop, and absence from recovery JSON.
Metadata reads do not extend expiry. Terminal tests verify streaming masking across
read boundaries and repeated prefixes. Real PTY checks launch the release helper,
compare the child environment internally, intentionally emit a disposable fixture
on both streams and verify redaction plus exit code 7. Invalid, revoked, edited,
and post-quit references fail before a marker-writing child can start. A failed
instruction copy revokes an existing grant. Restart restores only the ordinary tab.

The native smoke test runs the actual AppKit clipboard action with a unique
pasteboard and invokes the bundled helper. It verifies exact child injection,
masked output, exit status, use counts, Stop/termination hooks and failure before
child execution. Closing all access also shuts down the broker and removes its socket.
It checks real footer geometry and hit targets in light/dark at 420/880 pt.
Only synthetic values and isolated clipboard providers/pasteboards are used;
the user's clipboard, running app and session store are untouched.

Visually inspected generated native content views at 420 pt dark and 880 pt light.
Buttons remain visible at the narrow width, where font/encoding details hide first.
Stricter checks exposed an existing titlebar accessory sizing issue: its fixed
width prevented the window from reaching the requested narrow size. The spacer
now constrains only height, and tests assert the actual content width. Earlier
native narrow-window captures did not prove a 420 pt composed window; standalone
header layout tests were separate. The new captures have the requested dimensions.
These are offscreen AppKit checks, not a new on-screen user acceptance session.

The Mac GUI registers lock, sleep and session-resignation revocation hooks.
Actual OS-event delivery, Linux execution/clipboard providers and terminal
lock/sleep behavior remain unqualified. No remote/cloud-agent transport exists.
Output masking covers literal occurrences; arbitrary child code can transform or
transmit a secret and already delivered values cannot be revoked. Art's hands-on
Secret Drop feedback is the next gate.

### Feedback increment: saving ends private mode (2026-11-12)

Art reported that Cmd+S wrote a file but left the tab private. Successful Save now
turns the same tab into an ordinary file tab in both clients. The shared completion
operation attaches its path, marks the document saved, ends private mode and
revokes only that tab's Secret Drop grant. Text, selection, tab identity and undo
history survive. Other private tabs remain private. Future recovery includes the
saved tab; subsequent Save writes the attached file without a filename prompt.
Save UI and current product docs explain this behavior. Failed/cancelled saves
preserve the original private mode, path, dirty state, and agent grant.

Core/bridge regressions cover conversion, invalid inputs, unchanged revision and
selection, other-tab isolation, grant revocation, recovery and undo after conversion.
Native AppKit smoke exercises the same file-write path as Cmd+S with disposable
UTF-8 fixtures: failed writes and rejected symlinks remain private with live access,
successful saves show filename/ordinary footer and hide private controls, the old
reference fails before child execution, checkpoint restart restores an ordinary
file, and the next actual Save action writes the same file without opening a panel.

Real PTY checks exercise cancellation, failure, successful conversion, repeated
saving, restart, and hidden unsaved-private exclusion/confirmation. The separate
Secret Drop PTY check proves access still works after cancellation/failure and
is rejected after successful saving. The user's app, clipboard, files and session
store are not used by these checks. Native save-panel wording/cancellation remains
for Art's hands-on acceptance; automated native writes use the selected destination
directly rather than interacting with the panel.

Full `scripts/check.sh` passed with 41 Rust tests, formatting/Clippy, release builds,
12 existing PTY scenarios, the Secret Drop PTY scenario and native smoke checks.

### Feedback increment: closing the final Mac tab (2026-11-12)

Art reported that closing the final tab created another scratch instead of allowing
the app to close. Cmd+W and the tab's × now share one close operation. For the final
tab, existing discard checks run, an empty recovery checkpoint is flushed before
the live document is dropped, and the actual window closes. The app's existing
last-window policy then allows termination. No empty replacement is displayed.
Whole-window close and Cmd+Q retain ordinary recovery; explicit final-tab closure
removes that tab from it. The TUI keeps its existing empty-buffer fallback.

A failed final-tab recovery flush offers Keep Editing, which preserves the original
document, or Close Anyway, which warns that an earlier session could return.
Successful closure skips a second quit confirmation/flush, stops agent access,
and prevents pending view events from queuing recovery of the discarded text.

The release AppKit smoke passed with isolated windows, pasteboards and recovery
directories. It observes actual window-close notifications for the Cmd+W action,
the real tab close button, an empty private tab, and a multi-tab session reduced
to its last tab. It checks `.terminateNow`, the last-window termination policy,
and that restart contains one empty scratch after explicit final-tab closure.
A separate red-window-close case retains the ordinary text for restart. Existing
Pocket, private-save and Secret Drop native smoke checks also pass. No running
user window, clipboard or recovery store was used. Interactive discard/error
dialogs and the complete on-screen quit workflow remain for hands-on acceptance.

### Hands-on checkpoint: Secret Drop (2026-11-12)

Art pasted instructions from Give to Agent in a Mac private tab. The local bundled
helper ran a child that reported only whether it received a nonempty environment
value; it returned success. This proves delivery, not equality to an independently
known value. Art clicked Stop; using the same reference then returned a closed/
expired error with status 1 before the marker-printing child could start. No raw
value was printed, copied to a file or retained in this document. Art also confirmed
the private-save conversion after restarting the updated app. Mac Give/Stop is
accepted; terminal manual use, clipboard fast paths and OS-event gates remain open.

### Feedback increment: Save As (2026-11-12)

The next bounded M2 increment adds File → Save As / Shift+Cmd+S on Mac and F4 in
the terminal. Both work on existing file tabs as well as scratches. Success attaches
the chosen destination for future saves/recovery without creating a second tab.
Cancellation and write failures preserve the previous path, edited text, dirty
state and selection. Known read-only files and symlinks are rejected in both clients;
external-change/race handling and durability qualification remain pending.

Native smoke checks the menu/shortcut, current filename/folder prefill, cancelled
selection, failed/missing/read-only/symlink destinations, successful replacement,
byte-exact Unicode/CRLF, preserved selection/history, regular Save to the new path,
an untouched original file, and restart with the new destination. Destination
choices are supplied to the same Save/Save As path without opening modal panels.
The native replacement confirmation itself still needs Art's hands-on acceptance.

The additional real PTY case presses F4 on an edited file, cancels, attempts failed
destinations, declines then confirms replacement, verifies filename edits reset
approval, saves again to the new destination, and restarts. Until explicit approval
the existing target remains unchanged. All fixtures, clipboards and recovery stores
are isolated from the user's normal app/session. Full `scripts/check.sh` passed:
41 Rust tests, formatting/Clippy, 13 PTY scenarios, the Secret Drop PTY scenario and
native release smoke tests. The expanded filename-approval reset case also passed.

### Routine increment: grouped Undo/Redo (2026-11-12)

Art asked to self-test and commit routine mechanics, reserving hands-on checks for
notable features and interface decisions. The roadmap delivery policy now reflects
that. This increment adds shared input-run grouping in Mac and terminal. Adjacent
typing, repeated backspace and repeated forward delete group separately until a
one-second input gap, explicit boundary, 512 edits or 64 KiB of changed payload.
History stores ordered deltas without repeatedly prepending deleted text or copying
the document. Large individual pastes remain atomic. Total history limits, IME
composition qualification and grouped multi-edit transforms remain separate work.

Core tests use a controlled monotonic clock to verify pause boundaries without
sleeping. They cover Unicode/ZWJ/combining sequences, forward/backward cursors,
CRLF/Unicode line separators, explicit boundaries, isolated paste and selection
replacement, saved-state identity, divergent edits, group bounds and invalid/no-op
requests. Bridge tests cover grouped UTF-16 conversion and malformed input kinds.

The release AppKit smoke calls native input methods and checks the actual text view
against Rust after each undo/redo. It covers automatic caret movement versus user
selection, emoji deletion, a unique-pasteboard one-character insertion, selection
replacement, newline, saved-state flags and independent tab histories. The real PTY
scenario exercises the same commands, including an actual 1.1-second pause and
backspace/delete key sequences. Existing Secret Drop tests still prove edit/undo
revocation: restoring old text never restores the old capability. The user's app,
clipboard, files and recovery store are untouched by these checks.

Full `scripts/check.sh` passed: 49 Rust tests, formatting/Clippy, release builds,
14 PTY scenarios, the Secret Drop PTY scenario and all native smoke checks.

In a separate on-screen `dev.vibechar.undo-check` app, pressed a/b/c individually:
one Cmd+Z cleared the run and Shift+Cmd+Z restored it. Two Backspace presses were
undone together. Left/right between typing runs separated the next undo, and a
one-character paste stayed separate from the following typed run. Observed each
result in the actual text view. Only disposable synthetic text was used; the paste
automation restored the clipboard. Quit the QA app and removed its bundle,
registration, recovery and preferences. No manual checkpoint is required for Art
on this routine increment.

## Smart syntax increment — 2026-11-12

Both clients now run shared local syntax detection and background highlighting.
The pinned catalog reports 186 visible grammars, not 186 automatic content detectors.
Tests cover filename/manual precedence, shebangs, 15 common content families,
conservative prose/token fallback, JavaScript/Python import ambiguity, UTF-16
ranges, source-free paint metadata, incremental equivalence after late-line edits
and multiline-comment changes, unchanged-prefix reuse and latest-request wins.
Document revision, language and path changes reject obsolete results. Ordinary
language pins survive checkpoint load; private text and pins are excluded.

Full `scripts/check.sh` passed: **56 Rust tests**, formatting/Clippy, release builds,
**16 real PTY scenarios**, the Secret Drop PTY scenario and all native smoke checks.
The syntax PTY scenario verifies truecolor output, F2 extension search, pinning,
Escape, restart, Auto reset, unchanged text and private recovery exclusion. It
explicitly clears the inherited NO_COLOR only in the color assertion session;
the editor continues respecting NO_COLOR normally.

Native checks verify colored UTF-16 ranges, text/selection/Undo preservation,
Auto/manual/Auto switching, and footer button geometry at 420/880 pt with private
Give/Stop controls. The picker checks bounded results, extension aliases, Enter
arriving before an async query returns, empty results and Escape. Actual offscreen
renders were visually inspected in both appearances: ignored
`dist/syntax-ui/syntax-{light,dark}-{420,880}.png` and
`language-picker-{light,dark}.png`. Picker images render its real view against a
Pocket surface; they do not capture the system popover's material or shadow.

A separate on-screen `dev.vibechar.syntax-check` bundle verified: automatic Swift
colors, click and Control+Cmd+L invocation, `py` search via individual keypresses,
Return pinning, Escape keeping the pin, persistence after Cmd+Q/relaunch, clicking
Auto to restore Swift detection, and live Light/Dark appearance. A synthetic
private JSON paste detected JSON; one Cmd+Z cleared it and returned the badge to
Text. Original text and editor focus were preserved when choosing languages.
The automation's general typeText helper targeted the main editor despite an
open popover; that synthetic insertion was undone and the actual search was
verified with individual keys instead. The user's existing app/recovery remained
untouched; the paste automation restored clipboard contents. Removed the QA bundle,
registration, recovery and preferences after quit.

Single-sample full-suite paste-to-Auto-JSON time was 151.95 ms including the 120 ms
debounce; highlighted TUI RSS was 8,592 KiB. Additional local release/PTY observations:

| Synthetic workload | Paste to detected/limited label | Next edit to PTY screen | Process RSS |
| --- | --- | --- | --- |
| 2,000 JSON records, 58,000 bytes | 180.63 ms | 0.61 ms | 10,672 KiB |
| One 12,011-byte JSON line, limited preview | 157.95 ms | 1.91 ms | 6,432 KiB |
| One 1,048,587-byte JSON line, limited preview | 256.81 ms | 21.66 ms | 12,896 KiB |

Ten empty warm TUI launches observed a 4.64 ms median first frame, 227.20 ms maximum,
and 3,344 KiB median RSS. These include Python/process/PTY startup and are neither
cold-launch percentiles nor terminal-display latency. The 1 MiB edit still has
presentation/line-processing cost despite uncolored parsing fallback. Size/line
fallback and span budgets are explicit in the development guide; the 160 ms worker
slice is cooperative between lines and is not a hard per-regex deadline.

The isolated Mac process reported **136,640 KiB RSS (about 133.4 MiB)** after Swift
highlighting, language search, restart and a theme switch. This exceeds the
provisional Mac budget. It is a different workload from earlier observations and
does not isolate the grammar cost. Raw supplemental measurements are in ignored
`dist/syntax-measurements.json`. No Sublime comparison, peak-memory qualification,
Linux runtime check or multi-emulator color acceptance has been performed.
Art's visual/interaction feedback on this new feature is the next checkpoint.

## Terminal mouse and quiet navigation — 2026-11-12

Mouse reporting was previously disabled, allowing an emulator to translate wheel
gestures into arrow keys. The event loop also restarted recovery/syntax deadlines
and displayed Saving locally for every key, including navigation and prompts.

The TUI now enables mouse reporting for its lifetime. Wheel events scroll the
viewport independently of the caret; redraws and background syntax results do not
snap back to it. Offscreen carets are hidden, keyboard editing/navigation reveals
them, and left clicks map screen cells to whole grapheme boundaries. Mapping
accounts for the body origin, viewport offsets, tabs, wide characters, combining
marks and ZWJ emoji; clicks beyond a line/document clamp to its end. Prompts and
chrome clicks do not move the caret. Drag selection remains pending.

Recovery/syntax scheduling compares document identity/revision and persisted tab
metadata instead of treating every input as an edit. Cursor-only changes checkpoint
quietly and do not postpone an already pending text write. Scrolling changes no
persisted state and submits no recovery request. Mouse/bracketed-paste modes are
disabled on ordinary/error exit; panic cleanup is also installed, but not fault
injected in this increment.

Full `scripts/check.sh` passed: **59 Rust tests**, formatting/Clippy, release builds,
**19 real PTY scenarios**, Secret Drop integration and native AppKit checks. New PTY
cases inject actual SGR wheel/click/release sequences through the release parser:
scrolling changes the displayed first line, keeps the status caret at 1:1, and
leaves recovery bytes and modification time unchanged beyond the debounce window.
Clicking a scrolled row checkpoints the expected cursor without a saving flash;
typing edits that position and one Undo restores the source. Relaunch/arrow movement
preserves the cursor quietly. A click in the second emoji cell snaps after its whole
grapheme, preserves CRLF/tab/combining text, and undoes exactly. PTY teardown checks
that mouse modes 1000/1006, bracketed paste, raw mode and alternate screen are reset.
Unit/render checks also cover scroll bounds, resize/redraw, horizontal offsets,
EOF, ignored clicks, and typing after a click. No user's terminal, clipboard,
recovery data or files were opened. Physical trackpad/emulator acceptance remains
for hands-on feedback; the binary and bundled helper have both been rebuilt.

## Quiet native selection recovery — 2026-11-12

Mac selection notifications previously used the ordinary save scheduler, flashing
Saving locally on clicks/selection and repeatedly postponing the debounce. They
now use a quiet path: queued writes capture the latest caret without being
rescheduled by navigation. Unchanged ranges and private selection changes enqueue
nothing. Text mutations still show saving, and actual failures stay visible until
a successful write. Shared text/history/recovery remain in Rust; this fixes the
AppKit event/status adapter rather than introducing another document engine.

`scripts/build-mac.sh` passed all native checks including a new real NSTextView /
isolated recovery smoke: cursor and range changes keep Saved locally, ordinary
selection restores from disk, duplicate notifications enqueue nothing, and clicks
do not replace an already queued text-write work item. A blocked session.json path
proves quiet-save failures still surface and remain until a successful retry.
Private range changes do not schedule recovery or leak the synthetic fixture.
The initial test read the file before the async write finished; its wait now
checks persisted selection instead of the in-memory capture. No user window,
clipboard, recovery or source file was used. The native app was rebuilt/signed.

## Terminal selection and clipboard — 2026-11-12

TUI now supports Shift+arrows/Home/End, Ctrl+Shift+Home/End, Ctrl+A, Escape,
Left/Right collapse, drag selection, Shift+click, Unicode word/segment double
click and word drag. Holding a drag beyond the text area scrolls on an 80 ms
timer that stops on release; ordinary idle sessions gain no polling timer.
Selection uses Pocket's warm light/dark background, with whole tab/wide-glyph
cells and a marker for selected line breaks. Rendering remains viewport-only.

Ctrl+C/X/V and Ctrl+Insert / Shift+Delete/Insert use explicit clipboard adapters.
Cut mutates only after a successful copy. Ordinary paste accepts up to 8 MiB of
UTF-8, independently from Secret Drop's 64 KiB limit. Failed copy/cut/paste keeps
source and selection. Selection replacements/deletions use isolated shared Rust
history; Undo restores exact source text and returns the caret. Copy/navigation
does not change document revision or revoke Secret Drop; real edits still do.

Shared buffer/checkpoint metadata now includes an optional selection_head endpoint
beside the normalized range. Direction survives tab changes and restart; older
version 1 snapshots remain compatible and invalid endpoints are rejected. Private
buffers, including their selection metadata, are still filtered before capture.
The native bridge clears this direction metadata when setting an AppKit NSRange.
Selection-only changes in both interfaces checkpoint quietly; the Mac fix remains
in the separate preceding commit.

Full `scripts/check.sh` passed: **67 Rust tests**, formatting/Clippy, release builds,
**19 existing + 4 selection PTY scenarios**, Secret Drop integration and all native
checks, including quiet Mac selection recovery. New unit/render tests cover
forward/backward selection across ZWJ/combining/CRLF, range collapse, isolated
replacement/deletion Undo, per-tab direction, word drag, edge autoscroll/release,
and clipped tabs/wide text/line-break highlighting in both palettes. A regression
also covers deleting after shrinking a selection to zero, preventing a stale
anchor outside the edited document.

`scripts/test-selection.py` injects actual modified-key and SGR mouse sequences
through the release parser with isolated synthetic clipboard providers. It proves
selected-background ANSI output, exact Unicode/CRLF copy/cut, failed cut preserving
text, invalid UTF-8 and oversized paste preserving selection, successful 70 KiB
paste, replacement/Undo, backward-selection recovery/extension, multi-line drag,
double click, Shift+click and drag autoscroll. Private selection copy is an explicit
export; replacement/Undo still leaves its fixture absent from recovery. All PTYs,
providers and temporary files are cleaned up. The user's actual clipboard and
running editor are untouched. Physical emulator/trackpad, Linux clipboard and
remote-terminal clipboard acceptance remain platform qualification work.

## Shared find/replace increment — 2026-11-12

Both clients now use one local Rust literal/regex worker with case options,
wraparound navigation, scalar/UTF-16 hit ranges, per-match replacement and a batch
preview. It operates on an immutable rope snapshot with a latest-wins slot and
bounded compiled-regex/capture expansion. Query/preview state stays outside session
checkpoints. Search and no-op batches preserve text state and live Secret Drop
grants; real replacement batches revoke the document grant. Input/output/match and
cooperative scan limits are explicit in development; this does not qualify large
documents or guarantee a hard per-regex wall-clock bound.

`Document::replace_many` validates every range before mutation and applies sorted
edits in reverse source order as one history transaction/revision. Tests prove
Unicode/UTF-16 positions, literal metacharacters, case folding, named/numbered
capture expansion, escaped dollars, zero-width matches, invalid patterns/groups,
match caps, stale revision/query/document rejection, no-op state preservation,
batch overlap rejection and byte-exact Undo/redo across CRLF. A private-grant test
checks successful fetch after search/no-op, rejection after a real batch and no
grant resurrection after Undo. The bridge checks owned frame stability after
mutation, UTF-16 output selection, one revision and malformed input handling.

Full `scripts/check.sh` passed: **77 Rust tests**, formatting/Clippy, release builds,
**19 base + 4 selection + 3 find PTY scenarios**, Secret Drop integration and all
native smoke checks. The new PTY tests exercise live counts, preview/cancel/apply,
fast Enter queued before a worker result, literal/regex/case toggles, capture
replacement, zero-width multiline insertion, one-step Undo/clean-state restoration,
private source exclusion and an unmatched query absent from recovery. Escape and
the following CSI key are sent as distinct actions to avoid an ambiguous doubled
Escape/Alt prefix in the test stream.

Native smoke covers counts/navigation, unchanged dirty/revision/status on search
or a no-op batch, actual text-view mirroring, one-step Undo, stale/error rejection,
private replacement, Escape and 420/880 pt control geometry in both appearances.
The real views are exported under ignored `dist/find-ui/find-{light,dark}-{420,880}.png`.
Live QA caught a drawing-region bug that painted over the tabs; clipping the new
bar to its bounds fixed it and was verified on screen. The field-editor Undo
manager is separate from document Undo and is cleared on closing Find.

An isolated `dev.vibechar.find-check` app verified Cmd+F, selected-text query
seeding, Cmd+G, Option+Cmd+F, entering replacement text, All… preview, applying all
three matches and restoring the source with one Cmd+Z. Undo within the query field
restored its query without changing source. Case/regex toggles, a visibly invalid
regex, disabled match actions, Escape, preserved tabs/brand mark, and a live Dark
appearance were also checked. Closing/relaunching did not restore a find bar or
query history. Removed the QA bundle, registration, synthetic recovery/preferences;
paste automation restored clipboard contents. No user editor/files/recovery were
opened. Physical terminal-emulator and Linux acceptance remain open.

## Local text tools increment — 2026-11-12

The complete `scripts/check.sh` passed: formatting, Clippy with warnings as errors,
84 Rust tests, release builds, 30 PTY scenarios plus the separate Secret Drop
PTY/helper scenario, and the rebuilt native app's smoke suite. Six new core tests
exercise token-preserving JSON (large integers/exponents, duplicate keys, strings,
empty/nested structures), validity/idempotence/output bounds, line endings, exact
selection, one-step Undo/clean state, no-ops, stale/wrong-document plans, query
aliases/input bounds and private grant preservation/revocation. One C bridge test
covers null/overflow/split-surrogate rejection and a UTF-16 selected transaction.

`scripts/test-tools.py` adds four real release PTY scenarios: exact JSON pretty/
minify bytes, Unicode/CRLF selection with untouched neighbors, sort/dedupe/trim,
Undo/Redo, no-op Undo preservation, cancellation/quiet recovery, invalid JSON and
retry, private recovery exclusion and no persisted palette-query marker. Native
smoke covers the same shared commands through the Swift bridge, selection/Undo,
errors/staleness/private scope and actual light/dark view geometry. Exported real
views live under ignored `dist/tools-ui/text-tools-{light,dark}.png`.

An isolated `dev.vibechar.tools-check` app verified Cmd+K, initial whole-tab scope,
Enter formatting without changing large numbers/duplicate keys, one Cmd+Z back to
the source, query search by `dedupe`, query-only Undo, Escape/focus return, selected
scope, invalid JSON with unchanged source and retry, clicking Remove duplicate
lines, arrow navigation and Enter sorting. Light/dark appearances were inspected.
The selected row initially drew its description above its title; correcting the
flipped coordinate system was rebuilt/smoke-tested and confirmed live. Restart
restored transformed text with no palette/query history. The QA process was quit;
its bundle, registration, synthetic recovery and preferences were removed.

The tool target is limited to 1 MiB, formatted output to 2 MiB. Computation runs on
a bounded worker and applies only to the captured document/revision; cancellation
discards its result. Named reversible tools apply directly on Enter. This is not
the future AI/recipe preview feature. No network or user credentials were used.
Terminal-emulator/Linux qualification and general large-document budgets remain open.

A follow-up bridge regression checks a selected JSON object surrounded by unrelated
text, including a UTF-16 emoji prefix: only the selection is formatted, one Undo
restores the source, and a missing closing quote returns an error without edits.

## Unicode case and URL tools — 2026-11-12

The complete `scripts/check.sh` passed: formatting, Clippy with warnings as errors,
88 Rust tests, release builds, 32 PTY scenarios plus Secret Drop, and native smoke.
Three additional core tests cover Cyrillic, Greek final sigma, expanding Unicode
case mappings and selection ranges, CRLF/whitespace/NUL preservation, UTF-8 percent
encoding round trips, upper/lower hex, literal plus, one-pass decoding, malformed
escapes, invalid UTF-8, expansion limits and private grant behavior on error/edit.

The local-tools PTY suite now has six scenarios. New coverage includes uppercase/
lowercase on a Unicode/CRLF selection with untouched neighbors and clean Undo,
reaching the ninth command via Up, the five-row viewport and its range/count,
URL round trips/Redo/error cancellation, and new commands in private tabs. Native
smoke additionally exercises nine rows in the fixed-height NSScrollView, reveal/
wrap, clicking the last command, UTF-16 expansion/contraction and filtering after
scrolling. Real palette views are under ignored `dist/tools-extended-ui/`.

An isolated `dev.vibechar.tools-extended-check` app verified the visible five-row
list/count, native accessibility scroll action and tail-row click, URL encode/
decode of Unicode/plus/slash, filtered `url`/`case`/`lower`, Up wrapping/revealing the
last command, a no-op decode, ordinary/rapid Enter and selected `Straße` → `STRASSE`
with preserved neighbors and one-step Undo. Native pointer-scroll automation did
not move the popover, while its accessibility scroll action and keyboard reveal
did; physical mouse/trackpad qualification remains open. One earlier automated
Return inserted a newline over the selected source rather than applying the
command; Undo restored it, and relaunch plus repeated normal/rapid Enter checks
did not reproduce it. Its origin is unestablished: keep keyboard/focus qualification
open rather than claiming that every live-input edge is resolved. The QA process
was quit and its own bundle, registration, recovery and preferences removed.

URL encoding operates on components, with a 1 MiB target / 2 MiB output bound.
Decoding never fetches a URL, never performs a second pass and rejects invalid
UTF-8 without partial/lossy edits. Case mappings use Rust's Unicode defaults,
without locale-specific settings. No dependency or network call was added.
M3 multicursor and complete large-document mode remain open; M4/M5 AI follows M3.

## Shared multiple selections — 2026-11-12

The complete `scripts/check.sh` passed: formatting, Clippy with warnings as errors,
101 Rust tests, release builds, 38 PTY scenarios plus Secret Drop and native smoke.
A subsequent native menu-validation follow-up additionally checks Copy when the
primary Find hit is zero-width but other selections contain text.

The increment adds 12 core tests and one C bridge regression, bringing Rust
coverage to 101 tests. Shared cases exercise word-at-caret versus literal fragments,
case sensitivity, next/all/wrap, Unicode grapheme boundaries, anchored navigation,
wide glyphs/tabs/CRLF, collisions, ordered copy, isolated paste, grouped typing/
deletion, save/pause boundaries, valid Undo/Redo carets, stale/limited rejection,
Find adoption with different-length and zero-width ranges, and Secret Drop
preservation on metadata/no-op versus revocation on real edits. The bridge checks
UTF-16, null/overflow/split-surrogate inputs, identity/revision and CRLF insertion.

Six real release PTY scenarios in `scripts/test-multi.py` bring the combined suite
to 38 (plus the independent Secret Drop helper scenario). They cover next/all,
case-sensitive editing, grouped Undo/Redo, fake-provider copy/cut/paste failures,
multiline Unicode paste, grapheme deletion/Shift movement, Escape, queued regex
and zero-width Find hits, tab resets and private recovery exclusion. No real
clipboard or user recovery state is used by the automated suites.

Native smoke drives the actual PocketTextView hooks and Rust bridge: quiet
selection/recovery, typing/deletion groups, unique-pasteboard copy/cut/paste,
graphemes, navigation, regex adoption, Undo/Redo, Escape, tab/private state and IME
fallback to the primary. Marked text preserves core/view agreement and leaves
other selections untouched; ordinary composition history granularity remains an
IME qualification item. Real view exports are under ignored
`dist/multi-ui/multi-{selections,carets}-{light,dark}-{420,880}.png`.

An isolated `dev.vibechar.multi-check` app verified Cmd+D (1 then 2 selections),
Cmd+Shift+L (3 whole-word matches, leaving `category` untouched), physical keyboard
typing under the active Russian layout into all targets, one Cmd+Z back to source,
Redo, regex Find adoption with an emoji range, full multiline paste into four
targets and one Undo, Escape, new/closed tabs and restart without a stale set.
Secondary highlights/carets and quiet selection status were inspected live.

Live rapid-key testing exposed a race: All → Right → two Backspaces could edit only
the seed before the matching frame was adopted. The shared bounded input queue
now replays navigation/edits after the full frame; matching failures cannot replay
text on only the seed. Added core, real PTY and native regressions. The exact live
sequence then changed all three targets and one Undo restored them; immediate
three-character typing after All also passed. Save/close/tab/mode changes first
pump or reject while queued input remains, preventing silent loss. The QA app was
quit and its bundle, registration, recovery/preferences and crashed synthetic
smoke-fixture directories were removed.

Limits are documented in development: 4 MiB matching source, 1 KiB literal seed,
1,000 selections, 8 MiB edit payload and a 512-action / 8 MiB pending-input queue.
Sets are transient and only the primary enters ordinary recovery. Arbitrary
mouse-added carets, rectangles, rich multiline-fragment clipboard metadata, visual-wrap
vertical navigation, broad IME qualification and cross-emulator/Linux checks
remain outside this increment. Complete large-document mode and M4/M5 AI remain open.

## Multicursor paste distribution correction (2026-11-12)

The reported sequence exposed full-payload replication: copying two `foo`
selections produced `foo\nfoo`, which was then inserted at both moved carets.
Paste now distributes equal-count clipboard lines in document order through the
shared core; differing counts retain full-payload replication. LF/CRLF separators
and a final line ending are omitted only during distribution. Single-caret paste
retains the exact payload; Enter remains a separate newline operation.

Three new core regressions cover the exact copy/move/paste sequence, CRLF,
Unicode fragments with different lengths and resulting caret offsets, intentional
empty lines, empty clipboard no-op, count mismatch, single-caret fidelity,
explicit newline insertion and paste queued before matching completes. Bridge
coverage checks UTF-16 offsets. Native smoke performs Cmd+D twice, actual copy
through a unique pasteboard, Down and Paste against the native mirror, then one
Undo back to the clean source. A seventh multicursor PTY scenario covers both
clipboard-provider and bracketed paste, one Undo and unchanged Enter behavior.

`bash scripts/check.sh` passed: formatting, Clippy, 104 Rust tests, release builds,
39 PTY scenarios plus the separate Secret Drop helper scenario, and all native
Swift/Rust smoke checks. An isolated `dev.vibechar.paste-spread-check` app also
verified live Cmd+D twice, Down and insertion of the synthetic copied payload:
exactly four `foo` rows and two carets, with one Undo restoring the source.
`left\r\nright\r\n` similarly produced one fragment at each caret and one Undo
restored the source. Live paste restored the user's previous clipboard; actual
copy was tested with the unique-pasteboard native smoke. The QA app was quit and
its bundle, registration, recovery and preferences removed.

## Shared history retention — first large-document increment (2026-11-12)

History previously retained every inserted/removed string for the life of a
document. The shared core now retains at most 1,024 complete Undo/Redo steps and
32 MiB of charged history allocations per document, evicting oldest whole steps.
Charges include string and change-vector capacities. A single newest operation
larger than the budget is retained so it remains undoable; the next edit may
expire it. This is a retention policy, not a hard process/peak-RSS ceiling.

Four new Rust regressions exercise entry and allocation limits, grouped and batch
accounting, Unicode, saved-state identity after expiry, complete ordered Undo/Redo,
divergent branches, invalid/no-op edits and an oversized atomic operation. A new
release PTY scenario sends 1,029 separate Unicode pastes, exhausts the 1,024 retained
steps, tests one extra Undo, replays Redo to a clean saved file and branches with
an emoji. It verifies saved bytes remain unchanged after unsaved editing. The
bulk-input helper pumps both PTY directions with nonblocking writes: its first
blocking producer attempt deadlocked on PTY backpressure; the isolated processes
were terminated and their synthetic temporary state removed. No application
deadlock was established by that harness failure.

Native smoke uses RustDocument through the Swift/C bridge to exhaust the retained
Unicode steps, replay Redo to the exact saved-state identity and invalidate a
divergent branch. `bash scripts/check.sh` passed formatting, Clippy, all 108 Rust
tests, release builds, 40 PTY scenarios plus the separate Secret Drop helper, and
all native smoke checks. No user clipboard or recovery state was used.

The `profile_history` example provides a repeatable synthetic workload:
a 512 KiB document with 96 alternating full replacements, followed by all retained
Undo/Redo operations. It samples RSS using `ps` before history replay, and checks
the final saved-state identity. Thirty separate release processes per version
on the named hardware above observed:

| Measurement | Unbounded history | Bounded history, quiet follow-up |
| --- | --- | --- |
| Median sampled RSS | 103,504 KiB | 26,720 KiB |
| Maximum sampled RSS | 103,616 KiB | 26,720 KiB |
| Median of each process's edit p95 | 0.204 ms | 0.192 ms |
| Retained Undo steps | 96 | 21 |

An earlier post-change series concurrent with compilation had 49,616 KiB median
and 57,056 KiB maximum RSS, with 0.435 ms median edit p95. The quiet series avoids
concurrent compilation. RSS varied between series; these observations are not
memory ceilings.
Raw samples are in ignored `dist/history-before.json` and `dist/history-after.json`.
These are core-only warm-binary observations, not editor startup, input-to-display
latency, peak-memory measurements or a Sublime comparison. The document/fixtures,
Rope allocations, allocator overhead and UI copies are outside the history charge.

Large/minified viewport and navigation costs, native bridge copies, parsing limits
under representative workloads and peak-memory qualification remain open. M3
large-document mode and the M1/M6 performance gates are not complete.

## Long-line navigation, viewport reads and Mac snapshots (2026-11-12)

Left/Right/Backspace previously copied and segmented the whole logical line from
its start. TUI drawing and column calculations made further full-line copies and
passes. The shared core now walks Rope chunks near the caret, caches sparse
scalar/UTF-16/cell checkpoints, and copies only whole graphemes intersecting the
TUI viewport. Edits/history invalidate only affected geometry suffixes. Both
clients' multicursors reuse this geometry rather than allocating every grapheme
boundary. The cache holds at most eight lines × 4,096 points (1 MiB of point
storage per document); stride coarsening keeps large lines within that budget.

Six new core tests compare chunk navigation at every scalar with full Unicode
segmentation across varied chunk seams, including flags, emoji, Indic and long
combining sequences. They check geometry/UTF-16 windows against full-line oracles,
cache invalidation through edits/batches/Undo/Redo, combining insertion at a cached
boundary, prefix reuse and coarsening/LRU budgets. Cross-chunk context testing
found an incorrect split inside an emoji sequence; boundary queries now replay
contiguous context, growing on demand. Two TUI renderer tests compare clipped and
full-line selection/Find output and actual syntax colors after non-BMP text.

Two new release PTY scenarios exercise 1/10 MiB files with Unicode tails: composed
and emoji deletion, grouped Undo/Redo, Shift selection replacement, preserved
source bytes, cursor recovery/restart and Save. Mac snapshot copy-out now fills
Swift String storage directly; its smoke case covers empty text, 1 MiB, embedded
NUL, Unicode, CRLF, changed text and Undo. Native draw/selection metadata uses text
storage length instead of bridging a full String for emptiness/length checks.

`bash scripts/check.sh` passed: formatting, Clippy with warnings as errors,
116 Rust tests, release builds, 42 real PTY scenarios plus the separate Secret
Drop helper scenario, and every native Swift/Rust smoke check. The development
Mac app was rebuilt and signed locally.

The committed profilers use synthetic data and isolated recovery. The final TUI
comparison ran the previous `b054947` development helper and the new release binary
sequentially, with the same profiler and 30 samples per action. Each starts with a
single valid ASCII JSON line, moves to its end, then repeats Left/Right/typing/
Backspace. RSS is sampled after the final debounced checkpoint reaches Saved locally.
On the named hardware above:

| Workload / observation | Before | After |
| --- | --- | --- |
| 1 MiB Left, p50 / p95 | 39.910 / 41.233 ms | 0.302 / 0.489 ms |
| 1 MiB typing, p50 / p95 | 32.878 / 35.153 ms | 0.309 / 0.497 ms |
| 1 MiB Backspace, p50 / p95 | 40.052 / 40.823 ms | 0.313 / 0.492 ms |
| 10 MiB first jump to end, single sample | 325.251 ms | 6.077 ms |
| 10 MiB Left, p50 / p95 | 860.434 / 884.298 ms | 0.393 / 0.541 ms |
| 10 MiB typing, p50 / p95 | 555.921 / 581.594 ms | 0.390 / 0.546 ms |
| 10 MiB Backspace, p50 / p95 | 861.155 / 884.705 ms | 0.392 / 0.535 ms |
| 1 MiB sampled RSS | 12,272 KiB | 8,656 KiB |
| 10 MiB sampled RSS | 636,272 KiB | 28,736 KiB |

Times include Python/PTY input, process work, output and screen reconstruction;
they do not measure physical terminal-display latency. RSS observations include
allocator/recovery behavior and are not peak memory or hard ceilings. Earlier
samples without waiting for the final checkpoint observed 691,168 → 25,984 KiB
for 10 MiB; the final comparison adds the same idle checkpoint gate to both sides.
Single first-frame samples varied substantially (including an 847.526 ms baseline
1 MiB launch); these runs do not establish startup percentiles or cold-launch wins.

Core-only 30-sample previous/next pairs at the end of a 10 MiB ASCII line observed
150.792 → 0.000458 ms p50 (151.651 → 0.000500 ms p95). These isolate the removed
line scan and must not be presented as UI latency. Mac's synthetic snapshot-only
30-sample 10 MiB + Unicode/NUL case observed p50 2.843 → 2.607 ms and p95 3.096 →
2.658 ms, with sampled RSS 54,800 → 43,552 KiB. This measures String copy-out,
not AppKit layout or input-to-display latency. Raw reports remain in ignored
`dist/{navigation,text,snapshots}-{before,after}.json`. The temporary baseline
helper was removed after the comparison; no user files or clipboard were used.

Native AppKit large/minified layout, full snapshot replacement on history actions,
pathological giant grapheme/context work, full-line word double-click, peak-memory
and Linux/terminal-emulator qualification remain open. This increment does not
close M3 large-document mode or establish a Sublime performance claim.

## Native AppKit history and layout increment (2026-11-13)

The native profile separated two costs: resetting the complete presentation on
every Undo/Redo, and contiguous layout of preceding log paragraphs during a jump.
The editor now patches the native storage from replay-order UTF-16 history edits,
sets text and uniform typography in one pass for full presentations, and selects
AppKit's layout mode from the caret line's length. Noncontiguous layout is enabled
up to 32,768 UTF-16 units; longer lines retain contiguous layout. Enabling it
unconditionally had doubled giant-paragraph typing cost in an intermediate probe,
so that setting was not shipped. Background layout is disabled. Syntax/Find avoid
clearing temporary attributes when they have not painted any.

One new core observer regression covers grouped and batch replay against each
intermediate source state. Three bridge regressions cover UTF-16 ranges, NUL and
emoji, frame ownership/null/copy guards, the 1 MiB estimated encoded-size / 4,096
record budgets and complete fallback without a second history operation. A cheap
line-length query reads Rope metadata; invalid/split-surrogate offsets fail safely.
New native smoke verifies incremental edits, empty Redo, current typography after
zoom, snapshot fallback, stale presentation length, invalid patch rejection,
marked-text fallback and layout-mode transitions. Broader IME qualification remains
open. The complete `bash scripts/check.sh` passed 120 Rust tests, 42 PTY scenarios
plus the independent Secret Drop helper, release builds and every native smoke.

`scripts/profile-mac.py` runs four fresh child processes with synthetic 1/10 MiB
minified JSON/log text through the actual AppDelegate, PocketTextView, Rust bridge
and bitmap draw. The pre-change build had the profiler added to the behavior at
`451bceb`; the final build uses the same fixture and timing code. No recovery
store, user files or real clipboard are used. Thirty typing/Backspace samples are
collected per case; show, first draw, jump and Undo/Redo are single observations.
These include native CPU/layout/bitmap work, not physical presentation latency,
file I/O, source construction, startup percentiles or a Sublime comparison.

| Observation | Before | After |
| --- | --- | --- |
| 1 MiB minified Undo / Redo | 118.105 / 116.516 ms | 4.405 / 3.851 ms |
| 10 MiB minified Undo / Redo | 1,146.678 / 1,142.097 ms | 16.858 / 16.425 ms |
| 1 MiB logs jump to end | 106.298 ms | 4.128 ms |
| 10 MiB logs jump to end | 1,055.919 ms | 4.270 ms |
| 1 MiB logs Undo / Redo | 104.062 / 104.230 ms | 1.880 / 1.464 ms |
| 10 MiB logs Undo / Redo | 1,018.693 / 1,020.775 ms | 2.573 / 1.887 ms |
| 10 MiB minified typing p50 / p95 | 17.454 / 17.677 ms | 18.353 / 18.652 ms |
| 10 MiB logs typing p50 / p95 | 1.293 / 1.562 ms | 1.462 / 1.728 ms |
| First native presentation, 10 MiB minified | 1,812.092 ms | 1,896.411 ms |

No steady-state typing speedup is claimed: the final input samples remain near
the previous cost. First layout of a giant wrapped paragraph is still expensive
and is not solved by this increment. Raw reports are ignored
`dist/appkit-{before,after}.json`; the temporary pre-change executable was removed.

An isolated `dev.vibechar.appkit-check-20261113` app opened a synthetic 10 MiB log
through File → Open. The real window rendered its text and the saved recovery
contained the correct file. After the file panel closed, CUA window binding
reported timeouts/no-windows and could not reliably focus or edit the body; a
rebind yielded the real window screenshot. Live tail-key/Undo acceptance is not
claimed from this attempt. A one-second diagnostic sample found the app waiting
for events on its main thread, with the syntax worker waiting, rather than a busy
layout stack. It reported physical footprint 127.6M and peak 184.2M (as labeled by
the sampler); this separate large-file observation is not an idle-empty budget
measurement or a before/after memory comparison. Native editing/rendering/history
were exercised by the profiler and smoke instead. The fixture remained byte-exact;
the disposable QA process, bundle, registration, preferences, recovery and file
were removed. User recovery and clipboard were not changed.

Large-paragraph first layout, retained/peak memory, complete live accessibility/IME
and multi-platform qualification remain open. M1/M3/M6 performance gates remain
open; this records a bounded native optimization, not release acceptance.

### Feedback increment: initial native viewport layout (2026-11-13)

The first caret reveal laid out loaded text at the provisional text-container
width. Resolving the window's constraints then changed that width and discarded
the paragraph layout. Window construction now resolves the empty viewport before
loading text. The regression smoke observes text-container geometry changes: an
instrumented pre-fix executable fails its loaded-width assertion, while the final
build passes. Native wrapping, selection and text storage keep their existing
behavior. First input/history, full selection/copy including NUL, tab/caret
restoration, private tabs, resizing and appearance were checked through real
AppKit objects and bitmap rendering. The complete `bash scripts/check.sh` passed
120 Rust tests, 42 real PTY scenarios, the independent Secret Drop helper and all
native smoke tests; the signed development app was rebuilt.

The profiler now includes bitmap allocation and drawing in `first_screen_ms`,
and records first typing/Backspace at position zero before jumping to EOF. This
exposed another existing cost that the previous EOF-only input sample missed.
`native_first_frame_ms` also includes AppDelegate/window construction and opening
the synthetic document in Rust. Source-fixture construction and NSApplication
initialization are outside that timer. These are offscreen native layout/bitmap
observations, not on-screen latency, file I/O, cold-launch percentiles or a Sublime
comparison.

Five fresh child processes per version used identical instrumentation and a
10 MiB minified JSON fixture. The only behavior difference in the comparison is
the empty-viewport layout. Each process also took 30 EOF input samples. Values
below are medians of the five per-process observations, including per-process
EOF p95; five runs do not establish a startup p95.

| Observation | Before | After |
| --- | --- | --- |
| Show through first bitmap frame | 1,870.541 ms | 1,107.116 ms |
| Native setup through first bitmap frame | 1,906.036 ms | 1,146.897 ms |
| First typing at start | 972.998 ms | 973.830 ms |
| First Backspace at start | 962.789 ms | 970.031 ms |
| Jump to end | 2.906 ms | 3.021 ms |
| EOF typing p95 | 19.042 ms | 18.751 ms |
| EOF Undo / Redo | 18.469 / 17.878 ms | 18.498 / 18.081 ms |

First presentation improved by about 41%; the giant paragraph still takes about
1.1 seconds to show, and editing its beginning still costs about one second.
Sampling attributes the remaining work to AppKit paragraph shaping/wrapping.
This increment removes duplicate work; it does not complete giant-line performance
or large-document mode. No steady-state input improvement is claimed.

A separate final four-fixture run observed first-screen work of 130.622 / 1,104.556
ms for 1 / 10 MiB minified JSON and 18.714 / 21.814 ms for short-line logs. These are
single observations. Reports are ignored `dist/first-show-series-{before,after}.json`
and `dist/first-show-matrix-after.json`. Temporary probe sources/executables and
the instrumented pre-fix executable were removed. User recovery and the real
clipboard were not accessed. The remaining M1/M3/M6 performance gates stay open.

### Feedback increment: indentation, wrapping and cursor position (2026-11-16)

Both frontends now invoke shared Rust indentation/newline plans. Tab uses four-cell
stops at carets and four-space prefixes for selected lines. Shift+Tab removes one
leading tab or up to four spaces; overlapping multicursor line targets deduplicate.
Core plans map both endpoints; TUI retains selection direction and Mac updates its
selected range. A half-open range ending at the next line's start excludes that
line. Enter copies leading spaces/tabs before
the replacement start. Reading the first Rope line also fixes LF insertion into
CRLF scratches initialized by paste/stdin. Explicit edits share one Undo step;
no-op outdents retain revision/history/grants. Commands enforce line/output budgets.

Mac receives bounded UTF-16 native patches with snapshot fallback after applying
once. Its footer keeps logical line:column visible at 420 pt, including private
tabs. View → Wrap Lines / Option+Cmd+W toggles actual native layout/horizontal
scrolling. The native menu key event, wrapped/unwrapped fragment geometry, wide
resize, Unicode/CRLF, selections, multiple carets, history and private grant behavior
were exercised. Wrap toggles preserve text/revision/selection and grants; real
indent edits revoke a private grant. Light/dark bitmap captures at 420/880 pt were
generated under ignored `dist/editing-ui/`; wrapped dark/narrow and unwrapped
light/wide captures were visually inspected.

TUI F10 toggles greedy grapheme/cell wrapping. Sparse row checkpoints share the
existing bounded line cache and invalidate affected suffixes after edits; they do
not materialize the document's wrapped text. Drawing, mouse selection, drag/wheel
scrolling, arrow navigation and Home/End share visual-row geometry. Logical status
coordinates remain stable. End retains upstream affinity at a wrap boundary so
repeating it does not advance through subsequent rows. Real newline boundaries
avoid artificial blank rows. Mac defaults wrapped, TUI unwrapped; this session
view preference is excluded from checkpoints and never changes file/clipboard
bytes, dirty state or Undo. Their native word/cell break points can differ.

The final full `bash scripts/check.sh` passed 130 Rust tests, formatting/Clippy,
release builds, 46 real PTY scenarios, the independent Secret Drop helper and every
native smoke; the signed development app was rebuilt. New Rust coverage includes
UTF-16 rejection/positions, bounded patch fallback after applying once, indentation
selection mapping, CRLF, multicursor history, sparse cache coarsening/invalidation,
Unicode visual rows, resize, mouse/drag and viewport-only recovery behavior.

Four new real-PTY scenarios verify block indentation/outdent/newline/Undo with
Russian/emoji/CRLF; wrapped hit testing and copy across visual rows without added
newlines; actual terminal resize and byte-exact save; private recovery exclusion
and explicit save conversion; and 10 MiB wrapped tail navigation, typing/history
and resize with an unchanged original file. The large case is regression coverage,
not a new latency/memory qualification. All fixtures use temporary files/state and
synthetic clipboards. User recovery and the real clipboard were not accessed.
The previously recorded giant AppKit paragraph cost and broader IME/accessibility,
memory, Linux and release qualification remain open.

## Line numbers and shared text statistics (2026-11-16)

Both clients now start with a logical line-number gutter, current-line accent and
quiet continuation dots for visual wraps. Clicking a number selects the entire
source line, including its ending. Mac View → Line Numbers (⌥⌘N) and TUI F12 toggle
the gutter without editing or saving text. The footer adds adaptive text/selection
counts alongside the existing logical cursor position. Click the Mac counter or
press TUI F11 for an exact document-versus-selection table: characters, words,
logical lines, UTF-8 bytes and selection/caret counts. Escape/F11 dismisses the TUI
panel; typing or paste closes it and continues in the previously focused field.

Character counts use extended graphemes (`👩‍💻`, `é` and CRLF each count once),
not scalar/UTF-16 counts or AI tokens. Word counts use runs of letters, numbers or
underscores. Overlapping selected text and touched lines count once. An empty
document has one logical line; a final newline creates an empty final line.
Counts above 4 KiB use a lazy background Rope worker, revision/selection checks
and cooperative 64 MiB / 500 ms analysis budgets. Exact line/byte metadata remains
available when a detailed count is unavailable. This does not qualify pathological
single-grapheme timing or a general process-memory ceiling.

The full `scripts/check.sh` passed 138 Rust tests, formatting/Clippy, release builds,
50 real PTY scenarios, the independent Secret Drop helper and all native smokes.
After the final TUI panel/paste/focus adjustment, formatting/Clippy, all 138 Rust
tests, release builds, counters/find/tools PTY suites and native smokes were rerun.
New coverage includes chunk-crossing Unicode counting, overlapping selections,
stale-result rejection/cancellation/disposal, bridge UTF-16 validation, numbered
wrapped hit testing and scrolling, narrow private layouts and unchanged recovery
marks. Four dedicated real-PTY cases verify byte-exact CRLF line copy, body hit
testing after the gutter, toggles, detailed counts, Unicode/multicursor counts,
actual resize/private exclusion, panel paste/Undo and a 10 MiB background count.

The native counter smoke checks empty/trailing lines, selected emoji/bytes/words,
wrapped fragments, scrolling, gutter clicks, narrow/light/dark geometry, private
multiselection and grant preservation. Bitmap inspection caught ruler paint
escaping its bounds and covering sibling content; explicit clipping fixes it.
A regression check compares header pixels with the ruler shown/hidden. Synthetic
final snapshots are reproducible under ignored `dist/counters-ui/`. No user recovery
or real clipboard content was read. Broader IME/accessibility and Linux acceptance
remain open.

A single synthetic 10 MiB minified AppKit sample with numbers/counters enabled
observed 1,111.438 ms through the first bitmap frame, 964.469 ms first typing at the
start and 956.231 ms first Backspace. This is a regression spot check, not a latency
percentile, physical-screen measurement or improvement claim. The previously
recorded giant-paragraph layout/edit cost remains unresolved. The numeric report
is ignored `dist/counters-performance.json`.

## Adaptive large-text mode (2026-11-16)

Large-document mode is implemented in both clients from 512 KiB UTF-8. Its shared
policy centralizes existing syntax/search/tools/statistics/history byte budgets
and the new 64 KiB pointer-word scan limit. Oversized word double click no longer
flattens a giant TUI line; Mac uses the same bounded word-selection adapter,
including expansion of both endpoints during word drag. Smaller selected fragments
remain usable by local tools in documents exceeding whole-tab limits.

Mac retains its native text system and source offsets. `BudgetTypesetter` limits
wrapped first-window context to 256 Ki glyphs, rounded to composed characters.
Automatic prepares full native context for distant selection/paste and reuses it
within that source revision; a prefix edit can return to bounded context. This
avoids repeatedly reflowing unchanged text during start/end navigation. Native
installation-time temporary EOF selections are ignored. On forces chunking and
Off restores standard layout. Bidi text, no-wrap and oversized composed clusters
retain standard context. A quiet lightning icon and tooltip explain mode state;
TUI status/F11 disclose large-text state and the selected-tool budget.

`scripts/check.sh` passed 141 Rust tests, formatting/Clippy, release builds, **53
real PTY scenarios**, the Secret Drop helper and all native smokes. Final native
selection/context refinements were followed by another complete native smoke and
the large/counter PTY suites; final formatting/Clippy also passed. New coverage:

- UTF-8 threshold crossings through edit/Undo, revision-bound bidi decisions,
  invalid UTF-16/surrogate positions and bounded word selection.
- Native single-paragraph first-load policy, prepared-context reuse on navigation,
  a prefix edit returning to bounded context, Unicode crossing a chunk boundary,
  NUL/CRLF, actual native caret/pointer geometry, word drag, full copy, delete,
  Undo/Redo, byte-exact save, mode/wrap changes, tabs, private exclusion/grants and
  narrow light/dark views. Synthetic snapshots are under ignored `dist/large-ui/`.
- Real-PTY 512 KiB threshold/Undo, 10 MiB numbered word-selection refusal, clear
  search/multicursor/tool limit errors, a small JSON selection transformed inside
  the large file and reverted/saved exactly, plus large private recovery exclusion.

The following are **medians of three fresh synthetic 10 MiB minified processes**,
with three repeated EOF inputs per process. The baseline executable was copied
from the `df2b899` development app before this work. These are CPU/bitmap work
observations, not physical latency, cold-launch percentiles or a Sublime comparison.

| Operation | Before | Adaptive Auto |
| --- | ---: | ---: |
| Show through first bitmap | 1,107.599 ms | 185.691 ms |
| First typing at start | 976.278 ms | 61.930 ms |
| First Backspace at start | 967.827 ms | 54.384 ms |
| First EOF reveal after those edits | 8.281 ms | 979.654 ms |
| Median EOF typing | 17.826 ms | 19.608 ms |

The EOF result is a disclosed trade-off: full paragraph work is deferred until it
is needed, rather than done before the first viewport/input. Once prepared, the
same-revision start/end reveals in the candidate took about 4.116 / 3.392 ms. On
forces chunks and can make a first distant reveal slower; Automatic avoids repeated
small-context prefix work on this path. These results do not close the M6 latency
or memory gates. Users can choose Off for standard native presentation.

One actual 10 MiB synthetic clipboard-paste sample observed first-frame work of
1,160.152 ms in Auto and 1,153.412 ms in Off. The next prefix input observed
61.058 / 1,006.732 ms, while repeat EOF reveals were 3.400 / 3.122 ms. These single
paste samples establish functional coverage and the adaptive path, not a paste
latency percentile or a guaranteed performance equivalence.

A separate final four-fixture sample observed first-frame work of 60.351 / 190.150
ms for 1/10 MiB minified text and 21.169 / 23.948 ms for 1/10 MiB logs. Raw summaries
are ignored `dist/large-before.json`, `large-current.json`, `large-paste-auto.json`,
`large-paste-off.json` and `large-final-matrix.json`. Fixtures use isolated synthetic
pasteboards, temporary recovery/files and in-memory source; no real clipboard or
user recovery content was accessed. No permanent background prelayout, polling or
source truncation was added. General peak memory, contextual/pathological Unicode,
IME/accessibility, Linux and multi-terminal qualification remain M6 work.

## Initial performance observations

One `ps` sample after the native edit/save workflow reported 103,200 KiB RSS
(about 100.8 MiB). This exceeds the provisional 40 MiB Mac budget. It includes
AppKit/text presentation and was not an empty-buffer or peak-memory measurement.
There is no evidence yet that the Rust bridge, rather than native framework costs,
is responsible; profile before changing renderer architecture.

The initial TUI PTY sample reported 2,784 KiB RSS (about 2.7 MiB). Its observed
first frame was about 336 ms, including Python/PTY/process startup and first-run OS
work. These single samples cannot establish latency percentiles or beat Sublime.

Warm-run measurements, when present below, must be kept separate from cold launch
and from actual terminal-emulator display latency. No Sublime comparison has been run.

Thirty subsequent warm runs of the final release TUI, each with a fresh controlling
PTY and no document, observed the first frame plus visible cursor as follows:

| Metric | Observation |
| --- | --- |
| p50 startup | 15.32 ms |
| p95 startup | 23.61 ms |
| Minimum / maximum | 13.75 / 38.24 ms |
| Median / maximum process RSS | 2,656 / 2,672 KiB |

The timer includes Python subprocess/fork and PTY startup. Cached binaries and OS
libraries make this a warm-run baseline; it does not measure photons on a real
terminal display. The raw summary is in ignored `dist/terminal-baseline.json`.

A later full-check run on the unchanged release binary observed a 651.14 ms launch
sample and 2,736 KiB RSS. Launch variance is therefore unresolved; the warm series
must not be used as a guaranteed startup claim or to imply the cold-launch target
is achieved. Isolate OS scheduling/launch work and the harness in the M1 baseline.

## Remaining M1 evidence

Native snapshots and AppKit presentation now have synthetic 1/10 MiB observations
above. Native startup percentiles, the full memory matrix and renderer decisions
still need qualification; M1's baseline checkbox remains open. M2 recovery is partial: retention and broader durability
qualification remain open. M3 smart syntax, find/replace, nine local tools and
basic shared multicursor editing and adaptive large-document mode are implemented;
full large-document performance qualification remains open. M4.1 connection settings,
M4.2 selection rewriting, M5.1 example-based preview/execution and M5.2 named recipe
storage/offline replay are implemented. Saved AI instructions and the live
task-completion benchmark remain open. The prototype should not hold the only
copy of important text.

## 2026-11-17 — M4.1: Mac OpenAI connection settings

Implemented a native Pocket Settings window (Cmd+,): secure key entry, replace /
remove, a searchable four-model Responses catalog, explicit Refresh and Test &
Save. The only startup change is the menu entry; opening Settings is the first
Keychain read, and provider requests require an explicit action. The terminal
and shared Rust engine have no provider changes.

`bash scripts/check.sh` passed formatting, strict Clippy, **141 Rust tests**, the
release workspace build, **53 real PTY scenarios**, the separate Secret Drop
helper scenario, and all Swift/native smoke tests including AI Settings. The
development app was rebuilt and ad-hoc signed; `codesign --verify --deep --strict`
passed. The dedicated `--smoke-ai-settings` also passed from the signed bundle.

New synthetic/native evidence:

- A UUID-scoped real Keychain item was added, read, replaced and deleted, including
  repeated removal. All test values were synthetic; the production service was
  never read. In-memory failure fixtures verified that authentication failure and
  a failed Keychain replacement preserve the saved credential/model preference.
- Reopening settings restores the saved model and leaves the secure replacement
  field empty; a saved-key preview was added in the follow-up below.
  The temporary preferences domain contains no synthetic key. Closing clears the
  field/editor undo state and retained settings keys (a short Keychain commit
  already in progress finishes first). Model-availability metadata is discarded
  so it cannot survive into a different credential's session.
- URLProtocol fixtures checked the actual adapter's HTTPS endpoint, method,
  synthetic Authorization header and exact request fields. Responses tests send
  only the fixed test prompt, `store: false`, and a bounded model-specific output
  budget. Catalog discovery filters unsupported IDs.
- Fixtures exercised 401 authentication, listing 403 versus inference 403, model
  404, quota versus rate-limit 429, 503, rejected requests, malformed / incomplete /
  refusal responses, timeout and offline errors. Error text never includes the
  provider body or its echoed synthetic key. Oversized response bodies are rejected;
  cancellation stops a suspended URL loading task. The production redirect
  delegate rejects a constructed cross-host redirect without contacting it.
- A deliberately cancellation-insensitive service completed late replies after
  key changes, model changes, Cancel, close and removal. None saved a stale key or
  model. Opening, searching and selecting models made zero provider calls.
  Restricted model listing still allowed a direct model test.
- Native controls exercised local search (including no matches and Return),
  Test & Save error/success, refresh, secure-field clearing, singleton Settings
  opening and menu definitions. Settings command routing uses an injected focused
  window in the background harness: Close closes Settings, editor actions are
  disabled, and field Undo leaves the document's revision/tab count unchanged.
  This avoids depending on macOS granting foreground activation to a CLI test.
- Ready, error and saved-key/availability views were bitmap-rendered and visually
  inspected in light and dark appearances. These captures exclude the system
  titlebar. Focus stealing, physical keyboard interaction, VoiceOver and broader
  accessibility acceptance remain manual qualification.

No real OpenAI request was made and no real key was collected. Account/model
access and billing must be checked through the explicit UI Test & Save action.
It is API-billed and sends no editor/selection/clipboard content. Rewriting, diffs
and recipes remain subsequent increments; no AI editing was added here.

### Saved-key preview follow-up

The saved key now appears as a read-only `sk-…Ab12` preview after saving and reopening
Settings. Replace opens an empty secure input; Cancel restores the saved preview.
Only the fixed `sk-` prefix and final four characters are visible, and short values
are fully masked. The preview is derived in memory and is never used as a candidate key.

`bash scripts/build-mac.sh` passed the full native smoke suite. The dedicated AI
smoke also passed with light/dark bitmap captures, visually inspected in both themes.
Native checks cover blank replacement disabling Test & Save, failed replacement /
Cancel preserving the old credential and preview, successful replacement updating
the suffix, reopen restoring it, removal clearing it, and short-value masking.
`codesign --verify --deep --strict` passed on the rebuilt development app. All keys
and provider responses in these checks were synthetic.

## 2026-11-17 — M4.2: selection rewriting with protected fragments and diffs

Implemented Shift+Cmd+K / Edit → Rewrite Selection in the Mac GUI. Explicit Preview
uses the saved key/model and sends only the captured selection plus instruction.
Source/Changes/Result views expose the proposal before Apply. The shared Rust
engine owns privacy checks, protected occurrences and atomic revision-bound apply;
native presentation replays only the accepted range. The TUI has no provider calls.

`bash scripts/check.sh` passed formatting, strict Clippy, **147 Rust tests**, release
workspace build, **53 real PTY scenarios**, the separate Secret Drop helper check,
and all native smoke tests including the new rewrite suite. Six Rust tests were
added across core and C bridge. The dedicated `--smoke-rewrite` passed with native
light/dark bitmaps at 760×720 and 640×600, visually inspected. The signed development
app was rebuilt. Checks used synthetic credentials and provider fixtures only.

Evidence covers:

- Bounded selection-only capture, Unicode/UTF-16 boundaries, CRLF, an empty
  replacement, output/source limits, no-op, one Undo/Redo, and unchanged text outside
  the target. Native Apply checks the Rust document and AppKit mirror together.
- Private-buffer capture rejection before credential access/source extraction,
  and private menu/action exclusion in the native app. No production Keychain
  item, environment credential, clipboard or recovery data was read by tests.
- Protected occurrences absent from request text, exact byte restoration (including
  NUL and emoji), and rejection of missing, duplicated, modified or reordered
  markers. Overlapping protected ranges are rejected without partial application.
- Request fixtures verify the HTTPS endpoint, synthetic authorization, configured
  model, exact JSON instruction/selection, `store: false`, 16,384 output-token
  budget and absence of tools/conversations/adjacent text. Completed empty text
  can be proposed; refusals/errors cannot become applicable output.
- Late replies after source edits, Cancel, instruction changes and close cannot
  create/apply a proposal. Undo back to original bytes is stale because revisions
  are monotonic. Tab changes close/clear the native capture. Key/provider errors
  and rejected previews leave document text/history alone.
- Source protection controls, diff highlighting/counts, keyboard menu definitions,
  Apply/Undo/Redo, stale disabling, Cmd+W routing and UI cleanup. Native source edits
  through NSTextView invalidate an existing preview. Background command routing
  uses the same injected focused-window seam as AI Settings tests.
- LCS cell budget / coarse replacement fallback and a 4,096-line display budget
  near the first change. Partial previews are labeled and the complete Source and
  Result remain accessible. These are explicit operation budgets, not a general
  latency qualification.

Live OpenAI generation and the subjective quality of actual model rewrites remain
Art's explicit UI check with his configured key. Physical keyboard interaction,
VoiceOver and broader IME qualification remain manual acceptance. Marked occurrences
are the protection boundary; unmarked duplicates and the instruction are sent as
written. Example-based inference/recipes remain M5.

## 2026-11-17 — M5.1: Do the Rest from one example

Implemented Option+Cmd+K / Edit → Do the Rest for complete-line selections in the
Mac GUI. The native window shows the first nonblank row as Before and an editable
After. Explicit Do the rest sends only that pair to OpenAI Structured Outputs;
all remaining records are processed locally by the shared Rust recipe executor.
Source, diff, complete Result, readable Rule and sampled Skipped reasons precede Apply.
The selected example itself is transformed together with the other matched rows.

`bash scripts/check.sh` passed formatting, strict Clippy, **155 Rust tests**, release
workspace build, **53 real PTY scenarios**, the separate Secret Drop helper check
and all native smoke tests, including Do the Rest and prior AI Settings/Rewrite.
Eight Rust tests were added across core and bridge. `--smoke-examples` passed with
light/dark bitmap captures at 820×760 and 700×640, visually inspected. The development
app was rebuilt and its ad-hoc signature verified.

Evidence:

- Eleven recipe demonstrations were checked on unseen records: URL prefixing,
  Unicode upper/lower, trim, delimited field formatting, delimiter replacement,
  JSON name/ID link formatting, exact large/exponent JSON numbers, env→JSON per row,
  JSON string encoding and last-field extraction. These test the executor's
  generalization; they are not live model-inference-quality measurements.
- Validation reproduces After byte-for-byte, rejects unsupported versions/fields,
  unsupported semantic rules, wrong examples, obvious hardcoded unreferenced fields
  and implicit structured JSON conversions. Raw JSON numeric lexemes are retained;
  duplicate source/output keys are rejected. Delimiter aliases have regression coverage.
- Batch fixtures preserve malformed/missing-field rows, blanks, mixed LF/CRLF,
  final newline and outside-target bytes. Counts and sampled skip reasons are
  checked. Apply needs at least one match beyond the example and makes one atomic
  history transaction; native tests verify both the Rust document and AppKit mirror
  through Undo/Redo. Source/output budgets and incomplete-line rejection are exercised.
- Actual HTTP fixtures assert the example-only payload, configured nondefault model,
  `store: false`, 4,096 output-token budget, strict json_schema and the core-supplied
  five-field root schema. No filenames, surrounding text or target records are sent.
  Synthetic unseen target markers are absent from recorded provider arguments.
- Private capture fails before credential access; menu and direct native action
  refuse private tabs. No production Keychain item, clipboard, environment secret
  or recovery was accessed. Missing-key/provider/invalid-rule failures leave the tab
  untouched. Late replies after Cancel, After edits, close and source edits cannot
  apply. Tab switching clears the capture; Cmd+W closes the auxiliary window.
- Source/Changes/Result/Rule/Skipped controls, narrow layout, native source editing,
  stale disabling and cleanup are checked. The common generated-edit presentation
  path is covered by both Rewrite and Do the Rest. CRLF diff lines now paint with
  one display newline rather than a spurious blank line, with a shared regression.

No real provider call was made. Live inference and whether the workflow beats
manual editing remain Art's UI/benchmark acceptance. Rules are transient in this
increment; named recipe saving/offline replay UI, saved AI rewrite instructions,
multiline/aggregate records and interactive type-conversion choices remain open.

## 2026-11-17 — M5.2: saved local recipes and offline replay

Implemented **Save Recipe…** on a current, validated Do the Rest preview and
**Edit → Saved Recipes… / Option+Cmd+R**. The native library searches names and
structural summaries, supports rename and confirmed deletion, and opens the shared
Source/Changes/Result/Rule/Skipped surface in on-device mode. Search arrows choose,
Return previews. The selected target is untouched until Apply; one Undo restores it.
Only the name, UUID and versioned rule persist; captured source/Before/After/result
are excluded. Literal text in the rule is explicitly included in the save disclosure.

Validation:

- `bash scripts/check.sh` passed formatting, strict Clippy, **158 Rust tests**,
  release workspace build, **53 real PTY scenarios**, the separate Secret Drop
  helper and the complete native smoke suite. Three Rust regressions were added
  for replay/capture/history limits and the actual C bridge.
- After final Swift refinements, `bash scripts/build-mac.sh` rebuilt the development
  bundle and passed all native smoke tests again. Dedicated `--smoke-examples` and
  `--smoke-recipes` used synthetic fixtures; the ad-hoc signature was verified.
- The actual Save Recipe button opens a native name sheet. Cancel writes nothing;
  accepting writes the learned rule. A fresh store loads it, the native library
  replays it on a different tab containing an unseen record, and Rust/AppKit agree
  after Apply. The original teaching values and target rows are absent from the file.
- A separate disposable library checks canonical recipe persistence/stable UUID,
  trimmed/duplicate/invalid names, rename/delete, 0600 file permissions, malformed
  JSON, future library and rule versions, and an unwritable destination. Invalid
  mutations or unreadable/future files never overwrite existing library bytes.
- Offline replay is exercised with credential/provider traps that fail if called.
  It accepts one matching row, including when earlier rows do not match, preserves
  skips/blanks/mixed LF/CRLF/outside text and exact huge JSON numbers, and applies
  one history transaction. Zero matches, stale source, cancellation, tab switching,
  private targets, partial CRLF and source/output budgets remain guarded.
- Native menu/shortcut, search/no-results, Return-to-preview, auxiliary Cmd+W and
  both document/presentation Undo/Redo are checked. Light/dark library, empty search,
  560×460 library and offline-preview bitmaps were inspected; the teaching preview
  also retains its 700×640 layout with the added Save Recipe button.

No real provider request, production credential, clipboard or session recovery was
accessed. Fixtures use disposable directories and a unique clipboard, with cleanup.
This closes named deterministic recipe storage/replay, not the entire M5 milestone:
saved AI instructions, interactive type choices and live inference/task-completion
acceptance remain open. Library UI/storage are Mac-only; TUI scope is unchanged.

## 2026-11-17 — Graphite app icon and native packaging

Art selected the black Graphite `V_` concept and accepted the functional MVP scope;
product polish begins with the Mac icon. The selected 1254×1254 RGBA master and
exact built-in imagegen prompts are committed under `apps/macos/Artwork/`.

- `scripts/build-icon.sh` exports ten standard 1×/2× legacy representations through
  1024 px and compiles the native `AppIcon.icon` using Xcode `actool`. Packaging
  includes `AppIcon.icns`, `Assets.car`, `CFBundleIconFile` and `CFBundleIconName`
  before signing. Intermediate iconsets/catalog workspaces are cleaned up.
- A bitmap-only first build visibly gained a gray backplate and an undersized icon
  through `NSWorkspace.icon(forFile:)` on this Mac. The native catalog fixes that
  observed output; the chosen artwork's scale is 1.0, with a graphite fill and extra
  glass/translucency/shadows disabled. The Finder/Terminal/TextEdit comparison was
  rerendered from the actual bundle icon lookup and visually inspected on light and
  dark backgrounds. The selected shape is no longer nested inside a gray plate.
- The master has transparent outer corners and a solid center (alpha >99%). The
  ICNS round-trip exposes all ten 16–1024 px representations. Native bitmap QA
  inspected 16/32/48/64/128 pt output for legibility and transparent margins.
- `bash scripts/build-mac.sh` passed the complete native smoke suite with the icon
  packaged. After the final artwork-scale adjustment, icon packaging was rerun,
  the bundle re-signed and `codesign --verify --deep --strict` passed. `bash -n`
  validates both build scripts. Rust/TUI code is unchanged; their prior checks
  were not rerun for this artwork-only increment.
- LaunchServices was refreshed for the existing development bundle. The user's
  running editor was left open, so its live Dock tile still requires a full quit
  and reopen. No Dock reset, user preference changes, credentials, clipboard,
  private tabs or recovery data were accessed. Actual older-macOS display and
  clear/tinted appearance acceptance remain untested; the literal ICNS fallback
  and modern asset catalog are present in the signed bundle.

Local review artifact: `dist/icon-dock-preview.png` (generated bitmap comparison,
not a screenshot of the user's Dock). Apple references are linked in the artwork
README; the build never calls an image model or requires an API key.


## Distribution and unified launcher — 2026-11-17

The [full CI run](https://github.com/rovnyart/vibechar/actions/runs/44094955442)
passed at `71b1943792736f36a6eea2f810a89785af060786` on macOS 26 and Ubuntu 24.04. The
[first stable release](https://github.com/rovnyart/vibechar/releases/tag/build-71b194379273)
contains the signed Mac app, terminal client and static Linux x86_64 binaries from that
same revision. The public MIT repository preserves the original Git history.

- Each primary platform passed 160 Rust tests, strict Clippy/formatting, release
  builds and 55 real PTY scenarios. Linux's static musl binaries additionally
  passed the two launcher PTY scenarios and the isolated installer fixture.
- The native suites passed editing, recovery, private/Secret Drop, syntax,
  counters, multi-selection, AI settings, rewrite, examples and offline recipes.
  AI suites run in independent AppKit processes after `finishLaunching`, with
  a 180-second timeout per process. They retain synthetic HTTP/credential
  fixtures and actual recipe-sheet save/cancel/rename/delete assertions.
- Classic scrollbars exposed a real loaded-paragraph width change. Space is now
  reserved before loading text; unwrapped editors fit after scroller/ruler tiling.
  Dedicated first-presentation and editing regressions with
  `-AppleShowScrollBars Always` passed in the Mac CI matrix.
- Save As filesystem tests inject the destination request, preserving suggested
  name/directory, cancellation, failure, overwrite, history and recovery checks
  without starting the system's remote save-panel service. The normal GUI path
  still presents the same native panel.
- Launcher coverage checks Unicode files and piped input in real PTYs, startup
  and running-app URL routing, existing-tab reuse, nonexistent files remaining
  unsaved, ignored grant URLs, menu routing, idempotent PATH installation,
  preserved shell settings and unrelated-command collision refusal.
- Mac archives were downloaded from the successful CI run, verified against
  its revision and checksums, then Developer ID signed and notarized locally.
  `codesign --verify --deep --strict`, Apple acceptance, stapling and `spctl`
  assessment passed for the archived builds. No signing credential was exported
  or copied into the repository.
- The actual public curl command passed fresh installation and reinstallation
  in a disposable Mac home directory. Installed `vc --version`,
  `vc -t --version`, `vc --terminal --help`, the native launcher smoke, signature
  and stapled-ticket validation all passed. The managed PATH block appeared once
  and preserved pre-existing synthetic shell settings. Icons and all license
  notices were present in the installed app.
- A separate real-archive fixture also rejected a tampered checksum before any
  app/PATH installation. Linux's installer fixture passed on its Linux runner;
  its downloads are stubbed while extraction and installed binaries are real.
- These tests did not open the user's recovery, clipboard, API key or private
  tabs, and did not change the user's PATH. This is clean-home validation on
  existing systems, not a fresh macOS 14 VM or broad manual accessibility/IME
  qualification. Those remain tracked in the roadmap.

The first stable release used the existing local Developer ID and notarization
profile. GitHub signing secrets were not configured at publication time, so CI's
initial publication was a preview and was promoted after local notarization.
Future trusted-main builds use the [documented signing setup](apple-signing.md);
without it, CI continues publishing previews and preserves the latest stable
release. Final documentation-only updates use GitHub's
[supported `[skip ci]` marker](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/skip-workflow-runs); the release code is the fully tested revision linked above.


## Apple Silicon release target — 2026-11-17

Mac builds now target Apple Silicon (arm64) exclusively. CI validates and publishes
one Mac archive (GUI, terminal and `vc`) plus the Linux x86_64 terminal archive.
The Mac builder refuses unsupported hosts, the packager checks the architecture
of the app and both helpers, and the installer rejects unsupported Macs before
network access or home-directory changes.

Five isolated publication tests passed: the two-platform stable release,
undeclared-file exclusion, rejected extra/missing platform metadata, checksum
mismatch rejection and preview-description updates. The real signed ARM archive
also passed fresh install, reinstall, CLI/native launcher smoke, checksum rejection
and simulated unsupported-Mac rejection. Shell syntax and workflow YAML checks
passed. Existing Rust and native editor code are unchanged.

GitHub signing configuration was corrected by adding the repository variable
`APPLE_TEAM_ID`. The Apple Silicon job in
[the signing verification run](https://github.com/rovnyart/vibechar/actions/runs/44103145064)
then imported the certificate, signed, received Apple acceptance, stapled the
ticket and passed Gatekeeper. Signing credentials remain in GitHub secrets.


The [Apple Silicon + Linux CI run](https://github.com/rovnyart/vibechar/actions/runs/44107134279)
passed completely at `baae5a7af6e4c782a2db0f8e04942c2e5225bfdd`, including
certificate import, automatic Developer ID signing, Apple notarization and
publication. The [stable release](https://github.com/rovnyart/vibechar/releases/tag/build-baae5a7af6e4)
contains only the Apple Silicon Mac archive and Linux x86_64 terminal archive,
their metadata and SHA256SUMS. Obsolete Mac assets were also removed from the
pre-existing release, with its checksums and description updated.

The actual public curl installer passed fresh installation and reinstallation
from this release in a temporary home. Installed GUI launcher smoke, both client
version/help commands, signature, stapled ticket and Gatekeeper checks passed.
`lipo -archs` confirmed that the app, `vc` and terminal helper each contain only
`arm64`. Temporary homes were removed; the user's PATH and editor session were
untouched. Product versioning was not changed in this increment.
