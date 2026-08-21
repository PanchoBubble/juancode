# @juancode/wire-conformance

The wire protocol as an executable spec, plus the suite that measures a core
against it.

juancode is growing a second core: the Swift one in `apps/native` today, the Rust
one in `apps/juancoded` next. Both speak the same WebSocket protocol to the same
clients (the SwiftUI app, the Oracle sidecar, the phone console). Without one spec
both cores are measured against, "the Rust core is at parity" is a feeling. With
it, switching cores is a supported configuration.

## Layout

```
spec/v1/protocol.json          the message catalogue for protocol version 1
spec/v1/scenarios/*.json       one golden transcript per scenario
fixtures/fake-agent.sh         the deterministic pty child the scenarios drive
fixtures/fake-editor.sh        stand-in for $VISUAL/$EDITOR
fixtures/fake-gh.sh            stand-in for gh, so no run can reach GitHub
src/                           the harness (client, matcher, runner, reports)
parity/<core>-status.json      per-scenario status for a core
parity/<core>-core.md          the generated parity checklist (the artifact)
```

## How it is versioned

The directory name **is** the version: `spec/v1` describes wire protocol version
1, the number a core reports in `serverInfo.protocolVersion`. A core is
conformant at v1 when it passes every scenario in `spec/v1`.

- A backwards-compatible addition (a new message, a new capability, a new
  optional field) is a bump of `specRevision` inside `spec/v1/protocol.json`.
- A change that would break an existing client is a new `spec/v2` directory, and
  cores advertise `protocolVersion: 2`. v1 stays in the tree and keeps being
  measured for as long as any core claims it.

`src/drift.test.ts` compares the catalogue against
`apps/native/Sources/JuancodeServer/WireProtocol.swift` directly: add a message
or a capability there and the suite goes red until the spec describes it. That is
what keeps the spec from becoming documentation.

## Running it

Fast checks (no core, part of `pnpm test` at the repo root):

```
pnpm --filter @juancode/wire-conformance test
```

The live suite against the Swift core (builds and boots `juancode-serve` itself,
on its own port and its own sqlite dir):

```
pnpm --filter @juancode/wire-conformance test:conformance
```

Against any other core, by URL:

```
JUANCODE_CONFORMANCE_URL=ws://127.0.0.1:4300/ws \
JUANCODE_CONFORMANCE_LABEL=rust \
pnpm --filter @juancode/wire-conformance test:conformance
```

Knobs:

| Variable                          | Meaning                                                           |
| --------------------------------- | ----------------------------------------------------------------- |
| `JUANCODE_CONFORMANCE_URL`        | Drive a core that is already running instead of booting one       |
| `JUANCODE_CONFORMANCE_LABEL`      | Name for that core in the report (`swift`, `rust`, …)             |
| `JUANCODE_CONFORMANCE_PORT`       | Port for a core we boot (default 4295; never 4280/4281)           |
| `JUANCODE_CONFORMANCE_SKIP_BUILD` | `1` when `juancode-serve` is already built                        |
| `JUANCODE_CONFORMANCE_REPORT`     | Write the run report here (`.md` for prose, `.json` for a status) |
| `JUANCODE_CONFORMANCE_KEEP`       | `1` keeps the booted core's temp data dir for inspection          |

**It never drives port 4280 or 4281.** Those are a developer's live app and
sidecar; driving them would create, resize and kill their real sessions. The
booted core gets its own port, sqlite dir, oracle control dir and fake provider
binaries, and `startCore` refuses those two ports outright.

## The parity checklist

```
JUANCODE_CONFORMANCE_URL=ws://127.0.0.1:4300/ws \
JUANCODE_CONFORMANCE_LABEL=rust \
JUANCODE_CONFORMANCE_REPORT=parity/rust-status.json \
pnpm --filter @juancode/wire-conformance test:conformance

pnpm --filter @juancode/wire-conformance parity rust
```

The first command measures the core and writes the status file; the second
regenerates `parity/rust-core.md` from the scenario registry plus that status.
The markdown is generated, never hand-edited, so the checklist cannot drift from
the scenarios. A status file whose `source` is `source-read` was seeded by
reading a core's code rather than running the suite, and says so in the output;
scenarios in it are marked `unknown`, which counts as unmet.

## The fake agent

Golden transcripts need a reproducible pty child, so the scenarios do not drive
`claude`/`codex`/`opencode` — they drive `fixtures/fake-agent.sh`, pointed at by
`JUANCODE_CLAUDE_BIN` / `JUANCODE_CODEX_BIN` / `JUANCODE_OPENCODE_BIN`. It reads
one command per line off the pty and prints exactly what was asked for:

| Command            | Effect                                                        |
| ------------------ | ------------------------------------------------------------- |
| `ECHO <text>`      | print the text                                                |
| `BUSY`             | print the working footer, so the session reads as busy        |
| `PROMPT`           | print a yes/no question on the bottom row (waiting for input) |
| `CLEAR`            | erase the screen, which ends a busy turn                      |
| `ALT` / `MAIN`     | enter / leave the alternate screen buffer                     |
| `HIDE` / `SHOW`    | hide / show the cursor                                        |
| `MOVE <row> <col>` | position the cursor                                           |
| `TITLE <text>`     | set an OSC 2 window title, the way a CLI names its session    |
| `EXIT <code>`      | exit with that status                                         |

**How a real provider differs.** Everything the suite asserts about the wire is
identical, but three things change with a real CLI:

1. **Activity is inferred, not commanded.** The core enters busy on the working
   footer (or a structured transcript event) and leaves it on a settle; the fake
   agent paints that footer on demand, whereas a real CLI paints it whenever it
   feels like it. A real-provider run therefore asserts the same transitions but
   cannot assert exactly when they happen.
2. **Resumability is real.** `claude` pins its session id, `codex`/`opencode`
   have theirs discovered from their own files. The `unresumable` scenario relies
   on a codex-shaped session whose id was never captured; with a real codex that
   id may exist and the same scenario would resume instead.
3. **Delivery is verified.** Queued messages and initial prompts land through a
   paste-then-verified-Enter engine that watches for the CLI's input box. The
   queue scenario deliberately holds the session busy so nothing is delivered,
   which keeps the snapshots deterministic; a real-provider run would also
   exercise the delivery path.

`gh` is stubbed to fail, exactly the way an unauthenticated `gh` fails, so the
tracked-PR scenario measures the fan-out without touching GitHub.

## Writing a scenario

A scenario is a JSON file: an id, a title, a sentence about what conformance to
it buys a client, the capabilities and environment it needs, and steps.

```json
{
  "id": "input-ack",
  "title": "input and inputAck ordering",
  "asserts": "every sequenced input is acked exactly once, in order",
  "requires": ["pty"],
  "capabilities": ["inputAck"],
  "ignore": ["activity", "output"],
  "steps": [
    { "send": { "type": "input", "sessionId": "$session", "data": "x", "seq": 1 } },
    { "expect": { "type": "inputAck", "sessionId": "$session", "seq": 1 } },
    { "expectNone": { "type": "inputAck" }, "withinMs": 800 }
  ]
}
```

Steps: `open` (a second connection), `close` (drop one, which is how a core's
disconnect behaviour gets driven), `send`, `raw` (a non-JSON frame), `expect`,
`expectHandshake`, `expectFirstFrame`, `expectNone`, `sleep`. `expect` consumes
frames with a cursor, so consecutive expects assert **order**; a frame that is
neither the match nor in `ignore` fails the step. `bind` reads a value out of a
matched frame (`{"session": "session.id"}`) for later `$session` references.

`open` normally swallows the handshake and the connect-time broadcasts; `{"open":
"b", "keep": true}` keeps them, for a transcript that asserts what a client is
told the moment it arrives. Each connection's own `serverInfo.clientId` is bound
as `$clientA` / `$clientB`, so a step can assert **which** client owns a grid.

Matchers are partial on objects and exact on arrays, with explicit operators for
anything looser: `$absent`, `$present`, `$type`, `$oneOf`, `$regex`, `$contains`,
`$notContains`, `$gte`/`$gt`/`$lte`/`$lt`, `$length`, `$exact`, `$not`, `$every`,
`$some`, `$any`, `$var`. A mistyped operator is an error, not a silent pass.

`requires` gates a scenario on the environment (`pty`, `git`, `gh`);
`capabilities` gates it on what the core advertises. Either way the scenario is
reported as **skipped with a reason**, never silently passed. `skipInCI` marks a
scenario that cannot run in GitHub Actions, with the reason.

## CI

`.github/workflows/wire-conformance.yml` runs the fast checks on Linux and the
live suite against a freshly built Swift core on macOS, uploads the run report,
and fails if a checked-in parity checklist is stale relative to its status file.
