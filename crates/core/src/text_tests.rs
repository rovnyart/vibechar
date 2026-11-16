use super::*;

#[test]
fn wrapped_rows_keep_graphemes_tabs_crlf_and_eof_caret() {
    for source in ["ab界c", "👩‍💻e\u{301}\tlast\r\nnext", "", "abcdefgh", "\t界"] {
        let d = Document::new(source);
        for width in [1, 3, 4, 7, 80] {
            for line in 0..d.line_count() {
                let mut joined = String::new();
                let mut row = 0;
                while let Some(w) = d.wrapped_window(line, row, width) {
                    assert_eq!(
                        d.wrapped_row_at(d.line_start(line) + w.character, width),
                        row
                    );
                    assert!(d.is_grapheme_boundary(d.line_start(line) + w.character));
                    joined.push_str(&w.text);
                    row += 1;
                    assert!(row <= source.len() + 1);
                }
                assert_eq!(joined, d.line(line));
                let last = d.wrapped_row_at(d.line_range(line).end, width);
                assert_eq!(last + 1, row);
            }
        }
    }
    let d = Document::new("ab界c");
    assert_eq!(d.wrapped_window(0, 0, 3).unwrap().text, "ab");
    assert_eq!(d.wrapped_window(0, 1, 3).unwrap().text, "界c");
    assert_eq!(d.wrapped_window(0, 2, 3).unwrap().text, "");
}

#[test]
fn sparse_wrapping_survives_edits_undo_and_width_changes() {
    let mut d = Document::new(&"x".repeat(512 * 1024));
    assert_eq!(d.wrapped_row_at(d.len_chars(), 4), 128 * 1024);
    assert!(
        d.layout.borrow().lines[0]
            .wrap
            .as_ref()
            .unwrap()
            .points
            .len()
            <= MAX_POINTS
    );
    let at = d.len_chars() - 10;
    d.replace(at..at, "界").unwrap();
    for width in [4, 9, 80] {
        let reference = Document::new(&d.text());
        for position in [0, at - 1, at, at + 1, d.len_chars()] {
            let row = d.wrapped_row_at(position, width);
            assert_eq!(row, reference.wrapped_row_at(position, width));
            assert_eq!(
                d.wrapped_window(0, row, width).unwrap().text,
                reference.wrapped_window(0, row, width).unwrap().text
            );
        }
    }
    d.undo();
    assert_eq!(d.wrapped_row_at(d.len_chars(), 4), 128 * 1024);
    assert!(!d.is_dirty());
}
use crate::{EditKind, TextEdit};
use unicode_segmentation::UnicodeSegmentation;

fn points(text: &str) -> Vec<Point> {
    let mut result = vec![Point::default()];
    for grapheme in text.graphemes(true) {
        let point = *result.last().unwrap();
        result.push(Point {
            byte: point.byte + grapheme.len(),
            character: point.character + grapheme.chars().count(),
            utf16: point.utf16 + grapheme.encode_utf16().count(),
            column: point.column + cell_width(grapheme, point.column),
        });
    }
    result
}

fn check_geometry(doc: &Document) {
    for line in 0..doc.line_count() {
        let text = doc.line(line);
        let reference = points(&text);
        for point in reference.iter().step_by((reference.len() / 63).max(1)) {
            assert_eq!(
                doc.display_column(doc.line_start(line) + point.character),
                point.column
            );
            let floor = *reference
                .iter()
                .rfind(|p| p.column <= point.column)
                .unwrap();
            assert_eq!(
                doc.position_at_column(line, point.column, false),
                doc.line_start(line) + floor.character
            );
        }
        for left in (0..reference.last().unwrap().column + 5).step_by((text.len() / 79).max(1)) {
            let start = *reference.iter().rfind(|p| p.column <= left).unwrap();
            let mut end_index = reference
                .partition_point(|p| p.column <= left + 19)
                .saturating_sub(1);
            if reference[end_index].column < left + 19 && end_index + 1 < reference.len() {
                end_index += 1;
            }
            let end = reference[end_index];
            let window = doc.line_window(line, left, 19);
            assert_eq!(window.text, text[start.byte..end.byte]);
            assert_eq!(
                (window.character, window.utf16, window.column),
                (start.character, start.utf16, start.column)
            );
        }
    }
}

#[test]
fn rope_chunk_navigation_matches_full_unicode_segmentation_at_every_scalar() {
    for padding in (890..1040).step_by(13) {
        let source = format!(
            "{}{}\r\n{}",
            "a".repeat(padding),
            "e\u{301}👩‍💻🇷🇺🇦🇲क्\u{200d}ष\u{600}界".repeat(80),
            "🇦".repeat(400)
        );
        let doc = Document::new(&source);
        let boundaries = points(&source)
            .into_iter()
            .map(|p| p.character)
            .collect::<Vec<_>>();
        for position in 0..=doc.len_chars() {
            let next = boundaries
                .get(boundaries.partition_point(|p| *p <= position))
                .copied()
                .unwrap_or(doc.len_chars());
            let previous = boundaries[boundaries
                .partition_point(|p| *p < position)
                .saturating_sub(1)];
            assert_eq!(
                doc.next_grapheme(position),
                next,
                "next at {position}, padding {padding}"
            );
            assert_eq!(
                doc.previous_grapheme(position),
                previous,
                "previous at {position}, padding {padding}"
            );
            assert_eq!(
                doc.is_grapheme_boundary(position),
                boundaries.binary_search(&position).is_ok()
            );
        }
    }
}

#[test]
fn long_emoji_and_indic_context_survives_many_rope_chunks() {
    for cluster in [
        format!("👩{}\u{200d}💻", "\u{301}".repeat(3000)),
        format!("क्{}ष", "\u{301}".repeat(3000)),
    ] {
        let source = format!("{}{}tail", "x".repeat(981), cluster);
        let doc = Document::new(&source);
        let end = 981 + cluster.chars().count();
        assert_eq!(doc.next_grapheme(981), end);
        assert_eq!(doc.previous_grapheme(end), 981);
        assert_eq!(doc.next_grapheme(end), end + 1);
        assert!(doc
            .line_window(0, 980, 5)
            .text
            .starts_with(&format!("x{cluster}")));
        check_geometry(&doc);
    }
}

#[test]
fn sparse_geometry_and_windows_preserve_unicode_offsets_tabs_and_endings() {
    let doc = Document::new(&format!(
        "{}\r\n\u{301}\t界👩‍💻\0\n",
        "a界e\u{301}👩‍💻\t".repeat(1400)
    ));
    let revision = doc.revision();
    check_geometry(&doc);
    assert_eq!(doc.revision(), revision);
    assert!(!doc.is_dirty());
    assert!(doc.undo.is_empty());
    for (column, floor, nearest) in [(1, 0, 1), (2, 1, 1), (3, 1, 2), (4, 2, 2)] {
        let doc = Document::new("界界");
        assert_eq!(doc.position_at_column(0, column, false), floor);
        assert_eq!(doc.position_at_column(0, column, true), nearest);
    }
}

#[test]
fn edits_batch_undo_and_redo_invalidate_only_valid_line_prefixes() {
    let mut doc = Document::new(&format!(
        "{}e\u{301}👩‍💻\tZ\r\nsecond\r\nthird",
        "a".repeat(15000)
    ));
    check_geometry(&doc);
    let boundary = doc
        .layout
        .borrow()
        .lines
        .iter()
        .find(|l| l.index == 0)
        .unwrap()
        .points[1]
        .character;
    // Insert a combining mark exactly at a cached boundary: the previous ASCII
    // scalar now belongs to the new composed character.
    doc.replace(boundary..boundary, "\u{301}").unwrap();
    check_geometry(&doc);
    doc.undo();
    check_geometry(&doc);
    doc.redo();
    check_geometry(&doc);
    doc.replace(2..7, "\n界\r\n").unwrap();
    check_geometry(&doc);
    let end = doc.len_chars();
    doc.replace_many(&[
        TextEdit {
            range: 0..1,
            text: "👩‍💻".into(),
        },
        TextEdit {
            range: end - 3..end,
            text: "tail\n".into(),
        },
    ])
    .unwrap();
    check_geometry(&doc);
    doc.undo();
    check_geometry(&doc);
    doc.redo();
    check_geometry(&doc);
    doc.replace(0..doc.len_chars(), "").unwrap();
    check_geometry(&doc);
    doc.undo();
    check_geometry(&doc);
}

#[test]
fn tail_typing_reuses_prefix_checkpoints_and_noops_keep_cached_geometry() {
    let mut doc = Document::new(&"x".repeat(1024 * 1024));
    assert_eq!(doc.display_column(doc.len_chars()), doc.len_chars());
    let count = doc.layout.borrow().lines[0].points.len();
    let end = doc.len_chars();
    doc.edit(end..end, "界", EditKind::Typing).unwrap();
    assert_eq!(doc.layout.borrow().lines[0].points.len(), count - 1);
    assert_eq!(doc.display_column(doc.len_chars()), end + 2);
    let after = doc.layout.borrow().lines[0].points.len();
    assert!(!doc.replace(0..0, "").unwrap());
    assert!(doc.replace(0..usize::MAX, "bad").is_err());
    assert_eq!(doc.layout.borrow().lines[0].points.len(), after);
    doc.undo();
    assert_eq!(doc.display_column(doc.len_chars()), end);
    doc.redo();
    assert_eq!(doc.display_column(doc.len_chars()), end + 2);
}

#[test]
fn geometry_cache_coarsens_and_evicts_with_fixed_metadata_budgets() {
    let doc = Document::new(&format!(
        "{}\n{}",
        "x".repeat(24 * 1024 * 1024),
        "tail\n".repeat(12)
    ));
    assert_eq!(doc.display_column(doc.line_range(0).end), 24 * 1024 * 1024);
    {
        let cache = doc.layout.borrow();
        assert!(cache.lines[0].stride > STRIDE);
        assert!(cache.lines[0].points.len() <= MAX_POINTS);
        assert!(cache.lines[0].points.capacity() <= MAX_POINTS);
    }
    for line in 1..doc.line_count() {
        doc.line_window(line, 0, 10);
    }
    assert_eq!(doc.layout.borrow().lines.len(), MAX_LINES);
    assert!(!doc.layout.borrow().lines.iter().any(|l| l.index == 0));
    assert_eq!(doc.line_window(0, 24 * 1024 * 1024 - 7, 7).text, "xxxxxxx");
}
