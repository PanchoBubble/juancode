# AGENTS.md

## What juancode is

A **light web harness** for running the real `claude` (Claude Code) and `codex` CLIs
from a browser. Unlike t3code, it does **not** reimplement the agents or their MCP
plumbing — it spawns the genuine CLI binaries in a pseudo-terminal (`node-pty`) with
the user's environment inherited untouched. That means user-scope MCP servers
(`~/.claude.json`), account connectors, `~/.codex/config.toml`, and project `.mcp.json`
all load exactly as they do in a normal terminal. Preserving that faithfulness is the
core value of this project — never inject a shadow `HOME`/`CODEX_HOME` or override
`mcpServers`.

## Stack

- **Backend** `apps/server`: Express 5 + `ws` + `node-pty` + `better-sqlite3`, TypeScript, run via `tsx`.
- **Frontend** `apps/web`: Vite + React 19 + TanStack Router + TanStack Query + Tailwind v4 + xterm.js.
- pnpm workspaces, Node ≥ 22.

## Architecture (one paragraph)

The browser holds one shared WebSocket (`apps/web/src/lib/socket.ts`) to the server's
`/ws`. Each session is one pty running a real CLI (`apps/server/src/session.ts`),
tracked live in an in-memory registry and persisted (metadata + capped scrollback) to
sqlite (`apps/server/src/db.ts`) so history survives restarts. xterm.js renders the pty
stream faithfully; keystrokes flow back as `input` messages. The wire protocol lives in
`apps/server/src/protocol.ts` and is mirrored in `apps/web/src/protocol.ts` — **keep the
two in sync**.

## UI components — IMPORTANT

Before building any non-trivial UI component from scratch, first check
**https://github.com/brillout/awesome-react-components** for a well-maintained existing
library that fits. Prefer a vetted component over a hand-rolled one. Only build custom
when nothing suitable exists or the dependency cost isn't justified.

## Conventions

- All TypeScript. `verbatimModuleSyntax` is on — use `import type` for type-only imports.
- Use real newlines, not escaped ones, in any generated content.
- Prefer extracting shared logic into a module over duplicating it across files.

## Before considering a task done

Run from the repo root:

- `pnpm typecheck`
- `pnpm lint`
- `pnpm test`

(`pnpm check` runs all three.) A Husky pre-commit hook runs eslint + prettier + related
vitest on staged files.

## Run it locally

- `pnpm dev` — runs server (`:4280`) and web (`:5280`) together. Open http://localhost:5280.
- Requires `claude` and/or `codex` on PATH and authenticated. Override binary paths with
  `JUANCODE_CLAUDE_BIN` / `JUANCODE_CODEX_BIN` if needed.
