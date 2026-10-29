---
name: dispatch-agents
description: Dispatch a task to a NEW, separate agent session (a real claude/codex/opencode pty in the juancode app, in its own git worktree) through juancode's Oracle — in ANY project. Use whenever the user says "dispatch an agent", "dispatch a session", "spin up / open / start a new session or agent for X", "hand this off to another agent", "fire off N agents to do …". This is NOT the in-process Agent/Task subagent tool — never satisfy a dispatch request with a subagent.
---

# dispatch-agents

"Dispatch" means a **separate juancode session**: a real CLI pty visible in the native
app's grid, steerable from Telegram, outliving this session, usually isolated in its
own git worktree. It is **not** the built-in Agent/Task tool. If you catch yourself
reaching for a subagent after the user said "dispatch", stop and use this instead.

The dispatch goes to the Oracle sidecar: `POST http://127.0.0.1:4281/api/dispatch`.

Never pass `--model`, a shadow HOME/CODEX_HOME, or mcpServers overrides — the
dispatched CLI inherits the user's environment untouched.

## Procedure

1. **Preflight** (one call):

   ```bash
   curl -s -m 2 http://127.0.0.1:4281/healthz && curl -s -m 2 http://127.0.0.1:4280/presence
   ```

   - Sidecar (4281) dead → tell the user to start it (`pnpm dev:oracle` in
     `~/workdir/personal/juancode`) and stop. Do NOT fall back to a subagent.
   - Native app (4280) not answering at all → a dispatch is durably queued and starts
     on next launch; say so. A JSON error body ("/presence is not served with the rust
     core") means the app IS up — proceed.

2. **Resolve the project**: the repo the work belongs in, as an absolute path —
   normally the main checkout, `git rev-parse --show-toplevel` (for a worktree, use
   the main checkout: `dirname "$(git rev-parse --git-common-dir)"`). Use another path
   only if the user named one.

3. **Write the prompt** to the session scratchpad (never into the repo). The new
   session has fresh context, so make it self-contained:
   - The goal and acceptance criteria, in full — paste ticket text (Linear, bd, …)
     rather than linking only.
   - Relevant files, decisions already made, what's ruled out.
   - The finish line (see below).
   - "You are in a fresh git worktree; orient with `pwd`, `git status -sb`,
     `git log --oneline -3`." when `worktree:true`.

   The session will also load that repo's own CLAUDE.md/AGENTS.md, so don't restate
   repo conventions — just point at anything easy to miss.

   ```bash
   cat > "$SCRATCH/dispatch-<slug>.txt" <<'PROMPT'
   <the full prompt>
   PROMPT
   ```

4. **Dispatch** (`jq` does the quoting, so the prompt can contain anything):

   ```bash
   jq -n --arg project "<abs project path>" \
         --arg from "${CLAUDE_CODE_SESSION_ID:-}" \
         --rawfile prompt "$SCRATCH/dispatch-<slug>.txt" \
     '{project:$project, prompt:$prompt, provider:"claude", worktree:true, fromSessionId:$from}' \
     | curl -s -m 30 -X POST http://127.0.0.1:4281/api/dispatch \
         -H 'content-type: application/json' --data-binary @-
   ```

   Optional fields: `provider` (`claude` | `codex` | `opencode`, default claude),
   `worktree` (default here: true — set false only when the user wants it in the main
   checkout), `ticket` (a ticket id; enforces one live session per ticket — pass it
   whenever the work is a ticket). `fromSessionId` puts the new session in this
   session's chain.

   Read the response as accepted-or-not:

   - `"state":"started"` + `sessionId` → running.
   - `"state":"queued"` → **accepted**; it starts by itself. Not a failure.
   - `"state":"duplicate"` → already dispatched; `dispatchId` names the existing one.
   - HTTP 409 → that ticket already has a live session. Report it; only re-post with
     `"force":true` if the user says so.
   - `ok:false` / other 4xx/5xx → real failure; report the error.

   **Never re-post a dispatch** to "retry" a queued one — that is how two agents end
   up racing on the same worktree. Wait on it instead (below).

5. **Report** the dispatch id and session id (or "queued"), one line per dispatch.
   Do NOT also do the work yourself.

   When the response contains `subscriptionId`, status and recent assistant output
   are queued into your session automatically on completion, questions, exit or
   failure. End your turn and wait for the notification; no background command is
   needed. The parent id supplied to dispatch establishes this subscription before
   the child starts. Use `oracle_session_subscribe` for other sessions, and
   `oracle_session_unsubscribe` to stop following one.

   Follow-up only when the response has no `subscriptionId` (for example a caller
   outside a juancode session):

   ```bash
   # Run in the background (run_in_background: true); returns when the agent asks for
   # input, settles idle, exits or fails to start, and the harness wakes you. Never poll
   # in a sleep loop: each check is a full turn over your context.
   curl -s 'http://127.0.0.1:4281/api/dispatches/<dispatchId>/wait?timeout=3600'
   curl -s 'http://127.0.0.1:4281/api/dispatches?limit=10'
   curl -s -X POST http://127.0.0.1:4281/api/observe \
     -H 'content-type: application/json' -d '{"sessionId":"<id>"}'   # Telegram pings
   ```

## Finish line

Use what the user asked for. If they didn't say, follow the target repo's own
shipping rules from its CLAUDE.md/AGENTS.md (e.g. juancode ships straight to main;
most work repos want a branch + PR). If those don't say either, default to: commit on a
branch, push it, open a PR, do not merge.

## Several at once

Cap at 4 concurrent (a live session is ~300MB and ~6% of a core), one task per
dispatch, and give each a non-overlapping file lane in its prompt.

Repo-specific wrappers: juancode's `dispatch-ticket` skill (bd tickets) builds on
this one.
