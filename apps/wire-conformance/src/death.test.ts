// What the harness reports when the core process dies in the middle of a run.
//
// This is the case juancode-jyl9 was filed for: on 2026-09-04 the Rust daemon went
// away between scenario 24 and 25 of a six-times repeat, and every scenario after
// it reported `connect ECONNREFUSED 127.0.0.1:4297`. The run therefore scored the
// core 25 of 33, which is a number nobody measured, and it carried no core output
// at all because the boot probe was the only place that printed any.
//
// So the death here is deliberate rather than awaited: a real process, a real
// SIGKILL between two scenarios, and the assertions are on what the report says
// afterwards. Nothing in this file waits for the flake.

import { join } from "node:path";

import { afterAll, describe, expect, it } from "vitest";

import { FIXTURES, makeLogRing, startCore, type CoreUnderTest } from "./core.ts";
import { renderRunMarkdown, toStatusFile, type RunReport } from "./report.ts";
import { guardCore, runScenarioRepeatedly, type Outcome, type RunContext } from "./runner.ts";
import type { Scenario } from "./spec.ts";

const FAKE_CORE = join(FIXTURES, "fake-core.mjs");

/** A scenario shell. The guard only reads the id, and the runner is stubbed. */
function scenario(id: string): Scenario {
  return { id, title: id, asserts: id, steps: [] };
}

/** The stub scenario driver: pass while the core answers, fail when it does not.
 *
 *  A real transcript is not what is under test here — the harness's reaction to a
 *  dead core is — but the pass/fail still has to come from the actual process, or
 *  the test would be asserting that a mock returns what it was told to. */
function healthDrivenRunner(httpBase: string) {
  let calls = 0;
  const run = async (s: Scenario): Promise<Outcome> => {
    calls += 1;
    try {
      const res = await fetch(`${httpBase}/api/health`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return { status: "passed", scenarioId: s.id, ms: 1, attempts: 1, passes: 1 };
    } catch (e) {
      return {
        status: "failed",
        scenarioId: s.id,
        ms: 1,
        attempts: 1,
        passes: 0,
        error: e instanceof Error ? e.message : String(e),
      };
    }
  };
  return { run, calls: () => calls };
}

const ctx = {} as RunContext; // the stub runner never reads it

describe("a core that dies mid-run", () => {
  let core: CoreUnderTest | undefined;
  afterAll(async () => {
    await core?.stop();
  });

  it("is reported as one death with its own log, not as N failed scenarios", async () => {
    core = await startCore({ core: "rust", exe: FAKE_CORE, port: 0 });
    const driver = healthDrivenRunner(core.httpBase);
    const guard = guardCore(core, driver.run);

    const before = [
      await guard.run(scenario("01-first"), ctx, 1),
      await guard.run(scenario("02-second"), ctx, 1),
    ];
    expect(before.map((o) => o.status)).toEqual(["passed", "passed"]);
    expect(guard.death).toBeNull();
    // The boot output has to still be in hand at this point, or there is nothing
    // for the death to carry.
    expect(core.log()).toContain("fake-core: listening on");

    // The death. Between scenarios, on purpose: that is where it happened.
    expect(core.pid).not.toBeNull();
    process.kill(core.pid as number, "SIGKILL");
    await new Promise((r) => setTimeout(r, 300));

    const after = [
      await guard.run(scenario("03-discovers"), ctx, 1),
      await guard.run(scenario("04-later"), ctx, 1),
      await guard.run(scenario("05-last"), ctx, 1),
    ];
    expect(after.map((o) => o.status)).toEqual(["unmeasured", "unmeasured", "unmeasured"]);

    const death = guard.death;
    expect(death).not.toBeNull();
    if (!death) return;
    expect(death.signal).toBe("SIGKILL");
    expect(death.reason).toContain("SIGKILL");
    expect(death.discoveredBy).toBe("03-discovers");
    // The last scenario that finished, which is the fact the ticket wanted: the
    // core died AFTER 02, so 03 onwards say nothing about the core.
    expect(death.afterScenarioId).toBe("02-second");
    expect(death.log).toContain("fake-core: booting");
    expect(death.log).toContain("fake-core: this line is on stderr");

    // Once latched, no further scenario pays for a connection attempt.
    expect(driver.calls()).toBe(3);

    const report: RunReport = {
      core: "fake",
      url: core.wsUrl,
      specRevision: "test",
      protocolVersion: 1,
      capabilities: [],
      repeat: 1,
      outcomes: [...before, ...after],
      coreDeath: death,
    };
    const md = renderRunMarkdown(report, "2026-09-07");
    expect(md).toContain("## The core died mid-run");
    expect(md).toContain("Died after: 02-second");
    expect(md).toContain("Noticed by: 03-discovers");
    expect(md).toContain("SIGKILL");
    // The core's own output, in the report, for a death that was not a boot failure.
    expect(md).toContain("fake-core: this line is on stderr");
    // And the score reads as what it is.
    expect(md).toContain("2 passed, 0 failed, 0 skipped, 3 unmeasured (the core died)");
    expect(md).not.toContain("03-discovers: NO");

    const status = toStatusFile(report, "2026-09-07");
    expect(status.scenarios["01-first"]?.status).toBe("passed");
    expect(status.scenarios["03-discovers"]?.status).toBe("unmeasured");
    // No attempt counts on an unmeasured verdict: "0/1" would read as a measurement.
    expect(status.scenarios["03-discovers"]?.attempts).toBeUndefined();
  }, 60_000);
});

describe("the core log ring", () => {
  it("keeps the tail rather than a count of chunks", () => {
    const ring = makeLogRing(10);
    ring.push("abcdefgh");
    ring.push("ijkl");
    expect(ring.text()).toBe("cdefghijkl");
  });

  it("keeps everything that fits", () => {
    const ring = makeLogRing(10);
    ring.push("ab");
    ring.push("cd");
    expect(ring.text()).toBe("abcd");
  });
});

// The same death, but under a repeat pass — which is the shape CI actually runs
// both cores in now (JUANCODE_CONFORMANCE_REPEAT=3 on the Swift job since it was
// written, on the Rust job since juancode-jyl9's own core turned out to be the one
// that dies). A death on attempt 2 of 3 has a partial pass in hand, and the failure
// mode worth guarding against is that partial averaging into a green verdict: 1/3
// is not a measurement of a core that is no longer running.

/** A single-attempt driver for `runScenarioRepeatedly`, backed by the real health
 *  endpoint, that kills the core on a chosen attempt.
 *
 *  Global attempt count rather than per-scenario, because the interesting attempt
 *  is "the second one of the second scenario" and only the caller knows where that
 *  falls. The kill is inside the driver for lack of anywhere else to stand: the
 *  attempts happen inside the repeat loop, so a test body cannot get between two of
 *  them. */
function attemptDriver(core: CoreUnderTest, killAtAttempt: number) {
  let attempts = 0;
  const run = async (): Promise<void> => {
    attempts += 1;
    if (attempts === killAtAttempt) {
      expect(core.pid).not.toBeNull();
      process.kill(core.pid as number, "SIGKILL");
      await new Promise((r) => setTimeout(r, 300));
    }
    const res = await fetch(`${core.httpBase}/api/health`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
  };
  return { run, attempts: () => attempts };
}

describe("a core that dies on attempt 2 of 3", () => {
  let core: CoreUnderTest | undefined;
  afterAll(async () => {
    await core?.stop();
  });

  it("is unmeasured with no partial credit, not a pass averaged from attempt 1", async () => {
    const repeat = 3;
    core = await startCore({ core: "rust", exe: FAKE_CORE, port: 0 });
    // Attempt 5 overall = the second attempt at the second scenario: the first
    // scenario gets its full 3, so the report has a real 3/3 to sit next to.
    const driver = attemptDriver(core, 5);
    const guard = guardCore(core, (s, c, r) => runScenarioRepeatedly(s, c, r, driver.run));

    const outcomes = [
      await guard.run(scenario("01-repeats-clean"), ctx, repeat),
      await guard.run(scenario("02-dies-mid-repeat"), ctx, repeat),
      await guard.run(scenario("03-never-ran"), ctx, repeat),
    ];

    expect(outcomes.map((o) => o.status)).toEqual(["passed", "unmeasured", "unmeasured"]);
    // Attempt 3 of scenario 02 was never paid for, and neither was scenario 03.
    expect(driver.attempts()).toBe(5);

    const death = guard.death;
    expect(death).not.toBeNull();
    if (!death) return;
    expect(death.signal).toBe("SIGKILL");
    expect(death.afterScenarioId).toBe("01-repeats-clean");
    expect(death.discoveredBy).toBe("02-dies-mid-repeat");
    expect(death.log).toContain("fake-core: booting");

    const report: RunReport = {
      core: "fake",
      url: core.wsUrl,
      specRevision: "test",
      protocolVersion: 1,
      capabilities: [],
      repeat,
      outcomes,
      coreDeath: death,
    };
    const md = renderRunMarkdown(report, "2026-09-07");
    expect(md).toContain("Attempts per scenario: 3");
    expect(md).toContain("## The core died mid-run");
    expect(md).toContain("Died after: 01-repeats-clean");
    expect(md).toContain("Noticed by: 02-dies-mid-repeat");
    expect(md).toContain("1 passed, 0 failed, 0 skipped, 2 unmeasured (the core died)");
    // The scenario that died reads as unmeasured, and specifically NOT as the 1/3
    // its one surviving attempt would otherwise have earned it.
    expect(md).toContain("02-dies-mid-repeat: unmeasured (core died)");
    expect(md).not.toContain("02-dies-mid-repeat: 1/3");

    const status = toStatusFile(report, "2026-09-07");
    expect(status.scenarios["01-repeats-clean"]).toMatchObject({
      status: "passed",
      attempts: 3,
      passes: 3,
    });
    expect(status.scenarios["02-dies-mid-repeat"]?.status).toBe("unmeasured");
    // No "1/3" survives into the committed-claim comparison either: a scenario the
    // core was alive for one third of is not a scenario that was measured.
    expect(status.scenarios["02-dies-mid-repeat"]?.attempts).toBeUndefined();
    expect(status.scenarios["02-dies-mid-repeat"]?.passes).toBeUndefined();
  }, 60_000);
});

describe("the repeat loop", () => {
  it("reports the attempt that stopped it and stops there", async () => {
    // No process here: this is the arithmetic the guard above depends on, stated
    // on its own so a change to it fails loudly rather than through a death test.
    let attempts = 0;
    const outcome = await runScenarioRepeatedly(scenario("07-flaky"), ctx, 3, async () => {
      attempts += 1;
      if (attempts === 2) throw new Error("gone");
    });

    expect(attempts).toBe(2);
    expect(outcome.status).toBe("failed");
    if (outcome.status !== "failed") return;
    expect(outcome.attempts).toBe(3);
    expect(outcome.passes).toBe(1);
    expect(outcome.error).toContain("attempt 2 of 3");
  });
});
