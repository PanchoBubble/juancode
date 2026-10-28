//! Read-only stack metadata from GitHub's public GraphQL stack API, the same
//! server-side stacks managed by github/gh-stack. Keep this enrichment separate
//! from the main PR query: older hosts or missing permissions must not hide PRs.
use super::{graphql, repo_owner_name, PullRequest};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrStackMetadata {
    pub id: String,
    pub number: i64,
    pub size: i64,
    pub entries: Vec<PrStackEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrStackEntry {
    pub position: i64,
    pub number: i64,
    pub title: String,
    pub url: String,
    pub branch: String,
    pub state: String,
}

const STACK_FIELDS: &str = r#"id number size entries(first: 100) {
    nodes { position pullRequest { number title url headRefName state } }
    pageInfo { hasNextPage endCursor }
}"#;

fn query(numbers: &[i64]) -> String {
    let fields = numbers
        .iter()
        .map(|n| format!("p{n}: pullRequest(number: {n}) {{ stack {{ {STACK_FIELDS} }} }}"))
        .collect::<Vec<_>>()
        .join("\n");
    format!("query($owner: String!, $name: String!) {{ repository(owner: $owner, name: $name) {{ {fields} }} }}")
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawStack {
    id: String,
    number: i64,
    size: i64,
    entries: RawEntries,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawEntries {
    nodes: Vec<Option<RawEntry>>,
    page_info: PageInfo,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PageInfo {
    has_next_page: bool,
    end_cursor: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawEntry {
    position: i64,
    pull_request: Option<RawMember>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawMember {
    number: i64,
    title: String,
    url: String,
    head_ref_name: String,
    state: String,
}

fn metadata(raw: RawStack) -> Option<PrStackMetadata> {
    if raw.id.is_empty() || raw.number <= 0 || raw.size < 1 || raw.entries.page_info.has_next_page {
        return None;
    }
    let mut entries = Vec::new();
    for entry in raw.entries.nodes.into_iter().flatten() {
        // Inaccessible members leave gaps. Preserve the API's positions and size;
        // never renumber the visible entries to hide those gaps.
        if let Some(pr) = entry.pull_request {
            if entry.position < 1 || entry.position > raw.size || pr.number <= 0 {
                return None;
            }
            entries.push(PrStackEntry {
                position: entry.position,
                number: pr.number,
                title: pr.title,
                url: pr.url,
                branch: pr.head_ref_name,
                state: pr.state,
            });
        }
    }
    entries.sort_by_key(|entry| entry.position);
    let positions: std::collections::BTreeSet<_> = entries.iter().map(|e| e.position).collect();
    let numbers: std::collections::BTreeSet<_> = entries.iter().map(|e| e.number).collect();
    if positions.len() != entries.len() || numbers.len() != entries.len() {
        return None;
    }
    Some(PrStackMetadata {
        id: raw.id,
        number: raw.number,
        size: raw.size,
        entries,
    })
}

async fn complete(cwd: &str, mut stack: RawStack) -> Option<PrStackMetadata> {
    let mut cursors = std::collections::BTreeSet::new();
    while stack.entries.page_info.has_next_page {
        let cursor = stack.entries.page_info.end_cursor.as_deref()?;
        if !cursors.insert(cursor.to_owned()) {
            return None;
        }
        let query = r#"query($id: ID!, $after: String!) {
            node(id: $id) { ... on PullRequestStack {
                entries(first: 100, after: $after) {
                    nodes { position pullRequest { number title url headRefName state } }
                    pageInfo { hasNextPage endCursor }
                }
            } }
        }"#;
        let out = graphql(cwd, query, &[("id", &stack.id), ("after", cursor)], &[]).await?;
        let body: serde_json::Value = serde_json::from_str(&out).ok()?;
        if body.get("errors").is_some() {
            return None;
        }
        let page: RawEntries =
            serde_json::from_value(body["data"]["node"]["entries"].clone()).ok()?;
        stack.entries.nodes.extend(page.nodes);
        stack.entries.page_info = page.page_info;
    }
    metadata(stack)
}

/// Best effort with a total ten-second budget, including pagination. Completed
/// batches survive a later failure; failures leave stackKnown=false for inference.
pub(super) async fn enrich(cwd: &str, prs: &mut [&mut PullRequest]) {
    let _ = tokio::time::timeout(std::time::Duration::from_secs(10), async {
        let mut repos: BTreeMap<(String, String), Vec<i64>> = BTreeMap::new();
        for pr in prs.iter() {
            if pr.url.starts_with("https://github.com/") && pr.number > 0 {
                if let Some(repo) = repo_owner_name(&pr.url) {
                    repos.entry(repo).or_default().push(pr.number);
                }
            }
        }
        for ((owner, name), mut numbers) in repos {
            numbers.sort_unstable();
            numbers.dedup();
            let mut stacks: BTreeMap<String, PrStackMetadata> = BTreeMap::new();
            for batch in numbers.chunks(25) {
                let Some(out) = graphql(
                    cwd,
                    &query(batch),
                    &[("owner", &owner), ("name", &name)],
                    &[],
                )
                .await
                else {
                    continue;
                };
                let Ok(body) = serde_json::from_str::<serde_json::Value>(&out) else {
                    continue;
                };
                if body.get("errors").is_some() {
                    continue;
                }
                for number in batch {
                    let node = &body["data"]["repository"][format!("p{number}")];
                    let Some(value) = node.get("stack") else {
                        continue;
                    };
                    let stack = if value.is_null() {
                        None
                    } else {
                        let Ok(raw) = serde_json::from_value::<RawStack>(value.clone()) else {
                            continue;
                        };
                        if !stacks.contains_key(&raw.id) {
                            let Some(stack) = complete(cwd, raw).await else {
                                continue;
                            };
                            stacks.insert(stack.id.clone(), stack);
                        }
                        let Some(stack) = value["id"].as_str().and_then(|id| stacks.get(id)) else {
                            continue;
                        };
                        if !stack.entries.iter().any(|e| e.number == *number) {
                            continue;
                        }
                        Some(stack.clone())
                    };
                    for pr in prs.iter_mut().filter(|pr| {
                        pr.number == *number
                            && repo_owner_name(&pr.url) == Some((owner.clone(), name.clone()))
                    }) {
                        pr.stack = stack.clone();
                        pr.stack_known = true;
                    }
                }
            }
        }
    })
    .await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn raw() -> RawStack {
        serde_json::from_value(json!({
            "id": "STACK_node", "number": 17, "size": 3,
            "entries": {
                "nodes": [
                    {"position": 3, "pullRequest": {
                        "number": 5, "title": "tip", "url": "https://github.com/o/r/pull/5",
                        "headRefName": "tip", "state": "OPEN"
                    }},
                    {"position": 1, "pullRequest": {
                        "number": 90, "title": "base", "url": "https://github.com/o/r/pull/90",
                        "headRefName": "base", "state": "MERGED"
                    }},
                    {"position": 2, "pullRequest": null}
                ],
                "pageInfo": {"hasNextPage": false, "endCursor": null}
            }
        }))
        .unwrap()
    }

    #[test]
    fn canonical_positions_survive_missing_and_merged_members() {
        let stack = metadata(raw()).unwrap();
        assert_eq!(stack.size, 3);
        assert_eq!(
            stack
                .entries
                .iter()
                .map(|e| (e.position, e.number))
                .collect::<Vec<_>>(),
            vec![(1, 90), (3, 5)]
        );
        assert_eq!(stack.entries[0].state, "MERGED");
        let wire = serde_json::to_value(stack).unwrap();
        assert_eq!(wire["number"], 17);
        assert_eq!(wire["entries"][1]["branch"], "tip");
        assert_eq!(wire["entries"][1]["position"], 3);
    }

    #[test]
    fn incomplete_or_ambiguous_metadata_is_not_published() {
        let mut unfinished = raw();
        unfinished.entries.page_info.has_next_page = true;
        assert!(metadata(unfinished).is_none());
        let mut duplicate = raw();
        duplicate.entries.nodes[0].as_mut().unwrap().position = 1;
        assert!(metadata(duplicate).is_none());
        let mut invalid = raw();
        invalid.entries.nodes[0].as_mut().unwrap().position = 0;
        assert!(metadata(invalid).is_none());
    }

    #[test]
    fn query_uses_separate_pr_aliases_and_canonical_positions() {
        let query = query(&[5, 90]);
        assert!(query.contains("p5: pullRequest(number: 5)"));
        assert!(query.contains("p90: pullRequest(number: 90)"));
        assert!(query.contains("position pullRequest"));
        assert!(query.contains("hasNextPage endCursor"));
        assert!(!query.contains("mutation"));
    }
}
