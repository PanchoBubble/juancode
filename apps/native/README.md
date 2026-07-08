# juancode native (Swift)

Native macOS port of juancode where **the app is the server** (epic `juancode-u34`).
A single in-process registry owns the real ptys (claude/codex via `forkpty`, env
untouched), fanning pty output out to N subscribers: the local SwiftUI view AND
remote browser/phone clients over an embedded WS server.

## `JuancodeCore` — the node-pty replacement (`juancode-u34.2`)

Dependency-free Swift library mirroring the server's session layer. SwiftTerm and
the embedded server are _subscribers_ to this core (added in u34.3/u34.4), so the
core has no UI/server deps.

| Swift (`Sources/JuancodeCore`) | mirrors (`apps/server/src`)                    |
| ------------------------------ | ---------------------------------------------- |
| `PtyProcess`                   | node-pty (`forkpty` + `execvp`)                |
| `Session`                      | `session.ts`                                   |
| `SessionRegistry`              | `registry.ts`                                  |
| `CodexSessionDiscovery`        | `codexSession.ts`                              |
| `Providers` / `resolveBin`     | `providers.ts` / `resolveBin.ts`               |
| `ActivityDetector`             | `activityDetector.ts`                          |
| `Scrollback`                   | `scrollback.ts`                                |
| `Protocol` (models)            | `protocol.ts`                                  |
| `SessionStore` (seam)          | `db.ts` surface — in-memory now, GRDB in u34.5 |

### Key invariants

- **Env fidelity by construction.** `PtyProcess` spawns via `forkpty` + `execvp`,
  inheriting `environ` verbatim — no shadow HOME/CODEX_HOME, no envp built. The
  prime directive holds with no careful copying.
- **fork() safety.** All C strings are built in the parent _before_ `forkpty`; the
  child calls only async-signal-safe `chdir`/`execvp`/`_exit`. (fork in a
  multithreaded process can't safely `malloc`.)
- **Fan-out.** `Session.subscribeOutput(replay:)` is the seam every consumer uses;
  late subscribers get a scrollback replay, exactly like the WS layer on reattach.
- **Reliable lifecycle.** Exit is detected by a dedicated `waitpid` thread (no
  kqueue/EOF races); `terminate()` sends graceful SIGTERM + closes the master,
  then a SIGKILL backstop after 200ms for children that defer SIGTERM.

### Seams for later tickets

- `SessionStore` — write-path persistence used by `Session`. Default
  `InMemorySessionStore`; the SQLite store lands in `JuancodePersistence` (below).
- Title/usage polling (u34.6) plug in via `SessionEnvironment`.

## `JuancodePersistence` — SQLite store (`juancode-u34.5`)

GRDB-backed `PersistentStore` (a faithful port of `apps/server/src/db.ts`).
Persists session metadata + capped scrollback, GitHub-PR-style inline diff
comments, cached 'Review with Claude' results, and an **FTS5** full-text index
over titles + scrollback — so history and search survive app restarts.

| Swift (`Sources/JuancodePersistence`) | mirrors (`apps/server/src`)                      |
| ------------------------------------- | ------------------------------------------------ |
| `GRDBStore`                           | `db.ts` (`sessionDb` + `commentDb` + `reviewDb`) |

- **Schema-compatible** with the Node `juancode.db`: scrollback is TEXT (a lossy
  UTF-8 view of the raw pty bytes), so the same data dir is readable by either
  implementation. Replay stays faithful because trimming happens on byte
  boundaries upstream (`Scrollback`).
- The only target that depends on GRDB; `JuancodeCore` stays dependency-free.
  The server holds one `GRDBStore` as both the `SessionStore` (handed to the
  registry's `SessionEnvironment`) and the richer `PersistentStore` for queries.

## `JuancodeServices` — auxiliary services (`juancode-u34.6`)

1:1 Swift `Process` ports of the server's shell-out + parse modules. Foundation +
`JuancodeCore` only (no server/UI deps). Every shell-out goes through
`ProcessRunner` (an `execFile` replacement that inherits the environment verbatim —
the prime directive).

| Swift (`Sources/JuancodeServices`) | mirrors (`apps/server/src`)                     |
| ---------------------------------- | ----------------------------------------------- |
| `ProcessRunner`                    | `execFile` (the shared shell-out backbone)      |
| `Git`                              | `git.ts` (diff, state, worktrees, commit, push) |
| `Gh` / `Commit`                    | `gh.ts` / `commit.ts` (PRs; AI commit message)  |
| `Review`                           | `review.ts` ('Review with Claude')              |
| `Beads` / `Status`                 | `beads.ts` / `status.ts` (bd issues; MCP/auth)  |
| `SessionTitle` / `SessionUsage`    | `sessionTitle.ts` / `sessionUsage.ts`           |
| `RecoverSession`                   | `recoverSession.ts` (recover an old CLI id)     |
| `EphemeralPty`                     | `editor.ts` + `terminal.ts` (editor/shell ptys) |
| `SessionEnvironment.live(store:)`  | the title/usage poll seam wired into `Session`  |

Title/usage polling is injected into `Session` via `SessionEnvironment` (the core
stays dependency-free); use `SessionEnvironment.live(store:)` for the real seams.

## `JuancodeServer` — embedded WS+HTTP server (`juancode-u34.3`)

A Hummingbird 2 server that folds the server role into the app. Serves the
`protocol.ts` wire format over `/ws` (mirrors `ws.ts`) and the REST endpoints
(mirrors `index.ts`), so the existing React web app (`apps/web`) works as a
remote client almost unchanged. Remote browser/phone clients subscribe to
registry sessions here; the local SwiftUI view (u34.4) is an in-process
subscriber to the same registry (no WS hop).

| Swift (`Sources/JuancodeServer`) | mirrors (`apps/server/src`)                             |
| -------------------------------- | ------------------------------------------------------- |
| `WireProtocol`                   | `protocol.ts` (`ClientMessage`/`ServerMessage` Codable) |
| `WebSocketConnection`            | `ws.ts` (per-connection subs + activity + routing)      |
| `JuancodeServer` (routes)        | `index.ts` (REST: diff/git/PR/beads/review/…)           |
| `AppState`                       | the `registry` + `sessionDb` + ephemeral singletons     |

`AppState` owns one `GRDBStore` (handed to the registry as the `SessionStore`
and used directly as the `PersistentStore` for queries), the `SessionRegistry`
(built with `SessionEnvironment.live`), and the ephemeral editor/terminal ptys.

## `JuancodeApp` — the SwiftUI shell (`juancode-u34.4`)

The native app (`swift run juancode`): the local shell AND the host of the
embedded server. The local UI is an **in-process subscriber** to the same
`SessionRegistry` the server drives — no WS hop for the local view; remote
browser/phone clients attach to the identical registry over `/ws`.

| Swift (`Sources/JuancodeApp`) | role                                                                                               |
| ----------------------------- | -------------------------------------------------------------------------------------------------- |
| `JuancodeApp` (`@main`)       | boots `AppState`, starts the embedded server in the background                                     |
| `AppModel`                    | observable bridge to the registry/store (sessions, activity, create/reactivate/delete)             |
| `RootView` / `SidebarView`    | `NavigationSplitView` sidebar + session detail                                                     |
| `SwiftTermLive`               | SwiftTerm `TerminalView` fed by `Session.subscribeOutput` (replay + live); keystrokes/resize → pty |
| `GhosttyLive`                 | libghostty (GPU) counterpart of `SwiftTermLive` over the same seam; see _Terminal backend_ below   |
| `NewSessionView`              | provider + cwd + accept-all + worktree → `registry.create`                                         |

Core shell shipped: sidebar with live activity dots, session view,
new-session + reactivate + delete.

### Terminal backend — GhosttyKit spike (`juancode-gq9`)

SwiftTerm 1.13.0 had unreliable resize + render glitches in full-screen TUIs, so
the live surface was spiked over to **GhosttyKit** (`Lakr233/libghostty-spm`,
GPU-rendered) behind the existing `SwiftTermLive` seam. The architecture is
unchanged: _we_ still own the pty. libghostty runs as a host-driven backend via
`InMemoryTerminalSession` — pty output is pushed in with `receive(_:)`, keystrokes
come back through the `write` callback, and grid changes arrive on the resize
delegate → our SIGWINCH. Ghostty spawns no process of its own.

`TerminalBackendChoice.useGhostty` picks the backend at every call site
(`RootView` main session, `OracleDock` chat, `BottomTerminalPanel` shell):

- **default** → `GhosttyLive` / `GhosttyEphemeral` (GhosttyKit)
- `JUANCODE_SWIFTTERM=1` → `SwiftTermLive` / `SwiftTermEphemeral` (fallback for A/B)

SwiftTerm is retained as the fallback (not retired) until the spike is signed off;
`EditorOverlay`'s ephemeral pty still runs on SwiftTerm. Both backends build clean
(`swift build`); the remaining sign-off is visual — confirming glitch-free
full-screen TUI + resize on a real display.

### Panels (`juancode-5za`, shipped)

The `apps/web` panels are now ported to SwiftUI, keyed per work dir off `AppModel`
(`beadsByCwd` / `prsByCwd`):

| `Sources/JuancodeApp`         | role                                                                                                      |
| ----------------------------- | --------------------------------------------------------------------------------------------------------- |
| `ChangesPanel`                | git diff with vim-like syntax highlighting + click-drag line-range inline comments + 'Review with Claude' |
| `IssuesPanel`                 | interactive bd/beads issues per folder (grouped via `BeadsGrouping`); `workOnIssue` dispatches a session  |
| `BottomTerminalPanel`         | per-workdir shell terminal, VS Code-style tabs + split                                                    |
| `SearchPanel` / `StatusPanel` | FTS5 scrollback search; MCP/auth status                                                                   |
| `EditorOverlay`               | in-app file editor modal (ephemeral pty)                                                                  |
| `RootView`                    | tabbed right-side panel switching Changes/Issues, docks the bottom terminal                               |

## Oracle — global orchestrator (`juancode-wjg`)

A persistent global helper docked bottom-right (`OracleDock`), independent of the
focused session/workdir. Two surfaces in one floating panel:

- **Issues** — a global bd tracker living in its own control dir
  (`~/.juancode/oracle`, a git repo with a `.beads` tracker, prefix `oracle-`). It's
  just another cwd, so the existing `getBeads(cwd)` reads it unchanged — no `--db`
  plumbing. Each item offers **Dispatch…** (spawn an agent in a project) and **Ask
  Oracle**.
- **Chat** — a real pinned `claude` session (cwd = the control dir, so it gets
  native bd access + reads `AGENTS.md`). Identified by its unique cwd and hidden
  from the per-project sidebar; restored across launches.

| `Sources/…`                     | role                                                                                                                                                                                              |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `JuancodeServices/Oracle.swift` | control-dir bootstrap (`git init` + `bd init`), the `dispatch.jsonl` mailbox (append/tail with offset + partial-line safety), the `state.json` snapshot, and the agent's `AGENTS.md` instructions |
| `JuancodeApp/OracleModel.swift` | owns the agent session, tails the mailbox to spawn project agents, keeps `state.json` fresh, exposes the global tracker                                                                           |
| `JuancodeApp/OracleDock.swift`  | the bottom-right overlay: Issues view + dispatch picker + the agent chat terminal                                                                                                                 |

**Dispatch bridge.** Rather than scraping a TUI pty stream, the Oracle agent (and
the dock UI) append one `OracleDispatch` JSON line to `dispatch.jsonl`; the app
tails it and turns each line into a real session via `AppModel.create` (reusing
worktree isolation). Deterministic, observable, and faithful — the agent uses its
normal file tools, no new network surface. Set `JUANCODE_ORACLE_DIR` to relocate
the control dir (tests do).

## Run

Requires macOS 14+, a Swift 6 toolchain (Xcode 16 / recent Swift), and
`claude`/`codex` on your `PATH` and authenticated (the app spawns the real CLIs —
tests don't need them, they use a fake resolver).

### The app (recommended)

```sh
cd apps/native
scripts/dev-app.sh               # build + run the SwiftUI app in the foreground
```

Run the app through `scripts/dev-app.sh`, **not** `swift run juancode`. The script
wraps the binary in a minimal `.app` bundle and execs the inner binary straight
from your terminal. That matters for two reasons:

- **Bundle identity.** A bare SPM executable has no bundle, so macOS file panels
  (`NSOpenPanel` / SwiftUI `.fileImporter`) hang and the Dock icon is flaky.
- **Env fidelity (the prime directive).** Exec'ing the binary from your shell (not
  via Finder/`open`) hands the app your full environment — `PATH`, MCP config, keys
  — which `claude`/`codex` must inherit. Launching via `open` would give it
  launchd's stripped environment and break that.

Useful knobs:

```sh
JUANCODE_CONFIG=release scripts/dev-app.sh   # optimized build
JUANCODE_SWIFTTERM=1     scripts/dev-app.sh   # SwiftTerm terminal backend (default is GhosttyKit)
JUANCODE_ORACLE_DIR=…    scripts/dev-app.sh   # relocate the Oracle control dir
scripts/dev-app.sh --print-bin               # build + assemble, print the inner binary path, don't exec
```

### Other targets

```sh
swift test                       # unit + integration (core + persistence + services + server)
swift run juancode-smoke claude  # smoke the core against the real claude CLI
swift run juancode-serve         # boot the embedded WS+HTTP server (headless) on :4280
```

With `juancode-serve` running, the oracle sidecar (`pnpm dev:oracle`) can connect
to its `/ws` on `:4280` to bridge sessions to Telegram / the phone console.

(`swift run juancode` does build and launch the app, but without the `.app`
wrapper — expect hanging file pickers and a flaky Dock icon. Use `dev-app.sh`.)
