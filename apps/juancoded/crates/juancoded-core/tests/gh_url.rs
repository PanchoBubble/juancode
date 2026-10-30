//! A PR named by URL is read and written without a checkout: every `gh` call it makes
//! carries the repository (and host) itself and runs outside any repository.
//!
//! One test, because `JUANCODE_GH_BIN` is process-global: a stub `gh` records each
//! call's working directory and argv, so what the daemon actually runs is asserted
//! rather than how it builds it.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use juancoded_core::gh::{self, PrUrl, ReviewCommentDraft};
use juancoded_core::gh_convo;

fn stub_gh(dir: &Path) -> std::path::PathBuf {
    let bin = dir.join("gh");
    let log = dir.join("calls.log");
    let script = format!(
        r#"#!/bin/sh
printf '%s|' "$(pwd -P)" >> '{log}'
printf '%s ' "$@" | tr '\n' ' ' >> '{log}'
printf '\n' >> '{log}'
case "$1 $2" in
  "pr view") printf '{{"number":42,"title":"t","url":"https://ghe.example.com/acme/widgets/pull/42","headRefName":"b"}}' ;;
  "pr diff") printf 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-x\n+y\n' ;;
esac
exit 0
"#,
        log = log.display()
    );
    std::fs::write(&bin, script).unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    bin
}

#[tokio::test]
async fn url_addressed_pr_runs_gh_with_an_explicit_repo_outside_any_checkout() {
    let dir = tempdir("gh-url");
    std::env::set_var("JUANCODE_GH_BIN", stub_gh(&dir));
    let reference = PrUrl::parse("https://ghe.example.com/acme/widgets/pull/42").unwrap();

    let pr = gh::pr_by_url(&reference).await.unwrap();
    assert_eq!(pr.number, 42);
    let diff = gh::pr_diff_url(&reference).await.unwrap();
    assert_eq!(diff.files.len(), 1);
    gh::comment_on_pr_url(&reference, "hello").await.unwrap();
    gh::reply_to_review_comment_url(&reference, 7, "re")
        .await
        .unwrap();
    gh::submit_review_url(
        &reference,
        "",
        &[ReviewCommentDraft {
            path: "a.txt".into(),
            line: 1,
            side: "RIGHT".into(),
            start_line: None,
            start_side: None,
            body: "nit".into(),
        }],
    )
    .await
    .unwrap();
    gh::set_review_thread_resolved_url(&reference, "PRRT_1", true)
        .await
        .unwrap();
    // The stub answers nothing parseable; only the invocation is under test.
    assert!(gh_convo::pr_conversation_url(&reference).await.is_none());
    let _ = gh::pr_check_runs_url(&reference).await;

    let log = std::fs::read_to_string(dir.join("calls.log")).unwrap();
    let calls: Vec<(&str, &str)> = log.lines().filter_map(|l| l.split_once('|')).collect();
    assert_eq!(calls.len(), 8, "{log}");
    let scratch = std::fs::canonicalize(std::env::temp_dir()).unwrap();
    for (cwd, _) in &calls {
        assert_eq!(Path::new(cwd), scratch, "ran inside a checkout: {log}");
    }
    let argv = |i: usize| calls[i].1;
    assert!(argv(0).starts_with("pr view 42 --repo ghe.example.com/acme/widgets "));
    assert!(argv(1).starts_with("pr diff 42 --repo ghe.example.com/acme/widgets"));
    assert!(argv(2).starts_with("pr comment 42 --repo ghe.example.com/acme/widgets --body hello"));
    assert!(argv(3)
        .contains("--hostname ghe.example.com repos/acme/widgets/pulls/42/comments/7/replies"));
    assert!(
        argv(4).contains("--hostname ghe.example.com repos/acme/widgets/pulls/42/reviews --input")
    );
    assert!(argv(5).starts_with("api graphql --hostname ghe.example.com "));
    assert!(argv(5).contains("id=PRRT_1"));
    assert!(argv(6).starts_with("api graphql --hostname ghe.example.com "));
    assert!(argv(6).contains("name=widgets"));
    assert!(argv(7).starts_with("pr checks 42 --repo ghe.example.com/acme/widgets"));
}

#[test]
fn pr_urls_that_do_not_name_a_pull_request_are_rejected() {
    for bad in [
        "",
        "not a url",
        "github.com/acme/widgets/pull/42",
        "https://github.com/acme/widgets/issues/42",
        "https://github.com/acme/widgets/pull/0",
        "https://github.com/acme/widgets/pull/abc",
        "https://github.com/acme/pull/42",
        "https://user@github.com/acme/widgets/pull/42",
        "https://github.com/../widgets/pull/42",
    ] {
        assert!(PrUrl::parse(bad).is_none(), "accepted {bad:?}");
    }
    let ok = PrUrl::parse("  http://github.com/acme/widgets/pull/9/files?x=1#y ").unwrap();
    assert_eq!(
        (ok.owner.as_str(), ok.repo.as_str(), ok.number),
        ("acme", "widgets", 9)
    );
}

fn tempdir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("juancoded-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}
