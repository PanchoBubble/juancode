# juancode

> One code with Juancode

A native macOS app for running the **real** Claude Code, Codex and opencode CLIs —
with all your MCP servers, auth, and slash commands intact — plus a Telegram/phone
sidecar so you can fire a task from your desk and steer it from your phone.

It spawns the genuine `claude` / `codex` / `opencode` binaries in a pseudo-terminal. Nothing
about your CLI config is intercepted or rewritten, so MCPs that work in your
terminal work here too (unlike heavier harnesses that re-plumb MCP and drop your
servers).

## Layout

- **`apps/native`** — the macOS app (Swift / SwiftUI), the primary surface: the shell
  plus the relay that serves `:4280` over WebSocket + HTTP, so remote clients have one
  address to talk to. See [apps/native/README.md](./apps/native/README.md).
- **`apps/juancoded`** — the core (`juancoded`, Rust): a separate daemon that owns the
  real ptys (`forkpty`, env untouched), the session store and the VT grid, and keeps
  your sessions running after you quit the app. See
  [apps/juancoded/README.md](./apps/juancoded/README.md).
- **`apps/oracle-mcp`** — a Node sidecar (MCP server + Telegram bridge + a small
  phone web console) that talks to the native app's embedded server on `:4280`.
  Lets you observe/steer sessions and dispatch agents from Telegram or a phone.
  See [apps/oracle-mcp/README.md](./apps/oracle-mcp/README.md).

## Requirements

- macOS with Xcode 16+ / Swift 6 (for the native app)
- A Rust toolchain via [rustup](https://rustup.rs) (for the `juancoded` core)
- Node ≥ 22 (pinned in `.nvmrc`) + [pnpm](https://pnpm.io) — for the sidecar
- `claude`, `codex` and/or `opencode` installed and authenticated on your PATH

## Quick start

The app is a client of the Rust core and refuses to launch without one, so the core
comes first. Pick one of two ways to run it.

**A. Terminal launch (dev loop).** The launch script builds `juancoded`, starts a daemon
this launch owns, runs the app, and reaps the daemon when the app exits:

```bash
apps/native/scripts/dev-app.sh                          # build core + app, run in the foreground
JUANCODE_DAEMON_PERSIST=1 apps/native/scripts/dev-app.sh # same, but sessions survive quitting the app
```

**B. LaunchAgent (Dock / Spotlight launches).** Keep the core running across app quits,
logout and reboot, then launch the app however you like:

```bash
(cd apps/juancoded && cargo build --release)   # the agent never builds; it runs what is there
pnpm daemon:agent install                      # write the plist and start the job
make install                                   # release bundle into ~/Applications
```

Telegram / phone sidecar (optional, in a second terminal):

```bash
nvm use                      # -> Node from .nvmrc
pnpm install
pnpm dev:oracle              # oracle-mcp sidecar
```

## The Rust core (`juancoded`)

The daemon owns the ptys, the VT grid and the session store, listens on **`:4290`**,
and the app relays it on `:4280`. Manage it from the repo root:

```bash
pnpm daemon:status           # what is running, who owns it, is it stale vs this checkout
pnpm daemon:restart          # move onto the current build (ends its ptys, asks first)
pnpm daemon:stop             # end it (asks first)
pnpm daemon:agent status     # LaunchAgent: installed? loaded? on whose checkout?
pnpm daemon:agent restart    # move the LaunchAgent onto a new build (asks first)
```

Things worth knowing:

- **Restarting the core ends every live session.** Nothing restarts it for you on a
  rebuild; a stale daemon shows as `rust · stale` in the app's core badge instead.
- **Data** lives in `~/.juancode/rust-core/juancoded-rust.db` (override with
  `JUANCODED_DATA_DIR`). Old Swift-core history can be imported once with
  `juancoded import-swift ~/.juancode/data/juancode.db` (daemon stopped).
- **Start it from a plain terminal**, not from inside a `claude` session: env is
  inherited as-is, so a parent Claude session's markers leak into the spawned CLIs.
- Logs: `~/.juancode/logs/juancoded.error.log` for the LaunchAgent.

Details (lifetime rules, ownership, crate layout, conformance):
[apps/juancoded/README.md](./apps/juancoded/README.md) and the "Starting the Rust
daemon" section of [apps/native/README.md](./apps/native/README.md).

## Remote access (use it from your phone)

Notifications and remote steering go over **Telegram**: set `TELEGRAM_BOT_TOKEN`
for the oracle sidecar and message the bot once so it learns your chat. You can
observe sessions, get pinged when one needs input or finishes, and reply straight
into a session from Telegram.

The sidecar also serves a small phone web console; expose it with a tunnel
(Cloudflare Tunnel or Tailscale) and put Cloudflare Access / a token in front of
it. See [apps/oracle-mcp/README.md](./apps/oracle-mcp/README.md) for the details.

## Configuration

| Env var                         | Default                 | Purpose                                               |
| ------------------------------- | ----------------------- | ----------------------------------------------------- |
| `JUANCODE_PORT`                 | `4280`                  | Native app's embedded server port                     |
| `JUANCODED_DATA_DIR`            | `~/.juancode/rust-core` | Where the core keeps its DB                           |
| `JUANCODE_DAEMON_PERSIST`       | `0`                     | `1`: the core outlives the app launch that started it |
| `JUANCODE_SESSIONS_PER_PROJECT` | `0` (no cap)            | Retention; read once at core start                    |
| `JUANCODE_CLAUDE_BIN`           | `claude`                | Path to the Claude CLI                                |
| `JUANCODE_CODEX_BIN`            | `codex`                 | Path to the Codex CLI                                 |
| `JUANCODE_OPENCODE_BIN`         | `opencode`              | Path to the opencode CLI                              |
| `JUANCODE_OPENCODE_DB`          | _(auto)_                | opencode's SQLite db (titles, usage, resume ids)      |
| `TELEGRAM_BOT_TOKEN`            | _(unset)_               | Enables the Telegram bridge                           |

## Scripts (sidecar)

- `pnpm dev` — run every `apps/*` Node package in watch mode
- `pnpm dev:oracle` — just the oracle-mcp sidecar
- `pnpm check` — lint + typecheck + test

See [AGENTS.md](./AGENTS.md) for contributor/agent guidance.
