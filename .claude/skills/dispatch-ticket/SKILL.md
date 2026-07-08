---
name: dispatch-ticket
description: Dispatch a bd (beads) ticket to a fresh, autonomous headless `claude` session that works it end-to-end on this repo — the way the Oracle dispatches agents into projects. Use when the user wants to hand a ticket to a separate session ("dispatch <id>", "spin up a session for <id>", "open a new session to do <id>") rather than working it in the current context. Spawns a real `claude -p` process in the background.
---

# dispatch-ticket

Hand a bd ticket to a **separate, autonomous `claude` session** that implements it
end-to-end on this repo, then commits and pushes — mirroring how juancode's Oracle
dispatches real CLI sessions into projects. This keeps the _current_ session's
context free: the dispatched session runs headless in the background and reports
when it exits.

**Prime directive of this repo:** never inject a shadow HOME/CODEX_HOME or override
mcpServers — the dispatched `claude` inherits the environment untouched, exactly
like a normal terminal. Do not pass `--model` or env overrides; let it run as the
user's `claude` normally would.

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
   `closed` (tell the user) or `in_progress` under another owner.

2. **Claim it:**

   ```bash
   sh -c 'bd update <id> --status in_progress --json >/dev/null 2>&1 </dev/null'
   ```

3. **Build the task prompt** — write it to the scratchpad (NOT into the repo). It
   must be self-contained (the dispatched session has fresh context). Include:
   - The ticket id, title, and full description (paste from step 1).
   - The repo path and the **juancode conventions block** below.
   - The **finish-line policy** (see "Autonomy" — default: commit + push to main).
     Write with a real heredoc (real newlines, not `\n`):

   ```bash
   cat > "$SCRATCH/dispatch-<id>.txt" <<'PROMPT'
   <the full prompt>
   PROMPT
   ```

   (`$SCRATCH` = the session scratchpad dir from the system prompt.)

4. **Dispatch** a fresh headless session in the repo, in the background:

   ```bash
   cd <repo-root> && env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
     claude -p "$(cat "$SCRATCH/dispatch-<id>.txt")" --dangerously-skip-permissions
   ```

   Run it with `run_in_background: true`. `--dangerously-skip-permissions` is what
   makes it autonomous (no approval prompts), matching the Oracle's `skipPermissions`
   dispatch. **Unset `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN`** (as shown): a parent
   Claude Code session often has a metered API key in its env, which the spawned
   `claude` would prefer over the user's claude.ai subscription login — leading to a
   "Credit balance is too low" failure. Unsetting them makes the dispatched session
   auth via the user's normal login, exactly like a terminal (the prime directive).
   The background task re-invokes you when it exits.

5. **Report** to the user: which ticket was dispatched, that a separate `claude`
   session is now working it in the background, and that you'll relay the outcome
   when it finishes. Do NOT also do the work yourself — it's dispatched.

## juancode conventions block (embed verbatim in the prompt)

```
You are an autonomous coding session on the juancode repo at <REPO_ROOT>.
Implement bd ticket <ID> end-to-end: investigate, implement, test, commit, push, close.

Repo shape: apps/native (SwiftUI macOS app that IS the server — Swift package,
the primary surface), apps/oracle-mcp (Node Telegram/phone sidecar; pnpm
workspace, Node ≥22). The old apps/web + apps/server (browser harness) were
removed — native + Telegram only.

Hard rules:
- The WS wire protocol lives in apps/native/Sources/JuancodeServer/WireProtocol.swift;
  the sidecar's client mirror is apps/oracle-mcp/src/native-events.ts — keep them in
  sync when touching either.
- TypeScript: verbatimModuleSyntax is on — use `import type` for type-only imports.
- Use real newlines in generated content. Prefer extracting shared logic over
  duplicating. Prime directive: never inject a shadow HOME/CODEX_HOME or override
  mcpServers.

Gates before done (run from repo root):
- If Swift changed: `swift build --package-path apps/native` and
  `swift test --package-path apps/native` (add/adjust tests; mirror existing test
  style). SourceKit "no such module" diagnostics after edits are stale — the build
  is the source of truth.
- TS: `pnpm typecheck`, `pnpm lint`, `pnpm test`. NOTE: apps/server/src/beads.test.ts
  has ONE pre-existing flaky failure (a real-`bd` daemon cold-start timeout)
  UNRELATED to your change — 215/216 with only that red is acceptable; everything
  else must be green.

Commit + push (finish line):
- Verify `git config user.name` == "JuanOne" (email juan.f.d.luca@gmail.com).
- Stage ONLY the files you changed — the tree may be live-edited by other sessions;
  never `git add -A`, add explicit paths.
- Commit message references <ID>. It must NOT contain any `Co-Authored-By: Claude`
  trailer and must be solely under the user's identity.
- Then: `git pull --rebase` && `git push`. Confirm `git status` is up to date with
  origin.
- Close the ticket: `sh -c 'bd close <ID> --reason "<summary incl. commit sha>" 2>&1 </dev/null'`.
- File any discovered follow-ups: `sh -c 'bd create "..." --description="..." -t <type> -p <n> --deps discovered-from:<ID> --json </dev/null'`.

End your run by printing: the design, files changed, commit sha, gate results
(call out the beads flake if it appears), and any follow-ups filed.
```

## Autonomy (finish-line policy)

Default: **commit + push to main**. If the user asked for a PR instead, replace the
finish-line block with: branch `ticket/<id>`, commit, push the branch, open a PR with
`gh pr create` (body ends with the standard Claude Code attribution line), and leave
the ticket in_progress with a comment linking the PR. If "commit only", stop after a
local branch commit and don't push.

## Notes

- One ticket per dispatch (keeps the dispatched session's context tight).
- Dispatch is fire-and-forget; the background task notifies on exit. Relay the result.
- If `claude` isn't on PATH, say so — dispatch requires the real CLI (as the whole
  project does).
