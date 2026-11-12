use super::*;
use std::{
    thread,
    time::{Duration, Instant},
};

fn wait(multi: &mut Multi, document: &Document) {
    let deadline = Instant::now() + Duration::from_secs(3);
    while multi.busy() {
        multi.poll(document);
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(1));
    }
}
fn all(document: &Document, range: Range<usize>) -> Multi {
    let mut multi = Multi::default();
    multi.request(document, range, true).unwrap();
    wait(&mut multi, document);
    multi
}

#[test]
fn word_next_all_wrap_and_typing_share_one_history_entry() {
    let mut document = Document::new("cat cat CAT cat");
    let mut multi = Multi::default();
    multi.request(&document, 0..0, false).unwrap();
    assert_eq!(multi.primary().unwrap().range(), 0..3);
    multi.request(&document, 0..3, false).unwrap();
    multi.request(&document, 0..3, false).unwrap();
    wait(&mut multi, &document);
    assert_eq!(multi.selections().len(), 3);
    assert_eq!(multi.primary().unwrap().range(), 12..15);
    multi.request(&document, 12..15, true).unwrap();
    wait(&mut multi, &document);
    assert_eq!(
        multi.copy_text(&document).unwrap().unwrap(),
        "cat\ncat\ncat"
    );
    assert_eq!(document.revision(), 0);
    assert!(!document.is_dirty());
    for text in ["d", "o", "g"] {
        multi.edit(&mut document, text, EditKind::Typing).unwrap();
    }
    assert_eq!(document.text(), "dog dog CAT dog");
    assert_eq!(document.revision(), 3);
    document.undo();
    assert_eq!(document.text(), "cat cat CAT cat");
    assert!(!document.is_dirty());
    document.redo();
    assert_eq!(document.text(), "dog dog CAT dog");
}

#[test]
fn caret_seed_matches_whole_words_while_explicit_selection_matches_fragments() {
    let document = Document::new("cat category concatenate cat");
    let mut multi = Multi::default();
    multi.request(&document, 0..0, true).unwrap();
    wait(&mut multi, &document);
    assert_eq!(multi.selections().len(), 2);
    let multi = all(&document, 0..3);
    assert_eq!(multi.selections().len(), 4);
}

#[test]
fn deletion_merges_colliding_carets_and_preserves_a_valid_undo_cursor() {
    let mut document = Document::new("aa aa");
    let mut multi = all(&document, 0..2);
    multi.navigate(&document, 1, false).unwrap();
    for _ in 0..3 {
        multi.edit(&mut document, "", EditKind::Backspace).unwrap();
    }
    assert_eq!(document.text(), "");
    assert_eq!(multi.selections().len(), 1);
    let caret = document.undo().unwrap();
    assert_eq!(document.text(), "aa aa");
    assert!(caret <= document.len_chars());
    assert!(!document.is_dirty());
    let mut multi = all(&document, 0..2);
    multi
        .edit(&mut document, "", EditKind::DeleteForward)
        .unwrap();
    assert_eq!(document.text(), " ");
    document.undo();
    assert_eq!(document.text(), "aa aa");
}

#[test]
fn matching_and_deletion_never_split_graphemes_or_crlf() {
    let mut document = Document::new("e e\u{301} e 👩‍💻 👩‍💻\r\n");
    let multi = all(&document, 0..1);
    assert_eq!(multi.selections().len(), 2);
    let start = "e e\u{301} e ".chars().count();
    let mut multi = all(&document, start..start + 3);
    assert_eq!(multi.selections().len(), 2);
    multi.navigate(&document, 1, false).unwrap();
    multi.edit(&mut document, "", EditKind::Backspace).unwrap();
    assert_eq!(document.text(), "e e\u{301} e  \r\n");
    document.undo();
    assert!(!document.is_dirty());
    let mut multi = all(&document, document.len_chars() - 2..document.len_chars());
    multi.navigate(&document, 1, false).unwrap();
    multi.edit(&mut document, "", EditKind::Backspace).unwrap();
    assert!(!document.text().ends_with(['\r', '\n']));
    document.undo();
    assert!(document.text().ends_with("\r\n"));
}

#[test]
fn navigation_handles_wide_glyphs_tabs_direction_and_deduplication() {
    let document = Document::new("x\t猫\nx\t👩‍💻\nx\tz");
    let mut multi = Multi::default();
    multi.request(&document, 0..0, false).unwrap();
    multi.navigate(&document, 1, false).unwrap();
    multi.navigate(&document, 1, false).unwrap();
    assert_eq!(multi.primary().unwrap().head, 2);
    multi.navigate(&document, 3, false).unwrap();
    assert_eq!(multi.primary().unwrap().head, document.line_start(1) + 2);
    multi.navigate(&document, 1, true).unwrap();
    assert_eq!(
        multi.primary().unwrap().range(),
        document.line_start(1) + 2..document.line_start(1) + 5
    );
    multi.navigate(&document, 0, true).unwrap();
    assert!(multi.primary().unwrap().range().is_empty());
    let mut multi = all(&document, 0..1);
    multi.navigate(&document, 6, false).unwrap();
    assert_eq!(multi.selections().len(), 1);
}

#[test]
fn isolated_paste_save_and_navigation_separate_typing_runs() {
    let mut document = Document::new("x x");
    let mut multi = all(&document, 0..1);
    multi.edit(&mut document, "ab", EditKind::Isolated).unwrap();
    multi.edit(&mut document, "c", EditKind::Typing).unwrap();
    document.mark_saved();
    multi.edit(&mut document, "d", EditKind::Typing).unwrap();
    document.undo();
    assert_eq!(document.text(), "abc abc");
    assert!(!document.is_dirty());
    document.undo();
    assert_eq!(document.text(), "ab ab");
    document.undo();
    assert_eq!(document.text(), "x x");
}

#[test]
fn stale_oversized_and_excessive_matches_are_rejected_without_edits() {
    let mut document = Document::new("x ".repeat(MAX_SELECTIONS + 1).as_str());
    let mut multi = all(&document, 0..1);
    assert_eq!(multi.selections().len(), 1);
    assert!(multi.message.as_ref().unwrap().contains("1,000"));
    assert_eq!(document.revision(), 0);
    document.replace(0..1, "y").unwrap();
    let after = document.text();
    assert!(multi.edit(&mut document, "z", EditKind::Typing).is_err());
    assert_eq!(document.text(), after);
    let document = Document::new(&"x".repeat(MAX_SOURCE + 1));
    let mut multi = Multi::default();
    assert!(multi.request(&document, 0..1, true).is_err());
    let mut document = Document::new("x x");
    let mut multi = all(&document, 0..1);
    assert!(multi
        .edit(
            &mut document,
            &"a".repeat(MAX_BATCH_BYTES / 2 + 1),
            EditKind::Isolated
        )
        .is_err());
    assert_eq!(document.text(), "x x");
}

#[test]
fn private_selection_copy_navigation_and_noop_keep_access_real_edits_revoke_it() {
    let mut session = crate::session::Session::new("", None);
    session.open_private();
    session.active_mut().document.replace(0..0, "x x").unwrap();
    let reference = session.share_active().unwrap();
    let mut multi = all(&session.active().document, 0..1);
    assert_eq!(
        multi
            .copy_text(&session.active().document)
            .unwrap()
            .unwrap(),
        "x\nx"
    );
    assert!(!multi
        .edit(&mut session.active_mut().document, "x", EditKind::Isolated)
        .unwrap());
    assert!(crate::handoff::fetch(&reference).is_ok());
    multi
        .edit(&mut session.active_mut().document, "!", EditKind::Typing)
        .unwrap();
    assert!(crate::handoff::fetch(&reference).is_err());
    session.active_mut().document.undo();
    assert!(crate::handoff::fetch(&reference).is_err());
}

#[test]
fn find_can_adopt_different_length_and_zero_width_matches_atomically() {
    let mut document = Document::new("a longer\r\nz");
    let mut multi = Multi::default();
    multi.adopt(&document, &[0..1, 2..8, 10..11], 1).unwrap();
    multi.edit(&mut document, "X", EditKind::Typing).unwrap();
    assert_eq!(document.text(), "X X\r\nX");
    document.undo();
    assert_eq!(document.text(), "a longer\r\nz");
    assert!(!document.is_dirty());
    multi.adopt(&document, &[0..0, 10..10], 0).unwrap();
    multi.edit(&mut document, "> ", EditKind::Isolated).unwrap();
    assert_eq!(document.text(), "> a longer\r\n> z");
    document.undo();
    let old = multi.selections().to_vec();
    assert!(multi.adopt(&document, &[0..3, 2..4], 0).is_err());
    assert_eq!(multi.selections(), old);
    let document = Document::new("e\u{301}");
    assert!(multi
        .adopt(&document, std::slice::from_ref(&(0..1)), 0)
        .is_err());
}

#[test]
fn batch_typing_groups_are_bounded_and_never_absorb_single_cursor_input() {
    let mut document = Document::new("x x");
    let mut multi = all(&document, 0..1);
    for _ in 0..=crate::MAX_GROUP_EDITS {
        multi.edit(&mut document, "y", EditKind::Typing).unwrap();
    }
    document.undo();
    assert_eq!(
        document.text(),
        format!(
            "{} {}",
            "y".repeat(crate::MAX_GROUP_EDITS),
            "y".repeat(crate::MAX_GROUP_EDITS)
        )
    );
    document.undo();
    assert_eq!(document.text(), "x x");
    assert!(!document.is_dirty());
    let mut multi = all(&document, 0..1);
    multi.edit(&mut document, "a", EditKind::Typing).unwrap();
    document.edit(1..1, "!", EditKind::Typing).unwrap();
    document.undo();
    assert_eq!(document.text(), "a a");
    document.undo();
    assert_eq!(document.text(), "x x");
}

#[test]
fn input_and_navigation_wait_for_the_full_match_set_in_order() {
    let source = "cat category cat\ncat";
    let mut document = Document::new(source);
    let mut multi = Multi::default();
    multi.request(&document, 0..0, false).unwrap();
    multi.request(&document, 0..3, true).unwrap();
    multi.navigate(&document, 1, false).unwrap();
    multi.edit(&mut document, "", EditKind::Backspace).unwrap();
    multi.edit(&mut document, "", EditKind::Backspace).unwrap();
    assert_eq!(document.text(), source);
    assert!(multi.has_queued_input());
    assert!(multi.copy_text(&document).is_err());
    let deadline = Instant::now() + Duration::from_secs(3);
    while multi.busy() {
        multi.pump(&mut document);
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(document.text(), "c category c\nc");
    assert_eq!(multi.selections().len(), 3);
    document.undo();
    assert_eq!(document.text(), source);
    assert!(!document.is_dirty());
    let mut document = Document::new("x x");
    let mut multi = all(&document, 0..1);
    multi.request(&document, 0..1, false).unwrap();
    multi.edit(&mut document, "z", EditKind::Typing).unwrap();
    multi.pump(&mut document);
    assert_eq!(document.text(), "z z");
}

#[test]
fn rejected_all_matches_does_not_apply_queued_text_to_only_the_seed() {
    let source = "x ".repeat(MAX_SELECTIONS + 1);
    let mut document = Document::new(&source);
    let mut multi = Multi::default();
    multi.request(&document, 0..0, true).unwrap();
    multi.edit(&mut document, "data", EditKind::Typing).unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while multi.busy() {
        multi.pump(&mut document);
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(document.text(), source);
    assert!(!document.is_dirty());
    assert!(!multi.has_queued_input());
    assert!(multi.message.as_ref().unwrap().contains("1,000"));
}

#[test]
fn copied_lines_spread_to_moved_carets_without_duplication() {
    for newline in ["\n", "\r\n"] {
        let source = format!("foo{newline}{newline}foo{newline}{newline}");
        let mut document = Document::new(&source);
        let mut multi = all(&document, 0..3);
        let clipboard = multi.copy_text(&document).unwrap().unwrap();
        assert_eq!(clipboard, "foo\nfoo");
        multi.navigate(&document, 3, false).unwrap();
        assert!(multi.paste(&mut document, &clipboard).unwrap());
        assert_eq!(
            document.text(),
            format!("foo{newline}foo{newline}foo{newline}foo{newline}")
        );
        assert_eq!(multi.selections().len(), 2);
        document.undo();
        assert_eq!(document.text(), source);
        assert!(!document.is_dirty());
    }
}

#[test]
fn paste_preserves_fragments_unicode_empty_lines_and_explicit_newlines() {
    let mut document = Document::new("👩‍💻 x / x");
    let mut multi = all(&document, 4..5);
    multi.paste(&mut document, "я🦀\r\nß\n").unwrap();
    assert_eq!(document.text(), "👩‍💻 я🦀 / ß");
    assert_eq!(
        multi
            .selections()
            .iter()
            .map(|s| s.head)
            .collect::<Vec<_>>(),
        vec![6, 10]
    );
    document.undo();
    let mut multi = all(&document, 4..5);
    let selections = multi.selections().to_vec();
    assert!(!multi.paste(&mut document, "").unwrap());
    assert_eq!(multi.selections(), selections);
    multi.paste(&mut document, "\n\n").unwrap();
    assert_eq!(document.text(), "👩‍💻  / ");
    document.undo();
    let mut multi = all(&document, 4..5);
    multi.edit(&mut document, "\n", EditKind::Isolated).unwrap();
    assert_eq!(document.text(), "👩‍💻 \n / \n");
    document.undo();
    let mut multi = all(&document, 4..5);
    multi.paste(&mut document, "a\nb\nc").unwrap();
    assert_eq!(document.text(), "👩‍💻 a\nb\nc / a\nb\nc");
    let mut document = Document::new("x");
    let mut multi = all(&document, 0..1);
    multi.paste(&mut document, "one\r\ntwo\r\n").unwrap();
    assert_eq!(document.text(), "one\r\ntwo\r\n");
}

#[test]
fn queued_paste_distributes_after_the_match_count_is_known() {
    let mut document = Document::new("x x");
    let mut multi = Multi::default();
    multi.request(&document, 0..0, true).unwrap();
    multi.paste(&mut document, "left\nright").unwrap();
    assert_eq!(document.text(), "x x");
    let deadline = Instant::now() + Duration::from_secs(3);
    while multi.busy() {
        multi.pump(&mut document);
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(document.text(), "left right");
    document.undo();
    assert_eq!(document.text(), "x x");
    assert!(!document.is_dirty());
}
