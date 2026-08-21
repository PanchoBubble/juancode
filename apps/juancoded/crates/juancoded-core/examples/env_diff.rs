//! Print the diff between a pty child's environment and our own.
//!
//! The prime directive says the child's environment IS ours, and this is how that is
//! checked against a real spawn rather than argued about. `/usr/bin/env` in a real pty,
//! parsed, diffed both ways against `std::env::vars`. Run it from a plain terminal to
//! see what a terminal launch would give a CLI:
//!
//! ```sh
//! cargo run --example env_diff -p juancoded-core
//! ```
//!
//! An overlay can be added as `KEY=VALUE` arguments, which is how opencode's opt-in
//! bypass is inspected:
//!
//! ```sh
//! cargo run --example env_diff -p juancoded-core -- OPENCODE_PERMISSION='{"edit":"allow"}'
//! ```

use std::collections::HashMap;

use juancoded_core::provider::resolve_provider_bin;
use juancoded_core::pty::{PtyEvent, PtyHandle, SpawnSpec};

fn main() {
    let env_overlay: HashMap<String, String> = std::env::args()
        .skip(1)
        .filter_map(|arg| {
            arg.split_once('=')
                .map(|(k, v)| (k.to_string(), v.to_string()))
        })
        .collect();
    let announced = env_overlay.keys().cloned().collect::<Vec<_>>();

    // What we would actually spawn, resolved the way a login shell resolves it.
    for provider in ["claude", "codex", "opencode"] {
        match resolve_provider_bin(provider) {
            Some(path) => println!("RESOLVED {provider} -> {path}"),
            None => println!("RESOLVED {provider} -> (nothing found)"),
        }
    }

    let pty = PtyHandle::spawn(
        SpawnSpec {
            program: "/usr/bin/env".into(),
            args: vec![],
            cwd: "/tmp".into(),
            cols: 200,
            rows: 50,
            env_overlay,
        },
        512,
    )
    .expect("spawn");
    let mut rx = pty.subscribe();
    let mut out = Vec::new();
    while let Ok(PtyEvent::Output(bytes)) = rx.blocking_recv() {
        out.extend_from_slice(&bytes);
    }

    let text = String::from_utf8_lossy(&out).to_string();
    let child: HashMap<String, String> = text
        .lines()
        .filter_map(|line| line.trim_end_matches('\r').split_once('='))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    let ours: HashMap<String, String> = std::env::vars().collect();

    let mut findings = 0;
    for (key, value) in &child {
        if !ours.contains_key(key) {
            let tag = if announced.contains(key) {
                "OVERLAY"
            } else {
                findings += 1;
                "ADDED  "
            };
            println!("{tag} {key}={value}");
        }
    }
    for (key, value) in &ours {
        // macOS strips DYLD_* when exec'ing a system binary, and a CLI would not get
        // it from a terminal either. Not ours to promise, so not a finding.
        if key.starts_with("DYLD_") {
            continue;
        }
        match child.get(key) {
            None => {
                findings += 1;
                println!("MISSING {key}");
            }
            Some(theirs) if theirs != value => {
                findings += 1;
                println!("CHANGED {key}: ours={value:?} child={theirs:?}");
            }
            _ => {}
        }
    }
    println!(
        "-- {} keys ours, {} keys child, {findings} unexplained difference(s)",
        ours.len(),
        child.len()
    );
}
