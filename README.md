# vibechar

A tiny, native text workbench for macOS and the terminal.

Open it, paste something, shape it, take the result. Vibechar should feel immediate
before you connect an AI provider. The first AI feature helps turn an example edit
into a reusable text transformation, with a preview before anything changes.

## Product boundaries

- Plain text, individual files, and disposable or persistent scratch buffers.
- One editing engine and command model, with a native Mac UI and a terminal UI.
- Keyboard-first editing, broad syntax highlighting, and useful local transforms.
- Optional AI through your own OpenAI API key; explicit invocation and selected context.
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
ahead. The first native Pocket interface is implemented: compact
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
