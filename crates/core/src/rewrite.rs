//! Explicit, memory-only selection proposals. No provider or credential access.
use crate::{session::Session, TextEdit};
use std::{
    ops::Range,
    sync::atomic::{AtomicU64, Ordering},
};

pub const MAX_SOURCE: usize = 32 * 1024;
pub const MAX_OUTPUT: usize = 128 * 1024;
pub const MAX_PROTECTED: usize = 32;
static NEXT_CAPTURE: AtomicU64 = AtomicU64::new(1);

pub struct Rewrite {
    document: u64,
    revision: u64,
    range: Range<usize>,
    source: String,
    protected: Vec<Range<usize>>,
    prefix: String,
    crlf: bool,
    result: Option<String>,
}

impl Rewrite {
    pub fn capture(session: &Session, range: Range<usize>) -> Result<Self, &'static str> {
        if session.active().is_private() {
            return Err("Private tabs cannot use AI. Use local text tools instead.");
        }
        let document = &session.active().document;
        if range.is_empty() || range.start > range.end || range.end > document.len_chars() {
            return Err("Select some text to rewrite.");
        }
        let rope = document.checkpoint_text();
        if rope.slice(range.clone()).len_bytes() > MAX_SOURCE {
            return Err("Select up to 32 KiB to rewrite.");
        }
        let source = rope.slice(range.clone()).to_string();
        let prefix = loop {
            let prefix = format!(
                "[[VIBECHAR_KEEP_{}_",
                NEXT_CAPTURE.fetch_add(1, Ordering::Relaxed)
            );
            if !source.contains(&prefix) {
                break prefix;
            }
        };
        Ok(Self {
            document: document.id(),
            revision: document.revision(),
            range,
            source,
            protected: Vec::new(),
            prefix,
            crlf: document.newline() == "\r\n",
            result: None,
        })
    }

    pub fn is_current(&self, session: &Session) -> bool {
        let buffer = session.active();
        !buffer.is_private()
            && buffer.document.id() == self.document
            && buffer.document.revision() == self.revision
    }
    pub fn source(&self) -> &str {
        &self.source
    }
    pub fn result(&self) -> Option<&str> {
        self.result.as_deref()
    }
    pub fn protected(&self) -> &[Range<usize>] {
        &self.protected
    }
    pub fn clear(&mut self, protection: bool) {
        self.result = None;
        if protection {
            self.protected.clear();
        }
    }
    pub fn protect(&mut self, range: Range<usize>) -> Result<(), &'static str> {
        if range.is_empty()
            || range.start > range.end
            || range.end > self.source.len()
            || !self.source.is_char_boundary(range.start)
            || !self.source.is_char_boundary(range.end)
        {
            return Err("Select a complete text fragment in Source.");
        }
        if self.protected.len() >= MAX_PROTECTED {
            return Err("Keep up to 32 fragments exact.");
        }
        if self
            .protected
            .iter()
            .any(|r| r.start < range.end && range.start < r.end)
        {
            return Err("Kept fragments cannot overlap. Clear them to choose again.");
        }
        self.result = None;
        self.protected.push(range);
        self.protected.sort_by_key(|r| r.start);
        Ok(())
    }
    fn marker(&self, index: usize) -> String {
        format!("{}{index}]]", self.prefix)
    }
    pub fn request_text(&self) -> String {
        let mut request = String::new();
        let mut from = 0;
        for (index, range) in self.protected.iter().enumerate() {
            request.push_str(&self.source[from..range.start]);
            request.push_str(&self.marker(index));
            from = range.end;
        }
        request.push_str(&self.source[from..]);
        request
    }
    pub fn propose(&mut self, output: &str) -> Result<(), &'static str> {
        self.result = None;
        if output.len() > MAX_OUTPUT {
            return Err("Result exceeds 128 KiB. Try a smaller selection.");
        }
        let normalized = if self.crlf {
            output.replace("\r\n", "\n").replace('\n', "\r\n")
        } else {
            output.into()
        };
        if normalized.matches(&self.prefix).count() != self.protected.len() {
            return Err("The model changed a kept fragment. Nothing was applied.");
        }
        let mut restored = String::new();
        let mut from = 0;
        for (index, range) in self.protected.iter().enumerate() {
            let marker = self.marker(index);
            if normalized.matches(&marker).count() != 1 {
                return Err("The model changed a kept fragment. Nothing was applied.");
            }
            let Some(relative) = normalized[from..].find(&marker) else {
                return Err("The model reordered kept fragments. Nothing was applied.");
            };
            let at = from + relative;
            restored.push_str(&normalized[from..at]);
            restored.push_str(&self.source[range.clone()]);
            from = at + marker.len();
        }
        restored.push_str(&normalized[from..]);
        if restored.len() > MAX_OUTPUT {
            return Err("Result exceeds 128 KiB. Try a smaller selection.");
        }
        self.result = Some(restored);
        Ok(())
    }
    pub fn apply(&mut self, session: &mut Session) -> Result<(bool, Range<usize>), &'static str> {
        if !self.is_current(session) {
            return Err("Text changed. Select it again to make a new preview.");
        }
        let text = self
            .result
            .as_ref()
            .ok_or("Generate a preview before applying.")?;
        let range = self.range.start..self.range.start + text.chars().count();
        let changed = session
            .active_mut()
            .document
            .replace_many(&[TextEdit {
                range: self.range.clone(),
                text: text.clone(),
            }])
            .map_err(|_| "The selection is no longer available.")?;
        self.result = None;
        Ok((changed, range))
    }
}

/// Convert native UTF-16 to UTF-8 bytes without accepting half a surrogate pair.
pub fn byte_range(text: &str, start: usize, length: usize) -> Result<Range<usize>, &'static str> {
    let end = start.checked_add(length).ok_or("Invalid text range.")?;
    let mut utf16 = 0;
    let (mut from, mut to) = (None, None);
    for (byte, character) in text
        .char_indices()
        .chain(std::iter::once((text.len(), '\0')))
    {
        if utf16 == start {
            from = Some(byte);
        }
        if utf16 == end {
            to = Some(byte);
            break;
        }
        utf16 += character.len_utf16();
    }
    from.zip(to)
        .map(|(a, b)| a..b)
        .ok_or("Select a complete text fragment in Source.")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn selection_only_one_undo_unicode_crlf_and_noop() {
        let mut session = Session::new("outside 👩‍💻\r\nhello\r\ntail", None);
        let mut rewrite = Rewrite::capture(&session, 13..20).unwrap();
        assert_eq!(rewrite.source(), "hello\r\n");
        rewrite.propose("Привет 🦀\n").unwrap();
        assert_eq!(rewrite.result(), Some("Привет 🦀\r\n"));
        assert!(rewrite.apply(&mut session).unwrap().0);
        assert_eq!(
            session.active().document.text(),
            "outside 👩‍💻\r\nПривет 🦀\r\ntail"
        );
        assert!(rewrite.apply(&mut session).is_err());
        session.active_mut().document.undo().unwrap();
        assert_eq!(
            session.active().document.text(),
            "outside 👩‍💻\r\nhello\r\ntail"
        );
        let mut noop = Rewrite::capture(&session, 13..18).unwrap();
        noop.propose("hello").unwrap();
        assert!(!noop.apply(&mut session).unwrap().0);
    }
    #[test]
    fn protected_values_never_enter_request_and_are_restored_exactly() {
        let mut session = Session::new("x secret\0🦀 y unchanged z", None);
        let mut rewrite =
            Rewrite::capture(&session, 0..session.active().document.len_chars()).unwrap();
        rewrite.protect(2..13).unwrap();
        rewrite.protect(16..25).unwrap();
        let request = rewrite.request_text();
        assert!(!request.contains("secret") && !request.contains("unchanged"));
        rewrite.propose(&request.replace("x ", "new ")).unwrap();
        rewrite.apply(&mut session).unwrap();
        assert_eq!(
            session.active().document.text(),
            "new secret\0🦀 y unchanged z"
        );
    }
    #[test]
    fn missing_duplicated_modified_and_reordered_markers_fail_closed() {
        let session = Session::new("one two", None);
        let mut rewrite = Rewrite::capture(&session, 0..7).unwrap();
        rewrite.protect(0..3).unwrap();
        rewrite.protect(4..7).unwrap();
        let (a, b) = (rewrite.marker(0), rewrite.marker(1));
        for invalid in [
            a.clone(),
            format!("{a} {a} {b}"),
            format!("{b} {a}"),
            format!("{a} {}", b.replace("]]", "]")),
        ] {
            assert!(rewrite.propose(&invalid).is_err());
            assert!(rewrite.result().is_none());
        }
        assert!(rewrite.protect(2..5).is_err());
        rewrite.clear(true);
        assert_eq!(rewrite.request_text(), "one two");
    }
    #[test]
    fn private_stale_changed_undo_and_other_document_are_rejected() {
        let mut session = Session::new("source", None);
        let mut rewrite = Rewrite::capture(&session, 0..6).unwrap();
        rewrite.propose("new").unwrap();
        session.active_mut().document.replace(0..0, "x").unwrap();
        assert!(rewrite.apply(&mut session).is_err());
        session.active_mut().document.undo().unwrap();
        assert!(!rewrite.is_current(&session));
        let other = Session::new("source", None);
        assert!(!rewrite.is_current(&other));
        session.open_private();
        assert!(Rewrite::capture(&session, 0..1).is_err());
        assert!(rewrite.apply(&mut session).is_err());
    }
    #[test]
    fn limits_scalar_boundaries_and_empty_deletion() {
        assert_eq!(byte_range("a🦀b", 1, 2), Ok(1..5));
        assert!(byte_range("a🦀b", 2, 1).is_err());
        assert!(byte_range("a", usize::MAX, 1).is_err());
        let mut session = Session::new("x", None);
        let mut rewrite = Rewrite::capture(&session, 0..1).unwrap();
        assert!(rewrite.propose(&"x".repeat(MAX_OUTPUT + 1)).is_err());
        rewrite.propose("").unwrap();
        rewrite.apply(&mut session).unwrap();
        assert_eq!(session.active().document.text(), "");
        assert!(Rewrite::capture(&session, 0..0).is_err());
        let session = Session::new(&"x".repeat(MAX_SOURCE + 1), None);
        assert!(Rewrite::capture(&session, 0..MAX_SOURCE + 1).is_err());
    }
}
