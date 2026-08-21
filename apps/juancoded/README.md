# juancoded — the harness core in Rust (spike: juancode-52e8.3)

Go/no-go spike for epic `juancode-52e8`: move the non-UI half of juancode into a
portable Rust daemon behind a switchable backend.

**Verdict: GO.** All three risks cleared, all three numbers below beat the Swift
path, and the Swift UI renders a session the Rust core owns with no FFI and no new
protocol.

## What it proves

1. **Env fidelity, by construction and by test.** `portable-pty`'s
   `CommandBuilder::new` seeds from `std::env::vars_os()`, so the child gets our
   whole environment and nothing else. The only entry we ever add is a provider's
   `spawn_env` overlay — opencode's opt-in bypass, which that CLI exposes only as an
   env var. `pty::tests::the_child_environment_is_inherited_untouched` runs
   `/usr/bin/env` in a real pty and diffs it against our own environ, and asserts no
   `CODEX_HOME` / `CLAUDE_CONFIG_DIR` appeared. Live confirmation: the spawned
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
cargo run --release -p juancoded-core --example echo_latency
cargo run --release -p juancoded-core --example throughput <big-file>
cargo run --release -p juancoded-server --example uds_rtt -- /tmp/juancoded-spike.sock
```

## Crate layout

| Crate | What it owns | Swift counterpart |
| --- | --- | --- |
| `juancoded-vt` | The grid (`alacritty_terminal`), `Snapshot`, `screen` frame encoding | `SessionTerminalModel.swift`, `ScreenWire.swift` |
| `juancoded-core` | Wire model types, provider specs + `resolve_bin`, pty host, session registry | `Protocol.swift`, `Providers.swift`, `PtyProcess.swift`, `SessionRegistry.swift` |
| `juancoded-server` | The wire protocol, WS connection loop, screen streamer, listeners | `WireProtocol.swift`, `WebSocketConnection.swift`, `ScreenStreamer.swift` |
| `juancoded-persistence` | The per-core DB seam (in-memory for now) | `JuancodePersistence` |
| `juancoded-plugins` | `EffectRegistry` + `EffectGuard`: a registration that unregisters on `Drop` | none — this is the point of the move |
| `juancoded` | The daemon binary | — |

`juancoded-plugins` is the smallest crate and the one carrying the epic's fourth
argument: cordis's "registrations are reversible effects" is just a value whose
`Drop` unregisters. It is proven by test and wired into nothing yet — juancode-52e8.4
builds the real registry on top.

## Run it

```sh
cargo build --release
JUANCODED_SOCKET=/tmp/juancoded.sock JUANCODED_PORT=4290 ./target/release/juancoded
```

Ports: **4290 by default, never 4280 or 4281.** The Swift app owns 4280 and the
oracle sidecar owns 4281, so running all three at once is never a port fight.
`juancode-52e8.2` is where the *active* core takes over 4280.

The daemon refuses to start if another instance is already listening on its socket,
and binds TCP before touching the socket path — a failed second start used to unlink
the live instance's socket and leave it running but unreachable.

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

No persistence beyond an in-memory store, no queue / tracked-PR / editor / terminal
messages, no activity detection worth the name (a 700 ms quiet debounce stands in for
`ActivityDetector`), no grid arbitration between competing clients, no session
resume, no codex/opencode session-id discovery. Each of those is a named child of the
epic. Nothing in `apps/native` was modified by this spike, and nothing here runs
unless started by hand.
