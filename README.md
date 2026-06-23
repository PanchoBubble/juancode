# juancode

A light web harness for running the **real** Claude Code and Codex CLIs from your
browser — with all your MCP servers, auth, and slash commands intact.

It spawns the genuine `claude` / `codex` binaries in a pseudo-terminal and renders them
with xterm.js. Nothing about your CLI config is intercepted or rewritten, so MCPs that
work in your terminal work here too (unlike heavier harnesses that re-plumb MCP and drop
your servers).

## Requirements

- Node 24 (pinned in `.nvmrc`), [pnpm](https://pnpm.io)
- `claude` and/or `codex` installed and authenticated on your PATH

> The native modules (`better-sqlite3`, `node-pty`) are V8-ABI-specific, so the
> Node version you **install** with must match the one you **run** with. Run
> `nvm use` (reads `.nvmrc`) before installing or starting. If you switch Node
> versions, run `pnpm rebuild better-sqlite3 node-pty` to recompile.

## Quick start

```bash
nvm use           # -> Node 24 (see .nvmrc)
pnpm install
pnpm dev          # server on :4280, web on :5280
```

Open http://localhost:5280, pick a provider and a working directory, and start a session.

## How it works

- `apps/server` — Express + WebSocket + `node-pty` + `better-sqlite3`. One pty per
  session, inheriting your environment so MCP config loads natively. Session metadata and
  scrollback are persisted to `data/juancode.db`.
- `apps/web` — Vite + React + TanStack Router/Query + Tailwind + xterm.js.

## Configuration

| Env var                | Default            | Purpose                          |
| ---------------------- | ------------------ | -------------------------------- |
| `JUANCODE_PORT`        | `4280`             | Server port                      |
| `JUANCODE_DATA_DIR`    | `./data`           | Where the sqlite db lives        |
| `JUANCODE_DEFAULT_CWD` | your home dir      | Default dir for the dir browser  |
| `JUANCODE_CLAUDE_BIN`  | `claude`           | Path to the Claude CLI           |
| `JUANCODE_CODEX_BIN`   | `codex`            | Path to the Codex CLI            |

## Scripts

- `pnpm dev` / `pnpm dev:server` / `pnpm dev:web`
- `pnpm build` — build both apps (server then `web/dist`, which the server serves)
- `pnpm check` — lint + typecheck + test

See [AGENTS.md](./AGENTS.md) for contributor/agent guidance.
