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

`src/drift.test.ts` compares the catalogue against both cores' wire sources
directly - `apps/native/Sources/JuancodeServer/WireProtocol.swift` and
`apps/juancoded/crates/juancoded-server/src/wire.rs` - so adding a message or a
capability to either one turns the suite red until the spec describes it. That is
what keeps the spec from becoming documentation.

### The catalogue is the union, and the gate says which core

The two cores do not implement the same set. The Swift core has `trackedPrs`,
`editor`, `terminal`, `restartFresh`, `spawnModel` and `spawnPreset`; the Rust core has
`queueEdit` and `transcript`. The catalogue describes **all** of it, and a
message's capability gate is what says which core speaks it. Each core is then
measured against the subset its own advertised capability list entails:

- **nothing off the catalogue** - a type a core speaks that `protocol.json` does
  not describe is drift, whichever core grew it;
- **no empty promises** - a capability a core advertises has to come with every
  frame its gate names, because a client switches a feature on off that string.

Neither half asks a core to grow a decode case, or an encoder it would never use,
for a capability it does not advertise. Two cross-checks stop the catalogue
inventing things nobody implements: every catalogued message must be implemented
by at least one core, and every known capability advertised by at least one.

This replaced a rule that compared the catalogue to `WireProtocol.swift` alone,
under which a frame only the Rust core spoke could not be listed at all - and an
unlisted frame is an unmeasurable one, because a golden transcript may only
reference catalogued types. `editQueued` and the three transcript frames sat in
that hole; the `transcript` and `queue-edit` scenarios are what came out of
closing it.

A frame behind a capability a core deliberately **withholds** (the Rust core's
`contributions`: complete daemon-side, unadvertised because nothing renders a
descriptor yet) is exempt from the first check, by name, in a list in
`drift.test.ts` that carries the reason. The exemption lasts exactly as long as
the capability stays unadvertised: advertise it and the suite goes red until the
catalogue describes the frames.

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

Against the Rust core (builds and boots `juancoded` the same way):

```
JUANCODE_CONFORMANCE_CORE=rust JUANCODE_CONFORMANCE_PORT=4300 \
pnpm --filter @juancode/wire-conformance test:conformance
```

Against a core that is already running, by URL:

```
JUANCODE_CONFORMANCE_URL=ws://127.0.0.1:4300/ws \
JUANCODE_CONFORMANCE_LABEL=rust \
pnpm --filter @juancode/wire-conformance test:conformance
```

Knobs:

| Variable                          | Meaning                                                           |
| --------------------------------- | ----------------------------------------------------------------- |
| `JUANCODE_CONFORMANCE_CORE`       | Which core to build and boot: `swift` (default) or `rust`         |
| `JUANCODE_CONFORMANCE_URL`        | Drive a core that is already running instead of booting one       |
| `JUANCODE_CONFORMANCE_LABEL`      | Name for that core in the report (`swift`, `rust`, …)             |
| `JUANCODE_CONFORMANCE_PORT`       | Port for a core we boot: `0` picks a free one (default 4295)      |
| `JUANCODE_CONFORMANCE_SKIP_BUILD` | `1` when the core binary is already built                         |
| `JUANCODE_CONFORMANCE_REPORT`     | Write the run report here (`.md` for prose, `.json` for a status) |
| `JUANCODE_CONFORMANCE_STATUS`     | Also write a status JSON here, whatever the report is             |
| `JUANCODE_CONFORMANCE_KEEP`       | `1` keeps the booted core's temp data dir for inspection          |
| `JUANCODE_CONFORMANCE_RUN_TOKEN`  | Pin the per-run id stamp; two runs sharing one collide on purpose |
| `JUANCODE_CONFORMANCE_REPEAT`     | Attempts per scenario inside one boot (default 1; CI uses 3)      |

A relative report or status path is resolved from this package's directory, not
the repo root, because that is where the suite runs.

**It never drives port 4280 or 4281.** Those are a developer's live app and
sidecar; driving them would create, resize and kill their real sessions. The
booted core gets its own port, sqlite dir, oracle control dir, unix socket and
fake provider binaries, and `startCore` refuses those two ports outright.

**`JUANCODE_CONFORMANCE_PORT=0` is the setting to use on a shared machine.** The
suite binds `127.0.0.1:0`, reads back the port the kernel gave it, and hands that
one number to both the core boot and the clients, so two agents running the suite
from two worktrees cannot land on each other. The port is picked _after_ the
build, because a port reserved before a multi-minute `cargo build` is a port
somebody else can take while it compiles.

A port a caller names is still honoured — CI pins one per job, and a developer
with a debugger attached wants to know the number — and for that case the boot
first probes the port and refuses the run if anything already answers a health
check there. Without that refusal the spawned child cannot bind, exits, and
`waitHealthy` is satisfied by the squatter: the suite then scores a daemon it
does not own and goes red the moment that daemon's owner stops it, which is
exactly what two agents sharing 4300 measured (juancode-kr1n).

The two cores read different variables for the same thing, and `startCore` knows
it: the Rust daemon takes its port from `JUANCODED_PORT` and its socket from
`JUANCODED_SOCKET`, so a boot that only set the Swift core's spellings would
silently land on the default 4290 and take the developer's own socket away from
their daemon.

## Ids, and why a second run does not collide

A scenario claims ids inside the core that outlive the scenario: a dispatch id it
must not be able to claim twice (`dispatch-correlation`), and the CLI id of an
adopted conversation the core must recognise as already adopted
(`adopt-external`). Reusing those ids on a second run measures the dedup instead
of the scenario, which is what made a repeat run against one daemon report two
failures that were not core bugs.

So the runner stamps them: `conformance-<scenario>-<run token>-<attempt>`, unique
per attempt and identical for every step of one attempt. Per attempt rather than
per process, because running the whole spec more than once inside a single boot is
how repeatability gets measured at all.

## Repeating the whole spec inside one boot

```
JUANCODE_CONFORMANCE_REPEAT=5 JUANCODE_CONFORMANCE_CORE=rust JUANCODE_CONFORMANCE_PORT=4300 \
pnpm --filter @juancode/wire-conformance test:conformance
```

Every scenario runs five times against the same core; a scenario passes only if
all five attempts passed, and the report says `handshake: 5/5` rather than a bare
`yes`. A spec measured once still reads honestly, as `1/1`.

Why a knob and not a habit: twice a conformance score has been reported off a
single run and turned out not to be repeatable (juancode-g2kl on the Rust side,
juancode-p5vb on the Swift side, where `tracked-prs` was 20 of 20 one day and 2
of 6 the next). The macOS CI job therefore runs with `REPEAT=3`, so a flake at
p5vb's 1-in-3 rate is red on nearly every push instead of one push in three.

Inside one boot rather than as N whole jobs, because the build plus the boot
dominates the wall clock, and repeating in one boot also exercises the
scenario-after-scenario ordering a fresh boot per run hides. That ordering is
where a scenario used to be failed by a frame that was not its own: an `exit`
from the previous scenario's killed session, reaped while the next scenario's
socket was the one open. A scenario now asserts only about the sessions it
created — the driver tells each connection which ids are its own, and a frame
about anybody else's session is skipped rather than failed — and cleanup waits
for the `exit` of every session it kills instead of sleeping a flat 400ms
(juancode-a3ck).

## The parity checklist

```
JUANCODE_CONFORMANCE_CORE=rust JUANCODE_CONFORMANCE_PORT=4300 \
JUANCODE_CONFORMANCE_STATUS=parity/rust-status.json \
pnpm --filter @juancode/wire-conformance test:conformance

pnpm --filter @juancode/wire-conformance parity rust
```

The first command measures the core and writes the status file; the second
regenerates `parity/rust-core.md` from the scenario registry plus that status.
The markdown is generated, never hand-edited, so the checklist cannot drift from
the scenarios. A status file whose `source` is `source-read` was seeded by
reading a core's code rather than running the suite, and says so in the output;
scenarios in it are marked `unknown`, which counts as unmet.

Regenerating the markdown is **not** a freshness check, because it regenerates
FROM the status file: a status file whose measurement is months old regenerates
cleanly. That is how the Rust checklist went on claiming the queue scenario was
skipped for a commit after the core started passing it. The check that catches it
compares the committed claim against a run that just happened:

```
pnpm exec tsx src/parity-cli.ts --verify <status file a run just wrote>
```

It compares verdicts, capabilities, spec revision and protocol version, and
ignores the measurement date and the wording of a note, so it fails only when the
claim and the core actually disagree. Both conformance jobs in CI run it, which
makes the checked-in parity file a measurement rather than a promise.

## The fake agent

Golden transcripts need a reproducible pty child, so the scenarios do not drive
`claude`/`codex`/`opencode` — they drive `fixtures/fake-agent.sh`, pointed at by
`JUANCODE_CLAUDE_BIN` / `JUANCODE_CODEX_BIN` / `JUANCODE_OPENCODE_BIN`. It reads
one command per line off the pty and prints exactly what was asked for:

| Command             | Effect                                                        |
| ------------------- | ------------------------------------------------------------- |
| `ECHO <text>`       | print the text                                                |
| `BUSY`              | print the working footer, so the session reads as busy        |
| `PROMPT`            | print a yes/no question on the bottom row (waiting for input) |
| `CLEAR`             | erase the screen, which ends a busy turn                      |
| `ALT` / `MAIN`      | enter / leave the alternate screen buffer                     |
| `HIDE` / `SHOW`     | hide / show the cursor                                        |
| `MOVE <row> <col>`  | position the cursor                                           |
| `TITLE <text>`      | set an OSC 2 window title, the way a CLI names its session    |
| `TRANSCRIPT <text>` | append one turn to claude's own jsonl (the transcript plane)  |
| `SPAWN`             | leave a helper running in the session's process group         |
| `EXIT <code>`       | exit with that status                                         |

`TRANSCRIPT` is the odd one out: it writes a file rather than painting a screen.
The transcript plane does not read the pty, it reads the CLI's own store, so a
stand-in that only paints would leave that plane with nothing to read. It writes a
claude-shaped turn into `$JUANCODE_CLAUDE_PROJECTS_DIR/<cwd slug>/<pinned session
id>.jsonl`, which is where a real `claude` would write it, and never a developer's
real `~/.claude`: with the variable unset the command is a no-op. Nothing it does
paints a working footer, which is how `transcript-activity` can attribute a busy
edge to the record rather than to the screen.

The file is deliberately not created on spawn. A core's first bind attempt lands on
the spawn banner, so a file that already exists binds at once and the first batch a
session yields is empty - which would make `transcript-activity`'s history
assertion vacuous, since the records that must not pulse are exactly the ones the
first successful bind finds already written. The price is a failed first bind and a
`BIND_RETRY` back-off, which is why both transcript scenarios wait it out and then
send an unrelated `ECHO` to make the session dirty again: a bound transcript is
only polled for a session that has produced output.

`SPAWN` is the other one that reaches past the screen. It forks a helper into the
agent's process group and records its pid in `orphan.pid` in the session cwd, then
the `orphan-reap` scenario reads that pid directly. The helper ignores `SIGHUP` and
`SIGTERM`, so closing the pty master and a graceful stop both fail to reach it and
only a core that escalates `killpg` to `SIGKILL` passes. It runs `sleep 30`, not a
loop: the assertion is about a process outliving its session, and a fixture that
could outlive the suite would be the same bug wearing the test's clothes.

The `spawn-preset` scenario needs one more thing the pty cannot carry: a preset on
disk for a name to resolve against. `coreEnv` points every booted core at its own
`JUANCODE_PRESET_DIR` and writes `conformance.md` into it (a one-line marker, since
claude's mechanism puts the body in the CLI's argv and the scenario matches it out of
`ARGS`). `conformance-missing` is deliberately never written: a core has to refuse a
name it cannot resolve rather than spawn without it. Unset, a core would read the
developer's real presets and the run would depend on what they happen to have written.

**How a real provider differs.** Everything the suite asserts about the wire is
identical, but three things change with a real CLI:

1. **Activity is inferred, not commanded.** The core enters busy on the working
   footer (or a structured transcript event) and leaves it on a settle; the fake
   agent paints that footer on demand and writes that record on demand, whereas a
   real CLI does both whenever it feels like it. A real-provider run therefore
   asserts the same transitions but cannot assert exactly when they happen.
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
`expectHandshake`, `expectFirstFrame`, `expectNone`, `sleep`, `descendant`. `expect` consumes
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

`descendant` is the one step that does not touch the socket:
`{"descendant": "alive" | "reaped", "pidFile": "$orphanPid", "withinMs": 5000}`
asserts that the helper `SPAWN` left running is up, or gone. It exists because
reaping a process group produces no frame and deliberately never will (see
`decisions` in `protocol.json`), so `orphan-reap` reads the pid the fixture wrote.
The two polarities are a pair: `reaped` refuses to run when the pid file names
nothing, because a `SPAWN` that silently did nothing would otherwise satisfy it, so
the `alive` step before the kill is what makes the assertion mean anything.

`requires` gates a scenario on the environment (`pty`, `git`, `gh`);
`capabilities` gates it on what the core advertises. Either way the scenario is
reported as **skipped with a reason**, never silently passed. `skipInCI` marks a
scenario that cannot run in GitHub Actions, with the reason.

## CI

`.github/workflows/wire-conformance.yml` runs the fast checks on Linux, then one
job per core, each of which builds that core, boots it through this suite, uploads
the run report and the measured status, and fails if the committed parity file no
longer describes what it measured. The Swift job needs macOS for the Swift
toolchain; the Rust job runs on Linux. Neither depends on the other, so a core can
go red on its own.
