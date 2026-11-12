# Prototype verification

Started: 2026-11-11. Latest increment: 2026-11-12.
This records local prototype evidence, not MVP release acceptance.

## Environment

- Apple M5, 16 GiB RAM, macOS 27.0.1 (26A434), Apple Silicon.
- Rust 1.99.1, Swift 6.4.2, release builds for runnable clients.
- Development .app uses local ad-hoc signing; it is not notarized or installed globally.

## Automated checks

- 41 Rust tests: 7 document/history/Unicode, 3 session/buffer behavior, 1 bounded
  Unicode scratch-label test, 7 core recovery, 4 Secret Drop transport/revocation/save,
  5 C bridge, and 14 terminal model/layout/recovery/output-masking tests.
- Rust formatting and Clippy with warnings as errors.
- Rust release workspace build and Swift release link.
- Native Swift ↔ Rust smoke test: embedded NUL, Russian text, UTF-16 rejection,
  emoji substitution, undo/redo, dirty tracking, and saved-state reset.
- Native last-tab close checks: Cmd+W action, the real tab close button, empty
  private tab, multiple-tab behavior, close notifications/termination decision,
  removed-tab recovery versus whole-window recovery.
- Thirteen real PTY scenarios: bracketed paste + undo/redo + byte-exact UTF-8/CRLF save;
  unsaved-change protection; piped stdin with interactive keyboard; scratch save-as;
  failed read-only save preserving the previous destination; two independently
  saved buffers with restart/cursor restoration; background checkpoint + forced
  termination; closed tabs staying closed; corrupt recovery; concurrent writer
  rejection; and failed quit flush with manual text rescue before explicit quit.
- Save As PTY coverage includes existing file tabs, cancelled prompts, failed and
  read-only/symlink destinations, replacement confirmation/reset, Unicode paths,
  subsequent Save to the new path and restart with that destination.
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

Native startup and Mac bridge/presentation costs across representative file sizes
still need measurement. The milestone's baseline checkbox remains open until that
evidence is recorded. M2 recovery is partial: private mode is implemented with
hands-on feedback pending; retention and broader durability qualification remain
open. M3 syntax/editing tools and M4/M5 AI are not
implemented. The prototype should not hold the only copy of important text.
