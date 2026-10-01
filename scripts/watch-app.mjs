#!/usr/bin/env node
// `pnpm dev:app`: rebuild the juancode .app when apps/native changes and relaunch it.
//
// The build is dev-app.sh's own (`--print-bin`), so this bundle is assembled exactly the
// way a `juancode` launch assembles it. It runs with JUANCODE_DAEMON=off, which makes
// dev-app.sh skip `juancoded.sh ensure` entirely: a watch loop relaunches the app many
// times an hour and must never build, start, claim or reap the daemon. The app adopts
// whatever daemon is already running (normally launchd's), so sessions survive every
// relaunch.
//
// The app is run as a direct child of this process, never through `open`, so it
// inherits this terminal's environment untouched (PATH, MCP config, keys). It is only
// ever stopped by the pid this process spawned.
//
// Start it through apps/native/scripts/watch-app.sh, which holds the `kill 0` trap.

import { spawn, spawnSync } from "node:child_process";
import { watch } from "node:fs";
import { get } from "node:http";
import { dirname, join, relative } from "node:path";
import { clearTimeout, setTimeout } from "node:timers";
import { fileURLToPath } from "node:url";
import {
  createRebuildScheduler,
  isSourceChange,
  summarizeBuildErrors,
} from "./lib/rebuild-scheduler.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const NATIVE = join(ROOT, "apps/native");
const DEV_APP = join(NATIVE, "scripts/dev-app.sh");
const DAEMON_SCRIPT = join(NATIVE, "scripts/juancoded.sh");
const DEBOUNCE_MS = Number(process.env.JUANCODE_WATCH_DEBOUNCE_MS ?? 1000);
const QUIT_GRACE_MS = Number(process.env.JUANCODE_WATCH_QUIT_GRACE_MS ?? 10_000);
const DAEMON_PORT = process.env.JUANCODED_PORT ?? "4290";
// Test seams: a stand-in app (the same one dev-app.sh honours) and a stand-in build
// command, so the loop can be exercised without a GUI or a real compile.
const STAND_IN_APP = process.env.JUANCODE_APP_BIN ?? "";
const BUILD_OVERRIDE = process.env.JUANCODE_WATCH_BUILD ?? "";

const log = (msg) => console.log(`[dev:app ${new Date().toTimeString().slice(0, 8)}] ${msg}`);

let app = null;
let build = null;
let shuttingDown = false;

function runBuild() {
  return new Promise((resolve) => {
    const env = { ...process.env, JUANCODE_DAEMON: "off" };
    const child = BUILD_OVERRIDE
      ? spawn("bash", ["-c", BUILD_OVERRIDE], { env, stdio: ["ignore", "pipe", "pipe"] })
      : spawn(DEV_APP, ["--print-bin"], { env, stdio: ["ignore", "pipe", "pipe"] });
    build = child;
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("close", (code, signal) => {
      build = null;
      const bin = stdout.trim().split("\n").filter(Boolean).pop() ?? "";
      resolve({ ok: code === 0 && bin !== "", code, signal, bin, output: `${stderr}\n${stdout}` });
    });
  });
}

function buildId() {
  if (process.env.JUANCODE_BUILD_ID) return process.env.JUANCODE_BUILD_ID;
  // Read-only: hashes the checkout and the daemon binary's mtime, starts nothing.
  const r = spawnSync(DAEMON_SCRIPT, ["build-id"], { encoding: "utf8" });
  return r.status === 0 ? r.stdout.trim() : "";
}

function waitForExit(child, ms) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
  return new Promise((resolve) => {
    const t = setTimeout(() => resolve(false), ms);
    child.once("exit", () => {
      clearTimeout(t);
      resolve(true);
    });
  });
}

async function stopApp() {
  const current = app;
  if (!current) return;
  app = null;
  current.quitting = true;
  log(`quitting app pid ${current.pid}`);
  current.kill("SIGTERM");
  if (!(await waitForExit(current, QUIT_GRACE_MS))) {
    log(`app pid ${current.pid} ignored SIGTERM for ${QUIT_GRACE_MS}ms, sending SIGKILL`);
    current.kill("SIGKILL");
    await waitForExit(current, 2000);
  }
}

function launchApp(bin) {
  const id = buildId();
  const env = id ? { ...process.env, JUANCODE_BUILD_ID: id } : process.env;
  const child = spawn(bin, [], { env, stdio: "inherit" });
  app = child;
  log(`launched ${bin.startsWith(ROOT) ? relative(ROOT, bin) : bin} (pid ${child.pid})`);
  child.on("error", (err) => log(`app failed to start: ${err.message}`));
  child.on("exit", (code, signal) => {
    if (child.quitting || shuttingDown) return;
    if (app === child) app = null;
    log(
      `app exited on its own (${signal ?? `code ${code}`}); the next successful build relaunches it`,
    );
  });
}

async function rebuildAndRelaunch() {
  const started = Date.now();
  log(app ? "change detected, rebuilding (the running app stays up)" : "building");
  const r = await runBuild();
  if (shuttingDown) return;
  const secs = ((Date.now() - started) / 1000).toFixed(1);
  if (!r.ok) {
    log(`build FAILED after ${secs}s${app ? `; app pid ${app.pid} left running` : ""}:`);
    for (const line of summarizeBuildErrors(r.output)) console.log(`  ${line}`);
    log("watching for the next change");
    return;
  }
  log(`build ok in ${secs}s`);
  await stopApp();
  if (shuttingDown) return;
  launchApp(r.bin);
}

function daemonAnswers() {
  return new Promise((resolve) => {
    const req = get(`http://127.0.0.1:${DAEMON_PORT}/health`, { timeout: 1500 }, (res) => {
      res.resume();
      resolve(res.statusCode === 200);
    });
    req.on("timeout", () => req.destroy());
    req.on("error", () => resolve(false));
  });
}

function runningAppPids() {
  // `-a`: a terminal opened inside a juancode session is a child of the app, and pgrep
  // hides its own ancestors by default.
  const r = spawnSync("pgrep", ["-a", "-f", "juancode.app/Contents/MacOS/juancode"], {
    encoding: "utf8",
  });
  return r.stdout.split("\n").filter(Boolean);
}

async function shutdown(code) {
  if (shuttingDown) return;
  shuttingDown = true;
  scheduler.stop();
  for (const w of watchers) w.close();
  if (build) build.kill("SIGTERM");
  await stopApp();
  process.exit(code);
}

const scheduler = createRebuildScheduler({ debounceMs: DEBOUNCE_MS, run: rebuildAndRelaunch });
const watchers = [];

if (!STAND_IN_APP) {
  const others = runningAppPids();
  if (others.length > 0) {
    log(`juancode is already running (pid ${others.join(", ")}).`);
    log("Quit it first (Cmd-Q). This loop only ever stops an app it launched itself,");
    log("and two instances would fight over :4280. Run it from a normal terminal, not");
    log("from a session inside juancode, or quitting the app ends this loop too.");
    process.exit(1);
  }
}

if (!(await daemonAnswers())) {
  log(`no juancoded answering on :${DAEMON_PORT}. This loop never starts one;`);
  log("start it with `pnpm daemon` or the LaunchAgent (apps/native/scripts/juancoded-agent.sh).");
}

process.on("SIGINT", () => void shutdown(130));
process.on("SIGTERM", () => void shutdown(143));
process.on("SIGHUP", () => void shutdown(129));

// fs.watch is FSEvents-backed and recursive on macOS, so no fswatch dependency is needed.
const onChange = (base) => (_event, file) => {
  const rel = file ? join(base, file.toString()) : base;
  if (isSourceChange(rel)) scheduler.notify();
};
watchers.push(watch(join(NATIVE, "Sources"), { recursive: true }, onChange("Sources")));
watchers.push(
  watch(NATIVE, { recursive: false }, (event, file) => {
    if (file?.toString() === "Package.swift") onChange("")(event, file);
  }),
);

log(`watching apps/native/Sources and Package.swift (debounce ${DEBOUNCE_MS}ms); Ctrl-C to stop`);
scheduler.notify();
