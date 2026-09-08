//! The tracked-PR watch list, its poll loop, and the sessions it drives.
//!
//! A port of `PrTrackingEngine`, and the daemon-side half protocol v1 was missing: the
//! Swift core has owned this since juancode-bt2, so under `JUANCODE_CORE=rust` the
//! whole PR-watching surface — the sidebar rows, the CI pokes, the Telegram ping path —
//! had nothing behind it (juancode-4lnv).
//!
//! What tracking a PR *is*: a dedicated agent session, standing on a worktree with the
//! PR's branch checked out, seeded once with the PR context and the
//! auto-fix-or-escalate contract. From then on a poll loop diffs the PR's `gh`
//! activity, types fix prompts into that session for the changes an agent should just
//! make, and raises a [`TrackNotification`] for the ones that need a human. juancode
//! reviews nothing itself; it decides who the work belongs to and hands it over.
//!
//! Two rules the wire depends on, and both live here rather than in the frames:
//!
//! 1. **The list is the unit.** Every change produces the complete watch list, replaced
//!    wholesale. There are no deltas, so a client's whole job is to replace what it is
//!    holding.
//! 2. **A change is a change.** The engine publishes after every mutation and after
//!    every poll pass; the *connection* is what compares the list it would send against
//!    the one it last sent and stays silent when they match (see
//!    `Fanout::tracked_prs`). The comparison belongs there because it is the WIRE shape
//!    that must have moved: a `repoNwo` backfill changes the engine's row and nothing a
//!    client can see, and a poll pass over an unreachable `gh` changes nothing at all.
//!    Re-announcing either one races whatever the client asked for next, which is how a
//!    client that untracks a PR gets answered by a snapshot that still lists it.
//!
//! Not ported from the Swift engine, and deliberately: the webhook ingest
//! (`ingestWebhook`, the debounce, `findByRepoNumber`), because the trigger for it is an
//! HTTP endpoint this daemon does not serve — with no `/api/pr-webhook` here there is
//! nothing to debounce, and the poll is this core's only update path. The respawn ladder
//! (`respawn`, which opens a REPLACEMENT session on a fresh worktree when the original
//! conversation cannot be resumed) is also absent: this core revives the recorded
//! session and, failing that, says so through a notification rather than silently
//! rebinding the watch to a session the client has never heard of.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tracing::{debug, info, warn};

use juancoded_core::gh;
use juancoded_core::model::{now_ms, ProviderId};
use juancoded_core::pr::{
    auto_fix_prompt, classify_pr_activity, stalled_ci_fix_reason, track_seed_prompt,
    BranchWorktree, PrActivity, TrackEvent, TrackNotification, TrackedPr,
};
use juancoded_core::worktree;
use juancoded_persistence::SessionStore;
use juancoded_state::registry::CreateRequest;
use juancoded_state::{ClientId, SessionsApi};

use crate::seed::{deliver_text, log_outcome, Precondition, SeedTiming};

/// Cadence of the poll loop, matching the Swift core's `Config.prPollInterval` without
/// its webhook branch: that branch demotes the poll to a slow reconciler *because*
/// webhooks are delivering changes in near-real-time, and this core has no webhook path
/// to be the fast half of that pair.
pub const POLL_INTERVAL: Duration = Duration::from_secs(60);

/// The grid a tracked PR's agent is spawned at. It has no viewport of its own until
/// somebody opens it, and whatever the CLI prints in its first turn is wrapped at the
/// spawn width forever, so this matches the wire layer's `DEFAULT_GRID` rather than a
/// nominal 80x24 that would leave a permanently narrow transcript.
const SPAWN_GRID: (u16, u16) = (120, 40);

/// What a client asked to be watched.
#[derive(Debug, Clone)]
pub struct TrackRequest {
    /// The repo, which is the identity a watch is keyed by — never a worktree.
    pub cwd: String,
    pub number: i64,
    pub title: String,
    pub url: String,
    pub branch: String,
    /// The connection that asked. It owns the spawned session's grid, so the claim is
    /// released when that client goes away; a daemon-owned claim would leave a session
    /// nobody could ever resize.
    pub owner: ClientId,
}

/// What subscribers hear.
#[derive(Debug, Clone)]
pub enum TrackedPrChange {
    /// The whole watch list. See rule 2 above for who decides whether it goes out.
    List(Vec<TrackedPr>),
    /// One escalation, as a ping a client can alert on without diffing the list.
    Notification {
        tracked_id: String,
        pr_number: i64,
        notification: TrackNotification,
    },
}

/// How many changes a slow subscriber may fall behind before it starts losing them. A
/// lost `List` is survivable by construction — the next one is the whole list again —
/// which is the other reason there are no deltas.
const CHANGE_BUFFER: usize = 64;

pub struct TrackedPrs {
    sessions: Arc<dyn SessionsApi>,
    store: Arc<dyn SessionStore>,
    changes: broadcast::Sender<TrackedPrChange>,
    /// PRs under watch, keyed by [`TrackedPr::key`]. A `std::sync::Mutex` and never held
    /// across an `await`: every method here reads a clone out, computes, and writes back.
    tracked: Mutex<BTreeMap<String, TrackedPr>>,
    /// The poll loop, running only while something is tracked. Swift's rule, kept: a
    /// tick over an empty list costs nothing, but "the loop starts when the first PR is
    /// tracked" is what makes the first pass land immediately after a track rather than
    /// up to a whole interval later.
    poll: Mutex<Option<JoinHandle<()>>>,
    poll_interval: Duration,
    seed_timing: SeedTiming,
}

impl TrackedPrs {
    /// Open the engine over a store, restoring whatever was being watched before the
    /// last restart. The loop is not started here — [`Self::start_if_tracking`] does
    /// that, from the same place the daemon's other pumps are started.
    pub fn new(
        sessions: Arc<dyn SessionsApi>,
        store: Arc<dyn SessionStore>,
        poll_interval: Duration,
    ) -> Arc<Self> {
        let restored = match store.tracked_prs() {
            Ok(rows) => rows,
            Err(e) => {
                // A watch list that will not load is not a reason to refuse to serve:
                // the frames still work, they just start from nothing.
                warn!("could not restore the tracked-PR watch list: {e:#}");
                Vec::new()
            }
        };
        let tracked = restored.into_iter().map(|pr| (pr.id.clone(), pr)).collect();
        Arc::new(Self {
            sessions,
            store,
            changes: broadcast::channel(CHANGE_BUFFER).0,
            tracked: Mutex::new(tracked),
            poll: Mutex::new(None),
            poll_interval,
            seed_timing: SeedTiming::default(),
        })
    }

    pub fn subscribe(&self) -> broadcast::Receiver<TrackedPrChange> {
        self.changes.subscribe()
    }

    /// The watch list, most-recently-polled first — the order the Swift core's
    /// `AppModel.trackedList` renders, so both cores hand a client the same rows in the
    /// same places.
    pub fn list(&self) -> Vec<TrackedPr> {
        let mut out: Vec<TrackedPr> = self.held().values().cloned().collect();
        out.sort_by(|a, b| {
            (b.last_polled_at.unwrap_or(0), b.number)
                .cmp(&(a.last_polled_at.unwrap_or(0), a.number))
        });
        out
    }

    /// Start watching a PR: spawn the agent that will work it, seed it with the PR
    /// context, and publish the new list.
    ///
    /// `None` when the PR is already tracked (a no-op, not an error — the watch that
    /// exists is the one that was asked for) or when the session could not be spawned at
    /// all, which is the one case where tracking would be a row with nobody behind it.
    pub async fn track(self: &Arc<Self>, req: TrackRequest) -> Option<TrackedPr> {
        let key = TrackedPr::key(&req.cwd, req.number);
        if self.held().contains_key(&key) {
            return None;
        }

        // The agent works the PR on its own worktree with the PR's branch checked out,
        // so it never touches the main checkout and several tracked PRs can run at once.
        // The entry stays keyed by the REPO cwd while the session runs in the worktree.
        // A repo git cannot give us a tree for — no remote, offline with an unknown
        // branch, the branch open somewhere that refuses even a detached copy — is still
        // tracked in the repo root rather than not tracked at all.
        let worktree = self.pr_worktree(&req).await;
        let cwd = worktree
            .as_ref()
            .map(|w| w.path.clone())
            .unwrap_or_else(|| req.cwd.clone());
        let seed = track_seed_prompt(
            req.number,
            &req.title,
            &req.branch,
            &req.url,
            worktree.as_ref(),
        );
        let meta = match self.sessions.create(CreateRequest {
            provider: ProviderId::Claude,
            cwd,
            cols: SPAWN_GRID.0,
            rows: SPAWN_GRID.1,
            // The tracking contract is "go fix this and push"; an agent stopping on
            // every tool prompt cannot honour it unattended. Same choice the Swift
            // engine makes for the same reason.
            skip_permissions: true,
            model: Some("opus".into()),
            preset: None,
            // Already standing in the worktree above, which is the PR's branch rather
            // than a fresh `juancode/<name>` one this flag would cut.
            isolate_worktree: false,
            dispatch_id: None,
            owner: req.owner,
        }) {
            Ok(meta) => meta,
            Err(e) => {
                warn!(pr = req.number, "no session to track this PR with: {e}");
                return None;
            }
        };

        let entry = TrackedPr {
            id: key.clone(),
            number: req.number,
            title: req.title,
            url: req.url,
            branch: req.branch,
            cwd: req.cwd.clone(),
            session_id: Some(meta.id.clone()),
            repo_nwo: None,
            baseline: Default::default(),
            notifications: Vec::new(),
            last_polled_at: None,
            created_at: now_ms(),
        };
        self.held().insert(key.clone(), entry.clone());
        self.persist(&entry);
        self.publish_list();
        info!(pr = entry.number, session = %meta.id, worktree = ?worktree.as_ref().map(|w| &w.path),
              "tracking a pull request");

        // The seed spans the CLI's whole boot window, so it is delivered behind the
        // list: a client must not wait on a boot to learn the PR is being watched.
        let me = Arc::clone(self);
        let session = meta.id.clone();
        tokio::spawn(async move {
            let outcome = deliver_text(
                Arc::clone(&me.sessions),
                &session,
                &seed,
                me.seed_timing,
                Precondition::Booting,
            )
            .await;
            log_outcome(&session, &outcome);
        });

        // Repo identity is resolved off the track path: it is a `gh` round-trip, the
        // only thing that needs it is matching an inbound GitHub event, and a resolve
        // that misses here is backfilled by the next poll.
        let me = Arc::clone(self);
        let cwd = req.cwd;
        tokio::spawn(async move {
            if let Some(nwo) = gh::repo_nwo(&cwd).await {
                me.set_repo_nwo(&key, nwo);
            }
        });

        self.start_if_tracking();
        Some(entry)
    }

    /// Stop watching a PR, and publish the list without it. The agent session is left
    /// alone: it is a conversation, and the work in it outlives the watch.
    ///
    /// `false` when nothing was tracked under that id, and then nothing is published —
    /// a list that did not change carries no information.
    pub fn untrack(&self, tracked_id: &str) -> bool {
        if self.held().remove(tracked_id).is_none() {
            return false;
        }
        if let Err(e) = self.store.untrack_pr(tracked_id) {
            warn!(tracked = tracked_id, "could not persist the untrack: {e:#}");
        }
        self.publish_list();
        self.stop_if_idle();
        true
    }

    /// Dismiss a surfaced decision once the user has dealt with it. `false` when the
    /// watch or the notification is already gone.
    pub fn resolve_notification(&self, tracked_id: &str, notification_id: &str) -> bool {
        let entry = {
            let mut held = self.held();
            let Some(entry) = held.get_mut(tracked_id) else {
                return false;
            };
            let before = entry.notifications.len();
            entry.notifications.retain(|n| n.id != notification_id);
            if entry.notifications.len() == before {
                return false;
            }
            entry.clone()
        };
        self.persist(&entry);
        self.publish_list();
        true
    }

    /// Run the poll loop for as long as anything is tracked. Idempotent: called on every
    /// track, and once at boot for a watch list restored from the store.
    pub fn start_if_tracking(self: &Arc<Self>) {
        if self.held().is_empty() {
            return;
        }
        let mut poll = self.poll.lock().unwrap_or_else(|e| e.into_inner());
        if poll.as_ref().is_some_and(|h| !h.is_finished()) {
            return;
        }
        let me = Arc::clone(self);
        let interval = self.poll_interval;
        *poll = Some(tokio::spawn(async move {
            loop {
                me.poll_once().await;
                tokio::time::sleep(interval).await;
            }
        }));
    }

    fn stop_if_idle(&self) {
        if !self.held().is_empty() {
            return;
        }
        if let Some(handle) = self.poll.lock().unwrap_or_else(|e| e.into_inner()).take() {
            handle.abort();
        }
    }

    /// One pass over every tracked PR: fetch its activity, classify what changed, type
    /// the fixes into the driving agent, and raise the decisions that are not its to
    /// make.
    ///
    /// The fetches run concurrently, so a pass is one round of parallel `gh` spawns
    /// rather than N sequential ones; the results are applied one at a time, in the
    /// order they came back, because each apply mutates the watch list.
    pub async fn poll_once(self: &Arc<Self>) {
        let to_poll: Vec<TrackedPr> = self.held().values().cloned().collect();
        if to_poll.is_empty() {
            return;
        }
        let mut fetches = Vec::new();
        for entry in to_poll {
            fetches.push(tokio::spawn(async move {
                let activity = gh::pr_activity(&entry.cwd, entry.number).await;
                let viewer = gh::viewer_login(&entry.cwd).await;
                let nwo = match entry.repo_nwo {
                    Some(_) => None,
                    None => gh::repo_nwo(&entry.cwd).await,
                };
                (entry.id, activity, viewer, nwo)
            }));
        }
        for fetch in fetches {
            let Ok((key, activity, viewer, nwo)) = fetch.await else {
                continue;
            };
            let Some(activity) = activity else {
                // `gh` missing, unauthenticated, offline, rate-limited: this pass knows
                // nothing about that PR, so it changes nothing about it.
                debug!(tracked = %key, "no activity this pass");
                continue;
            };
            self.apply(&key, activity, &viewer, nwo).await;
        }
        // Rule 2: published unconditionally, and silent on the wire unless the list a
        // connection would send actually moved.
        self.publish_list();
    }

    /// Apply one PR's freshly-fetched activity.
    async fn apply(
        self: &Arc<Self>,
        key: &str,
        activity: PrActivity,
        viewer_login: &str,
        repo_nwo: Option<String>,
    ) {
        // The entry may have been untracked while the fetch was in flight.
        let Some(mut entry) = self.held().get(key).cloned() else {
            return;
        };
        if entry.repo_nwo.is_none() {
            entry.repo_nwo = repo_nwo;
        }
        let number = entry.number;
        let result = classify_pr_activity(&entry.baseline, &activity, viewer_login);
        entry.baseline = result.baseline;
        entry.last_polled_at = Some(now_ms());

        // Terminal: the PR merged or closed. Ping subscribers once, so a client can
        // toast it, then drop the watch. The session is left alone.
        if let Some(reason) = result.events.iter().find_map(|e| match e {
            TrackEvent::Closed(reason) => Some(reason.clone()),
            _ => None,
        }) {
            self.publish_notification(key, TrackNotification::now(number, reason));
            self.untrack(key);
            return;
        }

        let mut fix_reasons = Vec::new();
        let mut raised = Vec::new();
        for event in result.events {
            match event {
                TrackEvent::AutoFix(reason) => fix_reasons.push(reason),
                TrackEvent::NeedsDecision(reason) => {
                    raised.push(TrackNotification::now(number, reason))
                }
                TrackEvent::Closed(_) => {}
            }
        }
        entry.notifications.extend(raised.iter().cloned());

        // Red CI must always have a live agent on it. The classifier is edge-triggered,
        // so a session that died while CI was already failing would otherwise leave the
        // PR red and unattended forever: every later pass sees failing → failing and
        // finds nothing to do.
        let session_live = entry
            .session_id
            .as_deref()
            .is_some_and(|id| self.sessions.is_running(id));
        if let Some(stalled) =
            stalled_ci_fix_reason(entry.baseline.checks, session_live, !fix_reasons.is_empty())
        {
            fix_reasons.push(stalled);
        }

        // Written back before the delivery below, which awaits a whole boot window in
        // the revive case: the row a client reads must not wait on a paste.
        self.held().insert(key.to_string(), entry.clone());
        self.persist(&entry);
        for notification in raised {
            self.publish_notification(key, notification);
        }
        if fix_reasons.is_empty() {
            return;
        }
        let prompt = auto_fix_prompt(number, &entry.branch, &fix_reasons);
        if let Some(offline) = self.hand_over(&entry, &prompt, session_live).await {
            self.raise(key, number, offline);
        }
    }

    /// Type the fix prompt into the PR's agent, reviving it first when its pty is gone.
    /// `Some(reason)` when the work could not be handed over at all.
    async fn hand_over(&self, entry: &TrackedPr, prompt: &str, live: bool) -> Option<String> {
        let Some(session) = entry.session_id.clone() else {
            return Some("Auto-fix needed, but this PR has no session driving it.".into());
        };
        // A live session is mid-conversation and takes the delivery straight in. One
        // that has to come up first has a boot to sit through, exactly like a spawn's
        // seed, which is what the two preconditions are.
        let precondition = if live {
            Precondition::LiveIdle
        } else {
            // `reactivate` respawns the CLI on the conversation the row remembers. The
            // grid it claims is handed straight back: the daemon is not a viewer, and a
            // claim nothing ever releases would leave the pane un-resizable.
            const DAEMON: ClientId = 0;
            let revived = self
                .sessions
                .reactivate(&session, DAEMON, SPAWN_GRID.0, SPAWN_GRID.1);
            self.sessions.release_client(DAEMON);
            if let Err(e) = revived {
                return Some(format!(
                    "Auto-fix needed, but the session working this PR could not be resumed: {e}"
                ));
            }
            Precondition::Booting
        };
        let outcome = deliver_text(
            Arc::clone(&self.sessions),
            &session,
            prompt,
            self.seed_timing,
            precondition,
        )
        .await;
        log_outcome(&session, &outcome);
        outcome
            .reason()
            .map(|why| format!("Auto-fix needed, but the prompt did not reach the agent: {why}"))
    }

    /// Raise a decision on a tracked PR, deduplicated by message.
    ///
    /// Deduplicated because the poll is level-triggered for exactly the cases that reach
    /// here: a session that stays unresumable would otherwise raise the same notification
    /// on every pass, and a list that grows a row a minute is one nobody reads.
    fn raise(&self, key: &str, number: i64, message: String) {
        let (entry, notification) = {
            let mut held = self.held();
            let Some(entry) = held.get_mut(key) else {
                return;
            };
            if entry.notifications.iter().any(|n| n.message == message) {
                return;
            }
            let notification = TrackNotification::now(number, message);
            entry.notifications.push(notification.clone());
            (entry.clone(), notification)
        };
        self.persist(&entry);
        self.publish_notification(key, notification);
        self.publish_list();
    }

    /// The worktree a tracked PR's agent should stand in, or `None` to use the repo
    /// itself. Best-effort on purpose — see the comment in [`Self::track`].
    async fn pr_worktree(&self, req: &TrackRequest) -> Option<BranchWorktree> {
        let cwd = req.cwd.clone();
        let name = format!("pr-{}", req.number);
        let branch = req.branch.clone();
        // Blocking git, and several commands of it (a fetch among them), so it goes on
        // the blocking pool rather than holding a runtime thread for a network round
        // trip.
        match tokio::task::spawn_blocking(move || worktree::create_on_branch(&cwd, &name, &branch))
            .await
        {
            Ok(Ok(made)) => Some(made),
            Ok(Err(e)) => {
                warn!(pr = req.number, "tracking without a worktree: {e}");
                None
            }
            Err(e) => {
                warn!(pr = req.number, "tracking without a worktree: {e}");
                None
            }
        }
    }

    fn set_repo_nwo(&self, key: &str, nwo: String) {
        let entry = {
            let mut held = self.held();
            let Some(entry) = held.get_mut(key) else {
                return;
            };
            if entry.repo_nwo.is_some() {
                return;
            }
            entry.repo_nwo = Some(nwo);
            entry.clone()
        };
        self.persist(&entry);
        // Deliberately no `publish_list`: `repoNwo` is not on the wire, so the list a
        // client would be sent has not moved.
    }

    fn persist(&self, entry: &TrackedPr) {
        if let Err(e) = self.store.upsert_tracked_pr(entry) {
            warn!(tracked = %entry.id, "could not persist the tracked PR: {e:#}");
        }
    }

    fn publish_list(&self) {
        // No subscribers is the daemon's normal resting state, not a failure.
        let _ = self.changes.send(TrackedPrChange::List(self.list()));
    }

    fn publish_notification(&self, tracked_id: &str, notification: TrackNotification) {
        let _ = self.changes.send(TrackedPrChange::Notification {
            tracked_id: tracked_id.to_string(),
            pr_number: notification.pr_number,
            notification,
        });
    }

    fn held(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, TrackedPr>> {
        self.tracked.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use juancoded_core::pr::PrChecks;
    use juancoded_persistence::SqliteStore;

    /// The engine over the test tree's real registry (`/bin/cat` for a provider) and an
    /// in-memory store, with a `gh` that always fails — which is what a machine with no
    /// token, no network and no business reaching GitHub from a unit test has.
    fn engine() -> (Arc<TrackedPrs>, Arc<dyn SessionsApi>) {
        std::env::set_var("JUANCODE_GH_BIN", "/usr/bin/false");
        let sessions = crate::testing::sessions();
        let store: Arc<dyn SessionStore> = Arc::new(SqliteStore::in_memory().expect("a store"));
        (
            TrackedPrs::new(Arc::clone(&sessions), store, Duration::from_secs(3600)),
            sessions,
        )
    }

    fn request(cwd: &str, number: i64) -> TrackRequest {
        TrackRequest {
            cwd: cwd.into(),
            number,
            title: "conformance fixture PR".into(),
            url: format!("https://example.invalid/pr/{number}"),
            branch: "main".into(),
            owner: 1,
        }
    }

    /// A git repo with one commit, so the worktree attempt has something real to refuse
    /// or accept rather than a path that is not a repo at all.
    fn repo(tag: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("juancoded-trackedpr-{tag}-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        let root = dir.join("repo");
        std::fs::create_dir_all(&root).unwrap();
        for args in [
            vec!["init", "--quiet", "--initial-branch=main"],
            vec!["add", "-A"],
        ] {
            std::process::Command::new("git")
                .args(&args)
                .current_dir(&root)
                .output()
                .expect("git");
        }
        std::fs::write(root.join("f.txt"), "base\n").unwrap();
        for args in [
            vec!["add", "f.txt"],
            vec![
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@localhost",
                "commit",
                "--quiet",
                "-m",
                "base",
            ],
        ] {
            std::process::Command::new("git")
                .args(&args)
                .current_dir(&root)
                .output()
                .expect("git");
        }
        root
    }

    /// Tracking spawns the agent that will work the PR, and the list that follows is the
    /// complete set with the new watch in it.
    #[tokio::test]
    async fn tracking_a_pr_spawns_its_driving_session_and_publishes_the_whole_list() {
        let (engine, sessions) = engine();
        let root = repo("spawn");
        let cwd = root.to_string_lossy().to_string();
        let mut changes = engine.subscribe();

        assert!(engine.list().is_empty(), "nothing is watched to begin with");
        let entry = engine
            .track(request(&cwd, 4242))
            .await
            .expect("a watch, with a session behind it");
        let session = entry.session_id.clone().expect("a driving session");
        assert!(
            sessions.meta(&session).is_some(),
            "the session really exists"
        );
        assert_eq!(entry.id, TrackedPr::key(&cwd, 4242));

        let TrackedPrChange::List(list) = changes.try_recv().expect("a list went out") else {
            panic!("the first change is the list");
        };
        assert_eq!(list, vec![entry.clone()]);

        // Already tracked is a no-op, and no-ops publish nothing.
        assert!(engine.track(request(&cwd, 4242)).await.is_none());
        assert!(matches!(
            changes.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));

        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// The clause the whole `expectNone` step of the conformance scenario is about: a
    /// pass that learned nothing leaves the list byte-identical, which is what lets the
    /// connection stay silent. Asserted on the list itself rather than on the absence of
    /// a publish, because the publish is unconditional by design.
    #[tokio::test]
    async fn a_poll_that_found_nothing_leaves_the_list_exactly_as_it_was() {
        let (engine, _sessions) = engine();
        let root = repo("nomove");
        let cwd = root.to_string_lossy().to_string();
        engine.track(request(&cwd, 4242)).await.expect("a watch");
        let before = engine.list();

        engine.poll_once().await;
        assert_eq!(
            engine.list(),
            before,
            "an unreachable gh must not stamp a poll time, a state or a notification"
        );
        assert_eq!(before[0].last_polled_at, None);
        assert_eq!(before[0].baseline.checks, PrChecks::None);
        assert!(!before[0].baseline.baselined);

        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// Untracking publishes the list back, and the untracked id is not in it. The
    /// session stays: it is a conversation, not a side effect of the watch.
    #[tokio::test]
    async fn untracking_publishes_the_list_without_it_and_keeps_the_session() {
        let (engine, sessions) = engine();
        let root = repo("untrack");
        let cwd = root.to_string_lossy().to_string();
        let entry = engine.track(request(&cwd, 4242)).await.expect("a watch");
        let session = entry.session_id.clone().expect("a session");
        let mut changes = engine.subscribe();

        assert!(engine.untrack(&entry.id));
        let TrackedPrChange::List(list) = changes.try_recv().expect("a list went out") else {
            panic!("untracking publishes a list");
        };
        assert!(list.is_empty(), "{list:?}");
        assert!(engine.list().is_empty());
        assert!(
            sessions.meta(&session).is_some(),
            "the agent's conversation outlives the watch"
        );

        // An id that is not tracked changes nothing and says nothing.
        assert!(!engine.untrack(&entry.id));
        assert!(matches!(
            changes.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));

        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// The watch list is the thing that has to survive a restart, along with the two
    /// things a poller adds to it: an open decision, and the baseline that stops the
    /// first poll after a restart replaying old activity as new.
    #[tokio::test]
    async fn the_watch_list_and_its_decisions_survive_a_restart() {
        let sessions = crate::testing::sessions();
        let file = std::env::temp_dir().join(format!(
            "juancoded-trackedpr-restart-{}.db",
            std::process::id()
        ));
        std::fs::remove_file(&file).ok();
        let store: Arc<dyn SessionStore> =
            Arc::new(SqliteStore::open(&file).expect("a store on disk"));

        let root = repo("restart");
        let cwd = root.to_string_lossy().to_string();
        let first = TrackedPrs::new(Arc::clone(&sessions), Arc::clone(&store), POLL_INTERVAL);
        let entry = first.track(request(&cwd, 4242)).await.expect("a watch");
        first.raise(&entry.id, 4242, "@somebody requested changes".into());
        let before = first.list();
        assert_eq!(before[0].notifications.len(), 1);
        drop(first);

        let store: Arc<dyn SessionStore> = Arc::new(SqliteStore::open(&file).expect("reopened"));
        let second = TrackedPrs::new(sessions, store, POLL_INTERVAL);
        assert_eq!(second.list(), before, "the same watch, decision included");

        // And resolving it is what clears it, on the row a client can address.
        let notification_id = before[0].notifications[0].id.clone();
        assert!(second.resolve_notification(&entry.id, &notification_id));
        assert!(second.list()[0].notifications.is_empty());
        assert!(
            !second.resolve_notification(&entry.id, &notification_id),
            "a decision already dealt with is not dealt with twice"
        );

        std::fs::remove_file(&file).ok();
        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// The dedup on the escalation path. A session that stays unresumable is asked about
    /// on every pass, so without this the watch grows one identical decision a minute.
    #[tokio::test]
    async fn the_same_decision_is_not_raised_twice() {
        let (engine, _sessions) = engine();
        let root = repo("dedup");
        let cwd = root.to_string_lossy().to_string();
        let entry = engine.track(request(&cwd, 4242)).await.expect("a watch");

        engine.raise(&entry.id, 4242, "the session is gone".into());
        engine.raise(&entry.id, 4242, "the session is gone".into());
        assert_eq!(engine.list()[0].notifications.len(), 1);
        engine.raise(&entry.id, 4242, "and CI went red".into());
        assert_eq!(engine.list()[0].notifications.len(), 2);
        assert_eq!(
            engine.list()[0].state(),
            juancoded_core::pr::TrackState::NeedsDecision,
            "an open decision is what the badge is for"
        );

        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }
}
