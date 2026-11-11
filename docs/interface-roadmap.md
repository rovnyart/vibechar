# Early interface design pass

Priority: immediately after the Mac session-recovery feedback checkpoint.
This is core product work, not a cosmetic task deferred until M6.

The first user feedback rejected the current visual quality. The tall grey tab
area and stock segmented control are disposable engineering scaffolding. Keeping
native text input does not require keeping this window composition.

## Visual direction

- [ ] Produce two or three Mac window studies with the same realistic content.
- [ ] Show an empty scratch, three tabs, and populated JSON/log/prose examples.
- [ ] Establish a distinctive vibechar identity: typography, palette, spacing, icon idea.
- [ ] Art picks the direction; implement the selected direction in the next increment.

Studies must show a lightweight text editor. The editing canvas dominates the
window; no dashboard, card grid, or permanent AI chat panel is required.

## Window and tabs

- [ ] Compact title/tab composition, balanced traffic-light placement and margins.
- [ ] Purpose-built tabs with clear active state, close affordance, and new-tab button.
- [ ] Useful scratch labels from content, with stable fallbacks.
- [ ] Legible long names, 10+ tabs, overflow, resize, and keyboard switching.
- [ ] Modified-file indicator distinct from local session-save state.
- [ ] Remove oversized grey bands and permanent instructional/debug text.
- [ ] Keep native menus, focus behavior, and familiar Mac shortcuts.

## Canvas and typography

- [ ] Deliberate font size, line height, text insets, selection color, and cursor.
- [ ] Check Russian/English prose, JSON, code, emoji, and long lines side by side.
- [ ] Predictable font zoom; quiet line/column indicators.
- [ ] Opaque text canvas; use native materials only where they improve chrome.
- [ ] Preserve native selection, IME, clipboard, and accessibility.

## Color and identity

- [ ] Design light and dark appearances together with consistent contrast/hierarchy.
- [ ] Choose one confident accent and an intentional neutral palette.
- [ ] Avoid generic all-grey controls, excessive borders, and decorative gradients.
- [ ] Develop the app icon and wordmark after selecting the window direction.

## Interaction and states

- [ ] Empty state invites immediate typing with minimal useful hints.
- [ ] Quiet local saving; visible failures with a concrete recovery action.
- [ ] Clear tab create/switch/close feedback without moving the editing target.
- [ ] Designed hover/focus/pressed states and keyboard-only navigation.
- [ ] Any motion is short, interruptible, and respects reduced motion.
- [ ] Search, command palette, and future previews share this visual language.

## Acceptance

Review empty, one-tab, three-tab, many-tab, long-name, long-line, restored-session,
save-error, light/dark, and narrow-window states. Test keyboard use, VoiceOver,
Unicode/IME input, scrolling, and focus restoration. Check actual application
screenshots, not only mockups.

Deliver one coherent visual increment for Art to try. Art's acceptance of the
working interface is the exit gate. Native widgets compiling or one acceptable
screenshot does not satisfy it. The current engineering shell has not passed.
