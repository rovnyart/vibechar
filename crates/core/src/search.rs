//! Local, revision-bound find/replace. Source snapshots and parsing stay off input threads.
use crate::{Document, TextEdit};
use regex::{Captures, Regex, RegexBuilder};
use ropey::Rope;
use serde::Serialize;
use std::{
    ops::Range,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Condvar, Mutex,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};
use unicode_segmentation::UnicodeSegmentation;

pub const MAX_SOURCE: usize = crate::limits::SEARCH_BYTES;
pub const MAX_MATCHES: usize = 10_000;
pub const MAX_QUERY: usize = 1024;
pub const MAX_REPLACEMENT: usize = 64 * 1024;
const MAX_OUTPUT: usize = 8 * 1024 * 1024;

#[derive(Clone, PartialEq, Eq, Default)]
pub struct Query {
    pub needle: String,
    pub replacement: Option<String>,
    pub regex: bool,
    pub case_sensitive: bool,
    pub whole_graphemes: bool,
    pub whole_words: bool,
}
#[derive(Serialize, Clone, Debug)]
pub struct Hit {
    pub start: usize,
    pub end: usize,
    pub utf16_start: usize,
    pub utf16_length: usize,
}
#[derive(Serialize)]
pub struct Example {
    pub before: String,
    pub after: String,
}
#[derive(Serialize)]
pub struct Frame {
    pub serial: u64,
    pub document: u64,
    pub revision: u64,
    pub matches: Vec<Hit>,
    pub changed: usize,
    pub limited: bool,
    pub error: Option<String>,
    pub examples: Vec<Example>,
    #[serde(skip)]
    pub encoded: Vec<u8>,
    #[serde(skip)]
    edits: Option<Vec<TextEdit>>,
    #[serde(skip)]
    request: u64,
}
#[derive(Clone, PartialEq, Eq)]
struct Key {
    document: u64,
    revision: u64,
    query: Query,
}
struct Request {
    key: Key,
    text: Rope,
    token: u64,
}
struct Shared {
    pending: Mutex<Option<Request>>,
    ready: Mutex<Option<Arc<Frame>>>,
    wake: Condvar,
    wanted: AtomicU64,
    stop: AtomicBool,
}
pub struct Engine {
    shared: Arc<Shared>,
    key: Option<Key>,
    worker: Option<JoinHandle<()>>,
}
impl Engine {
    pub fn new() -> std::io::Result<Self> {
        let shared = Arc::new(Shared {
            pending: Mutex::new(None),
            ready: Mutex::new(None),
            wake: Condvar::new(),
            wanted: AtomicU64::new(0),
            stop: AtomicBool::new(false),
        });
        let state = shared.clone();
        let worker = thread::Builder::new()
            .name("vibechar-find".into())
            .spawn(move || {
                let mut compiled = None;
                loop {
                    let mut pending = state.pending.lock().unwrap();
                    while pending.is_none() && !state.stop.load(Ordering::Acquire) {
                        pending = state.wake.wait(pending).unwrap();
                    }
                    if state.stop.load(Ordering::Acquire) {
                        break;
                    }
                    let request = pending.take().unwrap();
                    drop(pending);
                    if let Some(mut frame) = scan(&request, &state, &mut compiled) {
                        if state.wanted.load(Ordering::Acquire) == request.token {
                            frame.serial = request.token;
                            frame.encoded = serde_json::to_vec(&frame).unwrap_or_default();
                            *state.ready.lock().unwrap() = Some(Arc::new(frame));
                        }
                    }
                }
            })?;
        Ok(Self {
            shared,
            key: None,
            worker: Some(worker),
        })
    }
    pub fn submit(&mut self, document: &Document, query: Query) {
        let key = Key {
            document: document.id(),
            revision: document.revision(),
            query,
        };
        if self.key.as_ref() == Some(&key) {
            return;
        }
        let token = self.shared.wanted.fetch_add(1, Ordering::AcqRel) + 1;
        *self.shared.ready.lock().unwrap() = None;
        *self.shared.pending.lock().unwrap() = Some(Request {
            key: key.clone(),
            text: document.checkpoint_text(),
            token,
        });
        self.key = Some(key);
        self.shared.wake.notify_one();
    }
    pub fn busy(&self) -> bool {
        self.key.is_some() && self.current().is_none()
    }
    pub fn clear(&mut self) {
        self.shared.wanted.fetch_add(1, Ordering::AcqRel);
        self.shared.pending.lock().unwrap().take();
        self.shared.ready.lock().unwrap().take();
        self.key = None;
    }
    fn current(&self) -> Option<Arc<Frame>> {
        let frame = self.shared.ready.lock().ok()?.clone()?;
        (frame.request == self.shared.wanted.load(Ordering::Acquire)).then_some(frame)
    }
    pub fn frame(&self, document: &Document, after: u64) -> Option<Arc<Frame>> {
        let frame = self.current()?;
        (frame.document == document.id()
            && frame.revision == document.revision()
            && frame.serial > after)
            .then_some(frame)
    }
    pub fn apply(
        &self,
        document: &mut Document,
        serial: u64,
        index: Option<usize>,
    ) -> Result<(bool, Range<usize>), &'static str> {
        let frame = self
            .frame(document, 0)
            .ok_or("Text changed · refresh the preview")?;
        if frame.serial != serial || frame.error.is_some() || frame.limited {
            return Err("Preview is no longer available");
        }
        let edits = frame.edits.as_ref().ok_or("Open Replace first")?;
        let chosen = if let Some(index) = index {
            std::slice::from_ref(edits.get(index).ok_or("No match selected")?)
        } else {
            edits.as_slice()
        };
        let first = chosen.first().ok_or("No matches")?;
        let range = first.range.start..first.range.start + first.text.chars().count();
        document
            .replace_many(chosen)
            .map(|changed| (changed, range))
            .map_err(|_| "Text changed · refresh the preview")
    }
}
impl Drop for Engine {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
        self.shared.wanted.fetch_add(1, Ordering::AcqRel);
        self.shared.pending.lock().unwrap().take();
        self.shared.wake.notify_one();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

enum Part {
    Literal(String),
    Group(usize),
}
fn replacement_parts(text: &str, regex: Option<&Regex>) -> Result<Vec<Part>, &'static str> {
    let Some(regex) = regex else {
        return Ok(vec![Part::Literal(text.into())]);
    };
    let names: Vec<_> = regex.capture_names().collect();
    let mut parts = Vec::new();
    let mut literal = String::new();
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '$' {
            literal.push(ch);
            continue;
        }
        if chars.peek() == Some(&'$') {
            chars.next();
            literal.push('$');
            continue;
        }
        let braced = chars.peek() == Some(&'{');
        if braced {
            chars.next();
        }
        let mut name = String::new();
        while chars
            .peek()
            .is_some_and(|c| c.is_ascii_alphanumeric() || *c == '_')
        {
            name.push(chars.next().unwrap());
        }
        if braced && chars.next() != Some('}') {
            return Err("Replacement has an unclosed ${group}");
        }
        if name.is_empty() {
            if braced {
                return Err("Replacement group is empty");
            }
            literal.push('$');
            continue;
        }
        let index = name
            .parse::<usize>()
            .ok()
            .filter(|&i| i < names.len())
            .or_else(|| names.iter().position(|&n| n == Some(name.as_str())))
            .ok_or("Unknown replacement group · use $1 or ${name}")?;
        if !literal.is_empty() {
            parts.push(Part::Literal(std::mem::take(&mut literal)));
        }
        parts.push(Part::Group(index));
    }
    if !literal.is_empty() {
        parts.push(Part::Literal(literal));
    }
    Ok(parts)
}
fn expanded(parts: &[Part], captures: &Captures<'_>) -> Result<String, &'static str> {
    let mut text = String::new();
    for part in parts {
        let value = match part {
            Part::Literal(s) => s.as_str(),
            Part::Group(i) => captures.get(*i).map_or("", |m| m.as_str()),
        };
        if text.len() + value.len() > MAX_OUTPUT {
            return Err("Replacement output exceeds 8 MiB");
        }
        text.push_str(value);
    }
    Ok(text)
}
fn sample(text: &str) -> String {
    let mut result = String::new();
    for ch in text.chars().take(120) {
        match ch {
            '\n' => result.push('↵'),
            '\r' => result.push('␍'),
            '\t' => result.push('⇥'),
            c if c.is_control() => result.push('�'),
            c => result.push(c),
        }
    }
    if text.chars().nth(120).is_some() {
        result.push('…');
    }
    if result.is_empty() {
        result.push('∅');
    }
    result
}
type Compiled = Option<(String, bool, bool, Regex)>;
fn scan(request: &Request, shared: &Shared, compiled: &mut Compiled) -> Option<Frame> {
    let query = &request.key.query;
    let mut frame = Frame {
        serial: 0,
        document: request.key.document,
        revision: request.key.revision,
        matches: Vec::new(),
        changed: 0,
        limited: false,
        error: None,
        examples: Vec::new(),
        encoded: Vec::new(),
        edits: query.replacement.as_ref().map(|_| Vec::new()),
        request: request.token,
    };
    let result = (|| -> Result<(), &'static str> {
        if request.text.len_bytes() > MAX_SOURCE {
            return Err("Search is limited to 4 MiB documents");
        }
        if query.needle.len() > MAX_QUERY {
            return Err("Find text exceeds 1 KiB");
        }
        if query
            .replacement
            .as_ref()
            .is_some_and(|r| r.len() > MAX_REPLACEMENT)
        {
            return Err("Replacement exceeds 64 KiB");
        }
        if query.needle.is_empty() {
            return Ok(());
        }
        if !compiled.as_ref().is_some_and(|(n, r, c, _)| {
            n == &query.needle && *r == query.regex && *c == query.case_sensitive
        }) {
            let pattern = if query.regex {
                query.needle.clone()
            } else {
                regex::escape(&query.needle)
            };
            let re = RegexBuilder::new(&pattern)
                .case_insensitive(!query.case_sensitive)
                .multi_line(true)
                .crlf(true)
                .size_limit(1024 * 1024)
                .dfa_size_limit(1024 * 1024)
                .nest_limit(64)
                .build()
                .map_err(|_| "Invalid or too complex regex · check the pattern")?;
            *compiled = Some((query.needle.clone(), query.regex, query.case_sensitive, re));
        }
        let regex = &compiled.as_ref().unwrap().3;
        let parts = query
            .replacement
            .as_ref()
            .map(|r| replacement_parts(r, query.regex.then_some(regex)))
            .transpose()?;
        let source = request.text.to_string();
        let started = Instant::now();
        let mut output_bytes = source.len();
        let mut boundaries = source
            .grapheme_indices(true)
            .map(|(i, _)| i)
            .chain(std::iter::once(source.len()))
            .peekable();
        let mut words = source
            .unicode_word_indices()
            .map(|(start, word)| start..start + word.len())
            .peekable();
        for captures in regex.captures_iter(&source) {
            if shared.stop.load(Ordering::Acquire)
                || shared.wanted.load(Ordering::Acquire) != request.token
            {
                return Ok(());
            }
            if frame.matches.len() == MAX_MATCHES {
                frame.limited = true;
                break;
            }
            if started.elapsed() > Duration::from_secs(1) {
                return Err("Search budget exceeded · refine the pattern");
            }
            let found = captures.get(0).unwrap();
            if query.whole_words {
                while words.peek().is_some_and(|range| range.end <= found.start()) {
                    words.next();
                }
                if !words
                    .peek()
                    .is_some_and(|range| range.start == found.start() && range.end == found.end())
                {
                    continue;
                }
            }
            if query.whole_graphemes {
                while boundaries
                    .peek()
                    .is_some_and(|offset| *offset < found.start())
                {
                    boundaries.next();
                }
                let start_ok = boundaries.peek() == Some(&found.start());
                while boundaries
                    .peek()
                    .is_some_and(|offset| *offset < found.end())
                {
                    boundaries.next();
                }
                if !start_ok || boundaries.peek() != Some(&found.end()) {
                    continue;
                }
            }
            let start = request.text.byte_to_char(found.start());
            let end = request.text.byte_to_char(found.end());
            let utf16_start = request.text.char_to_utf16_cu(start);
            frame.matches.push(Hit {
                start,
                end,
                utf16_start,
                utf16_length: request.text.char_to_utf16_cu(end) - utf16_start,
            });
            if let Some(parts) = &parts {
                let text = expanded(parts, &captures)?;
                output_bytes = output_bytes
                    .saturating_sub(found.len())
                    .checked_add(text.len())
                    .ok_or("Replacement output exceeds 8 MiB")?;
                if output_bytes > MAX_OUTPUT {
                    return Err("Replacement output exceeds 8 MiB");
                }
                if text != found.as_str() {
                    frame.changed += 1;
                    if frame.examples.len() < 3 {
                        frame.examples.push(Example {
                            before: sample(found.as_str()),
                            after: sample(&text),
                        });
                    }
                }
                frame.edits.as_mut().unwrap().push(TextEdit {
                    range: start..end,
                    text,
                });
            }
        }
        Ok(())
    })();
    if let Err(error) = result {
        frame.error = Some(error.into());
        frame.edits = None;
    }
    if shared.stop.load(Ordering::Acquire) || shared.wanted.load(Ordering::Acquire) != request.token
    {
        None
    } else {
        Some(frame)
    }
}

#[cfg(test)]
#[path = "search_tests.rs"]
mod tests;
