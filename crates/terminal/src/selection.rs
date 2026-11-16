//! Terminal selection, pointer gestures and explicit clipboard actions.
use super::*;
use std::{
    ops::Range,
    time::{Duration, Instant},
};

#[derive(Default)]
pub(super) struct Pointer {
    last_click: Option<(Instant, u64, u16, u16)>,
    drag: Option<Drag>,
}
struct Drag {
    origin: Range<usize>,
    words: bool,
    column: u16,
    row: u16,
}

impl Editor {
    pub fn selection(&self) -> Range<usize> {
        let anchor = self.anchor.unwrap_or(self.cursor);
        anchor.min(self.cursor)..anchor.max(self.cursor)
    }
    pub fn selection_state(&self) -> (usize, usize) {
        (self.anchor.unwrap_or(self.cursor), self.cursor)
    }
    pub(super) fn restore_selection(&mut self) {
        let buffer = self.session.active();
        let range = buffer.selection.clone();
        let head = buffer.selection_head.unwrap_or(range.end);
        let anchor = if head == range.start {
            range.end
        } else {
            range.start
        };
        // Old checkpoints/native selections can land inside a composed grapheme.
        let snap = |position| {
            if position == 0 {
                0
            } else {
                self.document()
                    .next_grapheme(self.document().previous_grapheme(position))
            }
        };
        let cursor = snap(head);
        let anchor = (!range.is_empty()).then(|| snap(anchor));
        self.cursor = cursor;
        self.anchor = anchor;
        self.pointer = Pointer::default();
    }
    fn set_caret(&mut self, position: usize, extend: bool) {
        self.wrap_end = false;
        if extend {
            self.anchor.get_or_insert(self.cursor);
        } else {
            self.anchor = None;
        }
        self.cursor = position;
        self.reveal_cursor = true;
    }
    pub(super) fn navigate_selection(&mut self, key: KeyEvent) -> bool {
        let control = key.modifiers.contains(KeyModifiers::CONTROL);
        let extend = key.modifiers.contains(KeyModifiers::SHIFT);
        if key
            .modifiers
            .intersects(KeyModifiers::ALT | KeyModifiers::SUPER)
        {
            return false;
        }
        let range = self.selection();
        let target = match key.code {
            KeyCode::Left if !control => {
                if !extend && !range.is_empty() {
                    range.start
                } else {
                    self.document().previous_grapheme(self.cursor)
                }
            }
            KeyCode::Right if !control => {
                if !extend && !range.is_empty() {
                    range.end
                } else {
                    self.document().next_grapheme(self.cursor)
                }
            }
            KeyCode::Up | KeyCode::Down if !control => {
                let old = self.cursor;
                self.vertical(if key.code == KeyCode::Up { -1 } else { 1 });
                let target = self.cursor;
                self.cursor = old;
                target
            }
            KeyCode::Home => {
                if control {
                    0
                } else if self.wrap {
                    self.wrapped_edge(false)
                } else {
                    self.document()
                        .line_start(self.document().line_index(self.cursor))
                }
            }
            KeyCode::End => {
                if control {
                    self.document().len_chars()
                } else if self.wrap {
                    self.wrapped_edge(true)
                } else {
                    self.line_end()
                }
            }
            KeyCode::Esc => {
                self.anchor = None;
                return true;
            }
            _ => return false,
        };
        self.set_caret(target, extend);
        self.wrap_end = self.wrap && key.code == KeyCode::End && !control;
        true
    }
    pub(super) fn delete_selection(&mut self) -> bool {
        let range = self.selection();
        if range.is_empty() {
            return false;
        }
        if self
            .session
            .active_mut()
            .document
            .replace(range.clone(), "")
            .is_ok()
        {
            self.cursor = range.start;
            self.wrap_end = false;
            self.anchor = None;
            self.pointer = Pointer::default();
            self.reveal_cursor = true;
        }
        true
    }
    pub(super) fn copy_selection(&mut self, cut: bool) {
        if self.multi.active(self.document()) {
            match self.multi.copy_text(self.document()) {
                Ok(Some(text)) => match crate::clipboard::copy(&text) {
                    Ok(()) => {
                        if cut {
                            self.multi_edit("", EditKind::Isolated);
                        }
                        self.message = if cut {
                            "Selections cut"
                        } else {
                            "Selections copied"
                        }
                        .into();
                    }
                    Err(_) => self.message = "Clipboard unavailable · selections kept".into(),
                },
                Ok(None) => self.message = "Select text before copying".into(),
                Err(error) => self.message = error,
            }
            return;
        }
        let range = self.selection();
        if range.is_empty() {
            self.message = "Select text first · Shift+arrows or drag".into();
            return;
        }
        let Ok(text) = self.document().text_range(range) else {
            return;
        };
        match crate::clipboard::copy(&text) {
            Ok(()) => {
                if cut {
                    self.delete_selection();
                }
                self.message = if cut {
                    "Selection cut"
                } else {
                    "Selection copied"
                }
                .into();
            }
            Err(_) => self.message = "Clipboard unavailable · selection kept".into(),
        }
    }
    pub(super) fn paste_clipboard(&mut self) {
        match crate::clipboard::read_text() {
            Ok(text) => self.paste(&text),
            Err(_) => {
                self.message = "Clipboard unavailable or text exceeds 8 MiB · selection kept".into()
            }
        }
    }

    pub fn mouse(&mut self, event: MouseEvent) {
        if self.stats_open
            || self.tools.is_some()
            || self.save_prompt.is_some()
            || self.language_prompt.is_some()
        {
            return;
        }
        if self.line_numbers && self.gutter.contains((event.column, event.row).into()) {
            if event.kind == MouseEventKind::Down(MouseButton::Left) {
                self.pump_multi();
                if self.multi.has_queued_input() {
                    return;
                }
                if let Some(row) = self
                    .screen_rows(usize::from(self.viewport.height))
                    .get(usize::from(event.row - self.viewport.y))
                {
                    if let Some(find) = &mut self.find {
                        find.focused = false;
                        find.preview = None;
                    }
                    self.cancel_private_quit();
                    self.close_pending = false;
                    let start = self.document().line_start(row.line);
                    let end = if row.line + 1 < self.document().line_count() {
                        self.document().line_start(row.line + 1)
                    } else {
                        self.document().len_chars()
                    };
                    self.multi.clear();
                    self.pointer = Pointer::default();
                    self.anchor = Some(end);
                    self.cursor = start;
                    self.reveal_cursor = false;
                    self.wrap_end = false;
                    self.session.active_mut().document.break_undo_group();
                }
                return;
            }
            if matches!(
                event.kind,
                MouseEventKind::ScrollUp | MouseEventKind::ScrollDown
            ) {
                let mut event = event;
                event.column = self.viewport.x;
                self.mouse_at(event, Instant::now());
            }
            return;
        }
        if self.find_mouse(event) {
            return;
        }
        self.mouse_at(event, Instant::now());
    }
    fn mouse_at(&mut self, event: MouseEvent, now: Instant) {
        if self.save_prompt.is_some() || self.language_prompt.is_some() || self.viewport.is_empty()
        {
            return;
        }
        if event.kind == MouseEventKind::Up(MouseButton::Left) {
            if self.pointer.drag.is_some() {
                self.extend_drag(event.column, event.row);
            }
            self.pointer.drag = None;
            return;
        }
        if event.kind == MouseEventKind::Drag(MouseButton::Left) {
            if self.pointer.drag.is_some() {
                self.extend_drag(event.column, event.row);
            }
            return;
        }
        if !self.viewport.contains((event.column, event.row).into()) {
            return;
        }
        match event.kind {
            MouseEventKind::ScrollUp | MouseEventKind::ScrollDown => {
                self.cancel_private_quit();
                self.close_pending = false;
                self.pointer.last_click = None;
                if self.wrap {
                    self.scroll_wrapped(if event.kind == MouseEventKind::ScrollUp {
                        -3
                    } else {
                        3
                    });
                    return;
                }
                let max_top = self
                    .document()
                    .line_count()
                    .saturating_sub(usize::from(self.viewport.height));
                self.top = if event.kind == MouseEventKind::ScrollUp {
                    self.top.saturating_sub(3)
                } else {
                    self.top.saturating_add(3).min(max_top)
                };
                self.reveal_cursor = false;
            }
            MouseEventKind::Down(MouseButton::Left) => {
                self.wrap_end = false;
                self.pump_multi();
                if self.multi.has_queued_input() {
                    self.message = "Finishing matching · click again shortly".into();
                    return;
                }
                self.multi.clear();
                self.cancel_private_quit();
                self.close_pending = false;
                self.session.active_mut().document.break_undo_group();
                let extend = event.modifiers.contains(KeyModifiers::SHIFT);
                let double = !extend
                    && self.pointer.last_click.is_some_and(|(at, doc, x, y)| {
                        now.saturating_duration_since(at) <= Duration::from_millis(350)
                            && doc == self.document().id()
                            && x == event.column
                            && y == event.row
                    });
                let origin = if double {
                    let word = self.word_at(self.mouse_position(event.column, event.row, false));
                    self.anchor = Some(word.start);
                    self.cursor = word.end;
                    word
                } else {
                    self.set_caret(self.mouse_position(event.column, event.row, true), extend);
                    let anchor = self.anchor.unwrap_or(self.cursor);
                    anchor..anchor
                };
                self.pointer.last_click =
                    (!double).then_some((now, self.document().id(), event.column, event.row));
                self.pointer.drag = Some(Drag {
                    origin,
                    words: double,
                    column: event.column,
                    row: event.row,
                });
                self.reveal_cursor = true;
            }
            _ => {}
        }
    }
    fn mouse_position(&self, column: u16, row: u16, nearest: bool) -> usize {
        let row = row.clamp(self.viewport.y, self.viewport.bottom() - 1);
        let column = column.clamp(self.viewport.x, self.viewport.right() - 1);
        if self.wrap {
            let rows = self.screen_rows(usize::from(self.viewport.height));
            let Some(visual) = rows.get(usize::from(row - self.viewport.y)) else {
                return self.document().len_chars();
            };
            let start = self.document().line_start(visual.line) + visual.window.character;
            let end = start + visual.window.text.chars().count();
            return self
                .position_at_column(
                    visual.line,
                    visual.window.column + usize::from(column - self.viewport.x),
                    nearest,
                )
                .clamp(start, end);
        }
        let line = self.top + usize::from(row - self.viewport.y);
        if line >= self.document().line_count() {
            return self.document().len_chars();
        }
        self.position_at_column(
            line,
            self.left + usize::from(column - self.viewport.x),
            nearest,
        )
    }
    fn word_at(&mut self, position: usize) -> Range<usize> {
        self.document()
            .word_selection(position)
            .unwrap_or_else(|error| {
                self.message = error.into();
                position..position
            })
    }
    fn extend_drag(&mut self, column: u16, row: u16) {
        let drag = self.pointer.drag.as_mut().unwrap();
        drag.column = column;
        drag.row = row;
        let origin = drag.origin.clone();
        let words = drag.words;
        let position = self.mouse_position(column, row, !words);
        if words {
            let word = self.word_at(position);
            if word.end <= origin.start {
                self.anchor = Some(origin.end);
                self.cursor = word.start;
            } else {
                self.anchor = Some(origin.start);
                self.cursor = word.end.max(origin.end);
            }
        } else {
            self.anchor = Some(origin.start);
            self.cursor = position;
        }
        self.reveal_cursor = false;
    }
    pub fn drag_scrolling(&self) -> bool {
        !self.viewport.is_empty()
            && self
                .pointer
                .drag
                .as_ref()
                .is_some_and(|drag| !self.viewport.contains((drag.column, drag.row).into()))
    }
    pub fn tick_drag(&mut self) {
        if self.viewport.is_empty() {
            return;
        }
        let Some(drag) = &self.pointer.drag else {
            return;
        };
        let (column, row) = (drag.column, drag.row);
        if self.wrap {
            if row < self.viewport.y {
                self.scroll_wrapped(-1);
            }
            if row >= self.viewport.bottom() {
                self.scroll_wrapped(1);
            }
            self.extend_drag(column, row);
            return;
        }
        let max_top = self
            .document()
            .line_count()
            .saturating_sub(usize::from(self.viewport.height));
        if row < self.viewport.y {
            self.top = self.top.saturating_sub(1);
        }
        if row >= self.viewport.bottom() {
            self.top = self.top.saturating_add(1).min(max_top);
        }
        if column < self.viewport.x {
            self.left = self.left.saturating_sub(2);
        }
        if column >= self.viewport.right() {
            let line = (self.top
                + usize::from(
                    row.clamp(self.viewport.y, self.viewport.bottom() - 1) - self.viewport.y,
                ))
            .min(self.document().line_count() - 1);
            let max_left = self
                .document()
                .display_column(self.document().line_range(line).end)
                .saturating_sub(usize::from(self.viewport.width).saturating_sub(1));
            self.left = self.left.saturating_add(2).min(max_left);
        }
        self.extend_drag(column, row);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn press(editor: &mut Editor, code: KeyCode, modifiers: KeyModifiers) {
        editor.handle(KeyEvent::new(code, modifiers));
    }
    fn mouse(kind: MouseEventKind, column: u16, row: u16) -> MouseEvent {
        MouseEvent {
            kind,
            column,
            row,
            modifiers: KeyModifiers::NONE,
        }
    }

    #[test]
    fn shift_navigation_crosses_whole_graphemes_and_crlf_and_reverses_anchor() {
        let mut e = Editor::new("a👩‍💻e\u{301}\r\nsecond", None);
        press(&mut e, KeyCode::Right, KeyModifiers::NONE);
        for end in [4, 6, 8] {
            press(&mut e, KeyCode::Right, KeyModifiers::SHIFT);
            assert_eq!(e.selection(), 1..end);
        }
        press(&mut e, KeyCode::Left, KeyModifiers::SHIFT);
        assert_eq!(e.selection(), 1..6);
        press(
            &mut e,
            KeyCode::Home,
            KeyModifiers::CONTROL | KeyModifiers::SHIFT,
        );
        assert_eq!(e.selection_state(), (1, 0));
        press(&mut e, KeyCode::Right, KeyModifiers::NONE);
        assert_eq!(e.cursor, 1);
        assert!(e.selection().is_empty());
        press(&mut e, KeyCode::End, KeyModifiers::SHIFT);
        assert_eq!(e.selection(), 1..6);
        press(&mut e, KeyCode::Down, KeyModifiers::SHIFT);
        assert_eq!(e.selection().start, 1);
        assert!(e.cursor > 8);
        press(&mut e, KeyCode::Esc, KeyModifiers::NONE);
        assert!(e.selection().is_empty());
    }

    #[test]
    fn replacement_and_selected_deletion_are_isolated_undo_steps() {
        for deletion in [KeyCode::Backspace, KeyCode::Delete] {
            let mut e = Editor::new("hello world", None);
            e.cursor = 11;
            press(&mut e, KeyCode::Home, KeyModifiers::SHIFT);
            press(&mut e, deletion, KeyModifiers::NONE);
            assert_eq!(e.document().text(), "");
            press(&mut e, KeyCode::Char('z'), KeyModifiers::CONTROL);
            assert_eq!(e.document().text(), "hello world");
        }
        let mut e = Editor::new("hello 👩‍💻", None);
        press(&mut e, KeyCode::Char('a'), KeyModifiers::CONTROL);
        e.insert("Привет\r\n");
        e.handle(KeyEvent::new(KeyCode::Char('!'), KeyModifiers::NONE));
        press(&mut e, KeyCode::Char('z'), KeyModifiers::CONTROL);
        assert_eq!(e.document().text(), "Привет\r\n");
        press(&mut e, KeyCode::Char('z'), KeyModifiers::CONTROL);
        assert_eq!(e.document().text(), "hello 👩‍💻");
        press(&mut e, KeyCode::Char('y'), KeyModifiers::CONTROL);
        assert_eq!(e.document().text(), "Привет\r\n");
    }

    #[test]
    fn deletion_after_shrinking_selection_to_zero_does_not_leave_a_stale_anchor() {
        let mut e = Editor::new("ab", None);
        e.cursor = 2;
        press(&mut e, KeyCode::Left, KeyModifiers::SHIFT);
        press(&mut e, KeyCode::Right, KeyModifiers::SHIFT);
        press(&mut e, KeyCode::Backspace, KeyModifiers::NONE);
        assert_eq!(e.selection(), 1..1);
        e.insert("!");
        assert_eq!(e.document().text(), "a!");
    }

    #[test]
    fn backward_selection_keeps_its_head_when_switching_tabs() {
        let mut e = Editor::new("first", None);
        e.cursor = 5;
        press(&mut e, KeyCode::Home, KeyModifiers::SHIFT);
        press(&mut e, KeyCode::Char('n'), KeyModifiers::CONTROL);
        e.insert("second");
        press(&mut e, KeyCode::F(6), KeyModifiers::NONE);
        assert_eq!(e.selection_state(), (5, 0));
        press(&mut e, KeyCode::Right, KeyModifiers::SHIFT);
        assert_eq!(e.selection_state(), (5, 1));
    }

    #[test]
    fn pointer_drag_double_click_and_word_drag_keep_unicode_boundaries() {
        let mut e = Editor::new("привет foo_bar world", None);
        e.update_viewport(Rect::new(0, 1, 30, 5));
        let now = Instant::now();
        let down = mouse(MouseEventKind::Down(MouseButton::Left), 8, 1);
        e.mouse_at(down, now);
        e.mouse_at(mouse(MouseEventKind::Up(MouseButton::Left), 8, 1), now);
        e.mouse_at(down, now + Duration::from_millis(100));
        assert_eq!(e.selection(), 7..14);
        e.mouse(mouse(MouseEventKind::Drag(MouseButton::Left), 16, 1));
        assert_eq!(e.selection(), 7..20);
        e.mouse(mouse(MouseEventKind::Drag(MouseButton::Left), 2, 1));
        assert_eq!(e.selection_state(), (14, 0));
        e.mouse(mouse(MouseEventKind::Up(MouseButton::Left), 2, 1));
        assert!(!e.drag_scrolling());
        e.pointer = Pointer::default();
        e.anchor = None;
        e.cursor = 1;
        e.mouse(MouseEvent {
            modifiers: KeyModifiers::SHIFT,
            ..mouse(MouseEventKind::Down(MouseButton::Left), 5, 1)
        });
        assert_eq!(e.selection(), 1..5);
    }

    #[test]
    fn drag_outside_viewport_scrolls_until_release_and_does_not_mutate_text() {
        let source = "abcdef\n".repeat(40);
        let mut e = Editor::new(&source, None);
        e.update_viewport(Rect::new(0, 1, 10, 4));
        let revision = e.document().revision();
        e.mouse(mouse(MouseEventKind::Down(MouseButton::Left), 1, 1));
        e.mouse(mouse(MouseEventKind::Drag(MouseButton::Left), 3, 6));
        assert!(e.drag_scrolling());
        e.tick_drag();
        e.update_viewport(Rect::new(0, 1, 10, 4));
        assert_eq!(e.top, 1);
        assert_eq!(e.selection().start, 1);
        assert_eq!(e.cursor, e.document().line_start(4) + 3);
        e.mouse(mouse(MouseEventKind::Up(MouseButton::Left), 3, 6));
        assert!(!e.drag_scrolling());
        e.tick_drag();
        assert_eq!(e.top, 1);
        assert_eq!(e.document().revision(), revision);
        assert_eq!(e.document().text(), source);
    }
}
