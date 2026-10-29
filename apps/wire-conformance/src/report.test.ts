import { describe, expect, it } from "vitest";

import { statusDifferences, type StatusFile } from "./report.ts";

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
