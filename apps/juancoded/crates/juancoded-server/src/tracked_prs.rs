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
//! The webhook ingest IS ported, though the daemon still serves no HTTP: the trigger
//! reaches it as a wire frame instead (`prWebhook`), translated from the desktop's
//! `/api/pr-webhook` by the relay that already fronts this core for the sidecar. Without
//! it the poll was the only update path and a review comment took up to a minute to
//! land (juancode-rnx6). The poll interval below is deliberately NOT demoted to the
//! Swift core's webhook-assisted 300s: the secret that says whether webhooks are
//! actually configured lives in the sidecar's process, not this one, and a poll slowed
//! on an assumption that turns out false is a watch that updates every five minutes.
//!
//! The respawn ladder
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

use juancoded_cordis::bus::Bus;
use juancoded_cordis::events::{PrNotify, PrNotifyCandidate, PrNotifyKind, PrNotifyPass};
use juancoded_core::gh;
use juancoded_core::model::{now_ms, ProviderId};
use juancoded_core::pr::{
    auto_fix_prompt, classify_pr_activity, repo_slug_from_pr_url, stalled_ci_fix_reason,
    track_seed_prompt, BranchWorktree, PrActivity, TrackEvent, TrackNotification, TrackedPr,
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

/// How long a webhook-triggered refresh waits before it runs. One push fires several
/// GitHub events within moments — a `push`, a `check_suite`, a `check_run` per job — and
/// each costing its own round of `gh` spawns is how a busy PR turns into a fork storm.
/// The burst coalesces into one refresh per PR. Matches the Swift engine's
/// `webhookDebounce`.
pub const WEBHOOK_DEBOUNCE: Duration = Duration::from_secs(2);

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
    /// Adopt the watch into this session instead of spawning one for it. `None` is the
    /// spawning track; `Some` is the session the user is already sitting in, which is
    /// typically the one whose branch opened the PR.
    pub adopt_session_id: Option<String>,
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
    /// Debounce timers for webhook-triggered refreshes, keyed by [`TrackedPr::key`].
    /// An entry here means "a refresh for this PR is already coming", which is what
    /// makes a burst of events one refresh.
    pending_refresh: Mutex<BTreeMap<String, JoinHandle<()>>>,
    webhook_debounce: Duration,
    seed_timing: SeedTiming,
    /// The bus the notification rules hang off (juancode-2vlz). Every candidate a pass
    /// produces goes through `pr.notify` before anybody is told, and with no listener
    /// mounted the terminal returns all of them — which is exactly the behaviour this
    /// engine had before the rules existed.
    bus: Bus,
}

impl TrackedPrs {
    /// Open the engine over a store, restoring whatever was being watched before the
    /// last restart. The loop is not started here — [`Self::start_if_tracking`] does
    /// that, from the same place the daemon's other pumps are started.
    pub fn new(
        sessions: Arc<dyn SessionsApi>,
        store: Arc<dyn SessionStore>,
        poll_interval: Duration,
        bus: Bus,
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
            pending_refresh: Mutex::new(BTreeMap::new()),
            webhook_debounce: WEBHOOK_DEBOUNCE,
            seed_timing: SeedTiming::default(),
            bus,
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
    ///
    /// A request carrying `adopt_session_id` is [`Self::adopt`] instead: no worktree and
    /// no spawn, the watch goes into a session that already exists.
    pub async fn track(self: &Arc<Self>, req: TrackRequest) -> Option<TrackedPr> {
        let key = TrackedPr::key(&req.cwd, req.number);
        if self.held().contains_key(&key) {
            return None;
        }
        if req.adopt_session_id.is_some() {
            return self.adopt(req, key).await;
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
            worktree_name: None,
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
            me.deliver(&session, &seed, false).await;
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

    /// Track a PR in a session that already exists — the "Track PR in this session"
    /// path, where the user is sitting in the conversation whose branch opened the PR.
    ///
    /// No worktree and no spawn: the session is already standing on the branch, and a
    /// second agent cut onto a tree of its own would be a rival committing to the same
    /// branch. All this does is hand that session the watch contract; from there it is
    /// an ordinary tracked PR, and the poll loop types fixes into it and escalates
    /// decisions out of it exactly as it would for a spawned tracker.
    ///
    /// `None` — so no list is published and the asking client's track times out into
    /// its own error — when the session is one this core does not hold, when it cannot
    /// be brought back up, or when it already drives another tracked PR. That last one
    /// is the rule the poll loop depends on: one session, one watch contract, or two
    /// PRs' fix prompts interleave in one conversation.
    async fn adopt(self: &Arc<Self>, req: TrackRequest, key: String) -> Option<TrackedPr> {
        let session = req.adopt_session_id.clone()?;
        if self
            .held()
            .values()
            .any(|e| e.session_id.as_deref() == Some(session.as_str()))
        {
            warn!(pr = req.number, session = %session,
                  "that session already drives a tracked PR");
            return None;
        }
        if self.sessions.meta(&session).is_none() {
            warn!(pr = req.number, session = %session, "no such session to track this PR in");
            return None;
        }
        // Asleep, or offline after a restart, is fine: the same revive the poll loop
        // uses brings it back. Only a session that cannot come up at all fails the
        // adoption, and it fails it BEFORE the list is published — a watch whose
        // session never came back is a row with nobody behind it.
        let live = self.sessions.is_running(&session);
        if !live {
            if let Err(e) = self.revive(&session) {
                warn!(pr = req.number, session = %session,
                      "the session to track this PR in could not be resumed: {e}");
                return None;
            }
        }

        // No worktree argument: the seed's worktree paragraph tells the agent where the
        // tree it was given is, and this session was not given one.
        let seed = track_seed_prompt(req.number, &req.title, &req.branch, &req.url, None);
        let entry = TrackedPr {
            id: key.clone(),
            number: req.number,
            title: req.title,
            url: req.url,
            branch: req.branch,
            cwd: req.cwd.clone(),
            session_id: Some(session.clone()),
            repo_nwo: None,
            baseline: Default::default(),
            notifications: Vec::new(),
            last_polled_at: None,
            created_at: now_ms(),
        };
        self.held().insert(key.clone(), entry.clone());
        self.persist(&entry);
        self.publish_list();
        info!(pr = entry.number, session = %session, revived = !live,
              "tracking a pull request in a session that already exists");

        // Behind the list, like a spawn's seed: a client must not wait on a paste to
        // learn the PR is being watched.
        let me = Arc::clone(self);
        tokio::spawn(async move {
            if let Some(why) = me.deliver(&session, &seed, live).await {
                warn!(session = %session, "the watch contract did not reach the agent: {why}");
            }
        });

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
        // A refresh already scheduled for it would spend `gh` spawns on a watch that no
        // longer exists, and `apply` would find no row to write to anyway.
        if let Some(pending) = self.pending().remove(tracked_id) {
            pending.abort();
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

    /// A webhook said something happened to `number` in `nwo`: refresh every watch it
    /// matches, and answer how many that was.
    ///
    /// The event is a TRIGGER, never a payload. Nothing in it is stored and nothing in
    /// it is believed — the refresh re-reads the PR through `gh` on the same
    /// classify-inject-notify path a poll uses, so a forged or stale event can only
    /// cost a fetch. That is also why this needs no auth of its own: the sidecar
    /// verifies GitHub's HMAC before anything reaches the wire, and the worst a frame
    /// that got past it can do is ask this core to look at GitHub sooner.
    ///
    /// Zero matches is the ordinary answer, not an error: a webhook fires for every PR
    /// in a repo and this core watches a handful.
    pub fn ingest_webhook(self: &Arc<Self>, nwo: &str, number: i64) -> usize {
        let matched = self.find_by_repo_number(nwo, number);
        for key in &matched {
            self.schedule_refresh(key.clone());
        }
        if !matched.is_empty() {
            info!(
                repo = nwo,
                pr = number,
                watches = matched.len(),
                "a webhook moved a tracked pull request"
            );
        }
        matched.len()
    }

    /// The keys of every watch a webhook's repo + number names.
    ///
    /// `repo_nwo` is compared case-insensitively, because GitHub slugs are. A watch
    /// whose identity has not resolved yet falls back to the owner/name in its own PR
    /// url: the resolve is a `gh` round trip fired off the track path, so the first
    /// minute of every watch would otherwise match nothing at all.
    fn find_by_repo_number(&self, nwo: &str, number: i64) -> Vec<String> {
        let want = nwo.trim().to_lowercase();
        self.held()
            .values()
            .filter(|e| e.number == number)
            .filter(|e| match &e.repo_nwo {
                Some(stored) => stored.to_lowercase() == want,
                None => repo_slug_from_pr_url(&e.url).is_some_and(|slug| slug == want),
            })
            .map(|e| e.id.clone())
            .collect()
    }

    /// Queue one PR's refresh, folding an event into the refresh already coming for it.
    fn schedule_refresh(self: &Arc<Self>, key: String) {
        let mut pending = self.pending();
        if pending.get(&key).is_some_and(|h| !h.is_finished()) {
            return;
        }
        let me = Arc::clone(self);
        let delay = self.webhook_debounce;
        let id = key.clone();
        pending.insert(
            key,
            tokio::spawn(async move {
                tokio::time::sleep(delay).await;
                // Cleared before the work, not after: a second burst arriving while the
                // fetch is in flight is about activity this refresh may already have
                // read past, and it deserves a refresh of its own.
                me.pending().remove(&id);
                me.refresh_one(&id).await;
            }),
        );
    }

    /// One PR's fetch-classify-apply, the poll's inner pass for a single watch.
    async fn refresh_one(self: &Arc<Self>, key: &str) {
        let Some(entry) = self.held().get(key).cloned() else {
            return;
        };
        let activity = gh::pr_activity(&entry.cwd, entry.number).await;
        let viewer = gh::viewer_login(&entry.cwd).await;
        let nwo = match entry.repo_nwo {
            Some(_) => None,
            None => gh::repo_nwo(&entry.cwd).await,
        };
        let Some(activity) = activity else {
            // `gh` missing, unauthenticated, offline, rate-limited: this refresh knows
            // nothing, so it changes nothing. The poll is still behind it.
            debug!(tracked = %key, "no activity on the webhook refresh");
            return;
        };
        self.apply(key, activity, &viewer, nwo).await;
        // Rule 2 again: published unconditionally, silent on the wire unless the list a
        // connection would send actually moved.
        self.publish_list();
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
            // Through the rules like everything else, so a merge of somebody else's PR
            // is as quiet as its reviews were — but the watch is dropped either way: the
            // filter decides who hears about it, never whether it happened.
            for surviving in self.notifiable(
                &entry,
                viewer_login,
                &activity.author,
                vec![PrNotifyCandidate {
                    kind: PrNotifyKind::Closed,
                    message: reason,
                    actor: String::new(),
                    review_id: None,
                }],
            ) {
                self.publish_notification(key, TrackNotification::now(number, surviving.message));
            }
            self.untrack(key);
            return;
        }

        let mut fix_reasons = Vec::new();
        let mut candidates = Vec::new();
        for event in result.events {
            match event {
                TrackEvent::AutoFix(reason) => fix_reasons.push(reason),
                // Only a decision is a notification. An auto-fix is work handed to the
                // agent, and the rules are about what reaches a person.
                TrackEvent::NeedsDecision(reason) => candidates.push(PrNotifyCandidate {
                    kind: PrNotifyKind::Review,
                    actor: actor_of(&reason),
                    message: reason,
                    review_id: None,
                }),
                TrackEvent::Closed(_) => {}
            }
        }
        let raised: Vec<TrackNotification> = self
            .notifiable(&entry, viewer_login, &activity.author, candidates)
            .into_iter()
            .map(|c| TrackNotification::now(number, c.message))
            .collect();
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

    /// Run one pass's candidates through the `pr.notify` rules and hand back what
    /// survived.
    ///
    /// The terminal returns every candidate, so a tree that mounted no filter behaves
    /// exactly as this engine did before the rules existed — which is what makes the
    /// row in the tree genuinely removable rather than load-bearing.
    ///
    /// `notes` are logged rather than dropped: a notification that never arrived is the
    /// hardest kind of bug to report, and the sentence explaining it is written right
    /// here and nowhere else.
    fn notifiable(
        &self,
        entry: &TrackedPr,
        viewer_login: &str,
        author: &str,
        candidates: Vec<PrNotifyCandidate>,
    ) -> Vec<PrNotifyCandidate> {
        if candidates.is_empty() {
            return candidates;
        }
        let mut pass = PrNotifyPass {
            tracked_id: entry.id.clone(),
            pr_number: entry.number,
            viewer: viewer_login.to_lowercase(),
            author: author.to_lowercase(),
            already_open: entry
                .notifications
                .iter()
                .map(|n| n.message.clone())
                .collect(),
            candidates,
            notes: Vec::new(),
        };
        let kept = self
            .bus
            .waterfall::<PrNotify>(&mut pass, |p| std::mem::take(&mut p.candidates));
        for note in &pass.notes {
            debug!("{note}");
        }
        kept
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
        if !live {
            if let Err(e) = self.revive(&session) {
                return Some(format!(
                    "Auto-fix needed, but the session working this PR could not be resumed: {e}"
                ));
            }
        }
        self.deliver(&session, prompt, live)
            .await
            .map(|why| format!("Auto-fix needed, but the prompt did not reach the agent: {why}"))
    }

    /// Bring a session's pty back on the conversation its row remembers.
    ///
    /// The grid claim is handed straight back: the daemon is not a viewer, and a claim
    /// nothing ever releases would leave the pane un-resizable.
    fn revive(&self, session: &str) -> Result<(), String> {
        const DAEMON: ClientId = 0;
        let revived = self
            .sessions
            .reactivate(session, DAEMON, SPAWN_GRID.0, SPAWN_GRID.1);
        self.sessions.release_client(DAEMON);
        revived.map(|_| ()).map_err(|e| e.to_string())
    }

    /// Paste `text` into a session and submit it. `Some(reason)` when nothing reached
    /// the agent.
    ///
    /// `live` is about the session's state BEFORE any revive: a session that was up all
    /// along is between turns and takes the paste straight in, and one that had to be
    /// brought back has a CLI boot to sit through, exactly like a spawn's seed.
    async fn deliver(&self, session: &str, text: &str, live: bool) -> Option<String> {
        let precondition = if live {
            Precondition::LiveIdle
        } else {
            Precondition::Booting
        };
        let outcome = deliver_text(
            Arc::clone(&self.sessions),
            session,
            text,
            self.seed_timing,
            precondition,
        )
        .await;
        log_outcome(session, &outcome);
        outcome.reason().map(str::to_string)
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

    fn pending(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, JoinHandle<()>>> {
        self.pending_refresh
            .lock()
            .unwrap_or_else(|e| e.into_inner())
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

/// The handle a classifier sentence names, lower-cased, or empty when it names nobody.
///
/// `classify_pr_activity` writes its reasons as prose ("@hubber requested changes"),
/// which is the right shape for a client to render and the wrong shape for a rule to
/// read. Lifting the `@handle` back out is a small dishonesty about where the structure
/// lives, and it is here rather than in the classifier because the classifier's output
/// is a sentence by design: two cores render it, and a structured event would have to
/// be rendered identically by both.
fn actor_of(reason: &str) -> String {
    reason
        .split_whitespace()
        .find_map(|word| word.strip_prefix('@'))
        .map(|handle| {
            handle
                .trim_end_matches(|c: char| !c.is_alphanumeric() && c != '-')
                .to_lowercase()
        })
        .unwrap_or_default()
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
            TrackedPrs::new(
                Arc::clone(&sessions),
                store,
                Duration::from_secs(3600),
                Bus::new(),
            ),
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
            adopt_session_id: None,
            owner: 1,
        }
    }

    /// The same request, asking for the watch to go into a session that already exists.
    fn adopting(cwd: &str, number: i64, session: &str) -> TrackRequest {
        TrackRequest {
            adopt_session_id: Some(session.into()),
            ..request(cwd, number)
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

    /// The "Track PR in This Session" path: the watch goes into the session the user is
    /// already sitting in, and nothing else is spawned or cut. Both halves matter — a
    /// second agent on a tree of its own would be a rival committing to the same branch,
    /// which is the whole reason this path is not the spawning one (juancode-jlhz).
    #[tokio::test]
    async fn adopting_puts_the_watch_in_a_session_that_already_exists() {
        let (engine, sessions) = engine();
        let root = repo("adopt");
        let cwd = root.to_string_lossy().to_string();
        let mine = sessions
            .create(CreateRequest {
                provider: ProviderId::Claude,
                cwd: cwd.clone(),
                cols: 80,
                rows: 24,
                skip_permissions: false,
                model: None,
                preset: None,
                isolate_worktree: false,
                worktree_name: None,
                dispatch_id: None,
                owner: 1,
            })
            .expect("a session to adopt into");
        let before = sessions.ids().len();
        let mut changes = engine.subscribe();

        let entry = engine
            .track(adopting(&cwd, 4242, &mine.id))
            .await
            .expect("a watch in the session that asked for it");
        assert_eq!(entry.session_id.as_deref(), Some(mine.id.as_str()));
        assert_eq!(
            sessions.ids().len(),
            before,
            "adopting spawns nothing: the session the user is in is the tracker"
        );
        assert_eq!(
            sessions.meta(&mine.id).map(|m| m.cwd),
            Some(cwd.clone()),
            "and it is not moved onto a worktree of its own"
        );

        let TrackedPrChange::List(list) = changes.try_recv().expect("a list went out") else {
            panic!("the first change is the list");
        };
        assert_eq!(list, vec![entry]);

        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// One session, one watch contract. Two would interleave two PRs' fix prompts in one
    /// conversation, so the second adoption is refused — and refused silently, because a
    /// list that did not change carries no information.
    #[tokio::test]
    async fn one_session_cannot_drive_two_tracked_prs() {
        let (engine, sessions) = engine();
        let root = repo("adopt-twice");
        let cwd = root.to_string_lossy().to_string();
        let mine = sessions
            .create(CreateRequest {
                provider: ProviderId::Claude,
                cwd: cwd.clone(),
                cols: 80,
                rows: 24,
                skip_permissions: false,
                model: None,
                preset: None,
                isolate_worktree: false,
                worktree_name: None,
                dispatch_id: None,
                owner: 1,
            })
            .expect("a session to adopt into");
        engine
            .track(adopting(&cwd, 4242, &mine.id))
            .await
            .expect("the first watch");
        let mut changes = engine.subscribe();

        assert!(engine.track(adopting(&cwd, 4343, &mine.id)).await.is_none());
        assert_eq!(engine.list().len(), 1);
        assert!(matches!(
            changes.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));

        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// A session id this core does not hold is refused rather than quietly turned into
    /// the spawning track. The client asked for the watch to go into one conversation;
    /// a spawn would be a different agent on a different tree, which is the failure the
    /// Swift client refused to invent on its own.
    #[tokio::test]
    async fn adopting_into_a_session_this_core_does_not_hold_is_refused() {
        let (engine, sessions) = engine();
        let root = repo("adopt-ghost");
        let cwd = root.to_string_lossy().to_string();
        let before = sessions.ids().len();

        assert!(engine
            .track(adopting(&cwd, 4242, "no-such-session"))
            .await
            .is_none());
        assert!(engine.list().is_empty());
        assert_eq!(sessions.ids().len(), before, "and nothing was spawned");

        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// A webhook names a repo and a number; what it has to find is the WATCH, and the
    /// two ways a watch knows its repo both have to answer. `repo_nwo` is the resolved
    /// one and is compared case-insensitively; the PR url is the fallback that covers
    /// the first minute of every watch, before the `gh` round trip off the track path
    /// has come back (juancode-rnx6).
    #[tokio::test]
    async fn a_webhook_finds_a_watch_by_its_repo_and_number() {
        let (engine, _sessions) = engine();
        let root = repo("webhook-match");
        let cwd = root.to_string_lossy().to_string();
        let mut req = request(&cwd, 4242);
        req.url = "https://github.com/PanchoBubble/juancode/pull/4242".into();
        let entry = engine.track(req).await.expect("a watch");

        // Nothing has resolved `repo_nwo` yet: the url is what answers.
        assert_eq!(engine.ingest_webhook("PanchoBubble/juancode", 4242), 1);
        assert_eq!(
            engine.ingest_webhook("panchobubble/JUANCODE", 4242),
            1,
            "GitHub slugs are case-insensitive and so is this"
        );
        assert_eq!(
            engine.ingest_webhook("PanchoBubble/juancode", 99),
            0,
            "another PR in the same repo is not this watch"
        );
        assert_eq!(
            engine.ingest_webhook("someone/else", 4242),
            0,
            "the same number in another repo is not this watch either"
        );

        // And once it has resolved, the stored identity is what answers — including for
        // a watch whose url says nothing (a PR tracked from a url this core cannot read).
        engine.set_repo_nwo(&entry.id, "PanchoBubble/juancode".into());
        assert_eq!(engine.ingest_webhook("PanchoBubble/juancode", 4242), 1);

        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// One push fires a `push`, a `check_suite` and a `check_run` per job within
    /// moments. Each one costing its own round of `gh` spawns is how a busy PR turns
    /// into a fork storm, so the burst has to coalesce into one pending refresh.
    #[tokio::test]
    async fn a_burst_of_webhooks_coalesces_into_one_pending_refresh() {
        let (engine, _sessions) = engine();
        let root = repo("webhook-burst");
        let cwd = root.to_string_lossy().to_string();
        let mut req = request(&cwd, 4242);
        req.url = "https://github.com/PanchoBubble/juancode/pull/4242".into();
        let entry = engine.track(req).await.expect("a watch");

        for _ in 0..5 {
            assert_eq!(engine.ingest_webhook("PanchoBubble/juancode", 4242), 1);
        }
        assert_eq!(engine.pending().len(), 1, "five events, one refresh");

        // And untracking cancels it: a refresh for a watch that no longer exists would
        // spend the `gh` spawns and have no row to write to.
        assert!(engine.untrack(&entry.id));
        assert!(engine.pending().is_empty());

        std::fs::remove_dir_all(root.parent().unwrap()).ok();
    }

    /// The whole point of the fast path: an event does not wait for the poll. With `gh`
    /// pointed at /usr/bin/false the refresh learns nothing and so changes nothing —
    /// what is asserted is that it RAN, off the debounce and without a poll pass.
    #[tokio::test]
    async fn a_webhook_refresh_runs_without_waiting_for_a_poll() {
        let (engine, _sessions) = engine();
        let root = repo("webhook-refresh");
        let cwd = root.to_string_lossy().to_string();
        let mut req = request(&cwd, 4242);
        req.url = "https://github.com/PanchoBubble/juancode/pull/4242".into();
        engine.track(req).await.expect("a watch");

        assert_eq!(engine.ingest_webhook("PanchoBubble/juancode", 4242), 1);
        assert_eq!(engine.pending().len(), 1);
        // The poll interval this engine was built with is an hour, so anything that
        // happens here happened because of the webhook.
        for _ in 0..100 {
            if engine.pending().is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(
            engine.pending().is_empty(),
            "the debounced refresh never ran"
        );

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
        let first = TrackedPrs::new(
            Arc::clone(&sessions),
            Arc::clone(&store),
            POLL_INTERVAL,
            Bus::new(),
        );
        let entry = first.track(request(&cwd, 4242)).await.expect("a watch");
        first.raise(&entry.id, 4242, "@somebody requested changes".into());
        let before = first.list();
        assert_eq!(before[0].notifications.len(), 1);
        drop(first);

        let store: Arc<dyn SessionStore> = Arc::new(SqliteStore::open(&file).expect("reopened"));
        let second = TrackedPrs::new(sessions, store, POLL_INTERVAL, Bus::new());
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

/// The notification rules, from this side of the seam (juancode-2vlz). The rules
/// themselves are tested in the plugin; what is tested here is that the poller actually
/// asks, and that a tree without the plugin is the poller this engine has always been.
#[cfg(test)]
mod notify_filter_tests {
    use super::*;
    use juancoded_cordis::plugins::PrNotifyFilter;
    use juancoded_cordis::{Entry, EntryList};
    use juancoded_persistence::SqliteStore;
    use std::sync::Arc;

    fn engine_on(bus: Bus) -> Arc<TrackedPrs> {
        std::env::set_var("JUANCODE_GH_BIN", "/usr/bin/false");
        let store: Arc<dyn SessionStore> = Arc::new(SqliteStore::in_memory().expect("a store"));
        TrackedPrs::new(
            crate::testing::sessions(),
            store,
            Duration::from_secs(3600),
            bus,
        )
    }

    fn filtered_bus() -> Bus {
        let mut loader = juancoded_cordis::Loader::new();
        loader.register(Arc::new(PrNotifyFilter));
        let entries = EntryList::new().push(Entry::new("pr-notify-filter", "pr-notify-filter"));
        loader.apply(&entries).expect("the filter mounts");
        let bus = loader.bus().clone();
        // The loader owns the effect scope, so it has to outlive the bus it registered
        // into: leaking it here is what keeps the listener mounted for the assertion.
        std::mem::forget(loader);
        bus
    }

    fn watch(notifications: Vec<TrackNotification>) -> TrackedPr {
        TrackedPr {
            id: "/tmp#7".into(),
            number: 7,
            title: "t".into(),
            url: "https://github.com/o/r/pull/7".into(),
            branch: "b".into(),
            cwd: "/tmp".into(),
            session_id: None,
            baseline: Default::default(),
            notifications,
            created_at: 0,
            last_polled_at: None,
            repo_nwo: None,
        }
    }

    fn candidate(message: &str) -> PrNotifyCandidate {
        PrNotifyCandidate {
            kind: PrNotifyKind::Review,
            actor: actor_of(message),
            message: message.into(),
            review_id: None,
        }
    }

    /// The load-bearing property of making this a row in the tree: with nothing mounted,
    /// every candidate survives, which is the poller as it was before any of this.
    #[test]
    fn a_tree_with_no_filter_notifies_exactly_what_it_always_did() {
        let engine = engine_on(Bus::new());
        let kept = engine.notifiable(
            &watch(Vec::new()),
            "octocat",
            "hubber",
            vec![
                candidate("@a requested changes"),
                candidate("@b requested changes"),
            ],
        );
        assert_eq!(kept.len(), 2);
    }

    #[test]
    fn with_the_filter_mounted_somebody_elses_pr_goes_quiet() {
        let engine = engine_on(filtered_bus());
        let theirs = engine.notifiable(
            &watch(Vec::new()),
            "octocat",
            "hubber",
            vec![candidate("@a requested changes")],
        );
        assert!(theirs.is_empty(), "rule 1: not the viewer's PR");

        let mine = engine.notifiable(
            &watch(Vec::new()),
            "octocat",
            "OctoCat",
            vec![
                candidate("@a requested changes"),
                candidate("@b requested changes"),
            ],
        );
        assert_eq!(
            mine.iter().map(|c| c.message.as_str()).collect::<Vec<_>>(),
            vec!["@b requested changes"],
            "rule 2: one pass, one reviewer's last word — and the author match is \
             case-insensitive, because GitHub is"
        );

        let repeat = engine.notifiable(
            &watch(vec![TrackNotification::now(7, "@b requested changes")]),
            "octocat",
            "octocat",
            vec![candidate("@b requested changes")],
        );
        assert!(repeat.is_empty(), "rule 3: already open");
    }

    /// A pass with nothing in it must not reach the bus at all: the rules would have
    /// nothing to decide, and the empty answer is already known.
    #[test]
    fn an_empty_pass_is_answered_without_asking_anybody() {
        let engine = engine_on(filtered_bus());
        assert!(engine
            .notifiable(&watch(Vec::new()), "octocat", "octocat", Vec::new())
            .is_empty());
    }

    /// The classifier writes prose and the rules read handles, so this is the one place
    /// the two shapes meet.
    #[test]
    fn a_handle_comes_back_out_of_the_sentence_it_was_written_into() {
        assert_eq!(actor_of("@hubber requested changes"), "hubber");
        assert_eq!(actor_of("New review from @Octo-Cat"), "octo-cat");
        assert_eq!(actor_of("2 new comments from @a and @b"), "a");
        assert_eq!(actor_of("CI went red"), "");
        assert_eq!(actor_of(""), "");
    }
}
