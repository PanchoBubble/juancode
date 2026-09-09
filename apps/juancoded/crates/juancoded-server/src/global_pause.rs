//! Global pause: sleep every live agent at once, and play back exactly that set.
//!
//! The daemon-side half of the frames PR #31 gave the desktop. Those frames were
//! answered by the Swift `CoreProxyServer` sitting in front of this daemon, so a pause
//! worked only while the app was the endpoint — and the surface that wants it most is
//! the one with no app in the loop: the reason to pause everything is that you are
//! walking away from the Mac, and a headless `juancoded` is exactly what a phone is
//! talking to then (juancode-uchf).
//!
//! Pause reuses the per-session sleep path ([`SessionsApi::sleep`], the frame the first
//! half of juancode-nizo added), so the ~300MB a live CLI holds is actually returned —
//! that is the point of the button, not a flag flip. Play is a real `--resume` per
//! session, spread over bounded lanes for the same reason the pause was taken.
//!
//! ## What the set does not contain
//!
//! [`GlobalPause::targets`] filters on **liveness**, never on the dormant flag, and
//! both exclusions that falls out of are load-bearing:
//!
//!   * A session that exited on its own before the pause is not in the set, so a play
//!     does not resurrect it. It is the same refusal `sleepSession` makes for a session
//!     with no live pty and for the same reason — a crashed row woken by a global play
//!     is indistinguishable from one somebody paused.
//!   * A session already asleep when the pause lands is excluded by that identical
//!     rule, so it stays the user's own sleep rather than becoming this pause's to wake.
//!
//! ## Why a set at all
//!
//! `dormant` is a strict superset of the paused set: the idle reaper, the live-session
//! cap, a shutdown and a per-session `sleepSession` all set it too, and the daemon does
//! not persist which one did. A play driven off `dormant` would wake sessions somebody
//! slept themselves weeks ago. Narrowing it back into a query over a persisted sleep
//! reason is juancode-7dc5; until then the pause keeps its own record.

use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::broadcast;
use tracing::{debug, info, warn};

use juancoded_core::model::SessionKind;
use juancoded_persistence::SessionStore;
use juancoded_state::{ClientId, SessionsApi};

/// How many revivals run at once. Each one is a real CLI process, so this is what
/// bounds the RAM and pty burst of a play after a big pause — the same bound, and the
/// same number, the Swift core applies (`GlobalResume.lanes`).
const LANES: usize = 4;

/// The gap between two revivals within one lane. `fork`+`exec` costs a quarter of a
/// second on a quiet Mac here and multiples of that under load, so a play with no gap
/// is four spawn storms rather than four lanes.
const LANE_GAP: Duration = Duration::from_millis(150);

/// The grid a revived session is respawned at when nothing remembers its own. Matches
/// the wire layer's `DEFAULT_GRID`: whatever the CLI prints in its first turn is
/// wrapped at the spawn width forever, so a nominal 80x24 would leave a permanently
/// narrow transcript that resizing the pane cannot widen.
const DEFAULT_GRID: (u16, u16) = (120, 40);

/// The grid claim a revival takes and hands straight back. The daemon is not a viewer,
/// and a claim nothing ever releases would leave the pane un-resizable. Connection ids
/// start at 1, so this collides with nobody.
const DAEMON: ClientId = 0;

/// How many changes a slow subscriber may fall behind before it starts losing them. A
/// lost state is survivable by construction: the next one is the whole set again, which
/// is the other reason there are no deltas.
const CHANGE_BUFFER: usize = 16;

/// The paused set, its persistence, and its change fan-out.
///
/// One per daemon, not one per connection — the whole point of the frames is that a
/// pause taken from the phone is the set the desktop plays, so every connection reads
/// and writes this one object.
pub struct GlobalPause {
    sessions: Arc<dyn SessionsApi>,
    /// `None` when the tree mounted no store. The frames still work; the set just does
    /// not survive a restart, which is worth saying out loud rather than refusing over.
    store: Option<Arc<dyn SessionStore>>,
    changes: broadcast::Sender<Vec<String>>,
    /// A `std::sync::Mutex`, never held across an `await`: every method reads a clone
    /// out, computes, and writes back.
    paused: Mutex<BTreeSet<String>>,
}

impl GlobalPause {
    /// Open the book over a store, restoring whatever pause was in effect before the
    /// last restart.
    pub fn new(sessions: Arc<dyn SessionsApi>, store: Option<Arc<dyn SessionStore>>) -> Arc<Self> {
        let restored: BTreeSet<String> = match store.as_ref().map(|s| s.paused_sessions()) {
            Some(Ok(ids)) => ids.into_iter().collect(),
            Some(Err(e)) => {
                // A set that will not load is not a reason to refuse to serve: the
                // frames still work, they just start from no pause in effect.
                warn!("could not restore the paused set: {e:#}");
                BTreeSet::new()
            }
            None => BTreeSet::new(),
        };
        Arc::new(Self {
            sessions,
            store,
            changes: broadcast::channel(CHANGE_BUFFER).0,
            paused: Mutex::new(restored),
        })
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Vec<String>> {
        self.changes.subscribe()
    }

    /// The set a play would revive right now, sorted.
    pub fn paused(&self) -> Vec<String> {
        self.paused
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .cloned()
            .collect()
    }

    /// Sleep every live agent session and record the set. Returns what it took.
    ///
    /// The set is recorded and published BEFORE a single pty dies. That ordering is the
    /// same rule the dormant flag got in juancode-nizo's first half and it is
    /// load-bearing for the same reason: a process killed before the record landed is a
    /// session nothing remembers pausing, and a client would see the exits race the
    /// state that is supposed to explain them. Recording an id whose sleep then fails is
    /// harmless — a play skips anything still live.
    pub fn pause_all(&self) -> Vec<String> {
        let targets = self.targets();
        if targets.is_empty() {
            return Vec::new();
        }
        // Union, not assignment: pausing again after a partial play (some rows woken by
        // hand) must not drop the ones still asleep from the set.
        self.mutate(|set| set.extend(targets.iter().cloned()));
        info!(count = targets.len(), "global pause");
        for id in &targets {
            if let Err(e) = self.sessions.sleep(id) {
                // Not fatal and not removed from the set: the row may have exited
                // between the plan and the kill, and a play filters on liveness anyway.
                debug!(session = %id, error = %e, "could not sleep a session for the pause");
            }
        }
        targets
    }

    /// Read the paused set, clear it, and hand back the sessions a play owes.
    ///
    /// Read-and-clear in one step, and the cleared state is published before this
    /// returns, so a pause landing mid-play cannot have its set half-consumed and a
    /// client's button stops reading "paused" the moment the play starts. A revival that
    /// then fails leaves a clickable sleeping row rather than a pause that never lifts.
    ///
    /// Separate from [`Self::revive_all`] because the clear is synchronous and the
    /// revivals are not: the caller publishes the state on its own task and spawns the
    /// spawning.
    pub fn take_for_resume(&self) -> Vec<String> {
        let mut taken = Vec::new();
        self.mutate(|set| taken = std::mem::take(set).into_iter().collect());
        // Anything that came back on its own while paused (clicked, resumed by the
        // Oracle) or vanished from the store entirely is dropped here rather than
        // attempted: a play brings back what is still asleep, not what it recorded.
        taken
            .into_iter()
            .filter(|id| self.sessions.meta(id).is_some() && !self.sessions.is_running(id))
            .collect()
    }

    /// Respawn the given sessions, at most [`LANES`] at a time.
    pub async fn revive_all(self: Arc<Self>, ids: Vec<String>) {
        if ids.is_empty() {
            return;
        }
        info!(count = ids.len(), "global play");
        let mut lanes: Vec<Vec<String>> = vec![Vec::new(); LANES.min(ids.len())];
        // Round-robin rather than contiguous chunks, so the head of the list starts
        // early instead of queueing behind a lane's whole share.
        for (i, id) in ids.into_iter().enumerate() {
            let lane = i % lanes.len();
            lanes[lane].push(id);
        }
        let mut handles = Vec::new();
        for lane in lanes {
            let book = Arc::clone(&self);
            handles.push(tokio::spawn(async move {
                for id in lane {
                    book.revive(&id);
                    tokio::time::sleep(LANE_GAP).await;
                }
            }));
        }
        for handle in handles {
            let _ = handle.await;
        }
    }

    /// One revival. `reactivate` respawns the CLI on the conversation the row
    /// remembers and clears the dormant flag on the way, which is why waking is not a
    /// frame of its own.
    fn revive(&self, id: &str) {
        // The width the session was last drawn at, when the registry still remembers
        // it: scrollback parsed at one grid and replayed at another is a garbled pane,
        // so a revival guesses only when it has to.
        let (cols, rows) = self.sessions.grid(id).unwrap_or(DEFAULT_GRID);
        let revived = self.sessions.reactivate(id, DAEMON, cols, rows);
        self.sessions.release_client(DAEMON);
        if let Err(e) = revived {
            // The row stays asleep and stays clickable. It is deliberately NOT put back
            // into the set: a play that half-failed must still lift the pause, or the
            // button says "paused" forever over sessions nothing will ever revive.
            warn!(session = %id, error = %e, "could not revive a session for the play");
        }
    }

    /// The sessions a pause should sleep: everything live and agent-backed, including
    /// whichever pane somebody is looking at — a "pause all" that leaves the focused
    /// session burning CPU is not a pause.
    ///
    /// Editor and terminal panes are not here at all, because on this core they are not
    /// sessions: they live in the ephemeral pty registry, they hold no conversation to
    /// resume, and sleeping one would lose the buffer and bring back an empty shell.
    /// The `kind` filter is the belt to that braces, for any row adopted as an editor.
    fn targets(&self) -> Vec<String> {
        self.sessions
            .sessions()
            .into_iter()
            .filter(|meta| meta.kind == SessionKind::Agent)
            // Liveness, never the dormant flag. See the module note: this one predicate
            // is what keeps a crashed row and a row the user slept themselves out of
            // the set, and therefore out of the play.
            .filter(|meta| self.sessions.is_running(&meta.id))
            .map(|meta| meta.id)
            .collect()
    }

    /// Apply a change, persist the result, publish it, and hand it back.
    ///
    /// Persist before publish: a client told about a set this daemon would not have
    /// after a restart is a client holding a pause nothing can lift.
    fn mutate(&self, f: impl FnOnce(&mut BTreeSet<String>)) -> Vec<String> {
        let ids: Vec<String> = {
            let mut set = self.paused.lock().unwrap_or_else(|e| e.into_inner());
            f(&mut set);
            set.iter().cloned().collect()
        };
        if let Some(store) = self.store.as_ref() {
            if let Err(e) = store.set_paused_sessions(&ids) {
                warn!("could not persist the paused set: {e:#}");
            }
        }
        // A send with no receivers is the whole daemon having no connections, which is
        // not an error: the set is on disk and the next client is told on connect.
        let _ = self.changes.send(ids.clone());
        ids
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use juancoded_core::model::ProviderId;
    use juancoded_state::registry::{CreateRequest, SessionEvent};

    fn book() -> (Arc<GlobalPause>, Arc<dyn SessionsApi>) {
        let sessions = crate::testing::sessions();
        (GlobalPause::new(Arc::clone(&sessions), None), sessions)
    }

    fn spawn(sessions: &Arc<dyn SessionsApi>) -> String {
        sessions
            .create(CreateRequest {
                provider: ProviderId::Claude,
                cwd: "/tmp".into(),
                cols: 80,
                rows: 24,
                skip_permissions: false,
                model: None,
                preset: None,
                isolate_worktree: false,
                dispatch_id: None,
                owner: 1,
            })
            .expect("the fake CLI spawns")
            .id
    }

    /// A pty's death is asynchronous, and every rule here is a predicate on liveness,
    /// so a test that asserted before the reap would be asserting the wrong state.
    async fn wait_for_exit(events: &mut broadcast::Receiver<SessionEvent>, id: &str) {
        let wait = tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                match events.recv().await {
                    Ok(SessionEvent::Exit { session_id, .. }) if session_id == id => return,
                    Ok(_) => continue,
                    Err(e) => panic!("the session bus went away waiting for {id}: {e}"),
                }
            }
        });
        wait.await.unwrap_or_else(|_| panic!("no exit for {id}"));
    }

    /// The set is what a play revives, so what it leaves out is the whole contract.
    #[tokio::test]
    async fn a_session_that_already_exited_is_not_in_the_set() {
        let (book, sessions) = book();
        let mut events = sessions.subscribe();
        let live = spawn(&sessions);
        let dead = spawn(&sessions);
        sessions.kill(&dead).expect("the second one ends");
        wait_for_exit(&mut events, &dead).await;

        let slept = book.pause_all();

        assert!(slept.contains(&live), "{slept:?}");
        assert!(
            !slept.contains(&dead),
            "a row that ended on its own is not this pause's to wake: {slept:?}"
        );
        assert_eq!(book.paused(), vec![live]);
    }

    /// The identical rule, from the other side: `targets` filters on liveness and not
    /// on the dormant flag, so a row somebody slept themselves stays their sleep rather
    /// than becoming this pause's to wake.
    #[tokio::test]
    async fn a_session_already_asleep_is_not_in_the_set() {
        let (book, sessions) = book();
        let mut events = sessions.subscribe();
        let live = spawn(&sessions);
        let asleep = spawn(&sessions);
        sessions.sleep(&asleep).expect("the second one sleeps");
        wait_for_exit(&mut events, &asleep).await;
        assert!(
            sessions.meta(&asleep).expect("the row stays").dormant,
            "the premise of this test is a dormant row"
        );

        let slept = book.pause_all();

        assert_eq!(slept, vec![live]);
        assert!(
            !book.paused().contains(&asleep),
            "a sleep the user asked for is not part of the pause"
        );
    }

    /// Nothing live is not a pause: no set, and therefore no state frame either.
    #[tokio::test]
    async fn pausing_nothing_records_nothing() {
        let (book, sessions) = book();
        let mut events = sessions.subscribe();
        let only = spawn(&sessions);
        sessions.kill(&only).expect("it ends");
        wait_for_exit(&mut events, &only).await;
        let mut changes = book.subscribe();

        assert!(book.pause_all().is_empty());
        assert!(book.paused().is_empty());
        assert!(
            changes.try_recv().is_err(),
            "an empty pause published a set"
        );
    }

    /// The clear happens before the play, so a resume that revives nothing still lifts
    /// the pause.
    #[tokio::test]
    async fn a_resume_clears_the_set_before_it_revives_anything() {
        let (book, sessions) = book();
        let mut events = sessions.subscribe();
        let id = spawn(&sessions);
        book.pause_all();
        wait_for_exit(&mut events, &id).await;
        assert_eq!(book.paused(), vec![id.clone()]);

        let owed = book.take_for_resume();

        assert_eq!(owed, vec![id]);
        assert!(
            book.paused().is_empty(),
            "the set has to be empty the moment the play starts"
        );
    }

    /// A row that came back on its own while paused is not respawned a second time.
    #[tokio::test]
    async fn a_resume_skips_what_is_already_live_again() {
        let (book, sessions) = book();
        let mut events = sessions.subscribe();
        let paused = spawn(&sessions);
        let woken = spawn(&sessions);
        book.pause_all();
        wait_for_exit(&mut events, &paused).await;
        wait_for_exit(&mut events, &woken).await;
        // Back by hand, the way a click or the Oracle would bring it.
        sessions
            .reactivate(&woken, 1, 80, 24)
            .expect("the row resumes");

        let owed = book.take_for_resume();

        assert_eq!(owed, vec![paused], "a live row is not a revival");
    }

    /// Persistence is the point of the store leg: quitting while paused is half of why
    /// anyone pauses, and a set lost on restart strands every row it took.
    #[tokio::test]
    async fn the_set_survives_a_restart_when_there_is_a_store() {
        let store: Arc<dyn SessionStore> = Arc::new(
            juancoded_persistence::SqliteStore::in_memory().expect("an in-memory store opens"),
        );
        let sessions = crate::testing::sessions();
        let first = GlobalPause::new(Arc::clone(&sessions), Some(Arc::clone(&store)));
        let id = spawn(&sessions);
        first.pause_all();

        let second = GlobalPause::new(Arc::clone(&sessions), Some(store));

        assert_eq!(second.paused(), vec![id]);
    }
}
