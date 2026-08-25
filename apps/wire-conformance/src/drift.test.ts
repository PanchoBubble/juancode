// The link between the spec and the cores' sources of truth.
//
// A spec that is merely "documentation" rots the first time someone adds a
// message. So the spec is compared against the cores directly: add a client
// message, a server message, or a capability to either one and this test goes red
// until spec/v1/protocol.json describes it (and, ideally, a scenario covers it).
//
// The catalogue is the UNION of what the cores speak, not a mirror of one of them
// (see the CATALOGUE_IS_THE_UNION rule in protocol.json). What says which core
// speaks a message is its capability gate, so each core is measured against the
// messages its own advertised capability list entails:
//
//   * nothing off the catalogue - a type a core speaks that this file does not
//     describe is drift, whichever core grew it;
//   * no empty promises - a capability a core advertises must come with every
//     frame its gate names, because clients feature-detect off exactly that.
//
// Neither half asks a core to grow a decode case, or an encoder it would never
// use, for a capability it does not advertise. The rule this replaced compared the
// catalogue to WireProtocol.swift alone, which is why `editQueued` and the three
// transcript frames were implemented, advertised and unlistable - and therefore
// unmeasurable, since a golden transcript may only reference catalogued types.

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { loadProtocol, loadScenarios, expectedTypes, sentTypes } from "./spec.ts";

const here = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(here, "..", "..", "..");

/** A capability a core implements in full and deliberately does not advertise,
 *  plus the types that would be catalogued the day it does. */
interface Withheld {
  capability: string;
  types: string[];
  why: string;
}

/** One core's wire source, and how to read the four things out of it. */
interface CoreProbe {
  name: string;
  path: string;
  clientTypes(src: string): string[];
  serverTypes(src: string): string[];
  capabilities(src: string): string[];
  version(src: string): number | null;
  /** Frames behind a capability this core withholds. Exempt from the
   *  nothing-off-the-catalogue check for exactly as long as it stays withheld. */
  withheld: Withheld[];
}

const SWIFT: CoreProbe = {
  name: "swift",
  path: join(REPO_ROOT, "apps", "native", "Sources", "JuancodeServer", "WireProtocol.swift"),
  /** Client types the decoder recognises: `case "attach":` in its switch. */
  clientTypes: (src) => {
    const decoder = src.slice(src.indexOf("extension ClientMessage: Decodable"));
    return [...decoder.matchAll(/^\s*case "([a-zA-Z]+)":/gm)].map((m) => m[1] as string);
  },
  /** Server types the encoder emits: `try c.encode("attached", forKey: .type)`. */
  serverTypes: (src) =>
    [...src.matchAll(/encode\("([a-zA-Z]+)", forKey: \.type\)/g)].map((m) => m[1] as string),
  capabilities: (src) => {
    const line = /static let capabilities = \[([^\]]*)\]/.exec(src);
    if (!line) return [];
    return [...(line[1] as string).matchAll(/"([^"]+)"/g)].map((m) => m[1] as string);
  },
  version: (src) => {
    const m = /static let version = (\d+)/.exec(src);
    return m ? Number(m[1]) : null;
  },
  withheld: [],
};

const RUST: CoreProbe = {
  name: "rust",
  path: join(REPO_ROOT, "apps", "juancoded", "crates", "juancoded-server", "src", "wire.rs"),
  /** Client types the decoder recognises: `"attach" => Ok(Self::Attach {` in its
   *  match. Sliced to the decode fn so the module's own tests, which are full of
   *  frame literals, cannot contribute a type nothing decodes. */
  clientTypes: (src) => {
    const decoder = src.slice(
      src.indexOf("pub fn decode"),
      src.indexOf("impl From<&str> for ClientMessage"),
    );
    return [...decoder.matchAll(/^\s*"([a-zA-Z]+)" =>/gm)].map((m) => m[1] as string);
  },
  /** Server types the encoder emits: `"type": "attached"` inside `to_value`.
   *  Sliced for the same reason, and more sharply: a test asserting on a CLIENT
   *  frame literal would otherwise read as a server frame this core encodes. */
  serverTypes: (src) => {
    const encoder = src.slice(src.indexOf("pub fn to_value"), src.indexOf("#[cfg(test)]"));
    return [...encoder.matchAll(/"type":\s*"([a-zA-Z]+)"/g)].map((m) => m[1] as string);
  },
  capabilities: (src) => {
    const line = /pub const CAPABILITIES: &\[&str\] = &\[([^\]]*)\]/.exec(src);
    if (!line) return [];
    return [...(line[1] as string).matchAll(/"([^"]+)"/g)].map((m) => m[1] as string);
  },
  version: (src) => {
    const m = /pub const PROTOCOL_VERSION: u32 = (\d+)/.exec(src);
    return m ? Number(m[1]) : null;
  },
  withheld: [
    {
      capability: "contributions",
      types: [
        "subscribeContributions",
        "unsubscribeContributions",
        "activateContribution",
        "contributions",
        "contributionResult",
      ],
      why: "the daemon side is complete but nothing renders a descriptor yet, so advertising it would promise chrome nothing draws",
    },
  ],
};

const PROBES: CoreProbe[] = [SWIFT, RUST];

function sourceOf(probe: CoreProbe): string | null {
  return existsSync(probe.path) ? readFileSync(probe.path, "utf8") : null;
}

const spec = loadProtocol();

/** The messages a core advertising `caps` has promised to implement: everything
 *  ungated, plus everything gated by a capability it advertises. */
function entailedBy(caps: string[], messages: Record<string, { capability?: string }>): string[] {
  return Object.entries(messages)
    .filter(([, m]) => m.capability === undefined || caps.includes(m.capability))
    .map(([type]) => type);
}

/** Types this core may speak without cataloguing them, because the capability
 *  behind them is one it does not advertise. Advertising it removes the exemption,
 *  which is what makes the catalogue catch the frames on the day they go public. */
function exempt(probe: CoreProbe, caps: string[]): string[] {
  return probe.withheld.filter((w) => !caps.includes(w.capability)).flatMap((w) => w.types);
}

describe.each(PROBES)("the $name core against the catalogue", (probe) => {
  const src = sourceOf(probe);
  const caps = src ? probe.capabilities(src) : [];

  it.runIf(src)("speaks no client message this catalogue does not describe", () => {
    const spoken = [...new Set(probe.clientTypes(src as string))];
    // A regex that matched nothing would make every subset check below pass.
    expect(spoken.length, "the client-type regex found nothing").toBeGreaterThan(10);
    const allowed = new Set([...Object.keys(spec.clientMessages), ...exempt(probe, caps)]);
    expect(spoken.filter((t) => !allowed.has(t))).toEqual([]);
  });

  it.runIf(src)("speaks no server message this catalogue does not describe", () => {
    const spoken = [...new Set(probe.serverTypes(src as string))];
    expect(spoken.length, "the server-type regex found nothing").toBeGreaterThan(10);
    const allowed = new Set([...Object.keys(spec.serverMessages), ...exempt(probe, caps)]);
    expect(spoken.filter((t) => !allowed.has(t))).toEqual([]);
  });

  it.runIf(src)("implements every message its advertised capabilities entail", () => {
    // The half a client depends on: it switches a feature on because the core said
    // the capability's name, so every frame that gate covers has to be answered.
    const client = new Set(probe.clientTypes(src as string));
    const server = new Set(probe.serverTypes(src as string));
    expect(entailedBy(caps, spec.clientMessages).filter((t) => !client.has(t))).toEqual([]);
    expect(entailedBy(caps, spec.serverMessages).filter((t) => !server.has(t))).toEqual([]);
  });

  it.runIf(src)("advertises only capabilities the catalogue knows", () => {
    expect(caps.length).toBeGreaterThan(0);
    for (const cap of caps) expect(spec.capabilities.known).toContain(cap);
  });

  it.runIf(src)("agrees on the protocol version", () => {
    expect(probe.version(src as string)).toBe(spec.protocolVersion);
  });
});

describe("the catalogue against the cores", () => {
  // The other direction, and the one the per-core checks cannot cover on their own:
  // each of those measures a core against the subset the catalogue gates onto it, so
  // an invented message gated by an invented capability would be nobody's problem.
  // It is everybody's here.
  const sources = PROBES.map((probe) => ({ probe, src: sourceOf(probe) })).filter(
    (p): p is { probe: CoreProbe; src: string } => p.src !== null,
  );
  const complete = sources.length === PROBES.length;

  it.runIf(complete)("describes no message neither core implements", () => {
    const spoken = new Set(
      sources.flatMap(({ probe, src }) => [...probe.clientTypes(src), ...probe.serverTypes(src)]),
    );
    const orphans = [...Object.keys(spec.clientMessages), ...Object.keys(spec.serverMessages)]
      .filter((t) => !spoken.has(t))
      .sort();
    expect(orphans, "catalogued but implemented by no core").toEqual([]);
  });

  it.runIf(complete)("knows no capability neither core advertises", () => {
    const advertised = new Set(sources.flatMap(({ probe, src }) => probe.capabilities(src)));
    expect(spec.capabilities.known.filter((c) => !advertised.has(c))).toEqual([]);
  });
});

describe("scenario coverage", () => {
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
