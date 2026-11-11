# Architecture

## Shared engine, native interfaces

```text
AppKit / Swift ── small C ABI ──┐
                              ├── Rust engine ── documents / history / commands
Terminal UI / Rust ────────────┘                ├─ local transforms / proposals
                                               └─ explicit AI adapter (later)
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
  into a String for every keystroke. Add transaction grouping and history limits M2.
- Every mutation, including undo/redo, advances a monotonic revision. Dirty tracking
  uses history state identity so undo to a saved state becomes clean again.
- AppKit should patch its presentation storage instead of replacing the whole view
  on every keystroke. Viewport reads in the TUI do not serialize the entire document.

## Bridge ownership

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
history. Both clients check hidden buffers before quitting, and closing the last
buffer creates a fresh empty one. Scroll geometry remains the responsibility of
each interface.

The engine provides versioned recovery checkpoints. Capture filters out private
buffers before cloning immutable ropes, paths, or selections. The stored active
index is remapped to the retained ordinary tabs. If the active tab is private,
restart selects the preceding ordinary tab (or the first if none precedes it).
A private-only session checkpoints a fresh empty ordinary scratch. The format
remains version 1 and all restored buffers are ordinary.

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
regardless of its dirty flag; quitting checks hidden private text too. The frontends
allow an explicit file copy without attaching that path to the private tab or
enabling its recovery. Private document text/history remain in process memory.

Retention remains pending. Recovery persists ordinary text without encryption.
This feature excludes private buffers from app-owned recovery; it does not erase
earlier ordinary snapshots, clipboard contents, explicit exports, or OS-managed
swap/crash data. Future AI, recipes, and diagnostics must reject private buffers
before collecting text. Those services do not exist in the current offline app.

Save buffers through a same-directory temporary file + flush/sync + atomic replace,
with a documented symlink/permissions policy and external-change check. Prototype
save support must be labeled until these semantics are complete.

## Commands, transforms, proposals

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

One optional OpenAI adapter is enough initially. Use the Responses API and supported
structured outputs for recipe proposals; confirm model availability at implementation.
Do not add provider frameworks or an agent runtime. Network work never holds the
document/UI thread. Cancellation and revision validation protect in-flight edits.

The key lives in macOS Keychain, or only in the environment of a Linux TUI session;
never write it to a project config, logs, snapshots, or action files. Provider requests
are explicitly invoked and scoped. A private document cannot produce an AI request.
Secret detection can assist the user later, but cannot enforce these promises alone.

## Reference documentation

- [Ropey](https://docs.rs/ropey/1.6.1/ropey/)
- [Ratatui](https://docs.rs/ratatui/0.29.0/ratatui/)
- [Apple text editing](https://developer.apple.com/library/archive/documentation/TextFonts/Conceptual/CocoaTextArchitecture/TextEditing/TextEditing.html)
- [Syntect](https://github.com/trishume/syntect)
- [OpenAI structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses)
