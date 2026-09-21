# @juancode/wire-conformance

The wire protocol as an executable spec, plus the suite that measures a core
against it.

juancode had two cores while it was being ported: the Swift one in `apps/native`
and the Rust one in `apps/juancoded`. Both spoke the same WebSocket protocol to the
same clients (the SwiftUI app, the Oracle sidecar, the phone console). Without one
spec both were measured against, "the Rust core is at parity" would have been a
feeling — and it is that measurement, over months, that made deleting the Swift core
(juancode-nqpm, 2026-09-21) a decision rather than a leap.

One core boots here now. The spec did not shrink with it, and it should not: it is
what a client depends on, what the daemon is checked against on every PR, and what a
second implementation would be measured with if there is ever another one.

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

`src/drift.test.ts` compares the catalogue against both wire sources directly -
`apps/native/Sources/JuancodeServer/WireProtocol.swift`, which survives the Swift
core's deletion because it is what the desktop client and the `:4280` relay encode
with, and
`apps/juancoded/crates/juancoded-server/src/wire.rs` - so adding a message or a
capability to either one turns the suite red until the spec describes it. That is
what keeps the spec from becoming documentation.

### The catalogue is the union, and the gate says which core

The two cores did not implement the same set; the catalogue is still written as a
union, because the drift probes below still read both wire sources and because a
capability gate is how a client feature-detects. Both had `restartFresh`, `spawnModel`,
`spawnPreset`, `editor`, `terminal`, `trackedPrs`, `trackPrInSession`, `prWebhook`,
`namedKeys` and
`globalPause`; the Rust core also has
`queueEdit`, `transcript`, `reaper`, `stuck`, `sessionList`, `sessionDelete`,
`sessionSleep`, `sessionEdit` and `heavyQueue` on top of that. The catalogue describes **all** of it, and a
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
| `JUANCODE_CONFORMANCE_CORE`       | Which core to build and boot. One: `rust` (the default)           |
| `JUANCODE_CONFORMANCE_URL`        | Drive a core that is already running instead of booting one       |
| `JUANCODE_CONFORMANCE_LABEL`      | Name for that core in the report (`rust`, …)                      |
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

**A booted core inherits no `JUANCODE_*` / `JUANCODED_*` variable it was not
handed.** The boot strips the whole prefix out of the parent environment before
applying its own (`isolatedParentEnv`), keeping only `JUANCODED_LOG`, which
changes how loud a core is and nothing else. The prefix rather than a list of the
ones that have bitten, because a knob added to a core later must not be able to
arrive from a developer's shell without anybody noticing.

The one that made this a rule: `JUANCODE_OWNER_PID` arms the Rust daemon's
lifetime watchdog, and a core that reads one ends **itself** a grace period (120s
by default) after that process is gone — through the orderly shutdown path, so it
exits 0 with no panic and no crash report, and every later scenario sees
`ECONNREFUSED`. That variable is in the environment of every agent session a
launcher-owned daemon spawned, because a pty child inherits it, so a suite run
inside one used to boot a core owned by the developer's launcher. Measured
2026-09-18 against `juancoded` with a six-second grace: owner killed, daemon gone
seven seconds later, exit status 0.

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
of 6 the next). Both CI conformance jobs therefore run with `REPEAT=3`, so a
flake at p5vb's 1-in-3 rate is red on nearly every push instead of one push in
three. The Rust job was the one scored on a single pass until 2026-09-07, which
had it backwards: the only mid-run core death anyone has seen was that core (see
below), and it is a required check on `main`, so a one-pass score was the
load-bearing number. Three attempts cost it ~2 minutes and leave it inside the
Swift job's wall clock, so nothing waits longer for it.

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

### Measure parity on a quiet machine

`REPEAT` raises the odds of catching a flake; it does not make a loaded machine
behave. Measured 2026-09-20, whole suite, Rust core, `REPEAT=5`, own ephemeral port,
on a machine running at load average 4.1-4.8 on 14 cores (other agent sessions):
**45 passed, 4 failed**. Two of the four were assertion defects and are fixed
(`queue` step 15, `queue-edit`'s unheld busy premise). The other two were not, and
no rewrite of an assertion reaches them: `activity-notify` step 7 ran out of an
8000ms budget waiting for the settle after a `CLEAR`, and `session-delete` step 9
got an `error` frame back from an `isolateWorktree` create instead of a `created`
(juancode-sag9).

So a parity number that is going to justify something — juancode-nqpm deletes the
Swift core off one — has to be taken on a machine that is not carrying other agent
sessions, and the run that produced it has to be named. A score taken under load is
a lower bound on the core and an upper bound on nothing.

## When the core dies mid-run

A core process that goes away between two scenarios used to be invisible. The
harness printed the core's stdout only when the BOOT health probe failed, so a
death at scenario 25 left no core log at all — just `connect ECONNREFUSED` on
every scenario from there to the end of the file, and a report that scored the
core 25 of 33 (juancode-jyl9, seen once in six `REPEAT` passes over the Rust core
on 2026-09-04).

Three things changed, all in the harness:

- The core's stdout and stderr are kept in a byte-bounded ring (64KB) for the
  **whole run**, not just the boot.
- A scenario failure asks the core whether it is still alive. Two refused health
  probes 250ms apart, so a core busy enough to drop one connection is not
  declared dead.
- The first `no` latches. That scenario and every scenario after it are reported
  `unmeasured`, not `failed`, and none of them opens another socket.

The report then names the death instead of burying it:

```
- Result: 24 passed, 0 failed, 3 skipped, 6 unmeasured (the core died)

## The core died mid-run

- Died after: 24-transcript
- Noticed by: 25-queue-edit
- How: the core was killed by SIGKILL
- Exit status: none, signal: SIGKILL

### Core output
...the last 8KB the core printed...
```

`unmeasured` is a distinct status everywhere it lands: in the status JSON (with
no attempt counts — a `0/6` would read as six measurements that came back
negative), in the parity checklist, and in `statusDifferences`, so a run whose
core died cannot quietly agree with a committed parity claim.

Exactly one scenario goes red for a death: the one that discovered it, whose
failure message carries the exit status, the signal and the core's log. The rest
report as skipped. A run showing eight red scenarios for one process death is
reporting a score it never took.

A death lands the same way part-way through a repeat pass, which is now the only
way CI runs: a scenario whose attempt 1 passed and whose attempt 2 hit a dead
core is `unmeasured`, and its 1/3 goes nowhere. A partial pass is not a
measurement of a core that is no longer running, so the repeat loop returns the
failure that lets the guard latch rather than the pass it could have averaged
(`death.test.ts`, "a core that dies on attempt 2 of 3").

`src/death.test.ts` covers this end to end against `fixtures/fake-core.mjs` — a
real process, a real `SIGKILL` between two scenarios, and assertions on the
report. It does not wait for the flake.

### First question: did it die at all?

`ECONNREFUSED` says nothing is listening. It does not say the process is gone,
and those are different bugs with the same symptom — the same run of unmeasured
scenarios, the same empty log. Everything above (the exit status, the uptime, the
crash report, the core's last words) can only describe a process that ended, so a
core that is still in the process table and no longer serving used to be reported
as a death whose exit status the harness had merely missed.

So the record answers that first, with one `kill(pid, 0)`:

```
- How: the core is STILL RUNNING as pid 41207 and has stopped serving …
- Process: STILL RUNNING when the harness looked, so this is not a death
- Up for: 214.8s when it stopped answering
```

and the section is headed `## The core stopped serving mid-run, and did NOT die`,
so nobody reads a death off a process that never died. A live core also gets a
`sample(1)` of its threads attached, which is to this branch what the crash report
is to a signal death: the only evidence of what it is doing instead of listening.

The exit status is also worth waiting two seconds for. The two health probes take
a quarter of a second, and a process that ended while they were in flight has its
`exit` event queued behind them — so a record written the instant the socket
refused could say `code: none, signal: none` about a core that exited perfectly
normally, which is exactly what a still-running core says. `settleExit` removes
that overlap before the liveness check has to arbitrate it.

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

The `heavy-queue` scenario needs the same kind of thing and for the same reason, one
level up: the queue is a shared filesystem registry, and a scenario cannot write a
file. `coreEnv` points every booted core at its own `JUANCODE_HEAVY_ROOT` and seeds
two waiting entries in it (`seedHeavyQueue`), for this process's pid and its parent's
— two pids that are alive for the length of the run, because a core filters the
registry on liveness and a dead entry is in no snapshot. That variable moves the
capacity config with the registry, which is what keeps `heavySetSlots` from
rewriting the developer's live `~/.claude/heavy-queue.json`; unset, a run would be
reordering their real jobs. Nothing in the scenario signals either pid: `heavyCancel`
is exercised against a pid the queue does **not** hold, which is the refusal that
keeps that frame from being an arbitrary-signal gadget.

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
`expectHandshake`, `expectFirstFrame`, `expectNone`, `sleep`, `descendant`, `get`. `expect` consumes
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

### `expectNone` may only assert silence where the protocol is silent

`expectNone` is the one step that can be written so it asserts something no core
ever promised. "No frame of type T for N milliseconds" is a claim when the core is
contractually quiet about T — after an `unsubscribeQueue`, or for a `sessionDeleted`
nobody asked for. It is not a claim on a channel something else is allowed to speak
on: the queue's delivery pump ticks four times a second and owns the
`pending` -> `inFlight` edge, so a bare `{"expectNone": {"type": "queue"}}` is decided
by how loaded the machine is rather than by the core. That flaked queue-edit 1 in 5
(fixed in ce3c770, 2026-09-04) and then failed queue 6 of 6 on a loaded
machine while the committed parity file still said 3/3 (juancode-45cp).

Scope the matcher to the content that would prove the bug instead — for "a
whitespace-only message is not queued at all", `items: {"$some": {"text": {"$regex":
"^\\s*$"}}}` — and an unrelated state transition cannot trip it. Widening `withinMs`
only moves a flake; forbidding the revision from advancing does not work either,
because an `inFlight` transition advances it.

The other half of the same lesson is the premise. A scenario that needs a session to
be busy before it asserts anything has to **wait for the busy edge**, not sleep a flat
500ms and hope: until the core has seen the turn start, `deliverable` reads the session
as idle and the pump is free to claim the head of the queue. `{"expect": {"type":
"activity", "sessionId": "$session", "state": "busy"}}` is the premise stated on the
wire, and it costs nothing on a quiet machine.

`descendant` is the one step that does not touch the socket:
`{"descendant": "alive" | "reaped", "pidFile": "$orphanPid", "withinMs": 5000}`
asserts that the helper `SPAWN` left running is up, or gone. It exists because
reaping a process group produces no frame and deliberately never will (see
`decisions` in `protocol.json`), so `orphan-reap` reads the pid the fixture wrote.
The two polarities are a pair: `reaped` refuses to run when the pid file names
nothing, because a `SPAWN` that silently did nothing would otherwise satisfy it, so
the `alive` step before the kill is what makes the assertion mean anything.

`get` is the other step that is not about a frame:
`{"get": "/api/sessions/$session/screen?json=1", "status": 200, "expectBody": {…}}`
reads one of the core's own HTTP routes. Those routes are wire surface — the sidecar
and the phone console reach a session through them, and `/screen` is the only
width-correct way to look at a session without holding a subscription open — but they
are requests and replies rather than frames on the shared socket, so no `expect` can
see them. `status` defaults to 200. The body is asserted with the same matcher
language a frame gets, as decoded JSON (`expectBody`) or as raw text (`expectText`);
`bind` works off the JSON body. This is the one place `$name` is substituted INSIDE a
string, because a URL is the one place a bound id has to sit in the middle of one.

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
