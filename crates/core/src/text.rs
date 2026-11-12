//! Rope-local grapheme navigation and bounded, sparse logical-line geometry.
use crate::Document;
use ropey::RopeSlice;
use unicode_segmentation::{GraphemeCursor, GraphemeIncomplete};
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

impl Document {
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
