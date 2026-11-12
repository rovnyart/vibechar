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

fn assert_history_accounting(doc: &Document) {
    assert_eq!(
        doc.history_bytes,
        doc.undo
            .iter()
            .chain(&doc.redo)
            .map(HistoryEntry::retained_bytes)
            .sum::<usize>()
    );
    assert!(doc.undo.len() + doc.redo.len() <= MAX_HISTORY_STEPS);
    assert!(doc.history_bytes <= MAX_HISTORY_BYTES || doc.undo.len() + doc.redo.len() == 1);
}

#[test]
fn oldest_steps_expire_without_changing_saved_state_or_redo_order() {
    let mut doc = Document::new("");
    for _ in 0..MAX_HISTORY_STEPS + 5 {
        doc.replace(doc.len_chars()..doc.len_chars(), "я").unwrap();
    }
    assert_eq!(doc.undo.len(), MAX_HISTORY_STEPS);
    assert_history_accounting(&doc);
    doc.mark_saved();
    for _ in 0..MAX_HISTORY_STEPS {
        assert!(doc.undo().is_some());
        assert!(doc.is_dirty());
        assert_history_accounting(&doc);
    }
    assert_eq!(doc.text(), "я".repeat(5));
    let revision = doc.revision();
    assert_eq!(doc.undo(), None);
    assert_eq!(doc.revision(), revision);
    for _ in 0..MAX_HISTORY_STEPS {
        assert!(doc.redo().is_some());
        assert_history_accounting(&doc);
    }
    assert_eq!(doc.len_chars(), MAX_HISTORY_STEPS + 5);
    assert!(!doc.is_dirty());
    assert_eq!(doc.redo(), None);
}

#[test]
fn large_replacements_evict_oldest_history_within_the_allocation_budget() {
    let a = "a".repeat(512 * 1024);
    let b = "b".repeat(a.len());
    let mut doc = Document::new(&a);
    for step in 0..48 {
        doc.replace(0..doc.len_chars(), if step % 2 == 0 { &b } else { &a })
            .unwrap();
        assert_history_accounting(&doc);
    }
    let retained = doc.undo.len();
    assert!(retained > 1 && retained < 48);
    assert!(doc.history_bytes <= MAX_HISTORY_BYTES);
    // Identical bytes do not make an expired save-state identity reachable again.
    for _ in 0..retained {
        assert!(doc.undo().is_some());
    }
    assert_eq!(doc.undo(), None);
    assert!(doc.is_dirty());
    for _ in 0..retained {
        assert!(doc.redo().is_some());
    }
    assert_eq!(doc.text(), a);
    doc.mark_saved();
    doc.undo();
    assert!(doc.is_dirty());
    doc.redo();
    assert!(!doc.is_dirty());
    assert_history_accounting(&doc);
}

#[test]
fn an_oversized_atomic_edit_keeps_one_undo_and_yields_to_a_newer_edit() {
    let mut doc = Document::new("old");
    doc.replace(0..3, "new").unwrap();
    doc.mark_saved();
    let large = "x".repeat(MAX_HISTORY_BYTES + 1);
    doc.replace(0..3, &large).unwrap();
    assert_eq!(doc.undo.len(), 1);
    assert!(doc.history_bytes > MAX_HISTORY_BYTES);
    assert_history_accounting(&doc);
    assert_eq!(doc.undo(), Some(3));
    assert_eq!(doc.text(), "new");
    assert!(!doc.is_dirty());
    assert_eq!(doc.undo(), None);
    assert!(doc.redo().is_some());
    doc.replace(0..1, "y").unwrap();
    assert_eq!(doc.undo.len(), 1);
    assert!(doc.history_bytes < 1024);
    assert_eq!(doc.undo(), Some(1));
    assert_eq!(doc.len_bytes(), large.len());
    assert_eq!(doc.text_range(0..1).unwrap(), "x");
    assert!(doc.is_dirty());
    assert_history_accounting(&doc);
}

#[test]
fn grouped_and_batch_allocations_follow_undo_redo_and_branch_invalidation() {
    let mut doc = Document::new("");
    let now = Instant::now();
    for text in ["я", "🦀", "e\u{301}"] {
        type_at(&mut doc, text, now);
        assert_history_accounting(&doc);
    }
    for continuation in [false, true] {
        let end = doc.len_chars();
        doc.replace_many_input(
            &[
                TextEdit {
                    range: 0..0,
                    text: "L".into(),
                },
                TextEdit {
                    range: end..end,
                    text: "R".into(),
                },
            ],
            EditKind::Typing,
            continuation,
        )
        .unwrap();
        assert_history_accounting(&doc);
    }
    assert_eq!(doc.undo.len(), 2);
    assert_eq!(doc.text(), "LLя🦀e\u{301}RR");
    doc.undo();
    assert_eq!(doc.text(), "я🦀e\u{301}");
    assert_history_accounting(&doc);
    let before = doc.history_bytes;
    assert!(!doc.replace(0..0, "").unwrap());
    assert!(doc.replace(0..usize::MAX, "bad").is_err());
    assert_eq!(doc.history_bytes, before);
    assert_eq!(doc.redo.len(), 1);
    doc.redo();
    assert_eq!(doc.text(), "LLя🦀e\u{301}RR");
    doc.undo();
    doc.replace(0..0, "new").unwrap();
    assert_eq!(doc.redo(), None);
    assert_history_accounting(&doc);
    doc.undo();
    doc.undo();
    assert_eq!(doc.text(), "");
    assert!(!doc.is_dirty());
    assert_history_accounting(&doc);
}

#[test]
fn history_observer_replays_grouped_and_batch_changes_against_each_source_state() {
    let mut doc = Document::new("👩‍💻 я x\r\n");
    doc.replace_many(&[
        TextEdit {
            range: 4..5,
            text: "🦀".into(),
        },
        TextEdit {
            range: 6..7,
            text: "ß\0".into(),
        },
    ])
    .unwrap();
    let now = Instant::now();
    for text in ["e", "\u{301}", "🇦🇲"] {
        type_at(&mut doc, text, now)
    }
    doc.mark_saved();
    let final_text = doc.text();
    let mut mirror = final_text.clone();
    let mut calls = 0;
    let mut observe = |before: &Document, range: Range<usize>, inserted: &str| {
        assert_eq!(before.text(), mirror);
        let byte = |at| {
            mirror
                .char_indices()
                .nth(at)
                .map_or(mirror.len(), |(byte, _)| byte)
        };
        let bytes = byte(range.start)..byte(range.end);
        mirror.replace_range(bytes, inserted);
        calls += 1;
    };
    let revision = doc.revision();
    assert!(doc.undo_with(&mut observe).is_some());
    assert!(doc.undo_with(&mut observe).is_some());
    assert!(doc.undo_with(&mut observe).is_none());
    assert_eq!(doc.revision(), revision + 2);
    assert!(doc.is_dirty());
    assert!(doc.redo_with(&mut observe).is_some());
    assert!(doc.redo_with(&mut observe).is_some());
    assert!(doc.redo_with(&mut observe).is_none());
    assert_eq!(calls, 10);
    assert_eq!(mirror, final_text);
    assert_eq!(doc.text(), final_text);
    assert!(!doc.is_dirty());
    assert_history_accounting(&doc);
}
