use std::path::PathBuf;
use vibechar_core::session::Session;

#[test]
fn buffers_keep_independent_text_selection_and_history() {
    let mut session = Session::new("", None);
    session
        .active_mut()
        .document
        .replace(0..0, "Арт 👩‍💻")
        .unwrap();
    session.active_mut().selection = 2..3;
    session.open("", None);
    session
        .active_mut()
        .document
        .replace(0..0, "second")
        .unwrap();
    assert!(session.select(0));
    assert_eq!(session.active().document.text(), "Арт 👩‍💻");
    assert_eq!(session.active().selection, 2..3);
    session.active_mut().document.undo();
    assert!(session.select(1));
    assert_eq!(session.active().document.text(), "second");
    assert!(session.active().document.is_dirty());
}

#[test]
fn closing_requires_confirmation_and_never_leaves_an_empty_session() {
    let mut session = Session::new("keep", None);
    assert!(!session.close_active(false));
    assert_eq!(session.active().document.text(), "keep");
    assert!(session.close_active(true));
    assert_eq!(session.buffers().len(), 1);
    assert_eq!(session.active().label(), "Scratch 2");
    assert!(!session.has_unsaved());
}

#[test]
fn file_buffers_start_clean_and_hidden_edits_count_when_quitting() {
    let mut session = Session::new("loaded", Some(PathBuf::from("test.txt")));
    assert_eq!(session.active().label(), "test.txt");
    assert!(!session.has_unsaved());
    session.active_mut().document.replace(0..0, "!").unwrap();
    session.open("", None);
    assert!(!session.active().document.is_dirty());
    assert!(session.has_unsaved());
    assert!(!session.select(100));
    assert_eq!(session.active_index(), 1);
    session.close_active(false);
    assert_eq!(session.active().document.text(), "!loaded");
}
