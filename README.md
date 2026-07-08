# juancode

> One code with Juancode

A native macOS app for running the **real** Claude Code and Codex CLIs — with all
your MCP servers, auth, and slash commands intact — plus a Telegram/phone sidecar
so you can fire a task from your desk and steer it from your phone.

It spawns the genuine `claude` / `codex` binaries in a pseudo-terminal. Nothing
about your CLI config is intercepted or rewritten, so MCPs that work in your
terminal work here too (unlike heavier harnesses that re-plumb MCP and drop your
servers).

## Layout

- **`apps/native`** — the macOS app (Swift / SwiftUI), the primary surface. **The
  app is the server**: an in-process registry owns the real ptys (`forkpty`, env
  untouched) and fans output out to both the local SwiftUI view and remote clients
  over an embedded WebSocket + HTTP server on `:4280`. See
  [apps/native/README.md](./apps/native/README.md).
- **`apps/oracle-mcp`** — a Node sidecar (MCP server + Telegram bridge + a small
  phone web console) that talks to the native app's embedded server on `:4280`.
  Lets you observe/steer sessions and dispatch agents from Telegram or a phone.
  See [apps/oracle-mcp/README.md](./apps/oracle-mcp/README.md).

## Requirements

- macOS with Xcode / SwiftPM (for the native app)
- Node ≥ 22 (pinned in `.nvmrc`) + [pnpm](https://pnpm.io) — for the sidecar
- `claude` and/or `codex` installed and authenticated on your PATH

## Quick start

Native app:

```bash
cd apps/native
swift run juancode-app       # the macOS app (embedded server on :4280)
```

Telegram / phone sidecar (optional, in a second terminal):

```bash
nvm use                      # -> Node from .nvmrc
pnpm install
pnpm dev:oracle              # oracle-mcp sidecar
```

## Remote access (use it from your phone)

Notifications and remote steering go over **Telegram**: set `TELEGRAM_BOT_TOKEN`
for the oracle sidecar and message the bot once so it learns your chat. You can
observe sessions, get pinged when one needs input or finishes, and reply straight
into a session from Telegram.

The sidecar also serves a small phone web console; expose it with a tunnel
(Cloudflare Tunnel or Tailscale) and put Cloudflare Access / a token in front of
it. See [apps/oracle-mcp/README.md](./apps/oracle-mcp/README.md) for the details.

## Configuration

| Env var               | Default   | Purpose                           |
| --------------------- | --------- | --------------------------------- |
| `JUANCODE_PORT`       | `4280`    | Native app's embedded server port |
| `JUANCODE_CLAUDE_BIN` | `claude`  | Path to the Claude CLI            |
| `JUANCODE_CODEX_BIN`  | `codex`   | Path to the Codex CLI             |
| `TELEGRAM_BOT_TOKEN`  | _(unset)_ | Enables the Telegram bridge       |

## Scripts (sidecar)

- `pnpm dev` — run every `apps/*` Node package in watch mode
- `pnpm dev:oracle` — just the oracle-mcp sidecar
- `pnpm check` — lint + typecheck + test

See [AGENTS.md](./AGENTS.md) for contributor/agent guidance.
