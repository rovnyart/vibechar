use super::*;

fn result(engine: &Engine, document: &Document) -> Arc<Frame> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(frame) = engine.frame(document, 0) {
            return frame;
        }
        assert!(Instant::now() < deadline, "search worker did not finish");
        thread::sleep(Duration::from_millis(2));
    }
}
fn query(needle: &str, replacement: Option<&str>, regex: bool) -> Query {
    Query {
        needle: needle.into(),
        replacement: replacement.map(str::to_owned),
        regex,
        case_sensitive: false,
        whole_graphemes: false,
        whole_words: false,
    }
}
#[test]
fn literal_unicode_case_utf16_and_metadata_are_correct() {
    let doc = Document::new("👩‍💻 Я я [x] PRIVATE_FIND_FIXTURE");
    let mut engine = Engine::new().unwrap();
    engine.submit(&doc, query("Я", None, false));
    let frame = result(&engine, &doc);
    assert_eq!(frame.matches.len(), 2);
    assert_eq!(
        (frame.matches[0].start, frame.matches[0].utf16_start),
        (4, 6)
    );
    let encoded = String::from_utf8(frame.encoded.clone()).unwrap();
    assert!(!encoded.contains("PRIVATE_FIND_FIXTURE"));
    assert_eq!(doc.revision(), 0);
    engine.submit(&doc, query("[x]", None, false));
    assert_eq!(result(&engine, &doc).matches.len(), 1);
}
#[test]
fn regex_groups_preview_apply_and_single_undo_are_shared() {
    let mut doc = Document::new("a=1\r\nb=22\r\n");
    let mut engine = Engine::new().unwrap();
    engine.submit(
        &doc,
        query(r"(?P<key>\w+)=(\d+)", Some("${key}: $2 $$"), true),
    );
    let frame = result(&engine, &doc);
    assert_eq!((frame.matches.len(), frame.changed), (2, 2));
    assert_eq!(frame.examples[0].after, "a: 1 $");
    let revision = doc.revision();
    assert!(engine.apply(&mut doc, frame.serial, None).unwrap().0);
    assert_eq!(doc.text(), "a: 1 $\r\nb: 22 $\r\n");
    assert_eq!(doc.revision(), revision + 1);
    doc.undo().unwrap();
    assert_eq!(doc.text(), "a=1\r\nb=22\r\n");
    assert!(!doc.is_dirty());
    doc.redo().unwrap();
    assert_eq!(doc.text(), "a: 1 $\r\nb: 22 $\r\n");
}
#[test]
fn plans_reject_edits_undo_new_queries_and_other_documents() {
    let mut doc = Document::new("foo foo");
    let mut engine = Engine::new().unwrap();
    engine.submit(&doc, query("foo", Some("bar"), false));
    let frame = result(&engine, &doc);
    engine.submit(&doc, query("foo", Some("NEW"), false));
    assert!(engine.apply(&mut doc, frame.serial, None).is_err());
    let frame = result(&engine, &doc);
    doc.replace(0..0, "!").unwrap();
    doc.undo();
    assert!(engine.apply(&mut doc, frame.serial, None).is_err());
    let mut other = Document::new("foo foo");
    assert!(engine.apply(&mut other, frame.serial, None).is_err());
    assert_eq!(other.text(), "foo foo");
}
#[test]
fn zero_width_errors_and_limits_do_not_apply_partial_results() {
    let mut engine = Engine::new().unwrap();
    let mut doc = Document::new("a\nb\n");
    engine.submit(&doc, query("^", Some(">"), true));
    let frame = result(&engine, &doc);
    engine.apply(&mut doc, frame.serial, None).unwrap();
    assert_eq!(doc.text(), ">a\n>b\n>");
    doc.undo();
    for q in [query("[", Some("x"), true), query("a", Some("$9"), true)] {
        engine.submit(&doc, q);
        let frame = result(&engine, &doc);
        assert!(frame.error.is_some());
        assert!(engine.apply(&mut doc, frame.serial, None).is_err());
        assert_eq!(doc.text(), "a\nb\n");
    }
    let mut many = Document::new(&"a".repeat(MAX_MATCHES + 1));
    engine.submit(&many, query("a", Some("b"), false));
    let frame = result(&engine, &many);
    assert!(frame.limited);
    assert!(engine.apply(&mut many, frame.serial, None).is_err());
    assert_eq!(many.revision(), 0);
}
#[test]
fn batches_validate_before_mutating_and_noop_preserves_revision() {
    let mut doc = Document::new("hello");
    let edit = |range, text: &str| TextEdit {
        range,
        text: text.into(),
    };
    assert!(doc
        .replace_many(&[edit(0..1, "x"), edit(0..2, "y")])
        .is_err());
    assert_eq!(doc.text(), "hello");
    assert_eq!(doc.revision(), 0);
    assert!(!doc.replace_many(&[edit(0..5, "hello")]).unwrap());
    assert_eq!(doc.revision(), 0);
    let mut engine = Engine::new().unwrap();
    engine.submit(&doc, query("l", Some("l"), false));
    let frame = result(&engine, &doc);
    assert!(!engine.apply(&mut doc, frame.serial, None).unwrap().0);
    assert!(!doc.is_dirty());
    assert!(doc.undo().is_none());
}

#[test]
fn private_search_and_noop_keep_grants_but_a_real_batch_revokes_them() {
    let mut session = crate::session::Session::new("", None);
    session.open_private();
    session
        .active_mut()
        .document
        .replace(0..0, "PRIVATE_BATCH_FIXTURE x x")
        .unwrap();
    let reference = session.share_active().unwrap();
    let mut engine = Engine::new().unwrap();
    engine.submit(&session.active().document, query(" x", Some(" x"), false));
    let frame = result(&engine, &session.active().document);
    assert!(
        !engine
            .apply(&mut session.active_mut().document, frame.serial, None)
            .unwrap()
            .0
    );
    assert!(crate::handoff::fetch(&reference).is_ok());
    engine.submit(&session.active().document, query(" x", Some(" y"), false));
    let frame = result(&engine, &session.active().document);
    engine
        .apply(&mut session.active_mut().document, frame.serial, None)
        .unwrap();
    assert!(crate::handoff::fetch(&reference).is_err());
    session.active_mut().document.undo();
    assert!(crate::handoff::fetch(&reference).is_err());
}
