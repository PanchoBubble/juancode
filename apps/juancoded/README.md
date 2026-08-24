# juancoded — the harness core in Rust

Epic `juancode-52e8`: move the non-UI half of juancode into a portable Rust daemon
behind a switchable backend. The go/no-go spike (juancode-52e8.3) cleared all three
risks and beat the Swift path on every number below; the composition core
(juancode-52e8.4) and the state layer (juancode-52e8.6) landed on top of it.

## What the spike proved

1. **Env fidelity, by construction and by test.** `portable-pty`'s
   `CommandBuilder::new` seeds from `std::env::vars_os()`, so the child gets our
   whole environment and nothing else. The only entry we ever add is a provider's
   `spawn_env` overlay — opencode's opt-in bypass, which that CLI exposes only as an
   env var. `pty::tests::the_child_environment_is_our_environment_entry_for_entry` runs
   `/usr/bin/env` in a real pty and diffs it both ways against our own environ, and
   asserts no `CODEX_HOME` / `CLAUDE_CONFIG_DIR` appeared. Live confirmation: the spawned
   `claude` printed `Opus 5 (1M context) · Claude Team · Fanvue` and
   `1 MCP server needs authentication · run /mcp` — the real account and the real
   user-scope MCP config, loaded exactly as in a terminal.

2. **One grid, one owner.** `alacritty_terminal` owns the grid behind `&mut`, fed
   only from the session's pty pump. `Snapshot` is a value type, so views are
   readers. The bug class in juancode-d89 / o9h2 / 8llo / 1th / 9goj / grnu — two
   things parsing one stream on different threads — is not expressible here.

3. **The existing wire protocol is the whole boundary.** `juancoded-server` is a
   translation of `WireProtocol.swift`, not a redesign: `created`, `attached` with
   scrollback, `output`, `screen` (reset + row diffs), `inputAck`, `resizeAck`,
   `activity`, `exit`, `error`, `unresumable`. `serverInfo` advertises a deliberately
   narrower capability list than the Swift core, and clients feature-detect off it —
   which is what makes a partial core a supported configuration rather than a broken
   one.

4. **The Swift UI needs no FFI.** `client-spike/` is a plain `TerminalView` fed from
   the socket (never `LocalProcessTerminalView` — the pty is not ours). Keystrokes go
   out as `input`, resizes as `resize`. It rendered the full Claude Code TUI, and
   `--dump-after` prints the grid read back out of the view's own terminal.

## The three numbers (2026-08-21, M-series arm64, release build)

| Measure | Rust core | Swift path | Note |
| --- | --- | --- | --- |
| VT parse | **0.0769 ms / 16KB** (213 MB/s) | 0.156 ms / 16KB | 2.0x faster. Same chunk unit as the recorded Swift figure. |
| Grid projection | 0.0227 ms / 120x40 | — | Cost of one `snapshot()`. |
| Harness echo (in → out, `/bin/cat`) | **p50 0.017 ms**, p99 0.029 | — | pty + grid feed + fan-out, no socket. |
| Wire hop (input → inputAck, UDS) | **p50 0.0385 ms**, p90 0.115, p99 0.335 | 0 (in-process) | The cost the split adds: ~38 µs. |
| Echo through the real `claude` TUI | p50 8.6 ms, p99 19.3 | — | The CLI's own repaint dominates; identical either side. |
| Throughput (12 MB dump) | 50–72 MB/s delivered, 0.2 s wall, 0.21 s user + 0.30 s sys | — | pty read + grid feed + fan-out. |
| Daemon memory, idle | **3.97 MB** | — | `footprint`, not `ps` RSS. |
| Harness memory per live session | **~780 KB** | — | 3.97 MB idle → 6.32 MB with 3 live sessions. |
| The `claude` process itself | 265–270 MB each | same | Unchanged: the known ~300 MB/session is the CLI, not the harness. |

Reading of the latency question the ticket poses: the socket hop is microseconds
(38 µs p50), two orders of magnitude below the CLI's own repaint and three below a
perceptible frame. The split-process design does not cost typing latency.

Caveat on comparability: juancode-2n0 never produced a keystroke→echo baseline for
the Swift core ("the probe is still unwritten"), so the Swift column is the recorded
parse-cost figure only. The Rust numbers above are absolute, and the hop is measured
directly — but a like-for-like Swift echo number would need the same probe added to
the running app.

Reproduce:

```sh
cargo run --release -p juancoded-vt   --example parse_cost
cargo run --release -p juancoded-state --example echo_latency
cargo run --release -p juancoded-state --example throughput <big-file>
cargo run --release -p juancoded-server --example uds_rtt -- /tmp/juancoded-spike.sock
```

## Crate layout

| Crate | What it owns | Swift counterpart |
| --- | --- | --- |
| `juancoded-vt` | The grid (`alacritty_terminal`), `Snapshot`, `screen` frame encoding | `SessionTerminalModel.swift`, `ScreenWire.swift` |
| `juancoded-core` | Wire model types, provider specs + `resolve_provider_bin`, the pty host, activity inference, the change rollup | `Protocol.swift`, `Providers.swift`, `PtyProcess.swift`, `ActivityDetector.swift`, `ChangeBadge.swift` |
| `juancoded-cordis` | The composition core: keyed services, RAII effect guards, the entry list, the typed bus, `dump-config` | none — this is the point of the move |
| `juancoded-state` | The session registry, the grid authority, the `sessions` and `store` services | `SessionRegistry.swift`, `Session.swift`, `GridArbiter.swift` |
| `juancoded-persistence` | SQLite: sessions, scrollback (with its grid), queue, tracked PRs, the dispatch ledger, and the read-only scanners for the CLIs' own stores | `JuancodePersistence` |
| `juancoded-server` | The wire protocol, WS connection loop, screen streamer, listeners | `WireProtocol.swift`, `WebSocketConnection.swift`, `ScreenStreamer.swift` |
| `juancoded` | The daemon binary: apply the entry list, serve the `sessions` service | — |
| `juancoded-plugins` | The original standalone `EffectRegistry` spike, superseded by `juancoded-cordis` and wired into nothing (juancode-yuce) | — |

## The state layer, and where it lives

It **mounts into** the cordis tree; it does not sit beside it. `sessions` and `store`
are ordinary keyed services, the registry resolves `pty`, `terminal` and `store` by
key like any other consumer, and the wire layer holds an `Arc<dyn SessionsApi>`
without knowing that a registry, a SQLite file or an `alacritty_terminal` grid exist.
Input travels the `session.input` around chain (so the live-pty guard, and later a
steering queue's claim boundary, can refuse a write), output the `session.output`
observe chain (whose one listener feeds the grid), and an exit the `session.exit`
fan-out. `juancoded --dump-config` prints the whole thing, and
`crates/juancoded-state/tests/mounted_tree.rs` asserts that output — so "the state
layer is in the tree" is a test, not a claim.

There is exactly one composition mechanism in this daemon, and it is the one
juancode-52e8.4 built.

## Four bugs that are now unwritable

| Was | Why it cannot happen here | Test |
| --- | --- | --- |
| juancode-1th / 8llo: last-write-wins resize, two viewers flapping the TUI | One authority arbitrates, and the pty and the grid move from the same call with the same numbers | `tests/resize_authority.rs` (including the juancode-po1 matrix) |
| juancode-grnu: scrollback replayed at a guessed width | The grid is stored beside the bytes, and the replay is rebuilt at that grid — the same code path after an exit and after a restart | `tests/restart_scrollback_width.rs` |
| juancode-9goj: two parsers, one stream, a corrupted global | One grid behind one lock, fed from one task; readers get value snapshots | `tests/one_grid_owner.rs` |
| juancode-d89 / o9h2 / jpvj: the daemon blocking on a wedged UI surface | Output is published on a bounded broadcast that drops a slow receiver's backlog; the producer never waits and never buffers on its behalf | `tests/one_grid_owner.rs` |

Pty feeds are deliberately **not** coalesced. Measured parse cost is 0.0769 ms per
16 KB here and parse was never the lag source (juancode-kdn), so batching would trade
a real latency floor for an imaginary saving.

## Provider parity

The three CLIs are spawned the same way and differ in exactly three places. Every one
of those is a fact about the CLI, not a preference of ours.

| | claude | codex | opencode |
| --- | --- | --- | --- |
| Resumable id | `--session-id <ours>`, known at spawn | its own, read from `~/.codex/sessions/**/rollout-*.jsonl` | its own, read from opencode's SQLite |
| When the id lands | immediately | while it boots | on the FIRST message, so possibly minutes later |
| Bypass | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` | `OPENCODE_PERMISSION`, because its TUI has no flag |
| Env overlay | none | none | that one entry, only for a session that asked |

**The environment is inherited, entry for entry.** `CommandBuilder::new` seeds from
`std::env::vars_os()`, and the only entry ever added is a provider's `spawn_env`
overlay. That is asserted as a two-way diff rather than a spot check, at both levels:
`pty::tests::the_child_environment_is_our_environment_entry_for_entry` diffs a real pty
child's `/usr/bin/env` against our own environ, and
`juancoded-state/tests/provider_parity.rs` does the same through the registry for all
three providers with bypass on and off. Measured here: 0 unexplained differences across
109 entries, with the overlay accounting for exactly one added key in the opencode
bypass case. `cargo run --example env_diff -p juancoded-core` runs that comparison by
hand and prints what each provider would resolve to.

The one difference the diff excludes is `DYLD_*`, which macOS strips when exec'ing a
system binary. A CLI would not get it from a terminal either, so it is not ours to
promise.

**Binary resolution has one answer.** `resolve_provider_bin(provider)` folds the
`JUANCODE_CLAUDE_BIN` / `JUANCODE_CODEX_BIN` / `JUANCODE_OPENCODE_BIN` override into the
lookup, so the override is part of the answer rather than an argument a call site has to
remember; the registry and the `provider.resolveBin` chain both go through it and cannot
disagree. Under the override the ladder is the Swift one, cheapest rung first: inherited
PATH, `$SHELL -lc`, the well-known install dirs, then `$SHELL -lic`. That last one
being the rung that costs a plugin-heavy `.zshrc` six seconds, which is why it is last
and why both shell probes are timeout-bounded. Results are memoized for the process,
misses for a minute (juancode-8fp), and an override short-circuits ahead of the cache so
a test's stub is honoured on every call.

**Shutdown asks before it insists.** `PtyHandle::stop` sends SIGTERM, waits out a
bounded 3-second grace, then SIGKILL. `claude` traps SIGTERM to flush its transcript,
and killing first meant a `--resume` repainted a conversation missing its last few
prompts, since the CLI repaints from its transcript and not from our scrollback
(juancode-6cqj). Unmounting the `pty` service asks every child at once and waits for
the set, so N sessions cost one grace rather than N.

## Where the data lives

`$JUANCODED_DATA_DIR/juancoded-rust.db`, falling back to `$JUANCODE_DATA_DIR` and then
to `~/.juancode/rust-core/`. Never `~/.juancode/data/juancode.db`, which is the Swift
core's: one DB file per core is what makes flipping cores a restart rather than a
migration, and the file name says which core wrote it even if someone points both at
one directory.

Schema (`crates/juancoded-persistence/src/schema.rs`): `sessions`, `scrollback`
(`session_id`, **`cols`**, **`rows`**, `bytes`), `queue`, `tracked_prs`, `dispatches`.
`cols`/`rows` are not metadata — without them the bytes can only be replayed by
guessing a width, and a wrong guess garbles every hard wrap in the history.

Beside the DB, while the daemon is listening: `juancoded.run`, `key=value` lines
carrying the pid, port, build stamp, `JUANCODE_BUILD_ID` and effective
`sessions_per_project` (`crates/juancoded-server/src/identity.rs`). It exists so a
launcher can tell whether the running daemon matches the checkout **without opening a
socket** — `key=value` rather than JSON precisely because the only reader is a shell
script, and a check that needs a JSON parser it may not have is a check that gets
skipped. Written on a successful bind, removed on a clean stop; a crash leaves it
behind, which is why every reader confirms the pid is alive first.

## Conformance

Measured against `apps/wire-conformance` (20 golden scenarios, protocol v1) by
pointing the suite at a hand-booted daemon on its own port, its own data dir and the
suite's fake agent. **17 of 20 passing, three skipped, none failing**, five runs out
of five, 2026-08-22.

The three that are not are capability-gated and report as skipped rather than failed,
because the core does not advertise what it cannot do: `queue`, `trackedPrs` and
`editor`/`terminal`. All three have their tables in the schema. `queue` also has its
whole wire surface now (juancode-1esi): the capability is withheld because nothing
delivers a queued message into a pty yet, and scenario 10 passes as soon as it is
switched on. See [docs/queue-delivery-port.md](./docs/queue-delivery-port.md).
See the package README in `apps/wire-conformance` for how to point the suite at a
core by URL.

### Measure it on a clean slate, or the number is not the core's

**One daemon and one data dir per run.** Two scenarios address fixed identifiers —
`adopt-external` adopts the CLI session id `conformance-adopted-0001`, and
`dispatch-correlation` claims the dispatch id `conformance-dispatch-correlation`. This
core dedups both for the lifetime of its store, which is the behaviour those scenarios
are asserting: the second adopt of a conversation we already own is silence, and the
second create for a claimed dispatch is an error. Point a second run at the same
daemon and both scenarios fail on the first step, every time, because the run before
already claimed those ids. Measured: run 1 of a reused daemon scores as a fresh one
and runs 2 through 5 lose exactly those two scenarios, five times out of five.

That is not flakiness and there is nothing to fix in the core; it is a measurement that
was taken against a daemon that still remembered the previous one. A repeatable score
means a fresh `JUANCODED_DATA_DIR` and a fresh process for each run.

## Run it

```sh
cargo build --release
JUANCODED_SOCKET=/tmp/juancoded.sock JUANCODED_PORT=4290 ./target/release/juancoded
./target/release/juancoded --dump-config   # print the tree and exit, binding nothing
```

The Unix socket path has to be short: `sun_path` is 104 bytes on macOS, so a socket
under a deep scratch directory fails to bind.

Ports: **4290 by default, never 4280 or 4281.** The Swift app owns 4280 and the
oracle sidecar owns 4281, so running all three at once is never a port fight.
`juancode-52e8.2` is where the *active* core takes over 4280.

The daemon refuses to start if another instance is already listening on its socket,
and binds TCP before touching the socket path — a failed second start used to unlink
the live instance's socket and leave it running but unreachable.

### It outlives the app, so it has to say who it is

A daemon holding ptys must survive an app relaunch — that is the point of a separate
process. The cost is that an app can reconnect to a daemon started hours ago, under
an older build and a different environment, and show its mirror as if it were fresh.
So `serverInfo` carries a `daemon` object — pid, boot time, binary path, build stamp,
`buildId`, data dir, and the retention it actually enforces — and the client compares
it against its own launch (`DaemonIdentity` in `apps/native/Sources/JuancodeClient`).
A mismatch shows in the core badge as `rust · stale` rather than being invisible.

`JUANCODE_SESSIONS_PER_PROJECT` is the one that bites: it is read **once, at daemon
start**, so setting it on an app launch line does nothing until the daemon restarts.
That is why the effective value goes out on the handshake instead of being inferred.

`apps/native/scripts/juancoded.sh` (`ensure|reap|status|stop|restart`) owns the
lifetime from the app side: a launch that starts a daemon owns it and reaps it when
the app exits (`SIGTERM`, grace period, then `SIGKILL`), and a daemon it did not start
is reported but never touched. Ownership is recorded in `juancoded.owner` beside the
run file — separate files because they have separate writers, and one process must
never be editing the other's record.

That teardown is why `main` takes **SIGTERM** through the same orderly shutdown as
ctrl-c. Default SIGTERM disposition is immediate death with no unwinding, which would
have made the launcher's grace period a wait over an already-dead process — the exact
torn-write-mid-flush the grace period exists to avoid.

Then point the Swift client at it:

```sh
cd client-spike && swift build
./.build/debug/JuancodedClientSpike --cwd ~/some/project          # interactive window
./.build/debug/JuancodedClientSpike --cwd ~/some/project --dump-after 12   # grid to stderr
```

Launch the daemon from a **plain terminal**, not from inside a `claude` session: env
inheritance is faithful, so a `CLAUDE_CODE_CHILD_SESSION` marker in the parent is
passed straight through and the spawned CLI turns transcript saving off.

## Deliberately not here

No queue **delivery**: `subscribeQueue` / `unsubscribeQueue` / `queueMessage` /
`dequeueMessage` and the `queue` snapshot all work, and a queued message then sits
there, because the paste-then-verified-Enter engine is still Swift-only
(juancode-52e8.8). The `queue` capability stays withheld until it is not, so no client
can offer a send button whose messages pile up.

No `trackedPrs` / `editor` / `terminal` wire surfaces (both have their tables, neither
has its messages), and no structured-transcript activity signal: the detector reads the
rendered screen only, where the Swift one also fuses the CLI's stream-json transcript
(juancode-52e8.12). Each of those is a named child of the epic.

Nothing in `apps/native` was modified, and nothing here runs unless started by hand:
the daemon binds no port until launched, and mounting the tree spawns no child until a
client asks for a session.
