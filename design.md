# Design direction

Vibechar is a small, sharp tool. The text is the interface's center of gravity.
Opening a blank scratch buffer must land on a focused cursor immediately.

## Immediate design priority

Art selected **Pocket** as the Mac visual direction on 2026-11-11 and approved
**`V_`** as the brand mark. Pocket is the internal name of the design direction;
the product remains vibechar. See [Mac interface studies](docs/design-studies.md)
for the original comparison and tradeoffs.

The first native Pocket increment replaces the rejected segmented-control shell.
Art's hands-on acceptance of the working interface is pending. Continue the early
design pass before more editing/AI features; follow the
[Interface roadmap](docs/interface-roadmap.md).

## Mac

- Follow Pocket: a small, precise pocket instrument for text, with restrained
  character in its proportions, typography, tabs, and interaction feedback.
- Use AppKit text input, native menus/dialogs, system focus and accessibility behavior.
- Traffic lights and compact document tabs share the top row, with explicit close
  and new-tab controls. Keep a generous text canvas and quiet status at the bottom.
- Monospaced system font, 15 pt default; comfortable padding; system light/dark colors.
- Warm light neutrals and graphite dark neutrals, with one restrained warm orange
  accent for actions, active details, and the brand mark. Maintain readable contrast.
- Keep large reading/editing surfaces opaque; translucent system chrome is optional.
- Avoid onboarding walls, permanent AI chat panels, decorative cards, and dashboards.
- Scratch buffers get useful generated labels, not mandatory naming dialogs.

## Identity

- Use the exact uppercase mark **`V_`**: a simple monospaced V with a cursor-like
  underscore. Keep it small in the Mac chrome, with the underscore carrying the
  warm orange accent. Do not animate it continuously.
- The wordmark is **vibechar**. The mark is a compact signature, leaving the text
  canvas dominant. Refine its optical spacing and app-icon treatment within this
  identity rather than reopening the choice of direction.
- The approved study establishes the visual direction. Exact metrics, native
  materials, contrast, and overflow behavior still need qualification in the app.

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
