//! Harness echo latency: keystroke in -> byte out, through the pty, the grid and
//! the session bus, with a child (`/bin/cat`) that echoes instantly so the number
//! is the harness's cost and not a CLI's repaint.
//!
//! Run: cargo run --release -p juancoded-state --example echo_latency

use std::time::Instant;

use juancoded_core::model::ProviderId;
use juancoded_state::registry::{CreateRequest, SessionEvent};

#[tokio::main]
async fn main() {
    let (_loader, _report, reg) =
        juancoded_state::boot_with(&juancoded_state::test_entries("/bin/cat", &[]))
            .expect("mount the tree");
    let mut rx = reg.subscribe();
    let meta = reg
        .create(CreateRequest {
            provider: ProviderId::Claude,
            cwd: "/tmp".into(),
            cols: 120,
            rows: 40,
            skip_permissions: false,
            model: None,
            preset: None,
            isolate_worktree: false,
            dispatch_id: None,
            owner: 1,
        })
        .expect("spawn cat");

    // Let the pty settle before timing anything.
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;

    let mut samples = Vec::new();
    for i in 0..300u32 {
        let marker = format!("k{i}\n");
        let start = Instant::now();
        reg.input(&meta.id, marker.as_bytes()).expect("input");
        loop {
            match rx.recv().await {
                Ok(SessionEvent::Output { bytes, .. }) => {
                    if String::from_utf8_lossy(&bytes).contains(marker.trim()) {
                        samples.push(start.elapsed().as_secs_f64() * 1000.0);
                        break;
                    }
                }
                Ok(_) => {}
                Err(_) => return,
            }
        }
    }
    let _ = reg.kill(&meta.id);

    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let pct = |p: f64| samples[((samples.len() as f64 - 1.0) * p) as usize];
    println!("harness echo latency over {} samples (ms)", samples.len());
    println!(
        "  p50 {:.3}  p90 {:.3}  p99 {:.3}  max {:.3}",
        pct(0.5),
        pct(0.9),
        pct(0.99),
        samples[samples.len() - 1]
    );
}
