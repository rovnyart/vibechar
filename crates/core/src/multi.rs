//! Transient multiple selections. Matching, edits and navigation share one contract.
use crate::{
    search::{Engine, Query, MAX_QUERY, MAX_SOURCE},
    Document, EditKind, TextEdit,
};
use std::{collections::VecDeque, ops::Range};
use unicode_segmentation::UnicodeSegmentation;

pub const MAX_SELECTIONS: usize = 1_000;
pub const MAX_BATCH_BYTES: usize = 8 * 1024 * 1024;
enum Pending {
    Edit(String, EditKind),
    Paste(String),
    Move(u32, bool),
    Editing(crate::editing::Action),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Selection {
    pub anchor: usize,
    pub head: usize,
}
impl Selection {
    pub fn range(&self) -> Range<usize> {
        self.anchor.min(self.head)..self.anchor.max(self.head)
    }
    fn forward(range: Range<usize>) -> Self {
        Self {
            anchor: range.start,
            head: range.end,
        }
    }
}
#[derive(Default)]
pub struct Multi {
    selections: Vec<Selection>,
    primary: usize,
    document: u64,
    revision: u64,
    serial: u64,
    engine: Option<Engine>,
    needle: Option<String>,
    whole_words: bool,
    next: usize,
    all: bool,
    last_kind: Option<EditKind>,
    queued: VecDeque<Pending>,
    queued_bytes: usize,
    pub message: Option<String>,
}
impl Multi {
    pub fn selections(&self) -> &[Selection] {
        &self.selections
    }
    pub fn primary_index(&self) -> usize {
        self.primary
    }
    pub fn primary(&self) -> Option<&Selection> {
        self.selections.get(self.primary)
    }
    pub fn adopt(
        &mut self,
        document: &Document,
        ranges: &[Range<usize>],
        primary: usize,
    ) -> Result<(), String> {
        if document.len_bytes() > MAX_SOURCE {
            return self.fail("Multiple selections are limited to 4 MiB documents");
        }
        if ranges.is_empty() {
            return self.fail("No matches to select");
        }
        if ranges.len() > MAX_SELECTIONS {
            return self.fail("More than 1,000 matches · use Replace All");
        }
        if primary >= ranges.len() {
            return self.fail("Invalid primary selection");
        }
        for (index, range) in ranges.iter().enumerate() {
            if range.start > range.end
                || range.end > document.len_chars()
                || index > 0 && ranges[index - 1].end > range.start
            {
                return self.fail("Invalid or overlapping selections");
            }
            if !document.is_grapheme_boundary(range.start)
                || !document.is_grapheme_boundary(range.end)
            {
                return self.fail("Matches split a composed character · refine Find");
            }
        }
        self.clear();
        self.document = document.id();
        self.revision = document.revision();
        self.primary = primary;
        self.selections = ranges.iter().cloned().map(Selection::forward).collect();
        self.normalize();
        self.serial += 1;
        Ok(())
    }
    pub fn serial(&self) -> u64 {
        self.serial
    }
    pub fn report_error(&mut self, message: String) {
        self.message = Some(message);
        self.serial += 1;
    }
    pub fn active(&self, document: &Document) -> bool {
        self.document == document.id()
            && self.revision == document.revision()
            && !self.selections.is_empty()
    }
    pub fn busy(&self) -> bool {
        self.matching() || !self.queued.is_empty()
    }
    fn matching(&self) -> bool {
        self.next > 0 || self.all
    }
    pub fn has_queued_input(&self) -> bool {
        !self.queued.is_empty()
    }
    pub fn clear(&mut self) {
        self.selections.clear();
        self.primary = 0;
        self.engine = None;
        self.needle = None;
        self.whole_words = false;
        self.next = 0;
        self.all = false;
        self.last_kind = None;
        self.queued.clear();
        self.queued_bytes = 0;
        self.message = None;
        self.serial += 1;
    }
    pub fn request(
        &mut self,
        document: &Document,
        selection: Range<usize>,
        all: bool,
    ) -> Result<(), String> {
        self.last_kind = None;
        self.message = None;
        if !self.active(document) || self.needle.is_none() {
            self.clear();
            if document.len_bytes() > MAX_SOURCE {
                return self.fail("Multiple selections are limited to 4 MiB documents");
            }
            let empty = selection.is_empty();
            let range = if empty {
                word_at(document, selection.start)?
            } else {
                selection
            };
            if range.start > range.end || range.end > document.len_chars() {
                return self.fail("Invalid selection");
            }
            if document.text.slice(range.clone()).len_bytes() > MAX_QUERY {
                return self.fail("Select up to 1 KiB of matching text");
            }
            if range.is_empty() {
                return self.fail("Select text or place the caret in a word");
            }
            if !document.is_grapheme_boundary(range.start)
                || !document.is_grapheme_boundary(range.end)
            {
                return self.fail("Select complete characters");
            }
            let needle = document
                .text_range(range.clone())
                .map_err(|_| "Invalid selection")?;
            self.whole_words = empty && needle.unicode_words().eq(std::iter::once(needle.as_str()));
            self.needle = Some(needle);
            self.selections = vec![Selection::forward(range)];
            self.document = document.id();
            self.revision = document.revision();
            self.serial += 1;
            if empty && !all {
                return Ok(());
            }
        }
        if all {
            self.all = true;
            self.next = 0;
        } else if !self.all {
            self.next = (self.next + 1).min(MAX_SELECTIONS);
        }
        if self.engine.is_none() {
            match Engine::new() {
                Ok(engine) => self.engine = Some(engine),
                Err(_) => {
                    self.next = 0;
                    self.all = false;
                    return self.fail("Could not start matching worker");
                }
            }
        }
        self.engine.as_mut().unwrap().submit(
            document,
            Query {
                needle: self.needle.clone().unwrap(),
                case_sensitive: true,
                whole_graphemes: true,
                whole_words: self.whole_words,
                ..Query::default()
            },
        );
        self.serial += 1;
        Ok(())
    }
    pub fn poll(&mut self, document: &Document) -> bool {
        if !self.matching() {
            return false;
        }
        if !self.active(document) {
            self.clear();
            return true;
        }
        let Some(frame) = self
            .engine
            .as_ref()
            .and_then(|engine| engine.frame(document, 0))
        else {
            return false;
        };
        self.message = None;
        let rejected = frame.error.is_some()
            || frame.limited
            || self.all && (frame.matches.len() > MAX_SELECTIONS || frame.matches.is_empty());
        if let Some(error) = &frame.error {
            self.message = Some(error.clone());
        } else if frame.limited {
            self.message = Some("Too many matches · use Find / Replace All".into());
        } else if self.all {
            if frame.matches.len() > MAX_SELECTIONS {
                self.message = Some("More than 1,000 matches · use Replace All".into());
            } else if !frame.matches.is_empty() {
                let primary = self.primary().unwrap().range();
                self.selections = frame
                    .matches
                    .iter()
                    .map(|hit| Selection::forward(hit.start..hit.end))
                    .collect();
                self.primary = self
                    .selections
                    .iter()
                    .position(|s| s.range() == primary)
                    .unwrap_or(0);
            }
        } else {
            for _ in 0..self.next {
                if self.selections.len() >= MAX_SELECTIONS {
                    self.message = Some("1,000 selections · use Replace All for more".into());
                    break;
                }
                let origin = self.primary().unwrap().range().end;
                let begin = frame.matches.partition_point(|hit| hit.start < origin);
                let found = frame.matches[begin..]
                    .iter()
                    .chain(&frame.matches[..begin])
                    .find(|hit| {
                        !self.selections.iter().any(|s| {
                            let r = s.range();
                            r.start < hit.end && hit.start < r.end
                        })
                    });
                let Some(hit) = found else {
                    self.message = Some("All matching occurrences are selected".into());
                    break;
                };
                self.selections.push(Selection::forward(hit.start..hit.end));
                self.primary = self.selections.len() - 1;
                self.normalize();
            }
        }
        self.next = 0;
        self.all = false;
        if rejected {
            self.queued.clear();
            self.queued_bytes = 0;
        }
        self.serial += 1;
        true
    }
    pub fn pump(&mut self, document: &mut Document) -> bool {
        let serial = self.serial;
        self.poll(document);
        while !self.matching() {
            let Some(action) = self.queued.pop_front() else {
                break;
            };
            let result = match action {
                Pending::Edit(text, kind) => {
                    self.queued_bytes -= text.len();
                    self.edit(document, &text, kind).map(|_| ())
                }
                Pending::Move(direction, extend) => self.navigate(document, direction, extend),
                Pending::Editing(action) => self.editing(document, action).map(|_| ()),
                Pending::Paste(text) => {
                    self.queued_bytes -= text.len();
                    self.paste(document, &text).map(|_| ())
                }
            };
            if let Err(error) = result {
                self.report_error(error);
                self.queued.clear();
                self.queued_bytes = 0;
                break;
            }
        }
        self.serial != serial
    }
    fn enqueue(&mut self, action: Pending) -> Result<(), String> {
        let bytes = match &action {
            Pending::Edit(text, _) | Pending::Paste(text) => text.len(),
            _ => 0,
        };
        if self.queued.len() >= 512 || self.queued_bytes + bytes > MAX_BATCH_BYTES {
            return self.fail("Pending input exceeds budget · wait for matches");
        }
        self.queued_bytes += bytes;
        self.queued.push_back(action);
        self.serial += 1;
        Ok(())
    }
    fn fail<T>(&mut self, message: &str) -> Result<T, String> {
        self.message = Some(message.into());
        self.serial += 1;
        Err(message.into())
    }
    fn valid(&self, document: &Document) -> Result<(), String> {
        if self.active(document) {
            Ok(())
        } else {
            Err("Selections are stale · select matches again".into())
        }
    }
    pub fn copy_text(&self, document: &Document) -> Result<Option<String>, String> {
        self.valid(document)?;
        if self.busy() {
            return Err("Wait for matching before copying".into());
        }
        let mut result = String::new();
        for selection in &self.selections {
            let range = selection.range();
            if range.is_empty() {
                continue;
            }
            let text = document
                .text_range(range)
                .map_err(|_| "Invalid selection")?;
            if result.len() + text.len() + 1 > MAX_BATCH_BYTES {
                return Err("Selected text exceeds 8 MiB".into());
            }
            if !result.is_empty() {
                result.push('\n');
            }
            result.push_str(&text);
        }
        Ok((!result.is_empty()).then_some(result))
    }
    pub fn editing(
        &mut self,
        document: &mut Document,
        action: crate::editing::Action,
    ) -> Result<bool, String> {
        self.valid(document)?;
        if self.matching() {
            self.enqueue(Pending::Editing(action))?;
            return Ok(false);
        }
        let plan = document.editing_plan(&self.selections, action)?;
        let changed = document
            .replace_many(&plan.edits)
            .map_err(|_| "Invalid indentation ranges")?;
        self.selections = plan.selections;
        self.revision = document.revision();
        self.engine = None;
        self.needle = None;
        self.next = 0;
        self.all = false;
        self.message = None;
        self.last_kind = None;
        self.normalize();
        self.serial += 1;
        Ok(changed)
    }
    pub fn edit(
        &mut self,
        document: &mut Document,
        text: &str,
        kind: EditKind,
    ) -> Result<bool, String> {
        self.valid(document)?;
        if self.matching() {
            self.enqueue(Pending::Edit(text.into(), kind))?;
            return Ok(false);
        }
        if text
            .len()
            .checked_mul(self.selections.len())
            .is_none_or(|bytes| bytes > MAX_BATCH_BYTES)
        {
            return self.fail("Multicursor edit exceeds 8 MiB");
        }
        let deleting = matches!(kind, EditKind::Backspace | EditKind::DeleteForward);
        let mut targets: Vec<(Range<usize>, bool)> = Vec::new();
        for (index, selection) in self.selections.iter().enumerate() {
            let mut range = selection.range();
            if deleting && range.is_empty() {
                range = if kind == EditKind::Backspace {
                    document.previous_grapheme(range.start)..range.end
                } else {
                    range.start..document.next_grapheme(range.end)
                };
            }
            if deleting {
                if let Some((last, primary)) = targets.last_mut() {
                    if range.start <= last.end {
                        last.end = last.end.max(range.end);
                        *primary |= index == self.primary;
                        continue;
                    }
                }
            }
            targets.push((range, index == self.primary));
        }
        let inserted = if deleting { "" } else { text };
        self.apply_targets(document, &targets, &[inserted], kind)
    }
    /// Spread N clipboard lines over N selections; otherwise repeat the full payload.
    pub fn paste(&mut self, document: &mut Document, text: &str) -> Result<bool, String> {
        self.valid(document)?;
        if text.is_empty() {
            return Ok(false);
        }
        if text.len() > MAX_BATCH_BYTES {
            return self.fail("Multicursor paste exceeds 8 MiB");
        }
        if self.matching() {
            self.enqueue(Pending::Paste(text.into()))?;
            return Ok(false);
        }
        let count = self.selections.len();
        if count > 1 {
            let mut fragments = Vec::with_capacity(count);
            for line in text.split_inclusive('\n') {
                if fragments.len() == count {
                    return self.edit(document, text, EditKind::Isolated);
                }
                let fragment = if let Some(body) = line.strip_suffix('\n') {
                    body.strip_suffix('\r').unwrap_or(body)
                } else {
                    line
                };
                fragments.push(fragment);
            }
            if fragments.len() == count {
                let targets = self
                    .selections
                    .iter()
                    .enumerate()
                    .map(|(index, selection)| (selection.range(), index == self.primary))
                    .collect::<Vec<_>>();
                return self.apply_targets(document, &targets, &fragments, EditKind::Isolated);
            }
        }
        self.edit(document, text, EditKind::Isolated)
    }
    fn apply_targets(
        &mut self,
        document: &mut Document,
        targets: &[(Range<usize>, bool)],
        fragments: &[&str],
        kind: EditKind,
    ) -> Result<bool, String> {
        let fragment = |index: usize| {
            if fragments.len() == 1 {
                fragments[0]
            } else {
                fragments[index]
            }
        };
        let bytes = targets
            .iter()
            .enumerate()
            .map(|(index, (range, _))| {
                document.text.slice(range.clone()).len_bytes() + fragment(index).len()
            })
            .sum::<usize>();
        if bytes > MAX_BATCH_BYTES {
            return self.fail("Multicursor edit exceeds 8 MiB");
        }
        let edits = targets
            .iter()
            .enumerate()
            .map(|(index, (range, _))| TextEdit {
                range: range.clone(),
                text: fragment(index).into(),
            })
            .collect::<Vec<_>>();
        let old_count = self.selections.len();
        let changed = document
            .replace_many_input(&edits, kind, self.last_kind == Some(kind))
            .map_err(|_| "Selections are stale")?;
        let mut delta = 0isize;
        self.selections = targets
            .iter()
            .enumerate()
            .map(|(index, (range, primary))| {
                let count = fragment(index).chars().count();
                let caret = range.start.wrapping_add_signed(delta) + count;
                delta += count as isize - range.len() as isize;
                if *primary {
                    self.primary = index;
                }
                Selection {
                    anchor: caret,
                    head: caret,
                }
            })
            .collect();
        self.revision = document.revision();
        self.engine = None;
        self.needle = None;
        self.next = 0;
        self.all = false;
        self.message = None;
        self.normalize();
        self.last_kind = (old_count == self.selections.len()).then_some(kind);
        self.serial += 1;
        Ok(changed)
    }
    /// Directions: left/right/up/down, line start/end, document start/end.
    pub fn navigate(
        &mut self,
        document: &Document,
        direction: u32,
        extend: bool,
    ) -> Result<(), String> {
        self.valid(document)?;
        if self.matching() {
            return self.enqueue(Pending::Move(direction, extend));
        }
        let mut selections = self.selections.clone();
        for selection in &mut selections {
            let range = selection.range();
            let head = selection.head;
            let target = match direction {
                0 if !extend && !range.is_empty() => range.start,
                1 if !extend && !range.is_empty() => range.end,
                0 => document.previous_grapheme(head),
                1 => document.next_grapheme(head),
                2 | 3 => {
                    let line = document
                        .line_index(head)
                        .saturating_add_signed(if direction == 2 { -1 } else { 1 })
                        .min(document.line_count() - 1);
                    document.position_at_column(line, document.display_column(head), false)
                }
                4 => document.line_start(document.line_index(head)),
                5 => document.line_range(document.line_index(head)).end,
                6 => 0,
                7 => document.len_chars(),
                _ => return Err("Unsupported cursor movement".into()),
            };
            if !extend {
                selection.anchor = target;
            }
            selection.head = target;
        }
        self.selections = selections;
        self.normalize();
        self.needle = None;
        self.engine = None;
        self.next = 0;
        self.all = false;
        self.last_kind = None;
        self.message = None;
        self.serial += 1;
        Ok(())
    }
    fn normalize(&mut self) {
        let mut ranges = self
            .selections
            .iter()
            .cloned()
            .enumerate()
            .map(|(i, s)| (s, i == self.primary))
            .collect::<Vec<_>>();
        ranges.sort_by_key(|(s, _)| {
            let r = s.range();
            (r.start, r.end)
        });
        let mut output: Vec<(Selection, bool)> = Vec::new();
        for (selection, primary) in ranges {
            let range = selection.range();
            if let Some((last, was_primary)) = output.last_mut() {
                let previous = last.range();
                if range.start < previous.end
                    || range.start == previous.start
                    || range.is_empty() && range.start == previous.end
                {
                    let reverse = if primary {
                        selection.head < selection.anchor
                    } else {
                        last.head < last.anchor
                    };
                    let start = previous.start.min(range.start);
                    let end = previous.end.max(range.end);
                    *last = if reverse {
                        Selection {
                            anchor: end,
                            head: start,
                        }
                    } else {
                        Selection::forward(start..end)
                    };
                    *was_primary |= primary;
                    continue;
                }
            }
            output.push((selection, primary));
        }
        self.primary = output.iter().position(|(_, p)| *p).unwrap_or(0);
        self.selections = output.into_iter().map(|(s, _)| s).collect();
    }
}

fn word_at(document: &Document, position: usize) -> Result<Range<usize>, String> {
    if position > document.len_chars() {
        return Err("Invalid caret".into());
    }
    let line = document.line_index(position);
    let start = document.line_start(line);
    if document.text.line(line).len_bytes() > crate::limits::WORD_LINE_BYTES {
        return Err("Select a fragment in this long line first".into());
    }
    let text = document.line(line);
    let offset = position - start;
    let mut previous_byte = 0;
    let mut offset_chars = 0;
    let words = text
        .unicode_word_indices()
        .map(|(byte, word)| {
            offset_chars += text[previous_byte..byte].chars().count();
            previous_byte = byte;
            offset_chars..offset_chars + word.chars().count()
        })
        .collect::<Vec<_>>();
    if let Some(range) = words
        .iter()
        .find(|r| r.contains(&offset))
        .or_else(|| words.iter().find(|r| r.end == offset))
    {
        return Ok(start + range.start..start + range.end);
    }
    let from = document.previous_grapheme(document.next_grapheme(position));
    let to = document.next_grapheme(from);
    let range = from..to;
    let text = document
        .text_range(range.clone())
        .map_err(|_| "Invalid caret")?;
    Ok(if text.trim().is_empty() {
        position..position
    } else {
        range
    })
}

#[cfg(test)]
#[path = "multi_tests.rs"]
mod tests;
