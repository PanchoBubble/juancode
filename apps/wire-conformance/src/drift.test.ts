// The link between the spec and the Swift core's source of truth.
//
// A spec that is merely "documentation" rots the first time someone adds a
// message. So the spec is compared against WireProtocol.swift directly: add a
// client message, a server message, or a capability there and this test goes red
// until spec/v1/protocol.json describes it (and, ideally, a scenario covers it).

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { loadProtocol, loadScenarios, expectedTypes, sentTypes } from "./spec.ts";

const here = dirname(fileURLToPath(import.meta.url));
const WIRE_SWIFT = join(
  here,
  "..",
  "..",
  "native",
  "Sources",
  "JuancodeServer",
  "WireProtocol.swift",
);

function swiftSource(): string | null {
  return existsSync(WIRE_SWIFT) ? readFileSync(WIRE_SWIFT, "utf8") : null;
}

/** Client types the Swift decoder recognises: `case "attach":` in its switch. */
function swiftClientTypes(src: string): string[] {
  const decoder = src.slice(src.indexOf("extension ClientMessage: Decodable"));
  return [...decoder.matchAll(/^\s*case "([a-zA-Z]+)":/gm)].map((m) => m[1] as string);
}

/** Server types the Swift encoder emits: `try c.encode("attached", forKey: .type)`. */
function swiftServerTypes(src: string): string[] {
  return [...src.matchAll(/encode\("([a-zA-Z]+)", forKey: \.type\)/g)].map((m) => m[1] as string);
}

function swiftCapabilities(src: string): string[] {
  const line = /static let capabilities = \[([^\]]*)\]/.exec(src);
  if (!line) return [];
  return [...(line[1] as string).matchAll(/"([^"]+)"/g)].map((m) => m[1] as string);
}

function swiftVersion(src: string): number | null {
  const m = /static let version = (\d+)/.exec(src);
  return m ? Number(m[1]) : null;
}

describe("spec matches WireProtocol.swift", () => {
  const src = swiftSource();
  const spec = loadProtocol();

  it.runIf(src)("covers every client message the Swift core decodes", () => {
    const swift = swiftClientTypes(src as string).sort();
    expect(swift.length).toBeGreaterThan(10);
    expect(Object.keys(spec.clientMessages).sort()).toEqual(swift);
  });

  it.runIf(src)("covers every server message the Swift core encodes", () => {
    const swift = [...new Set(swiftServerTypes(src as string))].sort();
    expect(swift.length).toBeGreaterThan(10);
    expect(Object.keys(spec.serverMessages).sort()).toEqual(swift);
  });

  it.runIf(src)("agrees on the protocol version", () => {
    expect(swiftVersion(src as string)).toBe(spec.protocolVersion);
  });

  it.runIf(src)("knows every capability the Swift core advertises", () => {
    for (const cap of swiftCapabilities(src as string)) {
      expect(spec.capabilities.known).toContain(cap);
    }
  });
});

describe("scenario coverage", () => {
  const spec = loadProtocol();
  const scenarios = loadScenarios();
  const asserted = new Set(scenarios.flatMap(expectedTypes));
  const driven = new Set(scenarios.flatMap(sentTypes));

  it("asserts every server message except the ones documented as uncovered", () => {
    // `trackNotification` needs a real GitHub event to fire, so no scenario can
    // provoke it from a socket alone; it is on the parity checklist instead.
    const uncovered = ["trackNotification"];
    for (const type of Object.keys(spec.serverMessages)) {
      if (uncovered.includes(type)) continue;
      expect(asserted, `no scenario asserts a ${type} frame`).toContain(type);
    }
  });

  it("drives every client message except the ones documented as undriven", () => {
    // `resolveTrackNotification` can only be sent for a notification that exists,
    // which needs the GitHub event above.
    const undriven = ["resolveTrackNotification"];
    for (const type of Object.keys(spec.clientMessages)) {
      if (undriven.includes(type)) continue;
      expect(driven, `no scenario sends a ${type} frame`).toContain(type);
    }
  });
});
