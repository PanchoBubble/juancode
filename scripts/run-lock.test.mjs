// The lock's one job: a dead owner must never be able to stop the next run.
//
// So the cases below are the deaths, not the happy path — a claim with no pid
// (the shape the one-off reclaim pass actually left on disk), a claim naming a
// pid nothing holds, a claim old enough that its pid must have been recycled —
// and each asserts that the next acquire GETS THE LOCK. The one case that must
// fail is a claim whose pid is genuinely alive, which is checked against this
// test process's own pid so it is a real liveness answer and not a fake one.
//
// Run: node --test scripts/run-lock.test.mjs   (or `pnpm test:scripts`)

import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, test } from "node:test";
import {
  OWNER_FILE,
  STALE_AFTER_MS,
  acquire,
  ownerState,
  parseOwner,
  processAlive,
} from "./lib/run-lock.mjs";

const NOW = Date.UTC(2026, 8, 20, 12, 0, 0);
const roots = [];

function freshDir() {
  const d = mkdtempSync(join(tmpdir(), "run-lock-test-"));
  roots.push(d);
  return join(d, "the.lock");
}

/** A lock directory already held by `body`. */
function heldBy(body) {
  const dir = freshDir();
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, OWNER_FILE), body);
  return dir;
}

after(() => {
  for (const r of roots) rmSync(r, { recursive: true, force: true });
});

describe("liveness", () => {
  test("this process is alive, an impossible pid is not, and launchd is never an owner", () => {
    assert.equal(processAlive(process.pid), true);
    // Above the default kern.maxproc ceiling, so nothing can hold it.
    assert.equal(processAlive(4_000_000), false);
    assert.equal(processAlive(0), false);
    // pid 1 is what an orphan is reparented TO — a claim naming it is a claim
    // whose owner already died.
    assert.equal(processAlive(1), false);
    assert.equal(processAlive(null), false);
  });
});

describe("the claim", () => {
  test("first occurrence of a key wins and junk lines are skipped", () => {
    const o = parseOwner("junk\npid=42\npid=99\ntoken=ab\n\ntool=worktree-sweep\n");
    assert.equal(o.pid, 42);
    assert.equal(o.token, "ab");
    assert.equal(o.tool, "worktree-sweep");
    assert.equal(o.startedAt, null);
  });

  test("a live pid holds the lock", () => {
    const state = ownerState(
      `pid=${process.pid}\ntoken=aa\nstartedAt=${new Date(NOW).toISOString()}\n`,
      {
        now: NOW,
      },
    );
    assert.equal(state.state, "held");
  });

  test("a dead pid does not", () => {
    const state = ownerState(`pid=4000000\ntoken=aa\nstartedAt=${new Date(NOW).toISOString()}\n`, {
      now: NOW,
    });
    assert.equal(state.state, "stale");
    assert.match(state.why, /4000000 is gone/);
  });

  // The exact bytes found in ~/.juancode/worktree-reclaim.lock/owner on
  // 2026-09-20: a freeform line from before this module existed. No pid means
  // no way to check, and "cannot check" must resolve to stale or the lock is
  // permanent.
  test("the record the one-off pass left is stale, not held", () => {
    const state = ownerState(
      "1e6aa209 2026-09-19T19:22:53Z took-over-stale-lock-from ee66b7b3 (pid 10855 dead, socket gone, not in daemon running list); user approved\n",
      { now: NOW },
    );
    assert.equal(state.state, "stale");
    assert.match(state.why, /names no pid/);
  });

  test("a live pid past the staleness ceiling is taken over anyway", () => {
    const old = new Date(NOW - STALE_AFTER_MS - 60_000).toISOString();
    const state = ownerState(`pid=${process.pid}\ntoken=aa\nstartedAt=${old}\n`, { now: NOW });
    assert.equal(state.state, "stale");
    assert.match(state.why, /past the 6h ceiling/);
    // And one second inside it is still held — the ceiling is a ceiling, not a
    // second liveness opinion.
    const young = new Date(NOW - STALE_AFTER_MS + 1000).toISOString();
    assert.equal(
      ownerState(`pid=${process.pid}\ntoken=aa\nstartedAt=${young}\n`, { now: NOW }).state,
      "held",
    );
  });

  test("no claim at all is not a held lock", () => {
    assert.equal(ownerState(null).state, "none");
  });
});

describe("acquire", () => {
  test("a free directory is taken, recorded with a pid, and released", () => {
    const dir = freshDir();
    const got = acquire(dir, { tool: "test", now: NOW });
    assert.equal(got.ok, true);
    assert.equal(got.tookOver, null);
    const claim = parseOwner(readFileSync(join(dir, OWNER_FILE), "utf8"));
    assert.equal(claim.pid, process.pid);
    assert.equal(claim.tool, "test");
    assert.equal(claim.token, got.token);
    assert.equal(got.release(), true);
    assert.equal(existsSync(dir), false);
  });

  test("a lock a live process holds is refused", () => {
    const dir = heldBy(
      `pid=${process.pid}\ntoken=other\nstartedAt=${new Date(NOW).toISOString()}\n`,
    );
    const got = acquire(dir, { tool: "test", now: NOW });
    assert.equal(got.ok, false);
    assert.match(got.why, /is alive/);
    // And it left the other claim exactly where it was.
    assert.equal(parseOwner(readFileSync(join(dir, OWNER_FILE), "utf8")).token, "other");
  });

  test("a lock a dead process holds is taken over, leftovers and all", () => {
    const dir = heldBy(`pid=4000000\ntoken=dead\nstartedAt=${new Date(NOW).toISOString()}\n`);
    writeFileSync(join(dir, `${OWNER_FILE}.stale-ee66b7b3`), "ee66b7b3 2026-09-19T18:22:03Z\n");
    const got = acquire(dir, { tool: "test", now: NOW });
    assert.equal(got.ok, true);
    assert.match(got.tookOver, /4000000 is gone/);
    assert.deepEqual(got.leftovers, [`${OWNER_FILE}.stale-ee66b7b3`]);
    assert.equal(existsSync(join(dir, `${OWNER_FILE}.stale-ee66b7b3`)), false);
    const claim = readFileSync(join(dir, OWNER_FILE), "utf8");
    assert.equal(parseOwner(claim).pid, process.pid);
    assert.match(claim, /tookOver=/, "the takeover has to leave an account of itself");
    got.release();
  });

  test("the same process can take the lock again after releasing it", () => {
    const dir = freshDir();
    const first = acquire(dir, { tool: "test", now: NOW });
    assert.equal(first.ok, true);
    assert.equal(first.release(), true);
    const second = acquire(dir, { tool: "test", now: NOW });
    assert.equal(second.ok, true, "a released lock must not need a takeover");
    assert.equal(second.tookOver, null);
    second.release();
  });

  test("releasing does not remove a lock somebody else has taken over", () => {
    const dir = freshDir();
    const mine = acquire(dir, { tool: "test", now: NOW });
    assert.equal(mine.ok, true);
    // Somebody decided this run was past the ceiling and took it.
    writeFileSync(
      join(dir, OWNER_FILE),
      `pid=${process.pid}\ntoken=theirs\nstartedAt=${new Date(NOW).toISOString()}\n`,
    );
    assert.equal(mine.release(), false);
    assert.equal(
      existsSync(dir),
      true,
      "pulling a live holder's lock is the one unforgivable move",
    );
    assert.equal(parseOwner(readFileSync(join(dir, OWNER_FILE), "utf8")).token, "theirs");
  });
});
