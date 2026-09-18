//! A pull request's conversation, in one `gh api graphql` call.
//!
//! A port of `JuancodeServices/GhConversation.swift`. The shape is GitHub's
//! Conversation tab: the PR's own description, the issue-level comments, the review
//! verdicts with the inline comments each one submitted, the review threads those
//! comments hang in, and the commits — enough that a review can be read without
//! opening github.com.
//!
//! One call, not five. Everything the tab shows is reachable from one `pullRequest`
//! node, and the alternative is a REST fan-out whose cost on the machine this is
//! developed on is a quarter of a second of `fork+exec` per request before GitHub is
//! even asked. Parsing is a pure function over the JSON string, so the whole shape is
//! testable without a process.
//!
//! Timestamps cross the wire as milliseconds since the epoch, like every other
//! timestamp this daemon serves, rather than as the ISO strings GitHub sends: a client
//! that has to parse RFC-3339 to sort a timeline is a client that can disagree with
//! this core about the order of two comments.

use serde::{Deserialize, Serialize};

use crate::gh::{iso8601_ms, repo_owner_name};

/// One emoji reaction bucket — GitHub's `reactionGroups` entry, kept only when
/// somebody actually reacted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrReaction {
    /// GitHub's content enum: `THUMBS_UP`, `HEART`, `ROCKET`, …
    pub content: String,
    pub count: i64,
}

/// One comment in a conversation: an issue-level comment, or one turn of an inline
/// review thread.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrConversationComment {
    /// The GraphQL node id — stable, and what deduplication is keyed on.
    pub id: String,
    /// The REST id, which is the one a *reply* has to target. Absent for a comment
    /// GitHub did not report one for, which is why a thread with no reply target is a
    /// thread the composer refuses rather than posts into the void.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub database_id: Option<i64>,
    #[serde(default)]
    pub author: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_avatar_url: Option<String>,
    #[serde(default)]
    pub body: String,
    /// Milliseconds since the epoch, or absent when the stamp was missing or garbage —
    /// one unparseable date must not sink a conversation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<i64>,
    #[serde(default)]
    pub url: String,
    /// For an inline comment: the file it hangs off and the line within it. Both absent
    /// for an issue-level comment, which has no location.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<i64>,
    /// The unified-diff hunk the comment is anchored to — an `@@ … @@` header plus the
    /// context ending at the commented line. Rendering it is what lets a review be read
    /// away from the diff it is about.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff_hunk: Option<String>,
    #[serde(default)]
    pub reactions: Vec<PrReaction>,
}

/// One inline review thread: where it hangs, whether it has been dealt with, and its
/// comments in thread order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrReviewThread {
    pub id: String,
    pub is_resolved: bool,
    pub is_outdated: bool,
    #[serde(default)]
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<i64>,
    pub comments: Vec<PrConversationComment>,
}

impl PrReviewThread {
    /// The REST comment id a reply to this thread must name. GitHub's replies API only
    /// accepts a *top-level* review comment, so the target is always the thread's first
    /// comment — replying to a reply is a 422.
    pub fn reply_target_id(&self) -> Option<i64> {
        self.comments.first().and_then(|c| c.database_id)
    }
}

/// One review verdict, with the inline comments it submitted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrReviewItem {
    pub id: String,
    #[serde(default)]
    pub author: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_avatar_url: Option<String>,
    /// APPROVED / CHANGES_REQUESTED / COMMENTED / DISMISSED / PENDING, upper-cased.
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub body: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<i64>,
    #[serde(default)]
    pub url: String,
    /// The inline comments submitted as part of this review, in thread order — the way
    /// GitHub's Conversation tab groups a review with what it said.
    #[serde(default)]
    pub comments: Vec<PrConversationComment>,
    #[serde(default)]
    pub reactions: Vec<PrReaction>,
}

/// One commit on the PR, for the interleaved timeline.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrCommit {
    pub oid: String,
    pub abbreviated_oid: String,
    #[serde(default)]
    pub message_headline: String,
    /// The author's login when GitHub knows the account, otherwise the name on the
    /// commit — an unlinked commit still has an author worth showing.
    #[serde(default)]
    pub author: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub committed_date: Option<i64>,
}

/// A PR's whole conversation.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrConversation {
    /// OPEN / CLOSED / MERGED, upper-cased, for the header.
    pub state: String,
    /// The PR's own description as raw markdown; empty when it has none.
    #[serde(default)]
    pub body: String,
    pub issue_comments: Vec<PrConversationComment>,
    pub reviews: Vec<PrReviewItem>,
    pub threads: Vec<PrReviewThread>,
    #[serde(default)]
    pub commits: Vec<PrCommit>,
}

/// The one query. `last` on the comment and review connections rather than `first`,
/// because a long PR's recent turns are the ones being read; `first` on the threads,
/// because a thread's identity is what a reply targets and the oldest open one is as
/// live as the newest.
fn conversation_query() -> String {
    let comment_fields = "id databaseId author { login avatarUrl } body createdAt url \
reactionGroups { content reactors { totalCount } }";
    let inline_fields = "id databaseId author { login avatarUrl } body createdAt url path line \
diffHunk reactionGroups { content reactors { totalCount } }";
    format!(
        "query($owner: String!, $name: String!, $number: Int!) {{\n\
           repository(owner: $owner, name: $name) {{\n\
             pullRequest(number: $number) {{\n\
               state\n\
               body\n\
               comments(last: 50) {{ nodes {{ {comment_fields} }} }}\n\
               reviews(last: 30) {{\n\
                 nodes {{\n\
                   id author {{ login avatarUrl }} state body createdAt url\n\
                   reactionGroups {{ content reactors {{ totalCount }} }}\n\
                   comments(first: 50) {{ nodes {{ {inline_fields} }} }}\n\
                 }}\n\
               }}\n\
               reviewThreads(first: 100) {{\n\
                 nodes {{\n\
                   id isResolved isOutdated path line\n\
                   comments(first: 50) {{ nodes {{ {inline_fields} }} }}\n\
                 }}\n\
               }}\n\
               commits(last: 100) {{\n\
                 nodes {{ commit {{ oid abbreviatedOid messageHeadline committedDate \
authors(first: 1) {{ nodes {{ name user {{ login avatarUrl }} }} }} }} }}\n\
               }}\n\
             }}\n\
           }}\n\
         }}"
    )
}

/// Read a PR's conversation, scoped by the owner/name lifted from its own url so there
/// is no extra `gh repo view` round-trip. `None` when `gh` is missing or
/// unauthenticated, the url is not a github.com PR url, or the response will not parse
/// — all of which the view reads as "could not load", which is the truth in each case.
pub async fn pr_conversation(cwd: &str, number: i64, pr_url: &str) -> Option<PrConversation> {
    let (owner, name) = repo_owner_name(pr_url)?;
    let raw = crate::gh::graphql(
        cwd,
        &conversation_query(),
        &[("owner", owner.as_str()), ("name", name.as_str())],
        &[("number", number)],
    )
    .await?;
    parse_pr_conversation(&raw)
}

/// Map the GraphQL response onto the wire shape.
///
/// Field-tolerant on purpose: a missing `databaseId`, `line` or date becomes absent, a
/// missing author becomes empty, and only a comment, review or thread with no `id` at
/// all is dropped — without one it cannot be identified, replied to or deduplicated.
/// `None` is returned only when the JSON is structurally not a conversation: no
/// `repository.pullRequest` object in it.
pub fn parse_pr_conversation(json: &str) -> Option<PrConversation> {
    let decoded: ConversationResponse = serde_json::from_str(json).ok()?;
    let pr = decoded.data?.repository?.pull_request?;

    let reviews: Vec<PrReviewItem> = pr
        .reviews
        .and_then(|c| c.nodes)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|r| {
            Some(PrReviewItem {
                id: r.id?,
                author: r
                    .author
                    .as_ref()
                    .and_then(|a| a.login.clone())
                    .unwrap_or_default(),
                author_avatar_url: r.author.and_then(|a| a.avatar_url),
                state: r.state.unwrap_or_default().to_uppercase(),
                body: r.body.unwrap_or_default(),
                created_at: r.created_at.as_deref().and_then(iso8601_ms),
                url: r.url.unwrap_or_default(),
                comments: map_comments(r.comments),
                reactions: map_reactions(r.reaction_groups),
            })
        })
        .collect();

    // Drop empty-review noise. GitHub records a bare COMMENTED review for every reply
    // to an inline comment; with no body, no inline comments of its own and no
    // reactions it renders as a card that says nothing. Only that exact shape goes —
    // a verdict, or anything carrying content, is kept.
    let meaningful: Vec<PrReviewItem> = reviews
        .into_iter()
        .filter(|r| {
            !(r.state == "COMMENTED"
                && r.body.is_empty()
                && r.comments.is_empty()
                && r.reactions.is_empty())
        })
        .collect();

    let threads: Vec<PrReviewThread> = pr
        .review_threads
        .and_then(|c| c.nodes)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|t| {
            Some(PrReviewThread {
                id: t.id?,
                is_resolved: t.is_resolved.unwrap_or(false),
                is_outdated: t.is_outdated.unwrap_or(false),
                path: t.path.unwrap_or_default(),
                line: t.line,
                comments: map_comments(t.comments),
            })
        })
        .collect();

    let commits: Vec<PrCommit> = pr
        .commits
        .and_then(|c| c.nodes)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|edge| {
            let c = edge.commit?;
            let oid = c.oid?;
            let author = c.authors.and_then(|a| a.nodes).unwrap_or_default();
            let first = author.into_iter().next();
            Some(PrCommit {
                abbreviated_oid: c
                    .abbreviated_oid
                    .unwrap_or_else(|| oid.chars().take(7).collect()),
                message_headline: c.message_headline.unwrap_or_default(),
                author: first
                    .and_then(|a| a.user.and_then(|u| u.login).or(a.name))
                    .unwrap_or_default(),
                committed_date: c.committed_date.as_deref().and_then(iso8601_ms),
                oid,
            })
        })
        .collect();

    Some(PrConversation {
        state: pr.state.unwrap_or_default().to_uppercase(),
        body: pr.body.unwrap_or_default(),
        issue_comments: map_comments(pr.comments),
        reviews: meaningful,
        threads,
        commits,
    })
}

fn map_reactions(groups: Option<Vec<ReactionGroupNode>>) -> Vec<PrReaction> {
    groups
        .unwrap_or_default()
        .into_iter()
        .filter_map(|g| {
            let count = g.reactors.and_then(|r| r.total_count).unwrap_or(0);
            if count <= 0 {
                return None;
            }
            Some(PrReaction {
                content: g.content?,
                count,
            })
        })
        .collect()
}

fn map_comments(conn: Option<CommentConnection>) -> Vec<PrConversationComment> {
    conn.and_then(|c| c.nodes)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|c| {
            Some(PrConversationComment {
                id: c.id?,
                database_id: c.database_id,
                author: c
                    .author
                    .as_ref()
                    .and_then(|a| a.login.clone())
                    .unwrap_or_default(),
                author_avatar_url: c.author.and_then(|a| a.avatar_url),
                body: c.body.unwrap_or_default(),
                created_at: c.created_at.as_deref().and_then(iso8601_ms),
                url: c.url.unwrap_or_default(),
                path: c.path,
                line: c.line,
                diff_hunk: c.diff_hunk,
                reactions: map_reactions(c.reaction_groups),
            })
        })
        .collect()
}

// ── the GraphQL response, exactly as asked for ───────────────────────────────

#[derive(Debug, Deserialize)]
struct ConversationResponse {
    data: Option<ConversationData>,
}
#[derive(Debug, Deserialize)]
struct ConversationData {
    repository: Option<ConversationRepo>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConversationRepo {
    pull_request: Option<PullRequestNode>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PullRequestNode {
    state: Option<String>,
    body: Option<String>,
    comments: Option<CommentConnection>,
    reviews: Option<ReviewConnection>,
    review_threads: Option<ThreadConnection>,
    commits: Option<CommitConnection>,
}
#[derive(Debug, Deserialize)]
struct CommentConnection {
    nodes: Option<Vec<CommentNode>>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CommentNode {
    id: Option<String>,
    database_id: Option<i64>,
    author: Option<GraphAuthor>,
    body: Option<String>,
    created_at: Option<String>,
    url: Option<String>,
    path: Option<String>,
    line: Option<i64>,
    diff_hunk: Option<String>,
    reaction_groups: Option<Vec<ReactionGroupNode>>,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphAuthor {
    login: Option<String>,
    avatar_url: Option<String>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReactionGroupNode {
    content: Option<String>,
    reactors: Option<ReactorConnection>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReactorConnection {
    total_count: Option<i64>,
}
#[derive(Debug, Deserialize)]
struct ReviewConnection {
    nodes: Option<Vec<ReviewNode>>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReviewNode {
    id: Option<String>,
    author: Option<GraphAuthor>,
    state: Option<String>,
    body: Option<String>,
    created_at: Option<String>,
    url: Option<String>,
    comments: Option<CommentConnection>,
    reaction_groups: Option<Vec<ReactionGroupNode>>,
}
#[derive(Debug, Deserialize)]
struct ThreadConnection {
    nodes: Option<Vec<ThreadNode>>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadNode {
    id: Option<String>,
    is_resolved: Option<bool>,
    is_outdated: Option<bool>,
    path: Option<String>,
    line: Option<i64>,
    comments: Option<CommentConnection>,
}
#[derive(Debug, Deserialize)]
struct CommitConnection {
    nodes: Option<Vec<CommitEdge>>,
}
#[derive(Debug, Deserialize)]
struct CommitEdge {
    commit: Option<CommitNode>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CommitNode {
    oid: Option<String>,
    abbreviated_oid: Option<String>,
    message_headline: Option<String>,
    committed_date: Option<String>,
    authors: Option<CommitAuthorConnection>,
}
#[derive(Debug, Deserialize)]
struct CommitAuthorConnection {
    nodes: Option<Vec<CommitAuthor>>,
}
#[derive(Debug, Deserialize)]
struct CommitAuthor {
    name: Option<String>,
    user: Option<GraphAuthor>,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A realistic response: one issue comment with reactions, one review verdict, and
    /// two threads — one live with a back-and-forth in it, one resolved and outdated
    /// with nothing left in it. Lifted from `GhConversationTests.swift` so both cores
    /// are answering the same fixture.
    const FULL: &str = r#"
    {"data":{"repository":{"pullRequest":{
      "state":"OPEN",
      "body":"This PR fixes the thing.",
      "comments":{"nodes":[
        {"id":"IC_1","databaseId":111,
         "author":{"login":"alice","avatarUrl":"https://avatars.example/alice.png"},
         "body":"Looks good overall","createdAt":"2026-07-01T12:00:00Z",
         "url":"https://github.com/o/r/pull/5#issuecomment-111",
         "reactionGroups":[{"content":"THUMBS_UP","reactors":{"totalCount":3}},
                           {"content":"HEART","reactors":{"totalCount":1}},
                           {"content":"CONFUSED","reactors":{"totalCount":0}}]}
      ]},
      "reviews":{"nodes":[
        {"id":"PRR_1","author":{"login":"bob"},"state":"changes_requested",
         "body":"Needs tests","createdAt":"2026-07-01T13:30:00.500Z",
         "url":"https://github.com/o/r/pull/5#pullrequestreview-1",
         "reactionGroups":[{"content":"ROCKET","reactors":{"totalCount":2}}]}
      ]},
      "reviewThreads":{"nodes":[
        {"id":"RT_1","isResolved":false,"isOutdated":false,
         "path":"Sources/App/Main.swift","line":42,
         "comments":{"nodes":[
           {"id":"RC_1","databaseId":222,"author":{"login":"bob"},
            "body":"This can crash on nil","createdAt":"2026-07-01T13:31:00Z",
            "url":"https://github.com/o/r/pull/5#discussion_r222",
            "diffHunk":"@@ -38,6 +38,7 @@ func load() {"},
           {"id":"RC_2","databaseId":333,"author":{"login":"carol"},
            "body":"Agreed","createdAt":"2026-07-01T13:32:00Z",
            "url":"https://github.com/o/r/pull/5#discussion_r333"}
         ]}},
        {"id":"RT_2","isResolved":true,"isOutdated":true,
         "path":"README.md","line":null,"comments":{"nodes":[]}}
      ]},
      "commits":{"nodes":[
        {"commit":{"oid":"abc123def4567890","abbreviatedOid":"abc123d",
                   "messageHeadline":"fix the thing","committedDate":"2026-07-01T11:00:00Z",
                   "authors":{"nodes":[{"name":"Alice A","user":{"login":"alice"}}]}}},
        {"commit":{"oid":"0123456789abcdef","messageHeadline":"and again",
                   "committedDate":"2026-07-01T14:00:00Z",
                   "authors":{"nodes":[{"name":"Unlinked Person","user":null}]}}}
      ]}
    }}}}"#;

    /// Every optional nulled or garbage. The parse has to survive this: a PR whose
    /// author deleted their account, or whose date GitHub spelled in a way this core
    /// does not read, is still a PR somebody wants to look at.
    const MINIMAL: &str = r#"
    {"data":{"repository":{"pullRequest":{
      "state":"MERGED",
      "comments":{"nodes":[
        {"id":"IC_1","databaseId":null,"author":null,"body":null,
         "createdAt":"not a date","url":null}
      ]},
      "reviews":{"nodes":[
        {"id":"PRR_1","author":null,"state":null,"body":null,"createdAt":null,"url":null}
      ]},
      "reviewThreads":{"nodes":[
        {"id":"RT_1","isResolved":false,"isOutdated":false,"path":"a.txt","line":null,
         "comments":{"nodes":[
           {"id":"RC_1","databaseId":null,"author":null,"body":null,
            "createdAt":null,"url":null}
         ]}}
      ]}
    }}}}"#;

    #[test]
    fn the_whole_tab_comes_out_of_one_response() {
        let conv = parse_pr_conversation(FULL).expect("a conversation");
        assert_eq!(conv.state, "OPEN");
        assert_eq!(conv.body, "This PR fixes the thing.");

        let comment = &conv.issue_comments[0];
        assert_eq!(comment.database_id, Some(111));
        assert_eq!(comment.author, "alice");
        assert_eq!(
            comment.author_avatar_url.as_deref(),
            Some("https://avatars.example/alice.png")
        );
        assert_eq!(comment.created_at, iso8601_ms("2026-07-01T12:00:00Z"));
        assert_eq!(
            comment.reactions,
            vec![
                PrReaction {
                    content: "THUMBS_UP".into(),
                    count: 3
                },
                PrReaction {
                    content: "HEART".into(),
                    count: 1
                }
            ],
            "an empty bucket is not a reaction anybody left"
        );

        let review = &conv.reviews[0];
        assert_eq!(
            review.state, "CHANGES_REQUESTED",
            "upper-cased on the way in"
        );
        assert_eq!(review.created_at, iso8601_ms("2026-07-01T13:30:00.500Z"));

        assert_eq!(conv.threads.len(), 2);
        let live = &conv.threads[0];
        assert!(!live.is_resolved && !live.is_outdated);
        assert_eq!(live.path, "Sources/App/Main.swift");
        assert_eq!(live.line, Some(42));
        assert_eq!(live.comments.len(), 2);
        assert!(live.comments[0].diff_hunk.is_some());
        assert_eq!(
            live.reply_target_id(),
            Some(222),
            "a reply targets the thread's first comment, never the last one written"
        );
        let done = &conv.threads[1];
        assert!(done.is_resolved && done.is_outdated);
        assert_eq!(
            done.reply_target_id(),
            None,
            "an empty thread has no target"
        );

        assert_eq!(conv.commits.len(), 2);
        assert_eq!(
            conv.commits[0].author, "alice",
            "the account, when there is one"
        );
        assert_eq!(
            conv.commits[1].author, "Unlinked Person",
            "and the name on the commit when GitHub has no account for it"
        );
        assert_eq!(
            conv.commits[1].abbreviated_oid, "0123456",
            "an absent short oid is the first seven of the long one, not empty"
        );
    }

    #[test]
    fn everything_optional_may_be_missing_without_losing_the_conversation() {
        let conv = parse_pr_conversation(MINIMAL).expect("a conversation");
        assert_eq!(conv.state, "MERGED");
        assert_eq!(conv.body, "");
        assert_eq!(conv.issue_comments.len(), 1);
        assert_eq!(conv.issue_comments[0].author, "");
        assert_eq!(conv.issue_comments[0].database_id, None);
        assert_eq!(
            conv.issue_comments[0].created_at, None,
            "a date this core cannot read is no date, not a wrong one"
        );
        assert_eq!(conv.reviews.len(), 1);
        assert_eq!(conv.threads[0].comments.len(), 1);
        assert_eq!(conv.threads[0].line, None);
        assert!(conv.commits.is_empty(), "no commits key is no commits");
    }

    /// An id is the one field that cannot be defaulted: without it a comment cannot be
    /// replied to, deduplicated or given a stable identity in a list.
    #[test]
    fn an_item_with_no_id_is_dropped_rather_than_given_one() {
        let conv = parse_pr_conversation(
            r#"{"data":{"repository":{"pullRequest":{
                 "state":"OPEN",
                 "comments":{"nodes":[{"body":"who am i"},{"id":"IC_2","body":"me"}]},
                 "reviews":{"nodes":[{"state":"APPROVED"}]},
                 "reviewThreads":{"nodes":[{"path":"a.txt"}]}
               }}}}"#,
        )
        .expect("a conversation");
        assert_eq!(conv.issue_comments.len(), 1);
        assert_eq!(conv.issue_comments[0].id, "IC_2");
        assert!(conv.reviews.is_empty());
        assert!(conv.threads.is_empty());
    }

    /// GitHub writes a bare COMMENTED review for every inline reply. Keeping them puts
    /// a contentless card in the timeline for each turn of a conversation that is
    /// already fully visible in its own thread.
    #[test]
    fn a_review_that_is_only_the_record_of_a_reply_is_not_an_event() {
        let conv = parse_pr_conversation(
            r#"{"data":{"repository":{"pullRequest":{
                 "state":"OPEN",
                 "reviews":{"nodes":[
                   {"id":"R1","state":"COMMENTED","body":"","comments":{"nodes":[]}},
                   {"id":"R2","state":"COMMENTED","body":"a real note","comments":{"nodes":[]}},
                   {"id":"R3","state":"APPROVED","body":"","comments":{"nodes":[]}},
                   {"id":"R4","state":"COMMENTED","body":"",
                    "reactionGroups":[{"content":"EYES","reactors":{"totalCount":1}}],
                    "comments":{"nodes":[]}}
                 ]}
               }}}}"#,
        )
        .expect("a conversation");
        assert_eq!(
            conv.reviews
                .iter()
                .map(|r| r.id.as_str())
                .collect::<Vec<_>>(),
            vec!["R2", "R3", "R4"],
            "a verdict, a body and a reaction each say something; an empty comment does not"
        );
    }

    #[test]
    fn json_that_is_not_a_conversation_is_no_conversation() {
        for bad in ["", "not json", "{}", r#"{"data":{"repository":null}}"#] {
            assert!(parse_pr_conversation(bad).is_none(), "{bad:?}");
        }
    }

    /// The query is built once and asked for exactly the fields the parse reads. This
    /// guards the pairing: a field dropped from the query silently becomes `None` in
    /// every conversation, and nothing else in the suite would notice.
    #[test]
    fn the_query_asks_for_every_field_the_parse_reads() {
        let q = conversation_query();
        for field in [
            "databaseId",
            "avatarUrl",
            "diffHunk",
            "reactionGroups",
            "isResolved",
            "isOutdated",
            "abbreviatedOid",
            "messageHeadline",
            "committedDate",
        ] {
            assert!(q.contains(field), "the query must ask for {field}");
        }
    }
}
