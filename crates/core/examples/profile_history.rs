//! Synthetic history workload; reports samples, not a UI latency or RSS guarantee.
use std::{process::Command, time::Instant};
use vibechar_core::Document;

fn rss_kib() -> Option<usize> {
    let output = Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .ok()?;
    String::from_utf8(output.stdout).ok()?.trim().parse().ok()
}

fn main() {
    let bytes = 512 * 1024;
    let steps = 96;
    let a = "a".repeat(bytes);
    let b = "b".repeat(bytes);
    let mut document = Document::new(&a);
    let before_rss = rss_kib();
    let mut edits = Vec::with_capacity(steps);
    for step in 0..steps {
        let start = Instant::now();
        document
            .replace(0..document.len_chars(), if step % 2 == 0 { &b } else { &a })
            .unwrap();
        edits.push(start.elapsed().as_secs_f64() * 1000.0);
    }
    let retained_rss = rss_kib();
    document.mark_saved();
    let mut undo_steps = 0;
    while document.undo().is_some() {
        undo_steps += 1;
    }
    let mut redo_steps = 0;
    while document.redo().is_some() {
        redo_steps += 1;
    }
    assert_eq!(undo_steps, redo_steps);
    assert_eq!(document.text(), a);
    assert!(!document.is_dirty());
    edits.sort_by(f64::total_cmp);
    println!(
        "{}",
        serde_json::json!({
            "fixture_bytes": bytes, "replacements": steps,
            "before_rss_kib": before_rss, "retained_rss_kib": retained_rss,
            "edit_p50_ms": edits[steps / 2], "edit_p95_ms": edits[steps * 95 / 100],
            "undo_steps": undo_steps, "redo_steps": redo_steps
        })
    );
}
