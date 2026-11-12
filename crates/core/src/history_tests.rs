use super::*;

fn type_at(doc: &mut Document, value: &str, now: Instant) {
    let end = doc.len_chars();
    doc.edit_at(end..end, value, EditKind::Typing, now).unwrap();
}

#[test]
fn adjacent_unicode_typing_is_one_step_with_monotonic_revisions() {
    let mut doc = Document::new("");
    let now = Instant::now();
    for text in ["я", "👩‍💻", "e\u{301}"] {
        type_at(&mut doc, text, now);
    }
    assert_eq!(doc.text(), "я👩‍💻e\u{301}");
    assert_eq!(doc.revision(), 3);
    assert_eq!(doc.undo(), Some(0));
    assert_eq!(doc.text(), "");
    assert!(!doc.is_dirty());
    assert_eq!(doc.revision(), 4);
    assert_eq!(doc.redo(), Some(6));
    assert_eq!(doc.text(), "я👩‍💻e\u{301}");
    assert_eq!(doc.revision(), 5);
}

#[test]
fn pause_explicit_boundaries_and_newlines_separate_groups() {
    let mut doc = Document::new("");
    let now = Instant::now();
    type_at(&mut doc, "a", now);
    type_at(&mut doc, "b", now + Duration::from_millis(999));
    type_at(&mut doc, "c", now + Duration::from_millis(1999));
    doc.break_undo_group();
    type_at(&mut doc, "d", now + Duration::from_millis(2000));
    doc.undo();
    assert_eq!(doc.text(), "abc");
    doc.undo();
    assert_eq!(doc.text(), "ab");
    doc.undo();
    assert_eq!(doc.text(), "");
    for newline in ["\r\n", "\u{2028}"] {
        for value in ["prefix", newline, "tail"] {
            type_at(&mut doc, value, now);
        }
        doc.undo();
        assert_eq!(doc.text(), format!("prefix{newline}"));
        doc.undo();
        assert_eq!(doc.text(), "prefix");
        doc.undo();
        assert_eq!(doc.text(), "");
    }
}

#[test]
fn backward_and_forward_deletion_restore_graphemes_and_cursor() {
    let text = "я👩‍💻e\u{301}";
    let now = Instant::now();
    let mut back = Document::new(text);
    back.edit_at(4..6, "", EditKind::Backspace, now).unwrap();
    back.edit_at(1..4, "", EditKind::Backspace, now).unwrap();
    assert_eq!(back.text(), "я");
    assert_eq!(back.undo(), Some(6));
    assert_eq!(back.text(), text);
    assert_eq!(back.redo(), Some(1));
    assert_eq!(back.text(), "я");
    let mut forward = Document::new(text);
    for end in [1, 3, 2] {
        forward
            .edit_at(0..end, "", EditKind::DeleteForward, now)
            .unwrap();
    }
    assert_eq!(forward.text(), "");
    assert_eq!(forward.undo(), Some(6));
    assert_eq!(forward.text(), text);
    assert!(!forward.is_dirty());
    assert_eq!(forward.redo(), Some(0));
    assert_eq!(forward.text(), "");
}

#[test]
fn save_points_and_divergent_edits_keep_correct_dirty_state() {
    let mut doc = Document::new("");
    let now = Instant::now();
    type_at(&mut doc, "a", now);
    type_at(&mut doc, "b", now);
    doc.mark_saved();
    type_at(&mut doc, "c", now);
    type_at(&mut doc, "d", now);
    doc.undo();
    assert_eq!(doc.text(), "ab");
    assert!(!doc.is_dirty());
    doc.undo();
    assert_eq!(doc.text(), "");
    assert!(doc.is_dirty());
    doc.redo();
    assert_eq!(doc.text(), "ab");
    assert!(!doc.is_dirty());
    type_at(&mut doc, "X", now);
    assert_eq!(doc.redo(), None);
    doc.undo();
    assert_eq!(doc.text(), "ab");
    assert!(!doc.is_dirty());
}

#[test]
fn paste_selection_replacement_and_nonadjacent_edits_stay_separate() {
    let now = Instant::now();
    let mut doc = Document::new("");
    type_at(&mut doc, "ab", now);
    doc.replace(2..2, "P").unwrap();
    type_at(&mut doc, "cd", now);
    doc.undo();
    assert_eq!(doc.text(), "abP");
    doc.undo();
    assert_eq!(doc.text(), "ab");
    doc.undo();
    assert_eq!(doc.text(), "");
    let mut doc = Document::new("hello");
    doc.edit_at(0..5, "x", EditKind::Typing, now).unwrap();
    type_at(&mut doc, "y", now);
    doc.undo();
    assert_eq!(doc.text(), "x");
    doc.undo();
    assert_eq!(doc.text(), "hello");
    let mut doc = Document::new("");
    type_at(&mut doc, "a", now);
    doc.edit_at(0..0, "b", EditKind::Typing, now).unwrap();
    doc.undo();
    assert_eq!(doc.text(), "a");
}

#[test]
fn grouping_is_bounded_but_large_paste_remains_one_step() {
    let now = Instant::now();
    let mut doc = Document::new("");
    for _ in 0..MAX_GROUP_EDITS + 1 {
        type_at(&mut doc, "x", now);
    }
    doc.undo();
    assert_eq!(doc.len_chars(), MAX_GROUP_EDITS);
    doc.undo();
    assert_eq!(doc.text(), "");
    type_at(&mut doc, &"x".repeat(MAX_GROUP_BYTES), now);
    type_at(&mut doc, "y", now);
    doc.undo();
    assert_eq!(doc.len_chars(), MAX_GROUP_BYTES);
    doc.undo();
    assert_eq!(doc.text(), "");
    doc.replace(0..0, &"x".repeat(MAX_GROUP_BYTES * 2)).unwrap();
    doc.undo();
    assert_eq!(doc.text(), "");
}

#[test]
fn invalid_and_noop_edits_preserve_revision_and_the_active_group() {
    let mut doc = Document::new("");
    let now = Instant::now();
    type_at(&mut doc, "a", now);
    assert!(doc.edit_at(0..2, "bad", EditKind::Isolated, now).is_err());
    assert!(!doc.edit_at(0..1, "a", EditKind::Isolated, now).unwrap());
    assert_eq!(doc.revision(), 1);
    type_at(&mut doc, "b", now);
    doc.undo();
    assert_eq!(doc.text(), "");
}
