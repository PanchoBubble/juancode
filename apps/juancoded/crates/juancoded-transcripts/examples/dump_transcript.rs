//! Print the typed events a real transcript produces. The seam's own `dump-config`.
//!
//! ```text
//! cargo run -p juancoded-transcripts --example dump_transcript -- <cwd> <cli-session-id> [limit]
//! cargo run -p juancoded-transcripts --example dump_transcript -- --opencode <db> <conversation> [limit]
//! ```
//!
//! Read-only, like everything else here: it locates the file the way the daemon does,
//! reads it once from offset zero, and prints. It stores no cursor and touches nothing.

use juancoded_transcripts::claude::{transcript_path, ClaudeJsonl};
use juancoded_transcripts::opencode::OpencodeSqlite;
use juancoded_transcripts::{Binding, TranscriptEvent, TranscriptSource};

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (source, binding, limit): (Box<dyn TranscriptSource>, Binding, usize) =
        match args.as_slice() {
            [flag, db, conversation, rest @ ..] if flag == "--opencode" => (
                Box::new(OpencodeSqlite::new()),
                Binding::OpencodeSqlite {
                    db: db.into(),
                    conversation: conversation.clone(),
                },
                rest.first().and_then(|n| n.parse().ok()).unwrap_or(40),
            ),
            [cwd, id, rest @ ..] => {
                let root = juancoded_transcripts::claude::projects_root();
                let Some(path) = transcript_path(&root, cwd, id) else {
                    eprintln!("no transcript for {id} under {}", root.display());
                    std::process::exit(1);
                };
                println!("{}", path.display());
                (
                    Box::new(ClaudeJsonl::new()),
                    Binding::ClaudeJsonl { path },
                    rest.first().and_then(|n| n.parse().ok()).unwrap_or(40),
                )
            }
            _ => {
                eprintln!("usage: dump_transcript <cwd> <cli-session-id> [limit]");
                eprintln!("       dump_transcript --opencode <db> <conversation> [limit]");
                std::process::exit(2);
            }
        };

    let (events, cursor) = source.read(&binding, &String::new())?;
    println!("{} events, cursor {cursor}\n", events.len());

    for emitted in events.iter().take(limit) {
        let turn = emitted.turn.as_deref().unwrap_or("-");
        let body = match &emitted.event {
            TranscriptEvent::TurnStart { prompt } => format!("prompt {}", one_line(prompt)),
            TranscriptEvent::TurnEnd { reason } => {
                format!("reason={}", reason.as_deref().unwrap_or("-"))
            }
            TranscriptEvent::Step { step, model } => {
                format!("{step} model={}", model.as_deref().unwrap_or("-"))
            }
            TranscriptEvent::Assistant { text, .. } => one_line(text),
            TranscriptEvent::Thinking { text, .. } => one_line(text),
            TranscriptEvent::ToolCall { name, input, .. } => {
                format!("{name} {}", one_line(input))
            }
            TranscriptEvent::ToolResult { ok, output, .. } => {
                format!("ok={ok} {}", one_line(output))
            }
            TranscriptEvent::Usage { usage, .. } => format!(
                "in={} out={} cacheRead={} cacheWrite={} reasoning={}",
                usage.input, usage.output, usage.cache_read, usage.cache_write, usage.reasoning
            ),
        };
        println!(
            "{:<12} turn={:<38} {}",
            emitted.event.kind(),
            &turn[..turn.len().min(38)],
            body
        );
    }
    if events.len() > limit {
        println!("... {} more", events.len() - limit);
    }
    Ok(())
}

fn one_line(text: &str) -> String {
    let flat: String = text
        .chars()
        .map(|c| if c == '\n' || c == '\r' { ' ' } else { c })
        .collect();
    let flat = flat.trim();
    if flat.chars().count() <= 90 {
        return flat.to_string();
    }
    format!("{}…", flat.chars().take(90).collect::<String>())
}
