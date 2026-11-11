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
| [Development](docs/development.md) | Toolchain, commands, tests, and current limitations |
| [Verification](docs/verification.md) | Observed prototype behavior, measurements, and open gates |

## Current implementation

The shared Rust engine drives both a terminal editor and a native macOS editing
shell. Both support multiple scratch buffers with independent text,
cursor/selection, undo history, file destinations, and unsaved-close protection.
Both clients save their own local sessions and restore ordinary tabs after restart. Their
session files are separate; live synchronization is not implemented. Highlighting
and AI are still ahead. The first native Pocket interface is implemented: compact
tabs with overflow, the `V_` mark, warm light/graphite dark appearances, text zoom,
and quiet session status. Art accepted the first Pocket increment.
Private scratches are now available in both clients: Shift+Cmd+N on Mac or Ctrl+P
in the terminal. They are excluded from recovery and have generic titles. Closing
or quitting with private text asks before discarding it; explicitly saving a copy
creates a normal file on disk. Private-mode hands-on feedback is the next checkpoint.
See the roadmap for status and the development guide for runnable commands.
