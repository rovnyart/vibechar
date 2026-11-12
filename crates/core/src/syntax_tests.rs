use super::*;

fn request(text: &str, path: Option<&str>, mode: Option<&str>, revision: u64) -> Request {
    Request {
        token: revision + 1,
        key: Key {
            document: 1,
            revision,
            path: path.map(PathBuf::from),
            mode: mode.map(str::to_owned),
        },
        text: Rope::from_str(text),
    }
}
fn state(token: u64) -> Shared {
    Shared {
        pending: Mutex::new(None),
        ready: Mutex::new(None),
        wake: Condvar::new(),
        wanted: AtomicU64::new(token),
        serial: AtomicU64::new(0),
        stop: AtomicBool::new(false),
    }
}
fn complete(request: &Request, cache: &mut Option<Cache>) -> Frame {
    let state = state(request.token);
    loop {
        let frame = paint(request, cache, &state).unwrap();
        if frame.complete {
            return frame;
        }
    }
}

#[test]
fn detects_common_pastes_and_respects_file_and_manual_modes() {
    for (token, text) in [
        ("json", "{\"hello\": \"world\", \"n\": 42}"),
        ("JSON Lines", "{\"n\":1}\n{\"n\":2}"),
        ("DotENV", "API_TOKEN=placeholder\nREGION=local"),
        ("toml", "[service]\nport = 8080"),
        ("yaml", "name: pocket\nport: 8080\nactive: true"),
        ("sql", "SELECT name FROM users WHERE id = 42;"),
        ("sh", "curl https://example.invalid"),
        ("rs", "pub fn main() { println!(\"hello\"); }"),
        ("swift", "import Foundation\nlet n = 42"),
        ("py", "def greet(name):\n    return name"),
        ("ts", "interface User { name: string }"),
        ("js", "const greet = (name) => name;"),
        ("js", "import React from 'react'\nconst n = 42"),
        ("md", "# Pocket\n\nA small text editor."),
        ("html", "<!DOCTYPE html><html></html>"),
        ("xml", "<?xml version=\"1.0\"?><root/>"),
    ] {
        let found = detect(&request(text, None, None, 0));
        assert_eq!(
            found
                .syntax
                .unwrap_or_else(|| panic!("no syntax for {token}: {text}"))
                .name,
            resolve(token).unwrap().name,
            "detection mismatch for {token}"
        );
        if token == "JSON Lines" {
            assert_eq!(found.name, token);
        }
    }
    let text = "{\"n\":42}";
    assert_eq!(detect(&request(text, Some("a.rs"), None, 0)).name, "Rust");
    assert_eq!(
        detect(&request(text, Some("a.rs"), Some("Python"), 0)).name,
        "Python"
    );
    assert_eq!(
        detect(&request(text, Some("a.json"), Some("Plain Text"), 0)).name,
        "Text"
    );
    assert_eq!(
        detect(&request("#!/usr/bin/env python3\nprint(42)", None, None, 0)).name,
        "Python"
    );
    for text in [
        "",
        "Привет! Вот мой пост для команды.",
        "123",
        "AbCDef123==",
        "eyJhbGciOiJIUzI1NiJ9.x.y",
    ] {
        assert_eq!(detect(&request(text, None, None, 0)).name, "Text");
    }
}

#[test]
fn spans_are_utf16_bounded_and_never_contain_source_text() {
    let source = "{\"name\":\"PRIVATE_SYNTAX_FIXTURE_я👩‍💻\",\"count\":42}";
    let req = request(source, None, None, 0);
    let frame = complete(&req, &mut None);
    assert_eq!(frame.language, "JSON");
    assert!(frame.spans.iter().any(|s| s.role == 2));
    assert!(frame.spans.iter().any(|s| s.role == 3));
    let mut valid = vec![0];
    let mut offset = 0;
    for ch in source.chars() {
        offset += ch.len_utf16();
        valid.push(offset);
    }
    for span in &frame.spans {
        assert!(valid.contains(&span.start) && valid.contains(&(span.start + span.length)));
        assert!((1..=10).contains(&span.role));
    }
    let json = serde_json::to_string(&frame).unwrap();
    assert!(!json.contains("PRIVATE_SYNTAX_FIXTURE") && !json.contains(source));
    assert_eq!(req.text.to_string(), source);
}

#[test]
fn incremental_reparse_matches_fresh_parse_and_keeps_unchanged_prefix() {
    let source: String = (0..100)
        .map(|i| format!("pub fn f_{i}() {{ let n = {i}; }}\n"))
        .collect();
    let mut cache = None;
    complete(&request(&source, Some("main.rs"), None, 0), &mut cache);
    let prefix = cache.as_ref().unwrap().lines[0].clone();
    let changed = source.replace("let n = 81", "let n = 999");
    let req = request(&changed, Some("main.rs"), None, 1);
    let incremental = complete(&req, &mut cache);
    assert!(Arc::ptr_eq(&prefix, &cache.as_ref().unwrap().lines[0]));
    let fresh = complete(&req, &mut None);
    assert_eq!(
        serde_json::to_string(&incremental.spans).unwrap(),
        serde_json::to_string(&fresh.spans).unwrap()
    );
    let commented = format!("/*\n{changed}\n*/");
    let req = request(&commented, Some("main.rs"), None, 2);
    let incremental = complete(&req, &mut cache);
    let fresh = complete(&req, &mut None);
    assert_eq!(
        serde_json::to_string(&incremental.spans).unwrap(),
        serde_json::to_string(&fresh.spans).unwrap()
    );
}

#[test]
fn large_and_pathological_lines_fall_back_without_parsing() {
    for source in [
        "x".repeat(MAX_BYTES + 1),
        "const x = ".to_owned() + &"a".repeat(MAX_LINE + 1),
        "x\n".repeat(MAX_LINES + 1),
    ] {
        let frame = complete(&request(&source, Some("test.js"), None, 0), &mut None);
        assert!(frame.limited && frame.complete && frame.spans.is_empty());
    }
}

#[test]
fn worker_only_publishes_latest_request_and_session_rejects_old_revisions() {
    let mut engine = Engine::new().unwrap();
    engine.submit(1, 0, Rope::from_str("pub fn main() {}"), None, None);
    engine.submit(2, 1, Rope::from_str("{\"n\":42}"), None, None);
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if let Some(frame) = engine.frame(0) {
            assert_eq!((frame.document, frame.revision), (2, 1));
            if frame.complete {
                break;
            }
        }
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(5));
    }
    let mut session = crate::session::Session::new("{\"n\":42}", None);
    session.submit_syntax();
    session.active_mut().document.replace(0..0, " ").unwrap();
    assert!(session.syntax_frame(0).is_none());
    session.submit_syntax();
    loop {
        if let Some(frame) = session.syntax_frame(0) {
            assert_eq!(frame.revision, session.active().document.revision());
            if frame.complete {
                break;
            }
        }
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(5));
    }
    assert!(session.set_language("Python"));
    assert!(
        session.syntax_frame(0).is_none(),
        "A previous Auto frame cannot override a new pin"
    );
    session.active_mut().path = Some(PathBuf::from("different.rs"));
    assert!(session.syntax_frame(0).is_none());
}

#[test]
fn language_search_is_short_and_finds_extensions() {
    assert!(syntax_count() >= 150);
    assert!(choices("").len() <= 7);
    assert_eq!(choices("")[0].id, "");
    for extension in ["json", "ts", "py", "rs", "swift", "toml", "yaml", "sh"] {
        assert!(
            !choices(extension).is_empty(),
            "missing language {extension}"
        );
    }
    assert!(choices("some-unknown-language-xyz").is_empty());
    assert!(!valid_mode("some-unknown-language-xyz"));
}
