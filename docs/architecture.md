# Architecture

## Shared engine, native interfaces

```text
AppKit / Swift ── optional OpenAI adapter + Keychain (Mac only)
       │
       └── small C ABI ──┐
                        ├── Rust engine ── documents / history / commands
Terminal UI / Rust ──────┘                 └─ local transforms / proposals / recipes
```

The Rust engine owns committed text and undo history. Both interfaces submit
changes to it. AppKit owns native input, text presentation, selection, accessibility,
and IME composition. The terminal client owns terminal events and cell layout.
Transient IME composition is reconciled at commit, rather than becoming a second
undo history. The initial AppKit mirror is a measured prototype, not proof that
duplicating text meets the final memory budget.

Initial dependencies: Ropey for the UTF-8 rope, Unicode segmentation for cursor
boundaries, Ratatui/Crossterm for the terminal. Start from an ordinary Cargo workspace
and a Swift Package. No runtime service, webview, or JavaScript engine is required.

## Text positions and history

- Internal edit ranges use Unicode scalar indices, with explicit validation.
- The C bridge converts AppKit UTF-16 ranges at the boundary and rejects offsets
  inside surrogate pairs. Byte offsets, UTF-16 units, graphemes, and terminal cells
  must never be interchanged implicitly.
- User navigation/deletion operates on grapheme boundaries. CRLF stays intact.
- Changes keep inserted/removed payloads for undo; do not clone the whole document
  into a String for every keystroke. Adjacent input groups share one history entry
  containing ordered deltas, avoiding repeated prepend/copy of deleted runs.
  History retention is bounded per document as described below.
- Every mutation, including undo/redo, advances a monotonic revision. Dirty tracking
  uses history state identity so undo to a saved state becomes clean again.
- AppKit should patch its presentation storage instead of replacing the whole view
  on every keystroke. Viewport reads in the TUI do not serialize the entire document.

`Document::edit` distinguishes typing, backspace, forward delete and isolated
operations. Only adjacent operations of the same input kind coalesce, with less
than one second between edits. Line boundaries, selection replacement, clipboard
operations, navigation, explicit save, undo/redo and tab changes separate steps.
Each group is bounded to 512 edits and 64 KiB of changed payload. A single large
paste is still one isolated step.

Undo and Redo share a per-document retention budget of 32 MiB of charged history
allocations and 1,024 complete steps. Accounting includes string capacities and
change-vector capacity, rather than text lengths alone. Each real edit discards
the divergent Redo branch and evicts oldest whole Undo entries through a deque,
without shifting the remaining entries or rescanning the entire history. Moving
an entry between Undo and Redo retains its charge. The newest atomic operation is
always retained, even when it alone exceeds the byte budget; a subsequent edit
can expire it. Current text, state identities and save points are never rewritten
by retention. This bounds retained history, not total process RSS or peak memory
while applying a large edit; allocator overhead and unused outer-container slots
are outside the charge. Each open document has its own budget.

Every edit advances state/revision even when added to an existing group. Undo
reverses its deltas in reverse order and redo replays them forward; each advances
revision once. File-save points end a group, so undo can return exactly to a clean
saved state. Recovery only copies document state and never changes input grouping.
Explicit replacement APIs remain isolated by default; input adapters opt into
coalescing. AppKit tracks the outermost editing action so internal `insertText`
calls cannot turn paste into typing, and distinguishes automatic caret updates
from user selection changes. The TUI classifies key events versus bracketed paste.

Mac history presentation uses `Document::undo_with` / `redo_with`: the engine
replays the existing history and exposes each replacement before mutating its
source state. The bridge converts that step's coordinates to UTF-16 and returns
an owned `VcHistory` frame with cursor, source/target lengths and replay-order
edits. No Swift/AppKit callback runs while Rust holds the document. The frame
contains at most 1 MiB of conservatively estimated encoded JSON and 4,096 edits;
if either budget is exceeded, it returns `edits:null` after completing the same
history operation. Mac then takes a full snapshot without replaying history again.
The ordinary Rust Undo/Redo APIs use an empty observer and retain their behavior.

AppKit validates the sequence's lengths/ranges before changing text storage,
applies edits in one storage editing group, and gives inserted ranges the current
uniform typography. Marked text or a mismatched presentation length also uses the
snapshot fallback. Full presentations set text and typography together rather
than assigning text and then restyling the whole buffer. These frames are transient
presentation data, including in private tabs; they are never logged or persisted.

## Logical-line geometry and viewport reads

`text` walks Rope chunks with GraphemeCursor instead of copying/scanning the
current line from its start for each Left/Right/Backspace. When a boundary needs
preceding context, it replays with a contiguous window that grows on demand;
emoji, Indic and regional-indicator rules remain intact across chunk boundaries.
Printable ASCII runs advance together, leaving their last scalar for normal
segmentation in case a combining mark follows in another chunk.

Each document has an LRU geometry cache for eight logical lines. Sparse points
record byte/scalar/UTF-16/cell offsets, initially about every 4 KiB; at 4,096 points
the line coarsens its stride and retains alternate points. Point storage is thus
at most 1 MiB per document, plus small container/allocator overhead. The first
distant column lookup scans its prefix; subsequent reads start at a nearby point.
Edits, batch edits, Undo and Redo invalidate the affected suffix and later lines,
preserving only checkpoints strictly before the changed scalar. No-op/invalid
edits preserve the cache. Cache reads change no revision, recovery state or grant.

The terminal requests only whole graphemes intersecting the visible cell range,
with original scalar/UTF-16/cell origins for selection, Find and syntax painting.
It reads logical-line bounds directly from the Rope. Current-revision syntax
frames need no full-line hash; stale colors are checked only for bounded short
lines. Multicursor movement/deletion in both clients uses this same geometry,
replacing the old per-operation array of every grapheme boundary.

This is not a hard execution/allocation limit for pathological Unicode: one
grapheme, or its required context, can be arbitrarily long. Word double-click
still uses the full logical line. Native AppKit paragraph layout remains separate
qualification work. Mac snapshot copy-out fills the
Swift String's UTF-8 storage directly, avoiding an intermediate zeroed byte array;
ordinary edits still submit deltas.

Mac enables noncontiguous layout for a caret line up to 32,768 UTF-16 units and
the initial bounded window in large-text mode, and uses contiguous layout beyond
that window: the latter avoids a measured tail-input regression. The choice updates from Rope metadata
on selection, edit, buffer and history changes, without scanning the source.
Background AppKit layout is disabled; visible requests drive layout. Syntax/Find
only clear their temporary attributes when they previously painted any. This
does not change wrapping, truncate text or make first layout of a giant paragraph
cheap; large-file memory and broader renderer qualification remain open.

Window construction resolves the empty scroll view's geometry before loading
the first document. Otherwise the initial caret reveal lays out the paragraph at
the provisional container width, and Auto Layout invalidates that work when the
viewport reaches its actual width. The native first-presentation smoke checks
that initial width remains stable after loading, as well as first input, history,
full selection, tab/caret restoration, private tabs, resizing and appearance.
The profiler includes the first bitmap draw and first input at the beginning:
moving work from show into drawing or typing is not a presentation improvement.

## Line numbers and numerical statistics

The Mac gutter is an `NSRulerView` driven by visible native line fragments; logical
line indexes/ranges come from Rope metadata through the bridge. The TUI paints a
separate gutter from its existing visual-row projection and subtracts its width
before hit testing/wrapping. Both draw logical numbers, accent the current line,
use dots for wrapped continuations, and select the full logical line (including its
ending) on a number click. Visibility is a client-session view preference; it does
not change text, history, recovery status or grants.

`metrics::Engine` owns revision/selection-bound **numeric-only** frames. It counts
extended grapheme clusters (including one CRLF), words as runs of graphemes
containing letters/numbers/underscores, logical lines and UTF-8 bytes. Nonempty
selection ranges are merged before counting; touched line intervals are unioned,
excluding the next line when a selection ends exactly at its start. Empty text
has one document line and zero selected lines. Targets/selections/carets are counted
separately. Bytes are metadata for the source text, not a disk-file size promise.

Up to 4 KiB is counted inline; larger scans use a lazy background worker over an
immutable Rope snapshot without flattening. Document totals are reused for cursor
and selection changes. Document/revision epochs cancel obsolete source work;
selection serials cancel obsolete selection work without starving document totals.
Scans stop at 64 MiB or an elapsed 500 ms budget (checked between chunks/graphemes).
Oversized/pathological input retains exact line/byte metadata and shows unavailable
character/word counts, never a partial total. As with existing grapheme navigation,
one pathological cluster/context can exceed a cooperative cancellation interval.
No numeric frame serializes source text. Workers sleep on a condition variable;
clients poll every 25 ms only while counting, then stop. This is independent of the
existing recovery, syntax, search and explicitly open Secret Drop timers.

Mac shows compact primary counts, exact details in a live popover and a tooltip;
TUI uses a width-adaptive status line and F11 details. Neither moves the caret or
marks the document edited when updating counts.

## Large-document policy

`limits.rs` defines shared byte/history budgets and the 512 KiB large-document
threshold. Both clients use it for visible mode state; existing syntax/search/
tools/statistics/history engines enforce the same values. Pointer-word selection
uses a shared, at-most-64-KiB logical line scan. Giant-line double click declines
with a fragment-selection hint instead of flattening/scanning the line on input.

Mac `BudgetTypesetter` subclasses the existing `NSATSTypesetter`. In wrapped large
mode, `setParagraphGlyphRange` delegates a prefix of at most 256 Ki glyphs to native
layout, with a zero-length separator at a composed-character boundary. No synthetic
newline is inserted and no source/native offset translation is needed. Native
input, Find/multicursor ranges, clipboard, history and file saving remain intact.
Short paragraphs and standard/no-wrap mode use the original full paragraph range.
Auto also prepares full native context for distant selections/paste, caching that
choice for the active document revision so repeated navigation does not reflow it.
A new prefix edit can return to bounded context. On forces bounded chunks; Off
retains standard behavior. `setPlainText` suppresses transient installation-time
selection callbacks so a temporary EOF does not accidentally expand context.
The existing caret-line layout policy additionally enables noncontiguous layout
inside the first budget window; the tail retains the faster contiguous path.

Splitting bidi context could alter visual ordering. `Document::native_paragraph_budget`
therefore returns zero for RTL/Arabic-number classes and directional embeddings,
overrides and isolates. It uses [`unicode-bidi::bidi_class`](https://docs.rs/unicode-bidi/0.3.18/unicode_bidi/fn.bidi_class.html),
pinned at 0.3.18. ASCII Rope chunks skip scalar decoding; the result is cached by
revision. One oversized composed cluster also falls back to full native context.
These fallbacks prioritize existing text semantics over a layout latency claim.

Bounded context improves first presentation and local editing but the native
layout driver may fill preceding holes on distant navigation. This is measured
and disclosed as a trade-off, not hidden behind a first-frame-only benchmark.
No renderer migration, permanent background prelayout or idle polling is added.

## Bridge ownership

Indentation and inherited-newline input use `Document::editing_plan`. It produces
sorted prefix/replacement edits and mapped selections before the caller applies
one atomic transaction. Ranges ending at a following line's start exclude that
line; multicursor targets deduplicate touched lines. Commands use four-cell tab
stops, preserve hard tabs/line endings and enforce 100,000-line / 8 MiB insertion
limits. The native bridge returns bounded replay-order UTF-16 patches plus the
new selection; a missing patch list requests the existing full-snapshot fallback
after applying once. Empty outdents do not change history or grants.

TUI soft wrapping projects logical lines into greedy grapheme-safe visual rows.
The existing per-document line cache also retains sparse row-start checkpoints,
coarsening at 4,096 points per cached line and retaining up to eight lines. Edits
invalidate only affected suffixes. Only visible row text is copied. Drawing, pointer
hit testing, scrolling and keyboard navigation share that projection. Mac retains
native layout. Wrap state is a client-session view preference, excluded from
document revisions/checkpoints; status columns come from shared logical geometry.

Expose opaque document and session handles. The creator frees an owned handle
exactly once. Session documents are borrowed until the next session mutation and
must not be freed independently; Swift resolves the active pointer for each call.
Text and metadata use caller-owned copy-out buffers. Validate null pointers,
UTF-8, and ranges. Handles are thread-confined. No Rust panic may unwind through C.
On allocation failure the process may abort; normal malformed requests return an
error status. Keep public surface small and verify with a native link/smoke test.

## Documents and persistence

One process owns one session. Both clients understand the same recovery/action
formats; live concurrent editing of the same scratch session is outside MVP.
Opening the same file in two processes requires external-change checks before save.

The shared Rust session owns its buffer collection, active index, scratch numbering,
file destinations, and saved selections. Each buffer has an independent document
history. Both clients check hidden buffers before quitting. The engine maintains
at least one buffer, creating an empty fallback after the last closes. The TUI
displays that fallback; the Mac UI closes its window and exits instead. A Mac
last-tab close flushes an empty checkpoint before dropping the live document,
so cancelling after a failed flush keeps the text intact. Whole-window close and
Cmd+Q preserve ordinary tabs; explicit tab close removes them from recovery.
Scroll geometry remains the responsibility of each interface.

The engine provides versioned recovery checkpoints. Capture filters out private
buffers before cloning immutable ropes, paths, or selections. The stored active
index is remapped to the retained ordinary tabs. If the active tab is private,
restart selects the preceding ordinary tab (or the first if none precedes it).
A private-only session checkpoints a fresh empty ordinary scratch. The format
remains version 1 and all restored buffers are ordinary.

Terminal selection is an anchor plus active caret in Unicode scalar positions.
The client normalizes its range when storing session metadata, with an optional
selection_head endpoint to preserve direction. The checkpoint validates this
endpoint and accepts older snapshots without it. The Mac adapter clears terminal
direction metadata when setting its native NSRange. Selection-only checkpoint
updates are quiet in both interfaces; they never mutate source/history. TUI
rendering maps whole graphemes to cells and applies the Pocket selection style
over syntax; mouse hit testing uses the inverse mapping. Selection edits use the
same isolated Document transaction as native replacements, with no second history.

The Mac window disables AppKit window-state preservation and snapshot restoration
at construction. The filtered Rust checkpoint is the sole document recovery path;
window-frame preferences still store only geometry. See Apple's
[window preservation](https://developer.apple.com/documentation/appkit/nswindow/isrestorable)
and [snapshot restoration](https://developer.apple.com/documentation/appkit/nswindow/disablesnapshotrestoration()) APIs.

Capture clones immutable ropes
instead of serializing on the input thread. Mac debounces capture, serializes/writes
on a background queue, and flushes that queue on quit. The client owns its Application
Support directory and process lock. Writes use atomic replacement and owner-only
permissions. Invalid snapshots do not replace a live session; failed restore disables
automatic writes to preserve the original. Undo history is not persisted.

Terminal uses the same checkpoint API with a worker queue and an exclusive process
lock. Its default storage is separate from the GUI session. Normal quit fences
pending writes; a failed flush keeps the editor open unless the user explicitly
quits without the latest changes. Startup refuses corrupt data and an already
owned session before entering raw terminal mode. Idle input and worker queues block.

Private scratches are chosen at creation; ordinary buffers cannot be converted
after earlier checkpoints may have persisted them. Labels are generic even if a
private document has a path. Closing a nonempty private tab requires confirmation,
regardless of its dirty flag; quitting checks hidden private text too. After a
successful explicit file write, both frontends call shared `Session::complete_save`:
revoke the tab's grant, attach the destination, end private mode, and mark saved.
The tab then participates in ordinary recovery. Failed or cancelled writes never
call completion and preserve mode, path, dirty state and grant. Text, selection and
undo history remain intact; undoing text does not re-enter private mode.

Retention remains pending. Recovery persists ordinary text without encryption.
This feature excludes private buffers from app-owned recovery; it does not erase
earlier ordinary snapshots, clipboard contents, explicit exports, or OS-managed
swap/crash data. Future AI, recipes, and diagnostics must reject private buffers
before collecting text. Those services do not exist in the current editor.
Secret Drop is a separate, explicitly invoked local export described below.

## Local syntax pipeline

Each document has a stable runtime identity and monotonic revision. Language
override is per-buffer metadata; checkpoints persist it only for ordinary tabs,
with an optional field compatible with version 1 snapshots. Detection uses a
bounded sample and conservative filename/shebang/content rules. Private paths are
not passed to the detector. Plain Text bypasses grammar loading entirely.

A lazily created Session worker owns parsing and a single-document incremental
cache. Requests contain a cheap immutable Rope clone plus identity/revision/path/
mode. One latest-wins pending slot replaces queued work; the worker checks
cancellation between lines. Syntect with two-face grammars and the pure Rust regex
backend generates semantic role IDs. Checkpoints every 32 lines allow reparsing
from before the first changed line. A changed grammar/document resets the cache.
Soft slices publish partial results and resume from a parser-state checkpoint.
Hard size/line/span caps provide an explicit limited preview; see development.

Immutable frames contain only metadata, UTF-16 ranges and role IDs, never source
strings. The C ABI returns an owned frame handle backed by Arc, so two-pass copy-out
cannot race a newer result. The live Session remains thread-confined. Clients
poll only while work is pending, reading busy before taking the frame to avoid
missing a completion between those operations. Results must match the current
document, revision, path and override. AppKit temporarily colors visible text;
terminal rows additionally check their current line hash before reusing colors.
Neither path mutates source, history, selection, saved-state flags or Secret Drop.
The same palette roles have separate light/dark render colors in both clients.

No parser state or painted source is written to disk; no provider is involved.
This does not securely erase process memory or OS-managed swap. Imported grammar
licenses are shipped with the bundle and exposed by the CLI.

Save buffers through a same-directory temporary file + flush/sync + atomic replace,
with a documented symlink/permissions policy and external-change check. Prototype
save support must be labeled until these semantics are complete.

Save As always asks for a destination, including for an already attached file.
Mac uses the native panel and its replacement confirmation; terminal F4 uses a
filename prompt and an explicit second Enter for an existing destination. Filename
edits/cancellation clear pending replacement approval. Both reuse the ordinary
write/completion path: changing the session's destination happens only after a
successful write. Save As does not create a second tab or reset text/undo/selection.
The old file stays untouched when choosing another destination. Known read-only
files and symlinks are rejected; external-change and race qualification remain M2.

## Secret Drop: explicit local export

The session lazily owns one `DropHost`, an embedded Unix-socket worker. Publishing
is permitted only for a nonempty private document. It stores an immutable UTF-8
value and random capability in memory; the document owns a revocation link.
Real edits, undo/redo, successful file save, closing, or dropping the document remove that grant. Session
Stop clears all grants. Recovery never captures the host, link, reference or value.

Each editor uses a random socket under an owner-only per-user directory. Socket
mode and peer UID are checked in both directions. Requests are length-prefixed,
bounded JSON containing only the access token; replies contain the value or a
generic denial. There is no enumeration, executable request, plaintext-read CLI,
or TCP listener. The editor never runs the agent's requested program.

`vibechar run <reference> --env NAME -- <program> [args...]` dispatches before TUI
or recovery initialization. The helper fetches once, injects the environment
variable, launches under the caller's permissions, streams literal output masking,
and preserves exit status. Two independent stream filters handle stdout/stderr,
including read-boundary matches, with bounded state and linear processing.
Program arguments and helper errors never include the fetched value. A trusted
child receives the actual value and can still retain, encode or transmit it.

Successful requests refresh a 30-minute idle timeout. Status reads prune expired
grants without extending access. Frontends update status once per second only while
any grant is live; ordinary idle sessions still block. Mac additionally listens for
lock/sleep/session resignation. Terminal OS-event hooks are deferred. Revocation
affects future fetches, not data already delivered to a child.

The Mac app bundles the helper; both interfaces copy a ready instruction containing
its absolute path and opaque reference. Clipboard reads happen only on Paste Secret
for Agent. Failed instruction copies revoke access. No provider API, model request,
agent runtime, or per-agent MCP setup is involved. See the
[full contract](secret-drop.md) for limits and remaining acceptance checks.

## Commands, transforms, proposals

`multi::Multi` owns transient anchored selections, their primary index and the
document identity/revision. Both adapters use the same seed/next/all, adoption,
navigation, clipboard-text and edit operations. Next/all reuses the local search
worker with literal/case-sensitive matching plus streaming grapheme/word boundary
filters. It queues rapid requests until a current frame exists. Find can adopt
its actual regex/literal hits after identity/revision/budget checks, including
zero-width carets. UI adapters never independently expand edit ranges.
While matching is pending, bounded input/navigation is queued in the shared core.
The UI-thread pump adopts the current frame and replays actions in order; stale/
limited failures cannot apply queued text to only the initial range. Adapters
compare revisions when pumping so deferred edits update mirrors and real-save
status. Commands that could discard queued input first pump it or require retry.

Multicursor edits normalize overlapping deletion targets, check the aggregate
payload and apply descending through `Document::replace_many_input`. A history
entry records batch-step counts separately from individual target changes, so
bounded typing/deletion runs group without merging with ordinary single-cursor
input. Undo/Redo replays the complete sequence and returns a valid single caret.
The shared sparse line geometry supplies whole-grapheme deletion and logical-line/
cell navigation without building a point for every character. Sets are not stored
in session checkpoints; only the primary uses existing quiet recovery.
Paste is a distinct shared action: it distributes equal-count clipboard lines,
otherwise replicates the full payload. Both paths use the same atomic edit helper
and map each resulting caret by its own inserted length. Queued paste determines
distribution only after the matching frame establishes the actual target count.
Typed/newline input never uses clipboard distribution. No clipboard cache or
platform-specific provenance data is retained.

Mac keeps one native primary selection and paints secondary ranges/carets; AppKit
does not expose multiple empty selectedRanges. PocketTextView routes supported
input through Rust before native mutation, mirrors accepted text once and guards
programmatic selection callbacks so they do not break grouped input. IME marked
text clears the set first. Terminal shares the same ranges/history, renders only
visible intersections and polls only while matching is pending. Selection metadata
alone cannot trigger the Saving locally text-change status.

The find/replace worker owns a latest-wins request slot, a compiled-regex cache
and an immutable rope snapshot. It is created on opening Find and sleeps when idle;
closing Find or changing tabs releases it. The key includes document identity,
revision, literal/regex and case options, query and replacement. Requests invalidate
old frames immediately. Normal find frames expose scalar/UTF-16 ranges; replacement
frames additionally expose bounded before/after examples, while full edits remain
private to the engine. The C bridge owns stable Arc-backed frame handles for
two-pass copy-out. Query/preview state never enters session checkpoints.

`Document::replace_many` validates sorted, nonoverlapping ranges and builds removed
payloads before changing text. It applies in descending source order, then pushes
one shared history entry, advances revision once and clears redo. Undo reverses
that ordered transaction; redo replays it. No-op batches advance no state and do
not revoke Secret Drop. A real batch revokes the document's grant once, like any
other edit. Find applies only when the engine request/serial, document and revision
still match the preview. Error/limited results are not partially applied. Search
budgets and replacement-group expansion bounds are documented in development.

The implemented `tools` module owns a nine-command catalog, shared query filtering,
bounded transformations and revision-bound plans. Both adapters display the same
IDs/titles/semantics. On Enter, a job captures a cheap immutable Rope snapshot and
explicit scalar range, extracts/transforms up to 1 MiB on a worker and returns a
plan over a one-slot channel. Neither adapter scans/transforms source on its input
thread. Dropping a job discards its result; it never applies from the worker.
The C bridge owns the job, polls nonblockingly and converts UTF-16 only at the
boundary. Apply checks identity/revision and uses `replace_many`, so history,
dirty state and Secret Drop behavior stay shared. Errors have metadata-only messages;
JSON formatting preserves original token lexemes after validation with IgnoredAny.
Case changes use Unicode string mappings, preserving context-sensitive casing.
URL component encoding preflights its output budget; decoding is a strict one-pass
UTF-8 conversion. Both use the same selected-range plan and history as other tools.
Queries/jobs are transient and excluded from persistence. Named tools apply on
Enter and use Undo for reversal; inference/recipe previews remain future work.

Common operations are commands, not UI callbacks. A local transform returns edits
for a specified selection. A proposal is bound to document identity, source revision,
and an explicit target. Acceptance validates the unchanged source and protected spans,
then applies all edits as one undo transaction. Rejection is a no-op.

Example inference returns a bounded declarative recipe, never executable source.
Recipes pass local shape/cost validation and must reproduce the example before
being offered. A valid schema does not prove a semantically correct transformation;
the preview and example checks remain necessary. Preserve unsupported and ambiguous
cases as first-class outcomes. Local recipes and AI prompts have different execution
and privacy properties, visible in the command palette.

## AI boundary (M4–M5)

Scope updated 2026-11-17: provider networking and AI interaction are Mac GUI-only.
Use a small asynchronous native adapter (URLSession) for OpenAI Responses and model
discovery, with Keychain credential storage. TUI has no AI settings, OpenAI
environment-key lookup or provider calls of its own. Rust still owns proposals, recipe validation, source revision
checks and atomic document/history application. No provider framework or agent runtime
is needed. Supported structured outputs for recipes are a later M5 concern.

M4.1 implements Settings → AI only: masked key entry, replace/delete, model choice
and an explicit connection test. Non-secret model ID belongs in normal preferences;
the key never belongs in config, logs, snapshots, recipes or raw error diagnostics.
Model discovery supplies IDs/availability; compatibility comes from a small supported
text-model catalog, confirmed against current official docs at implementation time.
Model-list permission failures are separate from invalid credentials. Testing a
selected model sends a small fixed synthetic input through Responses, with bounded
output, timeout/cancellation and no editor/clipboard context. Disclose API billing.
Changing key/model invalidates stale results; failed tests do not erase a working
saved configuration. All provider I/O is explicitly invoked and stays off the UI
thread. Automated tests use fixtures and isolated Keychain service entries.

M4.2 adds Mac rewriting/previews. Cancellation and revision checks protect in-flight
edits. A private document cannot produce an AI request; the global Settings test
is independent of documents and sends synthetic input only.
Secret detection can assist the user later, but cannot enforce these promises alone.

## Reference documentation

- [Ropey](https://docs.rs/ropey/1.6.1/ropey/)
- [Ratatui](https://docs.rs/ratatui/0.29.0/ratatui/)
- [Apple text editing](https://developer.apple.com/library/archive/documentation/TextFonts/Conceptual/CocoaTextArchitecture/TextEditing/TextEditing.html)
- [Syntect](https://github.com/trishume/syntect)
- [OpenAI structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses)
- [OpenAI model discovery](https://developers.openai.com/api/reference/resources/models/methods/list)
- [OpenAI Responses](https://developers.openai.com/api/reference/resources/responses/methods/create)
