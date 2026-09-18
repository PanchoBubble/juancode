// Booting a core under test.
//
// Two modes:
//   * JUANCODE_CONFORMANCE_URL points at an already-running core (how you drive a
//     core in a container, or one you have a debugger attached to).
//   * otherwise the core named by JUANCODE_CONFORMANCE_CORE is built and booted
//     here: `swift` (the default) builds `juancode-serve`, `rust` builds
//     `juancoded`.
//
// Booting is the mode CI uses for both cores. A core somebody started by hand is
// a core whose environment nobody can see in the log, and every unrepeatable
// conformance score this repo has reported came from one.
//
// Isolation is the hard requirement: a developer's live app owns :4280 and the
// sidecar owns :4281, and driving THAT app would create, resize and kill their
// real sessions. So the boot pins its own port, its own sqlite dir, its own
// oracle control dir, its own unix socket, and fake provider binaries.

import { spawn, type ChildProcess } from "node:child_process";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:net";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = join(here, "..");
const REPO_ROOT = join(PKG_ROOT, "..", "..");
const NATIVE_ROOT = join(REPO_ROOT, "apps", "native");
const JUANCODED_ROOT = join(REPO_ROOT, "apps", "juancoded");

export const FIXTURES = join(PKG_ROOT, "fixtures");

/** The cores this harness knows how to build and boot itself. */
export const CORE_NAMES = ["swift", "rust"] as const;
export type CoreName = (typeof CORE_NAMES)[number];

/** How a core went away, and what it said on the way out.
 *
 *  The log is the whole point. A core that dies mid-run used to leave nothing
 *  behind: the boot probe printed the core's output on a boot failure and nowhere
 *  else, so the death between scenario 24 and 25 in juancode-jyl9 was six
 *  ECONNREFUSED messages and no core log at all. */
export interface CoreDeath {
  /** One line a human can read: "killed by SIGKILL", "exited with status 101". */
  reason: string;
  code: number | null;
  signal: string | null;
  /** Tail of the core's stdout+stderr for the whole run, not just boot. */
  log: string;
  /** How long the core had been up, in ms, or null for a core we did not boot.
   *
   *  Here because a death at a round number is a different bug from a death at a
   *  random one: the daemon's own lifetime watchdog ends it a fixed grace after its
   *  owner goes (120s by default), a lease or a timer looks the same way, and a
   *  crash does not. Without this the report says which scenario noticed, which is a
   *  position in a run and not a duration. Exact when node saw the exit; otherwise it
   *  is when the harness FOUND the core gone, which the death is at or before. */
  upMs: number | null;
  /** The head of the macOS crash report the kernel wrote for this process, or null.
   *
   *  The gap it fills: a core that dies on SIGSEGV/SIGABRT prints nothing on its way
   *  out, so the 64KB ring is empty for exactly the deaths that most need explaining,
   *  and the backtrace is in a file nobody thought to look in. */
  crashReport: string | null;
}

/** A process exit as node saw it, with the clock reading that makes it a duration. */
interface ExitRecord {
  code: number | null;
  signal: string | null;
  atMs: number;
}

export interface CoreUnderTest {
  /** Label used in the parity report ("swift", "rust", or whatever was passed in). */
  label: string;
  /** WebSocket endpoint, e.g. ws://127.0.0.1:4295/ws */
  wsUrl: string;
  /** HTTP base, for the health probe. */
  httpBase: string;
  /** Where this core keeps its sqlite, or null when we did not boot it. */
  dataDir: string | null;
  /** Whether the suite booted this core (and may therefore stop it). */
  owned: boolean;
  /** The core process, when we booted it. Exposed so a test can kill it. */
  pid: number | null;
  /** Bounded tail of the core's own output so far. Empty for a core we did not boot. */
  log(): string;
  /** Non-null once the core is gone: how it died, plus everything it printed.
   *
   *  Costs health probes, so it is asked only once something has already gone wrong. */
  death(): Promise<CoreDeath | null>;
  stop(): Promise<void>;
}

/** How much of the core's output to keep. Bounded because a core under a repeat
 *  pass can print for minutes, and unbounded is how a harness ends up holding a
 *  whole run's stdout in memory. The tail is the part that explains a death. */
export const LOG_LIMIT_BYTES = 64 * 1024;

/** A byte-bounded tail of everything written to it.
 *
 *  Bounded by BYTES rather than by chunks: the old boot-only ring kept the last 200
 *  chunks, so a core logging one 8KB line at a time held 1.6MB and a core logging a
 *  byte at a time held 200 bytes. Neither of those is a size. */
export function makeLogRing(limit = LOG_LIMIT_BYTES): {
  push(chunk: string): void;
  text(): string;
} {
  let buf = "";
  return {
    push(chunk: string) {
      buf += chunk;
      if (buf.length > limit) buf = buf.slice(buf.length - limit);
    },
    text: () => buf,
  };
}

/** Where macOS leaves a crash report. Per-user, so no privilege is involved. */
export const CRASH_REPORT_DIR = join(homedir(), "Library", "Logs", "DiagnosticReports");

/** How much of a crash report to carry. The head, because the exception, the
 *  termination reason and the faulting thread are at the top of an `.ips` and the
 *  rest is every other thread's stack. */
const CRASH_REPORT_CHARS = 6000;

/** The signals that make the kernel write a crash report. SIGKILL and SIGTERM are
 *  deliberately absent: nothing is written for them, so looking would only ever find
 *  an unrelated file. */
const CRASH_SIGNALS = ["SIGSEGV", "SIGBUS", "SIGABRT", "SIGILL", "SIGFPE", "SIGTRAP", "SIGSYS"];

/** The head of the crash report macOS wrote for `exeName` since `sinceMs`, or null.
 *
 *  Matched by name and by time, and never by pid: the pid IS in the report body but
 *  the filename is `<exe>-<date>-<time>.ips`, and reading every report in the
 *  directory to find one would be reading the developer's other crashes. `sinceMs`
 *  is the boot time of the core we are asking about, so a report from an earlier run
 *  of the same binary cannot be picked up as this death's.
 *
 *  Best effort by design: ReportCrash writes the file a second or two after the
 *  process is gone, so a death the suite notices immediately can legitimately find
 *  nothing here, and the log and exit signal remain the primary evidence. */
export function findCrashReport(
  exeName: string,
  sinceMs: number,
  dir = CRASH_REPORT_DIR,
): string | null {
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    // No such directory (not macOS, or a sandbox): nothing to report.
    return null;
  }
  const candidates = names
    .filter((n) => n.startsWith(`${exeName}-`) && n.endsWith(".ips"))
    .map((n) => {
      const path = join(dir, n);
      try {
        return { path, at: statSync(path).mtimeMs };
      } catch {
        return null;
      }
    })
    .filter((c): c is { path: string; at: number } => c !== null && c.at >= sinceMs)
    .sort((a, b) => b.at - a.at);
  const newest = candidates[0];
  if (!newest) return null;
  try {
    const body = readFileSync(newest.path, "utf8");
    const head = body.slice(0, CRASH_REPORT_CHARS);
    return `${newest.path}\n\n${head}${body.length > head.length ? "\n… (truncated)" : ""}`;
  } catch {
    return null;
  }
}

/** One line naming how a process ended. */
export function describeExit(code: number | null, signal: string | null): string {
  if (signal) return `the core was killed by ${signal}`;
  if (code === null) return "the core exited for an unknown reason";
  return `the core exited with status ${code}`;
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

function run(cmd: string, args: string[], cwd: string, timeoutMs: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`${cmd} ${args.join(" ")} timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    child.stdout.on("data", (d) => (out += d.toString()));
    child.stderr.on("data", (d) => (err += d.toString()));
    child.on("exit", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(out);
      else reject(new Error(`${cmd} ${args.join(" ")} exited ${code}\n${err.slice(-4000)}`));
    });
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
  });
}

/** One health probe: null when it answered, else why it did not.
 *
 *  The Swift core serves /api/health; the Rust core serves both /health and
 *  /api/health. Probing both keeps the harness core-agnostic (the divergence
 *  itself is a parity item). */
async function probeHealth(httpBase: string): Promise<string | null> {
  let lastError = "never probed";
  for (const path of ["/api/health", "/health"]) {
    try {
      const res = await fetch(`${httpBase}${path}`);
      if (res.ok) return null;
      lastError = `HTTP ${res.status} on ${path}`;
    } catch (e) {
      lastError = e instanceof Error ? e.message : String(e);
    }
  }
  return lastError;
}

/** Two failed probes 250ms apart, or null if either answered.
 *
 *  Twice on purpose. One refused connection is what a mid-run death gives off, but
 *  it is also what a core busy enough to drop a listen-backlog entry gives off, and
 *  latching "the core died" on that would turn one slow scenario into an unmeasured
 *  tail. A process that is actually gone refuses both. */
async function confirmUnreachable(httpBase: string): Promise<string | null> {
  const first = await probeHealth(httpBase);
  if (first === null) return null;
  await sleep(250);
  return await probeHealth(httpBase);
}

/** Wait for the core to answer, giving up early when `abort` says the wait is
 *  pointless — a core that has already exited is never going to answer, and the
 *  reason it exited is the error worth reporting. */
async function waitHealthy(
  httpBase: string,
  timeoutMs: number,
  abort?: () => string | null,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let lastError = "never probed";
  while (Date.now() < deadline) {
    const why = await probeHealth(httpBase);
    if (why === null) return;
    lastError = why;
    const stop = abort?.();
    if (stop) throw new Error(`${stop} (last probe: ${lastError})`);
    await sleep(200);
  }
  throw new Error(`core at ${httpBase} never became healthy (${lastError})`);
}

/** Write the preset the `spawn-preset` scenario names, and return the directory.
 *
 *  One line, and a marker rather than prose: claude's mechanism puts the body in the
 *  CLI's argv, the fake agent echoes argv back through `ARGS`, and the scenario matches
 *  on the marker — so a multi-line body would arrive folded into the output frame and a
 *  generic one could match something else in the line. `conformance-missing` is
 *  deliberately NOT written: the scenario needs a name that resolves to nothing to prove
 *  the core errors instead of dropping it. */
export function seedPresets(dir: string): string {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "conformance.md"), "PRESET-MARKER-conformance\n", "utf8");
  return dir;
}

/** The core knobs a run is allowed to inherit from whoever started it. Exactly one,
 *  and it changes how loud the core is rather than what it does — which is the bar
 *  for being on this list, because the point of the list below is that a knob a core
 *  READS is a knob a run must SET. */
/** The heavy-queue registry a booted core reads, seeded with two waiting jobs.
 *
 *  Seeded here rather than by a scenario for the reason `seedPresets` is: the core
 *  reads a directory, and a scenario cannot write a file. Left unset a core would
 *  read `/tmp/claude-heavy-$UID` — the developer's REAL queue — and the scenario's
 *  `heavySetSlots` would rewrite the live `~/.claude/heavy-queue.json` that other
 *  tooling on the machine reads. `JUANCODE_HEAVY_ROOT` moves the config with the
 *  registry for exactly that reason, so one variable is the whole isolation.
 *
 *  The two pids are this process and its parent, because the core filters the
 *  registry on liveness and an entry for a dead pid is not in any snapshot. They are
 *  alive for the length of the run by construction, and nothing in the scenario ever
 *  signals them: `heavyCancel` is exercised against a pid the queue does NOT hold,
 *  which is the refusal that keeps the frame from being an arbitrary-kill gadget.
 *  `since` is fixed so the waiting order is the seeded order on every attempt. */
export function seedHeavyQueue(dir: string): string {
  const queue = join(dir, "queue");
  mkdirSync(queue, { recursive: true });
  const entry = (pid: number, since: number, cwd: string) =>
    JSON.stringify({ pid, prio: 0, since, slot: 0, cmd: "conformance job", cwd, child: null });
  writeFileSync(join(queue, `${HEAVY_PIDS.a}.json`), entry(HEAVY_PIDS.a, 100, "/repo/first"));
  writeFileSync(join(queue, `${HEAVY_PIDS.b}.json`), entry(HEAVY_PIDS.b, 200, "/repo/second"));
  return dir;
}

/** The two live pids `seedHeavyQueue` writes entries for, and one that is not in the
 *  registry at all. `0` can never be a job: it is not a pid a process can have, so a
 *  core that took it for one would be signalling its own process group. */
export const HEAVY_PIDS = { a: process.pid, b: process.ppid, missing: 0 };

export const CORE_ENV_PASSTHROUGH = ["JUANCODED_LOG"];

/** The parent environment with every core knob removed.
 *
 *  A booted core inherits the shell that started the suite, and both cores read a
 *  pile of `JUANCODE_*` / `JUANCODED_*` variables. Anything this boot does not set
 *  explicitly therefore arrives from the developer's session, which is the opposite
 *  of the "its own everything" the boot promises — and several of those knobs are
 *  not cosmetic:
 *
 *    * `JUANCODE_OWNER_PID` arms the Rust daemon's lifetime watchdog. A core that
 *      reads one ends ITSELF a grace period (120s by default) after that process is
 *      gone, through the orderly shutdown path — no panic, no crash, no last words,
 *      just a daemon that stops answering mid-run. That is the exact shape of
 *      juancode-jyl9, and the variable is in the environment of every agent session
 *      the launcher's daemon spawned, because a pty child inherits it.
 *    * `JUANCODE_OPENCODE_DB` points a core at a real opencode store.
 *    * `JUANCODE_REAP_SWEEP_MS` re-times the reaper the boot deliberately disabled.
 *
 *  So the rule is the whole prefix rather than a list of the ones that have bitten:
 *  a knob added to a core later must not be able to arrive from a developer's shell
 *  without anybody noticing. `JUANCODE_CONFORMANCE_*` goes too — those are read by
 *  this process, never by a core. */
export function isolatedParentEnv(
  parent: NodeJS.ProcessEnv = process.env,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(parent)) {
    if (value === undefined) continue;
    if (/^JUANCODED?_/.test(key) && !CORE_ENV_PASSTHROUGH.includes(key)) continue;
    out[key] = value;
  }
  return out;
}

/** The environment a booted core runs with. Every knob here exists so the golden
 *  transcripts are reproducible; see apps/native/Sources/JuancodeCore/Config.swift. */
export function coreEnv(port: number, dataDir: string, oracleDir: string): Record<string, string> {
  const fakeAgent = join(FIXTURES, "fake-agent.sh");
  const fakeEditor = join(FIXTURES, "fake-editor.sh");
  const fakeGh = join(FIXTURES, "fake-gh.sh");
  for (const f of [fakeAgent, fakeEditor, fakeGh]) chmodSync(f, 0o755);
  return {
    JUANCODE_PORT: String(port),
    JUANCODE_HOST: "127.0.0.1",
    JUANCODE_DATA_DIR: dataDir,
    JUANCODE_ORACLE_DIR: oracleDir,
    // Deterministic pty children: no provider CLI, no auth, no network.
    JUANCODE_CLAUDE_BIN: fakeAgent,
    JUANCODE_CODEX_BIN: fakeAgent,
    JUANCODE_OPENCODE_BIN: fakeAgent,
    // Two knobs on purpose: JuancodeCore resolves the editor from JUANCODE_EDITOR,
    // but the ephemeral pty the `openEditor` message actually spawns reads
    // $VISUAL/$EDITOR (EphemeralPty.editorCommand). Set all three so neither path
    // launches the developer's real editor.
    JUANCODE_EDITOR: fakeEditor,
    VISUAL: fakeEditor,
    EDITOR: fakeEditor,
    // A predictable login shell for `openTerminal`, instead of the developer's own
    // interactive shell sourcing their rc files.
    SHELL: "/bin/bash",
    // Tracked-PR polling must not reach GitHub from a test run.
    JUANCODE_GH_BIN: fakeGh,
    // The transcript seam reads claude's own project directories. Left unset it would
    // read the developer's — 387 of them on the machine this was written on — and a
    // conformance run would be walking somebody's real conversation history looking
    // for the fake agent's session id. Read-only either way, but "its own everything"
    // is the promise this boot makes, so it gets its own empty one.
    JUANCODE_CLAUDE_PROJECTS_DIR: join(dataDir, "claude-projects"),
    // The preset directory a `create.preset` name resolves against. Its own, and
    // seeded here rather than by a scenario, because the core reads it at spawn and a
    // scenario cannot write a file. Left unset a core would read the developer's real
    // presets, so a run would depend on what they happen to have written.
    JUANCODE_PRESET_DIR: seedPresets(join(dataDir, "presets")),
    // The heavy-queue registry, and the capacity config that moves with it. See
    // `seedHeavyQueue`: unset, a run would reorder the developer's real queue and
    // rewrite their live `~/.claude/heavy-queue.json`.
    JUANCODE_HEAVY_ROOT: seedHeavyQueue(join(dataDir, "heavy")),
    // Fixed scrollback so replay assertions do not depend on a user's setting.
    JUANCODE_SCROLLBACK: String(64 * 1024),
    // No retention pruning and no reaping: a scenario's session must still exist
    // when the next step addresses it.
    JUANCODE_SESSIONS_PER_PROJECT: "0",
    JUANCODE_MAX_LIVE_SESSIONS: "0",
    JUANCODE_REAP_IDLE_MINUTES: "0",
  };
}

/** How to build and boot one core. Everything that differs between the Swift and
 *  the Rust core lives here; the boot itself is shared. */
interface CoreRecipe {
  /** Build the product, then hand back the executable to spawn. */
  resolve(skipBuild: boolean, buildTimeoutMs: number): Promise<string>;
  /** Environment on top of coreEnv() that this core needs to be isolated. */
  isolation(port: number, dataDir: string): Record<string, string>;
}

const RECIPES: Record<CoreName, CoreRecipe> = {
  swift: {
    resolve: async (skipBuild, buildTimeoutMs) => {
      if (!skipBuild) {
        // A sibling `swift build` holds the same package lock, so this can block
        // for minutes before it even starts compiling. That is normal, not a hang.
        await run("swift", ["build", "--product", "juancode-serve"], NATIVE_ROOT, buildTimeoutMs);
      }
      const binPath = (
        await run(
          "swift",
          ["build", "--product", "juancode-serve", "--show-bin-path"],
          NATIVE_ROOT,
          120_000,
        )
      ).trim();
      return join(binPath.split("\n").pop() ?? binPath, "juancode-serve");
    },
    // coreEnv already speaks the Swift core's own variables.
    isolation: () => ({}),
  },
  rust: {
    resolve: async (skipBuild, buildTimeoutMs) => {
      if (!skipBuild) {
        // Same caveat as swift: a sibling cargo holds the target-dir lock.
        await run("cargo", ["build", "--bin", "juancoded"], JUANCODED_ROOT, buildTimeoutMs);
      }
      // Ask cargo where the target dir is rather than assuming ./target: a
      // CARGO_TARGET_DIR in the environment (CI caching does this) moves it.
      const meta = JSON.parse(
        await run(
          "cargo",
          ["metadata", "--format-version", "1", "--no-deps"],
          JUANCODED_ROOT,
          120_000,
        ),
      ) as { target_directory?: string };
      const targetDir = meta.target_directory ?? join(JUANCODED_ROOT, "target");
      return join(targetDir, "debug", "juancoded");
    },
    isolation: (port, dataDir) => ({
      // The daemon reads its OWN spellings. coreEnv's JUANCODE_PORT means nothing
      // to it, so without these it listens on its default 4290 with the
      // developer's real data dir, which is exactly the isolation the README
      // promises it has.
      JUANCODED_PORT: String(port),
      JUANCODED_DATA_DIR: dataDir,
      // And it defaults its unix socket to $HOME/.juancode/juancoded.sock, so
      // unset it would take the developer's socket away from their own daemon.
      // Short filename on purpose: a unix socket path is capped near 104 bytes
      // and the temp dir already spends half of that.
      JUANCODED_SOCKET: join(dataDir, "jd.sock"),
    }),
  },
};

/** Which core a boot should build, from the environment. */
export function coreName(raw = process.env.JUANCODE_CONFORMANCE_CORE): CoreName {
  if (raw === undefined || raw === "") return "swift";
  const found = CORE_NAMES.find((n) => n === raw);
  if (!found) {
    throw new Error(
      `JUANCODE_CONFORMANCE_CORE=${raw} is not a core this suite can boot (${CORE_NAMES.join(", ")})`,
    );
  }
  return found;
}

/** The default port for a core we boot, and the two ports a boot must never touch. */
export const DEFAULT_PORT = 4295;
const DEV_PORTS = [4280, 4281];

/** Which port a boot should use, from the environment.
 *
 *  `0` means "ask the kernel for a free one", which is the only setting under which
 *  two runs on one machine cannot collide. A fixed port is still honoured, because CI
 *  pins one per job and a developer attaching a debugger wants to know the number. */
export function conformancePort(raw = process.env.JUANCODE_CONFORMANCE_PORT): number {
  if (raw === undefined || raw.trim() === "") return DEFAULT_PORT;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0 || n > 65535) {
    throw new Error(
      `JUANCODE_CONFORMANCE_PORT=${raw} is not a port (0 for an ephemeral one, or 1-65535)`,
    );
  }
  return n;
}

/** A port the kernel says is free: bind 127.0.0.1:0, read back what we were given,
 *  release it and hand the number to the core.
 *
 *  There is a window between the release and the core's bind, so this is not a lock —
 *  but it draws from the ephemeral range (49152+ here), which nothing pins by hand,
 *  instead of from the handful of numbers every agent's README tells it to try. The
 *  pre-flight probe still guards a port a caller named. */
export function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.on("error", reject);
    probe.listen({ host: "127.0.0.1", port: 0 }, () => {
      const addr = probe.address();
      if (addr === null || typeof addr === "string") {
        probe.close(() => reject(new Error("could not read back an ephemeral port")));
        return;
      }
      const { port } = addr;
      probe.close((err) => (err ? reject(err) : resolve(port)));
    });
  });
}

export interface StartOptions {
  /** Which core to build and boot. Defaults to JUANCODE_CONFORMANCE_CORE. */
  core?: CoreName;
  /** Port for a core we boot ourselves, or 0 for an ephemeral one. Never 4280/4281
   *  (a dev machine's app/sidecar). Defaults to JUANCODE_CONFORMANCE_PORT. */
  port?: number;
  /** Skip the build (the binary is already built, e.g. a previous CI step). */
  skipBuild?: boolean;
  buildTimeoutMs?: number;
  /** Boot this executable instead of building a core. Skips the recipe's build
   *  entirely; the isolation environment still applies. Exists so the harness's own
   *  death handling can be tested against a process it is allowed to kill. */
  exe?: string;
}

/** Attach to a running core, or build and boot one. */
export async function startCore(opts: StartOptions = {}): Promise<CoreUnderTest> {
  const external = process.env.JUANCODE_CONFORMANCE_URL;
  if (external) {
    const httpBase = external.replace(/^ws/, "http").replace(/\/ws$/, "").replace(/\/$/, "");
    const wsUrl = `${httpBase.replace(/^http/, "ws")}/ws`;
    await waitHealthy(httpBase, 30_000);
    return {
      label: process.env.JUANCODE_CONFORMANCE_LABEL ?? "external",
      wsUrl,
      httpBase,
      dataDir: null,
      owned: false,
      pid: null,
      // Somebody else's process: we do not hold its stdout, so all we can report
      // about its death is that it stopped answering.
      log: () => "",
      death: async () => {
        const why = await confirmUnreachable(httpBase);
        return why === null
          ? null
          : {
              reason: `the core stopped answering ${httpBase} (${why})`,
              code: null,
              signal: null,
              log: "",
              // Somebody else's process: we did not start it, so we cannot say how
              // long it had been up, and its crash report is not ours to go looking
              // for under a name we never spawned.
              upMs: null,
              crashReport: null,
            };
      },
      stop: async () => {},
    };
  }

  const name = opts.core ?? coreName();
  const recipe = RECIPES[name];
  const requested = opts.port ?? conformancePort();
  if (DEV_PORTS.includes(requested)) {
    throw new Error(
      `refusing to drive port ${requested}: that is a developer's live app / sidecar`,
    );
  }
  // Somebody else's core on the port answers every probe below, so the suite
  // would boot a child that cannot bind, not notice, measure a daemon it does
  // not own, and then go red the moment that daemon's owner stops it. Measured
  // here: two agents ran the rust suite on 4300 in different worktrees, and the
  // second one reported 16 scenarios failing with ECONNREFUSED. A score against
  // a core you did not boot is not a measurement.
  //
  // Only for a port a caller named: an ephemeral one is picked below, from the
  // range nothing pins by hand, and has nothing to collide with.
  if (requested !== 0 && (await probeHealth(`http://127.0.0.1:${requested}`)) === null) {
    throw new Error(
      `something is already serving http://127.0.0.1:${requested} — refusing to drive a ` +
        `core this run did not boot. Use JUANCODE_CONFORMANCE_PORT=0 for a free port, ` +
        `name another one, or point JUANCODE_CONFORMANCE_URL at it deliberately.`,
    );
  }
  const skipBuild = opts.skipBuild ?? process.env.JUANCODE_CONFORMANCE_SKIP_BUILD === "1";
  const buildTimeoutMs = opts.buildTimeoutMs ?? 20 * 60_000;

  const exe = opts.exe ?? (await recipe.resolve(skipBuild, buildTimeoutMs));

  // After the build on purpose: a cargo or swift build is minutes long, and a port
  // reserved before it is a port somebody else can take while we compile.
  const port = requested === 0 ? await freePort() : requested;
  const httpBase = `http://127.0.0.1:${port}`;

  const dataDir = mkdtempSync(join(tmpdir(), "juancode-conformance-data-"));
  const oracleDir = mkdtempSync(join(tmpdir(), "juancode-conformance-oracle-"));
  const env = {
    ...isolatedParentEnv(),
    ...coreEnv(port, dataDir, oracleDir),
    ...recipe.isolation(port, dataDir),
  };
  const bootedAtMs = Date.now();
  const child: ChildProcess = spawn(exe, [], {
    cwd: dataDir,
    env,
    stdio: ["ignore", "pipe", "pipe"],
    // Its own process group, so stopping the core also stops the fake agents it
    // spawned without ever signalling anything else on the machine.
    detached: true,
  });
  // Kept for the WHOLE run, not just the boot. This ring is the only record of
  // what a core said before it went away mid-suite.
  const ring = makeLogRing();
  const record = (d: Buffer) => ring.push(d.toString());
  child.stdout?.on("data", record);
  child.stderr?.on("data", record);
  // A holder rather than a bare `let`: the exit lands on a callback, and the
  // narrowing TypeScript does to a captured `let` would type it away.
  const state: { exit: ExitRecord | null } = { exit: null };
  child.on("exit", (code, signal) => (state.exit = { code, signal, atMs: Date.now() }));

  try {
    await waitHealthy(httpBase, 60_000, () =>
      state.exit ? `the core exited before it answered on ${httpBase}` : null,
    );
  } catch (e) {
    stopGroup(child);
    throw new Error(`${e instanceof Error ? e.message : String(e)}\ncore output:\n${ring.text()}`);
  }

  return {
    label: process.env.JUANCODE_CONFORMANCE_LABEL ?? name,
    wsUrl: `ws://127.0.0.1:${port}/ws`,
    httpBase,
    dataDir,
    owned: true,
    pid: child.pid ?? null,
    log: () => ring.text(),
    death: async () => {
      // A crash report is only ever looked for when the signal says the kernel
      // wrote one, so a death by SIGKILL or a clean exit never reads the
      // developer's crash directory at all.
      const forensics = (exit: ExitRecord | null, reason: string): CoreDeath => ({
        reason,
        code: exit?.code ?? null,
        signal: exit?.signal ?? null,
        log: ring.text(),
        upMs: (exit?.atMs ?? Date.now()) - bootedAtMs,
        crashReport:
          exit?.signal && CRASH_SIGNALS.includes(exit.signal)
            ? findCrashReport(basename(exe), bootedAtMs)
            : null,
      });
      const exit = state.exit;
      if (exit) return forensics(exit, describeExit(exit.code, exit.signal));
      // No exit event yet — ask the socket instead. A core that refuses a
      // connection is gone whether or not node has reaped it.
      const why = await confirmUnreachable(httpBase);
      if (why === null) return null;
      const late = state.exit as ExitRecord | null;
      return forensics(
        late,
        late
          ? describeExit(late.code, late.signal)
          : `the core stopped answering ${httpBase} (${why})`,
      );
    },
    stop: async () => {
      if (!state.exit) stopGroup(child);
      await sleep(300);
      if (process.env.JUANCODE_CONFORMANCE_KEEP !== "1") {
        rmSync(dataDir, { recursive: true, force: true });
        rmSync(oracleDir, { recursive: true, force: true });
      }
    },
  };
}

/** SIGTERM then SIGKILL the core's whole process group (it holds the fake ptys). */
function stopGroup(child: ChildProcess): void {
  const pid = child.pid;
  if (!pid) return;
  try {
    process.kill(-pid, "SIGTERM");
  } catch {
    // Already gone.
  }
  setTimeout(() => {
    try {
      process.kill(-pid, "SIGKILL");
    } catch {
      // Already gone.
    }
  }, 1500);
}
