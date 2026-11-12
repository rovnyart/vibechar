//! Thread-confined, copy-in/copy-out C boundary. See include/vibechar.h for ownership.
#![allow(clippy::missing_safety_doc)]

use std::{
    panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf,
    ptr, slice, str,
};
use vibechar_core::{checkpoint::Checkpoint, session::Session, Document};

pub type VcDocument = Document;

fn guard<T: Default>(operation: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(operation)).unwrap_or_default()
}

unsafe fn input<'a>(data: *const u8, length: usize) -> Option<&'a str> {
    if length == 0 {
        return Some("");
    }
    if data.is_null() || length > isize::MAX as usize {
        return None;
    }
    str::from_utf8(slice::from_raw_parts(data, length)).ok()
}

#[no_mangle]
pub unsafe extern "C" fn vc_document_new(text: *const u8, length: usize) -> *mut VcDocument {
    guard(|| {
        input(text, length).map_or(ptr::null_mut(), |text| {
            Box::into_raw(Box::new(Document::new(text)))
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_document_free(document: *mut VcDocument) {
    if !document.is_null() {
        guard(|| drop(Box::from_raw(document)));
    }
}

#[no_mangle]
pub unsafe extern "C" fn vc_document_length(document: *const VcDocument) -> usize {
    guard(|| document.as_ref().map_or(0, |doc| doc.len_bytes()))
}

#[no_mangle]
pub unsafe extern "C" fn vc_document_copy(
    document: *const VcDocument,
    output: *mut u8,
    capacity: usize,
) -> bool {
    guard(|| {
        let Some(doc) = document.as_ref() else {
            return false;
        };
        let length = doc.len_bytes();
        if length > capacity || capacity > isize::MAX as usize {
            return false;
        }
        if length == 0 {
            return true;
        }
        if output.is_null() {
            return false;
        }
        let destination = slice::from_raw_parts_mut(output, length);
        doc.write_to(destination).is_ok()
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_document_replace(
    document: *mut VcDocument,
    start: usize,
    length: usize,
    replacement: *const u8,
    replacement_length: usize,
) -> bool {
    vc_document_edit(document, start, length, replacement, replacement_length, 0)
}

#[no_mangle]
pub unsafe extern "C" fn vc_document_edit(
    document: *mut VcDocument,
    start: usize,
    length: usize,
    replacement: *const u8,
    replacement_length: usize,
    kind: u32,
) -> bool {
    guard(|| {
        use vibechar_core::EditKind;
        let kind = match kind {
            0 => EditKind::Isolated,
            1 => EditKind::Typing,
            2 => EditKind::Backspace,
            3 => EditKind::DeleteForward,
            _ => return false,
        };
        let Some(doc) = document.as_mut() else {
            return false;
        };
        let Some(text) = input(replacement, replacement_length) else {
            return false;
        };
        let Some(end) = start.checked_add(length) else {
            return false;
        };
        let (Ok(start), Ok(end)) = (doc.char_from_utf16(start), doc.char_from_utf16(end)) else {
            return false;
        };
        doc.edit(start..end, text, kind).is_ok()
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_document_break_undo_group(document: *mut VcDocument) {
    guard(|| {
        if let Some(doc) = document.as_mut() {
            doc.break_undo_group();
        }
    });
}

unsafe fn history(document: *mut VcDocument, cursor: *mut usize, redo: bool) -> bool {
    guard(|| {
        let (Some(doc), Some(cursor)) = (document.as_mut(), cursor.as_mut()) else {
            return false;
        };
        let position = if redo { doc.redo() } else { doc.undo() };
        let Some(position) = position else {
            return false;
        };
        let Ok(offset) = doc.utf16_from_char(position) else {
            return false;
        };
        *cursor = offset;
        true
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_document_undo(document: *mut VcDocument, cursor: *mut usize) -> bool {
    history(document, cursor, false)
}

#[no_mangle]
pub unsafe extern "C" fn vc_document_redo(document: *mut VcDocument, cursor: *mut usize) -> bool {
    history(document, cursor, true)
}

#[no_mangle]
pub unsafe extern "C" fn vc_document_dirty(document: *const VcDocument) -> bool {
    guard(|| document.as_ref().is_some_and(|doc| doc.is_dirty()))
}

#[no_mangle]
pub unsafe extern "C" fn vc_document_mark_saved(document: *mut VcDocument) {
    guard(|| {
        if let Some(doc) = document.as_mut() {
            doc.mark_saved();
        }
    });
}

#[no_mangle]
pub extern "C" fn vc_session_new() -> *mut Session {
    guard(|| Box::into_raw(Box::new(Session::new("", None))))
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_free(session: *mut Session) {
    if !session.is_null() {
        guard(|| drop(Box::from_raw(session)));
    }
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_count(session: *const Session) -> usize {
    guard(|| {
        session
            .as_ref()
            .map_or(0, |session| session.buffers().len())
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_active(session: *const Session) -> usize {
    guard(|| session.as_ref().map_or(0, Session::active_index))
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_select(session: *mut Session, index: usize) -> bool {
    guard(|| {
        session
            .as_mut()
            .is_some_and(|session| session.select(index))
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_open(
    session: *mut Session,
    text: *const u8,
    length: usize,
    path: *const u8,
    path_length: usize,
) -> bool {
    guard(|| {
        let (Some(session), Some(text), Some(path)) = (
            session.as_mut(),
            input(text, length),
            input(path, path_length),
        ) else {
            return false;
        };
        session.open(
            text,
            if path.is_empty() {
                None
            } else {
                Some(PathBuf::from(path))
            },
        );
        true
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_open_private(session: *mut Session) -> bool {
    guard(|| {
        let Some(session) = session.as_mut() else {
            return false;
        };
        session.open_private();
        true
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_buffer_private(session: *const Session, index: usize) -> bool {
    guard(|| {
        session
            .as_ref()
            .and_then(|session| session.buffers().get(index))
            .is_some_and(|buffer| buffer.is_private())
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_has_private_text(session: *const Session) -> bool {
    guard(|| session.as_ref().is_some_and(Session::has_private_text))
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_needs_close_confirmation(session: *const Session) -> bool {
    guard(|| {
        session
            .as_ref()
            .is_some_and(|session| session.active().needs_close_confirmation())
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_share(session: *mut Session) -> i32 {
    guard(|| {
        let Some(session) = session.as_mut() else {
            return 0;
        };
        match session.share_active() {
            Ok(_) => 1,
            Err(error) if error.kind() == std::io::ErrorKind::InvalidInput => 2,
            Err(_) => 0,
        }
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_session_drop_active(session: *const Session) -> bool {
    guard(|| {
        session
            .as_ref()
            .is_some_and(|s| s.active().document.drop_uses().is_some())
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_session_has_drop_access(session: *const Session) -> bool {
    guard(|| session.as_ref().is_some_and(Session::has_drop_access))
}
#[no_mangle]
pub unsafe extern "C" fn vc_session_drop_uses(session: *const Session) -> u64 {
    guard(|| {
        session
            .as_ref()
            .and_then(|s| s.active().document.drop_uses())
            .unwrap_or(0)
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_session_revoke_drop(session: *mut Session) {
    guard(|| {
        if let Some(session) = session.as_mut() {
            session.active_mut().document.revoke_drop();
        }
    });
}
#[no_mangle]
pub unsafe extern "C" fn vc_session_revoke_all_drops(session: *mut Session) {
    guard(|| {
        if let Some(session) = session.as_mut() {
            session.revoke_all_drops();
        }
    });
}
#[no_mangle]
pub unsafe extern "C" fn vc_session_drop_instruction(
    session: *const Session,
    executable: *const u8,
    length: usize,
    output: *mut u8,
    capacity: usize,
) -> usize {
    guard(|| {
        let (Some(session), Some(executable)) = (session.as_ref(), input(executable, length))
        else {
            return 0;
        };
        session
            .drop_instruction(executable)
            .map_or(0, |text| copy_metadata(&text, output, capacity))
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_close(session: *mut Session, discard: bool) -> bool {
    guard(|| {
        session
            .as_mut()
            .is_some_and(|session| session.close_active(discard))
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_has_unsaved(session: *const Session) -> bool {
    guard(|| session.as_ref().is_some_and(Session::has_unsaved))
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_buffer_dirty(session: *const Session, index: usize) -> bool {
    guard(|| {
        session
            .as_ref()
            .and_then(|session| session.buffers().get(index))
            .is_some_and(|buffer| buffer.document.is_dirty())
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_buffer_is_file(session: *const Session, index: usize) -> bool {
    guard(|| {
        session
            .as_ref()
            .and_then(|session| session.buffers().get(index))
            .is_some_and(|buffer| buffer.path.is_some())
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_document(session: *mut Session) -> *mut VcDocument {
    guard(|| {
        session.as_mut().map_or(ptr::null_mut(), |session| {
            &mut session.active_mut().document
        })
    })
}

unsafe fn copy_metadata(text: &str, output: *mut u8, capacity: usize) -> usize {
    if !output.is_null() && capacity >= text.len() && capacity <= isize::MAX as usize {
        ptr::copy_nonoverlapping(text.as_ptr(), output, text.len());
    }
    text.len()
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_label(
    session: *const Session,
    index: usize,
    output: *mut u8,
    capacity: usize,
) -> usize {
    guard(|| {
        session
            .as_ref()
            .and_then(|session| session.buffers().get(index))
            .map_or(0, |buffer| copy_metadata(&buffer.label(), output, capacity))
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_path(
    session: *const Session,
    output: *mut u8,
    capacity: usize,
) -> usize {
    guard(|| {
        session
            .as_ref()
            .and_then(|session| session.active().path.as_ref())
            .map_or(0, |path| {
                copy_metadata(&path.to_string_lossy(), output, capacity)
            })
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_set_path(
    session: *mut Session,
    path: *const u8,
    length: usize,
) -> bool {
    guard(|| {
        let (Some(session), Some(path)) = (session.as_mut(), input(path, length)) else {
            return false;
        };
        session.active_mut().path = if path.is_empty() {
            None
        } else {
            Some(PathBuf::from(path))
        };
        true
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_complete_save(
    session: *mut Session,
    path: *const u8,
    length: usize,
) -> bool {
    guard(|| {
        let (Some(session), Some(path)) = (session.as_mut(), input(path, length)) else {
            return false;
        };
        if path.is_empty() || path.contains('\0') {
            return false;
        }
        session.complete_save(PathBuf::from(path));
        true
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_set_selection(
    session: *mut Session,
    start: usize,
    length: usize,
) -> bool {
    guard(|| {
        let Some(buffer) = session.as_mut().map(Session::active_mut) else {
            return false;
        };
        let Some(end) = start.checked_add(length) else {
            return false;
        };
        let (Ok(start), Ok(end)) = (
            buffer.document.char_from_utf16(start),
            buffer.document.char_from_utf16(end),
        ) else {
            return false;
        };
        buffer.selection = start..end;
        true
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_selection(
    session: *const Session,
    start: *mut usize,
    length: *mut usize,
) -> bool {
    guard(|| {
        let (Some(buffer), Some(start), Some(length)) = (
            session.as_ref().map(Session::active),
            start.as_mut(),
            length.as_mut(),
        ) else {
            return false;
        };
        let (Ok(first), Ok(end)) = (
            buffer.document.utf16_from_char(buffer.selection.start),
            buffer.document.utf16_from_char(buffer.selection.end),
        ) else {
            return false;
        };
        *start = first;
        *length = end - first;
        true
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_checkpoint(session: *const Session) -> *mut Checkpoint {
    guard(|| {
        session.as_ref().map_or(ptr::null_mut(), |session| {
            Box::into_raw(Box::new(Checkpoint::capture(session)))
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_checkpoint_free(checkpoint: *mut Checkpoint) {
    if !checkpoint.is_null() {
        guard(|| drop(Box::from_raw(checkpoint)));
    }
}

#[no_mangle]
pub unsafe extern "C" fn vc_checkpoint_save(
    checkpoint: *const Checkpoint,
    path: *const u8,
    length: usize,
) -> bool {
    guard(|| {
        let (Some(checkpoint), Some(path)) = (checkpoint.as_ref(), input(path, length)) else {
            return false;
        };
        checkpoint.save(std::path::Path::new(path)).is_ok()
    })
}

#[no_mangle]
pub unsafe extern "C" fn vc_session_restore(
    session: *mut Session,
    path: *const u8,
    length: usize,
) -> i32 {
    guard(|| {
        let (Some(session), Some(path)) = (session.as_mut(), input(path, length)) else {
            return 0;
        };
        match Checkpoint::load(std::path::Path::new(path)) {
            Ok(Some(restored)) => {
                *session = restored;
                1
            }
            Ok(None) => 2,
            Err(_) => 0,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grouped_edits_preserve_utf16_boundaries_and_explicit_breaks() {
        unsafe {
            use vibechar_core::EditKind;
            vc_document_break_undo_group(ptr::null_mut());
            let doc = vc_document_new(ptr::null(), 0);
            for (offset, text) in [(0, "я"), (1, "👩‍💻"), (6, "e\u{301}")] {
                assert!(vc_document_edit(
                    doc,
                    offset,
                    0,
                    text.as_ptr(),
                    text.len(),
                    EditKind::Typing as u32
                ));
            }
            assert!(!vc_document_edit(doc, 2, 0, b"x".as_ptr(), 1, 1));
            assert!(!vc_document_edit(doc, 8, 0, b"x".as_ptr(), 1, 99));
            let mut cursor = 999;
            assert!(vc_document_undo(doc, &mut cursor));
            assert_eq!(cursor, 0);
            assert_eq!(vc_document_length(doc), 0);
            assert!(vc_document_redo(doc, &mut cursor));
            assert_eq!(cursor, 8);
            vc_document_break_undo_group(doc);
            assert!(vc_document_edit(doc, 8, 0, b"!".as_ptr(), 1, 1));
            assert!(vc_document_undo(doc, &mut cursor));
            assert_eq!(cursor, 8);
            assert_eq!(vc_document_length(doc), "я👩‍💻e\u{301}".len());
            vc_document_free(doc);
        }
    }

    #[test]
    fn completed_save_converts_private_tab_but_invalid_paths_do_not() {
        unsafe {
            let session = vc_session_new();
            assert!(vc_session_open_private(session));
            let text = "SAVE_BRIDGE_FIXTURE";
            assert!(vc_document_replace(
                vc_session_document(session),
                0,
                0,
                text.as_ptr(),
                text.len()
            ));
            assert!(!vc_session_complete_save(ptr::null_mut(), ptr::null(), 0));
            assert!(!vc_session_complete_save(session, ptr::null(), 0));
            assert!(!vc_session_complete_save(session, b"\xff".as_ptr(), 1));
            assert!(!vc_session_complete_save(session, b"no\0nul".as_ptr(), 6));
            assert!(vc_session_buffer_private(session, 1));
            assert!(vc_document_dirty(vc_session_document(session)));
            let path = "/tmp/saved-fixture.txt";
            assert!(vc_session_complete_save(session, path.as_ptr(), path.len()));
            assert!(!vc_session_buffer_private(session, 1));
            assert!(!vc_document_dirty(vc_session_document(session)));
            assert!(!vc_session_needs_close_confirmation(session));
            assert_eq!(vc_session_path(session, ptr::null_mut(), 0), path.len());
            assert!(vc_session_close(session, false));
            vc_session_free(session);
        }
    }

    #[test]
    fn private_bridge_exposes_mode_and_protects_a_clean_private_tab_from_close() {
        unsafe {
            assert!(!vc_session_open_private(ptr::null_mut()));
            assert!(!vc_session_buffer_private(ptr::null(), 0));
            assert!(!vc_session_has_private_text(ptr::null()));
            assert!(!vc_session_needs_close_confirmation(ptr::null()));
            let session = vc_session_new();
            assert!(vc_session_open_private(session));
            assert!(vc_session_buffer_private(session, 1));
            assert!(!vc_session_buffer_private(session, 99));
            assert!(!vc_session_has_private_text(session));
            let text = "PRIVATE_BRIDGE_FIXTURE";
            assert!(vc_document_replace(
                vc_session_document(session),
                0,
                0,
                text.as_ptr(),
                text.len()
            ));
            vc_document_mark_saved(vc_session_document(session));
            assert!(vc_session_has_private_text(session));
            assert!(vc_session_needs_close_confirmation(session));
            assert!(!vc_session_close(session, false));
            assert!(vc_session_close(session, true));
            assert!(!vc_session_has_private_text(session));
            vc_session_free(session);
        }
    }

    #[test]
    fn native_round_trip_preserves_nul_unicode_and_history() {
        unsafe {
            let text = "я🦀\0";
            let handle = vc_document_new(text.as_ptr(), text.len());
            assert!(!handle.is_null());
            assert!(!vc_document_replace(handle, 2, 1, b"x".as_ptr(), 1));
            assert!(vc_document_replace(handle, 1, 2, b"x".as_ptr(), 1));
            let mut cursor = 0;
            assert!(vc_document_undo(handle, &mut cursor));
            assert_eq!(cursor, 3);
            let mut bytes = vec![0; vc_document_length(handle)];
            assert!(!vc_document_copy(
                handle,
                bytes.as_mut_ptr(),
                bytes.len() - 1
            ));
            assert!(vc_document_copy(handle, bytes.as_mut_ptr(), bytes.len()));
            assert_eq!(bytes, text.as_bytes());
            assert!(vc_document_redo(handle, &mut cursor));
            assert!(vc_document_dirty(handle));
            vc_document_free(handle);
        }
    }

    #[test]
    fn invalid_input_returns_status_instead_of_unwinding() {
        unsafe {
            assert!(vc_document_new([0xff].as_ptr(), 1).is_null());
            assert!(!vc_document_replace(ptr::null_mut(), 0, 0, ptr::null(), 0));
            assert!(!vc_document_dirty(ptr::null()));
            vc_document_free(ptr::null_mut());
        }
    }

    #[test]
    fn session_bridge_preserves_utf16_selection_and_rejects_unconfirmed_close() {
        unsafe {
            let session = vc_session_new();
            assert!(!vc_session_buffer_is_file(session, 0));
            assert!(!vc_session_buffer_is_file(ptr::null(), 0));
            assert!(!vc_session_buffer_is_file(session, usize::MAX));
            let text = "я🦀";
            assert!(vc_document_replace(
                vc_session_document(session),
                0,
                0,
                text.as_ptr(),
                text.len()
            ));
            assert!(!vc_session_set_selection(session, 2, 0));
            assert!(vc_session_set_selection(session, 1, 2));
            assert!(vc_session_open(session, ptr::null(), 0, ptr::null(), 0));
            assert_eq!(vc_session_count(session), 2);
            assert!(vc_session_has_unsaved(session));
            assert!(vc_session_select(session, 0));
            let (mut start, mut length) = (0, 0);
            assert!(vc_session_selection(session, &mut start, &mut length));
            assert_eq!((start, length), (1, 2));
            assert!(!vc_session_close(session, false));
            assert!(vc_session_close(session, true));
            assert_eq!(vc_session_count(session), 1);
            assert!(!vc_session_has_unsaved(session));
            let path = "/tmp/bridge-file.txt";
            assert!(vc_session_set_path(session, path.as_ptr(), path.len()));
            assert!(vc_session_buffer_is_file(session, 0));
            vc_session_free(session);
        }
    }
}
