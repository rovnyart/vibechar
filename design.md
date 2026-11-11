# Design direction

Vibechar is a small, sharp tool. The text is the interface's center of gravity.
Opening a blank scratch buffer must land on a focused cursor immediately.

## Immediate design priority

The current window and segmented-control tab row are engineering placeholders,
not an accepted product design. Art's first feedback explicitly rejected the visual
quality. The Mac design pass now comes directly after recovery feedback, before
more editing/AI features. Follow [Interface roadmap](docs/interface-roadmap.md).

## Mac

- Use AppKit text input, native menus/dialogs, system focus and accessibility behavior.
- A compact title area, generous text canvas, and quiet status at the bottom.
- Monospaced system font, 15 pt default; comfortable padding; system light/dark colors.
- One warm orange accent for actions, source/result distinctions, and active details.
- Keep large reading/editing surfaces opaque; translucent system chrome is optional.
- Avoid onboarding walls, permanent AI chat panels, decorative cards, and dashboards.
- Scratch buffers get useful generated labels, not mandatory naming dialogs.

## Terminal

- Same commands and document semantics, fitted to a cell grid.
- Quiet header and status/footer; content consumes nearly the whole screen.
- Never require a mouse. Respect terminal capabilities and resize events.
- Conventional insertion mode, arrows, Ctrl shortcuts; modal Vim behavior is not MVP.
- Render only the viewport, accounting for wide graphemes, tabs, and horizontal scroll.

## Editing and AI

- Standard editing remains immediate and works without a key or network.
- AI starts from a command or selection. No automatic calls while typing.
- Example workflow: edit an item → invoke "Do the rest" → choose target → preview.
- Preview keeps the original accessible; accept is a deliberate action and one undo.
- Local recipes show that they run locally; AI instructions show that they call a model.
- Never hide errors in a transient success-looking animation.
- Motion explains a state change; respect reduced motion. The editor remains usable
  if every animation is removed.

## First-run and private text

First launch is a blank buffer; later Mac launches restore the last local session.
Quitting preserves open tabs; explicitly closing a tab removes it from that session.
A quiet "Saved locally" state distinguishes recovery from exporting a file.
Key setup appears only when an AI action is invoked.
Private mode must have a persistent, unobtrusive label. Before private mode exists,
the prototype must make no claim that pasted tokens are protected from persistence.

## Quality checks before MVP

Verify empty, long-line, large-file, multilingual, light/dark, resized, error,
proposal, private, and recovery states. Check Russian, combining accents, emoji/ZWJ,
IME input, keyboard-only use, and VoiceOver on Mac. Verify terminal rendering in
Terminal.app and at least one additional commonly used terminal.
