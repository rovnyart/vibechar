use crate::{copy_metadata, guard, input, Session};
use std::ptr;
use vibechar_core::rewrite::{self, Rewrite};

pub struct VcRewrite {
    value: Option<Rewrite>,
    error: String,
}

#[no_mangle]
pub unsafe extern "C" fn vc_rewrite_new(
    session: *const Session,
    start: usize,
    length: usize,
) -> *mut VcRewrite {
    guard(|| {
        let Some(session) = session.as_ref() else {
            return ptr::null_mut();
        };
        let result = (|| {
            if session.active().is_private() {
                return Err("Private tabs cannot use AI. Use local text tools instead.");
            }
            let doc = &session.active().document;
            let end = start.checked_add(length).ok_or("Invalid selection.")?;
            let from = doc
                .char_from_utf16(start)
                .map_err(|_| "Invalid selection.")?;
            let to = doc.char_from_utf16(end).map_err(|_| "Invalid selection.")?;
            Rewrite::capture(session, from..to)
        })();
        let (value, error) = match result {
            Ok(v) => (Some(v), String::new()),
            Err(e) => (None, e.into()),
        };
        Box::into_raw(Box::new(VcRewrite { value, error }))
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_rewrite_free(value: *mut VcRewrite) {
    if !value.is_null() {
        guard(|| drop(Box::from_raw(value)));
    }
}
#[no_mangle]
pub unsafe extern "C" fn vc_rewrite_valid(
    value: *const VcRewrite,
    session: *const Session,
) -> bool {
    guard(|| {
        value
            .as_ref()
            .and_then(|v| v.value.as_ref())
            .zip(session.as_ref())
            .is_some_and(|(v, s)| v.is_current(s))
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_rewrite_json(
    value: *const VcRewrite,
    output: *mut u8,
    capacity: usize,
) -> usize {
    guard(|| {
        let Some(value) = value.as_ref() else {
            return 0;
        };
        let json = if let Some(v) = &value.value {
            let ranges: Vec<_> = v
                .protected()
                .iter()
                .map(|r| {
                    serde_json::json!({
                        "start": v.source()[..r.start].encode_utf16().count(),
                        "length": v.source()[r.clone()].encode_utf16().count()
                    })
                })
                .collect();
            serde_json::json!({"source":v.source(),"request":v.request_text(),"result":v.result(),"protected":ranges,"error":value.error})
        } else {
            serde_json::json!({"source":"","request":"","result":null,"protected":[],"error":value.error})
        };
        copy_metadata(&json.to_string(), output, capacity)
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_rewrite_protect(
    value: *mut VcRewrite,
    start: usize,
    length: usize,
) -> bool {
    guard(|| {
        let Some(value) = value.as_mut() else {
            return false;
        };
        let Some(v) = value.value.as_mut() else {
            return false;
        };
        match rewrite::byte_range(v.source(), start, length).and_then(|range| v.protect(range)) {
            Ok(()) => {
                value.error.clear();
                true
            }
            Err(e) => {
                value.error = e.into();
                false
            }
        }
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_rewrite_clear(value: *mut VcRewrite, protection: bool) {
    guard(|| {
        if let Some(value) = value.as_mut() {
            if let Some(v) = &mut value.value {
                v.clear(protection);
            }
            value.error.clear();
        }
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_rewrite_result(
    value: *mut VcRewrite,
    text: *const u8,
    length: usize,
) -> bool {
    guard(|| {
        let Some(value) = value.as_mut() else {
            return false;
        };
        let Some(v) = value.value.as_mut() else {
            return false;
        };
        v.clear(false);
        let result = if length > rewrite::MAX_OUTPUT {
            Err("Result exceeds 128 KiB. Try a smaller selection.")
        } else {
            input(text, length)
                .ok_or("Unreadable model response.")
                .and_then(|text| v.propose(text))
        };
        match result {
            Ok(()) => {
                value.error.clear();
                true
            }
            Err(e) => {
                value.error = e.into();
                false
            }
        }
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_rewrite_apply(
    value: *mut VcRewrite,
    session: *mut Session,
    start: *mut usize,
    length: *mut usize,
) -> i32 {
    guard(|| {
        let (Some(value), Some(session), Some(start), Some(length)) = (
            value.as_mut(),
            session.as_mut(),
            start.as_mut(),
            length.as_mut(),
        ) else {
            return 0;
        };
        let Some(v) = value.value.as_mut() else {
            return 0;
        };
        match v.apply(session) {
            Ok((changed, range)) => {
                let doc = &session.active().document;
                *start = doc.utf16_from_char(range.start).unwrap();
                *length = doc.utf16_from_char(range.end).unwrap() - *start;
                value.error.clear();
                if changed {
                    1
                } else {
                    2
                }
            }
            Err(e) => {
                value.error = e.into();
                0
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::*;
    #[test]
    fn utf16_selection_private_boundary_and_atomic_apply() {
        unsafe {
            assert!(vc_rewrite_new(ptr::null(), 0, 1).is_null());
            assert!(!vc_rewrite_valid(ptr::null(), ptr::null()));
            vc_rewrite_free(ptr::null_mut());
            vc_rewrite_clear(ptr::null_mut(), true);
            let mut session = Session::new("🦀 source tail", None);
            let invalid = vc_rewrite_new(&session, 1, 1);
            assert!((*invalid).value.is_none());
            vc_rewrite_free(invalid);
            let value = vc_rewrite_new(&session, 3, 6);
            assert!(vc_rewrite_valid(value, &session));
            assert!(!vc_rewrite_protect(value, usize::MAX, 1));
            let result = "new 👩‍💻";
            assert!(vc_rewrite_result(value, result.as_ptr(), result.len()));
            let (mut start, mut length) = (0, 0);
            assert_eq!(
                vc_rewrite_apply(value, &mut session, &mut start, &mut length),
                1
            );
            assert_eq!((start, length), (3, 9));
            assert_eq!(session.active().document.text(), "🦀 new 👩‍💻 tail");
            assert_eq!(
                vc_rewrite_apply(value, &mut session, &mut start, &mut length),
                0
            );
            session.active_mut().document.undo().unwrap();
            assert_eq!(session.active().document.text(), "🦀 source tail");
            vc_rewrite_free(value);
            session.open_private();
            let value = vc_rewrite_new(&session, 0, 1);
            assert!((*value).value.is_none());
            let count = vc_rewrite_json(value, ptr::null_mut(), 0);
            let mut json = vec![0; count];
            vc_rewrite_json(value, json.as_mut_ptr(), count);
            assert!(std::str::from_utf8(&json)
                .unwrap()
                .contains("\"source\":\"\""));
            vc_rewrite_free(value);
        }
    }
}
