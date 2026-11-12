//! Core-only synthetic long-line navigation samples, without UI or disk writes.
use std::{hint::black_box, time::Instant};
use vibechar_core::Document;

fn main() {
    let mut results = Vec::new();
    for bytes in [1024 * 1024, 10 * 1024 * 1024] {
        let document = Document::new(&"x".repeat(bytes));
        for position in [0, bytes / 2, bytes] {
            let mut samples = Vec::new();
            for _ in 0..30 {
                let start = Instant::now();
                black_box(document.previous_grapheme(black_box(position)));
                black_box(document.next_grapheme(black_box(position)));
                samples.push(start.elapsed().as_secs_f64() * 1000.0);
            }
            samples.sort_by(f64::total_cmp);
            results.push(serde_json::json!({"bytes": bytes, "position": position,
                "pair_p50_ms": samples[15], "pair_p95_ms": samples[28]}));
        }
    }
    println!("{}", serde_json::json!(results));
}
