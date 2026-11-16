//! Rope-local grapheme navigation and bounded, sparse logical-line geometry.
use crate::Document;
use ropey::RopeSlice;
use unicode_segmentation::{GraphemeCursor, GraphemeIncomplete, UnicodeSegmentation};
use unicode_width::UnicodeWidthStr;

#[cfg(test)]
#[path = "text_tests.rs"]
mod tests;

const MAX_LINES: usize = 8;
const MAX_POINTS: usize = 4096;
const STRIDE: usize = 4096;

pub fn cell_width(grapheme: &str, column: usize) -> usize {
    if grapheme == "\t" {
        4 - column % 4
    } else if grapheme.chars().any(char::is_control) {
        1
    } else {
        UnicodeWidthStr::width(grapheme)
    }
}

#[derive(Clone, Copy, Default, Debug, PartialEq, Eq)]
struct Point {
    byte: usize,
    character: usize,
    utf16: usize,
    column: usize,
}

pub struct LineWindow {
    pub text: String,
    pub character: usize,
    pub utf16: usize,
    pub column: usize,
}

struct Line {
    index: usize,
    stride: usize,
    points: Vec<Point>,
    wrap: Option<Wrapping>,
}

struct Wrapping {
    width: usize,
    stride: usize,
    points: Vec<(usize, Point)>,
}

#[derive(Default)]
pub(crate) struct Cache {
    lines: Vec<Line>,
}

impl Cache {
    pub(crate) fn invalidate(&mut self, line: usize, character: usize) {
        // Later line numbers/offsets may change. Keep only an unaffected prefix.
        self.lines.retain(|entry| entry.index <= line);
        if let Some(entry) = self.lines.iter_mut().find(|entry| entry.index == line) {
            entry
                .points
                .retain(|p| p.character < character || p.byte == 0);
            if let Some(wrap) = &mut entry.wrap {
                wrap.points
                    .retain(|(_, p)| p.character < character || p.byte == 0);
            }
        }
    }

    fn line(&mut self, index: usize) -> &mut Line {
        if let Some(at) = self.lines.iter().position(|entry| entry.index == index) {
            let entry = self.lines.remove(at);
            self.lines.push(entry);
        } else {
            if self.lines.len() == MAX_LINES {
                self.lines.remove(0);
            }
            self.lines.push(Line {
                index,
                stride: STRIDE,
                points: vec![Point::default()],
                wrap: None,
            });
        }
        self.lines.last_mut().unwrap()
    }
}

#[derive(Clone, Copy)]
enum Target {
    Character(usize),
    Column(usize),
}
impl Target {
    fn remaining(self, point: Point) -> usize {
        match self {
            Self::Character(at) => at.saturating_sub(point.character),
            Self::Column(at) => at.saturating_sub(point.column),
        }
    }
    fn includes(self, point: Point) -> bool {
        match self {
            Self::Character(at) => point.character <= at,
            Self::Column(at) => point.column <= at,
        }
    }
}

impl Line {
    fn wrapped(
        &mut self,
        text: RopeSlice<'_>,
        width: usize,
        target: usize,
        by_character: bool,
    ) -> Option<(usize, Point)> {
        let width = width.max(1);
        if self.wrap.as_ref().is_none_or(|w| w.width != width) {
            self.wrap = Some(Wrapping {
                width,
                stride: 1,
                points: vec![(0, Point::default())],
            });
        }
        let cache = self.wrap.as_mut().unwrap();
        let index = cache
            .points
            .partition_point(|(row, p)| {
                if by_character {
                    p.character <= target
                } else {
                    *row <= target
                }
            })
            .saturating_sub(1);
        let (mut row, mut point) = cache.points[index];
        loop {
            if !by_character && row == target {
                return Some((row, point));
            }
            let Some(next) = wrap_next(text, point, width) else {
                return if by_character {
                    Some((row, point))
                } else {
                    None
                };
            };
            if by_character && next.character > target {
                return Some((row, point));
            }
            row += 1;
            point = next;
            if row > cache.points.last().unwrap().0
                && (row % cache.stride == 0 || point.byte == text.len_bytes())
            {
                if cache.points.len() == MAX_POINTS {
                    let mut i = 0;
                    cache.points.retain(|_| {
                        i += 1;
                        i % 2 == 1
                    });
                    cache.stride = cache.stride.saturating_mul(2);
                }
                cache.points.push((row, point));
            }
        }
    }
    fn record(&mut self, point: Point, end: usize) {
        let last = *self.points.last().unwrap();
        if point.byte > last.byte && (point.byte - last.byte >= self.stride || point.byte == end) {
            if self.points.len() == MAX_POINTS {
                let mut index = 0;
                self.points.retain(|_| {
                    index += 1;
                    index % 2 == 1
                });
                self.stride = self.stride.saturating_mul(2);
            }
            self.points.push(point);
        }
    }

    fn locate(&mut self, text: RopeSlice<'_>, target: Target) -> Point {
        let index = self
            .points
            .partition_point(|p| target.includes(*p))
            .saturating_sub(1);
        let mut point = self.points[index];
        let mut walker = Walker::new(text, point.byte);
        while point.byte < text.len_bytes() {
            let ascii = walker.ascii(target.remaining(point).min(self.stride));
            if ascii > 0 {
                point.byte += ascii;
                point.character += ascii;
                point.utf16 += ascii;
                point.column += ascii;
            } else {
                let next = walker.next(point);
                if !target.includes(next) {
                    break;
                }
                point = next;
            }
            self.record(point, text.len_bytes());
        }
        point
    }
}

// Greedy cell wrapping: keep graphemes whole and retain logical tab stops. A
// full final row has an empty continuation for the insertion caret at EOF.
fn wrap_next(text: RopeSlice<'_>, start: Point, width: usize) -> Option<Point> {
    if start.byte == text.len_bytes() {
        return None;
    }
    let mut point = start;
    let mut walker = Walker::new(text, start.byte);
    let limit = start.column.saturating_add(width);
    while point.byte < text.len_bytes() {
        let ascii = walker.ascii(limit.saturating_sub(point.column));
        if ascii > 0 {
            point.byte += ascii;
            point.character += ascii;
            point.utf16 += ascii;
            point.column += ascii;
        } else {
            let next = walker.next(point);
            if next.column > limit && point.byte > start.byte {
                return Some(point);
            }
            point = next;
        }
        if point.column >= limit {
            return Some(point);
        }
    }
    None
}

// Cursor chunks are borrowed from the Rope. Only a grapheme crossing chunks
// needs temporary contiguous storage; ordinary ASCII runs advance together.
struct Walker<'a> {
    text: RopeSlice<'a>,
    cursor: GraphemeCursor,
    chunk: &'a str,
    start: usize,
}
impl<'a> Walker<'a> {
    fn new(text: RopeSlice<'a>, byte: usize) -> Self {
        let (chunk, start, _, _) = text.chunk_at_byte(byte);
        Self {
            text,
            cursor: GraphemeCursor::new(byte, text.len_bytes(), true),
            chunk,
            start,
        }
    }
    fn boundary(&mut self, forward: bool) -> Option<usize> {
        loop {
            let result = if forward {
                self.cursor.next_boundary(self.chunk, self.start)
            } else {
                self.cursor.prev_boundary(self.chunk, self.start)
            };
            match result {
                Ok(boundary) => return boundary,
                Err(GraphemeIncomplete::PreContext(_)) => {
                    let at = self.cursor.cur_cursor();
                    let boundary = self.context_boundary(at);
                    self.cursor = GraphemeCursor::new(at, self.text.len_bytes(), true);
                    (self.chunk, self.start, _, _) = self.text.chunk_at_byte(at);
                    if boundary {
                        return Some(at);
                    }
                }
                Err(GraphemeIncomplete::NextChunk) => {
                    (self.chunk, self.start, _, _) =
                        self.text.chunk_at_byte(self.start + self.chunk.len());
                }
                Err(GraphemeIncomplete::PrevChunk) => {
                    (self.chunk, self.start, _, _) = self.text.chunk_at_byte(self.start - 1);
                }
                Err(GraphemeIncomplete::InvalidOffset) => {
                    unreachable!("Rope cursor chunk must contain its offset")
                }
            }
        }
    }
    fn context_boundary(&self, at: usize) -> bool {
        // Replay with contiguous context, expanding only when asked. Emoji and
        // Indic sequences can need context spanning more than one Rope chunk.
        let (_, mut left, _, _) = self.text.chunk_at_byte(at.saturating_sub(1));
        let (chunk, start, _, _) = self.text.chunk_at_byte(at);
        let right = start + chunk.len();
        let mut growth = (right - left).max(1);
        loop {
            let slice = self.text.byte_slice(left..right);
            let text = std::borrow::Cow::<'_, str>::from(slice);
            let mut cursor = GraphemeCursor::new(at, self.text.len_bytes(), true);
            match cursor.is_boundary(&text, left) {
                Ok(boundary) => return boundary,
                Err(GraphemeIncomplete::PreContext(end)) => {
                    (_, left, _, _) = self.text.chunk_at_byte(end.saturating_sub(growth));
                    growth = growth.saturating_mul(2);
                }
                _ => unreachable!("Contiguous boundary context contains the cursor"),
            }
        }
    }
    fn ascii(&mut self, limit: usize) -> usize {
        let byte = self.cursor.cur_cursor();
        if byte == self.start + self.chunk.len() && byte < self.text.len_bytes() {
            (self.chunk, self.start, _, _) = self.text.chunk_at_byte(byte);
        }
        let prefix = self.chunk[byte - self.start..]
            .bytes()
            .take_while(|b| (b' '..=b'~').contains(b))
            .count();
        // The final ASCII scalar can join a combining mark in the next chunk.
        let count = prefix.saturating_sub(1).min(limit);
        if count > 0 {
            self.cursor.set_cursor(byte + count);
        }
        count
    }
    fn next(&mut self, point: Point) -> Point {
        let end = self.boundary(true).unwrap_or(self.text.len_bytes());
        let owned;
        let grapheme = if point.byte >= self.start && end <= self.start + self.chunk.len() {
            &self.chunk[point.byte - self.start..end - self.start]
        } else {
            owned = self.text.byte_slice(point.byte..end).to_string();
            &owned
        };
        Point {
            byte: end,
            character: point.character + grapheme.chars().count(),
            utf16: point.utf16 + grapheme.encode_utf16().count(),
            column: point.column + cell_width(grapheme, point.column),
        }
    }
}

/// Count without flattening the Rope. Work is bounded/cancellable between chunks;
/// a word is a run of graphemes containing letters, numbers or underscores.
pub(crate) fn count_text(text: RopeSlice<'_>, cancel: impl Fn() -> bool) -> Option<(usize, usize)> {
    let mut walker = Walker::new(text, 0);
    let (mut byte, mut characters, mut words, mut in_word) = (0, 0, 0, false);
    while byte < text.len_bytes() {
        if cancel() {
            return None;
        }
        let ascii = walker.ascii(4096);
        if ascii > 0 {
            characters += ascii;
            for chunk in text.byte_slice(byte..byte + ascii).chunks() {
                for b in chunk.bytes() {
                    let word = b.is_ascii_alphanumeric() || b == b'_';
                    if word && !in_word {
                        words += 1;
                    }
                    in_word = word;
                }
            }
            byte += ascii;
        } else {
            let end = walker.boundary(true).unwrap_or(text.len_bytes());
            let word = text
                .byte_slice(byte..end)
                .chars()
                .any(|c| c.is_alphanumeric() || c == '_');
            if word && !in_word {
                words += 1;
            }
            in_word = word;
            characters += 1;
            byte = end;
        }
    }
    Some((characters, words))
}

impl Document {
    /// Whole word/punctuation/space under a pointer; never flatten a giant line.
    pub fn word_selection(&self, position: usize) -> Result<std::ops::Range<usize>, &'static str> {
        if position > self.len_chars() {
            return Err("Invalid caret");
        }
        let line = self.line_index(position);
        let range = self.line_range(line);
        let slice = self.text.slice(range.clone());
        if slice.len_bytes() > crate::limits::WORD_LINE_BYTES {
            return Err("Long line · drag to select a fragment");
        }
        let mut start = range.start;
        for word in slice.to_string().split_word_bounds() {
            let end = start + word.chars().count();
            if position >= start && position < end {
                return Ok(start..end);
            }
            start = end;
        }
        Ok(position..position)
    }
    pub fn wrapped_row_at(&self, position: usize, width: usize) -> usize {
        let line = self.line_index(position);
        let range = self.line_range(line);
        let (row, point) = self
            .layout
            .borrow_mut()
            .line(line)
            .wrapped(
                self.text.slice(range.clone()),
                width,
                position.min(range.end) - range.start,
                true,
            )
            .unwrap();
        if line + 1 < self.line_count()
            && row > 0
            && point.byte == self.text.slice(range).len_bytes()
        {
            row - 1
        } else {
            row
        }
    }

    /// Bounded text for one visual row, with logical character/UTF-16/cell origins.
    pub fn wrapped_window(&self, line: usize, row: usize, width: usize) -> Option<LineWindow> {
        if line >= self.line_count() {
            return None;
        }
        let text = self.text.slice(self.line_range(line));
        let (_, start) = self
            .layout
            .borrow_mut()
            .line(line)
            .wrapped(text, width, row, false)?;
        if line + 1 < self.line_count() && row > 0 && start.byte == text.len_bytes() {
            return None;
        }
        let end = wrap_next(text, start, width.max(1)).unwrap_or_else(|| {
            self.layout
                .borrow_mut()
                .line(line)
                .locate(text, Target::Character(text.len_chars()))
        });
        Some(LineWindow {
            text: text.byte_slice(start.byte..end.byte).to_string(),
            character: start.character,
            utf16: start.utf16,
            column: start.column,
        })
    }
    pub(crate) fn invalidate_layout(&self, position: usize) {
        let line = self.line_index(position);
        self.layout
            .borrow_mut()
            .invalidate(line, position - self.line_start(line));
    }

    /// Content range excludes CRLF and all line endings recognized by Ropey.
    pub fn line_range(&self, line: usize) -> std::ops::Range<usize> {
        let line = line.min(self.line_count() - 1);
        let raw = self.text.line(line);
        let mut length = raw.len_chars();
        if length > 0 {
            let last = raw.char(length - 1);
            if matches!(
                last,
                '\r' | '\n' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
            ) {
                length -= 1;
                if last == '\n' && length > 0 && raw.char(length - 1) == '\r' {
                    length -= 1;
                }
            }
        }
        let start = self.line_start(line);
        start..start + length
    }

    pub fn display_column(&self, position: usize) -> usize {
        let position = position.min(self.len_chars());
        let line = self.line_index(position);
        let range = self.line_range(line);
        self.layout
            .borrow_mut()
            .line(line)
            .locate(
                self.text.slice(range.clone()),
                Target::Character(position.min(range.end) - range.start),
            )
            .column
    }

    pub fn position_at_column(&self, line: usize, column: usize, nearest: bool) -> usize {
        let line = line.min(self.line_count() - 1);
        let range = self.line_range(line);
        let text = self.text.slice(range.clone());
        let point = self
            .layout
            .borrow_mut()
            .line(line)
            .locate(text, Target::Column(column));
        if nearest && point.column < column && point.byte < text.len_bytes() {
            let next = Walker::new(text, point.byte).next(point);
            if column - point.column >= (next.column - point.column).div_ceil(2) {
                return range.start + next.character;
            }
        }
        range.start + point.character
    }

    /// Copy only complete graphemes intersecting the requested cell viewport.
    pub fn line_window(&self, line: usize, left: usize, width: usize) -> LineWindow {
        let line = line.min(self.line_count() - 1);
        let text = self.text.slice(self.line_range(line));
        let mut cache = self.layout.borrow_mut();
        let line = cache.line(line);
        let start = line.locate(text, Target::Column(left));
        if width == 0 {
            return LineWindow {
                text: String::new(),
                character: start.character,
                utf16: start.utf16,
                column: start.column,
            };
        }
        let right = left.saturating_add(width);
        let mut end = line.locate(text, Target::Column(right));
        if end.column < right && end.byte < text.len_bytes() {
            end = Walker::new(text, end.byte).next(end);
        }
        LineWindow {
            text: text.byte_slice(start.byte..end.byte).to_string(),
            character: start.character,
            utf16: start.utf16,
            column: start.column,
        }
    }

    pub fn next_grapheme(&self, position: usize) -> usize {
        self.grapheme_boundary(position, true)
    }
    pub(crate) fn is_grapheme_boundary(&self, position: usize) -> bool {
        position == 0
            || position == self.len_chars()
            || self.next_grapheme(self.previous_grapheme(position)) == position
    }
    pub fn previous_grapheme(&self, position: usize) -> usize {
        self.grapheme_boundary(position, false)
    }
    fn grapheme_boundary(&self, position: usize, forward: bool) -> usize {
        let byte = self.text.char_to_byte(position.min(self.len_chars()));
        let mut walker = Walker::new(self.text.slice(..), byte);
        walker
            .boundary(forward)
            .map_or(if forward { self.len_chars() } else { 0 }, |at| {
                self.text.byte_to_char(at)
            })
    }
}
