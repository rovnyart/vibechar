//! Bounded local text commands, shared by both clients. No text leaves this process.
use crate::{Document, TextEdit};
use serde::Serialize;
use std::{collections::HashSet, ops::Range, sync::mpsc, thread};

pub const MAX_SOURCE: usize = 1024 * 1024;
const MAX_OUTPUT: usize = 2 * 1024 * 1024;

#[derive(Clone, Copy, Serialize)]
pub struct Command {
    pub id: u32,
    pub title: &'static str,
    pub detail: &'static str,
    pub keywords: &'static str,
}
pub const COMMANDS: [Command; 9] = [
    Command {
        id: 1,
        title: "Format JSON",
        detail: "Readable JSON · 2-space indent",
        keywords: "pretty beautify json indent",
    },
    Command {
        id: 2,
        title: "Minify JSON",
        detail: "Compact JSON · preserve every value",
        keywords: "compact compress json",
    },
    Command {
        id: 3,
        title: "Sort lines",
        detail: "Ascending · case-sensitive Unicode order",
        keywords: "sort order lines ascending",
    },
    Command {
        id: 4,
        title: "Remove duplicate lines",
        detail: "Keep the first occurrence · exact matches",
        keywords: "unique dedupe duplicates lines",
    },
    Command {
        id: 5,
        title: "Trim trailing whitespace",
        detail: "Remove spaces and tabs at line ends",
        keywords: "clean trim trailing whitespace spaces tabs",
    },
    Command {
        id: 6,
        title: "Uppercase",
        detail: "Unicode uppercase · preserve whitespace",
        keywords: "upper case caps capital letters регистр верхний",
    },
    Command {
        id: 7,
        title: "Lowercase",
        detail: "Unicode lowercase · preserve whitespace",
        keywords: "lower case small letters регистр нижний",
    },
    Command {
        id: 8,
        title: "URL encode",
        detail: "Encode a URL component · UTF-8 → %HH",
        keywords: "url encode percent escape uri кодировать",
    },
    Command {
        id: 9,
        title: "URL decode",
        detail: "Decode %HH once · + stays +",
        keywords: "url decode percent unescape uri декодировать",
    },
];
pub fn choices(query: &str) -> Vec<Command> {
    let query = query.to_lowercase();
    COMMANDS
        .into_iter()
        .filter(|command| {
            let haystack = format!("{} {}", command.title, command.keywords).to_lowercase();
            query.split_whitespace().all(|word| haystack.contains(word))
        })
        .collect()
}

pub struct Plan {
    document: u64,
    revision: u64,
    range: Range<usize>,
    text: String,
}
impl Plan {
    pub fn apply(&self, document: &mut Document) -> Result<(bool, Range<usize>), String> {
        if document.id() != self.document || document.revision() != self.revision {
            return Err("Text changed · run the command again".into());
        }
        let changed = document
            .replace_many(&[TextEdit {
                range: self.range.clone(),
                text: self.text.clone(),
            }])
            .map_err(|_| "Text range is no longer available")?;
        Ok((
            changed,
            self.range.start..self.range.start + self.text.chars().count(),
        ))
    }
}

/// One bounded job per explicit command. Dropping it discards the result without blocking input.
pub struct Job {
    receiver: mpsc::Receiver<Result<Plan, String>>,
    result: Option<Result<Plan, String>>,
}
impl Job {
    pub fn start(document: &Document, range: Range<usize>, command: u32) -> Result<Self, String> {
        if !COMMANDS.iter().any(|c| c.id == command) {
            return Err("Unknown command".into());
        }
        if range.start > range.end || range.end > document.len_chars() {
            return Err("Invalid text range".into());
        }
        let text = document.checkpoint_text();
        if text.slice(range.clone()).len_bytes() > MAX_SOURCE {
            return Err("Select up to 1 MiB to use text tools".into());
        }
        let id = document.id();
        let revision = document.revision();
        let newline = document.newline();
        let (sender, receiver) = mpsc::sync_channel(1);
        thread::Builder::new()
            .name("vibechar-tool".into())
            .spawn(move || {
                let source = text.slice(range.clone()).to_string();
                let result = transform(&source, command, newline).map(|text| Plan {
                    document: id,
                    revision,
                    range,
                    text,
                });
                let _ = sender.send(result);
            })
            .map_err(|_| "Could not start text tool")?;
        Ok(Self {
            receiver,
            result: None,
        })
    }
    pub fn poll(&mut self) -> Option<&Result<Plan, String>> {
        if self.result.is_none() {
            match self.receiver.try_recv() {
                Ok(result) => self.result = Some(result),
                Err(mpsc::TryRecvError::Disconnected) => {
                    self.result = Some(Err("Text tool stopped".into()))
                }
                Err(mpsc::TryRecvError::Empty) => {}
            }
        }
        self.result.as_ref()
    }
}

fn transform(source: &str, command: u32, newline: &str) -> Result<String, String> {
    if command <= 2 {
        return json(source, command == 1, newline);
    }
    if command >= 6 {
        let output = match command {
            6 => source.to_uppercase(),
            7 => source.to_lowercase(),
            8 => encode_component(source)?,
            9 => decode_component(source)?,
            _ => return Err("Unknown command".into()),
        };
        return if output.len() > MAX_OUTPUT {
            Err("Result exceeds 2 MiB".into())
        } else {
            Ok(output)
        };
    }
    if command == 5 {
        let mut output = String::with_capacity(source.len());
        for line in source.split_inclusive('\n') {
            let (body, ending) = split_ending(line);
            output.push_str(body.trim_end_matches([' ', '\t']));
            output.push_str(ending);
        }
        return Ok(output);
    }
    // Move line bodies, retaining the original line-ending sequence and final-newline state.
    let lines = source
        .split_inclusive('\n')
        .map(split_ending)
        .collect::<Vec<_>>();
    let mut bodies = lines.iter().map(|(body, _)| *body).collect::<Vec<_>>();
    if command == 3 {
        bodies.sort_unstable();
    } else {
        let mut seen = HashSet::new();
        bodies.retain(|line| seen.insert(*line));
    }
    let final_ending = lines.last().map_or("", |(_, ending)| *ending);
    let mut output = String::with_capacity(source.len());
    for (index, body) in bodies.iter().enumerate() {
        output.push_str(body);
        output.push_str(if index + 1 == bodies.len() {
            final_ending
        } else {
            lines[index].1
        });
    }
    Ok(output)
}

fn unreserved(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~')
}
fn encode_component(source: &str) -> Result<String, String> {
    let size = source
        .bytes()
        .map(|byte| if unreserved(byte) { 1 } else { 3 })
        .sum::<usize>();
    if size > MAX_OUTPUT {
        return Err("Encoded text exceeds 2 MiB".into());
    }
    let mut output = String::with_capacity(size);
    const HEX: &[u8] = b"0123456789ABCDEF";
    for byte in source.bytes() {
        if unreserved(byte) {
            output.push(char::from(byte));
        } else {
            output.push('%');
            output.push(char::from(HEX[usize::from(byte >> 4)]));
            output.push(char::from(HEX[usize::from(byte & 15)]));
        }
    }
    Ok(output)
}
fn decode_component(source: &str) -> Result<String, String> {
    let bytes = source.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let octet = bytes
                .get(index + 1)
                .and_then(|byte| hex(*byte))
                .zip(bytes.get(index + 2).and_then(|byte| hex(*byte)));
            let Some((high, low)) = octet else {
                return Err(format!("Invalid URL escape · byte {}", index + 1));
            };
            output.push(high * 16 + low);
            index += 3;
        } else {
            output.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(output).map_err(|_| "Decoded text is not valid UTF-8".into())
}
fn hex(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}
fn split_ending(line: &str) -> (&str, &str) {
    if let Some(body) = line.strip_suffix("\r\n") {
        (body, "\r\n")
    } else if let Some(body) = line.strip_suffix('\n') {
        (body, "\n")
    } else {
        (line, "")
    }
}

fn json(source: &str, pretty: bool, newline: &str) -> Result<String, String> {
    // Validate without round-tripping through Value: retain numeric lexemes, key order,
    // duplicate keys and string escapes exactly, including arbitrarily large JSON numbers.
    serde_json::from_str::<serde::de::IgnoredAny>(source).map_err(|error| {
        format!(
            "Invalid JSON · line {}, column {}",
            error.line(),
            error.column()
        )
    })?;
    let mut compact = String::with_capacity(source.len());
    let (mut quoted, mut escaped) = (false, false);
    for ch in source.chars() {
        if quoted {
            compact.push(ch);
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                quoted = false;
            }
        } else if ch == '"' {
            quoted = true;
            compact.push(ch);
        } else if !matches!(ch, ' ' | '\t' | '\r' | '\n') {
            compact.push(ch);
        }
    }
    let mut output = String::with_capacity(compact.len());
    if pretty {
        let mut chars = compact.chars().peekable();
        let mut depth = 0usize;
        quoted = false;
        escaped = false;
        while let Some(ch) = chars.next() {
            output.push(ch);
            if quoted {
                if escaped {
                    escaped = false;
                } else if ch == '\\' {
                    escaped = true;
                } else if ch == '"' {
                    quoted = false;
                }
            } else {
                match ch {
                    '"' => quoted = true,
                    '{' | '[' => {
                        depth += 1;
                        if !matches!(chars.peek(), Some('}' | ']')) {
                            indent(&mut output, newline, depth);
                        }
                    }
                    '}' | ']' => {
                        depth -= 1;
                    }
                    ',' => indent(&mut output, newline, depth),
                    ':' => output.push(' '),
                    _ => {}
                }
            }
            if !quoted && matches!(chars.peek(), Some('}' | ']')) && !matches!(ch, '{' | '[') {
                indent(&mut output, newline, depth.saturating_sub(1));
            }
            if output.len() > MAX_OUTPUT {
                return Err("Formatted JSON exceeds 2 MiB".into());
            }
        }
    } else {
        output = compact;
    }
    if source.ends_with('\n') {
        output.push_str(if source.ends_with("\r\n") {
            "\r\n"
        } else {
            "\n"
        });
    }
    if output.len() > MAX_OUTPUT {
        return Err("Formatted JSON exceeds 2 MiB".into());
    }
    Ok(output)
}
fn indent(output: &mut String, newline: &str, depth: usize) {
    output.push_str(newline);
    for _ in 0..depth {
        output.push_str("  ");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn wait(job: &mut Job) -> &Result<Plan, String> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while job.poll().is_none() {
            assert!(std::time::Instant::now() < deadline);
            thread::sleep(std::time::Duration::from_millis(1));
        }
        job.poll().unwrap()
    }
    #[test]
    fn json_retains_values_escapes_order_and_duplicate_keys() {
        let source = " {\"z\":1e400,\"z\":9007199254740993123456789,\"a\":[{},[],\" x \\\" \\n\",true,null]} \r\n";
        let pretty = transform(source, 1, "\r\n").unwrap();
        assert!(pretty.contains("\r\n  \"z\": 1e400,"));
        assert!(pretty.contains("\r\n    {},\r\n    [],"));
        assert!(pretty.ends_with("\r\n}\r\n"));
        assert_eq!(transform(&pretty,2,"\r\n").unwrap(),"{\"z\":1e400,\"z\":9007199254740993123456789,\"a\":[{},[],\" x \\\" \\n\",true,null]}\r\n");
        assert_eq!(transform(&pretty, 1, "\r\n").unwrap(), pretty);
        assert_eq!(
            transform("{\"a\":\"b\"}", 1, "\n").unwrap(),
            "{\n  \"a\": \"b\"\n}"
        );
        assert!(transform("{bad}", 1, "\n")
            .unwrap_err()
            .starts_with("Invalid JSON · line"));
    }
    #[test]
    fn lines_preserve_endings_final_newline_and_exact_matches() {
        assert_eq!(transform("b\r\na\r\na", 3, "\r\n").unwrap(), "a\r\na\r\nb");
        assert_eq!(
            transform("b\na\r\nb\nA\r\n", 4, "\n").unwrap(),
            "b\na\r\nA\r\n"
        );
        assert_eq!(
            transform("  a \t\r\nb\t\n  ", 5, "\n").unwrap(),
            "  a\r\nb\n"
        );
        assert_eq!(transform("\n\n", 4, "\n").unwrap(), "\n");
        assert_eq!(transform("", 3, "\n").unwrap(), "");
    }
    #[test]
    fn selection_is_one_transaction_and_stale_plans_fail() {
        let mut doc = Document::new("👩‍💻\nb\na\ntail");
        let mut job = Job::start(&doc, 4..7, 3).unwrap();
        let plan = wait(&mut job).as_ref().unwrap();
        assert_eq!(plan.apply(&mut doc).unwrap(), (true, 4..7));
        assert_eq!(doc.text(), "👩‍💻\na\nb\ntail");
        assert!(plan.apply(&mut doc).is_err());
        doc.undo();
        assert_eq!(doc.text(), "👩‍💻\nb\na\ntail");
        assert!(!doc.is_dirty());
        let mut job = Job::start(&doc, 0..doc.len_chars(), 5).unwrap();
        let revision = doc.revision();
        assert!(!wait(&mut job).as_ref().unwrap().apply(&mut doc).unwrap().0);
        assert_eq!(doc.revision(), revision);
        assert!(!doc.is_dirty());
        let mut other = Document::new(&doc.text());
        assert!(job
            .poll()
            .unwrap()
            .as_ref()
            .unwrap()
            .apply(&mut other)
            .is_err());
    }
    #[test]
    fn command_search_and_limits() {
        assert_eq!(choices("json").len(), 2);
        assert_eq!(choices("dedupe")[0].id, 4);
        assert!(choices("missing").is_empty());
        assert_eq!(choices("").len(), 9);
        assert_eq!(choices("url decode")[0].id, 9);
        assert_eq!(choices("регистр").len(), 2);
        let large = Document::new(&"a".repeat(MAX_SOURCE + 1));
        assert!(Job::start(&large, 0..large.len_chars(), 3).is_err());
        assert!(Job::start(&large, 1..2, 999).is_err());
        assert!(Job::start(&large, Range { start: 2, end: 1 }, 3).is_err());
        assert!(Job::start(&large, 0..10, 3).is_ok());
        assert!(transform(
            &format!("[{}]", "[0],".repeat(100_000).trim_end_matches(',')),
            1,
            "\n"
        )
        .is_ok());
    }

    #[test]
    fn unicode_case_preserves_layout_and_can_expand_a_selection() {
        let text = "\tStraße Привет e\u{301} 👩‍💻\r\n";
        assert_eq!(
            transform(text, 6, "\n").unwrap(),
            "\tSTRASSE ПРИВЕТ E\u{301} 👩‍💻\r\n"
        );
        assert_eq!(
            transform("ΟΣ İ ПРИВЕТ\0\r\n", 7, "\n").unwrap(),
            "ος i\u{307} привет\0\r\n"
        );
        let prefix = "👩‍💻 ";
        let mut doc = Document::new(&format!("{prefix}straße tail"));
        let start = prefix.chars().count();
        let mut job = Job::start(&doc, start..start + 6, 6).unwrap();
        assert_eq!(
            wait(&mut job).as_ref().unwrap().apply(&mut doc).unwrap(),
            (true, start..start + 7)
        );
        assert_eq!(doc.text(), format!("{prefix}STRASSE tail"));
        doc.undo();
        assert_eq!(doc.text(), format!("{prefix}straße tail"));
        assert!(!doc.is_dirty());
    }

    #[test]
    fn percent_encoding_round_trips_utf8_and_decodes_only_once() {
        let text = "Az09-._~ /+?&=é🦀\r\n\0";
        let encoded = "Az09-._~%20%2F%2B%3F%26%3D%C3%A9%F0%9F%A6%80%0D%0A%00";
        assert_eq!(transform(text, 8, "\n").unwrap(), encoded);
        assert_eq!(transform(encoded, 9, "\n").unwrap(), text);
        assert_eq!(transform("%252F+%2b", 9, "\n").unwrap(), "%2F++");
        assert_eq!(transform("%2F", 8, "\n").unwrap(), "%252F");
        for text in ["%", "%A", "%GG", "prefix%SECRET"] {
            let error = transform(text, 9, "\n").unwrap_err();
            assert!(error.starts_with("Invalid URL escape · byte "));
            assert!(!error.contains("SECRET"));
        }
        for text in ["%FF", "%C3%28", "%ED%A0%80"] {
            assert_eq!(
                transform(text, 9, "\n").unwrap_err(),
                "Decoded text is not valid UTF-8"
            );
        }
        assert_eq!(
            transform("already+plain", 9, "\n").unwrap(),
            "already+plain"
        );
    }

    #[test]
    fn url_expansion_is_bounded_and_errors_do_not_change_private_access() {
        assert_eq!(
            transform(&"~".repeat(MAX_SOURCE), 8, "\n").unwrap().len(),
            MAX_SOURCE
        );
        assert_eq!(
            transform(&" ".repeat(MAX_SOURCE), 8, "\n").unwrap_err(),
            "Encoded text exceeds 2 MiB"
        );
        let mut session = crate::session::Session::new("", None);
        session.open_private();
        session.active_mut().document.replace(0..0, "%GG").unwrap();
        let reference = session.share_active().unwrap();
        let doc = &session.active().document;
        let revision = doc.revision();
        let mut job = Job::start(doc, 0..doc.len_chars(), 9).unwrap();
        assert!(wait(&mut job).is_err());
        assert_eq!(session.active().document.revision(), revision);
        assert!(crate::handoff::fetch(&reference).is_ok());
        let doc = &session.active().document;
        let mut job = Job::start(doc, 0..doc.len_chars(), 8).unwrap();
        wait(&mut job)
            .as_ref()
            .unwrap()
            .apply(&mut session.active_mut().document)
            .unwrap();
        assert_eq!(session.active().document.text(), "%25GG");
        assert!(crate::handoff::fetch(&reference).is_err());
    }

    #[test]
    fn private_noop_and_errors_keep_access_real_tools_revoke_it() {
        let mut session = crate::session::Session::new("", None);
        session.open_private();
        session
            .active_mut()
            .document
            .replace(0..0, "b\na\nb")
            .unwrap();
        let reference = session.share_active().unwrap();
        let doc = &session.active().document;
        let mut noop = Job::start(doc, 0..doc.len_chars(), 5).unwrap();
        let plan = wait(&mut noop).as_ref().unwrap();
        assert!(!plan.apply(&mut session.active_mut().document).unwrap().0);
        assert!(crate::handoff::fetch(&reference).is_ok());
        let doc = &session.active().document;
        let mut invalid = Job::start(doc, 0..doc.len_chars(), 1).unwrap();
        assert!(wait(&mut invalid).is_err());
        assert!(crate::handoff::fetch(&reference).is_ok());
        let doc = &session.active().document;
        let mut job = Job::start(doc, 0..doc.len_chars(), 4).unwrap();
        wait(&mut job)
            .as_ref()
            .unwrap()
            .apply(&mut session.active_mut().document)
            .unwrap();
        assert!(crate::handoff::fetch(&reference).is_err());
        session.active_mut().document.undo();
        assert!(crate::handoff::fetch(&reference).is_err());
    }

    #[test]
    fn json_format_is_valid_idempotent_and_bounded() {
        for source in [
            "null",
            "true",
            "42",
            "1e400",
            "\"a\\\"b\"",
            "{}",
            "[]",
            "[1,2,3]",
            "{\"a\":\"b\"}",
            "[{\"a\":[{},[],[\"b\"]]}]",
            "{\"x\":{},\"y\":[]}",
        ] {
            let pretty = transform(source, 1, "\n").unwrap();
            serde_json::from_str::<serde::de::IgnoredAny>(&pretty).unwrap();
            assert_eq!(transform(&pretty, 2, "\n").unwrap(), source);
            assert_eq!(transform(&pretty, 1, "\n").unwrap(), pretty);
        }
        let nested = format!("{}0{}", "[".repeat(2000), "]".repeat(2000));
        assert!(transform(&nested, 1, "\n").is_err());
    }
}
