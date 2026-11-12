//! Local, lazy, revision-bound syntax detection and incremental background paint.
#[cfg(test)]
#[path = "syntax_tests.rs"]
mod tests;
use ropey::Rope;
use serde::Serialize;
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Condvar, Mutex, OnceLock,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};
use syntect::{
    easy::HighlightLines,
    highlighting::{Color, HighlightState, StyleModifier, Theme, ThemeItem},
    parsing::{ParseState, SyntaxReference, SyntaxSet},
};

const MAX_BYTES: usize = 512 * 1024;
const MAX_LINE: usize = 8192;
const MAX_LINES: usize = 10_000;
const MAX_SPANS: usize = 20_000;
const SLICE: Duration = Duration::from_millis(160);

fn syntaxes() -> &'static SyntaxSet {
    static SET: OnceLock<SyntaxSet> = OnceLock::new();
    SET.get_or_init(two_face::syntax::extra_newlines)
}

#[derive(Clone, Serialize)]
pub struct Choice {
    pub id: String,
    pub name: String,
    pub extensions: Vec<String>,
}

fn display(id: &str) -> &str {
    match id {
        "Plain Text" => "Text",
        "DotENV" => "Environment",
        "JavaScript (Babel)" => "JavaScript",
        "Bourne Again Shell (bash)" | "Bash" => "Shell",
        "TypescriptReact" => "TSX",
        _ => id,
    }
}

fn resolve(id: &str) -> Option<&'static SyntaxReference> {
    if id == "JSON Lines" {
        return syntaxes().find_syntax_by_extension("json");
    }
    syntaxes()
        .find_syntax_by_name(id)
        .or_else(|| syntaxes().find_syntax_by_token(id))
}
pub fn valid_mode(id: &str) -> bool {
    id.is_empty() || id == "Plain Text" || resolve(id).is_some()
}

pub fn choices(query: &str) -> Vec<Choice> {
    let query = query.trim().to_lowercase();
    let mut list = vec![Choice {
        id: String::new(),
        name: "Automatic".into(),
        extensions: vec!["auto".into()],
    }];
    list.extend(
        syntaxes()
            .syntaxes()
            .iter()
            .filter(|s| !s.hidden)
            .map(|s| Choice {
                id: s.name.clone(),
                name: display(&s.name).into(),
                extensions: s.file_extensions.clone(),
            }),
    );
    list.push(Choice {
        id: "JSON Lines".into(),
        name: "JSON Lines".into(),
        extensions: vec!["jsonl".into(), "ndjson".into()],
    });
    let common = [
        "",
        "Plain Text",
        "JSON",
        "TypeScript",
        "Python",
        "SQL",
        "Markdown",
        "Rust",
    ];
    let mut ranked: Vec<_> = list
        .into_iter()
        .filter_map(|choice| {
            let name = choice.name.to_lowercase();
            let id = choice.id.to_lowercase();
            let score = if query.is_empty() {
                100 + common.iter().position(|&s| s == choice.id).unwrap_or(100)
            } else if name == query
                || id == query
                || choice
                    .extensions
                    .iter()
                    .any(|s| s.eq_ignore_ascii_case(&query))
            {
                0
            } else if name.starts_with(&query) || id.starts_with(&query) {
                1
            } else if name.contains(&query) || id.contains(&query) {
                2
            } else {
                return None;
            };
            Some((score, choice))
        })
        .collect();
    ranked.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.name.cmp(&b.1.name)));
    ranked
        .into_iter()
        .take(7)
        .map(|(_, choice)| choice)
        .collect()
}

pub fn syntax_count() -> usize {
    syntaxes().syntaxes().iter().filter(|s| !s.hidden).count()
}
pub fn licenses() -> String {
    two_face::acknowledgement::listing().to_md()
}

#[derive(Clone, Serialize, Debug)]
pub struct Span {
    pub start: usize,
    pub length: usize,
    pub role: u8,
}
pub struct LinePaint {
    pub hash: u64,
    pub spans: Vec<Span>,
    units: usize,
}
pub fn line_hash(text: &str) -> u64 {
    text.trim_end_matches([
        '\r', '\n', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}',
    ])
    .bytes()
    .fold(0xcbf29ce484222325, |hash, byte| {
        (hash ^ byte as u64).wrapping_mul(0x100000001b3)
    })
}

#[derive(Serialize)]
pub struct Frame {
    pub serial: u64,
    pub document: u64,
    pub revision: u64,
    pub language: String,
    pub syntax: String,
    pub reason: String,
    pub automatic: bool,
    pub complete: bool,
    pub limited: bool,
    pub spans: Vec<Span>,
    #[serde(skip)]
    pub lines: Vec<Arc<LinePaint>>,
    #[serde(skip)]
    pub encoded: Vec<u8>,
    #[serde(skip)]
    request: u64,
}

#[derive(Clone, PartialEq, Eq)]
struct Key {
    document: u64,
    revision: u64,
    path: Option<PathBuf>,
    mode: Option<String>,
}
struct Request {
    token: u64,
    key: Key,
    text: Rope,
}
struct Shared {
    pending: Mutex<Option<Request>>,
    ready: Mutex<Option<Arc<Frame>>>,
    wake: Condvar,
    wanted: AtomicU64,
    serial: AtomicU64,
    stop: AtomicBool,
}
pub struct Engine {
    shared: Arc<Shared>,
    key: Option<Key>,
    next: u64,
    worker: Option<JoinHandle<()>>,
}
impl Engine {
    pub fn new() -> std::io::Result<Self> {
        let shared = Arc::new(Shared {
            pending: Mutex::new(None),
            ready: Mutex::new(None),
            wake: Condvar::new(),
            wanted: AtomicU64::new(0),
            serial: AtomicU64::new(0),
            stop: AtomicBool::new(false),
        });
        let state = shared.clone();
        let worker = thread::Builder::new()
            .name("vibechar-syntax".into())
            .spawn(move || {
                let mut cache = None;
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
                    loop {
                        let Some(mut frame) = paint(&request, &mut cache, &state) else {
                            cache = None;
                            break;
                        };
                        if state.wanted.load(Ordering::Acquire) != request.token {
                            cache = None;
                            break;
                        }
                        let complete = frame.complete;
                        frame.serial = state.serial.fetch_add(1, Ordering::Relaxed) + 1;
                        frame.encoded = serde_json::to_vec(&frame).unwrap_or_default();
                        *state.ready.lock().unwrap() = Some(Arc::new(frame));
                        if complete {
                            break;
                        }
                    }
                }
            })?;
        Ok(Self {
            shared,
            key: None,
            next: 0,
            worker: Some(worker),
        })
    }
    pub fn submit(
        &mut self,
        document: u64,
        revision: u64,
        text: Rope,
        path: Option<PathBuf>,
        mode: Option<String>,
    ) {
        let key = Key {
            document,
            revision,
            path,
            mode,
        };
        if self.key.as_ref() == Some(&key) {
            return;
        }
        self.next += 1;
        self.shared.wanted.store(self.next, Ordering::Release);
        *self.shared.pending.lock().unwrap() = Some(Request {
            token: self.next,
            key: key.clone(),
            text,
        });
        self.key = Some(key);
        self.shared.wake.notify_one();
    }
    pub fn frame(&self, after: u64) -> Option<Arc<Frame>> {
        let frame = self.shared.ready.lock().ok()?.clone()?;
        (frame.request == self.shared.wanted.load(Ordering::Acquire) && frame.serial > after)
            .then_some(frame)
    }
    pub fn matches(
        &self,
        document: u64,
        revision: u64,
        path: Option<&std::path::Path>,
        mode: Option<&str>,
    ) -> bool {
        self.key.as_ref().is_some_and(|key| {
            key.document == document
                && key.revision == revision
                && key.path.as_deref() == path
                && key.mode.as_deref() == mode
        })
    }
    pub fn busy(&self) -> bool {
        self.key.is_some() && self.frame(0).is_none_or(|frame| !frame.complete)
    }
}
impl Drop for Engine {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
        self.shared.wanted.fetch_add(1, Ordering::Release);
        self.shared.pending.lock().unwrap().take();
        self.shared.wake.notify_one();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

struct Detection {
    syntax: Option<&'static SyntaxReference>,
    name: String,
    reason: String,
}
fn picked(token: &str, reason: &str) -> Detection {
    if token == "Plain Text" {
        return Detection {
            syntax: None,
            name: "Text".into(),
            reason: reason.into(),
        };
    }
    let syntax = resolve(token);
    Detection {
        syntax,
        name: if token == "JSON Lines" {
            token.into()
        } else {
            syntax.map_or("Text", |s| display(&s.name)).into()
        },
        reason: reason.into(),
    }
}
fn structured_json(text: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(text).is_ok_and(|v| v.is_object() || v.is_array())
}
fn pair(line: &str, separator: char) -> bool {
    line.trim()
        .split_once(separator)
        .is_some_and(|(key, value)| {
            !value.trim().is_empty()
                && !key.is_empty()
                && key.len() <= 64
                && key
                    .trim()
                    .chars()
                    .all(|c| c.is_alphanumeric() || "_-.\"'".contains(c))
        })
}
fn detect(request: &Request) -> Detection {
    if let Some(mode) = &request.key.mode {
        return picked(mode, "Pinned for this tab");
    }
    if let Some(path) = &request.key.path {
        let name = path.file_name().unwrap_or_default().to_string_lossy();
        if name.ends_with(".jsonl") || name.ends_with(".ndjson") {
            return picked("JSON Lines", "File extension");
        }
        if name == ".env" || name.starts_with(".env.") {
            return picked("DotENV", "File name");
        }
        if !matches!(
            path.extension().and_then(|s| s.to_str()),
            Some("txt" | "log")
        ) {
            if let Some(syntax) = syntaxes().find_syntax_by_extension(&name).or_else(|| {
                path.extension()
                    .and_then(|e| e.to_str())
                    .and_then(|e| syntaxes().find_syntax_by_extension(e))
            }) {
                if syntax.name != "Plain Text" {
                    return Detection {
                        syntax: Some(syntax),
                        name: display(&syntax.name).into(),
                        reason: "File extension".into(),
                    };
                }
            }
        }
    }
    let sample: String = request.text.chars().take(8192).collect();
    let text = sample.trim();
    if text.starts_with("#!") {
        if let Some(syntax) =
            syntaxes().find_syntax_by_first_line(text.lines().next().unwrap_or(""))
        {
            return Detection {
                syntax: Some(syntax),
                name: display(&syntax.name).into(),
                reason: "Shebang".into(),
            };
        }
    }
    let lines: Vec<_> = text
        .lines()
        .filter(|line| !line.trim().is_empty() && !line.trim().starts_with('#'))
        .take(80)
        .collect();
    if lines.len() > 1 && lines.iter().take(6).all(|line| structured_json(line)) {
        return picked("JSON Lines", "One JSON record per line");
    }
    if (text.starts_with('{') || text.starts_with('['))
        && (structured_json(text) || (text.contains("\":") && !text.contains("=>")))
    {
        return picked("json", "JSON structure");
    }
    let env = lines
        .iter()
        .filter(|line| {
            pair(
                line.trim().strip_prefix("export ").unwrap_or(line.trim()),
                '=',
            )
        })
        .count();
    if env > 0
        && env == lines.len()
        && (env > 1
            || lines[0]
                .split('=')
                .next()
                .unwrap_or("")
                .chars()
                .all(|c| c.is_ascii_uppercase() || c == '_'))
    {
        return picked("DotENV", "KEY=value pairs");
    }
    if lines
        .iter()
        .any(|s| s.trim().starts_with('[') && s.trim().ends_with(']'))
        && env > 0
    {
        return picked("toml", "TOML tables");
    }
    if lines.iter().filter(|line| pair(line, ':')).count() >= 2 && !text.contains('{') {
        return picked("yaml", "YAML keys");
    }
    let upper = text.to_ascii_uppercase();
    if [
        "SELECT ",
        "WITH ",
        "INSERT ",
        "UPDATE ",
        "CREATE TABLE",
        "DELETE FROM",
        "ALTER TABLE",
    ]
    .iter()
    .any(|s| upper.starts_with(s))
        && (upper.contains(" FROM ")
            || upper.contains("\nFROM ")
            || upper.contains(" SET ")
            || upper.contains(" VALUES")
            || text.ends_with(';'))
    {
        return picked("sql", "SQL statement");
    }
    if ["curl ", "docker ", "npm ", "git ", "sudo "]
        .iter()
        .any(|s| text.starts_with(s))
        || text.contains(" | jq")
    {
        return picked("sh", "Shell command");
    }
    if text.contains("fn ")
        && text.contains('(')
        && (text.contains("pub ")
            || text.contains("let mut ")
            || text.contains("->")
            || text.contains("println!"))
    {
        return picked("rs", "Rust declarations");
    }
    if text.contains("import Foundation")
        || text.contains("import AppKit")
        || (text.contains("func ") && text.contains("let "))
    {
        return picked("swift", "Swift declarations");
    }
    if lines
        .iter()
        .any(|s| s.trim().starts_with("def ") && s.trim().ends_with(':'))
        || text.starts_with("from ") && text.contains(" import ")
        || text.starts_with("import ")
            && text.contains('\n')
            && !text.contains(';')
            && !text.contains(" from ")
    {
        return picked("py", "Python declarations");
    }
    if text.contains("interface ")
        || text.starts_with("type ") && text.contains('=')
        || text.contains(": string")
        || text.contains(": number")
    {
        return picked("ts", "TypeScript types");
    }
    if ["const ", "let ", "var ", "function ", "export "]
        .iter()
        .any(|s| text.starts_with(s))
        && (text.contains('=') || text.contains('('))
        || text.starts_with("import ") && text.contains(" from ")
    {
        return picked("js", "JavaScript declarations");
    }
    if text.starts_with("<!DOCTYPE") || text.starts_with("<html") {
        return picked("html", "HTML document");
    }
    if text.starts_with("<?xml") || text.starts_with('<') && text.contains("</") {
        return picked("xml", "XML tags");
    }
    if text.starts_with("# ")
        || text.starts_with("## ")
        || text.contains("\n```")
        || text.contains("](")
    {
        return picked("md", "Markdown structure");
    }
    picked("Plain Text", "No strong language signal")
}

fn theme() -> &'static Theme {
    static THEME: OnceLock<Theme> = OnceLock::new();
    THEME.get_or_init(|| {
        let mut theme = Theme::default();
        theme.settings.foreground = Some(Color {
            r: 0,
            g: 0,
            b: 0,
            a: 255,
        });
        for (role, scopes) in [
            (1, "keyword, storage"),
            (2, "string"),
            (3, "constant.numeric, constant.language"),
            (4, "comment"),
            (5, "entity.name.type, support.type, support.class"),
            (6, "entity.name.function, support.function"),
            (
                7,
                "meta.mapping.key string, meta.object-literal.key, entity.name.tag",
            ),
            (8, "markup.heading"),
            (9, "markup.underline.link, markup.link"),
            (10, "punctuation"),
        ] {
            theme.scopes.push(ThemeItem {
                scope: scopes.parse().unwrap(),
                style: StyleModifier {
                    foreground: Some(Color {
                        r: role,
                        g: 0,
                        b: 0,
                        a: 255,
                    }),
                    ..Default::default()
                },
            });
        }
        theme
    })
}
#[derive(Clone)]
struct Anchor {
    line: usize,
    highlight: HighlightState,
    parse: ParseState,
}
struct Cache {
    document: u64,
    syntax: String,
    text: Rope,
    lines: Vec<Arc<LinePaint>>,
    anchors: Vec<Anchor>,
}

fn paint(request: &Request, cache: &mut Option<Cache>, shared: &Shared) -> Option<Frame> {
    let detection = detect(request);
    let mut frame = Frame {
        serial: 0,
        document: request.key.document,
        revision: request.key.revision,
        language: detection.name,
        syntax: detection
            .syntax
            .map_or("Plain Text", |s| s.name.as_str())
            .into(),
        reason: detection.reason,
        automatic: request.key.mode.is_none(),
        complete: true,
        limited: false,
        spans: Vec::new(),
        lines: Vec::new(),
        encoded: Vec::new(),
        request: request.token,
    };
    if request.text.len_bytes() > MAX_BYTES
        || request.text.len_lines() > MAX_LINES
        || request.text.lines().any(|line| line.len_bytes() > MAX_LINE)
    {
        frame.limited = true;
        *cache = None;
        return Some(frame);
    }
    let Some(syntax) = detection.syntax else {
        *cache = None;
        return Some(frame);
    };
    let reusable = cache
        .as_ref()
        .is_some_and(|c| c.document == request.key.document && c.syntax == syntax.name);
    if !reusable {
        *cache = Some(Cache {
            document: request.key.document,
            syntax: syntax.name.clone(),
            text: request.text.clone(),
            lines: Vec::new(),
            anchors: Vec::new(),
        });
    }
    let cache = cache.as_mut().unwrap();
    let changed = cache
        .text
        .lines()
        .zip(request.text.lines())
        .take(cache.lines.len())
        .take_while(|(old, new)| old == new)
        .count();
    let anchor = cache
        .anchors
        .iter()
        .rev()
        .find(|a| a.line <= changed)
        .cloned();
    let start = anchor.as_ref().map_or(0, |a| a.line);
    let mut highlighter = anchor.map_or_else(
        || HighlightLines::new(syntax, theme()),
        |a| HighlightLines::from_state(theme(), a.highlight, a.parse),
    );
    cache.lines.truncate(start);
    cache.anchors.retain(|a| a.line <= start);
    cache.text = request.text.clone();
    let started = Instant::now();
    let mut count: usize = cache.lines.iter().map(|line| line.spans.len()).sum();
    for index in start..request.text.len_lines() {
        if shared.wanted.load(Ordering::Acquire) != request.token
            || shared.stop.load(Ordering::Acquire)
        {
            return None;
        }
        let text = request.text.line(index).to_string();
        let mut offset = 0;
        let mut spans: Vec<Span> = Vec::new();
        let Ok(ranges) = highlighter.highlight_line(&text, syntaxes()) else {
            frame.limited = true;
            break;
        };
        for (style, value) in ranges {
            let length = value.encode_utf16().count();
            if style.foreground.r > 0 && length > 0 {
                if let Some(last) = spans
                    .last_mut()
                    .filter(|s| s.role == style.foreground.r && s.start + s.length == offset)
                {
                    last.length += length;
                } else {
                    spans.push(Span {
                        start: offset,
                        length,
                        role: style.foreground.r,
                    });
                }
            }
            offset += length;
        }
        count += spans.len();
        if count > MAX_SPANS {
            frame.limited = true;
            break;
        }
        cache.lines.push(Arc::new(LinePaint {
            hash: line_hash(&text),
            spans,
            units: offset,
        }));
        if (index + 1) % 32 == 0 {
            let (highlight, parse) = highlighter.state();
            cache.anchors.push(Anchor {
                line: index + 1,
                highlight: highlight.clone(),
                parse: parse.clone(),
            });
            highlighter = HighlightLines::from_state(theme(), highlight, parse);
        }
        if started.elapsed() >= SLICE && index + 1 < request.text.len_lines() {
            let (highlight, parse) = highlighter.state();
            cache.anchors.push(Anchor {
                line: index + 1,
                highlight,
                parse,
            });
            frame.complete = false;
            break;
        }
    }
    let mut offset = 0;
    for line in &cache.lines {
        frame.spans.extend(line.spans.iter().map(|span| Span {
            start: span.start + offset,
            length: span.length,
            role: span.role,
        }));
        offset += line.units;
    }
    frame.lines.clone_from(&cache.lines);
    Some(frame)
}
