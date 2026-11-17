use crate::{copy_metadata, guard, input, Session};
use std::ptr;
use vibechar_core::examples::{self, Capture, Job, Plan};

pub struct VcExample {
    capture: Option<Capture>,
    job: Option<Job>,
    plan: Option<Plan>,
    error: String,
}

#[no_mangle]
pub unsafe extern "C" fn vc_recipe_schema(output: *mut u8, capacity: usize) -> usize {
    guard(|| copy_metadata(&examples::schema().to_string(), output, capacity))
}
#[no_mangle]
pub unsafe extern "C" fn vc_recipe_info(
    rule: *const u8,
    length: usize,
    output: *mut u8,
    capacity: usize,
) -> usize {
    guard(|| {
        let result = if length > examples::MAX_RULE {
            Err("The recipe is too large.")
        } else {
            input(rule, length)
                .ok_or("Invalid recipe text.")
                .and_then(examples::Recipe::parse)
        };
        let json = match result {
            Ok(recipe) => serde_json::json!({"rule":serde_json::to_string(&recipe).unwrap(),
                "summary":recipe.summary(),"explanation":recipe.explain(),"error":""}),
            Err(error) => {
                serde_json::json!({"rule":null,"summary":null,"explanation":null,"error":error})
            }
        };
        copy_metadata(&json.to_string(), output, capacity)
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_example_new(
    session: *const Session,
    start: usize,
    length: usize,
) -> *mut VcExample {
    new_capture(session, start, length, false)
}
#[no_mangle]
pub unsafe extern "C" fn vc_recipe_new(
    session: *const Session,
    start: usize,
    length: usize,
) -> *mut VcExample {
    new_capture(session, start, length, true)
}
unsafe fn new_capture(
    session: *const Session,
    start: usize,
    length: usize,
    replay: bool,
) -> *mut VcExample {
    guard(|| {
        let Some(session) = session.as_ref() else {
            return ptr::null_mut();
        };
        let result = (|| {
            if session.active().is_private() {
                return Err("Private tabs cannot use saved recipes or teach AI examples.");
            }
            let doc = &session.active().document;
            let end = start.checked_add(length).ok_or("Invalid selection.")?;
            let from = doc
                .char_from_utf16(start)
                .map_err(|_| "Invalid selection.")?;
            let to = doc.char_from_utf16(end).map_err(|_| "Invalid selection.")?;
            if replay {
                Capture::for_replay(session, from..to)
            } else {
                Capture::new(session, from..to)
            }
        })();
        let (capture, error) = match result {
            Ok(c) => (Some(c), String::new()),
            Err(e) => (None, e.into()),
        };
        Box::into_raw(Box::new(VcExample {
            capture,
            job: None,
            plan: None,
            error,
        }))
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_example_free(value: *mut VcExample) {
    if !value.is_null() {
        guard(|| drop(Box::from_raw(value)));
    }
}
#[no_mangle]
pub unsafe extern "C" fn vc_example_valid(
    value: *const VcExample,
    session: *const Session,
) -> bool {
    guard(|| {
        value
            .as_ref()
            .and_then(|v| v.capture.as_ref())
            .zip(session.as_ref())
            .is_some_and(|(v, s)| v.is_current(s))
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_example_clear(value: *mut VcExample) {
    guard(|| {
        if let Some(v) = value.as_mut() {
            v.job = None;
            v.plan = None;
            v.error.clear();
        }
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_example_start(
    value: *mut VcExample,
    session: *const Session,
    rule: *const u8,
    rule_length: usize,
    after: *const u8,
    after_length: usize,
) -> bool {
    guard(|| {
        let (Some(v), Some(s)) = (value.as_mut(), session.as_ref()) else {
            return false;
        };
        v.job = None;
        v.plan = None;
        let result = (|| {
            let capture = v.capture.as_ref().ok_or("No example is available.")?;
            if !capture.is_current(s) {
                return Err("Text changed. Select the rows again.");
            }
            if rule_length > examples::MAX_RULE || after_length > examples::MAX_EXAMPLE {
                return Err("The example or rule is too large.");
            }
            let (rule, after) = (
                input(rule, rule_length).ok_or("Invalid rule text.")?,
                input(after, after_length).ok_or("Invalid example text.")?,
            );
            Job::start(capture.clone(), rule.into(), after.into())
        })();
        match result {
            Ok(job) => {
                v.job = Some(job);
                v.error.clear();
                true
            }
            Err(e) => {
                v.error = e.into();
                false
            }
        }
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_recipe_start(
    value: *mut VcExample,
    session: *const Session,
    rule: *const u8,
    length: usize,
) -> bool {
    guard(|| {
        let (Some(v), Some(s)) = (value.as_mut(), session.as_ref()) else {
            return false;
        };
        v.job = None;
        v.plan = None;
        let result = (|| {
            let capture = v.capture.as_ref().ok_or("No selection is available.")?;
            if !capture.is_current(s) {
                return Err("Text changed. Select the rows again.");
            }
            if length > examples::MAX_RULE {
                return Err("The recipe is too large.");
            }
            let rule = input(rule, length).ok_or("Invalid recipe text.")?;
            Job::replay(capture.clone(), rule.into())
        })();
        match result {
            Ok(job) => {
                v.job = Some(job);
                v.error.clear();
                true
            }
            Err(error) => {
                v.error = error.into();
                false
            }
        }
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_example_poll(value: *mut VcExample) -> i32 {
    guard(|| {
        let Some(v) = value.as_mut() else {
            return -1;
        };
        if v.plan.is_some() {
            return 1;
        }
        if !v.error.is_empty() {
            return -1;
        }
        match v.job.as_mut().and_then(Job::take) {
            None => 0,
            Some(Ok(plan)) => {
                v.job = None;
                v.plan = Some(plan);
                1
            }
            Some(Err(e)) => {
                v.job = None;
                v.error = e.into();
                -1
            }
        }
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_example_json(
    value: *const VcExample,
    output: *mut u8,
    capacity: usize,
) -> usize {
    guard(|| {
        let Some(v) = value.as_ref() else {
            return 0;
        };
        let c = v.capture.as_ref();
        let json = serde_json::json!({
            "source":c.map_or("",Capture::source),"before":c.map_or("",|c| c.before.as_str()),
            "example_line":c.map_or(0,|c| c.example_line),"records":c.map_or(0,|c| c.records),
            "result":v.plan.as_ref().map(|p| &p.result),"stats":v.plan.as_ref().map(|p| &p.stats),
            "rule":v.plan.as_ref().map(|p| serde_json::to_string_pretty(&p.recipe).unwrap()),
            "summary":v.plan.as_ref().map(|p| p.recipe.summary()),
            "explanation":v.plan.as_ref().map(|p| p.recipe.explain()),"error":v.error
        });
        copy_metadata(&json.to_string(), output, capacity)
    })
}
#[no_mangle]
pub unsafe extern "C" fn vc_example_apply(
    value: *mut VcExample,
    session: *mut Session,
    start: *mut usize,
    length: *mut usize,
) -> i32 {
    guard(|| {
        let (Some(v), Some(s), Some(start), Some(length)) = (
            value.as_mut(),
            session.as_mut(),
            start.as_mut(),
            length.as_mut(),
        ) else {
            return 0;
        };
        let Some(plan) = v.plan.as_ref() else {
            return 0;
        };
        match plan.apply(s) {
            Ok((changed, range)) => {
                let doc = &s.active().document;
                *start = doc.utf16_from_char(range.start).unwrap();
                *length = doc.utf16_from_char(range.end).unwrap() - *start;
                v.plan = None;
                v.error.clear();
                if changed {
                    1
                } else {
                    2
                }
            }
            Err(e) => {
                v.error = e.into();
                0
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn saved_rule_metadata_and_single_row_replay_cross_the_bridge() {
        unsafe {
            let rule = r#"{"version":1,"input":"line","delimiter":"","format":"text","parts":[{"field":"$","casing":"upper","trim":false,"encoding":"text","prefix":"","suffix":""}]}"#;
            let count = vc_recipe_info(rule.as_ptr(), rule.len(), ptr::null_mut(), 0);
            let mut bytes = vec![0; count];
            assert_eq!(
                vc_recipe_info(rule.as_ptr(), rule.len(), bytes.as_mut_ptr(), count),
                count
            );
            let metadata: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(metadata["error"], "");
            assert!(metadata["rule"].as_str().unwrap().contains("upper"));
            assert!(vc_recipe_info(ptr::null(), examples::MAX_RULE + 1, ptr::null_mut(), 0) > 0);
            assert!(vc_recipe_new(ptr::null(), 0, 1).is_null());
            assert!(!vc_recipe_start(
                ptr::null_mut(),
                ptr::null(),
                ptr::null(),
                0
            ));
            let mut session = Session::new("Боб 🦀", None);
            let value = vc_recipe_new(&session, 0, "Боб 🦀".encode_utf16().count());
            assert!(vc_example_valid(value, &session));
            assert!(vc_recipe_start(value, &session, rule.as_ptr(), rule.len()));
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
            while vc_example_poll(value) == 0 {
                assert!(std::time::Instant::now() < deadline);
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
            let (mut start, mut length) = (0, 0);
            assert_eq!(
                vc_example_apply(value, &mut session, &mut start, &mut length),
                1
            );
            assert_eq!(session.active().document.text(), "БОБ 🦀");
            assert_eq!((start, length), (0, "БОБ 🦀".encode_utf16().count()));
            vc_example_free(value);
        }
    }
    #[test]
    fn ffi_privacy_unicode_planning_stale_and_single_undo() {
        unsafe {
            assert!(vc_example_new(ptr::null(), 0, 1).is_null());
            vc_example_free(ptr::null_mut());
            assert!(!vc_example_valid(ptr::null(), ptr::null()));
            assert_eq!(vc_example_poll(ptr::null_mut()), -1);
            let source = "one 🦀\r\ntwo 🦀\r\n";
            let mut session = Session::new(source, None);
            let value = vc_example_new(&session, 0, source.encode_utf16().count());
            assert!(vc_example_valid(value, &session));
            let rule = r#"{"version":1,"input":"line","delimiter":"","format":"text","parts":[{"field":"$","casing":"keep","trim":false,"encoding":"text","prefix":"- ","suffix":""}]}"#;
            let after = "- one 🦀";
            assert!(vc_example_start(
                value,
                &session,
                rule.as_ptr(),
                rule.len(),
                after.as_ptr(),
                after.len()
            ));
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
            while vc_example_poll(value) == 0 {
                assert!(std::time::Instant::now() < deadline);
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
            let (mut start, mut length) = (0, 0);
            assert_eq!(
                vc_example_apply(value, &mut session, &mut start, &mut length),
                1
            );
            assert_eq!(session.active().document.text(), "- one 🦀\r\n- two 🦀\r\n");
            assert_eq!(length, source.encode_utf16().count() + 4);
            session.active_mut().document.undo().unwrap();
            assert_eq!(session.active().document.text(), source);
            assert!(!vc_example_valid(value, &session));
            vc_example_free(value);
            session.open_private();
            let value = vc_example_new(&session, 0, 1);
            assert!((*value).capture.is_none());
            vc_example_free(value);
        }
    }
}
