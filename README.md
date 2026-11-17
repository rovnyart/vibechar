# vibechar

A tiny, native text workbench for macOS and the terminal.

Open it, paste something, shape it, take the result. Vibechar should feel immediate
before you connect an AI provider. The first AI feature helps turn an example edit
into a reusable text transformation, with a preview before anything changes.

## Product boundaries

- Plain text, individual files, and disposable or persistent scratch buffers.
- One editing engine and command model, with a native Mac UI and a terminal UI.
- Keyboard-first editing, broad syntax highlighting, and useful local transforms.
- Optional Mac GUI-only AI through your own OpenAI API key; explicit invocation and
  selected context. TUI stays local with Secret Drop.
- Projects, folder workspaces, LSP servers, plugin marketplaces, and autonomous coding
  agents are outside the MVP.

## Documentation

| Document | What to read it for |
| --- | --- |
| [Roadmap](docs/roadmap.md) | MVP scope, milestones, dependencies, and acceptance gates |
| [Architecture](docs/architecture.md) | Shared engine, native adapters, data ownership, and AI boundaries |
| [Design](design.md) | Interaction and visual direction for both interfaces |
| [Interface roadmap](docs/interface-roadmap.md) | The early Mac design pass and visual acceptance gates |
| [Secret Drop](docs/secret-drop.md) | Private clipboard-to-agent workflow and local access contract |
| [Development](docs/development.md) | Toolchain, commands, tests, and current limitations |
| [Verification](docs/verification.md) | Observed prototype behavior, measurements, and open gates |

## Current implementation

The shared Rust engine drives both a terminal editor and a native macOS editing
shell. Both support multiple scratch buffers with independent text,
cursor/selection, undo history, file destinations, and unsaved-close protection.
Both clients save their own local sessions and restore ordinary tabs after restart. Their
session files are separate; live synchronization is not implemented. AI is still
ahead. The next AI increment is Mac Settings: Keychain key storage, connection
testing and model selection; rewriting/previews follow separately. The first
native Pocket interface is implemented: compact
tabs with overflow, the `V_` mark, warm light/graphite dark appearances, text zoom,
and quiet session status. Art accepted the first Pocket increment.
Private scratches are now available in both clients: Shift+Cmd+N on Mac or Ctrl+P
in the terminal. They are excluded from recovery and have generic titles. Closing
or quitting with private text asks before discarding it. Saving a private tab makes
it an ordinary file tab, includes it in recovery, and closes that tab's agent access.
Cancelled or failed saves keep the tab private.
See the roadmap for status and the development guide for runnable commands.

Typing and repeated deletion now undo as input runs in both clients. A pause,
navigation, paste, newline, save or changing tabs separates steps. Paste stays
one step, and undo across a file save restores its correct modification state.

Save As is available through File → Save As / Shift+Cmd+S on Mac and F4 in the
terminal, including for files already open. A successful save attaches the new
destination; cancellation/failure keeps the original. Existing destinations need
replacement confirmation. Art has tested Save As and the Mac Secret Drop Give/Stop
workflow. Routine mechanics are verified automatically; visible features remain
hands-on feedback checkpoints.

Smart syntax is available in both clients. Auto uses the filename and conservative
local content detection for common JSON, environment, SQL, Markdown and code pastes.
Ambiguous fragments stay Text. Click **Auto · JSON** in the Mac footer, or use
**Control+Cmd+L** / **F2** in the terminal, to search by language or extension and pin
an override. Auto resets the pin. The pinned catalog has **186 visible grammars**;
this is coverage, not a claim to infer every language from arbitrary fragments.
Parsing runs in a background worker; ordinary pins survive restart and private
ones are excluded from recovery. Large/minified input uses an explicit uncolored
fallback; see [syntax limits](docs/development.md#smart-syntax).

The terminal supports click-to-edit, Shift-navigation and drag selection, word
double click, edge autoscroll, Ctrl+A/C/X/V, and selection replacement/Undo.
Ordinary selections preserve their direction across tabs and restart. Wheel/
trackpad scrolling moves the viewport independently of the caret and does not
write recovery; selection/caret navigation checkpoints quietly without flashing
Saving locally in both clients.

Logical line numbers are enabled in both clients, with an active-line accent and
dots for wrapped continuations. Click a number to select its whole source line.
The footer counts text/selected graphemes, with words, lines, UTF-8 bytes and
selection/caret totals available by clicking the Mac counter or pressing TUI
**F11**. Toggle numbers with Mac **Option+Cmd+N** or TUI **F12**. Larger counts
run in the shared background engine; see the [counter semantics and limits](docs/development.md#line-numbers-and-counters).

Find/replace now shares a local Rust worker in both clients: literal or regex,
case matching, highlighted results and wraparound navigation. On Mac use **Cmd+F**
or **Option+Cmd+F** for replacement, then **All…** to preview a batch. In the TUI
use **Ctrl+F / Ctrl+R**, **Tab** between fields, **F3 / Shift+F3** for navigation and
**F5** for the batch preview; Enter confirms it and Escape cancels. Replace All is
one Undo, and stale previews cannot overwrite subsequent edits. Queries/previews
stay in memory, including for private tabs. See the [find limits](docs/development.md#find-and-replace).

**Cmd+K** on Mac / **Ctrl+K** in the terminal opens a small searchable Text Tools
palette: format/minify JSON, sort lines, remove duplicate lines, trim trailing
whitespace, Unicode uppercase/lowercase and URL encode/decode. The list stays compact:
scroll or use arrows, or type `case` / `url` to filter. The visible target is the
selection, or the whole tab when nothing is selected. Arrows choose, Enter applies,
Escape cancels; every change is one Undo.
Commands run locally on a Rust worker, including in private tabs. JSON retains
number precision, key order, duplicate keys and string escapes. See the
[tool semantics and limits](docs/development.md#local-text-tools).

Multiple selections work in both clients: **Cmd+D / Ctrl+D** selects the word at
the caret, then adds the next occurrence. **Cmd+Shift+L / Ctrl+L** selects all;
when Find is open it uses the current literal/regex results. Type, delete, paste
and move/extend all carets together; input runs share Undo. Pasting N lines into N
carets distributes one line to each, preventing duplicated copied selections.
Escape keeps a single primary selection. Selection changes checkpoint quietly. See the
[multicursor controls and limits](docs/development.md#multiple-selections).

Undo/Redo history has a shared per-document retention budget in both clients:
1,024 steps / 32 MiB of charged allocations, keeping the newest operation
undoable even when it alone exceeds the budget. Oldest steps expire as needed.

Large text mode activates from **512 KiB**. Mac bounds wrapped paragraph layout
and offers **View → Large Text Mode → Automatic / On / Off**; a lightning mark
appears beside the counter. TUI shows **Large text** and keeps its viewport-based
renderer. Text, real newlines and file bytes are unchanged. First distant Mac
navigation can be slower; see the [mode and operation limits](docs/development.md#large-text-mode).

Secret Drop is implemented in both clients. Copy a secret, then use **Agent →
Paste Secret for Agent** (Option+Cmd+V) on Mac or **F8** in the terminal. Vibechar
creates a private tab and replaces the clipboard with an instruction for your
local agent. Paste it into the chat. The included `vibechar run` helper passes
the value directly to a command's environment; the instruction contains only a
temporary reference. No API key, account, or MCP configuration is needed.

For an existing private tab, use **Give to Agent** / Shift+Cmd+C on Mac or
Ctrl+G / F7 in the terminal. Stop, edits, successful file save, tab close, and editor exit revoke future
access; 30 minutes without use expires it. Keep the originating editor open.
This first increment supports agents on the same computer and OS user account.
The command receives the real value; output masking covers literal matches,
not arbitrary transformations. See the [access contract](docs/secret-drop.md).
