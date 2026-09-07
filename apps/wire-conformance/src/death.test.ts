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
import { guardCore, type Outcome, type RunContext } from "./runner.ts";
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
