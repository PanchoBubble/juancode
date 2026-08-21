//! Parse cost per 16KB chunk, the same unit the Swift path was measured in
//! (0.156ms/16KB, recorded in the perf notes) so the two are comparable.
//!
//! Run: cargo run --release -p juancoded-vt --example parse_cost

use std::time::Instant;

use juancoded_vt::TerminalModel;

const CHUNK: usize = 16 * 1024;

fn chunk_of_realistic_output() -> Vec<u8> {
    // A mix of plain text, SGR colour runs and cursor moves — what an agent TUI
    // actually emits. All-ASCII plain text would flatter the parser.
    let line = "\x1b[2m 12:04:18\x1b[0m \x1b[32m✓\x1b[0m src/app/session.rs \x1b[33m+18 -4\x1b[0m \
                \x1b[38;2;120;140;200mrunning tests\x1b[0m\r\n";
    let mut buf = Vec::with_capacity(CHUNK + line.len());
    while buf.len() < CHUNK {
        buf.extend_from_slice(line.as_bytes());
    }
    buf.truncate(CHUNK);
    buf
}

fn main() {
    let chunk = chunk_of_realistic_output();
    let mut model = TerminalModel::new(120, 40, 10_000);

    // Warm the allocator and the grid's scrollback.
    for _ in 0..64 {
        model.feed(&chunk);
    }

    let iterations = 2_000;
    let start = Instant::now();
    for _ in 0..iterations {
        model.feed(&chunk);
    }
    let feed = start.elapsed();

    let snap_iterations = 500;
    let start = Instant::now();
    for _ in 0..snap_iterations {
        let s = model.snapshot();
        std::hint::black_box(&s);
    }
    let snapshot = start.elapsed();

    let per_chunk_ms = feed.as_secs_f64() * 1000.0 / iterations as f64;
    let per_snapshot_ms = snapshot.as_secs_f64() * 1000.0 / snap_iterations as f64;
    println!("parse:    {per_chunk_ms:.4} ms / 16KB chunk");
    println!(
        "          {:.1} MB/s",
        (CHUNK as f64 * iterations as f64) / feed.as_secs_f64() / 1e6
    );
    println!("snapshot: {per_snapshot_ms:.4} ms / 120x40 projection");
}
