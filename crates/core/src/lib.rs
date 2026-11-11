//! Shared document storage and edit history for the native and terminal clients.

pub mod checkpoint;
pub mod handoff;
pub mod session;

use std::{fmt, ops::Range};

use ropey::Rope;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidPosition;

impl fmt::Display for InvalidPosition {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("text position is outside the document or splits a UTF-16 surrogate pair")
    }
}

impl std::error::Error for InvalidPosition {}

struct Change {
    start: usize,
    removed: String,
    inserted: String,
    before: u64,
    after: u64,
}

pub struct Document {
    text: Rope,
    undo: Vec<Change>,
    redo: Vec<Change>,
    revision: u64,
    state: u64,
    next_state: u64,
    saved_state: u64,
    crlf: bool,
    drop_access: Option<handoff::GrantLink>,
}

impl Drop for Document {
    fn drop(&mut self) {
        self.revoke_drop();
    }
}

impl Document {
    pub(crate) fn checkpoint_text(&self) -> Rope {
        self.text.clone()
    }

    pub(crate) fn restore(text: Rope, dirty: bool) -> Self {
        let mut document = Self::new("");
        let mut previous = '\0';
        document.crlf = text
            .chars()
            .find_map(|character| {
                if character == '\n' {
                    return Some(previous == '\r');
                }
                previous = character;
                None
            })
            .unwrap_or(false);
        document.text = text;
        document.state = u64::from(dirty);
        document.next_state = document.state + 1;
        document
    }

    pub fn new(text: &str) -> Self {
        Self {
            text: Rope::from_str(text),
            undo: Vec::new(),
            redo: Vec::new(),
            revision: 0,
            state: 0,
            next_state: 1,
            saved_state: 0,
            drop_access: None,
            crlf: text
                .find('\n')
                .is_some_and(|at| at > 0 && text.as_bytes()[at - 1] == b'\r'),
        }
    }

    /// Replace a range measured in Unicode scalar values, recording one undo step.
    pub fn replace(
        &mut self,
        range: Range<usize>,
        inserted: &str,
    ) -> Result<bool, InvalidPosition> {
        if range.start > range.end || range.end > self.len_chars() {
            return Err(InvalidPosition);
        }
        let removed = self.text.slice(range.clone()).to_string();
        if removed == inserted {
            return Ok(false);
        }
        self.revoke_drop();
        self.text.remove(range.clone());
        self.text.insert(range.start, inserted);
        let change = Change {
            start: range.start,
            removed,
            inserted: inserted.to_owned(),
            before: self.state,
            after: self.next_state,
        };
        self.state = self.next_state;
        self.next_state += 1;
        self.revision += 1;
        self.undo.push(change);
        self.redo.clear();
        Ok(true)
    }

    pub fn undo(&mut self) -> Option<usize> {
        let change = self.undo.pop()?;
        self.revoke_drop();
        self.text
            .remove(change.start..change.start + change.inserted.chars().count());
        self.text.insert(change.start, &change.removed);
        self.state = change.before;
        self.revision += 1;
        let cursor = change.start + change.removed.chars().count();
        self.redo.push(change);
        Some(cursor)
    }

    pub fn redo(&mut self) -> Option<usize> {
        let change = self.redo.pop()?;
        self.revoke_drop();
        self.text
            .remove(change.start..change.start + change.removed.chars().count());
        self.text.insert(change.start, &change.inserted);
        self.state = change.after;
        self.revision += 1;
        let cursor = change.start + change.inserted.chars().count();
        self.undo.push(change);
        Some(cursor)
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn revoke_drop(&mut self) {
        self.drop_access = None;
    }
    pub fn drop_reference(&self) -> Option<&str> {
        self.drop_access.as_ref().map(|grant| grant.reference())
    }
    pub fn drop_uses(&self) -> Option<u64> {
        self.drop_access.as_ref().and_then(|grant| grant.uses())
    }
    pub(crate) fn publish_drop(&mut self, grant: handoff::GrantLink) {
        self.drop_access = Some(grant);
    }

    pub fn is_dirty(&self) -> bool {
        self.state != self.saved_state
    }

    pub fn mark_saved(&mut self) {
        self.saved_state = self.state;
    }

    pub fn text(&self) -> String {
        self.text.to_string()
    }

    pub fn len_chars(&self) -> usize {
        self.text.len_chars()
    }

    pub fn len_bytes(&self) -> usize {
        self.text.len_bytes()
    }

    pub fn line_count(&self) -> usize {
        self.text.len_lines()
    }

    pub fn line_index(&self, position: usize) -> usize {
        self.text.char_to_line(position.min(self.len_chars()))
    }

    pub fn line_start(&self, line: usize) -> usize {
        self.text.line_to_char(line.min(self.line_count() - 1))
    }

    pub fn line(&self, line: usize) -> String {
        let mut raw = self.text.line(line.min(self.line_count() - 1)).to_string();
        if raw.ends_with("\r\n") {
            raw.truncate(raw.len() - 2);
        } else if let Some(last) = raw.chars().next_back() {
            if matches!(
                last,
                '\r' | '\n' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
            ) {
                raw.truncate(raw.len() - last.len_utf8());
            }
        }
        raw
    }

    pub fn newline(&self) -> &'static str {
        if self.crlf {
            "\r\n"
        } else {
            "\n"
        }
    }

    pub fn write_to(&self, writer: impl std::io::Write) -> std::io::Result<()> {
        self.text.write_to(writer)
    }

    pub fn char_from_utf16(&self, offset: usize) -> Result<usize, InvalidPosition> {
        if offset > self.text.len_utf16_cu() {
            return Err(InvalidPosition);
        }
        let index = self.text.utf16_cu_to_char(offset);
        if self.text.char_to_utf16_cu(index) != offset {
            return Err(InvalidPosition);
        }
        Ok(index)
    }

    pub fn utf16_from_char(&self, index: usize) -> Result<usize, InvalidPosition> {
        if index > self.len_chars() {
            return Err(InvalidPosition);
        }
        Ok(self.text.char_to_utf16_cu(index))
    }

    pub fn next_grapheme(&self, position: usize) -> usize {
        let position = position.min(self.len_chars());
        let line = self.line_index(position);
        let start = self.line_start(line);
        let raw = self.text.line(line).to_string();
        let mut offset = start;
        for grapheme in raw.graphemes(true) {
            offset += grapheme.chars().count();
            if offset > position {
                return offset;
            }
        }
        self.len_chars()
    }

    pub fn previous_grapheme(&self, position: usize) -> usize {
        let position = position.min(self.len_chars());
        if position == 0 {
            return 0;
        }
        let line = self.line_index(position - 1);
        let start = self.line_start(line);
        let raw = self.text.line(line).to_string();
        let mut offset = start;
        for grapheme in raw.graphemes(true) {
            let next = offset + grapheme.chars().count();
            if next >= position {
                return offset;
            }
            offset = next;
        }
        start
    }
}
