//! The `goal` service: one completion objective per session, and the permission to
//! spend another round on it.
//!
//! The record is durable and boring. The interesting half is what is *not* in it.
//!
//! A goal carries an objective, a phase, a revision, a round cap and the rounds it
//! has used. Every accepted mutation names the revision it was written against, so
//! two writers cannot both think they were last; a mismatch is
//! [`GoalError::Stale`] rather than a silent overwrite.
//!
//! **Activation** — permission to start another round — is held in this process's
//! memory and nowhere else. [`GoalJournal`], the durability contract, has no method
//! that can carry it: not "it is not persisted by convention" but "there is no call
//! that could persist it". So a daemon restart, a resume and a fork all come back
//! disarmed, and automatic work always waits on a fresh human authorization. That is
//! the whole point of this module; the record is scaffolding for it.
//!
//! The other rule worth stating up front: **any accepted mutation other than
//! starting a round disarms.** Raising the cap, editing the objective, pausing,
//! blocking, completing — each is new work or a new budget, and each costs the loop
//! its authorization. Only [`GoalApi::arm`] arms, and it must name the exact revision
//! it is authorizing, so nobody arms a goal that changed under them.

use std::collections::BTreeMap;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::service::Service;

/// Where a goal stands. `blocked` is the single durable "stopped by a problem" state;
/// there is deliberately no second sad path, so anything that needs a human names
/// itself with a code rather than inventing a phase.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GoalPhase {
    Active,
    Paused,
    Blocked,
    Complete,
}

impl GoalPhase {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Paused => "paused",
            Self::Blocked => "blocked",
            Self::Complete => "complete",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "active" => Some(Self::Active),
            "paused" => Some(Self::Paused),
            "blocked" => Some(Self::Blocked),
            "complete" => Some(Self::Complete),
            _ => None,
        }
    }

    pub fn is_active(self) -> bool {
        matches!(self, Self::Active)
    }
}

/// Why a phase is `blocked`, in a form something can route on.
///
/// Lower-kebab-case and validated, because this string is a routing key: a Telegram
/// rule, a retry policy or a dashboard filter matches on it, and a code that is
/// sometimes `RoundCap` and sometimes `round cap reached` cannot be matched at all.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct BlockCode(String);

/// The one code this module raises itself: the loop asked for a round it has no
/// budget for.
pub const ROUND_CAP_REACHED: &str = "round-cap-reached";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BadBlockCode {
    pub given: String,
    pub reason: &'static str,
}

impl std::fmt::Display for BadBlockCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "`{}` is not a block code: {} (want lower-kebab-case)",
            self.given, self.reason
        )
    }
}

impl std::error::Error for BadBlockCode {}

impl BlockCode {
    /// Longest code we accept. Generous for anything descriptive, short enough that a
    /// code cannot quietly become the human message.
    pub const MAX_LEN: usize = 64;

    pub fn parse(given: &str) -> Result<Self, BadBlockCode> {
        let bad = |reason| BadBlockCode {
            given: given.to_string(),
            reason,
        };
        if given.is_empty() {
            return Err(bad("empty"));
        }
        if given.len() > Self::MAX_LEN {
            return Err(bad("longer than 64 bytes"));
        }
        if given.starts_with('-') || given.ends_with('-') {
            return Err(bad("leading or trailing dash"));
        }
        if given.contains("--") {
            return Err(bad("doubled dash"));
        }
        if !given
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        {
            return Err(bad("not lower-kebab-case ascii"));
        }
        Ok(Self(given.to_string()))
    }

    pub fn round_cap_reached() -> Self {
        Self(ROUND_CAP_REACHED.to_string())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// A block: the code routes, the message is for whoever reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Blocked {
    pub code: BlockCode,
    pub message: String,
}

/// One session's goal, as it is stored.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Goal {
    pub session_id: String,
    pub objective: String,
    pub phase: GoalPhase,
    /// Bumped by every accepted mutation, and the compare-and-set identity every
    /// mutation is written against.
    pub revision: u64,
    pub round_cap: u32,
    pub rounds_used: u32,
    /// `Some` exactly when `phase` is [`GoalPhase::Blocked`]. Kept as one option
    /// rather than two nullable columns so the invariant is unstateable-wrong here
    /// even though SQLite cannot express it.
    pub block: Option<Blocked>,
    pub created_at: i64,
    pub updated_at: i64,
}

impl Goal {
    /// The reference a caller passes back to mutate this goal.
    pub fn at(&self) -> GoalRef {
        GoalRef {
            session_id: self.session_id.clone(),
            revision: self.revision,
        }
    }

    pub fn rounds_left(&self) -> u32 {
        self.round_cap.saturating_sub(self.rounds_used)
    }
}

/// "The goal for this session, as it stood at this revision." Every mutation takes
/// one, which is what makes a lost update an error instead of a surprise.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GoalRef {
    pub session_id: String,
    pub revision: u64,
}

impl GoalRef {
    pub fn new(session_id: impl Into<String>, revision: u64) -> Self {
        Self {
            session_id: session_id.into(),
            revision,
        }
    }
}

/// Who armed a goal and when. Memory only: this type never reaches a journal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Armed {
    pub by: String,
    pub at: i64,
}

/// A goal plus its activation, in one readable shape.
///
/// This is what a client reads: the session cell wants `phase` and
/// `roundsUsed`/`roundCap`, and a Telegram route wants `blockCode` with
/// `blockMessage` to quote. camelCase because that is how this daemon's wire already
/// spells everything.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GoalSnapshot {
    pub session_id: String,
    pub objective: String,
    pub phase: GoalPhase,
    pub revision: u64,
    pub round_cap: u32,
    pub rounds_used: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub block_code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub block_message: Option<String>,
    /// Always false on the first read after a boot. Never restored from anywhere.
    pub armed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub armed_by: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

impl GoalSnapshot {
    fn of(goal: &Goal, armed: Option<&Armed>) -> Self {
        Self {
            session_id: goal.session_id.clone(),
            objective: goal.objective.clone(),
            phase: goal.phase,
            revision: goal.revision,
            round_cap: goal.round_cap,
            rounds_used: goal.rounds_used,
            block_code: goal.block.as_ref().map(|b| b.code.as_str().to_string()),
            block_message: goal.block.as_ref().map(|b| b.message.clone()),
            armed: armed.is_some(),
            armed_by: armed.map(|a| a.by.clone()),
            created_at: goal.created_at,
            updated_at: goal.updated_at,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GoalError {
    NoGoal {
        session: String,
    },
    AlreadyExists {
        session: String,
    },
    /// Somebody else wrote first. The caller re-reads and decides again; it does not
    /// get to win by asking twice.
    Stale {
        session: String,
        expected: u64,
        actual: u64,
    },
    EmptyObjective,
    /// `blocked` is reachable only through [`GoalApi::block`], because a block with
    /// no code is a dead end nothing can route.
    BlockNeedsCode,
    BadCode(BadBlockCode),
    /// A cap under the rounds already spent would make `rounds_left` a lie. Rejected
    /// rather than clamped: the caller asked for something impossible and should hear
    /// about it.
    CapBelowUsed {
        cap: u32,
        used: u32,
    },
    NotActive {
        phase: GoalPhase,
    },
    /// The durable write failed, so the mutation did not happen. Reported rather than
    /// swallowed: a rail that loses its own record of a spent round is not a rail.
    Journal(String),
}

impl std::fmt::Display for GoalError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoGoal { session } => write!(f, "session `{session}` has no goal"),
            Self::AlreadyExists { session } => {
                write!(f, "session `{session}` already has a goal")
            }
            Self::Stale {
                session,
                expected,
                actual,
            } => write!(
                f,
                "goal for `{session}` moved on: wrote against revision {expected}, it is at {actual}"
            ),
            Self::EmptyObjective => write!(f, "a goal with no objective is not a goal"),
            Self::BlockNeedsCode => {
                write!(f, "use block(code, message) to reach the blocked phase")
            }
            Self::BadCode(e) => write!(f, "{e}"),
            Self::CapBelowUsed { cap, used } => {
                write!(f, "a cap of {cap} is below the {used} rounds already spent")
            }
            Self::NotActive { phase } => write!(f, "the goal is {}, not active", phase.as_str()),
            Self::Journal(e) => write!(f, "the goal could not be recorded: {e}"),
        }
    }
}

impl std::error::Error for GoalError {}

/// Why a round did not start. Not an error: a refused round is the rail working, and
/// the caller gets the goal back so it can say what happened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RoundRefusal {
    /// Nobody has authorized another round in this process. The restart case lands
    /// here, every time.
    Disarmed,
    /// The cap is spent. The goal is now durably blocked with
    /// [`ROUND_CAP_REACHED`], so this refusal is visible to a client that never saw
    /// the call.
    CapReached,
    NotActive(GoalPhase),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RoundOutcome {
    /// One round was spent. The goal carries the new `rounds_used` and revision.
    Started(Goal),
    Refused {
        goal: Goal,
        reason: RoundRefusal,
    },
}

impl RoundOutcome {
    pub fn goal(&self) -> &Goal {
        match self {
            Self::Started(goal) => goal,
            Self::Refused { goal, .. } => goal,
        }
    }

    pub fn started(&self) -> bool {
        matches!(self, Self::Started(_))
    }
}

/// What consumers of the `goal` key may do.
pub trait GoalApi: Send + Sync {
    fn get(&self, session: &str) -> Option<Goal>;
    fn snapshot(&self, session: &str) -> Option<GoalSnapshot>;
    /// Every goal this core knows, session order. One read for a client that is
    /// drawing a whole session list.
    fn snapshots(&self) -> Vec<GoalSnapshot>;

    fn create(&self, session: &str, objective: &str, round_cap: u32) -> Result<Goal, GoalError>;
    /// A fresh goal on another session from this one's objective and cap.
    ///
    /// Rounds start at zero and the fork is disarmed, like everything else that was
    /// not authorized in this process a moment ago.
    fn fork(&self, from: &str, to: &str) -> Result<Goal, GoalError>;

    fn set_objective(&self, at: &GoalRef, objective: &str) -> Result<Goal, GoalError>;
    fn set_round_cap(&self, at: &GoalRef, round_cap: u32) -> Result<Goal, GoalError>;
    /// Move to `active`, `paused` or `complete`. `blocked` is [`Self::block`]'s job.
    fn set_phase(&self, at: &GoalRef, phase: GoalPhase) -> Result<Goal, GoalError>;
    fn block(&self, at: &GoalRef, code: &str, message: &str) -> Result<Goal, GoalError>;
    fn delete(&self, at: &GoalRef) -> Result<(), GoalError>;

    /// Authorize rounds on the goal as it stands at `at`.
    ///
    /// Not a mutation: the revision does not move and nothing is written down, which
    /// is exactly why a restart cannot bring this back.
    fn arm(&self, at: &GoalRef, by: &str) -> Result<Goal, GoalError>;
    /// Withdraw the authorization. `false` means it was not armed.
    fn disarm(&self, session: &str) -> bool;
    fn armed(&self, session: &str) -> Option<Armed>;

    /// Spend one round, if there is permission and budget for it.
    ///
    /// This is the only call that consumes the cap. An ordinary human turn in the
    /// same session goes nowhere near it.
    fn begin_round(&self, at: &GoalRef) -> Result<RoundOutcome, GoalError>;
}

/// The contract marker: `ctx.resolve::<GoalService>()` yields `Arc<dyn GoalApi>`.
pub struct GoalService;

impl Service for GoalService {
    const KEY: &'static str = "goal";
    type Api = dyn GoalApi;
}

/// The durable half of a goal, and only the durable half.
///
/// Look at what cannot be said here: there is no `set_armed`, no `armed` field on
/// anything that crosses this trait, and no blob a caller could smuggle one through.
/// "Activation never survives a restart" is therefore a property of these three
/// signatures rather than of anyone remembering to leave a column out.
pub trait GoalJournal: Send + Sync {
    fn load_all(&self) -> Result<Vec<Goal>, String>;
    fn put(&self, goal: &Goal) -> Result<(), String>;
    fn remove(&self, session: &str) -> Result<(), String>;
}

/// A journal that forgets when the process does. The default when no path is
/// configured, and what a test uses when it is not testing durability.
#[derive(Default)]
pub struct MemoryJournal {
    rows: Mutex<BTreeMap<String, Goal>>,
}

impl MemoryJournal {
    pub fn new() -> Self {
        Self::default()
    }
}

impl GoalJournal for MemoryJournal {
    fn load_all(&self) -> Result<Vec<Goal>, String> {
        Ok(self.lock().values().cloned().collect())
    }

    fn put(&self, goal: &Goal) -> Result<(), String> {
        self.lock().insert(goal.session_id.clone(), goal.clone());
        Ok(())
    }

    fn remove(&self, session: &str) -> Result<(), String> {
        self.lock().remove(session);
        Ok(())
    }
}

impl MemoryJournal {
    fn lock(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, Goal>> {
        self.rows.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// A journal that refuses every write. Tests only, and the reason
/// [`GoalError::Journal`] exists.
#[cfg(test)]
pub struct BrokenJournal;

#[cfg(test)]
impl GoalJournal for BrokenJournal {
    fn load_all(&self) -> Result<Vec<Goal>, String> {
        Ok(Vec::new())
    }

    fn put(&self, _goal: &Goal) -> Result<(), String> {
        Err("disk on fire".into())
    }

    fn remove(&self, _session: &str) -> Result<(), String> {
        Err("disk on fire".into())
    }
}

struct State {
    goals: BTreeMap<String, Goal>,
    /// The whole rail, in one field that no journal call can reach. Presence is
    /// permission.
    armed: BTreeMap<String, Armed>,
}

/// The `goal` service's implementation: the records, the activation map, and one
/// journal behind them.
pub struct GoalBook {
    state: Mutex<State>,
    journal: Box<dyn GoalJournal>,
    clock: fn() -> i64,
}

impl GoalBook {
    /// Load whatever the journal holds. Nothing comes back armed, because there is
    /// nowhere for "armed" to have come back from.
    pub fn restore(journal: Box<dyn GoalJournal>) -> Result<Self, GoalError> {
        Self::restore_with_clock(journal, juancoded_core::model::now_ms)
    }

    pub(crate) fn restore_with_clock(
        journal: Box<dyn GoalJournal>,
        clock: fn() -> i64,
    ) -> Result<Self, GoalError> {
        let loaded = journal.load_all().map_err(GoalError::Journal)?;
        let goals = loaded
            .into_iter()
            .map(|g| (g.session_id.clone(), g))
            .collect();
        Ok(Self {
            state: Mutex::new(State {
                goals,
                armed: BTreeMap::new(),
            }),
            journal,
            clock,
        })
    }

    /// How many goals came back from the journal. The mount site logs it.
    pub fn len(&self) -> usize {
        self.lock().goals.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Read the goal `at` names, or say why the caller is not allowed to write it.
    fn checked(state: &State, at: &GoalRef) -> Result<Goal, GoalError> {
        let goal = state
            .goals
            .get(&at.session_id)
            .ok_or_else(|| GoalError::NoGoal {
                session: at.session_id.clone(),
            })?;
        if goal.revision != at.revision {
            return Err(GoalError::Stale {
                session: at.session_id.clone(),
                expected: at.revision,
                actual: goal.revision,
            });
        }
        Ok(goal.clone())
    }

    /// Record `next` durably, then adopt it, then disarm.
    ///
    /// The order matters: memory never gets ahead of the journal, so a crash between
    /// the two loses the mutation rather than inventing a spent round. And the disarm
    /// is here rather than at each call site, which is what makes "any accepted
    /// mutation disarms" true by construction instead of by review.
    fn commit(&self, state: &mut State, mut next: Goal) -> Result<Goal, GoalError> {
        next.revision += 1;
        next.updated_at = (self.clock)();
        self.journal.put(&next).map_err(GoalError::Journal)?;
        state.armed.remove(&next.session_id);
        state.goals.insert(next.session_id.clone(), next.clone());
        Ok(next)
    }
}

impl GoalApi for GoalBook {
    fn get(&self, session: &str) -> Option<Goal> {
        self.lock().goals.get(session).cloned()
    }

    fn snapshot(&self, session: &str) -> Option<GoalSnapshot> {
        let state = self.lock();
        let goal = state.goals.get(session)?;
        Some(GoalSnapshot::of(goal, state.armed.get(session)))
    }

    fn snapshots(&self) -> Vec<GoalSnapshot> {
        let state = self.lock();
        state
            .goals
            .values()
            .map(|goal| GoalSnapshot::of(goal, state.armed.get(&goal.session_id)))
            .collect()
    }

    fn create(&self, session: &str, objective: &str, round_cap: u32) -> Result<Goal, GoalError> {
        let objective = objective.trim();
        if objective.is_empty() {
            return Err(GoalError::EmptyObjective);
        }
        let mut state = self.lock();
        if state.goals.contains_key(session) {
            return Err(GoalError::AlreadyExists {
                session: session.to_string(),
            });
        }
        let now = (self.clock)();
        let goal = Goal {
            session_id: session.to_string(),
            objective: objective.to_string(),
            phase: GoalPhase::Active,
            revision: 1,
            round_cap,
            rounds_used: 0,
            block: None,
            created_at: now,
            updated_at: now,
        };
        self.journal.put(&goal).map_err(GoalError::Journal)?;
        // Not `commit`: there is no prior revision to bump and nothing to disarm, and
        // a fresh goal starting at revision 1 is what every CAS caller expects.
        state.goals.insert(session.to_string(), goal.clone());
        Ok(goal)
    }

    fn fork(&self, from: &str, to: &str) -> Result<Goal, GoalError> {
        let source = self.get(from).ok_or_else(|| GoalError::NoGoal {
            session: from.to_string(),
        })?;
        // Through `create`, so the fork starts at revision 1 with no rounds spent and
        // no activation. A fork that inherited its parent's permission would be the
        // exact hole this module exists to close.
        self.create(to, &source.objective, source.round_cap)
    }

    fn set_objective(&self, at: &GoalRef, objective: &str) -> Result<Goal, GoalError> {
        let objective = objective.trim();
        if objective.is_empty() {
            return Err(GoalError::EmptyObjective);
        }
        let mut state = self.lock();
        let mut next = Self::checked(&state, at)?;
        next.objective = objective.to_string();
        self.commit(&mut state, next)
    }

    fn set_round_cap(&self, at: &GoalRef, round_cap: u32) -> Result<Goal, GoalError> {
        let mut state = self.lock();
        let mut next = Self::checked(&state, at)?;
        if round_cap < next.rounds_used {
            return Err(GoalError::CapBelowUsed {
                cap: round_cap,
                used: next.rounds_used,
            });
        }
        next.round_cap = round_cap;
        self.commit(&mut state, next)
    }

    fn set_phase(&self, at: &GoalRef, phase: GoalPhase) -> Result<Goal, GoalError> {
        if phase == GoalPhase::Blocked {
            return Err(GoalError::BlockNeedsCode);
        }
        let mut state = self.lock();
        let mut next = Self::checked(&state, at)?;
        next.phase = phase;
        // Leaving `blocked` clears the block with it: a code that outlived its phase
        // would keep routing a problem that is over.
        next.block = None;
        self.commit(&mut state, next)
    }

    fn block(&self, at: &GoalRef, code: &str, message: &str) -> Result<Goal, GoalError> {
        let code = BlockCode::parse(code).map_err(GoalError::BadCode)?;
        let mut state = self.lock();
        let mut next = Self::checked(&state, at)?;
        next.phase = GoalPhase::Blocked;
        next.block = Some(Blocked {
            code,
            message: message.to_string(),
        });
        self.commit(&mut state, next)
    }

    fn delete(&self, at: &GoalRef) -> Result<(), GoalError> {
        let mut state = self.lock();
        Self::checked(&state, at)?;
        self.journal
            .remove(&at.session_id)
            .map_err(GoalError::Journal)?;
        state.goals.remove(&at.session_id);
        state.armed.remove(&at.session_id);
        Ok(())
    }

    fn arm(&self, at: &GoalRef, by: &str) -> Result<Goal, GoalError> {
        let mut state = self.lock();
        let goal = Self::checked(&state, at)?;
        if !goal.phase.is_active() {
            return Err(GoalError::NotActive { phase: goal.phase });
        }
        state.armed.insert(
            at.session_id.clone(),
            Armed {
                by: by.to_string(),
                at: (self.clock)(),
            },
        );
        // The revision does not move and the journal was not touched. Arming is a fact
        // about this process, not about the goal.
        Ok(goal)
    }

    fn disarm(&self, session: &str) -> bool {
        self.lock().armed.remove(session).is_some()
    }

    fn armed(&self, session: &str) -> Option<Armed> {
        self.lock().armed.get(session).cloned()
    }

    fn begin_round(&self, at: &GoalRef) -> Result<RoundOutcome, GoalError> {
        let mut state = self.lock();
        let goal = Self::checked(&state, at)?;
        if !goal.phase.is_active() {
            return Ok(RoundOutcome::Refused {
                reason: RoundRefusal::NotActive(goal.phase),
                goal,
            });
        }
        if !state.armed.contains_key(&at.session_id) {
            return Ok(RoundOutcome::Refused {
                goal,
                reason: RoundRefusal::Disarmed,
            });
        }
        if goal.rounds_left() == 0 {
            // The refusal is durable, not just returned: whoever asked may be a loop
            // nobody is watching, and the reason a session stopped has to outlive the
            // call that discovered it.
            let mut next = goal;
            next.phase = GoalPhase::Blocked;
            next.block = Some(Blocked {
                code: BlockCode::round_cap_reached(),
                message: format!(
                    "spent all {} rounds; a human decides whether to raise the cap",
                    next.round_cap
                ),
            });
            let blocked = self.commit(&mut state, next)?;
            return Ok(RoundOutcome::Refused {
                goal: blocked,
                reason: RoundRefusal::CapReached,
            });
        }
        let mut next = goal;
        next.rounds_used += 1;
        // Started rounds keep their authorization: the cap is the budget, and making a
        // human re-arm between every round of an unattended loop would mean no
        // unattended loop. `commit` disarms, so re-arm after it, which also means a
        // failed journal write leaves the goal disarmed.
        let by = state.armed.get(&at.session_id).cloned();
        let started = self.commit(&mut state, next)?;
        if let Some(by) = by {
            state.armed.insert(at.session_id.clone(), by);
        }
        Ok(RoundOutcome::Started(started))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn clock() -> i64 {
        1_700_000_000_000
    }

    fn book() -> GoalBook {
        GoalBook::restore_with_clock(Box::new(MemoryJournal::new()), clock).unwrap()
    }

    fn armed_goal(book: &GoalBook, cap: u32) -> Goal {
        let goal = book.create("s1", "land the ticket", cap).unwrap();
        book.arm(&goal.at(), "juan").unwrap()
    }

    #[test]
    fn a_created_goal_starts_active_at_revision_one_with_no_rounds_spent() {
        let book = book();
        let goal = book.create("s1", "  land the ticket  ", 5).unwrap();
        assert_eq!(goal.objective, "land the ticket");
        assert_eq!(goal.phase, GoalPhase::Active);
        assert_eq!((goal.revision, goal.round_cap, goal.rounds_used), (1, 5, 0));
        assert!(goal.block.is_none());
        assert!(book.armed("s1").is_none(), "a new goal is not authorized");
        assert_eq!(
            book.create("s1", "something else", 5).unwrap_err(),
            GoalError::AlreadyExists {
                session: "s1".into()
            }
        );
        assert_eq!(
            book.create("s2", "   ", 5).unwrap_err(),
            GoalError::EmptyObjective
        );
    }

    #[test]
    fn every_accepted_mutation_moves_the_revision_and_a_stale_write_is_refused() {
        let book = book();
        let goal = book.create("s1", "first", 5).unwrap();
        let stale = goal.at();

        let after = book.set_objective(&stale, "second").unwrap();
        assert_eq!(after.revision, 2);
        assert_eq!(after.objective, "second");

        // The same reference again is a lost update, and it loses.
        assert_eq!(
            book.set_objective(&stale, "third").unwrap_err(),
            GoalError::Stale {
                session: "s1".into(),
                expected: 1,
                actual: 2,
            }
        );
        assert_eq!(book.get("s1").unwrap().objective, "second");
        // A refused mutation is not a mutation: the revision did not move either.
        assert_eq!(book.get("s1").unwrap().revision, 2);

        let after = book.set_round_cap(&after.at(), 9).unwrap();
        assert_eq!((after.revision, after.round_cap), (3, 9));
        let after = book.set_phase(&after.at(), GoalPhase::Paused).unwrap();
        assert_eq!((after.revision, after.phase), (4, GoalPhase::Paused));
    }

    #[test]
    fn a_cap_below_the_rounds_already_spent_is_refused_not_clamped() {
        let book = book();
        let goal = armed_goal(&book, 4);
        let goal = match book.begin_round(&goal.at()).unwrap() {
            RoundOutcome::Started(g) => g,
            other => panic!("expected a started round, got {other:?}"),
        };
        assert_eq!(goal.rounds_used, 1);
        assert_eq!(
            book.set_round_cap(&goal.at(), 0).unwrap_err(),
            GoalError::CapBelowUsed { cap: 0, used: 1 }
        );
        // Equal to what is spent is legal, and it leaves no rounds left.
        let pinned = book.set_round_cap(&goal.at(), 1).unwrap();
        assert_eq!(pinned.rounds_left(), 0);
    }

    #[test]
    fn blocked_is_the_only_sad_path_and_it_carries_a_routable_code() {
        let book = book();
        let goal = book.create("s1", "land the ticket", 5).unwrap();
        assert_eq!(
            book.set_phase(&goal.at(), GoalPhase::Blocked).unwrap_err(),
            GoalError::BlockNeedsCode,
            "reaching blocked without a code has to be impossible"
        );

        let blocked = book
            .block(
                &goal.at(),
                "review-required",
                "two approvals missing on #4242",
            )
            .unwrap();
        assert_eq!(blocked.phase, GoalPhase::Blocked);
        let block = blocked.block.as_ref().unwrap();
        assert_eq!(block.code.as_str(), "review-required");
        assert_eq!(block.message, "two approvals missing on #4242");

        // Leaving the phase takes the code with it.
        let resumed = book.set_phase(&blocked.at(), GoalPhase::Active).unwrap();
        assert!(resumed.block.is_none());

        for bad in ["", "Review-Required", "review required", "-lead", "a--b"] {
            assert!(
                matches!(
                    book.block(&resumed.at(), bad, "x"),
                    Err(GoalError::BadCode(_))
                ),
                "`{bad}` should not be a code"
            );
        }
        assert!(BlockCode::parse("ci-red-3").is_ok());
        assert!(BlockCode::parse(&"a".repeat(65)).is_err());
    }

    #[test]
    fn a_round_needs_an_authorization_and_a_restart_cannot_have_one() {
        let book = book();
        let goal = book.create("s1", "land the ticket", 3).unwrap();

        // Disarmed is the state a fresh process is in, and it refuses.
        match book.begin_round(&goal.at()).unwrap() {
            RoundOutcome::Refused { reason, goal } => {
                assert_eq!(reason, RoundRefusal::Disarmed);
                assert_eq!(goal.rounds_used, 0, "a refused round costs nothing");
                assert_eq!(goal.revision, 1, "and does not move the revision");
            }
            other => panic!("expected a refusal, got {other:?}"),
        }

        let armed = book.arm(&goal.at(), "juan").unwrap();
        assert_eq!(armed.revision, 1, "arming is not a durable mutation");
        assert_eq!(book.armed("s1").unwrap().by, "juan");
        assert!(book.begin_round(&armed.at()).unwrap().started());
    }

    #[test]
    fn arming_names_the_revision_it_authorizes_and_any_mutation_revokes_it() {
        let book = book();
        let goal = armed_goal(&book, 5);
        assert!(book.armed("s1").is_some());

        // Raising the cap is granting more budget, so it costs the authorization.
        let wider = book.set_round_cap(&goal.at(), 9).unwrap();
        assert!(
            book.armed("s1").is_none(),
            "a new budget needs a new authorization"
        );
        // And the stale reference cannot re-arm the goal it no longer describes.
        assert!(matches!(
            book.arm(&goal.at(), "juan"),
            Err(GoalError::Stale { .. })
        ));
        assert!(book.armed("s1").is_none());
        book.arm(&wider.at(), "juan").unwrap();
        assert!(book.armed("s1").is_some());

        // So does editing the objective.
        let edited = book
            .set_objective(&wider.at(), "land something else")
            .unwrap();
        assert!(book.armed("s1").is_none());

        // A goal that is not active cannot be armed at all.
        let paused = book.set_phase(&edited.at(), GoalPhase::Paused).unwrap();
        assert_eq!(
            book.arm(&paused.at(), "juan").unwrap_err(),
            GoalError::NotActive {
                phase: GoalPhase::Paused
            }
        );
    }

    #[test]
    fn a_started_round_keeps_its_authorization_so_a_loop_can_run_its_budget() {
        let book = book();
        let goal = armed_goal(&book, 3);
        let mut at = goal.at();
        for spent in 1..=3 {
            let outcome = book.begin_round(&at).unwrap();
            assert!(outcome.started(), "round {spent} was refused: {outcome:?}");
            assert_eq!(outcome.goal().rounds_used, spent);
            at = outcome.goal().at();
        }
        assert!(book.armed("s1").is_some(), "still authorized mid-budget");
    }

    #[test]
    fn the_round_after_the_cap_blocks_the_goal_durably_and_disarms_it() {
        let book = book();
        let goal = armed_goal(&book, 1);
        let started = book.begin_round(&goal.at()).unwrap();
        assert!(started.started());

        let outcome = book.begin_round(&started.goal().at()).unwrap();
        match outcome {
            RoundOutcome::Refused { goal, reason } => {
                assert_eq!(reason, RoundRefusal::CapReached);
                assert_eq!(goal.phase, GoalPhase::Blocked);
                assert_eq!(
                    goal.block.as_ref().unwrap().code.as_str(),
                    ROUND_CAP_REACHED
                );
                assert_eq!(goal.rounds_used, 1, "the refused round was not spent");
            }
            other => panic!("expected a cap refusal, got {other:?}"),
        }
        assert!(
            book.armed("s1").is_none(),
            "a blocked goal is not authorized"
        );
        // And the block is in the journal, not just in the return value.
        assert_eq!(
            book.snapshot("s1").unwrap().block_code.as_deref(),
            Some(ROUND_CAP_REACHED)
        );
    }

    #[test]
    fn a_round_on_a_paused_goal_is_refused_without_spending_anything() {
        let book = book();
        let goal = armed_goal(&book, 5);
        let paused = book.set_phase(&goal.at(), GoalPhase::Paused).unwrap();
        book.lock().armed.insert(
            "s1".into(),
            Armed {
                by: "a bug".into(),
                at: 0,
            },
        );
        match book.begin_round(&paused.at()).unwrap() {
            RoundOutcome::Refused { reason, goal } => {
                assert_eq!(reason, RoundRefusal::NotActive(GoalPhase::Paused));
                assert_eq!(goal.rounds_used, 0);
            }
            other => panic!("expected a phase refusal, got {other:?}"),
        }
    }

    #[test]
    fn a_journal_that_refuses_the_write_refuses_the_mutation() {
        let book = GoalBook::restore_with_clock(Box::new(BrokenJournal), clock).unwrap();
        assert_eq!(
            book.create("s1", "land it", 3).unwrap_err(),
            GoalError::Journal("disk on fire".into())
        );
        assert!(
            book.get("s1").is_none(),
            "memory must not get ahead of the journal"
        );
    }

    #[test]
    fn a_reloaded_book_has_the_goals_and_none_of_the_authorizations() {
        let journal = Arc::new(MemoryJournal::new());
        struct Shared(Arc<MemoryJournal>);
        impl GoalJournal for Shared {
            fn load_all(&self) -> Result<Vec<Goal>, String> {
                self.0.load_all()
            }
            fn put(&self, goal: &Goal) -> Result<(), String> {
                self.0.put(goal)
            }
            fn remove(&self, session: &str) -> Result<(), String> {
                self.0.remove(session)
            }
        }

        let first = GoalBook::restore_with_clock(Box::new(Shared(journal.clone())), clock).unwrap();
        let goal = first.create("s1", "land the ticket", 4).unwrap();
        let goal = first.arm(&goal.at(), "juan").unwrap();
        let goal = first.begin_round(&goal.at()).unwrap().goal().clone();
        assert!(first.armed("s1").is_some());
        drop(first);

        let second =
            GoalBook::restore_with_clock(Box::new(Shared(journal.clone())), clock).unwrap();
        let back = second.get("s1").unwrap();
        assert_eq!(back, goal, "the record replays whole");
        assert_eq!(back.rounds_used, 1);
        assert!(
            second.armed("s1").is_none(),
            "a reload must never come back authorized"
        );
        assert!(!second.snapshot("s1").unwrap().armed);
        assert!(matches!(
            second.begin_round(&back.at()).unwrap(),
            RoundOutcome::Refused {
                reason: RoundRefusal::Disarmed,
                ..
            }
        ));
    }

    #[test]
    fn a_fork_inherits_the_objective_and_none_of_the_progress() {
        let book = book();
        let goal = armed_goal(&book, 4);
        let goal = book.begin_round(&goal.at()).unwrap().goal().clone();
        assert_eq!(goal.rounds_used, 1);

        let forked = book.fork("s1", "s2").unwrap();
        assert_eq!(forked.objective, goal.objective);
        assert_eq!(forked.round_cap, 4);
        assert_eq!((forked.rounds_used, forked.revision), (0, 1));
        assert!(book.armed("s2").is_none(), "a fork is never pre-authorized");
        assert!(book.armed("s1").is_some(), "and the parent is untouched");
        assert_eq!(
            book.fork("nobody", "s3").unwrap_err(),
            GoalError::NoGoal {
                session: "nobody".into()
            }
        );
    }

    #[test]
    fn deleting_needs_the_current_revision_and_takes_the_authorization_with_it() {
        let book = book();
        let goal = armed_goal(&book, 3);
        assert!(matches!(
            book.delete(&GoalRef::new("s1", 99)),
            Err(GoalError::Stale { .. })
        ));
        book.delete(&goal.at()).unwrap();
        assert!(book.get("s1").is_none());
        assert!(book.armed("s1").is_none());
        assert_eq!(
            book.delete(&goal.at()).unwrap_err(),
            GoalError::NoGoal {
                session: "s1".into()
            }
        );
    }

    #[test]
    fn a_snapshot_says_everything_a_session_cell_and_a_telegram_route_need() {
        let book = book();
        let goal = armed_goal(&book, 6);
        let goal = book.begin_round(&goal.at()).unwrap().goal().clone();
        let snap = book.snapshot("s1").unwrap();
        assert_eq!(snap.phase, GoalPhase::Active);
        assert_eq!((snap.rounds_used, snap.round_cap), (1, 6));
        assert!(snap.armed);
        assert_eq!(snap.armed_by.as_deref(), Some("juan"));

        let blocked = book
            .block(&goal.at(), "ci-red", "3 checks failing")
            .unwrap();
        let snap = book.snapshot("s1").unwrap();
        assert_eq!(snap.block_code.as_deref(), Some("ci-red"));
        assert_eq!(snap.block_message.as_deref(), Some("3 checks failing"));
        assert!(!snap.armed, "blocking disarmed it");
        assert_eq!(snap.revision, blocked.revision);

        // It is JSON a client reads without knowing this crate exists.
        let json = serde_json::to_value(&snap).unwrap();
        assert_eq!(json["phase"], "blocked");
        assert_eq!(json["roundsUsed"], 1);
        assert_eq!(json["roundCap"], 6);
        assert_eq!(json["blockCode"], "ci-red");
        assert_eq!(json["armed"], false);
        assert_eq!(
            serde_json::from_value::<GoalSnapshot>(json).unwrap(),
            snap,
            "and it round-trips, so the wire layer can decode its own frames"
        );

        book.create("s2", "another", 2).unwrap();
        let ids: Vec<String> = book.snapshots().into_iter().map(|s| s.session_id).collect();
        assert_eq!(ids, ["s1", "s2"]);
    }
}
