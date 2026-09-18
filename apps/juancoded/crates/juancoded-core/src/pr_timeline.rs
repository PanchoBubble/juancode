//! The conversation, arranged the way it is read.
//!
//! A port of `JuancodeServices/PrTimeline.swift`. Three pure decisions live here, and
//! all three exist because GitHub's data model and GitHub's Conversation tab are not
//! the same shape:
//!
//!  1. Comments, review verdicts and commits arrive in three separate lists and are
//!     read as one chronology.
//!  2. A review's inline comments are *turns in threads*, not events of their own, so a
//!     reply has to render under the thread it belongs to rather than as its own card
//!     re-printing the same `path:line` and the same diff hunk.
//!  3. Once the replies are folded away, some review events have nothing left to show,
//!     and an empty card is worse than no card.
//!
//! It runs in the daemon rather than in the client because the phone and the desktop
//! must not disagree about the order of two comments, and because "is this card empty"
//! is a question with one right answer, not a rendering preference.

use serde::{Deserialize, Serialize};

use crate::gh::PrCheckRun;
use crate::gh_convo::{
    PrCommit, PrConversation, PrConversationComment, PrReviewItem, PrReviewThread,
};

/// One entry of the merged timeline. Inline threads are deliberately not in here: they
/// stay grouped under the review that opened them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum PrTimelineItem {
    Comment {
        /// Namespaced, so a comment, a review and a commit can never collide even if
        /// GitHub handed back overlapping node ids.
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        created_at: Option<i64>,
        comment: PrConversationComment,
    },
    Review {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        created_at: Option<i64>,
        review: PrReviewItem,
        /// The threads this review *starts*, each with its whole comment list — what
        /// the card renders under the verdict.
        thread_groups: Vec<PrThreadGroup>,
    },
    Commit {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        created_at: Option<i64>,
        commit: PrCommit,
    },
}

impl PrTimelineItem {
    pub fn id(&self) -> &str {
        match self {
            Self::Comment { id, .. } | Self::Review { id, .. } | Self::Commit { id, .. } => id,
        }
    }

    pub fn created_at(&self) -> Option<i64> {
        match self {
            Self::Comment { created_at, .. }
            | Self::Review { created_at, .. }
            | Self::Commit { created_at, .. } => *created_at,
        }
    }
}

/// One inline thread as the conversation renders it: the anchor, whether it has been
/// dealt with, the id a reply must target, and every comment in it — root first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrThreadGroup {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<i64>,
    pub is_resolved: bool,
    pub is_outdated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reply_target_id: Option<i64>,
    /// Never empty: a group with no comments is not a thread anybody opened.
    pub comments: Vec<PrConversationComment>,
}

/// Merge comments, review verdicts and commits into one chronology.
///
/// Undated items sort last and keep their input order, as do ties. That determinism is
/// the point: two clients reading the same conversation a second apart must not draw
/// two different orders, and a garbage `createdAt` must not shuffle the rest.
pub fn pr_timeline(
    comments: &[PrConversationComment],
    reviews: &[PrReviewItem],
    commits: &[PrCommit],
    threads: &[PrReviewThread],
) -> Vec<PrTimelineItem> {
    let mut items: Vec<PrTimelineItem> = Vec::new();
    for c in comments {
        items.push(PrTimelineItem::Comment {
            id: format!("comment:{}", c.id),
            created_at: c.created_at,
            comment: c.clone(),
        });
    }
    for r in reviews {
        items.push(PrTimelineItem::Review {
            id: format!("review:{}", r.id),
            created_at: r.created_at,
            thread_groups: review_thread_groups(r, threads),
            review: r.clone(),
        });
    }
    for c in commits {
        items.push(PrTimelineItem::Commit {
            id: format!("commit:{}", c.oid),
            created_at: c.committed_date,
            commit: c.clone(),
        });
    }
    // Stable sort on the dated items only, with the undated pushed to the back: Rust's
    // sort is stable, so input order survives every tie without an index to carry.
    items.sort_by(|a, b| match (a.created_at(), b.created_at()) {
        (Some(x), Some(y)) => x.cmp(&y),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => std::cmp::Ordering::Equal,
    });
    items
}

/// The timeline of a fetched conversation, with the review events that would draw as an
/// empty card dropped. Comments and commits always survive.
pub fn pr_visible_timeline(conversation: &PrConversation) -> Vec<PrTimelineItem> {
    pr_timeline(
        &conversation.issue_comments,
        &conversation.reviews,
        &conversation.commits,
        &conversation.threads,
    )
    .into_iter()
    .filter(|item| match item {
        PrTimelineItem::Review {
            review,
            thread_groups,
            ..
        } => review_has_visible_content(review, thread_groups),
        _ => true,
    })
    .collect()
}

/// The inline threads a review *starts*, each carrying its full comment list.
///
/// A review comment that only replies to a thread an earlier review opened yields
/// nothing here — it renders nested under that thread's root instead. Without this,
/// every turn of a back-and-forth became its own card, re-printing the same `path:line`
/// and the same diff hunk: the thread was on screen three times over with nothing to
/// say the three cards were one conversation.
pub fn review_thread_groups(
    review: &PrReviewItem,
    threads: &[PrReviewThread],
) -> Vec<PrThreadGroup> {
    let mut out = Vec::new();
    for c in &review.comments {
        let owning = threads
            .iter()
            .find(|t| t.comments.iter().any(|tc| tc.id == c.id));
        let Some(t) = owning else {
            // No thread carries it — a shape GitHub should not hand back. Render it
            // alone rather than drop a real comment on the floor.
            out.push(PrThreadGroup {
                id: c.id.clone(),
                path: c.path.clone(),
                line: c.line,
                is_resolved: false,
                is_outdated: false,
                reply_target_id: c.database_id,
                comments: vec![c.clone()],
            });
            continue;
        };
        // A reply: its root already renders the whole thread, this comment included.
        if t.comments.first().map(|f| f.id.as_str()) != Some(c.id.as_str()) {
            continue;
        }
        out.push(PrThreadGroup {
            id: t.id.clone(),
            path: if t.path.is_empty() {
                c.path.clone()
            } else {
                Some(t.path.clone())
            },
            line: t.line.or(c.line),
            is_resolved: t.is_resolved,
            is_outdated: t.is_outdated,
            reply_target_id: t.reply_target_id(),
            comments: t.comments.clone(),
        });
    }
    out
}

/// Whether a review event still has anything to show once its replies have been folded
/// into their threads: a summary body, a reaction, a thread it started, or a verdict
/// that says something on its own. A bare `COMMENTED` review carrying only replies
/// would draw as an empty card, and the replies are already visible in their threads.
pub fn review_has_visible_content(review: &PrReviewItem, groups: &[PrThreadGroup]) -> bool {
    if !review.body.trim().is_empty() || !review.reactions.is_empty() || !groups.is_empty() {
        return true;
    }
    !matches!(
        review.state.to_uppercase().as_str(),
        "COMMENTED" | "PENDING" | ""
    )
}

/// The coarse outcome a checks row draws: green tick, red cross, orange spinner, grey
/// dash.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PrCheckOutcome {
    Pass,
    Fail,
    Pending,
    Skipped,
}

/// Collapse a check run's gh `bucket` into the row outcome, falling back to the raw
/// `state` for the older commit-status shape that has no bucket. Failure defers to
/// [`PrCheckRun::failed`], so the icon and the "is CI red" answer can never disagree.
pub fn check_outcome(run: &PrCheckRun) -> PrCheckOutcome {
    if run.failed() {
        return PrCheckOutcome::Fail;
    }
    match run.bucket.as_str() {
        "pass" => return PrCheckOutcome::Pass,
        "skipping" | "cancel" => return PrCheckOutcome::Skipped,
        "pending" => return PrCheckOutcome::Pending,
        _ => {}
    }
    match run.state.as_str() {
        "SUCCESS" => PrCheckOutcome::Pass,
        "SKIPPED" | "NEUTRAL" | "CANCELLED" => PrCheckOutcome::Skipped,
        _ => PrCheckOutcome::Pending,
    }
}

/// The fixtures both test modules below build conversations out of.
#[cfg(test)]
mod tests_support {
    use super::*;

    pub(super) fn comment(id: &str, at: Option<i64>) -> PrConversationComment {
        PrConversationComment {
            id: id.into(),
            database_id: None,
            author: "alice".into(),
            author_avatar_url: None,
            body: String::new(),
            created_at: at,
            url: String::new(),
            path: None,
            line: None,
            diff_hunk: None,
            reactions: Vec::new(),
        }
    }

    pub(super) fn inline(id: &str, path: &str, line: i64, db: i64) -> PrConversationComment {
        PrConversationComment {
            path: Some(path.into()),
            line: Some(line),
            database_id: Some(db),
            ..comment(id, Some(0))
        }
    }

    pub(super) fn review(id: &str, state: &str, at: Option<i64>) -> PrReviewItem {
        PrReviewItem {
            id: id.into(),
            author: "bob".into(),
            author_avatar_url: None,
            state: state.into(),
            body: String::new(),
            created_at: at,
            url: String::new(),
            comments: Vec::new(),
            reactions: Vec::new(),
        }
    }

    pub(super) fn commit(oid: &str, at: Option<i64>) -> PrCommit {
        PrCommit {
            oid: oid.into(),
            abbreviated_oid: oid.chars().take(7).collect(),
            message_headline: String::new(),
            author: String::new(),
            committed_date: at,
        }
    }

    pub(super) fn thread(id: &str, resolved: bool, comments: Vec<PrConversationComment>) -> PrReviewThread {
        PrReviewThread {
            id: id.into(),
            is_resolved: resolved,
            is_outdated: false,
            path: "Sources/App/Main.swift".into(),
            line: Some(42),
            comments,
        }
    }

}

#[cfg(test)]
mod tests {
    use super::tests_support::*;
    use super::*;

    #[test]
    fn three_lists_become_one_chronology() {
        let items = pr_timeline(
            &[comment("c1", Some(300)), comment("c2", Some(100))],
            &[review("r1", "APPROVED", Some(200))],
            &[commit("abc1234", Some(50))],
            &[],
        );
        assert_eq!(
            items.iter().map(PrTimelineItem::id).collect::<Vec<_>>(),
            vec!["commit:abc1234", "comment:c2", "review:r1", "comment:c1"]
        );
    }

    /// Determinism, twice over: an unreadable date must not shuffle the rest, and two
    /// events GitHub stamped the same millisecond must not swap between two reads.
    #[test]
    fn undated_items_sort_last_and_ties_keep_the_order_they_came_in() {
        let items = pr_timeline(
            &[comment("c1", None), comment("c2", Some(100))],
            &[review("r1", "APPROVED", None)],
            &[],
            &[],
        );
        assert_eq!(
            items.iter().map(PrTimelineItem::id).collect::<Vec<_>>(),
            vec!["comment:c2", "comment:c1", "review:r1"]
        );

        let tied = pr_timeline(
            &[comment("c1", Some(5)), comment("c2", Some(5))],
            &[review("r1", "APPROVED", Some(5))],
            &[commit("abc1234", Some(5))],
            &[],
        );
        assert_eq!(
            tied.iter().map(PrTimelineItem::id).collect::<Vec<_>>(),
            vec!["comment:c1", "comment:c2", "review:r1", "commit:abc1234"],
            "comments, then reviews, then commits — the input order, every time"
        );
    }

    /// The ids are namespaced because the three kinds come from three GraphQL
    /// connections and nothing guarantees their ids are distinct from each other.
    #[test]
    fn an_id_says_which_kind_it_is() {
        let items = pr_timeline(
            &[comment("same", Some(1))],
            &[review("same", "APPROVED", Some(2))],
            &[commit("same", Some(3))],
            &[],
        );
        assert_eq!(
            items.iter().map(PrTimelineItem::id).collect::<Vec<_>>(),
            vec!["comment:same", "review:same", "commit:same"]
        );
    }

    #[test]
    fn a_reply_renders_under_its_thread_root_rather_than_as_its_own_card() {
        let root = inline("RC_1", "Sources/App/Main.swift", 42, 222);
        let reply = inline("RC_2", "Sources/App/Main.swift", 42, 333);
        let t = thread("RT_1", false, vec![root.clone(), reply.clone()]);

        let opening = PrReviewItem {
            comments: vec![root.clone()],
            ..review("R1", "CHANGES_REQUESTED", Some(1))
        };
        let groups = review_thread_groups(&opening, &[t.clone()]);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].id, "RT_1");
        assert_eq!(
            groups[0].comments.len(),
            2,
            "the root's card is the whole thread"
        );
        assert_eq!(groups[0].reply_target_id, Some(222));

        let replying = PrReviewItem {
            comments: vec![reply],
            ..review("R2", "COMMENTED", Some(2))
        };
        assert!(
            review_thread_groups(&replying, &[t]).is_empty(),
            "the reply is already on screen inside its thread"
        );
    }

    /// The fallback matters more than it looks: a comment GitHub reports without a
    /// thread would otherwise vanish from the review that made it.
    #[test]
    fn a_comment_no_thread_claims_still_renders_alone() {
        let orphan = inline("RC_9", "a.txt", 3, 999);
        let r = PrReviewItem {
            comments: vec![orphan],
            ..review("R1", "COMMENTED", Some(1))
        };
        let groups = review_thread_groups(&r, &[]);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].id, "RC_9");
        assert_eq!(groups[0].path.as_deref(), Some("a.txt"));
        assert_eq!(groups[0].reply_target_id, Some(999));
        assert!(!groups[0].is_resolved);
    }

    #[test]
    fn a_group_carries_the_threads_own_resolution_not_the_reviews() {
        let root = inline("RC_1", "Sources/App/Main.swift", 42, 222);
        let t = thread("RT_1", true, vec![root.clone()]);
        let r = PrReviewItem {
            comments: vec![root],
            ..review("R1", "CHANGES_REQUESTED", Some(1))
        };
        let groups = review_thread_groups(&r, &[t]);
        assert!(
            groups[0].is_resolved,
            "the thread was resolved, so the card says so"
        );
        assert_eq!(groups[0].line, Some(42));
    }

    #[test]
    fn a_review_with_nothing_left_to_show_leaves_the_timeline() {
        let root = inline("RC_1", "Sources/App/Main.swift", 42, 222);
        let reply = inline("RC_2", "Sources/App/Main.swift", 42, 333);
        let conv = PrConversation {
            state: "OPEN".into(),
            body: String::new(),
            issue_comments: vec![comment("IC_1", Some(10))],
            reviews: vec![
                PrReviewItem {
                    comments: vec![root.clone()],
                    ..review("R1", "CHANGES_REQUESTED", Some(20))
                },
                PrReviewItem {
                    comments: vec![reply.clone()],
                    ..review("R2", "COMMENTED", Some(30))
                },
                PrReviewItem {
                    body: "looks good".into(),
                    ..review("R3", "COMMENTED", Some(40))
                },
                review("R4", "APPROVED", Some(50)),
            ],
            threads: vec![thread("RT_1", false, vec![root, reply])],
            commits: Vec::new(),
        };
        assert_eq!(
            pr_visible_timeline(&conv)
                .iter()
                .map(PrTimelineItem::id)
                .collect::<Vec<_>>(),
            vec!["comment:IC_1", "review:R1", "review:R3", "review:R4"],
            "R2 is the record of a reply and has no card of its own"
        );
    }

    fn run(bucket: &str, state: &str) -> PrCheckRun {
        PrCheckRun {
            name: "build".into(),
            state: state.into(),
            bucket: bucket.into(),
            link: String::new(),
        }
    }

    #[test]
    fn a_checks_row_reads_the_bucket_first_and_the_state_only_when_there_is_none() {
        assert_eq!(check_outcome(&run("pass", "SUCCESS")), PrCheckOutcome::Pass);
        assert_eq!(check_outcome(&run("fail", "FAILURE")), PrCheckOutcome::Fail);
        assert_eq!(check_outcome(&run("pending", "")), PrCheckOutcome::Pending);
        assert_eq!(check_outcome(&run("skipping", "")), PrCheckOutcome::Skipped);
        assert_eq!(check_outcome(&run("cancel", "")), PrCheckOutcome::Skipped);
        // No bucket: the legacy commit-status shape.
        assert_eq!(check_outcome(&run("", "SUCCESS")), PrCheckOutcome::Pass);
        assert_eq!(check_outcome(&run("", "NEUTRAL")), PrCheckOutcome::Skipped);
        assert_eq!(check_outcome(&run("", "ERROR")), PrCheckOutcome::Fail);
        assert_eq!(
            check_outcome(&run("", "SOMETHING_NEW")),
            PrCheckOutcome::Pending,
            "a state this core has never seen is still running, not passing"
        );
    }
}

/// The wire spelling. A tagged enum renames its VARIANTS with `rename_all`, not its
/// fields, so an item can be perfectly correct and still reach a client as
/// `created_at` and `thread_groups` — which is a timeline that draws in the wrong
/// order and a review with no thread under it, from a core whose own tests all pass.
#[cfg(test)]
mod wire_tests {
    use super::tests_support::*;
    use super::*;

    #[test]
    fn every_key_a_client_reads_is_camel_case() {
        let items = pr_timeline(
            &[comment("c1", Some(10))],
            &[review("r1", "APPROVED", Some(20))],
            &[commit("abc1234", Some(30))],
            &[],
        );
        let json = serde_json::to_string(&items).expect("serialises");
        for key in ["\"kind\"", "\"createdAt\"", "\"threadGroups\"", "\"comment\""] {
            assert!(json.contains(key), "missing {key} in {json}");
        }
        assert!(
            !json.contains("created_at") && !json.contains("thread_groups"),
            "a snake_case key reached the wire: {json}"
        );
    }
}
