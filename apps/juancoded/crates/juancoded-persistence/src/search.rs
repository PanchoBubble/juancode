//! Searching a session's history, answered from the daemon's own store.
//!
//! This exists because the desktop could not answer it. The mirror at
//! `~/.juancode/data/juancode-rust.db` only ever learns a session's bytes by
//! attaching to it over the socket, so every session this Mac has not clicked —
//! every dispatched one, every one older than the switch to this core — was in the
//! index under its title and nothing else. The daemon is the side that holds the
//! history, so it is the side that answers.
//!
//! **No index over the text.** The obvious shape is fts5, and it is the wrong one
//! here: an fts5 table keeps a second copy of everything it indexes (juancode-5bwj
//! is that complaint about the mirror), and the corpus is 436 MB of transcript JSON.
//! What makes a scan affordable instead is that the interesting part of that corpus
//! is small. Of 534,846 records in the real store, tool calls and their results are
//! 350 MB; what a person or an agent actually SAID — a turn's prompt, an assistant
//! reply, a thought — is 25 MB across 33k records. `transcript_by_kind` (migration 9)
//! narrows to those rows by index, and the scan reads only them.
//!
//! Measured on the real 610 MB store, 857 sessions (2026-09-17): 0.36s warm for a
//! word in 377 sessions, ~0.2s for a rarer one, 3.0s on the first query after the
//! daemon starts and the pages are cold. If the corpus outgrows that, the answer is
//! a narrower corpus or a contentless index — not a second copy of the text.
//!
//! **Matched against the extracted text, not the record.** `json_extract` first and
//! `LIKE` second, rather than `LIKE` over the raw JSON, and the difference is not
//! subtle: every record carries `"source":"claude-jsonl"`, so a raw-JSON match for
//! "claude" found 764 of 857 sessions where the text itself is in 377. Extracting
//! also un-escapes, so a query containing a quote or a newline can match at all.

use anyhow::Result;
use rusqlite::Connection;

/// One session the search matched, with the text around the first match in it.
///
/// No `SessionMeta`: the caller already holds every row (the desktop's mirror is a
/// complete copy after a backfill, and the registry's map is the daemon's own), and
/// sending a second copy of 857 rows' metadata to answer a search would be the same
/// duplication this module exists to avoid.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchHit {
    pub session_id: String,
    pub snippet: String,
}

/// The record kinds that hold something a person would search for.
///
/// Deliberately not `toolCall` / `toolResult`: they are 80% of the bytes and almost
/// none of the meaning, and a search that matched inside a `Bash` command's output
/// would answer "which session ran grep" rather than "which session was about this".
const CONVERSATION_KINDS: &str = "'turnStart','assistant','thinking'";

/// The JSON path each kind keeps its text at. `turnStart` is the human's prompt;
/// `assistant` and `thinking` both use `text`.
const RECORD_TEXT: &str =
    "coalesce(json_extract(record, '$.prompt'), json_extract(record, '$.text'))";

/// Characters either side of the match in a snippet.
const SNIPPET_WINDOW: usize = 80;

/// Sessions whose history mentions `query`, newest first, at most `limit` of them.
///
/// Two corpora, unioned: the conversation records above, and the raw pty scrollback
/// for sessions that have it. Scrollback is scanned whole (27.9 MB in the real store,
/// 0.15s) rather than indexed, for the same reason the transcripts are not.
pub fn search(conn: &Connection, query: &str, limit: usize) -> Result<Vec<SearchHit>> {
    let query = query.trim();
    if query.is_empty() || limit == 0 {
        return Ok(Vec::new());
    }
    let pattern = like_pattern(query);

    let mut candidates: Vec<String> = Vec::new();
    {
        let mut stmt = conn.prepare(&format!(
            "SELECT DISTINCT session_id FROM transcript_records \
             WHERE json_extract(record, '$.kind') IN ({CONVERSATION_KINDS}) \
               AND {RECORD_TEXT} LIKE ?1 ESCAPE '\\'"
        ))?;
        let rows = stmt.query_map([&pattern], |r| r.get::<_, String>(0))?;
        for id in rows {
            candidates.push(id?);
        }
    }
    {
        let mut stmt = conn.prepare(
            "SELECT session_id FROM scrollback \
             WHERE length(bytes) > 0 AND CAST(bytes AS TEXT) LIKE ?1 ESCAPE '\\'",
        )?;
        let rows = stmt.query_map([&pattern], |r| r.get::<_, String>(0))?;
        for id in rows {
            candidates.push(id?);
        }
    }
    if candidates.is_empty() {
        return Ok(Vec::new());
    }

    // Ranked by recency in Rust rather than by a join, because the id list is at most
    // a few hundred and the whole session table is under a thousand rows: one small
    // read beats building an `IN (?,?,…)` the width of the candidate set.
    let mut order: std::collections::HashMap<String, i64> = std::collections::HashMap::new();
    {
        let mut stmt = conn.prepare("SELECT id, updated_at FROM sessions")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
        for row in rows {
            let (id, updated_at) = row?;
            order.insert(id, updated_at);
        }
    }
    candidates.sort();
    candidates.dedup();
    // A candidate with no session row is dropped rather than returned: the caller
    // draws a row for every hit, and it has no row to draw.
    candidates.retain(|id| order.contains_key(id));
    candidates.sort_by(|a, b| order[b].cmp(&order[a]).then_with(|| a.cmp(b)));
    candidates.truncate(limit);

    let mut hits = Vec::with_capacity(candidates.len());
    for id in candidates {
        let snippet = record_snippet(conn, &id, &pattern, query)?
            .or(scrollback_snippet(conn, &id, query)?)
            .unwrap_or_default();
        hits.push(SearchHit {
            session_id: id,
            snippet,
        });
    }
    Ok(hits)
}

/// The first conversation record in this session that matches, reduced to a snippet.
fn record_snippet(
    conn: &Connection,
    id: &str,
    pattern: &str,
    query: &str,
) -> Result<Option<String>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {RECORD_TEXT} FROM transcript_records \
         WHERE session_id = ?1 AND json_extract(record, '$.kind') IN ({CONVERSATION_KINDS}) \
           AND {RECORD_TEXT} LIKE ?2 ESCAPE '\\' \
         ORDER BY seq LIMIT 1"
    ))?;
    let text: Option<String> = stmt
        .query_row(rusqlite::params![id, pattern], |r| r.get::<_, String>(0))
        .ok();
    Ok(text.and_then(|t| snippet(&t, query)))
}

/// The same, over the session's raw pty bytes. Lossy UTF-8 because a scrollback ring
/// is cut at a byte boundary, not a character one.
fn scrollback_snippet(conn: &Connection, id: &str, query: &str) -> Result<Option<String>> {
    let bytes: Option<Vec<u8>> = conn
        .query_row(
            "SELECT bytes FROM scrollback WHERE session_id = ?1",
            [id],
            |r| r.get::<_, Vec<u8>>(0),
        )
        .ok();
    Ok(bytes.and_then(|b| snippet(&String::from_utf8_lossy(&b), query)))
}

/// `query` as a `LIKE` pattern that matches it literally. The wildcards and the
/// escape itself are escaped, so searching for `100%` finds `100%` rather than
/// everything.
fn like_pattern(query: &str) -> String {
    let mut out = String::with_capacity(query.len() + 2);
    out.push('%');
    for ch in query.chars() {
        if matches!(ch, '%' | '_' | '\\') {
            out.push('\\');
        }
        out.push(ch);
    }
    out.push('%');
    out
}

/// The text around the first occurrence of `query`, with the match in brackets and an
/// ellipsis on whichever side was cut. Shaped like the mirror's `snippet()` output so
/// a merged result list does not read as two different search engines.
///
/// ASCII case folding, which is not a shortcut: it is exactly what SQLite's `LIKE`
/// does, so the snippet finds the same occurrence the query matched on. Folding the
/// whole string with `to_lowercase` would move byte offsets and could point at a
/// different place in the text than the one that matched.
fn snippet(haystack: &str, query: &str) -> Option<String> {
    let at = haystack
        .to_ascii_lowercase()
        .find(&query.to_ascii_lowercase())?;
    let end = at + query.len();
    let start = floor_boundary(haystack, at.saturating_sub(SNIPPET_WINDOW));
    let stop = ceil_boundary(haystack, (end + SNIPPET_WINDOW).min(haystack.len()));
    let mut out = String::new();
    if start > 0 {
        out.push('…');
    }
    out.push_str(collapse(&haystack[start..at]).trim_start());
    out.push('[');
    out.push_str(&haystack[at..end]);
    out.push(']');
    out.push_str(collapse(&haystack[end..stop]).trim_end());
    if stop < haystack.len() {
        out.push('…');
    }
    Some(out)
}

/// One line, so a snippet cut out of a multi-line prompt is still one row tall.
fn collapse(text: &str) -> String {
    text.replace(['\n', '\r', '\t'], " ")
}

fn floor_boundary(text: &str, mut at: usize) -> usize {
    while at > 0 && !text.is_char_boundary(at) {
        at -= 1;
    }
    at
}

fn ceil_boundary(text: &str, mut at: usize) -> usize {
    while at < text.len() && !text.is_char_boundary(at) {
        at += 1;
    }
    at
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_wildcard_in_the_query_is_matched_literally() {
        assert_eq!(like_pattern("100%"), "%100\\%%");
        assert_eq!(like_pattern("a_b"), "%a\\_b%");
        assert_eq!(like_pattern("c:\\x"), "%c:\\\\x%");
    }

    #[test]
    fn a_snippet_brackets_the_match_and_marks_what_it_cut() {
        let text = "the daemon keeps the bytes";
        assert_eq!(
            snippet(text, "daemon").unwrap(),
            "the [daemon] keeps the bytes"
        );
        assert!(snippet(text, "nothing here").is_none());
    }

    #[test]
    fn a_snippet_matches_the_case_insensitively_the_way_like_does() {
        assert_eq!(snippet("Scrollback", "scrollback").unwrap(), "[Scrollback]");
    }

    #[test]
    fn a_long_haystack_is_cut_on_both_sides_with_ellipses() {
        let text = format!("{}needle{}", "a".repeat(400), "b".repeat(400));
        let out = snippet(&text, "needle").unwrap();
        assert!(out.starts_with('…') && out.ends_with('…'), "{out}");
        assert!(out.contains("[needle]"), "{out}");
        assert!(out.chars().count() < 200, "{out}");
    }

    #[test]
    fn a_multibyte_neighbourhood_does_not_split_a_character() {
        let text = format!("{}needle{}", "é".repeat(100), "→".repeat(100));
        let out = snippet(&text, "needle").unwrap();
        assert!(out.contains("[needle]"), "{out}");
    }

    #[test]
    fn newlines_in_a_prompt_become_one_line() {
        let out = snippet("first line\nwith a needle\nthen more", "needle").unwrap();
        assert!(!out.contains('\n'), "{out}");
    }
}
