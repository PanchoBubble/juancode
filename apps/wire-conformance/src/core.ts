// Booting a core under test.
//
// Two modes:
//   * JUANCODE_CONFORMANCE_URL points at an already-running core (this is how the
//     Rust core gets measured, and how you drive a core in a container).
//   * otherwise the Swift core's headless runner (`juancode-serve`) is built and
//     booted here.
//
// Isolation is the hard requirement: a developer's live app owns :4280 and the
// sidecar owns :4281, and driving THAT app would create, resize and kill their
// real sessions. So the boot pins its own port, its own sqlite dir, its own
// oracle control dir, and fake provider binaries.

import { spawn, type ChildProcess } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = join(here, "..");
const REPO_ROOT = join(PKG_ROOT, "..", "..");
const NATIVE_ROOT = join(REPO_ROOT, "apps", "native");

export const FIXTURES = join(PKG_ROOT, "fixtures");

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

async function waitHealthy(httpBase: string, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let lastError = "never probed";
  while (Date.now() < deadline) {
    // The Swift core serves /api/health; the Rust core serves /health. Probing
    // both keeps the harness core-agnostic (the divergence itself is a parity item).
    for (const path of ["/api/health", "/health"]) {
      try {
        const res = await fetch(`${httpBase}${path}`);
        if (res.ok) return;
        lastError = `HTTP ${res.status} on ${path}`;
      } catch (e) {
        lastError = e instanceof Error ? e.message : String(e);
      }
    }
    await sleep(200);
  }
  throw new Error(`core at ${httpBase} never became healthy (${lastError})`);
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
    // Fixed scrollback so replay assertions do not depend on a user's setting.
    JUANCODE_SCROLLBACK: String(64 * 1024),
    // No retention pruning and no reaping: a scenario's session must still exist
    // when the next step addresses it.
    JUANCODE_SESSIONS_PER_PROJECT: "0",
    JUANCODE_MAX_LIVE_SESSIONS: "0",
    JUANCODE_REAP_IDLE_MINUTES: "0",
  };
}

export interface StartOptions {
  /** Port for a core we boot ourselves. Never 4280/4281 (a dev machine's app/sidecar). */
  port?: number;
  /** Skip `swift build` (the binary is already built, e.g. a previous CI step). */
  skipBuild?: boolean;
  buildTimeoutMs?: number;
}

/** Attach to a running core, or build and boot the Swift one. */
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

  const port = opts.port ?? Number(process.env.JUANCODE_CONFORMANCE_PORT ?? 4295);
  if (port === 4280 || port === 4281) {
    throw new Error(`refusing to drive port ${port}: that is a developer's live app / sidecar`);
  }
  const skipBuild = opts.skipBuild ?? process.env.JUANCODE_CONFORMANCE_SKIP_BUILD === "1";
  const buildTimeoutMs = opts.buildTimeoutMs ?? 20 * 60_000;

  if (!skipBuild) {
    // A sibling `swift build` holds the same package lock, so this can block for
    // minutes before it even starts compiling. That is normal, not a hang.
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
  const exe = join(binPath.split("\n").pop() ?? binPath, "juancode-serve");

  const dataDir = mkdtempSync(join(tmpdir(), "juancode-conformance-data-"));
  const oracleDir = mkdtempSync(join(tmpdir(), "juancode-conformance-oracle-"));
  const env = { ...process.env, ...coreEnv(port, dataDir, oracleDir) };
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

  const httpBase = `http://127.0.0.1:${port}`;
  try {
    await waitHealthy(httpBase, 60_000);
  } catch (e) {
    stopGroup(child);
    throw new Error(`${e instanceof Error ? e.message : String(e)}\ncore output:\n${log.join("")}`);
  }

  return {
    label: process.env.JUANCODE_CONFORMANCE_LABEL ?? "swift",
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
