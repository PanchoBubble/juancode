// The scenario driver: turns a golden transcript into socket traffic and
// assertions. One driver, any core — the only thing that changes between the
// Swift and the Rust core is the URL.

import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  WireClient,
  readServerInfo,
  WireProtocolError,
  type Frame,
  type SessionScope,
} from "./client.ts";
import { matchValue, readBindings, resolveVars, type Vars } from "./match.ts";
import { negotiate, SUITE_REQUIREMENTS } from "./negotiate.ts";
import type { Requirement, Scenario, Step } from "./spec.ts";

/** Per-run scratch space the scenarios address through bound variables. */
export interface Workspace {
  /** A plain directory that exists — the default cwd for `create`. */
  cwd: string;
  /** A git repo with one commit and one uncommitted file, for the settle-edge
   *  change rollup and for the tracked-PR worktree path. */
  gitCwd: string;
  /** A path that does not exist, for the create-guard error. */
  missingCwd: string;
  /** A file inside `cwd`, for openEditor. */
  file: string;
  dispose(): void;
}

export function makeWorkspace(): Workspace {
  const root = mkdtempSync(join(tmpdir(), "juancode-conformance-work-"));
  const cwd = join(root, "plain");
  const gitCwd = join(root, "repo");
  mkdirSync(cwd);
  mkdirSync(gitCwd);
  const file = join(cwd, "note.txt");
  writeFileSync(file, "conformance fixture\n");

  const git = (...args: string[]) =>
    execFileSync("git", args, {
      cwd: gitCwd,
      stdio: "ignore",
      env: {
        ...process.env,
        GIT_AUTHOR_NAME: "conformance",
        GIT_AUTHOR_EMAIL: "conformance@localhost",
        GIT_COMMITTER_NAME: "conformance",
        GIT_COMMITTER_EMAIL: "conformance@localhost",
      },
    });
  git("init", "--quiet", "--initial-branch=main");
  writeFileSync(join(gitCwd, "committed.txt"), "base\n");
  git("add", "committed.txt");
  git("commit", "--quiet", "-m", "base");
  // Leave the tree dirty: the settle edge only carries a `changes` rollup when
  // there is something to report.
  writeFileSync(join(gitCwd, "committed.txt"), "base\nchanged\n");

  return {
    cwd,
    gitCwd,
    missingCwd: join(root, "definitely-not-here"),
    file,
    dispose: () => rmSync(root, { recursive: true, force: true }),
  };
}

/** A token unique to this suite process.
 *
 * Ids a scenario claims inside a core outlive the scenario: the core persists a
 * dispatch id so a second create for it is rejected, and remembers an adopted CLI
 * id so adopting it again is a no-op. Both are the features scenario 17 and 16
 * exist to prove, so an id reused by a later run measures the dedup instead of
 * the scenario. Stamping the process makes a second run against the same daemon
 * a fresh claim.
 *
 * Overridable so a repeatability measurement can pin it: forcing two runs to share
 * a token is how you demonstrate that it is the token doing the work. */
const RUN_TOKEN =
  process.env.JUANCODE_CONFORMANCE_RUN_TOKEN ??
  `${Date.now().toString(36)}-${process.pid.toString(36)}`;

/** How many times each scenario has been run in this process. */
const attempts = new Map<string, number>();

/** The 1-based attempt number for the next run of this scenario.
 *
 * Per attempt rather than per process, because one boot has to be able to run the
 * same scenario more than once: a repeat pass over the whole spec inside a single
 * core is the point of measuring repeatability at all. */
export function bumpAttempt(scenarioId: string): number {
  const next = (attempts.get(scenarioId) ?? 0) + 1;
  attempts.set(scenarioId, next);
  return next;
}

/** Everything a scenario's steps can reference before its first `bind`.
 *
 * One place, so `spec.test.ts` can check that no transcript references a variable
 * nothing seeds without keeping its own copy of the list. */
export function seedVars(
  workspace: Omit<Workspace, "dispose">,
  scenarioId: string,
  attempt: number,
): Vars {
  // Recognisable on purpose: a human reading a session list or a dispatch log
  // should still be able to tell what made these.
  const stamp = `${RUN_TOKEN}-${attempt}`;
  return {
    cwd: workspace.cwd,
    gitCwd: workspace.gitCwd,
    missingCwd: workspace.missingCwd,
    file: workspace.file,
    dispatchId: `conformance-${scenarioId}-${stamp}`,
    requestId: `req-${scenarioId}-${stamp}`,
    cliSessionId: `conformance-adopted-${scenarioId}-${stamp}`,
    // Where the fake agent's `SPAWN` records its helper's pid. Fixed per workspace
    // rather than stamped like the ids above, because the AGENT has to write it
    // knowing only its own cwd: an `input` frame carries one literal string, and
    // `resolveVars` substitutes a whole value, never inside one, so a stamped path
    // could not be spelled into the command. `SPAWN` unlinks before it forks and
    // the probe re-reads on every poll, so a file left by an earlier attempt costs
    // that attempt a few milliseconds, not a verdict.
    orphanPid: join(workspace.cwd, "orphan.pid"),
    // The preset `seedPresets` wrote, and a name it deliberately did not: a core has to
    // error on a name it cannot resolve rather than spawn without it. Fixed rather than
    // stamped, because the file is written at boot and every attempt reads the same one.
    presetName: "conformance",
    presetMarker: "PRESET-MARKER-conformance",
    missingPresetName: "conformance-missing",
  };
}

export interface RunContext {
  wsUrl: string;
  workspace: Workspace;
  /** Capabilities the core advertised, for gating. */
  capabilities: string[];
  /** Environment facts, for `requires` gating. */
  available: Requirement[];
}

/** What one scenario did in one core boot.
 *
 *  `attempts` and `passes` are on the verdict rather than beside it because a
 *  score reported off a single run has twice turned out not to be repeatable
 *  (juancode-g2kl, juancode-p5vb): a report that cannot say HOW MANY times a
 *  scenario was measured cannot be read as a gate. A single measurement is still
 *  honest, it just reads as 1/1. */
export type Outcome =
  | { status: "passed"; scenarioId: string; ms: number; attempts: number; passes: number }
  | { status: "skipped"; scenarioId: string; reason: string }
  | {
      status: "failed";
      scenarioId: string;
      ms: number;
      attempts: number;
      passes: number;
      error: string;
    };

/** Why a scenario cannot run against this core / in this environment, or null. */
export function skipReason(scenario: Scenario, ctx: RunContext): string | null {
  for (const cap of scenario.capabilities ?? []) {
    if (!ctx.capabilities.includes(cap)) {
      return `core does not advertise the "${cap}" capability`;
    }
  }
  for (const req of scenario.requires ?? []) {
    if (!ctx.available.includes(req)) return `environment has no ${req}`;
  }
  if (scenario.skipInCI && process.env.CI) return scenario.skipInCI;
  return null;
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/** Variable a connection's own `serverInfo.clientId` is bound under: `a` → `$clientA`. */
export function clientVar(name: string): string {
  return `client${name.charAt(0).toUpperCase()}${name.slice(1)}`;
}

/** Which scenario attempt claimed each session id, for the whole suite process.
 *
 *  Module-level because that is the scope of the problem: the frames a scenario
 *  has to ignore are the ones about sessions an EARLIER scenario created, and no
 *  single scenario can know those ids. */
const sessionOwners = new Map<string, string>();

/** The session ids a frame announces as belonging to whoever asked for them.
 *
 *  Replies only. `created` answers a `create` or an `adoptExternal`, `editorReady`
 *  and `terminalReady` answer an `openEditor` / `openTerminal`. An `activity`
 *  broadcast is deliberately NOT an announcement: a connection receives those for
 *  every session in the core, so claiming from one would adopt exactly the frames
 *  this scoping exists to filter out. */
export function announcedSessionIds(frame: Frame): string[] {
  const ids: string[] = [];
  if (frame.type === "created") {
    const session = frame.session as Record<string, unknown> | undefined;
    if (typeof session?.id === "string") ids.push(session.id);
  }
  if (frame.type === "editorReady" && typeof frame.editorId === "string") ids.push(frame.editorId);
  if (frame.type === "terminalReady" && typeof frame.terminalId === "string") {
    ids.push(frame.terminalId);
  }
  return ids;
}

/** The session a frame is about, or undefined for one that names none (`serverInfo`,
 *  a `trackedPrs` list, an `error` with no session). A frame naming no session is
 *  never foreign: there is nothing to attribute it to. */
export function frameSessionId(frame: Frame): string | undefined {
  for (const key of ["sessionId", "editorId", "terminalId"]) {
    const value = frame[key];
    if (typeof value === "string") return value;
  }
  const session = frame.session as Record<string, unknown> | undefined;
  return typeof session?.id === "string" ? session.id : undefined;
}

/** The ownership filter for one attempt at one scenario.
 *
 *  Foreign means KNOWN to belong to another attempt, never merely unrecognised: a
 *  session's own `activity` can beat its `created` reply (see the note in
 *  17-dispatch-correlation), so treating unknown ids as foreign would silently
 *  drop frames a step is waiting for and turn this fix into a timeout. */
export function makeSessionScope(runKey: string): SessionScope & { owned: Set<string> } {
  const owned = new Set<string>();
  return {
    owned,
    claim(frame: Frame) {
      for (const id of announcedSessionIds(frame)) {
        owned.add(id);
        sessionOwners.set(id, runKey);
      }
    },
    isForeign(frame: Frame) {
      const id = frameSessionId(frame);
      if (id === undefined || owned.has(id)) return false;
      const owner = sessionOwners.get(id);
      return owner !== undefined && owner !== runKey;
    },
  };
}

/** Drive one scenario. Throws on the first assertion that fails. */
export async function runScenario(scenario: Scenario, ctx: RunContext): Promise<void> {
  const ignore = scenario.ignore ?? [];
  const clients = new Map<string, WireClient>();
  const attempt = bumpAttempt(scenario.id);
  const vars: Vars = seedVars(ctx.workspace, scenario.id, attempt);
  const scope = makeSessionScope(`${scenario.id}#${attempt}`);

  const open = async (name: string, keep = false): Promise<WireClient> => {
    const client = await WireClient.connect(ctx.wsUrl, name, { scope });
    clients.set(name, client);
    // Every connection starts with the handshake; consume it here so scenarios
    // only spell it out when the handshake itself is what they assert.
    const info = readServerInfo((await client.handshake()).frame);
    const verdict = negotiate(info, SUITE_REQUIREMENTS);
    if (!verdict.ok) throw new WireProtocolError(`connection ${name}: ${verdict.reason}`);
    // The connection's own grid-ownership token, as `$clientA` / `$clientB`, so a
    // transcript can assert WHICH client owns a grid rather than only that someone
    // does. The core mints it, so there is no other way for a scenario to know it.
    if (info.clientId !== undefined) vars[clientVar(name)] = info.clientId;
    // Past the handshake (and past the activity broadcasts a connection gets for
    // sessions that already existed): the transcript starts from here. A scenario
    // that asserts what a connection is told on arrival keeps them instead.
    if (!keep) client.drain();
    return client;
  };

  const clientFor = (name = "a"): WireClient => {
    const c = clients.get(name);
    if (!c) throw new Error(`scenario ${scenario.id} used connection "${name}" before opening it`);
    return c;
  };

  try {
    await open("a");
    for (const [index, step] of scenario.steps.entries()) {
      try {
        await runStep(step, { scenario, ctx, vars, ignore, clientFor, open });
      } catch (e) {
        const label = "note" in step && step.note ? ` (${step.note})` : "";
        const detail = e instanceof Error ? e.message : String(e);
        throw new Error(`step ${index + 1}${label}: ${detail}`);
      }
    }
  } finally {
    await cleanup(clients, scope.owned);
  }
}

/** How many times each scenario runs inside ONE core boot.
 *
 *  Repeating inside one boot rather than as N whole CI jobs is deliberate: the
 *  build plus boot dominates the wall clock, and a fresh boot per run hides the
 *  sequence-of-scenarios ordering that late frames from a previous scenario come
 *  out of. So N attempts cost N times the transcripts and nothing else. */
export function repeatCount(env: NodeJS.ProcessEnv = process.env): number {
  const raw = env.JUANCODE_CONFORMANCE_REPEAT;
  if (raw === undefined || raw.trim() === "") return 1;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1) {
    throw new Error(
      `JUANCODE_CONFORMANCE_REPEAT must be a positive integer, got ${JSON.stringify(raw)}`,
    );
  }
  return n;
}

/** Run one scenario `repeat` times and report a single verdict.
 *
 *  All N attempts have to pass. Stops at the first failure, because the verdict is
 *  already decided and a scenario that fails once is not a scenario whose remaining
 *  attempts are interesting. `attempts` is therefore what the gate ASKED for rather
 *  than how many ran, so a ratio reads against the bar it had to clear; the error
 *  message names the attempt that stopped it. */
export async function runScenarioRepeatedly(
  scenario: Scenario,
  ctx: RunContext,
  repeat: number,
): Promise<Outcome> {
  const started = Date.now();
  let passes = 0;
  for (let attempt = 1; attempt <= repeat; attempt++) {
    try {
      await runScenario(scenario, ctx);
      passes += 1;
    } catch (e) {
      const detail = e instanceof Error ? e.message : String(e);
      return {
        status: "failed",
        scenarioId: scenario.id,
        ms: Date.now() - started,
        attempts: repeat,
        passes,
        error: repeat > 1 ? `attempt ${attempt} of ${repeat}: ${detail}` : detail,
      };
    }
  }
  return {
    status: "passed",
    scenarioId: scenario.id,
    ms: Date.now() - started,
    attempts: repeat,
    passes,
  };
}

interface StepContext {
  scenario: Scenario;
  ctx: RunContext;
  vars: Vars;
  ignore: string[];
  clientFor: (name?: string) => WireClient;
  open: (name: string, keep?: boolean) => Promise<WireClient>;
}

async function runStep(step: Step, s: StepContext): Promise<void> {
  if ("open" in step) {
    await s.open(step.open, step.keep === true);
    return;
  }
  if ("close" in step) {
    s.clientFor(step.close).close();
    return;
  }
  if ("sleep" in step) {
    await sleep(step.sleep);
    return;
  }
  if ("send" in step) {
    s.clientFor(step.on).send(resolveVars(step.send, s.vars) as Frame);
    return;
  }
  if ("raw" in step) {
    s.clientFor(step.on).sendRaw(step.raw);
    return;
  }
  if ("expectHandshake" in step) {
    const { frame } = await s.clientFor(step.on).handshake();
    const matcher = resolveVars(step.expectHandshake, s.vars) as Frame;
    const result = matchValue(frame, matcher, s.vars);
    if (!result.ok) {
      throw new WireProtocolError(
        `handshake did not match: ${result.why}\n  got: ${JSON.stringify(frame)}`,
      );
    }
    return;
  }
  if ("expectFirstFrame" in step) {
    const client = s.clientFor(step.on);
    const frame = client.frameAt(0);
    const matcher = resolveVars(step.expectFirstFrame, s.vars) as Frame;
    const result = matchValue(frame, matcher, s.vars);
    if (!result.ok) {
      throw new WireProtocolError(
        `first frame did not match: ${result.why}\n  got: ${JSON.stringify(frame)}`,
      );
    }
    return;
  }
  if ("expectNone" in step) {
    await s.clientFor(step.on).expectNone(resolveVars(step.expectNone, s.vars) as Frame, {
      vars: s.vars,
      withinMs: step.withinMs,
    });
    return;
  }
  if ("expect" in step) {
    const frame = await s.clientFor(step.on).waitFor(resolveVars(step.expect, s.vars) as Frame, {
      vars: s.vars,
      timeoutMs: step.timeoutMs,
      ignore: step.ignore ?? s.ignore,
    });
    if (step.bind) {
      Object.assign(s.vars, readBindings(frame, step.bind));
    }
    return;
  }
  if ("descendant" in step) {
    await probeDescendant(
      step.descendant,
      resolveVars(step.pidFile, s.vars) as string,
      step.withinMs,
    );
    return;
  }
  throw new Error(`unrecognised step: ${JSON.stringify(step)}`);
}

/** The pid the fake agent's helper recorded, or null while the file is absent or
 *  not yet a number. Re-read on every poll: `SPAWN` unlinks and rewrites, so a
 *  stale file resolves itself within milliseconds. */
function readHelperPid(pidFile: string): number | null {
  try {
    const pid = Number(readFileSync(pidFile, "utf8").trim());
    // > 1 rejects both an empty parse (NaN) and pid 1, which is never ours and
    // whose liveness would make every `alive` probe pass.
    return Number.isInteger(pid) && pid > 1 ? pid : null;
  } catch {
    return null;
  }
}

/** Signal 0 asks the kernel whether a pid exists without touching it. EPERM means
 *  it exists and is someone else's, which for this probe is still alive. */
function pidRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "EPERM";
  }
}

/** Assert a session's spawned helper is running, or gone.
 *
 *  Not a wire assertion: reaping a process group leaves no frame behind, so this
 *  reads the pid the fixture recorded. `alive` is the control — it has to pass
 *  before `reaped` means anything, and `reaped` refuses to run without a pid for
 *  exactly that reason, so a `SPAWN` that silently did nothing fails the scenario
 *  instead of quietly satisfying it. */
async function probeDescendant(
  want: "alive" | "reaped",
  pidFile: string,
  withinMs = 8000,
): Promise<void> {
  const deadline = Date.now() + withinMs;

  if (want === "reaped") {
    const pid = readHelperPid(pidFile);
    if (pid === null) {
      throw new Error(
        `nothing to reap: no helper pid in ${pidFile}. A "descendant: alive" step has to ` +
          `pass first, or this step would report a pass for a helper that never started.`,
      );
    }
    while (Date.now() < deadline) {
      if (!pidRunning(pid)) return;
      await sleep(100);
    }
    throw new Error(
      `helper ${pid} survived the session by ${withinMs}ms. Killing a session has to reap ` +
        `the whole process group: this helper ignores HUP and TERM, so only an escalation ` +
        `to killpg(SIGKILL) reaches it, and nothing did.`,
    );
  }

  while (Date.now() < deadline) {
    const pid = readHelperPid(pidFile);
    if (pid !== null && pidRunning(pid)) return;
    await sleep(100);
  }
  throw new Error(
    `no live helper pid in ${pidFile} after ${withinMs}ms — the fake agent's SPAWN did not ` +
      `leave one running, so the reap assertion that follows would be vacuous.`,
  );
}

/** Kill every session a scenario created and WAIT for the core to say they are
 *  gone, so the next scenario's connection does not inherit their broadcasts.
 *
 *  The waiting is the point. This used to sleep a flat 400ms, which is a guess
 *  rather than a barrier: when the core took longer than that to reap a pty, the
 *  `exit` landed on whichever connection was open next — the next scenario's,
 *  mid-assertion (juancode-a3ck). A missed `exit` is no longer a failure either,
 *  because a frame about a retired session now reads as foreign, so the deadline
 *  here only bounds how long the suite is willing to be tidy. */
async function cleanup(
  clients: Map<string, WireClient>,
  sessionIds: Set<string>,
  timeoutMs = 4_000,
): Promise<void> {
  // A scenario may have closed one connection deliberately; kill through whichever
  // is still open, or the sessions it created outlive the run.
  const first = [...clients.values()].find((c) => !c.isClosed);
  if (first && sessionIds.size) {
    for (const id of sessionIds) first.send({ type: "kill", sessionId: id });
    await waitForExits(clients, sessionIds, timeoutMs);
  }
  for (const client of clients.values()) client.close();
}

/** Block until every id has an `exit` on some connection, or the deadline. Reads
 *  the whole recorded stream rather than the cursor: a scenario that asserted its
 *  own `exit` has already consumed it, and that still counts as reaped. */
async function waitForExits(
  clients: Map<string, WireClient>,
  sessionIds: Set<string>,
  timeoutMs: number,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  const exited = (): boolean => {
    const seen = new Set<string>();
    for (const client of clients.values()) {
      for (const frame of client.frames) {
        if (frame.type === "exit" && typeof frame.sessionId === "string") seen.add(frame.sessionId);
      }
    }
    return [...sessionIds].every((id) => seen.has(id));
  };
  while (!exited()) {
    if (Date.now() >= deadline) return;
    if ([...clients.values()].every((c) => c.isClosed)) return;
    await sleep(20);
  }
}
