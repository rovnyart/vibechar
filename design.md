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
- Find opens below the tabs, leaving the canvas dominant. Cmd+F finds, Option+Cmd+F
  reveals replacement; Cmd+G / Shift+Cmd+G navigate. Show count, case and regex
  toggles without a settings dialog. Reflow controls at narrow widths. All… shows
  a small before/after preview and a deliberate Replace All action; one Undo restores
  the batch. Escape closes find and restores editing focus.
- Syntax starts in Auto. A quiet footer badge states the detected language; its
  tooltip explains the local signal. Click or Control+Cmd+L opens a compact search
  with at most seven suggestions, never an alphabetic wall. Return pins, Escape
  cancels, Auto resets. Preserve text, selection and Undo throughout.
- Cmd+K opens a small Pocket Text Tools popover with the orange `V_` signature,
  explicit Selection/Whole tab scope, one search field and five visible command rows.
  A native scrolling list reveals additional tools; arrows keep the current row in
  view and a quiet count hints at more commands. Filtering by `case` or `url` narrows
  the catalog immediately.
  Rows pair a clear action with a short semantic hint. Arrows/Enter or a click
  applies; Escape dismisses and returns focus to the text. Keep this transient,
  with no recent-query history, permanent sidebar or second confirmation step.
- Syntax colors belong to Pocket: muted rose keywords, sage strings, ochre
  constants, teal keys and soft purple types. Keep separate light/dark palettes
  and reserve the warm orange chrome accent for actions and the `V_` mark.
- Cmd+D selects a word/adds the next occurrence; Cmd+Shift+L selects all, including
  current Find results. Secondary selections use warm Pocket highlighting and
  secondary carets use slim orange strokes; the primary stays native. A quiet
  footer count states the mode and Escape exit. No extra permanent editing panel.

## Identity

- Use the exact uppercase mark **`V_`**: a simple monospaced V with a cursor-like
  underscore. Keep it small in the Mac chrome, with the underscore carrying the
  warm orange accent. Do not animate it continuously.
- The wordmark is **vibechar**. The mark is a compact signature, leaving the text
  canvas dominant. Refine its optical spacing and app-icon treatment within this
  identity rather than reopening the choice of direction.

Art selected **Graphite** for the Mac app icon on 2026-11-17: a graphite rounded
tile, warm ivory `V` and peach-orange underscore, with restrained physical depth.
The selected transparent master and generation provenance live in
`apps/macos/Artwork/`; packaging exports the native 1×/2× icon family through
1024 px, plus a native Icon Composer catalog for modern macOS. The native enclosure
retains the graphite fill and avoids a second system backplate. The app icon is a
solid tile with transparent outer margins, separate
from the smaller, quieter typographic mark used in the editor chrome.
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
- Shift-navigation and drag share one selection model; double click selects a
  word/segment. Use Pocket's warm selection background, including selected tabs
  and line-break markers. Cut changes text only after copying succeeds, typing
  replaces the selection, and replacement/deletion stays one undo step.
- F4 opens Save As for scratches or files. Existing destinations require a second
  Enter; Esc cancels. Editing the filename resets replacement confirmation.
- F2 opens the same local language search; arrows select, Return pins, Escape
  cancels. Auto is the default. Colors follow the dark Pocket palette unless
  `VIBECHAR_COLOR_SCHEME=light` is selected for a light terminal background.
- Ctrl+F / Ctrl+R opens compact find/replacement rows. Tab switches fields,
  F3 / Shift+F3 navigates, Alt+C/R toggles case/regex. F5 previews a batch; Enter
  applies and Escape goes back. Fields accept cursor editing and paste; query
  input never edits the document. Closing the panel clears its in-memory query.
- Ctrl+K opens the same Text Tools catalog in a compact centered panel. Show target,
  command descriptions and keyboard hints. Keep source selection untouched until
  application; a tool error stays in the panel, and one Undo reverses a change.
  Fit at most five rows (fewer in a short terminal), reveal the current choice while
  navigating and show the visible range/count when more tools are available.
- Ctrl+D / Ctrl+L share next/all occurrence semantics with Mac. Paint all ranges
  and secondary block carets, retaining the terminal cursor on the primary. Show
  a count and keyboard hints. Mouse clicks and Escape return to a single selection;
  wheel scrolling keeps the set and never flashes a recovery-save status.

## Editing and AI

- Standard editing remains immediate and works without a key or network.
- Undo/redo follows input runs, not individual keystrokes. Pause, navigation,
  selection, newlines, paste and save establish deliberate boundaries; typing,
  backspace and forward delete stay distinct. A pasted fragment is one step.
- AI is Mac GUI-only for MVP; TUI retains local editing and Secret Drop.
- AI starts from a Mac command or selection. No automatic calls while typing.
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
Mac Settings → AI (Cmd+,) is always reachable, without first-launch onboarding.
The first AI increment provides a masked Keychain key, model choice and an explicit
connection test using synthetic text. If a later AI action needs setup, it opens
this same settings surface. Test/model refresh does not read editor or clipboard
content; disclose that a selected-model test is API-billed.
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
