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
import { HEAVY_PIDS, type CoreDeath } from "./core.ts";
import type { Requirement, Scenario, Step } from "./spec.ts";

/** Per-run scratch space the scenarios address through bound variables. */
export interface Workspace {
  /** A plain directory that exists — the default cwd for `create`. */
  cwd: string;
  /** A git repo with one commit and one uncommitted file, for the settle-edge
   *  change rollup and for the tracked-PR worktree path. */
  gitCwd: string;
  /** A SECOND git repo, with a local bare remote already wired up as `origin` and
   *  a 40-line file committed, for the working-tree scenario (juancode-52e8.14.5).
   *
   *  Its own repo rather than a remote bolted onto `gitCwd`: a commit and a push are
   *  writes, and running them against the tree that scenario 30 branches worktrees off
   *  would make an isolation test depend on what a changes test left behind. The bare
   *  remote is local, so the push is a file copy and the suite needs no network. */
  gitRemoteCwd: string;
  /** A checkout `fake-gh.sh` answers for: a plain directory carrying a
   *  `.gh-fixtures/` of recorded gh output. The stub keys off the cwd rather than off
   *  a variable so both of its behaviours are live in one core boot - 14-tracked-prs
   *  needs a `gh` that fails, 45-github needs one that answers. */
  ghCwd: string;
  /** A path that does not exist, for the create-guard error. */
  missingCwd: string;
  /** A file inside `cwd`, for openEditor. */
  file: string;
  dispose(): void;
}

/** Write the fixture's git identity into the repo's own config.
 *
 *  In the repo's config and not this process's environment, because the commits that
 *  matter are not made by this process: `changes` asks the CORE to commit, in a linked
 *  worktree, out of a process this file never touches. A repo whose identity lived only
 *  in the fixture's env commits fine here and answers `Author identity unknown` on any
 *  machine without an ambient global `user.email` — which is every CI runner, and is why
 *  main was red from 2026-09-18. Local config is kept in the common dir, so every linked
 *  worktree of this repo resolves it too.
 */
function seedIdentity(git: (...args: string[]) => unknown): void {
  git("config", "user.name", "conformance");
  git("config", "user.email", "conformance@localhost");
}

export function makeWorkspace(): Workspace {
  const root = mkdtempSync(join(tmpdir(), "juancode-conformance-work-"));
  const cwd = join(root, "plain");
  const gitCwd = join(root, "repo");
  mkdirSync(cwd);
  mkdirSync(gitCwd);
  const file = join(cwd, "note.txt");
  writeFileSync(file, "conformance fixture\n");

  const git = (...args: string[]) => execFileSync("git", args, { cwd: gitCwd, stdio: "ignore" });
  git("init", "--quiet", "--initial-branch=main");
  seedIdentity(git);
  writeFileSync(join(gitCwd, "committed.txt"), "base\n");
  git("add", "committed.txt");
  git("commit", "--quiet", "-m", "base");
  // Leave the tree dirty: the settle edge only carries a `changes` rollup when
  // there is something to report.
  writeFileSync(join(gitCwd, "committed.txt"), "base\nchanged\n");

  // The changes fixture: its own repo, its own bare remote, and a file wide enough
  // that two edits far apart produce two hunks rather than one — which is what a
  // per-hunk discard has to be measured against.
  const gitRemoteCwd = join(root, "remote-repo");
  const bare = join(root, "origin.git");
  mkdirSync(gitRemoteCwd);
  const gitRemote = (...args: string[]) =>
    execFileSync("git", args, { cwd: gitRemoteCwd, stdio: "ignore" });
  execFileSync("git", ["init", "--quiet", "--bare", bare], { stdio: "ignore" });
  gitRemote("init", "--quiet", "--initial-branch=main");
  seedIdentity(gitRemote);
  writeFileSync(
    join(gitRemoteCwd, "wide.txt"),
    Array.from({ length: 40 }, (_, i) => `line ${i + 1}`).join("\n") + "\n",
  );
  gitRemote("add", "wide.txt");
  gitRemote("commit", "--quiet", "-m", "base");
  gitRemote("remote", "add", "origin", bare);
  gitRemote("push", "--quiet", "-u", "origin", "main");

  return {
    cwd,
    gitCwd,
    gitRemoteCwd,
    ghCwd: seedGhFixtures(join(root, "gh-repo")),
    missingCwd: join(root, "definitely-not-here"),
    file,
    dispose: () => rmSync(root, { recursive: true, force: true }),
  };
}

/** The recorded `gh` output 45-github reads, in the directory `fake-gh.sh` answers
 *  for.
 *
 *  Recorded shapes, not invented ones: every field here is one the parsers in
 *  `juancoded_core::gh` / `gh_convo` / `actions_log` actually read, spelled the way gh
 *  spells it. Three of them carry a deliberate awkwardness, because a fixture that is
 *  only the happy path tests nothing:
 *
 *   * PR #7 is somebody else's with the viewer's review requested, and #42 is the
 *     viewer's own with red CI — so the triage answer has to order two different
 *     reasons rather than repeat one.
 *   * The conversation carries a bare COMMENTED review that is only the record of an
 *     inline reply, which the timeline has to drop.
 *   * The Actions log carries seven fractional digits, an unterminated `##[group]` and
 *     an ANSI-coloured line, all of which the real thing does. */
function seedGhFixtures(dir: string): string {
  const fixtures = join(dir, ".gh-fixtures");
  mkdirSync(fixtures, { recursive: true });
  const write = (name: string, body: unknown) =>
    writeFileSync(
      join(fixtures, name),
      typeof body === "string" ? body : `${JSON.stringify(body, null, 2)}\n`,
      "utf8",
    );
  const url = (n: number) => `https://github.com/conformance/repo/pull/${n}`;
  const inline = (id: string, databaseId: number, login: string, body: string, at: string) => ({
    id,
    databaseId,
    author: { login },
    body,
    createdAt: at,
    url: `${url(42)}#discussion_r${databaseId}`,
    path: "Sources/App/Login.swift",
    line: 42,
    ...(id === "RC_1" ? { diffHunk: "@@ -38,6 +38,7 @@ func load() {" } : {}),
  });

  write("viewer.txt", "octocat\n");
  write("repo-nwo.txt", "conformance/repo\n");
  write("pr-list.json", [
    {
      number: 42,
      title: "Fix the login redirect",
      url: url(42),
      headRefName: "octocat/fix-login",
      isDraft: false,
      statusCheckRollup: [
        { status: "COMPLETED", conclusion: "SUCCESS" },
        { status: "COMPLETED", conclusion: "FAILURE" },
      ],
      author: { login: "octocat" },
      assignees: [{ login: "octocat" }],
      createdAt: "2026-09-01T09:00:00Z",
      reviewDecision: "REVIEW_REQUIRED",
      reviewRequests: [{ login: "hubber" }],
      additions: 120,
      deletions: 9,
      changedFiles: 4,
    },
    {
      number: 7,
      title: "Bump the flake",
      url: url(7),
      headRefName: "hubber/bump",
      isDraft: false,
      statusCheckRollup: [{ status: "COMPLETED", conclusion: "SUCCESS" }],
      author: { login: "hubber" },
      assignees: [],
      createdAt: "2026-08-20T09:00:00Z",
      reviewRequests: [{ login: "octocat" }, { slug: "platform" }],
      additions: 2,
      deletions: 2,
      changedFiles: 1,
    },
  ]);
  write("pr-for-branch.json", [
    {
      number: 42,
      title: "Fix the login redirect",
      url: url(42),
      headRefName: "octocat/fix-login",
      isDraft: false,
      statusCheckRollup: [],
      author: { login: "octocat" },
    },
  ]);
  // The half of a folder's PRs the page cap hides. Only #7 comes back, so a scenario
  // can tell a search that reached past the cap from a second copy of the list.
  write("pr-search.json", [
    {
      number: 7,
      title: "Bump the flake",
      url: url(7),
      headRefName: "hubber/bump",
      isDraft: false,
      statusCheckRollup: [{ status: "COMPLETED", conclusion: "SUCCESS" }],
      author: { login: "hubber" },
      assignees: [],
      createdAt: "2026-08-20T09:00:00Z",
      reviewRequests: [{ login: "octocat" }],
      additions: 2,
      deletions: 2,
      changedFiles: 1,
    },
  ]);
  // A PR's net diff, as `gh pr diff` prints it: one combined patch, not the mailbox
  // series `--patch` emits. A rename is one entry with `-M`, which is why the parser
  // has to read `rename from`/`rename to` rather than a delete and an add.
  write(
    "pr-diff.patch",
    [
      "diff --git a/Sources/App/Login.swift b/Sources/App/Login.swift",
      "index 1111111..2222222 100644",
      "--- a/Sources/App/Login.swift",
      "+++ b/Sources/App/Login.swift",
      "@@ -38,6 +38,7 @@ func load() {",
      "   let session = store.current",
      "+  guard session.isValid else { return }",
      "   return session",
      "diff --git a/README.md b/docs/README.md",
      "similarity index 96%",
      "rename from README.md",
      "rename to docs/README.md",
      "",
    ].join("\n"),
  );
  // What gh prints when it opens a PR: the url on stdout and nothing else.
  write("pr-create.txt", `${url(99)}\n`);
  write("pr-comment.txt", `${url(42)}#issuecomment-999\n`);
  write("run-rerun.txt", "\u2713 Requested rerun of run 901\n");
  // The viewer's cross-repo queue: one authored PR with red CI and one somebody else
  // wrote that asked for the viewer's review, so the two buckets and the two attention
  // reasons are both exercised by one fetch.
  const viewerNode = (
    n: number,
    repo: string,
    author: string,
    rollup: Array<Record<string, string>>,
  ) => ({
    number: n,
    title: `PR ${n}`,
    url: `https://github.com/${repo}/pull/${n}`,
    isDraft: false,
    createdAt: "2026-09-01T09:00:00Z",
    headRefName: `${author}/work`,
    additions: 10,
    deletions: 1,
    changedFiles: 2,
    repository: { nameWithOwner: repo },
    author: { login: author },
    assignees: { nodes: [] },
    reviewDecision: null,
    reviewRequests: { nodes: [{ requestedReviewer: { login: "octocat" } }] },
    reviewThreads: { nodes: [{ isResolved: false }, { isResolved: true }] },
    rollup: {
      nodes: [{ commit: { statusCheckRollup: { contexts: { nodes: rollup } } } }],
    },
  });
  write("viewer-prs.json", {
    data: {
      mine: {
        nodes: [
          viewerNode(42, "conformance/repo", "octocat", [
            { status: "COMPLETED", conclusion: "SUCCESS" },
            { status: "COMPLETED", conclusion: "FAILURE" },
          ]),
        ],
      },
      reviews: {
        nodes: [
          viewerNode(31, "conformance/other", "hubber", [
            { status: "COMPLETED", conclusion: "SUCCESS" },
          ]),
        ],
      },
    },
  });
  write("thread-counts.json", {
    data: {
      repository: {
        pullRequests: {
          nodes: [
            { number: 42, reviewThreads: { nodes: [{ isResolved: false }, { isResolved: true }] } },
            { number: 7, reviewThreads: { nodes: [] } },
          ],
        },
      },
    },
  });
  write("pr-activity.json", {
    state: "OPEN",
    author: { login: "octocat" },
    statusCheckRollup: [{ status: "COMPLETED", conclusion: "FAILURE" }],
    comments: [],
    reviews: [],
  });
  write("pr-checks.json", [
    {
      name: "build",
      state: "SUCCESS",
      bucket: "pass",
      link: "https://github.com/conformance/repo/actions/runs/900/job/1",
    },
    {
      name: "test",
      state: "FAILURE",
      bucket: "fail",
      link: "https://github.com/conformance/repo/actions/runs/901/job/2",
    },
  ]);
  write("conversation.json", {
    data: {
      repository: {
        pullRequest: {
          state: "OPEN",
          body: "Fixes the redirect loop.",
          comments: {
            nodes: [
              {
                id: "IC_1",
                databaseId: 111,
                author: { login: "hubber", avatarUrl: "https://avatars.invalid/hubber.png" },
                body: "Looks good overall",
                createdAt: "2026-09-01T12:00:00Z",
                url: `${url(42)}#issuecomment-111`,
                reactionGroups: [
                  { content: "THUMBS_UP", reactors: { totalCount: 2 } },
                  { content: "CONFUSED", reactors: { totalCount: 0 } },
                ],
              },
            ],
          },
          reviews: {
            nodes: [
              {
                id: "PRR_1",
                author: { login: "hubber" },
                state: "CHANGES_REQUESTED",
                body: "Needs a test",
                createdAt: "2026-09-01T13:00:00Z",
                url: `${url(42)}#pullrequestreview-1`,
                comments: {
                  nodes: [
                    inline("RC_1", 222, "hubber", "This can crash on nil", "2026-09-01T13:01:00Z"),
                  ],
                },
              },
              {
                id: "PRR_2",
                author: { login: "octocat" },
                state: "COMMENTED",
                body: "",
                createdAt: "2026-09-01T13:05:00Z",
                url: `${url(42)}#pullrequestreview-2`,
                comments: {
                  nodes: [inline("RC_2", 333, "octocat", "Fixed", "2026-09-01T13:05:00Z")],
                },
              },
            ],
          },
          reviewThreads: {
            nodes: [
              {
                id: "RT_1",
                isResolved: false,
                isOutdated: false,
                path: "Sources/App/Login.swift",
                line: 42,
                comments: {
                  nodes: [
                    inline("RC_1", 222, "hubber", "This can crash on nil", "2026-09-01T13:01:00Z"),
                    inline("RC_2", 333, "octocat", "Fixed", "2026-09-01T13:05:00Z"),
                  ],
                },
              },
            ],
          },
          commits: {
            nodes: [
              {
                commit: {
                  oid: "abc123def4567890",
                  abbreviatedOid: "abc123d",
                  messageHeadline: "fix the redirect",
                  committedDate: "2026-09-01T11:00:00Z",
                  authors: { nodes: [{ name: "Octo Cat", user: { login: "octocat" } }] },
                },
              },
            ],
          },
        },
      },
    },
  });
  const esc = "";
  write(
    "run-log.txt",
    [
      "build\tRun tests\t2026-09-01T09:41:02.1234567Z ##[group]Run pnpm test",
      "build\tRun tests\t2026-09-01T09:41:02.2000000Z pnpm test",
      "build\tRun tests\t2026-09-01T09:41:02.3000000Z ##[endgroup]",
      "build\tRun tests\t2026-09-01T09:41:09.0000000Z FAIL src/login.spec.ts",
      "build\tRun tests\t2026-09-01T09:41:09.5000000Z ##[error]Process completed with exit code 1.",
      "build\tLint\t2026-09-01T09:42:00.0000000Z ##[group]Never closed",
      `build\tLint\t2026-09-01T09:42:01.0000000Z ${esc}[1;31mwarning${esc}[0m: 2 warnings`,
      "",
    ].join("\n"),
  );
  return dir;
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
    gitRemoteCwd: workspace.gitRemoteCwd,
    ghCwd: workspace.ghCwd,
    missingCwd: workspace.missingCwd,
    file: workspace.file,
    dispatchId: `conformance-${scenarioId}-${stamp}`,
    requestId: `req-${scenarioId}-${stamp}`,
    cliSessionId: `conformance-adopted-${scenarioId}-${stamp}`,
    // The name a client asks its isolation worktree be called. Stamped like the ids
    // above and for a sharper reason: `git worktree add` refuses a directory that
    // exists and a branch that exists, and every attempt runs against the same repo,
    // so a fixed name would pass once and then error for the rest of the run.
    worktreeName: `conformance-${stamp}`,
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
    // The two pids `seedHeavyQueue` wrote registry entries for, and one the queue
    // does not hold. Fixed rather than stamped: the entries are written at boot and
    // every attempt reads the same two. The missing one is `0`, which no process can
    // have — a core that treated it as a job would be signalling its own group.
    heavyPidA: HEAVY_PIDS.a,
    heavyPidB: HEAVY_PIDS.b,
    heavyMissingPid: HEAVY_PIDS.missing,
    presetName: "conformance",
    presetMarker: "PRESET-MARKER-conformance",
    missingPresetName: "conformance-missing",
  };
}

export interface RunContext {
  wsUrl: string;
  /** Where the core's HTTP surface lives, for the `get` step. Derived from `wsUrl`
   *  when a caller does not say: both listeners are the same process on the same
   *  port, and a suite that let them disagree could report a read against a core it
   *  was not driving. */
  httpBase?: string;
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
    }
  /** The core was gone, so nothing about this scenario was measured. Distinct from
   *  "failed" because it says nothing about the core's conformance: when the daemon
   *  dies at scenario 25, reporting the eight scenarios after it as failures scores
   *  the core 25/33 for one process death (juancode-jyl9). */
  | { status: "unmeasured"; scenarioId: string; reason: string };

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
 *  message names the attempt that stopped it.
 *
 *  A partial pass is deliberately NOT a pass: attempt 1 of 3 succeeding and attempt
 *  2 dying is a failure carrying 1/3, which is what lets `guardCore` above turn it
 *  into one `unmeasured` verdict instead of averaging a dead core into a green run.
 *
 *  `runOne` is injectable for the same reason `guardCore`'s is: the death path has
 *  to be measurable against a real process that really goes away, and a golden
 *  transcript is not what that is testing. */
export async function runScenarioRepeatedly(
  scenario: Scenario,
  ctx: RunContext,
  repeat: number,
  runOne: (scenario: Scenario, ctx: RunContext) => Promise<void> = runScenario,
): Promise<Outcome> {
  const started = Date.now();
  let passes = 0;
  for (let attempt = 1; attempt <= repeat; attempt++) {
    try {
      await runOne(scenario, ctx);
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

/** The part of a booted core a suite run needs in order to notice it is gone.
 *
 *  An interface rather than `CoreUnderTest` so the guard can be driven by a stub. */
export interface SuiteCore {
  death(): Promise<CoreDeath | null>;
}

/** A death, plus where in the run it happened. */
export interface CoreDeathRecord extends CoreDeath {
  /** The last scenario that finished before the death was noticed, or null when
   *  nothing had finished yet. This is the "after X" the report prints. */
  afterScenarioId: string | null;
  /** The scenario whose failure exposed the death. Unmeasured like the rest, but
   *  it is the one the run reports as the failure, so a dead core is still red. */
  discoveredBy: string;
}

export interface SuiteGuard {
  /** Non-null once the core has been found dead. */
  readonly death: CoreDeathRecord | null;
  /** Run one scenario, unless the core is already gone. */
  run(scenario: Scenario, ctx: RunContext, repeat: number): Promise<Outcome>;
}

/** Wrap the scenario driver so one process death reads as one process death.
 *
 *  Without this, a core that goes away mid-run turns every remaining scenario into
 *  a `connect ECONNREFUSED` failure and the run reports a conformance score it
 *  never measured (juancode-jyl9: six scenarios "failed" for one death). So: a
 *  failure asks the core whether it is still there, and the first time the answer
 *  is no the guard latches — everything after is `unmeasured`, and nothing after
 *  pays for a connection attempt.
 *
 *  Only asked AFTER a failure. A healthy run costs no extra probes, and a core busy
 *  enough to refuse one connection is not latched dead by a passing scenario. */
export function guardCore(
  core: SuiteCore,
  runOne: (
    scenario: Scenario,
    ctx: RunContext,
    repeat: number,
  ) => Promise<Outcome> = runScenarioRepeatedly,
): SuiteGuard {
  let death: CoreDeathRecord | null = null;
  let lastFinished: string | null = null;

  const unmeasured = (scenarioId: string, d: CoreDeathRecord): Outcome => ({
    status: "unmeasured",
    scenarioId,
    reason: `${d.reason} after ${d.afterScenarioId ?? "boot"}, so this scenario never ran`,
  });

  return {
    get death() {
      return death;
    },
    async run(scenario, ctx, repeat) {
      if (death) return unmeasured(scenario.id, death);
      const outcome = await runOne(scenario, ctx, repeat);
      if (outcome.status === "failed") {
        const found = await core.death();
        if (found) {
          const record: CoreDeathRecord = {
            ...found,
            afterScenarioId: lastFinished,
            discoveredBy: scenario.id,
          };
          death = record;
          return unmeasured(scenario.id, record);
        }
      }
      lastFinished = scenario.id;
      return outcome;
    },
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
  if ("get" in step) {
    await requestOverHttp("GET", step.get, step, s);
    return;
  }
  if ("post" in step) {
    await requestOverHttp("POST", step.post, step, s);
    return;
  }
  if ("delete" in step) {
    await requestOverHttp("DELETE", step.delete, step, s);
    return;
  }
  throw new Error(`unrecognised step: ${JSON.stringify(step)}`);
}

/** Substitute `$name` INSIDE a string, which `resolveVars` deliberately does not do.
 *
 *  Everywhere else in a scenario a variable is a whole value — a frame's `sessionId`
 *  is `"$session"` and nothing more — so whole-value substitution is the right rule
 *  and interpolating would make a literal `$` in a prompt a hazard. A URL is the one
 *  place the id has to sit inside a longer string, so the path gets this and nothing
 *  else does. The value is percent-encoded: a session id is a path SEGMENT. */
export function interpolate(path: string, vars: Vars): string {
  return path.replace(/\$([a-zA-Z][a-zA-Z0-9]*)/g, (whole, name: string) =>
    name in vars ? encodeURIComponent(String(vars[name])) : whole,
  );
}

/** The HTTP half of the wire: `${wsUrl}` minus `/ws`, plus the path a step names. */
export function httpBaseOf(ctx: RunContext): string {
  if (ctx.httpBase) return ctx.httpBase.replace(/\/$/, "");
  return ctx.wsUrl
    .replace(/^ws/, "http")
    .replace(/\/ws$/, "")
    .replace(/\/$/, "");
}

/** One `get`, `post` or `delete` step: make the request, assert the status, assert
 *  the body.
 *
 *  The body is matched with the same `matchValue` a frame gets, so a scenario asserts
 *  a read the way it asserts everything else. `expectBody` decodes JSON first and
 *  fails loudly on a body that is not JSON — a core answering `text/plain` where a
 *  scenario asked for a document is a conformance failure, not a parse accident.
 *
 *  A `DELETE` that worked answers 204 with no body at all, so the default expected
 *  status follows the verb and an empty body is only a failure when the step asked
 *  to match one. A `POST` carries a JSON body, because opening a PR or posting a
 *  comment is a request with a body and a side effect; a core that answered those on
 *  GET would be one a browser could fire by prefetching a link.
 *
 *  One function for all three verbs because everything after `fetch` is identical, and
 *  three copies would eventually assert three different things about the same reply. */
async function requestOverHttp(
  method: "GET" | "POST" | "DELETE",
  spec: string,
  step: {
    body?: unknown;
    status?: number;
    expectBody?: unknown;
    expectText?: unknown;
    bind?: Record<string, string>;
  },
  s: StepContext,
): Promise<void> {
  const path = interpolate(spec, s.vars);
  const url = `${httpBaseOf(s.ctx)}${path.startsWith("/") ? "" : "/"}${path}`;
  let res: Response;
  try {
    res =
      method === "POST"
        ? await fetch(url, {
            method,
            headers: { "content-type": "application/json" },
            body: JSON.stringify(resolveVars(step.body ?? {}, s.vars)),
          })
        : await fetch(url, { method });
  } catch (e) {
    throw new WireProtocolError(
      `${method} ${url} did not answer: ${e instanceof Error ? e.message : e}`,
    );
  }
  const text = await res.text();
  const want = step.status ?? (method === "DELETE" ? 204 : 200);
  if (res.status !== want) {
    throw new WireProtocolError(
      `${method} ${path} answered ${res.status}, expected ${want}\n  body: ${text.slice(0, 400)}`,
    );
  }
  if (step.expectText !== undefined) {
    const result = matchValue(text, resolveVars(step.expectText, s.vars), s.vars);
    if (!result.ok) {
      throw new WireProtocolError(
        `${method} ${path} body did not match: ${result.why}\n  got: ${text.slice(0, 400)}`,
      );
    }
  }
  if (step.expectBody === undefined && !step.bind) return;
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    throw new WireProtocolError(
      `${method} ${path} did not answer with JSON\n  got: ${text.slice(0, 400)}`,
    );
  }
  if (step.expectBody !== undefined) {
    const result = matchValue(body, resolveVars(step.expectBody, s.vars), s.vars);
    if (!result.ok) {
      throw new WireProtocolError(
        `${method} ${path} body did not match: ${result.why}\n  got: ${text.slice(0, 400)}`,
      );
    }
  }
  if (step.bind) Object.assign(s.vars, readBindings(body as Frame, step.bind));
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
