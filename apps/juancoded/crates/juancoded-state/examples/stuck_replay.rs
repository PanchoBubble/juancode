//! Replay real claude transcripts through the repeat-tool chain and report what it
//! would have said.
//!
//! The point is calibration, not a test: unit tests prove the counter counts, and this
//! answers the different question of whether the thing it counts ever happens. It
//! reads through the real seam — [`juancoded_transcripts::claude::ClaudeJsonl`], the
//! same source the daemon's pump uses — so what the chain sees here is exactly what it
//! sees live, sub-agent lines dropped and all.
//!
//! ```sh
//! cargo run -p juancoded-state --example stuck_replay                    # every project
//! cargo run -p juancoded-state --example stuck_replay -- <file>…         # named files
//! cargo run -p juancoded-state --example stuck_replay -- --thresholds 2  # sweep lower
//! ```
//!
//! `--thresholds` exists because the shipped `[3, 5, 8]` fired zero times across this
//! machine's whole corpus, and a detector that never fires on the only real data there
//! is has to be able to say what run length it would have taken.
//!
//! One line per file that reached a run of two or more, then a histogram of run
//! lengths over the whole corpus and every advisory that fired.

use std::path::{Path, PathBuf};

use juancoded_state::stuck::{RepeatChain, StuckAlert, REPEAT_THRESHOLDS};
use juancoded_transcripts::claude::{projects_root, ClaudeJsonl};
use juancoded_transcripts::{Binding, TranscriptSource};

fn main() -> anyhow::Result<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut thresholds = REPEAT_THRESHOLDS.to_vec();
    if let Some(at) = args.iter().position(|a| a == "--thresholds") {
        let spec = args
            .get(at + 1)
            .cloned()
            .unwrap_or_else(|| "--thresholds needs a list, e.g. 2,3,5".into());
        thresholds = spec
            .split(',')
            .filter_map(|t| t.trim().parse().ok())
            .collect();
        args.drain(at..=at + 1);
    }
    let files = if args.is_empty() {
        all_transcripts(&projects_root())
    } else {
        args.iter().map(PathBuf::from).collect()
    };
    if files.is_empty() {
        println!("no transcripts under {}", projects_root().display());
        return Ok(());
    }

    let source = ClaudeJsonl::new();
    let mut histogram: Vec<u64> = vec![0; 64];
    let mut calls = 0u64;
    let mut alerts: Vec<(PathBuf, StuckAlert)> = Vec::new();
    let mut longest: Vec<(u32, String, PathBuf)> = Vec::new();
    let mut read_failures = 0u64;

    for path in &files {
        let binding = Binding::ClaudeJsonl { path: path.clone() };
        // One read from an empty cursor is the whole file, which is what a replay wants
        // and precisely what the live pump must never do (that is its `fresh` set).
        let (events, _cursor) = match source.read(&binding, &String::new()) {
            Ok(read) => read,
            Err(_) => {
                read_failures += 1;
                continue;
            }
        };
        let mut chain = RepeatChain::with_thresholds(thresholds.clone());
        let mut best = (0u32, String::new());
        let mut prior = 0u32;
        for emitted in &events {
            let is_call = matches!(
                emitted.event,
                juancoded_transcripts::TranscriptEvent::ToolCall { .. }
            );
            if is_call {
                calls += 1;
            }
            if let Some(alert) = chain.on_event(&emitted.event) {
                alerts.push((path.clone(), alert));
            }
            // Only a call can move the run, and only sampling on calls keeps the inert
            // events between two of them from re-recording the same peak.
            if !is_call {
                continue;
            }
            let run = chain.run();
            // A run's length is only known when it ends, so record the peak as it falls.
            if run <= prior && prior > 0 {
                bump(&mut histogram, prior);
            }
            if run > best.0 {
                best = (run, chain.tool().unwrap_or("-").to_string());
            }
            prior = run;
        }
        if prior > 0 {
            bump(&mut histogram, prior);
        }
        if best.0 >= 2 {
            longest.push((best.0, best.1, path.clone()));
        }
    }

    longest.sort_by(|a, b| b.0.cmp(&a.0));
    println!(
        "files: {}  toolCalls: {calls}  unreadable: {read_failures}",
        files.len()
    );
    println!("identical-argument run lengths:");
    for (len, count) in histogram.iter().enumerate().skip(1) {
        if *count > 0 {
            println!("  {len:>3}: {count}");
        }
    }
    println!("runs of 2 or more ({}):", longest.len());
    for (run, tool, path) in &longest {
        println!("  {run} x {tool}  {}", path.display());
    }
    println!("advisories at thresholds {thresholds:?}: {}", alerts.len());
    for (path, alert) in &alerts {
        println!("  [{}] {}", path.display(), alert.advice);
    }
    Ok(())
}

fn bump(histogram: &mut Vec<u64>, run: u32) {
    let idx = run as usize;
    if idx >= histogram.len() {
        histogram.resize(idx + 1, 0);
    }
    histogram[idx] += 1;
}

fn all_transcripts(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(dirs) = std::fs::read_dir(root) else {
        return out;
    };
    for dir in dirs.flatten() {
        let Ok(files) = std::fs::read_dir(dir.path()) else {
            continue;
        };
        for file in files.flatten() {
            let path = file.path();
            if path.extension().is_some_and(|e| e == "jsonl") {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}
