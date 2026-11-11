# Prototype verification

Date: 2026-11-11. This records local evidence for M1, not MVP release acceptance.

## Environment

- Apple M5, 16 GiB RAM, macOS 27.0.1 (26A434), Apple Silicon.
- Rust 1.99.1, Swift 6.4.2, release builds for runnable clients.
- Development .app uses local ad-hoc signing; it is not notarized or installed globally.

## Automated checks

- 28 Rust tests: 7 document/history/Unicode, 3 session/buffer behavior, 5 core recovery,
  3 C bridge, and 10 terminal model/layout/recovery tests.
- Rust formatting and Clippy with warnings as errors.
- Rust release workspace build and Swift release link.
- Native Swift ↔ Rust smoke test: embedded NUL, Russian text, UTF-16 rejection,
  emoji substitution, undo/redo, dirty tracking, and saved-state reset.
- Ten real PTY scenarios: bracketed paste + undo/redo + byte-exact UTF-8/CRLF save;
  unsaved-change protection; piped stdin with interactive keyboard; scratch save-as;
  failed read-only save preserving the previous destination; two independently
  saved buffers with restart/cursor restoration; background checkpoint + forced
  termination; closed tabs staying closed; corrupt recovery; concurrent writer
  rejection; and failed quit flush with manual text rescue before explicit quit.
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
evidence is recorded. M2 recovery is partial: retention, private buffers, and broader
durability qualification remain open. M3 syntax/editing tools and M4/M5 AI are not
implemented. The prototype should not hold the only copy of important text.
