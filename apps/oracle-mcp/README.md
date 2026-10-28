# @juancode/oracle-mcp

An MCP sidecar that exposes the juancode **Oracle** (the global orchestrator) to a
remote MCP client — e.g. the **Claude mobile app** — so you can manage global
issues, dispatch agents into projects, list running sessions, and talk to the
Oracle from your phone.

The pty/agent work always stays on the Mac (the CLAUDE.md prime directive). This
sidecar only **relays intent and reads state**:

| Tool                     | What it does                                        | Mechanism                                                                                                                                                                                      |
| ------------------------ | --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `oracle_list_issues`     | List the Oracle's global `bd` items (ready-flagged) | `bd --sandbox list` in `~/.juancode/oracle`                                                                                                                                                    |
| `oracle_create_issue`    | Create a global tracker item                        | `bd create`                                                                                                                                                                                    |
| `oracle_dispatch`        | Spawn/seed an agent in a project                    | WS `create` with ack; falls back to `dispatch.jsonl` when the app is down                                                                                                                      |
| `oracle_dispatch_status` | What happened to a dispatch                         | merges `oracle-dispatches.json` + `dispatch-results.jsonl` + live `/api/sessions`                                                                                                              |
| `oracle_list_sessions`   | List live + persisted sessions                      | `GET` the native app's `/api/sessions`                                                                                                                                                         |
| `oracle_session_screen`  | What a session's pane shows right now               | `GET /api/sessions/:id/screen` — the RENDERED grid, not the byte log; falls back to `/scrollback` for a reaped pty or a core without the route                                                 |
| `oracle_ask`             | Ask the live Oracle agent                           | append `ask.jsonl` (native app tails it)                                                                                                                                                       |
| `oracle_session_handoff` | Hand a long session off to a fresh one              | `session-handoff.ts`: queue the note request, read the reply's note, WS `create` the successor, `createHandoff`, `sleepSession`. Also `POST /api/sessions/:id/handoff` (the native row action) |

`dispatch` is WS-first: with the app up you get a real ack (the session id, or the
real error for a bad path/provider); with the app down the dispatch is durably
queued in `dispatch.jsonl` and starts exactly once on the app's next launch (the
app persists its mailbox offset and dedupes by `dispatchId`). Outcomes are also
written to `dispatch-results.jsonl`, which the sidecar tails to relay failures —
and queued-dispatch starts — to Telegram. `ask` requires the **native app to be
running**. `list_issues`/`create_issue` work whenever `bd` is installed.

Dispatch through MCP or `POST /api/dispatch` automatically selects a model without
an extra LLM call. Clearly bounded chores (short spelling/formatting/rename/summary
requests) use Codex `gpt-6-luna`; ordinary or ambiguous work uses Claude `sonnet`;
architecture, security, migrations and concurrency hazards use Claude `opus`.
This is a conservative prompt heuristic, not a guarantee of difficulty or savings.
For ticket-only prompts, the orchestrator should supply `complexity` (`simple`,
`standard`, `complex`) using the ticket's actual scope.

An explicit `provider` pins the provider: Claude tiers are `haiku`/`sonnet`/`opus`,
Codex tiers are `gpt-6-luna`/`gpt-6.1-sol`/`gpt-6-astra`. An explicit `model` wins;
`model: "default"` preserves the CLI's configured model. A model override without
a provider uses Claude, as before. OpenCode keeps its CLI default unless configured.
Customize a tier for available account models with sidecar environment variables
`JUANCODE_DISPATCH_<CLAUDE|CODEX|OPENCODE>_<SIMPLE|STANDARD|COMPLEX>_MODEL`;
use `default` as the value to keep CLI configuration. No CLI environment is replaced.
Codex model IDs follow [the official model guide](https://learn.chatgpt.com/docs/models);
account availability can differ. Unavailable models surface the CLI's own error.

The reply's `modelSelection` and dispatch registry expose provider, model, complexity,
and routing reason. Offline dispatches persist the chosen model so replay cannot
silently choose a different one. Direct writes to `dispatch.jsonl` bypass sidecar
routing; use the API/MCP entry point for automatic selection.

Every dispatch this sidecar creates is also recorded in `oracle-dispatches.json`
(args + outcome + the originating Telegram chat when there is one), the native app
persists the `dispatchId` on the session it spawns, and the `activity` broadcast
carries it back — so when a dispatched agent needs input or finishes, the bridge
pings the chat that dispatched it, no `/observe` needed. `GET /api/dispatches`
lists recent dispatches with their merged outcomes for the console.

## Two ways to reach it from a phone

1. **Web console (no Claude plan requirement).** The sidecar serves a mobile-first
   page at `/` plus a small REST API. Open `https://oracle.<your-domain>/` in a
   phone browser, authenticate once via Cloudflare Access (browser cookie), and use
   the **Issues / Sessions / Chat** tabs. **Chat** runs a headless `claude -p` turn
   in the control dir (clean text, no TUI) with conversation continuity. This is the
   path to use when custom MCP connectors aren't available on your Claude plan.
2. **MCP custom connector.** If your Claude plan supports custom connectors, add
   `https://oracle.<your-domain>/mcp` directly (see step 4 below). Same capabilities,
   exposed as MCP tools.

Both are gated by the same Cloudflare Access app.

### Headless chat auth (important)

The Chat tab shells out to `claude -p` in `~/.juancode/oracle`. The sidecar **strips
`ANTHROPIC_API_KEY` from that subprocess** so claude uses your **claude.ai
subscription + connectors** — identical to how the GUI Oracle authenticates (the key
is only present in interactive shells via `~/.zshrc`, never in the GUI app's login
env, and when set it _disables_ claude.ai connectors). Run `JUANCODE_CLAUDE_BIN` /
ensure `claude` is on PATH and logged in.

## Architecture

**This sidecar stays** — decided in juancode-52e8.14.7 and not to be re-opened. The
Swift core is retired in favour of `apps/juancoded` (Rust), and the daemon absorbs nothing of
what is here: Telegram, the phone console, voice transcription, triggers, cron, the
dispatch registry and the MCP server are not core work and gain nothing from Rust. The
seam is the one long-lived WS in `src/native-events.ts`, and it already survived the core
swap. The daemon owes this sidecar a complete `activity` stream, which it emits; the one
thing it now sends itself is the user's outbound notification webhook, because that has
to keep firing with the desktop app closed. See `apps/juancoded/README.md` →
"Notifications".

```
Phone (Claude app, custom connector)
  │  MCP over HTTPS  +  OAuth via Cloudflare Access
  ▼
Cloudflare Access  (Zero Trust — gated to your email)
  │  Cloudflare Tunnel (cloudflared on the Mac; no inbound ports opened)
  ▼
oracle-mcp  (this sidecar, 127.0.0.1:4281)
  ├─ bd / dispatch.jsonl / ask.jsonl   (Oracle control dir)
  └─ GET 127.0.0.1:4280/api/sessions   (native app's embedded server)
```

### What 4280 is

The sidecar always talks to `127.0.0.1:4280` (`JUANCODE_PORT` / `JUANCODE_API`).
What answers there is a **relay**: `/ws` is forwarded verbatim to the `juancoded`
daemon, and the REST session reads are answered from the desktop's mirror of the
daemon's rows. It is served by the SwiftUI app while that is up, and by
`juancode-serve` (`swift run juancode-serve`) while it is not.

There used to be a second answer here — the app's own in-process Swift core, which
served the full REST set out of its own registry. juancode-nqpm deleted it, so 4280
means one thing now.

| 4280 is               | `/ws`                   | REST                                            |
| --------------------- | ----------------------- | ----------------------------------------------- |
| a relay to the daemon | forwarded to the daemon | sessions + search + delete, everything else 501 |

The `juancoded` daemon on `JUANCODED_PORT` (4290) serves only `/health`,
`/api/health` and `/ws`, so pointing `JUANCODE_API` straight at it would leave the
session list, the delete and the PR webhook with nothing to answer them. The relay
exists so one address answers all of it. Its `/api/health` says what is behind it
(`{"core":"rust","relayingTo":"http://127.0.0.1:4290"}`).

Two consequences worth knowing:

- **Nothing serving 4280, daemon up.** The sidecar is blind even though the daemon
  is still running ptys: no notifications, no steering, no dispatch. That is what
  `juancode-serve` is for (juancode-eko6) — run it and the desktop can stay closed.
- **Capabilities are read, never assumed.** Anything the handshake does not
  advertise is refused with that list rather than reported as done. `/ws` frames the
  relay cannot answer come back 501 rather than silently succeeding.

## 1. Run the sidecar

```sh
pnpm --filter @juancode/oracle-mcp start
# → oracle-mcp listening on http://127.0.0.1:4281/mcp
```

Environment variables (all optional):

| Var                              | Default                 | Purpose                                                                                                                                                              |
| -------------------------------- | ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ORACLE_MCP_PORT`                | `4281`                  | Port the sidecar listens on                                                                                                                                          |
| `ORACLE_MCP_HOST`                | `127.0.0.1`             | Bind address (keep on localhost — the tunnel reaches it)                                                                                                             |
| `JUANCODE_ORACLE_DIR`            | `~/.juancode/oracle`    | Oracle control dir (mailboxes + `bd` tracker)                                                                                                                        |
| `JUANCODE_API`                   | `http://127.0.0.1:4280` | Native app's embedded server base URL                                                                                                                                |
| `JUANCODE_BD_BIN`                | `bd`                    | Path to the `bd` binary                                                                                                                                              |
| `TELEGRAM_BOT_TOKEN`             | _(unset)_               | BotFather token. When set, the sidecar long-polls Telegram and routes messages through the same Oracle chat backend as the browser console. Unset ⇒ bridge disabled. |
| `ALLOWED_USER_IDS`               | _(empty)_               | Comma/space-separated numeric Telegram user ids allowed to use the bridge. Empty ⇒ every message is ignored.                                                         |
| `JUANCODE_GH_WEBHOOK_SECRET`     | _(unset)_               | HMAC secret for `POST /api/github-webhook`. Unset ⇒ the endpoint answers 503 and PR tracking stays poll-only. See "GitHub webhooks" below.                           |
| `JUANCODE_CONTEXT_ALERT_PERCENT` | `80`                    | Context-pressure line (percent of the model's window) that pings observing Telegram chats. `0` disables it. See "Cost + context alerts".                             |
| `JUANCODE_SESSION_SPEND_CAP_USD` | _(unset)_               | Estimated spend on one session that pings observing chats, in USD. Unset/`0` ⇒ no spend alerts.                                                                      |
| `JUANCODE_HANDOFF_ALERT_TOKENS`  | `250000`                | Context size in tokens past which observing chats are told a handoff would be cheaper. `0` disables it. See "Session handoff".                                       |

### Cost + context alerts (juancode-lncw)

The native app derives per-session token/cost usage from the CLI's own transcripts
and puts it on `SessionMeta.usage` — including **context pressure**: what the live
conversation currently occupies of the model's context window (the newest turn's
input + cache tokens), against a window from the price table in the Swift core. The
sidecar reads that off the `sessionMeta` frames it already receives, so this adds
nothing to the wire protocol and nothing to any request path.

`usage-alerts.ts` latches **one alert per crossing**, not one per poll: a session that
climbs past `JUANCODE_CONTEXT_ALERT_PERCENT` pings the chats observing it (plus the
chat a dispatch came from) once, then stays quiet while it keeps filling. A compaction
that drops it clear of the line re-arms the alert. A spend cap fires exactly once —
an estimate only grows.

Nothing here steers a session: no compaction, no pause, no cap enforcement. It exists
so a wall is visible before you hit it.

### Session handoff (juancode-u5q)

Cache reads dominate spend: a session at 400k context re-reads all of it every turn.
A second latch fires once when a session's context passes `JUANCODE_HANDOFF_ALERT_TOKENS`
(absolute tokens, default 250k — the Swift badge turns purple at the same line, set in
Settings › Sessions) and suggests a handoff. Nothing hands off on its own.

A handoff (`oracle_session_handoff`, or the session row's "Hand Off to Fresh Session",
which calls `POST /api/sessions/:id/handoff`) runs `session-handoff.ts` once for both:
it queues a one-line request for a ≤60-line note between `<<<HANDOFF>>>` and
`<<<END HANDOFF>>>` (through the queue, so it never types over a draft), waits for the
session to settle, and takes the note from the reply. No note, a question back, or a
timeout refuses and changes nothing. Otherwise it spawns the successor in the same
checkout with the same provider, model and permission mode and the note as its first
prompt, records the handoff in the daemon's chain handoff history (making a chain for
the old session if it has none), and puts the old session to sleep — dormant and
resumable. Nothing is written to the repo or the worktree.

### Telegram bridge (juancode-c6y)

With `TELEGRAM_BOT_TOKEN` set, you can chat with Oracle from Telegram using the
**same brain and session model** as the browser console — each message is routed
through `oracleChat` (headless `claude -p` with `--resume`), identical to `/api/chat`.
Transport is long-poll `getUpdates` (no webhook), so it works behind the existing
`oracle` Cloudflare Tunnel with no inbound port. Each Telegram chat keeps its **own**
`claude` session id (separate from the browser thread, no cross-talk); `/new` (or
`/start`) resets it. Replies are chunked to Telegram's 4096-char limit. Only users in
`ALLOWED_USER_IDS` are answered; everyone else is silently ignored.

#### Replies and pings

Every session-scoped bot message (a needs-input or finish ping, a stuck advisory, a
`✅ Sent to` confirmation, an `/api/notify` ping) is logged with its Telegram message id
in `~/.juancode/oracle/oracle-telegram-outbound.json`. A Telegram **reply** to one of
them is resolved through that log and typed into that session's pty. A plain message
with no reply-to, or a reply to anything not in the log, goes to the Oracle chat
(`oracle-telegram-sessions.json`, one Oracle session per chat).

A message sent straight to the Bot API (curl with the token) is not in the log, so a
reply to it can only reach the Oracle. To ping about a session so replies route back to
it, use `POST /api/notify` or the `oracle_notify_session` MCP tool:

```sh
curl -s -X POST 127.0.0.1:4281/api/notify -H 'Content-Type: application/json' \
  -d '{"sessionId":"<full session id>","text":"Need a decision on X"}'
```

A finish ping goes out once per turn: a replayed settle is deduped, but once the session
goes busy again, or a Telegram reply is delivered to it, its next finish pings again.

#### Control keys (juancode-uigs)

A reply — typed or tapped — is **bracketed-pasted**, which is what makes it literal: the
CLI keeps the bytes and never reads them as keystrokes. So Esc, Ctrl-C and the arrows
needed a path of their own, and without it two things were unreachable from a phone:
interrupting a runaway agent, and answering a permission prompt, which is exactly what
claude stops on and drives with arrows + Enter.

A needs-input ping and a stuck advisory now carry a keypad (`Esc  ⌃C  ↑  ↓  ⏎`), and
`/keys <n|id>` posts one for any session. The phone console's live session view has the
same row, and `POST /api/keys {sessionId, keys}` / the `oracle_session_keys` MCP tool are
the programmatic forms.

The buttons send key **names**, never bytes: the vocabulary (`Enter`, `Escape`, `Tab`,
`Backspace`, `Space`, `Up`, `Down`, `Left`, `Right`, `C-a` … `C-z`) belongs to the core,
which resolves it on the `key` wire frame behind the `namedKeys` capability. A core too
old to know that frame gets the bytes resolved here instead — still raw, still never
bracketed-pasted. An unknown name is refused rather than typed into the agent's prompt
box.

Config is read from the process env, with a fallback `apps/oracle-mcp/.env`
(gitignored) loaded at startup — a real shell export always wins over the file. Copy
`.env.example` to `.env` and fill in `TELEGRAM_BOT_TOKEN` + `ALLOWED_USER_IDS` (the bot
is `@main_claw_mc_bot`, carried over from the deprecated juan-code Codex bot).

Smoke-test locally with the MCP Inspector or curl:

```sh
curl -s http://127.0.0.1:4281/healthz
curl -s -X POST http://127.0.0.1:4281/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

## 2. Cloudflare Tunnel

Requires a domain on a Cloudflare-managed zone and `cloudflared` installed
(`brew install cloudflared`).

```sh
cloudflared tunnel login                     # authorize your zone
cloudflared tunnel create oracle             # creates a tunnel + credentials file
cloudflared tunnel route dns oracle oracle.<your-domain>
```

`~/.cloudflared/config.yml`:

```yaml
tunnel: oracle
credentials-file: /Users/<you>/.cloudflared/<TUNNEL-UUID>.json
ingress:
  - hostname: oracle.<your-domain>
    service: http://127.0.0.1:4281
  - service: http_status:404
```

Run it (and later install as a launchd service with `cloudflared service install`
so it survives reboots — pairs with the wake helper in juancode-u34.8):

```sh
cloudflared tunnel run oracle
```

## 3. Cloudflare Access (OAuth gate)

This is what lets the phone authenticate. In **Zero Trust → Access → Applications**:

1. **Add an application → Self-hosted.** Public hostname: `oracle.<your-domain>`.
2. **Advanced settings → enable "Managed OAuth".** This makes Access expose the
   standard OAuth 2.0 endpoints (`/authorize`, `/token`, dynamic client
   registration) that the Claude app's connector flow expects, and lets
   non-browser clients complete the flow.
3. **Policy:** Allow → Include → _Emails_ → your email. For the login method, a
   **One-time PIN** identity provider needs no external IdP.
4. Save. Access now intercepts unauthenticated requests to `oracle.<your-domain>`,
   runs the OAuth login, and injects a `Cf-Access-Jwt-Assertion` header before
   traffic reaches the sidecar.

> Note: Cloudflare's MCP-with-Access docs are written around Workers origins, but a
> self-hosted Access app is just _a public hostname_ and the Tunnel provides exactly
> that — so the same **Managed OAuth** toggle covers this tunnel origin. Validate the
> OAuth handshake end-to-end when you add the connector (step 4); that's the one part
> to confirm live.

## Session recall (`oracle_session_search` / `oracle_session_excerpt`)

Every agent already writes its sessions somewhere, so recall reads what is on disk
instead of capturing anything new — no vector DB, no extra runtime, no always-on worker.
`transcript-index.ts` keeps a SQLite FTS5 index at
`~/.juancode/data/transcript-index.db` and refreshes it on every search.

One store, several readers (an `IndexSource` each):

| agent      | source                                                     | incremental on                                 |
| ---------- | ---------------------------------------------------------- | ---------------------------------------------- |
| `claude`   | `~/.claude/projects/<slug>/<sessionId>.jsonl`              | file mtime + size, reading only appended bytes |
| `opencode` | `~/.local/share/opencode/opencode.db` (`message` + `part`) | `time_updated`, message and parts alike        |

Every row carries its `agent`, and every hit returns it, so an answer can say which agent
said a thing. Rows are **never** merged across agents — two agents saying the same thing
is a signal. `agents: ["opencode"]` narrows a search; omit it for all of them.

The opencode DB is opened read-only and never written to (a live opencode session holds
it in WAL mode); if a read-only open is refused, the reader falls back to a throwaway
copy. opencode stores reasoning as plain text, so recall reaches the real thinking there,
unlike Claude Code's transcripts.

Two tools, on purpose:

| tool                     | returns                                                                      |
| ------------------------ | ---------------------------------------------------------------------------- |
| `oracle_session_search`  | compact hit list — id, agent, session, project, branch, ts, one-line snippet |
| `oracle_session_excerpt` | full text for **one** id, optionally ±N surrounding turns                    |

Dumping matches straight into context is what makes transcript recall expensive, so the
hit list carries no bodies. Ask for the ids that look relevant, nothing more.

First call builds the whole index (~9s for 940 Claude files / 121k entries here, plus
~4s for 3.3k opencode messages); later calls refresh in ~100ms. Overrides:
`JUANCODE_CLAUDE_PROJECTS_DIR`, `JUANCODE_OPENCODE_DB`, `JUANCODE_TRANSCRIPT_INDEX_DB`.

The index is **local only**. Transcripts contain confidential tool output, so nothing
here fans out on its own — no web-console view, no Telegram surface. Callers decide what
to surface.

## Chains (`chain_*` tools, Telegram `/chains`)

A chain is a named, cross-project group — sessions (Oracles included), tracked PRs,
beads issues and Linear tickets — that the **daemon** keeps (see
[apps/juancoded/README.md](../juancoded/README.md#chains-named-groups-of-work)). The
sidecar holds no copy of its own: `native-events.ts` mirrors the book off the shared
`:4280` socket and every write goes to the core and waits for its `chainResult`.
`src/chains.ts` is the one reader and writer, so the tools and Telegram describe a chain
the same way.

| Tool           | What it does                                                                         |
| -------------- | ------------------------------------------------------------------------------------ |
| `chain_list`   | chains with a member count per kind; `state` = `active` (default), `inactive`, `all` |
| `chain_show`   | one chain, members grouped by kind; sessions carry project, provider and live status |
| `chain_create` | a new active chain; the slug is its id forever (`auth-rewrite`)                      |
| `chain_add`    | tag an item in, **moving** it out of any other chain (one chain per item)            |
| `chain_remove` | untag an item; with `slug`, only if it is still in that chain                        |
| `chain_close`  | mark it inactive; members stay tagged                                                |

Members are `kind` + `ref`: a session id (a unique prefix is resolved), a PR's tracked
key `<absolute repo path>#<number>` (or the number plus `prCwd`), a beads id, a Linear
identifier. `title`/`url` are a snapshot for the kinds the daemon cannot look up.

On Telegram, `/chains` lists the active chains numbered, `/chains all` every chain, and
`/chains <n|slug>` shows one. Read-only by design: tagging is the Oracle's job.

**Dispatches inherit the dispatching session's chain.** `oracle_dispatch` sends
`create.fromSessionId` (daemon capability `chainInherit`) so the new session joins the
dispatching session's chain — and the daemon starts a chain, named after that session,
when it is in none. The shared MCP endpoint does not know which session is calling, so
`src/dispatch-origin.ts` works it out: the `fromSessionId` the caller passed (a Claude
Code `$CLAUDE_CODE_SESSION_ID`, matched against `cliSessionId`, or a juancode id or
prefix), else the one running Oracle session in the control dir that is busy — an
Oracle making a tool call is mid-turn. Anything else (several busy, none, the headless
phone chat dispatching) sends no source and the session starts unchained. The field goes
on the wire only once that socket's `serverInfo` advertises `chainInherit`, and rides the
`dispatch.jsonl` line for the queued path. `POST /api/dispatch` resolves a given
`fromSessionId` the same way and infers nothing; the dispatch-ticket skill passes its own
`$CLAUDE_CODE_SESSION_ID`.

## SessionEnd memory candidates

`memory-candidates.ts` runs as a `SessionEnd` hook (wired in `.claude/settings.json`).
When a session ends it digests its own transcript, asks a cheap model for at most three
facts that were **non-obvious**, and appends them to
`~/.claude/projects/<slug>/memory/CANDIDATES.md`.

It never writes `memory/*.md` or `MEMORY.md` — promoting a candidate stays a manual act,
which is what keeps the curated set worth reading. It also skips sessions under 12 turns,
drops candidates whose slug already exists (or was already proposed), drops near-dupes of
the existing index, rejects anything matching a credential/contact pattern, and always
exits 0 so it can never block a session ending.

It runs as plain `node …/memory-candidates.ts` — Node ≥ 22.18 strips the types — so the
hook needs nothing installed from this repo.

Env: `JUANCODE_MEMORY_CANDIDATES=0` to disable,
`JUANCODE_MEMORY_CANDIDATES_MIN_TURNS`, `JUANCODE_MEMORY_CANDIDATES_MODEL`,
`JUANCODE_MEMORY_CANDIDATES_DEBUG=1`. To run it in every project rather than just this
one, move the same hook block into `~/.claude/settings.json` with an absolute path.

## GitHub webhooks (tracked-PR fast path)

The native app's PR tracker normally polls `gh` every 60s. With webhooks wired up,
GitHub pushes events instead and the poll demotes to a **~5-minute slow reconciler**
that only catches missed deliveries. The chain:

```
GitHub  →  https://oracle.<your-domain>/api/github-webhook   (sidecar, HMAC verify)
        →  http://127.0.0.1:4280/api/pr-webhook              (native app, repo + PR number only)
        →  PrTrackingEngine.refreshPr                        (re-fetches via gh, classify/inject/notify)
```

The event is a **trigger, not a payload** — the native side re-fetches PR state via
`gh` itself, so nothing from the webhook body is trusted beyond repo + number.

### Setup

1. **Pick a secret** and export it as `JUANCODE_GH_WEBHOOK_SECRET` in **both** places:
   - the sidecar's env (`apps/oracle-mcp/.env` or a shell export) — it verifies each
     delivery's `X-Hub-Signature-256` against it; unset ⇒ the endpoint returns 503.
   - the **native app's** environment (the shell you launch `dev-app.sh` / `swift run`
     from) — seeing the var is what switches the tracker's poll from 60s to the 300s
     reconciler (`Config.prPollInterval`). If only the sidecar sees it, webhooks work
     but the app keeps fast-polling; if only the app sees it, you get slow polls and
     **no** fast path.

   ```sh
   # generate one
   openssl rand -hex 32
   ```

2. **Cloudflare Access bypass for the webhook path.** GitHub's webhook deliveries
   can't complete Access's OAuth login, so the Access gate must exempt exactly this
   path. Security for the path then rests **entirely on the HMAC secret** — that is
   why the sidecar rejects unsigned/badly-signed requests before reading anything.

   In **Zero Trust → Access → Applications**:

   1. **Add an application → Self-hosted**, hostname `oracle.<your-domain>`,
      path `api/github-webhook` (a path-scoped application; more specific paths
      win over the site-wide app from step 3 above).
   2. Give it a single policy with action **Bypass** → Include → _Everyone_.
   3. Save. Everything else on the hostname stays behind the existing Access app.

   (Equivalent via API: create an app with `domain: "oracle.<your-domain>/api/github-webhook"`
   and a `decision: "bypass"` policy. The tunnel ingress needs no change — the path
   still routes to the sidecar on `127.0.0.1:4281`.)

3. **Create the repo webhook** (after step 2 is live, or deliveries bounce off the
   Access login page):

   ```sh
   JUANCODE_GH_WEBHOOK_SECRET=... scripts/setup-github-webhook.sh owner/repo your-domain.com
   ```

   The script (repo root `scripts/`) resolves the repo via `gh`, skips creation if a
   hook already points at the URL, and subscribes to `pull_request`,
   `pull_request_review`, `issue_comment`, and `check_suite`. It never prints the
   secret.

### Verify rollout

- [ ] `curl -s -X POST https://oracle.<your-domain>/api/github-webhook -d '{}'` returns
      **401** (bad signature) — not an Access login page (bypass works), not 503
      (secret is set), not 404 (tunnel/route works).
- [ ] GitHub → repo → Settings → Webhooks → the hook shows a green tick on the
      `ping` delivery ("Recent Deliveries" has a redeliver button).
- [ ] Track a PR in the app, push a commit to its branch: the tracked entry reacts
      within ~20s (webhook → debounce → refresh).
- [ ] Kill the sidecar, push again: nothing happens immediately, then the slow
      reconciler picks it up within ~5 min (native app must have the secret in env).
- [ ] Restart the sidecar: webhook path resumes.

## Triggers: dispatches nobody typed (juancode-chhr)

A **trigger** starts an agent session on its own — on a cron schedule, or when an
issue/PR gains a configured GitHub label. Both go through the same `dispatch()` the
phone console and Telegram use, so a triggered session is an ordinary pty in the
native app: visible in the grid, observable from Telegram, recorded in the dispatch
registry — just tagged with where it came from.

### The table

Hand-edit `~/.juancode/oracle/oracle-triggers.json` (or `$JUANCODE_ORACLE_DIR/…`).
It is re-read on every tick and every webhook, so **no restart** is needed:

```json
{
  "enabled": true,
  "allowedProjects": ["/Users/you/workdir/personal/juancode"],
  "repos": { "PanchoBubble/juancode": "/Users/you/workdir/personal/juancode" },
  "schedules": [
    {
      "id": "nightly-ready",
      "cron": "0 3 * * *",
      "project": "/Users/you/workdir/personal/juancode",
      "ticket": "juancode-42",
      "worktree": true,
      "telegramChatId": 12345678
    },
    {
      "id": "weekday-loose-work",
      "cron": "30 8 * * mon-fri",
      "project": "/Users/you/workdir/personal/juancode",
      "prompt": "Run pnpm loose and report anything uncommitted or unpushed."
    }
  ],
  "labels": [{ "repo": "PanchoBubble/juancode", "label": "agent:fix", "worktree": true }]
}
```

- `allowedProjects` is the **only** thing that makes a repo dispatchable by a
  trigger, and it is fail-closed: empty or missing ⇒ nothing fires anywhere. A path
  matches exactly or as a directory inside an allowed root (after `path.resolve`, so
  `..` can't walk out).
- A schedule needs a `prompt` **or** a `ticket`. A `ticket` gets a self-contained
  seed prompt telling the fresh session to `bd show` it and work it end-to-end.
- `cron` is the ordinary 5-field expression (`minute hour day month weekday`), with
  `*`, lists, ranges, `*/step`, and `mon`/`jan` names, evaluated in the Mac's local
  time. A bad expression drops that schedule and is reported in `problems`.
- A label rule fires on the **transition into** the label (`labeled`), never on
  removal or on an edit of an already-labelled issue. It resolves the local repo
  from `project`, else the `repos` map; an unmapped repo simply doesn't fire.
  Label dispatches default to `worktree: true` and, for a PR, the seed prompt tells
  the agent to check the head branch out — the native `create` message has no branch
  field yet, so the worktree starts on the default branch.
- `provider` (`claude` / `codex` / `opencode`) and `telegramChatId` work exactly as
  they do on `POST /api/dispatch`.

### Kill switch

`JUANCODE_TRIGGERS=0` (also `false` / `no` / `off`) in the sidecar's env disables
**every** trigger — no schedule loop, no label dispatch — for when the machine is
busy. `"enabled": false` in the config does the same without an env change; the env
switch wins either way. Both are read at fire time.

### Overlap and restarts

- Each fire records the minute it fired in, plus its dispatchId/sessionId, in
  `oracle-trigger-state.json` (separate from the config, so the sidecar never
  rewrites what you wrote). A restart mid-minute cannot double-fire.
- A schedule will not start a second run while its previous one is still `running`,
  or while a previous run is still sitting in the offline dispatch mailbox. If the
  native app can't be reached the tick **skips** rather than guessing.
- A minute missed because the sidecar was down is **not** replayed later;
  `lastFiredAt` in the state file is how you see it was missed.

### Seeing them

```sh
curl -s 127.0.0.1:4281/api/triggers | jq          # the table as the sidecar read it, + problems
curl -s '127.0.0.1:4281/api/dispatches?trigger=1' # only trigger-started dispatches
```

Telegram lifecycle pings for a triggered session carry a `⏱ started by …` line, so a
message you didn't ask for says which schedule or label produced it.

For label triggers the repo webhook must also send `issues` (for plain issues);
`scripts/setup-github-webhook.sh` subscribes to it.

## 4. Add the connector on your phone

In the Claude mobile app → **Settings → Connectors → Add custom connector**, enter:

```
https://oracle.<your-domain>/mcp
```

You'll be sent through the Cloudflare Access browser login once (one-time PIN to
your email). After that the Oracle tools appear in the app and you can drive the
Oracle from your phone.

## Security notes

- The sidecar performs **no auth itself** — it trusts that Cloudflare Access gated
  the request, and binds to `127.0.0.1`. **Never** expose port 4281 directly to the
  internet or bind it to `0.0.0.0`.
- For defense-in-depth you may additionally validate the `Cf-Access-Jwt-Assertion`
  header against your team's public keys, but it isn't required given the
  tunnel-only ingress + Access gate.
