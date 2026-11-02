//! Full review context must use the PR's immutable head blob, even for forks and
//! URL-only reviews. Exercise real argv and a head changing between reads.
use juancoded_core::gh::{self, PrUrl};
use std::os::unix::fs::PermissionsExt;

#[tokio::test]
async fn full_context_uses_fork_revision_and_refuses_a_moving_head() {
    let dir = std::env::temp_dir().join(format!("juancode-pr-file-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let bin = dir.join("gh");
    let script = r#"#!/bin/sh
printf '%s\n' "$*" >> '__DIR__/calls'
case "$1 $2" in
  'repo view') printf 'acme/widgets'; exit 0 ;;
  'pr diff')
    if test -f '__DIR__/move'; then touch '__DIR__/moved'; fi
    printf 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n'
    exit 0 ;;
esac
case "$*" in
  *headRefOid*)
    sha=abc123
    if test -f '__DIR__/moved'; then sha=changed; fi
    printf '{"data":{"repository":{"pullRequest":{"headRefOid":"%s","headRepository":{"name":"fork","owner":{"login":"contributor"}}}}}}' "$sha" ;;
  *expression=*)
    if test -f '__DIR__/binary'; then
      printf '{"data":{"repository":{"object":{"isBinary":true,"text":null}}}}'
    else
      printf '%s' '{"data":{"repository":{"object":{"isBinary":false,"text":"new\n"}}}}'
    fi ;;
esac
"#.replace("__DIR__", &dir.to_string_lossy());
    std::fs::write(&bin, script).unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::env::set_var("JUANCODE_GH_BIN", &bin);
    let reference = PrUrl::parse("https://ghe.example.com/acme/widgets/pull/42").unwrap();
    let content = gh::pr_file(&PrUrl::scratch_cwd(), 42, Some(&reference), "a.txt")
        .await
        .unwrap();
    assert_eq!(content.text, "new\n");
    assert!(content.diff.contains("+new"));
    let log = std::fs::read_to_string(dir.join("calls")).unwrap();
    assert!(log.contains("--hostname ghe.example.com"));
    assert!(log.contains("owner=contributor -f name=fork -f expression=abc123:a.txt"));
    assert!(log.contains("pr diff 42 --repo ghe.example.com/acme/widgets"));

    // The checkout-addressed path resolves its own repo, while keeping the blob
    // rooted in the contributor's fork.
    assert_eq!(
        gh::pr_file(dir.to_str().unwrap(), 42, None, "a.txt")
            .await
            .unwrap()
            .text,
        "new\n"
    );
    std::fs::write(dir.join("binary"), "").unwrap();
    assert!(
        gh::pr_file(&PrUrl::scratch_cwd(), 42, Some(&reference), "a.txt")
            .await
            .unwrap_err()
            .to_string()
            .contains("binary")
    );
    std::fs::remove_file(dir.join("binary")).unwrap();
    std::fs::write(dir.join("move"), "").unwrap();
    assert!(
        gh::pr_file(&PrUrl::scratch_cwd(), 42, Some(&reference), "a.txt")
            .await
            .unwrap_err()
            .to_string()
            .contains("PR changed")
    );
    assert!(
        gh::pr_file(&PrUrl::scratch_cwd(), 42, Some(&reference), "../escape")
            .await
            .is_err()
    );
    std::env::remove_var("JUANCODE_GH_BIN");
    std::fs::remove_dir_all(dir).unwrap();
}
