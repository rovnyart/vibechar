//! Thread-confined, copy-in/copy-out C boundary. See include/vibechar.h for ownership.
#![allow(clippy::missing_safety_doc)]

use std::{
    panic::{catch_unwind, AssertUnwindSafe},
    ptr, slice, str,
};
use vibechar_core::Document;

pub struct VcDocument(Document);

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
            Box::into_raw(Box::new(VcDocument(Document::new(text))))
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
    guard(|| document.as_ref().map_or(0, |doc| doc.0.len_bytes()))
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
        let length = doc.0.len_bytes();
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
        doc.0.write_to(destination).is_ok()
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
    guard(|| {
        let Some(doc) = document.as_mut() else {
            return false;
        };
        let Some(text) = input(replacement, replacement_length) else {
            return false;
        };
        let Some(end) = start.checked_add(length) else {
            return false;
        };
        let (Ok(start), Ok(end)) = (doc.0.char_from_utf16(start), doc.0.char_from_utf16(end))
        else {
            return false;
        };
        doc.0.replace(start..end, text).is_ok()
    })
}

unsafe fn history(document: *mut VcDocument, cursor: *mut usize, redo: bool) -> bool {
    guard(|| {
        let (Some(doc), Some(cursor)) = (document.as_mut(), cursor.as_mut()) else {
            return false;
        };
        let position = if redo { doc.0.redo() } else { doc.0.undo() };
        let Some(position) = position else {
            return false;
        };
        let Ok(offset) = doc.0.utf16_from_char(position) else {
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
    guard(|| document.as_ref().is_some_and(|doc| doc.0.is_dirty()))
}

#[no_mangle]
pub unsafe extern "C" fn vc_document_mark_saved(document: *mut VcDocument) {
    guard(|| {
        if let Some(doc) = document.as_mut() {
            doc.0.mark_saved();
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
