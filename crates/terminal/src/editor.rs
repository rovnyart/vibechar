use std::path::PathBuf;

use crossterm::event::{
    KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use ratatui::layout::Rect;
use unicode_segmentation::UnicodeSegmentation;
pub use vibechar_core::cell_width;
use vibechar_core::{session::Session, Document, EditKind};

use crate::files;

#[path = "find.rs"]
pub(crate) mod find;
#[path = "multi.rs"]
mod multi;
#[path = "selection.rs"]
mod selection;
#[path = "tools.rs"]
pub(crate) mod tools;
#[path = "wrapping.rs"]
mod wrapping;

pub struct Editor {
    pub session: Session,
    pub cursor: usize,
    anchor: Option<usize>,
    pointer: selection::Pointer,
    pub top: usize,
    pub left: usize,
    pub wrap: bool,
    pub line_numbers: bool,
    pub stats_open: bool,
    pub gutter: Rect,
    pub metrics: vibechar_core::metrics::Engine,
    wrap_top: usize,
    wrap_end: bool,
    pub message: String,
    pub recovery_status: &'static str,
    pub save_prompt: Option<String>,
    pub language_prompt: Option<String>,
    pub syntax: Option<std::sync::Arc<vibechar_core::syntax::Frame>>,
    pub light_syntax: bool,
    pub find: Option<find::Find>,
    pub tools: Option<tools::Palette>,
    pub multi: vibechar_core::multi::Multi,
    viewport: Rect,
    reveal_cursor: bool,
    language_choice: usize,
    overwrite_pending: Option<PathBuf>,
    close_pending: bool,
    private_quit_pending: bool,
}

impl Editor {
    pub fn new(text: &str, path: Option<PathBuf>) -> Self {
        Self::from_session(Session::new(text, path))
    }

    pub fn from_session(session: Session) -> Self {
        let cursor = session.active().selection.start;
        let mut editor = Self {
            session,
            cursor,
            anchor: None,
            pointer: selection::Pointer::default(),
            top: 0,
            left: 0,
            wrap: false,
            line_numbers: !std::env::var("VIBECHAR_LINE_NUMBERS").is_ok_and(|v| v == "0"),
            stats_open: false,
            gutter: Rect::default(),
            metrics: Default::default(),
            wrap_top: 0,
            wrap_end: false,
            message: String::new(),
            recovery_status: "Saving locally…",
            save_prompt: None,
            language_prompt: None,
            syntax: None,
            light_syntax: std::env::var("VIBECHAR_COLOR_SCHEME").is_ok_and(|s| s == "light"),
            find: None,
            tools: None,
            multi: vibechar_core::multi::Multi::default(),
            viewport: Rect::default(),
            reveal_cursor: true,
            language_choice: 0,
            overwrite_pending: None,
            close_pending: false,
            private_quit_pending: false,
        };
        editor.restore_selection();
        editor
    }

    pub fn insert(&mut self, text: &str) {
        self.session.active_mut().document.break_undo_group();
        self.insert_with_kind(text, EditKind::Isolated, false);
    }
    pub fn paste(&mut self, text: &str) {
        self.stats_open = false;
        self.session.active_mut().document.break_undo_group();
        self.insert_with_kind(text, EditKind::Isolated, true);
    }

    fn insert_with_kind(&mut self, text: &str, kind: EditKind, paste: bool) {
        self.cancel_private_quit();
        if self.tools_insert(text) {
            return;
        }
        if self.find_insert(text) {
            return;
        }
        if let Some(prompt) = &mut self.language_prompt {
            if !text.contains(['\n', '\r', '\0']) && prompt.len() + text.len() <= 128 {
                prompt.push_str(text);
                self.language_choice = 0;
            }
            return;
        }
        if let Some(prompt) = &mut self.save_prompt {
            if !text.contains(['\n', '\r', '\0']) {
                self.overwrite_pending = None;
                prompt.push_str(text);
            }
            return;
        }
        if text.is_empty() {
            return;
        }
        if self.multi.active(self.document()) {
            if paste {
                self.multi_paste(text)
            } else {
                self.multi_edit(text, kind)
            };
            return;
        }
        let range = self.selection();
        let start = range.start;
        let kind = if range.is_empty() {
            kind
        } else {
            EditKind::Isolated
        };
        if self
            .session
            .active_mut()
            .document
            .edit(range, text, kind)
            .is_ok()
        {
            self.cursor = start + text.chars().count();
            self.wrap_end = false;
            self.anchor = None;
            self.pointer = selection::Pointer::default();
            self.reveal_cursor = true;
        }
        self.close_pending = false;
    }

    pub fn document(&self) -> &Document {
        &self.session.active().document
    }

    pub fn handle(&mut self, key: KeyEvent) -> bool {
        if key.kind == KeyEventKind::Release {
            return false;
        }
        if self.stats_open {
            self.stats_open = false;
            if matches!(key.code, KeyCode::Esc | KeyCode::F(11)) {
                return false;
            }
        }
        let direct_edit = matches!(
            key.code,
            KeyCode::Char(_) | KeyCode::Backspace | KeyCode::Delete
        ) && !key
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER);
        if !direct_edit {
            self.session.active_mut().document.break_undo_group();
        }
        let quitting =
            key.code == KeyCode::Char('q') && key.modifiers.contains(KeyModifiers::CONTROL);
        if !quitting {
            self.cancel_private_quit();
        }
        self.pump_multi();
        if self.multi.has_queued_input()
            && (key.modifiers.contains(KeyModifiers::CONTROL)
                && matches!(
                    key.code,
                    KeyCode::Char(
                        'q' | 'n' | 'p' | 'w' | 's' | 'z' | 'y' | 'f' | 'r' | 'k' | 'g' | 'a'
                    )
                )
                || matches!(key.code, KeyCode::F(2 | 4 | 6 | 7 | 8)))
        {
            self.message = "Finishing matching · try that command again shortly".into();
            return false;
        }
        if self.handle_tools_key(key) {
            return false;
        }
        if self.save_prompt.is_none() && self.language_prompt.is_none() {
            match key.code {
                KeyCode::F(11) => {
                    self.close_pending = false;
                    self.pointer = selection::Pointer::default();
                    self.stats_open = true;
                    return false;
                }
                KeyCode::F(12) => {
                    self.close_pending = false;
                    self.pointer = selection::Pointer::default();
                    self.line_numbers = !self.line_numbers;
                    self.reveal_cursor = true;
                    return false;
                }
                _ => {}
            }
        }
        if self.handle_find_key(key) {
            return false;
        }
        if (key.code == KeyCode::Char('v') && key.modifiers.contains(KeyModifiers::CONTROL))
            || (key.code == KeyCode::Insert && key.modifiers.contains(KeyModifiers::SHIFT))
        {
            self.paste_clipboard();
            return false;
        }
        if self.language_prompt.is_some() {
            self.language_key(key);
            return false;
        }
        if self.save_prompt.is_some() {
            self.prompt_key(key);
            return false;
        }
        if self.handle_multi_key(key) {
            return false;
        }
        self.reveal_cursor = true;
        self.pointer = selection::Pointer::default();
        if self.navigate_selection(key) {
            self.close_pending = false;
            return false;
        }
        if key.code == KeyCode::Insert && key.modifiers.contains(KeyModifiers::CONTROL) {
            self.copy_selection(false);
            return false;
        }
        if key.code == KeyCode::Delete && key.modifiers.contains(KeyModifiers::SHIFT) {
            self.copy_selection(true);
            return false;
        }
        if key.modifiers.contains(KeyModifiers::CONTROL) {
            return self.control(key.code);
        }
        self.close_pending = false;
        match key.code {
            KeyCode::Char(ch)
                if !key
                    .modifiers
                    .intersects(KeyModifiers::ALT | KeyModifiers::SUPER) =>
            {
                self.insert_with_kind(&ch.to_string(), EditKind::Typing, false)
            }
            KeyCode::Enter => self.editing(vibechar_core::editing::Action::Newline),
            KeyCode::F(4) => self.save_as(),
            KeyCode::F(2) => {
                self.multi.clear();
                self.language_prompt = Some(String::new());
                self.language_choice = 0;
                self.message.clear();
            }
            KeyCode::F(6) => self.switch_buffer(if key.modifiers.contains(KeyModifiers::SHIFT) {
                -1
            } else {
                1
            }),
            KeyCode::F(7) => self.give_to_agent(),
            KeyCode::F(8) => self.paste_for_agent(),
            KeyCode::F(9) => {
                self.session.revoke_all_drops();
                self.message = "All agent access closed in this editor.".into();
            }
            KeyCode::Tab if key.modifiers.contains(KeyModifiers::SHIFT) => {
                self.editing(vibechar_core::editing::Action::Outdent)
            }
            KeyCode::Tab => self.editing(vibechar_core::editing::Action::Tab),
            KeyCode::BackTab => self.editing(vibechar_core::editing::Action::Outdent),
            KeyCode::F(10) => self.toggle_wrap(),
            KeyCode::Backspace => {
                self.wrap_end = false;
                if self.delete_selection() {
                    return false;
                }
                self.anchor = None;
                let start = self.document().previous_grapheme(self.cursor);
                if self
                    .session
                    .active_mut()
                    .document
                    .edit(start..self.cursor, "", EditKind::Backspace)
                    .is_ok()
                {
                    self.cursor = start;
                }
            }
            KeyCode::Delete => {
                self.wrap_end = false;
                if self.delete_selection() {
                    return false;
                }
                self.anchor = None;
                let end = self.document().next_grapheme(self.cursor);
                let _ = self.session.active_mut().document.edit(
                    self.cursor..end,
                    "",
                    EditKind::DeleteForward,
                );
            }
            _ => {}
        }
        false
    }

    pub fn update_viewport(&mut self, body: Rect) {
        if self.wrap {
            self.update_wrapped_viewport(body);
            return;
        }
        if body != self.viewport {
            let line = self.document().line_index(self.cursor);
            let column = self.cursor_column();
            if line >= self.top
                && line < self.top + usize::from(self.viewport.height)
                && column >= self.left
                && column < self.left + usize::from(self.viewport.width)
            {
                self.reveal_cursor = true;
            }
        }
        self.viewport = body;
        let height = usize::from(body.height).max(1);
        self.top = self
            .top
            .min(self.document().line_count().saturating_sub(height));
        if !self.reveal_cursor || body.is_empty() {
            return;
        }
        let line = self.document().line_index(self.cursor);
        let column = self.cursor_column();
        self.top = self.top.min(line);
        if line >= self.top + height {
            self.top = line + 1 - height;
        }
        self.left = self.left.min(column);
        let width = usize::from(body.width);
        if column >= self.left + width {
            self.left = column + 1 - width;
        }
        self.reveal_cursor = false;
    }

    // Only persisted metadata participates; viewport movement and prompts do not.
    pub fn recovery_mark(&self) -> RecoveryMark {
        let buffer = self.session.active();
        RecoveryMark {
            document: self.document().id(),
            revision: self.document().revision(),
            count: self.session.buffers().len(),
            dirty: self.document().is_dirty(),
            private: buffer.is_private(),
            path: buffer.path.clone(),
            language: self.session.language().map(str::to_owned),
        }
    }

    fn control(&mut self, code: KeyCode) -> bool {
        if code == KeyCode::Char('q') {
            self.close_pending = false;
            if self.session.has_private_text() && !self.private_quit_pending {
                self.message =
                    "Private tabs will be lost. Ctrl+Q again to discard · any other key cancels"
                        .into();
                self.private_quit_pending = true;
                return false;
            }
            return true;
        }
        if code == KeyCode::Char('w') {
            if self.session.active().needs_close_confirmation() && !self.close_pending {
                self.message = if self.session.active().is_private() {
                    "Private text is not recovered. Ctrl+W again to discard · Ctrl+S saves a file"
                } else {
                    "Unsaved text. Ctrl+S to save · Ctrl+W again to discard this buffer"
                }
                .into();
                self.close_pending = true;
                return false;
            }
            self.session.close_active(self.close_pending);
            self.restore_cursor();
            self.close_pending = false;
            return false;
        }
        self.close_pending = false;
        match code {
            KeyCode::Char('a') => {
                self.wrap_end = false;
                self.multi.clear();
                self.anchor = Some(0);
                self.cursor = self.document().len_chars();
            }
            KeyCode::Char('c') => self.copy_selection(false),
            KeyCode::Char('x') => self.copy_selection(true),
            KeyCode::Char('s') => self.save(),
            KeyCode::Char('g') => self.give_to_agent(),
            KeyCode::Char('n') => {
                self.open("", None);
            }
            KeyCode::Char('p') => {
                self.remember_cursor();
                self.session.open_private();
                self.restore_cursor();
            }
            KeyCode::PageDown => self.switch_buffer(1),
            KeyCode::PageUp => self.switch_buffer(-1),
            KeyCode::Char('z') => {
                self.multi.clear();
                if let Some(cursor) = self.session.active_mut().document.undo() {
                    self.wrap_end = false;
                    self.cursor = cursor;
                    self.anchor = None;
                }
            }
            KeyCode::Char('y') => {
                self.multi.clear();
                if let Some(cursor) = self.session.active_mut().document.redo() {
                    self.wrap_end = false;
                    self.cursor = cursor;
                    self.anchor = None;
                }
            }
            _ => {}
        }
        false
    }

    fn cancel_private_quit(&mut self) {
        if self.private_quit_pending {
            self.private_quit_pending = false;
            self.message.clear();
        }
    }

    pub fn pump_syntax(&mut self) {
        let serial = self.syntax.as_ref().map_or(0, |frame| frame.serial);
        if let Some(frame) = self.session.syntax_frame(serial) {
            self.syntax = Some(frame);
        }
    }
    pub fn language_options(&self) -> Vec<vibechar_core::syntax::Choice> {
        vibechar_core::syntax::choices(self.language_prompt.as_deref().unwrap_or(""))
    }
    pub fn selected_language(&self) -> usize {
        self.language_choice
    }
    fn language_key(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Esc => self.language_prompt = None,
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.language_prompt = None
            }
            KeyCode::Enter => {
                if let Some(choice) = self.language_options().get(self.language_choice) {
                    if self.session.set_language(&choice.id) {
                        self.syntax = None;
                        self.session.submit_syntax();
                        self.message = if choice.id.is_empty() {
                            "Language: Automatic".into()
                        } else {
                            format!("Language pinned: {} · F2 → Auto resets", choice.name)
                        };
                        self.language_prompt = None;
                    }
                }
            }
            KeyCode::Down => {
                let count = self.language_options().len();
                if count > 0 {
                    self.language_choice = (self.language_choice + 1) % count;
                }
            }
            KeyCode::Up => {
                let count = self.language_options().len();
                if count > 0 {
                    self.language_choice = (self.language_choice + count - 1) % count;
                }
            }
            KeyCode::Backspace => {
                if let Some(query) = &mut self.language_prompt {
                    query.pop();
                    self.language_choice = 0;
                }
            }
            KeyCode::Char(ch)
                if !key.modifiers.intersects(
                    KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER,
                ) =>
            {
                if let Some(query) = &mut self.language_prompt {
                    if query.len() + ch.len_utf8() <= 128 {
                        query.push(ch);
                        self.language_choice = 0;
                    }
                }
            }
            _ => {}
        }
    }

    fn give_to_agent(&mut self) {
        let result = (|| {
            self.session.share_active()?;
            let executable = std::env::current_exe()?;
            let instruction = self
                .session
                .drop_instruction(&executable.to_string_lossy())
                .unwrap();
            crate::clipboard::copy(&instruction)
        })();
        self.message = match result {
            Ok(()) => {
                "Instructions copied. Paste into your local agent chat. F9 closes access.".into()
            }
            Err(error) => {
                self.session.active_mut().document.revoke_drop();
                format!("Could not prepare Secret Drop: {error}")
            }
        };
    }
    fn paste_for_agent(&mut self) {
        let text = match crate::clipboard::read().and_then(|text| {
            vibechar_core::handoff::validate_secret(&text)?;
            if text.starts_with("Use this local Vibechar Secret Drop") {
                return Err(std::io::Error::other(
                    "Clipboard already contains instructions. Copy a new secret or use Ctrl+G.",
                ));
            }
            Ok(text)
        }) {
            Ok(text) => text,
            Err(error) => {
                self.message = error.to_string();
                return;
            }
        };
        self.remember_cursor();
        self.session.open_private();
        self.restore_cursor();
        self.insert(&text);
        self.give_to_agent();
    }

    fn line_end(&self) -> usize {
        let line = self.document().line_index(self.cursor);
        self.document().line_range(line).end
    }

    pub fn cursor_column(&self) -> usize {
        self.document().display_column(self.cursor)
    }

    fn vertical(&mut self, direction: isize) {
        if self.wrap {
            self.vertical_wrapped(direction);
            return;
        }
        let line = self.document().line_index(self.cursor);
        let target = line
            .saturating_add_signed(direction)
            .min(self.document().line_count() - 1);
        if target == line {
            return;
        }
        self.cursor = self.position_at_column(target, self.cursor_column(), false);
    }

    fn position_at_column(&self, line: usize, column: usize, nearest: bool) -> usize {
        self.document().position_at_column(line, column, nearest)
    }

    pub fn remember_cursor(&mut self) {
        let range = self.selection();
        self.session.active_mut().selection_head = (!range.is_empty()).then_some(self.cursor);
        self.session.active_mut().selection = range;
    }

    fn restore_cursor(&mut self) {
        self.multi.clear();
        self.find = None;
        self.tools = None;
        self.restore_selection();
        self.top = 0;
        self.wrap_top = 0;
        self.wrap_end = false;
        self.left = 0;
        self.reveal_cursor = true;
        self.message.clear();
    }

    pub fn open(&mut self, text: &str, path: Option<PathBuf>) {
        self.remember_cursor();
        self.session.open(text, path);
        self.restore_cursor();
    }

    pub fn select_buffer(&mut self, index: usize) {
        self.remember_cursor();
        if self.session.select(index) {
            self.restore_cursor();
        }
    }

    fn switch_buffer(&mut self, direction: isize) {
        self.remember_cursor();
        let count = self.session.buffers().len();
        let index =
            (self.session.active_index() as isize + direction).rem_euclid(count as isize) as usize;
        self.session.select(index);
        self.restore_cursor();
    }

    fn save(&mut self) {
        if self.session.active().is_private() {
            self.save_as();
            return;
        }
        let Some(path) = self.session.active().path.clone() else {
            self.save_as();
            return;
        };
        self.save_to(path);
    }

    fn save_as(&mut self) {
        self.save_prompt = Some(String::new());
        self.overwrite_pending = None;
        self.message.clear();
    }

    pub fn confirming_overwrite(&self) -> bool {
        self.overwrite_pending.is_some()
    }

    fn save_to(&mut self, path: PathBuf) {
        match files::save(&path, self.document()) {
            Ok(()) => {
                self.message = format!("Saved {}", path.display());
                self.session.complete_save(path);
            }
            Err(error) => self.message = format!("Save failed: {error}"),
        }
    }

    fn prompt_key(&mut self, key: KeyEvent) {
        if key.code == KeyCode::Esc
            || (key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c'))
        {
            self.save_prompt = None;
            self.overwrite_pending = None;
            return;
        }
        if key.code == KeyCode::Enter {
            let Some(value) = self.save_prompt.clone() else {
                return;
            };
            if !value.is_empty() {
                let target = match std::path::absolute(value) {
                    Ok(path) => path,
                    Err(error) => {
                        self.save_prompt = None;
                        self.overwrite_pending = None;
                        self.message = format!("Save failed: {error}");
                        return;
                    }
                };
                if target.exists() && self.overwrite_pending.as_ref() != Some(&target) {
                    self.overwrite_pending = Some(target);
                    return;
                }
                self.save_prompt = None;
                self.overwrite_pending = None;
                self.save_to(target);
            } else {
                self.save_prompt = None;
                self.overwrite_pending = None;
            }
            return;
        }
        let Some(value) = &mut self.save_prompt else {
            return;
        };
        match key.code {
            KeyCode::Backspace => {
                self.overwrite_pending = None;
                if let Some((offset, _)) = value.grapheme_indices(true).next_back() {
                    value.truncate(offset);
                }
            }
            KeyCode::Char(ch)
                if !key.modifiers.intersects(
                    KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER,
                ) =>
            {
                self.overwrite_pending = None;
                value.push(ch)
            }
            _ => {}
        }
    }
}

#[derive(PartialEq, Eq)]
pub struct RecoveryMark {
    document: u64,
    revision: u64,
    count: usize,
    dirty: bool,
    private: bool,
    path: Option<PathBuf>,
    language: Option<String>,
}

pub fn display_width(text: &str) -> usize {
    text.graphemes(true)
        .fold(0, |column, grapheme| column + cell_width(grapheme, column))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
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
    fn wheel_only_scrolls_the_viewport_and_keyboard_returns_to_the_caret() {
        let source = "line\n".repeat(30);
        let mut editor = Editor::new(&source, None);
        let body = Rect::new(0, 1, 40, 6);
        editor.update_viewport(body);
        let mark = editor.recovery_mark();
        for _ in 0..20 {
            editor.mouse(mouse(MouseEventKind::ScrollDown, 2, 3));
        }
        editor.update_viewport(body);
        assert_eq!(editor.top, editor.document().line_count() - 6);
        assert_eq!(editor.cursor, 0);
        assert!(editor.recovery_mark() == mark);
        assert_eq!(editor.document().text(), source);
        editor.update_viewport(Rect::new(0, 1, 40, 8));
        assert!(
            editor.top > 0,
            "A redraw/resize must preserve an independently scrolled viewport"
        );
        editor.handle(key(KeyCode::Right));
        editor.update_viewport(body);
        assert_eq!((editor.cursor, editor.top), (1, 0));
        for _ in 0..20 {
            editor.mouse(mouse(MouseEventKind::ScrollUp, 2, 3));
        }
        assert_eq!(editor.top, 0);
    }

    #[test]
    fn clicks_use_display_cells_and_whole_graphemes_with_scrolling_and_eof_clamps() {
        let mut editor = Editor::new("a界e\u{301}👩‍💻\tZ\r\nshort\r\nlast", None);
        let body = Rect::new(4, 2, 20, 5);
        editor.update_viewport(body);
        let revision = editor.document().revision();
        for (cell, expected) in [
            (0, 0),
            (1, 1),
            (2, 2),
            (3, 2),
            (4, 4),
            (5, 7),
            (6, 7),
            (7, 8),
            (8, 8),
            (15, 9),
        ] {
            editor.mouse(mouse(
                MouseEventKind::Down(MouseButton::Left),
                body.x + cell,
                body.y,
            ));
            assert_eq!(editor.cursor, expected, "cell {cell}");
        }
        editor.left = 4;
        editor.mouse(mouse(
            MouseEventKind::Down(MouseButton::Left),
            body.x,
            body.y,
        ));
        assert_eq!(editor.cursor, 4);
        editor.left = 0;
        editor.top = 1;
        editor.mouse(mouse(
            MouseEventKind::Down(MouseButton::Left),
            body.x + 2,
            body.y,
        ));
        assert_eq!(editor.cursor, editor.document().line_start(1) + 2);
        editor.mouse(mouse(
            MouseEventKind::Down(MouseButton::Left),
            body.x,
            body.y + 4,
        ));
        assert_eq!(editor.cursor, editor.document().len_chars());
        editor.mouse(mouse(
            MouseEventKind::Down(MouseButton::Left),
            body.x,
            body.y - 1,
        ));
        editor.mouse(mouse(
            MouseEventKind::Down(MouseButton::Right),
            body.x,
            body.y,
        ));
        assert_eq!(editor.cursor, editor.document().len_chars());
        editor.save_prompt = Some(String::new());
        editor.mouse(mouse(
            MouseEventKind::Down(MouseButton::Left),
            body.x,
            body.y,
        ));
        assert_eq!(editor.cursor, editor.document().len_chars());
        assert_eq!(editor.document().revision(), revision);
    }

    #[test]
    fn backspace_and_undo_preserve_a_whole_emoji_sequence() {
        let mut editor = Editor::new("", None);
        editor.insert("я👩‍💻");
        editor.handle(key(KeyCode::Backspace));
        assert_eq!(editor.document().text(), "я");
        editor.handle(KeyEvent::new(KeyCode::Char('z'), KeyModifiers::CONTROL));
        assert_eq!(editor.document().text(), "я👩‍💻");
        assert_eq!(editor.cursor, 4);
    }

    #[test]
    fn vertical_navigation_accounts_for_wide_characters_and_tabs() {
        let mut editor = Editor::new("a界\n\tZ", None);
        editor.cursor = 2;
        editor.handle(key(KeyCode::Down));
        assert_eq!(editor.cursor, 3);
        editor.handle(key(KeyCode::Right));
        assert_eq!(editor.cursor_column(), 4);
    }

    #[test]
    fn restored_session_places_new_input_at_the_saved_cursor() {
        let mut session = Session::new("first", None);
        session.active_mut().selection = 2..2;
        let mut editor = Editor::from_session(session);
        editor.insert("!");
        assert_eq!(editor.document().text(), "fi!rst");
        assert_eq!(editor.cursor, 3);
    }

    #[test]
    fn switching_keeps_cursor_and_undo_in_their_own_buffers() {
        let mut editor = Editor::new("", None);
        editor.insert("first");
        editor.handle(key(KeyCode::Left));
        editor.handle(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::CONTROL));
        editor.insert("second");
        editor.handle(key(KeyCode::F(6)));
        assert_eq!(editor.document().text(), "first");
        assert_eq!(editor.cursor, 4);
        editor.handle(KeyEvent::new(KeyCode::Char('z'), KeyModifiers::CONTROL));
        assert_eq!(editor.document().text(), "");
        editor.handle(key(KeyCode::F(6)));
        assert_eq!(editor.document().text(), "second");
        assert_eq!(editor.cursor, 6);
    }

    #[test]
    fn closing_a_buffer_preserves_edited_text_until_confirmed() {
        let mut editor = Editor::new("keep", None);
        let close = KeyEvent::new(KeyCode::Char('w'), KeyModifiers::CONTROL);
        editor.handle(close);
        assert_eq!(editor.document().text(), "keep");
        editor.handle(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::CONTROL));
        editor.handle(close);
        assert_eq!(editor.document().text(), "keep");
        editor.handle(close);
        assert_eq!(editor.document().text(), "keep");
        editor.handle(close);
        assert_eq!(editor.document().text(), "");
        assert_eq!(editor.session.buffers().len(), 1);
    }

    #[test]
    fn hidden_clean_private_text_still_requires_fresh_quit_confirmation() {
        let mut editor = Editor::new("public", None);
        let control = |ch| KeyEvent::new(KeyCode::Char(ch), KeyModifiers::CONTROL);
        editor.handle(control('p'));
        assert!(editor.session.active().is_private());
        editor.insert("PRIVATE_EDITOR_FIXTURE");
        editor.session.active_mut().document.mark_saved();
        editor.handle(control('w'));
        assert!(editor.session.active().is_private());
        editor.handle(key(KeyCode::F(6))); // Private remains open behind a public tab.
        assert!(!editor.session.active().is_private());
        assert!(!editor.handle(control('q')));
        editor.handle(key(KeyCode::Left));
        assert!(!editor.handle(control('q')));
        editor.insert("!"); // Paste also cancels the quit confirmation.
        assert!(!editor.handle(control('q')));
        assert!(editor.handle(control('q')));
    }

    #[test]
    fn a_quit_request_cancels_the_previous_private_close_confirmation() {
        let mut editor = Editor::new("", None);
        let control = |ch| KeyEvent::new(KeyCode::Char(ch), KeyModifiers::CONTROL);
        editor.handle(control('p'));
        editor.insert("PRIVATE_CLOSE_FIXTURE");
        editor.handle(control('w'));
        assert!(!editor.handle(control('q')));
        editor.handle(control('w'));
        assert!(editor.session.active().is_private());
        editor.handle(control('w'));
        assert!(!editor.session.has_private_text());
    }
}
