import { describe, expect, it } from "vitest";

import {
  mark,
  renderParityMarkdown,
  renderRunMarkdown,
  statusDifferences,
  toStatusFile,
  type RunReport,
  type StatusFile,
} from "./report.ts";

function status(over: Partial<StatusFile> = {}): StatusFile {
  return {
    core: "rust",
    coreLabel: "apps/juancoded, the Rust core",
    source: "measured",
    measuredAt: "2026-08-01",
    specRevision: "1.3.0",
    protocolVersion: 1,
    capabilities: ["screen", "queue"],
    scenarios: { handshake: { status: "passed" }, queue: { status: "passed" } },
    ...over,
  };
}

describe("checking a committed parity claim against a fresh measurement", () => {
  it("accepts a measurement that agrees, whenever it was taken", () => {
    expect(statusDifferences(status(), status({ measuredAt: "2026-12-24" }))).toEqual([]);
  });

  it("ignores the order capabilities are advertised in", () => {
    expect(statusDifferences(status(), status({ capabilities: ["queue", "screen"] }))).toEqual([]);
  });

  it("ignores a reworded note on a verdict that did not change", () => {
    const measured = status({
      scenarios: { handshake: { status: "passed" }, queue: { status: "passed", note: "fine" } },
    });
    expect(statusDifferences(status(), measured)).toEqual([]);
  });

  it("reports a scenario that now fails", () => {
    const measured = status({
      scenarios: { handshake: { status: "passed" }, queue: { status: "failed", note: "timeout" } },
    });
    expect(statusDifferences(status(), measured)).toEqual([
      "queue: committed passed, measured failed",
    ]);
  });

  it("reports a scenario the committed file understates", () => {
    // The stale-parity case: the core grew a capability and now passes what the
    // checked-in file still calls skipped.
    const committed = status({
      capabilities: ["screen"],
      scenarios: { handshake: { status: "passed" }, queue: { status: "skipped", note: "no cap" } },
    });
    expect(statusDifferences(committed, status())).toEqual([
      "capabilities: committed [screen], measured [queue, screen]",
      "queue: committed skipped, measured passed",
    ]);
  });

  it("reports a scenario that only one side knows about", () => {
    const measured = status({
      scenarios: {
        handshake: { status: "passed" },
        queue: { status: "passed" },
        "seeded-input": { status: "passed" },
      },
    });
    expect(statusDifferences(status(), measured)).toEqual([
      "seeded-input: committed absent, measured passed",
    ]);
  });
});

describe("how many measurements a verdict rests on", () => {
  it("reads a pass as a ratio, so a one-run green cannot pose as the gate", () => {
    expect(mark("passed", 3, 3)).toBe("3/3");
    expect(mark("passed", 1, 1)).toBe("1/1");
  });

  it("keeps a failure's ratio, which is the whole point of p5vb", () => {
    expect(mark("failed", 6, 2)).toBe("NO (2/6)");
  });

  it("falls back to a bare mark when nothing counted", () => {
    expect(mark("passed")).toBe("yes");
    expect(mark("skipped", 3, 0)).toBe("n/a");
    expect(mark("unknown")).toBe("not measured");
  });

  it("does not compare the counts, only the verdicts", () => {
    // CI measures three times and a local re-measure measures once; they agree
    // about the core, and a diff here would call that a regression.
    const committed = status({
      scenarios: { handshake: { status: "passed", attempts: 3, passes: 3 } },
    });
    const measured = status({
      scenarios: { handshake: { status: "passed", attempts: 1, passes: 1 } },
    });
    expect(statusDifferences(committed, measured)).toEqual([]);
  });
});

describe("what a run report says about repetition", () => {
  const report = (over: Partial<RunReport> = {}): RunReport => ({
    core: "rust",
    url: "ws://127.0.0.1:4300/ws",
    specRevision: "1.7.0",
    protocolVersion: 1,
    capabilities: ["screen"],
    repeat: 3,
    outcomes: [
      { status: "passed", scenarioId: "handshake", ms: 10, attempts: 3, passes: 3 },
      {
        status: "failed",
        scenarioId: "tracked-prs",
        ms: 20,
        attempts: 3,
        passes: 1,
        error: "attempt 2 of 3: boom",
      },
      { status: "skipped", scenarioId: "spawn-preset", reason: "no capability" },
    ],
    ...over,
  });

  it("says how many attempts each scenario was asked for", () => {
    expect(renderRunMarkdown(report(), "2026-09-04")).toContain("- Attempts per scenario: 3");
  });

  it("prints each verdict as a ratio", () => {
    const md = renderRunMarkdown(report(), "2026-09-04");
    expect(md).toContain("- handshake: 3/3");
    expect(md).toContain("- tracked-prs: NO (1/3)");
    expect(md).toContain("- spawn-preset: n/a");
  });

  it("carries the counts into the checked-in status file", () => {
    const file = toStatusFile(report(), "2026-09-04");
    expect(file.scenarios["handshake"]).toEqual({ status: "passed", attempts: 3, passes: 3 });
    expect(file.scenarios["tracked-prs"]).toMatchObject({
      status: "failed",
      attempts: 3,
      passes: 1,
    });
    expect(file.scenarios["spawn-preset"]).toEqual({ status: "skipped", note: "no capability" });
  });

  it("puts the ratio in the parity checklist a human reads", () => {
    const file = toStatusFile(report(), "2026-09-04");
    const scenarios = [
      { id: "handshake", title: "Capability handshake", asserts: "a", steps: [] },
      { id: "tracked-prs", title: "tracked PRs", asserts: "b", steps: [] },
    ];
    const md = renderParityMarkdown(scenarios, file);
    expect(md).toContain("- Attempts behind each verdict: 3 per scenario");
    expect(md).toContain("- handshake: 3/3 - Capability handshake");
    expect(md).toContain("- tracked-prs: NO (1/3) - tracked PRs");
  });
});
