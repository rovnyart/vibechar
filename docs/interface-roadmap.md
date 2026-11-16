# Early interface design pass

Priority: immediately after the Mac session-recovery feedback checkpoint.
This is core product work, not a cosmetic task deferred until M6.

The first user feedback rejected the current visual quality. The tall grey tab
area and stock segmented control are disposable engineering scaffolding. Keeping
native text input does not require keeping this window composition.

## Visual direction

Art selected **Pocket** and the **`V_`** mark on 2026-11-11. Follow the accepted
[design direction](../design.md); [Mac interface studies](design-studies.md)
preserves the comparison. Art accepted the first native increment on 2026-11-12.
Remaining qualification and app-icon work stay open for later polish.

- [x] Produce two or three Mac window studies with the same realistic content.
- [x] Show an empty scratch, three tabs, and populated JSON/log/prose examples.
- [x] Art selects Pocket and the uppercase `V_` mark.
- [ ] Establish a distinctive vibechar identity: typography, palette, spacing, icon idea.
- [x] Implement the first Pocket increment; hands-on feedback is now the checkpoint.

Studies must show a lightweight text editor. The editing canvas dominates the
window; no dashboard, card grid, or permanent AI chat panel is required.

## Window and tabs

- [x] Compact title/tab composition, balanced traffic-light placement and margins.
- [x] Purpose-built tabs with clear active state, close affordance, and new-tab button.
- [x] Useful scratch labels from content, with stable fallbacks.
- [x] Legible long names, 10+ tabs, overflow, resize, and keyboard switching.
- [x] Modified-file indicator distinct from local session-save state.
- [x] Remove oversized grey bands and permanent instructional/debug text.
- [x] Keep native menus, focus behavior, and familiar Mac shortcuts.

## Canvas and typography

- [x] Deliberate font size, line height, text insets, selection color, and cursor.
- [ ] Check Russian/English prose, JSON, code, emoji, and long lines side by side.
- [x] Text zoom through View; display the current size quietly in the footer.
- [x] Quiet line/column indicators, visible in narrow/private layouts; visual wrap toggle.
- [x] Logical line-number gutter with warm active-line accent and quiet continuation
  dots; adaptive selection/text counters and a click-to-open numerical detail table.
- [x] Opaque text canvas; use native materials only where they improve chrome.
- [ ] Preserve native selection, IME, clipboard, and accessibility.

## Color and identity

- [x] Design and render light/dark appearances together; View can override the system.
- [x] Choose warm orange with warm light / graphite dark neutrals for Pocket.
- [x] Give syntax its own coordinated light/dark palette and a compact Auto badge.
- [x] Avoid generic all-grey controls, excessive borders, and decorative gradients.
- [ ] Refine the approved `V_` mark, vibechar wordmark, and app icon.

## Interaction and states

- [x] Empty state invites immediate typing with minimal useful hints.
- [x] Quiet local saving; persistent failures explain saving a copy with Cmd+S.
- [x] Clear tab create/switch/close feedback without moving the editing target.
- [x] Auto language detection with a short searchable override, keyboard selection,
  cancellation and focus restoration. Ordinary overrides survive restart.
- [ ] Designed hover/focus/pressed states and keyboard-only navigation.
- [ ] Any motion is short, interruptible, and respects reduced motion.
- [ ] Search, command palette, and future previews share this visual language.

## Acceptance

Review empty, one-tab, three-tab, many-tab, long-name, long-line, restored-session,
save-error, light/dark, and narrow-window states. Test keyboard use, VoiceOver,
Unicode/IME input, scrolling, and focus restoration. Check actual application
screenshots, not only mockups.

Art accepted the first working Pocket increment on 2026-11-12. This completes its
hands-on feedback checkpoint; the remaining unchecked qualification items are
still required before release. M6 rechecks the final interface and performance.
