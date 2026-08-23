//! The goal rail: mounts the `goal` service and annotates input without charging it.
//!
//! Two jobs, and the second one is the interesting half.
//!
//! It claims the `goal` key with a [`GoalBook`] restored from a journal, which is how
//! phase, revision, cap and rounds-used survive a restart. And it sits on the
//! `session.input` around chain purely to *read*: it stamps the goal's state into the
//! request's notes and delegates. It never touches the cap from there, and that is
//! deliberate. A continuation round and a human asking "what is going on?" arrive at
//! a session by exactly the same path, so a listener that counted writes would charge
//! the loop's budget for a person's question. The cap is spent by
//! [`GoalApi::begin_round`] and by nothing else: the caller starting a round has to
//! say so.
//!
//! Mounting always comes back disarmed, because there is nothing in the journal that
//! could have said otherwise. See [`crate::services::goal`].

mod journal;

use std::sync::Arc;

use crate::events::SessionInput;
use crate::plugin::{Context, Plugin};
use crate::services::goal::{
    GoalApi, GoalBook, GoalJournal, GoalPhase, GoalService, MemoryJournal,
};

pub use journal::SqliteGoalJournal;

/// Claims the `goal` key.
///
/// Config: `{ "path": "/path/to.db" }` for a durable journal, `":memory:"` for the
/// real SQL without a file, and nothing at all for a journal that forgets with the
/// process.
pub struct SessionGoal;

impl Plugin for SessionGoal {
    fn name(&self) -> &'static str {
        "session-goal"
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        let journal: Box<dyn GoalJournal> = match ctx.config().get("path").and_then(|v| v.as_str())
        {
            Some(path) => Box::new(SqliteGoalJournal::open(path)?),
            None => Box::new(MemoryJournal::new()),
        };
        let book = Arc::new(GoalBook::restore(journal)?);
        tracing::info!(
            entry = ctx.id(),
            goals = book.len(),
            "goals restored, every one of them disarmed"
        );

        let api: Arc<dyn GoalApi> = book.clone();
        ctx.provide::<GoalService>(api)?;

        ctx.around::<SessionInput, _>("goal.turn-note", move |request, next| {
            if let Some(note) = note_for(book.as_ref(), &request.session) {
                request.notes.push(note);
            }
            // Delegate, always. The goal is state a write is described by, never
            // policy a write is refused for; refusing input is the guard's job.
            next.run(request)
        });
        Ok(())
    }
}

/// What this session's goal looks like right now, in one line for the input notes.
fn note_for(book: &GoalBook, session: &str) -> Option<String> {
    let snapshot = book.snapshot(session)?;
    let tail = match (snapshot.phase, snapshot.block_code.as_deref()) {
        (GoalPhase::Blocked, Some(code)) => format!(" {code}"),
        _ if snapshot.armed => " armed".to_string(),
        _ => " disarmed".to_string(),
    };
    Some(format!(
        "session-goal: {} {}/{}{tail}",
        snapshot.phase.as_str(),
        snapshot.rounds_used,
        snapshot.round_cap,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    use serde_json::json;

    use crate::entry::{Entry, EntryList};
    use crate::events::{InputDecision, InputRequest};
    use crate::loader::Loader;
    use crate::services::goal::{GoalSnapshot, RoundOutcome, RoundRefusal, ROUND_CAP_REACHED};
    use crate::{boot_with, FiberState};

    /// Names the directory a restart child boots its journal in.
    const RESTART_DIR: &str = "JUANCODED_GOAL_RESTART_DIR";
    /// What a restart child prints so its parent can read the state it saw.
    const MARKER: &str = "GOAL-RESTART-STATE ";

    fn tree(config: serde_json::Value) -> Loader {
        let entries = EntryList::new().push(Entry::new("goal", "session-goal").config(config));
        boot_with(&entries).unwrap().0
    }

    fn api(loader: &Loader) -> Arc<dyn GoalApi> {
        loader.services().resolve::<GoalService>().unwrap()
    }

    /// A person typing into the session. It travels the same chain a continuation
    /// round's write would.
    fn human_turn(loader: &Loader, session: &str) -> InputRequest {
        let mut request = InputRequest::new(session, b"what is going on?\n".to_vec());
        let decision = loader
            .bus()
            .waterfall::<SessionInput>(&mut request, |r| InputDecision::Delivered(r.data.len()));
        assert_eq!(decision, InputDecision::Delivered(18));
        request
    }

    #[test]
    fn the_plugin_claims_the_goal_key_and_takes_it_back_when_the_row_is_disabled() {
        let mut entries = EntryList::new().push(Entry::new("goal", "session-goal"));
        let (mut loader, report) = boot_with(&entries).unwrap();
        assert!(report.is_clean(), "{:?}", report.diagnostics());
        assert!(loader.services().has("goal"));
        assert_eq!(
            loader.bus().listeners_of::<SessionInput>(),
            ["goal.turn-note"]
        );

        entries.set_disabled("goal", true);
        loader.apply(&entries).unwrap();
        assert_eq!(loader.state("goal").unwrap(), &FiberState::Disabled);
        assert!(!loader.services().has("goal"));
        assert!(loader.bus().listeners_of::<SessionInput>().is_empty());
    }

    #[test]
    fn an_unrelated_human_turn_does_not_consume_the_round_cap() {
        let loader = tree(json!({}));
        let goal = api(&loader);
        let created = goal.create("s1", "land the ticket", 3).unwrap();
        let armed = goal.arm(&created.at(), "juan").unwrap();

        // Three turns from a person, on an armed goal, down the same chain a
        // continuation round writes through.
        for _ in 0..3 {
            let request = human_turn(&loader, "s1");
            assert_eq!(
                request.notes,
                ["session-goal: active 0/3 armed"],
                "the plugin saw the turn"
            );
        }
        let after = goal.get("s1").unwrap();
        assert_eq!(after.rounds_used, 0, "a human turn is not a round");
        assert_eq!(after.revision, 1, "and is not a mutation of the record");
        assert!(
            goal.armed("s1").is_some(),
            "nor does it cost the authorization"
        );

        // Two continuation cycles do consume it, because the caller said so.
        let mut at = armed.at();
        for spent in 1..=2 {
            let outcome = goal.begin_round(&at).unwrap();
            assert!(outcome.started(), "{outcome:?}");
            assert_eq!(outcome.goal().rounds_used, spent);
            at = outcome.goal().at();
        }

        // More turns from the person, interleaved. Still two.
        for _ in 0..5 {
            let request = human_turn(&loader, "s1");
            assert_eq!(request.notes, ["session-goal: active 2/3 armed"]);
        }
        assert_eq!(goal.get("s1").unwrap().rounds_used, 2);

        // The budget is three, so the third round runs and the fourth stops the loop.
        let third = goal.begin_round(&at).unwrap();
        assert!(third.started());
        let fourth = goal.begin_round(&third.goal().at()).unwrap();
        assert!(matches!(
            fourth,
            RoundOutcome::Refused {
                reason: RoundRefusal::CapReached,
                ..
            }
        ));
        assert_eq!(goal.get("s1").unwrap().rounds_used, 3);

        // And a person can still talk to a session whose loop is blocked.
        let request = human_turn(&loader, "s1");
        assert_eq!(
            request.notes,
            [format!("session-goal: blocked 3/3 {ROUND_CAP_REACHED}")]
        );
        assert_eq!(goal.get("s1").unwrap().rounds_used, 3);
    }

    #[test]
    fn a_session_with_no_goal_passes_through_the_chain_unannotated() {
        let loader = tree(json!({}));
        let request = human_turn(&loader, "ungoverned");
        assert!(request.notes.is_empty());
    }

    #[test]
    fn a_second_tree_over_the_same_file_replays_the_record_and_not_the_authorization() {
        let dir = scratch("same-file");
        let config = json!({ "path": db(&dir).to_string_lossy() });

        let first = tree(config.clone());
        let goal = api(&first);
        let created = goal.create("s1", "land the ticket", 4).unwrap();
        let armed = goal.arm(&created.at(), "juan").unwrap();
        let started = goal.begin_round(&armed.at()).unwrap();
        assert!(started.started());
        assert!(goal.armed("s1").is_some());
        drop(first);

        let second = tree(config);
        let goal = api(&second);
        let back = goal.get("s1").unwrap();
        assert_eq!(back.objective, "land the ticket");
        assert_eq!((back.rounds_used, back.round_cap, back.revision), (1, 4, 2));
        assert!(goal.armed("s1").is_none());
        assert!(matches!(
            goal.begin_round(&back.at()).unwrap(),
            RoundOutcome::Refused {
                reason: RoundRefusal::Disarmed,
                ..
            }
        ));
        std::fs::remove_dir_all(&dir).ok();
    }

    /// The real thing: two processes, neither of them this one.
    ///
    /// A same-process reload can only show that nothing was read back from the
    /// journal. It cannot show that nothing else carried the authorization across,
    /// because in one process there is always something that could have. So the goal
    /// is armed in a child process that then exits, and read back in a second child
    /// that shares nothing with it but the file on disk.
    #[test]
    fn a_real_restart_brings_the_goal_back_and_the_authorization_never() {
        let dir = scratch("restart");
        let armed = run_child("goal_restart_child_arms", &dir);
        assert!(armed.state.armed, "the first process armed it: {armed:?}");
        assert_eq!(armed.state.armed_by.as_deref(), Some("juan"));
        assert_eq!(armed.state.rounds_used, 2);
        assert_eq!(armed.state.revision, 3);

        let restarted = run_child("goal_restart_child_observes", &dir);
        assert!(
            !restarted.state.armed,
            "a restarted daemon came back authorized: {restarted:?}"
        );
        assert_eq!(restarted.state.armed_by, None);
        // Everything durable did come back, so this is a restart and not an empty file.
        assert_eq!(restarted.state.objective, armed.state.objective);
        assert_eq!(restarted.state.phase, GoalPhase::Active);
        assert_eq!(restarted.state.rounds_used, 2);
        assert_eq!(restarted.state.round_cap, 5);
        assert_eq!(restarted.state.revision, 3);
        // And the round it asked for on the way out was refused for want of a human.
        assert_eq!(restarted.round.as_deref(), Some("disarmed"));

        let here = std::process::id();
        assert!(
            armed.pid != here && restarted.pid != here && armed.pid != restarted.pid,
            "three distinct processes were the point: {here} {armed:?} {restarted:?}"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    #[ignore = "spawned by a_real_restart_...; needs JUANCODED_GOAL_RESTART_DIR"]
    fn goal_restart_child_arms() {
        let loader = tree(json!({ "path": db(&child_dir()).to_string_lossy() }));
        let goal = api(&loader);
        let created = goal.create("s1", "land the ticket", 5).unwrap();
        let mut at = goal.arm(&created.at(), "juan").unwrap().at();
        for _ in 0..2 {
            let outcome = goal.begin_round(&at).unwrap();
            assert!(outcome.started(), "{outcome:?}");
            at = outcome.goal().at();
        }
        report(goal.as_ref(), None);
    }

    #[test]
    #[ignore = "spawned by a_real_restart_...; needs JUANCODED_GOAL_RESTART_DIR"]
    fn goal_restart_child_observes() {
        let loader = tree(json!({ "path": db(&child_dir()).to_string_lossy() }));
        let goal = api(&loader);
        let back = goal
            .get("s1")
            .expect("the goal did not survive the restart");
        let round = match goal.begin_round(&back.at()).unwrap() {
            RoundOutcome::Started(_) => "started",
            RoundOutcome::Refused {
                reason: RoundRefusal::Disarmed,
                ..
            } => "disarmed",
            RoundOutcome::Refused { reason, .. } => panic!("unexpected refusal {reason:?}"),
        };
        report(goal.as_ref(), Some(round));
    }

    #[derive(Debug)]
    struct ChildReport {
        pid: u32,
        state: GoalSnapshot,
        round: Option<String>,
    }

    /// Print what this process sees, for its parent to read off stdout.
    fn report(goal: &dyn GoalApi, round: Option<&str>) {
        let line = json!({
            "pid": std::process::id(),
            "state": goal.snapshot("s1").unwrap(),
            "round": round,
        });
        println!("{MARKER}{line}");
    }

    fn child_dir() -> PathBuf {
        PathBuf::from(std::env::var(RESTART_DIR).expect("this test is spawned, not run directly"))
    }

    fn db(dir: &Path) -> PathBuf {
        dir.join("goals.db")
    }

    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("juancoded-goal-{name}-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Run one of the ignored tests above as a fresh process against `dir`.
    fn run_child(test: &str, dir: &Path) -> ChildReport {
        let exe = std::env::current_exe().expect("a test binary knows its own path");
        let name = format!("plugins::goal::tests::{test}");
        let output = Command::new(&exe)
            .args([
                &name,
                "--exact",
                "--ignored",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(RESTART_DIR, dir)
            .output()
            .expect("spawn the test binary again");
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            output.status.success(),
            "child `{test}` failed: {}\n{stdout}",
            String::from_utf8_lossy(&output.stderr)
        );
        // Split rather than strip: libtest writes `test <name> ... ` with no newline
        // before the child's own output lands, so the marker is mid-line.
        let line = stdout
            .lines()
            .find_map(|l| l.split_once(MARKER).map(|(_, rest)| rest.trim()))
            .unwrap_or_else(|| panic!("child `{test}` printed no state:\n{stdout}"));
        let value: serde_json::Value = serde_json::from_str(line).unwrap();
        ChildReport {
            pid: value["pid"].as_u64().unwrap() as u32,
            state: serde_json::from_value(value["state"].clone()).unwrap(),
            round: value["round"].as_str().map(str::to_string),
        }
    }
}
