---
name: dispatch-ticket
description: Dispatch a bd (beads) ticket to a fresh, autonomous agent session that works it end-to-end on this repo — through juancode's Oracle, so the session is a real pty in the native app. Use when the user wants to hand a ticket to a separate session ("dispatch <id>", "spin up a session for <id>", "open a new session to do <id>") rather than working it in the current context.
---

# dispatch-ticket

Hand a bd ticket to a **separate, autonomous agent session** that implements it
end-to-end, then commits and pushes. This keeps the _current_ session's context free.

The dispatch goes through the Oracle (`POST 127.0.0.1:4281/api/dispatch`), so the
session is a real `claude` pty in the native app: visible in the grid, steerable from
Telegram, isolated in its own git worktree. The generic mechanics (preflight, repo
resolution, worktree flag, follow-up endpoints, concurrency cap) live in the
user-scope **dispatch-agents** skill — read it if anything below is unclear. This
skill is the bd-ticket-shaped wrapper around it.

**Prime directive of this repo:** never inject a shadow HOME/CODEX_HOME or override
mcpServers — the dispatched CLI inherits the environment untouched, exactly like a
normal terminal. Do not pass `--model`.

## Arguments

`$ARGUMENTS` is the bd ticket id (e.g. `juancode-1u3`). If empty, ask which ticket,
or run `bd ready` and offer the top items. Never guess an id.

## Procedure

1. **Fetch the ticket** (daemon-safe — bd's cold-start can stall pipes, so always
   redirect stdio):

   ```bash
   sh -c 'bd show <id> 2>&1 </dev/null'
   ```

   Confirm it exists and read its title + description. Abort if it's already
   `closed` (tell the user) or `in_progress` under another owner. Also check the
   ticket isn't already landed on `origin/main` — a parallel session may have shipped
   it.

2. **Claim it:**

   ```bash
   sh -c 'bd update <id> --status in_progress --json >/dev/null 2>&1 </dev/null'
   ```

3. **Preflight the Oracle** (one call):

   ```bash
   curl -s -m 2 http://127.0.0.1:4281/healthz && curl -s -m 2 http://127.0.0.1:4280/presence
   ```

   Sidecar (4281) dead → start it with `pnpm dev:oracle` and stop. Native app (4280)
   dead → the dispatch is durably queued and starts on next launch; say so.

4. **Build the task prompt** — write it to the scratchpad (NOT into the repo). It
   must be self-contained (the dispatched session has fresh context). Include:
   - The ticket id, title, and full description (paste from step 1).
   - The **juancode conventions block** below, verbatim.
   - The **finish-line policy** (see "Autonomy" — default: commit + push to main).

   Write with a real heredoc (real newlines, not `\n`):

   ```bash
   cat > "$SCRATCH/dispatch-<id>.txt" <<'PROMPT'
   <the full prompt>
   PROMPT
   ```

   (`$SCRATCH` = the session scratchpad dir from the system prompt.)

5. **Dispatch** it — `jq -Rs` handles the quoting, so the prompt can contain anything:

   ```bash
   jq -n --arg project "$(git rev-parse --show-toplevel)" \
         --rawfile prompt "$SCRATCH/dispatch-<id>.txt" \
     '{project:$project, prompt:$prompt, provider:"claude", worktree:true}' \
     | curl -s -m 30 -X POST http://127.0.0.1:4281/api/dispatch \
         -H 'content-type: application/json' --data-binary @-
   ```

   The response is the truth: `started:true` + `sessionId` → really running;
   `queued:true` → app down, starts on launch; `ok:false` → a real failure, report it
   rather than retrying blind. Keep the `dispatchId`.

   The Oracle dispatches with permissions skipped, which is what makes the session
   autonomous. `worktree:true` isolates it, so it never collides with this session or
   the other agents in this tree.

6. **Report** to the user: which ticket was dispatched, the session id (or that it's
   queued), and the dispatch id. Do NOT also do the work yourself — it's dispatched.
   To follow up later:

   ```bash
   curl -s 'http://127.0.0.1:4281/api/dispatches?limit=10'
   curl -s -X POST http://127.0.0.1:4281/api/observe \
     -H 'content-type: application/json' -d '{"sessionId":"<id>"}'   # Telegram pings
   ```

## juancode conventions block (embed verbatim in the prompt)

```
You are an autonomous coding session on the juancode repo. You are in a FRESH GIT
WORKTREE off it, so start by orienting: `pwd`, `git status -sb`, `git log --oneline -3`.
Implement bd ticket <ID> end-to-end: investigate, implement, test, commit, push, close.

Repo shape: apps/native (SwiftUI macOS app that IS the server — Swift package, the
primary surface), apps/juancoded (the Rust core port), apps/oracle-mcp (Node
Telegram/phone sidecar; pnpm workspace, Node ≥22). There is no web app and no React.

Hard rules:
- The WS wire protocol lives in apps/native/Sources/JuancodeServer/WireProtocol.swift;
  the sidecar's client mirror is apps/oracle-mcp/src/native-events.ts — keep them in
  sync when touching either.
- TypeScript: verbatimModuleSyntax is on — use `import type` for type-only imports.
- Never use `Task.sleep(for:)` in apps/native — it aborts the release app; use `Nap`.
- Use real newlines in generated content. Prefer extracting shared logic over
  duplicating. Prime directive: never inject a shadow HOME/CODEX_HOME or override
  mcpServers.

Gates before done (run from repo root):
- If Swift changed: `swift build --package-path apps/native` and the narrowest
  `swift test --package-path apps/native --filter <Suite>` that covers your change
  (never the full suite). `swift build --target` does NOT relink the xctest bundle,
  and `--skip-build` runs a stale binary and fakes a pass. SourceKit "no such module"
  diagnostics after edits are stale — the build is the source of truth.
- TS: `pnpm typecheck`, `pnpm lint`, `pnpm test`. Wrap any pnpm/vitest command as
  `~/.claude/bin/heavy pnpm ...` (a hook refuses it otherwise).
- Never leave a background process behind, and never use a spin loop as load.

Commit + push (finish line):
- Verify `git config user.name` == "JuanOne" before committing.
- Stage ONLY the files you changed — the tree is live-edited by other sessions;
  never `git add -A`, add explicit paths.
- Commit message references <ID> in the body, never in an inline code comment. It must
  NOT contain any `Co-Authored-By: Claude` trailer and must be solely under the user's
  identity.
- Then: `git pull --rebase` && `git push`. Confirm `git status` is up to date with
  origin. This repo ships straight to main — do NOT open a PR unless asked.
- Close the ticket: `sh -c 'bd close <ID> --reason "<summary incl. commit sha>" 2>&1 </dev/null'`.
- File any discovered follow-ups: `sh -c 'bd create "..." --description="..." -t <type> -p <n> --deps discovered-from:<ID> --json </dev/null'`.

End your run by printing: the design, files changed, commit sha, gate results, and
any follow-ups filed.
```

## Autonomy (finish-line policy)

Default: **commit + push to main**. If the user asked for a PR instead, replace the
finish-line block with: branch `ticket/<id>`, commit, push the branch, open a PR with
`gh pr create`, DO NOT MERGE, and leave the ticket in_progress with a comment linking
the PR. If "commit only", stop after a local branch commit and don't push.

## Notes

- One ticket per dispatch (keeps the dispatched session's context tight).
- Dispatch is fire-and-forget: it does NOT notify this session on exit. Poll
  `/api/dispatches` or observe it on Telegram.
- Several tickets at once: cap at 4 concurrent (a live session is ~300MB and ~6% of a
  core) and give each one a non-overlapping file lane.
