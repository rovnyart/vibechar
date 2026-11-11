# Mac interface studies

Decision, 2026-11-11: Art selected **Pocket** and approved **`V_`** as the brand mark.
[Design direction](../design.md) records the accepted baseline. Paper and Signal
remain archived alternatives, not active implementation directions.

The first native Pocket increment is implemented and awaiting Art's hands-on
feedback. Acceptance of the direction is separate from acceptance of the working
interface.

## Product feeling

A small, precise text workbench that feels good to open several times a day.
The common loop is paste, inspect, change, copy, leave, and return. A scratch is
immediately useful without choosing a project, naming a document, or configuring AI.

Character should come from the proportions, tabs, typography, selection, and
editing behavior. The canvas remains the largest and quietest surface. Native
input, menus, window behavior, and accessibility are part of the design.

## Three directions

The chat contains interactive studies using the same JSON, Russian message draft,
and worker log. Each study also includes an empty scratch and a canned change
preview. These illustrate interactions; they are not running editor/AI features.

### Pocket

Compact traffic lights and document tabs share one top row. A warm neutral canvas,
restrained orange accent, monospaced text, and small `V_` signature give it the feel
of a pocket instrument. Status stays quiet at the bottom. A content-specific
operation opens a change preview in the editing surface.

Selected by Art: it best fits the mixed daily use of structured text, logs, and
short drafts while keeping familiar Mac navigation. The comparison sketch used
a lowercase signature; the approved mark is the uppercase **`V_`**.

Risk: without careful proportions and interaction work it could remain a plain
editor with a different accent. The actual application must establish the quality.

### Paper — archived alternative

A separate title line and thin underlined document tabs frame a centered reading
measure. Blue proofing details and editorial typography make prose feel deliberate.
The study explores a serif treatment for prose while keeping code monospaced.

Risk: it may imply a writing app rather than a general text workbench. Font/layout
changes must be explicit choices; pasting text must not unexpectedly move the
editing target or switch its typography.

### Signal — archived alternative

A compact instrument header, green/graphite palette, monospaced chrome, and a bottom
row of numbered buffer keys give it the strongest visual personality. Those keys
switch scratch buffers; they do not introduce project navigation.

Risk: bottom tabs change a familiar habit, and instrument styling could become
distracting during long editing sessions. Test the interaction before adopting it.

## Interaction principles to carry into implementation

- Opening a scratch focuses the cursor immediately; decoration never delays input.
- Tab labels come from useful content, with explicit new/close affordances and
  stable selection. Many tabs need a designed overflow behavior.
- Local session saving stays quiet; a failed save remains visible with a recovery
  action. Modified file state is separate from session recovery.
- Local operations and AI operations identify how they run. No background model
  calls while typing. The original remains accessible during a proposal.
- Applying a proposal is deliberate and produces one undo step. A future
  example-driven transformation uses the same preview language.
- Hover, pressed, focus, inactive-window, and restored states deserve the same
  attention as the main screenshot.
- Light/dark appearances, arbitrary window sizes, keyboard use, reduced motion,
  increased contrast, and native text input are designed together.

## Next checkpoint

The first Pocket increment covers window composition, tabs, typography, palette,
the `V_` mark, and quiet status. Stop for Art's hands-on feedback before continuing.
The study's transformations remain future work.

Judge the result in the real app with empty, JSON, log, Russian/English prose,
many-tab, long-name, narrow-window, and light/dark states. A study or successful
build does not constitute acceptance of the interface.

## Craft references

- [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass):
  functional navigation/control layer, restrained effects, native adaptation, and
  support for accessibility settings and arbitrary window sizes.
- [Panic Nova](https://nova.app/): a native Mac editor with deliberate craft and
  personality. Its IDE scope is outside vibechar's intended scope.
- [iA Writer focus mode](https://ia.net/writer/support/editor/focus-mode): a useful
  example of text-focused behavior, including the documented tradeoff between
  cursor centering and selecting/editing text. Automatic typewriter scrolling
  is not a default for vibechar's paste/edit/copy workflow.
