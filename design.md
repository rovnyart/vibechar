# Design direction

Vibechar is a small, sharp tool. The text is the interface's center of gravity.
Opening a blank scratch buffer must land on a focused cursor immediately.

## Immediate design priority

Art selected **Pocket** as the Mac visual direction on 2026-11-11 and approved
**`V_`** as the brand mark. Pocket is the internal name of the design direction;
the product remains vibechar. See [Mac interface studies](docs/design-studies.md)
for the original comparison and tradeoffs.

The first native Pocket increment replaces the rejected segmented-control shell.
Art accepted the first working Pocket interface on 2026-11-12. Continue qualifying
the remaining states and polish in the [Interface roadmap](docs/interface-roadmap.md)
while progressing through the remaining M2 behavior work.

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
- File → Save As / Shift+Cmd+S chooses a new destination with the current filename
  and folder prefilled. Native replacement confirmation applies; only a successful
  write changes the tab's file association.
- Syntax starts in Auto. A quiet footer badge states the detected language; its
  tooltip explains the local signal. Click or Control+Cmd+L opens a compact search
  with at most seven suggestions, never an alphabetic wall. Return pins, Escape
  cancels, Auto resets. Preserve text, selection and Undo throughout.
- Syntax colors belong to Pocket: muted rose keywords, sage strings, ochre
  constants, teal keys and soft purple types. Keep separate light/dark palettes
  and reserve the warm orange chrome accent for actions and the `V_` mark.

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
- Wheel scrolling moves the viewport independently of the editing caret. Hide an
  offscreen caret and reveal it on keyboard editing/navigation. A left click places
  it at the nearest whole grapheme. Scrolling never flashes a recovery-save status;
  cursor-only checkpoint updates are quiet.
- F4 opens Save As for scratches or files. Existing destinations require a second
  Enter; Esc cancels. Editing the filename resets replacement confirmation.
- F2 opens the same local language search; arrows select, Return pins, Escape
  cancels. Auto is the default. Colors follow the dark Pocket palette unless
  `VIBECHAR_COLOR_SCHEME=light` is selected for a light terminal background.

## Editing and AI

- Standard editing remains immediate and works without a key or network.
- Undo/redo follows input runs, not individual keystrokes. Pause, navigation,
  selection, newlines, paste and save establish deliberate boundaries; typing,
  backspace and forward delete stay distinct. A pasted fragment is one step.
- AI starts from a command or selection. No automatic calls while typing.
- Example workflow: edit an item → invoke "Do the rest" → choose target → preview.
- Preview keeps the original accessible; accept is a deliberate action and one undo.
- Local recipes show that they run locally; AI instructions show that they call a model.
- Never hide errors in a transient success-looking animation.
- Motion explains a state change; respect reduced motion. The editor remains usable
  if every animation is removed.

## First-run and private text

First launch is a blank buffer; later launches restore the last ordinary local session.
Quitting preserves open tabs; explicitly closing a tab removes it from that session.
On Mac, closing the last tab by its × or Cmd+W closes the window and exits, instead
of creating another visible scratch. Discard checks still apply. The red window
button and Cmd+Q preserve ordinary tabs for the next launch.
A quiet "Saved locally" state distinguishes recovery from exporting a file.
Key setup appears only when an AI action is invoked.
Private scratches are created explicitly with Shift+Cmd+N on Mac or Ctrl+P in the
terminal. Use a generic title, a lock on Mac, and a persistent "not recovered" label.
The shared checkpoint excludes their text, paths, and selections before worker
serialization. Private mode cannot be applied to an existing ordinary buffer.
Nonempty private tabs require close/quit confirmation, including hidden tabs.
Cmd+S / Ctrl+S writes a file and turns the private tab into an ordinary file tab.
The save UI states that this enables local recovery and closes its agent access.
The filename replaces the generic title; the lock/private actions disappear.
Cancellation or failure keeps the tab private and its agent grant unchanged.
Later saves use the attached file. Ordinary recovery is local and unencrypted.

## Secret Drop

The fast path is one explicit clipboard action: Paste Secret for Agent creates
a private tab, opens temporary access, and copies a ready-to-send instruction.
Use Option+Cmd+V on Mac or F8 in the terminal; clipboard contents are never watched.
An existing private tab offers Give to Agent (Shift+Cmd+C / Ctrl+G or F7).

Keep the text canvas dominant. The private footer shows access state and use count,
with Copy Again and Stop beside it; ordinary tabs gain no extra chrome. Stop closes
the current tab on Mac; Agent also offers Close All. Terminal F9 closes all access
in that editor. All labels remain generic, and grant errors stay distinct from
ordinary recovery failures. Narrow Mac windows hide font details before actions.

The copied instruction contains a temporary local reference and helper invocation,
never the value. The actual command receives an environment variable. Editing,
closing, Stop, or quitting revokes access; 30 minutes without use expires it.
The Mac app additionally closes access on lock/sleep/session switch. Terminal
lock/sleep integration remains a qualification item. See the
[Secret Drop contract](docs/secret-drop.md) for the boundary and limitations.

## Quality checks before MVP

Verify empty, long-line, large-file, multilingual, light/dark, resized, error,
proposal, private, and recovery states. Check Russian, combining accents, emoji/ZWJ,
IME input, keyboard-only use, and VoiceOver on Mac. Verify terminal rendering in
Terminal.app and at least one additional commonly used terminal.
