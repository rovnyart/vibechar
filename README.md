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
| [Development](docs/development.md) | Toolchain, commands, tests, and current limitations |
| [Verification](docs/verification.md) | Observed prototype behavior, measurements, and open gates |

## Current implementation

The repository starts with milestone M1: a shared Rust document engine, a terminal
editor, and a native macOS editing shell connected through a small C interface.
This is an architecture prototype, not the MVP. See the roadmap for status and
the development guide for runnable commands.
