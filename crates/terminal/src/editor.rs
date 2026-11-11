use std::path::PathBuf;

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;
use vibechar_core::Document;

use crate::files;

pub struct Editor {
    pub document: Document,
    pub cursor: usize,
    pub path: Option<PathBuf>,
    pub top: usize,
    pub left: usize,
    pub message: String,
    pub save_prompt: Option<String>,
    discard_pending: bool,
}

impl Editor {
    pub fn new(text: &str, path: Option<PathBuf>) -> Self {
        let document = if path.is_none() && !text.is_empty() {
            let mut document = Document::new("");
            document
                .replace(0..0, text)
                .expect("empty insertion is a valid range");
            document
        } else {
            Document::new(text)
        };
        Self {
            document,
            cursor: 0,
            path,
            top: 0,
            left: 0,
            message: "Preview · Save your text to keep it".into(),
            save_prompt: None,
            discard_pending: false,
        }
    }

    pub fn insert(&mut self, text: &str) {
        if let Some(prompt) = &mut self.save_prompt {
            if !text.contains(['\n', '\r', '\0']) {
                prompt.push_str(text);
            }
            return;
        }
        if self
            .document
            .replace(self.cursor..self.cursor, text)
            .is_ok()
        {
            self.cursor += text.chars().count();
        }
        self.discard_pending = false;
    }

    pub fn handle(&mut self, key: KeyEvent) -> bool {
        if key.kind == KeyEventKind::Release {
            return false;
        }
        if self.save_prompt.is_some() {
            self.prompt_key(key);
            return false;
        }
        if key.modifiers.contains(KeyModifiers::CONTROL) {
            return self.control(key.code);
        }
        self.discard_pending = false;
        match key.code {
            KeyCode::Char(ch)
                if !key
                    .modifiers
                    .intersects(KeyModifiers::ALT | KeyModifiers::SUPER) =>
            {
                self.insert(&ch.to_string())
            }
            KeyCode::Enter => self.insert(self.document.newline()),
            KeyCode::Tab => self.insert("    "),
            KeyCode::Left => self.cursor = self.document.previous_grapheme(self.cursor),
            KeyCode::Right => self.cursor = self.document.next_grapheme(self.cursor),
            KeyCode::Up => self.vertical(-1),
            KeyCode::Down => self.vertical(1),
            KeyCode::Home => {
                self.cursor = self
                    .document
                    .line_start(self.document.line_index(self.cursor))
            }
            KeyCode::End => self.cursor = self.line_end(),
            KeyCode::Backspace => {
                let start = self.document.previous_grapheme(self.cursor);
                if self.document.replace(start..self.cursor, "").is_ok() {
                    self.cursor = start;
                }
            }
            KeyCode::Delete => {
                let _ = self
                    .document
                    .replace(self.cursor..self.document.next_grapheme(self.cursor), "");
            }
            _ => {}
        }
        false
    }

    fn control(&mut self, code: KeyCode) -> bool {
        if code == KeyCode::Char('q') {
            if !self.document.is_dirty() || self.discard_pending {
                return true;
            }
            self.message = "Unsaved text. Ctrl+S to save · Ctrl+Q again to discard".into();
            self.discard_pending = true;
            return false;
        }
        self.discard_pending = false;
        match code {
            KeyCode::Char('s') => self.save(),
            KeyCode::Char('z') => {
                if let Some(cursor) = self.document.undo() {
                    self.cursor = cursor;
                }
            }
            KeyCode::Char('y') => {
                if let Some(cursor) = self.document.redo() {
                    self.cursor = cursor;
                }
            }
            KeyCode::Home => self.cursor = 0,
            KeyCode::End => self.cursor = self.document.len_chars(),
            _ => {}
        }
        false
    }

    fn line_end(&self) -> usize {
        let line = self.document.line_index(self.cursor);
        self.document.line_start(line) + self.document.line(line).chars().count()
    }

    pub fn cursor_column(&self) -> usize {
        let line = self.document.line_index(self.cursor);
        let prefix: String = self
            .document
            .line(line)
            .chars()
            .take(self.cursor - self.document.line_start(line))
            .collect();
        display_width(&prefix)
    }

    fn vertical(&mut self, direction: isize) {
        let line = self.document.line_index(self.cursor);
        let target = line
            .saturating_add_signed(direction)
            .min(self.document.line_count() - 1);
        if target == line {
            return;
        }
        let column = self.cursor_column();
        let mut width = 0;
        let mut offset = 0;
        for grapheme in self.document.line(target).graphemes(true) {
            let next_width = width + cell_width(grapheme, width);
            if next_width > column {
                break;
            }
            width = next_width;
            offset += grapheme.chars().count();
        }
        self.cursor = self.document.line_start(target) + offset;
    }

    fn save(&mut self) {
        let Some(path) = &self.path else {
            self.save_prompt = Some(String::new());
            return;
        };
        match files::save(path, &self.document) {
            Ok(()) => {
                self.document.mark_saved();
                self.message = format!("Saved {}", path.display());
            }
            Err(error) => self.message = format!("Save failed: {error}"),
        }
    }

    fn prompt_key(&mut self, key: KeyEvent) {
        if key.code == KeyCode::Esc
            || (key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c'))
        {
            self.save_prompt = None;
            return;
        }
        if key.code == KeyCode::Enter {
            let Some(value) = self.save_prompt.take() else {
                return;
            };
            if !value.is_empty() {
                let target = PathBuf::from(value);
                if target.exists() {
                    self.message = "Choose a new filename; replacing an existing file needs a later save-as dialog".into();
                    return;
                }
                self.path = Some(target);
                self.save();
            }
            return;
        }
        let Some(value) = &mut self.save_prompt else {
            return;
        };
        match key.code {
            KeyCode::Backspace => {
                if let Some((offset, _)) = value.grapheme_indices(true).next_back() {
                    value.truncate(offset);
                }
            }
            KeyCode::Char(ch)
                if !key.modifiers.intersects(
                    KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER,
                ) =>
            {
                value.push(ch)
            }
            _ => {}
        }
    }
}

pub fn cell_width(grapheme: &str, column: usize) -> usize {
    if grapheme == "\t" {
        return 4 - column % 4;
    }
    if grapheme.chars().any(char::is_control) {
        return 1;
    }
    UnicodeWidthStr::width(grapheme)
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

    #[test]
    fn backspace_and_undo_preserve_a_whole_emoji_sequence() {
        let mut editor = Editor::new("", None);
        editor.insert("я👩‍💻");
        editor.handle(key(KeyCode::Backspace));
        assert_eq!(editor.document.text(), "я");
        editor.handle(KeyEvent::new(KeyCode::Char('z'), KeyModifiers::CONTROL));
        assert_eq!(editor.document.text(), "я👩‍💻");
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
    fn quit_requires_explicit_discard_after_editing() {
        let mut editor = Editor::new("", None);
        editor.insert("keep me");
        let quit = KeyEvent::new(KeyCode::Char('q'), KeyModifiers::CONTROL);
        assert!(!editor.handle(quit));
        assert!(editor.handle(quit));
    }

    #[test]
    fn piped_text_is_unsaved_until_written_to_a_file() {
        let mut editor = Editor::new("piped input", None);
        assert!(editor.document.is_dirty());
        assert!(!editor.handle(KeyEvent::new(KeyCode::Char('q'), KeyModifiers::CONTROL)));
    }
}
