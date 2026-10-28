# AGENTS.md

## What juancode is

A **native macOS harness** for running the real `claude` (Claude Code), `codex` and
`opencode` CLIs, with a Node **Telegram/phone sidecar** for remote steering. Unlike
t3code, it does **not** reimplement the agents or their MCP plumbing — it spawns the
genuine CLI binaries in a pseudo-terminal with the user's environment inherited
untouched. That means user-scope MCP servers (`~/.claude.json`), account connectors,
`~/.codex/config.toml`, `~/.config/opencode/opencode.json`, and project `.mcp.json` all
load exactly as they do in a normal terminal. Preserving that faithfulness is the core
value of this project — never inject a shadow `HOME`/`CODEX_HOME` or override
`mcpServers`. The one sanctioned exception is a per-spawn env entry a CLI offers no flag
for (opencode's opt-in `OPENCODE_PERMISSION` bypass), set only when that session asked
for it.

## Stack

- **`apps/native`** (primary surface): Swift / SwiftUI macOS app — the shell, plus the
  relay that serves `:4280` over WebSocket + HTTP to the oracle sidecar and any remote
  client. It does not own the ptys: juancode-nqpm deleted the in-process Swift core, so
  the app connects to the daemon like every other client and refuses to launch without
  one. See [apps/native/README.md](./apps/native/README.md).
- **`apps/juancoded`**: the Rust core (`juancoded`), a separate daemon that owns the real
  ptys (`forkpty`), the VT grid, the session store and the tracked-PR watch list, and
  outlives the app. See [apps/juancoded/README.md](./apps/juancoded/README.md).
- **`apps/oracle-mcp`**: Node sidecar (Express 5 + `ws` + MCP SDK, TypeScript via `tsx`).
  MCP server + Telegram bridge + a small phone web console; talks to the native app's
  embedded server on `:4280`. Telegram is the notification/remote-steering path. It also
  owns **session recall** (`oracle_session_search` → `oracle_session_excerpt`, a local FTS5
  index over `~/.claude/projects/**/*.jsonl`) and the **SessionEnd memory-candidate hook** —
  search there first when asking "what did we decide about X"; see
  [apps/oracle-mcp/README.md](./apps/oracle-mcp/README.md).
- pnpm workspaces, Node ≥ 22 (for the sidecar only; the native app builds with SwiftPM).

## Architecture (one paragraph)

The `juancoded` daemon owns the ptys and speaks the wire protocol
(`apps/native/Sources/JuancodeServer/WireProtocol.swift` is the Swift side of it),
broadcasting session `activity` over `/ws`. The native app relays `:4280` to it, and the
oracle sidecar keeps a single long-lived WS client to that relay
(`apps/oracle-mcp/src/native-events.ts`) and fans session events out in-process to the
Telegram bridge (`telegram.ts`), which pings the relevant chat when a session needs input
or finishes and routes replies back into the session's pty. Notifications go over Telegram —
there is no Web Push.

## Conventions

- Sidecar is all TypeScript. `verbatimModuleSyntax` is on — use `import type` for type-only imports.
- Use real newlines, not escaped ones, in any generated content.
- Prefer extracting shared logic into a module over duplicating it across files.

## Before considering a task done

Run from the repo root:

- `pnpm typecheck`
- `pnpm lint`
- `pnpm test`

(`pnpm check` runs all three.) A Husky pre-commit hook runs eslint + prettier + related
vitest on staged files.

If you changed anything under `scripts/`, also run `pnpm test:scripts` (node:test over
`scripts/*.test.mjs`). It is deliberately not part of `pnpm check`: it builds real git
fixtures and spawns real processes, so it takes minutes on a loaded machine.

## Never leave a background process behind

Several tests here only fail on a loaded machine, so measuring them means generating
load. Do that with a **bounded** workload that ends by itself, typically one real
`cargo test --workspace` run you wait for. Never with a spin loop.

This rule exists because a spin loop already cost a night of a hot laptop. An agent
generating load wrote:

```sh
for i in $(seq 1 12); do (while :; do :; done) & done   # do NOT do this
...
kill $(jobs -p) 2>/dev/null                             # never reached them
```

The shell owning that job table exited before the `kill` ran, the subshells were
reparented to `launchd`, and 84 of them span for 14 hours at load average 150.

- Do not use `while :` / `while true` as a load source.
- Anything you background must be torn down by a trap that fires on every exit path,
  not by a bare `kill` at the end: `trap 'kill 0' EXIT INT TERM`.
- Before you call a task done, prove you left nothing running:

```sh
ps -Ao pid,ppid,pcpu,etime,command -r | awk 'NR>1 && $2==1 && $3>3 && /zsh|bash|node|swift|cargo|vitest|python|while/'
pgrep -fl 'while :|while true'
```

Both must print nothing. A process whose PPID is 1 has outlived its parent, so nothing
will ever clean it up but you.

## Shipping: merge to main, no PRs

For now this repo ships straight to `main` — do NOT open GitHub PRs unless explicitly
asked. Work on a branch if convenient, then land it yourself (fast-forward preferred,
e.g. `git push origin <branch>:main`) and confirm `main` is up to date. This also
applies to dispatched/background agent sessions. This is the repo's opt-in to the
Beads "team-maintainer" profile below: close beads, run the gates, commit, `bd dolt push`
and push as part of finishing.

## Run it locally

- Native app: `cd apps/native && swift run juancode-app` (embedded server on `:4280`).
- Sidecar: `pnpm dev:oracle` (or `pnpm dev` for every `apps/*` Node package).
- Requires `claude`, `codex` and/or `opencode` on PATH and authenticated. Override binary
  paths with `JUANCODE_CLAUDE_BIN` / `JUANCODE_CODEX_BIN` / `JUANCODE_OPENCODE_BIN` if needed.

## Worktree hygiene

Agent sessions each get a worktree and nothing used to prune them; on 2026-09-19 that was
a full disk (56 worktrees, 214G) and builds failing for reasons unrelated to their ticket.

- `pnpm loose` — what is uncommitted, unpushed, PR-less or prunable across every worktree.
- `pnpm sweep` — DRY RUN by default: what a sweep would remove, and why it keeps the rest.
  `--apply` removes. It keeps anything dirty, with unpushed commits, with an open PR, with
  a running session (asked of the daemon AND of the process table), younger than two days,
  or that it could not read; and it refuses to remove anything at all when the daemon is
  not answering, because then it cannot know what is live. `--apply` also takes
  `~/.juancode/worktree-reclaim.lock` first so two sweeps cannot race; a lock whose owner
  pid is gone is taken over automatically, so a killed run cannot block the next one.
  Every run appends to `~/.juancode/logs/worktree-sweep.log`.
- `apps/native/scripts/worktree-sweeper-agent.sh` installs the daily LaunchAgent
  (`com.juanone.juancode-sweeper`). It installs DISARMED — the daily run is a dry run
  until `... arm`. Read a dry run first.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:46cd31e7 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
