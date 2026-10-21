//! Chains: named, cross-project groups of related work.
//!
//! A chain is a tag. Its slug is its id and its display name at once (`auth-rewrite`),
//! so there is no second identifier to keep in step with the first and nothing to
//! rename: a slug is immutable for as long as the chain exists. What it groups are
//! *members* — agent sessions (an Oracle is one of those, distinguished by its cwd
//! and nothing else), tracked PRs, beads issues and Linear tickets — and an item is in
//! at most one chain. Tagging an item that is already in a chain moves it.
//!
//! The types here are the model and its rules. Where the rows live is
//! `juancoded-persistence::chain_store`, and who mutates them and tells every client is
//! `juancoded-server::chains`.

use serde::{Deserialize, Serialize};

/// The longest slug a chain may have. A badge draws the whole slug, so this is a
/// layout bound as much as a sanity one.
pub const MAX_SLUG_LEN: usize = 48;

/// Whether a chain is still being worked. A closed chain keeps its members — closing is
/// "this is done", not "forget this" — and can be reopened.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChainState {
    Active,
    Inactive,
}

impl ChainState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Inactive => "inactive",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "active" => Some(Self::Active),
            "inactive" => Some(Self::Inactive),
            _ => None,
        }
    }
}

/// What a member is. The `ref` that goes with it is the id that kind already has
/// everywhere else, never one minted for chains:
///
/// | kind | ref |
/// | --- | --- |
/// | `session` | the session id (Oracles included) |
/// | `tracked_pr` | the tracked PR's key, `<cwd>#<number>` (`TrackedPr::key`) |
/// | `beads` | the issue id, e.g. `juancode-dbo.1` |
/// | `linear` | the issue identifier, e.g. `ENG-123` |
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChainMemberKind {
    Session,
    TrackedPr,
    Beads,
    Linear,
}

impl ChainMemberKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Session => "session",
            Self::TrackedPr => "tracked_pr",
            Self::Beads => "beads",
            Self::Linear => "linear",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "session" => Some(Self::Session),
            "tracked_pr" => Some(Self::TrackedPr),
            "beads" => Some(Self::Beads),
            "linear" => Some(Self::Linear),
            _ => None,
        }
    }
}

/// One item in a chain.
///
/// `title` and `url` are a snapshot taken when the item was tagged, for the kinds this
/// daemon cannot look up by itself (a beads issue, a Linear ticket). A session's title
/// lives on its `SessionMeta` and is not copied here; a client draws the live one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChainMember {
    pub kind: ChainMemberKind,
    #[serde(rename = "ref")]
    pub ref_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// Epoch ms the item joined THIS chain. A move restamps it; re-tagging it into the
    /// chain it is already in does not.
    pub added_at: i64,
    /// Whether the work is finished, for the kinds whose state only a client can see:
    /// a beads issue or a Linear ticket that was closed, as the client last reported
    /// it. Always `false` for a session or a tracked PR — the daemon reads those itself
    /// (see [`MemberStatus`]) and storing a copy would be a second answer that drifts.
    /// On the wire only while `true`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub done: bool,
}

impl ChainMember {
    /// Whether the kind is one whose done-state a client reports, rather than one the
    /// daemon reads for itself.
    pub fn is_reported(kind: ChainMemberKind) -> bool {
        matches!(kind, ChainMemberKind::Beads | ChainMemberKind::Linear)
    }
}

/// What the daemon knows about a member it can see for itself.
///
/// The auto-close rule (`juancoded-server::chains`) is "every member is finished", and
/// this is the per-kind meaning of finished, kept beside the model so the rule is
/// testable without a registry or a poller.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemberStatus {
    /// Still being worked, or not knowable — which is treated the same, so a chain is
    /// never closed on a guess.
    Live,
    Finished,
}

impl Chain {
    /// Whether this chain is one auto-close should close: active, not empty, and every
    /// member finished. An empty chain never qualifies, so a chain that was just
    /// created (or emptied) stays open until somebody closes it.
    pub fn all_finished(&self, status: impl Fn(&ChainMember) -> MemberStatus) -> bool {
        self.state == ChainState::Active
            && !self.members.is_empty()
            && self
                .members
                .iter()
                .all(|m| status(m) == MemberStatus::Finished)
    }
}

/// A chain and everything in it, members in the order they joined.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Chain {
    pub slug: String,
    pub state: ChainState,
    pub created_at: i64,
    /// When it was last closed. `None` while active; a reopen clears it.
    pub closed_at: Option<i64>,
    pub members: Vec<ChainMember>,
}

/// Why a slug was refused. The `code` is what goes on the wire.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SlugError(pub &'static str);

/// Check a slug: lowercase ASCII letters and digits in dash-separated words, no
/// leading, trailing or doubled dash, at most [`MAX_SLUG_LEN`] long.
///
/// Refused rather than normalised. A client that sent `Auth Rewrite` and got back
/// `auth-rewrite` would hold a name it never chose, and two clients normalising
/// differently is exactly the disagreement an immutable id exists to rule out. The
/// normalising belongs in the UI that offers the name, before it is a name.
pub fn validate_slug(slug: &str) -> Result<(), SlugError> {
    if slug.is_empty() {
        return Err(SlugError("chain-slug-empty"));
    }
    if slug.len() > MAX_SLUG_LEN {
        return Err(SlugError("chain-slug-too-long"));
    }
    let words_ok = slug.split('-').all(|word| {
        !word.is_empty()
            && word
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    });
    if !words_ok {
        return Err(SlugError("chain-slug-invalid"));
    }
    Ok(())
}

/// Make a slug out of free text, for a chain the daemon names itself (a dispatch from a
/// session in no chain starts one, named after that session). Lowercase ASCII words,
/// everything else a separator, cut at a word boundary to leave `room` bytes of
/// [`MAX_SLUG_LEN`] for a `-2` style suffix. `None` when nothing of the text survives.
pub fn slug_from_text(text: &str, room: usize) -> Option<String> {
    let limit = MAX_SLUG_LEN.saturating_sub(room);
    let mut slug = String::new();
    for word in text
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|w| !w.is_empty())
    {
        let word = word.to_ascii_lowercase();
        let needed = if slug.is_empty() {
            word.len()
        } else {
            word.len() + 1
        };
        if slug.len() + needed > limit {
            if slug.is_empty() {
                slug.push_str(&word[..limit]);
            }
            break;
        }
        if !slug.is_empty() {
            slug.push('-');
        }
        slug.push_str(&word);
    }
    (!slug.is_empty()).then_some(slug)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn free_text_becomes_a_valid_slug_cut_at_a_word() {
        assert_eq!(
            slug_from_text("Fix the Auth_Rewrite (v2)!", 4).as_deref(),
            Some("fix-the-auth-rewrite-v2")
        );
        assert_eq!(slug_from_text("  ¿qué?  ", 4).as_deref(), Some("qu"));
        assert_eq!(slug_from_text("—", 4), None);
        let long = "word ".repeat(30);
        let slug = slug_from_text(&long, 4).unwrap();
        assert!(
            slug.len() <= MAX_SLUG_LEN - 4 && !slug.ends_with('-'),
            "{slug}"
        );
        let one = slug_from_text(&"a".repeat(100), 4).unwrap();
        assert_eq!(one.len(), MAX_SLUG_LEN - 4);
        for s in [slug, one] {
            assert_eq!(validate_slug(&s), Ok(()));
        }
    }

    #[test]
    fn a_slug_is_lowercase_words_joined_by_single_dashes() {
        for ok in ["auth-rewrite", "a", "v2", "q4-2026-launch", "x-1-y"] {
            assert_eq!(validate_slug(ok), Ok(()), "{ok}");
        }
        for (bad, code) in [
            ("", "chain-slug-empty"),
            ("Auth-Rewrite", "chain-slug-invalid"),
            ("auth rewrite", "chain-slug-invalid"),
            ("-auth", "chain-slug-invalid"),
            ("auth-", "chain-slug-invalid"),
            ("auth--rewrite", "chain-slug-invalid"),
            ("auth_rewrite", "chain-slug-invalid"),
            ("authé", "chain-slug-invalid"),
        ] {
            assert_eq!(validate_slug(bad), Err(SlugError(code)), "{bad:?}");
        }
        assert_eq!(
            validate_slug(&"a".repeat(MAX_SLUG_LEN + 1)),
            Err(SlugError("chain-slug-too-long"))
        );
        assert_eq!(validate_slug(&"a".repeat(MAX_SLUG_LEN)), Ok(()));
    }

    #[test]
    fn kinds_and_states_round_trip_through_their_wire_spelling() {
        for kind in [
            ChainMemberKind::Session,
            ChainMemberKind::TrackedPr,
            ChainMemberKind::Beads,
            ChainMemberKind::Linear,
        ] {
            assert_eq!(ChainMemberKind::parse(kind.as_str()), Some(kind));
            assert_eq!(
                serde_json::to_value(kind).unwrap(),
                serde_json::Value::String(kind.as_str().into())
            );
        }
        for state in [ChainState::Active, ChainState::Inactive] {
            assert_eq!(ChainState::parse(state.as_str()), Some(state));
        }
        assert_eq!(ChainMemberKind::parse("pr"), None);
    }

    #[test]
    fn a_member_serialises_ref_under_its_wire_name() {
        let member = ChainMember {
            kind: ChainMemberKind::Beads,
            ref_id: "juancode-dbo.1".into(),
            title: Some("Chains core".into()),
            url: None,
            added_at: 7,
            done: false,
        };
        let v = serde_json::to_value(&member).unwrap();
        assert_eq!(
            v,
            serde_json::json!({
                "kind": "beads", "ref": "juancode-dbo.1", "title": "Chains core", "addedAt": 7
            })
        );
        let done = ChainMember {
            done: true,
            ..member
        };
        assert_eq!(serde_json::to_value(&done).unwrap()["done"], true);
    }

    #[test]
    fn only_an_active_chain_with_every_member_finished_qualifies_for_auto_close() {
        let member = |ref_id: &str| ChainMember {
            kind: ChainMemberKind::Beads,
            ref_id: ref_id.into(),
            title: None,
            url: None,
            added_at: 1,
            done: false,
        };
        let mut chain = Chain {
            slug: "a".into(),
            state: ChainState::Active,
            created_at: 1,
            closed_at: None,
            members: Vec::new(),
        };
        let finished = |_: &ChainMember| MemberStatus::Finished;
        assert!(
            !chain.all_finished(finished),
            "an empty chain never closes itself"
        );
        chain.members = vec![member("x-1"), member("x-2")];
        assert!(chain.all_finished(finished));
        assert!(!chain.all_finished(|m| if m.ref_id == "x-2" {
            MemberStatus::Live
        } else {
            MemberStatus::Finished
        }));
        chain.state = ChainState::Inactive;
        assert!(
            !chain.all_finished(finished),
            "a closed chain is not closed twice"
        );
    }
}
