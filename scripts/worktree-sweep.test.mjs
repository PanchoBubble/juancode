// The sweeper's verdict, checked against a fixture of real git worktrees.
//
// The classifier is the whole ticket, so it is tested against git actually
// saying these things rather than against hand-written facts. Each case below
// is a worktree this script builds in a temp dir — clean+old, dirty+old,
// unpushed+old, clean+fresh, a live session, a merged PR, the main checkout —
// and the assertion is the verdict `decide` reaches for it.
//
// Run: node --test scripts/worktree-sweep.test.mjs   (or `pnpm test:scripts`)

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { inspectWorktree, mainCheckoutOf, parseWorktrees } from "./lib/worktree-scan.mjs";
import { DAY_MS, decide, isUnder } from "./lib/worktree-sweep-core.mjs";

const NOW = Date.UTC(2026, 8, 19, 12, 0, 0);
const MAX_AGE_MS = 2 * DAY_MS;
const OLD = NOW - 9 * DAY_MS;
const FRESH = NOW - 3 * 60 * 60 * 1000;

const run = (cwd, cmd, args) =>
  execFileSync(cmd, args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
const g = (cwd, ...args) => run(cwd, "git", args);

/** Stamp a worktree (and optionally its git bookkeeping) as nine days old. */
function backdate(treePath, alsoGitDir) {
  const stale = new Date(OLD);
  const stampDeep = (dir, depth) => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      const p = join(dir, e.name);
      if (e.isDirectory() && e.name !== ".git" && depth < 4) stampDeep(p, depth + 1);
      try {
        utimesSync(p, stale, stale);
      } catch {
        /* .git is a file here and stamping it is harmless either way */
      }
    }
    utimesSync(dir, stale, stale);
  };
  stampDeep(treePath, 0);
  if (!alsoGitDir) return;
  const gitDir = g(treePath, "rev-parse", "--absolute-git-dir");
  for (const f of ["index", "HEAD", "logs/HEAD", "ORIG_HEAD", "COMMIT_EDITMSG"]) {
    const p = join(gitDir, f);
    if (existsSync(p)) utimesSync(p, stale, stale);
  }
}

let root; // temp dir
let origin; // bare remote
let main; // the main checkout
let trees; // name -> path

before(() => {
  // realpath, not the raw mkdtemp path: on macOS /var is a symlink to
  // /private/var and git reports the resolved form, so an unresolved fixture
  // path matches nothing git says.
  root = realpathSync(mkdtempSync(join(tmpdir(), "wtsweep-")));
  origin = join(root, "origin.git");
  main = join(root, "main");
  g(root, "init", "--bare", "-q", "--initial-branch=main", origin);
  g(root, "clone", "-q", origin, main);
  g(main, "config", "user.email", "fixture@example.invalid");
  g(main, "config", "user.name", "fixture");
  writeFileSync(join(main, "README"), "base\n");
  writeFileSync(join(main, ".gitignore"), "build/\n");
  g(main, "add", "-A");
  g(main, "commit", "-qm", "base");
  g(main, "push", "-q", "origin", "main");

  const add = (name, branch) => {
    const p = join(root, name);
    g(main, "worktree", "add", "-q", "-b", branch, p);
    g(p, "config", "user.email", "fixture@example.invalid");
    g(p, "config", "user.name", "fixture");
    return p;
  };

  trees = {
    // 1. clean, no commits of its own, old  -> the only removable shape
    cleanOld: add("clean-old", "clean-old"),
    // 2. an uncommitted edit, old           -> keep
    dirtyOld: add("dirty-old", "dirty-old"),
    // 3. an untracked file only, old        -> keep (untracked IS work)
    untrackedOld: add("untracked-old", "untracked-old"),
    // 4. a commit that was never pushed     -> keep (invisible to gh)
    unpushedOld: add("unpushed-old", "unpushed-old"),
    // 5. pushed to its own branch, not in main -> keep (no PR / not merged)
    pushedOld: add("pushed-old", "pushed-old"),
    // 6. clean but touched an hour ago      -> keep
    cleanFresh: add("clean-fresh", "clean-fresh"),
    // 7. clean + old, but a session is in it -> keep
    liveOld: add("live-old", "live-old"),
    // 8. commits that ARE in origin/main    -> removable when old
    mergedOld: add("merged-old", "merged-old"),
    // 9. ignored build output only          -> removable (git ignores it)
    buildOnlyOld: add("build-only-old", "build-only-old"),
  };

  writeFileSync(join(trees.dirtyOld, "README"), "edited by an agent, never committed\n");
  writeFileSync(join(trees.untrackedOld, "notes.md"), "scratch that exists nowhere else\n");

  writeFileSync(join(trees.unpushedOld, "work.txt"), "local only\n");
  g(trees.unpushedOld, "add", "-A");
  g(trees.unpushedOld, "commit", "-qm", "unpushed work");

  writeFileSync(join(trees.pushedOld, "work.txt"), "pushed to a branch\n");
  g(trees.pushedOld, "add", "-A");
  g(trees.pushedOld, "commit", "-qm", "pushed work");
  g(trees.pushedOld, "push", "-q", "-u", "origin", "pushed-old");

  writeFileSync(join(trees.mergedOld, "shipped.txt"), "landed on main\n");
  g(trees.mergedOld, "add", "-A");
  g(trees.mergedOld, "commit", "-qm", "shipped work");
  g(trees.mergedOld, "push", "-q", "origin", "merged-old:main");
  g(main, "fetch", "-q", "origin");

  mkdirSync(join(trees.buildOnlyOld, "build"), { recursive: true });
  writeFileSync(join(trees.buildOnlyOld, "build", "artifact.o"), "x".repeat(1024));

  // Everything is nine days old except clean-fresh, whose GIT BOOKKEEPING is
  // left current while its working files are back-dated too. That is the
  // last-modified-not-created case: on files alone it looks stale, and the
  // sweeper must still read it as touched-just-now.
  for (const [name, p] of Object.entries(trees)) backdate(p, name !== "cleanFresh");
});

after(() => rmSync(root, { recursive: true, force: true }));

/** The real git facts for one fixture tree, plus the two things git cannot know. */
function candidateFor(path, { mtimeMs = OLD, liveReasons = [], prs = new Map() } = {}) {
  const t = parseWorktrees(main).find((w) => w.path === path);
  assert.ok(t, `no worktree registered at ${path}`);
  return { ...inspectWorktree(t, { repoRoot: main, prs }), mtimeMs, liveReasons };
}

const verdictFor = (path, extra, opts = {}) =>
  decide(candidateFor(path, extra), { nowMs: NOW, maxAgeMs: MAX_AGE_MS, ...opts });

describe("worktree sweeper classifier", () => {
  test("clean + old + nothing running: the one case it removes", () => {
    const v = verdictFor(trees.cleanOld);
    assert.equal(v.verdict, "remove");
    assert.equal(v.code, "STALE");
  });

  test("ignored build output does not make an old clean tree worth keeping", () => {
    assert.equal(verdictFor(trees.buildOnlyOld).verdict, "remove");
  });

  test("commits already in origin/main are not work that exists only here", () => {
    const v = verdictFor(trees.mergedOld);
    assert.equal(v.verdict, "remove", v.reason);
  });

  test("an uncommitted edit is kept", () => {
    const v = verdictFor(trees.dirtyOld);
    assert.equal(v.verdict, "keep");
    assert.equal(v.code, "DIRTY");
  });

  test("an untracked file is kept — it is work too", () => {
    const v = verdictFor(trees.untrackedOld);
    assert.equal(v.verdict, "keep");
    assert.equal(v.code, "DIRTY");
  });

  test("UNPUSHED COMMITS ARE KEPT: no upstream means gh cannot see them", () => {
    const c = candidateFor(trees.unpushedOld);
    assert.equal(c.pushed, null, "fixture should have no remote branch");
    assert.equal(c.dirty, 0, "fixture should otherwise look clean");
    const v = decide(c, { nowMs: NOW, maxAgeMs: MAX_AGE_MS });
    assert.equal(v.verdict, "keep");
    assert.equal(v.code, "UNPUSHED");
  });

  test("commits pushed to their own branch but not in main are kept", () => {
    const v = verdictFor(trees.pushedOld);
    assert.equal(v.verdict, "keep");
    assert.equal(v.code, "UNMERGED");
  });

  test("an open PR is kept even when the tree is old and clean", () => {
    const prs = new Map([
      ["clean-old", { number: 7, state: "OPEN", isDraft: false, url: "u", mergedAt: null }],
    ]);
    const v = verdictFor(trees.cleanOld, { prs });
    assert.equal(v.verdict, "keep");
    assert.equal(v.code, "PR_OPEN");
  });

  test("a tree modified three hours ago is not two days old", () => {
    const v = verdictFor(trees.cleanFresh, { mtimeMs: FRESH });
    assert.equal(v.verdict, "keep");
    assert.equal(v.code, "FRESH");
  });

  test("a live session outranks every other signal", () => {
    const v = verdictFor(trees.liveOld, {
      liveReasons: ["daemon reports a running session at " + trees.liveOld],
    });
    assert.equal(v.verdict, "keep");
    assert.equal(v.code, "LIVE");
  });

  test("the main checkout is never a candidate", () => {
    const v = verdictFor(main);
    assert.equal(v.verdict, "keep");
    assert.ok(["MAIN_CHECKOUT", "MAIN_BRANCH"].includes(v.code), v.code);
  });

  test("a tree inside a protected path is never a candidate", () => {
    const v = verdictFor(trees.cleanOld, {}, { protectedPaths: [root] });
    assert.equal(v.verdict, "keep");
    assert.equal(v.code, "PROTECTED");
  });

  test("unreadable git state is kept, never guessed at", () => {
    const c = { ...candidateFor(trees.cleanOld), readable: false };
    assert.equal(decide(c, { nowMs: NOW, maxAgeMs: MAX_AGE_MS }).code, "UNREADABLE");
  });

  test("no modification time means no removal", () => {
    const v = verdictFor(trees.cleanOld, { mtimeMs: NaN });
    assert.equal(v.verdict, "keep");
    assert.equal(v.code, "NO_MTIME");
  });

  test("a locked worktree is kept", () => {
    const c = { ...candidateFor(trees.cleanOld), locked: true };
    assert.equal(decide(c, { nowMs: NOW, maxAgeMs: MAX_AGE_MS }).code, "LOCKED");
  });
});

describe("the sweeper end to end, against the fixture", () => {
  // One subprocess run per claim and no more: every exec on this machine costs a
  // quarter of a second before the child's first instruction, so a test that
  // spawns the sweeper per assertion takes ten minutes.
  //
  // A stand-in for the daemon serves /api/sessions, because "a session is
  // running in this tree" is the guard most likely to be the difference between
  // a tidy disk and a destroyed afternoon, and asserting it against an injected
  // value would prove nothing about the code that reads the daemon.
  // The stand-in daemon runs in ITS OWN PROCESS. execFileSync blocks this one's
  // event loop, so a server living here could never answer the sweeper's request
  // — it would look exactly like a daemon that is down, and the test would pass
  // for the wrong reason.
  let daemon;
  let daemonUrl;
  let deadUrl;
  let report;
  let logText;
  const sweepLogDir = join(root, "sweeplog");
  // Its own lock directory, never ~/.juancode's: an --apply here must not be
  // refused because a real sweep happens to be running, nor refuse a real one.
  const sweepLockDir = join(root, "sweep.lock");

  const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

  const sweep = (extraArgs, url) => {
    const out = execFileSync(
      process.execPath,
      [
        join(import.meta.dirname, "worktree-sweep.mjs"),
        `--root=${main}`,
        "--json",
        "--no-fetch",
        "--days=2",
        ...extraArgs,
      ],
      {
        cwd: root,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        env: {
          ...process.env,
          JUANCODE_LOG_DIR: sweepLogDir,
          JUANCODE_APP_URL: url,
          JUANCODE_SWEEP_LOCK: sweepLockDir,
        },
      },
    );
    return JSON.parse(out.slice(out.indexOf("{")));
  };

  const registered = () => new Set(parseWorktrees(main).map((w) => w.path));

  before(() => {
    const stub = join(root, "daemon-stub.mjs");
    const portFile = join(root, "daemon.port");
    writeFileSync(
      stub,
      [
        'import { createServer } from "node:http";',
        'import { readFileSync, writeFileSync } from "node:fs";',
        "// The payload comes from a FILE, not argv: the sweeper also treats a",
        "// process whose command line names a worktree as a reason to keep it,",
        "// and a stub carrying these paths in its argv would pin them all.",
        'const payload = readFileSync(process.argv[2], "utf8");',
        "const s = createServer((_q, r) => {",
        '  r.setHeader("content-type", "application/json");',
        "  r.end(payload);",
        "});",
        's.listen(0, "127.0.0.1", () => writeFileSync(process.argv[3], String(s.address().port)));',
        "// Never outlive the test, even if the test is killed.",
        "setTimeout(() => process.exit(0), 600000);",
        "",
      ].join("\n"),
    );
    const sessionsFile = join(root, "sessions.json");
    writeFileSync(
      sessionsFile,
      JSON.stringify([
        { id: "s1", status: "running", cwd: trees.liveOld, worktreePath: trees.liveOld },
        { id: "s2", status: "exited", cwd: trees.cleanOld, worktreePath: trees.cleanOld },
      ]),
    );
    daemon = spawn(process.execPath, [stub, sessionsFile, portFile], { stdio: "ignore" });
    for (let i = 0; i < 200 && !existsSync(portFile); i++) sleep(50);
    assert.ok(existsSync(portFile), "the stand-in daemon never came up");
    daemonUrl = `http://127.0.0.1:${readFileSync(portFile, "utf8").trim()}`;
    // A port nothing is listening on, for the "cannot see what is running" case.
    // Taken from a second stub that is then killed, so it is a port the OS just
    // handed out rather than a guess that something else may be sitting on.
    const deadPortFile = join(root, "dead.port");
    const emptyFile = join(root, "empty-sessions.json");
    writeFileSync(emptyFile, "[]");
    const dead = spawn(process.execPath, [stub, emptyFile, deadPortFile], { stdio: "ignore" });
    for (let i = 0; i < 200 && !existsSync(deadPortFile); i++) sleep(50);
    assert.ok(existsSync(deadPortFile), "the second stub never came up");
    deadUrl = `http://127.0.0.1:${readFileSync(deadPortFile, "utf8").trim()}`;
    dead.kill("SIGKILL");

    // Re-stamp before the first sweep: the classifier tests above ran git in
    // every fixture tree.
    for (const [name, p] of Object.entries(trees)) backdate(p, name !== "cleanFresh");

    report = sweep([], daemonUrl);
    logText = readFileSync(join(sweepLogDir, "worktree-sweep.log"), "utf8");
  });

  after(() => daemon?.kill("SIGTERM"));

  test("a dry run removes nothing", () => {
    assert.equal(report.mode, "DRY-RUN");
    assert.equal(report.daemonReachable, true);
    assert.deepEqual(report.removed, []);
    assert.equal(registered().size, Object.keys(trees).length + 1);
  });

  test("it names exactly the trees with nothing worth keeping", () => {
    const rm = report.rows
      .filter((r) => r.verdict === "remove")
      .map((r) => r.branch)
      .sort();
    assert.deepEqual(
      rm,
      ["build-only-old", "clean-old", "merged-old"],
      JSON.stringify(report.rows.map((r) => [r.branch, r.code, r.ageHours])),
    );
  });

  test("the daemon's running session pins its tree, old and clean as it is", () => {
    const row = report.rows.find((r) => r.branch === "live-old");
    assert.equal(row.verdict, "keep");
    assert.equal(row.code, "LIVE");
    // and an EXITED session in clean-old does not pin it
    assert.equal(report.rows.find((r) => r.branch === "clean-old").verdict, "remove");
  });

  test("LAST MODIFIED, NOT CREATED: files stamped nine days ago, git touched now", () => {
    // clean-fresh's working files were back-dated with every other tree's; only
    // its git bookkeeping is current. A creation-time or file-mtime-only reading
    // would call it stale and delete it.
    const row = report.rows.find((r) => r.branch === "clean-fresh");
    assert.equal(row.verdict, "keep");
    assert.equal(row.code, "FRESH", JSON.stringify(row));
  });

  test("the log records every tree, kept ones included, with the reason", () => {
    assert.match(logText, /^=== .* DRY-RUN /m);
    for (const r of report.rows) {
      const line = logText.split("\n").find((l) => l.includes(` ${r.path} `));
      assert.ok(line, `no log line for ${r.path}`);
      assert.match(line, r.verdict === "remove" ? /^WOULD-RM / : /^kept {4}/);
      assert.ok(line.includes(r.code), line);
      assert.ok(line.includes(`head=${r.head.slice(0, 12)}`), line);
    }
  });

  test("--apply removes nothing while the daemon cannot be asked what is running", () => {
    const before = registered();
    const r = sweep(["--apply"], deadUrl);
    assert.match(r.mode, /^REFUSED/);
    assert.equal(r.daemonReachable, false);
    assert.deepEqual(r.removed, []);
    assert.deepEqual(registered(), before);
  });

  test("a sweep does not reset the age clock it reads", () => {
    // `git status` rewrites .git/index, and the sweep above ran it in every
    // tree. If the index counted as a freshness signal, every tree would now
    // read as touched-this-second and nothing would ever age past the floor —
    // the sweeper would quietly never remove anything. Nothing is re-stamped
    // between these two runs on purpose.
    const again = sweep([], daemonUrl);
    const rm = again.rows
      .filter((r) => r.verdict === "remove")
      .map((r) => r.branch)
      .sort();
    assert.deepEqual(
      rm,
      ["build-only-old", "clean-old", "merged-old"],
      JSON.stringify(again.rows.map((x) => [x.branch, x.code, x.reason])),
    );
  });

  test("--apply removes nothing when lsof and ps report nothing", () => {
    // The daemon is only one of the two liveness sources. If the process table
    // comes back empty that is not "nothing is running", it is "we cannot see" —
    // and a machine where a hundred processes report as zero is exactly the one
    // you do not want deleting directories.
    const fakeBin = join(root, "blind-bin");
    mkdirSync(fakeBin, { recursive: true });
    for (const name of ["lsof", "ps"]) {
      const f = join(fakeBin, name);
      writeFileSync(f, "#!/bin/sh\nexit 1\n");
      chmodSync(f, 0o755);
    }
    const before = registered();
    const out = execFileSync(
      process.execPath,
      [
        join(import.meta.dirname, "worktree-sweep.mjs"),
        `--root=${main}`,
        "--json",
        "--no-fetch",
        "--apply",
        "--days=2",
      ],
      {
        cwd: root,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        env: {
          ...process.env,
          JUANCODE_LOG_DIR: sweepLogDir,
          JUANCODE_APP_URL: daemonUrl,
          JUANCODE_SWEEP_LOCK: sweepLockDir,
          PATH: `${fakeBin}:${process.env.PATH}`,
        },
      },
    );
    const r = JSON.parse(out.slice(out.indexOf("{")));
    assert.equal(r.processesSampled, false);
    assert.equal(r.daemonReachable, true, "the daemon half must still be working");
    assert.match(r.mode, /^REFUSED/);
    assert.deepEqual(r.removed, []);
    assert.deepEqual(registered(), before);
  });

  test("--dry-run beats --apply when both are passed", () => {
    const before = registered();
    const r = sweep(["--apply", "--dry-run"], daemonUrl);
    assert.equal(r.mode, "DRY-RUN");
    assert.deepEqual(r.removed, []);
    assert.deepEqual(registered(), before);
  });

  // Last, because it is the only test that changes the fixture.
  test("--apply removes exactly those three and leaves everything else standing", () => {
    const r = sweep(["--apply"], daemonUrl);
    assert.equal(r.mode, "APPLY");
    assert.deepEqual(
      r.removed.map((p) => p.split("/").pop()).sort(),
      ["build-only-old", "clean-old", "merged-old"],
      JSON.stringify(r.rows.map((x) => [x.branch, x.code, x.reason])),
    );
    const left = registered();
    for (const name of [
      "dirtyOld",
      "untrackedOld",
      "unpushedOld",
      "pushedOld",
      "cleanFresh",
      "liveOld",
    ]) {
      assert.ok(left.has(trees[name]), `${name} should have survived the sweep`);
    }
    assert.ok(left.has(main));
    assert.ok(!left.has(trees.cleanOld));
    assert.match(readFileSync(join(sweepLogDir, "worktree-sweep.log"), "utf8"), /^REMOVED /m);
  });
});

describe("finding the checkout to sweep", () => {
  test("a path inside a worktree still resolves to the MAIN checkout", () => {
    // Otherwise the tree the sweep was launched from is the one exempted as
    // "the main checkout", and the real main checkout is judged on its merits.
    assert.equal(mainCheckoutOf(trees.dirtyOld), main);
    assert.equal(mainCheckoutOf(main), main);
  });
});

describe("isUnder", () => {
  test("is prefix-safe", () => {
    assert.equal(isUnder("/a/b/c", "/a/b"), true);
    assert.equal(isUnder("/a/b", "/a/b"), true);
    assert.equal(isUnder("/a/bc", "/a/b"), false);
    assert.equal(isUnder("/a/b", "/a/b/c"), false);
  });
});
