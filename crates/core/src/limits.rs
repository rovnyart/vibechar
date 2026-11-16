//! Shared resource policy. Large mode changes presentation, never source/history.
pub const LARGE_TEXT_BYTES: usize = 512 * 1024;
pub const NATIVE_PARAGRAPH_GLYPHS: usize = 256 * 1024;
pub const WORD_LINE_BYTES: usize = 64 * 1024;
pub const SYNTAX_BYTES: usize = 512 * 1024;
pub const SYNTAX_LINE_BYTES: usize = 8192;
pub const SEARCH_BYTES: usize = 4 * 1024 * 1024;
pub const TOOL_BYTES: usize = 1024 * 1024;
pub const METRICS_BYTES: usize = 64 * 1024 * 1024;
pub const HISTORY_BYTES: usize = 32 * 1024 * 1024;
pub const HISTORY_STEPS: usize = 1024;

impl crate::Document {
    pub fn is_large(&self) -> bool {
        self.len_bytes() >= LARGE_TEXT_BYTES
    }
    /// Do not cut paragraph context used by the Unicode bidi algorithm. Cached
    /// by revision; ASCII Rope chunks skip scalar/property decoding entirely.
    pub fn native_paragraph_budget(&self) -> usize {
        if let Some((revision, safe)) = *self.native_layout_safety.borrow() {
            if revision == self.revision() {
                return if safe { NATIVE_PARAGRAPH_GLYPHS } else { 0 };
            }
        }
        use unicode_bidi::BidiClass::*;
        let safe = self.text.chunks().all(|chunk| {
            chunk.is_ascii()
                || chunk.chars().all(|c| {
                    !matches!(
                        unicode_bidi::bidi_class(c),
                        R | AL | AN | LRE | RLE | LRO | RLO | PDF | LRI | RLI | FSI | PDI
                    )
                })
        });
        *self.native_layout_safety.borrow_mut() = Some((self.revision(), safe));
        if safe {
            NATIVE_PARAGRAPH_GLYPHS
        } else {
            0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Document;
    #[test]
    fn mode_follows_utf8_size_through_edit_undo_without_changing_save_state() {
        let mut doc = Document::new(&"я".repeat(LARGE_TEXT_BYTES / 2 - 1));
        let revision = doc.revision();
        assert!(!doc.is_large());
        assert_eq!(doc.revision(), revision);
        assert!(!doc.is_dirty());
        doc.replace(0..0, "я").unwrap();
        assert!(doc.is_large());
        doc.undo().unwrap();
        assert!(!doc.is_large() && !doc.is_dirty());
        doc.redo().unwrap();
        assert!(doc.is_large());
    }
    #[test]
    fn pointer_words_keep_composed_text_whole_and_decline_unbounded_lines() {
        let doc = Document::new("hello я\u{301}, 👩‍💻\r\nlast");
        assert_eq!(doc.word_selection(7).unwrap(), 6..8);
        assert_eq!(doc.word_selection(9).unwrap(), 9..10);
        let long = Document::new(&("я".repeat(WORD_LINE_BYTES / 2 + 1) + "\nlast"));
        assert!(long.word_selection(1).is_err());
        assert_eq!(
            long.word_selection(long.len_chars() - 2).unwrap(),
            long.len_chars() - 4..long.len_chars()
        );
        assert!(!long.is_dirty() && long.revision() == 0);
    }
    #[test]
    fn bidi_context_falls_back_and_the_decision_tracks_history_and_rope_chunks() {
        let mut doc = Document::new(&("x".repeat(2048) + "я👩‍💻e\u{301}界"));
        assert_eq!(doc.native_paragraph_budget(), NATIVE_PARAGRAPH_GLYPHS);
        for inserted in ["שלום", "مرحبا", "١", "\u{202e}", "\u{2066}", "\u{2069}"] {
            doc.replace(0..0, inserted).unwrap();
            assert_eq!(doc.native_paragraph_budget(), 0);
            doc.undo().unwrap();
            assert_eq!(doc.native_paragraph_budget(), NATIVE_PARAGRAPH_GLYPHS);
        }
    }
}
