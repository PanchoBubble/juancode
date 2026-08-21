//! Throughput of a heavy dump: `cat` a large file through a session and measure
//! the bytes that reach the session bus, with the grid being fed the whole way.
//!
//! Run: cargo run --release -p juancoded-core --example throughput [path]

use std::sync::Arc;
use std::time::Instant;

use juancoded_core::model::ProviderId;
use juancoded_core::registry::{CreateRequest, Registry, SessionEvent};

#[tokio::main]
async fn main() {
    let path = std::env::args().nth(1).expect("usage: throughput <file>");
    let size = std::fs::metadata(&path).expect("stat").len();

    let reg = Arc::new(Registry::new());
    let mut rx = reg.subscribe();
    let start = Instant::now();
    let meta = reg
        .create(
            CreateRequest {
                provider: ProviderId::Claude,
                cwd: "/tmp".into(),
                cols: 120,
                rows: 40,
                skip_permissions: false,
                model: None,
                dispatch_id: None,
            },
            Some(("/bin/cat".into(), vec![path.clone()])),
        )
        .expect("spawn cat");

    // A slow subscriber lags rather than stalling the grid: the pump is a separate
    // reader, so dropped frames are the *viewer's* loss and the model stays whole.
    // Counting them is the point — it is the property that keeps a heavy dump from
    // backpressuring the pty.
    let mut bytes = 0u64;
    let mut chunks = 0u64;
    let mut dropped = 0u64;
    loop {
        match rx.recv().await {
            Ok(SessionEvent::Output { bytes: b, .. }) => {
                bytes += b.len() as u64;
                chunks += 1;
            }
            Ok(SessionEvent::Exit { .. }) => break,
            Ok(_) => {}
            Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => dropped += n,
            Err(_) => break,
        }
    }
    let elapsed = start.elapsed();

    // What the grid actually absorbed, independent of what this subscriber saw.
    let grid_rows = reg.snapshot(&meta.id).map(|s| s.rows).unwrap_or(0);
    let _ = reg.kill(&meta.id);

    println!("file {:.1} MB", size as f64 / 1e6);
    println!(
        "  subscriber saw {:.1} MB in {} chunks ({} dropped by lag)",
        bytes as f64 / 1e6,
        chunks,
        dropped
    );
    println!(
        "  {:.1} MB/s delivered end to end (pty read + grid feed + fan-out), {:.2}s wall, grid {} rows",
        bytes as f64 / elapsed.as_secs_f64() / 1e6, elapsed.as_secs_f64(), grid_rows
    );
    // The tail gap is the kernel discarding whatever is still queued in the pty
    // when the last slave fd closes — a property of ptys on macOS, not of this
    // code, and one the Swift core's forkpty path shares. It only shows up for a
    // producer that exits mid-flood; an interactive CLI never does.
    if bytes < size {
        println!(
            "  note: {:.1} MB of tail dropped by the kernel at slave close",
            (size - bytes) as f64 / 1e6
        );
    }
}
