// Spec integrity: the scenarios and the message catalogue have to agree with each
// other before either is worth running against a core.

import { describe, expect, it } from "vitest";

import { expectedTypes, loadProtocol, loadScenarios, sentTypes } from "./spec.ts";

const spec = loadProtocol();
const scenarios = loadScenarios();

/** Variable references in a step's VALUES ("$session"), never in its keys —
 *  matcher operators are keys and look the same. */
function variableRefs(value: unknown, out = new Set<string>()): Set<string> {
  if (typeof value === "string") {
    if (value.startsWith("$") && /^\$[a-zA-Z][a-zA-Z0-9]*$/.test(value)) out.add(value.slice(1));
    return out;
  }
  if (Array.isArray(value)) {
    for (const v of value) variableRefs(v, out);
    return out;
  }
  if (typeof value === "object" && value !== null) {
    for (const v of Object.values(value)) variableRefs(v, out);
  }
  return out;
}

describe("protocol catalogue", () => {
  it("declares a version and a required capability set", () => {
    expect(spec.protocolVersion).toBe(1);
    expect(spec.capabilities.required.length).toBeGreaterThan(0);
    for (const cap of spec.capabilities.required) {
      expect(spec.capabilities.known).toContain(cap);
    }
  });

  it("gates every capability onto messages that exist", () => {
    const all = new Set([...Object.keys(spec.clientMessages), ...Object.keys(spec.serverMessages)]);
    for (const [cap, types] of Object.entries(spec.capabilities.gates)) {
      expect(spec.capabilities.known, `gate for unknown capability ${cap}`).toContain(cap);
      for (const type of types) expect(all, `${cap} gates unknown message ${type}`).toContain(type);
    }
  });

  it("keeps each message's capability consistent with the gates", () => {
    const entries = [
      ...Object.entries(spec.clientMessages),
      ...Object.entries(spec.serverMessages),
    ];
    for (const [type, msg] of entries) {
      if (!msg.capability) continue;
      expect(spec.capabilities.gates[msg.capability], `${type} claims ${msg.capability}`).toContain(
        type,
      );
    }
  });
});

describe("scenarios", () => {
  it("all parse with unique ids", () => {
    expect(scenarios.length).toBeGreaterThan(10);
    const ids = scenarios.map((s) => s.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("say what they buy a client", () => {
    for (const s of scenarios) {
      expect(s.title.length, `${s.id} has no title`).toBeGreaterThan(0);
      expect(s.asserts.length, `${s.id} does not say what it asserts`).toBeGreaterThan(30);
    }
  });

  it("only reference message types the spec knows", () => {
    for (const s of scenarios) {
      for (const type of sentTypes(s)) {
        // `someFutureMessage` is deliberately unknown: that is the point of the
        // tolerate-unknown-types rule.
        if (type === "someFutureMessage") continue;
        expect(spec.clientMessages, `${s.id} sends unknown ${type}`).toHaveProperty(type);
      }
      for (const type of expectedTypes(s)) {
        expect(spec.serverMessages, `${s.id} expects unknown ${type}`).toHaveProperty(type);
      }
    }
  });

  it("declare the capabilities their messages are gated on", () => {
    for (const s of scenarios) {
      const declared = new Set(s.capabilities ?? []);
      for (const type of [...sentTypes(s), ...expectedTypes(s)]) {
        const msg = spec.clientMessages[type] ?? spec.serverMessages[type];
        if (!msg?.capability) continue;
        expect(
          declared.has(msg.capability),
          `${s.id} touches ${type} but does not declare the ${msg.capability} capability`,
        ).toBe(true);
      }
    }
  });

  it("open every connection they address", () => {
    for (const s of scenarios) {
      const open = new Set(["a"]);
      for (const step of s.steps) {
        if ("open" in step) {
          open.add(step.open);
          continue;
        }
        const on = "on" in step ? step.on : undefined;
        if (on) expect(open, `${s.id} addresses connection ${on} before opening it`).toContain(on);
      }
    }
  });

  it("bind a variable before referencing it", () => {
    for (const s of scenarios) {
      const bound = new Set(["cwd", "gitCwd", "missingCwd", "file", "dispatchId", "requestId"]);
      for (const step of s.steps) {
        for (const name of variableRefs(step)) {
          expect(bound, `${s.id} references $${name} before binding it`).toContain(name);
        }
        if ("bind" in step && step.bind) for (const name of Object.keys(step.bind)) bound.add(name);
      }
    }
  });
});
