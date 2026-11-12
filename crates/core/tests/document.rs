use vibechar_core::Document;

#[test]
fn replaces_unicode_without_confusing_bytes_and_characters() {
    let mut doc = Document::new("Арт 🦀!");
    doc.replace(4..5, "⚡").unwrap();
    assert_eq!(doc.text(), "Арт ⚡!");
    assert!(doc.is_dirty());
    assert_eq!(doc.undo(), Some(5));
    assert_eq!(doc.text(), "Арт 🦀!");
    assert!(!doc.is_dirty());
    assert_eq!(doc.redo(), Some(5));
    assert_eq!(doc.text(), "Арт ⚡!");
}

#[test]
fn saved_state_survives_undo_and_redo_but_not_a_divergent_edit() {
    let mut doc = Document::new("");
    doc.replace(0..0, "a").unwrap();
    doc.mark_saved();
    doc.replace(1..1, "b").unwrap();
    doc.undo();
    assert!(!doc.is_dirty());
    doc.undo();
    assert!(doc.is_dirty());
    doc.redo();
    assert!(!doc.is_dirty());
    doc.replace(1..1, "c").unwrap();
    assert_eq!(doc.redo(), None);
    assert!(doc.is_dirty());
}

#[test]
fn invalid_ranges_and_noops_do_not_change_history_or_revision() {
    let mut doc = Document::new("abc");
    assert!(doc.replace(2..4, "x").is_err());
    assert!(!doc.replace(1..2, "b").unwrap());
    assert_eq!(doc.revision(), 0);
    assert_eq!(doc.undo(), None);
    assert_eq!(doc.text(), "abc");
}

#[test]
fn undo_also_advances_revision_so_pending_proposals_become_stale() {
    let mut doc = Document::new("a");
    doc.replace(1..1, "b").unwrap();
    let revision = doc.revision();
    doc.undo();
    assert!(doc.revision() > revision);
    assert_eq!(doc.text(), "a");
}

#[test]
fn utf16_offsets_must_not_split_a_surrogate_pair() {
    let doc = Document::new("a🦀я");
    assert_eq!(doc.char_from_utf16(1).unwrap(), 1);
    assert!(doc.char_from_utf16(2).is_err());
    assert_eq!(doc.char_from_utf16(3).unwrap(), 2);
    assert_eq!(doc.utf16_from_char(3).unwrap(), 4);
    assert!(doc.char_from_utf16(5).is_err());
}

#[test]
fn navigation_treats_combining_and_zwj_sequences_as_one_grapheme() {
    let doc = Document::new("e\u{301}👩‍💻я");
    assert_eq!(doc.next_grapheme(0), 2);
    assert_eq!(doc.next_grapheme(2), 5);
    assert_eq!(doc.previous_grapheme(5), 2);
    assert_eq!(doc.previous_grapheme(2), 0);
    assert_eq!(doc.next_grapheme(6), 6);
}

#[test]
fn crlf_is_one_navigation_unit_and_line_content_excludes_its_ending() {
    let doc = Document::new("ab\r\nя\r\n");
    assert_eq!(doc.next_grapheme(2), 4);
    assert_eq!(doc.previous_grapheme(4), 2);
    assert_eq!(doc.line(0), "ab");
    assert_eq!(doc.line_start(1), 4);
    assert_eq!(doc.newline(), "\r\n");
    assert_eq!(doc.text(), "ab\r\nя\r\n");
    assert_eq!(doc.text_range(2..5).unwrap(), "\r\nя");
    assert!(doc.text_range(0..100).is_err());
}
