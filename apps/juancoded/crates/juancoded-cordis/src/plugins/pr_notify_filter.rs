use crate::events::{PrNotify, PrNotifyCandidate, PrNotifyKind, PrNotifyPass};
use crate::plugin::{Context, Plugin};

/// GitHub Desktop's notification rules, as a row in the tree (juancode-2vlz).
///
/// The tracked-PR poller pings on raw new activity, which on a busy repo is a Telegram
/// message per review comment on a PR you are not even the author of. GitHub Desktop
/// solved the same problem in `app/src/lib/valid-notification-pull-request-review.ts`
/// and `lib/notifications` (MIT), and its four rules are ported here:
///
///  1. Only PRs the viewer authored. Somebody else's PR getting a review is news for
///     them, not for you, and the tracked list is not a review queue.
///  2. Only the most recent review. A pass that finds three reviews at once found a
///     reviewer working through a file, not three decisions.
///  3. Dedupe repeats. The poll is level-triggered for the cases the engine raises, so
///     the same sentence would otherwise arrive on every pass forever.
///  4. Skip events the viewer caused. Half of this already lives in
///     `classify_pr_activity`, which filters new comments and reviews by author; this
///     catches the rest, which is anything the engine raises with an actor on it.
///
/// A plugin rather than a branch in `tracked_prs.rs`, and that is the interesting part.
/// These are one person's rules about their own inbox: somebody who tracks PRs they are
/// reviewing rather than authoring wants rule 1 off, and the answer to that should be
/// `disabled = true` on an entry rather than a rebuild. Registration is reversible, so
/// unmounting the row restores exactly the poller's old behaviour — every candidate
/// notified — with nothing left behind.
///
/// Rule 4 is deliberately NOT applied to [`PrNotifyKind::Engine`]: the engine's own
/// complaints ("could not reach the agent") are caused by the viewer in the sense that
/// they are about the viewer's session, and suppressing them would silence exactly the
/// failures nobody else is going to report.
pub struct PrNotifyFilter;

impl Plugin for PrNotifyFilter {
    fn name(&self) -> &'static str {
        "pr-notify-filter"
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        // Each rule is a flag, so a tree can keep the dedupe and drop the authored-only
        // rule without a second plugin.
        let config = ctx.config().clone();
        let flag = move |key: &str| config.get(key).and_then(|v| v.as_bool()).unwrap_or(true);
        let authored_only = flag("authoredOnly");
        let latest_review_only = flag("latestReviewOnly");
        let dedupe = flag("dedupe");
        let skip_self = flag("skipSelf");

        ctx.around::<PrNotify, _>("pr-notify.desktop-rules", move |pass, next| {
            let kept = filter(pass, authored_only, latest_review_only, dedupe, skip_self);
            pass.candidates = kept;
            next.run(pass)
        });
        Ok(())
    }
}

/// The four rules, in the order they get cheapest. Pure, so each one is testable on its
/// own and the reason a notification vanished is always recoverable from `notes`.
fn filter(
    pass: &mut PrNotifyPass,
    authored_only: bool,
    latest_review_only: bool,
    dedupe: bool,
    skip_self: bool,
) -> Vec<PrNotifyCandidate> {
    // Rule 1, and it takes the whole pass rather than a candidate: a PR that is not
    // yours has nothing in it worth pinging you about.
    //
    // Applied only when both logins are known. An empty viewer means `gh` could not say
    // who is signed in, and filtering on that would silence every notification on a
    // machine that is merely not authenticated — the loudest possible failure mode for
    // a rule whose whole job is to be quiet.
    if authored_only
        && !pass.viewer.is_empty()
        && !pass.author.is_empty()
        && pass.viewer != pass.author
    {
        pass.notes.push(format!(
            "pr-notify: dropped {} on #{} — authored by @{}, not the viewer",
            pass.candidates.len(),
            pass.pr_number,
            pass.author
        ));
        return Vec::new();
    }

    // Rule 2: among the reviews in ONE pass, only the last survives. Everything that is
    // not a review is untouched — red CI and a merge are not opinions that supersede
    // each other.
    let last_review = latest_review_only
        .then(|| {
            pass.candidates
                .iter()
                .rposition(|c| c.kind == PrNotifyKind::Review)
        })
        .flatten();

    let mut kept = Vec::new();
    for (index, candidate) in pass.candidates.iter().enumerate() {
        if let Some(last) = last_review {
            if candidate.kind == PrNotifyKind::Review && index != last {
                pass.notes.push(format!(
                    "pr-notify: superseded review — {}",
                    candidate.message
                ));
                continue;
            }
        }
        // Rule 4. The engine's own complaints are exempt: see the type note.
        if skip_self
            && candidate.kind != PrNotifyKind::Engine
            && !pass.viewer.is_empty()
            && candidate.actor == pass.viewer
        {
            pass.notes.push(format!(
                "pr-notify: the viewer caused it — {}",
                candidate.message
            ));
            continue;
        }
        // Rule 3, against what is already open AND against what this same pass has
        // already kept: a pass that produced the same sentence twice is one repeat the
        // open list has not heard about yet.
        if dedupe
            && (pass.already_open.contains(&candidate.message)
                || kept
                    .iter()
                    .any(|k: &PrNotifyCandidate| k.message == candidate.message))
        {
            pass.notes
                .push(format!("pr-notify: already said — {}", candidate.message));
            continue;
        }
        kept.push(candidate.clone());
    }
    kept
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(kind: PrNotifyKind, message: &str, actor: &str) -> PrNotifyCandidate {
        PrNotifyCandidate {
            kind,
            message: message.into(),
            actor: actor.into(),
            review_id: None,
        }
    }

    fn pass(candidates: Vec<PrNotifyCandidate>) -> PrNotifyPass {
        PrNotifyPass {
            tracked_id: "/tmp#7".into(),
            pr_number: 7,
            viewer: "octocat".into(),
            author: "octocat".into(),
            already_open: Vec::new(),
            candidates,
            notes: Vec::new(),
        }
    }

    fn messages(kept: &[PrNotifyCandidate]) -> Vec<&str> {
        kept.iter().map(|c| c.message.as_str()).collect()
    }

    fn all(p: &mut PrNotifyPass) -> Vec<PrNotifyCandidate> {
        filter(p, true, true, true, true)
    }

    #[test]
    fn somebody_elses_pr_has_nothing_in_it_to_ping_you_about() {
        let mut p = PrNotifyPass {
            author: "hubber".into(),
            ..pass(vec![
                candidate(PrNotifyKind::Review, "@hubber requested changes", "hubber"),
                candidate(PrNotifyKind::Ci, "CI went red", ""),
            ])
        };
        assert!(all(&mut p).is_empty());
        assert!(p.notes[0].contains("authored by @hubber"));
    }

    /// The loudest possible failure of a quieting rule: a machine where `gh` is merely
    /// not signed in must not go silent.
    #[test]
    fn a_viewer_this_core_cannot_name_is_not_a_reason_to_go_quiet() {
        let mut p = PrNotifyPass {
            viewer: String::new(),
            author: "hubber".into(),
            ..pass(vec![candidate(PrNotifyKind::Ci, "CI went red", "")])
        };
        assert_eq!(messages(&all(&mut p)), vec!["CI went red"]);

        let mut unknown_author = PrNotifyPass {
            author: String::new(),
            ..pass(vec![candidate(PrNotifyKind::Ci, "CI went red", "")])
        };
        assert_eq!(messages(&all(&mut unknown_author)), vec!["CI went red"]);
    }

    /// A reviewer working through a file leaves three reviews in one pass. That is one
    /// reviewer, not three decisions.
    #[test]
    fn only_the_last_review_of_a_pass_survives_and_nothing_else_is_touched() {
        let mut p = pass(vec![
            candidate(PrNotifyKind::Review, "@a commented", "a"),
            candidate(PrNotifyKind::Ci, "CI went red", ""),
            candidate(PrNotifyKind::Review, "@b requested changes", "b"),
            candidate(PrNotifyKind::Comment, "1 new comment", "b"),
        ]);
        assert_eq!(
            messages(&all(&mut p)),
            vec!["CI went red", "@b requested changes", "1 new comment"],
            "the earlier review goes; a comment and a CI result are not opinions"
        );
        assert!(p.notes.iter().any(|n| n.contains("superseded review")));
    }

    #[test]
    fn a_sentence_already_open_is_not_said_again() {
        let mut p = PrNotifyPass {
            already_open: vec!["could not reach the agent".into()],
            ..pass(vec![
                candidate(PrNotifyKind::Engine, "could not reach the agent", ""),
                candidate(PrNotifyKind::Ci, "CI went red", ""),
                candidate(PrNotifyKind::Ci, "CI went red", ""),
            ])
        };
        assert_eq!(
            messages(&all(&mut p)),
            vec!["CI went red"],
            "the open one is dropped, and so is the pass's own repeat of a new one"
        );
    }

    #[test]
    fn what_the_viewer_did_themselves_is_not_news_to_them() {
        let mut p = pass(vec![
            candidate(PrNotifyKind::Comment, "1 new comment", "octocat"),
            candidate(
                PrNotifyKind::Comment,
                "1 new comment from @hubber",
                "hubber",
            ),
        ]);
        assert_eq!(messages(&all(&mut p)), vec!["1 new comment from @hubber"]);
    }

    /// The exemption that keeps the rules from silencing the one thing nobody else
    /// reports: the engine's own failure to do its job.
    #[test]
    fn the_engines_own_complaints_survive_the_self_rule() {
        let mut p = pass(vec![candidate(
            PrNotifyKind::Engine,
            "the agent session is gone and could not be revived",
            "octocat",
        )]);
        assert_eq!(all(&mut p).len(), 1);
    }

    /// Every rule is a flag, so a tree can keep the quiet parts and drop the opinionated
    /// one without a second plugin — which is the whole reason this is an entry.
    #[test]
    fn each_rule_can_be_turned_off_on_its_own() {
        let candidates = vec![
            candidate(PrNotifyKind::Review, "@a commented", "a"),
            candidate(PrNotifyKind::Review, "@b requested changes", "b"),
        ];
        let mut theirs = PrNotifyPass {
            author: "hubber".into(),
            ..pass(candidates.clone())
        };
        assert_eq!(
            filter(&mut theirs, false, false, true, true).len(),
            2,
            "with rule 1 and rule 2 off, a PR you are reviewing notifies like any other"
        );
        let mut mine = pass(candidates);
        assert_eq!(filter(&mut mine, true, false, true, true).len(), 2);
    }

    #[test]
    fn nothing_in_equals_nothing_out() {
        let mut p = pass(Vec::new());
        assert!(all(&mut p).is_empty());
        assert!(p.notes.is_empty());
    }
}
