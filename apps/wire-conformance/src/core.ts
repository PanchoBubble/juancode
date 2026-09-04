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
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
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
  stop(): Promise<void>;
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

  const exe = await recipe.resolve(skipBuild, buildTimeoutMs);

  // After the build on purpose: a cargo or swift build is minutes long, and a port
  // reserved before it is a port somebody else can take while we compile.
  const port = requested === 0 ? await freePort() : requested;
  const httpBase = `http://127.0.0.1:${port}`;

  const dataDir = mkdtempSync(join(tmpdir(), "juancode-conformance-data-"));
  const oracleDir = mkdtempSync(join(tmpdir(), "juancode-conformance-oracle-"));
  const env = {
    ...process.env,
    ...coreEnv(port, dataDir, oracleDir),
    ...recipe.isolation(port, dataDir),
  };
  const child: ChildProcess = spawn(exe, [], {
    cwd: dataDir,
    env,
    stdio: ["ignore", "pipe", "pipe"],
    // Its own process group, so stopping the core also stops the fake agents it
    // spawned without ever signalling anything else on the machine.
    detached: true,
  });
  const log: string[] = [];
  const record = (d: Buffer) => {
    log.push(d.toString());
    if (log.length > 200) log.shift();
  };
  child.stdout?.on("data", record);
  child.stderr?.on("data", record);
  let exited = false;
  child.on("exit", () => (exited = true));

  try {
    await waitHealthy(httpBase, 60_000, () =>
      exited ? `the core exited before it answered on ${httpBase}` : null,
    );
  } catch (e) {
    stopGroup(child);
    throw new Error(`${e instanceof Error ? e.message : String(e)}\ncore output:\n${log.join("")}`);
  }

  return {
    label: process.env.JUANCODE_CONFORMANCE_LABEL ?? name,
    wsUrl: `ws://127.0.0.1:${port}/ws`,
    httpBase,
    dataDir,
    owned: true,
    stop: async () => {
      if (!exited) stopGroup(child);
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
