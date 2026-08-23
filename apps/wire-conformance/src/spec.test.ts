// Spec integrity: the scenarios and the message catalogue have to agree with each
// other before either is worth running against a core.

import { describe, expect, it } from "vitest";

import { clientVar, seedVars } from "./runner.ts";
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
    const all = new Map([
      ...Object.entries(spec.clientMessages),
      ...Object.entries(spec.serverMessages),
    ]);
    for (const [cap, targets] of Object.entries(spec.capabilities.gates)) {
      expect(spec.capabilities.known, `gate for unknown capability ${cap}`).toContain(cap);
      for (const target of targets) {
        // A gate is a message type, or `type.field` for a capability that gates one
        // optional field of an otherwise ungated message.
        const [type, field] = target.split(".");
        const msg = all.get(type as string);
        expect(msg, `${cap} gates unknown message ${type}`).toBeDefined();
        if (field) expect(msg?.optional, `${cap} gates unknown field ${target}`).toContain(field);
      }
    }
  });

  it("keeps each field capability consistent with the gates", () => {
    for (const [type, msg] of Object.entries(spec.clientMessages)) {
      for (const [field, cap] of Object.entries(msg.fieldCapabilities ?? {})) {
        expect(msg.optional, `${type}.${field} is gated but not optional`).toContain(field);
        expect(spec.capabilities.gates[cap], `${type}.${field} claims ${cap}`).toContain(
          `${type}.${field}`,
        );
      }
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

  it("declare the capabilities the fields they send are gated on", () => {
    // A gated FIELD is the silent case: a core without the capability answers the
    // message anyway, so a scenario that does not declare it would read as a pass.
    for (const s of scenarios) {
      const declared = new Set(s.capabilities ?? []);
      for (const step of s.steps) {
        if (!("send" in step) || typeof step.send.type !== "string") continue;
        const gates = spec.clientMessages[step.send.type]?.fieldCapabilities ?? {};
        for (const [field, cap] of Object.entries(gates)) {
          if (!(field in step.send)) continue;
          expect(
            declared.has(cap),
            `${s.id} sends ${step.send.type}.${field} but does not declare the ${cap} capability`,
          ).toBe(true);
        }
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
        if ("close" in step) {
          expect(open, `${s.id} closes connection ${step.close} before opening it`).toContain(
            step.close,
          );
          continue;
        }
        const on = "on" in step ? step.on : undefined;
        if (on) expect(open, `${s.id} addresses connection ${on} before opening it`).toContain(on);
      }
    }
  });

  it("bind a variable before referencing it", () => {
    for (const s of scenarios) {
      // `$clientA` and friends are bound by the runner out of each connection's own
      // handshake, so a connection's own grid-ownership token counts as bound the
      // moment it is opened.
      const bound = new Set([
        ...Object.keys(seedVars({ cwd: "", gitCwd: "", missingCwd: "", file: "" }, s.id, 1)),
        clientVar("a"),
      ]);
      for (const step of s.steps) {
        if ("open" in step) bound.add(clientVar(step.open));
        for (const name of variableRefs(step)) {
          expect(bound, `${s.id} references $${name} before binding it`).toContain(name);
        }
        if ("bind" in step && step.bind) for (const name of Object.keys(step.bind)) bound.add(name);
      }
    }
  });
});
