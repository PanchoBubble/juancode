# @juancode/oracle-mcp

An MCP sidecar that exposes the juancode **Oracle** (the global orchestrator) to a
remote MCP client — e.g. the **Claude mobile app** — so you can manage global
issues, dispatch agents into projects, list running sessions, and talk to the
Oracle from your phone.

The pty/agent work always stays on the Mac (the CLAUDE.md prime directive). This
sidecar only **relays intent and reads state**:

| Tool | What it does | Mechanism |
|------|--------------|-----------|
| `oracle_list_issues` | List the Oracle's global `bd` items (ready-flagged) | `bd --sandbox list` in `~/.juancode/oracle` |
| `oracle_create_issue` | Create a global tracker item | `bd create` |
| `oracle_dispatch` | Spawn/seed an agent in a project | WS `create` with ack; falls back to `dispatch.jsonl` when the app is down |
| `oracle_list_sessions` | List live + persisted sessions | `GET` the native app's `/api/sessions` |
| `oracle_ask` | Ask the live Oracle agent | append `ask.jsonl` (native app tails it) |

`dispatch` is WS-first: with the app up you get a real ack (the session id, or the
real error for a bad path/provider); with the app down the dispatch is durably
queued in `dispatch.jsonl` and starts exactly once on the app's next launch (the
app persists its mailbox offset and dedupes by `dispatchId`). Outcomes are also
written to `dispatch-results.jsonl`, which the sidecar tails to relay failures —
and queued-dispatch starts — to Telegram. `ask` requires the **native app to be
running**. `list_issues`/`create_issue` work whenever `bd` is installed.

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
env, and when set it *disables* claude.ai connectors). Run `JUANCODE_CLAUDE_BIN` /
ensure `claude` is on PATH and logged in.

## Architecture

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

## 1. Run the sidecar

```sh
pnpm --filter @juancode/oracle-mcp start
# → oracle-mcp listening on http://127.0.0.1:4281/mcp
```

Environment variables (all optional):

| Var | Default | Purpose |
|-----|---------|---------|
| `ORACLE_MCP_PORT` | `4281` | Port the sidecar listens on |
| `ORACLE_MCP_HOST` | `127.0.0.1` | Bind address (keep on localhost — the tunnel reaches it) |
| `JUANCODE_ORACLE_DIR` | `~/.juancode/oracle` | Oracle control dir (mailboxes + `bd` tracker) |
| `JUANCODE_API` | `http://127.0.0.1:4280` | Native app's embedded server base URL |
| `JUANCODE_BD_BIN` | `bd` | Path to the `bd` binary |
| `TELEGRAM_BOT_TOKEN` | _(unset)_ | BotFather token. When set, the sidecar long-polls Telegram and routes messages through the same Oracle chat backend as the browser console. Unset ⇒ bridge disabled. |
| `ALLOWED_USER_IDS` | _(empty)_ | Comma/space-separated numeric Telegram user ids allowed to use the bridge. Empty ⇒ every message is ignored. |
| `JUANCODE_GH_WEBHOOK_SECRET` | _(unset)_ | HMAC secret for `POST /api/github-webhook`. Unset ⇒ the endpoint answers 503 and PR tracking stays poll-only. See "GitHub webhooks" below. |

### Telegram bridge (juancode-c6y)

With `TELEGRAM_BOT_TOKEN` set, you can chat with Oracle from Telegram using the
**same brain and session model** as the browser console — each message is routed
through `oracleChat` (headless `claude -p` with `--resume`), identical to `/api/chat`.
Transport is long-poll `getUpdates` (no webhook), so it works behind the existing
`oracle` Cloudflare Tunnel with no inbound port. Each Telegram chat keeps its **own**
`claude` session id (separate from the browser thread, no cross-talk); `/new` (or
`/start`) resets it. Replies are chunked to Telegram's 4096-char limit. Only users in
`ALLOWED_USER_IDS` are answered; everyone else is silently ignored.

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
3. **Policy:** Allow → Include → *Emails* → your email. For the login method, a
   **One-time PIN** identity provider needs no external IdP.
4. Save. Access now intercepts unauthenticated requests to `oracle.<your-domain>`,
   runs the OAuth login, and injects a `Cf-Access-Jwt-Assertion` header before
   traffic reaches the sidecar.

> Note: Cloudflare's MCP-with-Access docs are written around Workers origins, but a
> self-hosted Access app is just *a public hostname* and the Tunnel provides exactly
> that — so the same **Managed OAuth** toggle covers this tunnel origin. Validate the
> OAuth handshake end-to-end when you add the connector (step 4); that's the one part
> to confirm live.

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
   2. Give it a single policy with action **Bypass** → Include → *Everyone*.
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
