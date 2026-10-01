// The watch loop's promise: saves never stack builds. A burst is one build, and any
// number of saves during a build is exactly one follow-up build.
//
// Run: node --test scripts/rebuild-scheduler.test.mjs   (or `pnpm test:scripts`)

import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { setImmediate } from "node:timers";
import {
  createRebuildScheduler,
  isSourceChange,
  summarizeBuildErrors,
} from "./lib/rebuild-scheduler.mjs";

function fakeClock() {
  let now = 0;
  let seq = 0;
  const timers = new Map();
  return {
    setTimer(fn, ms) {
      const id = ++seq;
      timers.set(id, { fn, at: now + ms });
      return id;
    },
    clearTimer(id) {
      timers.delete(id);
    },
    advance(ms) {
      now += ms;
      for (const [id, t] of [...timers]) {
        if (t.at <= now) {
          timers.delete(id);
          t.fn();
        }
      }
    },
  };
}

const flush = () => new Promise((r) => setImmediate(r));

function harness() {
  const clock = fakeClock();
  const builds = [];
  const s = createRebuildScheduler({
    debounceMs: 1000,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
    run: () =>
      new Promise((resolve) => {
        builds.push(resolve);
      }),
  });
  return { clock, builds, s };
}

describe("createRebuildScheduler", () => {
  test("a burst of saves is one build, after the quiet period", () => {
    const { clock, builds, s } = harness();
    s.notify();
    clock.advance(500);
    s.notify();
    clock.advance(900);
    assert.equal(builds.length, 0, "still inside the debounce window");
    clock.advance(100);
    assert.equal(builds.length, 1);
  });

  test("saves during a build coalesce into exactly one follow-up", async () => {
    const { clock, builds, s } = harness();
    s.notify();
    clock.advance(1000);
    assert.equal(builds.length, 1);
    s.notify();
    s.notify();
    s.notify();
    clock.advance(5000);
    assert.equal(builds.length, 1, "never a second concurrent build");
    builds[0]();
    await flush();
    clock.advance(1000);
    assert.equal(builds.length, 2);
    builds[1]();
    await flush();
    clock.advance(5000);
    assert.equal(builds.length, 2, "nothing left over once the follow-up ran");
  });

  test("no save during a build means no follow-up", async () => {
    const { clock, builds, s } = harness();
    s.notify();
    clock.advance(1000);
    builds[0]();
    await flush();
    clock.advance(5000);
    assert.equal(builds.length, 1);
    assert.equal(s.pending, false);
  });

  test("a failing build still lets the next save build", async () => {
    const clock = fakeClock();
    let runs = 0;
    const s = createRebuildScheduler({
      debounceMs: 10,
      setTimer: clock.setTimer,
      clearTimer: clock.clearTimer,
      run: async () => {
        runs++;
        throw new Error("compile error");
      },
    });
    s.notify();
    clock.advance(10);
    await flush();
    assert.equal(s.running, false);
    s.notify();
    clock.advance(10);
    await flush();
    assert.equal(runs, 2);
  });

  test("stop cancels a pending build and ignores later saves", () => {
    const { clock, builds, s } = harness();
    s.notify();
    s.stop();
    s.notify();
    clock.advance(5000);
    assert.equal(builds.length, 0);
  });
});

describe("summarizeBuildErrors", () => {
  test("keeps the error lines, deduplicated, and drops the source context", () => {
    const out = [
      "[3/9] Compiling JuancodeApp RootView.swift",
      "/x/RootView.swift:12:5: error: cannot find 'foo' in scope",
      "   foo()",
      "   ^~~",
      "/x/RootView.swift:12:5: error: cannot find 'foo' in scope",
      "error: fatalError",
    ].join("\n");
    assert.deepEqual(summarizeBuildErrors(out), [
      "/x/RootView.swift:12:5: error: cannot find 'foo' in scope",
      "error: fatalError",
    ]);
  });

  test("caps a flood of errors", () => {
    const out = Array.from({ length: 30 }, (_, i) => `f.swift:${i}:1: error: e${i}`).join("\n");
    const got = summarizeBuildErrors(out, 5);
    assert.equal(got.length, 6);
    assert.match(got[5], /25 more/);
  });

  test("falls back to the tail when no line says error:", () => {
    const out = Array.from({ length: 40 }, (_, i) => `line ${i}`).join("\n");
    const got = summarizeBuildErrors(out);
    assert.equal(got.length, 20);
    assert.equal(got[19], "line 39");
  });
});

describe("isSourceChange", () => {
  test("swift sources count, editor and build droppings do not", () => {
    assert.equal(isSourceChange("JuancodeApp/RootView.swift"), true);
    assert.equal(isSourceChange("JuancodeApp/.RootView.swift.swp"), false);
    assert.equal(isSourceChange("JuancodeApp/RootView.swift~"), false);
    assert.equal(isSourceChange("JuancodeApp/4913"), false);
    assert.equal(isSourceChange(".DS_Store"), false);
    assert.equal(isSourceChange(".build/debug/x.o"), false);
  });
});
