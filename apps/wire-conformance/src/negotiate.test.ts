import { describe, expect, it } from "vitest";

import { negotiate, SUITE_REQUIREMENTS } from "./negotiate.ts";
import { loadProtocol } from "./spec.ts";

const spec = loadProtocol();

const swiftCore = {
  protocolVersion: 1,
  capabilities: [
    "queue",
    "trackedPrs",
    "editor",
    "terminal",
    "adoptExternal",
    "inputAck",
    "resizeAck",
    "screen",
  ],
};

// What the Rust core advertises today (juancoded-server/src/wire.rs).
const rustCore = {
  protocolVersion: 1,
  capabilities: ["inputAck", "resizeAck", "screen", "adoptExternal"],
};

describe("negotiate", () => {
  it("accepts the full Swift core and lights up every optional feature", () => {
    const verdict = negotiate(swiftCore, SUITE_REQUIREMENTS);
    expect(verdict.ok).toBe(true);
    if (!verdict.ok) return;
    expect(verdict.version).toBe(1);
    expect(verdict.disabled).toEqual([]);
  });

  it("accepts a narrower core and reports which features to hide", () => {
    const verdict = negotiate(rustCore, SUITE_REQUIREMENTS);
    expect(verdict.ok).toBe(true);
    if (!verdict.ok) return;
    expect(verdict.disabled.sort()).toEqual(["editor", "queue", "terminal", "trackedPrs"]);
  });

  it("refuses a core whose protocol version it does not speak", () => {
    const verdict = negotiate({ ...swiftCore, protocolVersion: 2 }, SUITE_REQUIREMENTS);
    expect(verdict.ok).toBe(false);
    if (verdict.ok) return;
    expect(verdict.versionMismatch).toBe(true);
    expect(verdict.reason).toContain("v2");
  });

  it("refuses a core that is missing a capability the client cannot work without", () => {
    const queueClient = { protocolVersions: [1], required: ["queue"] };
    const verdict = negotiate(rustCore, queueClient);
    expect(verdict.ok).toBe(false);
    if (verdict.ok) return;
    expect(verdict.missing).toEqual(["queue"]);
    expect(verdict.versionMismatch).toBe(false);
  });

  it("refuses on version before it even looks at capabilities", () => {
    const verdict = negotiate({ protocolVersion: 9, capabilities: [] }, SUITE_REQUIREMENTS);
    expect(verdict.ok).toBe(false);
    if (verdict.ok) return;
    expect(verdict.versionMismatch).toBe(true);
    expect(verdict.missing).toEqual(SUITE_REQUIREMENTS.required);
  });

  it("requires exactly what the spec says is required", () => {
    expect(SUITE_REQUIREMENTS.required).toEqual(spec.capabilities.required);
    expect(SUITE_REQUIREMENTS.protocolVersions).toContain(spec.protocolVersion);
  });
});
