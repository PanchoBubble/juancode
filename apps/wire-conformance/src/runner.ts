// The scenario driver: turns a golden transcript into socket traffic and
// assertions. One driver, any core — the only thing that changes between the
// Swift and the Rust core is the URL.

import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { WireClient, readServerInfo, WireProtocolError, type Frame } from "./client.ts";
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

export type Outcome =
  | { status: "passed"; scenarioId: string; ms: number }
  | { status: "skipped"; scenarioId: string; reason: string }
  | { status: "failed"; scenarioId: string; ms: number; error: string };

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

/** Drive one scenario. Throws on the first assertion that fails. */
export async function runScenario(scenario: Scenario, ctx: RunContext): Promise<void> {
  const ignore = scenario.ignore ?? [];
  const clients = new Map<string, WireClient>();
  const vars: Vars = seedVars(ctx.workspace, scenario.id, bumpAttempt(scenario.id));

  const open = async (name: string, keep = false): Promise<WireClient> => {
    const client = await WireClient.connect(ctx.wsUrl, name);
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
    await cleanup(clients);
  }
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
  throw new Error(`unrecognised step: ${JSON.stringify(step)}`);
}

/** Kill every session a scenario created, so the next scenario's connection does
 *  not inherit their activity broadcasts, then close the sockets. */
async function cleanup(clients: Map<string, WireClient>): Promise<void> {
  const sessionIds = new Set<string>();
  for (const client of clients.values()) {
    for (const frame of client.frames) {
      if (frame.type === "created") {
        const session = frame.session as Record<string, unknown> | undefined;
        if (typeof session?.id === "string") sessionIds.add(session.id);
      }
      if (frame.type === "editorReady" && typeof frame.editorId === "string") {
        sessionIds.add(frame.editorId);
      }
      if (frame.type === "terminalReady" && typeof frame.terminalId === "string") {
        sessionIds.add(frame.terminalId);
      }
    }
  }
  // A scenario may have closed one connection deliberately; kill through whichever
  // is still open, or the sessions it created outlive the run.
  const first = [...clients.values()].find((c) => !c.isClosed);
  if (first) {
    for (const id of sessionIds) first.send({ type: "kill", sessionId: id });
    // Give the core a moment to reap the ptys before the socket goes away.
    await sleep(sessionIds.size ? 400 : 0);
  }
  for (const client of clients.values()) client.close();
}
