//! Visual rows are projected lazily; text offsets and recovery stay logical.
use super::*;
pub struct ScreenRow {
    pub line: usize,
    pub window: vibechar_core::LineWindow,
    pub last: bool,
}

impl Editor {
    pub(super) fn editing(&mut self, action: vibechar_core::editing::Action) {
        if self.multi.active(self.document()) {
            match self
                .multi
                .editing(&mut self.session.active_mut().document, action)
            {
                Ok(_) => self.sync_multi(),
                Err(e) => self.message = e,
            }
            return;
        }
        let (anchor, head) = self.selection_state();
        match self
            .document()
            .editing_plan(&[vibechar_core::multi::Selection { anchor, head }], action)
        {
            Ok(plan) => {
                if self
                    .session
                    .active_mut()
                    .document
                    .replace_many(&plan.edits)
                    .is_ok()
                {
                    let s = &plan.selections[0];
                    self.cursor = s.head;
                    self.wrap_end = false;
                    self.anchor = (s.anchor != s.head).then_some(s.anchor);
                    self.close_pending = false;
                    self.reveal_cursor = true;
                }
            }
            Err(e) => self.message = e,
        }
    }
    pub(super) fn toggle_wrap(&mut self) {
        self.wrap_end = false;
        self.wrap = !self.wrap;
        self.wrap_top = 0;
        self.left = 0;
        self.reveal_cursor = true;
        self.message = format!(
            "Line wrap {} · F10 toggles",
            if self.wrap { "on" } else { "off" }
        );
    }
    fn width(&self) -> usize {
        usize::from(self.viewport.width).max(1)
    }
    fn caret_row(&self) -> (usize, usize) {
        let line = self.document().line_index(self.cursor);
        let position = if self.wrap_end && self.cursor > self.document().line_start(line) {
            self.document().previous_grapheme(self.cursor)
        } else {
            self.cursor
        };
        (
            self.document().line_index(self.cursor),
            self.document().wrapped_row_at(position, self.width()),
        )
    }
    pub(super) fn step_row(&self, mut at: (usize, usize), amount: isize) -> (usize, usize) {
        for _ in 0..amount.unsigned_abs() {
            if amount > 0 {
                if self
                    .document()
                    .wrapped_window(at.0, at.1 + 1, self.width())
                    .is_some()
                {
                    at.1 += 1;
                } else if at.0 + 1 < self.document().line_count() {
                    at = (at.0 + 1, 0);
                } else {
                    break;
                }
            } else if at.1 > 0 {
                at.1 -= 1;
            } else if at.0 > 0 {
                at.0 -= 1;
                at.1 = self
                    .document()
                    .wrapped_row_at(self.document().line_range(at.0).end, self.width());
            } else {
                break;
            }
        }
        at
    }
    pub(super) fn update_wrapped_viewport(&mut self, body: Rect) {
        if self.viewport != body {
            let old = self
                .document()
                .wrapped_window(self.top, self.wrap_top, self.width())
                .map_or(0, |w| w.character);
            if self.screen_cursor().is_some() {
                self.reveal_cursor = true;
            }
            self.viewport = body;
            self.wrap_end = false;
            self.wrap_top = self
                .document()
                .wrapped_row_at(self.document().line_start(self.top) + old, self.width());
        }
        self.viewport = body;
        self.left = 0;
        self.top = self.top.min(self.document().line_count() - 1);
        if self
            .document()
            .wrapped_window(self.top, self.wrap_top, self.width())
            .is_none()
        {
            self.wrap_top = self
                .document()
                .wrapped_row_at(self.document().line_range(self.top).end, self.width());
        }
        if !self.reveal_cursor || body.is_empty() {
            return;
        }
        let caret = self.caret_row();
        let top = (self.top, self.wrap_top);
        let bottom = self.step_row(top, body.height.saturating_sub(1) as isize);
        let at = if caret < top {
            caret
        } else if caret > bottom {
            self.step_row(caret, -(body.height.saturating_sub(1) as isize))
        } else {
            top
        };
        (self.top, self.wrap_top) = at;
        self.reveal_cursor = false;
    }
    pub fn screen_rows(&self, height: usize) -> Vec<ScreenRow> {
        let mut rows = Vec::new();
        let mut at = (self.top, self.wrap_top);
        for _ in 0..height {
            if at.0 >= self.document().line_count() {
                break;
            }
            let (window, last) = if self.wrap {
                let Some(w) = self.document().wrapped_window(at.0, at.1, self.width()) else {
                    break;
                };
                (
                    w,
                    self.document()
                        .wrapped_window(at.0, at.1 + 1, self.width())
                        .is_none(),
                )
            } else {
                (
                    self.document().line_window(at.0, self.left, self.width()),
                    true,
                )
            };
            rows.push(ScreenRow {
                line: at.0,
                window,
                last,
            });
            if !self.wrap {
                at.0 += 1;
            } else {
                let next = self.step_row(at, 1);
                if next == at {
                    break;
                }
                at = next;
            }
        }
        rows
    }
    pub fn screen_cursor(&self) -> Option<(usize, usize)> {
        let logical = self.document().line_index(self.cursor);
        let col = self.cursor_column();
        if !self.wrap {
            return (logical >= self.top
                && logical < self.top + usize::from(self.viewport.height)
                && col >= self.left
                && col < self.left + self.width())
            .then(|| (col - self.left, logical - self.top));
        }
        let target = self.caret_row();
        let mut at = (self.top, self.wrap_top);
        for y in 0..usize::from(self.viewport.height) {
            if at == target {
                let w = self.document().wrapped_window(at.0, at.1, self.width())?;
                return Some((col.saturating_sub(w.column).min(self.width() - 1), y));
            }
            let next = self.step_row(at, 1);
            if next == at {
                break;
            }
            at = next;
        }
        None
    }
    pub(super) fn scroll_wrapped(&mut self, amount: isize) {
        let mut top = self.step_row((self.top, self.wrap_top), amount);
        let mut bottom = top;
        let height = self.viewport.height.saturating_sub(1) as isize;
        for _ in 0..height {
            let next = self.step_row(bottom, 1);
            if next == bottom {
                top = self.step_row(bottom, -height);
                break;
            }
            bottom = next;
        }
        (self.top, self.wrap_top) = top;
        self.reveal_cursor = false;
    }
    pub(super) fn wrapped_edge(&self, end: bool) -> usize {
        let (line, row) = self.caret_row();
        let w = self
            .document()
            .wrapped_window(line, row, self.width())
            .unwrap();
        let start = self.document().line_start(line) + w.character;
        if !end {
            return start;
        }
        let limit = start + w.text.chars().count();
        limit
    }
    pub(super) fn vertical_wrapped(&mut self, direction: isize) {
        let at = self.caret_row();
        let target = self.step_row(at, direction);
        if at == target {
            return;
        }
        let old = self
            .document()
            .wrapped_window(at.0, at.1, self.width())
            .unwrap();
        let next = self
            .document()
            .wrapped_window(target.0, target.1, self.width())
            .unwrap();
        let col = self.cursor_column().saturating_sub(old.column);
        let start = self.document().line_start(target.0) + next.character;
        let end = start + next.text.chars().count();
        let mut position = self
            .position_at_column(target.0, next.column + col, false)
            .min(end);
        if position == end
            && end > start
            && self
                .document()
                .wrapped_window(target.0, target.1 + 1, self.width())
                .is_some()
        {
            position = self.document().previous_grapheme(end);
        }
        self.cursor = position;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn key(e: &mut Editor, code: KeyCode, flags: KeyModifiers) {
        e.handle(KeyEvent::new(code, flags));
    }
    fn draw(e: &mut Editor, width: u16, height: u16) {
        e.line_numbers = false;
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(width, height)).unwrap();
        terminal.draw(|f| crate::view::draw(f, e)).unwrap();
    }
    #[test]
    fn block_indent_newline_and_multicursor_use_shared_history() {
        let source = "  one\r\n\t二";
        let mut e = Editor::new(source, None);
        e.session.active_mut().document.mark_saved();
        key(&mut e, KeyCode::Char('a'), KeyModifiers::CONTROL);
        key(&mut e, KeyCode::Tab, KeyModifiers::NONE);
        assert_eq!(e.document().text(), "      one\r\n    \t二");
        key(&mut e, KeyCode::BackTab, KeyModifiers::SHIFT);
        assert_eq!(e.document().text(), source);
        key(&mut e, KeyCode::Char('z'), KeyModifiers::CONTROL);
        key(&mut e, KeyCode::Char('z'), KeyModifiers::CONTROL);
        assert_eq!(e.document().text(), source);
        assert!(!e.document().is_dirty());
        key(&mut e, KeyCode::Home, KeyModifiers::CONTROL);
        key(&mut e, KeyCode::End, KeyModifiers::NONE);
        key(&mut e, KeyCode::Enter, KeyModifiers::NONE);
        assert_eq!(e.document().text(), "  one\r\n  \r\n\t二");
        let mut e = Editor::new("  foo\r\n\tfoo", None);
        e.session.active_mut().document.mark_saved();
        e.multi
            .adopt(&e.session.active().document, &[2..5, 8..11], 0)
            .unwrap();
        e.sync_multi();
        key(&mut e, KeyCode::Enter, KeyModifiers::NONE);
        assert_eq!(e.document().text(), "  \r\n  \r\n\t\r\n\t");
        key(&mut e, KeyCode::Char('z'), KeyModifiers::CONTROL);
        assert_eq!(e.document().text(), "  foo\r\n\tfoo");
        assert!(!e.document().is_dirty());
    }
    #[test]
    fn wrapped_mouse_navigation_and_resize_keep_logical_offsets() {
        let source = "abc界d👩‍💻ef\tg\n  tail";
        let mut e = Editor::new(source, None);
        e.session.active_mut().document.mark_saved();
        let revision = e.document().revision();
        key(&mut e, KeyCode::F(10), KeyModifiers::NONE);
        draw(&mut e, 6, 8);
        assert_eq!(e.screen_rows(5)[0].window.text, "abc界d");
        key(&mut e, KeyCode::Down, KeyModifiers::SHIFT);
        draw(&mut e, 6, 8);
        assert_eq!(e.selection_state(), (0, 5));
        assert_eq!(e.cursor_column(), 6);
        e.mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 0,
            row: e.viewport.y + 1,
            modifiers: KeyModifiers::NONE,
        });
        e.mouse(MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Left),
            column: 0,
            row: e.viewport.y + 1,
            modifiers: KeyModifiers::NONE,
        });
        assert_eq!(e.cursor, 5);
        assert_eq!(e.screen_cursor(), Some((0, 1)));
        key(&mut e, KeyCode::End, KeyModifiers::NONE);
        assert_eq!(e.cursor, 11);
        assert_eq!(e.screen_cursor(), Some((5, 1)));
        key(&mut e, KeyCode::End, KeyModifiers::NONE);
        assert_eq!(e.cursor, 11);
        key(&mut e, KeyCode::Left, KeyModifiers::NONE);
        draw(&mut e, 6, 8);
        assert_eq!(e.screen_cursor(), Some((4, 1)));
        let state = e.selection_state();
        draw(&mut e, 9, 6);
        assert_eq!(e.selection_state(), state);
        assert!(e.screen_cursor().is_some());
        key(&mut e, KeyCode::F(10), KeyModifiers::NONE);
        draw(&mut e, 9, 6);
        assert_eq!(e.document().text(), source);
        assert_eq!(e.document().revision(), revision);
        assert!(!e.document().is_dirty());
    }
    #[test]
    fn wrapped_scroll_resize_and_drag_do_not_edit_or_recover_view_state() {
        let mut e = Editor::new(&"x".repeat(500), None);
        e.toggle_wrap();
        draw(&mut e, 10, 8);
        let mark = e.recovery_mark();
        e.mouse(MouseEvent {
            kind: MouseEventKind::ScrollDown,
            column: 1,
            row: e.viewport.y,
            modifiers: KeyModifiers::NONE,
        });
        draw(&mut e, 10, 8);
        assert_eq!(e.wrap_top, 3);
        assert!(e.screen_cursor().is_none());
        assert!(e.recovery_mark() == mark);
        draw(&mut e, 8, 8);
        assert!(e.screen_cursor().is_none());
        key(&mut e, KeyCode::Right, KeyModifiers::NONE);
        draw(&mut e, 8, 8);
        assert_eq!(e.screen_cursor(), Some((1, 0)));
        e.mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 0,
            row: e.viewport.y,
            modifiers: KeyModifiers::NONE,
        });
        e.mouse(MouseEvent {
            kind: MouseEventKind::Drag(MouseButton::Left),
            column: 3,
            row: e.viewport.bottom() + 2,
            modifiers: KeyModifiers::NONE,
        });
        let before = e.selection().end;
        e.tick_drag();
        assert!(e.selection().end > before);
        assert!(e.recovery_mark() == mark);
        for _ in 0..100 {
            e.scroll_wrapped(3);
        }
        assert_eq!(
            e.screen_rows(usize::from(e.viewport.height)).len(),
            usize::from(e.viewport.height)
        );
    }
}
