use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicUsize, Ordering},
};
use vibechar_core::{checkpoint::Checkpoint, session::Session};

static SEQUENCE: AtomicUsize = AtomicUsize::new(0);

#[test]
fn backward_selection_head_round_trips_and_invalid_heads_are_rejected() {
    let directory = TemporaryDirectory::new();
    let mut session = Session::new("hello 👩‍💻", None);
    session.active_mut().selection = 1..5;
    session.active_mut().selection_head = Some(1);
    Checkpoint::capture(&session)
        .save(&directory.file())
        .unwrap();
    let restored = Checkpoint::load(&directory.file()).unwrap().unwrap();
    assert_eq!(restored.active().selection, 1..5);
    assert_eq!(restored.active().selection_head, Some(1));
    let mut json: serde_json::Value =
        serde_json::from_slice(&fs::read(directory.file()).unwrap()).unwrap();
    json["buffers"][0]["selection_head"] = serde_json::json!(3);
    fs::write(directory.file(), serde_json::to_vec(&json).unwrap()).unwrap();
    assert!(Checkpoint::load(&directory.file()).is_err());
}

#[test]
fn language_pins_restore_without_marking_text_dirty_and_private_pins_are_excluded() {
    let directory = TemporaryDirectory::new();
    let mut session = Session::new("a fragment", None);
    let revision = session.active().document.revision();
    let dirty = session.active().document.is_dirty();
    assert!(session.set_language("Python"));
    assert_eq!(session.active().document.revision(), revision);
    assert_eq!(session.active().document.is_dirty(), dirty);
    session.open_private();
    assert!(session.set_language("Swift"));
    let snapshot = Checkpoint::capture(&session);
    let encoded = serde_json::to_string(&snapshot).unwrap();
    assert!(encoded.contains("Python") && !encoded.contains("Swift"));
    snapshot.save(&directory.file()).unwrap();
    let mut restored = Checkpoint::load(&directory.file()).unwrap().unwrap();
    assert_eq!(restored.language(), Some("Python"));
    assert!(restored.set_language(""));
    assert_eq!(restored.language(), None);
    assert!(!restored.set_language("unknown-language-xyz"));
}

#[test]
fn private_text_and_paths_never_enter_checkpoints_and_active_indices_are_remapped() {
    let directory = TemporaryDirectory::new();
    let mut session = Session::new("public first", None);
    session.open_private();
    session
        .active_mut()
        .document
        .replace(0..0, "PRIVATE_FIXTURE_👩‍💻")
        .unwrap();
    session.active_mut().path = Some(PathBuf::from("/private-fixture/path-that-must-not-persist"));
    session.active_mut().document.mark_saved();
    assert!(!session.active().label().contains("FIXTURE"));
    assert!(session.active().needs_close_confirmation());
    assert!(session.has_private_text());
    session.open("public last", None);
    session.active_mut().selection = 3..3;
    let snapshot = Checkpoint::capture(&session);
    let encoded = serde_json::to_string(&snapshot).unwrap();
    assert!(!encoded.contains("PRIVATE_FIXTURE"));
    assert!(!encoded.contains("path-that-must-not-persist"));
    snapshot.save(&directory.file()).unwrap();
    let restored = Checkpoint::load(&directory.file()).unwrap().unwrap();
    assert_eq!(restored.buffers().len(), 2);
    assert_eq!(restored.active_index(), 1);
    assert_eq!(restored.active().document.text(), "public last");
    assert_eq!(restored.active().selection, 3..3);
    assert!(!restored.has_private_text());
    assert!(restored.buffers().iter().all(|buffer| !buffer.is_private()));
    session.select(1); // Private active: restart falls back to the preceding public tab.
    Checkpoint::capture(&session)
        .save(&directory.file())
        .unwrap();
    let restored = Checkpoint::load(&directory.file()).unwrap().unwrap();
    assert_eq!(restored.active().document.text(), "public first");
    assert!(!session.close_active(false));
    assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
}

#[test]
fn a_private_only_session_recovers_as_a_fresh_empty_public_scratch() {
    let directory = TemporaryDirectory::new();
    let mut session = Session::new("", None);
    session.open_private();
    session
        .active_mut()
        .document
        .replace(0..0, "PRIVATE_ONLY_FIXTURE")
        .unwrap();
    session.select(0);
    assert!(session.close_active(false));
    assert!(session.active().is_private());
    let snapshot = Checkpoint::capture(&session);
    assert!(!serde_json::to_string(&snapshot)
        .unwrap()
        .contains("PRIVATE_ONLY_FIXTURE"));
    snapshot.save(&directory.file()).unwrap();
    let restored = Checkpoint::load(&directory.file()).unwrap().unwrap();
    assert_eq!(restored.buffers().len(), 1);
    assert!(restored.active().document.text().is_empty());
    assert!(!restored.active().is_private());
    // The private tab may also precede every retained public tab.
    session.open("retained", None);
    session.select(0);
    Checkpoint::capture(&session)
        .save(&directory.file())
        .unwrap();
    assert_eq!(
        Checkpoint::load(&directory.file())
            .unwrap()
            .unwrap()
            .active()
            .document
            .text(),
        "retained"
    );
}

struct TemporaryDirectory(PathBuf);
impl TemporaryDirectory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "vibechar-recovery-test-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn file(&self) -> PathBuf {
        self.0.join("session.json")
    }
}
impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

#[test]
fn restore_keeps_tabs_order_selection_labels_and_file_dirty_state() {
    let directory = TemporaryDirectory::new();
    let mut session = Session::new("Арт 👩‍💻\r\n\0", None);
    session.active_mut().selection = 4..7;
    session.open("saved file", Some(PathBuf::from("/tmp/original.txt")));
    session.open("modified file", Some(PathBuf::from("/tmp/other.txt")));
    session.active_mut().document.replace(0..0, "!").unwrap();
    session.select(0);
    Checkpoint::capture(&session)
        .save(&directory.file())
        .unwrap();
    let mut restored = Checkpoint::load(&directory.file()).unwrap().unwrap();
    assert_eq!(restored.buffers().len(), 3);
    assert_eq!(restored.active_index(), 0);
    assert_eq!(restored.active().document.text(), "Арт 👩‍💻\r\n\0");
    assert_eq!(restored.active().selection, 4..7);
    assert!(restored.active().document.is_dirty());
    assert_eq!(restored.active_mut().document.undo(), None);
    restored.select(1);
    assert!(!restored.active().document.is_dirty());
    assert_eq!(
        restored.active().path,
        Some(PathBuf::from("/tmp/original.txt"))
    );
    restored.select(2);
    assert!(restored.active().document.is_dirty());
    restored.open("", None);
    assert_eq!(restored.active().label(), "Scratch 2");
}

#[test]
fn captured_text_is_immutable_while_the_live_document_keeps_changing() {
    let directory = TemporaryDirectory::new();
    let mut session = Session::new("first", None);
    let checkpoint = Checkpoint::capture(&session);
    session
        .active_mut()
        .document
        .replace(0..5, "second")
        .unwrap();
    let path = directory.file();
    std::thread::spawn(move || checkpoint.save(&path).unwrap())
        .join()
        .unwrap();
    assert_eq!(session.active().document.text(), "second");
    assert_eq!(
        Checkpoint::load(&directory.file())
            .unwrap()
            .unwrap()
            .active()
            .document
            .text(),
        "first"
    );
}

#[test]
fn closed_tabs_do_not_reappear_and_corruption_is_never_replaced_on_read() {
    let directory = TemporaryDirectory::new();
    let mut session = Session::new("keep", None);
    session.open("discard", None);
    session.close_active(true);
    Checkpoint::capture(&session)
        .save(&directory.file())
        .unwrap();
    assert_eq!(
        Checkpoint::load(&directory.file())
            .unwrap()
            .unwrap()
            .buffers()
            .len(),
        1
    );
    let corrupt = b"{interrupted";
    fs::write(directory.file(), corrupt).unwrap();
    assert!(Checkpoint::load(&directory.file()).is_err());
    assert_eq!(fs::read(directory.file()).unwrap(), corrupt);
}

#[test]
fn an_invalid_active_tab_is_rejected_before_constructing_a_session() {
    let directory = TemporaryDirectory::new();
    let session = Session::new("keep", None);
    Checkpoint::capture(&session)
        .save(&directory.file())
        .unwrap();
    let mut data: serde_json::Value =
        serde_json::from_slice(&fs::read(directory.file()).unwrap()).unwrap();
    data["active"] = serde_json::json!(100);
    let bytes = serde_json::to_vec(&data).unwrap();
    fs::write(directory.file(), &bytes).unwrap();
    assert!(Checkpoint::load(&directory.file()).is_err());
    assert_eq!(fs::read(directory.file()).unwrap(), bytes);
}

#[cfg(unix)]
#[test]
fn recovery_files_are_owner_only_and_failed_replacement_keeps_previous_data() {
    use std::os::unix::fs::PermissionsExt;
    let directory = TemporaryDirectory::new();
    let session = Session::new("keep", None);
    Checkpoint::capture(&session)
        .save(&directory.file())
        .unwrap();
    assert_eq!(
        fs::metadata(directory.file()).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let blocked = directory.0.join("blocked");
    fs::create_dir(&blocked).unwrap();
    fs::write(blocked.join("sentinel"), "keep").unwrap();
    assert!(Checkpoint::capture(&session).save(&blocked).is_err());
    assert_eq!(
        fs::read_to_string(blocked.join("sentinel")).unwrap(),
        "keep"
    );
    assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 2);
}
