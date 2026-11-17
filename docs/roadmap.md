# Roadmap to MVP

Status: active. Owner: Art. Started: 2026-11-11.

## The product promise

A lightweight text editor you reach for dozens of times a day. It opens immediately,
handles pasted technical text comfortably, and lets you describe or demonstrate a
transformation without turning the editing session into a conversation.

The first agent workflow is **Secret Drop**: copy a token, invoke Paste Secret for
Agent, paste the prepared instruction into a local agent chat. The agent uses it
in a command without the editor returning plaintext to the chat. Mac and terminal
share this operation; no agent-specific setup is required.

The later transformation demo: paste a list, edit one item into the desired shape, invoke
"Do the rest", review the affected items, accept, then save the transformation as
a named action. Reapplying a supported structural action runs locally.

This is a product hypothesis. The first prototype must establish that the example
is sufficiently unambiguous and that reviewing the result is faster than writing
a prompt or a script. Recognition of arbitrary editing intent is not promised.

## MVP contract

### Everyday editing

- macOS app and a real full-screen terminal editor; no desktop process needed for TUI.
- UTF-8 text, Unicode-aware movement and deletion, selections, undo/redo, copy/paste.
- New scratch buffers, switching buffers, open/save/save-as for individual files.
- Literal/regex search and replace with a preview; basic multicursor editing.
- Wrap toggle, indentation, line/column position, light/dark appearance on Mac.
- Preserve existing file bytes where no edits occur, line endings, and final newline.
- Unsupported encodings and binary files produce a useful error instead of conversion.
- Explicit errors for failed saves; preserve the buffer and previous destination.

### Useful without AI

- Language detection with an explicit override and syntax highlighting.
- First-class JSON, JSONL, YAML, TOML, Markdown, shell, SQL, JS/TS, Python, Rust, Swift;
  extend coverage through vetted syntax definitions rather than handwritten lexers.
- Format/minify valid JSON, sort/deduplicate lines, trim, change case, URL encode/decode.
- One command palette shared in meaning between both interfaces.
- Ordinary scratch buffers recover after restart; a private buffer never enters
  recovery storage, saved actions, AI requests, logs, or diagnostic attachments.
- Secret Drop explicitly exports one private value to a local command through a
  temporary reference and environment injection. This does not enable model
  rewrites or automatic collection of private buffers.
- No automatic clipboard monitoring. Paste happens when the user invokes it.

### Optional AI

- Scope updated 2026-11-17: AI features ship only in the macOS GUI for MVP.
  TUI remains a local editor with Secret Drop; no provider keys or AI requests.
- First increment: native Settings → AI (Cmd+,), user-supplied OpenAI key in
  macOS Keychain, connection test and model selection. No Vibechar account.
- Model discovery and a short synthetic selected-model test are explicit actions;
  connection testing never reads editor buffers or the clipboard.
- "Change selection": explain a transformation, receive a preview, accept/reject.
- "Do the rest": provide original + edited example and explicitly chosen target.
- A small local recipe language for supported structural transforms; unsupported
  intent is explained or handled as a one-off model rewrite after explicit choice.
- Named local recipes and named AI rewrite instructions are visibly distinct.
- Cancellation, network/provider errors, and stale results leave the text untouched.
- Protected text spans are enforced by the engine rather than only by a prompt.

### Deliberately outside MVP

Projects/folder trees, Git clients, LSP/completion, debuggers, arbitrary executable
plugins, background AI, chat histories, MCP servers, cloud sync, collaboration,
mobile clients, local model bundles, semantic indexing, Windows GUI, and a hosted
subscription service. Semantic selection is an experiment after the flagship
transform workflow proves useful; do not gate MVP on it.

## Milestones and release gates

Proceed in order. Each gate must have evidence; code existing is not proof of a
working interface, and local builds are not release validation. Checkboxes describe
completed work only. There are no calendar promises before M1 measurements.

### M0 — Product and engineering contract

- [x] Define the product, scope, AI hypothesis, and non-goals.
- [x] Document shared engine ownership and native interface boundaries.
- [x] Define interaction principles and provisional performance targets.
- [x] Write an executable delivery order and acceptance gates.

Exit: this roadmap, design, architecture, and local development instructions exist.

### M1 — Prove one engine works in two interfaces

- [x] Build a Rust document engine with Unicode-safe edits, monotonic revisions,
  correct dirty tracking, undo/redo, and UTF-16 conversion for AppKit.
- [x] Build a TUI with input, navigation, scrolling, bracketed paste, open/save,
  undo/redo, and a clean terminal restoration path on errors and normal exit.
- [x] Build a native AppKit shell that sends edit deltas to the same engine.
- [x] Test the C boundary and build/link a standalone development .app.
- [x] Exercise the real TUI and Mac UI, including Russian text and emoji.
- [ ] Record baseline startup and memory measurements, including bridge copies.

Exit: edit equivalent sample text in both clients, undo/redo to identical content,
save it, and verify bytes. Mac and TUI can run independently. The native text
system may retain a presentation copy, but cannot own a competing document history.
Do not commit to AppKit as the final renderer until its memory and typing costs
are measured with larger documents.

### M2 — Make it a dependable daily scratchpad

- [x] Shared in-memory buffer collection, new/switch/close, and unsaved-close protection.
- [x] Mac final-tab close exits through the window lifecycle; explicit closure is
  persisted without spawning another visible scratch. TUI keeps its empty fallback.
- [x] Save As for existing file buffers, cancellation/failure protection and
  overwrite confirmation in Mac and terminal, verified with native/PTY checks.
- [ ] Atomic saves, clear policy for symlinks/permissions/external file changes.
- [ ] Debounced recovery journal, crash recovery, retention limits, private mode.
- [x] Mac local session checkpoints and restart restoration (first recovery increment).
- [x] Wire terminal recovery, worker saves, quit flush, restart, and process ownership.
- [x] Private scratches in both clients: recovery exclusion, generic titles,
  persistent mode labels, explicit saving to ordinary file tabs, and close/quit confirmation.
- [x] Art's Mac hands-on acceptance of private creation and saving into an ordinary
  file tab. Terminal manual acceptance remains part of platform qualification.
- [ ] Qualify remaining durability cases and retention; audit private mode again
  when actions, diagnostics, and AI are introduced.
- [x] Group adjacent typing/backspace/forward-delete into shared undo steps, with
  pause, navigation, paste, save and tab boundaries in Mac and terminal.
- [x] Bound per-document Undo/Redo retention by allocation bytes and complete
  steps in the shared engine, preserving one oversized atomic operation.
- [x] TUI keyboard/mouse selections, word double click, drag autoscroll, clipboard,
  selection replacement/deletion and per-tab/restart direction preservation.
- [x] Shared Tab/Shift+Tab block indentation and per-caret stops, inherited indentation
  on Enter, CRLF-aware scratches, mapped selections/multicursors and atomic Undo.
- [x] Visual wrap toggles in both clients, logical line/column footer, TUI visual-row
  mouse/selection/navigation and bounded sparse wrapping geometry.
- [x] Logical line numbers with active-line accent, wrap continuation markers and
  click-to-select-line in both clients; shared grapheme/word/line/byte counters,
  selection unions and multicursor totals, with bounded background counting.
- [ ] Word navigation improvements; qualify selection/clipboard
  across terminal emulators and Linux.
- [ ] IME composition, accessibility, keyboard layout, and UTF-16/grapheme tests.
- [x] Decide same-machine simultaneous editing: separate sessions in MVP; no silent
  cross-process sharing or overwriting of another session's scratch recovery.

Exit: a week of personal use with no lost text, corrupted Unicode, silent overwrite,
or unexpected secret persistence. Failed disk writes and forced process termination
have meaningful integration tests. Private mode promises are audited end to end.

### M2a — Early Mac interface design and implementation

The rejected engineering shell has been replaced by the first native Pocket
increment. Art accepted it on 2026-11-12. Remaining visual qualification and polish
stay open, while the next behavior increments resume M2.

- [x] Compare three visual studies; Art selects Pocket and the `V_` brand mark.
- [ ] Follow the [interface roadmap](interface-roadmap.md): visual studies, selected
  direction, compact chrome, custom tabs, typography, light/dark, and interaction.
- [x] Implement one coherent Mac interface increment; stop for hands-on feedback.
- [ ] Check tab overflow, narrow windows, focus, empty/content/error states.
- [x] Art accepts the first working interface. M6 rechecks final polish/performance.

### M2b — Secret Drop: private text to local agents

Art selected this as the next main feature on 2026-11-12. Follow the
[Secret Drop contract](secret-drop.md): a clipboard fast path, explicit sharing of
one private scratch, a reusable memory-only reference, and `vibechar run` injection
into a child process. Implement the same operation model in Mac and terminal.

- [x] Shared local broker, CLI, editor commands/status and revocation.
- [x] Verify exact injection without disclosure, output masking, no recovery data,
  reference isolation, expiry, edits, close/quit and failed access.
- [x] Build a runnable Mac/terminal increment with native and real PTY checks.
- [x] Saving a private tab ends private mode and revokes its grant only after a
  successful write. Cancellation/failure preserves private mode; both clients agree.
- [x] Art's Mac hands-on acceptance of Give to Agent and Stop: the local helper
  received a nonempty value, then the old reference was rejected after Stop.
- [ ] Qualify actual OS lock/sleep notifications, Linux runtime/clipboard support,
  and terminal lock/sleep behavior. Remote/cloud agents need a separate design.

### M3 — Fast local text tools

- [x] Shared background incremental highlighting, viewport painting, local filename/
  content detection, and a short searchable language override (Mac and terminal).
- [x] Integrate Syntect + two-face with 186 visible grammars, Pocket light/dark colors,
  lazy loading, version-bound results and bounded pathological-input fallback.
  Primary paste cases, incremental invalidation, large/minified limits, recovery,
  native rendering and real PTY behavior are verified. Full latency/memory targets
  and multiple terminal emulators remain open; see verification.
- [x] Shared local literal/regex find and replace, case matching, highlighted hits,
  next/previous navigation, per-match replacement and a batch preview in both clients.
- [x] Select next/all occurrences and current Find hits for editing in both clients.
  Shared bounded selections/carets, Unicode navigation/deletion, typing, paste,
  copy/cut and grouped Undo; visible count, Escape and quiet selection recovery.
  Paste spreads N clipboard lines over N targets, with full-payload fallback.
  Rectangular selection and arbitrary mouse-added carets remain outside this increment.
- [x] Local transforms and a keyboard command palette in both clients: JSON
  format/minify, sort lines, remove duplicate lines and trim trailing whitespace.
  Selection/whole-tab scope, background execution and one Undo share the Rust core.
- [x] Extend local tools with Unicode uppercase/lowercase and URL component
  encoding/decoding. The nine-command palette keeps five rows visible, with
  search and keyboard navigation; Mac additionally scrolls with a mouse/trackpad.
- [x] Shared atomic batch edits as one undo transaction, first used by Replace All.
  Future transforms and multicursor commands can reuse this operation.
- [x] Large document mode with explicit budgets for parsing, rendering, and history.
  Shared policy starts at 512 KiB, with visible mode status in both clients.
  Wrapped Mac first-window layout uses 256 Ki-glyph chunks, rounded to composed
  characters; source bytes stay unchanged. Auto prepares full native context for
  distant navigation/paste and reuses it until another source revision. On forces
  chunking; Off keeps standard layout.
  Bidi paragraphs and oversized single clusters retain standard native layout.
  Mac offers Automatic / On / Off; TUI retains its bounded viewport renderer.
  Pointer-word selection declines lines above 64 KiB. Syntax, tools, search,
  counters and history retain their explicit shared limits; smaller selections
  remain usable in larger documents. Native first distant navigation, pathological
  Unicode, peak-memory and cross-platform qualification remain M6 work.

Exit: representative JSON, logs, code, and prose are pleasant to manipulate offline;
highlighting and commands do not block text input. Terminal styling and width
behavior are verified in supported terminals. Primary syntax set is tested, and
the broader imported-language count is reported honestly.

### M4 — macOS AI: connection settings, then trustworthy previews

AI UI and provider networking are macOS-only. Shared Rust retains document/history,
proposal validation and atomic apply; implementing AI in the TUI is outside MVP.

#### M4.1 — Connect OpenAI in Settings

- [x] Native Settings → AI, reachable through Cmd+, with masked key entry,
  replace/delete actions and Keychain storage. Keep keys out of ordinary settings,
  session recovery, logs and request/error diagnostics.
- [x] A compact searchable choice of supported Responses text models, with a useful
  default and saved model ID. Use current official model capabilities and account
  discovery where permitted; do not expose an unfiltered all-purpose model catalog.
- [x] Explicit model refresh and Test Connection actions through a small asynchronous
  native OpenAI adapter. A short synthetic Responses request verifies the chosen
  model; listing models alone is not an end-to-end inference test.
- [x] Distinguish authentication, model access, quota/rate limit and connectivity
  failures. Restricted model-list access must not be called an invalid key.
- [x] Explain that the model test is an API-billed request. Send no tab content,
  selection or clipboard text. No background checking or requests on launch.
- [x] Preserve a working saved configuration if replacement/testing fails; cancel
  or supersede stale checks after key/model edits. Test with isolated Keychain
  entries and provider fixtures; live smoke is explicitly invoked.

Exit: Art can save/replace/delete a key, refresh/choose a model, test that model
and reopen Settings with the model selection preserved. No editor transformation
is part of this increment. No real credentials are needed for automated tests.

#### M4.2 — Change selection with a reviewable diff

- [x] Use the configured OpenAI Responses adapter for explicit selection rewriting.
- [x] Send only the explicit selection and context needed for the requested action.
- [x] Native Mac proposal/accept/reject controls with visible diffs; shared atomic apply.
- [x] Bind every proposal to buffer identity + source revision; reject stale proposals.
- [x] Cancellation, timeout, rate limits, provider refusal, output-size limits.
- [x] Protected spans remain byte-identical; private buffers cannot invoke providers.
- [x] Provider fixtures for reliable tests; opt-in live smoke test without saved secrets.

Exit: a Mac rewrite can be reviewed before applying as one undo step.
Typing during generation is always responsive. Network errors or stale replies
cannot overwrite subsequent edits. Model-produced text is data and cannot execute.

### M5 — Flagship: demonstrate once, apply to the rest

Example capture, AI inference and preview UI are macOS-only. Recipe representation,
validation and deterministic replay belong to Rust and do not require a provider.

- [x] Explicitly capture before/after example; target the remaining lines or records.
  Start with an invoked workflow, not speculative AI calls on every manual edit.
- [x] Define the smallest useful recipe grammar: selected fields, prefix/suffix,
  delimiter changes, case transforms, and supported structured serialization.
- [x] Infer a recipe with structured output; validate locally against the example.
- [x] Show target preview and match/changed/skipped counts; preserve unsupported rows.
- [ ] Offer explicit choices for currently unsupported/ambiguous type conversions.
- [x] Limit recipe cost and output size; no arbitrary scripts, shell, or code evaluation.
- [x] Persist named recipes with a schema version; deterministic replay works offline.
- [ ] Save a rewrite instruction separately when a request intrinsically requires AI.
- [x] Make all generated changes reversible as one transaction.

M5.1 is implemented for explicit complete-line selections: first nonblank row is
the example, After is edited in a native window, and all selected rows (including
that example) are previewed locally. Input supports whole rows, literal delimiters,
top-level scalar JSON fields and key=value. Only Before/After goes to the provider.
M5.2 adds explicit named recipe saving from a validated preview and a searchable
Mac library (Option+Cmd+R) with rename/delete. Rules persist with library/recipe
versions; new selections replay locally without a provider/key, with preview and
one Undo. A replay may match one row; unmatched rows, including the first, are kept.
Only the rule and name persist, including its literal text; captures/examples do not.
Separately saved AI rewrite instructions remain a future increment.
Executor fixtures cover 11 supported demonstrations on unseen inputs; live model
inference quality and the task-completion benchmark below remain acceptance gates.

Exit: benchmark against manual workflows on realistic tasks: env → object, log
cleanup, extracting JSON fields, converting lists, and formatting links. At least
10 distinct supported examples and ambiguous/unsupported counterexamples. Run on
unseen inputs so a recipe cannot merely memorize the demonstration. Keep this
feature only if it wins on task completion and review effort.

### M6 — Polish and performance qualification

- [ ] Global Mac hotkey; focus/return behavior; native menus and accessibility labels.
- [ ] Local editing/Secret Drop parity audit; document shortcuts and Mac-only AI scope.
- [ ] macOS Apple Silicon primary; validate TUI on macOS and Linux x86_64.
- [ ] Measure the performance matrix below in release builds on named hardware.
- [ ] Profile the slow paths, trim resident memory, and enforce the useful budgets.
  Qualify first distant Mac navigation with chunked paragraph layout, contextual
  Unicode fallbacks and large-file peak memory; mode implementation is not a
  universal large-document latency or memory guarantee.
- [ ] Verify 0 idle network traffic and no idle polling/redraw loop when no Secret
  Drop is open. Active access allows a 1-second status/expiry check; measure its cost.
- [ ] Verify graceful startup/recovery when keychain, files, or terminal are unavailable.

Exit: no open text-loss, destructive-save, Unicode-corruption, secret-disclosure,
or broken-terminal blockers. An ordinary editor session requires no network access.

### M7 — Ship MVP

- [ ] CI: formatting/lint, Rust tests, bridge tests, macOS build, Linux TUI tests.
- [ ] macOS signed/notarized app, signed release metadata, reproducible versioning.
- [ ] CLI release archives, install/uninstall instructions, optional Homebrew tap.
- [ ] License choice, third-party licenses, privacy disclosure, API billing explanation.
- [ ] Export/recovery instructions; manual update path before any automatic updater.
- [ ] Clean-machine install + first-run + rollback/uninstall verification.
- [ ] Short demo of the flagship workflow and a known-limitations release note.

Exit: Art can install the release, use either interface, recover a scratch buffer,
connect his own key in the Mac GUI, run/review a transformation there, save a local
recipe, and replay it offline. TUI acceptance covers local editing and Secret Drop.
Signing credentials and publication destination are resolved here;
their absence does not block earlier local milestones.

## Provisional performance targets

These are hypotheses to test, not achieved numbers. Use named Apple Silicon hardware,
release builds, at least 30 repetitions, and report p50/p95, peak memory, file size,
highlighting state, warm/cold state, and the measurement method. For TUI, account
for the terminal emulator separately. Measure total process memory including AI
workers when active; do not hide memory in a resident daemon.

| Scenario | Initial target |
| --- | --- |
| Resident Mac window reveal → focused, editable view | p95 ≤ 50 ms |
| Cold launch → first editable blank buffer | Mac p95 ≤ 200 ms; TUI ≤ 100 ms |
| Key event → presented edit, ordinary buffer | p95 ≤ one 60 Hz frame on Mac |
| Idle empty session, AI inactive | Mac ≤ 40 MiB; TUI ≤ 15 MiB resident, to validate |
| Paste 1 MiB technical text | First editable view ≤ 100 ms; highlighting may follow |
| Open 10 MiB logs / minified JSON | Remain responsive; no unbounded parsing or wrapping |
| AI request in flight | Input remains responsive; cancellation prevents later apply |

Compare with the installed Sublime Text on the same machine and workloads, with
equivalent highlighting and no extra packages. "Faster and smaller than Sublime"
is a release claim only after this comparison; if these initial budgets are
unrealistic, record evidence and adjust architecture or targets explicitly.

## Risk-driven decisions

| Risk | Earliest evidence and response |
| --- | --- |
| AppKit and Rust keep too much duplicated text | M1/M3 RSS and typing measurements; consider a custom text storage/layout adapter before release |
| Unicode/IME differences break shared edits | M1 boundary tests, M2 composition and native keyboard checks |
| Examples underdetermine a transformation | M5 explicit scope, preview, ambiguity choices, bounded recipe language |
| Syntax breadth causes slow startup or bad regex cases | M3 lazy loading, worker budgets, unhighlighted fallback |
| Recovery makes private scratch unsafe | M2 explicit private buffer, no automatic secret detection guarantee |
| Feature parity makes the TUI awkward | M1/M4 prove shared operations with platform-native input conventions |
| Editor foundations absorb all effort | Finish each gate; defer semantic selection and speculative integrations |

## Delivery sequence

M0 → M1 → M2 recovery checkpoint → M2a Mac interface → remaining M2 → M3 → M4 → M5 → M6 → M7.

Deliver one small runnable increment at a time. From 2026-11-12, Art delegates
routine mechanics and bug fixes to autonomous verification and local commits;
do not block each such increment on a manual walkthrough. Reserve Art's hands-on
feedback for notable features, interaction design and the AI workflows.
The first requested feedback
increment adds in-memory scratch buffers while the M1 performance investigation
remains open. This does not close the M1 measurement gate or the M2 durability gate.
Commit each completed, verified increment locally. Recovery parity in both clients
was the final behavior step before M2a.

After M1, measure before expanding. After M3, use the offline editor daily. After
M4, evaluate rewrite UX with a small model before building inference. After M5,
keep only the action types that repeatedly save time. Shipping M7 is the MVP;
completing an earlier milestone must never be reported as a finished product.
