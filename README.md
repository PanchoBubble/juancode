# juancode

> One code with Juancode

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
- `apps/native` — a native macOS port (Swift / SwiftUI, epic `juancode-u34`) where **the
  app is the server**: an in-process registry owns the real ptys (`forkpty`, env
  untouched) and fans output out to both the local SwiftUI view and remote browser/phone
  clients over an embedded WebSocket server, so `apps/web` works against it unchanged. See
  [apps/native/README.md](./apps/native/README.md).

## Configuration

| Env var                | Default                 | Purpose                                                                                                       |
| ---------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------- |
| `JUANCODE_PORT`        | `4280`                  | Server port                                                                                                   |
| `JUANCODE_DATA_DIR`    | `./data`                | Where the sqlite db lives                                                                                     |
| `JUANCODE_DEFAULT_CWD` | your home dir           | Default dir for the dir browser                                                                               |
| `JUANCODE_CLAUDE_BIN`  | `claude`                | Path to the Claude CLI                                                                                        |
| `JUANCODE_CODEX_BIN`   | `codex`                 | Path to the Codex CLI                                                                                         |
| `JUANCODE_TOKEN`       | _(unset)_               | Access token for remote use (see below)                                                                       |
| `JUANCODE_SERVER`      | `http://localhost:4280` | Backend `pnpm dev:web` proxies to — point it at a Mac app's embedded server (e.g. `http://my-mac.local:4280`) |

## Remote access (use it from your phone)

The headline feature of a web harness: fire a task from your laptop, then check
and steer it from your phone. Two things make that safe and reachable — a token
and a tunnel.

### 1. Turn on auth with `JUANCODE_TOKEN`

By default juancode is localhost-only with **no auth** — exactly as before.
Setting `JUANCODE_TOKEN` opts in to token auth on **every** HTTP request and the
WebSocket. Leave it unset for normal local development.

```bash
JUANCODE_TOKEN="$(openssl rand -hex 24)" pnpm dev
```

The token is accepted via an `Authorization: Bearer <token>` header, a
`?token=<token>` query param, or an httpOnly cookie. On a phone, just open the
URL once with `?token=…` appended — the server sets a cookie and you can bookmark
the bare URL afterwards:

```
https://your-tunnel-host/?token=YOUR_TOKEN
```

If you open the URL without a token you get a small sign-in page; the web app
also prompts for the token if a request comes back unauthorized.

> ⚠️ **The token is the only thing between the public internet and a shell on your
> machine.** Use a long random value, serve over HTTPS (both tunnels below do),
> and treat it like a password. Never expose juancode publicly without it.

### 2. Expose it with a tunnel

juancode does **not** bundle or spawn a tunnel — that keeps the CLI-faithfulness
promise (your real environment, untouched) and avoids shipping a network daemon
you didn't ask for. Bring your own tunnel; both of these are one command and give
you HTTPS:

**Cloudflare Tunnel** (quick, no account needed for a throwaway URL):

```bash
JUANCODE_TOKEN="$(openssl rand -hex 24)" pnpm dev   # in one terminal
cloudflared tunnel --url http://localhost:4280       # in another
```

`cloudflared` prints a `https://<random>.trycloudflare.com` URL. Open it with
`?token=…` appended.

**Tailscale** (private to your tailnet, or public via Funnel):

```bash
# Private to your own devices (recommended):
tailscale serve http://localhost:4280

# Or expose publicly on the internet (Funnel — pair with JUANCODE_TOKEN!):
tailscale funnel http://localhost:4280
```

Point the tunnel at the **server** port (`4280`, where the built web app is
served), not the Vite dev port. For remote use, build first so the server serves
the app: `pnpm build`, then `pnpm --filter @juancode/server start`.

## Scripts

- `pnpm dev` / `pnpm dev:server` / `pnpm dev:web`
- `pnpm build` — build both apps (server then `web/dist`, which the server serves)
- `pnpm check` — lint + typecheck + test

See [AGENTS.md](./AGENTS.md) for contributor/agent guidance.
