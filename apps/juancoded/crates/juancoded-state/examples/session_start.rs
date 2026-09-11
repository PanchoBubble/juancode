//! How long a new session takes to become usable, split by stage.
//!
//! The question this answers is the one a person asks while watching a pane stay
//! blank: where did those seconds go. It times the whole path — create frame in,
//! first pty byte out — for an ordinary session and for one isolated in a git
//! worktree, and separately times the steps inside the worktree setup so the two
//! numbers can be subtracted honestly.
//!
//! It spawns the REAL provider CLI, because a stand-in that echoes instantly
//! measures the harness and hides the thing that actually costs the user seconds.
//!
//! Run: cargo run --release -p juancoded-state --example session_start -- <repo> [runs]

use std::time::{Duration, Instant};

use juancoded_core::model::ProviderId;
use juancoded_core::worktree;
use juancoded_state::registry::{CreateRequest, SessionEvent};

/// Long enough for a cold `claude` to paint, short enough that a hung boot does not
/// hang the harness.
const FIRST_FRAME_TIMEOUT: Duration = Duration::from_secs(30);

struct Run {
    create_ms: f64,
    first_frame_ms: f64,
}

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let repo = args
        .next()
        .unwrap_or_else(|| std::env::current_dir().unwrap().to_string_lossy().into());
    let runs: usize = args.next().and_then(|n| n.parse().ok()).unwrap_or(3);

    // In-memory store so the measurement leaves no rows behind; real provider
    // binaries, because their cold start is half of what is being measured.
    let (_loader, _report, reg) =
        juancoded_state::boot_with(&juancoded_state::plugins::entries_over_store(":memory:"))
            .expect("mount the tree");

    for isolate in [false, true] {
        let mut samples = Vec::new();
        for _ in 0..runs {
            let mut rx = reg.subscribe();
            let start = Instant::now();
            let meta = match reg.create(CreateRequest {
                provider: ProviderId::Claude,
                cwd: repo.clone(),
                cols: 120,
                rows: 40,
                skip_permissions: false,
                model: None,
                preset: None,
                isolate_worktree: isolate,
                dispatch_id: None,
                owner: 1,
            }) {
                Ok(meta) => meta,
                Err(e) => {
                    eprintln!("create failed: {e}");
                    return;
                }
            };
            let create_ms = start.elapsed().as_secs_f64() * 1000.0;
            let first_frame_ms = loop {
                match tokio::time::timeout(FIRST_FRAME_TIMEOUT, rx.recv()).await {
                    Ok(Ok(SessionEvent::Output { session_id, bytes })) if session_id == meta.id => {
                        if !bytes.is_empty() {
                            break start.elapsed().as_secs_f64() * 1000.0;
                        }
                    }
                    Ok(Ok(_)) => {}
                    Ok(Err(_)) | Err(_) => break f64::NAN,
                }
            };
            samples.push(Run {
                create_ms,
                first_frame_ms,
            });
            let _ = reg.kill(&meta.id);
            if let Some(path) = &meta.worktree_path {
                let _ = worktree::remove(path);
                drop_branch(&repo, path);
            }
            // The CLI's own teardown, and the pty's, before the next run starts.
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        report(isolate, &samples);
    }

    // The steps inside worktree setup, timed on their own: the end-to-end pair above
    // says how much isolation costs, this says which step spent it.
    println!("\nworktree setup stages (ms, {runs} runs)");
    for _ in 0..runs {
        let name = format!("bench{}", uuid_ish());
        match worktree::create_timed(&repo, &name) {
            Ok((created, s)) => {
                println!(
                    "  root {:7.1}  base_ref(fetch) {:7.1}  worktree add {:7.1}  link node_modules {:7.1}",
                    s.repo_root_ms, s.base_ref_ms, s.worktree_add_ms, s.link_modules_ms
                );
                let _ = worktree::remove(&created.path);
                drop_branch(&repo, &created.path);
            }
            Err(e) => println!("  failed: {e}"),
        }
    }
}

fn report(isolate: bool, samples: &[Run]) {
    println!(
        "\nsession start, isolateWorktree={isolate} ({} runs, ms)",
        samples.len()
    );
    for s in samples {
        println!(
            "  create {:8.1}   first frame {:8.1}",
            s.create_ms, s.first_frame_ms
        );
    }
    let med = |f: fn(&Run) -> f64| {
        let mut v: Vec<f64> = samples.iter().map(f).filter(|n| !n.is_nan()).collect();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        v.get(v.len() / 2).copied().unwrap_or(f64::NAN)
    };
    println!(
        "  median: create {:.1}   first frame {:.1}",
        med(|s| s.create_ms),
        med(|s| s.first_frame_ms)
    );
}

/// `worktree::remove` leaves the branch behind on purpose. A benchmark's branches
/// are empty by construction, so it cleans up after itself rather than leaving a
/// `juancode/bench*` for every run in the repo it measured.
fn drop_branch(repo: &str, worktree_path: &str) {
    let name = std::path::Path::new(worktree_path)
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    let _ = std::process::Command::new("git")
        .args(["branch", "-D", &format!("juancode/{name}")])
        .current_dir(repo)
        .output();
}

fn uuid_ish() -> String {
    uuid::Uuid::new_v4()
        .to_string()
        .chars()
        .take(8)
        .collect::<String>()
}
