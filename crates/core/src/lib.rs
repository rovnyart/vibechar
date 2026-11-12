//! Shared document storage and edit history for the native and terminal clients.

pub mod checkpoint;
pub mod handoff;
pub mod session;

#[cfg(test)]
mod history_tests;

use std::{
    fmt,
    ops::Range,
    time::{Duration, Instant},
};

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
    removed_chars: usize,
    inserted_chars: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum EditKind {
    Isolated = 0,
    Typing = 1,
    Backspace = 2,
    DeleteForward = 3,
}

struct HistoryEntry {
    changes: Vec<Change>,
    kind: EditKind,
    bytes: usize,
}

const TYPING_PAUSE: Duration = Duration::from_secs(1);
const MAX_GROUP_EDITS: usize = 512;
const MAX_GROUP_BYTES: usize = 64 * 1024;

pub struct Document {
    text: Rope,
    undo: Vec<HistoryEntry>,
    redo: Vec<HistoryEntry>,
    last_edit: Option<Instant>,
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
            last_edit: None,
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
        self.edit(range, inserted, EditKind::Isolated)
    }

    /// Coalesce adjacent input of the same kind until a pause or explicit boundary.
    pub fn edit(
        &mut self,
        range: Range<usize>,
        inserted: &str,
        kind: EditKind,
    ) -> Result<bool, InvalidPosition> {
        self.edit_at(range, inserted, kind, Instant::now())
    }

    pub fn break_undo_group(&mut self) {
        self.last_edit = None;
    }

    fn edit_at(
        &mut self,
        range: Range<usize>,
        inserted: &str,
        kind: EditKind,
        now: Instant,
    ) -> Result<bool, InvalidPosition> {
        if range.start > range.end || range.end > self.len_chars() {
            return Err(InvalidPosition);
        }
        let removed = self.text.slice(range.clone()).to_string();
        if removed == inserted {
            return Ok(false);
        }
        let bytes = removed.len() + inserted.len();
        let groupable = bytes <= MAX_GROUP_BYTES
            && !removed.contains([
                '\r', '\n', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}',
            ])
            && !inserted.contains([
                '\r', '\n', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}',
            ])
            && match kind {
                EditKind::Typing => range.is_empty() && !inserted.is_empty(),
                EditKind::Backspace | EditKind::DeleteForward => {
                    !range.is_empty() && inserted.is_empty()
                }
                EditKind::Isolated => false,
            };
        let merge = groupable
            && self.last_edit.is_some_and(|last| {
                now.checked_duration_since(last)
                    .is_some_and(|gap| gap < TYPING_PAUSE)
            })
            && self.undo.last().is_some_and(|entry| {
                let last = entry.changes.last().unwrap();
                entry.kind == kind
                    && entry.changes.len() < MAX_GROUP_EDITS
                    && entry.bytes + bytes <= MAX_GROUP_BYTES
                    && match kind {
                        EditKind::Typing => range.start == last.start + last.inserted_chars,
                        EditKind::Backspace => range.end == last.start,
                        EditKind::DeleteForward => range.start == last.start,
                        EditKind::Isolated => false,
                    }
            });
        self.revoke_drop();
        self.text.remove(range.clone());
        self.text.insert(range.start, inserted);
        let change = Change {
            start: range.start,
            removed,
            inserted: inserted.to_owned(),
            before: self.state,
            after: self.next_state,
            removed_chars: range.end - range.start,
            inserted_chars: inserted.chars().count(),
        };
        self.state = self.next_state;
        self.next_state += 1;
        self.revision += 1;
        if merge {
            let entry = self.undo.last_mut().unwrap();
            entry.bytes += bytes;
            entry.changes.push(change);
        } else {
            self.undo.push(HistoryEntry {
                changes: vec![change],
                kind: if groupable { kind } else { EditKind::Isolated },
                bytes,
            });
        }
        self.last_edit = groupable.then_some(now);
        self.redo.clear();
        Ok(true)
    }

    pub fn undo(&mut self) -> Option<usize> {
        self.break_undo_group();
        let entry = self.undo.pop()?;
        self.revoke_drop();
        for change in entry.changes.iter().rev() {
            self.text
                .remove(change.start..change.start + change.inserted_chars);
            self.text.insert(change.start, &change.removed);
        }
        let first = &entry.changes[0];
        self.state = first.before;
        self.revision += 1;
        let cursor = first.start
            + if entry.kind == EditKind::DeleteForward {
                entry
                    .changes
                    .iter()
                    .map(|change| change.removed_chars)
                    .sum()
            } else {
                first.removed_chars
            };
        self.redo.push(entry);
        Some(cursor)
    }

    pub fn redo(&mut self) -> Option<usize> {
        self.break_undo_group();
        let entry = self.redo.pop()?;
        self.revoke_drop();
        for change in &entry.changes {
            self.text
                .remove(change.start..change.start + change.removed_chars);
            self.text.insert(change.start, &change.inserted);
        }
        let last = entry.changes.last().unwrap();
        self.state = last.after;
        self.revision += 1;
        let cursor = last.start + last.inserted_chars;
        self.undo.push(entry);
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
        self.break_undo_group();
        self.drop_access = Some(grant);
    }

    pub fn is_dirty(&self) -> bool {
        self.state != self.saved_state
    }

    pub fn mark_saved(&mut self) {
        self.break_undo_group();
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
