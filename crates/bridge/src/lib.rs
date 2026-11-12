//! Thread-confined, copy-in/copy-out C boundary. See include/vibechar.h for ownership.
#![allow(clippy::missing_safety_doc)]

use std::{
    panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf,
    ptr, slice, str,
};
use vibechar_core::{checkpoint::Checkpoint, session::Session, Document};

pub type VcDocument = Document;
pub struct VcSyntaxFrame(std::sync::Arc<vibechar_core::syntax::Frame>);
pub struct VcSearch(vibechar_core::search::Engine);
pub struct VcSearchFrame(std::sync::Arc<vibechar_core::search::Frame>);

pub struct VcTool {
    job: Option<vibechar_core::tools::Job>,
    error: Option<String>,
}
#[no_mangle]
pub unsafe extern "C" fn vc_tool_choices(
    query: *const u8,
    length: usize,
    output: *mut u8,
    capacity: usize,
) -> usize {
    guard(|| {
        if length > 256 {
            return 0;
        }
        let Some(query) = input(query, length) else {
            return 0;
        };
        let json = serde_json::to_string(&vibechar_core::tools::choices(query)).unwrap_or_default();
        copy_metadata(&json, output, capacity)
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_tool_start(
    document: *const VcDocument,
    start: usize,
    length: usize,
    command: u32,
) -> *mut VcTool {
    guard(|| {
        let Some(doc) = document.as_ref() else {
            return ptr::null_mut();
        };
        let Some(end) = start.checked_add(length) else {
            return ptr::null_mut();
        };
        let (Ok(start), Ok(end)) = (doc.char_from_utf16(start), doc.char_from_utf16(end)) else {
            return ptr::null_mut();
        };
        let (job, error) = match vibechar_core::tools::Job::start(doc, start..end, command) {
            Ok(job) => (Some(job), None),
            Err(error) => (None, Some(error)),
        };
        Box::into_raw(Box::new(VcTool { job, error }))
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_tool_free(tool: *mut VcTool) {
    if !tool.is_null() {
        guard(|| drop(Box::from_raw(tool)));
    }
}
#[no_mangle]
pub unsafe extern "C" fn vc_tool_poll(tool: *mut VcTool) -> i32 {
    guard(|| {
        let Some(tool) = tool.as_mut() else {
            return -1;
        };
        if tool.error.is_some() {
            return -1;
        }
        match tool.job.as_mut().and_then(|job| job.poll()) {
            None => 0,
            Some(Ok(_)) => 1,
            Some(Err(error)) => {
                tool.error = Some(error.clone());
                -1
            }
        }
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_tool_error(
    tool: *const VcTool,
    output: *mut u8,
    capacity: usize,
) -> usize {
    guard(|| {
        copy_metadata(
            tool.as_ref().and_then(|t| t.error.as_deref()).unwrap_or(""),
            output,
            capacity,
        )
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_tool_apply(
    tool: *mut VcTool,
    document: *mut VcDocument,
    start: *mut usize,
    length: *mut usize,
) -> i32 {
    guard(|| {
        if start.is_null() || length.is_null() {
            return 0;
        }
        let (Some(tool), Some(doc)) = (tool.as_mut(), document.as_mut()) else {
            return 0;
        };
        let Some(Ok(plan)) = tool.job.as_mut().and_then(|job| job.poll()) else {
            return 0;
        };
        let Ok((changed, range)) = plan.apply(doc) else {
            tool.error = Some("Text changed · run the command again".into());
            return 0;
        };
        let (Ok(from), Ok(to)) = (
            doc.utf16_from_char(range.start),
            doc.utf16_from_char(range.end),
        ) else {
            return 0;
        };
        *start = from;
        *length = to - from;
        if changed {
            1
        } else {
            2
        }
    })
}

#[no_mangle]
pub extern "C" fn vc_search_new() -> *mut VcSearch {
    guard(|| {
        vibechar_core::search::Engine::new().map_or(ptr::null_mut(), |engine| {
            Box::into_raw(Box::new(VcSearch(engine)))
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_search_free(search: *mut VcSearch) {
    if !search.is_null() {
        guard(|| drop(Box::from_raw(search)));
    }
}
#[no_mangle]
pub unsafe extern "C" fn vc_search_submit(
    search: *mut VcSearch,
    document: *const VcDocument,
    needle: *const u8,
    needle_length: usize,
    replacement: *const u8,
    replacement_length: usize,
    flags: u32,
) -> bool {
    guard(|| {
        let Some(search) = search.as_mut() else {
            return false;
        };
        if flags & !7 != 0 || needle_length > 64 * 1024 || replacement_length > 64 * 1024 {
            search.0.clear();
            return false;
        }
        let (Some(doc), Some(needle), Some(replacement)) = (
            document.as_ref(),
            input(needle, needle_length),
            input(replacement, replacement_length),
        ) else {
            search.0.clear();
            return false;
        };
        search.0.submit(
            doc,
            vibechar_core::search::Query {
                needle: needle.into(),
                replacement: (flags & 4 != 0).then(|| replacement.into()),
                regex: flags & 1 != 0,
                case_sensitive: flags & 2 != 0,
            },
        );
        true
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_search_busy(search: *const VcSearch) -> bool {
    guard(|| search.as_ref().is_some_and(|s| s.0.busy()))
}
#[no_mangle]
pub unsafe extern "C" fn vc_search_frame(
    search: *const VcSearch,
    document: *const VcDocument,
    after: u64,
) -> *mut VcSearchFrame {
    guard(|| {
        let (Some(search), Some(doc)) = (search.as_ref(), document.as_ref()) else {
            return ptr::null_mut();
        };
        search.0.frame(doc, after).map_or(ptr::null_mut(), |frame| {
            Box::into_raw(Box::new(VcSearchFrame(frame)))
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_search_frame_free(frame: *mut VcSearchFrame) {
    if !frame.is_null() {
        guard(|| drop(Box::from_raw(frame)));
    }
}
#[no_mangle]
pub unsafe extern "C" fn vc_search_frame_json(
    frame: *const VcSearchFrame,
    output: *mut u8,
    capacity: usize,
) -> usize {
    guard(|| {
        frame.as_ref().map_or(0, |f| {
            copy_metadata(str::from_utf8(&f.0.encoded).unwrap_or(""), output, capacity)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_search_apply(
    search: *const VcSearch,
    document: *mut VcDocument,
    serial: u64,
    index: usize,
    start: *mut usize,
    length: *mut usize,
) -> i32 {
    guard(|| {
        if start.is_null() || length.is_null() {
            return 0;
        }
        let (Some(search), Some(doc)) = (search.as_ref(), document.as_mut()) else {
            return 0;
        };
        let Ok((changed, range)) =
            search
                .0
                .apply(doc, serial, (index != usize::MAX).then_some(index))
        else {
            return 0;
        };
        let (Ok(from), Ok(to)) = (
            doc.utf16_from_char(range.start),
            doc.utf16_from_char(range.end),
        ) else {
            return 0;
        };
        *start = from;
        *length = to - from;
        if changed {
            1
        } else {
            2
        }
    })
}

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
pub unsafe extern "C" fn vc_document_revision(document: *const VcDocument) -> u64 {
    guard(|| document.as_ref().map_or(0, Document::revision))
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
pub unsafe extern "C" fn vc_session_syntax_submit(session: *mut Session) {
    guard(|| {
        if let Some(session) = session.as_mut() {
            session.submit_syntax();
        }
    });
}
#[no_mangle]
pub unsafe extern "C" fn vc_session_syntax_busy(session: *const Session) -> bool {
    guard(|| session.as_ref().is_some_and(Session::syntax_busy))
}
#[no_mangle]
pub unsafe extern "C" fn vc_session_syntax_frame(
    session: *const Session,
    after: u64,
) -> *mut VcSyntaxFrame {
    guard(|| {
        session
            .as_ref()
            .and_then(|s| s.syntax_frame(after))
            .map_or(ptr::null_mut(), |frame| {
                Box::into_raw(Box::new(VcSyntaxFrame(frame)))
            })
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_syntax_frame_free(frame: *mut VcSyntaxFrame) {
    if !frame.is_null() {
        guard(|| drop(Box::from_raw(frame)));
    }
}
#[no_mangle]
pub unsafe extern "C" fn vc_syntax_frame_json(
    frame: *const VcSyntaxFrame,
    output: *mut u8,
    capacity: usize,
) -> usize {
    guard(|| {
        frame.as_ref().map_or(0, |frame| {
            copy_metadata(
                str::from_utf8(&frame.0.encoded).unwrap_or(""),
                output,
                capacity,
            )
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_session_language(
    session: *const Session,
    output: *mut u8,
    capacity: usize,
) -> usize {
    guard(|| {
        session.as_ref().map_or(0, |s| {
            copy_metadata(s.language().unwrap_or(""), output, capacity)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_session_set_language(
    session: *mut Session,
    value: *const u8,
    length: usize,
) -> bool {
    guard(|| {
        if length > 128 {
            return false;
        }
        let (Some(session), Some(mode)) = (session.as_mut(), input(value, length)) else {
            return false;
        };
        session.set_language(mode)
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_syntax_choices(
    query: *const u8,
    length: usize,
    output: *mut u8,
    capacity: usize,
) -> usize {
    guard(|| {
        if length > 128 {
            return 0;
        }
        let Some(query) = input(query, length) else {
            return 0;
        };
        let result =
            serde_json::to_string(&vibechar_core::syntax::choices(query)).unwrap_or_default();
        copy_metadata(&result, output, capacity)
    })
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
        buffer.selection_head = None;
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
    fn tools_validate_utf16_and_apply_one_revision_bound_transaction() {
        unsafe {
            assert!(vc_tool_start(ptr::null(), 0, 0, 1).is_null());
            assert_eq!(vc_tool_poll(ptr::null_mut()), -1);
            vc_tool_free(ptr::null_mut());
            assert_eq!(vc_tool_choices(ptr::null(), 1, ptr::null_mut(), 0), 0);
            let source = "👩‍💻\nb\na\ntail";
            let doc = vc_document_new(source.as_ptr(), source.len());
            assert!(vc_tool_start(doc, 1, 1, 3).is_null());
            assert!(vc_tool_start(doc, usize::MAX, 2, 3).is_null());
            let job = vc_tool_start(doc, 6, 3, 3);
            assert!(!job.is_null());
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
            while vc_tool_poll(job) == 0 {
                assert!(std::time::Instant::now() < deadline);
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
            let (mut start, mut length) = (0, 0);
            assert_eq!(vc_tool_apply(job, doc, &mut start, &mut length), 1);
            assert_eq!((start, length), (6, 3));
            assert_eq!((*doc).text(), "👩‍💻\na\nb\ntail");
            assert_eq!(vc_tool_apply(job, doc, &mut start, &mut length), 0);
            assert!(vc_tool_error(job, ptr::null_mut(), 0) > 0);
            assert!(vc_document_undo(doc, &mut start));
            assert_eq!((*doc).text(), source);
            assert!(!vc_document_dirty(doc));
            vc_tool_free(job);
            vc_document_free(doc);
        }
    }

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
            vc_session_syntax_submit(ptr::null_mut());
            assert!(!vc_session_syntax_busy(ptr::null()));
            assert!(vc_session_syntax_frame(ptr::null(), 0).is_null());
            assert_eq!(vc_syntax_frame_json(ptr::null(), ptr::null_mut(), 0), 0);
            vc_syntax_frame_free(ptr::null_mut());
            assert_eq!(vc_syntax_choices([0xff].as_ptr(), 1, ptr::null_mut(), 0), 0);
            assert_eq!(vc_syntax_choices(ptr::null(), 129, ptr::null_mut(), 0), 0);
            assert!(!vc_session_set_language(ptr::null_mut(), ptr::null(), 0));
            assert!(!vc_search_busy(ptr::null()));
            assert!(vc_search_frame(ptr::null(), ptr::null(), 0).is_null());
            vc_search_free(ptr::null_mut());
            vc_search_frame_free(ptr::null_mut());
            assert_eq!(vc_search_frame_json(ptr::null(), ptr::null_mut(), 0), 0);
        }
    }

    #[test]
    fn find_bridge_keeps_immutable_frames_and_applies_utf16_batch_once() {
        unsafe {
            let source = "👩‍💻 one one";
            let document = vc_document_new(source.as_ptr(), source.len());
            let search = vc_search_new();
            assert!(!search.is_null());
            assert!(vc_search_submit(
                search,
                document,
                b"one".as_ptr(),
                3,
                b"two".as_ptr(),
                3,
                4
            ));
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
            let frame = loop {
                let f = vc_search_frame(search, document, 0);
                if !f.is_null() {
                    break f;
                }
                assert!(std::time::Instant::now() < deadline);
                std::thread::sleep(std::time::Duration::from_millis(2));
            };
            let size = vc_search_frame_json(frame, ptr::null_mut(), 0);
            let mut bytes = vec![0; size];
            assert_eq!(vc_search_frame_json(frame, bytes.as_mut_ptr(), size), size);
            let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(value["matches"][0]["utf16_start"], 6);
            let serial = value["serial"].as_u64().unwrap();
            let (mut start, mut length) = (0, 0);
            assert_eq!(
                vc_search_apply(
                    search,
                    document,
                    serial,
                    usize::MAX,
                    &mut start,
                    &mut length
                ),
                1
            );
            assert_eq!((start, length), (6, 3));
            assert_eq!(vc_document_revision(document), 1);
            let mut copied = vec![0; size];
            vc_search_frame_json(frame, copied.as_mut_ptr(), size);
            assert_eq!(bytes, copied);
            assert_eq!(
                vc_search_apply(
                    search,
                    document,
                    serial,
                    usize::MAX,
                    &mut start,
                    &mut length
                ),
                0
            );
            assert!(!vc_search_submit(
                search,
                document,
                [0xff].as_ptr(),
                1,
                ptr::null(),
                0,
                0
            ));
            vc_search_frame_free(frame);
            vc_search_free(search);
            vc_document_free(document);
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
