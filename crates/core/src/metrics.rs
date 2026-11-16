//! Revision/selection-bound numerical statistics. Large scans never run on input.
use crate::Document;
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

const INLINE: usize = 4096;
#[cfg(test)]
#[path = "metrics_tests.rs"]
mod tests;
const MAX_BYTES: usize = crate::limits::METRICS_BYTES;

#[derive(Clone, Default, Debug, Serialize, PartialEq, Eq)]
pub struct Extent {
    pub bytes: usize,
    pub lines: usize,
    pub characters: Option<usize>,
    pub words: Option<usize>,
}
#[derive(Clone, Default, Debug, Serialize)]
pub struct Frame {
    pub large: bool,
    pub document: u64,
    pub revision: u64,
    pub serial: u64,
    pub total: Extent,
    pub selected: Extent,
    pub targets: usize,
    pub selections: usize,
    pub carets: usize,
    pub busy: bool,
    pub limited: bool,
}
struct Request {
    text: Rope,
    ranges: Vec<Range<usize>>,
    epoch: u64,
    frame: Frame,
}
#[derive(Default)]
struct Shared {
    pending: Mutex<Option<Request>>,
    wake: Condvar,
    done: Mutex<Option<Frame>>,
    total: Mutex<Option<(u64, Extent)>>,
    serial: AtomicU64,
    epoch: AtomicU64,
    stop: AtomicBool,
}
#[derive(Default)]
pub struct Engine {
    shared: Arc<Shared>,
    worker: Option<JoinHandle<()>>,
    current: Option<Frame>,
    ranges: Vec<Range<usize>>,
    epoch: u64,
}
impl Drop for Engine {
    fn drop(&mut self) {
        {
            let _pending = self.shared.pending.lock().unwrap();
            self.shared.stop.store(true, Ordering::Relaxed);
            self.shared.wake.notify_one();
        }
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
fn counted(text: ropey::RopeSlice<'_>, cancel: impl Fn() -> bool) -> Option<(usize, usize)> {
    if text.len_bytes() > MAX_BYTES {
        return None;
    }
    let start = Instant::now();
    crate::text::count_text(text, || {
        cancel() || start.elapsed() > Duration::from_millis(500)
    })
}
impl Engine {
    /// Repeated calls with the same version/ranges are free: no new work or scan.
    pub fn submit(&mut self, doc: &Document, ranges: &[Range<usize>]) {
        if self
            .current
            .as_ref()
            .is_some_and(|f| f.document == doc.id() && f.revision == doc.revision())
            && self.ranges == ranges
        {
            return;
        }
        let changed = self
            .current
            .as_ref()
            .is_none_or(|f| f.document != doc.id() || f.revision != doc.revision());
        if changed {
            self.epoch += 1;
            self.shared.epoch.store(self.epoch, Ordering::Relaxed);
        }
        let serial = self.shared.serial.fetch_add(1, Ordering::Relaxed) + 1;
        self.ranges = ranges.to_vec();
        let mut selected = ranges
            .iter()
            .filter(|r| r.start < r.end && r.end <= doc.len_chars())
            .cloned()
            .collect::<Vec<_>>();
        selected.sort_by_key(|r| r.start);
        let mut merged: Vec<Range<usize>> = Vec::new();
        for r in selected.iter().cloned() {
            if let Some(last) = merged.last_mut() {
                if r.start <= last.end {
                    last.end = last.end.max(r.end);
                    continue;
                }
            }
            merged.push(r);
        }
        let mut extent = Extent::default();
        let mut line_end = 0;
        for r in &merged {
            extent.bytes += doc.text.slice(r.clone()).len_bytes();
            let first = doc.line_index(r.start);
            let mut last = doc.line_index(r.end);
            if last > first && r.end == doc.line_start(last) {
                last -= 1;
            }
            extent.lines += (last + 1).saturating_sub(first.max(line_end));
            line_end = last + 1;
        }
        let mut frame = Frame {
            large: doc.is_large(),
            document: doc.id(),
            revision: doc.revision(),
            serial,
            total: Extent {
                bytes: doc.len_bytes(),
                lines: doc.line_count(),
                ..Extent::default()
            },
            selected: extent,
            targets: ranges.len(),
            selections: selected.len(),
            carets: ranges.iter().filter(|r| r.is_empty()).count(),
            busy: false,
            limited: false,
        };
        if let Some((epoch, total)) = &*self.shared.total.lock().unwrap() {
            if *epoch == self.epoch {
                frame.total = total.clone();
                frame.limited = total.characters.is_none();
            }
        }
        if frame.total.characters.is_none() && frame.total.bytes <= INLINE {
            if let Some((chars, words)) = counted(doc.text.slice(..), || false) {
                frame.total.characters = Some(chars);
                frame.total.words = Some(words);
            }
        }
        if frame.total.characters.is_some() {
            *self.shared.total.lock().unwrap() = Some((self.epoch, frame.total.clone()));
        }
        if frame.selected.bytes <= INLINE {
            let (mut chars, mut words) = (0, 0);
            let mut complete = true;
            for r in &merged {
                if let Some((c, w)) = counted(doc.text.slice(r.clone()), || false) {
                    chars += c;
                    words += w;
                } else {
                    complete = false;
                    break;
                }
            }
            if complete {
                frame.selected.characters = Some(chars);
                frame.selected.words = Some(words);
            }
        }
        if merged.len() == 1 && merged[0] == (0..doc.len_chars()) {
            frame.selected.characters = frame.total.characters;
            frame.selected.words = frame.total.words;
        }
        frame.busy = frame.total.characters.is_none() && !frame.limited
            || frame.selected.characters.is_none();
        self.current = Some(frame.clone());
        if !frame.busy {
            return;
        }
        if self.worker.is_none() {
            let shared = self.shared.clone();
            match thread::Builder::new()
                .name("vibechar-counts".into())
                .spawn(move || worker(shared))
            {
                Ok(worker) => self.worker = Some(worker),
                Err(_) => {
                    if let Some(frame) = &mut self.current {
                        frame.busy = false;
                        frame.limited = true;
                    }
                    return;
                }
            }
        }
        *self.shared.pending.lock().unwrap() = Some(Request {
            text: doc.checkpoint_text(),
            ranges: merged,
            epoch: self.epoch,
            frame,
        });
        self.shared.wake.notify_one();
    }
    pub fn frame(&self, doc: &Document) -> Option<Frame> {
        let mut frame = self.current.as_ref()?.clone();
        if frame.document != doc.id() || frame.revision != doc.revision() {
            return None;
        }
        if let Some(done) = self.shared.done.lock().unwrap().as_ref() {
            if done.serial == frame.serial {
                frame = done.clone();
            }
        }
        if let Some((epoch, total)) = self.shared.total.lock().unwrap().as_ref() {
            if *epoch == self.epoch {
                frame.total = total.clone();
            }
        }
        Some(frame)
    }
}
fn worker(shared: Arc<Shared>) {
    loop {
        let request = {
            let mut pending = shared.pending.lock().unwrap();
            while pending.is_none() && !shared.stop.load(Ordering::Relaxed) {
                pending = shared.wake.wait(pending).unwrap();
            }
            if shared.stop.load(Ordering::Relaxed) {
                return;
            }
            pending.take().unwrap()
        };
        let Request {
            text,
            ranges,
            epoch,
            mut frame,
        } = request;
        let stopped =
            || shared.stop.load(Ordering::Relaxed) || shared.epoch.load(Ordering::Relaxed) != epoch;
        if stopped() {
            continue;
        }
        let cached = shared.total.lock().unwrap().clone();
        if let Some((_, total)) = cached.filter(|(e, _)| *e == epoch) {
            frame.total = total;
        } else if frame.total.characters.is_none() {
            if let Some((chars, words)) = counted(text.slice(..), stopped) {
                frame.total.characters = Some(chars);
                frame.total.words = Some(words);
            } else {
                frame.limited = true;
            }
            if !stopped() {
                *shared.total.lock().unwrap() = Some((epoch, frame.total.clone()));
            }
        }
        let cancelled = || stopped() || shared.serial.load(Ordering::Relaxed) != frame.serial;
        if cancelled() {
            continue;
        }
        if ranges.len() == 1 && ranges[0] == (0..text.len_chars()) {
            frame.selected.characters = frame.total.characters;
            frame.selected.words = frame.total.words;
        }
        if frame.selected.characters.is_none() {
            let (mut chars, mut words) = (0, 0);
            let mut bytes = 0;
            let mut limited = false;
            let selection_start = Instant::now();
            for r in ranges {
                bytes += text.slice(r.clone()).len_bytes();
                if bytes > MAX_BYTES {
                    limited = true;
                    break;
                }
                if let Some((c, w)) = counted(text.slice(r), || {
                    cancelled() || selection_start.elapsed() > Duration::from_millis(500)
                }) {
                    chars += c;
                    words += w;
                } else {
                    limited = true;
                    break;
                }
            }
            if !limited {
                frame.selected.characters = Some(chars);
                frame.selected.words = Some(words);
            } else {
                frame.limited = true;
            }
        }
        if cancelled() {
            continue;
        }
        frame.limited |= frame.total.characters.is_none() || frame.selected.characters.is_none();
        frame.busy = false;
        *shared.done.lock().unwrap() = Some(frame);
    }
}

pub fn number(value: usize) -> String {
    let digits = value.to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}
pub fn bytes(value: usize) -> String {
    if value < 1024 {
        format!("{value} B")
    } else if value < 1024 * 1024 {
        format!("{:.1} KiB", value as f64 / 1024.0)
    } else {
        format!("{:.1} MiB", value as f64 / (1024.0 * 1024.0))
    }
}
pub fn compact(value: usize) -> String {
    if value >= 1_000_000 {
        format!("{:.1}M", value as f64 / 1_000_000.0)
    } else if value >= 1_000 {
        format!("{:.1}K", value as f64 / 1_000.0)
    } else {
        value.to_string()
    }
}
impl Frame {
    pub fn summary(&self, compact: bool) -> String {
        let chars = |e: &Extent| {
            e.characters
                .map(if compact { self::compact } else { number })
                .unwrap_or_else(|| {
                    if self.busy {
                        "…".into()
                    } else {
                        "—".into()
                    }
                })
        };
        if self.selections > 0 {
            let prefix = if self.targets > 1 {
                format!("{} selections · ", self.targets)
            } else {
                "1 selection · ".into()
            };
            if compact {
                format!("{} sel · {} ln", chars(&self.selected), self.selected.lines)
            } else {
                format!(
                    "{prefix}{} {} selected · {} {}",
                    chars(&self.selected),
                    if self.selected.characters == Some(1) {
                        "char"
                    } else {
                        "chars"
                    },
                    self.selected.lines,
                    if self.selected.lines == 1 {
                        "line"
                    } else {
                        "lines"
                    },
                )
            }
        } else if self.targets > 1 {
            format!("{} carets", self.carets)
        } else if compact {
            format!("{} ch · {} ln", chars(&self.total), self.total.lines)
        } else {
            format!(
                "{} chars · {} words · {} lines",
                chars(&self.total),
                self.total
                    .words
                    .map(number)
                    .unwrap_or_else(|| if self.busy { "…" } else { "—" }.into()),
                self.total.lines
            )
        }
    }
}
