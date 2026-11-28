---
name: dispatch-ticket
description: Dispatch a bd (beads) ticket to a fresh, autonomous agent session that works it end-to-end on this repo through juancode's Oracle. Use when the user asks to dispatch a ticket or start a separate session for it, rather than work it in the current context. Follows the shared dispatch-agents provider policy.
---

# dispatch-ticket

Hand a bd ticket to a **separate, autonomous agent session** that implements it
end-to-end, then commits and pushes. This keeps the _current_ session's context free.

The mechanics (preflight, worktree flag, provider choice, model table, response states,
notifications, concurrency cap) live in the **dispatch-agents** skill (source:
`.claude/user-skills/dispatch-agents/`; install steps are in it). Read it; this skill only
adds the bd-ticket specifics. Set `DISPATCH_PROVIDER` as it says; do not hardcode Claude.

**Prime directive of this repo:** never inject a shadow HOME/CODEX_HOME or override
mcpServers — the dispatched CLI inherits the environment untouched, exactly like a
normal terminal. Pick `model` from the dispatch-agents **Model by role** table (the only
place those defaults live); never pass CLI flags.

## Arguments

`$ARGUMENTS` is the bd ticket id (e.g. `juancode-1u3`). If empty, ask which ticket,
or run `bd ready` and offer the top items. Never guess an id.

## Procedure

1. **Fetch the ticket** (daemon-safe — bd's cold-start can stall pipes, so always
   redirect stdio):

   ```bash
   sh -c 'bd show <id> 2>&1 </dev/null'
   ```

   Confirm it exists and read its status. Abort if it's already
   `closed` (tell the user) or `in_progress` under another owner. Also check the
   ticket isn't already landed on `origin/main` — a parallel session may have shipped
   it.

2. **Claim it:**

   ```bash
   sh -c 'bd update <id> --status in_progress --json >/dev/null 2>&1 </dev/null'
   ```

3. **Preflight** the Oracle as dispatch-agents describes (sidecar down: `pnpm dev:oracle`).

4. **Build the task prompt** in the scratchpad (NOT the repo). Do not paste the
   ticket: the child runs `bd show <id>` itself. The prompt is the **juancode
   conventions block** below with `<ID>` filled in, plus only what the ticket does
   not say (decisions made, files other sessions are editing, a lane restriction, a
   PR-instead-of-push finish line from "Autonomy"). Keep the first line's
   "Implement bd ticket <ID> end-to-end" wording; the dispatch guard reads the id
   from it.

   ```bash
   cat > "$SCRATCH/dispatch-<id>.txt" <<'PROMPT'
   <the block, plus extras>
   PROMPT
   ```

   (`$SCRATCH` = the session scratchpad dir from the system prompt.)

5. **Dispatch** it — `jq` handles the quoting, so the prompt can contain anything:

   ```bash
   jq -n --arg project "$(git rev-parse --show-toplevel)" --arg ticket "<id>" \
         --arg provider "$DISPATCH_PROVIDER" \
         --arg model "<model from the role table>" \
         --arg from "${CLAUDE_CODE_SESSION_ID:-${CODEX_THREAD_ID:-}}" \
         --rawfile prompt "$SCRATCH/dispatch-<id>.txt" \
     '{project:$project, prompt:$prompt, provider:$provider, model:$model, worktree:true, ticket:$ticket, fromSessionId:$from}' \
     | curl -s -m 30 -X POST http://127.0.0.1:4281/api/dispatch \
         -H 'content-type: application/json' --data-binary @-
   ```

   Pass `ticket` — it is what stops a second session landing on the same bd id.
   Pass `fromSessionId` — it puts the new session in this session's chain (starting
   one named after this session if it is in none). An empty one is ignored.

   The response is the truth. Read `state`, and read it as accepted-or-not:

   - `"state":"started"` + `sessionId` → session created (not proof it is working;
     check the exact id in `GET :4281/api/sessions` and its screen/transcript before
     saying so).
   - `"state":"queued"` → **accepted**, the app just didn't ack in time; it starts by
     itself. This is NOT a failure and NOT something to post again.
   - `"state":"duplicate"` → this was already dispatched; `dispatchId` is the one that
     exists. Nothing new was created.
   - HTTP 409 → that ticket already has a live session. Report it; do not force past
     it without asking.
   - `ok:false` / another 4xx → a real failure (bad path, unknown provider). Report it.

   **Never re-post a dispatch** (that is how `juancode-h1an` got two agents racing on
   one worktree). Keep the `dispatchId` and wait on it (see Notes).

6. **Report** to the user: which ticket was dispatched, the session id (or that it's
   queued and will start on its own), and the dispatch id. Do NOT also do the work yourself — it's dispatched.
   To follow up later:

   ```bash
   curl -s 'http://127.0.0.1:4281/api/dispatches?limit=10'
   curl -s -X POST http://127.0.0.1:4281/api/observe \
     -H 'content-type: application/json' -d '{"sessionId":"<id>"}'   # Telegram pings
   ```

## juancode conventions block (embed in the prompt, `<ID>` filled in)

The child also loads this repo's AGENTS.md (gates, shipping, conventions), so this
holds only what is easy to miss.

```
You are an autonomous coding session on the juancode repo, in a FRESH GIT WORKTREE.
Orient: `pwd`, `git status -sb`, `git log --oneline -3`.
Implement bd ticket <ID> end-to-end: read it with `sh -c 'bd show <ID> 2>&1 </dev/null'`,
then investigate, implement, test, commit, push, close.

Easy to miss:
- Wire protocol: apps/native/Sources/JuancodeWire/WireProtocol.swift and its
  sidecar mirror apps/oracle-mcp/src/native-events.ts change together.
- Never `Task.sleep(for:)` in apps/native (aborts the release app); use `Nap`.
- Swift gate: `swift build --package-path apps/native` plus the narrowest
  `swift test --package-path apps/native --filter <Suite>` (never the full suite;
  `--skip-build` fakes a pass). Stale SourceKit "no such module" is noise.
- TS gate: `~/.claude/bin/heavy pnpm typecheck|lint|test` (a hook refuses bare pnpm).
- Leave no background process behind; no spin loops as load.

Finish line:
- `git config user.name` must be "JuanOne". Stage ONLY your files by explicit path
  (the tree is live-edited by other sessions). In the commit body (not code
  comments) reference <ID>; no `Co-Authored-By` trailer.
- `git pull --rebase` && `git push` (ships to main, no PR unless asked); confirm
  `git status` is up to date.
- `sh -c 'bd close <ID> --reason "<summary incl. commit sha>" 2>&1 </dev/null'`.
- Follow-ups: `sh -c 'bd create "..." --description="..." -t <type> -p <n> --deps discovered-from:<ID> --json </dev/null'`.

End by printing: the design, files changed, commit sha, gate results, follow-ups filed.
```

## Autonomy (finish-line policy)

Default: **commit + push to main**. If the user asked for a PR instead, replace the
finish-line block with: branch `ticket/<id>`, commit, push the branch, open a PR with
`gh pr create`, DO NOT MERGE, and leave the ticket in_progress with a comment linking
the PR. If "commit only", stop after a local branch commit and don't push.

## Notes

- One ticket per dispatch; several at once follow the dispatch-agents cap and lanes.
- With `fromSessionId` the response has a `subscriptionId`: results arrive in your
  message queue; end your turn and wait. Otherwise use the dispatch-agents wait
  command. Never poll in a sleep loop.
