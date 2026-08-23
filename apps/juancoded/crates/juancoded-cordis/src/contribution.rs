//! Contributions: declarative extension points on the built-in surfaces.
//!
//! A plugin that wants to change juancode's chrome does not own the sidebar, the
//! session row or the status bar. It registers a *descriptor* saying what it wants to
//! appear and where, the shell renders descriptors generically, and the plugin gets a
//! guard back. Adding chrome is then a daemon-side registration with no client change,
//! which is the whole point: the 23k lines of SwiftUI stay privileged UI and stay put.
//!
//! Four rules hold the model together.
//!
//! 1. **A contribution is an effect.** [`ContributionRegistry::contribute`] hands back
//!    an [`Effect`], so a contribution appears when its plugin mounts and is gone when
//!    it unmounts, with nothing to restart and no second teardown path to forget. This
//!    is the RAII registry earning its keep.
//! 2. **A contribution is addressed by a stable id**, the same way an entry row is.
//!    The id is what `dump-config` prints, what an activation names, and what a second
//!    registration collides with rather than silently replacing.
//! 3. **Order is deterministic.** Rows sort by `(sort_key, id)`, never by registration
//!    order, so two plugins contributing the same slot produce the same list on every
//!    boot and in every client.
//! 4. **Actions are round trips.** A descriptor carries no code. Activating one sends
//!    [`Activation`] to the daemon, which runs the owning plugin's handler and answers
//!    with an [`ActivationOutcome`]. The client never executes plugin logic.
//!
//! Custom views (arbitrary layout) are deliberately not here: they need a webview
//! panel host, which is its own ticket and justified by the PR/diff backlog rather
//! than by plugins.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::effect::Effect;

/// The descriptor schema, versioned alongside the wire protocol.
///
/// A client compares this against what it knows how to render. It is bumped when an
/// existing field changes meaning, never for a new [`Placement`] variant: a new
/// surface is additive precisely because an unknown one is ignored.
pub const SCHEMA_VERSION: u32 = 1;

/// What a contribution wants to see, declared up front.
///
/// No ambient access: a descriptor that never says `SessionTranscript` cannot read a
/// transcript, and asking anyway is [`ScopeError`] rather than data. This matters the
/// moment an agent can write a plugin at runtime, which is the point of the model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DataNeed {
    /// This session's activity and status. Not its bytes.
    SessionActivity,
    /// This session's transcript turns.
    SessionTranscript,
    /// The sessions in the project the surface is showing.
    ProjectSessions,
    /// The PRs juancode is already tracking.
    TrackedPrs,
}

impl DataNeed {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::SessionActivity => "session.activity",
            Self::SessionTranscript => "session.transcript",
            Self::ProjectSessions => "project.sessions",
            Self::TrackedPrs => "prs.tracked",
        }
    }
}

/// A visual weight the shell maps to its own palette. Descriptors never name colours:
/// a plugin that hard-coded `#ff0000` would be unreadable in one of the two themes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Tone {
    #[default]
    Neutral,
    Info,
    Success,
    Warning,
    Danger,
}

/// A short decoration on a row: the stuck-session and goal-phase indicators are the
/// shape this was drawn around.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Badge {
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(default)]
    pub tone: Tone,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tooltip: Option<String>,
}

impl Badge {
    pub fn new(label: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            ..Self::default()
        }
    }

    pub fn tone(mut self, tone: Tone) -> Self {
        self.tone = tone;
        self
    }

    pub fn icon(mut self, icon: impl Into<String>) -> Self {
        self.icon = Some(icon.into());
        self
    }
}

/// What a context-menu item hangs off.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MenuTarget {
    Session,
    Project,
    Pr,
}

/// One typed field in a settings card, so the shell renders the form and the plugin
/// never ships a view.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum SettingsField {
    Toggle {
        key: String,
        label: String,
        #[serde(default)]
        value: bool,
    },
    Text {
        key: String,
        label: String,
        #[serde(default)]
        value: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        placeholder: Option<String>,
    },
    Choice {
        key: String,
        label: String,
        options: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        value: Option<String>,
    },
    /// A field type this client does not render. Never an error: the rest of the card
    /// still draws.
    #[serde(other)]
    Unrecognized,
}

/// Where a descriptor mounts and what it says there.
///
/// A variant the client does not know decodes as [`Placement::Unrecognized`] and is
/// skipped, so an old client plus a new plugin degrades rather than breaking. That is
/// why a new surface never bumps [`SCHEMA_VERSION`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "surface", rename_all = "camelCase")]
pub enum Placement {
    SidebarSection {
        title: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        icon: Option<String>,
        #[serde(default)]
        collapsible: bool,
    },
    SidebarItem {
        /// The id of a sidebar section, contributed or built in.
        section: String,
        label: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        icon: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        badge: Option<Badge>,
    },
    /// A decoration on a session row, which is where the first real users live.
    SessionBadge {
        badge: Badge,
        /// Which sessions it applies to. Empty means every session.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        when_activity: Vec<String>,
    },
    ContextMenuItem {
        target: MenuTarget,
        label: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        icon: Option<String>,
        #[serde(default)]
        destructive: bool,
    },
    StatusBarItem {
        text: String,
        #[serde(default)]
        tone: Tone,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tooltip: Option<String>,
    },
    Command {
        title: String,
        /// A chord in the shell's own spelling, e.g. `cmd+shift+g`. Advisory: the
        /// shell refuses one that collides with a built-in rather than stealing it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        keybinding: Option<String>,
        #[serde(default = "yes")]
        in_palette: bool,
    },
    SettingsCard {
        title: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        subtitle: Option<String>,
        fields: Vec<SettingsField>,
    },
    /// Routing and filtering for one class of notification. juancode-2vlz's rules are
    /// this shape.
    NotificationRule {
        title: String,
        /// The event name the rule reacts to, e.g. `session.exit`.
        event: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        channel: Option<String>,
        #[serde(default)]
        muted: bool,
    },
    OracleSection {
        title: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        body: Option<String>,
    },
    #[serde(other)]
    Unrecognized,
}

fn yes() -> bool {
    true
}

impl Placement {
    /// The surface name as it goes over the wire. Used for `dump-config` and for a
    /// client's "do I render this" check.
    pub fn surface(&self) -> &'static str {
        match self {
            Self::SidebarSection { .. } => "sidebarSection",
            Self::SidebarItem { .. } => "sidebarItem",
            Self::SessionBadge { .. } => "sessionBadge",
            Self::ContextMenuItem { .. } => "contextMenuItem",
            Self::StatusBarItem { .. } => "statusBarItem",
            Self::Command { .. } => "command",
            Self::SettingsCard { .. } => "settingsCard",
            Self::NotificationRule { .. } => "notificationRule",
            Self::OracleSection { .. } => "oracleSection",
            Self::Unrecognized => "unrecognized",
        }
    }
}

/// One registered contribution, exactly as it travels to a client.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Contribution {
    /// Stable and unique. The address for activation, for `dump-config`, and for the
    /// client's diff between two snapshots.
    pub id: String,
    #[serde(flatten)]
    pub placement: Placement,
    /// Ties for a slot break by id, so the order never depends on mount order.
    #[serde(default)]
    pub sort_key: i32,
    /// What the contribution is allowed to see. Empty is the honest default.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub needs: BTreeSet<DataNeed>,
    /// The entry id of the plugin that registered it. Filled in by the registry, so a
    /// descriptor cannot claim to come from somewhere it does not.
    #[serde(default)]
    pub owner: String,
}

impl Contribution {
    pub fn new(id: impl Into<String>, placement: Placement) -> Self {
        Self {
            id: id.into(),
            placement,
            sort_key: 0,
            needs: BTreeSet::new(),
            owner: String::new(),
        }
    }

    pub fn sort_key(mut self, sort_key: i32) -> Self {
        self.sort_key = sort_key;
        self
    }

    pub fn needs(mut self, need: DataNeed) -> Self {
        self.needs.insert(need);
        self
    }
}

/// A client asking the daemon to run a contribution's action.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Activation {
    pub contribution: String,
    /// What the item was activated on: a session id, a project path, a PR number.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    /// Anything the surface collected, such as a settings card's edited fields.
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub payload: Value,
}

impl Activation {
    pub fn new(contribution: impl Into<String>) -> Self {
        Self {
            contribution: contribution.into(),
            target: None,
            payload: Value::Null,
        }
    }

    pub fn on(mut self, target: impl Into<String>) -> Self {
        self.target = Some(target.into());
        self
    }

    pub fn with(mut self, payload: Value) -> Self {
        self.payload = payload;
        self
    }
}

/// What came back. `Unhandled` is a real answer: the contribution exists but declares
/// no action, or the plugin that owned it has since unmounted.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "outcome", rename_all = "camelCase")]
pub enum ActivationOutcome {
    Handled {
        #[serde(default, skip_serializing_if = "Value::is_null")]
        result: Value,
    },
    Refused {
        reason: String,
    },
    Unhandled,
}

impl ActivationOutcome {
    pub fn handled() -> Self {
        Self::Handled {
            result: Value::Null,
        }
    }

    pub fn refused(reason: impl Into<String>) -> Self {
        Self::Refused {
            reason: reason.into(),
        }
    }
}

/// Reading data a descriptor never asked for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScopeError {
    pub contribution: String,
    pub need: DataNeed,
}

impl fmt::Display for ScopeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "contribution `{}` did not declare `{}`",
            self.contribution,
            self.need.as_str()
        )
    }
}

impl std::error::Error for ScopeError {}

/// What a handler is allowed to read, which is exactly what its descriptor declared.
///
/// The check is here rather than in a comment because an agent-authored plugin is the
/// case the model has to survive: a descriptor that wants a transcript has to say so
/// where a human reading `dump-config` can see it.
pub struct Scope {
    contribution: String,
    needs: BTreeSet<DataNeed>,
}

impl Scope {
    pub fn allows(&self, need: DataNeed) -> bool {
        self.needs.contains(&need)
    }

    /// Gate a read on the declaration. `Err` is the answer for anything undeclared.
    pub fn require(&self, need: DataNeed) -> Result<(), ScopeError> {
        if self.allows(need) {
            Ok(())
        } else {
            Err(ScopeError {
                contribution: self.contribution.clone(),
                need,
            })
        }
    }

    pub fn contribution(&self) -> &str {
        &self.contribution
    }
}

/// A plugin's answer to one activation. Runs on the daemon, never on the client.
pub type Handler = Arc<dyn Fn(&Activation, &Scope) -> ActivationOutcome + Send + Sync>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContributionTaken {
    pub id: String,
    pub held_by: String,
}

impl fmt::Display for ContributionTaken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "contribution `{}` is already registered by `{}`",
            self.id, self.held_by
        )
    }
}

impl std::error::Error for ContributionTaken {}

struct Slot {
    /// Monotonic, so a stale guard cannot evict an id someone has re-registered.
    seq: u64,
    contribution: Contribution,
    handler: Option<Handler>,
}

#[derive(Default)]
struct Inner {
    slots: BTreeMap<String, Slot>,
    /// Bumped on every add and every removal. A client that holds this number knows
    /// whether the snapshot it has is the current one.
    revision: u64,
    shutdown: bool,
}

/// Everything currently contributed, plus the revision it is a snapshot of.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub schema_version: u32,
    pub revision: u64,
    pub items: Vec<Contribution>,
}

/// Clone-cheap handle to the shared contribution registry.
#[derive(Clone, Default)]
pub struct ContributionRegistry {
    inner: Arc<Mutex<Inner>>,
}

static SEQ: AtomicU64 = AtomicU64::new(1);

impl ContributionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a descriptor for as long as the returned guard lives.
    ///
    /// `owner` is stamped on the descriptor here rather than taken from it: a plugin
    /// does not get to say it is somebody else.
    pub fn contribute(
        &self,
        owner: &str,
        contribution: Contribution,
    ) -> Result<Effect, ContributionTaken> {
        self.register(owner, contribution, None)
    }

    /// The same, with the action the owning plugin runs when a client activates it.
    pub fn contribute_with(
        &self,
        owner: &str,
        contribution: Contribution,
        handler: impl Fn(&Activation, &Scope) -> ActivationOutcome + Send + Sync + 'static,
    ) -> Result<Effect, ContributionTaken> {
        self.register(owner, contribution, Some(Arc::new(handler)))
    }

    fn register(
        &self,
        owner: &str,
        mut contribution: Contribution,
        handler: Option<Handler>,
    ) -> Result<Effect, ContributionTaken> {
        contribution.owner = owner.to_string();
        let id = contribution.id.clone();
        let seq = SEQ.fetch_add(1, Ordering::Relaxed);
        {
            let mut inner = self.lock();
            if inner.shutdown {
                return Ok(Effect::inert(format!("contribution:{id}")));
            }
            if let Some(existing) = inner.slots.get(&id) {
                return Err(ContributionTaken {
                    id,
                    held_by: existing.contribution.owner.clone(),
                });
            }
            inner.slots.insert(
                id.clone(),
                Slot {
                    seq,
                    contribution,
                    handler,
                },
            );
            inner.revision += 1;
        }
        tracing::debug!(id = %id, owner, "contribution registered");
        let weak: Weak<Mutex<Inner>> = Arc::downgrade(&self.inner);
        let taken = id.clone();
        Ok(Effect::new(format!("contribution:{id}"), move || {
            // A dead registry, or an id someone has since re-registered, means there
            // is nothing of ours left to take back.
            if let Some(inner) = weak.upgrade() {
                if let Ok(mut inner) = inner.lock() {
                    if inner.slots.get(&taken).is_some_and(|s| s.seq == seq) {
                        inner.slots.remove(&taken);
                        inner.revision += 1;
                        tracing::debug!(id = %taken, "contribution withdrawn");
                    }
                }
            }
        }))
    }

    /// Every contribution, in the one order every client must agree on.
    pub fn rows(&self) -> Vec<Contribution> {
        let mut rows: Vec<Contribution> = self
            .lock()
            .slots
            .values()
            .map(|s| s.contribution.clone())
            .collect();
        // Sort key first, id second. Never registration order: two plugins racing for
        // the same slot would otherwise draw in a different order on the next boot.
        rows.sort_by(|a, b| a.sort_key.cmp(&b.sort_key).then_with(|| a.id.cmp(&b.id)));
        rows
    }

    /// The rows for one surface, in the same order.
    pub fn rows_for(&self, surface: &str) -> Vec<Contribution> {
        self.rows()
            .into_iter()
            .filter(|c| c.placement.surface() == surface)
            .collect()
    }

    pub fn snapshot(&self) -> Snapshot {
        // Read the revision under the same lock generation as the rows, or a snapshot
        // could carry a number it does not match.
        let (revision, mut items) = {
            let inner = self.lock();
            (
                inner.revision,
                inner
                    .slots
                    .values()
                    .map(|s| s.contribution.clone())
                    .collect::<Vec<_>>(),
            )
        };
        items.sort_by(|a, b| a.sort_key.cmp(&b.sort_key).then_with(|| a.id.cmp(&b.id)));
        Snapshot {
            schema_version: SCHEMA_VERSION,
            revision,
            items,
        }
    }

    pub fn revision(&self) -> u64 {
        self.lock().revision
    }

    pub fn get(&self, id: &str) -> Option<Contribution> {
        self.lock().slots.get(id).map(|s| s.contribution.clone())
    }

    pub fn len(&self) -> usize {
        self.lock().slots.len()
    }

    pub fn is_empty(&self) -> bool {
        self.lock().slots.is_empty()
    }

    /// Run a contribution's action on the daemon.
    ///
    /// The handler is looked up and cloned out before it runs, so a handler that
    /// registers or withdraws a contribution of its own does not deadlock on the
    /// registry it was called from.
    pub fn activate(&self, activation: &Activation) -> ActivationOutcome {
        let found = {
            let inner = self.lock();
            inner.slots.get(&activation.contribution).map(|slot| {
                (
                    slot.handler.clone(),
                    slot.contribution.needs.clone(),
                    slot.contribution.id.clone(),
                )
            })
        };
        let Some((handler, needs, id)) = found else {
            return ActivationOutcome::Unhandled;
        };
        let Some(handler) = handler else {
            return ActivationOutcome::Unhandled;
        };
        let scope = Scope {
            contribution: id,
            needs,
        };
        handler(activation, &scope)
    }

    /// Withdraw everything and refuse further registrations. Guards dropped afterwards
    /// find their slot gone and do nothing.
    pub fn shutdown(&self) {
        let mut inner = self.lock();
        inner.shutdown = true;
        if !inner.slots.is_empty() {
            inner.slots.clear();
            inner.revision += 1;
        }
    }

    pub fn is_shutdown(&self) -> bool {
        self.lock().shutdown
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        // A poisoned lock means a handler panicked mid-activation; the map itself is
        // still sound, so keep serving rather than taking the daemon down with it.
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn badge(id: &str) -> Contribution {
        Contribution::new(
            id,
            Placement::SessionBadge {
                badge: Badge::new("stuck").tone(Tone::Warning),
                when_activity: vec!["waitingInput".into()],
            },
        )
    }

    #[test]
    fn a_contribution_is_gone_when_its_guard_is() {
        let reg = ContributionRegistry::new();
        {
            let _guard = reg.contribute("goal-tracker", badge("goal.phase")).unwrap();
            assert_eq!(reg.len(), 1);
            assert_eq!(reg.get("goal.phase").unwrap().owner, "goal-tracker");
        }
        assert!(reg.is_empty());
        assert!(reg.get("goal.phase").is_none());
    }

    #[test]
    fn two_plugins_cannot_claim_one_id() {
        let reg = ContributionRegistry::new();
        let _first = reg.contribute("goal-tracker", badge("goal.phase")).unwrap();
        let err = reg.contribute("impostor", badge("goal.phase")).unwrap_err();
        assert_eq!(err.held_by, "goal-tracker");
    }

    #[test]
    fn a_descriptor_cannot_claim_an_owner_it_does_not_have() {
        let reg = ContributionRegistry::new();
        let mut c = badge("goal.phase");
        c.owner = "somebody-else".into();
        let _guard = reg.contribute("goal-tracker", c).unwrap();
        assert_eq!(reg.get("goal.phase").unwrap().owner, "goal-tracker");
    }

    #[test]
    fn order_is_the_sort_key_then_the_id_never_registration_order() {
        let reg = ContributionRegistry::new();
        let _c = reg.contribute("c", badge("zebra").sort_key(0)).unwrap();
        let _a = reg.contribute("a", badge("alpha").sort_key(0)).unwrap();
        let _b = reg.contribute("b", badge("beta").sort_key(-5)).unwrap();
        let ids: Vec<String> = reg.rows().into_iter().map(|c| c.id).collect();
        assert_eq!(ids, ["beta", "alpha", "zebra"]);
    }

    #[test]
    fn the_revision_moves_on_every_add_and_every_removal() {
        let reg = ContributionRegistry::new();
        let start = reg.revision();
        let guard = reg.contribute("one", badge("a")).unwrap();
        let after_add = reg.revision();
        assert!(after_add > start);
        drop(guard);
        assert!(reg.revision() > after_add);
    }

    #[test]
    fn a_snapshot_carries_the_revision_it_is_a_snapshot_of() {
        let reg = ContributionRegistry::new();
        let _guard = reg.contribute("one", badge("a")).unwrap();
        let snap = reg.snapshot();
        assert_eq!(snap.revision, reg.revision());
        assert_eq!(snap.schema_version, SCHEMA_VERSION);
        assert_eq!(snap.items.len(), 1);
    }

    #[test]
    fn a_stale_guard_does_not_withdraw_a_re_registered_id() {
        let reg = ContributionRegistry::new();
        let first = reg.contribute("first", badge("a")).unwrap();
        drop(first);
        let _second = reg.contribute("second", badge("a")).unwrap();
        assert_eq!(reg.get("a").unwrap().owner, "second");
    }

    #[test]
    fn dropping_a_guard_after_shutdown_is_a_no_op() {
        let reg = ContributionRegistry::new();
        let guard = reg.contribute("one", badge("a")).unwrap();
        reg.shutdown();
        drop(guard);
        assert!(reg.is_empty());
        let late = reg.contribute("late", badge("b")).unwrap();
        assert!(!late.is_live());
        assert!(reg.is_empty());
    }

    #[test]
    fn activating_a_contribution_runs_the_owning_plugin_not_the_client() {
        let reg = ContributionRegistry::new();
        let _guard = reg
            .contribute_with("goal-tracker", badge("goal.phase"), |activation, _| {
                ActivationOutcome::Handled {
                    result: serde_json::json!({ "ran_on": activation.target }),
                }
            })
            .unwrap();
        let outcome = reg.activate(&Activation::new("goal.phase").on("sess-1"));
        assert_eq!(
            outcome,
            ActivationOutcome::Handled {
                result: serde_json::json!({ "ran_on": "sess-1" })
            }
        );
    }

    #[test]
    fn activating_an_unknown_or_actionless_contribution_is_answered_not_an_error() {
        let reg = ContributionRegistry::new();
        assert_eq!(
            reg.activate(&Activation::new("nobody")),
            ActivationOutcome::Unhandled
        );
        let _guard = reg.contribute("one", badge("a")).unwrap();
        assert_eq!(
            reg.activate(&Activation::new("a")),
            ActivationOutcome::Unhandled
        );
    }

    #[test]
    fn an_activation_after_the_plugin_unmounted_is_unhandled_rather_than_stale() {
        let reg = ContributionRegistry::new();
        let guard = reg
            .contribute_with("goal-tracker", badge("goal.phase"), |_, _| {
                ActivationOutcome::handled()
            })
            .unwrap();
        drop(guard);
        assert_eq!(
            reg.activate(&Activation::new("goal.phase")),
            ActivationOutcome::Unhandled
        );
    }

    #[test]
    fn a_handler_only_reads_what_its_descriptor_declared() {
        let reg = ContributionRegistry::new();
        let _guard = reg
            .contribute_with(
                "goal-tracker",
                badge("goal.phase").needs(DataNeed::SessionActivity),
                |_, scope| {
                    assert!(scope.require(DataNeed::SessionActivity).is_ok());
                    match scope.require(DataNeed::SessionTranscript) {
                        Err(e) => ActivationOutcome::refused(e.to_string()),
                        Ok(()) => ActivationOutcome::handled(),
                    }
                },
            )
            .unwrap();
        assert_eq!(
            reg.activate(&Activation::new("goal.phase")),
            ActivationOutcome::refused(
                "contribution `goal.phase` did not declare `session.transcript`"
            )
        );
    }

    #[test]
    fn a_surface_the_client_does_not_know_decodes_as_ignorable_rather_than_failing() {
        let json = serde_json::json!({
            "id": "from.the.future",
            "surface": "holographicOverlay",
            "sortKey": 3
        });
        let decoded: Contribution = serde_json::from_value(json).expect("degrade, not break");
        assert_eq!(decoded.placement, Placement::Unrecognized);
        assert_eq!(decoded.placement.surface(), "unrecognized");
        assert_eq!(decoded.sort_key, 3);
    }

    #[test]
    fn an_unknown_settings_field_leaves_the_rest_of_the_card_renderable() {
        let json = serde_json::json!({
            "id": "cfg",
            "surface": "settingsCard",
            "title": "Goals",
            "fields": [
                { "type": "toggle", "key": "on", "label": "Enabled", "value": true },
                { "type": "colorWheel", "key": "hue", "label": "Hue" }
            ]
        });
        let decoded: Contribution = serde_json::from_value(json).unwrap();
        let Placement::SettingsCard { fields, .. } = decoded.placement else {
            panic!("expected a settings card");
        };
        assert_eq!(fields.len(), 2);
        assert_eq!(fields[1], SettingsField::Unrecognized);
    }

    #[test]
    fn a_descriptor_round_trips_through_json_with_the_surface_as_the_tag() {
        let c = Contribution::new(
            "sidebar.goals",
            Placement::SidebarSection {
                title: "Goals".into(),
                icon: Some("target".into()),
                collapsible: true,
            },
        )
        .sort_key(10)
        .needs(DataNeed::ProjectSessions);
        let json = serde_json::to_value(&c).unwrap();
        assert_eq!(json["surface"], "sidebarSection");
        assert_eq!(json["needs"][0], "projectSessions");
        assert_eq!(serde_json::from_value::<Contribution>(json).unwrap(), c);
    }
}
