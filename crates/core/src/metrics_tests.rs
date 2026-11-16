use super::*;
use unicode_segmentation::UnicodeSegmentation;

fn ready(engine: &Engine, doc: &Document) -> Frame {
    let end = Instant::now() + Duration::from_secs(5);
    loop {
        let frame = engine.frame(doc).unwrap();
        if !frame.busy {
            return frame;
        }
        assert!(Instant::now() < end);
        thread::sleep(Duration::from_millis(2));
    }
}
#[test]
fn visible_characters_unicode_words_crlf_and_empty_text() {
    for source in [
        "",
        "foo_bar 123\nПривет 👩‍💻e\u{301}\r\n",
        "🇦🇲🇷🇺 café 中 文",
        "x".repeat(1023).as_str(),
    ] {
        let doc = Document::new(source);
        let mut e = Engine::default();
        e.submit(&doc, std::slice::from_ref(&(0..doc.len_chars())));
        let f = ready(&e, &doc);
        assert_eq!(f.total.characters, Some(source.graphemes(true).count()));
        assert_eq!(f.selected.characters, f.total.characters);
        assert_eq!(f.total.bytes, source.len());
        assert_eq!(
            f.selected.lines,
            if source.is_empty() {
                0
            } else {
                doc.line_index(doc.len_chars().saturating_sub(1)) + 1
            }
        );
    }
    let doc = Document::new("foo_bar 123 Привет 👩‍💻e\u{301}");
    let mut e = Engine::default();
    e.submit(&doc, std::slice::from_ref(&(0..0)));
    assert_eq!(ready(&e, &doc).total.words, Some(4));
}
#[test]
fn overlapping_ranges_and_lines_are_counted_once_but_targets_remain_visible() {
    let doc = Document::new("foo\r\nbar\r\nlast");
    let mut e = Engine::default();
    e.submit(&doc, &[0..5, 2..8, 5..8, 10..10]);
    let f = ready(&e, &doc);
    assert_eq!(f.selected.bytes, 8);
    assert_eq!(f.selected.characters, Some(7));
    assert_eq!(f.selected.lines, 2);
    assert_eq!((f.targets, f.selections, f.carets), (4, 3, 1));
    let serial = f.serial;
    e.submit(&doc, &[0..5, 2..8, 5..8, 10..10]);
    assert_eq!(e.frame(&doc).unwrap().serial, serial);
}
#[test]
fn chunks_and_async_revisions_never_publish_stale_counts() {
    let source = ("x".repeat(1018) + "👩‍💻e\u{301}\r\n").repeat(300);
    let mut doc = Document::new(&source);
    let mut e = Engine::default();
    e.submit(&doc, std::slice::from_ref(&(0..doc.len_chars())));
    let f = ready(&e, &doc);
    assert_eq!(f.total.characters, Some(source.graphemes(true).count()));
    e.submit(&doc, std::slice::from_ref(&(0..1)));
    assert_eq!(e.frame(&doc).unwrap().selected.characters, Some(1));
    doc.replace(0..doc.len_chars(), "new").unwrap();
    assert!(e.frame(&doc).is_none());
    e.submit(&doc, std::slice::from_ref(&(0..0)));
    let f = ready(&e, &doc);
    assert_eq!(f.total.characters, Some(3));
    assert_eq!(f.total.words, Some(1));
    assert_eq!(f.revision, doc.revision());
    assert_eq!(doc.text(), "new");
}
#[test]
fn cancellation_and_disposal_release_pending_snapshots() {
    let mut e = Engine::default();
    let large = Document::new(&"abc ".repeat(512 * 1024));
    e.submit(&large, std::slice::from_ref(&(0..large.len_chars())));
    let small = Document::new("👩‍💻");
    e.submit(&small, std::slice::from_ref(&(0..small.len_chars())));
    let f = ready(&e, &small);
    assert_eq!(f.total.characters, Some(1));
    assert_eq!(f.selected.characters, Some(1));
    drop(e);
}
